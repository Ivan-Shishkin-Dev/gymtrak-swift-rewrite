import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "GymTrak",
                systemImage: "dumbbell.fill",
                description: Text("Swift rewrite: setup done. Data model comes next.")
            )
        }
    }
}

#Preview {
    ContentView()
}
