import SwiftUI

struct VMDetailView: View {
    enum Tab: String, CaseIterable { case vm = "VM", terminal = "Terminal", files = "Files" }

    let vm: VirtualMachine
    let entry: SupportEntry
    @ObservedObject var runner: VMRunner
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var registry: RunnerRegistry
    @State private var tab: Tab = .vm
    @State private var showingPhoneInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
                if runner.isRunning {
                    Button("Stop", role: .destructive) { runner.stop() }
                } else {
                    Button("Start") { runner.start() }
                        .disabled(vm.state != .ready)
                        .help(vm.state == .ready ? "Boot this VM" : "Finish setup first")
                }
            }
            .padding(12)
            Divider()

            switch tab {
            case .vm: vmPane
            case .terminal: TerminalView(runner: runner)
            case .files: FileExplorerView(vm: vm, isRunning: runner.isRunning)
            }
        }
        .navigationTitle(vm.name)
        .navigationSubtitle("\(entry.deviceName) · iOS \(entry.ios)")
        .toolbar {
            // Serial/model/region properties exist only on the iPhone 11 (t8030) machine.
            if entry.machine == "t8030" {
                Button { showingPhoneInfo = true } label: { Label("Phone Info", systemImage: "person.text.rectangle") }
                    .help("Serial number, model, region… (applies on next start)")
            }
        }
        .sheet(isPresented: $showingPhoneInfo, onDismiss: { reloadRunnerIfStopped() }) {
            PhoneInfoView(vm: vm)
        }
    }

    @ViewBuilder
    private var vmPane: some View {
        if vm.state == .ready || runner.isRunning {
            devicePane
        } else {
            SetupPane(vm: vm, entry: entry, pipeline: registry.pipeline(for: vm, entry: entry, store: store))
        }
    }

    private var devicePane: some View {
        VStack(spacing: 18) {
            Image(systemName: runner.isRunning ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.system(size: 64))
                .foregroundStyle(runner.isRunning ? .green : .secondary)
            Text(statusText).font(.headline)
            HStack {
                ForEach(VMRunner.Button.allCases) { button in
                    Button(button.title) { runner.press(button) }
                }
            }
            .disabled(!runner.isRunning)
            HStack {
                Button("Send Trust Prompt") {
                    tab = .terminal
                    Task { await runner.sendTrustPrompt() }
                }
                .help("Ask iOS to trust the companion (needed once for USB internet)")
                if vm.jailbroken {
                    Button("Install Zebra") {
                        tab = .terminal
                        runner.installZebra()
                    }
                    .help("Install the Zebra package manager via apt (needs internet)")
                }
            }
            .disabled(!runner.isRunning)
            Text("The phone screen opens in its own window while the VM runs.")
                .font(.caption).foregroundStyle(.secondary)
            if registry.runningCount > 1 {
                Text("\(registry.runningCount) VMs running").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        if runner.isRunning { return "Running" }
        if let code = runner.lastExit { return "Stopped (exit \(code))" }
        return vm.state == .ready ? "Ready" : "Not set up yet"
    }

    /// Phone Info edits take effect on the next start: rebuild the stopped runner with the saved VM.
    private func reloadRunnerIfStopped() {
        guard let saved = store.machines.first(where: { $0.id == vm.id }) else { return }
        registry.refresh(saved, entry: entry)
    }
}
