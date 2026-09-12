import SwiftUI

@main
struct InfernoMacApp: App {
    @StateObject private var store = VMStore()
    @StateObject private var registry = RunnerRegistry()
    @StateObject private var carrier = CarrierStore()

    var body: some Scene {
        WindowGroup("InfernoMac") {
            ContentView()
                .environmentObject(store)
                .environmentObject(registry)
                .environmentObject(carrier)
                .frame(minWidth: 820, minHeight: 520)
        }

        Window("Carrier", id: "carrier") {
            CarrierConsoleView()
                .environmentObject(store)
                .environmentObject(registry)
                .environmentObject(carrier)
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}
