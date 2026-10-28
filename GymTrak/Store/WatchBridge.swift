import Foundation
import HealthKit
import WatchConnectivity

extension Snapshot {
    /// What the watch should show right now.
    func watchState(now: Date = Date(), runs: [RunActivity] = [], restEndsAt: Date? = nil,
                    restTotal: Int? = nil, restDefault: Int? = nil) -> WatchState {
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
        state.restTotal = restEndsAt == nil ? nil : restTotal
        state.restDefault = restDefault
        state.runPlan = runPlan(now: now, runs: runs)
        state.lifts = liftDay.map { exercises(of: $0.id).count }
        state.runMinutes = slot?.run?.durationMin

        if let open = openLift() {
            let items = workoutItems(open)
            let pending = pendingItems(open)
            let working = items.filter { !$0.warmup }
            var advice: [String: LiftAdvice] = [:]
            let queue: [WatchState.Current] = pending.map { a in
                let siblings = items.filter { $0.ex.id == a.ex.id && $0.warmup == a.warmup }
                let n = (siblings.firstIndex { $0.set.id == a.set.id } ?? 0) + 1
                let adv = advice[a.ex.id] ?? liftAdvice(for: a.ex, deload: open.deload ?? false, today: open.slotDate)
                advice[a.ex.id] = adv
                return .init(setId: a.set.id, exercise: a.ex.name, setNumber: n, setCount: siblings.count,
                             weight: a.set.weight, reps: bareReps(a.set.reps), target: a.warmup ? nil : adv.target(forSet: n - 1),
                             canStepLoad: a.ex.effectiveLoadType != .free,
                             restSeconds: a.warmup ? warmupRestSec : a.ex.restSeconds, warmup: a.warmup ? true : nil)
            }
            let current = queue.first
            var next: String?
            if pending.count > 1 {
                let b = pending[1]
                // Same exercise: the next set's load. A new exercise: just its name.
                if let a = pending.first, b.ex.id == a.ex.id {
                    next = "\(b.set.weight.isEmpty ? "—" : b.set.weight) × \(bareReps(b.set.reps))"
                } else {
                    next = b.ex.name
                }
            }
            state.workout = .init(sessionId: open.id, dayName: open.dayNameSnapshot ?? day(open.dayId)?.name ?? "Workout",
                                  startedAt: Date(timeIntervalSince1970: open.startedAt / 1000),
                                  done: working.filter(\.set.isDone).count, total: working.count, current: current, next: next,
                                  queue: queue)
        }
        return state
    }
}

extension Snapshot {
    /// Today's run for the watch. With nothing planned, a free easy run.
    func runPlan(now: Date, runs: [RunActivity]) -> WatchState.RunPlan {
        let cues = runCues(now: now, runs: runs)
        let rx = scheduleWeek(now)?.slot(DateKey.dow(now))?.run
        let (lo, hi, cap) = rx.map { ($0.hrZoneMin, $0.hrZoneMax, $0.hrHardCap) } ?? defaultHR(.easy)
        let easy = rx?.label.isEasy ?? true
        let total = cues.last?.at ?? 0
        return .init(title: rx.map { "\($0.label.rawValue) · \(Int(total)) min" } ?? "Free Run",
                     detail: easy ? "HR \(zoneLabel(lo, hi)), cap \(cap)" : "HR cap \(cap)",
                     minutes: total, zoneMin: lo, zoneMax: hi, cap: cap, easy: easy,
                     cues: rx == nil ? [] : cues.map { .init(at: $0.at, title: $0.title, body: $0.body) },
                     segments: runSegments(now: now, runs: runs).map { .init(name: $0.name, from: $0.from, to: $0.to, aim: $0.aim) })
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

    /// Open the watch app and start its strength workout, so heart rate records the whole lift
    /// and the workout lands in Apple Health (and Strava) without opening the watch app first.
    func launchWatchWorkout() {
        guard watchRecordsWorkouts, HKHealthStore.isHealthDataAvailable() else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        health.startWatchApp(with: config) { _, _ in }
    }

    private let health = HKHealthStore()

    /// Lifts the watch confirmed it's recording to Apple Health.
    private var recording: Set<String> = []

    /// True when the watch said it's saving this lift; otherwise the phone saves it.
    func watchIsRecording(_ sessionId: String) -> Bool { recording.contains(sessionId) }

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
        let state = currentState(store)
        guard state != lastSent, let data = WatchWire.encode(state) else { return }
        lastSent = state
        try? WCSession.default.updateApplicationContext([WatchWire.stateKey: data])
    }

    private func currentState(_ store: Store) -> WatchState {
        store.db.watchState(runs: runs, restEndsAt: rest?.endsAt, restTotal: rest?.targetSec, restDefault: rest?.defaultSec)
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
            guard store.db.anySet(id)?.isDone == false else { break }
            let nowDone = store.mutate { $0.toggleSet(id) } ?? false
            if nowDone, RestTimer.autoStart {
                let ex = store.db.anySet(id).flatMap { s in store.db.exercises.first { $0.id == s.exerciseId } }
                rest?.start(store.db.isWarmup(id) ? warmupRestSec : ex?.restSeconds)
            }
        case .stepLoad(let id, let dir):
            guard let st = store.db.anySet(id),
                  let ex = store.db.exercises.first(where: { $0.id == st.exerciseId }),
                  let w = stepLoad(st.weight, type: ex.effectiveLoadType, increment: ex.effectiveIncrement, direction: dir) else { break }
            store.mutate { $0.updateSetLoad(id, weight: w, reps: st.reps) }
        case .stepReps(let id, let dir):
            guard let st = store.db.anySet(id) else { break }
            let n = Int(bareReps(st.reps)) ?? 0
            store.mutate { $0.updateSetLoad(id, weight: st.weight, reps: "× \(max(0, n + dir))") }
        case .skipRest:
            rest?.stop()
        case .startRest(let seconds):
            rest?.start(seconds)
        case .addRest(let s):
            rest?.add(s)
        case .finish:
            rest?.stop()
            if let open = store.db.openLift() { store.mutate { $0.finishSession(open.id) } }
        case .refresh:
            lastSent = nil      // send it even if nothing changed
        case .recording(let id):
            recording.insert(id)
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
        let action = Self.fresh(message)
        let reply = UncheckedReply(replyHandler)
        Task { @MainActor in
            if let action { self.handle(action) }
            let state = self.store.map(self.currentState)
            reply.call(state.flatMap(WatchWire.encode).map { [WatchWire.stateKey: $0] } ?? [:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let action = Self.fresh(userInfo) else { return }
        Task { @MainActor in self.handle(action) }
    }

    /// The action, unless it's a rest-timer tap that arrived more than 15 s late
    /// (a queued Skip must not cancel a rest started since).
    nonisolated static func fresh(_ payload: [String: Any], now: Date = Date()) -> WatchAction? {
        guard let action = WatchWire.decode(WatchAction.self, from: payload[WatchWire.actionKey]) else { return nil }
        switch action {
        case .startRest, .addRest, .skipRest:
            if let sent = payload[WatchWire.sentAtKey] as? Double, now.timeIntervalSince1970 - sent > 15 { return nil }
        default: break
        }
        return action
    }
}

/// WatchConnectivity's reply handler isn't Sendable; it's safe to call once from any thread.
private struct UncheckedReply: @unchecked Sendable {
    let call: ([String: Any]) -> Void
    init(_ f: @escaping ([String: Any]) -> Void) { call = f }
}
