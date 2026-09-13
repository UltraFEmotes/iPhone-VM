import SwiftUI

@main
struct InfernoMacApp: App {
    @StateObject private var store = VMStore()
    @StateObject private var registry = RunnerRegistry()
    @StateObject private var carrier = CarrierStore()
    @StateObject private var clipboard = ClipboardSyncService()

    var body: some Scene {
        WindowGroup("InfernoMac") {
            ContentView()
                .environmentObject(store)
                .environmentObject(registry)
                .environmentObject(carrier)
                .environmentObject(clipboard)
                .frame(minWidth: 820, minHeight: 520)
                .task { carrier.delivery = MessagesDelivery(registry: registry, store: store) }
        }

        Window("Carrier", id: "carrier") {
            CarrierConsoleView()
                .environmentObject(store)
                .environmentObject(registry)
                .environmentObject(carrier)
                .environmentObject(clipboard)
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}
