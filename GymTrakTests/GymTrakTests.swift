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

    @Test func finishWithoutLiftingKeepsThePlanUnchanged() {
        var s = db([[6, 6], [6, 6]], start: "2026-10-15")
        s.exercises[0].setRows = [SetRow(weight: "200 lb", reps: "× 6"), SetRow(weight: "200 lb", reps: "× 6")]
        let id = s.startSession(day: s.days[0], options: StartOptions(scheduledDate: today, coach: true))
        #expect(s.sets(of: id).map(\.weight) == ["205 lb", "205 lb"])
        s.finishSession(id) // nothing ticked
        #expect(s.exercises[0].rows.map(\.weight) == ["200 lb", "200 lb"])
        #expect(s.liftAdvice(for: s.exercises[0], today: DateKey.addDays(today, 3)).target.hasPrefix("205"))
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
        #expect(a.target == "130 lb × 6" && a.why.contains("Working back") && a.note == nil)
    }

    @Test func machineSwitchStartsFresh() {
        // 200 lb, missed twice… then a new machine at 90 lb: no "missed twice" back-off from old history.
        let s = dbW([("200 lb", [4, 4]), ("200 lb", [4, 3]), ("90 lb", [5, 6])])
        let a = s.liftAdvice(for: s.exercises[0], today: today)
        #expect(a.kind == .hold && a.target == "90 lb × 6" && a.note?.contains("New setup") == true)
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
        let last = RunActivity(id: "r", source: .health, name: "Run", date: "2026-10-18", start: DateKey.date("2026-10-18"),
                               minutes: 40, miles: 4, avgHR: Double(rx.hrZoneMax - 5))
        let a = RunCoach.advice(rx, date: today, deload: false, schedule: nil, runs: [last])
        #expect(a.target == "45 min" && a.pace == "9:51–10:09 /mi")
    }

    @Test func runAdviceHoldsWhenHeartRateRanHigh() {
        let rx = makeRun(.easy, minutes: 30, timing: .standalone)
        let last = RunActivity(id: "r", source: .health, name: "Run", date: "2026-10-18", start: DateKey.date("2026-10-18"),
                               minutes: 40, miles: 4, avgHR: Double(rx.hrZoneMax + 15))
        let a = RunCoach.advice(rx, date: today, deload: false, schedule: nil, runs: [last])
        #expect(a.target == "40 min" && a.pace == "10:15–10:30 /mi")
    }
}

struct DotTests {
    let today = DateKey.date("2026-10-25")

    /// Mon lift, Wed run, Fri lift, every week from Oct 5 on.
    func planned() -> Snapshot {
        let week = ProgramWeek(id: 1, phase: "base", startDate: "2026-10-05", isDeload: false,
                               slots: [ProgramSlot(dow: .mon, liftDayId: 1, run: nil),
                                       ProgramSlot(dow: .wed, liftDayId: nil, run: makeRun(.easy, minutes: 25, timing: .standalone)),
                                       ProgramSlot(dow: .fri, liftDayId: 1, run: nil)],
                               updatedAt: 0)
        return Snapshot(days: [Day(id: 1, name: "Upper A", focus: "")], programWeeks: [week])
    }

    func finish(_ s: inout Snapshot, _ dates: [String]) {
        for (i, date) in dates.enumerated() {
            s.sessions.append(Session(id: "d\(i)", dayId: 1, date: date, startedAt: 1, finishedAt: 2, updatedAt: 0, type: .lift))
        }
    }

    @Test func finishedDaysShowAsDone() {
        var s = planned()
        finish(&s, ["2026-10-19", "2026-10-21", "2026-10-23"])
        let dots = s.weekDots(ending: today)
        #expect(dots.count == 7)
        #expect(dots.filter { $0.state == .done }.count == 3)
        #expect(dots.first?.date == "2026-10-19" && dots.first?.state == .done)
        #expect(dots.last?.date == "2026-10-25" && dots.last?.state == .rest)
    }

