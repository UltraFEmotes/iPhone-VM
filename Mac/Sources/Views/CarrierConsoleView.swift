import SwiftUI

/// The carrier console: phone numbers per VM, device status, admin messages, texts/calls, traffic log.
struct CarrierConsoleView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var registry: RunnerRegistry
    @EnvironmentObject private var carrier: CarrierStore

    @State private var numberEdits: [UUID: String] = [:]
    @State private var adminText = ""
    @State private var adminTarget: String = "ALL"
    @State private var textFrom = ""
    @State private var textTo = ""
    @State private var textBody = ""
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                devicesSection
                Divider()
                adminSection
                Divider()
                textSection
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
            }
            .padding(14)
            .frame(minWidth: 360, idealWidth: 400)

            logSection.frame(minWidth: 360)
        }
        .frame(minWidth: 780, minHeight: 480)
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices").font(.headline)
            if store.machines.isEmpty {
                Text("No VMs yet.").foregroundStyle(.secondary)
            }
            ForEach(store.machines) { vm in
                HStack {
                    Circle().fill(registry.isRunning(vm.id) ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                    Text(vm.name).lineLimit(1)
                    Spacer()
                    TextField("Number", text: binding(for: vm))
                        .textFieldStyle(.roundedBorder).frame(width: 130)
                        .onSubmit { assign(vm) }
                    Button("Set") { assign(vm) }
                }
            }
        }
    }

    private var adminSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Admin message").font(.headline)
            Picker("To", selection: $adminTarget) {
                Text("All devices").tag("ALL")
                ForEach(carrier.lines) { line in Text("\(name(for: line.vmID)) (\(line.number))").tag(line.number) }
            }
            HStack {
                TextField("Message", text: $adminText).textFieldStyle(.roundedBorder)
                Button("Send") {
                    let body = adminText, target = adminTarget == "ALL" ? nil : adminTarget
                    Task { await carrier.sendAdmin(body, to: target) }
                    adminText = ""
                }
                .disabled(adminText.isEmpty || carrier.lines.isEmpty)
            }
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text or call").font(.headline)
            HStack {
                TextField("From", text: $textFrom).textFieldStyle(.roundedBorder)
                TextField("To", text: $textTo).textFieldStyle(.roundedBorder)
            }
            TextField("Message", text: $textBody).textFieldStyle(.roundedBorder)
            HStack {
                Button("Send Text") {
                    let (f, t, b) = (textFrom, textTo, textBody)
                    Task { await carrier.sendText(from: f, to: t, body: b) }
                    textBody = ""
                }
                .disabled(textTo.isEmpty || textBody.isEmpty)
                Button("Call") {
                    let (f, t) = (textFrom, textTo)
                    Task { await carrier.placeCall(from: f, to: t) }
                }
                .disabled(textTo.isEmpty)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Traffic").font(.headline).padding(10)
            Table(carrier.messages.reversed()) {
                TableColumn("Time") { m in Text(m.date, style: .time).foregroundStyle(.secondary) }.width(70)
                TableColumn("Type") { m in Text(m.kind.rawValue) }.width(50)
                TableColumn("From → To") { m in Text("\(m.from) → \(m.to)").lineLimit(1) }
                TableColumn("Message") { m in Text(m.body).lineLimit(2) }
                TableColumn("Status") { m in
                    Text(m.delivered ? "Delivered" : (m.note ?? "Not delivered"))
                        .foregroundStyle(m.delivered ? .green : .secondary).lineLimit(2)
                }
            }
        }
    }

    private func binding(for vm: VirtualMachine) -> Binding<String> {
        Binding(get: { numberEdits[vm.id] ?? carrier.number(for: vm.id) ?? "" },
                set: { numberEdits[vm.id] = $0 })
    }

    private func assign(_ vm: VirtualMachine) {
        let value = numberEdits[vm.id] ?? carrier.number(for: vm.id) ?? carrier.suggestNumber()
        do {
            try carrier.assign(value, to: vm.id)
            numberEdits[vm.id] = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func name(for vmID: UUID) -> String { store.machines.first { $0.id == vmID }?.name ?? "Unknown VM" }
}
