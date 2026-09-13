import Foundation

/// Talks to the companion Debian VM (SSH on localhost:32222), which owns the iPhone VM's USB link.
enum Companion {
    private static var sshArgs: [String] {
        ["-i", InfernoPaths.dataRoot.appendingPathComponent("companion_key").path, "-p", "32222",
         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
         "-o", "ConnectTimeout=8", "inferno@localhost"]
    }

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

    enum TrustResult {
        case paired, denied, noDevice, other(String)
    }

    /// Asks iOS to pair with the companion once; iOS shows its "Trust This Computer?" prompt.
    static func sendTrustPrompt() async -> TrustResult {
        let out = await run("idevicepair pair 2>&1; idevicepair validate 2>&1")
        if out.contains("SUCCESS") { return .paired }
        if out.contains("denied the trust dialog") { return .denied }
        if out.contains("No device found") || out.contains("Unable to retrieve") { return .noDevice }
        if out.contains("Please accept the trust dialog") { return .other("Prompt shown — tap Trust in the VM, then press Send Trust Prompt again to confirm.") }
        return .other(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
