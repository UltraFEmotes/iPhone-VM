import Foundation

/// One device + iOS build that Inferno can run, with everything the setup pipeline needs.
struct SupportEntry: Codable, Identifiable, Hashable {
    struct Jailbreak: Codable, Hashable {
        var bootstrap: Bool
        var packageManager: String?
        var tweaks: String
    }

    var id: String
    var deviceName: String
    var device: String
    var board: String
    var machine: String
    var ios: String
    var build: String
    var status: String
    var ipswURL: URL
    var ipswSize: Int64
    var sepFirmwarePath: String
    var sepIV: String
    var sepKey: String
    var sepROM: String
    var sepROMURL: URL
    var trustcache: String
    var kernelcache: String
    var deviceTree: String
    var eraseRamdisk: String
    var bootArgs: String
    var memory: String
    var cpus: Int
    var jailbreak: Jailbreak
    /// Inferno bakes the SEP bypass per iOS major version at build time (SEP_USE_VERSION_OVERRIDE).
    var sepVersion: Int?
    /// iPhone 6s (s8000) simulates the SEP in software: no SEP firmware/ROM or SEP ticket needed.
    var usesSEPSim: Bool?

    var isTested: Bool { status == "tested" }
    var isExperimental: Bool { status == "experimental" }
}

struct SupportManifest: Codable {
    var version: Int
    var entries: [SupportEntry]

    /// Only tested entries are offered in the wizard.
    var testedEntries: [SupportEntry] { entries.filter(\.isTested) }

    static func loadBundled() -> SupportManifest {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(SupportManifest.self, from: data) else {
            return SupportManifest(version: 0, entries: [])
        }
        return manifest
    }
}
