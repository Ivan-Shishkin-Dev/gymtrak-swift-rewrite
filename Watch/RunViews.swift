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
                                            zoneMin: 120, zoneMax: 140, cap: 145, easy: true, cues: [],
                                            segments: [.init(name: "Easy", from: 0, to: 0, aim: "HR 120–140")])
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
    @State private var confirmEnd = false

    var body: some View {
        NavigationStack { metrics }
    }

    private var metrics: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let t = run.elapsed(at: ctx.date)
            let p = run.planTime(at: ctx.date)
            let seg = segment(at: p)
            VStack(alignment: .leading, spacing: 4) {
                partCard(seg)
                // Time running, and time left in the whole run.
                HStack(alignment: .lastTextBaseline) {
                    Text(clock(t))
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(run.phase == .paused ? Color.secondary : .yellow)
                        .fixedSize()
                    Spacer(minLength: 4)
                    if let total = run.plan?.minutes, total > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(p < total * 60 ? clock(total * 60 - p) : "0:00")
                                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("LEFT").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                hairline
                heartRow(aim: seg.aim)
                hairline
                HStack(alignment: .top) {
                    column("DISTANCE", String(format: "%.2f", run.miles), unit: "mi", alignment: .leading)
                    Spacer(minLength: 4)
                    column("PACE", paceText(run.pace), unit: "/mi", alignment: .trailing)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 6)
            .padding(.top, -10)     // use the space under the clock
            .padding(.bottom, 4)
            .overlay(alignment: .top) {
                if let b = run.banner, ctx.date.timeIntervalSince(b.shownAt) < 10 {
                    BannerView(banner: b).onTapGesture { run.banner = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: run.banner)
        }
        // Pause, back / next part (centered), End at the very bottom. Swiping right still works too.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                round(run.phase == .paused ? "play.fill" : "pause.fill", fill: .yellow, ink: .black,
                      label: run.phase == .paused ? "Resume" : "Pause") {
                    run.phase == .paused ? run.resume() : run.pause()
                }
                Spacer(minLength: 0)
                if run.canSkip {
                    HStack(spacing: 6) {
                        round("backward.end.fill", fill: .white.opacity(0.18), ink: .white, label: "Previous part") { run.skip(-1) }
                        round("forward.end.fill", fill: .white.opacity(0.18), ink: .white, label: "Next part") { run.skip(1) }
                    }
                    Spacer(minLength: 0)
                }
                round("xmark", fill: .red, ink: .white, label: "End run") { confirmEnd = true }
            }
            .padding(.horizontal, 6)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .confirmationDialog("End run?", isPresented: $confirmEnd) {
            Button("End and Save") { Task { await run.end() } }
            Button("Discard Run", role: .destructive) { run.discard() }
            Button("Keep Running", role: .cancel) {}
        }
    }

    private func round(_ icon: String, fill: Color, ink: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                .frame(width: 38, height: 38)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The part of the run you're in, how long it has left, and how far through it you are.
    private struct Part {
        var name: String
        var left: TimeInterval?     // nil = open-ended
        var progress: Double        // 0…1
        var aim: String
    }

    private func segment(at t: TimeInterval) -> Part {
        let parts = run.plan?.segments ?? []
        let min = t / 60
        if let s = parts.first(where: { min >= $0.from && ($0.to == 0 || min < $0.to) }) {
            guard s.to > 0 else { return Part(name: s.name, left: nil, progress: 0, aim: s.aim) }
            let length = (s.to - s.from) * 60
            return Part(name: s.name, left: s.to * 60 - t, progress: (t - s.from * 60) / max(length, 1), aim: s.aim)
        }
        if let last = parts.last, last.to > 0, min >= last.to {
            return Part(name: "Done", left: nil, progress: 1, aim: "Walk it off")
        }
        return Part(name: "Run", left: nil, progress: 0,
                    aim: "HR \(run.plan.map { "\($0.zoneMin)–\($0.zoneMax)" } ?? "120–140")")
    }

    /// Green card: what you're doing now, time left in it, and a bar that fills as it goes.
    private func partCard(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(part.name.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let left = part.left {
                    Text(clock(left)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            .foregroundStyle(.green)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.green.opacity(0.25))
                    Capsule().fill(.green).frame(width: geo.size.width * max(0, min(1, part.progress)))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var hairline: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
    }

    /// Heart rate in its zone color, the five-zone bar, and the aim for this part.
    private func heartRow(aim: String) -> some View {
        let hr = run.heartRate
        let zone = hr.map { run.zone(for: $0) }
        return HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(hr.map { "\(Int($0))" } ?? "--")
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(zone.map(zoneColor) ?? .primary)
                Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                ZoneBar(zone: zone)
                Text("Aim \(aim.replacingOccurrences(of: "HR ", with: ""))")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    /// A small caps label over a number and its unit.
    private func column(_ label: String, _ value: String, unit: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.6)
        }
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
            Button("Discard Run", role: .destructive) { run.discard() }
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
