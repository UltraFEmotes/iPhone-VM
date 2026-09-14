import SwiftUI

@MainActor
final class CarrierWindowPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(store: VMStore, registry: RunnerRegistry, carrier: CarrierStore, clipboard: ClipboardSyncService) {
        carrier.delivery = MessagesDelivery(registry: registry, store: store)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = CarrierConsoleView()
            .environmentObject(store)
            .environmentObject(registry)
            .environmentObject(carrier)
            .environmentObject(clipboard)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Carrier"
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.setFrameAutosaveName("InfernoMacCarrierConsole")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            window = nil
        }
    }
}
