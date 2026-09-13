import Foundation

/// Runs one Inferno VM as a child `qemu-system-aarch64` process.
/// Serial output streams into `log` (the Terminal tab); device buttons go over QMP `send-key`.
@MainActor
final class VMRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var log = ""
    @Published private(set) var lastExit: Int32?

    let vm: VirtualMachine
    let entry: SupportEntry
    private var process: Process?
    private var stdinPipe: Pipe?
    private let maxLogBytes = 400_000

    var qmpSocket: URL { vm.file("qmp.sock") }

    init(vm: VirtualMachine, entry: SupportEntry) {
        self.vm = vm
        self.entry = entry
    }

    /// Inferno machine arguments for a restored, patched VM (same layout as InfernoData/start_iphone.sh).
    func arguments(restoreMode: Bool = false) -> [String] {
        let f = { (name: String) in self.vm.file(name).path }
        let simulatedSEP = entry.usesSEPSim == true
        // Phone Info properties exist only on the iPhone 11 (t8030) machine.
        let identity = entry.machine == "t8030" ? (vm.identity?.machineProperties ?? []).map { "," + $0 }.joined() : ""
        var machine = "\(entry.machine),trustcache=\(f("trustcache")),kaslr-off=true"
        if !simulatedSEP || FileManager.default.fileExists(atPath: f("root_ticket.der")) {
            machine += ",ticket=\(f("root_ticket.der"))"
        }
        if !simulatedSEP {
            machine += ",sep-fw=\(f("sep-firmware.img4")),sep-rom=\(f(entry.sepROM))"
        }
        var args = [
            "-M", machine + identity,
            // Multi-threaded TCG spreads the emulated cores over host threads (the guest CPU is emulated;
            // Inferno's Apple SoC can't use HVF). tb-size is kept modest to avoid adding host memory pressure.
            "-accel", "tcg,thread=multi,tb-size=256",
            "-kernel", f("kernelcache"),
            "-dtb", f("devicetree.im4p"),
            "-append", entry.bootArgs + (vm.jailbroken ? " launchd_unsecure_cache=1" : ""),
            "-smp", "\(entry.cpus)", "-m", entry.memory,
            "-serial", "stdio", "-monitor", "none",
            "-qmp", "unix:\(qmpSocket.path),server=on,wait=off",
            // zoom-interpolation is a per-frame host scaling cost; drop it (scaling stays, just not smoothed).
            "-display", "cocoa,zoom-to-fit=on,show-cursor=on",
        ]
        if !simulatedSEP {
            // SEP storage flash (t8030); the s8000 simulated SEP has no pflash.
            args += ["-drive", "file=\(f("sep_nvram")),if=pflash,format=raw",
                     "-drive", "file=\(f("sep_ssc")),if=pflash,format=raw"]
        }
        let namespaces: [(String, Int, Int, String)] = [
            ("root", 1, 1, "nvme-ns"), ("firmware", 2, 2, "nvme-ns"), ("syscfg", 3, 3, "nvme-ns"),
            ("ctrl_bits", 4, 4, "nvme-ns"), ("nvram", 5, 5, "apple-nvram"), ("effaceable", 6, 6, "nvme-ns"),
            ("panic_log", 7, 8, "nvme-ns"),
        ]
        for (name, nsid, nstype, device) in namespaces {
            // The root disk may be stored compressed (root.qcow2) to save space.
            let qcow = vm.file(name + ".qcow2")
            let drive = FileManager.default.fileExists(atPath: qcow.path)
                ? "file=\(qcow.path),format=qcow2" : "file=\(f(name)),format=raw"
            args += ["-drive", "\(drive),if=none,id=\(name)",
                     "-device", "\(device),drive=\(name),bus=nvme-bus.0,nsid=\(nsid),nstype=\(nstype)" +
                        (device == "apple-nvram" ? ",id=nvram" : "") +
                        ",logical_block_size=4096,physical_block_size=4096"]
        }
        if restoreMode {
            args += ["-initrd", f("ramdisk_erase.dmg")]
        }
        return args
    }

    /// Boots the VM. The companion VM is started first if needed: it provides the emulated USB link
    /// (/tmp/InfernoUSBRemote) that gives the iPhone VM internet through reverse tethering.
    func start(restoreMode: Bool = false) {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            if !restoreMode {
                await ensureCompanion()
            }
            launch(restoreMode: restoreMode)
        }
    }

    @Published private(set) var isStarting = false

    private static func companionRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "qemu-system-aarch64 -M virt"]
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func ensureCompanion() async {
        if Self.companionRunning() { return }
        append("[starting companion VM for USB internet]\n")
        do {
            try await Shell.run(InfernoPaths.startCompanion.path, [])
        } catch {
            append("[companion failed to start: \(error.localizedDescription) — booting without internet]\n")
            return
        }
        // Wait for the companion's USB socket; the iPhone VM connects to it at boot.
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath: "/tmp/InfernoUSBRemote") { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        try? await Task.sleep(nanoseconds: 20_000_000_000) // let Debian bring up usbmuxd/dnsmasq
        append("[companion ready]\n")
    }

    private func launch(restoreMode: Bool) {
        guard !isRunning else { return }
        try? FileManager.default.removeItem(at: qmpSocket)
        let p = Process()
        let engine = InfernoPaths.qemu(forSEP: entry.sepVersion)
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            append("[missing Inferno engine for iOS \(entry.sepVersion ?? 14): \(engine.path)]\n")
            return
        }
        p.executableURL = engine
        p.arguments = arguments(restoreMode: restoreMode)
        p.currentDirectoryURL = vm.folder
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            Task { @MainActor in
                self?.appendRaw(data)
                if let text { self?.append(text) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.isRunning = false
                self?.lastExit = proc.terminationStatus
                self?.append("\n[VM exited with status \(proc.terminationStatus)]\n")
                self?.saveLog()
            }
        }
        do {
            append("[starting \(entry.deviceName) \(entry.ios)]\n")
            try p.run()
            process = p
            stdinPipe = input
            isRunning = true
            lastExit = nil
        } catch {
            append("[failed to start QEMU: \(error.localizedDescription)]\n")
        }
    }

    func stop() {
        process?.terminate()
    }

    /// Text typed in the Terminal tab goes to the guest's serial console (e.g. the jailbreak bash).
    func sendToSerial(_ line: String) {
        stdinPipe?.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// Raw keystrokes from the interactive console (arrows, Tab, Ctrl-C…), sent to the serial port as-is.
    func sendRaw(_ bytes: Data) {
        guard isRunning else { return }
        stdinPipe?.fileHandleForWriting.write(bytes)
    }

    /// When the user last typed in the interactive console. The carrier reply-poller backs off while the
    /// user is typing so its `carrier-msg poll` lines don't collide with their commands on the shared serial.
    private(set) var lastInteractiveInput = Date.distantPast
    func noteInteractiveInput() { lastInteractiveInput = Date() }
    var interactiveInputIsRecent: Bool { Date().timeIntervalSince(lastInteractiveInput) < 8 }

    /// Raw serial output for the interactive console. Every chunk is passed on unmodified, so the
    /// terminal sees escape sequences; `rawBacklog` replays recent output when a console opens.
    private(set) var rawBacklog = Data()
    private var rawListeners: [UUID: (Data) -> Void] = [:]
    private let maxRawBacklog = 256_000

    func addRawListener(_ listener: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        rawListeners[id] = listener
        return id
    }

    func removeRawListener(_ id: UUID) {
        rawListeners[id] = nil
    }

    private func appendRaw(_ data: Data) {
        rawBacklog.append(data)
        if rawBacklog.count > maxRawBacklog { rawBacklog = rawBacklog.suffix(maxRawBacklog / 2) }
        rawListeners.values.forEach { $0(data) }
    }

    /// Writes a message into the Terminal log (used by the VM tab's buttons).
    func note(_ text: String) {
        append("\n[\(text)]\n")
    }

    /// Asks iOS (via the companion) to pair, which shows the "Trust This Computer?" prompt in the VM.
    func sendTrustPrompt() async {
        note("asking iOS to trust the companion…")
        switch await Companion.sendTrustPrompt() {
        case .paired:
            note("paired ✓ — USB internet should come up within a minute")
        case .denied:
            note("iOS is refusing on this USB connection (Don't Trust was tapped). Stop and Start the VM, then press Send Trust Prompt again and tap Trust.")
        case .noDevice:
            note("the companion doesn't see the iPhone yet — wait until iOS has fully booted, then try again")
        case .other(let message):
            note(message)
        }
    }

    /// Remounts the System volume read-write and creates the dpkg/apt folders (lasts until reboot).
    func makeSystemWritable() {
        note("remounting / read-write")
        ["mount -uw /",
         "mkdir -p /var/lib/dpkg/info /var/lib/dpkg/updates /var/lib/apt/lists/partial /var/cache/apt/archives/partial /etc/apt/sources.list.d",
         "touch /var/lib/dpkg/status /var/lib/dpkg/available",
         "mount | grep ' / ' && echo SYSTEM_WRITABLE"].forEach(sendToSerial)
    }

    enum PackageManager: String, CaseIterable, Identifiable {
        case zebra = "Zebra", sileo = "Sileo"
        var id: String { rawValue }
        var sourceLine: String {
            switch self {
            case .zebra: return "deb [trusted=yes] https://getzbra.com/repo/ ./"
            case .sileo: return "deb [trusted=yes] https://repo.getsileo.app/ ./"
            }
        }
        var package: String { self == .zebra ? "xyz.willy.zebra" : "org.coolstar.sileo" }
        var app: String { "/Applications/\(rawValue).app" }
    }

    /// Installs a package manager through the jailbreak's root shell on the serial console (needs internet).
    /// The dpkg database starts empty (the bootstrap's copy is hidden under the Data volume), so the
    /// debs are installed with dpkg --force-depends instead of apt.
    func install(_ manager: PackageManager) {
        note("installing \(manager.rawValue) (needs internet; watch the output below)")
        makeSystemWritable()
        let list = manager.rawValue.lowercased()
        [   // Elucubratus (the checkra1n bootstrap's repo) for iOS 14 = CoreFoundation 1700
            "echo 'deb https://apt.bingner.com/ ios/1700.00 main' > /etc/apt/sources.list.d/bingner.list",
            "echo '\(manager.sourceLine)' > /etc/apt/sources.list.d/\(list).list",
            "apt-get update",
            "mkdir -p /tmp/debs && cd /tmp/debs && rm -f *.deb && apt-get download --allow-unauthenticated \(manager.package) uikittools",
            "dpkg -i --force-depends --force-overwrite /tmp/debs/*.deb",
            "uicache -p \(manager.app)",
            "echo \(manager.rawValue.uppercased())_INSTALL_DONE",
            "killall -9 SpringBoard",
        ].forEach(sendToSerial)
    }

    /// Installs the carrier helper: a sqlite3 signed on the Mac with the SMS storage entitlement
    /// (InfernoData/carrier/carrier-sqlite3), served by the companion at 192.168.178.1:8088 and pulled
    /// into the VM. iOS's sandbox refuses the Messages folder even to root without that entitlement.
    func setupCarrier() async {
        note("setting up the carrier helper (installs carrier-sqlite3 + carrier-msg via apt)…")
        // The companion serves the helper's apt repo over the VM's USB-tether network.
        let served = await Companion.run("bash /mnt/host/carrier/serve.sh").trimmingCharacters(in: .whitespacesAndNewlines)
        guard served.contains("HTTP 200") else {
            note("the companion isn't serving the carrier repo (\(served)). Start the VM's internet first (Send Trust Prompt).")
            return
        }
        // The VM has no curl, so install through apt. Isolate our repo so other repos can't fail the update.
        [
            "mount -uw /",
            "mkdir -p /usr/local/bin /etc/apt/sources.list.d /tmp/cs /var/lib/dpkg; touch /var/lib/dpkg/status",
            "mkdir -p /tmp/othersrc; mv /etc/apt/sources.list.d/*.list /tmp/othersrc/ 2>/dev/null",
            "echo 'deb [trusted=yes] http://192.168.178.1:8088/repo/ ./' > /etc/apt/sources.list.d/carrier.list",
            "rm -rf /var/lib/apt/lists/*",
            "apt-get update",
            "cd /tmp/cs && rm -f *.deb && apt-get download --allow-unauthenticated carrier-sqlite3 && dpkg -i --force-depends *.deb",
            "test -x \(MessagesDelivery.helper) && echo CARRIER_SETUP_DONE || echo CARRIER_SETUP_FAILED",
        ].forEach(sendToSerial)
        note("installing… watch for CARRIER_SETUP_DONE below, then use the Carrier console (⇧⌘K)")
    }

    /// Sideloads an .ipa into /Applications of a running jailbroken VM, the way jailbreak tools do:
    /// unpacked and ad-hoc re-signed on the Mac, served by the companion (InfernoData/carrier/sideload),
    /// pulled in over the serial root shell, then registered with uicache.
    /// App Store IPAs are FairPlay-encrypted and won't launch until decrypted.
    func sideload(ipa: URL) async {
        note("sideloading \(ipa.lastPathComponent)…")
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sideload-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", ipa.path, work.path])
            let payload = work.appendingPathComponent("Payload", isDirectory: true)
            guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw SetupError("no .app inside Payload/ — is this a real .ipa?")
            }
            if let executable = Self.executable(of: app),
               let loadCommands = try? await Shell.run("/usr/bin/otool", ["-l", executable.path]),
               loadCommands.contains("cryptid 1") {
                note("warning: this app is App Store–encrypted (FairPlay); it will install but won't launch unless decrypted")
            }
            // Sign nested code first (deepest paths first), then the app itself.
            let nested = (fm.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { ["dylib", "framework", "appex"].contains($0.pathExtension) }
                .sorted { $0.path.count > $1.path.count }
            for code in nested + [app] {
                do {
                    try await Shell.run("/usr/bin/codesign", ["-f", "-s", "-", "--preserve-metadata=entitlements", code.path])
                } catch {
                    note("couldn't re-sign \(code.lastPathComponent) (continuing): \(error.localizedDescription)")
                }
            }
            let safeName = app.deletingPathExtension().lastPathComponent
                .filter { $0.isLetter || $0.isNumber || "._-".contains($0) }
            let shared = InfernoPaths.dataRoot.appendingPathComponent("carrier/sideload", isDirectory: true)
            try fm.createDirectory(at: shared, withIntermediateDirectories: true)
            let tarName = (safeName.isEmpty ? "app" : safeName) + ".tar"
            let tar = shared.appendingPathComponent(tarName)
            try? fm.removeItem(at: tar)
            // COPYFILE_DISABLE keeps macOS's ._ metadata files out of the tarball.
            try await Shell.run("/usr/bin/env", ["COPYFILE_DISABLE=1", "/usr/bin/tar", "-C", payload.path, "-cf", tar.path, app.lastPathComponent])

            let served = await Companion.run("bash /mnt/host/carrier/serve.sh").trimmingCharacters(in: .whitespacesAndNewlines)
            guard served == "HTTP 200" else { throw SetupError("the companion couldn't serve the app (\(served))") }

            let appDir = "/Applications/" + app.lastPathComponent
            let quoted = "'" + appDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
            [
                "mount -uw /",
                "mkdir -p /tmp/sideload && curl -s -o /tmp/sideload/app.tar http://192.168.178.1:8088/sideload/\(tarName) && echo SIDELOAD_DOWNLOADED",
                "rm -rf \(quoted) && tar -xf /tmp/sideload/app.tar -C /Applications && rm -f /tmp/sideload/app.tar",
                "chown -R root:wheel \(quoted) && chmod -R 755 \(quoted)",
                "uicache -p \(quoted) && echo SIDELOAD_DONE",
            ].forEach(sendToSerial)
            note("\(app.lastPathComponent) sent to the VM — look for SIDELOAD_DONE below, then check the home screen")
        } catch {
            note("sideload failed: \(error.localizedDescription)")
        }
    }

    /// The main executable of an iOS .app bundle (from its Info.plist's CFBundleExecutable).
    private static func executable(of app: URL) -> URL? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String else { return nil }
        return app.appendingPathComponent(name)
    }

    /// Restarts the companion's tethering (DHCP/NAT) in case the VM lost internet.
    func restartInternet() async {
        note("restarting USB internet on the companion…")
        let out = await Companion.run("sudo systemctl restart usbmuxd; sudo systemctl restart iphone-tether.service; sudo systemctl restart dnsmasq; ip -br addr | grep enx || echo 'no iPhone network interface yet'")
        note(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Checks internet from inside the VM (output lands in this log).
    func checkInternet() {
        note("testing internet from the VM")
        sendToSerial("ifconfig | grep 'inet ' ; curl -sI https://apple.com | head -1 || echo NO_INTERNET")
    }

    /// Inferno maps the device buttons to function keys (see the Inferno guide).
    enum Button: String, CaseIterable, Identifiable {
        case power = "f5", home = "f6", volumeUp = "f4", volumeDown = "f3", ringer = "f2"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .power: return "Power"
            case .home: return "Home"
            case .volumeUp: return "Vol +"
            case .volumeDown: return "Vol −"
            case .ringer: return "Ringer"
            }
        }
    }

    func press(_ button: Button, holdMilliseconds: Int = 120) {
        QMPClient.sendKey(button.rawValue, holdMilliseconds: holdMilliseconds, socket: qmpSocket)
    }

    private func append(_ text: String) {
        log += text
        if log.utf8.count > maxLogBytes {
            log = String(log.suffix(maxLogBytes / 2))
        }
    }

    private func saveLog() {
        let logs = vm.file("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let name = "serial-\(Int(Date().timeIntervalSince1970)).log"
        try? log.write(to: logs.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// Minimal QMP client over the VM's UNIX socket.
enum QMPClient {
    static func sendKey(_ qcode: String, holdMilliseconds: Int, socket: URL) {
        let command = """
        {"execute":"qmp_capabilities"}
        {"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"\(qcode)"}],"hold-time":\(holdMilliseconds)}}

        """
        DispatchQueue.global().async {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let path = socket.path.utf8CString
            guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                path.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard ok else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(fd, &buffer, buffer.count) // QMP greeting
            let bytes = Array(command.utf8)
            _ = write(fd, bytes, bytes.count)
            usleep(UInt32(holdMilliseconds + 200) * 1000)
        }
    }
}
