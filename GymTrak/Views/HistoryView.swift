import SwiftUI

/// Every finished workout and run, with lifetime totals and a few fun facts on top.
struct HistoryView: View {
    @Environment(Store.self) private var store
    @Environment(Connections.self) private var connections

    var body: some View {
        let db = store.db
        let entries = db.historyEntries(synced: connections.runs)
        let stats = db.lifetimeStats(synced: connections.runs)
        let facts = historyFacts(stats)

        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView("No workouts yet.", systemImage: "clock.arrow.circlepath")
                        .listRowBackground(Color.clear)
                } else {
                    Section { totals(stats) }
                    if !facts.isEmpty {
                        Section("Facts") {
                            ForEach(facts, id: \.self) { fact in
                                Label { Text(fact) } icon: { Image(systemName: "sparkle").foregroundStyle(Theme.lift) }
                            }
                        }
                    }
                    ForEach(months(entries), id: \.title) { month in
                        Section(month.title) {
                            ForEach(month.entries) { row($0) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("History")
            .navigationDestination(for: String.self) { SessionDetailView(sessionId: $0) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .refreshable { await connections.refresh() }
        }
    }

    // MARK: Totals

    private func totals(_ s: LifetimeStats) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 14) {
            GridRow {
                stat("\(s.workouts)", "Workouts", "dumbbell.fill", Theme.lift)
                stat(s.pounds > 0 ? fmtPounds(s.pounds) : "—", "Moved", "scalemass.fill", Theme.lift)
            }
            GridRow {
                stat("\(s.runs)", "Runs", "figure.run", Theme.run)
                stat(s.runMiles > 0 ? String(format: "%.1f mi", s.runMiles) : "—", "Distance", "map.fill", Theme.run)
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemName: icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.number(20)).lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ e: HistoryEntry) -> some View {
        switch e.kind {
        case .lift(let id):
            NavigationLink(value: id) { rowLabel(e, icon: "dumbbell.fill", color: Theme.lift) }
        case .run:
            rowLabel(e, icon: "figure.run", color: Theme.run)
        }
    }

    private func rowLabel(_ e: HistoryEntry, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title)
                Text(e.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(DateKey.label(e.date, "MMM d")).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
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

/// One finished workout: every exercise and the sets you did, with PRs marked.
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

            List {
                Section {
                    LabeledContent("Sets", value: "\(done.count)")
                    if lb > 0 { LabeledContent("Moved", value: fmtPounds(lb)) }
                    if let d = session.durationSec, d >= 60 { LabeledContent("Time", value: "\(Int((d / 60).rounded())) min") }
                }
                ForEach(order, id: \.self) { name in
                    Section {
                        ForEach(groups[name, default: []].sorted { $0.setIndex < $1.setIndex }) { st in
                            HStack {
                                Text("Set \(st.setIndex + 1)").foregroundStyle(.secondary)
                                Spacer()
                                Text([st.weight, st.reps].filter { !$0.isEmpty }.joined(separator: " "))
                                    .font(.number(17)).monospacedDigit()
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(name)
                            if prNames.contains(name) {
                                Image(systemName: "trophy.fill").foregroundStyle(Theme.lift).accessibilityLabel("PR")
                            }
                        }
                    }
                }
                if done.isEmpty {
                    Text("Nothing logged.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(session.dayNameSnapshot ?? db.day(session.dayId)?.name ?? "Workout")
            .navigationSubtitle(DateKey.label(session.slotDate, "EEEE, MMM d"))
        } else {
            ContentUnavailableView("Workout not found", systemImage: "questionmark")
        }
    }
}