    @Test func unfinishedPastDayIsMissed() {
        var s = planned()
        finish(&s, ["2026-10-19", "2026-10-23"])
        #expect(s.weekDots(ending: today).filter { $0.state == .missed }.map(\.date) == ["2026-10-21"])
    }

    @Test func savingTheScheduleKeepsPastDotsAndStreak() {
        var s = planned()
        finish(&s, ["2026-10-05", "2026-10-07", "2026-10-09", "2026-10-12", "2026-10-14", "2026-10-16", "2026-10-19", "2026-10-23"])
        #expect(s.streakWeeks(today: today) == 2)
        // Editing the schedule moves its startDate to this Monday; history must not turn into rest days.
        s.saveSchedule(s.scheduleTemplate!)
        #expect(s.streakWeeks(today: today) == 2)
        #expect(s.weekDots(ending: today).filter { $0.state == .missed }.map(\.date) == ["2026-10-21"])
    }

    @Test func unfinishedTodayIsUpcoming() {
        var s = planned()
        finish(&s, ["2026-10-19", "2026-10-21"])
        // Friday is today and not logged yet.
        #expect(s.weekDots(ending: DateKey.date("2026-10-23")).last?.state == .upcoming)
    }

    @Test func runsLoggedOutsideSessionsCountAsDone() {
        var s = planned()
        finish(&s, ["2026-10-19", "2026-10-23"])
        let dots = s.weekDots(ending: today, doneExtra: ["2026-10-21"])
        #expect(dots.filter { $0.state == .missed }.isEmpty)
    }

    @Test func streakCountsCleanPastWeeks() {
        var s = planned()
        finish(&s, ["2026-10-05", "2026-10-07", "2026-10-09", "2026-10-12", "2026-10-14", "2026-10-16"])
        // The current week is missed so far, but it does not count until it ends.
        #expect(s.streakWeeks(today: today) == 2)
    }

    @Test func aMissInTheLastWeekStopsTheStreak() {
        var s = planned()
        finish(&s, ["2026-10-05", "2026-10-07", "2026-10-09", "2026-10-12", "2026-10-16"]) // Oct 14 missed
        #expect(s.streakWeeks(today: today) == 0)
    }

    @Test func anOlderMissLeavesOnlyTheWeeksAfterIt() {
        var s = planned()
        finish(&s, ["2026-10-09", "2026-10-12", "2026-10-14", "2026-10-16"]) // Oct 5 and 7 missed
        #expect(s.streakWeeks(today: today) == 1)
    }
}

@Suite struct HistoryTests {
    func snap() -> Snapshot {
        var s = Snapshot(days: [Day(id: 1, name: "Upper A", focus: "")],
                         exercises: [Exercise(id: "b", dayId: 1, order: 0, name: "Bench", sets: 2, weight: "200 lb", reps: "× 6",
                                              loadType: .weight, updatedAt: 0),
                                     Exercise(id: "p", dayId: 1, order: 1, name: "Leg Press", sets: 1, weight: "5 pl + 30", reps: "× 10",
                                              loadType: .plates, updatedAt: 0),
                                     Exercise(id: "c", dayId: 1, order: 2, name: "Curl", sets: 1, weight: "12", reps: "× 8",
                                              loadType: .machine, updatedAt: 0)],
                         programWeeks: [])
        for (n, (date, bench)) in [("2026-10-01", "180 lb"), ("2026-10-08", "190 lb"), ("2026-10-15", "200 lb")].enumerated() {
            let id = "s\(n)"
            s.sessions.append(Session(id: id, dayId: 1, date: date, startedAt: Double(n), finishedAt: Double(n) + 1,
                                      durationSec: 3000, updatedAt: 0, type: .lift))
            s.sets += [
                WorkoutSet(id: "\(id)-b0", sessionId: id, exerciseId: "b", exerciseName: "Bench", setIndex: 0,
                           weight: bench, reps: "× 6", completedAt: 1, updatedAt: 0),
                WorkoutSet(id: "\(id)-b1", sessionId: id, exerciseId: "b", exerciseName: "Bench", setIndex: 1,
                           weight: bench, reps: "× 6", completedAt: 1, updatedAt: 0),
                WorkoutSet(id: "\(id)-p0", sessionId: id, exerciseId: "p", exerciseName: "Leg Press", setIndex: 0,
                           weight: "5 pl + 30", reps: "× 10", completedAt: 1, updatedAt: 0),
                WorkoutSet(id: "\(id)-c0", sessionId: id, exerciseId: "c", exerciseName: "Curl", setIndex: 0,
                           weight: "12", reps: "× 8", completedAt: 1, updatedAt: 0),
                WorkoutSet(id: "\(id)-x", sessionId: id, exerciseId: "b", exerciseName: "Bench", setIndex: 2,
                           weight: "500 lb", reps: "× 6", completedAt: nil, updatedAt: 0), // never done
            ]
        }
        return s
    }

