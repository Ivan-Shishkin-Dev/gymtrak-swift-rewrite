import SwiftUI

@main
struct GymTrakApp: App {
    @State private var store = Store()
    @State private var rest = RestTimer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(rest)
                .preferredColorScheme(.dark)
        }
    }
}
