import Foundation

/// The Mac acting as the cellular carrier: custom phone numbers per VM, message routing and a traffic log.
/// How a message actually appears inside iOS is handled by a `CarrierDelivery` (chosen later).
@MainActor
final class CarrierStore: ObservableObject {
    struct Line: Codable, Identifiable, Hashable {
        var id: UUID { vmID }
        var vmID: UUID
        var number: String
    }

    enum Kind: String, Codable { case text = "Text", call = "Call", admin = "Admin" }

    struct Message: Codable, Identifiable, Hashable {
        var id = UUID()
        var date = Date()
        var kind: Kind
        var from: String
        var to: String
        var body: String
        var delivered: Bool
        var note: String?
    }

    private struct Saved: Codable {
        var lines: [Line] = []
        var messages: [Message] = []
        var lastReplyRowID: [String: Int] = [:]
        var contacts: [String: String] = [:]
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var messages: [Message] = []
    var delivery: CarrierDelivery = LogOnlyDelivery()

    /// Highest sms.db message ROWID already seen per VM, so a reply is turned into a text only once.
    private var lastReplyRowID: [UUID: Int] = [:]

    static let adminNumber = "ADMIN"
    private let file: URL = VMStore.vmsRoot.deletingLastPathComponent().appendingPathComponent("carrier.json")

    init() { load() }

    func number(for vmID: UUID) -> String? { lines.first { $0.vmID == vmID }?.number }
    func vmID(for number: String) -> UUID? { lines.first { $0.number == Self.normalize(number) }?.vmID }

    /// Custom contact names for numbers not tied to a VM (e.g. "Mom" → +15550•••). VM numbers use the VM name.
    @Published private(set) var contacts: [String: String] = [:]

    func setContact(_ name: String, for number: String) {
        let n = Self.normalize(number)
        guard !n.isEmpty else { return }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { contacts[n] = nil } else { contacts[n] = name }
        save()
    }

    /// Every number the carrier knows: VM lines, named contacts, and anything seen in the log.
    func allNumbers() -> [String] {
        var set = Set(lines.map(\.number)).union(contacts.keys)
        for m in messages { set.insert(m.from); set.insert(m.to) }
        set.remove(Self.adminNumber)
        return set.sorted()
    }

    /// The other parties `me` has exchanged messages with, most-recent first.
    func peers(of me: String) -> [String] {
        let me = Self.normalize(me)
        var last: [String: Date] = [:]
        for m in messages where m.from == me || m.to == me {
            let other = m.from == me ? m.to : m.from
            if other == me { continue }
            last[other] = max(last[other] ?? .distantPast, m.date)
        }
        return last.keys.sorted { (last[$0] ?? .distantPast) > (last[$1] ?? .distantPast) }
    }

    /// The transcript between two numbers (admin messages to `me` are included).
    func conversation(_ me: String, _ other: String) -> [Message] {
        let me = Self.normalize(me), other = Self.normalize(other)
        return messages.filter {
            ($0.from == me && $0.to == other) || ($0.from == other && $0.to == me) ||
            ($0.kind == .admin && $0.to == me && other == Self.adminNumber)
        }
    }

    /// Assigns (or clears, with an empty string) a VM's phone number. Numbers are unique.
    func assign(_ number: String, to vmID: UUID) throws {
        let clean = Self.normalize(number)
        if !clean.isEmpty, let owner = self.vmID(for: clean), owner != vmID {
            throw SetupError("\(clean) is already assigned to another VM")
        }
        lines.removeAll { $0.vmID == vmID }
        if !clean.isEmpty { lines.append(Line(vmID: vmID, number: clean)) }
        save()
        Task { @MainActor in await self.publishLinesIfPossible() }
    }

    /// Next free number in a fake +1 555 range.
    func suggestNumber() -> String {
        var n = 5550100
        while vmID(for: "+1\(n)") != nil { n += 1 }
        return "+1\(n)"
    }

    func sendText(from: String, to: String, body: String) async {
        await route(Message(kind: .text, from: Self.normalize(from), to: Self.normalize(to), body: body, delivered: false))
    }

    func placeCall(from: String, to: String) async {
        await route(Message(kind: .call, from: Self.normalize(from), to: Self.normalize(to), body: "Incoming call", delivered: false))
    }

    /// Admin message to one VM (by number) or, with `to == nil`, every VM that has a number.
    func sendAdmin(_ body: String, to: String?) async {
        let targets = to.map { [Self.normalize($0)] } ?? lines.map(\.number)
        for target in targets {
            await route(Message(kind: .admin, from: Self.adminNumber, to: target, body: body, delivered: false))
        }
    }

