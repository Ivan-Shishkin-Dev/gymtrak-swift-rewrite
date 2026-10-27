import SwiftUI

/// Shown after finishing a workout: what you hit, and what to aim for next time.
struct WorkoutSummaryView: View {
    let sessionId: String
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNav.self) private var nav

    var body: some View {
        let db = store.db
        if let session = db.sessions.first(where: { $0.id == sessionId }) {
            let done = db.sets(of: sessionId).filter(\.isDone)
            let prs = db.prs(sessionId: sessionId)
            let exercises = db.exercises(of: session.dayId)
                .filter { ex in done.contains { $0.exerciseId == ex.id } }
            let title = db.day(session.dayId)?.name ?? session.dayNameSnapshot ?? "Workout"
            let subtitle = [session.durationSec.map { fmtClock($0) }, "\(done.count) sets"]
                .compactMap { $0 }.joined(separator: " · ")

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.largeTitle.bold())
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }

                    if done.isEmpty {
                        Text("Nothing logged.").foregroundStyle(.secondary)
                    }

                    if !prs.isEmpty {
                        section("PRs") {
                            ForEach(Array(prs.enumerated()), id: \.offset) { _, pr in
                                HStack {
                                    Text(pr.0.name)
                                    Image(systemName: "trophy.fill").foregroundStyle(Theme.lift)
                                    Spacer()
                                    Text([.weight, .dumbbell].contains(pr.0.effectiveLoadType)
                                         ? "\(fmtNum(pr.before)) → \(fmtNum(pr.now))"
                                         : "New best")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }

                    if !exercises.isEmpty {
                        section("Next time") {
                            ForEach(exercises) { ex in
                                let a = db.liftAdvice(for: ex)
                                VStack(alignment: .leading, spacing: 3) {
                                    Label {
                                        Text(a.target).font(.subheadline.weight(.semibold))
                                    } icon: {
                                        Image(systemName: a.icon).foregroundStyle(Theme.lift)
                                    }
                                    .labelStyle(CoachLabelStyle())
                                    Text(ex.name)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.lift, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Theme.onLift)
                    }
                    Button("Undo finish") {
                        store.mutate { $0.reopenSession(sessionId) }
                        nav.reopenAfterSummary = true
                        dismiss()
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
