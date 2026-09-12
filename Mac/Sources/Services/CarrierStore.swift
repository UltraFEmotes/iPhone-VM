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
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var messages: [Message] = []
    var delivery: CarrierDelivery = LogOnlyDelivery()

    static let adminNumber = "ADMIN"
    private let file: URL = VMStore.vmsRoot.deletingLastPathComponent().appendingPathComponent("carrier.json")

    init() { load() }

    func number(for vmID: UUID) -> String? { lines.first { $0.vmID == vmID }?.number }
    func vmID(for number: String) -> UUID? { lines.first { $0.number == Self.normalize(number) }?.vmID }

    /// Assigns (or clears, with an empty string) a VM's phone number. Numbers are unique.
    func assign(_ number: String, to vmID: UUID) throws {
        let clean = Self.normalize(number)
        if !clean.isEmpty, let owner = self.vmID(for: clean), owner != vmID {
            throw SetupError("\(clean) is already assigned to another VM")
        }
        lines.removeAll { $0.vmID == vmID }
        if !clean.isEmpty { lines.append(Line(vmID: vmID, number: clean)) }
        save()
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

    private func route(_ message: Message) async {
        var m = message
        if let vmID = vmID(for: m.to) {
            do {
                try await delivery.deliver(m, to: vmID)
                m.delivered = true
            } catch {
                m.note = error.localizedDescription
            }
        } else {
            m.note = "No VM has number \(m.to)"
        }
        messages.append(m)
        if messages.count > 2000 { messages.removeFirst(messages.count - 2000) }
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
    }

    private func save() {
        try? JSONEncoder.iso.encode(Saved(lines: lines, messages: messages)).write(to: file, options: .atomic)
    }
}

/// How a routed message reaches iOS inside the VM. Placeholder until the in-VM delivery is chosen
/// (notification, a Carrier inbox app, or Messages).
protocol CarrierDelivery {
    func deliver(_ message: CarrierStore.Message, to vmID: UUID) async throws
}

struct LogOnlyDelivery: CarrierDelivery {
    func deliver(_ message: CarrierStore.Message, to vmID: UUID) async throws {
        throw SetupError("Logged only — in-VM delivery isn't set up yet")
    }
}
