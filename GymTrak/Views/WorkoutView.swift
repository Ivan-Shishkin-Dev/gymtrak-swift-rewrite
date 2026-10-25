import SwiftUI

/// The live workout: a set-by-set focus view, an overview of every exercise, and an
/// edit mode for changing the workout's structure.
struct WorkoutView: View {
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest
    @Environment(AppNav.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var focusMode = true
    @State private var editing = false
    @State private var expanded: Set<String> = []
    @State private var confirmFinish = false
    @State private var confirmDiscard = false
    @State private var loadTarget: SetEdit?
    @State private var repsTarget: SetEdit?
    @State private var renaming: Exercise?
    @State private var nameDraft = ""
    @State private var tick = 0

    struct SetEdit: Identifiable { let row: WorkoutSet; let ex: Exercise; var id: String { row.id } }
    struct Group: Identifiable {
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
            Color(Theme.bg).ignoresSafeArea().onAppear { dismiss() }
        }
    }

    // MARK: Layout

    private func content(session: Session, day: Day) -> some View {
        let db = store.db
        let sessionSets = db.sets(of: session.id)
        let groups = db.exercises(of: day.id).compactMap { ex -> Group? in
            let s = sessionSets.filter { $0.exerciseId == ex.id }.sorted { $0.setIndex < $1.setIndex }
            return s.isEmpty ? nil : Group(ex: ex, sets: s)
        }
        let ordered = groups.flatMap { g in g.sets.map { (set: $0, ex: g.ex) } }
        let pending = ordered.filter { !$0.set.isDone }
        let active = pending.first
        let done = sessionSets.filter(\.isDone).count
        let total = sessionSets.count
        let showFocus = focusMode && !editing

        return VStack(spacing: 0) {
            header(session: session, day: day, done: done, total: total)
            ProgressView(value: total == 0 ? 0 : Double(done), total: Double(max(total, 1)))
                .tint(Theme.volt).padding(.horizontal, 20).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 12) {
                    if !editing && !groups.isEmpty {
                        Picker("View", selection: $focusMode) {
                            Text("Current set").tag(true)
                            Text("Overview").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    if !store.canEdit || editing {
                        Text(store.canEdit ? "Editing: reorder, rename, change type, add or remove sets and exercises."
                                           : "Viewing a live workout (read only).")
                            .font(.system(size: 12)).foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if showFocus, let active, let group = groups.first(where: { $0.ex.id == active.ex.id }) {
                        let next = pending.dropFirst().first
                        FocusSetView(
                            ex: group.ex, sets: group.sets, current: active.set, canEdit: store.canEdit,
                            next: next.map { n in
                                let num = (groups.first { $0.ex.id == n.ex.id }?.sets.firstIndex { $0.id == n.set.id } ?? 0) + 1
                                return (n.ex.id == group.ex.id ? "set \(num)" : n.ex.name) + " · \(n.set.weight.isEmpty ? "—" : n.set.weight) × \(bareReps(n.set.reps))"
                            },
                            onStepLoad: { stepLoad(active.set, ex: group.ex, $0) },
                            onStepReps: { stepReps(active.set, $0) },
                            onEditWeight: { loadTarget = SetEdit(row: active.set, ex: group.ex) },
                            onEditReps: { repsTarget = SetEdit(row: active.set, ex: group.ex) },
                            onChip: { toggle($0, ex: group.ex) })
                    }
                    if showFocus && total > 0 && done == total {
                        VStack(spacing: 6) {
                            Text("All \(total) sets done").font(.display(26))
                            Text("Finish to save loads to the Plan for next time.").font(.system(size: 13.5)).foregroundStyle(Theme.sub)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 28).card(padding: 0)
                    }

                    if !showFocus {
                        ForEach(groups.filter { !$0.isDone || editing }) { g in
                            exerciseCard(g, session: session, groups: groups)
                        }
                        if editing {
                            Button {
                                let id = store.mutate { $0.addExerciseToSession(session.id, dayId: day.id) }
                                if let id, let ex = store.db.exercises.first(where: { $0.id == id }) { startRename(ex) }
                            } label: { Label("Add exercise", systemImage: "plus") }
                            .buttonStyle(DashedButtonStyle())
                            Button("Discard workout", role: .destructive) { confirmDiscard = true }
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.red).padding(8)
                        } else {
                            donePile(groups.filter(\.isDone), session: session, groups: groups)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 24)
            }

            if rest.isActive || (store.canEdit && !editing && !showFocus) {
                RestBar(canStart: store.canEdit && !editing && !showFocus)
            }
            if store.canEdit && !editing && ((showFocus && active != nil) || done > 0) {
                footer(active: showFocus ? active : nil, allDone: total > 0 && done == total)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
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
        .alert("Rename exercise", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
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
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("\(total - done) sets aren't ticked. Their planned loads stay as they were.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                rest.stop()
                store.mutate { $0.discardSession(session.id) }
                dismiss()
            }
        } message: { Text("Nothing from this session is saved. This can't be undone.") }
        .sensoryFeedback(.success, trigger: tick)
    }

    private func header(session: Session, day: Day, done: Int, total: Int) -> some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: Circle()).overlay(Circle().strokeBorder(Theme.pillBorder))
            }
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 1) {
                Text(day.name).font(.display(27))
                Text("\(day.focus.isEmpty ? "" : "\(day.focus) · ")\(done) of \(total) sets")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.sub).lineLimit(1)
            }
            Spacer()
            if store.canEdit {
                Button(editing ? "Done" : "Edit") { withAnimation(.snappy) { editing.toggle() } }
                    .buttonStyle(PillButtonStyle(active: editing))
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(fmtClock(ctx.date.timeIntervalSince1970 - session.startedAt / 1000))
                    .font(.display(18, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Theme.card, in: Capsule()).overlay(Capsule().strokeBorder(Theme.pillBorder))
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    private func footer(active: (set: WorkoutSet, ex: Exercise)?, allDone: Bool) -> some View {
        HStack(spacing: 10) {
            if let active {
                Button { toggle(active.set, ex: active.ex) } label: { Label("Done set", systemImage: "checkmark") }
                    .buttonStyle(VoltButtonStyle())
            }
            Button("Finish") { allDone ? finishNow() : (confirmFinish = true) }
                .buttonStyle(VoltButtonStyle(quiet: !allDone))
                .frame(maxWidth: active == nil ? .infinity : 120)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
        .background(Theme.bg.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(Theme.cardBorder).frame(height: 1) }
    }

    // MARK: Overview cards

    private func exerciseCard(_ g: Group, session: Session, groups: [Group]) -> some View {
        let idx = groups.firstIndex { $0.id == g.id } ?? 0
        let firstPending = groups.flatMap(\.sets).first { !$0.isDone }?.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if editing {
                    Button { store.mutate { $0.moveExercise(g.ex.id, -1) } } label: { Image(systemName: "chevron.up") }
                        .disabled(idx == 0)
                    Button { store.mutate { $0.moveExercise(g.ex.id, 1) } } label: { Image(systemName: "chevron.down") }
                        .disabled(idx == groups.count - 1)
                }
                Text(g.ex.name).font(.system(size: 15, weight: .semibold))
                    .onTapGesture { if editing { startRename(g.ex) } }
                Spacer()
                if editing {
                    Button(role: .destructive) {
                        store.mutate { $0.removeExerciseFromSession(session.id, exerciseId: g.ex.id) }
                    } label: { Image(systemName: "trash") }
                    .foregroundStyle(Theme.faint)
                } else if g.isDone {
                    Button { expanded.remove(g.ex.id) } label: { Image(systemName: "chevron.up") }.foregroundStyle(Theme.dim)
                }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            .padding(.top, 10).padding(.bottom, 4)

            if editing {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LoadType.allCases, id: \.self) { t in
                            Button(t.label) { store.mutate { $0.updateExercise(g.ex.id) { $0.loadType = t } } }
                                .buttonStyle(PillButtonStyle(active: g.ex.effectiveLoadType == t, height: 26))
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            ForEach(Array(g.sets.enumerated()), id: \.element.id) { i, st in
                setRow(st, number: i + 1, ex: g.ex, isActive: st.id == firstPending, canRemove: g.sets.count > 1)
            }

            if editing {
                Button { store.mutate { $0.addSetToSession(session.id, exerciseId: g.ex.id) } } label: {
                    Label("Add set", systemImage: "plus")
                }
                .buttonStyle(DashedButtonStyle()).padding(.top, 6)
                HStack(spacing: 8) {
                    settingField("Load step", value: fmtNum(g.ex.effectiveIncrement)) { v in
                        if let d = Double(v), d >= 0.5 { store.mutate { $0.updateExercise(g.ex.id) { $0.loadIncrement = d } } }
                    }
                    settingField("Rest seconds", value: String(g.ex.restSeconds ?? rest.defaultSec)) { v in
                        if let s = Int(v), s >= 15 { store.mutate { $0.updateExercise(g.ex.id) { $0.restSeconds = s } } }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private func setRow(_ st: WorkoutSet, number: Int, ex: Exercise, isActive: Bool, canRemove: Bool) -> some View {
        let live = isActive && !editing
        return HStack(spacing: 12) {
            Text("SET \(number)").font(.system(size: 10.5, design: .monospaced)).tracking(0.8)
                .foregroundStyle(live ? Theme.volt : Theme.dim).frame(width: 46, alignment: .leading)
            HStack(spacing: 6) {
                if live && store.canEdit && ex.effectiveLoadType != .free {
                    miniStep("minus") { stepLoad(st, ex: ex, -1) }
                }
                Text(st.weight.isEmpty ? "—" : st.weight).font(.display(22, weight: .semibold)).monospacedDigit()
                    .onTapGesture { if store.canEdit { loadTarget = SetEdit(row: st, ex: ex) } }
                if live && store.canEdit && ex.effectiveLoadType != .free {
                    miniStep("plus") { stepLoad(st, ex: ex, 1) }
                }
            }
            Spacer()
            Text(st.reps).font(.display(18, weight: .semibold)).foregroundStyle(Theme.sub).monospacedDigit()
                .onTapGesture { if store.canEdit { repsTarget = SetEdit(row: st, ex: ex) } }
            if editing {
                Button { store.mutate { $0.removeSet(st.id) } } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5))
                }
                .foregroundStyle(Theme.faint).disabled(!canRemove).opacity(canRemove ? 1 : 0.3)
            } else {
                Image(systemName: st.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24)).foregroundStyle(st.isDone ? Theme.volt : Color.white.opacity(0.22))
            }
        }
        .frame(height: 46)
        .padding(.horizontal, 10).padding(.horizontal, -10)
        .background(live ? Theme.voltTint : .clear, in: RoundedRectangle(cornerRadius: 12))
        .opacity(st.isDone && !editing ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !editing { toggle(st, ex: ex) } }
    }

    private func miniStep(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.pillBorder))
        }
        .buttonStyle(.plain)
    }

    private func settingField(_ label: String, value: String, commit: @escaping (String) -> Void) -> some View {
        SettingField(label: label, initial: value, commit: commit)
    }

    private func donePile(_ done: [Group], session: Session, groups: [Group]) -> some View {
        VStack(spacing: 12) {
            if !done.isEmpty {
                HStack(spacing: 10) {
                    Text("DONE · \(done.count)").eyebrow(Theme.faint)
                    Rectangle().fill(Theme.separator).frame(height: 1)
                }
                .padding(.top, 8)
            }
            ForEach(done) { g in
                if expanded.contains(g.ex.id) {
                    exerciseCard(g, session: session, groups: groups)
                } else {
                    Button { expanded.insert(g.ex.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.onVolt)
                                .frame(width: 24, height: 24).background(Theme.volt, in: Circle())
                            Text(g.ex.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.sub)
                            Spacer()
                            Text("\(g.sets.count) \(g.sets.count == 1 ? "set" : "sets")")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                        .card(radius: 16, padding: 14, border: Theme.voltTint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Actions

    private func toggle(_ st: WorkoutSet, ex: Exercise) {
        guard store.canEdit, !editing else { return }
        expanded.remove(ex.id)
        let nowDone = store.mutate { $0.toggleSet(st.id) } ?? false
        if nowDone {
            tick += 1
            rest.start(ex.restSeconds)
        }
    }

    private func stepLoad(_ st: WorkoutSet, ex: Exercise, _ dir: Int) {
        guard let w = GymTrak.stepLoad(st.weight, type: ex.effectiveLoadType, increment: ex.effectiveIncrement, direction: dir) else { return }
        store.mutate { $0.updateSetLoad(st.id, weight: w, reps: st.reps) }
    }

    private func stepReps(_ st: WorkoutSet, _ dir: Int) {
        guard let n = Int(bareReps(st.reps)) else { return }
        store.mutate { $0.updateSetLoad(st.id, weight: st.weight, reps: "× \(max(0, n + dir))") }
    }

    private func startRename(_ ex: Exercise) {
        nameDraft = ex.name
        renaming = ex
    }

    private func finishNow() {
        let db = store.db
        guard let session = db.sessions.first(where: { $0.isOpen && !$0.isRun }), let day = db.day(session.dayId) else { return }
        finish(session: session, day: day)
    }

    private func finish(session: Session, day: Day) {
        rest.stop()
        store.mutate { $0.finishSession(session.id) }
        nav.completed = (session.id, day.name)
        dismiss()
    }
}

/// A small numeric field that commits when editing ends.
private struct SettingField: View {
    let label: String
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.sub)
            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 34)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.pillBorder))
                .onSubmit { commit(text) }
                .onChange(of: text) { _, v in commit(v) }
        }
        .onAppear { text = initial }
    }
}

/// The set to do now, large, with steppers for load and reps.
struct FocusSetView: View {
    let ex: Exercise
    let sets: [WorkoutSet]
    let current: WorkoutSet
    let canEdit: Bool
    let next: String?
    let onStepLoad: (Int) -> Void
    let onStepReps: (Int) -> Void
    let onEditWeight: () -> Void
    let onEditReps: () -> Void
    let onChip: (WorkoutSet) -> Void

