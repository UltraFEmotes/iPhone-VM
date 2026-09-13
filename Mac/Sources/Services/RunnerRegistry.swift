import Foundation

/// One VMRunner per VM for the whole app session, so VMs keep running (and keep their Terminal log)
/// while you look at other VMs. This is what makes running several VMs at once work.
@MainActor
final class RunnerRegistry: ObservableObject {
    @Published private var runners: [UUID: VMRunner] = [:]
    /// One setup pipeline per VM for the whole session, so redrawing the Set Up screen never starts a second one.
    private var pipelines: [UUID: SetupPipeline] = [:]

    func pipeline(for vm: VirtualMachine, entry: SupportEntry, store: VMStore) -> SetupPipeline {
        if let existing = pipelines[vm.id] { return existing }
        let pipeline = SetupPipeline(vm: vm, entry: entry, store: store)
        pipelines[vm.id] = pipeline
        return pipeline
    }

    func runner(for vm: VirtualMachine, entry: SupportEntry) -> VMRunner {
        if let existing = runners[vm.id] {
            return existing
        }
        let runner = VMRunner(vm: vm, entry: entry)
        runners[vm.id] = runner
        return runner
    }

    /// Recreate a stopped VM's runner so it picks up changed settings (e.g. Phone Info).
    func refresh(_ vm: VirtualMachine, entry: SupportEntry) {
        if let existing = runners[vm.id], existing.isRunning { return }
        runners[vm.id] = VMRunner(vm: vm, entry: entry)
    }

    var runningCount: Int { runners.values.filter(\.isRunning).count }

    func isRunning(_ id: UUID) -> Bool { runners[id]?.isRunning ?? false }

    /// The running VM with this id, if any (used by the carrier to reach the VM's serial shell).
    func runningRunner(_ id: UUID) -> VMRunner? {
        guard let runner = runners[id], runner.isRunning else { return nil }
        return runner
    }

    func stopAll() {
        runners.values.forEach { $0.stop() }
    }
}
