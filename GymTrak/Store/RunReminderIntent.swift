import AppIntents
import Foundation
import UserNotifications

/// "Run Reminder": a Shortcuts automation runs it when an outdoor run starts on the Apple Watch
/// (Shortcuts → Automation → Apple Watch Workout → Is Started). It sends today's run as a notification,
/// which shows on the wrist while the phone is in your pocket.
struct RunReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Reminder"
    static let description = IntentDescription("Sends today's run: how long and what heart rate.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let brief = Self.loadSnapshot().runBrief(runs: Self.loadRuns())
        let content = UNMutableNotificationContent()
        content.title = brief.title
        content.body = brief.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "run-brief", content: content, trigger: nil))
        return .result(value: "\(brief.title)\n\(brief.body)")
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

struct GymTrakPhoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunReminderIntent(), phrases: ["Run reminder in \(.applicationName)"],
                    shortTitle: "Run Reminder", systemImageName: "figure.run")
    }
}
