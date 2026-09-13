import SwiftUI

/// Save states: take, restore and delete snapshots of a stopped VM.
struct SnapshotsView: View {
    let vm: VirtualMachine
    let isRunning: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [Snapshot] = []
    @State private var newName = ""
    @State private var message: String?
    @State private var busy = false
    @State private var confirmRestore: Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save States").font(.title2.bold())
            Text("A snapshot saves the VM's disks and chip storage. Restoring boots the VM exactly as it was — anything done since is gone.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isRunning {
                Label("Stop the VM first (type halt in the Terminal).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                TextField("Snapshot name, e.g. Before rm -rf", text: $newName).textFieldStyle(.roundedBorder)
                Button("Take Snapshot") { run { let s = try Snapshots.take(newName, of: vm); newName = ""; return "Saved “\(s.name)”" } }
            }
            List(snapshots) { snap in
                HStack {
                    VStack(alignment: .leading) {
                        Text(snap.name)
                        Text(snap.date, style: .date) + Text(" ") + Text(snap.date, style: .time)
                    }
                    Spacer()
                    Button("Restore") { confirmRestore = snap }
                    Button(role: .destructive) { run { try Snapshots.delete(snap, of: vm); return "Deleted “\(snap.name)”" } } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .frame(minHeight: 180)
            .overlay { if snapshots.isEmpty { Text("No snapshots yet").foregroundStyle(.secondary) } }
            if let message { Text(message).font(.caption) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .disabled(busy || isRunning)
        .onAppear { snapshots = Snapshots.list(for: vm) }
        .confirmationDialog("Restore “\(confirmRestore?.name ?? "")”?", isPresented: .init(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore", role: .destructive) {
                if let snap = confirmRestore { run { try Snapshots.restore(snap, of: vm); return "Restored “\(snap.name)” — press Start" } }
            }
        } message: {
            Text("Everything changed in the VM since this snapshot will be lost. Take a snapshot first if you want to keep it.")
        }
    }

    private func run(_ work: @escaping () throws -> String) {
        busy = true
        Task.detached {
            let result: String
            do { result = try work() } catch { result = "Failed: \(error.localizedDescription)" }
            await MainActor.run {
                message = result
                snapshots = Snapshots.list(for: vm)
                busy = false
            }
        }
    }
}
