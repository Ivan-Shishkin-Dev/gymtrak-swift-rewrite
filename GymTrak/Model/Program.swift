import Foundation

// Program helpers. Each ProgramWeek stores the local date of its own Monday, so
// finding "this week" is a string comparison, not week arithmetic.

enum DateKey {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2 // Monday
        return c
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local "yyyy-MM-dd".
    static func key(_ d: Date) -> String { formatter.string(from: d) }

    /// Local midnight of a "yyyy-MM-dd" key.
    static func date(_ key: String) -> Date { formatter.date(from: key) ?? Date() }

    static func addDays(_ key: String, _ n: Int) -> String {
        Self.key(calendar.date(byAdding: .day, value: n, to: date(key))!)
    }

    static func dow(_ d: Date) -> Dow {
        // Calendar weekday: 1 = Sunday … 7 = Saturday.
        Dow.allCases[(calendar.component(.weekday, from: d) + 5) % 7]
    }

    /// The Monday of the week `d` falls in.
    static func mondayKey(_ d: Date) -> String {
        addDays(key(d), -dow(d).index)
    }

    /// Today if it is a Monday, else the next Monday.
    static func upcomingMonday(_ d: Date) -> String {
        let i = dow(d).index
        return addDays(key(d), i == 0 ? 0 : 7 - i)
    }

    /// "Mon Oct 26" / "Oct 26" style labels.
    static func label(_ key: String, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date(key))
    }
}

extension ProgramWeek {
    func date(of dow: Dow) -> String { DateKey.addDays(startDate, dow.index) }
    var runMinutes: Int { slots.reduce(0) { $0 + ($1.run?.durationMin ?? 0) } }
}

extension Snapshot {
    /// The one weekly schedule that repeats every week (no numbered weeks or deloads — the coach handles load).
    var scheduleTemplate: ProgramWeek? {
        let monday = DateKey.mondayKey(Date())
        return weeks.last { $0.startDate <= monday } ?? weeks.first
    }

    /// The schedule laid onto the week containing `d`.
    func scheduleWeek(_ d: Date) -> ProgramWeek? {
        guard var w = scheduleTemplate else { return nil }
        w.startDate = DateKey.mondayKey(d)
        w.isDeload = false
        return w
    }

    /// Days before the program (or the first logged session) are never "missed".
    /// `saveSchedule` moves the week's startDate to this Monday, so the earliest session keeps history alive.
    var programStart: String? {
        let firstSession = sessions.filter { $0.finishedAt != nil && !$0.isDeleted }.map(\.slotDate).min()
        return [weeks.first?.startDate, firstSession].compactMap { $0 }.min()
    }

    /// Where one local date stands. `doneExtra` holds dates done outside a session (Strava or Health runs).
    func dotState(_ key: String, todayKey: String, doneExtra: Set<String>) -> DayDot.State {
        if doneDates.contains(key) || doneExtra.contains(key) { return .done }
        let date = DateKey.date(key)
        let slot = scheduleWeek(date)?.slot(DateKey.dow(date))
        guard let slot, !slot.isRest, let start = programStart, key >= start else { return .rest }
        return key < todayKey ? .missed : .upcoming
    }

    /// The last seven days, oldest first, ending on `today`.
    func weekDots(ending today: Date, doneExtra: Set<String> = []) -> [DayDot] {
        let todayKey = DateKey.key(today)
        return (0..<7).reversed().map { back in
            let key = DateKey.addDays(todayKey, -back)
            return DayDot(date: key, state: dotState(key, todayKey: todayKey, doneExtra: doneExtra))
        }
    }

    /// Consecutive Mon–Sun weeks with no missed day, counted back from last week.
    /// The current week only counts once it ends.
    func streakWeeks(today: Date, doneExtra: Set<String> = []) -> Int {
        guard let start = programStart else { return 0 }
        let todayKey = DateKey.key(today)
        var monday = DateKey.mondayKey(today)
        var count = 0
        while true {
            monday = DateKey.addDays(monday, -7)
            guard monday >= start else { break }
            let clean = (0..<7).allSatisfy { offset in
                dotState(DateKey.addDays(monday, offset), todayKey: todayKey, doneExtra: doneExtra) != .missed
            }
            guard clean else { break }
            count += 1
        }
        return count
    }

    /// Save the weekly schedule as the only week.
    mutating func saveSchedule(_ week: ProgramWeek, now: EpochMs = nowMs()) {
        var w = week
        w.id = 1
        w.isDeload = false
        w.startDate = DateKey.mondayKey(Date())
        w.updatedAt = now
        programWeeks = [w]
    }
}

/// One day on the home dots row.
struct DayDot: Identifiable, Hashable, Sendable {
    enum State: Sendable { case done, missed, rest, upcoming }
    let date: String
    let state: State
    var id: String { date }
}

