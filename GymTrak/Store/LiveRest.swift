import ActivityKit
import Foundation

/// Keeps one rest Live Activity in step with the rest timer: starts it when rest starts,
/// updates it when time is added or the next set changes, ends it when rest stops.
@MainActor
enum LiveRest {
    private static var current: Activity<RestActivityAttributes>? {
        Activity<RestActivityAttributes>.activities.first
    }

    static func sync(startedAt: Date?, endsAt: Date?, workout: String?, next: WatchState.Current?) {
        guard let startedAt, let endsAt, endsAt > Date() else {
            end()
            return
        }
        let state = RestActivityAttributes.ContentState(
            startedAt: startedAt, endsAt: endsAt,
            nextExercise: next?.exercise,
            nextLoad: next.map { n in n.weight.isEmpty ? "× \(n.reps)" : "\(n.weight) × \(n.reps)" })
        // Drop it from the lock screen a minute after rest is over.
        let content = ActivityContent(state: state, staleDate: endsAt.addingTimeInterval(60))

        if let activity = current {
            guard activity.content.state != state else { return }
            // Look the activity up off the main actor so nothing non-Sendable crosses over.
            Task.detached {
                for a in Activity<RestActivityAttributes>.activities { await a.update(content) }
            }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: RestActivityAttributes(workout: workout ?? "Workout"),
                                      content: content, pushType: nil)
        }
    }

    static func end() {
        guard current != nil else { return }
        Task.detached {
            for a in Activity<RestActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
