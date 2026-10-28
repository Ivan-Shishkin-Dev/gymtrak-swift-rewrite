import Foundation

/// One heads-up during a run: what to do from this minute on.
struct RunCue: Equatable {
    /// Minutes after the run starts.
    var at: Double
    var title: String
    var body: String
}

/// The heads-up sent when a run starts on the watch: today's run, how long, what heart rate.
struct RunBrief: Equatable {
    var title: String
    var body: String
}

extension Snapshot {
    /// The first cue, shown when the run starts.
    func runBrief(now: Date = Date(), runs: [RunActivity] = []) -> RunBrief {
        let first = runCues(now: now, runs: runs)[0]
        return RunBrief(title: first.title, body: first.body)
    }

    /// Every cue for today's run, in order, the first at minute 0.
    /// Easy runs: start, halfway, strides near the end, done. Hard runs: warm-up, the work, cool-down, done.
    /// With no run planned today, one cue with the easy zone so an extra run stays easy.
    func runCues(now: Date = Date(), runs: [RunActivity] = []) -> [RunCue] {
        let date = DateKey.key(now)
        let week = scheduleWeek(now)
        guard let rx = week?.slot(DateKey.dow(now))?.run else {
            let (lo, hi, cap) = defaultHR(.easy)
            return [RunCue(at: 0, title: "No run planned", body: "Keep it easy: HR \(zoneLabel(lo, hi)), cap \(cap).")]
        }
        let advice = RunCoach.advice(rx, date: date, deload: week?.isDeload ?? false, schedule: week, runs: runs)
        let total = Double(Int(advice.target.prefix { $0.isNumber }) ?? rx.durationMin)
        let zone = "HR \(zoneLabel(rx.hrZoneMin, rx.hrZoneMax)), cap \(rx.hrHardCap)"
        let pace = advice.pace.map { "\n\($0)" } ?? ""
        func mins(_ m: Double) -> String { "\(Int(m.rounded())) min" }
        let note = rx.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { "\n\($0)" } ?? ""

        if rx.label.isEasy {
            var cues = [RunCue(at: 0, title: "\(rx.label.rawValue) · \(mins(total))", body: zone + pace + note)]
            if total >= 16 {
                cues.append(RunCue(at: total / 2, title: "Halfway · \(mins(total / 2)) left", body: zone + ". Slow down if you're over."))
            }
            if rx.strides && total >= 10 {
                cues.append(RunCue(at: total - 3, title: "Strides now",
                                   body: "4 × 20 s fast and relaxed, 40 s easy jog between. Then easy to the end."))
            }
            cues.append(RunCue(at: total, title: "Done · \(mins(total))", body: "Walk 2–3 min to cool down."))
            return cues
        }

        // Hard runs: 10 min warm-up and 5 min cool-down around the work.
        let warm = min(10, total / 3), cool = min(5, total / 5)
        let work = max(0, total - warm - cool)
        let (lo, hi, _) = defaultHR(.easy)
        let what: String
        switch rx.label {
        case .intervals: what = "Hard reps, easy jog between. Stop a rep if form breaks."
        case .tempo: what = "Steady hard: a few words at a time."
        default: what = "Even effort. Kick the last 400 m."
        }
        return [
            RunCue(at: 0, title: "Warm-up · \(mins(warm))", body: "Easy, HR \(zoneLabel(lo, hi)).\n\(rx.label.rawValue) after: \(mins(work))." + note),
            RunCue(at: warm, title: "\(rx.label.rawValue) · \(mins(work))", body: "HR cap \(rx.hrHardCap)." + pace + "\n" + what),
            RunCue(at: warm + work, title: "Cool-down · \(mins(cool))", body: "Easy jog, HR under \(hi)."),
            RunCue(at: total, title: "Done · \(mins(total))", body: "Walk 2–3 min."),
        ]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
