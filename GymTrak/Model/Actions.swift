import Foundation

// Every change to the database, as pure mutations on a Snapshot. The Store calls
// these, then saves and syncs. Keeping them pure makes them easy to test.

/// Open sessions older than this are abandoned, not resumed.
let resumeWindowMs: EpochMs = 6 * 60 * 60 * 1000

struct StartOptions {
    var deload = false
    var weekNumber: Int? = nil
    var scheduledDate: String? = nil
}

extension Snapshot {
    // MARK: Lookups

    var activeDays: [Day] { days.filter { !$0.isArchived }.sorted { $0.rank < $1.rank } }
    var sortedDays: [Day] { days.sorted { $0.rank < $1.rank } }
    var weeks: [ProgramWeek] { (programWeeks ?? []).sorted { $0.id < $1.id } }

    func day(_ id: Int?) -> Day? { id.flatMap { id in days.first { $0.id == id } } }

    func exercises(of dayId: Int) -> [Exercise] {
        exercises.filter { $0.dayId == dayId }.sorted { $0.order < $1.order }
    }

    func sets(of sessionId: String) -> [WorkoutSet] {
        sets.filter { $0.sessionId == sessionId }
    }

    /// The single recent, still-open lift session, if any.
    func openLift(now: EpochMs = nowMs()) -> Session? {
        sessions.first { $0.isOpen && !$0.isRun && now - $0.startedAt < resumeWindowMs }
    }

    /// Dates that have a finished lift.
    var doneDates: Set<String> {
        Set(sessions.filter { $0.finishedAt != nil && !$0.isDeleted && !$0.isRun }.map(\.slotDate))
    }

    private func newSets(for ex: Exercise, rows: [SetRow], sessionId: String, now: EpochMs) -> [WorkoutSet] {
        rows.enumerated().map { i, row in
            WorkoutSet(id: newID(), sessionId: sessionId, exerciseId: ex.id, exerciseName: ex.name, setIndex: i,
                       weight: row.weight, reps: row.reps, targetWeight: row.weight, targetReps: row.reps,
                       weightNum: numericLoad(row.weight), repsNum: numericReps(row.reps),
                       completedAt: nil, updatedAt: now)
        }
    }

    // MARK: Sessions

    /// Start (or resume) a lift session for `day`. Stale or other open sessions are discarded.
    @discardableResult
    mutating func startSession(day: Day, options: StartOptions = .init(), now: EpochMs = nowMs()) -> String {
        let scheduled = options.scheduledDate ?? DateKey.key(Date(timeIntervalSince1970: now / 1000))
        let open = sessions.filter(\.isOpen)
        let resumable = open.first {
            $0.dayId == day.id && $0.slotDate == scheduled && now - $0.startedAt < resumeWindowMs
        }
        for s in open where s.id != resumable?.id { discardSession(s.id) }
        if let resumable { return resumable.id }

        let sessionId = newID()
        for ex in exercises(of: day.id) {
            let all = ex.rows
            // Deload drops the last set, but only where there are 3+ to drop from.
            let rows = options.deload && all.count >= 3 ? Array(all.dropLast()) : all
            sets += newSets(for: ex, rows: rows, sessionId: sessionId, now: now)
        }
        sessions.append(Session(
            id: sessionId, dayId: day.id, date: DateKey.key(Date(timeIntervalSince1970: now / 1000)),
            scheduledDate: options.scheduledDate, dayNameSnapshot: day.name, focusSnapshot: day.focus,
            startedAt: now, finishedAt: nil, durationSec: nil, updatedAt: now, type: .lift,
            weekNumber: options.weekNumber, deload: options.deload ? true : nil))
        return sessionId
    }

    /// Toggle a set done/undone. Returns true if it is now done.
    @discardableResult
    mutating func toggleSet(_ id: String, now: EpochMs = nowMs()) -> Bool {
        guard let i = sets.firstIndex(where: { $0.id == id }) else { return false }
        let nowDone = sets[i].completedAt == nil
        sets[i].completedAt = nowDone ? now : nil
        sets[i].updatedAt = now
        return nowDone
    }

    mutating func updateSetLoad(_ id: String, weight: String, reps: String, now: EpochMs = nowMs()) {
        guard let i = sets.firstIndex(where: { $0.id == id }) else { return }
        let w = weight.trimmingCharacters(in: .whitespaces)
        let r = reps.trimmingCharacters(in: .whitespaces)
        sets[i].weight = w
        sets[i].reps = r
        sets[i].weightNum = numericLoad(w)
        sets[i].repsNum = numericReps(r)
        sets[i].updatedAt = now
    }

