import Foundation
import Observation
import HealthKit
import Security

/// A run recorded somewhere else (Strava, Apple Health), matched to plan days by date.
struct RunActivity: Codable, Identifiable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case strava = "Strava", health = "Health" }
    var id: String
    var source: Source
    var name: String
    var date: String        // local yyyy-MM-dd
    var start: Date
    var minutes: Double
    var miles: Double
    var avgHR: Double?

    var summary: String {
        var parts = [String(format: "%.1f mi", miles), "\(Int(minutes.rounded())) min"]
        if let avgHR { parts.append("\(Int(avgHR)) bpm") }
        return parts.joined(separator: " · ")
    }
}

/// One day's movement from Apple Health.
struct DayActivity: Codable, Hashable, Sendable {
    var steps: Int = 0
    var calories: Double = 0     // active energy, kcal
    var miles: Double = 0        // walking + running
}

/// Strava + Apple Health, merged into one list of runs.
@MainActor
@Observable
final class Connections {
    private(set) var runs: [RunActivity] = []
    private(set) var stravaAthlete: String?
    private(set) var healthConnected = UserDefaults.standard.bool(forKey: "gt_health_on")
    private(set) var lastError: String?
    private(set) var refreshing = false
    /// Steps, active calories and distance by local date, Monday of last week through today.
    private(set) var activity: [String: DayActivity] = [:]
    /// Minutes asleep, by the date you woke up. Apple's Sleep Score itself isn't readable by other apps.
    private(set) var sleepMinutes: [String: Double] = [:]

    var stravaConnected: Bool { Keychain.get("strava") != nil }

    private let cacheURL = URL.documentsDirectory.appending(path: "runs.json")
    private let health = HKHealthStore()

    init() {
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([RunActivity].self, from: data) {
            runs = cached
        }
        stravaAthlete = UserDefaults.standard.string(forKey: "gt_strava_name")
    }

    /// Best run logged on a plan date (longest wins when there are several).
    func run(on date: String) -> RunActivity? {
        runs.filter { $0.date == date }.max { $0.minutes < $1.minutes }
    }

    /// Every date that has a recorded run.
    var runDates: Set<String> { Set(runs.map(\.date)) }

    // MARK: Refresh

    func refresh() async {
        guard !refreshing, stravaConnected || healthConnected else { return }
        refreshing = true
        defer { refreshing = false }
        var merged: [RunActivity] = []
        if stravaConnected {
            do { merged += try await stravaRuns() } catch { lastError = "Strava: \(error.localizedDescription)" }
        }
        if healthConnected {
            // Asks only for types not answered yet (sleep, for people who connected before it was added).
            try? await health.requestAuthorization(toShare: Self.healthShare, read: Self.healthRead)
            do { merged += try await healthRuns() } catch { lastError = "Health: \(error.localizedDescription)" }
            activity = await healthActivity()
            sleepMinutes = await healthSleep()
        }
        // Same run synced to both: keep the Strava copy (it has the name).
        var seen: [String: RunActivity] = [:]
        for r in merged.sorted(by: { $0.source == .strava && $1.source != .strava }) {
            let key = "\(r.date)-\(Int(r.start.timeIntervalSince1970 / 600))"
            if seen[key] == nil { seen[key] = r }
        }
        runs = seen.values.sorted { $0.start > $1.start }
        try? JSONEncoder().encode(runs).write(to: cacheURL, options: .atomic)
    }

    // MARK: Strava

    struct StravaConfig {
        let clientID: String
        let secret: String
        static func load() -> StravaConfig? {
            let info = Bundle.main.infoDictionary ?? [:]
            guard let id = info["StravaClientID"] as? String, !id.isEmpty, !id.contains("$("),
                  let secret = info["StravaClientSecret"] as? String, !secret.isEmpty, !secret.contains("$(") else { return nil }
            return StravaConfig(clientID: id, secret: secret)
        }
    }

    var stravaConfigured: Bool { StravaConfig.load() != nil }
    static let stravaCallbackScheme = "gymtrak"

