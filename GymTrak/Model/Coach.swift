import Foundation

// The coach: reads what you actually did and suggests what to aim for next.
// Nothing here is pre-planned — every target comes from your last sessions and runs.
//
// Lifts use double progression: hit every rep → add one increment; crush it → add two;
// just miss → same weight, get the reps; miss twice → back off ~5% and rebuild.
// Runs grow ~10% at a time while heart rate stays in zone, and hold when it doesn't.

enum Coach {
    /// Turn auto-apply off in Settings to only see the suggestion.
    static var autoApply: Bool {
        get { UserDefaults.standard.object(forKey: "gt_coach_auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gt_coach_auto") }
    }
}

// MARK: - Lifts

struct LiftAdvice: Equatable {
    enum Kind: Equatable { case new, push, reps, hold, backoff, deload }
    var kind: Kind
    /// Load change in the exercise's increments (+1 = one increment heavier).
    var steps: Int
    /// "230 lb × 6"
    var target: String
    /// "225–235 lb", or a rep range when the weight stays put.
    var range: String?
    /// One short reason.
    var why: String
    /// "↑ 4% in 3 sessions"
    var trend: String?
    /// Rep goal per set — the reps you were going for last time, so a missed set doesn't lower the bar.
    var reps: [Int]? = nil
    /// Per-set targets ("230 lb × 6"), filled in by `liftAdvice`.
    var sets: [String] = []
    /// Show `why` in the UI. Only when it changes what you do; the arrow and target cover the rest.
    var explain = false

    /// The one-line reason, or nil when the arrow and target already say it.
    var note: String? { explain ? why : nil }

    func target(forSet i: Int) -> String { sets.indices.contains(i) ? sets[i] : target }

    var icon: String {
        switch kind {
        case .new: "sparkles"
        case .push: "arrow.up.circle.fill"
        case .reps, .hold: "equal.circle.fill"
        case .backoff, .deload: "arrow.down.circle.fill"
        }
    }
}

/// One past session's working sets for an exercise.
struct LiftPerformance {
    struct Done { var weight: String; var score: Double?; var reps: Int; var target: Int }
    var date: String
    var deload: Bool
    var sets: [Done]
}

/// Rough single number for comparing loads of one type (plates count ~45 lb each).
func loadScore(_ raw: String, type: LoadType) -> Double? {
    let p = parseLoad(raw, type: type)
    switch type {
    case .weight, .dumbbell: return p.n
    case .machine: return p.max ? 10_000 + (p.add ?? 0) : p.n
    case .plates: return p.n.map { $0 * 45 + (p.add ?? 0) }
    case .bodyweight: return p.add ?? 0
    case .free: return nil
    }
}

/// The coach's jump size: 5–10 lb on pound-read machines, otherwise the exercise's increment.
/// Never more than 5 lb at a time.
func coachIncrement(_ ex: Exercise, _ raw: String) -> Double {
    let type = ex.effectiveLoadType
    if type == .plates { return 5 }
    if type == .machine && !parseLoad(raw, type: .machine).lb { return ex.loadIncrement ?? 1 } // pins
    return min(ex.loadIncrement ?? 5, 5)
}

/// Move a load by `steps` coach jumps. Plate loads move 5 lb at a time ("4 pl + 40" → "5 pl").
func coachShift(_ raw: String, ex: Exercise, steps: Int) -> String {
    let type = ex.effectiveLoadType
    guard steps != 0 else { return raw }
    if type == .plates, ex.loadIncrement == nil {
        var p = parseLoad(raw, type: .plates)
        guard let n = p.n else { return raw }
        let total = max(0, n * 45 + (p.add ?? 0) + Double(steps) * 5)
        let plates = (total / 45).rounded(.down)
        let rest = total - plates * 45
        p.n = plates
        p.add = rest == 0 ? nil : rest
        return formatLoad(p)
    }
    return shiftLoad(raw, type: type, increment: coachIncrement(ex, raw), steps: steps)
}

/// Apply `steps` increments to a load string (no change for free-text loads).
func shiftLoad(_ raw: String, type: LoadType, increment: Double, steps: Int) -> String {
    guard steps != 0 else { return raw }
    var w = raw
    for _ in 0..<abs(steps) {
        guard let next = stepLoad(w, type: type, increment: increment, direction: steps > 0 ? 1 : -1) else { return raw }
        w = next
    }
    return w
}

