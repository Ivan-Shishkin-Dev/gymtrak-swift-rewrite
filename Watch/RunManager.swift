import CoreLocation
import HealthKit
import Observation
import UserNotifications
import WatchKit

/// Records an outdoor run on the watch: time, heart rate and zone, distance, pace, and the GPS route,
/// saved to Apple Health (so Strava still gets it). Buzzes the plan's cues at their minute and warns
/// when heart rate stays over the plan.
@MainActor
@Observable
final class RunManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, CLLocationManagerDelegate {
    static let shared = RunManager()

    enum Phase { case idle, running, paused, saving }

    /// What's on screen for a few seconds after a cue or a heart-rate warning.
    struct Banner: Equatable {
        var title: String
        var body: String
        var shownAt: Date
    }

    private(set) var phase = Phase.idle
    private(set) var heartRate: Double?
    private(set) var miles: Double = 0
    /// Seconds per mile, from the watch's running speed.
    private(set) var pace: Double?
    private(set) var plan: WatchState.RunPlan?
    var banner: Banner?
    /// "Saved · 3.12 mi · 30:05", shown on the Run screen after a run.
    private(set) var lastRun: String?
    /// Lower edge of zones 2–5, in bpm (Apple-style, from heart rate reserve).
    private(set) var zoneFloors: [Double] = [114, 133, 152, 171]

    private let health = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var route: HKWorkoutRouteBuilder?
    private let location = CLLocationManager()
    private var loop: Task<Void, Never>?
    private var fired: Set<Int> = []
    private var overSince: Date?
    private var lastWarning = Date.distantPast

    var isActive: Bool { phase != .idle }

    /// Active running time (pauses don't count).
    func elapsed(at date: Date = .now) -> TimeInterval { builder?.elapsedTime(at: date) ?? 0 }

    /// Where you are in the plan. Starts equal to `elapsed`; skipping a part moves it.
    func planTime(at date: Date = .now) -> TimeInterval { max(0, elapsed(at: date) + offset) }
    private var offset: TimeInterval = 0
    /// Where you were in each part when you skipped away from it (plan seconds), so Back resumes there.
    private var leftAt: [Int: TimeInterval] = [:]

    var canSkip: Bool { (plan?.segments?.count ?? 0) > 1 }

    /// Jump to the next part (+1) or the previous one (−1). Returning to a part you skipped away from
    /// picks up where you left it; a new part starts at its beginning and its cue fires.
    func skip(_ direction: Int) {
        guard let parts = plan?.segments, parts.count > 1, let cues = plan?.cues else { return }
        let t = planTime()
        let i = parts.lastIndex { t / 60 >= $0.from } ?? 0
        let j = i + (direction > 0 ? 1 : -1)
        guard parts.indices.contains(j) else { return }
        leftAt[i] = t
        // Back to a part you've been in (either way): pick up where you left it, without repeating its cue.
        let resume = leftAt[j]
        let target = resume.map { $0 / 60 } ?? parts[j].from
        offset = target * 60 - elapsed()
        fired = Set(cues.indices.filter { resume == nil ? cues[$0].at < target : cues[$0].at <= target })
        overSince = nil
        WKInterfaceDevice.current().play(direction > 0 ? .directionUp : .directionDown)
    }

    /// 1–5.
    func zone(for bpm: Double) -> Int { 1 + zoneFloors.filter { bpm >= $0 }.count }

    // MARK: Start / pause / end

    func start(_ plan: WatchState.RunPlan) async {
        guard phase == .idle else { return }
        await WorkoutManager.shared.stopForRun()
        self.plan = plan
        lastRun = nil
        fired = []
        offset = 0
        leftAt = [:]
        overSince = nil

        await requestHealth()
        await loadZones()

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .fitness
        location.requestWhenInUseAuthorization()

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: health, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            route = HKWorkoutRouteBuilder(healthStore: health, device: nil)
            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)
            location.startUpdatingLocation()
            phase = .running
            WKInterfaceDevice.current().play(.start)
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            reset()
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    /// Save the run (with its route) to Apple Health.
    func end() async {
        guard let session, let builder, phase != .saving else { return }
        phase = .saving
        loop?.cancel()
        location.stopUpdatingLocation()
        let time = elapsed(), distance = miles
        session.end()
        try? await builder.endCollection(at: .now)
        do {
            if let workout = try await builder.finishWorkout() {
                _ = try? await route?.finishRoute(with: workout, metadata: nil)
                lastRun = "Saved · \(String(format: "%.2f", distance)) mi · \(clock(time))"
            } else {
                lastRun = "Not saved to Health"
            }
        } catch {
            lastRun = "Not saved: \(error.localizedDescription)"
        }
        reset()
        WKInterfaceDevice.current().play(.success)
    }

