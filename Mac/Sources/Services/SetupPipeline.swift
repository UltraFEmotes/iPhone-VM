import Foundation

/// Turns a new VM (device + iOS + jailbreak choice) into a bootable, patched Inferno VM.
/// Each finished step is recorded in `<vm>/steps.json`, so setup resumes after a relaunch.
@MainActor
final class SetupPipeline: ObservableObject {
    enum Step: String, CaseIterable, Codable, Identifiable {
        case checkSpace, downloadIPSW, downloadSEPROM, extract, tickets, sepFirmware, disks, restore, patch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .checkSpace: return "Check free space"
            case .downloadIPSW: return "Download firmware from Apple"
            case .downloadSEPROM: return "Download SEP ROM"
            case .extract: return "Unpack firmware"
            case .tickets: return "Create boot tickets"
            case .sepFirmware: return "Prepare Secure Enclave firmware"
            case .disks: return "Create disks"
            case .restore: return "Restore iOS (companion VM)"
            case .patch: return "Patch filesystem (asks for your password)"
            }
        }
    }

    enum StepState: Equatable { case pending, running, done, failed(String) }

    @Published private(set) var states: [Step: StepState] = [:]
    @Published private(set) var progress: Double?
    @Published private(set) var log = ""
    @Published private(set) var isRunning = false

    private(set) var vm: VirtualMachine
    let entry: SupportEntry
    private let store: VMStore
    private let keepAwake = KeepAwake()

    /// Shared with the companion VM through its 9p share of InfernoData.
    static let ipswCache = InfernoPaths.dataRoot.appendingPathComponent("ipsw-cache", isDirectory: true)
    private var ipswFile: URL { Self.ipswCache.appendingPathComponent(entry.ipswURL.lastPathComponent) }
    private var sharedTicket: URL { Self.ipswCache.appendingPathComponent("\(vm.id.uuidString)-root_ticket.der") }
    private var restoreDir: URL { vm.file("Restore") }

    init(vm: VirtualMachine, entry: SupportEntry, store: VMStore) {
        self.vm = vm
        self.entry = entry
        self.store = store
        let finished = Self.loadFinished(vm)
        Step.allCases.forEach { states[$0] = finished.contains($0) ? .done : .pending }
    }

    // MARK: running

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Notifier.requestPermission()
        keepAwake.begin(reason: "InfernoMac is setting up \(vm.name)")
        Task {
            defer { isRunning = false; keepAwake.end(); progress = nil }
            for step in Step.allCases where states[step] != .done {
                if entry.usesSEPSim == true, [.downloadSEPROM, .sepFirmware].contains(step) {
                    states[step] = .done
                    append("== \(step.title): not needed (simulated Secure Enclave)")
                    markFinished(step)
                    continue
                }
                states[step] = .running
                append("== \(step.title)")
                do {
                    try await run(step)
                    states[step] = .done
                    markFinished(step)
                } catch {
                    states[step] = .failed(error.localizedDescription)
                    append("!! \(error.localizedDescription)")
                    setState(.failed)
                    Notifier.post(title: "\(vm.name): setup failed", body: "\(step.title): \(error.localizedDescription)")
                    return
                }
            }
            setState(.ready)
            Notifier.post(title: "\(vm.name) is ready", body: "Restore complete. You can start the VM.")
        }
    }

    private func run(_ step: Step) async throws {
        switch step {
        case .checkSpace: try checkSpace()
        case .downloadIPSW: setState(.downloading); try await downloadIPSW()
        case .downloadSEPROM: try await download(entry.sepROMURL, to: vm.file(entry.sepROM))
        case .extract: setState(.preparing); try await extract()
        case .tickets: try await makeTickets()
        case .sepFirmware: try await repackSEP()
        case .disks: try await createDisks()
        case .restore: setState(.restoring); try await restore()
        case .patch: setState(.patching); try await patch()
        }
    }

    // MARK: steps

    private func checkSpace() throws {
        let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let need: Int64 = FileManager.default.fileExists(atPath: ipswFile.path) ? 12_000_000_000 : 18_000_000_000
        append("free: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)), need about \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file))")
        guard free >= need else { throw SetupError("Not enough free space") }
    }

    private func downloadIPSW() async throws {
        try FileManager.default.createDirectory(at: Self.ipswCache, withIntermediateDirectories: true)
        if let size = try? FileManager.default.attributesOfItem(atPath: ipswFile.path)[.size] as? Int64, size == entry.ipswSize {
            append("already downloaded"); return
        }
        // Only one download per IPSW file, even across VMs sharing the cache.
        let lock = ipswFile.appendingPathExtension("lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            throw SetupError("This firmware is already being downloaded by another setup. Try again when it finishes.")
        }
        defer { flock(fd, LOCK_UN); close(fd); try? FileManager.default.removeItem(at: lock) }
        // curl resumes partial downloads (-C -) and reports progress we parse into `progress`.
        try await Shell.run("/usr/bin/curl", ["-L", "-f", "-C", "-", "-o", ipswFile.path, "-#", entry.ipswURL.absoluteString]) { line in
            if let pct = line.split(separator: " ").last(where: { $0.hasSuffix("%") }).flatMap({ Double($0.dropLast()) }) {
                Task { @MainActor in self.progress = pct / 100 }
            }
        }
        let size = (try FileManager.default.attributesOfItem(atPath: ipswFile.path)[.size] as? Int64) ?? 0
        guard size == entry.ipswSize else { throw SetupError("IPSW size \(size) != expected \(entry.ipswSize)") }
    }

    private func download(_ url: URL, to dest: URL) async throws {
        if FileManager.default.fileExists(atPath: dest.path) { return }
        try await Shell.run("/usr/bin/curl", ["-L", "-f", "-s", "-o", dest.path, url.absoluteString])
    }

    private func extract() async throws {
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        let wanted = ["BuildManifest.plist", entry.kernelcache, entry.deviceTree, entry.trustcache,
                      entry.eraseRamdisk, entry.sepFirmwarePath]
        try await Shell.run("/usr/bin/unzip", ["-o", "-q", ipswFile.path] + wanted + ["-d", restoreDir.path], onLine: logLine)
        let copies: [(String, String)] = [(entry.kernelcache, "kernelcache"), (entry.deviceTree, "devicetree.im4p"),
                                          (entry.trustcache, "trustcache"), (entry.eraseRamdisk, "ramdisk_erase.dmg")]
        for (src, dst) in copies {
            try? FileManager.default.removeItem(at: vm.file(dst))
            try FileManager.default.copyItem(at: restoreDir.appendingPathComponent(src), to: vm.file(dst))
        }
    }

    private func makeTickets() async throws {
        let py = InfernoPaths.dataRoot.appendingPathComponent("venv/bin/python").path
        let shsh = InfernoPaths.dataRoot.appendingPathComponent("ticket.shsh2").path
        let manifest = restoreDir.appendingPathComponent("BuildManifest.plist").path
        let simulatedSEP = entry.usesSEPSim == true
        let tickets = simulatedSEP ? [("create_apticket.py", "root_ticket.der")]
            : [("create_apticket.py", "root_ticket.der"), ("create_septicket.py", "sep_root_ticket.der")]
        for (script, out) in tickets {
            do {
                try await Shell.run(py, [InfernoPaths.dataRoot.appendingPathComponent(script).path, entry.board,
                                         manifest, shsh, vm.file(out).path], onLine: logLine)
            } catch where simulatedSEP {
                // This machine boots without an AP ticket; carry on without one.
                append("AP ticket not created (\(error.localizedDescription)); continuing without it")
            }
        }
    }

    private func repackSEP() async throws {
        let img4 = InfernoPaths.dataRoot.appendingPathComponent("img4lib/img4").path
        let raw = vm.file("sep-firmware.raw").path
        let version = try await Shell.run(img4, ["-v", "-i", restoreDir.appendingPathComponent(entry.sepFirmwarePath).path,
                                                 "-o", raw, "-k", entry.sepIV + entry.sepKey])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let out = try await Shell.run(img4, ["-A", "-F", "-o", vm.file("sep-firmware.img4").path, "-i", raw,
                                             "-M", vm.file("sep_root_ticket.der").path, "-T", "rsep", "-V", version])
        guard out.contains("none") || out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SetupError("SEP repack output unexpected: \(out)")
        }
        try? FileManager.default.removeItem(atPath: raw)
    }

    private func createDisks() async throws {
        var sizes = [("root", "32G"), ("firmware", "8M"), ("syscfg", "128K"), ("ctrl_bits", "8K"), ("nvram", "8K"),
                     ("effaceable", "4K"), ("panic_log", "1M")]
        if entry.usesSEPSim != true {
            sizes += [("sep_nvram", "64K"), ("sep_ssc", "128K")]
        }
        for (name, size) in sizes where !FileManager.default.fileExists(atPath: vm.file(name).path) {
            try await Shell.run(InfernoPaths.qemuImg.path, ["create", "-f", "raw", vm.file(name).path, size])
        }
    }

    private func restore() async throws {
        let ssh = ["-i", InfernoPaths.dataRoot.appendingPathComponent("companion_key").path, "-p", "32222",
                   "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
                   "-o", "ServerAliveInterval=30", "inferno@localhost"]
        // 1. companion VM up
        if (try? await Shell.run("/usr/bin/ssh", ssh + ["-o", "ConnectTimeout=5", "true"])) == nil {
            append("starting companion VM")
            try await Shell.run(InfernoPaths.startCompanion.path, [])
            var up = false
            for _ in 0..<40 where !up {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                up = (try? await Shell.run("/usr/bin/ssh", ssh + ["-o", "ConnectTimeout=5", "true"])) != nil
            }
            guard up else { throw SetupError("companion VM did not come up") }
        }
        // 2. ticket where the companion can read it; OS image pre-extracted into idevicerestore's cache
        try? FileManager.default.removeItem(at: sharedTicket)
        try FileManager.default.copyItem(at: vm.file("root_ticket.der"), to: sharedTicket)
        let ipswName = ipswFile.lastPathComponent
        let cacheDir = "~/cache/" + (ipswName as NSString).deletingPathExtension
        let precache = """
        mkdir -p \(cacheDir) && python3 - <<'EOF'
        import zipfile, shutil, os
        z = zipfile.ZipFile("/mnt/host/ipsw-cache/\(ipswName)")
        big = max(z.infolist(), key=lambda i: i.file_size if i.filename.endswith((".dmg", ".dmg.aea")) else 0)
        dest = os.path.expanduser("\(cacheDir)/" + big.filename)
        if not (os.path.exists(dest) and os.path.getsize(dest) == big.file_size):
            with z.open(big) as s, open(dest, "wb") as d: shutil.copyfileobj(s, d, 16 << 20)
        print("cached", big.filename)
        EOF
        """
        append("caching OS image in companion (several minutes)")
        try await Shell.run("/usr/bin/ssh", ssh + [precache], onLine: logLine)
        // 3. boot restore ramdisk, then trigger the restore within its 120 s window
        let runner = VMRunner(vm: vm, entry: entry)
        runner.start(restoreMode: true)
        // Never leave the restore-ramdisk VM running when the restore fails part-way.
        defer { if runner.isRunning { runner.stop() } }
        var ready = false
        for _ in 0..<120 where !ready {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            ready = runner.log.contains("waiting for host to trigger start of restore")
            if !runner.isRunning && runner.lastExit != nil { break }
        }
        guard ready else { runner.stop(); throw SetupError("restore ramdisk never became ready") }
        append("ramdisk ready, running idevicerestore")
        let restoreCmd = "sudo idevicerestore --erase --restore-mode -i 0x1122334455667788 -C ~/cache " +
            "/mnt/host/ipsw-cache/\(ipswName) -T /mnt/host/ipsw-cache/\(sharedTicket.lastPathComponent)"
        let out = try await Shell.run("/usr/bin/ssh", ssh + [restoreCmd], onLine: logLine)
        guard out.contains("Restore Finished") || out.contains("DONE") else { throw SetupError("idevicerestore did not finish") }
        for _ in 0..<60 where runner.isRunning { try await Task.sleep(nanoseconds: 1_000_000_000) }
        runner.stop()
        try? FileManager.default.removeItem(at: sharedTicket)
    }

    private func patch() async throws {
        guard let script = Bundle.main.url(forResource: "patch_fs", withExtension: "sh") else {
            throw SetupError("patch_fs.sh missing from app bundle")
        }
        let cmd = ["/bin/bash", script.path, vm.folder.path, InfernoPaths.dataRoot.path, vm.jailbroken ? "1" : "0"]
            .map(Shell.quote).joined(separator: " ")
        let out = try await Shell.asAdministrator(cmd)
        append(out)
        guard out.contains("FS_PATCHES_DONE") else { throw SetupError("filesystem patch did not complete") }
    }

    // MARK: bookkeeping

    private func setState(_ state: VirtualMachine.SetupState) {
        vm.state = state
        try? store.save(vm)
    }

    private func append(_ line: String) {
        log += line + "\n"
        if log.utf8.count > 300_000 { log = String(log.suffix(150_000)) }
    }

    private nonisolated func logLine(_ line: String) {
        Task { @MainActor in self.append(line) }
    }

    private func markFinished(_ step: Step) {
        var finished = Self.loadFinished(vm)
        finished.insert(step)
        try? JSONEncoder().encode(Array(finished)).write(to: vm.file("steps.json"))
    }

    private static func loadFinished(_ vm: VirtualMachine) -> Set<Step> {
        guard let data = try? Data(contentsOf: vm.file("steps.json")),
              let list = try? JSONDecoder().decode([Step].self, from: data) else { return [] }
        return Set(list)
    }
}

struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
