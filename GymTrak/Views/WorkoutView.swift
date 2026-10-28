import SwiftUI

/// The live workout. "Current Set" shows one set at a time with big +/− controls;
/// "All Sets" lists every exercise. Tap a set to tick it; swipe to delete it; use an
/// exercise's ••• menu to rename, retype or remove it.
struct WorkoutView: View {
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest
    @Environment(AppNav.self) private var nav
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss

    @State private var mode = Mode.current
    @State private var confirmFinish = false
    @State private var confirmDiscard = false
    @State private var loadTarget: SetEdit?
    @State private var repsTarget: SetEdit?
    @State private var settingsTarget: Exercise?
    @State private var historyTarget: Exercise?
    @State private var renaming: Exercise?
    @State private var nameDraft = ""
    @State private var tick = 0
    @State private var stepTick = 0

    enum Mode: String, CaseIterable { case current = "Set", all = "All" }

    struct SetEdit: Identifiable { let row: WorkoutSet; let ex: Exercise; var id: String { row.id } }
    struct ExGroup: Identifiable {
        let ex: Exercise
        let sets: [WorkoutSet]
        var warmups: [WorkoutSet] = []
        var id: String { ex.id }
        var isDone: Bool { sets.allSatisfy(\.isDone) }
    }

    var body: some View {
        let db = store.db
        if let session = db.sessions.first(where: { $0.isOpen && !$0.isRun }), let day = db.day(session.dayId) {
            content(session: session, day: day)
        } else {
            Page.bg.ignoresSafeArea().onAppear { dismiss() }
        }
    }

    private func groups(_ session: Session, _ day: Day) -> [ExGroup] {
        let sets = store.db.sets(of: session.id)
        let warm = store.db.warmups(of: session.id)
        return store.db.exercises(of: day.id).compactMap { ex in
            let s = sets.filter { $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }
            let w = warm.filter { $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }
            return s.isEmpty ? nil : ExGroup(ex: ex, sets: s, warmups: w)
        }
    }

    // MARK: Layout

    private func content(session: Session, day: Day) -> some View {
        let groups = groups(session, day)
        // Warm-ups come first in the queue but don't count toward the sets total.
        let pending = store.db.pendingItems(session).map { (row: $0.set, ex: $0.ex) }
        let active = pending.first
        let total = groups.reduce(0) { $0 + $1.sets.count }
        let done = groups.reduce(0) { $0 + $1.sets.filter(\.isDone).count }
        let allDone = total > 0 && done == total

        return decorate(NavigationStack {
            page(session: session, day: day, groups: groups, active: active, next: pending.dropFirst().first,
                 total: total, done: done, allDone: allDone)
        }, session: session, day: day, total: total, done: done)
    }

    private func page(session: Session, day: Day, groups: [ExGroup], active: (row: WorkoutSet, ex: Exercise)?,
                      next: (row: WorkoutSet, ex: Exercise)?, total: Int, done: Int, allDone: Bool) -> some View {
            SwiftUI.Group {
                if mode == .current {
                    currentSetPage(groups: groups, active: active, next: next, allDone: allDone, total: total)
                } else {
                    allSetsList(groups: groups, session: session, day: day, activeId: active?.row.id)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Page.divider)
                            Capsule().fill(Page.text).frame(width: geo.size.width * Double(done) / Double(max(total, 1)))
                        }
                    }
                    .frame(height: 3)
                    .animation(.snappy, value: done)
                    HStack(spacing: 8) {
                        ForEach(Mode.allCases, id: \.self) { m in
                            Chip(title: m.rawValue, selected: mode == m) { mode = m }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
                .background(Page.bg)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if rest.isActive { RestBar() }
                    bottomBar(active: mode == .current ? active : nil, allDone: allDone)
                }
            }
            .background(Page.bg)
            .navigationTitle(day.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Page.bg, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar { toolbar(session: session, day: day, done: done, total: total) }
    }

