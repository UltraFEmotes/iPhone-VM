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
    @State private var showExperimental = false

    /// Tested entries always; experimental ones only when the user opts in.
    private var offered: [SupportEntry] {
        store.manifest.entries.filter { $0.isTested || (showExperimental && $0.isExperimental) }
    }

    private var devices: [String] {
        Array(Set(offered.map(\.deviceName))).sorted()
    }

    private var versions: [SupportEntry] {
        offered.filter { $0.deviceName == deviceName }
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
                    ForEach(versions) { e in
                        Text("iOS \(e.ios) (\(e.build))" + (e.isExperimental ? " — Experimental" : "")).tag(String?.some(e.id))
                    }
                }
                .disabled(deviceName == nil)

                Toggle("Show experimental versions", isOn: $showExperimental)
                    .help("Versions that haven't booted yet on this setup. They may fail during restore or boot.")
                Toggle("Jailbroken", isOn: $jailbroken)
                    .disabled(!canJailbreak)
                if let entry = selectedEntry, !entry.jailbreak.bootstrap {
                    Text("Jailbreak isn't available for iOS \(entry.ios): the bootstrap only supports iOS 12–14.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if jailbroken, let entry = selectedEntry {
                    Text(jailbreakNote(entry)).font(.caption).foregroundStyle(.secondary)
                }

                TextField("Name", text: $name, prompt: Text(defaultName))
            }
            .onChange(of: deviceName) { _, _ in entryID = versions.first?.id }
            .onChange(of: entryID) { _, _ in if !canJailbreak { jailbroken = false } }

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

    /// Only versions whose manifest entry ships the (iOS 12–14) bootstrap can be jailbroken.
    private var canJailbreak: Bool { selectedEntry?.jailbreak.bootstrap == true }

    private func create() {
        guard let entry = selectedEntry else { return }
        do {
            let vm = try store.create(name: name.isEmpty ? defaultName : name, entry: entry,
                                      jailbroken: jailbroken && entry.jailbreak.bootstrap)
            onCreate(vm)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
