import Foundation

/// The heads-up sent when a run starts on the watch: today's run, how long, what heart rate.
struct RunBrief: Equatable {
    var title: String
    var body: String
}

extension Snapshot {
    /// "Easy Run · 30 min" / "HR 120–140, cap 145\n10:40–11:00 /mi\nFinish with 4 × 20 s strides."
    /// With no run planned today, the easy zone so an extra run stays easy.
    func runBrief(now: Date = Date(), runs: [RunActivity] = []) -> RunBrief {
        let date = DateKey.key(now)
        let week = scheduleWeek(now)
        guard let rx = week?.slot(DateKey.dow(now))?.run else {
            let (lo, hi, cap) = defaultHR(.easy)
            return RunBrief(title: "No run planned", body: "Keep it easy: HR \(zoneLabel(lo, hi)), cap \(cap).")
        }
        let advice = RunCoach.advice(rx, date: date, deload: week?.isDeload ?? false, schedule: week, runs: runs)
        var lines = [rx.label.isEasy ? "HR \(zoneLabel(rx.hrZoneMin, rx.hrZoneMax)), cap \(rx.hrHardCap)"
                                     : "HR cap \(rx.hrHardCap)"]
        if let pace = advice.pace { lines.append(pace) }
        lines += advice.cues.prefix(2)
        if let notes = rx.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { lines.append(notes) }
        return RunBrief(title: "\(rx.label.rawValue) · \(advice.target)", body: lines.joined(separator: "\n"))
    }
}
