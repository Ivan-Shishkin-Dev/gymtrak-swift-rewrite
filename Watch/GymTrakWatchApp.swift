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
/// The Crown adds or removes 15 s (or picks the length before Start). After 0:00 it counts up in green.
/// The Health workout (heart rate, calories) records in the background while a workout is open on the phone.
struct RestTimerView: View {
    @Environment(WatchModel.self) private var model
    @State private var crown = 0.0
    @FocusState private var crownFocused: Bool

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let phase = model.phase(at: ctx.date)
                face(phase, now: ctx.date)
                    .toolbar { buttons(phase) }
            }
            .focusable()
            .focused($crownFocused)
            .digitalCrownRotation($crown, from: -100_000, through: 100_000, by: 1, sensitivity: .low,
                                  isContinuous: true, isHapticFeedbackEnabled: true)
            .onChange(of: crown) { old, new in
                let steps = Int(new.rounded()) - Int(old.rounded())
                guard steps != 0 else { return }
                if case .running = model.phase(at: .now) { model.addRest(15 * steps) } else { model.pick(steps) }
            }
            .onAppear { crownFocused = true }
        }
    }

    @ViewBuilder
    private func face(_ phase: WatchModel.RestPhase, now: Date) -> some View {
        switch phase {
        case .running(let end):
            let left = end.timeIntervalSince(now)
            let total = Double(model.state.restTotal ?? model.startSeconds)
            ring(progress: max(0, min(1, left / max(total, 1))), color: .white, track: 0.15) {
                time(clock(left.rounded(.up)), color: .primary)
                Label(end.formatted(date: .omitted, time: .shortened), systemImage: "bell.fill")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .over(let end):
            ring(progress: 1, color: .green, track: 0.15) {
                time("+" + clock(now.timeIntervalSince(end)), color: .green)
            }
        case .idle:
            ring(progress: 1, color: .white.opacity(0.35), track: 0) {
                time(clock(Double(model.startSeconds)), color: model.picked == nil ? .secondary : .primary)
            }
        }
    }

    private func time(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 52, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.5)
            .foregroundStyle(color)
    }

    /// A ring as big as the screen allows, centered both ways, with its content in the middle.
    private func ring<Content: View>(progress: Double, color: Color, track: Double,
                                     @ViewBuilder content: () -> Content) -> some View {
        let inner = content()
        return GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(.white.opacity(track), lineWidth: 7)
                Circle().trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                VStack(spacing: 2) { inner }.padding(.horizontal, 14)
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(4)
    }

    @ToolbarContentBuilder
    private func buttons(_ phase: WatchModel.RestPhase) -> some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if case .running = phase {
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
