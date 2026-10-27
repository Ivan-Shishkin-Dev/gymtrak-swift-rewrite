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

/// One Monday–Sunday week of training.
struct WeekStats: Equatable, Sendable {
    var workouts = 0
    var runs = 0
    var runMiles: Double = 0
    var avgWorkoutMinutes: Double?
}

/// How a lift day went: every set checked, some, or none.
enum LiftOutcome: Int, Sendable, Hashable, CaseIterable {
    case skipped, almost, finished
}

/// Whether a planned lift or run happened.
enum DayMark: Sendable, Hashable { case done, missed }

/// One day on the adherence calendar: what lifting and running happened.
struct ActivityDay: Hashable, Sendable {
    var date: String
    var lift: DayMark? = nil
    var run: DayMark? = nil
    /// The day's best workout, if one was logged.
    var sessionId: String? = nil
}

/// Pounds actually moved by one set, or nil when the load isn't in pounds (pins, bodyweight, free text).
func setPounds(_ weight: String, type: LoadType) -> Double? {
    let p = parseLoad(weight, type: type)
    switch type {
    case .weight, .dumbbell: return p.n
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

    /// Every day from the program start to today with a lift or run, oldest first.
    /// A workout with at least one checked set counts as a lift; a planned lift or run that passed without one is missed.
    /// `runDates` holds days with a synced run. Today only counts once something is done.
    func activityRecord(today: Date, runDates: Set<String>) -> [ActivityDay] {
        guard let start = programStart else { return [] }
        let todayKey = DateKey.key(today)
        var best: [String: (LiftOutcome, String)] = [:]
        for s in finishedLifts {
            let o = outcome(s.id)
            if o.rawValue > (best[s.slotDate]?.0.rawValue ?? -1) { best[s.slotDate] = (o, s.id) }
        }
        var out: [ActivityDay] = []
        var key = start
        while key <= todayKey {
            let d = DateKey.date(key)
            let slot = scheduleWeek(d)?.slot(DateKey.dow(d))
            let past = key < todayKey
            var day = ActivityDay(date: key, sessionId: best[key]?.1)
            if let o = best[key]?.0, o != .skipped { day.lift = .done }
            else if past && (slot?.liftDayId != nil || best[key] != nil) { day.lift = .missed }
            if runDates.contains(key) { day.run = .done }
            else if past && slot?.run != nil { day.run = .missed }
            if day.lift != nil || day.run != nil { out.append(day) }
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

    /// Totals for the Monday–Sunday week starting `monday`.
    func weekStats(monday: String, synced: [RunActivity]) -> WeekStats {
        let sunday = DateKey.addDays(monday, 6)
        let lifts = finishedLifts.filter { $0.slotDate >= monday && $0.slotDate <= sunday }
        let runs = allRuns(synced: synced).filter { $0.date >= monday && $0.date <= sunday }
        let timed = lifts.compactMap(\.durationSec).filter { $0 >= 60 && $0 < 4 * 3600 }
        return WeekStats(workouts: lifts.count, runs: runs.count, runMiles: runs.reduce(0) { $0 + $1.miles },
                         avgWorkoutMinutes: timed.isEmpty ? nil : timed.reduce(0, +) / Double(timed.count) / 60)
    }


}

/// 9.83 → "9:50 /mi".
func fmtPace(_ minPerMile: Double) -> String {
    let total = Int((minPerMile * 60).rounded())
    return String(format: "%d:%02d /mi", total / 60, total % 60)
}
