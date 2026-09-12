import Foundation

/// A VM on disk: `<VMs>/<id>/vm.json` plus its disks, boot files and logs in the same folder.
struct VirtualMachine: Codable, Identifiable, Hashable {
    enum SetupState: String, Codable {
        case new, downloading, preparing, restoring, patching, ready, failed
    }

    var id: UUID
    var name: String
    var entryID: String
    var jailbroken: Bool
    var state: SetupState
    var createdAt: Date

    var folder: URL { VMStore.vmsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
}

/// Paths to the existing Mac Inferno setup this app drives.
enum InfernoPaths {
    static let dataRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/iphone/InfernoData", isDirectory: true)
    static let qemu = dataRoot.appendingPathComponent("Inferno/build/qemu-system-aarch64")
    static let qemuImg = dataRoot.appendingPathComponent("Inferno/build/qemu-img")
    static let startCompanion = dataRoot.appendingPathComponent("start_companion.sh")
}

@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var machines: [VirtualMachine] = []
    let manifest = SupportManifest.loadBundled()

    static let vmsRoot: URL = {
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
