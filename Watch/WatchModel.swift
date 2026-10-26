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
        session.sendMessage(payload, replyHandler: { reply in
            let state = WatchWire.decode(WatchState.self, from: reply[WatchWire.stateKey])
            Task { @MainActor in if let state { self.apply(state) } }
        }, errorHandler: { _ in
            session.transferUserInfo(payload)
        })
    }

    /// Mark the current set done (the big button, and the Action Button shortcut).
    func logSet() {
        guard let id = state.workout?.current?.setId else { return }
        WKInterfaceDevice.current().play(.success)
        send(.toggle(setId: id))
    }

    func apply(_ new: WatchState) {
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
