import AppIntents
import WatchKit

/// The only workout style GymTrak starts.
enum GymWorkoutStyle: String, AppEnum {
    case strength
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workout"
    static let caseDisplayRepresentations: [GymWorkoutStyle: DisplayRepresentation] = [.strength: "Today's Lift"]
}

/// Lets the Ultra's Action Button start today's lift.
struct StartGymTrakWorkout: StartWorkoutIntent {
    static let title: LocalizedStringResource = "Start Today's Lift"

    @Parameter(title: "Workout")
    var workoutStyle: GymWorkoutStyle

    static var suggestedWorkouts: [StartGymTrakWorkout] { [StartGymTrakWorkout(style: .strength)] }

    var displayRepresentation: DisplayRepresentation { "Today's Lift" }

    init() { workoutStyle = .strength }

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchModel.shared.send(.start)
        return .result()
    }
}

/// "Log Set": assign it to the Action Button (Settings → Action Button → Shortcut) to tick the current set.
struct LogSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Set"
    static let description = IntentDescription("Marks the current set done.")

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchModel.shared.logSet()
        return .result()
    }
}

struct GymTrakShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogSetIntent(), phrases: ["Log a set in \(.applicationName)"],
                    shortTitle: "Log Set", systemImageName: "checkmark")
    }
}
