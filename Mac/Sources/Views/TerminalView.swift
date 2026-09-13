import SwiftUI

/// Live serial log of the VM, with an input line wired to the guest serial console.
struct TerminalView: View {
    @ObservedObject var runner: VMRunner
    @State private var input = ""
    @State private var autoScroll = true
    @State private var filter = ""
    @State private var showLog = false

    private var shownLog: String {
        guard !filter.isEmpty else { return runner.log }
        return runner.log.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showLog) {
                    Text("Console").tag(false)
                    Text("Log").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .help("Console: type straight into the VM's shell. Log: searchable history.")
                if !showLog {
                    Text(runner.isRunning ? "Click in the console and type — arrows, Tab and Ctrl-C work" : "Start the VM to use the console")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(8)
            if showLog { logView } else {
                SerialConsoleView(runner: runner)
                    .background(Color.black)
            }
        }
    }

    private var logView: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Toggle("Auto-scroll", isOn: $autoScroll)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.log, forType: .string)
                }
            }
            .padding(8)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(shownLog.isEmpty ? "No output yet." : shownLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: runner.log) { _, _ in
                    if autoScroll { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            HStack {
                TextField("Send to serial console", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(send)
                Button("Send", action: send).disabled(!runner.isRunning || input.isEmpty)
            }
            .padding(8)
        }
    }

    private func send() {
        guard runner.isRunning, !input.isEmpty else { return }
        runner.sendToSerial(input)
        input = ""
    }
}
