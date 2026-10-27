import SwiftUI

/// Opens a finished workout from anywhere (Today's recent list, History).
struct SessionRef: Hashable { let id: String }

/// Home, Notion-style: a greeting, today's numbers as properties, the week, recent activity, the schedule.
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(AppNav.self) private var nav
    @Environment(Connections.self) private var connections
    @AppStorage("gt_name") private var name = "Ivan"


    var body: some View {
        let db = store.db
        let now = Date()
        let todayKey = DateKey.key(now)

        NavigationStack {
            // Pinned to the top and stretched to the bottom; scrolls only if a small phone can't fit it.
            ViewThatFits(in: .vertical) {
                page(db, now: now, todayKey: todayKey)
                    .padding(.top, 8).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                ScrollView { page(db, now: now, todayKey: todayKey).padding(.top, 20).padding(.bottom, 110) }
            }
            .background(Page.bg)
            .navigationTitle("Today")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { DayScreen(date: $0) }
            .navigationDestination(for: SessionRef.self) { SessionDetailView(sessionId: $0.id) }
        }
    }

    @ViewBuilder
    private func page(_ db: Snapshot, now: Date, todayKey: String) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Today" : "Hi, \(name)")
                    .font(.system(size: 34, weight: .bold)).foregroundStyle(Page.text)
                Text(DateKey.label(todayKey, "EEEE, MMMM d"))
                    .font(.title3).foregroundStyle(Page.secondary)
            }
            .accessibilityAddTraits(.isHeader)

            if let week = db.scheduleWeek(now) {
                properties(week, todayKey: todayKey)
                let record = db.activityRecord(today: now, runDates: connections.runDates)
                if !record.isEmpty {
                    PageSection("Adherence") { CalendarKey() } content: { TrackRecord(days: record, isRest: db.isRestDay) }
                }
            } else {
                noSchedule
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
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
                         title: day?.name ?? "Rest",
                         detail: day == nil ? "" : (count == 1 ? "1 exercise" : "\(count) exercises"),
                         resting: day == nil)
    }

    private func runTile(_ run: RunPrescription?, done: Bool, todayKey: String) -> some View {
        TodayTile(icon: run == nil ? "sofa" : "figure.run", label: "Run", done: done,
                  title: run?.label.rawValue ?? "Rest",
                  detail: run.map { "\($0.durationMin) min" } ?? "",
                  resting: run == nil)
    }

    // MARK: Recent

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
                HStack(spacing: 8) {
                    Text(entry.title).foregroundStyle(Page.text)
                    if let o = entry.outcome { Tag(text: o.label, tint: o.color) }
                }
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
                        Text(done ? "Done" : (slot?.isRest ?? true) ? "Rest" : date == todayKey ? "Today" : date < todayKey ? "Missed" : "Upcoming")
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
                                    Text(ex.name).foregroundStyle(Page.text).lineLimit(1)
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
                    PageSection("Run") {
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

/// Icon hugging the first line of text.
struct CoachLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) { configuration.icon; configuration.title }
    }
}

/// "Shoot for 40 min" with the pace and a few how-to lines.
struct RunCoachRow: View {
    let advice: RunAdvice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shoot for \(advice.target)").font(.headline).foregroundStyle(Page.text)
            if let pace = advice.pace { Text(pace).font(.subheadline).foregroundStyle(Page.text) }
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
            // A rest tile has no detail line, so its title grows to fill the same space.
            Text(title).font(detail.isEmpty ? .system(size: 30, weight: .bold) : .title3.weight(.bold))
                .foregroundStyle(resting ? Page.secondary : Page.text)
                .lineLimit(1).minimumScaleFactor(0.75)
            if !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundStyle(Page.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
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
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint ?? Page.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.map { $0.opacity(0.16) } ?? Page.fill, in: Capsule())
    }
}

extension LiftOutcome {
    var label: String {
        switch self {
        case .finished: "Finished"
        case .almost: "Almost"
        case .skipped: "Skipped"
        }
    }

    var color: Color {
        switch self {
        case .finished: Color(light: 0x2DA44E, dark: 0x3FB950)
        case .almost: Color(light: 0xBF8700, dark: 0xE3B341)
        case .skipped: Color(light: 0xCF222E, dark: 0xF85149)
        }
    }
}

/// A month of training, one row per week (Sun–Sat). Green lift, blue run, split down the middle on days with both;
/// faded when missed. Rest days get a moon; unknown days and the future stay gray. Tap a colored day to open it.
struct TrackRecord: View {
    let days: [ActivityDay]
    var isRest: (String) -> Bool = { _ in false }
    /// History's week: shows its month, dims every other day, and hides the month arrows.
    var focus: ClosedRange<String>? = nil
    /// Called when a day is tapped, alongside opening it (History uses it to move to that week).
    var onPick: ((String) -> Void)? = nil
    @State private var monthOffset = 0

