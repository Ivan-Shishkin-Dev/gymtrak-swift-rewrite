import Foundation
import Observation
import UserNotifications
import WatchConnectivity
import WatchKit
import WidgetKit

/// Watch side of the link: holds the phone's latest `WatchState` and sends actions back.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate, UNUserNotificationCenterDelegate {
    static let shared = WatchModel()

    private(set) var state: WatchState = WatchModel.cached() ?? .empty
    private(set) var reachable = false
    private var restTask: Task<Void, Never>?
    /// Sets ticked on the watch that the phone hasn't confirmed yet.
    private var pendingDone: Set<String> = []
    private var pendingSince = Date.distantPast

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Rest timer
    // Each button changes the screen right away; the phone's reply then confirms it.

    func addRest(_ seconds: Int) {
        guard let end = state.restEndsAt, end > .now else { return }
        WKInterfaceDevice.current().play(.click)
        var s = state
        s.restEndsAt = end.addingTimeInterval(TimeInterval(seconds))
        s.restTotal = (s.restTotal ?? Int(end.timeIntervalSinceNow.rounded())) + seconds
        apply(s, local: true)
        send(.addRest(seconds: seconds))
    }

    /// Start sits where Skip was, so a double tap on Skip mustn't start a new rest.
    private var skippedAt = Date.distantPast

    func skipRest() {
        skippedAt = .now
        WKInterfaceDevice.current().play(.click)
        var s = state
        s.restEndsAt = nil
        s.restTotal = nil
        apply(s, local: true)
        send(.skipRest)
    }

    func startRest() {
        guard Date.now.timeIntervalSince(skippedAt) > 1 else { return }
        WKInterfaceDevice.current().play(.start)
        let seconds = state.restDefault ?? 180
        var s = state
        s.restEndsAt = .now.addingTimeInterval(TimeInterval(seconds))
        s.restTotal = seconds
        apply(s, local: true)
        send(.startRest)
    }

    /// Ask the phone for fresh state. Wakes the iPhone app in the background if it isn't running.
    func refresh() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        send(.refresh)
    }

    // The last state from the phone, so the watch never opens blank.
    private static let cacheKey = "gt_watch_state"

    private static func cached() -> WatchState? {
        WatchWire.decode(WatchState.self, from: UserDefaults.standard.data(forKey: cacheKey))
    }

    private static func cache(_ state: WatchState) {
        if let data = WatchWire.encode(state) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }

    /// Ask the phone to do something. Live message when the phone is reachable, queued otherwise.
    func send(_ action: WatchAction) {
        guard WCSession.isSupported(), let data = WatchWire.encode(action) else { return }
        let session = WCSession.default
        let payload = [WatchWire.actionKey: data]
        guard session.isReachable else {
            session.transferUserInfo(payload)
            return
        }
        Self.sendLive(session, payload) { state in
            Task { @MainActor in WatchModel.shared.apply(state) }
        }
    }

    /// WatchConnectivity calls these handlers on its own background queue, so they must not be
    /// main-actor closures (Swift 6 traps on the isolation check). Built here, outside the actor.
    nonisolated private static func sendLive(_ session: WCSession, _ payload: [String: Any],
                                             onState: @escaping @Sendable (WatchState) -> Void) {
        session.sendMessage(payload, replyHandler: { reply in
            if let state = WatchWire.decode(WatchState.self, from: reply[WatchWire.stateKey]) { onState(state) }
        }, errorHandler: { _ in
            session.transferUserInfo(payload)
        })
    }

    /// Mark the current set done (the big button, and the Action Button shortcut).
    func logSet() {
        guard var w = state.workout, let cur = w.current else { return }
        WKInterfaceDevice.current().play(.success)
        send(.toggle(setId: cur.setId))
        // Move on right away; the phone's state catches up and replaces this.
        pendingDone.insert(cur.setId)
        pendingSince = .now
        var s = state
        w.queue.removeAll { $0.setId == cur.setId }
        w.current = w.queue.first
        w.done += 1
        s.workout = w
        s.restEndsAt = .now.addingTimeInterval(TimeInterval(cur.restSeconds ?? 180))
        apply(s, local: true)
    }

    func apply(_ incoming: WatchState, local: Bool = false) {
        var new = incoming
        if !local { new = mergingPending(incoming) }
        let old = state
        state = new
        if !local { Self.cache(incoming) }
        if let w = new.widget, w != old.widget {
            w.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
        if new.restEndsAt != old.restEndsAt { scheduleRestHaptic(new.restEndsAt) }
        WorkoutManager.shared.follow(new)
    }

    /// Buzz when rest is over. With the app open, three strong taps. Otherwise a notification does it;
    /// it shares the phone's "rest-done" id, so the phone's copy doesn't buzz a second time.
    private func scheduleRestHaptic(_ end: Date?) {
        restTask?.cancel()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.restNotificationID])
        guard let end, end > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rest's up"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.restNotificationID, content: content, trigger: trigger))

        restTask = Task {
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
            guard !Task.isCancelled, WKApplication.shared().applicationState != .background else { return }
            for _ in 0..<3 {
                WKInterfaceDevice.current().play(.notification)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private static let restNotificationID = "rest-done"

    /// With the app on screen, the taps above are the alert; don't also show the notification.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    /// Keep sets the watch already ticked out of the queue until the phone reports them done
    /// (or 20 s pass, in case the tap never arrived).
    private func mergingPending(_ incoming: WatchState) -> WatchState {
        guard var w = incoming.workout, !pendingDone.isEmpty else { return incoming }
        let stillPending = Set(w.queue.map(\.setId)).intersection(pendingDone)
        if stillPending.isEmpty || Date.now.timeIntervalSince(pendingSince) > 20 {
            pendingDone.removeAll()
            return incoming
        }
        var s = incoming
        w.queue.removeAll { stillPending.contains($0.setId) }
        w.current = w.queue.first
        w.done += stillPending.count
        s.workout = w
        if s.restEndsAt == nil { s.restEndsAt = state.restEndsAt }
        return s
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let state = WatchWire.decode(WatchState.self, from: session.receivedApplicationContext[WatchWire.stateKey])
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if let state { self.apply(state) }
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = WatchWire.decode(WatchState.self, from: applicationContext[WatchWire.stateKey])
        Task { @MainActor in if let state { self.apply(state) } }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable { self.refresh() }
        }
    }
}
