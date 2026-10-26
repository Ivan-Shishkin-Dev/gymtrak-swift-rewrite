import SwiftUI
import WatchKit

@main
struct GymTrakWatchApp: App {
    @State private var model = WatchModel.shared
    @State private var workout = WorkoutManager.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .environment(workout)
                .task { model.activate() }
        }
    }
}

/// Today when nothing's open; the live set screen during a workout.
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if let w = model.state.workout {
            WorkoutPager(workout: w)
        } else {
            TodayWatchView()
        }
    }
}

// MARK: - Today

struct TodayWatchView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let s = model.state
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.todayTitle).font(.title3.weight(.bold)).lineLimit(2)
                        HStack(spacing: 12) {
                            if let n = s.lifts { Label("\(n)", systemImage: "dumbbell.fill") }
                            if let m = s.runMinutes { Label("\(m)m", systemImage: "figure.run") }
                        }
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("This week").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(s.weekDone)/\(s.weekPlanned)").font(.footnote.monospacedDigit())
                        }
                        Gauge(value: Double(s.weekDone), in: 0...Double(max(s.weekPlanned, 1))) { EmptyView() }
                            .gaugeStyle(.linearCapacity).tint(.white)
                    }
                    if s.streak > 0 {
                        Label(s.streak == 1 ? "1 week streak" : "\(s.streak) week streak", systemImage: "flame.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if s.todayDone {
                        Label("Done today", systemImage: "checkmark.circle.fill").font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
            }
            .navigationTitle(Date.now.formatted(.dateTime.weekday(.wide)))
            .toolbar {
                if s.canStart {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button { model.send(.start) } label: { Image(systemName: "play.fill") }
                            .accessibilityLabel(s.todayDone ? "Do again" : "Start workout")
                    }
                }
            }
        }
    }
}

// MARK: - Workout

/// Swipe left for Finish, like the Workout app.
struct WorkoutPager: View {
    let workout: WatchState.Workout
    @State private var page = 1

    var body: some View {
        TabView(selection: $page) {
            ControlsView(workout: workout).tag(0)
            SetView(workout: workout).tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

struct SetView: View {
    let workout: WatchState.Workout
    @Environment(WatchModel.self) private var model
    @Environment(WorkoutManager.self) private var manager
    @State private var crown = 0.0
    @State private var editingReps = false
    @FocusState private var crownFocused: Bool

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if let end = model.state.restEndsAt, end > ctx.date {
                    rest(end: end, now: ctx.date)
                } else if let c = workout.current {
                    set(c, now: ctx.date)
                } else {
                    allDone
                }
            }
        }
    }

    // MARK: Set

