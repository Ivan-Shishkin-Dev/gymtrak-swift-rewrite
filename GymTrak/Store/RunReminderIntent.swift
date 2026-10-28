import AppIntents
import Foundation
import UserNotifications

/// "Run Reminder": a Shortcuts automation runs it when an outdoor run starts on the Apple Watch
/// (Shortcuts → Automation → Apple Watch Workout → Is Started). It sends today's run as a notification,
/// then a cue at each change (halfway, strides, warm-up done…). They show on the wrist while the phone is in your pocket.
struct RunReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Reminder"
    static let description = IntentDescription("Sends today's run: how long and what heart rate.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cues = Self.loadSnapshot().runCues(runs: Self.loadRuns())
        await Self.schedule(cues)
        return .result(value: cues.map { "\(Int($0.at)) min: \($0.title)" }.joined(separator: "\n"))
    }

    /// The first cue now, the rest at their minute. Replaces cues from an earlier run.
    static func schedule(_ cues: [RunCue], start: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        await cancelCues()
        for (i, cue) in cues.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = cue.title
            content.body = cue.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let delay = start.addingTimeInterval(cue.at * 60).timeIntervalSinceNow
            let trigger = delay > 1 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
            try? await center.add(UNNotificationRequest(identifier: "run-cue-\(i)", content: content, trigger: trigger))
        }
    }

    static func cancelCues() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("run-cue-") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // Read straight from the files the app keeps, so this works with the phone locked and the app closed.

    private static func loadSnapshot() -> Snapshot {
        let url = URL.documentsDirectory.appending(path: "gymtrak.json")
        guard let data = try? Data(contentsOf: url), let db = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(programWeeks: [])
        }
        return db
    }

    private static func loadRuns() -> [RunActivity] {
        let url = URL.documentsDirectory.appending(path: "runs.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RunActivity].self, from: data)) ?? []
    }
}

/// "End Run Reminders": for an Apple Watch Workout → Is Ended automation, so cues stop if you finish early.
struct EndRunRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "End Run Reminders"
    static let description = IntentDescription("Cancels the rest of today's run cues.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await RunReminderIntent.cancelCues()
        return .result()
    }
}

struct GymTrakPhoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunReminderIntent(), phrases: ["Run reminder in \(.applicationName)"],
                    shortTitle: "Run Reminder", systemImageName: "figure.run")
        AppShortcut(intent: EndRunRemindersIntent(), phrases: ["End run reminders in \(.applicationName)"],
                    shortTitle: "End Run Reminders", systemImageName: "stop.circle")
    }
}
