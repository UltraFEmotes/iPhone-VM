import SwiftUI

@main
struct InfernoMacApp: App {
    @StateObject private var store = VMStore()

    var body: some Scene {
        WindowGroup("InfernoMac") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 520)
        }
    }
}
