import SwiftUI
import WidgetKit

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry { .init(date: .now, data: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(.init(date: .now, data: WidgetData.load() ?? .sample))
    }

    /// Hourly for a day, so "today" turns over at midnight.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let data = WidgetData.load() ?? .sample
        let cal = WidgetData.calendar
        let start = cal.dateInterval(of: .hour, for: .now)?.start ?? .now
        let entries = (0..<24).map { h in
            ComplicationEntry(date: h == 0 ? .now : cal.date(byAdding: .hour, value: h, to: start)!, data: data)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    var body: some View {
        let slot = entry.data.slot(on: entry.date)
        let done = entry.data.isDone(entry.date)
        let p = entry.data.weekProgress(entry.date)
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(p.done), in: 0...Double(max(p.planned, 1))) {
                Image(systemName: "dumbbell.fill")
            } currentValueLabel: {
                Text("\(p.done)/\(p.planned)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryCorner:
            Image(systemName: done ? "checkmark" : "dumbbell.fill")
                .widgetLabel { Text(slot.kind == .rest ? "Rest" : slot.title) }
        case .accessoryInline:
            Text(done ? "\(slot.title) ✓" : slot.kind == .rest ? "Rest day" : "\(slot.title) today")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(done ? "DONE" : "TODAY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(slot.title).font(.headline).widgetAccentable()
                Text(slot.coach ?? (slot.detail.isEmpty ? "\(p.done)/\(p.planned) this week" : slot.detail))
                    .font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct GymTrakComplications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchToday", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Today's workout and your week.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