    var body: some View {
        let index = sets.firstIndex { $0.id == current.id } ?? 0
        let reps = bareReps(current.reps)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ex.name).font(.display(26))
                Text("SET \(index + 1) OF \(sets.count)").font(.system(size: 11.5, design: .monospaced)).tracking(1.1).foregroundStyle(Theme.volt)
            }
            FlowChips(sets: sets, current: current, canEdit: canEdit, onChip: onChip)
            stepper(canStep: canEdit && ex.effectiveLoadType != .free, onStep: onStepLoad) {
                Button(action: onEditWeight) {
                    Text(current.weight.isEmpty ? "—" : current.weight)
                        .font(.display(current.weight.count > 7 ? 32 : 44)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .disabled(!canEdit)
            }
            stepper(canStep: canEdit && Int(reps) != nil, onStep: onStepReps) {
                Button(action: onEditReps) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reps.isEmpty ? "—" : reps).font(.display(34)).monospacedDigit()
                        Text("reps").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.sub)
                    }
                }
                .disabled(!canEdit)
            }
            if let next {
                Text("Next: \(next)").font(.system(size: 13)).foregroundStyle(Theme.sub).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(Theme.text)
        .card(padding: 18)
    }

    private func stepper<V: View>(canStep: Bool, onStep: @escaping (Int) -> Void, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            stepButton("minus", enabled: canStep) { onStep(-1) }
            value().buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 56)
            stepButton("plus", enabled: canStep) { onStep(1) }
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22, weight: .medium))
                .frame(width: 56, height: 56)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.pillBorder))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .sensoryFeedback(.selection, trigger: current.weight + current.reps)
    }
}

/// Set chips — progress through the exercise; tapping a done chip unticks it.
private struct FlowChips: View {
    let sets: [WorkoutSet]
    let current: WorkoutSet
    let canEdit: Bool
    let onChip: (WorkoutSet) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sets) { s in
                    let isCurrent = s.id == current.id
                    Button { onChip(s) } label: {
                        HStack(spacing: 4) {
                            if s.isDone { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)) }
                            Text("\(s.weight.isEmpty ? "—" : s.weight) × \(bareReps(s.reps))").monospacedDigit()
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 10).frame(minWidth: 64, minHeight: 44)
                        .foregroundStyle(s.isDone ? Theme.volt : isCurrent ? Theme.text : Theme.faint)
                        .background(s.isDone ? Theme.voltTint : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(s.isDone || isCurrent ? Theme.volt : Theme.pillBorder, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!s.isDone || !canEdit)
                }
            }
        }
    }
}
