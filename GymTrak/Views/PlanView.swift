import SwiftUI

/// The Plan: lift days and their exercises (the source of truth for loads), plus the schedule.
struct PlanView: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @State private var confirmDelete: Day?

    var body: some View {
        let db = store.db
        NavigationStack {
            List {
                Section {
                    ForEach(db.activeDays) { day in
                        NavigationLink(value: day.id) { dayRow(day) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { confirmDelete = day }
                                Button("Archive") { store.mutate { $0.archiveDay(day.id, true) } }.tint(Theme.warning)
                            }
                    }
                    .onMove { from, to in
                        guard let i = from.first else { return }
                        let id = db.activeDays[i].id
                        let steps = to > i ? to - i - 1 : to - i
                        store.mutate { snap in
                            for _ in 0..<abs(steps) { snap.moveDay(id, steps > 0 ? 1 : -1) }
                        }
                    }
                    Button { store.mutate { $0.addDay() } } label: { Label("Add day", systemImage: "plus") }
                } header: { Text("Lift days") }

                Section {
                    NavigationLink { ScheduleView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Schedule")
                                Text(scheduleSummary(db.scheduleTemplate)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { IconBadge(systemName: "calendar", color: Theme.run) }
                    }
                }

                let archived = db.sortedDays.filter(\.isArchived)
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { day in
                            HStack {
                                Text(day.name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") { store.mutate { $0.archiveDay(day.id, false) } }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .topLeftTitle("Plan")
            .navigationDestination(for: Int.self) { DayDetailView(dayId: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .confirmationDialog("Delete \(confirmDelete?.name ?? "day")?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Day", role: .destructive) {
                    if let d = confirmDelete { store.mutate { $0.deleteDay(d.id) } }
                }
            } message: { Text("Past workouts are kept.") }
        }
    }

    private func dayRow(_ day: Day) -> some View {
        let count = store.db.exercises(of: day.id).count
        let dows = store.db.weeks.first.map { w in w.slots.filter { $0.liftDayId == day.id }.map { $0.dow.short } } ?? []
        return HStack(spacing: 14) {
          IconBadge(systemName: "dumbbell.fill", color: Theme.lift, size: 36)
          VStack(alignment: .leading, spacing: 3) {
            Text(day.name).font(.headline)
            Text([dows.joined(separator: ", "), "\(count) exercises", day.focus].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
    }

    private func scheduleSummary(_ week: ProgramWeek?) -> String {
        guard let week else { return "Not set" }
        let lifts = week.slots.filter { $0.liftDayId != nil }.count
        let runs = week.slots.filter { $0.run != nil }.count
        return "\(lifts) lifts · \(runs) runs a week"
    }
}

// MARK: - Day detail

struct DayDetailView: View {
    let dayId: Int
    @Environment(Store.self) private var store
    @State private var name = ""
    @State private var focus = ""
    @State private var historyTarget: Exercise?

    var body: some View {
        let db = store.db
        if let day = db.day(dayId) {
            let exercises = db.exercises(of: dayId)
            List {
                Section("Day") {
                    TextField("Name", text: $name).onSubmit(saveDay)
                    TextField("Focus", text: $focus).onSubmit(saveDay)
                }
                Section("Exercises") {
                    ForEach(exercises) { ex in
                        HStack {
                            NavigationLink { ExerciseEditorView(exerciseId: ex.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ex.name)
                                    Text(exerciseSummary(ex.rows)).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Button { historyTarget = ex } label: {
                                Image(systemName: "chart.line.uptrend.xyaxis")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.lift)
                            .accessibilityLabel("History")
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { exercises[$0].id }
                        store.mutate { snap in ids.forEach { snap.deleteExercise($0) } }
                    }
                    .onMove { from, to in
                        guard let i = from.first else { return }
                        let id = exercises[i].id
                        let steps = to > i ? to - i - 1 : to - i
                        store.mutate { snap in for _ in 0..<abs(steps) { snap.moveExercise(id, steps > 0 ? 1 : -1) } }
                    }
                    Button { store.mutate { $0.addExercise(dayId: dayId) } } label: { Label("Add exercise", systemImage: "plus") }
                }
            }
            .navigationTitle(day.name)
            .toolbar { EditButton() }
            .onAppear { name = day.name; focus = day.focus }
            .onDisappear(perform: saveDay)
            .sheet(item: $historyTarget) { ex in
                NavigationStack { ExerciseHistoryView(ex: ex) }
                    .presentationDetents([.medium, .large])
            }
        } else {
            ContentUnavailableView("Day not found", systemImage: "questionmark")
        }
    }

    private func saveDay() {
        guard let day = store.db.day(dayId) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if (!n.isEmpty && n != day.name) || focus != day.focus {
            store.mutate { $0.updateDay(dayId, name: n.isEmpty ? nil : n, focus: focus) }
        }
    }
}

// MARK: - Exercise editor

struct ExerciseEditorView: View {
    let exerciseId: String
    /// False when opened from a live workout, where the sets are edited in place.
    var showsSets = true
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loadEdit: Int?
    @State private var repsEdit: Int?

    var body: some View {
        if let ex = store.db.exercises.first(where: { $0.id == exerciseId }) {
            let rows = ex.rows
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .onSubmit { commitName() }
                }
                Section {
                    Picker("Weight type", selection: Binding(get: { ex.effectiveLoadType }, set: { t in
                        store.mutate { $0.updateExercise(exerciseId) { $0.loadType = t } }
                    })) {
                        ForEach(LoadType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: { Text(loadTypeHelp(ex.effectiveLoadType)) }

                if showsSets { Section("Sets") {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        HStack {
                            Text("Set \(i + 1)").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Button(row.weight.isEmpty ? "Add" : row.weight) { loadEdit = i }
                                .buttonStyle(.borderless).foregroundStyle(row.weight.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button(row.reps.isEmpty ? "Reps" : row.reps) { repsEdit = i }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        var r = rows
                        r.remove(atOffsets: idx)
                        if !r.isEmpty { store.mutate { $0.setRows(exerciseId, r) } }
                    }
                    .deleteDisabled(rows.count <= 1)
                    Button { store.mutate { $0.setRows(exerciseId, rows + [rows.last ?? SetRow(weight: "", reps: "× 6")]) } } label: {
                        Label("Add Set", systemImage: "plus")
                    }
                } }
                Section("Workout") {
                    Stepper(value: Binding(get: { ex.effectiveIncrement }, set: { v in
                        store.mutate { $0.updateExercise(exerciseId) { $0.loadIncrement = v } }
                    }), in: 0.5...50, step: ex.effectiveIncrement >= 5 ? 2.5 : 0.5) {
                        LabeledContent("Step", value: fmtNum(ex.effectiveIncrement))
                    }
                    Stepper(value: Binding(get: { ex.restSeconds ?? 180 }, set: { v in
                        store.mutate { $0.updateExercise(exerciseId) { $0.restSeconds = v } }
                    }), in: 15...600, step: 15) {
                        LabeledContent("Rest", value: fmtClock(Double(ex.restSeconds ?? 180)))
                    }
                }
            }
            .navigationTitle(ex.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showsSets { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .onAppear { name = ex.name }
            .onDisappear(perform: commitName)
            .sheet(item: Binding(get: { loadEdit.map(IndexBox.init) }, set: { loadEdit = $0?.i })) { box in
                LoadEditorSheet(title: "\(ex.name) · set \(box.i + 1)", loadType: ex.effectiveLoadType, initial: rows[box.i].weight) { w in
                    var r = rows; r[box.i].weight = w
                    store.mutate { $0.setRows(exerciseId, r) }
                }
            }
            .sheet(item: Binding(get: { repsEdit.map(IndexBox.init) }, set: { repsEdit = $0?.i })) { box in
                RepsEditorSheet(title: "\(ex.name) · set \(box.i + 1)", initial: rows[box.i].reps) { reps in
                    var r = rows; r[box.i].reps = reps
                    store.mutate { $0.setRows(exerciseId, r) }
                }
            }
        }
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != store.db.exercises.first(where: { $0.id == exerciseId })?.name else { return }
        store.mutate { $0.updateExercise(exerciseId) { $0.name = n } }
    }

    private func loadTypeHelp(_ t: LoadType) -> String {
        switch t {
        case .weight: "e.g. 225 lb"
        case .machine: "e.g. 12, 120 lb, Max + 10"
        case .plates: "e.g. 5 pl + 25"
        case .bodyweight: "e.g. BW, +70, −25"
        case .free: "Any text"
        }
    }
}

private struct IndexBox: Identifiable { let i: Int; var id: Int { i } }
