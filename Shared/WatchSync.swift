import Foundation

/// Everything the watch shows. The phone owns the data and sends this whenever it changes.
struct WatchState: Codable, Equatable, Sendable {
    /// The set to do next.
    struct Current: Codable, Equatable, Sendable {
        var setId: String
        var exercise: String
        var setNumber: Int
        var setCount: Int
        var weight: String      // "135 lb", "4 pl + 25", "12"
        var reps: String        // "6"
        var target: String?     // coach: "135 lb × 6"
        var canStepLoad: Bool
        var restSeconds: Int?
        /// An optional warm-up set, not a working set.
        var warmup: Bool?
    }

    struct Workout: Codable, Equatable, Sendable {
        var sessionId: String
        var dayName: String
        var startedAt: Date
        var done: Int
        var total: Int
        var current: Current?
        /// "Set 2 · 125 lb × 6" or the next exercise's name.
        var next: String?
        /// Every set still to do, in order (current first), so the watch can move on without waiting for the phone.
        var queue: [Current] = []
    }

    /// Today's run for the watch's Run screen: what to aim for and the cues to buzz.
    struct RunPlan: Codable, Equatable, Sendable {
        struct Cue: Codable, Equatable, Sendable {
            var at: Double          // minutes into the run
            var title: String
            var body: String
        }
        var title: String           // "Easy Run · 30 min"
        var detail: String          // "HR 120–140, cap 145"
        var minutes: Double
        var zoneMin: Int
        var zoneMax: Int
        var cap: Int
        var easy: Bool
        var cues: [Cue]
    }

    var todayTitle: String          // "Upper A", "Long Run", "Rest Day"
    var todayDetail: String         // "8 lifts", "45 min"
    var lifts: Int? = nil           // exercises in today's lift
    var runMinutes: Int? = nil      // today's run length
    var canStart: Bool              // a lift is planned today
    var todayDone: Bool
    var weekDone: Int
    var weekPlanned: Int
    var streak: Int
    var workout: Workout?
    var restEndsAt: Date?
    /// Length of the running rest, for the ring.
    var restTotal: Int? = nil
    /// The phone's default rest, for Start.
    var restDefault: Int? = nil
    var runPlan: RunPlan? = nil
    /// Same summary the phone widgets use, for the watch complications.
    var widget: WidgetData?

    static let empty = WatchState(todayTitle: "Open GymTrak on iPhone", todayDetail: "", canStart: false, todayDone: false,
                                  weekDone: 0, weekPlanned: 0, streak: 0)

    init(todayTitle: String, todayDetail: String, canStart: Bool, todayDone: Bool, weekDone: Int, weekPlanned: Int,
         streak: Int, workout: Workout? = nil, restEndsAt: Date? = nil, widget: WidgetData? = nil) {
        self.todayTitle = todayTitle; self.todayDetail = todayDetail; self.canStart = canStart; self.todayDone = todayDone
        self.weekDone = weekDone; self.weekPlanned = weekPlanned; self.streak = streak
        self.workout = workout; self.restEndsAt = restEndsAt; self.widget = widget
    }
}

/// What the watch asks the phone to do.
enum WatchAction: Codable, Equatable, Sendable {
    case start
    case toggle(setId: String)
    case stepLoad(setId: String, direction: Int)
    case stepReps(setId: String, direction: Int)
    case skipRest
    case addRest(seconds: Int)
    case finish
    /// Start a rest of this length.
    case startRest(seconds: Int)
    /// Send the latest state; the watch asks when it opens.
    case refresh
}

/// WatchConnectivity carries plist dictionaries; these wrap the Codable payloads.
enum WatchWire {
    static let stateKey = "state"
    static let actionKey = "action"
    /// When the watch sent it (seconds since 1970). Queued messages can arrive minutes late.
    static let sentAtKey = "sentAt"

    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from any: Any?) -> T? {
        guard let data = any as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
