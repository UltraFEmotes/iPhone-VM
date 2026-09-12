import SwiftUI

/// Device → iOS version → jailbreak → create. Only tested manifest entries are offered.
struct NewVMWizard: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss
    var onCreate: (VirtualMachine) -> Void

    @State private var deviceName: String?
    @State private var entryID: String?
    @State private var jailbroken = false
    @State private var name = ""
    @State private var error: String?

    private var devices: [String] {
        Array(Set(store.manifest.testedEntries.map(\.deviceName))).sorted()
    }

    private var versions: [SupportEntry] {
        store.manifest.testedEntries.filter { $0.deviceName == deviceName }
    }

    private var selectedEntry: SupportEntry? {
        store.manifest.entries.first { $0.id == entryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New iPhone VM").font(.title2.bold())

            Form {
                Picker("Device", selection: $deviceName) {
                    Text("Choose…").tag(String?.none)
                    ForEach(devices, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("iOS version", selection: $entryID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(versions) { Text("iOS \($0.ios) (\($0.build))").tag(String?.some($0.id)) }
                }
                .disabled(deviceName == nil)

                Toggle("Jailbroken", isOn: $jailbroken)
                if jailbroken, let entry = selectedEntry {
                    Text(jailbreakNote(entry)).font(.caption).foregroundStyle(.secondary)
                }

                TextField("Name", text: $name, prompt: Text(defaultName))
            }
            .onChange(of: deviceName) { _, _ in entryID = versions.first?.id }

            if let entry = selectedEntry {
                Text("Downloads \(ByteCountFormatter.string(fromByteCount: entry.ipswSize, countStyle: .file)) of firmware from Apple and needs about 15 GB free.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedEntry == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var defaultName: String {
        guard let e = selectedEntry else { return "iPhone VM" }
        return "\(e.deviceName) (iOS \(e.ios))" + (jailbroken ? " JB" : "")
    }

    private func jailbreakNote(_ entry: SupportEntry) -> String {
        var parts = ["Installs a bash/apt bootstrap"]
        if let pm = entry.jailbreak.packageManager { parts.append("\(pm) package manager") }
        parts.append("tweaks: \(entry.jailbreak.tweaks)")
        return parts.joined(separator: " · ")
    }

    private func create() {
        guard let entry = selectedEntry else { return }
        do {
            let vm = try store.create(name: name.isEmpty ? defaultName : name, entry: entry, jailbroken: jailbroken)
            onCreate(vm)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