    var stravaAuthURL: URL? {
        guard let cfg = StravaConfig.load() else { return nil }
        var c = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: cfg.clientID),
            .init(name: "redirect_uri", value: "gymtrak://strava"),
            .init(name: "response_type", value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: "activity:read_all"),
        ]
        return c.url
    }

    private struct StravaToken: Codable {
        var access_token: String
        var refresh_token: String
        var expires_at: Double
        var athlete: Athlete?
        struct Athlete: Codable { var firstname: String?; var lastname: String? }
    }

    /// Finish the OAuth flow with the callback URL Strava redirected to.
    func finishStrava(callback: URL) async {
        guard let cfg = StravaConfig.load(),
              let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
            lastError = "Strava didn't return a code."
            return
        }
        do {
            let token = try await stravaTokenRequest(cfg, ["code": code, "grant_type": "authorization_code"])
            let name = [token.athlete?.firstname, token.athlete?.lastname].compactMap { $0 }.joined(separator: " ")
            stravaAthlete = name.isEmpty ? "Connected" : name
            UserDefaults.standard.set(stravaAthlete, forKey: "gt_strava_name")
            lastError = nil
            await refresh()
        } catch {
            lastError = "Strava: \(error.localizedDescription)"
        }
    }

    func disconnectStrava() {
        Keychain.delete("strava")
        stravaAthlete = nil
        UserDefaults.standard.removeObject(forKey: "gt_strava_name")
        runs.removeAll { $0.source == .strava }
        try? JSONEncoder().encode(runs).write(to: cacheURL, options: .atomic)
    }

    private func stravaTokenRequest(_ cfg: StravaConfig, _ extra: [String: String]) async throws -> StravaToken {
        var r = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: extra.merging(["client_id": cfg.clientID, "client_secret": cfg.secret]) { a, _ in a })
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        let token = try JSONDecoder().decode(StravaToken.self, from: data)
        Keychain.set("strava", try JSONEncoder().encode(token))
        return token
    }

    /// A valid access token, refreshed when it's about to expire.
    private func stravaAccessToken() async throws -> String {
        guard let data = Keychain.get("strava"), var token = try? JSONDecoder().decode(StravaToken.self, from: data),
              let cfg = StravaConfig.load() else { throw URLError(.userAuthenticationRequired) }
        if token.expires_at < Date().timeIntervalSince1970 + 120 {
            let athlete = token.athlete
            token = try await stravaTokenRequest(cfg, ["refresh_token": token.refresh_token, "grant_type": "refresh_token"])
            token.athlete = athlete
        }
        return token.access_token
    }

    private struct StravaActivity: Decodable {
        let id: Int
        let name: String
        let sport_type: String?
        let type: String?
        let start_date: Date
        let moving_time: Double
        let distance: Double
        let average_heartrate: Double?
    }

    /// Runs from the last 90 days.
    private func stravaRuns() async throws -> [RunActivity] {
        let token = try await stravaAccessToken()
        let after = Int(Date().addingTimeInterval(-90 * 86_400).timeIntervalSince1970)
        var r = URLRequest(url: URL(string: "https://www.strava.com/api/v3/athlete/activities?after=\(after)&per_page=100")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: r)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StravaActivity].self, from: data)
            .filter { ($0.sport_type ?? $0.type ?? "").localizedCaseInsensitiveContains("run") }
            .map {
                RunActivity(id: "strava-\($0.id)", source: .strava, name: $0.name, date: DateKey.key($0.start_date),
                            start: $0.start_date, minutes: $0.moving_time / 60, miles: $0.distance / 1609.344,
                            avgHR: $0.average_heartrate)
            }
    }

    // MARK: Apple Health

    /// HealthKit needs an entitlement only paid developer teams get.
    var healthAvailable: Bool {
        (Bundle.main.infoDictionary?["HealthEnabled"] as? String)?.uppercased() == "YES" && HKHealthStore.isHealthDataAvailable()
    }

    private static let healthRead: Set<HKObjectType> = [
        HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKCategoryType(.sleepAnalysis)]
    private static let healthShare: Set<HKSampleType> = [HKObjectType.workoutType()]

    func connectHealth() async {
        guard healthAvailable else { return }
        do {
            try await health.requestAuthorization(toShare: Self.healthShare, read: Self.healthRead)
            healthConnected = true
            UserDefaults.standard.set(true, forKey: "gt_health_on")
            await refresh()
        } catch {
            lastError = "Health: \(error.localizedDescription)"
        }
    }

    func disconnectHealth() {
        healthConnected = false
        UserDefaults.standard.set(false, forKey: "gt_health_on")
        runs.removeAll { $0.source == .health }
    }

    private func healthRuns() async throws -> [RunActivity] {
        let since = Date().addingTimeInterval(-90 * 86_400)
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let range = HKQuery.predicateForSamples(withStart: since, end: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, range]))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 100)
        let workouts = try await descriptor.result(for: health)
        return workouts.map { w in
            let meters = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
            let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?
                .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            return RunActivity(id: "health-\(w.uuid)", source: .health, name: "Run", date: DateKey.key(w.startDate),
                               start: w.startDate, minutes: w.duration / 60, miles: meters / 1609.344, avgHR: hr)
        }
    }

    /// Time asleep over the last week, by wake date. Overlapping samples (watch + phone) count once.
    private func healthSleep() async -> [String: Double] {
        let since = Date().addingTimeInterval(-8 * 86_400)
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await descriptor.result(for: health) else { return [:] }
        return sleepByWakeDate(samples.filter { asleep.contains($0.value) }.map { DateInterval(start: $0.startDate, end: $0.endDate) })
    }

    /// Daily sums for steps, active calories and distance, from last Monday to today.
    private func healthActivity() async -> [String: DayActivity] {
        let cal = DateKey.calendar
        let start = cal.date(byAdding: .day, value: -7, to: DateKey.date(DateKey.mondayKey(Date()))) ?? Date()
        var out: [String: DayActivity] = [:]
        func sums(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> [String: Double] {
            let type = HKQuantityType(id)
            let query = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: nil)),
                options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            guard let result = try? await query.result(for: health) else { return [:] }
            var d: [String: Double] = [:]
            result.enumerateStatistics(from: start, to: Date()) { stats, _ in
                if let v = stats.sumQuantity()?.doubleValue(for: unit) { d[DateKey.key(stats.startDate)] = v }
            }
            return d
        }
        for (k, v) in await sums(.stepCount, .count()) { out[k, default: .init()].steps = Int(v.rounded()) }
        for (k, v) in await sums(.activeEnergyBurned, .kilocalorie()) { out[k, default: .init()].calories = v }
        for (k, v) in await sums(.distanceWalkingRunning, .mile()) { out[k, default: .init()].miles = v }
        return out
    }

    /// Save a finished lift to Apple Health as a strength workout.
    func saveLift(start: Date, end: Date) async {
        guard healthConnected, healthAvailable else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        let builder = HKWorkoutBuilder(healthStore: health, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            lastError = "Health: \(error.localizedDescription)"
        }
    }
}

/// Tiny Keychain wrapper for tokens.
enum Keychain {
    private static let service = "dev.ivanshishkin.gymtrak"

    static func set(_ key: String, _ data: Data) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

/// Minutes asleep per wake date. Overlaps merge first so two sources don't double count.
/// A stretch belongs to the date six hours after it ends: a night ending 7 AM and an afternoon nap both count for that day.
func sleepByWakeDate(_ intervals: [DateInterval]) -> [String: Double] {
    var merged: [DateInterval] = []
    for i in intervals.sorted(by: { $0.start < $1.start }) {
        if let last = merged.last, i.start <= last.end {
            merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
        } else {
            merged.append(i)
        }
    }
    var out: [String: Double] = [:]
    for m in merged { out[DateKey.key(m.end.addingTimeInterval(6 * 3600)), default: 0] += m.duration / 60 }
    return out
}
