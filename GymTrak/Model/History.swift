import Foundation

/// A run from anywhere: logged in the app, or synced from Strava / Apple Health.
struct RunRecord: Hashable, Sendable {
    var id: String
    var date: String
    var minutes: Double
    var miles: Double
    var avgHR: Double?
    var name: String

    init(id: String, date: String, minutes: Double, miles: Double, avgHR: Double? = nil, name: String = "Run") {
        self.id = id; self.date = date; self.minutes = minutes; self.miles = miles; self.avgHR = avgHR; self.name = name
    }

    init(_ a: RunActivity) {
        self.init(id: a.id, date: a.date, minutes: a.minutes, miles: a.miles, avgHR: a.avgHR, name: a.name)
    }

    var paceMinPerMile: Double? { miles > 0.3 ? minutes / miles : nil }

    var summary: String {
        var parts: [String] = []
        if miles > 0 { parts.append(String(format: "%.1f mi", miles)) }
        parts.append("\(Int(minutes.rounded())) min")
        if let p = paceMinPerMile { parts.append(fmtPace(p)) }
        return parts.joined(separator: " · ")
    }
}

/// One row in History: a finished lift session or a run.
struct HistoryEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case lift(sessionId: String), run }
    var id: String
    var kind: Kind
    var date: String
    var title: String
    var detail: String
    /// Lifts only: how much of the workout got checked off.
    var outcome: LiftOutcome? = nil
}

/// How a lift day went: every set checked, some, or none.
enum LiftOutcome: Int, Sendable, Hashable, CaseIterable {
    case skipped, almost, finished
}

/// One lift day in the track record.
struct LiftDay: Hashable, Sendable {
    var date: String
    var outcome: LiftOutcome
    /// The workout behind it; nil for a day skipped outright.
    var sessionId: String? = nil
}

/// The most-improved lift: first vs. latest top set.
struct Improvement: Equatable, Sendable {
    var name: String
    var from: Double
    var to: Double
    var since: String
    var pct: Double { from > 0 ? (to - from) / from * 100 : 0 }
}

/// Lifetime totals behind the History header and the facts.
struct LifetimeStats: Equatable, Sendable {
    var workouts = 0
    var sets = 0
    var reps = 0
    var pounds: Double = 0
    /// Minutes over workouts with a believable timer (1 min to 4 h).
    var liftMinutes: Double = 0
    var timedWorkouts = 0
    var runs = 0
    var runMiles: Double = 0
    var runMinutes: Double = 0
    var longestRunMiles: Double = 0
    /// Fastest pace (min/mi) over runs of a mile or more.
    var fastestPace: Double?
    var firstDate: String?
    var daysTrained = 0
    var weekendDays = 0
    var favoriteDay: Dow?
    var favoriteDayCount = 0
    var heaviestName: String?
    var heaviestLb: Double = 0
    var mostSetsName: String?
    var mostSetsCount = 0
    var biggestDayLb: Double = 0
    var biggestDayDate: String?
    /// Minutes after midnight that timed workouts started.
    var earliestStart: Int?
    var latestStart: Int?
    var prs = 0
    var improved: Improvement?

    var heaviest: (name: String, lb: Double)? { heaviestName.map { ($0, heaviestLb) } }
    var avgWorkoutMinutes: Double? { timedWorkouts > 0 ? liftMinutes / Double(timedWorkouts) : nil }
    var avgPace: Double? { runMiles > 0.3 ? runMinutes / runMiles : nil }
}

/// Pounds actually moved by one set, or nil when the load isn't in pounds (pins, bodyweight, free text).
func setPounds(_ weight: String, type: LoadType) -> Double? {
    let p = parseLoad(weight, type: type)
    switch type {
    case .weight: return p.n
    case .plates: return p.n.map { $0 * 45 + (p.add ?? 0) }
    case .machine: return p.lb && !p.max ? p.n : nil
    case .bodyweight, .free: return nil
    }
}

extension Snapshot {
    /// Finished, non-deleted lift sessions, newest first.
    var finishedLifts: [Session] {
        sessions.filter { $0.finishedAt != nil && !$0.isDeleted && !$0.isRun }
            .sorted { ($0.slotDate, $0.finishedAt ?? 0) > ($1.slotDate, $1.finishedAt ?? 0) }
    }

