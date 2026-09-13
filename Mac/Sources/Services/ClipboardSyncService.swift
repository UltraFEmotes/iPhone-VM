import AppKit
import Foundation

@MainActor
final class ClipboardSyncService: ObservableObject {
    @Published private(set) var enabledVMs: Set<UUID> = []
    @Published private(set) var status = "Off"

    private var loopTask: Task<Void, Never>?
    private var lastPasteboardChange = NSPasteboard.general.changeCount
    private var lastLocalText = NSPasteboard.general.string(forType: .string) ?? ""
    private var lastRemoteSeq = 0

    func isEnabled(for vmID: UUID) -> Bool {
        enabledVMs.contains(vmID)
    }

    func setEnabled(_ enabled: Bool, for vm: VirtualMachine, runner: VMRunner) {
        if enabled {
            enabledVMs.insert(vm.id)
            status = "Starting..."
            Task {
                let served = await Companion.run("bash /mnt/host/carrier/serve.sh").trimmingCharacters(in: .whitespacesAndNewlines)
                guard served.contains("HTTP 200") else {
                    await MainActor.run {
                        self.enabledVMs.remove(vm.id)
                        self.status = "Broker unavailable"
                    }
                    runner.note("clipboard sync needs the carrier broker (\(served)); send the Trust prompt and run Set Up Carrier first")
                    return
                }
                runner.startClipboardAgent()
                let baseline = await self.fetchClip()
                await MainActor.run {
                    if let baseline {
                        self.lastRemoteSeq = baseline.seq
                    }
                    self.status = "Syncing"
                    self.ensureLoop()
                }
            }
        } else {
            enabledVMs.remove(vm.id)
            if enabledVMs.isEmpty {
                loopTask?.cancel()
                loopTask = nil
                status = "Off"
            }
        }
    }

    private func ensureLoop() {
        guard loopTask == nil else { return }
        lastPasteboardChange = NSPasteboard.general.changeCount
        lastLocalText = NSPasteboard.general.string(forType: .string) ?? ""
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func tick() async {
        guard !enabledVMs.isEmpty else { return }
        await publishMacClipboardIfNeeded()
        await applyVMClipboardIfNeeded()
    }

    private func publishMacClipboardIfNeeded() async {
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        guard change != lastPasteboardChange else { return }
        lastPasteboardChange = change
        let text = pasteboard.string(forType: .string) ?? ""
        guard text != lastLocalText else { return }
        lastLocalText = text
        guard !text.isEmpty else { return }
        if let clip = await postClip(text: text, source: "mac") {
            lastRemoteSeq = max(lastRemoteSeq, clip.seq)
            status = "Mac -> VM"
        }
    }

    private func applyVMClipboardIfNeeded() async {
        guard let clip = await fetchClip(),
              clip.seq > lastRemoteSeq else { return }
        lastRemoteSeq = clip.seq
        guard clip.source == "vm", clip.text != lastLocalText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clip.text, forType: .string)
        lastPasteboardChange = pasteboard.changeCount
        lastLocalText = clip.text
        status = "VM -> Mac"
    }

    private func fetchClip() async -> Clip? {
        await request("curl -s -m 3 http://127.0.0.1:8088/clip")
    }

    private func postClip(text: String, source: String) async -> Clip? {
        guard let data = try? JSONEncoder().encode(ClipPost(text: text, source: source)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return await request("curl -s -m 3 -H 'Content-Type: application/json' -XPOST http://127.0.0.1:8088/clip --data-binary \(Shell.quote(json))")
    }

    private func request(_ command: String) async -> Clip? {
        let out = await Companion.run(command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = out.data(using: .utf8),
              let clip = try? JSONDecoder().decode(Clip.self, from: data) else { return nil }
        return clip
    }

    private struct Clip: Decodable {
        let text: String
        let seq: Int
        let source: String
    }

    private struct ClipPost: Encodable {
        let text: String
        let source: String
    }
}
