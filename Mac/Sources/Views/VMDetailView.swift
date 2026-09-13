import SwiftUI

struct VMDetailView: View {
    enum Tab: String, CaseIterable { case vm = "VM", terminal = "Terminal", files = "Files", jailbreak = "Jailbreak", misc = "Misc" }

    private var tabs: [Tab] { Tab.allCases.filter { $0 != .jailbreak || vm.jailbroken } }

    let vm: VirtualMachine
    let entry: SupportEntry
    @ObservedObject var runner: VMRunner
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var registry: RunnerRegistry
    @EnvironmentObject private var clipboard: ClipboardSyncService
    @State private var tab: Tab = .vm
    @State private var showingPhoneInfo = false
    @State private var showingSnapshots = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: CGFloat(tabs.count) * 90)
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
            case .jailbreak: jailbreakPane
            case .misc: miscPane
            }
        }
        .navigationTitle(vm.name)
        .navigationSubtitle("\(entry.deviceName) · iOS \(entry.ios)")
        .toolbar {
            Button { showingSnapshots = true } label: { Label("Save States", systemImage: "clock.arrow.circlepath") }
                .help("Take or restore snapshots (VM must be stopped)")
                .disabled(vm.state != .ready)
            // Serial/model/region properties exist only on the iPhone 11 (t8030) machine.
            if entry.machine == "t8030" {
                Button { showingPhoneInfo = true } label: { Label("Phone Info", systemImage: "person.text.rectangle") }
                    .help("Serial number, model, region… (applies on next start)")
            }
        }
        .sheet(isPresented: $showingPhoneInfo, onDismiss: { reloadRunnerIfStopped() }) {
            PhoneInfoView(vm: vm)
        }
        .sheet(isPresented: $showingSnapshots) {
            SnapshotsView(vm: vm, isRunning: runner.isRunning || runner.isStarting)
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
            Text("The phone screen opens in its own window while the VM runs.")
                .font(.caption).foregroundStyle(.secondary)
            if registry.runningCount > 1 {
                Text("\(registry.runningCount) VMs running").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Actions run on the VM's serial root shell; output shows in the Terminal tab.
    private var jailbreakPane: some View {
        Form {
            Section("System") {
                action("Make System Writable", help: "Remounts / read-write until the next reboot") { runner.makeSystemWritable() }
                action("Respring", help: "Restart SpringBoard (refreshes home screen icons)") { runner.sendToSerial("killall -9 SpringBoard") }
                action("Refresh App Icons", help: "Run uicache for all apps") { runner.sendToSerial("uicache -a") }
            }
            Section("Apps") {
                action("Sideload IPA…", help: "Install any .ipa into /Applications (App Store apps must be decrypted to launch)") {
                    chooseIPA()
                }
            }
            Section("Carrier (needs internet)") {
                action("Set Up Carrier", help: "Installs the helper that puts Carrier Console texts into Messages") {
                    Task { await runner.setupCarrier() }
                }
            }
            Section("Package Managers (needs internet)") {
                ForEach(VMRunner.PackageManager.allCases) { manager in
                    action("Install \(manager.rawValue)", help: "Downloads \(manager.rawValue) and installs it with dpkg") { runner.install(manager) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!runner.isRunning)
        .overlay { if !runner.isRunning { Text("Start the VM to use these.").foregroundStyle(.secondary) } }
    }

    private var miscPane: some View {
        Form {
            Section("Internet") {
                action("Send Trust Prompt", help: "Ask iOS to trust the companion (needed once for USB internet)", disabled: !runner.isRunning) {
                    Task { await runner.sendTrustPrompt() }
                }
                if vm.jailbroken {
                    action("Repair Carrier", help: "Restart the broker and reinstall the in-VM carrier helpers", disabled: !runner.isRunning) {
                        Task { await runner.setupCarrier() }
                    }
                }
                action("Restart Internet", help: "Restart usbmuxd, tethering and DHCP on the companion", disabled: !runner.isRunning) {
                    Task { await runner.restartInternet() }
                }
                if vm.jailbroken {
                    action("Test Internet", help: "Show the VM's IP and ping apple.com from inside the VM", disabled: !runner.isRunning) { runner.checkInternet() }
                }
            }
            Section("Device") {
                action("Hold Power (3s)", help: "Long-press power, e.g. for the power-off slider", disabled: !runner.isRunning) { runner.press(.power, holdMilliseconds: 3000) }
                if vm.jailbroken {
                    action("Reboot iOS", help: "Reboot from inside the VM", disabled: !runner.isRunning) { runner.sendToSerial("reboot") }
                }
            }
            Section("Experimental Graphics") {
                Picker("Mode", selection: graphicsModeBinding) {
                    ForEach(VirtualMachine.GraphicsMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(currentGraphicsMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !currentGraphicsMode.isImplemented {
                    Text("This saves the experiment choice but falls back to Software Framebuffer until the emulator engine supports it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Changes apply the next time this VM starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if vm.jailbroken {
                Section("Clipboard") {
                    Toggle("Clipboard Sync", isOn: Binding(
                        get: { clipboard.isEnabled(for: vm.id) },
                        set: { clipboard.setEnabled($0, for: vm, runner: runner) }
                    ))
                    .disabled(!runner.isRunning)
                    Text(clipboard.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var currentVM: VirtualMachine {
        store.machines.first(where: { $0.id == vm.id }) ?? vm
    }

    private var currentGraphicsMode: VirtualMachine.GraphicsMode {
        currentVM.effectiveGraphicsMode
    }

    private var graphicsModeBinding: Binding<VirtualMachine.GraphicsMode> {
        Binding(
            get: { currentGraphicsMode },
            set: { mode in
                var updated = currentVM
                updated.graphicsMode = mode == .softwareFramebuffer ? nil : mode
                try? store.save(updated)
                reloadRunnerIfStopped()
            }
        )
    }

    private func chooseIPA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ipa") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an .ipa to install on the VM"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runner.sideload(ipa: url) }
    }

    /// A row that runs an action and jumps to the Terminal so the output is visible.
    private func action(_ title: String, help: String, disabled: Bool = false, _ perform: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run") { perform(); tab = .terminal }
                .disabled(disabled)
        }
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
