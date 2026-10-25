import Foundation
import Observation
import UserNotifications

/// The in-workout rest countdown. Timestamp-based, so it stays right after the app
/// is backgrounded; a local notification fires when rest is over.
@MainActor
@Observable
final class RestTimer {
    static let minSec = 15
    static let maxSec = 600

    private(set) var startedAt: Date?
    private(set) var targetSec: Int
    private(set) var defaultSec: Int

    var isActive: Bool { startedAt != nil }

    private static let defaultKey = "gt_rest_default"
    private static let activeKey = "gt_rest_active"
    private static let notificationID = "rest-done"

    init() {
        let d = UserDefaults.standard.integer(forKey: Self.defaultKey)
        let initial = d > 0 ? Self.clamp(d) : 180
        defaultSec = initial
        targetSec = initial
        if let saved = UserDefaults.standard.dictionary(forKey: Self.activeKey),
           let start = saved["startedAt"] as? Double, let target = saved["targetSec"] as? Int {
            let age = Date().timeIntervalSince1970 - start
            if age >= 0 && age < Double(target + 60) {
                startedAt = Date(timeIntervalSince1970: start)
                targetSec = target
            }
        }
    }

    static func clamp(_ s: Int) -> Int { min(maxSec, max(minSec, s)) }

    /// Start rest automatically when a set is ticked done. Defaults on.
    static let autoKey = "gt_rest_auto"
    static var autoStart: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }

    /// Seconds left; negative once overrun.
    func remaining(at now: Date) -> Double {
        guard let startedAt else { return Double(targetSec) }
        return Double(targetSec) - now.timeIntervalSince(startedAt)
    }

    func start(_ seconds: Int? = nil) {
        startedAt = Date()
        targetSec = Self.clamp(seconds ?? defaultSec)
        persist()
    }

    /// Nudge this rest only (±15 s).
    func add(_ delta: Int) {
        guard isActive else { return }
        targetSec = Self.clamp(targetSec + delta)
        persist()
    }

    /// Change the default for future rests; restarts a running rest at the new length.
    func setDefault(_ sec: Int) {
        defaultSec = Self.clamp(sec)
        UserDefaults.standard.set(defaultSec, forKey: Self.defaultKey)
        if isActive { start(defaultSec) }
    }

    func stop() {
        guard isActive else { return }
        startedAt = nil
        persist()
    }

    private func persist() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        guard let startedAt else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
            return
        }
        UserDefaults.standard.set(["startedAt": startedAt.timeIntervalSince1970, "targetSec": targetSec], forKey: Self.activeKey)
        let left = remaining(at: Date())
        guard left > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest's up"
        content.body = "Time for the next set."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: left, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger))
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
