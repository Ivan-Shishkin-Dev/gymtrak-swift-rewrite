import Foundation

// Record shapes. They mirror the old web app's schemas field for field, so its
// exported data imports as-is.
// Timestamps are epoch milliseconds (Double), dates are local "yyyy-MM-dd".

typealias EpochMs = Double

/// A lift day (Upper A, Lower B…). `order` is the editable position; legacy rows fall back to `id`.
struct Day: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var order: Int?
    var name: String
    var focus: String
    var slug: String?
    var splitRevision: Int?
    var planRevision: Int?
    var archived: Bool?
    var updatedAt: EpochMs?

    var rank: Int { order ?? id }
    var isArchived: Bool { archived ?? false }
}

/// One planned set's load.
struct SetRow: Codable, Hashable, Sendable {
    var weight: String
    var reps: String
}

/// How an exercise's load is entered. See `Load.swift` for the grammar of each.
enum LoadType: String, Codable, CaseIterable, Sendable {
    case weight, machine, plates, bodyweight, free

    var label: String {
        switch self {
        case .weight: "Weight"
        case .machine: "Machine"
        case .plates: "Plates"
        case .bodyweight: "Body"
        case .free: "Other"
        }
    }
}

/// A prescribed exercise belonging to a day, carrying its last-used loads.
struct Exercise: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var dayId: Int
    var order: Int
    var name: String
    var sets: Int
    var weight: String
    var reps: String
    var note: String?
    var libLoad: String?
    var setRows: [SetRow]?
    var loadType: LoadType?
    var loadIncrement: Double?
    var restSeconds: Int?
    var updatedAt: EpochMs

    /// Per-set loads; falls back to `sets` copies of weight/reps for legacy rows.
    var rows: [SetRow] {
        if let setRows, !setRows.isEmpty { return setRows }
        return Array(repeating: SetRow(weight: weight, reps: reps), count: max(1, sets))
    }

    var effectiveLoadType: LoadType { loadType ?? inferLoadType(weight) }

    var effectiveIncrement: Double {
        loadIncrement ?? (effectiveLoadType == .plates || effectiveLoadType == .machine ? 1 : 5)
    }
}

// MARK: - Program

enum Dow: String, Codable, CaseIterable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun

    var label: String {
        switch self {
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        case .sun: "Sunday"
        }
    }

    var short: String { String(label.prefix(3)) }
    var index: Int { Dow.allCases.firstIndex(of: self)! }
}

enum RunLabel: String, Codable, CaseIterable, Sendable {
    case easy = "Easy Run"
    case long = "Long Run"
    case intervals = "Intervals"
    case tempo = "Tempo Run"
    case timeTrial = "Time Trial"

    /// How hard the run should feel, in two words.
    var effort: String {
        switch self {
        case .easy, .long: "Zone 2"
        case .intervals: "Hard reps"
        case .tempo: "Steady hard"
        case .timeTrial: "Race effort"
        }
    }

    var isEasy: Bool { self == .easy || self == .long }
}

enum RunTiming: String, Codable, Sendable {
    case afterLift = "after-lift"
    case standalone
}

/// A planned run in one weekday slot.
struct RunPrescription: Codable, Hashable, Sendable {
    var label: RunLabel
    var timing: RunTiming
    var durationMin: Int
    var hrZoneMin: Int
    var hrZoneMax: Int
    var hrHardCap: Int
    var strides: Bool
    var notes: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(timing, forKey: .timing)
        try c.encode(durationMin, forKey: .durationMin)
        try c.encode(hrZoneMin, forKey: .hrZoneMin)
        try c.encode(hrZoneMax, forKey: .hrZoneMax)
        try c.encode(hrHardCap, forKey: .hrHardCap)
        try c.encode(strides, forKey: .strides)
        try c.encode(notes, forKey: .notes) // explicit null, as the PWA writes it
    }
}

/// One weekday of a program week. No lift and no run means rest.
struct ProgramSlot: Codable, Hashable, Sendable {
    var dow: Dow
    var liftDayId: Int?
    var run: RunPrescription?

