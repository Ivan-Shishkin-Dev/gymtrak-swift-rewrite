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
        .tint(Theme.lift)
        .environment(nav)
        .fullScreenCover(isPresented: $nav.showWorkout) {
            WorkoutView().environment(nav).tint(Theme.lift)
        }
        .sheet(isPresented: $nav.showSettings) {
            SettingsView().tint(Theme.lift)
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
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title3).foregroundStyle(Theme.lift)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.db.day(session.dayId)?.name ?? session.dayNameSnapshot ?? "Workout").font(.headline)
                    Text("\(done)/\(sets.count) sets").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Resume").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.lift)
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
            .contentShape(Rectangle())
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.lift)
                Text("Saved").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Undo") {
                    store.mutate { $0.reopenSession(done.sessionId) }
                    nav.completed = nil
                    nav.showWorkout = true
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: done.sessionId) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation { nav.completed = nil }
            }
        }
    }
}
