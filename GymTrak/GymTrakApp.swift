import SwiftUI

@main
struct GymTrakApp: App {
    @State private var store = Store()
    @State private var rest = RestTimer()
    @State private var connections = Connections()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(rest)
                .environment(connections)
                .task { WatchBridge.shared.start(store: store, rest: rest) }
        }
    }
}