/// The program week containing `d`, or nil when it falls outside the program.
func weekFor(_ weeks: [ProgramWeek], _ d: Date) -> ProgramWeek? {
    let key = DateKey.mondayKey(d)
    return weeks.first { $0.startDate == key }
}


func zoneLabel(_ lo: Int, _ hi: Int) -> String { "\(lo)–\(hi)" }

/// Measured Zone 2 pace: 2.5 mi in 30 min. Display only — the plan stays in minutes.
enum Zone2 {
    static let miles = 2.5
    static let minutes = 30.0
    static var pace: Double { minutes / miles }
    static func milesLabel(_ min: Int) -> String { String(format: "%.1f mi", Double(min) / pace) }
}

let stridesNote = "4 x 20 sec strides at the end, full walk recovery between each. Relaxed and fast, not sprints."
let deloadNote = "Deload week. Reduced volume is intentional."

// MARK: - Templates (the 4-day split and the 8-week run block)

enum TemplateSlug: String, CaseIterable { case upperA = "upper-a", lowerA = "lower-a", upperB = "upper-b", lowerB = "lower-b" }

struct TemplateSpec {
    struct ExerciseSpec { var name: String; var loadType: LoadType; var setRows: [SetRow] }
    var slug: TemplateSlug
    var name: String
    var focus: String
    var exercises: [ExerciseSpec]
}

let planRevision = 3
let splitRevision = 1

private func rows(_ pairs: (String, String)...) -> [SetRow] { pairs.map { SetRow(weight: $0.0, reps: $0.1) } }
private func ex(_ name: String, _ t: LoadType, _ r: [SetRow]) -> TemplateSpec.ExerciseSpec { .init(name: name, loadType: t, setRows: r) }

private let upperExercises = [
    ex("Machine Press", .machine, rows(("", ""), ("", ""))),
    ex("T-Bar", .plates, rows(("4 pl", "× 6"), ("4 pl", "× 6"))),
    ex("Pec Dec", .machine, rows(("220 lb", "× 6"), ("210 lb", "× 6"))),
    ex("Lat Pulldown Mach", .machine, rows(("220 lb", "× 6"), ("205 lb", "× 6"))),
    ex("Lateral Raise", .machine, rows(("50 lb", "× 6"), ("45 lb", "× 6"))),
]

private func lowerExercises(_ hinge: TemplateSpec.ExerciseSpec) -> [TemplateSpec.ExerciseSpec] {
    [
        ex("Shoulder Press", .machine, rows(("130 lb", "× 6"), ("120 lb", "× 6"))),
        ex("Incline Curl", .machine, rows(("12", "× 6"), ("11", "× 6"))),
        ex("Single-Arm Tricep", .weight, rows(("85 lb", "× 6"), ("75 lb", "× 9"))),
        hinge,
        ex("Leg Curl", .machine, rows(("170 lb", "× 10"), ("130 lb", "× 6"))),
        ex("Leg Extension", .weight, rows(("250 lb", "× 5"), ("230 lb", "× 5"))),
        ex("Adductor", .machine, rows(("16", "× 5"), ("16", "× 5"))),
        ex("Calf", .machine, rows(("12", "× 8"), ("12", "× 6"))),
        ex("Tibialis Raise", .bodyweight, rows(("BW", "× 20"), ("BW", "× 20"))),
        ex("Hip Abduction", .machine, rows(("15", ""), ("15", ""))),
        ex("Cable Crunch", .machine, rows(("14", "× 8"), ("13", "× 8"))),
    ]
}

let baseTemplates: [TemplateSpec] = [
    TemplateSpec(slug: .upperA, name: "Upper A", focus: "Push / pull", exercises: upperExercises),
    TemplateSpec(slug: .lowerA, name: "Lower A", focus: "Shoulders, arms / quad",
                 exercises: lowerExercises(ex("Leg Press", .plates, rows(("5 pl", "× 7"), ("4 pl + 25", "× 6"))))),
    TemplateSpec(slug: .upperB, name: "Upper B", focus: "Push / pull", exercises: upperExercises),
    TemplateSpec(slug: .lowerB, name: "Lower B", focus: "Shoulders, arms / hamstring",
                 exercises: lowerExercises(ex("SLDL", .weight, rows(("335 lb", "× 5"), ("315 lb", "× 4"))))),
]

func templateExercises(_ t: TemplateSpec, dayId: Int, now: EpochMs) -> [Exercise] {
    t.exercises.enumerated().map { i, e in
        Exercise(id: newID(), dayId: dayId, order: i + 1, name: e.name, sets: e.setRows.count,
                 weight: e.setRows[0].weight, reps: e.setRows[0].reps, setRows: e.setRows,
                 loadType: e.loadType, updatedAt: now)
    }
}

