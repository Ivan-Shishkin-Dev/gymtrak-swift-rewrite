import SwiftUI

/// The rest countdown, docked above the bottom bar: time left, −15 s / +15 s, Skip.
struct RestBar: View {
    @Environment(RestTimer.self) private var rest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let left = rest.remaining(at: ctx.date)
            let over = left < 0
            HStack(spacing: 12) {
                Gauge(value: max(0, min(1, left / Double(rest.targetSec)))) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(over ? Theme.warning : Page.text)
                    .scaleEffect(0.55)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(over ? "+\(fmtClock(-left))" : fmtClock(left))
                        .font(.number(22)).foregroundStyle(over ? Theme.warning : Page.text)
                    Text(over ? "Over" : "Rest").font(.caption).foregroundStyle(Page.secondary)
                }
                Spacer()
                Button("−15") { rest.add(-15) }
                Button("+15") { rest.add(15) }
                Button("Skip") { rest.stop() }.fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(Page.text)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Page.bg)
            .overlay(alignment: .top) { Rectangle().fill(Page.divider).frame(height: 1) }
            .onChange(of: left < -RestTimer.overtimeSec) { _, stale in if stale { rest.stop() } }
            .sensoryFeedback(.warning, trigger: over)
        }
    }
}
