import Foundation
import WatchConnectivity

extension Snapshot {
    /// The open lift's sets in workout order, paired with their exercise.
    func orderedSets(_ session: Session) -> [(set: WorkoutSet, ex: Exercise)] {
        let all = sets(of: session.id)
        return exercises(of: session.dayId).flatMap { ex in
            all.filter { $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }.map { ($0, ex) }
        }
    }

    /// What the watch should show right now.
    func watchState(now: Date = Date(), runs: [RunActivity] = [], restEndsAt: Date? = nil) -> WatchState {
        let todayKey = DateKey.key(now)
        let week = scheduleWeek(now)
        let slot = week?.slot(DateKey.dow(now))
        let liftDay = day(slot?.liftDayId)
        let done = doneDates.union(runs.map(\.date))
        let planned = Dow.allCases.filter { !(week?.slot($0)?.isRest ?? true) }
        let weekDone = planned.filter { dow in week.map { done.contains($0.date(of: dow)) } ?? false }.count

        let title = liftDay?.name ?? slot?.run?.label.rawValue ?? "Rest Day"
        var detail = ""
        if let liftDay {
            detail = "\(exercises(of: liftDay.id).count) lifts" + (slot?.run.map { " · \($0.durationMin) min run" } ?? "")
        } else if let run = slot?.run {
            detail = "\(run.durationMin) min"
        }

        var state = WatchState(todayTitle: title, todayDetail: detail, canStart: liftDay != nil,
                               todayDone: done.contains(todayKey), weekDone: weekDone, weekPlanned: planned.count,
                               streak: streakWeeks(today: now, doneExtra: Set(runs.map(\.date))),
                               restEndsAt: restEndsAt, widget: widgetData(runs: runs, now: now))
        state.lifts = liftDay.map { exercises(of: $0.id).count }
        state.runMinutes = slot?.run?.durationMin

        if let open = openLift() {
            let ordered = orderedSets(open)
            let pending = ordered.filter { !$0.set.isDone }
            var advice: [String: LiftAdvice] = [:]
            let queue: [WatchState.Current] = pending.map { a in
                let siblings = ordered.filter { $0.ex.id == a.ex.id }
                let n = (siblings.firstIndex { $0.set.id == a.set.id } ?? 0) + 1
                let adv = advice[a.ex.id] ?? liftAdvice(for: a.ex, deload: open.deload ?? false, today: open.slotDate)
                advice[a.ex.id] = adv
                return .init(setId: a.set.id, exercise: a.ex.name, setNumber: n, setCount: siblings.count,
                             weight: a.set.weight, reps: bareReps(a.set.reps), target: adv.target(forSet: n - 1),
                             canStepLoad: a.ex.effectiveLoadType != .free, restSeconds: a.ex.restSeconds)
            }
            let current = queue.first
            var next: String?
            if pending.count > 1 {
                let b = pending[1]
                if let a = pending.first, b.ex.id == a.ex.id {
                    let n = (ordered.filter { $0.ex.id == b.ex.id }.firstIndex { $0.set.id == b.set.id } ?? 0) + 1
                    next = "Set \(n) · \(b.set.weight.isEmpty ? "—" : b.set.weight) × \(bareReps(b.set.reps))"
                } else {
                    next = b.ex.name
                }
            }
            state.workout = .init(sessionId: open.id, dayName: open.dayNameSnapshot ?? day(open.dayId)?.name ?? "Workout",
                                  startedAt: Date(timeIntervalSince1970: open.startedAt / 1000),
                                  done: ordered.count - pending.count, total: ordered.count, current: current, next: next,
                                  queue: queue)
        }
        return state
    }
}

/// Phone side of the watch link: pushes `WatchState` and runs the watch's actions on the store.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private weak var store: Store?
    private var rest: RestTimer?
    private var runs: [RunActivity] = []
    private var lastSent: WatchState?

    /// The watch app is installed, so it records the workout to Apple Health (the phone shouldn't too).
    var watchRecordsWorkouts: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated
            && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }

    func start(store: Store, rest: RestTimer) {
        self.store = store
        self.rest = rest
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Send the latest state if it changed.
    func push(runs: [RunActivity]? = nil) {
        if let runs { self.runs = runs }
        guard let store, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        let state = store.db.watchState(runs: self.runs, restEndsAt: rest?.endsAt)
        guard state != lastSent, let data = WatchWire.encode(state) else { return }
        lastSent = state
        try? WCSession.default.updateApplicationContext([WatchWire.stateKey: data])
    }

    /// Run one action from the watch.
    func handle(_ action: WatchAction) {
        guard let store else { return }
        switch action {
        case .start:
            guard store.db.openLift() == nil, let week = store.db.scheduleWeek(Date()),
                  let day = store.db.day(week.slot(DateKey.dow(Date()))?.liftDayId) else { break }
            store.mutate { $0.startSession(day: day, options: StartOptions(scheduledDate: DateKey.key(Date()), coach: Coach.autoApply)) }
        case .toggle(let id):
            // The watch only sends this for sets still to do; a retried message must not undo it.
            guard store.db.sets.first(where: { $0.id == id })?.isDone == false else { break }
            let nowDone = store.mutate { $0.toggleSet(id) } ?? false
            if nowDone, RestTimer.autoStart {
                let ex = store.db.sets.first { $0.id == id }.flatMap { s in store.db.exercises.first { $0.id == s.exerciseId } }
                rest?.start(ex?.restSeconds)
            }
        case .stepLoad(let id, let dir):
            guard let st = store.db.sets.first(where: { $0.id == id }),
                  let ex = store.db.exercises.first(where: { $0.id == st.exerciseId }),
                  let w = stepLoad(st.weight, type: ex.effectiveLoadType, increment: ex.effectiveIncrement, direction: dir) else { break }
            store.mutate { $0.updateSetLoad(id, weight: w, reps: st.reps) }
        case .stepReps(let id, let dir):
            guard let st = store.db.sets.first(where: { $0.id == id }) else { break }
            let n = Int(bareReps(st.reps)) ?? 0
            store.mutate { $0.updateSetLoad(id, weight: st.weight, reps: "× \(max(0, n + dir))") }
        case .skipRest:
            rest?.stop()
        case .addRest(let s):
            rest?.add(s)
        case .finish:
            rest?.stop()
            if let open = store.db.openLift() { store.mutate { $0.finishSession(open.id) } }
        }
        push()
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.lastSent = nil; self.push() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let action = WatchWire.decode(WatchAction.self, from: message[WatchWire.actionKey])
        let reply = UncheckedReply(replyHandler)
        Task { @MainActor in
            if let action { self.handle(action) }
            let state = self.store?.db.watchState(runs: self.runs, restEndsAt: self.rest?.endsAt)
            reply.call(state.flatMap(WatchWire.encode).map { [WatchWire.stateKey: $0] } ?? [:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let action = WatchWire.decode(WatchAction.self, from: userInfo[WatchWire.actionKey]) else { return }
        Task { @MainActor in self.handle(action) }
    }
}

/// WatchConnectivity's reply handler isn't Sendable; it's safe to call once from any thread.
private struct UncheckedReply: @unchecked Sendable {
    let call: ([String: Any]) -> Void
    init(_ f: @escaping ([String: Any]) -> Void) { call = f }
}
