import SwiftUI

struct VMDetailView: View {
    enum Tab: String, CaseIterable { case vm = "VM", terminal = "Terminal" }

    let vm: VirtualMachine
    let entry: SupportEntry
    @StateObject private var runner: VMRunner
    @State private var tab: Tab = .vm

    init(vm: VirtualMachine, entry: SupportEntry) {
        self.vm = vm
        self.entry = entry
        _runner = StateObject(wrappedValue: VMRunner(vm: vm, entry: entry))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
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
            }
        }
        .navigationTitle(vm.name)
        .navigationSubtitle("\(entry.deviceName) · iOS \(entry.ios)")
    }

    @EnvironmentObject private var store: VMStore

    @ViewBuilder
    private var vmPane: some View {
        if vm.state == .ready || runner.isRunning {
            devicePane
        } else {
            SetupPane(vm: vm, entry: entry, store: store)
        }
    }

    private var devicePane: some View {
        VStack(spacing: 18) {
            Image(systemName: runner.isRunning ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.system(size: 64))
                .foregroundStyle(runner.isRunning ? .green : .secondary)
            Text(statusText).font(.headline)
            if vm.state != .ready {
                Text("Setup (download, restore, patch) comes next in this app. This VM is \(vm.state.rawValue).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                ForEach(VMRunner.Button.allCases) { button in
                    Button(button.title) { runner.press(button) }
                }
            }
            .disabled(!runner.isRunning)
            Text("The phone screen opens in its own window while the VM runs.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        if runner.isRunning { return "Running" }
        if let code = runner.lastExit { return "Stopped (exit \(code))" }
        return vm.state == .ready ? "Ready" : "Not set up yet"
    }
}
