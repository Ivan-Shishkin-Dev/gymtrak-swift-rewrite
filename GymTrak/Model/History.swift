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

    /// Every lift and run, newest first.
    func historyEntries(synced: [RunActivity]) -> [HistoryEntry] {
        let lifts = finishedLifts.map { s -> HistoryEntry in
            let done = doneSets(s.id)
            let lb = sessionPounds(s.id)
            var parts = [done.count == 1 ? "1 set" : "\(done.count) sets"]
            if lb > 0 { parts.append(fmtPounds(lb)) }
            if let d = s.durationSec, d >= 60 { parts.append("\(Int((d / 60).rounded())) min") }
            let title = s.dayNameSnapshot ?? day(s.dayId)?.name ?? "Workout"
            return HistoryEntry(id: s.id, kind: .lift(sessionId: s.id), date: s.slotDate, title: title,
                                detail: parts.joined(separator: " · "))
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

// MARK: - Facts

/// One fun fact. `kind` picks the icon and color.
struct Fact: Hashable, Sendable {
    enum Kind: Sendable { case lift, run, time, you }
    var kind: Kind
    var text: String

    var icon: String {
        switch kind {
        case .lift: "dumbbell.fill"
        case .run: "figure.run"
        case .time: "clock.fill"
        case .you: "star.fill"
        }
    }
}

/// Reference weights and distances. Rounded public figures, so every fact says "about".
enum FactRefs {
    /// (singular, plural, pounds)
    static let weights: [(String, String, Double)] = [
        ("concert grand piano", "concert grand pianos", 1_000),        // Steinway Model D ≈ 990 lb
        ("Toyota Camry", "Toyota Camrys", 3_400),                       // curb weight ≈ 3,300–3,500 lb
        ("African elephant", "African elephants", 13_000),             // adult bull ≈ 6 t
        ("school bus", "school buses", 25_000),                         // full-size, empty
        ("Boeing 737", "Boeing 737s", 91_000),                          // 737-800 empty ≈ 91,300 lb
        ("space shuttle", "space shuttles", 170_000),                   // orbiter, empty ≈ 172,000 lb
        ("blue whale", "blue whales", 300_000),                         // largest ≈ 150 short tons
        ("Statue of Liberty", "Statues of Liberty", 450_000),           // ≈ 225 short tons
        ("International Space Station", "International Space Stations", 925_000), // ≈ 420,000 kg
    ]
    /// (name, miles)
    static let distances: [(String, Double)] = [
        ("the Golden Gate Bridge", 1.7),
        ("a 5K", 3.107),
        ("Central Park's full loop", 6.1),
        ("Manhattan, end to end", 13.4),
        ("the English Channel at its narrowest", 21),
        ("a marathon", 26.2),
    ]
    static let everestMiles = 29_032.0 / 5_280           // ≈ 5.5 mi tall
    static let nycToLAMiles = 2_790.0                     // driving
    static let lotrExtendedHours = 706.0 / 60             // 208 + 235 + 263 min
    static let caloriesPerMile = 100.0                    // common rule of thumb for running
    static let pizzaSliceCalories = 285.0                 // one slice of a large cheese pizza
}

/// Every fact the totals support. Each is checked against a threshold so none reads silly.
func historyFacts(_ s: LifetimeStats) -> [Fact] {
    var out: [Fact] = []
    func n(_ x: Double) -> String { x < 10 ? String(format: "%.1f", x) : Int(x.rounded()).formatted() }
    func mi(_ x: Double) -> String { String(format: "%.1f mi", x) }
    func day(_ key: String) -> String { DateKey.date(key).formatted(.dateTime.month(.abbreviated).day()) }
    func clock(_ m: Int) -> String {
        var c = DateComponents(); c.hour = m / 60; c.minute = m % 60
        return (DateKey.calendar.date(from: c) ?? Date()).formatted(date: .omitted, time: .shortened)
    }

    // Lifting: pounds moved vs. real things. One fact per thing you've moved at least once.
    if s.pounds >= 1_000 {
        for (one, many, lb) in FactRefs.weights where s.pounds >= lb {
            let count = s.pounds / lb
            if count > 2_000 { continue }
            let name = count < 1.05 ? one : many
            out.append(Fact(kind: .lift, text: "You've moved \(fmtPounds(s.pounds)). That's about \(n(count)) \(name)."))
        }
    }
    if let h = s.heaviest { out.append(Fact(kind: .lift, text: "Heaviest set: \(h.name), \(fmtNum(h.lb)) lb.")) }
    if let imp = s.improved, imp.pct >= 1 {
        out.append(Fact(kind: .lift, text: "\(imp.name) is up \(Int(imp.pct.rounded()))% since \(day(imp.since)). \(fmtNum(imp.from)) → \(fmtNum(imp.to)) lb."))
    }
    if let name = s.mostSetsName, s.mostSetsCount >= 5 {
        out.append(Fact(kind: .lift, text: "Most-trained lift: \(name), \(s.mostSetsCount) sets."))
    }
    if let date = s.biggestDayDate, s.biggestDayLb > 0 {
        out.append(Fact(kind: .lift, text: "Biggest day: \(fmtPounds(s.biggestDayLb)) on \(day(date))."))
    }
    if s.prs >= 1 { out.append(Fact(kind: .lift, text: "\(s.prs) PRs and counting.")) }
    if s.sets >= 10 { out.append(Fact(kind: .lift, text: "\(s.sets.formatted()) sets, \(s.reps.formatted()) reps.")) }
    if s.workouts >= 2, s.pounds > 0 {
        out.append(Fact(kind: .lift, text: "Average workout moves \(fmtPounds(s.pounds / Double(s.workouts)))."))
    }

    // Running.
    if s.runMiles >= 1 {
        for (name, miles) in FactRefs.distances where s.runMiles >= miles {
            out.append(Fact(kind: .run, text: "\(mi(s.runMiles)) run. That's \(n(s.runMiles / miles))× \(name)."))
        }
        out.append(Fact(kind: .run, text: "Stacked up, your miles are \(n(s.runMiles / FactRefs.everestMiles)) Mount Everests tall."))
        let pct = s.runMiles / FactRefs.nycToLAMiles * 100
        out.append(Fact(kind: .run, text: "You're \(pct < 1 ? String(format: "%.2f", pct) : n(pct))% of the way from New York to LA on foot."))
        let cal = s.runMiles * FactRefs.caloriesPerMile
        out.append(Fact(kind: .run, text: "Your runs burned roughly \(Int(cal.rounded()).formatted()) calories. About \(n(cal / FactRefs.pizzaSliceCalories)) slices of pizza."))
    }
    if s.longestRunMiles >= 1 { out.append(Fact(kind: .run, text: "Longest run: \(mi(s.longestRunMiles)).")) }
    if let p = s.fastestPace { out.append(Fact(kind: .run, text: "Fastest pace: \(fmtPace(p)).")) }
    if let p = s.avgPace, s.runs >= 2 { out.append(Fact(kind: .run, text: "Average pace: \(fmtPace(p)).")) }

    // Time.
    let hours = (s.liftMinutes + s.runMinutes) / 60
    if hours >= 2 {
        out.append(Fact(kind: .time, text: "\(Int(hours.rounded())) hours trained. About \(Int((hours / 2).rounded())) movies' worth."))
    }
    if hours >= FactRefs.lotrExtendedHours {
        out.append(Fact(kind: .time, text: "Enough time to watch the extended Lord of the Rings trilogy \(n(hours / FactRefs.lotrExtendedHours))×."))
    }
    if let avg = s.avgWorkoutMinutes { out.append(Fact(kind: .time, text: "Average workout: \(Int(avg.rounded())) min.")) }
    if let e = s.earliestStart { out.append(Fact(kind: .time, text: "Earliest start: \(clock(e)).")) }
    if let l = s.latestStart, l != s.earliestStart { out.append(Fact(kind: .time, text: "Latest start: \(clock(l)).")) }

    // You.
    if let first = s.firstDate {
        let days = DateKey.calendar.dateComponents([.day], from: DateKey.date(first), to: Date()).day ?? 0
        if days >= 1 { out.append(Fact(kind: .you, text: "First logged workout: \(day(first)). \(days) days ago.")) }
    }
    if s.daysTrained >= 2 { out.append(Fact(kind: .you, text: "You've trained on \(s.daysTrained) different days.")) }
    if let d = s.favoriteDay, s.favoriteDayCount >= 3 {
        out.append(Fact(kind: .you, text: "\(d.label) is your day: \(s.favoriteDayCount) workouts."))
    }
    if s.daysTrained >= 5 {
        let pct = Int((Double(s.weekendDays) / Double(s.daysTrained) * 100).rounded())
        out.append(Fact(kind: .you, text: "\(pct)% of your training days are weekends."))
    }
    return out
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