    /// Checks each numbered, running VM for texts the user typed in its Messages app and turns them into
    /// incoming carrier texts. If the reply is addressed to another VM's number, it's delivered there too
    /// (VM-to-VM texting). Call this on a timer while the carrier console is open.
    func pollReplies() async {
        await publishLinesIfPossible()
        for line in lines {
            let baseline = lastReplyRowID[line.vmID]
            let result = await delivery.readReplies(vmID: line.vmID, number: line.number, since: baseline ?? 0)
            // First time we see this VM, remember where it is and don't replay its existing sent messages.
            if baseline == nil {
                lastReplyRowID[line.vmID] = result.lastRowID
                save()
                continue
            }
            guard result.lastRowID > baseline! else { continue }
            lastReplyRowID[line.vmID] = result.lastRowID
            for reply in result.messages {
                let to = Self.normalize(reply.to)
                var m = Message(kind: .text, from: line.number, to: to, body: reply.body, delivered: true, note: "from VM")
                if let destVM = vmID(for: to), destVM != line.vmID {
                    if delivery.routesVMReplies {
                        m.note = "from VM via broker"
                    } else {
                        do { try await delivery.deliver(m, to: destVM) }
                        catch { m.delivered = false; m.note = error.localizedDescription }
                    }
                }
                if !containsDuplicate(m) {
                    messages.append(m)
                }
            }
            if messages.count > 2000 { messages.removeFirst(messages.count - 2000) }
            save()
        }
    }

    private func route(_ message: Message) async {
        await publishLinesIfPossible()
        var m = message
        m.delivered = true                          // recorded on the Mac carrier
        // If the recipient is a running jailbroken VM, mirror it into the real Messages app and show failures.
        if let vmID = vmID(for: m.to) {
            do {
                try await delivery.deliver(m, to: vmID)
            } catch {
                m.delivered = false
                m.note = error.localizedDescription
            }
        }
        messages.append(m)
        if messages.count > 2000 { messages.removeFirst(messages.count - 2000) }
        save()
    }

    /// Clears the whole message log (keeps numbers and contacts).
    func clearMessages() {
        messages.removeAll()
        save()
    }

    static func normalize(_ number: String) -> String {
        let kept = number.filter { $0.isNumber || $0 == "+" }
        return number.uppercased() == adminNumber ? adminNumber : kept
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder.iso.decode(Saved.self, from: data) else { return }
        lines = saved.lines
        messages = saved.messages
        contacts = saved.contacts
        lastReplyRowID = Dictionary(uniqueKeysWithValues: saved.lastReplyRowID.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save() {
        let rowIDs = Dictionary(uniqueKeysWithValues: lastReplyRowID.map { ($0.key.uuidString, $0.value) })
        try? JSONEncoder.iso.encode(Saved(lines: lines, messages: messages, lastReplyRowID: rowIDs, contacts: contacts))
            .write(to: file, options: .atomic)
    }

    /// A display label for a number: VM name if it's a VM line, else a saved contact name, else the number.
    func displayName(_ number: String, vmName: (UUID) -> String?) -> String {
        let n = Self.normalize(number)
        if n == Self.adminNumber { return "Carrier admin" }
        if let vmID = vmID(for: n), let name = vmName(vmID) { return name }
        return contacts[n] ?? n
    }

    private func containsDuplicate(_ message: Message) -> Bool {
        messages.contains {
            $0.kind == message.kind &&
            $0.from == message.from &&
            $0.to == message.to &&
            $0.body == message.body &&
            abs($0.date.timeIntervalSince(message.date)) < 2
        }
    }

    private func publishLinesIfPossible() async {
        _ = await CarrierBrokerClient.post(
            "/api/lines",
            body: BrokerLinesRequest(lines: lines.map { BrokerLine(number: $0.number, vmID: $0.vmID.uuidString) }),
            as: BrokerOK.self
        )
    }
}

/// How a routed message reaches iOS inside the VM, and how replies come back out.
@MainActor
protocol CarrierDelivery {
    var routesVMReplies: Bool { get }
    func deliver(_ message: CarrierStore.Message, to vmID: UUID) async throws
    /// Texts the VM's user sent (is_from_me) with a ROWID greater than `since`, plus the new high-water ROWID.
    func readReplies(vmID: UUID, number: String, since: Int) async -> (messages: [(to: String, body: String)], lastRowID: Int)
}

extension CarrierDelivery {
    var routesVMReplies: Bool { false }

    func readReplies(vmID: UUID, number: String, since: Int) async -> (messages: [(to: String, body: String)], lastRowID: Int) {
        ([], since)
    }
}

struct LogOnlyDelivery: CarrierDelivery {
    func deliver(_ message: CarrierStore.Message, to vmID: UUID) async throws {
        throw SetupError("Logged only — in-VM delivery isn't set up yet")
    }
}

private struct BrokerLine: Encodable {
    let number: String
    let vmID: String

    enum CodingKeys: String, CodingKey {
        case number
        case vmID = "vm_id"
    }
}

private struct BrokerLinesRequest: Encodable {
    let lines: [BrokerLine]
}

private struct BrokerOK: Decodable {
    let ok: Bool
}
