import SwiftUI

/// What am I doing today? The lift can be started here; the run is described only
/// (it's tracked on the watch).
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @State private var viewWeekId: Int?
    @State private var selectedDow: Dow?
    @State private var confirmDiscard = false

    var body: some View {
        let db = store.db
        let weeks = db.weeks
        let today = Date()
        let todayKey = DateKey.key(today)
        let todayWeek = weekFor(weeks, today)
        // Program not started yet → show its first week rather than an empty screen.
        let nextWeek = todayWeek == nil ? weeks.first { $0.startDate > todayKey } : nil
        let homeWeek = todayWeek ?? nextWeek
        let week = weeks.first { $0.id == viewWeekId } ?? homeWeek
        let homeDow: Dow = todayWeek != nil ? DateKey.dow(today) : .mon
        let browsing = week?.id != homeWeek?.id || (selectedDow ?? homeDow) != homeDow

        NavigationStack {
            List {
                if let week {
                    let onTodayWeek = week.id == todayWeek?.id
                    let dow = selectedDow ?? (onTodayWeek ? DateKey.dow(today) : .mon)
                    daySections(week: week, dow: dow, todayKey: todayKey)
                    weekSection(week, weeks: weeks, onTodayWeek: onTodayWeek,
                                notStarted: week.id == nextWeek?.id, selected: dow, todayKey: todayKey)
                } else {
                    noProgramSection(hasWeeks: !weeks.isEmpty)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Today")
            .toolbar {
                if browsing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") {
                            withAnimation { viewWeekId = nil; selectedDow = nil }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .refreshable { await store.sync() }
        }
    }

    // MARK: The selected day

    @ViewBuilder
    private func daySections(week: ProgramWeek, dow: Dow, todayKey: String) -> some View {
        let db = store.db
        let slot = week.slot(dow)
        let date = week.date(of: dow)
        let isToday = date == todayKey
        let liftDay = db.day(slot?.liftDayId)
        let exercises = liftDay.map { db.exercises(of: $0.id) } ?? []
        let doneLift = liftDay.flatMap { d in
            db.sessions.first { $0.slotDate == date && $0.finishedAt != nil && !$0.isDeleted && !$0.isRun && $0.dayId == d.id }
        }

        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(isToday ? "Today, \(dow.label)" : "\(dow.label), \(DateKey.label(date, "MMMM d"))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isToday ? Theme.lift : .secondary)
                    Spacer()
                    if doneLift != nil {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.lift)
                    }
                }
                Text(liftDay?.name ?? slot?.run?.label.rawValue ?? "Rest Day")
                    .font(.largeTitle.bold())
                if let liftDay, !liftDay.focus.isEmpty {
                    Text(liftDay.focus).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } footer: {
            if week.isDeload { Label(deloadNote, systemImage: "arrow.down.circle") }
        }

        if let liftDay {
            Section {
                startButton(liftDay, week: week, date: date, done: doneLift != nil)
            }
            .listSectionSpacing(.compact)
        }

        if !exercises.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(exercises) { ex in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ex.name)
                            Text(exerciseSummary(ex.rows)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label("\(exercises.count) Exercises", systemImage: "dumbbell")
                }
            }
        }

        if let run = slot?.run {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(run.label.rawValue).font(.title3.bold())
                        Spacer()
                        Text("\(run.durationMin) min").font(.title3.bold()).foregroundStyle(Theme.run)
                    }
                    Text("\(run.label.effort) · \(zoneLabel(run.hrZoneMin, run.hrZoneMax)) bpm" +
                         (run.label.isEasy ? " · about \(Zone2.milesLabel(run.durationMin))" : ""))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                if let notes = run.notes { Text(notes).font(.subheadline) }
                if run.strides { Text("Then \(stridesNote)").font(.subheadline) }
            } header: {
                Label(liftDay != nil ? "Then Run" : "Run", systemImage: "figure.run")
            }
        }
    }

    /// Start, Resume, Do Again, or Unlock — whichever applies right now.
    private func startButton(_ day: Day, week: ProgramWeek, date: String, done: Bool) -> some View {
        let open = store.db.openLift()
        let isOpen = open?.dayId == day.id && open?.slotDate == date
        let title = !store.canEdit ? "Unlock to Start" : isOpen ? "Resume" : done ? "Do Again" : "Start"
        let icon = !store.canEdit ? "lock.fill" : isOpen ? "arrow.uturn.forward" : "play.fill"
        return Button {
            if !store.canEdit { nav.showSettings = true }
            else if isOpen { nav.showWorkout = true }
            else { start(day, week: week, date: date) }
        } label: {
            Label(title, systemImage: icon).font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(!store.canEdit || (done && !isOpen) ? .gray : Theme.lift)
        .controlSize(.large)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .confirmationDialog("Discard other workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard and Start", role: .destructive) { proceed(day, week: week, date: date) }
        }
    }

    // MARK: The week

    private func weekSection(_ week: ProgramWeek, weeks: [ProgramWeek], onTodayWeek: Bool,
                             notStarted: Bool, selected: Dow, todayKey: String) -> some View {
        let db = store.db
        let done = db.doneDates
        return Section {
            ForEach(Dow.allCases, id: \.self) { dow in
                let slot = week.slot(dow)
                let date = week.date(of: dow)
                let dayName = db.day(slot?.liftDayId)?.name
                Button {
                    selectedDow = dow
                } label: {
                    HStack(spacing: 14) {
                        VStack(spacing: 0) {
                            Text(dow.short.uppercased()).font(.caption2.weight(.semibold))
                            Text(DateKey.label(date, "d")).font(.title3.weight(.semibold)).monospacedDigit()
                        }
                        .frame(width: 36)
                        .foregroundStyle(date == todayKey ? Theme.lift : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            if let dayName {
                                Text(dayName).foregroundStyle(.primary)
                                if let run = slot?.run {
                                    Text("+ \(run.durationMin) min run").font(.caption).foregroundStyle(Theme.run)
                                }
                            } else if let run = slot?.run {
                                Text(run.label.rawValue).foregroundStyle(.primary)
                                Text("\(run.durationMin) min").font(.caption).foregroundStyle(Theme.run)
                            } else {
                                Text("Rest").foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if done.contains(date) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.lift)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(dow == selected ? Theme.lift.opacity(0.15) : nil)
            }
        } header: {
            HStack {
                Text(onTodayWeek ? "Week \(week.id) of \(weeks.last?.id ?? week.id)"
                     : notStarted ? "Week \(week.id) · Starts \(DateKey.label(week.startDate, "MMM d"))"
                     : "Week \(week.id) of \(weeks.last?.id ?? week.id)")
                Spacer()
                weekStepper(week, weeks: weeks)
            }
        }
    }

    private func weekStepper(_ week: ProgramWeek, weeks: [ProgramWeek]) -> some View {
        HStack(spacing: 18) {
            ForEach([-1, 1], id: \.self) { dir in
                let target = weeks.first { $0.id == week.id + dir }
                Button {
                    viewWeekId = target?.id
                    selectedDow = nil
                } label: {
                    Image(systemName: dir < 0 ? "chevron.left" : "chevron.right")
                }
                .disabled(target == nil)
                .accessibilityLabel(dir < 0 ? "Previous week" : "Next week")
            }
        }
        .font(.body.weight(.semibold))
        .textCase(nil)
    }

    private func noProgramSection(hasWeeks: Bool) -> some View {
        Section {
            ForEach(store.db.activeDays) { d in
                Button {
                    store.mutate { $0.startSession(day: d) }
                    nav.showWorkout = true
                } label: {
                    Label(d.name, systemImage: "play.circle")
                }
                .disabled(!store.canEdit)
            }
        } header: {
            Text(hasWeeks ? "No week scheduled" : "No program yet")
        } footer: {
            Text("Pick a workout.")
        }
    }

    // MARK: Starting

    private func start(_ day: Day, week: ProgramWeek, date: String) {
        if let open = store.db.openLift(), open.dayId != day.id || open.slotDate != date {
            confirmDiscard = true
            return
        }
        proceed(day, week: week, date: date)
    }

    private func proceed(_ day: Day, week: ProgramWeek, date: String) {
        store.mutate {
            $0.startSession(day: day, options: StartOptions(deload: week.isDeload, weekNumber: week.id, scheduledDate: date))
        }
        nav.showWorkout = true
    }
}

/// Gear button that also shows sync trouble at a glance.
struct SettingsButton: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav

    var body: some View {
        Button { nav.showSettings = true } label: {
            switch store.syncStatus {
            case .error: Image(systemName: "exclamationmark.icloud").foregroundStyle(Theme.warning)
            case .syncing: ProgressView()
            default: Image(systemName: "gearshape")
            }
        }
        .accessibilityLabel("Settings")
    }
}
