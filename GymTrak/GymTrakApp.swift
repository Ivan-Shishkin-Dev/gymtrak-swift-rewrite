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
                .onOpenURL { url in
                    // gymtrak://login?code=… from the sign-in email.
                    if url.host == "login" { Task { await store.handle(url) } }
                }
        }
    }
}
