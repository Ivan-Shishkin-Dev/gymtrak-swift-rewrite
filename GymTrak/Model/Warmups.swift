import Foundation

/// Rest after a warm-up set.
let warmupRestSec = 120

extension Exercise {
    /// The warm-ups a new workout starts with: last time's, or the defaults.
    var warmupPlan: [SetRow] {
        guard warmup == true else { return [] }
        if let warmupRows, !warmupRows.isEmpty { return warmupRows }
        return defaultWarmups
    }

    /// About half the first working set for 8, then about three quarters for 4.
    var defaultWarmups: [SetRow] {
        let top = rows.first?.weight ?? ""
        return [SetRow(weight: scaledLoad(top, 0.5), reps: "× 8"), SetRow(weight: scaledLoad(top, 0.75), reps: "× 4")]
    }

    /// `raw` scaled down and rounded to a load you can actually set. Blank when it can't be scaled (Max, free text).
    func scaledLoad(_ raw: String, _ fraction: Double) -> String {
        let type = effectiveLoadType
        var p = parseLoad(raw, type: type)
        func round(_ x: Double, to step: Double) -> Double { Swift.max(step, (x / step).rounded() * step) }
        switch type {
        case .weight, .dumbbell:
            guard let n = p.n else { return "" }
            p.n = round(n * fraction, to: Swift.max(effectiveIncrement, 5))
        case .machine:
            guard let n = p.n, !p.max else { return "" }
            p.n = round(n * fraction, to: p.lb ? Swift.max(effectiveIncrement, 5) : 1)
        case .plates:
            guard let n = p.n else { return "" }
            p.n = round(n * fraction, to: 1)
            p.add = nil
        case .bodyweight:
            return "BW"
        case .free:
            return ""
        }
        return formatLoad(p)
    }
}

/// One set in the live workout, in order: an exercise's warm-ups, then its working sets.
struct WorkoutItem {
    let set: WorkoutSet
    let ex: Exercise
    let warmup: Bool
}

extension Snapshot {
    func workoutItems(_ session: Session) -> [WorkoutItem] {
        let working = sets(of: session.id)
        let warm = warmups(of: session.id)
        return exercises(of: session.dayId).flatMap { ex in
            warm.filter { $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }.map { WorkoutItem(set: $0, ex: ex, warmup: true) }
            + working.filter { $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }.map { WorkoutItem(set: $0, ex: ex, warmup: false) }
        }
    }

    /// Sets still to do. Warm-ups are optional: once a working set of that exercise is done, they drop out.
    func pendingItems(_ session: Session) -> [WorkoutItem] {
        let items = workoutItems(session)
        let started = Set(items.filter { !$0.warmup && $0.set.isDone }.map(\.ex.id))
        return items.filter { !$0.set.isDone && !($0.warmup && started.contains($0.ex.id)) }
    }
}