private struct RunSpec { var label: RunLabel; var min: Int; var notes: String? = nil; var strides = false }
private func easy(_ m: Int, strides: Bool = false) -> RunSpec { RunSpec(label: .easy, min: m, strides: strides) }
private func long(_ m: Int) -> RunSpec { RunSpec(label: .long, min: m) }
private let fast = "Fast is about 10:00 /mi."
private let steady = "Steady is about 11:20 /mi, a few words at a time."

private let runs: [Int: (mon: RunSpec, wed: RunSpec, sat: RunSpec)] = [
    1: (easy(20), RunSpec(label: .intervals, min: 30, notes: "8 min easy, 6 × 1 min fast / 2 min walk-jog, 4 min easy. \(fast)"), long(40)),
    2: (easy(25), RunSpec(label: .intervals, min: 35, notes: "8 min easy, 8 × 1 min fast / 2 min walk-jog, 3 min easy. \(fast)"), long(45)),
    3: (easy(25), RunSpec(label: .tempo, min: 35, notes: "10 min easy, 2 × 8 min steady with 3 min jog between, 6 min easy. \(steady)"), long(50)),
    4: (easy(20), easy(25, strides: true), long(35)),
    5: (easy(30), RunSpec(label: .intervals, min: 40, notes: "10 min easy, 5 × 3 min fast / 2 min walk-jog, 5 min easy. \(fast)"), long(55)),
    6: (easy(30), RunSpec(label: .tempo, min: 40, notes: "10 min easy, 20 min steady, 10 min easy. \(steady)"), long(60)),
    7: (easy(30), RunSpec(label: .intervals, min: 45, notes: "10 min easy, 6 × 3 min fast / 2 min walk-jog, 5 min easy. \(fast)"), long(65)),
    8: (easy(20), easy(25, strides: true), RunSpec(label: .timeTrial, min: 45, notes: "10 min easy, then a 5K as fast as you can hold. The time to beat is 33:26.")),
]

/// Heart-rate zones per run type: Zone 2, quality-session average, race.
func defaultHR(_ label: RunLabel) -> (Int, Int, Int) {
    switch label {
    case .easy, .long: (120, 140, 145)
    case .intervals, .tempo: (145, 175, 185)
    case .timeTrial: (165, 190, 200)
    }
}

func makeRun(_ label: RunLabel, minutes: Int, timing: RunTiming, notes: String? = nil, strides: Bool = false) -> RunPrescription {
    let hr = defaultHR(label)
    return RunPrescription(label: label, timing: timing, durationMin: minutes, hrZoneMin: hr.0, hrZoneMax: hr.1, hrHardCap: hr.2, strides: strides, notes: notes)
}

private func run(_ s: RunSpec, _ timing: RunTiming) -> RunPrescription {
    makeRun(s.label, minutes: s.min, timing: timing, notes: s.notes, strides: s.strides)
}

/// The eight run-block weeks, anchored to `startMonday` (week 1's Monday).
func baseWeeks(startMonday: String, ids: [TemplateSlug: Int], now: EpochMs) -> [ProgramWeek] {
    (1...8).map { n in
        let r = runs[n]!
        let slots = [
            ProgramSlot(dow: .mon, liftDayId: ids[.upperA], run: run(r.mon, .afterLift)),
            ProgramSlot(dow: .tue, liftDayId: ids[.lowerA], run: nil),
            ProgramSlot(dow: .wed, liftDayId: nil, run: run(r.wed, .standalone)),
            ProgramSlot(dow: .thu, liftDayId: ids[.upperB], run: nil),
            ProgramSlot(dow: .fri, liftDayId: ids[.lowerB], run: nil),
            ProgramSlot(dow: .sat, liftDayId: nil, run: run(r.sat, .standalone)),
            ProgramSlot(dow: .sun, liftDayId: nil, run: nil),
        ]
        return ProgramWeek(id: n, phase: n <= 4 ? "build-1" : "build-2",
                           startDate: DateKey.addDays(startMonday, (n - 1) * 7),
                           isDeload: n == 4 || n == 8, slots: slots, updatedAt: now)
    }
}

/// A fresh database: the four lift days and the run block starting on the coming Monday.
func seedSnapshot(now: EpochMs = nowMs(), today: Date = Date()) -> Snapshot {
    var snap = Snapshot()
    var ids: [TemplateSlug: Int] = [:]
    for (i, t) in baseTemplates.enumerated() {
        let id = i + 1
        ids[t.slug] = id
        snap.days.append(Day(id: id, order: id, name: t.name, focus: t.focus, slug: t.slug.rawValue,
                             splitRevision: splitRevision, planRevision: planRevision, updatedAt: now))
        snap.exercises += templateExercises(t, dayId: id, now: now)
    }
    snap.programWeeks = baseWeeks(startMonday: DateKey.upcomingMonday(today), ids: ids, now: now)
    snap.schema = 2
    return snap
}