extension Snapshot {
    /// Finished sessions with done sets for this exercise, newest first.
    func liftHistory(for ex: Exercise, before: String? = nil, limit: Int = 4) -> [LiftPerformance] {
        let name = ex.name.lowercased()
        let type = ex.effectiveLoadType
        let finished = sessions
            .filter { $0.finishedAt != nil && !$0.isDeleted && !$0.isRun && (before == nil || $0.slotDate < before!) }
            .sorted { ($0.finishedAt ?? 0) > ($1.finishedAt ?? 0) }
        var out: [LiftPerformance] = []
        for s in finished {
            let done = sets
                .filter { $0.sessionId == s.id && $0.isDone && ($0.exerciseId == ex.id || $0.exerciseName.lowercased() == name) }
                .sorted { $0.setIndex < $1.setIndex }
                .compactMap { st -> LiftPerformance.Done? in
                    guard let reps = numericReps(st.reps).map(Int.init) else { return nil }
                    let target = numericReps(st.targetReps ?? st.reps).map(Int.init) ?? reps
                    return .init(weight: st.weight, score: loadScore(st.weight, type: type), reps: reps, target: target)
                }
            if !done.isEmpty { out.append(LiftPerformance(date: s.slotDate, deload: s.deload ?? false, sets: done)) }
            if out.count == limit { break }
        }
        return out
    }

