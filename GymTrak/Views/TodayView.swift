import SwiftUI

/// What am I doing today? The lift can be started here; the run is described only
/// (it's tracked on the watch).
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @Environment(Connections.self) private var connections
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

        // The hero card: green for a lift, blue for a run-only day, grey for rest.
        let heroColor: Color = liftDay != nil ? Theme.surface : slot?.run != nil ? Theme.run : Color(hex: 0x3A3A3C)
        let onHero: Color = heroColor.isLight ? .black : .white
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(isToday ? "Today · \(dow.label)" : "\(dow.label) · \(DateKey.label(date, "MMM d"))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(onHero.opacity(0.8))
                    Spacer()
                    if doneLift != nil {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.bold)).foregroundStyle(onHero)
                    }
                }
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: liftDay != nil ? "dumbbell.fill" : slot?.run != nil ? "figure.run" : "moon.zzz.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .rotationEffect(.degrees(liftDay != nil ? -45 : 0))
                        .frame(width: 56, height: 56)
                        .background(onHero.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(liftDay?.name ?? slot?.run?.label.rawValue ?? "Rest Day")
                            .font(.largeTitle.bold())
                        if let liftDay, !liftDay.focus.isEmpty {
                            Text(liftDay.focus).font(.subheadline).foregroundStyle(onHero.opacity(0.8))
                        }
                    }
                }
                .foregroundStyle(onHero)
                if let liftDay {
                    startButton(liftDay, week: week, date: date, done: doneLift != nil)
                }
            }
            .padding(.vertical, 8)
            .listRowBackground(
                LinearGradient(colors: [heroColor.mix(with: .white, by: 0.12), heroColor.mix(with: .black, by: 0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        } footer: {
            if week.isDeload { Label(deloadNote, systemImage: "arrow.down.circle").foregroundStyle(Theme.warning) }
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
                    Label { Text("\(exercises.count) Exercises") } icon: { IconBadge(systemName: "list.bullet", color: Theme.lift) }
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
                    if let notes = run.notes { Text(notes).font(.subheadline).padding(.top, 4) }
                    if run.strides { Text("Then \(stridesNote)").font(.subheadline).padding(.top, 4) }
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.run.opacity(0.14))
                if let done = connections.run(on: date) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Done · \(done.summary)").font(.subheadline.weight(.semibold))
                            Text(done.source == .strava ? "From Strava · \(done.name)" : "From Apple Health")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { IconBadge(systemName: "checkmark", color: Theme.run, size: 28) }
                    .listRowBackground(Theme.run.opacity(0.14))
                }
            } header: {
                Label(liftDay != nil ? "Then Run" : "Run", systemImage: "figure.run").foregroundStyle(Theme.run)
            }
        }
    }

    /// Start, Resume, Do Again, or Unlock — whichever applies right now. White on the colored card.
    private func startButton(_ day: Day, week: ProgramWeek, date: String, done: Bool) -> some View {
        let open = store.db.openLift()
        let isOpen = open?.dayId == day.id && open?.slotDate == date
        let title = !store.canEdit ? "Unlock to Start" : isOpen ? "Resume" : done ? "Do Again" : "Start Workout"
        let icon = !store.canEdit ? "lock.fill" : isOpen ? "arrow.uturn.forward" : "play.fill"
        return Button {
            if !store.canEdit { nav.showSettings = true }
            else if isOpen { nav.showWorkout = true }
            else { start(day, week: week, date: date) }
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(done && !isOpen ? Theme.onSurface : (Theme.onSurface == .white ? Theme.surface.mix(with: .black, by: 0.35) : .white))
                .background(done && !isOpen ? Theme.onSurface.opacity(0.18) : Theme.onSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .confirmationDialog("Discard other workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard and Start", role: .destructive) { proceed(day, week: week, date: date) }
        }
    }

    // MARK: The week

    private func weekSection(_ week: ProgramWeek, weeks: [ProgramWeek], onTodayWeek: Bool,
                             notStarted: Bool, selected: Dow, todayKey: String) -> some View {
        let db = store.db
        let done = db.doneDates.union(connections.runDates)
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

                        IconBadge(systemName: dayName != nil ? "dumbbell.fill" : slot?.run != nil ? "figure.run" : "moon.zzz.fill",
                                  color: dayName != nil ? Theme.lift : slot?.run != nil ? Theme.run : Color(.systemGray3),
                                  size: 28)
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
                .listRowBackground(dow == selected ? Theme.lift.opacity(0.2) : nil)
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
    @Environment(Connections.self) private var connections

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