    func run(_ date: String, _ mi: Double, _ min: Double) -> RunActivity {
        RunActivity(id: date, source: .health, name: "Morning Run", date: date, start: DateKey.date(date), minutes: min, miles: mi)
    }

    @Test func dumbbellLoadsParseAndStep() {
        #expect(formatLoad(parseLoad("70 lb", type: .dumbbell)) == "70 lb")
        #expect(stepLoad("70 lb", type: .dumbbell, increment: 5, direction: 1) == "75 lb")
        #expect(setPounds("70 lb", type: .dumbbell) == 70)
    }

    @Test func weekStatsCountOnlyThatWeek() {
        let w = snap().weekStats(monday: "2026-10-12", synced: [run("2026-10-12", 3, 30), run("2026-10-19", 5, 50)])
        #expect(w == WeekStats(workouts: 1, runs: 1, runMiles: 3, avgWorkoutMinutes: 50))
        #expect(snap().weekStats(monday: "2026-10-19", synced: []) == WeekStats())
    }

    @Test func setPoundsOnlyCountsPoundLoads() {
        #expect(setPounds("12", type: .machine) == nil)
        #expect(setPounds("90 lb", type: .machine) == 90)
    }

    @Test func outcomeCountsCheckedSets() {
        var s = snap()
        #expect(s.outcome("s2") == .almost)          // one set never ticked
        s.sets.removeAll { $0.id == "s2-x" }
        #expect(s.outcome("s2") == .finished)
        for i in s.sets.indices where s.sets[i].sessionId == "s1" { s.sets[i].completedAt = nil }
        #expect(s.outcome("s1") == .skipped)
    }

    @Test func activityRecordMarksLiftsAndRuns() {
        // Monday lift with a run, Wednesday run only. Oct 5: nothing. Oct 7: ran. Oct 12: lifted. Oct 14: missed the run.
        // Oct 19: lifted and ran. Oct 26 (today): nothing yet.
        let run = RunPrescription(label: .easy, timing: .standalone, durationMin: 30, hrZoneMin: 0, hrZoneMax: 0, hrHardCap: 0, strides: false)
        var s = Snapshot(days: [Day(id: 1, name: "Upper A", focus: "")], exercises: [],
                         programWeeks: [ProgramWeek(id: 1, phase: "", startDate: "2026-10-05", isDeload: false,
                                                    slots: [ProgramSlot(dow: .mon, liftDayId: 1, run: run),
                                                            ProgramSlot(dow: .wed, liftDayId: nil, run: run)], updatedAt: 0)])
        for (id, date, ticked) in [("a", "2026-10-12", 2), ("b", "2026-10-19", 1)] {
            s.sessions.append(Session(id: id, dayId: 1, date: date, startedAt: 0, finishedAt: 1, updatedAt: 0, type: .lift))
            for i in 0..<2 {
                s.sets.append(WorkoutSet(id: "\(id)\(i)", sessionId: id, exerciseId: "b", exerciseName: "Bench", setIndex: i,
                                         weight: "100 lb", reps: "× 5", completedAt: i < ticked ? 1 : nil, updatedAt: 0))
            }
        }
        let r = s.activityRecord(today: DateKey.date("2026-10-26").addingTimeInterval(6 * 3600),
                                 runDates: ["2026-10-07", "2026-10-19"])
        #expect(r.map(\.date) == ["2026-10-05", "2026-10-07", "2026-10-12", "2026-10-14", "2026-10-19", "2026-10-21"])
        #expect(r.map(\.lift) == [.missed, nil, .done, nil, .done, nil])
        #expect(r.map(\.run) == [.missed, .done, .missed, .missed, .done, .missed])
        #expect(r[2].sessionId == "a")
    }

