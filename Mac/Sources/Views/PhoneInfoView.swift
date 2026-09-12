import SwiftUI

/// Edits the emulated phone's identity (serial number, model, region…). Applies on the next VM start.
struct PhoneInfoView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss
    let vm: VirtualMachine
    @State private var identity: VirtualMachine.PhoneIdentity
    @State private var error: String?

    init(vm: VirtualMachine) {
        self.vm = vm
        _identity = State(initialValue: vm.identity ?? .init())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Phone Info").font(.title2.bold())
            Text("Leave a field empty to use Inferno's default. Changes apply the next time the VM starts.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("Serial number", text: $identity.serialNumber, prompt: Text("INFERNO_1122"))
                TextField("Logic board (MLB) serial", text: $identity.mlbSerial, prompt: Text("INFERNO_MLB1122"))
                TextField("Model number", text: $identity.modelNumber, prompt: Text("CKI12"))
                TextField("Region", text: $identity.regionInfo, prompt: Text("LL/A"))
                TextField("Regulatory model", text: $identity.regulatoryModel, prompt: Text("INFERN8030"))
                TextField("Config number", text: $identity.configNumber, prompt: Text("(empty)"))
            }
            Text("ECID can't be changed: this VM's boot ticket and Secure Enclave data are tied to it.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Reset to defaults") { identity = .init() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        var updated = vm
        updated.identity = identity.machineProperties.isEmpty ? nil : identity
        do {
            try store.save(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
