import Foundation
import HealthKit
import Observation

/// Runs a strength workout session while the phone has a workout open: live heart rate and
/// calories, saved to Apple Health when the workout ends with sets logged.
@MainActor
@Observable
final class WorkoutManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let shared = WorkoutManager()

    private(set) var heartRate: Double?
    private(set) var calories: Double = 0
    private(set) var running = false

    private let health = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var sessionId: String?
    private var setsDone = 0
    /// Started by the phone's Start Workout before the phone's state (with the workout's id) arrives.
    private static let pending = "pending"
    private var pendingSince = Date.distantPast

    /// Start or end the Health session to match the phone's workout.
    func follow(_ state: WatchState) {
        guard !RunManager.shared.isActive else { return }   // one session at a time; the run wins
        if let w = state.workout {
            setsDone = w.done
            if sessionId == Self.pending { sessionId = w.sessionId }       // the phone's workout we were launched for
            else if sessionId != w.sessionId { Task { await start(w.sessionId, at: w.startedAt) } }
        } else if sessionId == Self.pending, Date.now.timeIntervalSince(pendingSince) < 60 {
            // Launched by the phone; its state with the workout hasn't arrived yet.
        } else if sessionId != nil {
            let keep = setsDone > 0
            Task { await end(save: keep) }
        }
    }

    /// The phone's Start Workout launched the watch app: start recording now.
    func startFromPhone() {
        guard sessionId == nil, !RunManager.shared.isActive else { return }
        pendingSince = .now
        Task { await start(Self.pending, at: .now) }
    }

    /// End the lift session before a run starts (saved if any sets were logged).
    func stopForRun() async {
        guard sessionId != nil else { return }
        await end(save: setsDone > 0)
    }

    private func start(_ id: String, at start: Date) async {
        if sessionId != nil { await end(save: false) }
        sessionId = id
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        try? await health.requestAuthorization(toShare: share, read: read)

        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: health, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let begin = min(start, .now)
            session.startActivity(with: begin)
            try await builder.beginCollection(at: begin)
            running = true
        } catch {
            sessionId = nil
        }
    }

    private func end(save: Bool) async {
        let session = self.session, builder = self.builder
        self.session = nil
        self.builder = nil
        sessionId = nil
        running = false
        heartRate = nil
        calories = 0
        guard let session, let builder else { return }
        session.end()
        try? await builder.endCollection(at: .now)
        if save { _ = try? await builder.finishWorkout() } else { builder.discardWorkout() }
    }

    // MARK: Delegates

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hr = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity()?.doubleValue(for: bpm)
        let kcal = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in
            if let hr { self.heartRate = hr }
            if let kcal { self.calories = kcal }
        }
    }
}
