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
    @State private var renaming: Exercise?
    @State private var nameDraft = ""
    @State private var tick = 0

    enum Mode: String, CaseIterable { case current = "Set", all = "All" }

    struct SetEdit: Identifiable { let row: WorkoutSet; let ex: Exercise; var id: String { row.id } }
    struct ExGroup: Identifiable {
        let ex: Exercise
        let sets: [WorkoutSet]
        var id: String { ex.id }
        var isDone: Bool { sets.allSatisfy(\.isDone) }
    }

    var body: some View {
        let db = store.db
        if let session = db.sessions.first(where: { $0.isOpen && !$0.isRun }), let day = db.day(session.dayId) {
            content(session: session, day: day)
        } else {
            Color(.systemGroupedBackground).ignoresSafeArea().onAppear { dismiss() }
        }
    }

    private func groups(_ session: Session, _ day: Day) -> [ExGroup] {
        let sets = store.db.sets(of: session.id)
        return store.db.exercises(of: day.id).compactMap { ex in
            let s = sets.filter { $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }
            return s.isEmpty ? nil : ExGroup(ex: ex, sets: s)
        }
    }

    // MARK: Layout

    private func content(session: Session, day: Day) -> some View {
        let groups = groups(session, day)
        let pending = groups.flatMap { g in g.sets.filter { !$0.isDone }.map { (row: $0, ex: g.ex) } }
        let active = pending.first
        let total = groups.reduce(0) { $0 + $1.sets.count }
        let done = total - pending.count
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
                VStack(spacing: 10) {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Theme.lift).scaleEffect(y: 1.8)
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal).padding(.bottom, 8)
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if rest.isActive { RestBar() }
                    if store.canEdit { bottomBar(active: mode == .current ? active : nil, allDone: allDone) }
                }
            }
            .navigationTitle(day.name)
            .navigationBarTitleDisplayMode(.inline)
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
    }

    @ToolbarContentBuilder
    private func toolbar(session: Session, day: Day, done: Int, total: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Minimize workout")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(day.name).font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(fmtClock(ctx.date.timeIntervalSince1970 - session.startedAt / 1000)) · \(done) of \(total) sets")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        if store.canEdit {
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
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func bottomBar(active: (row: WorkoutSet, ex: Exercise)?, allDone: Bool) -> some View {
        HStack(spacing: 12) {
            if let active {
                Button { toggle(active.row, ex: active.ex) } label: {
                    Label("Done", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.lift)
            }
            Button { allDone ? finish() : (confirmFinish = true) } label: {
                Text("Finish").font(.headline).frame(maxWidth: active == nil ? .infinity : nil)
                    .padding(.horizontal, active == nil ? 0 : 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(allDone ? Theme.lift : Color(.systemGray5))
            .foregroundStyle(allDone ? .white : .primary)
        }
        .controlSize(.large)
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Current Set

    @ViewBuilder
    private func currentSetPage(groups: [ExGroup], active: (row: WorkoutSet, ex: Exercise)?,
                                next: (row: WorkoutSet, ex: Exercise)?, allDone: Bool, total: Int) -> some View {
        if let active, let group = groups.first(where: { $0.ex.id == active.ex.id }) {
            let index = (group.sets.firstIndex { $0.id == active.row.id } ?? 0) + 1
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 6) {
                        Text(group.ex.name).font(.title.bold()).multilineTextAlignment(.center)
                        Text("Set \(index) of \(group.sets.count)").font(.headline).foregroundStyle(Theme.lift)
                        setDots(group.sets, current: active.row.id)
                    }

                    VStack(spacing: 14) {
                        let unit = group.ex.effectiveLoadType.valueLabel(for: active.row.weight)
                        valueRow(label: unit,
                                 value: displayLoad(active.row.weight, unit: unit),
                                 canStep: store.canEdit && group.ex.effectiveLoadType != .free,
                                 onStep: { stepLoad(active.row, ex: group.ex, $0) },
                                 onTap: { loadTarget = SetEdit(row: active.row, ex: group.ex) })
                        valueRow(label: "Reps",
                                 value: bareReps(active.row.reps).isEmpty ? "—" : bareReps(active.row.reps),
                                 canStep: store.canEdit && (bareReps(active.row.reps).isEmpty || Int(bareReps(active.row.reps)) != nil),
                                 onStep: { stepReps(active.row, $0) },
                                 onTap: { repsTarget = SetEdit(row: active.row, ex: group.ex) })
                    }

                    if let next {
                        let nextIndex = (groups.first { $0.ex.id == next.ex.id }?.sets.firstIndex { $0.id == next.row.id } ?? 0) + 1
                        VStack(spacing: 2) {
                            Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(next.ex.id == group.ex.id ? "Set \(nextIndex)" : next.ex.name).font(.subheadline.weight(.semibold))
                            Text("\(next.row.weight.isEmpty ? "—" : next.row.weight) × \(bareReps(next.row.reps))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            ContentUnavailableView {
                Label(allDone ? "All Done" : "No Sets", systemImage: allDone ? "checkmark.circle.fill" : "dumbbell")
            } description: {
                Text(allDone ? "Tap Finish." : "Add one from •••")
            }
            .symbolRenderingMode(.multicolor)
            .background(Color(.systemGroupedBackground))
        }
    }

    /// One dot per set: filled when done, ringed for the current one. Tap a done dot to undo it.
    private func setDots(_ sets: [WorkoutSet], current: String) -> some View {
        HStack(spacing: 8) {
            ForEach(sets) { s in
                Button { toggle(s, ex: nil) } label: {
                    Circle()
                        .fill(s.isDone ? Theme.lift : Color(.systemGray4))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.lift, lineWidth: 2).frame(width: 16, height: 16).opacity(s.id == current ? 1 : 0))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!s.isDone || !store.canEdit)
                .accessibilityLabel(s.isDone ? "Undo set" : s.id == current ? "Current set" : "Set")
            }
        }
        .padding(.top, 4)
    }

    private func valueRow(label: String, value: String, canStep: Bool,
                          onStep: @escaping (Int) -> Void, onTap: @escaping () -> Void) -> some View {
        HStack {
            stepButton("minus", label: "Less \(label.lowercased())", enabled: canStep) { onStep(-1) }
            Button(action: onTap) {
                VStack(spacing: 2) {
                    Text(value).font(.number(44, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(label)
                        if store.canEdit { Image(systemName: "pencil").imageScale(.small) }
                    }
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!store.canEdit)
            .accessibilityHint("Tap to type a value")
            stepButton("plus", label: "More \(label.lowercased())", enabled: canStep) { onStep(1) }
        }
        .padding(16)
        .background(Theme.lift.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.lift.opacity(0.25)))
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2.weight(.semibold)).frame(width: 52, height: 52)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(Theme.lift)
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
        List {
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                Section {
                    ForEach(Array(g.sets.enumerated()), id: \.element.id) { n, st in
                        setRow(st, number: n + 1, ex: g.ex, isActive: st.id == activeId)
                            .swipeActions {
                                if store.canEdit && g.sets.count > 1 {
                                    Button("Delete", role: .destructive) { store.mutate { $0.removeSet(st.id) } }
                                }
                            }
                    }
                    if store.canEdit {
                        Button { store.mutate { $0.addSetToSession(session.id, exerciseId: g.ex.id) } } label: {
                            Label("Add Set", systemImage: "plus")
                        }
                    }
                } header: {
                    HStack {
                        Text(g.ex.name).font(.headline).foregroundStyle(.primary).textCase(nil)
                        if g.isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.lift) }
                        Spacer()
                        if store.canEdit { exerciseMenu(g.ex, session: session, index: i, count: groups.count) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func exerciseMenu(_ ex: Exercise, session: Session, index: Int, count: Int) -> some View {
        Menu {
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
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .textCase(nil)
    }

    private func setRow(_ st: WorkoutSet, number: Int, ex: Exercise, isActive: Bool) -> some View {
        HStack(spacing: 14) {
            Button { toggle(st, ex: ex) } label: {
                Image(systemName: st.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(st.isDone ? Theme.lift : isActive ? Theme.lift : Color(.systemGray3))
            }
            .buttonStyle(.borderless)
            .disabled(!store.canEdit)
            .accessibilityLabel(st.isDone ? "Mark set \(number) not done" : "Mark set \(number) done")

            Text("Set \(number)").foregroundStyle(.secondary).frame(width: 50, alignment: .leading)

            Button(st.weight.isEmpty ? "—" : st.weight) { loadTarget = SetEdit(row: st, ex: ex) }
                .buttonStyle(.borderless)
                .font(.number(20))
                .foregroundStyle(st.weight.isEmpty ? .secondary : .primary)
                .disabled(!store.canEdit)
            Spacer()
            Button(st.reps.isEmpty ? "Reps" : st.reps) { repsTarget = SetEdit(row: st, ex: ex) }
                .buttonStyle(.borderless)
                .font(.number(17))
                .foregroundStyle(.secondary)
                .disabled(!store.canEdit)
        }
        .padding(.vertical, 4)
        .listRowBackground(isActive ? Theme.lift.opacity(0.12) : nil)
        .opacity(st.isDone ? 0.55 : 1)
    }

    // MARK: Actions

    private func toggle(_ st: WorkoutSet, ex: Exercise?) {
        guard store.canEdit else { return }
        let nowDone = store.mutate { $0.toggleSet(st.id) } ?? false
        if nowDone {
            tick += 1
            let restSec = (ex ?? store.db.exercises.first { $0.id == st.exerciseId })?.restSeconds
            rest.start(restSec)
        }
    }

    private func stepLoad(_ st: WorkoutSet, ex: Exercise, _ dir: Int) {
        guard let w = GymTrak.stepLoad(st.weight, type: ex.effectiveLoadType, increment: ex.effectiveIncrement, direction: dir) else { return }
        store.mutate { $0.updateSetLoad(st.id, weight: w, reps: st.reps) }
    }

    private func stepReps(_ st: WorkoutSet, _ dir: Int) {
        let bare = bareReps(st.reps)
        guard let n = bare.isEmpty ? 0 : Int(bare) else { return }
        store.mutate { $0.updateSetLoad(st.id, weight: st.weight, reps: "× \(max(0, n + dir))") }
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
        Task { await connections.saveLift(start: start, end: Date()) }
        nav.completed = (session.id, day.name)
        dismiss()
    }
}
