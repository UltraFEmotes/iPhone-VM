import Foundation

/// Delivers carrier texts through the companion broker and guest-side carrier agent.
/// If the broker is unavailable, it falls back to the older serial-console helper path.
@MainActor
struct MessagesDelivery: CarrierDelivery {
    static let carrierHome = "/var/mobile/Library/InfernoCarrier"
    static let helper = "\(carrierHome)/bin/carrier-msg"
    static let agent = "\(carrierHome)/bin/carrier-agentd"

    let registry: RunnerRegistry
    let store: VMStore

    var routesVMReplies: Bool { true }

    func deliver(_ message: CarrierStore.Message, to vmID: UUID) async throws {
        guard isJailbroken(vmID) else {
            throw SetupError("Messages delivery needs a jailbroken VM")
        }

        if await CarrierBrokerClient.ensureReady() {
            startAgentIfRunning(vmID: vmID, number: message.to)
            let request = BrokerSendRequest(
                from: message.from,
                to: message.to,
                body: message.kind == .call ? "Incoming call" : message.body,
                kind: message.kind.brokerKind,
                source: "mac",
                clientID: "mac-\(message.id.uuidString)"
            )
            if await CarrierBrokerClient.post("/api/send", body: request, as: BrokerMessage.self) != nil {
                return
            }
        }

        guard let runner = registry.runningRunner(vmID) else {
            throw SetupError("VM isn't running and the carrier broker is unavailable")
        }
        deliverOverSerial(message, runner: runner)
    }

    /// Texts the VM user typed (Messages is_from_me), as (recipient, body) pairs, plus the new high-water id.
    func readReplies(vmID: UUID, number: String, since: Int) async -> (messages: [(to: String, body: String)], lastRowID: Int) {
        guard isJailbroken(vmID) else { return ([], since) }
        let cleanNumber = CarrierStore.normalize(number)

        if await CarrierBrokerClient.ensureReady() {
            startAgentIfRunning(vmID: vmID, number: cleanNumber)
            if let result = await brokerReplies(number: cleanNumber, since: since) {
                return result
            }
        }

        guard let runner = registry.runningRunner(vmID) else { return ([], since) }
        return await readRepliesOverSerial(runner: runner, since: since)
    }

    private func isJailbroken(_ vmID: UUID) -> Bool {
        store.machines.first(where: { $0.id == vmID })?.jailbroken == true
    }

    private func startAgentIfRunning(vmID: UUID, number: String) {
        guard let runner = registry.runningRunner(vmID) else { return }
        runner.startCarrierAgent(number: number, quiet: true)
    }

    private func brokerReplies(number: String, since: Int) async -> (messages: [(to: String, body: String)], lastRowID: Int)? {
        let response = await fetchBrokerMessages(number: number, since: since)
        let replayed = (response?.next ?? 0) <= since && since > 0
            ? await fetchBrokerMessages(number: number, since: 0)
            : response
        guard let replayed else { return nil }

        var high = since
        var replies: [(to: String, body: String)] = []
        for message in replayed.messages {
            high = max(high, message.id)
            guard message.source == "vm",
                  CarrierStore.normalize(message.from) == number,
                  !message.body.isEmpty else { continue }
            replies.append((CarrierStore.normalize(message.to), message.body))
        }
        return (replies, high)
    }

    private func fetchBrokerMessages(number: String, since: Int) async -> BrokerMessagesResponse? {
        let escaped = Self.queryEscape(number)
        return await CarrierBrokerClient.get("/api/messages?since=\(since)&number=\(escaped)", as: BrokerMessagesResponse.self)
    }

    private func deliverOverSerial(_ message: CarrierStore.Message, runner: VMRunner) {
        let from = Self.sh(message.from)
        switch message.kind {
        case .call:
            runner.sendToSerial("\(Self.helper) call \(from)")
        case .text, .admin:
            runner.sendToSerial("\(Self.helper) send \(from) \(Self.sh(message.body))")
        }
    }

    private func readRepliesOverSerial(runner: VMRunner, since: Int) async -> (messages: [(to: String, body: String)], lastRowID: Int) {
        if runner.interactiveInputIsRecent { return ([], since) }
        let marker = String(UUID().uuidString.prefix(8))
        runner.sendToSerial("echo CR_\(marker)_BEGIN; \(Self.helper) poll \(since); echo CR_\(marker)_END")
        try? await Task.sleep(nanoseconds: 900_000_000)
        return Self.parseReplies(runner.log, marker: marker, since: since)
    }

    /// Pulls the last CR_<marker>_BEGIN ... CR_<marker>_END block from the serial log and decodes rows
    /// (`ROWID:hex(recipient):hex(text)`), so kernel log spam interleaved on the console cannot corrupt them.
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

    private static func queryEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Single-quotes a value for the guest shell.
    private static func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct BrokerMessagesResponse: Decodable {
    let messages: [BrokerMessage]
    let next: Int
}

private struct BrokerMessage: Codable {
    let id: Int
    let from: String
    let to: String
    let body: String
    let kind: String?
    let source: String?
    let clientID: String?

    enum CodingKeys: String, CodingKey {
        case id, from, to, body, kind, source
        case clientID = "client_id"
    }
}

private struct BrokerSendRequest: Encodable {
    let from: String
    let to: String
    let body: String
    let kind: String
    let source: String
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case from, to, body, kind, source
        case clientID = "client_id"
    }
}

private extension CarrierStore.Kind {
    var brokerKind: String { rawValue.lowercased() }
}