    @Test func restDaysHaveNoLiftAndNoRun() {
        // Monday lift, Wednesday run, the rest off.
        let run = RunPrescription(label: .easy, timing: .standalone, durationMin: 30, hrZoneMin: 0, hrZoneMax: 0, hrHardCap: 0, strides: false)
        let s = Snapshot(days: [Day(id: 1, name: "Upper A", focus: "")], exercises: [],
                         programWeeks: [ProgramWeek(id: 1, phase: "", startDate: "2026-10-05", isDeload: false,
                                                    slots: [ProgramSlot(dow: .mon, liftDayId: 1, run: nil),
                                                            ProgramSlot(dow: .wed, liftDayId: nil, run: run)], updatedAt: 0)])
        #expect(s.isRestDay("2026-10-06"))
        #expect(s.isRestDay("2026-11-03"))
        #expect(!s.isRestDay("2026-10-07"))
        #expect(!s.isRestDay("2026-10-12"))
        #expect(!s.isRestDay("2026-10-04"))
    }

    @Test @MainActor func calendarWeeksStartOnSunday() {
        let w = TrackRecord.weeks(of: DateKey.date("2026-10-01").addingTimeInterval(6 * 3600))
        #expect(w.first?.first == "2026-09-27")
        #expect(w.last?.last == "2026-10-31")
        #expect(w.count == 5)
    }

    @Test func historyMergesLiftsAndRunsNewestFirst() {
        let h = snap().historyEntries(synced: [run("2026-10-10", 3.1, 30)])
        #expect(h.map(\.date) == ["2026-10-15", "2026-10-10", "2026-10-08", "2026-10-01"])
        #expect(h[0].title == "Upper A" && h[0].detail == "4 sets · 50 min")
        #expect(h[1].kind == .run && h[1].detail == "3.1 mi · 30 min · 9:41 /mi")
    }

    @Test func runawayRunTimerFallsBackToPlan() {
        var s = snap()
        let log = RunLog(label: .easy, dow: .mon, plannedMin: 30, hrZoneMin: 130, hrZoneMax: 150, hrHardCap: 170,
                         strides: false, actualMin: 2817, actualMi: 3)
        s.sessions.append(Session(id: "r", dayId: 0, date: "2026-10-05", startedAt: 0, finishedAt: 1, updatedAt: 0, type: .run, run: log))
        #expect(s.allRuns(synced: []).first?.minutes == 30)
    }
}

@Suite struct NotificationTests {
    /// Mon lift (Upper A), Wed run, rest otherwise.
    func snap() -> Snapshot {
        var s = Snapshot(days: [Day(id: 1, name: "Upper A", focus: "")],
                         exercises: [Exercise(id: "b", dayId: 1, order: 0, name: "Bench", sets: 1, weight: "200 lb", reps: "× 6",
                                              loadType: .weight, updatedAt: 0)],
                         programWeeks: [ProgramWeek(id: 1, phase: "", startDate: "2026-10-05", isDeload: false,
                                                    slots: [ProgramSlot(dow: .mon, liftDayId: 1, run: nil),
                                                            ProgramSlot(dow: .wed, liftDayId: nil, run: makeRun(.easy, minutes: 30, timing: .standalone))],
                                                    updatedAt: 0)])
        s.schema = 2
        return s
    }
    // Monday Oct 26 2026, 6:00 AM local.
    let now = DateKey.date("2026-10-26").addingTimeInterval(6 * 3600)

