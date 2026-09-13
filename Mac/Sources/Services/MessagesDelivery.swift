import Foundation

/// Delivers carrier texts into the real Messages app of a running jailbroken VM: the message is inserted
/// into /var/mobile/Library/SMS/sms.db through the VM's serial root shell, then Messages is reloaded.
/// No modem is involved — this is a simulated carrier.
///
/// iOS's sandbox refuses the SMS folder even to root unless the process holds the
/// `com.apple.private.security.storage.SMS` entitlement, so the SQL runs through a copy of sqlite3
/// re-signed with that entitlement (see `sqliteTool`).
@MainActor
struct MessagesDelivery: CarrierDelivery {
    static let sqliteTool = "/usr/local/bin/carrier-sqlite3"

    let registry: RunnerRegistry
    let store: VMStore

    func deliver(_ message: CarrierStore.Message, to vmID: UUID) async throws {
        guard let runner = registry.runningRunner(vmID) else {
            throw SetupError("VM isn't running — start it to receive texts")
        }
        guard store.machines.first(where: { $0.id == vmID })?.jailbroken == true else {
            throw SetupError("Messages delivery needs a jailbroken VM")
        }
        let body = message.kind == .call ? "📞 Missed call" : message.body
        runner.note("carrier: \(message.kind.rawValue.lowercased()) from \(message.from)")
        for line in Self.commands(from: message.from, body: body) { runner.sendToSerial(line) }
    }

    /// Shell lines for the VM: a heredoc of SQL (so quotes in the text survive) plus a Messages reload.
    static func commands(from sender: String, body: String) -> [String] {
        let text = sql(body.replacingOccurrences(of: "\n", with: " "))
        let handle = sql(sender)
        let guid = UUID().uuidString
        // iOS stores Messages dates as nanoseconds since 2001-01-01.
        let date = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        let db = "/var/mobile/Library/SMS/sms.db"
        return [
            "\(sqliteTool) \(db) <<'CARRIER_SQL'",
            "INSERT OR IGNORE INTO handle (id, country, service, uncanonicalized_id) VALUES (\(handle), 'us', 'SMS', \(handle));",
            "INSERT OR IGNORE INTO chat (guid, style, state, chat_identifier, service_name, account_login) VALUES ('SMS;-;' || \(handle), 45, 3, \(handle), 'SMS', 'E:');",
            "INSERT OR IGNORE INTO chat_handle_join (chat_id, handle_id) SELECT c.ROWID, h.ROWID FROM chat c, handle h WHERE c.chat_identifier = \(handle) AND h.id = \(handle) AND h.service = 'SMS';",
            "INSERT INTO message (guid, text, handle_id, service, account, date, date_delivered, is_from_me, is_finished, is_delivered, is_read, is_sent) SELECT '\(guid)', \(text), ROWID, 'SMS', 'E:', \(date), \(date), 0, 1, 1, 0, 0 FROM handle WHERE id = \(handle) AND service = 'SMS';",
            "INSERT INTO chat_message_join (chat_id, message_id, message_date) SELECT c.ROWID, m.ROWID, \(date) FROM chat c, message m WHERE c.chat_identifier = \(handle) AND m.guid = '\(guid)';",
            "CARRIER_SQL",
            "chown mobile:mobile \(db)*; killall -9 imagent MobileSMS 2>/dev/null; echo CARRIER_DELIVERED",
        ]
    }

    /// Reads texts the VM's user sent (Messages "is_from_me") since ROWID `since`, by running a query on the
    /// serial console and parsing its output. Rows are emitted as `ROWID:HEX(handle):HEX(text)` between two
    /// markers, so kernel log spam interleaved on the console can't corrupt them (hex has no odd characters).
    func readReplies(vmID: UUID, since: Int) async -> (messages: [(to: String, body: String)], lastRowID: Int) {
        guard let runner = registry.runningRunner(vmID),
              store.machines.first(where: { $0.id == vmID })?.jailbroken == true else { return ([], since) }
        let db = "/var/mobile/Library/SMS/sms.db"
        let query = "SELECT m.ROWID||':'||hex(h.id)||':'||hex(m.text) FROM message m " +
            "JOIN handle h ON m.handle_id=h.ROWID WHERE m.is_from_me=1 AND m.ROWID>\(since) ORDER BY m.ROWID;"
        let marker = UUID().uuidString.prefix(8)
        runner.sendToSerial("echo CR_\(marker)_BEGIN; \(Self.sqliteTool) \(db) \"\(query)\" 2>/dev/null; echo CR_\(marker)_END")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        return Self.parseReplies(runner.log, marker: String(marker), since: since)
    }

    /// Pulls the last `CR_<marker>_BEGIN … CR_<marker>_END` block out of the serial log and decodes its rows.
    static func parseReplies(_ log: String, marker: String, since: Int) -> (messages: [(to: String, body: String)], lastRowID: Int) {
        let lines = log.components(separatedBy: "\n")
        guard let end = lines.lastIndex(of: "CR_\(marker)_END"),
              let begin = lines[..<end].lastIndex(of: "CR_\(marker)_BEGIN") else { return ([], since) }
        var messages: [(to: String, body: String)] = []
        var maxRow = since
        for raw in lines[(begin + 1)..<end] {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
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

    private static func sql(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
