import SwiftUI
import WatchKit

@main
struct GymTrakWatchApp: App {
    @State private var model = WatchModel.shared
    @State private var workout = WorkoutManager.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RestTimerView()
                .environment(model)
                .environment(workout)
                .task { model.activate() }
        }
        .onChange(of: phase) { if phase == .active { model.refresh() } }
    }
}

/// The whole watch app: the phone's rest timer, laid out like the Clock app's timer.
/// A ring with the time in the middle and the end time under it; +15 bottom left, Skip or Start bottom right.
/// The Health workout (heart rate, calories) records in the background while a workout is open on the phone.
struct RestTimerView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let s = model.state
                let end = s.restEndsAt.flatMap { $0 > ctx.date ? $0 : nil }
                let total = Double(s.restTotal ?? s.restDefault ?? 180)
                let left = end.map { $0.timeIntervalSince(ctx.date) } ?? Double(s.restDefault ?? 180)
                ring(left: left, total: total, running: end != nil, end: end)
                    .toolbar { buttons(running: end != nil) }
            }
        }
    }

    private func ring(left: Double, total: Double, running: Bool, end: Date?) -> some View {
        let progress = running ? max(0, min(1, left / max(total, 1))) : 1
        return GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 7)
                Circle().trim(from: 0, to: progress)
                    .stroke(.white.opacity(running ? 1 : 0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                VStack(spacing: 2) {
                    Text(clock(running ? left.rounded(.up) : left))
                        .font(.system(size: d * 0.27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(running ? .primary : .secondary)
                    if let end {
                        Label(end.formatted(date: .omitted, time: .shortened), systemImage: "bell.fill")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(4)
    }

    @ToolbarContentBuilder
    private func buttons(running: Bool) -> some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if running {
                Button { model.addRest(15) } label: { Text("+15").font(.system(.body, design: .rounded).weight(.semibold)) }
                    .accessibilityLabel("Add 15 seconds")
                Spacer()
                Button { model.skipRest() } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Skip rest")
            } else {
                Spacer()
                Button { model.startRest() } label: { Image(systemName: "play.fill") }
                    .tint(.green)
                    .accessibilityLabel("Start rest")
            }
        }
    }
}

/// 125 → "2:05".
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
