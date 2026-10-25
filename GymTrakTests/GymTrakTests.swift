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
