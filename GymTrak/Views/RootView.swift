import SwiftUI

/// Screen-level navigation state shared across tabs.
@MainActor
@Observable
final class AppNav {
    var showWorkout = false
    var showSettings = false
    /// Set right after finishing; opens the finish summary sheet.
    var completed: (sessionId: String, label: String)?
    /// "Undo finish" on the summary: reopen the workout once the sheet is gone.
    var reopenAfterSummary = false
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest
    @Environment(Connections.self) private var connections
    @Environment(\.scenePhase) private var scenePhase
    @State private var nav = AppNav()
    @State private var loading = true
    @State private var showSummary = false

    var body: some View {
        ZStack {
            if store.canEdit || store.supabase == nil || !Store.accountsEnabled {
                tabs
            } else if !loading {
                SignInView().transition(.opacity)
            }
            if loading {
                LoadingView().transition(.opacity.combined(with: .scale(scale: 1.05)))
            }
        }
        .task {
            // Show at least one rep, then wait for the first sync — but never more than 5 s.
            let sync = Task { await store.sync() }
            try? await Task.sleep(for: .seconds(1.3))
            var waited = 1.3
            while store.syncStatus == .syncing && waited < 5 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 0.1
            }
            // Launch with -holdLoading to keep the splash up (for tweaking it).
            if ProcessInfo.processInfo.arguments.contains("-holdLoading") { return }
            withAnimation(.easeInOut(duration: 0.4)) { loading = false }
            await sync.value
            await connections.refresh()
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Today", systemImage: "house.fill") {
                TodayView().safeAreaInset(edge: .bottom) { dock }
            }
            Tab("Plan", systemImage: "list.bullet.rectangle") {
                PlanView().safeAreaInset(edge: .bottom) { dock }
            }
        }
        .tint(Theme.lift)
        .environment(nav)
        .preferredColorScheme(Appearance.shared.matteBackground ? .dark : nil)
        .fullScreenCover(isPresented: $nav.showWorkout) {
            WorkoutView().environment(nav).tint(Theme.lift)
        }
        .sheet(isPresented: $nav.showSettings) {
            SettingsView().tint(Theme.lift)
        }
        .sheet(isPresented: $showSummary, onDismiss: {
            nav.completed = nil
            if nav.reopenAfterSummary { nav.reopenAfterSummary = false; nav.showWorkout = true }
        }) {
            if let id = nav.completed?.sessionId {
                WorkoutSummaryView(sessionId: id).environment(nav)
                    .presentationDetents([.medium, .large])
                    .tint(Theme.lift)
            }
        }
        .onChange(of: nav.completed?.sessionId) { _, id in
            guard id != nil else { return }
            // Wait for the workout cover to finish dismissing; SwiftUI drops a sheet presented mid-dismiss.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                showSummary = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.sync(); await connections.refresh() } }
        }
    }

    /// One bar above the tab bar while a workout is open: progress, rest, Resume.
    @ViewBuilder private var dock: some View {
        if let open = store.db.openLift() {
            ResumeBanner(session: open) { nav.showWorkout = true }
        }
    }
}

struct ResumeBanner: View {
    let session: Session
    let onResume: () -> Void
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest

    var body: some View {
        let sets = store.db.sets(of: session.id)
        let done = sets.filter(\.isDone).count
        Button(action: onResume) {
            HStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title3).foregroundStyle(Theme.lift)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.db.day(session.dayId)?.name ?? session.dayNameSnapshot ?? "Workout").font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = rest.remaining(at: ctx.date)
                        HStack(spacing: 6) {
                            Text("\(done)/\(sets.count) sets")
                            if rest.isActive {
                                Text("·")
                                Text(left >= 0 ? "Rest \(fmtClock(left))" : "Rest over")
                                    .foregroundStyle(left >= 0 ? Theme.lift : Theme.warning)
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Resume")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.lift, in: Capsule())
                    .foregroundStyle(Theme.onLift)
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .top) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

