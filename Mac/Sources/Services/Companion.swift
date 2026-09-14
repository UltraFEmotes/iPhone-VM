import Foundation

/// Talks to the companion Debian VM (SSH on localhost:32222), which owns the iPhone VM's USB link.
enum Companion {
    private static var sshOptions: [String] {
        ["-i", InfernoPaths.dataRoot.appendingPathComponent("companion_key").path, "-p", "32222",
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
         "-o", "ConnectTimeout=8"]
    }
    private static let sshDestination = "inferno@localhost"
    private static var sshArgs: [String] {
        sshOptions + [sshDestination]
    }

    static let carrierLocalPort = 18088
    static var carrierBaseURL: URL { URL(string: "http://127.0.0.1:\(carrierLocalPort)")! }
    @MainActor private static var carrierTunnel: Process?

    /// Runs one command on the companion and returns its combined output (never throws for a non-zero exit).
    static func run(_ command: String) async -> String {
        do {
            return try await Shell.run("/usr/bin/ssh", sshArgs + [command])
        } catch let failure as Shell.Failure {
            return failure.tail
        } catch {
            return error.localizedDescription
        }
    }

    /// Starts the companion broker and keeps a local Mac URL forwarded to it.
    @MainActor
    static func ensureCarrierBroker() async -> Bool {
        if await localCarrierBrokerIsHealthy() { return true }
        let served = await run("bash /mnt/host/carrier/serve.sh").trimmingCharacters(in: .whitespacesAndNewlines)
        guard served.contains("HTTP 200") else { return false }
        if await localCarrierBrokerIsHealthy() { return true }
        startCarrierTunnel()
        for _ in 0..<20 {
            if await localCarrierBrokerIsHealthy() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    @MainActor
    private static func startCarrierTunnel() {
        if carrierTunnel?.isRunning == true { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshOptions + ["-N", "-L", "127.0.0.1:\(carrierLocalPort):127.0.0.1:8088", sshDestination]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.terminationHandler = { proc in
            Task { @MainActor in
                if carrierTunnel === proc {
                    carrierTunnel = nil
                }
            }
        }
        do {
            try p.run()
            carrierTunnel = p
        } catch {
            carrierTunnel = nil
        }
    }

    private static func localCarrierBrokerIsHealthy() async -> Bool {
        do {
            let url = carrierBaseURL.appendingPathComponent("api/health").absoluteString
            let out = try await Shell.run("/usr/bin/curl", ["-fsS", "-m", "2", url])
            return out.contains("\"ok\"")
        } catch {
            return false
        }
    }

    enum TrustResult {
        case paired, denied, noDevice, other(String)
    }

    /// Asks iOS to pair with the companion once; iOS shows its "Trust This Computer?" prompt.
    static func sendTrustPrompt() async -> TrustResult {
        // usbmuxd exits when idle; it must be running for idevicepair to see the iPhone.
        let out = await run("sudo systemctl start usbmuxd; sleep 3; idevicepair pair 2>&1; idevicepair validate 2>&1")
        if out.contains("SUCCESS") { return .paired }
        if out.contains("denied the trust dialog") { return .denied }
        if out.contains("No device found") || out.contains("Unable to retrieve") { return .noDevice }
        if out.contains("Please accept the trust dialog") { return .other("Prompt shown — tap Trust in the VM, then press Send Trust Prompt again to confirm.") }
        return .other(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
