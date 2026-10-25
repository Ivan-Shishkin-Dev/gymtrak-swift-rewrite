import SwiftUI

/// The rest countdown: ring, time left, ±15 s, skip. When idle (and allowed) it
/// shows a "Start rest" button instead.
struct RestBar: View {
    var canStart = false
    @Environment(RestTimer.self) private var rest
    @State private var showDefault = false

    var body: some View {
        Group {
            if rest.isActive {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    running(left: rest.remaining(at: ctx.date))
                }
            } else if canStart {
                Button { rest.start() } label: {
                    Label("Start rest · \(fmtClock(Double(rest.defaultSec)))", systemImage: "timer")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.cardBorder).frame(height: 1) }
    }

    private func running(left: Double) -> some View {
        let over = left < 0
        let fraction = max(0, min(1, left / Double(rest.targetSec)))
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.13), lineWidth: 3)
                Circle().trim(from: 0, to: fraction).stroke(over ? Theme.amber : Theme.volt, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(over ? "+\(fmtClock(-left))" : fmtClock(left))
                    .font(.display(22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(over ? Theme.amber : Theme.text)
                Text(over ? "Rest over" : "Resting").font(.system(size: 11)).foregroundStyle(Theme.sub)
            }
            .onTapGesture { showDefault = true }
            Spacer()
            chip("−15") { rest.add(-15) }
            chip("+15") { rest.add(15) }
            chip("Skip") { rest.stop() }
        }
        .padding(.vertical, 10)
        .onChange(of: left < -300) { _, stale in if stale { rest.stop() } }
        .sensoryFeedback(.warning, trigger: over)
        .confirmationDialog("Default rest", isPresented: $showDefault) {
            ForEach([60, 90, 120, 150, 180, 240, 300], id: \.self) { s in
                Button(fmtClock(Double(s))) { rest.setDefault(s) }
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(PillButtonStyle(height: 32))
    }
}