    @Test func plansRemindersForTrainingDaysOnly() {
        let p = Notifier.plan(snap(), runs: [], prefs: NotificationPrefs(), now: now)
        let ids = p.map(\.id)
        #expect(ids.contains("gt-workout-2026-10-26") && ids.contains("gt-missed-2026-10-26"))
        #expect(ids.contains("gt-workout-2026-10-28"))            // Wednesday run
        #expect(!ids.contains { $0.contains("2026-10-27") })       // Tuesday is rest
        #expect(ids.contains("gt-recap-2026-11-01"))               // Sunday
        #expect(!ids.contains { $0.hasPrefix("gt-fact") })         // off by default
        #expect(p.first { $0.id == "gt-workout-2026-10-26" }?.title == "Upper A today")
        #expect(p.first { $0.id == "gt-workout-2026-10-26" }?.body == "")
    }

    @Test func weeklyRecapIsWorkoutsThenMiles() {
        let sunday = DateKey.date("2026-11-01").addingTimeInterval(12 * 3600)
        let runs = [RunActivity(id: "r", source: .health, name: "Run", date: "2026-10-28", start: now, minutes: 30, miles: 3)]
        let text = Notifier.recapText(snap(), data: snap().widgetData(runs: runs, now: now), runs: runs, sunday: sunday)
        #expect(text.hasSuffix(" workouts\n3.0 mi"))
        #expect(!text.contains("lb") && !text.contains("·"))
    }

    @Test func doneDaysAndPastTimesAreSkipped() {
        var s = snap()
        s.sessions.append(Session(id: "x", dayId: 1, date: "2026-10-26", startedAt: 0, finishedAt: 1, updatedAt: 0, type: .lift))
        let late = DateKey.date("2026-10-28").addingTimeInterval(21 * 3600) // Wed 9 PM
        let p = Notifier.plan(s, runs: [], prefs: NotificationPrefs(), now: late)
        #expect(!p.contains { $0.id.contains("2026-10-26") || $0.id.contains("2026-10-28") })
        let early = Notifier.plan(s, runs: [], prefs: NotificationPrefs(), now: now)
        #expect(!early.contains { $0.id == "gt-workout-2026-10-26" })   // already logged
    }

    @Test func togglesAndTimesAreRespected() {
        var prefs = NotificationPrefs()
        prefs.missed = false; prefs.recap = false
        prefs.workoutTime = 9 * 60 + 30
        let p = Notifier.plan(snap(), runs: [], prefs: prefs, now: now)
        #expect(p.allSatisfy { $0.id.hasPrefix("gt-workout") })
        let c = DateKey.calendar.dateComponents([.hour, .minute], from: p[0].fireDate)
        #expect(c.hour == 9 && c.minute == 30)
        prefs.workout = false
        #expect(Notifier.plan(snap(), runs: [], prefs: prefs, now: now).isEmpty)
    }
}

@Suite struct WatchStateTests {
    /// Upper A on Mondays: Bench (2 sets) then Row (1 set).
    func snap() -> Snapshot {
        Snapshot(days: [Day(id: 1, name: "Upper A", focus: "")],
                 exercises: [Exercise(id: "b", dayId: 1, order: 0, name: "Bench", sets: 2, weight: "200 lb", reps: "× 6",
                                      setRows: [SetRow(weight: "200 lb", reps: "× 6"), SetRow(weight: "190 lb", reps: "× 8")],
                                      loadType: .weight, updatedAt: 0),
                             Exercise(id: "r", dayId: 1, order: 1, name: "Row", sets: 1, weight: "150 lb", reps: "× 10",
                                      loadType: .weight, updatedAt: 0)],
                 programWeeks: [ProgramWeek(id: 1, phase: "", startDate: "2026-10-05", isDeload: false,
                                            slots: [ProgramSlot(dow: .mon, liftDayId: 1, run: nil)], updatedAt: 0)])
    }
    let monday = DateKey.date("2026-10-26").addingTimeInterval(9 * 3600)

    @Test func todayWithoutWorkout() {
        let s = snap().watchState(now: monday)
        #expect(s.todayTitle == "Upper A" && s.todayDetail == "2 lifts" && s.canStart)
        #expect(s.workout == nil && s.weekPlanned == 1 && s.weekDone == 0)
    }

