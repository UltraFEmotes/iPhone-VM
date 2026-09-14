import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var registry: RunnerRegistry
    @EnvironmentObject private var carrier: CarrierStore
    @EnvironmentObject private var clipboard: ClipboardSyncService
    @EnvironmentObject private var carrierWindow: CarrierWindowPresenter
    @State private var selection: VirtualMachine.ID?
    @State private var showingWizard = false
    @State private var showingEnvironmentSetup = false

    var body: some View {
        NavigationView {
            sidebar
            detail
        }
        .navigationViewStyle(.columns)
        .sheet(isPresented: $showingWizard) {
            NewVMWizard { vm in selection = vm.id }
        }
        .sheet(isPresented: $showingEnvironmentSetup) {
            EnvironmentSetupView()
        }
        .task { if !InfernoPaths.isInstalled { showingEnvironmentSetup = true } }
    }

    private var sidebar: some View {
        List(store.machines, selection: $selection) { vm in
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name).font(.headline)
                Text(subtitle(for: vm)).font(.caption).foregroundStyle(.secondary)
            }
            .tag(vm.id)
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vm.folder]) }
                Button("Delete VM", role: .destructive) { try? store.delete(vm) }
            }
        }
        .overlay {
            if store.machines.isEmpty {
                EmptyStateView("No VMs yet", systemImage: "iphone", message: "Press + to set up an iPhone VM.")
            }
        }
        .toolbar {
            Button {
                if InfernoPaths.isInstalled { showingWizard = true } else { showingEnvironmentSetup = true }
            } label: { Label("New VM", systemImage: "plus") }
            Button {
                carrierWindow.show(store: store, registry: registry, carrier: carrier, clipboard: clipboard)
            } label: { Label("Carrier Console", systemImage: "bubble.left.and.bubble.right") }
                .help("Open the simulated carrier console")
            Button { showingEnvironmentSetup = true } label: { Label("Set Up Inferno", systemImage: "wrench.and.screwdriver") }
                .help("Build or repair the Inferno emulator and companion VM")
        }
        .frame(minWidth: 220, idealWidth: 250)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let vm = store.machines.first(where: { $0.id == id }),
           let entry = store.entry(for: vm) {
            VMDetailView(vm: vm, entry: entry, runner: registry.runner(for: vm, entry: entry)).id(vm.id)
        } else {
            EmptyStateView("Select a VM", systemImage: "cursorarrow.click")
        }
    }

    private func subtitle(for vm: VirtualMachine) -> String {
        let entry = store.entry(for: vm)
        let base = [entry?.deviceName, entry.map { "iOS \($0.ios)" }].compactMap { $0 }.joined(separator: " · ")
        return base + (vm.jailbroken ? " · Jailbroken" : "") + " · \(vm.state.rawValue.capitalized)"
    }
}
