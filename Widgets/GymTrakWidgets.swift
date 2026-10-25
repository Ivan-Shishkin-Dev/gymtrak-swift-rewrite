import SwiftUI
import WidgetKit

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, data: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, data: WidgetData.load() ?? .sample))
    }

    /// One entry an hour for a day, so "today" flips at midnight.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let data = WidgetData.load() ?? .sample
        let cal = WidgetData.calendar
        let start = cal.dateInterval(of: .hour, for: .now)?.start ?? .now
        let entries = (0..<24).map { h in
            Entry(date: h == 0 ? .now : cal.date(byAdding: .hour, value: h, to: start)!, data: data)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Pieces

private extension WidgetData.Kind {
    var icon: String {
        switch self {
        case .lift: "dumbbell.fill"
        case .run: "figure.run"
        case .rest: "moon.zzz.fill"
        }
    }
    var tint: Color { self == .run ? .cyan : .white }
}

private struct Dots: View {
    let week: [(date: Date, slot: WidgetData.Slot, done: Bool)]
    let today: Date

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, d in
                let isToday = WidgetData.key(d.date) == WidgetData.key(today)
                let past = d.date < WidgetData.calendar.startOfDay(for: today)
                VStack(spacing: 4) {
                    Circle()
                        .fill(fill(d, past: past))
                        .overlay(Circle().strokeBorder(.white.opacity(isToday ? 0.9 : 0), lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                    Text(d.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 10, weight: isToday ? .bold : .medium))
                        .foregroundStyle(.white.opacity(isToday ? 1 : 0.5))
                }
            }
        }
    }

    private func fill(_ d: (date: Date, slot: WidgetData.Slot, done: Bool), past: Bool) -> Color {
        if d.done { return d.slot.kind == .run ? .cyan : .white }
        if d.slot.kind == .rest { return .white.opacity(0.12) }
        return past ? .red.opacity(0.65) : .white.opacity(0.25)
    }
}

// MARK: - Today (home + lock screen)

struct TodayView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let slot = entry.data.slot(on: entry.date)
        let done = entry.data.isDone(entry.date)
        switch family {
        case .accessoryInline:
            Label(done ? "\(slot.title) ✓" : slot.kind == .rest ? "Rest day" : "\(slot.title) today",
                  systemImage: slot.kind.icon)
        case .accessoryCircular:
            let p = entry.data.weekProgress(entry.date)
            Gauge(value: Double(p.done), in: 0...Double(max(p.planned, 1))) {
                Image(systemName: "dumbbell.fill")
            } currentValueLabel: {
                Text("\(p.done)/\(p.planned)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(done ? "Done" : "Today", systemImage: done ? "checkmark.circle.fill" : slot.kind.icon)
                    .font(.caption.weight(.semibold))
                Text(slot.title).font(.headline).widgetAccentable()
                if !slot.detail.isEmpty { Text(slot.detail).font(.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            medium(slot, done: done)
        default:
            small(slot, done: done)
        }
    }

    private func small(_ slot: WidgetData.Slot, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: slot.kind.icon).font(.title3).foregroundStyle(slot.kind.tint)
                Spacer()
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white) }
            }
            Spacer(minLength: 0)
            Text(entry.date.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
            Text(slot.title).font(.title2.weight(.bold)).foregroundStyle(.white)
                .minimumScaleFactor(0.7).lineLimit(1)
            if !slot.detail.isEmpty {
                Text(slot.detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
    }

    private func medium(_ slot: WidgetData.Slot, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            small(slot, done: done)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("This week").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    if entry.data.streakWeeks > 0 {
                        Label("\(entry.data.streakWeeks) wk", systemImage: "flame.fill")
                            .font(.caption.weight(.bold)).foregroundStyle(.orange)
                    }
                }
                Dots(week: entry.data.week(of: entry.date), today: entry.date)
                Spacer(minLength: 0)
                if let coach = slot.coach, !done {
                    caption("SHOOT FOR", coach)
                } else {
                    let tomorrow = WidgetData.calendar.date(byAdding: .day, value: 1, to: entry.date) ?? entry.date
                    let next = entry.data.slot(on: tomorrow)
                    caption("TOMORROW", next.detail.isEmpty ? next.title : "\(next.title) · \(next.detail)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func caption(_ label: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: Provider()) { entry in
            TodayView(entry: entry)
                .containerBackground(for: .widget) { Background() }
                .widgetURL(URL(string: "gymtrak://today"))
        }
        .configurationDisplayName("Today")
        .description("Today's workout and your week.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/// Matte black, a touch lighter at the top.
private struct Background: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
    }
}

@main
struct GymTrakWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

// MARK: - Previews

#Preview("Today small", as: .systemSmall) { TodayWidget() } timeline: { Entry(date: .now, data: .sample) }
#Preview("Today medium", as: .systemMedium) { TodayWidget() } timeline: { Entry(date: .now, data: .sample) }
#Preview("Lock rect", as: .accessoryRectangular) { TodayWidget() } timeline: { Entry(date: .now, data: .sample) }