    /// Runs logged inside the app, plus synced ones. A synced run wins on the same date.
    func allRuns(synced: [RunActivity]) -> [RunRecord] {
        let syncedDates = Set(synced.map(\.date))
        let logged = sessions.compactMap { s -> RunRecord? in
            guard s.isRun, !s.isDeleted, s.finishedAt != nil, let r = s.run, !syncedDates.contains(s.slotDate),
                  let logged = r.actualMin, logged > 0 else { return nil }
            // A timer left running (the old web app did this) logs days, not minutes: use the plan instead.
            let min = logged > 300 ? Double(r.plannedMin) : logged
            return RunRecord(id: s.id, date: s.slotDate, minutes: min, miles: r.actualMi ?? 0, avgHR: r.avgHr,
                             name: r.label.rawValue)
        }
        return (logged + synced.map(RunRecord.init)).sorted { $0.date > $1.date }
    }

    /// Done sets in a session, with their pounds.
    /// Every set checked off is finished, some is almost, none is skipped.
    func outcome(_ sessionId: String) -> LiftOutcome {
        let all = sets.filter { $0.sessionId == sessionId }
        let done = all.filter(\.isDone).count
        if done == 0 { return .skipped }
        return done == all.count ? .finished : .almost
    }

    /// Every lift day from the program start to today, oldest first. A day with workouts takes its best one;
    /// a planned lift day that passed with no workout is skipped. Today only counts once something is logged.
    func liftRecord(today: Date) -> [LiftDay] {
        guard let start = programStart else { return [] }
        let todayKey = DateKey.key(today)
        var best: [String: (LiftOutcome, String)] = [:]
        for s in finishedLifts {
            let o = outcome(s.id)
            if o.rawValue > (best[s.slotDate]?.0.rawValue ?? -1) { best[s.slotDate] = (o, s.id) }
        }
        var out: [LiftDay] = []
        var key = start
        while key <= todayKey {
            if let (o, id) = best[key] {
                out.append(LiftDay(date: key, outcome: o, sessionId: id))
            } else if key < todayKey {
                let d = DateKey.date(key)
                if scheduleWeek(d)?.slot(DateKey.dow(d))?.liftDayId != nil {
                    out.append(LiftDay(date: key, outcome: .skipped))
                }
            }
            key = DateKey.addDays(key, 1)
        }
        return out
    }

    /// No lift and no run planned that day, from the program start on. Future days count too.
    func isRestDay(_ key: String) -> Bool {
        guard let start = programStart, key >= start else { return false }
        let d = DateKey.date(key)
        guard let week = scheduleWeek(d) else { return false }
        return week.slot(DateKey.dow(d))?.isRest ?? true
    }

    private func doneSets(_ sessionId: String) -> [(WorkoutSet, Double?)] {
        let types = Dictionary(exercises.map { ($0.id, $0.effectiveLoadType) }, uniquingKeysWith: { a, _ in a })
        return sets.filter { $0.sessionId == sessionId && $0.isDone }.map { st in
            let type = types[st.exerciseId] ?? inferLoadType(st.weight)
            return (st, setPounds(st.weight, type: type))
        }
    }

    /// Pounds moved in one session (weight × reps over done sets).
    func sessionPounds(_ sessionId: String) -> Double {
        doneSets(sessionId).reduce(0) { sum, pair in
            sum + (pair.1 ?? 0) * (numericReps(pair.0.reps) ?? 0)
        }
    }

    /// Minutes trained per date: timed lifts plus runs.
    func minutesTrained(runs synced: [RunActivity]) -> [String: Double] {
        var out: [String: Double] = [:]
        for l in finishedLifts { if let d = l.durationSec, d >= 60, d < 4 * 3600 { out[l.slotDate, default: 0] += d / 60 } }
        for r in allRuns(synced: synced) { out[r.date, default: 0] += r.minutes }
        return out
    }

    /// Every lift and run, newest first.
    func historyEntries(synced: [RunActivity]) -> [HistoryEntry] {
        let lifts = finishedLifts.map { s -> HistoryEntry in
            let done = doneSets(s.id)
            var parts = [done.count == 1 ? "1 set" : "\(done.count) sets"]
            if let d = s.durationSec, d >= 60 { parts.append("\(Int((d / 60).rounded())) min") }
            let title = s.dayNameSnapshot ?? day(s.dayId)?.name ?? "Workout"
            return HistoryEntry(id: s.id, kind: .lift(sessionId: s.id), date: s.slotDate, title: title,
                                detail: parts.joined(separator: " · "), outcome: outcome(s.id))
        }
        let runs = allRuns(synced: synced).map {
            HistoryEntry(id: "run-\($0.id)", kind: .run, date: $0.date, title: $0.name, detail: $0.summary)
        }
        return (lifts + runs).sorted { $0.date > $1.date }
    }

