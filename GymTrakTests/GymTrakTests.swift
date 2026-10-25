import Foundation
import Testing
@testable import GymTrak

struct LoadGrammarTests {
    @Test(arguments: [
        ("225 lb", LoadType.weight), ("6 pl", .plates), ("5+25", .plates), ("BW", .bodyweight),
        ("+70", .bodyweight), ("−25", .bodyweight), ("Max", .machine), ("Max + 10", .machine),
        ("12", .machine), ("wtd", .free), ("", .weight),
    ])
    func infersType(raw: String, expected: LoadType) {
        #expect(inferLoadType(raw) == expected)
    }

    @Test(arguments: ["225 lb", "120 lb", "12", "Max", "Max + 10", "6 pl", "5 pl + 25", "BW", "+70", "−25"])
    func canonicalStringsRoundTrip(raw: String) {
        #expect(canonicalLoad(raw) == raw)
    }

    @Test func stepsLoads() {
        #expect(stepLoad("225 lb", type: .weight, increment: 5, direction: 1) == "230 lb")
        #expect(stepLoad("12", type: .machine, increment: 1, direction: -1) == "11")
        #expect(stepLoad("Max", type: .machine, increment: 5, direction: 1) == "Max + 5")
        #expect(stepLoad("4 pl + 25", type: .plates, increment: 1, direction: 1) == "5 pl + 25")
        #expect(stepLoad("BW", type: .bodyweight, increment: 5, direction: -1) == "−5")
        #expect(stepLoad("heavy", type: .free, increment: 5, direction: 1) == nil)
    }

    @Test func summaries() {
        #expect(exerciseSummary([SetRow(weight: "220 lb", reps: "× 6"), SetRow(weight: "220 lb", reps: "× 6")]) == "2 sets of 220 lb × 6")
        #expect(exerciseSummary([SetRow(weight: "220 lb", reps: "× 6"), SetRow(weight: "210 lb", reps: "× 6")]) == "220 lb · 210 lb × 6")
        #expect(exerciseSummary([SetRow(weight: "85 lb", reps: "× 6"), SetRow(weight: "75 lb", reps: "× 9")]) == "85 lb × 6 · 75 lb × 9")
    }

    @Test func numericEquivalents() {
        #expect(numericLoad("225 lb") == 225)
        #expect(numericLoad("Max") == nil)
        #expect(numericReps("× 6") == 6)
        #expect(repsToken("8") == "× 8")
    }
}

struct PlateTests {
    @Test func greedyBreakdown() {
        #expect(plateBreakdown(add: 40) == [35, 5])
        #expect(plateBreakdown(add: 60) == [45, 10, 5])
        #expect(plateBreakdown(add: 2.5) == [2.5])
        #expect(plateBreakdown(add: 0).isEmpty)
    }

    @Test func plateLineOnlyForPlates() {
        #expect(plateLine("4 pl + 40", type: .plates) == "4 × 45 + 35 + 5")
        #expect(plateLine("4 pl", type: .plates) == "4 × 45")
        #expect(plateLine("120 lb", type: .machine) == nil)
        #expect(plateLine("225 lb", type: .weight) == nil)
    }
}

struct ProgramTests {
    let week = ProgramWeek(id: 9, phase: "base", startDate: "2026-08-31", isDeload: false,
                           slots: [ProgramSlot(dow: .mon, liftDayId: 1, run: nil)], updatedAt: 1)

    @Test func datesAreLocalAndMondayBased() {
        #expect(week.date(of: .mon) == "2026-08-31")
        #expect(week.date(of: .fri) == "2026-09-04")
        #expect(DateKey.mondayKey(DateKey.date("2026-09-03")) == "2026-08-31")
        #expect(DateKey.upcomingMonday(DateKey.date("2026-08-31")) == "2026-08-31")
        #expect(DateKey.upcomingMonday(DateKey.date("2026-09-01")) == "2026-09-07")
        #expect(slotSummary(week.slots[0], dayName: "Upper A") == "Upper A")
    }

    @Test func seedBuildsTheSplitAndRunBlock() {
        let snap = seedSnapshot(today: DateKey.date("2026-10-25"))
        #expect(snap.days.map(\.name) == ["Upper A", "Lower A", "Upper B", "Lower B"])
        #expect(snap.weeks.count == 8)
        #expect(snap.weeks.first?.startDate == "2026-10-26")
        #expect(snap.weeks.filter(\.isDeload).map(\.id) == [4, 8])
    }

