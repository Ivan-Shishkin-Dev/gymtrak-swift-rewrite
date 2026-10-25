import SwiftUI

/// Launch screen: a little dumbbell doing reps while the first sync runs.
struct LoadingView: View {
    @State private var up = false
    @State private var squash = false
    @State private var dot = 0

    private let words = ["Warming up", "Chalking hands", "Loading the bar", "Finding your plan"]
    @State private var word = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.lift.mix(with: .white, by: 0.15), Theme.lift.mix(with: .black, by: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    // Shadow that shrinks as the dumbbell goes up.
                    Ellipse()
                        .fill(.black.opacity(0.18))
                        .frame(width: up ? 60 : 110, height: 14)
                        .offset(y: 78)
                        .blur(radius: 3)

                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 92, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(up ? -12 : 12))
                        .scaleEffect(x: squash ? 1.12 : 1, y: squash ? 0.86 : 1, anchor: .bottom)
                        .offset(y: up ? -46 : 0)
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                }
                .frame(height: 190)

                HStack(spacing: 0) {
                    Text(words[word])
                        .contentTransition(.opacity)
                    Text(String(repeating: ".", count: dot + 1))
                        .frame(width: 26, alignment: .leading)
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .monospacedDigit()
            }
        }
        .task { await animate() }
    }

    /// Lift → land with a squash → repeat. Dots and the caption tick along.
    private func animate() async {
        var rep = 0
        while !Task.isCancelled {
            withAnimation(.easeOut(duration: 0.38)) { up = true; squash = false }
            try? await Task.sleep(for: .milliseconds(380))
            withAnimation(.easeIn(duration: 0.3)) { up = false }
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.spring(response: 0.18, dampingFraction: 0.4)) { squash = true }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { squash = false }
            dot = (dot + 1) % 3
            rep += 1
            if rep % 3 == 0 { withAnimation { word = (word + 1) % words.count } }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

#Preview { LoadingView() }