    func lifetimeStats(synced: [RunActivity]) -> LifetimeStats {
        var s = LifetimeStats()
        let lifts = finishedLifts
        s.workouts = lifts.count
        var dayCounts: [Dow: Int] = [:]
        var setsByName: [String: Int] = [:]
        for l in lifts {
            let done = doneSets(l.id)
            s.sets += done.count
            s.reps += done.reduce(0) { $0 + Int(numericReps($1.0.reps) ?? 0) }
            let lb = sessionPounds(l.id)
            s.pounds += lb
            if lb > s.biggestDayLb { s.biggestDayLb = lb; s.biggestDayDate = l.slotDate }
            if let d = l.durationSec, d >= 60, d < 4 * 3600 {
                s.liftMinutes += d / 60
                s.timedWorkouts += 1
                // Start time only means something when the timer ran for a real workout.
                if d >= 600 {
                    let start = Date(timeIntervalSince1970: l.startedAt / 1000)
                    let c = DateKey.calendar.dateComponents([.hour, .minute], from: start)
                    let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                    s.earliestStart = min(s.earliestStart ?? m, m)
                    s.latestStart = max(s.latestStart ?? m, m)
                }
            }
            dayCounts[DateKey.dow(DateKey.date(l.slotDate)), default: 0] += 1
            for (st, lb) in done {
                setsByName[st.exerciseName, default: 0] += 1
                if let lb, lb > s.heaviestLb { s.heaviestLb = lb; s.heaviestName = st.exerciseName }
            }
            s.prs += prs(sessionId: l.id).count
        }
        if let fav = dayCounts.max(by: { ($0.value, -$0.key.index) < ($1.value, -$1.key.index) }) {
            s.favoriteDay = fav.key
            s.favoriteDayCount = fav.value
        }
        if let top = setsByName.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            s.mostSetsName = top.key
            s.mostSetsCount = top.value
        }

        let runs = allRuns(synced: synced)
        s.runs = runs.count
        s.runMiles = runs.reduce(0) { $0 + $1.miles }
        s.runMinutes = runs.reduce(0) { $0 + $1.minutes }
        s.longestRunMiles = runs.map(\.miles).max() ?? 0
        s.fastestPace = runs.filter { $0.miles >= 1 }.compactMap(\.paceMinPerMile).min()

        let dates = Set(lifts.map(\.slotDate) + runs.map(\.date))
        s.daysTrained = dates.count
        s.weekendDays = dates.filter { [.sat, .sun].contains(DateKey.dow(DateKey.date($0))) }.count
        s.firstDate = dates.min()
        s.improved = mostImproved()
        return s
    }

    /// The lift with the biggest top-set gain from its first to its latest session (pound loads only, 3+ sessions).
    func mostImproved() -> Improvement? {
        var best: Improvement?
        for ex in exercises where [.weight, .plates, .machine].contains(ex.effectiveLoadType) {
            let h = liftHistory(for: ex, before: "9999-12-31", limit: .max)
            guard h.count >= 3, let first = h.last, let latest = h.first,
                  let a = first.sets.compactMap({ setPounds($0.weight, type: ex.effectiveLoadType) }).max(),
                  let b = latest.sets.compactMap({ setPounds($0.weight, type: ex.effectiveLoadType) }).max(),
                  a > 0, b > a else { continue }
            let imp = Improvement(name: ex.name, from: a, to: b, since: first.date)
            if best == nil || imp.pct > best!.pct { best = imp }
        }
        return best
    }
}

/// "8,450 lb", "84k lb", "1.2M lb".
func fmtPounds(_ lb: Double) -> String {
    switch lb {
    case 1_000_000...: return String(format: "%.1fM lb", lb / 1_000_000)
    case 100_000...: return "\(Int((lb / 1000).rounded()))k lb"
    default: return "\(Int(lb.rounded()).formatted()) lb"
    }
}

/// 9.83 → "9:50 /mi".
func fmtPace(_ minPerMile: Double) -> String {
    let total = Int((minPerMile * 60).rounded())
    return String(format: "%d:%02d /mi", total / 60, total % 60)
}