    mutating func addSetToSession(_ sessionId: String, exerciseId: String, now: EpochMs = nowMs()) {
        let last = sets.filter { $0.sessionId == sessionId && $0.exerciseId == exerciseId }
            .max { $0.setIndex < $1.setIndex }
        let w = last?.weight ?? ""
        let r = last?.reps ?? "× 6"
        sets.append(WorkoutSet(id: newID(), sessionId: sessionId, exerciseId: exerciseId,
                               exerciseName: last?.exerciseName ?? "", setIndex: (last?.setIndex ?? -1) + 1,
                               weight: w, reps: r, targetWeight: w, targetReps: r,
                               weightNum: last.flatMap { numericLoad($0.weight) },
                               repsNum: last.flatMap { numericReps($0.reps) },
                               completedAt: nil, updatedAt: now))
    }

    /// Remove one set; every exercise keeps at least one.
    mutating func removeSet(_ id: String) {
        guard let set = sets.first(where: { $0.id == id }) else { return }
        let siblings = sets.filter { $0.sessionId == set.sessionId && $0.exerciseId == set.exerciseId }
        guard siblings.count > 1 else { return }
        sets.removeAll { $0.id == id }
    }

    /// Add a new exercise to the day mid-workout and seed its sets in this session.
    @discardableResult
    mutating func addExerciseToSession(_ sessionId: String, dayId: Int, now: EpochMs = nowMs()) -> String {
        let id = addExercise(dayId: dayId, now: now)
        if let ex = exercises.first(where: { $0.id == id }) {
            sets += newSets(for: ex, rows: ex.rows, sessionId: sessionId, now: now)
        }
        return id
    }

    mutating func removeExerciseFromSession(_ sessionId: String, exerciseId: String) {
        sets.removeAll { $0.sessionId == sessionId && $0.exerciseId == exerciseId }
        exercises.removeAll { $0.id == exerciseId }
    }

    mutating func discardSession(_ id: String) {
        sets.removeAll { $0.sessionId == id }
        sessions.removeAll { $0.id == id }
    }

    /// Finish a session and carry each exercise's sets back to the Plan as its new loads.
    /// Done sets carry what you did; unticked sets keep their start-of-session target.
    mutating func finishSession(_ id: String, now: EpochMs = nowMs()) {
        guard let si = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[si]
        let byExercise = Dictionary(grouping: sets(of: id), by: \.exerciseId)
        for (exerciseId, exSets) in byExercise {
            let rows = exSets.sorted { $0.setIndex < $1.setIndex }.map { s in
                s.isDone ? SetRow(weight: s.weight, reps: s.reps)
                         : SetRow(weight: s.targetWeight ?? s.weight, reps: s.targetReps ?? s.reps)
            }
            guard !rows.isEmpty, let ei = exercises.firstIndex(where: { $0.id == exerciseId }) else { continue }
            // A deload runs a set short: keep the plan's trailing set(s) so the template doesn't shrink.
            let prev = exercises[ei].setRows ?? []
            let merged = (session.deload ?? false) && prev.count > rows.count ? rows + prev.dropFirst(rows.count) : rows
            exercises[ei].setRows = merged
            exercises[ei].sets = merged.count
            exercises[ei].weight = merged[0].weight
            exercises[ei].reps = merged[0].reps
            exercises[ei].updatedAt = now
        }
        sessions[si].finishedAt = now
        sessions[si].durationSec = ((now - session.startedAt) / 1000).rounded()
        sessions[si].updatedAt = now
    }

