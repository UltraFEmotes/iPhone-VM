import Foundation

/// Save states for a stopped VM: copies of its disks and SEP/NVRAM storage in `<vm>/snapshots/<id>/`.
/// On APFS, FileManager.copyItem clones files, so a snapshot is instant and only costs space as the
/// VM later diverges from it. Restoring clones the files back, so the VM boots as it was.
struct Snapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date = Date()
}

enum Snapshots {
    /// Everything iOS writes to: the NVMe namespaces plus SEP storage and NVRAM.
    static let stateFiles = ["root", "root.qcow2", "firmware", "syscfg", "ctrl_bits", "nvram",
                             "effaceable", "panic_log", "sep_nvram", "sep_ssc"]

    static func folder(for vm: VirtualMachine) -> URL { vm.file("snapshots") }

    static func list(for vm: VirtualMachine) -> [Snapshot] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: folder(for: vm), includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")) else { return nil }
            return try? JSONDecoder.iso.decode(Snapshot.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    static func take(_ name: String, of vm: VirtualMachine) throws -> Snapshot {
        let fm = FileManager.default
        let snap = Snapshot(name: name.isEmpty ? "Snapshot" : name)
        let dir = folder(for: vm).appendingPathComponent(snap.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for name in stateFiles where fm.fileExists(atPath: vm.file(name).path) {
                try fm.copyItem(at: vm.file(name), to: dir.appendingPathComponent(name))
            }
            try JSONEncoder.iso.encode(snap).write(to: dir.appendingPathComponent("snapshot.json"))
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return snap
    }

    /// Replaces the VM's state files with the snapshot's. Each file is cloned to a temporary name
    /// first, so a failure part-way leaves the current files untouched.
    static func restore(_ snap: Snapshot, of vm: VirtualMachine) throws {
        let fm = FileManager.default
        let dir = folder(for: vm).appendingPathComponent(snap.id.uuidString, isDirectory: true)
        let saved = stateFiles.filter { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard saved.contains(where: { $0 == "root" || $0 == "root.qcow2" }) else {
            throw SetupError("This snapshot has no root disk")
        }
        for name in saved {
            let staged = vm.file(name + ".restoring")
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: dir.appendingPathComponent(name), to: staged)
        }
        for name in saved {
            _ = try fm.replaceItemAt(vm.file(name), withItemAt: vm.file(name + ".restoring"))
        }
    }

    static func delete(_ snap: Snapshot, of vm: VirtualMachine) throws {
        try FileManager.default.removeItem(at: folder(for: vm).appendingPathComponent(snap.id.uuidString, isDirectory: true))
    }
}
