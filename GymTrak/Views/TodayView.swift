import SwiftUI
import Charts

/// Opens a finished workout from anywhere (Today's recent list, History).
struct SessionRef: Hashable { let id: String }

/// Home, Notion-style: a greeting, today's numbers as properties, the week, recent activity, the schedule.
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @Environment(Connections.self) private var connections
    @AppStorage("gt_name") private var name = "Ivan"
    @State private var filter = RecentFilter.all

    enum RecentFilter: String, CaseIterable { case all = "All", lifts = "Lifts", runs = "Runs" }

    var body: some View {
        let db = store.db
        let now = Date()
        let todayKey = DateKey.key(now)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let week = db.scheduleWeek(now) {
                        properties(week, todayKey: todayKey)
                        weekChart(week, todayKey: todayKey)
                        recent
                        schedule(week, todayKey: todayKey)
                    } else {
                        noSchedule
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 110)
            }
            .background(Page.bg)
            .topLeftTitle(name.isEmpty ? "Today" : "Hi, \(name)", subtitle: DateKey.label(todayKey, "EEEE, MMMM d"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .navigationDestination(for: String.self) { DayScreen(date: $0) }
            .navigationDestination(for: SessionRef.self) { SessionDetailView(sessionId: $0.id) }
            .refreshable { await connections.refresh() }
        }
    }

    // MARK: Properties

    @ViewBuilder
    private func properties(_ week: ProgramWeek, todayKey: String) -> some View {
        let db = store.db
        let slot = week.slot(DateKey.dow(Date()))
        let liftDay = db.day(slot?.liftDayId)
        let done = db.doneDates.union(connections.runDates)
        let today = connections.activity[todayKey]
        let planned = Dow.allCases.filter { !(week.slot($0)?.isRest ?? true) }
        let doneCount = planned.filter { done.contains(week.date(of: $0)) }.count
        let pct = planned.isEmpty ? 0 : Double(doneCount) / Double(planned.count)
        let streak = db.streakWeeks(today: Date(), doneExtra: connections.runDates)

        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: todayKey) {
                PropertyRow(icon: "calendar", label: "Today") {
                    HStack(spacing: 6) {
                        Text(todayTitle(slot, liftDay: liftDay)).fontWeight(.medium)
                        if done.contains(todayKey) { Image(systemName: "checkmark").foregroundStyle(Page.secondary) }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Page.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            if connections.healthConnected {
                PropertyRow(icon: "shoeprints.fill", label: "Steps") { Text(today.map { $0.steps.formatted() } ?? "—") }
                PropertyRow(icon: "flame", label: "Calories") { Text(today.map { "\(Int($0.calories.rounded()).formatted()) kcal" } ?? "—") }
                PropertyRow(icon: "location", label: "Distance") { Text(today.map { String(format: "%.1f mi", $0.miles) } ?? "—") }
            } else if connections.healthAvailable {
                PropertyRow(icon: "heart", label: "Activity") {
                    Button("Connect Apple Health") { Task { await connections.connectHealth() } }
                        .foregroundStyle(Page.text).underline()
                }
            }

            PropertyRow(icon: "target", label: "Weekly goal") {
                HStack(spacing: 10) {
                    Text("\(Int((pct * 100).rounded()))%").fontWeight(.medium)
                    ProgressView(value: pct).tint(Page.text).frame(maxWidth: 90)
                    Text("\(doneCount) of \(planned.count)").foregroundStyle(Page.secondary)
                }
            }
            if streak > 0 {
                PropertyRow(icon: "flame.fill", label: "Streak") { Text(streak == 1 ? "1 week" : "\(streak) weeks") }
            }

            if let liftDay {
                StartButton(day: liftDay, date: todayKey).padding(.top, 14)
            }
        }
    }

    private func todayTitle(_ slot: ProgramSlot?, liftDay: Day?) -> String {
        if let liftDay {
            let n = store.db.exercises(of: liftDay.id).count
            return "\(liftDay.name) · \(n) lifts" + (slot?.run.map { " + \($0.durationMin) min run" } ?? "")
        }
        if let run = slot?.run { return "\(run.label.rawValue) · \(run.durationMin) min" }
        return "Rest Day"
    }

    // MARK: Week chart

    private struct Bar: Identifiable { let id: String; let label: String; let value: Double; let isToday: Bool; let done: Bool }

    @ViewBuilder
    private func weekChart(_ week: ProgramWeek, todayKey: String) -> some View {
        let db = store.db
        let done = db.doneDates.union(connections.runDates)
        let useSteps = connections.healthConnected && Dow.allCases.contains { (connections.activity[week.date(of: $0)]?.steps ?? 0) > 0 }
        let minutes = db.minutesTrained(runs: connections.runs)
        let bars = Dow.allCases.map { dow -> Bar in
            let key = week.date(of: dow)
            let v = useSteps ? Double(connections.activity[key]?.steps ?? 0) : minutes[key] ?? 0
            return Bar(id: key, label: dow.short, value: v, isToday: key == todayKey, done: done.contains(key))
        }
        let range = "\(DateKey.label(week.startDate, "MMM d")) – \(DateKey.label(DateKey.addDays(week.startDate, 6), "MMM d"))"

        PageSection("This week", trailing: { Text(range) }) {
            Text(useSteps ? "Steps" : "Minutes trained").font(.subheadline).foregroundStyle(Page.secondary)
            Chart(bars) { b in
                BarMark(x: .value("Day", b.label), y: .value("Value", b.value), width: .ratio(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(b.isToday ? Page.text : Page.tertiary)
                    .annotation(position: .top, spacing: 4) {
                        if b.value > 0 {
                            Text(compact(b.value)).font(.caption2).foregroundStyle(Page.secondary)
                        }
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) {
                            let b = bars.first { $0.label == s }
                            VStack(spacing: 2) {
                                Text(s).font(.caption).foregroundStyle(b?.isToday == true ? Page.text : Page.secondary)
                                Circle().fill(b?.done == true ? Page.text : .clear).frame(width: 4, height: 4)
                            }
                        }
                    }
                }
            }
            .frame(height: 170)
        }
    }

    private func compact(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))"
    }

    // MARK: Recent

    private var recent: some View {
        let all = store.db.historyEntries(synced: connections.runs)
        let rows = all.filter {
            switch filter {
            case .all: true
            case .lifts: if case .lift = $0.kind { true } else { false }
            case .runs: $0.kind == .run
            }
        }.prefix(3)

        return PageSection("Recent", trailing: {
            Button("See all") { nav.tab = .history }.buttonStyle(.plain).underline()
        }) {
            HStack(spacing: 8) {
                ForEach(RecentFilter.allCases, id: \.self) { f in
                    Chip(title: f.rawValue, selected: filter == f) { filter = f }
                }
            }
            .padding(.bottom, 2)
            if rows.isEmpty {
                Text("Nothing yet.").foregroundStyle(Page.secondary).padding(.vertical, 6)
            }
            ForEach(Array(rows)) { e in
                HistoryRow(entry: e)
            }
        }
    }

    // MARK: Schedule

    private func schedule(_ week: ProgramWeek, todayKey: String) -> some View {
        let db = store.db
        let done = db.doneDates.union(connections.runDates)
        return PageSection("Schedule") {
            VStack(spacing: 0) {
                ForEach(Dow.allCases, id: \.self) { dow in
                    let slot = week.slot(dow)
                    let date = week.date(of: dow)
                    let isToday = date == todayKey
                    NavigationLink(value: date) {
                        HStack(spacing: 12) {
                            Text("\(dow.short) \(DateKey.label(date, "d"))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(isToday ? Page.text : Page.secondary)
                                .frame(width: 56, alignment: .leading)
                            Text(scheduleTitle(slot))
                                .foregroundStyle(slot?.isRest ?? true ? Page.secondary : Page.text)
                                .fontWeight(isToday ? .semibold : .regular)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if done.contains(date) { Image(systemName: "checkmark").foregroundStyle(Page.secondary) }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if dow != .sun { Rectangle().fill(Page.divider).frame(height: 1) }
                }
            }
        }
    }

    private func scheduleTitle(_ slot: ProgramSlot?) -> String {
        if let name = store.db.day(slot?.liftDayId)?.name {
            return name + (slot?.run.map { " + \($0.durationMin) min run" } ?? "")
        }
        if let run = slot?.run { return "\(run.label.rawValue) · \(run.durationMin) min" }
        return "Rest"
    }

    private var noSchedule: some View {
        PageSection("Pick a workout") {
            ForEach(store.db.activeDays) { d in
                Button {
                    store.mutate { $0.startSession(day: d) }
                    nav.showWorkout = true
                } label: {
                    Label(d.name, systemImage: "play").foregroundStyle(Page.text)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// One row of history: title, detail, date. Lifts open their sets.
struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        switch entry.kind {
        case .lift(let id):
            NavigationLink(value: SessionRef(id: id)) { label }.buttonStyle(.plain)
        case .run:
            label
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: entry.kind == .run ? "figure.run" : "dumbbell")
                .foregroundStyle(Page.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).foregroundStyle(Page.text)
                Text(entry.detail).font(.subheadline).foregroundStyle(Page.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(DateKey.label(entry.date, "MMM d")).font(.subheadline).foregroundStyle(Page.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// One day as a page: properties, the start button, exercises with coach targets, and the run.
struct DayScreen: View {
    let date: String
    @Environment(Store.self) private var store
    @Environment(Connections.self) private var connections

    var body: some View {
        let db = store.db
        let d = DateKey.date(date)
        let todayKey = DateKey.key(Date())
        let week = db.scheduleWeek(d)
        let slot = week?.slot(DateKey.dow(d))
        let liftDay = db.day(slot?.liftDayId)
        let exercises = liftDay.map { db.exercises(of: $0.id) } ?? []
        let done = db.doneDates.union(connections.runDates).contains(date)
        let title = liftDay?.name ?? slot?.run?.label.rawValue ?? "Rest Day"

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(Page.text).padding(.bottom, 10)
                    PropertyRow(icon: "calendar", label: "Date") { Text(DateKey.label(date, "EEEE, MMMM d")) }
                    PropertyRow(icon: "circle.dashed", label: "Status") {
                        Text(done ? "Done" : date == todayKey ? "Today" : date < todayKey ? "Missed" : "Upcoming")
                    }
                    if let liftDay, !liftDay.focus.isEmpty {
                        PropertyRow(icon: "scope", label: "Focus") { Text(liftDay.focus) }
                    }
                    if !exercises.isEmpty {
                        PropertyRow(icon: "list.bullet", label: "Exercises") { Text("\(exercises.count)") }
                    }
                    if let run = slot?.run {
                        PropertyRow(icon: "figure.run", label: "Run") { Text("\(run.durationMin) min · \(run.label.effort)") }
                    }
                    if let liftDay {
                        StartButton(day: liftDay, date: date).padding(.top, 14)
                    }
                }

                if !exercises.isEmpty {
                    PageSection("Exercises") {
                        VStack(spacing: 0) {
                            ForEach(exercises) { ex in
                                let a = db.liftAdvice(for: ex, today: date)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ex.name).foregroundStyle(Page.text)
                                    HStack(spacing: 6) {
                                        Image(systemName: a.icon).font(.caption).foregroundStyle(Page.secondary)
                                        Text(a.target).font(.subheadline.weight(.semibold)).foregroundStyle(Page.text)
                                        if let r = a.range { Text(r).font(.subheadline).foregroundStyle(Page.secondary) }
                                    }
                                    if let note = a.note { Text(note).font(.caption).foregroundStyle(Page.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 9)
                                if ex.id != exercises.last?.id { Rectangle().fill(Page.divider).frame(height: 1) }
                            }
                        }
                    }
                }

                if let run = slot?.run {
                    PageSection(liftDay != nil ? "Then run" : "Run") {
                        Text("\(run.label.effort) · \(zoneLabel(run.hrZoneMin, run.hrZoneMax)) bpm" +
                             (run.label.isEasy ? " · about \(Zone2.milesLabel(run.durationMin))" : ""))
                            .font(.subheadline).foregroundStyle(Page.secondary)
                        if let notes = run.notes { Text(notes).font(.subheadline).foregroundStyle(Page.text) }
                        if let logged = connections.run(on: date) {
                            Label("Done · \(logged.summary)", systemImage: "checkmark").foregroundStyle(Page.text)
                        } else if let week {
                            RunCoachRow(advice: RunCoach.advice(run, date: date, schedule: week, runs: connections.runs))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
        }
        .background(Page.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
    }
}

/// Start, Resume, or Do Again for one lift day on one date.
struct StartButton: View {
    let day: Day
    let date: String
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @State private var confirmDiscard = false

    var body: some View {
        let db = store.db
        let open = db.openLift()
        let isOpen = open?.dayId == day.id && open?.slotDate == date
        let done = db.sessions.contains { $0.slotDate == date && $0.finishedAt != nil && !$0.isDeleted && !$0.isRun && $0.dayId == day.id }
        PrimaryButton(title: isOpen ? "Resume" : done ? "Do Again" : "Start Workout",
                      icon: isOpen ? "arrow.uturn.forward" : "play.fill",
                      muted: done && !isOpen) {
            if isOpen { nav.showWorkout = true }
            else if let open, open.dayId != day.id || open.slotDate != date { confirmDiscard = true }
            else { proceed() }
        }
        .confirmationDialog("Discard other workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard and Start", role: .destructive) { proceed() }
        }
    }

    private func proceed() {
        store.mutate { $0.startSession(day: day, options: StartOptions(scheduledDate: date, coach: Coach.autoApply)) }
        nav.showWorkout = true
    }
}

/// Gear button; turns orange when the last save failed.
struct SettingsButton: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav

    var body: some View {
        Button { nav.showSettings = true } label: {
            if store.saveError != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            } else {
                Image(systemName: "gearshape")
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

/// "Shoot for 40 min" with the range, pace, a note when it matters, and a few how-to lines.
struct RunCoachRow: View {
    let advice: RunAdvice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shoot for \(advice.target)").font(.headline).foregroundStyle(Page.text)
                Spacer()
                if let range = advice.range { Text(range).font(.subheadline).foregroundStyle(Page.secondary) }
            }
            if let pace = advice.pace { Text(pace).font(.subheadline).foregroundStyle(Page.text) }
            if let note = advice.note { Text(note).font(.subheadline).foregroundStyle(Page.secondary) }
            ForEach(advice.cues, id: \.self) { cue in
                Text("• \(cue)").font(.subheadline).foregroundStyle(Page.secondary)
            }
        }
    }
}
