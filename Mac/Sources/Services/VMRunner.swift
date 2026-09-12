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
        var args = [
            "-M", "\(entry.machine),trustcache=\(f("trustcache")),ticket=\(f("root_ticket.der")),sep-fw=\(f("sep-firmware.img4")),sep-rom=\(f(entry.sepROM)),kaslr-off=true",
            "-kernel", f("kernelcache"),
            "-dtb", f("devicetree.im4p"),
            "-append", entry.bootArgs + (vm.jailbroken ? " launchd_unsecure_cache=1" : ""),
            "-smp", "\(entry.cpus)", "-m", entry.memory,
            "-serial", "stdio", "-monitor", "none",
            "-qmp", "unix:\(qmpSocket.path),server=on,wait=off",
            "-display", "cocoa,zoom-to-fit=on,zoom-interpolation=on,show-cursor=on",
            "-drive", "file=\(f("sep_nvram")),if=pflash,format=raw",
            "-drive", "file=\(f("sep_ssc")),if=pflash,format=raw",
        ]
        let namespaces: [(String, Int, Int, String)] = [
            ("root", 1, 1, "nvme-ns"), ("firmware", 2, 2, "nvme-ns"), ("syscfg", 3, 3, "nvme-ns"),
            ("ctrl_bits", 4, 4, "nvme-ns"), ("nvram", 5, 5, "apple-nvram"), ("effaceable", 6, 6, "nvme-ns"),
            ("panic_log", 7, 8, "nvme-ns"),
        ]
        for (name, nsid, nstype, device) in namespaces {
            args += ["-drive", "file=\(f(name)),format=raw,if=none,id=\(name)",
                     "-device", "\(device),drive=\(name),bus=nvme-bus.0,nsid=\(nsid),nstype=\(nstype)" +
                        (device == "apple-nvram" ? ",id=nvram" : "") +
                        ",logical_block_size=4096,physical_block_size=4096"]
        }
        if restoreMode {
            args += ["-initrd", f("ramdisk_erase.dmg")]
        }
        return args
    }

    func start(restoreMode: Bool = false) {
        guard !isRunning else { return }
        try? FileManager.default.removeItem(at: qmpSocket)
        let p = Process()
        p.executableURL = InfernoPaths.qemu
        p.arguments = arguments(restoreMode: restoreMode)
        p.currentDirectoryURL = vm.folder
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
            Task { @MainActor in self?.append(text) }
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
