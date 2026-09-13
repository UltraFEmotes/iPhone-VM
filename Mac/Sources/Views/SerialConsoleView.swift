import SwiftUI
import SwiftTerm

/// A real terminal on the VM's serial console: keystrokes go straight to the guest's shell, so line
/// editing, history, Tab completion, Ctrl-C and full-screen programs behave like Terminal.app.
struct SerialConsoleView: NSViewRepresentable {
    @ObservedObject var runner: VMRunner

    func makeCoordinator() -> Coordinator { Coordinator(runner: runner) }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        let runner: VMRunner
        private weak var view: SwiftTerm.TerminalView?
        private var listener: UUID?
        private var configured = false

        init(runner: VMRunner) { self.runner = runner }

        func attach(to view: SwiftTerm.TerminalView) {
            self.view = view
            let backlog = runner.rawBacklog
            if !backlog.isEmpty { view.feed(byteArray: ArraySlice(backlog)) }
            listener = runner.addRawListener { [weak self] data in
                self?.view?.feed(byteArray: ArraySlice(data))
            }
        }

        func detach() {
            if let listener { runner.removeRawListener(listener) }
            listener = nil
        }

        /// The iOS console starts without TERM or a window size; set both once so bash's line editor
        /// and programs like top/vi draw correctly.
        private func configureShellIfNeeded(cols: Int, rows: Int) {
            guard runner.isRunning else { return }
            if !configured {
                configured = true
                runner.sendRaw(Data("export TERM=xterm-256color\n".utf8))
            }
            runner.sendRaw(Data("stty rows \(rows) cols \(cols) 2>/dev/null\n".utf8))
        }

        // MARK: SwiftTerm.TerminalViewDelegate

        nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor in
                self.runner.noteInteractiveInput()   // pause the carrier poller while the user types
                self.runner.sendRaw(bytes)
            }
        }

        nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in self.configureShellIfNeeded(cols: newCols, rows: newRows) }
        }

        nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

        nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { Task { @MainActor in NSWorkspace.shared.open(url) } }
        }

        nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                Task { @MainActor in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
}
