import Foundation
import WidgetKit

extension Snapshot {
    /// The widget summary: the weekly schedule, what's done, the streak, and the facts.
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
        let stats = lifetimeStats(synced: runs)
        return WidgetData(slots: slots,
                          doneDates: Array(doneDates.union(runDates)).sorted(),
                          streakWeeks: streakWeeks(today: now, doneExtra: runDates),
                          facts: historyFacts(stats).map(\.text),
                          updatedAt: now)
    }
}

enum WidgetBridge {
    /// Write the summary and refresh the widgets, only when something changed.
    @MainActor static func publish(_ db: Snapshot, runs: [RunActivity]) {
        let data = db.widgetData(runs: runs)
        var old = WidgetData.load()
        old?.updatedAt = data.updatedAt
        guard old != data else { return }
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
