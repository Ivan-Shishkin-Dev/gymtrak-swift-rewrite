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
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date.now.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(s.todayTitle).font(.title3.weight(.bold)).lineLimit(2)
                if !s.todayDetail.isEmpty {
                    Text(s.todayDetail).font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Gauge(value: Double(s.weekDone), in: 0...Double(max(s.weekPlanned, 1))) { EmptyView() }
                        .gaugeStyle(.linearCapacity).tint(.white)
                    Text("\(s.weekDone)/\(s.weekPlanned)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if s.streak > 0 {
                    Label(s.streak == 1 ? "1 week" : "\(s.streak) weeks", systemImage: "flame")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if s.canStart {
                    Button { model.send(.start) } label: {
                        Label(s.todayDone ? "Do Again" : "Start", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                    .padding(.top, 6)
                } else if s.todayDone {
                    Label("Done", systemImage: "checkmark").font(.headline).padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Workout

/// Swipe right for controls, like the Workout app.
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let end = model.state.restEndsAt, end > ctx.date {
                rest(end: end, now: ctx.date)
            } else if let c = workout.current {
                set(c, now: ctx.date)
            } else {
                VStack(spacing: 8) {
                    Text("All done.").font(.title3.weight(.bold))
                    Button("Finish") { model.send(.finish) }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                }
            }
        }
    }

    private func header(_ now: Date) -> some View {
        HStack {
            Text(clock(now.timeIntervalSince(workout.startedAt))).monospacedDigit()
            Spacer()
            if let hr = manager.heartRate {
                Label("\(Int(hr))", systemImage: "heart.fill").labelStyle(.titleAndIcon).monospacedDigit()
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func set(_ c: WatchState.Current, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header(now)
            Text(c.exercise).font(.headline).lineLimit(1)
            Text("Set \(c.setNumber) of \(c.setCount)" + (c.target.map { " · \($0)" } ?? ""))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline) {
                Text(c.weight.isEmpty ? "—" : c.weight)
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .foregroundStyle(editingReps ? .secondary : .primary)
                Spacer()
                Text("× \(c.reps.isEmpty ? "—" : c.reps)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(editingReps ? .primary : .secondary)
                    .onTapGesture { editingReps.toggle() }
            }
            .focusable()
            .digitalCrownRotation($crown, from: -10_000, through: 10_000, by: 1, sensitivity: .low,
                                  isContinuous: true, isHapticFeedbackEnabled: true)
            .onChange(of: crown) { old, new in
                let steps = Int(new.rounded()) - Int(old.rounded())
                guard steps != 0 else { return }
                let dir = steps > 0 ? 1 : -1
                model.send(editingReps ? .stepReps(setId: c.setId, direction: dir)
                                       : (c.canStepLoad ? .stepLoad(setId: c.setId, direction: dir) : .stepReps(setId: c.setId, direction: dir)))
            }
            Text(editingReps ? "Crown sets reps" : "Crown sets weight · tap × for reps")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Button { model.logSet() } label: {
                Label("Done", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            .padding(.top, 4)
        }
        .padding(.horizontal, 4)
    }

    private func rest(end: Date, now: Date) -> some View {
        VStack(spacing: 6) {
            header(now)
            Spacer(minLength: 0)
            Text("REST").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(clock(end.timeIntervalSince(now))).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            if let next = workout.current {
                Text("Next: \(next.exercise) · \(next.weight) × \(next.reps)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button("Skip") { model.send(.skipRest) }
        }
    }
}

struct ControlsView: View {
    let workout: WatchState.Workout
    @Environment(WatchModel.self) private var model
    @Environment(WorkoutManager.self) private var manager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(workout.dayName).font(.headline)
                Text("\(workout.done) of \(workout.total) sets").font(.footnote).foregroundStyle(.secondary)
                if manager.calories > 0 {
                    Label("\(Int(manager.calories)) kcal", systemImage: "flame").font(.footnote).foregroundStyle(.secondary)
                }
                Button { model.send(.finish) } label: {
                    Label("Finish", systemImage: "flag.checkered").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 125 → "2:05".
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