    /// Throw the run away: nothing is saved to Apple Health.
    func discard() {
        guard let session, let builder, phase != .saving else { return }
        loop?.cancel()
        location.stopUpdatingLocation()
        session.end()
        builder.discardWorkout()
        lastRun = nil
        reset()
        WKInterfaceDevice.current().play(.click)
    }

    private func reset() {
        loop?.cancel()
        session = nil
        builder = nil
        route = nil
        phase = .idle
        heartRate = nil
        miles = 0
        pace = nil
        banner = nil
    }

    // MARK: Cues and heart-rate warnings

    /// Once a second: fire any cue whose minute has come; warn when heart rate stays high.
    private func tick() {
        guard phase == .running, let plan else { return }
        let t = planTime()
        for (i, cue) in plan.cues.enumerated() where i > 0 && !fired.contains(i) && t >= cue.at * 60 {
            fired.insert(i)
            alert(cue.title, cue.body)
        }
        // Over the plan for 30 s: easy runs above the zone, hard runs above the cap. At most once a minute.
        guard let hr = heartRate else { return }
        let limit = Double(plan.easy ? plan.zoneMax + 3 : plan.cap)
        if hr > limit {
            if overSince == nil { overSince = .now }
            if let since = overSince, Date.now.timeIntervalSince(since) >= 30, Date.now.timeIntervalSince(lastWarning) >= 60 {
                lastWarning = .now
                alert("HR \(Int(hr)) · ease off", "Back under \(plan.easy ? plan.zoneMax : plan.cap).")
            }
        } else {
            overSince = nil
        }
    }

    /// Strong taps and a banner with the app on screen; a notification when it isn't.
    private func alert(_ title: String, _ body: String) {
        banner = Banner(title: title, body: body, shownAt: .now)
        if WKApplication.shared().applicationState == .background {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "run-cue", content: content, trigger: nil))
        } else {
            Task {
                for _ in 0..<2 {
                    WKInterfaceDevice.current().play(.notification)
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
        }
    }

    // MARK: Health access

    static let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
                                                 HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned)]
    static let readTypes: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.distanceWalkingRunning),
                                               HKQuantityType(.activeEnergyBurned), HKQuantityType(.runningSpeed),
                                               HKQuantityType(.restingHeartRate), HKCharacteristicType(.dateOfBirth)]

    /// Ask once, when the app opens, so the prompt never has to appear mid-workout (or can't, in the background).
    private(set) var healthAllowed = HKHealthStore().authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized

    func requestHealth() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await health.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
        healthAllowed = health.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    // MARK: Zones

    /// Apple-style zones from heart rate reserve: 60/70/80/90 % between resting and max (220 − age).
    private func loadZones() async {
        var age = 30.0
        if let dob = try? health.dateOfBirthComponents(), let year = dob.year {
            age = Double(Calendar.current.component(.year, from: .now) - year)
        }
        var resting = 60.0
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.restingHeartRate))],
                                            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        if let sample = try? await query.result(for: health).first {
            resting = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }
        let maxHR = 220 - age
        zoneFloors = [0.6, 0.7, 0.8, 0.9].map { (resting + $0 * (maxHR - resting)).rounded() }
    }

    // MARK: Delegates

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard self.phase == .running || self.phase == .paused else { return }
            if toState == .paused { self.phase = .paused }
            if toState == .running { self.phase = .running }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hr = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity()?.doubleValue(for: bpm)
        let mi = workoutBuilder.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .mile())
        let speed = workoutBuilder.statistics(for: HKQuantityType(.runningSpeed))?.mostRecentQuantity()?
            .doubleValue(for: .meter().unitDivided(by: .second()))
        Task { @MainActor in
            if let hr { self.heartRate = hr }
            if let mi { self.miles = mi }
            if let speed, speed > 0.5 { self.pace = 1609.344 / speed }
            else if self.miles > 0.05 { self.pace = self.elapsed() / self.miles }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let good = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 50 }
        guard !good.isEmpty else { return }
        Task { @MainActor in try? await self.route?.insertRouteData(good) }
    }
}