    /// Exercises in this session whose top set beats every earlier session.
    /// Needs at least one earlier score to count as a PR.
    func prs(sessionId: String) -> [(Exercise, before: Double, now: Double)] {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return [] }
        var out: [(Exercise, before: Double, now: Double)] = []
        for ex in exercises {
            let type = ex.effectiveLoadType
            let now = sets
                .filter { $0.sessionId == sessionId && $0.isDone && $0.exerciseId == ex.id }
                .compactMap { loadScore($0.weight, type: type) }
                .max()
            guard let now else { continue }
            let before = liftHistory(for: ex, before: session.slotDate, limit: .max)
                .flatMap { $0.sets.compactMap(\.score) }
                .max()
            guard let before, now > before else { continue }
            out.append((ex, before: before, now: now))
        }
        return out
    }

    /// What to aim for next time on this exercise.
    func liftAdvice(for ex: Exercise, deload: Bool = false, today: String = DateKey.key(Date())) -> LiftAdvice {
        var a = rawLiftAdvice(for: ex, deload: deload, today: today)
        a.sets = ex.rows.enumerated().map { i, row in
            let w = coachShift(row.weight, ex: ex, steps: a.steps)
            let r = a.reps.map { String($0[min(i, $0.count - 1)]) } ?? bareReps(row.reps)
            return [w.isEmpty ? nil : w, r.isEmpty ? nil : r].compactMap { $0 }.joined(separator: " × ")
        }
        return a
    }

    private func rawLiftAdvice(for ex: Exercise, deload: Bool, today: String) -> LiftAdvice {
        let type = ex.effectiveLoadType
        let rows = ex.rows
        let base = rows.first ?? SetRow(weight: "", reps: "")
        let inc = coachIncrement(ex, base.weight)
        let incScore = inc
        let history = liftHistory(for: ex, before: nil, limit: 6)
        // Only compare against sessions on the same setup: a big jump in load means a new machine.
        let (real, switched) = sameSetup(history.filter { !$0.deload })
        let baseReps = real.first?.sets.first?.target ?? numericReps(base.reps).map(Int.init)
        let goals = real.first.map { last in rows.indices.map { i in last.sets[min(i, last.sets.count - 1)].target } }

        func load(_ steps: Int) -> String { coachShift(base.weight, ex: ex, steps: steps) }
        func target(_ steps: Int, reps: Int? = baseReps) -> String {
            let w = load(steps)
            let r = reps.map(String.init) ?? bareReps(base.reps)
            return [w.isEmpty ? nil : w, r.isEmpty ? nil : r].compactMap { $0 }.joined(separator: " × ")
        }
        func loadRange(_ lo: Int, _ hi: Int) -> String? {
            guard lo != hi, type != .free else { return nil }
            let a = load(lo), b = load(hi)
            if a.hasSuffix(" lb"), b.hasSuffix(" lb") { return "\(a.dropLast(3))–\(b)" }
            return "\(a) to \(b)"
        }
        func repRange(_ lo: Int?, _ hi: Int?) -> String? {
            guard let lo, let hi, lo != hi else { return nil }
            return "\(lo)–\(hi) reps"
        }
        /// Increments that make up `pct` of the top set (at least one).
        func pctSteps(_ pct: Double, score: Double?) -> Int {
            guard let score, score > 0, score < 10_000 else { return 1 }
            return max(1, Int((score * pct / incScore).rounded()))
        }

        let trend = trendText(real)

        if deload {
            let s = -pctSteps(0.1, score: real.first?.sets.first?.score ?? loadScore(base.weight, type: type))
            let hi = min(-1, s / 2)
            return LiftAdvice(kind: .deload, steps: s, target: target(s), range: loadRange(s, hi),
                              why: "Deload week. Light and crisp.", trend: trend, reps: goals)
        }
        guard let last = real.first else {
            return LiftAdvice(kind: .new, steps: 0, target: target(0), range: repRange(baseReps, baseReps.map { $0 + 2 }),
                              why: "First time. Find a solid set.", trend: nil, explain: true)
        }

        let gap = DateKey.calendar.dateComponents([.day], from: DateKey.date(last.date), to: DateKey.date(today)).day ?? 0
        let top = last.sets[0]
        let hitAll = last.sets.allSatisfy { $0.reps >= $0.target }
        let missedSets = last.sets.filter { $0.reps < $0.target }.count

        if gap > 14 {
            return LiftAdvice(kind: .hold, steps: 0, target: target(0), range: loadRange(-1, 0),
                              why: "\(gap) days off. Match last time.", trend: trend, reps: goals, explain: true)
        }
        // Working back up after a dip: one step at a time toward a weight you've already hit.
        if hitAll, let cur = top.score, cur < 10_000,
           let best = real.dropFirst().filter({ $0.sets.allSatisfy { $0.reps >= $0.target } })
            .compactMap({ $0.sets.first?.score }).filter({ $0 < 10_000 }).max(),
           best > cur {
            return LiftAdvice(kind: .push, steps: 1, target: target(1), range: loadRange(0, 1),
                              why: "Working back up. Add \(incLabel(type, inc)).", trend: trend, reps: goals)
        }
        if switched {
            return LiftAdvice(kind: .hold, steps: 0, target: target(0), range: nil,
                              why: "New setup. Repeat it, then build.", trend: nil, reps: goals, explain: true)
        }
        // Add weight only after two clean sessions in a row at this weight.
        let prev = real.dropFirst().first
        let cleanTwice = hitAll && prev.map { p in
            p.sets.allSatisfy { $0.reps >= $0.target } && p.sets.first?.score == top.score
        } == true
        if cleanTwice {
            return LiftAdvice(kind: .push, steps: 1, target: target(1), range: loadRange(0, 1),
                              why: "Clean twice. Add \(incLabel(type, inc)).", trend: trend, reps: goals)
        }
        if hitAll {
            return LiftAdvice(kind: .hold, steps: 0, target: target(0), range: nil,
                              why: "Hit it. Once more, then add \(incLabel(type, inc)).", trend: trend, reps: goals)
        }
        // Missed something. Twice in a row at this weight or heavier → back off.
        if let prev = real.dropFirst().first, prev.sets.contains(where: { $0.reps < $0.target }),
           let a = top.score, let b = prev.sets.first?.score, a >= b {
            let s = -pctSteps(0.05, score: top.score)
            return LiftAdvice(kind: .backoff, steps: s, target: target(s), range: loadRange(s, 0),
                              why: "Missed twice. Drop a bit.", trend: trend, reps: goals, explain: true)
        }
        if top.target - top.reps <= 1 && missedSets * 2 <= last.sets.count + 1 {
            return LiftAdvice(kind: .reps, steps: 0, target: target(0, reps: top.target),
                              range: repRange(top.reps, top.target),
                              why: "So close. Same weight, every rep.", trend: trend, reps: goals)
        }
        return LiftAdvice(kind: .hold, steps: 0, target: target(0), range: loadRange(-1, 0),
                          why: "Tough day last time. Repeat it.", trend: trend, reps: goals)
    }

    /// Mid-workout nudge: after a set, should the next one go up or down?
    func liveTip(sessionId: String, ex: Exercise) -> (text: String, steps: Int, setIds: [String])? {
        let mine = sets.filter { $0.sessionId == sessionId && $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }
        guard let lastDone = mine.last(where: \.isDone),
              let next = mine.first(where: { !$0.isDone && $0.setIndex > lastDone.setIndex }),
              let reps = numericReps(lastDone.reps), let target = numericReps(lastDone.targetReps ?? lastDone.reps)
        else { return nil }
        let type = ex.effectiveLoadType
        guard type != .free, let doneScore = loadScore(lastDone.weight, type: type),
              let nextScore = loadScore(next.weight, type: type) else { return nil }
        let remaining = mine.filter { !$0.isDone && $0.setIndex > lastDone.setIndex }.map(\.id)
        let delta = Int(reps - target)
        if delta >= 2 && nextScore <= doneScore {
            return ("+\(delta) reps. Add \(incLabel(type, coachIncrement(ex, next.weight)))?", 1, remaining)
        }
        if delta <= -2 && nextScore >= doneScore {
            return ("Short \(-delta) reps. Drop \(incLabel(type, coachIncrement(ex, next.weight)))?", -1, remaining)
        }
        return nil
    }

    /// Start-of-workout: set this session's loads and reps to the coach's targets.
    mutating func applyCoach(sessionId: String, ex: Exercise, advice: LiftAdvice, now: EpochMs = nowMs()) {
        let mine = sets.indices.filter { sets[$0].sessionId == sessionId && sets[$0].exerciseId == ex.id }
            .sorted { sets[$0].setIndex < sets[$1].setIndex }
        for (n, i) in mine.enumerated() {
            let w = coachShift(sets[i].weight, ex: ex, steps: advice.steps)
            sets[i].weight = w
            sets[i].targetWeight = w
            sets[i].weightNum = numericLoad(w)
            if let goals = advice.reps, !goals.isEmpty {
                let r = "× \(goals[min(n, goals.count - 1)])"
                sets[i].reps = r
                sets[i].targetReps = r
                sets[i].repsNum = numericReps(r)
            }
            sets[i].updatedAt = now
        }
    }

    /// Apply coached loads to a session's not-yet-done sets of one exercise.
    mutating func shiftSets(_ ids: [String], ex: Exercise, steps: Int, now: EpochMs = nowMs()) {
        for id in ids {
            guard let i = sets.firstIndex(where: { $0.id == id }) else { continue }
            let w = coachShift(sets[i].weight, ex: ex, steps: steps)
            sets[i].weight = w
            sets[i].targetWeight = w
            sets[i].weightNum = numericLoad(w)
            sets[i].updatedAt = now
        }
    }

    /// Newest run of sessions on the same setup. A top-set change over ~30% between sessions marks a switch.
    private func sameSetup(_ history: [LiftPerformance]) -> ([LiftPerformance], switched: Bool) {
        guard var prev = history.first else { return ([], false) }
        var out = [prev]
        for p in history.dropFirst() {
            if let a = prev.sets.first?.score, let b = p.sets.first?.score, a > 0, b > 0, a < 10_000, b < 10_000,
               max(a, b) / min(a, b) > 1.3 {
                return (out, out.count == 1)
            }
            out.append(p)
            prev = p
        }
        return (out, false)
    }

    private func trendText(_ history: [LiftPerformance]) -> String? {
        let tops = history.compactMap { p -> Double? in
            guard let s = p.sets.first?.score, s > 0, s < 10_000 else { return nil }
            return s * (1 + Double(p.sets[0].reps) / 30) // Epley estimated max
        }
        guard tops.count >= 3, let newest = tops.first, let oldest = tops.last, oldest > 0 else { return nil }
        let pct = Int(((newest / oldest - 1) * 100).rounded())
        if pct == 0 { return "Flat for \(tops.count) sessions" }
        return "\(pct > 0 ? "↑" : "↓") \(abs(pct))% in \(tops.count) sessions"
    }
}

