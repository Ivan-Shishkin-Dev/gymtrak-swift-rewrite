import SwiftUI

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
                    // Greeting and settings share one row at the top of the page.
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.isEmpty ? "Today" : "Hi, \(name)")
                                .font(.system(size: 34, weight: .bold)).foregroundStyle(Page.text)
                            Text(DateKey.label(todayKey, "EEEE, MMMM d"))
                                .font(.title3).foregroundStyle(Page.secondary)
                        }
                        .accessibilityAddTraits(.isHeader)
                        Spacer()
                        SettingsButton()
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(Page.fill, in: Circle())
                            .foregroundStyle(Page.text)
                    }
                    .padding(.top, 20)

                    if let week = db.scheduleWeek(now) {
                        properties(week, todayKey: todayKey)
                        recent
                    } else {
                        noSchedule
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
            .refreshable { await connections.refresh() }
            .background(Page.bg)
            .navigationTitle("Today")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { DayScreen(date: $0) }
            .navigationDestination(for: SessionRef.self) { SessionDetailView(sessionId: $0.id) }
        }
    }

    // MARK: Properties

    @ViewBuilder
    private func properties(_ week: ProgramWeek, todayKey: String) -> some View {
        let db = store.db
        let slot = week.slot(DateKey.dow(Date()))
        let liftDay = db.day(slot?.liftDayId)
        let today = connections.activity[todayKey]

        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: todayKey) {
                HStack(alignment: .top, spacing: 10) {
                    liftTile(liftDay, done: db.doneDates.contains(todayKey), todayKey: todayKey)
                    runTile(slot?.run, done: connections.runDates.contains(todayKey), todayKey: todayKey)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)

            if let liftDay {
                StartButton(day: liftDay, date: todayKey).padding(.top, 10)
            }

            if connections.healthConnected {
                VStack(spacing: 0) {
                    PropertyRow(icon: "shoeprints.fill", label: "Steps") { Text(today.map { $0.steps.formatted() } ?? "—") }
                    PropertyRow(icon: "flame", label: "Calories") { Text(today.map { "\(Int($0.calories.rounded()).formatted()) kcal" } ?? "—") }
                }
                .padding(.top, 18)
            } else if connections.healthAvailable {
                PropertyRow(icon: "heart", label: "Activity") {
                    Button("Connect Apple Health") { Task { await connections.connectHealth() } }
                        .foregroundStyle(Page.text).underline()
                }
                .padding(.top, 18)
            }
        }
    }

    private func liftTile(_ day: Day?, done: Bool, todayKey: String) -> some View {
        let count = day.map { store.db.exercises(of: $0.id).count } ?? 0
        return TodayTile(icon: "dumbbell", label: "Lift", done: done,
                         title: day?.name ?? "Off",
                         detail: day == nil ? Self.pick(Self.liftOff, todayKey) : (count == 1 ? "1 exercise" : "\(count) exercises"),
                         resting: day == nil)
    }

    private func runTile(_ run: RunPrescription?, done: Bool, todayKey: String) -> some View {
        TodayTile(icon: run == nil ? "sofa" : "figure.run", label: "Run", done: done,
                  title: run?.label.rawValue ?? "Rest",
                  detail: run.map { "\($0.durationMin) min" } ?? Self.pick(Self.runOff, todayKey),
                  resting: run == nil)
    }

    private static let liftOff = ["Iron gets a day off", "The bar is resting too", "Muscles under construction", "Grow, don't go"]
    private static let runOff = ["Legs on vacation", "Shoes are napping", "Zero miles, full credit", "Couch is the route"]

    /// Same line all day, a different one tomorrow.
    private static func pick(_ lines: [String], _ key: String) -> String {
        lines[abs(key.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % lines.count]
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
        }

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
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { e in
                    HistoryRow(entry: e)
                }
            }
        }
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
                    if !exercises.isEmpty {
                        PropertyRow(icon: "list.bullet", label: "Exercises") { Text("\(exercises.count)") }
                    }
                    if let run = slot?.run {
                        PropertyRow(icon: "figure.run", label: "Run") {
                            HStack(spacing: 8) { Text("\(run.durationMin) min"); Tag(text: run.label.effort) }
                        }
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
                                // Two columns: name left, target right. Every row lines up the same way.
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(ex.name).foregroundStyle(Page.text).lineLimit(1)
                                        if let note = a.note { Text(note).font(.caption).foregroundStyle(Page.secondary) }
                                    }
                                    Spacer(minLength: 8)
                                    Text(a.target).fontWeight(.semibold).foregroundStyle(Page.text).monospacedDigit()
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 10)
                                if ex.id != exercises.last?.id { Rectangle().fill(Page.divider).frame(height: 1) }
                            }
                        }
                    }
                }

                if let run = slot?.run {
                    PageSection(liftDay != nil ? "Then run" : "Run") {
                        VStack(alignment: .leading, spacing: 0) {
                            PropertyRow(icon: "gauge.with.dots.needle.33percent", label: "Effort") { Text(run.label.effort) }
                            PropertyRow(icon: "heart", label: "Heart rate") { Text("\(zoneLabel(run.hrZoneMin, run.hrZoneMax)) bpm") }
                            if run.label.isEasy {
                                PropertyRow(icon: "location", label: "Distance") { Text("About \(Zone2.milesLabel(run.durationMin))") }
                            }
                        }
                        if let notes = run.notes { Text(notes).font(.subheadline).foregroundStyle(Page.text) }
                        if let logged = connections.run(on: date) {
                            PropertyRow(icon: "checkmark", label: "Done") { Text(logged.summary) }
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
        .toolbarBackground(Page.bg, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
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
            Text("Shoot for \(advice.target)").font(.headline).foregroundStyle(Page.text)
            if let pace = advice.pace { Text(pace).font(.subheadline).foregroundStyle(Page.text) }
            if let note = advice.note { Text(note).font(.subheadline).foregroundStyle(Page.secondary) }
            ForEach(advice.cues, id: \.self) { cue in
                Text("• \(cue)").font(.subheadline).foregroundStyle(Page.secondary)
            }
        }
    }
}

/// One half of Today: what's planned for lifting or running, or a rest line.
private struct TodayTile: View {
    let icon: String
    let label: String
    let done: Bool
    let title: String
    let detail: String
    let resting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.subheadline)
                Text(label).font(.subheadline)
                Spacer(minLength: 0)
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Page.text) }
            }
            .foregroundStyle(Page.secondary)
            Spacer(minLength: 4)
            Text(title).font(.title3.weight(.bold))
                .foregroundStyle(resting ? Page.secondary : Page.text)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.subheadline).foregroundStyle(Page.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Page.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A small gray capsule for a short label, like a weekday or "Zone 2".
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Page.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Page.fill, in: Capsule())
    }
}
