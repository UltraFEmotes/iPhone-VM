import SwiftUI

/// First run on a Mac without Inferno: runs the bundled install_mac.sh (Homebrew packages, the Inferno build per
/// its guide, the companion VM and tools) and shows its progress. Re-running resumes where it stopped.
struct EnvironmentSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var log = ""
    @State private var step = ""
    @State private var running = false
    @State private var finished = InfernoPaths.isInstalled
    @State private var failure: String?
    @State private var allEngines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Inferno").font(.title2.bold())
            Text("iPhone VM runs the ChefKiss Inferno emulator plus a small companion Linux VM. This one-time setup installs Homebrew packages, builds Inferno from source (about 20–40 minutes) and creates the companion VM. It needs Homebrew, Apple's command line tools and about 20 GB free. Everything goes in \(InfernoPaths.dataRoot.path).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Also build the emulators for iOS 15–18 (experimental versions, about +1 hour)", isOn: $allEngines)
                .disabled(running)
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text(step.isEmpty ? "Starting…" : "Working: \(step)")
                } else if finished {
                    Label("Inferno is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let failure {
                    Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
                Button(finished ? "Done" : "Later") { dismiss() }.disabled(running)
                Button(failure == nil ? "Start Setup" : "Retry") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || finished)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "Setup log appears here." : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }

    private func run() async {
        guard let script = Bundle.main.url(forResource: "install_mac", withExtension: "sh") else {
            failure = "install_mac.sh is missing from the app"
            return
        }
        running = true
        failure = nil
        defer { running = false }
        var args = ["INFERNO_DATA=\(InfernoPaths.dataRoot.path)", "/bin/bash", script.path]
        if allEngines { args.append("--all-engines") }
        do {
            let output = try await Shell.run("/usr/bin/env", args) { line in
                Task { @MainActor in handle(line) }
            }
            if output.contains("DONE") && InfernoPaths.isInstalled {
                finished = true
            } else {
                failure = "Setup stopped before finishing — see the log"
            }
        } catch let error as Shell.Failure {
            failure = error.tail.split(separator: "\n").last { $0.hasPrefix("FAIL:") }.map { String($0.dropFirst(5)) }
                ?? "Setup stopped — see the log"
        } catch {
            failure = error.localizedDescription
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("STEP:") { step = String(line.dropFirst(5)) }
        if line.hasPrefix("FAIL:") { failure = String(line.dropFirst(5)) }
        log += line + "\n"
        if log.utf8.count > 300_000 { log = String(log.suffix(150_000)) }
    }
}