    var isRest: Bool { liftDayId == nil && run == nil }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dow, forKey: .dow)
        try c.encode(liftDayId, forKey: .liftDayId)
        try c.encode(run, forKey: .run)
    }
}

/// One week of the program. `id` is the week number; `startDate` is its Monday.
struct ProgramWeek: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var phase: String
    var startDate: String
    var isDeload: Bool
    var slots: [ProgramSlot]
    var updatedAt: EpochMs

    func slot(_ dow: Dow) -> ProgramSlot? { slots.first { $0.dow == dow } }
}

// MARK: - Sessions

enum SessionType: String, Codable, Sendable { case lift, run }

/// A performed run (legacy — runs are plan-only now, but old sessions keep it).
struct RunLog: Codable, Hashable, Sendable {
    var label: RunLabel
    var dow: Dow
    var plannedMin: Int
    var hrZoneMin: Int
    var hrZoneMax: Int
    var hrHardCap: Int
    var strides: Bool
    var actualMin: Double?
    var actualMi: Double?
    var avgHr: Double?
    var notes: String?
}

/// A workout session: one instance of a day, logged on a date.
struct Session: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var dayId: Int
    var date: String
    var scheduledDate: String?
    var dayNameSnapshot: String?
    var focusSnapshot: String?
    var startedAt: EpochMs
    var finishedAt: EpochMs?
    var durationSec: Double?
    var updatedAt: EpochMs
    var deleted: Bool?
    var type: SessionType?
    var weekNumber: Int?
    var deload: Bool?
    var run: RunLog?

    var isRun: Bool { (type ?? .lift) == .run }
    var isDeleted: Bool { deleted ?? false }
    var isOpen: Bool { finishedAt == nil && !isDeleted }
    /// The program date this session fulfils.
    var slotDate: String { scheduledDate ?? date }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(dayId, forKey: .dayId)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(scheduledDate, forKey: .scheduledDate)
        try c.encodeIfPresent(dayNameSnapshot, forKey: .dayNameSnapshot)
        try c.encodeIfPresent(focusSnapshot, forKey: .focusSnapshot)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(deleted, forKey: .deleted)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(weekNumber, forKey: .weekNumber)
        try c.encodeIfPresent(deload, forKey: .deload)
        try c.encodeIfPresent(run, forKey: .run)
    }
}

/// A single set performed within a session.
struct WorkoutSet: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var sessionId: String
    var exerciseId: String
    var exerciseName: String
    var setIndex: Int
    var weight: String
    var reps: String
    var targetWeight: String?
    var targetReps: String?
    var weightNum: Double?
    var repsNum: Double?
    var completedAt: EpochMs?
    var updatedAt: EpochMs

    var isDone: Bool { completedAt != nil }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(exerciseId, forKey: .exerciseId)
        try c.encode(exerciseName, forKey: .exerciseName)
        try c.encode(setIndex, forKey: .setIndex)
        try c.encode(weight, forKey: .weight)
        try c.encode(reps, forKey: .reps)
        try c.encodeIfPresent(targetWeight, forKey: .targetWeight)
        try c.encodeIfPresent(targetReps, forKey: .targetReps)
        try c.encode(weightNum, forKey: .weightNum)
        try c.encode(repsNum, forKey: .repsNum)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// The whole database, saved as one JSON file (same shape as the old web app's blob, so its backups import).
struct Snapshot: Codable, Sendable {
    var days: [Day] = []
    var exercises: [Exercise] = []
    var sessions: [Session] = []
    var sets: [WorkoutSet] = []
    /// Optional on purpose: absent (older writer) is different from empty.
    var programWeeks: [ProgramWeek]?
    var schema: Int?

    var maxUpdatedAt: EpochMs {
        var m: EpochMs = 0
        for d in days { m = max(m, d.updatedAt ?? 0) }
        for e in exercises { m = max(m, e.updatedAt) }
        for s in sessions { m = max(m, s.updatedAt) }
        for s in sets { m = max(m, s.updatedAt) }
        for w in programWeeks ?? [] { m = max(m, w.updatedAt) }
        return m
    }
}

func nowMs() -> EpochMs { (Date().timeIntervalSince1970 * 1000).rounded() }
func newID() -> String { UUID().uuidString.lowercased() }