    var body: some View {
        let cal = DateKey.calendar
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let month = focus.map { f in
            let d = DateKey.date(f.lowerBound)
            return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
        } ?? cal.date(byAdding: .month, value: monthOffset, to: thisMonth) ?? thisMonth
        let monthKey = String(DateKey.key(month).prefix(7))
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let weeks = Self.weeks(of: month, through: focus?.upperBound)
        let letters = ["S", "M", "T", "W", "T", "F", "S"]
        let todayKey = DateKey.key(Date())
        let earliest = days.first.map { String($0.date.prefix(7)) } ?? monthKey

        VStack(spacing: 10) {
            HStack {
                // Arrows only show when there's a month to go to.
                let canBack = focus == nil && monthKey > earliest
                let canForward = focus == nil && monthOffset < 0
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(!canBack).opacity(canBack ? 1 : 0)
                Spacer()
                Text(DateKey.label(DateKey.key(month), "MMMM yyyy")).font(.subheadline.weight(.semibold)).foregroundStyle(Page.text)
                Spacer()
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(!canForward).opacity(canForward ? 1 : 0)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Page.secondary)
            .buttonStyle(.plain)

            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(letters.indices, id: \.self) { i in
                        Text(letters[i])
                            .font(.caption2.weight(.medium)).foregroundStyle(Page.tertiary)
                    }
                }
                ForEach(weeks, id: \.self) { week in
                    GridRow {
                        ForEach(week, id: \.self) { key in
                            cell(key, inMonth: key.hasPrefix(monthKey) || focus?.contains(key) == true,
                                 day: byDate[key], isToday: key == todayKey)
                                .opacity(focus.map { $0.contains(key) ? 1 : 0.35 } ?? 1)
                        }
                    }
                }
            }

        }
    }

    @ViewBuilder
    private func cell(_ key: String, inMonth: Bool, day: ActivityDay?, isToday: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let resting = inMonth && day == nil && isRest(key)
        // Solid when everything planned happened, so the number reads dark on color.
        let solid = day.map { $0.lift != .missed && $0.run != .missed } ?? false
        let tile = shape
            .fill(inMonth ? (resting ? Self.restFill : Page.fill) : .clear)
            .overlay {
                if inMonth, let day {
                    HStack(spacing: 0) {
                        if let m = day.lift { Rectangle().fill(DayColor.lift.opacity(m == .done ? 1 : 0.3)) }
                        if let m = day.run { Rectangle().fill(DayColor.run.opacity(m == .done ? 1 : 0.3)) }
                    }
                    .clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(isToday ? Page.text : .clear, lineWidth: 1.5))
            .overlay {
                if inMonth {
                    VStack(spacing: 1) {
                        Text(DateKey.label(key, "d"))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                        if resting {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .foregroundStyle(solid ? Color.black.opacity(0.7) : day != nil ? Page.text : resting ? Self.restInk : Page.tertiary)
                }
            }
            // Cells take the spare height so the page reaches the bottom of the screen.
            .frame(minHeight: 30, maxHeight: 64)
            .frame(maxWidth: .infinity)
            .contentShape(shape)

        if inMonth {
            // Every day opens: a logged workout opens its sets, any other day opens the day.
            Group {
                if let id = day?.sessionId {
                    NavigationLink(value: SessionRef(id: id)) { tile }
                } else {
                    NavigationLink(value: key) { tile }
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { onPick?(key) })
            .accessibilityLabel([DateKey.label(key, "EEEE, MMMM d"),
                                 day?.lift.map { $0 == .done ? "Lifted" : "Missed lift" },
                                 day?.run.map { $0 == .done ? "Ran" : "Missed run" },
                                 resting ? "Rest" : nil].compactMap { $0 }.joined(separator: ", "))
        } else {
            tile.accessibilityHidden(true)
        }
    }

    /// Rest days: gray with a sleeping moon, kept clear of the run blue.
    static let restFill = Page.fill
    static let restInk = Page.secondary

    /// Adds a row when `through` (the Sunday ending a Monday–Sunday week) falls past the grid's last row.
    static func weeks(of month: Date, through: String?) -> [[String]] {
        var out = weeks(of: month)
        if let through, let last = out.last?.last, through > last {
            out.append((1...7).map { DateKey.addDays(last, $0) })
        }
        return out
    }

    /// The month's days as Sunday-first weeks, padded with the neighboring months' days.
    static func weeks(of month: Date) -> [[String]] {
        let cal = DateKey.calendar
        let last = DateKey.key(cal.date(byAdding: DateComponents(month: 1, day: -1), to: month) ?? month)
        // Calendar weekday: 1 = Sunday, so step back to the Sunday on or before the 1st.
        var start = DateKey.addDays(DateKey.key(month), 1 - cal.component(.weekday, from: month))
        var out: [[String]] = []
        while start <= last {
            out.append((0..<7).map { DateKey.addDays(start, $0) })
            start = DateKey.addDays(start, 7)
        }
        return out
    }
}

/// Calendar colors for each kind of training.
enum DayColor {
    static let lift = Color(light: 0x2DA44E, dark: 0x3FB950)
    static let run = Color(light: 0x0969DA, dark: 0x58A6FF)
}

/// The calendar's key: lift, run, rest.
private struct CalendarKey: View {
    var body: some View {
        HStack(spacing: 10) {
            swatch(DayColor.lift, "Lift")
            swatch(DayColor.run, "Run")
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(TrackRecord.restInk)
                Text("Rest")
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