    private func decorate<V: View>(_ v: V, session: Session, day: Day, total: Int, done: Int) -> some View {
        v
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; RestTimer.requestPermission() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(item: $loadTarget) { t in
            LoadEditorSheet(title: t.ex.name, loadType: t.ex.effectiveLoadType, initial: t.row.weight) { w in
                store.mutate { $0.updateSetLoad(t.row.id, weight: w, reps: t.row.reps) }
            }
        }
        .sheet(item: $repsTarget) { t in
            RepsEditorSheet(title: t.ex.name, initial: t.row.reps) { r in
                store.mutate { $0.updateSetLoad(t.row.id, weight: t.row.weight, reps: r) }
            }
        }
        .sheet(item: $settingsTarget) { ex in
            NavigationStack { ExerciseEditorView(exerciseId: ex.id, showsSets: false) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $historyTarget) { ex in
            NavigationStack { ExerciseHistoryView(ex: ex) }
                .presentationDetents([.medium, .large])
        }
        .alert("Rename Exercise", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                let text = nameDraft.trimmingCharacters(in: .whitespaces)
                if let ex = renaming, !text.isEmpty { store.mutate { $0.updateExercise(ex.id) { $0.name = text } } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Finish workout?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish") { finish(session: session, day: day) }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("\(total - done) sets left.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                rest.stop()
                store.mutate { $0.discardSession(session.id) }
                dismiss()
            }
        }
        .sensoryFeedback(.success, trigger: tick)
        .sensoryFeedback(.impact(weight: .light), trigger: stepTick)
    }

    @ToolbarContentBuilder
    private func toolbar(session: Session, day: Day, done: Int, total: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Minimize workout")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(day.name).font(.headline).foregroundStyle(Page.text)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(fmtClock(ctx.date.timeIntervalSince1970 - session.startedAt / 1000)) · \(done) of \(total) sets")
                        .font(.caption).foregroundStyle(Page.secondary).monospacedDigit()
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    let id = store.mutate { $0.addExerciseToSession(session.id, dayId: day.id) }
                    if let id, let ex = store.db.exercises.first(where: { $0.id == id }) {
                        mode = .all
                        startRename(ex)
                    }
                } label: { Label("Add Exercise", systemImage: "plus") }
                Button { rest.start() } label: { Label("Rest Timer", systemImage: "timer") }
                Divider()
                Button(role: .destructive) { confirmDiscard = true } label: {
                    Label("Discard Workout", systemImage: "trash")
                }
            } label: { Image(systemName: "ellipsis") }
        }
    }

    private func bottomBar(active: (row: WorkoutSet, ex: Exercise)?, allDone: Bool) -> some View {
        HStack(spacing: 10) {
            if let active {
                PrimaryButton(title: "Done", icon: "checkmark") { toggle(active.row, ex: active.ex) }
            }
            PrimaryButton(title: "Finish", icon: "flag.checkered", muted: !allDone) {
                allDone ? finish() : (confirmFinish = true)
            }
            .frame(maxWidth: active == nil ? .infinity : 130)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Page.bg)
        .overlay(alignment: .top) { Rectangle().fill(Page.divider).frame(height: 1) }
    }

    // MARK: Current Set

    @ViewBuilder
    private func currentSetPage(groups: [ExGroup], active: (row: WorkoutSet, ex: Exercise)?,
                                next: (row: WorkoutSet, ex: Exercise)?, allDone: Bool, total: Int) -> some View {
        if let active, let group = groups.first(where: { $0.ex.id == active.ex.id }) {
            let warm = group.warmups.contains { $0.id == active.row.id }
            let list = warm ? group.warmups : group.sets
            let index = (list.firstIndex { $0.id == active.row.id } ?? 0) + 1
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.ex.name).font(.system(size: 30, weight: .bold)).foregroundStyle(Page.text)
                        HStack(spacing: 10) {
                            Text("\(warm ? "Warm-up" : "Set") \(index) of \(list.count)").foregroundStyle(Page.secondary)
                            setDots(list, current: active.row.id)
                            if warm {
                                Spacer()
                                Button("Skip Warm-ups") { skipWarmups(group.ex) }
                                    .font(.subheadline).foregroundStyle(Page.text)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Page.fill, in: Capsule())
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if !warm { coachRows(group.ex, setIndex: index - 1) }
                        if let next {
                            // Same exercise: the next set's load. A new exercise: just its name.
                            PropertyRow(icon: "arrow.turn.down.right", label: "Next") {
                                Text(next.ex.id == group.ex.id
                                     ? "\(next.row.weight.isEmpty ? "—" : next.row.weight) × \(bareReps(next.row.reps))"
                                     : next.ex.name)
                                    .lineLimit(1)
                            }
                        }
                    }

                    VStack(spacing: 0) {
                        let unit = group.ex.effectiveLoadType.valueLabel(for: active.row.weight)
                        valueRow(label: unit,
                                 value: displayLoad(active.row.weight, unit: unit),
                                 canStep: group.ex.effectiveLoadType != .free,
                                 onStep: { stepLoad(active.row, ex: group.ex, $0) },
                                 onTap: { loadTarget = SetEdit(row: active.row, ex: group.ex) })
                        if let line = plateLine(active.row.weight, type: group.ex.effectiveLoadType) {
                            Text(line).font(.caption).foregroundStyle(Page.secondary).padding(.bottom, 8)
                        }
                        Rectangle().fill(Page.divider).frame(height: 1)
                        valueRow(label: "Reps",
                                 value: bareReps(active.row.reps).isEmpty ? "—" : bareReps(active.row.reps),
                                 canStep: (bareReps(active.row.reps).isEmpty || Int(bareReps(active.row.reps)) != nil),
                                 onStep: { stepReps(active.row, $0) },
                                 onTap: { repsTarget = SetEdit(row: active.row, ex: group.ex) })
                    }
                    .overlay(alignment: .top) { Rectangle().fill(Page.divider).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Page.divider).frame(height: 1) }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Page.bg)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(allDone ? "All done." : "No sets.").font(.system(size: 30, weight: .bold)).foregroundStyle(Page.text)
                Text(allDone ? "Tap Finish." : "Add one from •••").foregroundStyle(Page.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Page.bg)
        }
    }

    /// The coach's target as property rows, plus a nudge after a set that looked easy or hard.
    @ViewBuilder
    private func coachRows(_ ex: Exercise, setIndex: Int) -> some View {
        let db = store.db
        if let session = db.sessions.first(where: { $0.isOpen && !$0.isRun }) {
            let a = db.liftAdvice(for: ex, deload: session.deload ?? false, today: session.slotDate)
            let tip = db.liveTip(sessionId: session.id, ex: ex)
            PropertyRow(icon: a.icon.replacingOccurrences(of: ".fill", with: ""), label: "Shoot for") {
                Text(a.target(forSet: setIndex)).fontWeight(.semibold)
            }
            if let tip {
                PrimaryButton(title: tip.text, icon: tip.steps > 0 ? "arrow.up" : "arrow.down", muted: true) {
                    store.mutate { $0.shiftSets(tip.setIds, ex: ex, steps: tip.steps) }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
    }

    /// One dot per set: filled when done, ringed for the current one. Tap a done dot to undo it.
    private func setDots(_ sets: [WorkoutSet], current: String) -> some View {
        HStack(spacing: 4) {
            ForEach(sets) { s in
                Button { toggle(s, ex: nil) } label: {
                    Circle()
                        .fill(s.isDone ? Page.text : Page.divider)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Page.text, lineWidth: 1.5).frame(width: 13, height: 13).opacity(s.id == current ? 1 : 0))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!s.isDone)
                .accessibilityLabel(s.isDone ? "Undo set" : s.id == current ? "Current set" : "Set")
            }
        }
    }

    private func valueRow(label: String, value: String, canStep: Bool,
                          onStep: @escaping (Int) -> Void, onTap: @escaping () -> Void) -> some View {
        HStack {
            stepButton("minus", label: "Less \(label.lowercased())", enabled: canStep) { onStep(-1) }
            Button(action: onTap) {
                VStack(spacing: 0) {
                    Text(value).font(.number(52, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(Page.text)
                    Text(label).font(.footnote).foregroundStyle(Page.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Tap to type a value")
            stepButton("plus", label: "More \(label.lowercased())", enabled: canStep) { onStep(1) }
        }
        .padding(.vertical, 14)
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.medium)).foregroundStyle(Page.text)
                .frame(width: 52, height: 52)
                .background(Page.fill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0)
        .accessibilityLabel(label)
    }

    /// "225 lb" shows as a big "225" with "lb" underneath.
    private func displayLoad(_ raw: String, unit: String) -> String {
        guard !raw.isEmpty else { return "—" }
        if unit == "lb", raw.hasSuffix(" lb") { return String(raw.dropLast(3)) }
        if unit == "Max", raw == "Max" { return "Max" }
        return raw
    }

    // MARK: All Sets

    private func allSetsList(groups: [ExGroup], session: Session, day: Day, activeId: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    let a = store.db.liftAdvice(for: g.ex, deload: session.deload ?? false, today: session.slotDate)
                    PageSection(g.ex.name, trailing: { exerciseMenu(g.ex, session: session, index: i, count: groups.count) }) {
                        Button { historyTarget = g.ex } label: {
                            Text("Shoot for \(a.target)")
                                .font(.subheadline).foregroundStyle(Page.secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(spacing: 0) {
                            ForEach(Array(g.warmups.enumerated()), id: \.element.id) { n, st in
                                setRow(st, label: "W\(n + 1)", ex: g.ex, isActive: st.id == activeId)
                            }
                            ForEach(Array(g.sets.enumerated()), id: \.element.id) { n, st in
                                setRow(st, label: "Set \(n + 1)", ex: g.ex, isActive: st.id == activeId)
                                    .contextMenu {
                                        if g.sets.count > 1 {
                                            Button("Delete Set", systemImage: "trash", role: .destructive) { store.mutate { $0.removeSet(st.id) } }
                                        }
                                    }
                            }
                            Button { store.mutate { $0.addSetToSession(session.id, exerciseId: g.ex.id) } } label: {
                                Label("Add set", systemImage: "plus").font(.subheadline).foregroundStyle(Page.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background(Page.bg)
    }

    private func exerciseMenu(_ ex: Exercise, session: Session, index: Int, count: Int) -> some View {
        Menu {
            Button { historyTarget = ex } label: { Label("History", systemImage: "chart.line.uptrend.xyaxis") }
            Button { startRename(ex) } label: { Label("Rename", systemImage: "pencil") }
            Button { settingsTarget = ex } label: { Label("Settings", systemImage: "slider.horizontal.3") }
            Button { store.mutate { $0.moveExercise(ex.id, -1) } } label: { Label("Move Up", systemImage: "arrow.up") }
                .disabled(index == 0)
            Button { store.mutate { $0.moveExercise(ex.id, 1) } } label: { Label("Move Down", systemImage: "arrow.down") }
                .disabled(index == count - 1)
            Divider()
            Button(role: .destructive) {
                store.mutate { $0.removeExerciseFromSession(session.id, exerciseId: ex.id) }
            } label: { Label("Remove", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(Page.secondary).frame(width: 30, height: 24)
        }
    }

    /// A Notion-style to-do: square checkbox, set number, load and reps; done sets are struck through.
    private func setRow(_ st: WorkoutSet, label: String, ex: Exercise, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            Button { toggle(st, ex: ex) } label: {
                Image(systemName: st.isDone ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(st.isDone ? Page.text : isActive ? Page.text : Page.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(st.isDone ? "Mark \(label) not done" : "Mark \(label) done")

            Text(label).foregroundStyle(label.hasPrefix("W") ? Page.tertiary : Page.secondary).frame(width: 50, alignment: .leading)
            Button(st.weight.isEmpty ? "—" : st.weight) { loadTarget = SetEdit(row: st, ex: ex) }
                .buttonStyle(.plain)
                .font(.number(19))
                .foregroundStyle(st.weight.isEmpty ? Page.secondary : Page.text)
                .strikethrough(st.isDone, color: Page.secondary)
            Spacer()
            Button(st.reps.isEmpty ? "Reps" : st.reps) { repsTarget = SetEdit(row: st, ex: ex) }
                .buttonStyle(.plain)
                .font(.number(17))
                .foregroundStyle(Page.secondary)
                .strikethrough(st.isDone, color: Page.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isActive ? 8 : 0)
        .background(isActive ? Page.fill : .clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(st.isDone ? 0.6 : 1)
    }

    // MARK: Actions

    private func toggle(_ st: WorkoutSet, ex: Exercise?) {
        let nowDone = store.mutate { $0.toggleSet(st.id) } ?? false
        if nowDone {
            tick += 1
            if RestTimer.autoStart {
                let restSec = (ex ?? store.db.exercises.first { $0.id == st.exerciseId })?.restSeconds
                rest.start(store.db.isWarmup(st.id) ? warmupRestSec : restSec)
            }
        }
    }

    private func stepLoad(_ st: WorkoutSet, ex: Exercise, _ dir: Int) {
        guard let w = GymTrak.stepLoad(st.weight, type: ex.effectiveLoadType, increment: ex.effectiveIncrement, direction: dir) else { return }
        store.mutate { $0.updateSetLoad(st.id, weight: w, reps: st.reps) }
        stepTick += 1
    }

    private func stepReps(_ st: WorkoutSet, _ dir: Int) {
        let bare = bareReps(st.reps)
        guard let n = bare.isEmpty ? 0 : Int(bare) else { return }
        store.mutate { $0.updateSetLoad(st.id, weight: st.weight, reps: "× \(max(0, n + dir))") }
        stepTick += 1
    }

    private func skipWarmups(_ ex: Exercise) {
        guard let session = store.db.openLift() else { return }
        store.mutate { $0.skipWarmups(session.id, exerciseId: ex.id) }
    }

    private func startRename(_ ex: Exercise) {
        nameDraft = ex.name
        renaming = ex
    }

    private func finish() {
        let db = store.db
        guard let session = db.sessions.first(where: { $0.isOpen && !$0.isRun }), let day = db.day(session.dayId) else { return }
        finish(session: session, day: day)
    }

    private func finish(session: Session, day: Day) {
        rest.stop()
        store.mutate { $0.finishSession(session.id) }
        let start = Date(timeIntervalSince1970: session.startedAt / 1000)
        // The watch app records its own workout with heart rate; don't save a second copy.
        // The watch saves the lift (with heart rate) only if it said it's recording; otherwise save it here.
        if !WatchBridge.shared.watchIsRecording(session.id) { Task { await connections.saveLift(start: start, end: Date()) } }
        nav.completed = (session.id, day.name)
        dismiss()
    }
}
