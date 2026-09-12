import SwiftUI

/// Step list + live log for setting up a VM (download → restore → patch).
struct SetupPane: View {
    let vm: VirtualMachine
    let entry: SupportEntry
    @ObservedObject var pipeline: SetupPipeline

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SetupPipeline.Step.allCases) { step in
                    HStack(spacing: 8) {
                        icon(for: pipeline.states[step] ?? .pending).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            if case .failed(let why) = pipeline.states[step] {
                                Text(why).font(.caption).foregroundStyle(.red).lineLimit(3)
                            }
                            if pipeline.states[step] == .running, let p = pipeline.progress {
                                ProgressView(value: p).frame(width: 180)
                            }
                        }
                    }
                }
                Spacer()
                Button(pipeline.isRunning ? "Setting up…" : (vm.state == .failed ? "Retry Setup" : "Set Up")) {
                    pipeline.start()
                }
                .disabled(pipeline.isRunning)
                .keyboardShortcut(.defaultAction)
                Text("Keeps the Mac awake. You can leave this window; you'll get a notification when it's done.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(pipeline.log.isEmpty ? "Setup log appears here." : pipeline.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: pipeline.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private func icon(for state: SetupPipeline.StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
