import Foundation

/// Runs external tools (unzip, python, img4, qemu-img, ssh, osascript) for the setup pipeline.
enum Shell {
    struct Failure: LocalizedError {
        let command: String
        let status: Int32
        let tail: String
        var errorDescription: String? { "\(command) failed (exit \(status)): \(tail)" }
    }

    /// Runs `executable args…`, streaming each output line to `onLine`. Throws on a non-zero exit.
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                    env: [String: String] = [:], onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env.forEach { environment[$0.key] = $0.value }
            p.environment = environment

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let collected = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                collected.append(text)
                if let onLine {
                    text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).forEach { onLine(String($0)) }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { collected.append(String(decoding: rest, as: UTF8.self)) }
                let output = collected.value
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
                    continuation.resume(throwing: Failure(command: ([executable] + args).joined(separator: " ").prefix(160).description,
                                                          status: proc.terminationStatus, tail: tail))
                }
            }
            do {
                try p.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a shell command line through zsh.
    @discardableResult
    static func zsh(_ command: String, cwd: URL? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run("/bin/zsh", ["-c", command], cwd: cwd, onLine: onLine)
    }

    /// Runs a script as root via the standard macOS administrator password prompt.
    @discardableResult
    static func asAdministrator(_ command: String) async throws -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }

    /// Single-quotes a value for use inside a zsh command line.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ s: String) {
        lock.lock(); storage += s
        if storage.utf8.count > 200_000 { storage = String(storage.suffix(100_000)) }
        lock.unlock()
    }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}
