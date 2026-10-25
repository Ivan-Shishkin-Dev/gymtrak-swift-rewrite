import SwiftUI

/// Native iOS look: system colors only, so light and dark mode both work.
/// One accent (green) marks "lift"; blue marks "run".
enum Theme {
    static let lift = Color.green
    static let run = Color.blue
    static let warning = Color.orange
}

extension Font {
    /// Big rounded numbers for loads, reps and timers.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}
