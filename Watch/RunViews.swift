import SwiftUI
import WatchKit

/// Today's run and a Start button.
struct RunStartView: View {
    @Environment(WatchModel.self) private var model
    @Environment(RunManager.self) private var run

    var body: some View {
        let plan = model.state.runPlan ?? Self.freeRun
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.title).font(.title3.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
            Text(plan.detail).font(.footnote).foregroundStyle(.secondary)
            if plan.cues.count > 1 {
                Label("\(plan.cues.count - 1) cues on your wrist", systemImage: "bell.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let last = run.lastRun {
                Label(last, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4)
        .navigationTitle("Run")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button { Task { await run.start(plan) } } label: { Image(systemName: "play.fill") }
                    .tint(.green)
                    .accessibilityLabel("Start run")
            }
        }
    }

    static let freeRun = WatchState.RunPlan(title: "Free Run", detail: "HR 120–140, cap 145", minutes: 0,
                                            zoneMin: 120, zoneMax: 140, cap: 145, easy: true, cues: [])
}

/// During a run: swipe right for Pause and End, like the Workout app.
struct RunActiveView: View {
    @State private var page = 1

    var body: some View {
        TabView(selection: $page) {
            RunControlsView(done: { page = 1 }).tag(0)
            RunMetricsView().tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

/// Time, heart rate with its zone, distance and pace. A cue or warning shows on top for 10 s.
struct RunMetricsView: View {
    @Environment(RunManager.self) private var run

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                Text(clock(run.elapsed(at: ctx.date)))
                    .font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(run.phase == .paused ? Color.secondary : .yellow)
                    .lineLimit(1).minimumScaleFactor(0.6)
                heartRow
                metric(String(format: "%.2f", run.miles), unit: "MI")
                metric(paceText(run.pace), unit: "/MI")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 6)
            .overlay(alignment: .top) {
                if let b = run.banner, ctx.date.timeIntervalSince(b.shownAt) < 10 {
                    BannerView(banner: b).onTapGesture { run.banner = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: run.banner)
        }
    }

    private var heartRow: some View {
        let hr = run.heartRate
        let zone = hr.map { run.zone(for: $0) }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(hr.map { "\(Int($0))" } ?? "--")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            Image(systemName: "heart.fill").font(.system(size: 14)).foregroundStyle(.red)
            Spacer(minLength: 4)
            ZoneBar(zone: zone)
        }
        .foregroundStyle(zone.map(zoneColor) ?? .primary)
    }

    private func metric(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(unit).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }

    /// 588 s/mi → 9'48".
    private func paceText(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s > 0, s < 3600 else { return "--'--\"" }
        let t = Int(s.rounded())
        return "\(t / 60)'\(String(format: "%02d", t % 60))\""
    }
}

/// Five segments, the current zone lit and labeled, like the Workout app.
struct ZoneBar: View {
    let zone: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { z in
                Capsule()
                    .fill(zoneColor(z).opacity(z == zone ? 1 : 0.3))
                    .frame(width: z == zone ? 14 : 7, height: z == zone ? 8 : 5)
            }
            Text(zone.map { "Z\($0)" } ?? "")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(zone.map(zoneColor) ?? .secondary)
                .frame(width: 20, alignment: .leading)
        }
        .accessibilityElement()
        .accessibilityLabel(zone.map { "Zone \($0)" } ?? "No zone")
    }
}

/// The Workout app's zone colors: blue, teal, green, orange, red.
func zoneColor(_ zone: Int) -> Color {
    switch zone {
    case 1: .blue
    case 2: .teal
    case 3: .green
    case 4: .orange
    default: .red
    }
}

private struct BannerView: View {
    let banner: RunManager.Banner

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(banner.title).font(.headline).lineLimit(2)
            Text(banner.body).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 2)
    }
}

/// Pause/Resume and End, as two big round buttons.
struct RunControlsView: View {
    @Environment(RunManager.self) private var run
    let done: () -> Void
    @State private var confirmEnd = false

    var body: some View {
        HStack(spacing: 16) {
            control(run.phase == .paused ? "Resume" : "Pause",
                    icon: run.phase == .paused ? "arrow.clockwise" : "pause.fill", color: .yellow) {
                run.phase == .paused ? run.resume() : run.pause()
                done()
            }
            control("End", icon: "xmark", color: .red) { confirmEnd = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("End run?", isPresented: $confirmEnd) {
            Button("End and Save") { Task { await run.end() } }
            Button("Keep Running", role: .cancel) {}
        }
    }

    private func control(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: 24, weight: .bold)).foregroundStyle(color)
                    .frame(width: 64, height: 64)
                    .background(color.opacity(0.25), in: Circle())
            }
            .buttonStyle(.plain)
            Text(title).font(.footnote)
        }
    }
}
