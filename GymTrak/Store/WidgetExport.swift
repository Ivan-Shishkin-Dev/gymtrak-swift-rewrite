import Foundation

extension Snapshot {
    /// The widget summary: the weekly schedule, what's done, and the streak.
    func widgetData(runs: [RunActivity], now: Date = Date()) -> WidgetData {
        let runDates = Set(runs.map(\.date))
        let template = scheduleTemplate
        let today = DateKey.key(now)
        let slots: [WidgetData.Slot] = Dow.allCases.map { dow in
            guard let slot = template?.slot(dow), !slot.isRest else {
                return .init(kind: .rest, title: "Rest Day", detail: "")
            }
            if let id = slot.liftDayId, let day = day(id) {
                let exs = exercises(of: id)
                var detail = "\(exs.count) lifts"
                if let run = slot.run { detail += " · \(run.durationMin) min run" }
                let coach = exs.first.map { ex in "\(ex.name) · \(liftAdvice(for: ex, today: today).target)" }
                return .init(kind: .lift, title: day.name, detail: detail, coach: coach)
            }
            let run = slot.run!
            return .init(kind: .run, title: run.label.rawValue, detail: "\(run.durationMin) min")
        }
        return WidgetData(slots: slots,
                          doneDates: Array(doneDates.union(runDates)).sorted(),
                          streakWeeks: streakWeeks(today: now, doneExtra: runDates),
                          updatedAt: now)
    }
}
