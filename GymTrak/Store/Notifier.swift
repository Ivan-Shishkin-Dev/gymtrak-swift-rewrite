import Foundation
import UserNotifications

/// Which reminders are on and when. Stored in UserDefaults; times are minutes after midnight.
struct NotificationPrefs: Equatable {
    var workout = true, workoutTime = 7 * 60
    var missed = true, missedTime = 20 * 60
    var recap = true                       // Sunday 7 PM
    var rest = true

    static let recapTime = 19 * 60

    enum Key {
        static let workout = "gt_n_workout", workoutTime = "gt_n_workout_time"
        static let missed = "gt_n_missed", missedTime = "gt_n_missed_time"
        static let recap = "gt_n_recap"
        static let rest = "gt_n_rest"
    }

    static var current: NotificationPrefs {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
        let x = NotificationPrefs()
        return NotificationPrefs(workout: bool(Key.workout, x.workout), workoutTime: int(Key.workoutTime, x.workoutTime),
                                 missed: bool(Key.missed, x.missed), missedTime: int(Key.missedTime, x.missedTime),
                                 recap: bool(Key.recap, x.recap),
                                 rest: bool(Key.rest, x.rest))
    }
}

/// One local notification to schedule.
struct PlannedNotification: Equatable {
    var id: String
    var title: String
    var body: String
    var fireDate: Date
}

enum Notifier {
    static let prefix = "gt-"

    /// Everything to schedule for the next 7 days. Pure, so tests can check it.
    static func plan(_ db: Snapshot, runs: [RunActivity], prefs: NotificationPrefs, now: Date = Date()) -> [PlannedNotification] {
        let data = db.widgetData(runs: runs, now: now)
        let cal = DateKey.calendar
        let today = cal.startOfDay(for: now)
        var out: [PlannedNotification] = []

        func at(_ day: Date, _ minutes: Int) -> Date { day.addingTimeInterval(TimeInterval(minutes * 60)) }

        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let key = DateKey.key(day)
            let slot = data.slot(on: day)
            let done = data.isDone(day)

            if slot.kind != .rest && !done {
                if prefs.workout, at(day, prefs.workoutTime) > now {
                    let body = slot.coach.map { "Shoot for \($0)." } ?? (slot.detail.isEmpty ? "Let's go." : slot.detail)
                    out.append(.init(id: "\(prefix)workout-\(key)", title: "\(slot.title) today", body: body,
                                     fireDate: at(day, prefs.workoutTime)))
                }
                if prefs.missed, at(day, prefs.missedTime) > now {
                    out.append(.init(id: "\(prefix)missed-\(key)", title: "\(slot.title) isn't logged yet",
                                     body: "Still time to keep the week clean.", fireDate: at(day, prefs.missedTime)))
                }
            }

            if prefs.recap, DateKey.dow(day) == .sun, at(day, NotificationPrefs.recapTime) > now {
                out.append(.init(id: "\(prefix)recap-\(key)", title: "Your week",
                                 body: recapText(db, data: data, runs: runs, sunday: day),
                                 fireDate: at(day, NotificationPrefs.recapTime)))
            }
        }
        return out.sorted { $0.fireDate < $1.fireDate }
    }

    /// "4 of 5 workouts · 32k lb · 9.1 mi"
    static func recapText(_ db: Snapshot, data: WidgetData, runs: [RunActivity], sunday: Date) -> String {
        let p = data.weekProgress(sunday)
        let monday = DateKey.mondayKey(sunday)
        let sundayKey = DateKey.key(sunday)
        let lb = db.finishedLifts.filter { $0.slotDate >= monday && $0.slotDate <= sundayKey }
            .reduce(0) { $0 + db.sessionPounds($1.id) }
        let miles = db.allRuns(synced: runs).filter { $0.date >= monday && $0.date <= sundayKey }.reduce(0) { $0 + $1.miles }
        var parts = ["\(p.done) of \(p.planned) workouts"]
        if lb > 0 { parts.append(fmtPounds(lb)) }
        if miles > 0 { parts.append(String(format: "%.1f mi", miles)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Scheduling

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Replace every GymTrak reminder with a fresh plan.
    static func reschedule(_ db: Snapshot, runs: [RunActivity]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        for n in plan(db, runs: runs, prefs: .current) {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            let comps = DateKey.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: n.fireDate)
            try? await center.add(UNNotificationRequest(identifier: n.id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
}
