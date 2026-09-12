import SwiftUI

@main
struct InfernoMacApp: App {
    @StateObject private var store = VMStore()
    @StateObject private var registry = RunnerRegistry()

    var body: some Scene {
        WindowGroup("InfernoMac") {
            ContentView()
                .environmentObject(store)
                .environmentObject(registry)
                .frame(minWidth: 820, minHeight: 520)
        }
    }
}
