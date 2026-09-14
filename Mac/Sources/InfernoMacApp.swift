import SwiftUI

@main
struct InfernoMacApp: App {
    @StateObject private var store = VMStore()
    @StateObject private var registry = RunnerRegistry()
    @StateObject private var carrier = CarrierStore()
    @StateObject private var clipboard = ClipboardSyncService()
    @StateObject private var carrierWindow = CarrierWindowPresenter()

    var body: some Scene {
        WindowGroup("InfernoMac") {
            ContentView()
                .environmentObject(store)
                .environmentObject(registry)
                .environmentObject(carrier)
                .environmentObject(clipboard)
                .environmentObject(carrierWindow)
                .frame(minWidth: 820, minHeight: 520)
                .task { carrier.delivery = MessagesDelivery(registry: registry, store: store) }
        }
        .commands {
            CommandMenu("Carrier") {
                Button("Open Carrier Console") {
                    carrierWindow.show(store: store, registry: registry, carrier: carrier, clipboard: clipboard)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
