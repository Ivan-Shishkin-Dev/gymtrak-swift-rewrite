import SwiftUI

/// Home: today's workout up top, then this week. Tap a day to open it.
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @Environment(Connections.self) private var connections

    var body: some View {
        let db = store.db
        let today = Date()
        let todayKey = DateKey.key(today)

        NavigationStack {
            List {
                if let week = db.scheduleWeek(today) {
                    DaySections(week: week, dow: DateKey.dow(today), todayKey: todayKey)
                    weekSection(week, todayKey: todayKey)
                } else {
                    noProgramSection()
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(DateKey.dow(today).label)
            .navigationSubtitle(DateKey.label(todayKey, "MMMM d"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .navigationDestination(for: String.self) { DayScreen(date: $0) }
            .refreshable { await store.sync() }
        }
    }

    // MARK: The week

    private func weekSection(_ week: ProgramWeek, todayKey: String) -> some View {
        let db = store.db
        let done = db.doneDates.union(connections.runDates)
        return Section {
            ForEach(Dow.allCases, id: \.self) { dow in
                let slot = week.slot(dow)
                let date = week.date(of: dow)
                let dayName = db.day(slot?.liftDayId)?.name
                NavigationLink(value: date) {
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
                }
                .listRowBackground(date == todayKey ? Theme.lift.opacity(0.2) : nil)
            }
        }
    }

    private func noProgramSection() -> some View {
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
            Text("No schedule yet")
        } footer: {
            Text("Pick a workout.")
        }
    }
}

/// One day, full screen: "Tuesday / October 20" with a back button to home.
struct DayScreen: View {
    let date: String
    @Environment(Store.self) private var store

    var body: some View {
        let d = DateKey.date(date)
        List {
            if let week = store.db.scheduleWeek(d) {
                DaySections(week: week, dow: DateKey.dow(d), todayKey: DateKey.key(Date()), showExercises: true)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(DateKey.dow(d).label)
        .navigationSubtitle(DateKey.label(date, "MMMM d"))
        .navigationBarTitleDisplayMode(.large)
    }
}

/// The hero card, exercises with coach targets, and the run for one weekday.
struct DaySections: View {
    let week: ProgramWeek
    let dow: Dow
    let todayKey: String
    @State var showExercises = false
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @Environment(Connections.self) private var connections
    @State private var confirmDiscard = false

    var body: some View { daySections(week: week, dow: dow, todayKey: todayKey) }

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
                    Text(isToday ? "Today" : date < todayKey ? "Past" : "Upcoming")
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
                if !showExercises {
                    dotRow(onHero: onHero)
                }
            }
            .padding(.vertical, 8)
            .listRowBackground(
                LinearGradient(colors: [heroColor.mix(with: .white, by: 0.12), heroColor.mix(with: .black, by: 0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }

        if !exercises.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showExercises) {
                    ForEach(exercises) { ex in
                        let a = db.liftAdvice(for: ex, today: date)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ex.name)
                            Label {
                                Text(a.target).font(.subheadline.weight(.semibold))
                                + Text(a.range.map { "  \($0)" } ?? "").font(.subheadline).foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: a.icon).foregroundStyle(Theme.lift)
                            }
                            .labelStyle(CoachLabelStyle())
                            Text(a.why).font(.caption).foregroundStyle(.secondary)
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
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.run.opacity(0.14))
                if connections.run(on: date) == nil {
                    RunCoachRow(advice: RunCoach.advice(run, date: date, schedule: week, runs: connections.runs))
                        .listRowBackground(Theme.run.opacity(0.14))
                }
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

    /// Last seven days as dots, with the streak. Home only.
    private func dotRow(onHero: Color) -> some View {
        let now = Date()
        let doneExtra = connections.runDates
        let dots = store.db.weekDots(ending: now, doneExtra: doneExtra)
        let streak = store.db.streakWeeks(today: now, doneExtra: doneExtra)
        return HStack(spacing: 8) {
            ForEach(dots) { dot in
                Circle()
                    .fill(dotFill(dot.state, onHero: onHero))
                    .overlay(Circle().strokeBorder(onHero.opacity(0.6), lineWidth: dot.state == .upcoming ? 1.5 : 0))
                    .frame(width: 10, height: 10)
            }
            Spacer()
            if streak >= 1 {
                Text("\(streak) wk").font(.caption.weight(.semibold)).foregroundStyle(onHero.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last 7 days, \(dots.filter { $0.state == .done }.count) done")
    }

    /// Done uses the hero's own text color: the card is already Theme.lift in most accents, so a lift dot would vanish.
    private func dotFill(_ state: DayDot.State, onHero: Color) -> Color {
        switch state {
        case .done: onHero
        case .missed: .red.opacity(0.6)
        case .rest: onHero.opacity(0.15)
        case .upcoming: .clear
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
            $0.startSession(day: day, options: StartOptions(scheduledDate: date, coach: Coach.autoApply))
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

/// Icon hugging the first line of text.
struct CoachLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) { configuration.icon; configuration.title }
    }
}

/// "Shoot for 40 min" with the range, pace, why, and a few how-to lines.
struct RunCoachRow: View {
    let advice: RunAdvice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Shoot for \(advice.target)", systemImage: "scope").font(.headline).foregroundStyle(Theme.run)
                Spacer()
                if let range = advice.range { Text(range).font(.subheadline).foregroundStyle(.secondary) }
            }
            if let pace = advice.pace {
                Label(pace, systemImage: "speedometer").font(.subheadline.weight(.semibold))
            }
            Text(advice.why).font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(advice.cues, id: \.self) { cue in
                    Label(cue, systemImage: "checkmark").font(.subheadline).labelStyle(CoachLabelStyle())
                }
            }
        }
        .padding(.vertical, 4)
    }
}
