import SwiftUI
import Charts

/// One exercise's last sessions: a top-set trend line, then each session's sets, newest first.
struct ExerciseHistoryView: View {
    let ex: Exercise
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Oldest first, so the chart reads left to right.
    private var history: [LiftPerformance] {
        Array(store.db.liftHistory(for: ex, before: "9999-12-31", limit: 12).reversed())
    }

    var body: some View {
        let history = self.history
        let points = ExerciseHistory.points(history)
        Group {
            if history.isEmpty {
                ContentUnavailableView("No history yet.", systemImage: "chart.line.uptrend.xyaxis")
            } else {
                List {
                    if !points.isEmpty {
                        Section {
                            Chart(points) { p in
                                LineMark(x: .value("Date", p.date), y: .value("Load", p.load))
                                    .foregroundStyle(Theme.lift)
                                PointMark(x: .value("Date", p.date), y: .value("Load", p.load))
                                    .foregroundStyle(Theme.lift)
                            }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .frame(height: 180)
                            .padding(.vertical, 8)
                        }
                    }
                    Section {
                        ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, p in
                            row(p)
                        }
                    }
                }
            }
        }
        .navigationTitle(ex.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func row(_ p: LiftPerformance) -> some View {
        HStack {
            Text(DateKey.date(p.date).formatted(.dateTime.month(.abbreviated).day()))
            if p.deload { Text("Deload").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text(summary(p)).font(.number(17)).foregroundStyle(.secondary)
        }
    }

    /// "135 lb × 8, 8, 7"
    private func summary(_ p: LiftPerformance) -> String {
        let weight = p.sets.first?.weight ?? ""
        let reps = p.sets.map { String($0.reps) }.joined(separator: ", ")
        return weight.isEmpty ? "× \(reps)" : "\(weight) × \(reps)"
    }
}

/// One session's top set, plotted by date.
struct HistoryPoint: Identifiable, Equatable {
    let id: String
    let date: Date
    let load: Double
}

enum ExerciseHistory {
    /// Top-set loads for the chart. Input is oldest first. Pin-machine maxes (no number) are skipped.
    static func points(_ history: [LiftPerformance]) -> [HistoryPoint] {
        history.enumerated().compactMap { i, p in
            guard let top = p.sets.first, let s = top.score, s < 10_000 else { return nil }
            return HistoryPoint(id: "\(i)", date: DateKey.date(p.date), load: s)
        }
    }
}
