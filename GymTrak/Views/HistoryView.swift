import SwiftUI

/// Every finished workout and run, with lifetime totals on top.
struct HistoryView: View {
    @Environment(Store.self) private var store
    @Environment(Connections.self) private var connections

    var body: some View {
        let db = store.db
        let entries = db.historyEntries(synced: connections.runs)
        let s = db.lifetimeStats(synced: connections.runs)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if entries.isEmpty {
                        Text("No workouts yet.").foregroundStyle(Page.secondary).padding(.top, 20)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            PropertyRow(icon: "dumbbell", label: "Workouts") { Text("\(s.workouts)") }
                            PropertyRow(icon: "scalemass", label: "Moved") { Text(s.pounds > 0 ? fmtPounds(s.pounds) : "—") }
                            PropertyRow(icon: "figure.run", label: "Runs") { Text("\(s.runs)") }
                            PropertyRow(icon: "location", label: "Distance") { Text(s.runMiles > 0 ? String(format: "%.1f mi", s.runMiles) : "—") }
                            if let avg = s.avgWorkoutMinutes {
                                PropertyRow(icon: "clock", label: "Avg workout") { Text("\(Int(avg.rounded())) min") }
                            }
                            if let h = s.heaviest {
                                PropertyRow(icon: "trophy", label: "Heaviest") { Text("\(h.name), \(fmtNum(h.lb)) lb") }
                            }
                        }
                        ForEach(months(entries), id: \.title) { month in
                            PageSection(month.title, trailing: { Text("\(month.entries.count)") }) {
                                VStack(spacing: 0) {
                                    ForEach(month.entries) { e in
                                        HistoryRow(entry: e)
                                        if e.id != month.entries.last?.id { Rectangle().fill(Page.divider).frame(height: 1) }
                                    }
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .navigationDestination(for: SessionRef.self) { SessionDetailView(sessionId: $0.id) }
            .refreshable { await connections.refresh() }
        }
    }

    private struct Month { let title: String; let entries: [HistoryEntry] }

    /// Group newest-first entries by month: "October 2026".
    private func months(_ entries: [HistoryEntry]) -> [Month] {
        var out: [Month] = []
        for e in entries {
            let title = DateKey.label(e.date, "MMMM yyyy")
            if out.last?.title == title {
                out[out.count - 1] = Month(title: title, entries: out[out.count - 1].entries + [e])
            } else {
                out.append(Month(title: title, entries: [e]))
            }
        }
        return out
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
            let lb = db.sessionPounds(sessionId)
            let title = session.dayNameSnapshot ?? db.day(session.dayId)?.name ?? "Workout"

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(Page.text).padding(.bottom, 10)
                        PropertyRow(icon: "calendar", label: "Date") { Text(DateKey.label(session.slotDate, "EEEE, MMMM d")) }
                        PropertyRow(icon: "number", label: "Sets") { Text("\(done.count)") }
                        if lb > 0 { PropertyRow(icon: "scalemass", label: "Moved") { Text(fmtPounds(lb)) } }
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
