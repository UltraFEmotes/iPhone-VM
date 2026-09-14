import Foundation

/// A VM on disk: `<VMs>/<id>/vm.json` plus its disks, boot files and logs in the same folder.
struct VirtualMachine: Codable, Identifiable, Hashable {
    enum SetupState: String, Codable {
        case new, downloading, preparing, restoring, patching, ready, failed
    }

    enum GraphicsMode: String, Codable, CaseIterable, Identifiable {
        case softwareFramebuffer
        case agxMetal
        case paravirtualMetal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .softwareFramebuffer: return "Default Framebuffer"
            case .agxMetal: return "Smooth Full-Res"
            case .paravirtualMetal: return "Fast Half-Res"
            }
        }

        var detail: String {
            switch self {
            case .softwareFramebuffer:
                return "The normal 828x1792 iPhone framebuffer with QEMU's Cocoa display path."
            case .agxMetal:
                return "Keeps the native framebuffer and enables Cocoa scaling interpolation for the best-looking host presentation available in this engine."
            case .paravirtualMetal:
                return "Runs a 414x896 framebuffer to cut display-copy work by about 75%. Faster, but visibly lower resolution."
            }
        }

        var isImplemented: Bool {
            true
        }

        var machineProperties: [String] {
            switch self {
            case .softwareFramebuffer:
                return []
            case .agxMetal:
                return ["disp-width=828", "disp-height=1792"]
            case .paravirtualMetal:
                return ["disp-width=414", "disp-height=896"]
            }
        }

        var displayArguments: [String] {
            switch self {
            case .softwareFramebuffer, .paravirtualMetal:
                return ["-display", "cocoa,zoom-to-fit=on,show-cursor=on"]
            case .agxMetal:
                return ["-display", "cocoa,zoom-to-fit=on,show-cursor=on,zoom-interpolation=on"]
            }
        }

        var launchNote: String? {
            switch self {
            case .softwareFramebuffer:
                return nil
            case .agxMetal:
                return "graphics mode: Smooth Full-Res; Cocoa interpolation enabled"
            case .paravirtualMetal:
                return "graphics mode: Fast Half-Res; using a 414x896 framebuffer"
            }
        }
    }

    enum PerformanceMode: String, Codable, CaseIterable, Identifiable {
        case balanced
        case fastTCG
        case lowMemory

        var id: String { rawValue }

        var title: String {
            switch self {
            case .balanced: return "Balanced"
            case .fastTCG: return "Fast TCG"
            case .lowMemory: return "Low Memory"
            }
        }

        var detail: String {
            switch self {
            case .balanced:
                return "Uses multi-threaded TCG with a moderate translation cache and conservative JIT memory mappings."
            case .fastTCG:
                return "Gives TCG a larger translation cache and disables split W/X JIT mappings for less overhead. Faster when RAM is available."
            case .lowMemory:
                return "Uses a smaller translation cache to reduce host memory pressure."
            }
        }

        var tcgTBSize: Int {
            switch self {
            case .balanced: return 256
            case .fastTCG: return 768
            case .lowMemory: return 128
            }
        }

        var accelArgument: String {
            var parts = ["tcg", "thread=multi", "tb-size=\(tcgTBSize)"]
            if self == .fastTCG {
                parts.append("split-wx=off")
            }
            return parts.joined(separator: ",")
        }
    }

    enum AudioMode: String, Codable, CaseIterable, Identifiable {
        case disabled
        case aopCoreAudio

        var id: String { rawValue }

        var title: String {
            switch self {
            case .disabled: return "CoreAudio (Stable)"
            case .aopCoreAudio: return "AOP Speaker CoreAudio"
            }
        }

        var detail: String {
            switch self {
            case .disabled:
                return "Stable default. Keeps the MCA/CoreAudio output backend wired, but does not expose the unfinished AOP audio service to iOS."
            case .aopCoreAudio:
                return "Experimental. Exposes Inferno's AOP audio service in a speaker-only profile and uses QEMU's CoreAudio backend."
            }
        }

        var enablesAOPAudio: Bool {
            self == .aopCoreAudio
        }
    }

    /// Device identity passed to Inferno's machine properties. Empty = Inferno's default.
    /// ECID is not editable here: the restore's boot ticket and SEP data are tied to it.
    struct PhoneIdentity: Codable, Hashable {
        var serialNumber = ""
        var mlbSerial = ""
        var modelNumber = ""
        var regionInfo = ""
        var regulatoryModel = ""
        var configNumber = ""

        /// `-M t8030,...` properties for the non-empty fields (commas would break QEMU's option parsing).
        var machineProperties: [String] {
            let pairs = [("serial-number", serialNumber), ("mlb", mlbSerial), ("model", modelNumber),
                         ("region-info", regionInfo), ("regulatory-model", regulatoryModel),
                         ("config-number", configNumber)]
            return pairs.compactMap { key, value in
                let clean = value.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                return clean.isEmpty ? nil : "\(key)=\(clean)"
            }
        }
    }

    var id: UUID
    var name: String
    var entryID: String
    var jailbroken: Bool
    var state: SetupState
    var createdAt: Date
    var identity: PhoneIdentity? = nil
    var graphicsMode: GraphicsMode? = nil
    var performanceMode: PerformanceMode? = nil
    var audioMode: AudioMode? = nil

    var effectiveGraphicsMode: GraphicsMode { graphicsMode ?? .softwareFramebuffer }
    var effectivePerformanceMode: PerformanceMode { performanceMode ?? .balanced }
    var effectiveAudioMode: AudioMode { audioMode ?? .disabled }

    var folder: URL { VMStore.vmsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
}