    @Test func duplicatesWeekAfterTheLast() {
        var snap = Snapshot(programWeeks: [week])
        #expect(snap.duplicateProgramWeek(9) == 10)
        #expect(snap.weeks.last?.startDate == "2026-09-07")
        #expect(snap.weeks.last?.slots == week.slots)
    }
}

struct SessionTests {
    func fixture() -> (Snapshot, Day) {
        let day = Day(id: 1, order: 1, name: "Upper A", focus: "Press", updatedAt: 0)
        let ex = Exercise(id: "press", dayId: 1, order: 1, name: "Press", sets: 2, weight: "100 lb", reps: "× 5",
                          setRows: [SetRow(weight: "100 lb", reps: "× 5"), SetRow(weight: "90 lb", reps: "× 6")],
                          loadType: .weight, updatedAt: 0)
        return (Snapshot(days: [day], exercises: [ex], programWeeks: []), day)
    }

    @Test func carriesOnlyCompletedWorkForward() {
        var (snap, day) = fixture()
        let id = snap.startSession(day: day, options: StartOptions(weekNumber: 9, scheduledDate: "2026-09-01"))
        let sets = snap.sets(of: id).sorted { $0.setIndex < $1.setIndex }
        snap.updateSetLoad(sets[0].id, weight: "105 lb", reps: "× 5")
        snap.toggleSet(sets[0].id)
        snap.updateSetLoad(sets[1].id, weight: "500 lb", reps: "× 6") // never ticked
        snap.finishSession(id)

        let session = snap.sessions.first { $0.id == id }!
        #expect(session.scheduledDate == "2026-09-01")
        #expect(session.dayNameSnapshot == "Upper A")
        #expect(session.finishedAt != nil)
        #expect(snap.exercises[0].setRows == [SetRow(weight: "105 lb", reps: "× 5"), SetRow(weight: "90 lb", reps: "× 6")])
        #expect(snap.sets(of: id).count == 2)
    }

    @Test func reopenKeepsUnfinishedRows() {
        var (snap, day) = fixture()
        let id = snap.startSession(day: day)
        snap.finishSession(id)
        snap.reopenSession(id)
        #expect(snap.sessions.first?.finishedAt == nil)
        #expect(snap.sets(of: id).count == 2)
    }

    @Test func resumesSameDayAndDiscardsOthers() {
        var (snap, day) = fixture()
        let a = snap.startSession(day: day, options: StartOptions(scheduledDate: "2026-09-01"))
        #expect(snap.startSession(day: day, options: StartOptions(scheduledDate: "2026-09-01")) == a)
        let b = snap.startSession(day: day, options: StartOptions(scheduledDate: "2026-09-02"))
        #expect(b != a)
        #expect(snap.sessions.map(\.id) == [b])
    }

    @Test func deloadDropsLastSetOnlyFromThreePlus() {
        var (snap, day) = fixture()
        snap.setRows("press", [SetRow(weight: "1", reps: "× 1"), SetRow(weight: "2", reps: "× 1"), SetRow(weight: "3", reps: "× 1")])
        let id = snap.startSession(day: day, options: StartOptions(deload: true))
        #expect(snap.sets(of: id).count == 2)
        snap.finishSession(id)
        #expect(snap.exercises[0].setRows?.count == 3) // the plan keeps its third set
    }

    @Test func snapshotJSONRoundTripsWithExplicitNulls() throws {
        var (snap, day) = fixture()
        snap.startSession(day: day)
        let data = try JSONEncoder().encode(snap)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"finishedAt\":null"))
        #expect(json.contains("\"completedAt\":null"))
        let back = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(back.sessions == snap.sessions)
        #expect(back.sets == snap.sets)
    }
}

struct CoachTests {
    let bench = Exercise(id: "b", dayId: 1, order: 0, name: "Bench", sets: 2, weight: "200 lb", reps: "× 6",
                         setRows: [SetRow(weight: "200 lb", reps: "× 6"), SetRow(weight: "200 lb", reps: "× 6")],
                         loadType: .weight, updatedAt: 0)