func incLabel(_ type: LoadType, _ inc: Double) -> String {
    switch type {
    case .machine where inc <= 2: inc == 1 ? "a pin" : "\(fmtNum(inc)) pins"
    default: "\(fmtNum(inc)) lb"
    }
}

// MARK: - Runs

struct RunAdvice: Equatable {
    /// "40 min"
    var target: String
    var range: String?
    /// "10:40–11:00 /mi"
    var pace: String?
    var why: String
    /// Up to three short how-to lines.
    var cues: [String]
    /// Show `why` only when it changes the run (heart rate ran high last time).
    var explain = false
    var note: String? { explain ? why : nil }
}

enum RunCoach {
    /// What to aim for on a planned run, from the runs Apple Health already logged.
    static func advice(_ rx: RunPrescription, date: String, deload: Bool = false,
                       schedule: ProgramWeek?, runs: [RunActivity]) -> RunAdvice {
        let past = runs.filter { $0.date < date && $0.minutes >= 8 }.sorted { $0.start > $1.start }
        let labeled = past.map { ($0, label(for: $0, schedule: schedule)) }
        let same = labeled.filter { $0.1 == rx.label }.map(\.0).prefix(4)
        let easyRuns = labeled.filter { $0.1.isEasy }.map(\.0).prefix(6)

        // Easy pace from easy runs that stayed in zone.
        let inZone = easyRuns.filter { $0.miles > 0.3 && ($0.avgHR ?? 0) <= Double(rx.hrZoneMax + 2) }
        let easyPace = inZone.isEmpty ? nil : inZone.map { $0.minutes / $0.miles }.reduce(0, +) / Double(inZone.count)

        // Weekly mileage guard: don't stack more on a week that already jumped.
        let d = DateKey.date(date)
        let thisWeek = past.filter { DateKey.date($0.date) > d.addingTimeInterval(-7 * 86_400) }.map(\.miles).reduce(0, +)
        let lastWeek = past.filter {
            let t = DateKey.date($0.date)
            return t <= d.addingTimeInterval(-7 * 86_400) && t > d.addingTimeInterval(-14 * 86_400)
        }.map(\.miles).reduce(0, +)
        let bigWeek = lastWeek > 0 && thisWeek > lastWeek * 1.2

        var cues: [String] = []

        if rx.label.isEasy {
            cues = []
            if rx.strides { cues.append("Finish with 4 × 20 s strides.") }
            guard let last = same.first else {
                let m = deload ? round5(Double(rx.durationMin) * 0.8) : rx.durationMin
                return RunAdvice(target: "\(m) min", range: "\(max(10, m - 5))–\(m + 5) min",
                                 pace: easyPace.map { paceRange($0, -0.15, 0.15) },
                                 why: past.isEmpty ? "No runs synced yet. Plan's \(rx.durationMin) min." : "First \(rx.label.rawValue.lowercased()) on record.",
                                 cues: cues)
            }
            let hrHigh = (last.avgHR ?? 0) > Double(rx.hrZoneMax + 2)
            let base = last.minutes
            var target: Double
            var why: String
            if deload { target = base * 0.8; why = "Deload week. Shorter, easy." }
            else if hrHigh { target = base; why = "HR ran \(Int(last.avgHR!)) last time. Hold, go slower." }
            else if bigWeek { target = base; why = "Big week already. Hold." }
            else { target = min(base * 1.1, base + 10); why = "Last was \(Int(base.rounded())) min in zone. Add a little." }
            let t = round5(target)
            var pace = easyPace.map { paceRange($0, -0.15, 0.15) }
            if hrHigh, let lp = last.miles > 0.3 ? last.minutes / last.miles : nil { pace = paceRange(lp, 0.25, 0.5) }
            return RunAdvice(target: "\(t) min", range: "\(round5(base))–\(max(t, round5(base)) + 5) min",
                             pace: pace, why: why, cues: cues, explain: hrHigh && !deload)
        }

        // Hard days: keep the plan's structure, set the pace from what you've run.
        let hardPace: Double? = {
            if let last = same.first, last.miles > 0.3 {
                let p = last.minutes / last.miles
                let overCap = (last.avgHR ?? 0) > Double(rx.hrHardCap)
                return overCap ? p : p - 5.0 / 60 // ~5 s/mi faster when HR stayed under the cap
            }
            guard let easyPace else { return nil }
            switch rx.label {
            case .tempo: return easyPace - 1.25
            case .intervals: return easyPace - 2.0
            default: return easyPace - 1.75
            }
        }()
        let m = deload ? round5(Double(rx.durationMin) * 0.8) : rx.durationMin
        switch rx.label {
        case .intervals:
            cues = ["10 min easy warm-up.", "Hard reps, easy jog between.", "Stop if form breaks."]
        case .tempo:
            cues = ["10 min easy first.", "Steady hard: a few words at a time.", "Cap HR \(rx.hrHardCap)."]
        default:
            cues = ["Warm up well.", "Even splits. Kick the last 400 m.", "Cap HR \(rx.hrHardCap)."]
        }
        let why: String
        if deload { why = "Deload week. Ease off." }
        else if let last = same.first { why = "Last: \(last.summary)." }
        else { why = easyPace == nil ? "No runs synced yet. Go by feel." : "Pace set from your easy runs." }
        return RunAdvice(target: "\(m) min", range: nil, pace: hardPace.map { paceRange($0, -0.08, 0.08) }, why: why, cues: cues)
    }

    /// The schedule's run type on that weekday, or a guess from the run's length.
    static func label(for run: RunActivity, schedule: ProgramWeek?) -> RunLabel {
        if let l = schedule?.slot(DateKey.dow(DateKey.date(run.date)))?.run?.label { return l }
        return run.minutes >= 55 ? .long : .easy
    }

    static func round5(_ m: Double) -> Int { max(5, Int((m / 5).rounded()) * 5) }

    /// Pace in min/mi ± offsets (in minutes) → "10:40–11:00 /mi".
    static func paceRange(_ pace: Double, _ lo: Double, _ hi: Double) -> String {
        "\(fmtClock((pace + lo) * 60))–\(fmtClock((pace + hi) * 60)) /mi"
    }
}
