import SwiftUI

@main
struct GymTrakApp: App {
    @State private var store = Store()
    @State private var rest = RestTimer()
    @State private var connections = Connections()
    @State private var spotify = Spotify()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(rest)
                .environment(connections)
                .environment(spotify)
                .onOpenURL { url in
                    // gymtrak://spotify?code=… when the Spotify sign-in session isn't catching it.
                    if url.host == "spotify" { Task { await spotify.finishSpotify(callback: url) } }
                }
        }
    }
}