    @Test func walksThroughSetsInOrder() {
        var db = snap()
        let id = db.startSession(day: db.days[0], options: StartOptions(scheduledDate: "2026-10-26"))
        var w = db.watchState(now: monday).workout
        #expect(w?.sessionId == id && w?.total == 3 && w?.done == 0)
        #expect(w?.current?.exercise == "Bench" && w?.current?.setNumber == 1 && w?.current?.setCount == 2)
        #expect(w?.current?.weight == "200 lb" && w?.current?.reps == "6")
        #expect(w?.next == "190 lb × 8")
        #expect(w?.queue.map(\.exercise) == ["Bench", "Bench", "Row"] && w?.queue.first == w?.current)

        db.toggleSet(w!.current!.setId)
        w = db.watchState(now: monday).workout
        #expect(w?.done == 1 && w?.current?.setNumber == 2 && w?.next == "Row")

        db.toggleSet(w!.current!.setId)
        db.toggleSet(db.watchState(now: monday).workout!.current!.setId)
        w = db.watchState(now: monday).workout
        #expect(w?.done == 3 && w?.current == nil && w?.next == nil)
    }

    @Test func roundTripsOverTheWire() {
        let s = snap().watchState(now: monday)
        let back = WatchWire.decode(WatchState.self, from: WatchWire.encode(s))
        #expect(back == s)
        let a = WatchAction.stepLoad(setId: "x", direction: -1)
        #expect(WatchWire.decode(WatchAction.self, from: WatchWire.encode(a)) == a)
    }
}

@Suite struct StoreTests {
    @Test @MainActor func unreadableFileIsKeptNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "gymtrak.json")
        try Data("not json".utf8).write(to: url)
        let store = Store(fileURL: url, seedIfEmpty: false)
        #expect(store.loadError != nil)
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path()).filter { $0.contains("unreadable") }
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: dir.appending(path: copies[0])) == Data("not json".utf8))
    }

    @Test @MainActor func missingFileIsNotAnError() {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        #expect(Store(fileURL: url, seedIfEmpty: false).loadError == nil)
    }
}

@Suite struct SleepTests {
    @Test func overlapsCountOnceAndNightsGoToTheWakeDate() {
        let bed = DateKey.date("2026-10-26").addingTimeInterval(23 * 3600)      // Mon 11 PM
        let night = DateInterval(start: bed, duration: 7 * 3600)                  // to Tue 6 AM
        let phone = DateInterval(start: bed.addingTimeInterval(3600), duration: 2 * 3600)  // inside the watch's night
        let nap = DateInterval(start: DateKey.date("2026-10-27").addingTimeInterval(14 * 3600), duration: 1800)
        let s = sleepByWakeDate([night, phone, nap])
        #expect(s == ["2026-10-27": 7 * 60 + 30])
        #expect(fmtSleep(432) == "7h 12m")
        #expect(fmtSleep(45) == "45m")
    }
}

struct KisiTests {
    @Test func errorTextIsFoundWhereverKisiPutsIt() {
        #expect(Kisi.message(in: Data(#"{"message":"Invalid email or password"}"#.utf8)) == "Invalid email or password")
        #expect(Kisi.message(in: Data(#"{"errors":{"base":["Too far from the door"]}}"#.utf8)) == "Too far from the door")
        #expect(Kisi.message(in: Data("not json".utf8)) == "")
    }
}

struct WarmupTests {
    func fixture(warmup: Bool = true) -> (Snapshot, Day) {
        let day = Day(id: 1, order: 1, name: "Upper A", focus: "Press", updatedAt: 0)
        let press = Exercise(id: "press", dayId: 1, order: 1, name: "Press", sets: 2, weight: "200 lb", reps: "× 5",
                             setRows: [SetRow(weight: "200 lb", reps: "× 5"), SetRow(weight: "190 lb", reps: "× 6")],
                             loadType: .weight, warmup: warmup ? true : nil, updatedAt: 0)
        let curl = Exercise(id: "curl", dayId: 1, order: 2, name: "Curl", sets: 1, weight: "40 lb", reps: "× 8",
                            loadType: .weight, updatedAt: 0)
        return (Snapshot(days: [day], exercises: [press, curl], programWeeks: []), day)
    }

