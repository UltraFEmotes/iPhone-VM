import Foundation

/// One VMRunner per VM for the whole app session, so VMs keep running (and keep their Terminal log)
/// while you look at other VMs. This is what makes running several VMs at once work.
@MainActor
final class RunnerRegistry: ObservableObject {
    @Published private var runners: [UUID: VMRunner] = [:]

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

    func stopAll() {
        runners.values.forEach { $0.stop() }
    }
}
