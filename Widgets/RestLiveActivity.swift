import ActivityKit
import SwiftUI
import WidgetKit

/// Rest countdown on the lock screen and in the Dynamic Island.
struct RestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            LockScreenRest(context: context)
                .activityBackgroundTint(Color(white: 0.08))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(s).font(.title2.weight(.semibold)).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        NextSet(state: s)
                        bar(s)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.white)
            } compactTrailing: {
                countdown(s).frame(width: 46).font(.subheadline.weight(.semibold))
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.white)
            }
            .keylineTint(.white)
        }
    }
}

private struct LockScreenRest: View {
    let context: ActivityViewContext<RestActivityAttributes>

    var body: some View {
        let s = context.state
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rest").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    countdown(s).font(.system(size: 44, weight: .semibold, design: .rounded))
                }
                Spacer()
                NextSet(state: s, trailing: true)
            }
            bar(s)
        }
        .padding(16)
    }
}

/// "Up next" with the exercise and load.
private struct NextSet: View {
    let state: RestActivityAttributes.ContentState
    var trailing = false

    var body: some View {
        if let name = state.nextExercise {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
                Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                Text(name).font(.headline).foregroundStyle(.white).lineLimit(1)
                if let load = state.nextLoad {
                    Text(load).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}

/// Counts down to zero and stops there.
private func countdown(_ s: RestActivityAttributes.ContentState) -> some View {
    Text(timerInterval: s.startedAt...max(s.startedAt, s.endsAt), countsDown: true)
        .monospacedDigit()
        .foregroundStyle(.white)
        .multilineTextAlignment(.trailing)
}

private func bar(_ s: RestActivityAttributes.ContentState) -> some View {
    ProgressView(timerInterval: s.startedAt...max(s.startedAt, s.endsAt), countsDown: true) {
        EmptyView()
    } currentValueLabel: {
        EmptyView()
    }
    .tint(.white)
}

#Preview("Rest", as: .content, using: RestActivityAttributes(workout: "Upper A")) {
    RestLiveActivity()
} contentStates: {
    RestActivityAttributes.ContentState(startedAt: .now, endsAt: .now.addingTimeInterval(90),
                                        nextExercise: "Pec Dec", nextLoad: "215 lb × 6")
}
