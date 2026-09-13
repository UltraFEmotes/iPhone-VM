import Foundation

/// Delivers carrier texts into the real Messages app of a running jailbroken VM, and reads back replies the
/// VM's user types. It drives the on-VM `carrier-msg` helper over the serial console (installed by
/// "Set Up Carrier"), which uses a sqlite3 re-signed with the Messages data-vault entitlement.
@MainActor
struct MessagesDelivery: CarrierDelivery {
    static let helper = "/usr/local/bin/carrier-msg"

    let registry: RunnerRegistry
    let store: VMStore

    func deliver(_ message: CarrierStore.Message, to vmID: UUID) async throws {
        guard let runner = registry.runningRunner(vmID) else {
            throw SetupError("VM isn't running — start it to receive texts")
        }
        guard store.machines.first(where: { $0.id == vmID })?.jailbroken == true else {
            throw SetupError("Messages delivery needs a jailbroken VM")
        }
        let from = Self.sh(message.from)
        switch message.kind {
        case .call:
            runner.sendToSerial("\(Self.helper) call \(from)")
        case .text, .admin:
            runner.sendToSerial("\(Self.helper) send \(from) \(Self.sh(message.body))")
        }
    }

    /// Texts the VM user typed (Messages "is_from_me"), as (recipient, body) pairs, plus the new high ROWID.
    func readReplies(vmID: UUID, since: Int) async -> (messages: [(to: String, body: String)], lastRowID: Int) {
        guard let runner = registry.runningRunner(vmID),
              store.machines.first(where: { $0.id == vmID })?.jailbroken == true else { return ([], since) }
        // Don't inject a poll command while the user is typing in the Terminal — it shares this serial line.
        if runner.interactiveInputIsRecent { return ([], since) }
        let marker = String(UUID().uuidString.prefix(8))
        runner.sendToSerial("echo CR_\(marker)_BEGIN; \(Self.helper) poll \(since); echo CR_\(marker)_END")
        try? await Task.sleep(nanoseconds: 900_000_000)
        return Self.parseReplies(runner.log, marker: marker, since: since)
    }

    /// Pulls the last `CR_<marker>_BEGIN … CR_<marker>_END` block from the serial log and decodes its rows
    /// (`ROWID:hex(recipient):hex(text)`), so kernel log spam interleaved on the console can't corrupt them.
    static func parseReplies(_ log: String, marker: String, since: Int) -> (messages: [(to: String, body: String)], lastRowID: Int) {
        let lines = log.components(separatedBy: "\n")
        guard let end = lines.lastIndex(of: "CR_\(marker)_END"),
              let begin = lines[..<end].lastIndex(of: "CR_\(marker)_BEGIN") else { return ([], since) }
        var messages: [(to: String, body: String)] = []
        var maxRow = since
        for raw in lines[(begin + 1)..<end] {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let row = Int(parts[0]),
                  parts[1].allSatisfy(\.isHexDigit), parts[2].allSatisfy(\.isHexDigit) else { continue }
            maxRow = max(maxRow, row)
            let to = decodeHex(String(parts[1])), body = decodeHex(String(parts[2]))
            if !to.isEmpty { messages.append((to: to, body: body)) }
        }
        return (messages, maxRow)
    }

    private static func decodeHex(_ hex: String) -> String {
        var bytes = [UInt8]()
        let chars = Array(hex)
        var i = 0
        while i + 1 < chars.count {
            if let b = UInt8(String(chars[i...i + 1]), radix: 16) { bytes.append(b) }
            i += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Single-quotes a value for the guest shell.
    private static func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
