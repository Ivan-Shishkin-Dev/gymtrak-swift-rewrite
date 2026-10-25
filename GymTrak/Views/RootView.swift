import SwiftUI

/// Screen-level navigation state shared across tabs.
@MainActor
@Observable
final class AppNav {
    var showWorkout = false
    var showSettings = false
    /// Set right after finishing, for the "Saved · Undo" toast.
    var completed: (sessionId: String, label: String)?
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest
    @Environment(\.scenePhase) private var scenePhase
    @State private var nav = AppNav()

    var body: some View {
        TabView {
            Tab("Today", systemImage: "house.fill") {
                TodayView().safeAreaInset(edge: .bottom) { dock }
            }
            Tab("Plan", systemImage: "list.bullet.rectangle") {
                PlanView().safeAreaInset(edge: .bottom) { dock }
            }
        }
        .tint(Theme.volt)
        .environment(nav)
        .fullScreenCover(isPresented: $nav.showWorkout) {
            WorkoutView().environment(nav)
        }
        .sheet(isPresented: $nav.showSettings) {
            SettingsView()
        }
        .overlay(alignment: .top) { CompletionToast().environment(nav) }
        .task { await store.sync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.sync() } }
        }
        .onAppear {
            if !store.canEdit && store.db.days.isEmpty { nav.showSettings = true }
        }
    }

    /// Resume banner + rest timer, docked above the tab bar.
    @ViewBuilder private var dock: some View {
        VStack(spacing: 0) {
            if let open = store.db.openLift() {
                ResumeBanner(session: open) { nav.showWorkout = true }
            }
            if rest.isActive { RestBar() }
        }
    }
}

struct ResumeBanner: View {
    let session: Session
    let onResume: () -> Void
    @Environment(Store.self) private var store

    var body: some View {
        let sets = store.db.sets(of: session.id)
        let done = sets.filter(\.isDone).count
        Button(action: onResume) {
            HStack(spacing: 12) {
                Circle().fill(Theme.volt).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.db.day(session.dayId)?.name ?? session.dayNameSnapshot ?? "Workout") in progress")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("\(done) of \(sets.count) sets").font(.system(size: 12)).foregroundStyle(Theme.sub)
                }
                Spacer()
                Text("Resume").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.volt)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.volt)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(Theme.cardBorder).frame(height: 1) }
        }
        .buttonStyle(.plain)
    }
}

struct CompletionToast: View {
    @Environment(AppNav.self) private var nav
    @Environment(Store.self) private var store

    var body: some View {
        if let done = nav.completed {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.volt)
                Text("\(done.label) saved").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Undo") {
                    store.mutate { $0.reopenSession(done.sessionId) }
                    nav.completed = nil
                    nav.showWorkout = true
                }
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.volt)
            }
            .padding(.horizontal, 16).frame(height: 50)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.pillBorder))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: done.sessionId) {
                try? await Task.sleep(for: .seconds(6))
                withAnimation { nav.completed = nil }
            }
        }
    }
}
