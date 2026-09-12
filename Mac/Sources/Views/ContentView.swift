import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: VMStore
    @EnvironmentObject private var registry: RunnerRegistry
    @State private var selection: VirtualMachine.ID?
    @State private var showingWizard = false

    var body: some View {
        NavigationSplitView {
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
                    ContentUnavailableView("No VMs yet", systemImage: "iphone",
                                           description: Text("Press + to set up an iPhone VM."))
                }
            }
            .toolbar {
                Button { showingWizard = true } label: { Label("New VM", systemImage: "plus") }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let id = selection, let vm = store.machines.first(where: { $0.id == id }),
               let entry = store.entry(for: vm) {
                VMDetailView(vm: vm, entry: entry, runner: registry.runner(for: vm, entry: entry)).id(vm.id)
            } else {
                ContentUnavailableView("Select a VM", systemImage: "cursorarrow.click")
            }
        }
        .sheet(isPresented: $showingWizard) {
            NewVMWizard { vm in selection = vm.id }
        }
    }

    private func subtitle(for vm: VirtualMachine) -> String {
        let entry = store.entry(for: vm)
        let base = [entry?.deviceName, entry.map { "iOS \($0.ios)" }].compactMap { $0 }.joined(separator: " · ")
        return base + (vm.jailbroken ? " · Jailbroken" : "") + " · \(vm.state.rawValue.capitalized)"
    }
}
