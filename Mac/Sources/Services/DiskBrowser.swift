import Foundation

/// Read-only access to a stopped VM's iOS system volume, by attaching its raw root disk on the Mac.
@MainActor
final class DiskBrowser: ObservableObject {
    struct Item: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var mountPoint: URL?
    @Published private(set) var items: [Item] = []
    @Published private(set) var path: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false

    private var attachedDevice: String?
    let vm: VirtualMachine

    init(vm: VirtualMachine) { self.vm = vm }

    var rawRoot: URL { vm.file("root") }
    var canBrowse: Bool { FileManager.default.fileExists(atPath: rawRoot.path) }
    var currentURL: URL? { mountPoint.map { path.reduce($0) { $0.appendingPathComponent($1, isDirectory: true) } } }

    func attach() async {
        guard mountPoint == nil else { return }
        busy = true; error = nil
        defer { busy = false }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("InfernoMac-\(vm.id.uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        do {
            // -mountrandom keeps each VM's volumes separate; the System volume is the one with /System.
            let out = try await Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-noverify", "-noautofsck", "-nobrowse",
                                                              "-imagekey", "diskimage-class=CRawDiskImage",
                                                              "-mountrandom", mount.path, rawRoot.path])
            attachedDevice = out.split(separator: "\n").first.flatMap { $0.split(separator: "\t").first }.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            let volumes = out.split(separator: "\n").compactMap { line -> URL? in
                guard let last = line.split(separator: "\t").last, last.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: String(last).trimmingCharacters(in: .whitespaces), isDirectory: true)
            }
            guard let system = volumes.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("System").path) })
                    ?? volumes.first else {
                throw SetupError("No mountable iOS volume found on this disk")
            }
            mountPoint = system
            path = []
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func detach() async {
        guard let device = attachedDevice else { mountPoint = nil; return }
        _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", device, "-force"])
        attachedDevice = nil
        mountPoint = nil
        items = []
        path = []
    }

    func open(_ item: Item) {
        guard item.isDirectory else { return }
        path.append(item.name)
        reload()
    }

    func up() {
        guard !path.isEmpty else { return }
        path.removeLast()
        reload()
    }

    func copyOut(_ item: Item) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = downloads.appendingPathComponent(item.name)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: item.url, to: dest)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload() {
        guard let dir = currentURL else { items = []; return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        items = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Item(url: url, isDirectory: values?.isDirectory ?? false, size: Int64(values?.fileSize ?? 0))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}
