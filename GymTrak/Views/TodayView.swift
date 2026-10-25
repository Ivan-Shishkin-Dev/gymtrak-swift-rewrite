import SwiftUI

/// Answers one question: what am I doing today. The lift is started here; the run
/// is only described (it's tracked on the watch).
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @State private var viewWeekId: Int?
    @State private var selectedDow: Dow?
    @State private var exercisesOpenFor: Dow?
    @State private var confirmDiscard = false

    var body: some View {
        let db = store.db
        let weeks = db.weeks
        let today = Date()
        let todayKey = DateKey.key(today)
        let todayWeek = weekFor(weeks, today)
        // Program not started yet → show its first week instead of "nothing scheduled".
        let nextWeek = todayWeek == nil ? weeks.first { $0.startDate > todayKey } : nil
        let week = weeks.first { $0.id == viewWeekId } ?? todayWeek ?? nextWeek

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let week {
                        let onTodayWeek = week.id == todayWeek?.id
                        let dow = selectedDow ?? (onTodayWeek ? DateKey.dow(today) : .mon)
                        weekHeader(week, weeks: weeks, onTodayWeek: onTodayWeek, notStarted: week.id == nextWeek?.id)
                        if week.isDeload {
                            Text(deloadNote)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
                                .padding(.horizontal, 15).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.amber.opacity(0.28)))
                        }
                        dayCard(week: week, dow: dow, todayKey: todayKey)
                        Text(onTodayWeek ? "THIS WEEK" : "WEEK \(week.id)").eyebrow().padding(.top, 2)
                        WeekListView(week: week, days: db.days, doneDates: db.doneDates, todayKey: todayKey,
                                     selected: dow) { selectedDow = $0 }
                    } else {
                        noWeekCard(hasWeeks: !weeks.isEmpty)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("Today")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SyncBadge() } }
            .refreshable { await store.sync() }
        }
    }

    // MARK: Week header

    private func weekHeader(_ week: ProgramWeek, weeks: [ProgramWeek], onTodayWeek: Bool, notStarted: Bool) -> some View {
        HStack {
            Group {
                if onTodayWeek {
                    Text("WEEK \(week.id) OF \(weeks.last?.id ?? week.id)")
                } else if notStarted {
                    Text("WEEK \(week.id) OF \(weeks.last?.id ?? week.id) · STARTS \(DateKey.label(week.startDate, "EEE MMM d").uppercased())")
                } else {
                    Text("WEEK \(week.id) OF \(weeks.last?.id ?? week.id) · PREVIEW")
                }
            }
            .eyebrow(onTodayWeek ? Theme.volt : Theme.sub)
            Spacer()
            HStack(spacing: 0) {
                ForEach([-1, 1], id: \.self) { dir in
                    let target = weeks.first { $0.id == week.id + dir }
                    Button {
                        viewWeekId = target?.id
                        selectedDow = nil
                    } label: {
                        Image(systemName: dir < 0 ? "chevron.left" : "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 38, height: 30)
                    }
                    .disabled(target == nil)
                    .foregroundStyle(target == nil ? Theme.future : Theme.text)
                    if dir < 0 { Rectangle().fill(Theme.separator).frame(width: 1, height: 30) }
                }
            }
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.pillBorder))
        }
    }

    // MARK: The day card

    @ViewBuilder
    private func dayCard(week: ProgramWeek, dow: Dow, todayKey: String) -> some View {
        let db = store.db
        let slot = week.slot(dow)
        let selDate = week.date(of: dow)
        let liftDay = db.day(slot?.liftDayId)
        let exercises = liftDay.map { db.exercises(of: $0.id) } ?? []
        let doneLift = liftDay.flatMap { d in
            db.sessions.first { $0.slotDate == selDate && $0.finishedAt != nil && !$0.isDeleted && !$0.isRun && $0.dayId == d.id }
        }

        VStack(alignment: .leading, spacing: 14) {
            Text(selDate == todayKey ? "TODAY · \(dow.label.uppercased())"
                                     : "\(dow.label.uppercased()) · \(DateKey.label(selDate, "MMM d").uppercased())")
                .eyebrow(selDate == todayKey ? Theme.volt : Theme.sub)

            if slot?.isRest ?? true {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Rest").font(.display(36)).foregroundStyle(Theme.sub)
                    Text("Nothing scheduled.").font(.system(size: 14)).foregroundStyle(Theme.sub)
                }
            }

            if let liftDay {
                VStack(alignment: .leading, spacing: 12) {
                    Label("LIFT", systemImage: "dumbbell.fill").eyebrow(Theme.volt)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(liftDay.name).font(.display(36))
                        if !liftDay.focus.isEmpty {
                            Text(liftDay.focus).font(.system(size: 14)).foregroundStyle(Theme.sub)
                        }
                    }
                    if !exercises.isEmpty { exerciseList(exercises, dow: dow) }
                    if doneLift != nil {
                        Label("\(liftDay.name) done", systemImage: "checkmark")
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.volt)
                    }
                    if store.canEdit {
                        let label = doneLift != nil ? "Repeat \(liftDay.name)"
                            : selDate != todayKey ? "Do \(liftDay.name) today" : "Start \(liftDay.name)"
                        Button {
                            start(liftDay, week: week, date: selDate)
                        } label: {
                            Label(label, systemImage: "play.fill")
                        }
                        .buttonStyle(VoltButtonStyle(quiet: doneLift != nil))
                        .confirmationDialog(discardTitle, isPresented: $confirmDiscard, titleVisibility: .visible) {
                            Button("Discard & start", role: .destructive) { proceed(liftDay, week: week, date: selDate) }
                            Button("Keep it", role: .cancel) {}
                        } message: {
                            Text("Starting this one discards the unfinished session. This can't be undone.")
                        }
                    }
                }
            }

            if let run = slot?.run {
                runSection(run, afterLift: liftDay != nil)
            }
        }
        .card()
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.volt.opacity(0.58)).frame(height: 2).padding(.horizontal, 18)
        }
    }

    private func exerciseList(_ exercises: [Exercise], dow: Dow) -> some View {
        let open = exercisesOpenFor == dow
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { exercisesOpenFor = open ? nil : dow }
            } label: {
                HStack {
                    Text("\(exercises.count) exercises")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0)).foregroundStyle(Theme.dim)
                }
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.sub)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.pillBorder))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(spacing: 0) {
                    ForEach(Array(exercises.enumerated()), id: \.element.id) { i, ex in
                        if i > 0 { Divider().overlay(Theme.separator) }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(ex.name).font(.system(size: 14))
                            Spacer(minLength: 8)
                            Text(exerciseSummary(ex.rows))
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.value)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, 2).padding(.top, 4)
            }
        }
    }

    private func runSection(_ run: RunPrescription, afterLift: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if afterLift { Divider().overlay(Theme.separator).padding(.bottom, 4) }
            Label(afterLift ? "RUN · AFTER THE LIFT" : "RUN", systemImage: "figure.run").eyebrow(Theme.run)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(run.label.rawValue).font(.display(afterLift ? 28 : 36))
                Text("\(run.durationMin) min").font(.display(afterLift ? 22 : 26)).foregroundStyle(Theme.run)
            }
            Text("\(run.label.effort) · \(zoneLabel(run.hrZoneMin, run.hrZoneMax)) bpm" +
                 (run.label.isEasy ? " · about \(Zone2.milesLabel(run.durationMin))" : ""))
                .font(.system(size: 14)).foregroundStyle(Theme.sub)
            if run.notes != nil || run.strides {
                VStack(alignment: .leading, spacing: 6) {
                    if let notes = run.notes { Text(notes) }
                    if run.strides { Text("Then \(stridesNote)") }
                }
                .font(.system(size: 13.5)).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.runTint, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func noWeekCard(hasWeeks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(hasWeeks ? "No week scheduled" : "No program yet").font(.display(25))
            Text(hasWeeks ? "Today falls outside the program. Re-anchor it in the Plan tab, or pick a day below."
                          : "Pick a day below to start a workout.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.sub)
            if store.canEdit {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(store.db.activeDays) { d in
                        Button(d.name) {
                            store.mutate { $0.startSession(day: d) }
                            nav.showWorkout = true
                        }
                        .buttonStyle(VoltButtonStyle(quiet: true))
                    }
                }
            }
        }
        .card(radius: 24, padding: 22)
    }

    // MARK: Starting


    private var discardTitle: String {
        let open = store.db.openLift()
        return "Discard the \(store.db.day(open?.dayId)?.name ?? "open") session?"
    }

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

/// Sync state as a small toolbar badge; tap for settings.
struct SyncBadge: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav

    var body: some View {
        Button { nav.showSettings = true } label: {
            HStack(spacing: 6) {
                switch store.syncStatus {
                case .syncing: ProgressView().controlSize(.mini)
                case .synced: Image(systemName: "checkmark.icloud").foregroundStyle(Theme.sub)
                case .error: Image(systemName: "exclamationmark.icloud").foregroundStyle(Theme.amber)
                case .offline: Image(systemName: "icloud.slash").foregroundStyle(Theme.dim)
                case .idle: Image(systemName: "icloud").foregroundStyle(Theme.dim)
                }
                Image(systemName: store.canEdit ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(store.canEdit ? Theme.volt : Theme.sub)
            }
            .font(.system(size: 14))
        }
    }
}
