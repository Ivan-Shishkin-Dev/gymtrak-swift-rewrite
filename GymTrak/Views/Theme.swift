import SwiftUI

/// Native iOS look: system colors only, so light and dark mode both work.
/// One accent (green) marks "lift"; blue marks "run".
enum Theme {
    static let lift = Color.green
    static let run = Color.blue
    static let warning = Color.orange
}

/// Settings-app style icon: white symbol on a colored rounded square.
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

extension Font {
    /// Big rounded numbers for loads, reps and timers.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}
