import Foundation

/// The set that's up next in the open workout, for the lock-screen rest timer.
struct NextSet: Equatable {
    var workout: String     // "Upper A"
    var exercise: String    // "Bench"
    var weight: String      // "135 lb", "4 pl + 25", ""
    var reps: String        // "6"
    var warmup: Bool

    /// "135 lb × 6", or "× 6" with no load.
    var load: String { weight.isEmpty ? "× \(reps)" : "\(weight) × \(reps)" }
}

extension Snapshot {
    /// The next set still to do in the open lift; nil with no lift open or everything done.
    func nextSet() -> NextSet? {
        guard let open = openLift(), let item = pendingItems(open).first else { return nil }
        return NextSet(workout: open.dayNameSnapshot ?? day(open.dayId)?.name ?? "Workout",
                       exercise: item.ex.name, weight: item.set.weight, reps: bareReps(item.set.reps), warmup: item.warmup)
    }
}
