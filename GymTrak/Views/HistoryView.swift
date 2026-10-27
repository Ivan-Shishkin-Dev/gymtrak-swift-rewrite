import SwiftUI

/// One Monday–Sunday week of workouts and runs, with that week's totals on top. Arrows step back through older weeks.
struct HistoryView: View {
    @Environment(Store.self) private var store
    @Environment(Connections.self) private var connections
    @State private var weekOffset = 0

    var body: some View {
        let db = store.db
        let all = db.historyEntries(synced: connections.runs)
        let thisMonday = DateKey.mondayKey(Date())
        let monday = DateKey.addDays(thisMonday, 7 * weekOffset)
        let sunday = DateKey.addDays(monday, 6)
        let entries = all.filter { $0.date >= monday && $0.date <= sunday }
        let earliest = all.last.map { DateKey.mondayKey(DateKey.date($0.date)) } ?? thisMonday
        let s = db.weekStats(monday: monday, synced: connections.runs)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        weekPicker(monday: monday, sunday: sunday, canGoBack: monday > earliest)
                        // The month with this week lit up; tap any day to jump to its week.
                        TrackRecord(days: db.activityRecord(today: Date(), runDates: connections.runDates),
                                    isRest: db.isRestDay, focus: monday...sunday) { key in
                            let picked = DateKey.mondayKey(DateKey.date(key))
                            guard picked >= earliest, picked <= thisMonday else { return }
                            let days = DateKey.calendar.dateComponents([.day], from: DateKey.date(thisMonday), to: DateKey.date(picked)).day ?? 0
                            weekOffset = Int((Double(days) / 7).rounded())
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            PropertyRow(icon: "dumbbell", label: "Workouts") { Text("\(s.workouts)") }
                            PropertyRow(icon: "figure.run", label: "Runs") { Text("\(s.runs)") }
                            PropertyRow(icon: "location", label: "Miles") { Text(s.runMiles > 0 ? String(format: "%.1f mi", s.runMiles) : "—") }
                            PropertyRow(icon: "clock", label: "Avg workout") { Text(s.avgWorkoutMinutes.map { "\(Int($0.rounded())) min" } ?? "—") }
                        }
                    }
                    PageSection("Activity") {
                        if entries.isEmpty {
                            Text("Nothing this week.").foregroundStyle(Page.secondary).padding(.vertical, 8)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(entries) { e in
                                    HistoryRow(entry: e)
                                    if e.id != entries.last?.id { Rectangle().fill(Page.divider).frame(height: 1) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 110)
            }
            .background(Page.bg)
            .topLeftTitle("History")
            .navigationDestination(for: SessionRef.self) { SessionDetailView(sessionId: $0.id) }
            .refreshable { await connections.refresh() }
        }
    }

    /// "This week", "Last week", or the dates, with arrows that only show when there's a week to go to.
    private func weekPicker(monday: String, sunday: String, canGoBack: Bool) -> some View {
        HStack {
            Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .disabled(!canGoBack).opacity(canGoBack ? 1 : 0)
            Spacer()
            VStack(spacing: 1) {
                Text(weekOffset == 0 ? "This week" : weekOffset == -1 ? "Last week" : DateKey.label(monday, "MMMM d"))
                    .font(.headline).foregroundStyle(Page.text)
                Text("\(DateKey.label(monday, "MMM d")) – \(DateKey.label(sunday, "MMM d"))")
                    .font(.caption).foregroundStyle(Page.secondary)
            }
            Spacer()
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(weekOffset >= 0).opacity(weekOffset >= 0 ? 0 : 1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Page.secondary)
        .buttonStyle(.plain)
    }
}

/// One finished workout as a page: totals, then every exercise's sets, PRs marked.
struct SessionDetailView: View {
    let sessionId: String
    @Environment(Store.self) private var store

    var body: some View {
        let db = store.db
        if let session = db.sessions.first(where: { $0.id == sessionId }) {
            let done = db.sets(of: sessionId).filter(\.isDone)
            let prNames = Set(db.prs(sessionId: sessionId).map(\.0.name))
            let groups = Dictionary(grouping: done, by: \.exerciseName)
            let order = done.sorted { ($0.completedAt ?? 0, $0.setIndex) < ($1.completedAt ?? 0, $1.setIndex) }
                .map(\.exerciseName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let title = session.dayNameSnapshot ?? db.day(session.dayId)?.name ?? "Workout"

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(Page.text).padding(.bottom, 10)
                        PropertyRow(icon: "calendar", label: "Date") { Text(DateKey.label(session.slotDate, "EEEE, MMMM d")) }
                        let total = db.sets.filter { $0.sessionId == sessionId }.count
                        let o = db.outcome(sessionId)
                        PropertyRow(icon: "checkmark.circle", label: "Status") { Tag(text: o.label, tint: o.color) }
                        PropertyRow(icon: "number", label: "Sets") { Text(done.count == total ? "\(done.count)" : "\(done.count) of \(total)") }
                        if let d = session.durationSec, d >= 60, d < 4 * 3600 {
                            PropertyRow(icon: "clock", label: "Time") { Text("\(Int((d / 60).rounded())) min") }
                        }
                        if !prNames.isEmpty {
                            PropertyRow(icon: "trophy", label: "PRs") { Text(prNames.sorted().joined(separator: ", ")) }
                        }
                    }
                    if done.isEmpty { Text("Nothing logged.").foregroundStyle(Page.secondary) }
                    ForEach(order, id: \.self) { name in
                        PageSection(name, trailing: { if prNames.contains(name) { Image(systemName: "trophy") } }) {
                            VStack(spacing: 0) {
                                ForEach(groups[name, default: []].sorted { $0.setIndex < $1.setIndex }) { st in
                                    HStack {
                                        Text("Set \(st.setIndex + 1)").foregroundStyle(Page.secondary)
                                        Spacer()
                                        Text([st.weight, st.reps].filter { !$0.isEmpty }.joined(separator: " "))
                                            .monospacedDigit().foregroundStyle(Page.text)
                                    }
                                    .padding(.vertical, 6)
                                }
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
        } else {
            ContentUnavailableView("Workout not found", systemImage: "questionmark")
        }
    }
}