/// Paths to the Inferno setup this app drives: the original ~/Documents/iphone/InfernoData when it exists,
/// otherwise the app's own folder, which the first-run setup (install_mac.sh) fills.
enum InfernoPaths {
    static let dataRoot: URL = {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/iphone/InfernoData", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Inferno").path) { return legacy }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfernoMac/InfernoData", isDirectory: true)
    }()
    static let qemu = dataRoot.appendingPathComponent("Inferno/build/qemu-system-aarch64")

    /// True once install_mac.sh (or a manual setup) has produced the emulator and the companion VM.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: qemu.path) && FileManager.default.fileExists(atPath: startCompanion.path)
    }

    /// Engine build matching the entry's SEP version: iOS 14 uses the main build, 15–18 use build-sepN.
    static func qemu(forSEP version: Int?) -> URL {
        guard let version, version != 14 else { return qemu }
        return dataRoot.appendingPathComponent("Inferno/build-sep\(version)/qemu-system-aarch64")
    }
    static let qemuImg = dataRoot.appendingPathComponent("Inferno/build/qemu-img")
    static let startCompanion = dataRoot.appendingPathComponent("start_companion.sh")
}

@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var machines: [VirtualMachine] = []
    let manifest = SupportManifest.loadBundled()

    nonisolated static let vmsRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("InfernoMac/VMs", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(at: Self.vmsRoot, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.vmsRoot, includingPropertiesForKeys: nil)) ?? []
        machines = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("vm.json")) else { return nil }
            return try? JSONDecoder.iso.decode(VirtualMachine.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func entry(for vm: VirtualMachine) -> SupportEntry? {
        manifest.entries.first { $0.id == vm.entryID }
    }

    @discardableResult
    func create(name: String, entry: SupportEntry, jailbroken: Bool) throws -> VirtualMachine {
        let vm = VirtualMachine(id: UUID(), name: name, entryID: entry.id, jailbroken: jailbroken,
                                state: .new, createdAt: Date())
        try FileManager.default.createDirectory(at: vm.folder, withIntermediateDirectories: true)
        try save(vm)
        return vm
    }

    func save(_ vm: VirtualMachine) throws {
        try JSONEncoder.iso.encode(vm).write(to: vm.file("vm.json"), options: .atomic)
        reload()
    }

    func delete(_ vm: VirtualMachine) throws {
        try FileManager.default.removeItem(at: vm.folder)
        reload()
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