    @Test func defaultsScaleTheFirstWorkingSet() {
        let (snap, _) = fixture()
        #expect(snap.exercises[0].defaultWarmups == [SetRow(weight: "100 lb", reps: "× 8"), SetRow(weight: "150 lb", reps: "× 4")])
        let plates = Exercise(id: "p", dayId: 1, order: 1, name: "Press", sets: 1, weight: "4 pl + 15", reps: "× 5", loadType: .plates, updatedAt: 0)
        #expect(plates.defaultWarmups.map(\.weight) == ["2 pl", "3 pl"])
        let pin = Exercise(id: "m", dayId: 1, order: 1, name: "Curl", sets: 1, weight: "Max", reps: "× 5", loadType: .machine, updatedAt: 0)
        #expect(pin.defaultWarmups.map(\.weight) == ["", ""])
    }

    @Test func warmupsComeFirstAndStayOutOfTheSetCount() {
        var (snap, day) = fixture()
        let id = snap.startSession(day: day)
        #expect(snap.warmups(of: id).count == 2)
        #expect(snap.sets(of: id).count == 3)
        let session = snap.sessions[0]
        let firstTwo = snap.pendingItems(session).prefix(2).map(\.warmup)
        #expect(firstTwo == [true, true])
        let state = snap.watchState(now: Date())
        #expect(state.workout?.total == 3)
        #expect(state.workout?.current?.warmup == true)
        #expect(state.workout?.current?.restSeconds == warmupRestSec)
    }

    @Test func warmupsAreOptional() {
        var (snap, day) = fixture()
        let id = snap.startSession(day: day)
        let session = snap.sessions[0]
        // Doing a working set first drops the warm-ups from the queue.
        let first = snap.sets(of: id).first { $0.exerciseId == "press" && $0.setIndex == 0 }!
        snap.toggleSet(first.id)
        let warmLeft = snap.pendingItems(session).filter(\.warmup).count
        #expect(warmLeft == 0)
        // Or skip them outright.
        var (other, d2) = fixture()
        let id2 = other.startSession(day: d2)
        other.skipWarmups(id2, exerciseId: "press")
        #expect(other.warmups(of: id2).isEmpty)
    }

    @Test func coachIgnoresWarmupsAndFinishRemembersThem() {
        var (snap, day) = fixture()
        let id = snap.startSession(day: day)
        let w = snap.warmups(of: id).sorted { $0.setIndex < $1.setIndex }
        snap.updateSetLoad(w[0].id, weight: "95 lb", reps: "× 10")
        let ticked = snap.toggleSet(w[0].id)
        #expect(ticked)
        snap.finishSession(id)
        #expect(snap.exercises[0].warmupRows == [SetRow(weight: "95 lb", reps: "× 10"), SetRow(weight: "150 lb", reps: "× 4")])
        #expect(snap.exercises[0].setRows == [SetRow(weight: "200 lb", reps: "× 5"), SetRow(weight: "190 lb", reps: "× 6")])
        #expect(snap.liftHistory(for: snap.exercises[0]).isEmpty)
        // Next workout starts from what was used.
        let next = snap.startSession(day: day, options: StartOptions(scheduledDate: "2099-01-01"))
        #expect(snap.warmups(of: next).sorted { $0.setIndex < $1.setIndex }.first?.weight == "95 lb")
    }

    @Test func noWarmupsWhenOff() {
        var (snap, day) = fixture(warmup: false)
        let id = snap.startSession(day: day)
        #expect(snap.warmups(of: id).isEmpty)
    }

    @Test func discardRemovesWarmups() {
        var (snap, day) = fixture()
        let id = snap.startSession(day: day)
        snap.discardSession(id)
        #expect(snap.warmups?.isEmpty == true)
    }
}