    /// A snapshot with finished sessions; each entry is the reps done per set (target 6 at 200 lb).
    func db(_ history: [[Int]], start: String = "2026-10-01", weight: String = "200 lb") -> Snapshot {
        var s = Snapshot(days: [Day(id: 1, name: "Upper", focus: "")], exercises: [bench], programWeeks: [])
        for (n, reps) in history.enumerated() {
            let id = "s\(n)"
            let date = DateKey.addDays(start, n * 3)
            s.sessions.append(Session(id: id, dayId: 1, date: date, startedAt: Double(n) * 1e6,
                                      finishedAt: Double(n) * 1e6 + 1, updatedAt: 0, type: .lift))
            for (i, r) in reps.enumerated() {
                s.sets.append(WorkoutSet(id: "\(id)-\(i)", sessionId: id, exerciseId: "b", exerciseName: "Bench", setIndex: i,
                                         weight: weight, reps: "× \(r)", targetWeight: weight, targetReps: "× 6",
                                         completedAt: 1, updatedAt: 0))
            }
        }
        return s
    }

    var today: String { "2026-10-20" }

    @Test func prsNeedAHeavierTopSetThanEverBefore() {
        var heavier = db([[6, 6], [6, 6]], start: "2026-10-01")
        for i in heavier.sets.indices where heavier.sets[i].sessionId == "s1" { heavier.sets[i].weight = "205 lb" }
        let prs = heavier.prs(sessionId: "s1")
        #expect(prs.count == 1)
        #expect(prs.first?.before == 200 && prs.first?.now == 205)

        let same = db([[6, 6], [6, 6]], start: "2026-10-01")
        #expect(same.prs(sessionId: "s1").isEmpty)
        #expect(same.prs(sessionId: "s0").isEmpty) // first session has nothing to beat
    }

    @Test func historyChartSkipsPinMachinesAndKeepsOrder() {
        let history = [
            LiftPerformance(date: "2026-10-01", deload: false, sets: [.init(weight: "200 lb", score: 200, reps: 6, target: 6)]),
            LiftPerformance(date: "2026-10-08", deload: false, sets: [.init(weight: "Max", score: 10_000, reps: 8, target: 8)]),
            LiftPerformance(date: "2026-10-15", deload: false, sets: [.init(weight: "205 lb", score: 205, reps: 6, target: 6)]),
        ]
        let points = ExerciseHistory.points(history)
        #expect(points.map(\.load) == [200, 205])
        #expect(points.first.map { DateKey.key($0.date) } == "2026-10-01")
    }

    @Test func noHistoryKeepsWeight() {
        let a = db([]).liftAdvice(for: bench, today: today)
        #expect(a.kind == .new && a.steps == 0 && a.target == "200 lb × 6")
    }

    @Test func oneCleanSessionRepeats() {
        let a = db([[8, 6]], start: "2026-10-18").liftAdvice(for: bench, today: today)
        #expect(a.kind == .hold && a.target == "200 lb × 6")
    }

    @Test func twoCleanSessionsAddFive() {
        let a = db([[6, 6], [7, 6]], start: "2026-10-15").liftAdvice(for: bench, today: today)
        #expect(a.kind == .push && a.target == "205 lb × 6" && a.range == "200–205 lb")
    }

    @Test func nearMissHoldsAndRestoresRepGoal() {
        let a = db([[6, 5]], start: "2026-10-18").liftAdvice(for: bench, today: today)
        #expect(a.kind == .reps && a.steps == 0 && a.reps == [6, 6])
    }

    @Test func missingTwiceBacksOff() {
        let a = db([[4, 4], [4, 3]], start: "2026-10-15").liftAdvice(for: bench, today: today)
        #expect(a.kind == .backoff && a.steps == -2 && a.target == "190 lb × 6")
    }

    @Test func deloadDropsAboutTenPercent() {
        let a = db([[6, 6]], start: "2026-10-18").liftAdvice(for: bench, deload: true, today: today)
        #expect(a.kind == .deload && a.target == "180 lb × 6")
    }

    @Test func longBreakHolds() {
        let a = db([[6, 6]], start: "2026-09-01").liftAdvice(for: bench, today: today)
        #expect(a.kind == .hold && a.steps == 0)
    }

    @Test func startAppliesCoachTargets() {
        var s = db([[6, 6], [6, 6]], start: "2026-10-15")
        s.exercises[0].setRows = [SetRow(weight: "200 lb", reps: "× 6"), SetRow(weight: "200 lb", reps: "× 6")]
        let id = s.startSession(day: s.days[0], options: StartOptions(scheduledDate: today, coach: true))
        #expect(s.sets(of: id).map(\.weight) == ["205 lb", "205 lb"])
    }

