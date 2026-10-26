import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

/// Watch side of the link: holds the phone's latest `WatchState` and sends actions back.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    static let shared = WatchModel()

    private(set) var state: WatchState = .empty
    private(set) var reachable = false
    private var restTask: Task<Void, Never>?
    /// Sets ticked on the watch that the phone hasn't confirmed yet.
    private var pendingDone: Set<String> = []
    private var pendingSince = Date.distantPast

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
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
        if let w = new.widget, w != old.widget {
            w.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
        if new.restEndsAt != old.restEndsAt { scheduleRestHaptic(new.restEndsAt) }
        WorkoutManager.shared.follow(new)
    }

    /// Tap the wrist when rest is over.
    private func scheduleRestHaptic(_ end: Date?) {
        restTask?.cancel()
        guard let end, end > .now else { return }
        restTask = Task {
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.notification)
            try? await Task.sleep(for: .milliseconds(600))
            WKInterfaceDevice.current().play(.notification)
        }
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
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = WatchWire.decode(WatchState.self, from: applicationContext[WatchWire.stateKey])
        Task { @MainActor in if let state { self.apply(state) } }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }
}
