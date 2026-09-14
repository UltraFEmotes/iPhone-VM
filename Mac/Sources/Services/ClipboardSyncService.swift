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
                guard await CarrierBrokerClient.ensureReady() else {
                    await MainActor.run {
                        self.enabledVMs.remove(vm.id)
                        self.status = "Broker unavailable"
                    }
                    runner.note("clipboard sync needs the carrier broker; send the Trust prompt and run Set Up Carrier first")
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
        await CarrierBrokerClient.get("/clip", as: Clip.self)
    }

    private func postClip(text: String, source: String) async -> Clip? {
        await CarrierBrokerClient.post("/clip", body: ClipPost(text: text, source: source), as: Clip.self)
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
