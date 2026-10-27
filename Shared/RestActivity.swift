#if os(iOS)
import ActivityKit
import Foundation

/// The rest countdown as a Live Activity: lock screen and Dynamic Island.
struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var endsAt: Date
        /// The set coming up, e.g. "Pec Dec" and "215 lb × 6".
        var nextExercise: String?
        var nextLoad: String?
    }

    /// Today's workout, e.g. "Upper A".
    var workout: String
}
#endif
