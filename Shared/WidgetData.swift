import Foundation

/// Everything the widgets show. The app writes it to the shared App Group on every change;
/// the widget extension only reads it, so it never needs the app's model code.
struct WidgetData: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case lift, run, rest }

    /// One weekday of the repeating schedule.
    struct Slot: Codable, Sendable, Equatable {
        var kind: Kind
        var title: String      // "Upper A", "Long Run", "Rest Day"
        var detail: String     // "8 lifts · 25 min run", "45 min", ""
        var coach: String?     // "Shoulder Press · 135 lb × 6"
    }

    /// Monday first, 7 entries.
    var slots: [Slot]
    /// Local "yyyy-MM-dd" dates with a finished workout or a synced run.
    var doneDates: [String]
    var streakWeeks: Int
    var updatedAt: Date

    static let appGroup = "group.dev.ivanshishkin.gymtrak"
    static let kind = "GymTrak"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "widget.json")
    }

    static func load() -> WidgetData? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Reading

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        return c
    }()

    static func key(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 0 = Monday … 6 = Sunday.
    static func weekdayIndex(_ d: Date) -> Int { (calendar.component(.weekday, from: d) + 5) % 7 }

    func slot(on d: Date) -> Slot {
        let i = Self.weekdayIndex(d)
        return slots.indices.contains(i) ? slots[i] : Slot(kind: .rest, title: "Rest Day", detail: "")
    }

    func isDone(_ d: Date) -> Bool { doneDates.contains(Self.key(d)) }

    /// Monday–Sunday of the week containing `d`.
    func week(of d: Date) -> [(date: Date, slot: Slot, done: Bool)] {
        let monday = Self.calendar.date(byAdding: .day, value: -Self.weekdayIndex(d), to: Self.calendar.startOfDay(for: d)) ?? d
        return (0..<7).map { i in
            let day = Self.calendar.date(byAdding: .day, value: i, to: monday) ?? monday
            return (day, slot(on: day), isDone(day))
        }
    }

    /// (done, planned) training days this week.
    func weekProgress(_ d: Date) -> (done: Int, planned: Int) {
        let w = week(of: d).filter { $0.slot.kind != .rest }
        return (w.filter(\.done).count, w.count)
    }

    static let sample = WidgetData(
        slots: [
            Slot(kind: .lift, title: "Upper A", detail: "8 lifts · 25 min run", coach: "Bench · 185 lb × 6"),
            Slot(kind: .lift, title: "Lower A", detail: "8 lifts", coach: "Leg Press · 5 pl + 30 × 6"),
            Slot(kind: .run, title: "Intervals", detail: "35 min"),
            Slot(kind: .lift, title: "Upper B", detail: "7 lifts", coach: "Incline · 135 lb × 8"),
            Slot(kind: .lift, title: "Lower B", detail: "8 lifts", coach: "SLDL · 225 lb × 8"),
            Slot(kind: .run, title: "Long Run", detail: "45 min"),
            Slot(kind: .rest, title: "Rest Day", detail: ""),
        ],
        doneDates: [], streakWeeks: 3, updatedAt: .now)
}