    /// Undo a finish (the post-finish "Undo" action).
    mutating func reopenSession(_ id: String, now: EpochMs = nowMs()) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), !sessions[i].isDeleted else { return }
        sessions[i].finishedAt = nil
        sessions[i].durationSec = nil
        sessions[i].updatedAt = now
    }

    // MARK: Days

    mutating func updateDay(_ id: Int, name: String? = nil, focus: String? = nil, now: EpochMs = nowMs()) {
        guard let i = days.firstIndex(where: { $0.id == id }) else { return }
        if let name { days[i].name = name }
        if let focus { days[i].focus = focus }
        days[i].updatedAt = now
    }

    mutating func archiveDay(_ id: Int, _ archived: Bool, now: EpochMs = nowMs()) {
        guard let i = days.firstIndex(where: { $0.id == id }) else { return }
        days[i].archived = archived
        days[i].updatedAt = now
    }

    @discardableResult
    mutating func addDay(now: EpochMs = nowMs()) -> Int {
        let id = (days.map(\.id).max() ?? 0) + 1
        let order = (days.map(\.rank).max() ?? 0) + 1
        days.append(Day(id: id, order: order, name: "New day", focus: "", updatedAt: now))
        return id
    }

    /// Move a day one slot earlier (-1) or later (+1), renumbering every order to 1…n.
    mutating func moveDay(_ id: Int, _ dir: Int, now: EpochMs = nowMs()) {
        var ordered = sortedDays
        guard let idx = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(idx + dir) else { return }
        ordered.swapAt(idx, idx + dir)
        for (i, d) in ordered.enumerated() where d.order != i + 1 {
            if let j = days.firstIndex(where: { $0.id == d.id }) {
                days[j].order = i + 1
                days[j].updatedAt = now
            }
        }
    }

    /// Delete a day and its exercises. Past sessions keep their snapshots.
    mutating func deleteDay(_ id: Int) {
        exercises.removeAll { $0.dayId == id }
        days.removeAll { $0.id == id }
    }

    // MARK: Exercises

    mutating func updateExercise(_ id: String, now: EpochMs = nowMs(), _ change: (inout Exercise) -> Void) {
        guard let i = exercises.firstIndex(where: { $0.id == id }) else { return }
        change(&exercises[i])
        exercises[i].updatedAt = now
    }

    /// Replace an exercise's per-set rows, keeping the first-set fallback fields in step.
    mutating func setRows(_ id: String, _ rows: [SetRow], now: EpochMs = nowMs()) {
        guard !rows.isEmpty else { return }
        updateExercise(id, now: now) {
            $0.setRows = rows
            $0.sets = rows.count
            $0.weight = rows[0].weight
            $0.reps = rows[0].reps
        }
    }

    @discardableResult
    mutating func addExercise(dayId: Int, name: String = "New exercise", now: EpochMs = nowMs()) -> String {
        let order = (exercises.filter { $0.dayId == dayId }.map(\.order).max() ?? 0) + 1
        let id = newID()
        exercises.append(Exercise(id: id, dayId: dayId, order: order, name: name, sets: 2, weight: "",
                                  reps: "× 6", loadType: .weight, updatedAt: now))
        return id
    }

    mutating func deleteExercise(_ id: String) {
        exercises.removeAll { $0.id == id }
    }

    mutating func moveExercise(_ id: String, _ dir: Int, now: EpochMs = nowMs()) {
        guard let ex = exercises.first(where: { $0.id == id }) else { return }
        var siblings = exercises(of: ex.dayId)
        guard let idx = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(idx + dir) else { return }
        siblings.swapAt(idx, idx + dir)
        for (i, e) in siblings.enumerated() where e.order != i + 1 {
            updateExercise(e.id, now: now) { $0.order = i + 1 }
        }
    }

    // MARK: Program

    mutating func updateProgramWeek(_ week: ProgramWeek, now: EpochMs = nowMs()) {
        var w = week
        w.updatedAt = now
        var list = programWeeks ?? []
        if let i = list.firstIndex(where: { $0.id == w.id }) { list[i] = w } else { list.append(w) }
        programWeeks = list
    }

    /// Append a copy of a week after the last one. Returns the new week's id.
    @discardableResult
    mutating func duplicateProgramWeek(_ sourceId: Int, now: EpochMs = nowMs()) -> Int? {
        let list = weeks
        guard let source = list.first(where: { $0.id == sourceId }), let last = list.last else { return nil }
        var copy = source
        copy.id = last.id + 1
        copy.startDate = DateKey.addDays(last.startDate, 7)
        copy.updatedAt = now
        programWeeks = (programWeeks ?? []) + [copy]
        return copy.id
    }

    /// Re-anchor the whole program so week 1 starts on `startMonday`.
    mutating func setProgramStart(_ startMonday: String, now: EpochMs = nowMs()) {
        guard let first = weeks.first?.id else { return }
        programWeeks = (programWeeks ?? []).map { w in
            var w = w
            w.startDate = DateKey.addDays(startMonday, (w.id - first) * 7)
            w.updatedAt = now
            return w
        }
    }
}