    @Test func liveTipSuggestsAddingAfterEasySet() {
        var s = db([])
        let id = s.startSession(day: s.days[0])
        let first = s.sets(of: id).sorted { $0.setIndex < $1.setIndex }[0]
        s.updateSetLoad(first.id, weight: "200 lb", reps: "× 8")
        s.toggleSet(first.id)
        let tip = s.liveTip(sessionId: id, ex: bench)
        #expect(tip?.steps == 1)
        s.shiftSets(tip!.setIds, ex: bench, steps: 1)
        #expect(s.liveTip(sessionId: id, ex: bench) == nil) // applied — no repeat nudge
    }

    @Test func coachJumpsAreRealistic() {
        let plates = Exercise(id: "p", dayId: 1, order: 0, name: "Press", sets: 1, weight: "4 pl + 35", reps: "× 5",
                              loadType: .plates, updatedAt: 0)
        #expect(coachShift("4 pl + 40", ex: plates, steps: 1) == "5 pl")
        #expect(coachShift("5 pl", ex: plates, steps: -1) == "4 pl + 40")
        let stack = Exercise(id: "m", dayId: 1, order: 0, name: "Pec Dec", sets: 1, weight: "210 lb", reps: "× 6",
                             loadType: .machine, updatedAt: 0)
        #expect(coachShift("210 lb", ex: stack, steps: 1) == "215 lb")
        #expect(coachShift("14", ex: stack, steps: 1) == "15")
    }

    /// Sessions given as (weight, reps per set), oldest first.
    func dbW(_ history: [(String, [Int])], start: String = "2026-10-10") -> Snapshot {
        var s = db([])
        for (n, (w, reps)) in history.enumerated() {
            let one = db([reps], start: DateKey.addDays(start, n * 3), weight: w)
            var sess = one.sessions[0]; sess.id = "w\(n)"; sess.startedAt = Double(n) * 1e6; sess.finishedAt = Double(n) * 1e6 + 1
            s.sessions.append(sess)
            s.sets += one.sets.map { var x = $0; x.id = "w\(n)-\(x.setIndex)"; x.sessionId = sess.id; return x }
        }
        s.exercises[0].setRows = [SetRow(weight: history.last!.0, reps: "× 6"), SetRow(weight: history.last!.0, reps: "× 6")]
        return s
    }

    @Test func dipThenBackToBest() {
        // 135 → 125 (nailed it) → work back up 5 lb at a time.
        let s = dbW([("135 lb", [6, 6]), ("125 lb", [6, 6])])
        let a = s.liftAdvice(for: s.exercises[0], today: today)
        #expect(a.target == "130 lb × 6" && a.why.contains("Working back"))
    }

    @Test func machineSwitchStartsFresh() {
        // 200 lb, missed twice… then a new machine at 90 lb: no "missed twice" back-off from old history.
        let s = dbW([("200 lb", [4, 4]), ("200 lb", [4, 3]), ("90 lb", [5, 6])])
        let a = s.liftAdvice(for: s.exercises[0], today: today)
        #expect(a.kind == .hold && a.target == "90 lb × 6" && a.why.contains("New setup"))
        let b = dbW([("200 lb", [6, 6]), ("90 lb", [6, 6]), ("90 lb", [6, 6])])
        #expect(b.liftAdvice(for: b.exercises[0], today: today).target == "95 lb × 6")
    }

    @Test func runAdviceWithoutDataUsesPlan() {
        let rx = makeRun(.easy, minutes: 30, timing: .standalone)
        let a = RunCoach.advice(rx, date: today, deload: false, schedule: nil, runs: [])
        #expect(a.target == "30 min" && a.range == "25–35 min")
    }

    @Test func runAdviceGrowsWhenHeartRateStayedInZone() {
        let rx = makeRun(.easy, minutes: 30, timing: .standalone)
        let last = RunActivity(id: "r", source: .strava, name: "Run", date: "2026-10-18", start: DateKey.date("2026-10-18"),
                               minutes: 40, miles: 4, avgHR: Double(rx.hrZoneMax - 5))
        let a = RunCoach.advice(rx, date: today, deload: false, schedule: nil, runs: [last])
        #expect(a.target == "45 min" && a.pace == "9:51–10:09 /mi")
    }

    @Test func runAdviceHoldsWhenHeartRateRanHigh() {
        let rx = makeRun(.easy, minutes: 30, timing: .standalone)
        let last = RunActivity(id: "r", source: .strava, name: "Run", date: "2026-10-18", start: DateKey.date("2026-10-18"),
                               minutes: 40, miles: 4, avgHR: Double(rx.hrZoneMax + 15))
        let a = RunCoach.advice(rx, date: today, deload: false, schedule: nil, runs: [last])
        #expect(a.target == "40 min" && a.pace == "10:15–10:30 /mi")
    }
}