    @ViewBuilder
    private func set(_ c: WatchState.Current, now: Date) -> some View {
        let (load, unit) = split(c.weight)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                SetPills(current: c.setNumber, count: c.setCount)
                Spacer(minLength: 0)
                heart
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 14) {
                field(load, unit: unit, active: !editingReps) { editingReps = false }
                field(c.reps.isEmpty ? "—" : c.reps, unit: "reps", active: editingReps) { editingReps = true }
            }
            .focusable()
            .focused($crownFocused)
            .digitalCrownRotation($crown, from: -1000, through: 1000, by: 1, sensitivity: .low,
                                  isContinuous: true, isHapticFeedbackEnabled: true)
            .onChange(of: crown) { old, new in
                let steps = Int(new.rounded()) - Int(old.rounded())
                guard steps != 0 else { return }
                let dir = steps > 0 ? 1 : -1
                let reps = editingReps || !c.canStepLoad
                model.send(reps ? .stepReps(setId: c.setId, direction: dir) : .stepLoad(setId: c.setId, direction: dir))
            }
            .onAppear { crownFocused = true }
            // Only when the coach wants something other than what's loaded.
            if let target = c.target, target != "\(c.weight) × \(c.reps)" {
                Text("Goal \(target)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .navigationTitle(c.exercise)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { editingReps.toggle() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .accessibilityLabel(editingReps ? "Edit weight" : "Edit reps")
                Spacer()
                Button { model.logSet() } label: { Image(systemName: "checkmark") }
                    .tint(.green)
                    .accessibilityLabel("Set done")
            }
        }
    }

    /// One editable number. The one the Crown is changing gets an underline.
    private func field(_ value: String, unit: String?, active: Bool, select: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.45).lineLimit(1)
                .frame(height: 44)
                .foregroundStyle(active ? .primary : .secondary)
            Text(unit ?? "load").font(.caption2).foregroundStyle(.secondary)
            Capsule().fill(active ? Color.white : .clear).frame(width: 22, height: 2).padding(.top, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    /// "135 lb" → ("135", "lb"); "2 pl + 30" → ("2 pl + 30", nil).
    private func split(_ w: String) -> (String, String?) {
        if w.isEmpty { return ("—", nil) }
        if w.hasSuffix(" lb") { return (String(w.dropLast(3)), "lb") }
        if Double(w) != nil { return (w, "pin") }
        if w.contains("pl") { return (w.replacingOccurrences(of: " pl", with: "pl"), "plates") }
        return (w, nil)
    }

    // MARK: Rest

    private func rest(end: Date, now: Date) -> some View {
        let total = max(1, end.timeIntervalSince(workout.startedAt) > 0 ? Double(workout.current?.restSeconds ?? 180) : 180)
        let left = end.timeIntervalSince(now)
        return VStack(spacing: 6) {
            HStack { Spacer(); heart }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 6)
                Circle().trim(from: 0, to: max(0, min(1, left / total)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: left)
                Text(clock(left)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 104, height: 104)
            if let next = workout.current {
                Label(next.exercise, systemImage: "arrow.turn.down.right")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .navigationTitle("Rest")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { model.send(.addRest(seconds: 15)) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add 15 seconds")
                Spacer()
                Button { model.send(.skipRest) } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Skip rest")
            }
        }
    }

    private var allDone: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle").font(.largeTitle)
            Text("All sets done").font(.headline)
        }
        .navigationTitle(workout.dayName)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button { model.send(.finish) } label: { Image(systemName: "flag.checkered") }
                    .accessibilityLabel("Finish")
            }
        }
    }

    @ViewBuilder private var heart: some View {
        if let hr = manager.heartRate {
            Label("\(Int(hr))", systemImage: "heart.fill")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// One capsule per set: done filled, current wide, the rest dim.
struct SetPills: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...max(count, 1), id: \.self) { n in
                Capsule()
                    .fill(n <= current ? Color.white : Color.white.opacity(0.2))
                    .frame(width: n == current ? 18 : 7, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Set \(current) of \(count)")
    }
}

struct ControlsView: View {
    let workout: WatchState.Workout
    @Environment(WatchModel.self) private var model
    @Environment(WorkoutManager.self) private var manager
    @State private var confirmFinish = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(clock(ctx.date.timeIntervalSince(workout.startedAt)))
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                }
                HStack {
                    Image(systemName: "checklist")
                    Text("\(workout.done)/\(workout.total)").monospacedDigit()
                }
                .font(.footnote).foregroundStyle(.secondary)
                Gauge(value: Double(workout.done), in: 0...Double(max(workout.total, 1))) { EmptyView() }
                    .gaugeStyle(.linearCapacity).tint(.white)
                if manager.calories > 0 {
                    Label("\(Int(manager.calories)) kcal", systemImage: "flame").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .navigationTitle(workout.dayName)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button { confirmFinish = true } label: { Image(systemName: "flag.checkered") }
                        .accessibilityLabel("Finish workout")
                }
            }
            .confirmationDialog("Finish workout?", isPresented: $confirmFinish) {
                Button("Finish") { model.send(.finish) }
                Button("Keep Going", role: .cancel) {}
            }
        }
    }
}

/// 125 → "2:05".
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
