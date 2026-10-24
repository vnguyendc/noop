import SwiftUI

@main
struct NOOPWatchApp: App {
    @StateObject private var store = WatchSnapshotStore()
    @StateObject private var directClient = WatchDirectBLEClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchGlanceView(store: store, directClient: directClient)
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    directClient.stop()
                    store.setDirectModeActive(false)
                }
        }
    }
}
