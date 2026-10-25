import SwiftUI
import AuthenticationServices

/// Account, connections, sync, rest timer, program dates, data backup, and app info.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest
    @Environment(Connections.self) private var connections
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false
    @State private var startMonday = Date()
    @State private var confirmReanchor = false
    @State private var confirmReset = false
    @State private var coachTick = 0
    @AppStorage(RestTimer.autoKey) private var restAuto = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        LogoView(size: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GymTrak").font(.title2.bold())
                            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if Store.accountsEnabled { accessSection }
                AppearanceSection()
                connectionsSection
                if Store.accountsEnabled { syncSection }
                Section {
                    Toggle(isOn: Binding(get: { Coach.autoApply }, set: { Coach.autoApply = $0; coachTick += 1 })) {
                        Label { Text("Auto-Set Weights") } icon: { IconBadge(systemName: "scope", color: Theme.lift) }
                    }
                    .id(coachTick)
                } header: { Text("Coach") } footer: { Text("Fills each workout with the coach's targets.") }
                Section("Rest timer") {
                    Stepper(value: Binding(get: { rest.defaultSec }, set: { rest.setDefault($0) }),
                            in: RestTimer.minSec...RestTimer.maxSec, step: 15) {
                        Label { LabeledContent("Default Rest", value: fmtClock(Double(rest.defaultSec))) } icon: { IconBadge(systemName: "timer", color: .orange) }
                    }
                    Toggle(isOn: $restAuto) {
                        Label { Text("Auto-Start") } icon: { IconBadge(systemName: "play.fill", color: Theme.lift) }
                    }
                }
                dataSection
                Section("About") {
                                        LabeledContent("Lift days", value: "\(store.db.activeDays.count)")
                    LabeledContent("Workouts", value: "\(store.db.sessions.filter { $0.finishedAt != nil && !$0.isDeleted }.count)")
                    Link("GitHub", destination: URL(string: "https://github.com/Ivan-Shishkin-Dev/gymtrak-swift-rewrite")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if let first = store.db.weeks.first { startMonday = DateKey.date(first.startDate) }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var accessSection: some View {
        Section("Account") {
            if let email = store.email {
                Label { Text(email) } icon: { IconBadge(systemName: "person.fill", color: Theme.lift) }
                Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) { Task { await store.signOut(); dismiss() } }
                    } message: { Text("Your data stays in your account.") }
            } else {
                Label { Text("Demo mode") } icon: { IconBadge(systemName: "person.fill", color: .gray) }
            }
        }
    }

    @ViewBuilder private var connectionsSection: some View {
        Section {
            HStack {
                Label { Text("Strava") } icon: { IconBadge(systemName: "figure.run", color: .orange) }
                Spacer()
                if connections.stravaConnected {
                    Text(connections.stravaAthlete ?? "Connected").foregroundStyle(.secondary)
                } else {
                    Button("Connect") { Task { await connectStrava() } }
                        .disabled(!connections.stravaConfigured)
                }
            }
            .swipeActions { if connections.stravaConnected { Button("Disconnect", role: .destructive) { connections.disconnectStrava() } } }
            HStack {
                Label { Text("Apple Health") } icon: { IconBadge(systemName: "heart.fill", color: .pink) }
                Spacer()
                if connections.healthConnected {
                    Text("Connected").foregroundStyle(.secondary)
                } else if connections.healthAvailable {
                    Button("Connect") { Task { await connections.connectHealth() } }
                } else {
                    Text("Needs paid account").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .swipeActions { if connections.healthConnected { Button("Disconnect", role: .destructive) { connections.disconnectHealth() } } }
            if connections.stravaConnected || connections.healthConnected {
                Button { Task { await connections.refresh() } } label: {
                    HStack {
                        Text("Refresh Runs")
                        Spacer()
                        if connections.refreshing { ProgressView() } else { Text("\(connections.runs.count)").foregroundStyle(.secondary) }
                    }
                }
            }
            if let error = connections.lastError {
                Text(error).font(.footnote).foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Connections")
        } footer: {
            if !connections.stravaConfigured { Text("Add your Strava API keys to Secrets.xcconfig to connect.") }
        }
    }

    private func connectStrava() async {
        guard let url = connections.stravaAuthURL else { return }
        do {
            let callback = try await webAuth.authenticate(using: url, callbackURLScheme: Connections.stravaCallbackScheme)
            await connections.finishStrava(callback: callback)
        } catch {
            // Cancelled by the user: nothing to do.
        }
    }

    @ViewBuilder private var syncSection: some View {
        Section("Sync") {
            LabeledContent("Status") {
                switch store.syncStatus {
                case .offline: Text("Offline")
                case .idle: Text("Idle")
                case .syncing: ProgressView()
                case .synced: Text("Synced").foregroundStyle(Theme.lift)
                case .error: Text("Error").foregroundStyle(Theme.warning)
                }
            }
            if case .error(let message) = store.syncStatus {
                Text(message).font(.footnote).foregroundStyle(Theme.warning)
            }
            if let last = store.lastSyncedAt {
                LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .shortened))
            }
            Button { Task { await store.sync() } } label: {
                Label { Text("Sync Now") } icon: { IconBadge(systemName: "arrow.triangle.2.circlepath", color: Theme.run) }
            }
            Button("Reset from Cloud", role: .destructive) { confirmReset = true }
                .confirmationDialog("Use the cloud copy?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Replace local data", role: .destructive) { Task { await store.forcePull() } }
                } message: { Text("Unsynced changes are lost.") }
        }
    }

    @ViewBuilder private var programSection: some View {
        Section {
            if store.db.weeks.isEmpty {
                Text("No program installed.").foregroundStyle(.secondary)
            } else {
                DatePicker(selection: $startMonday, displayedComponents: .date) {
                    Label { Text("Week 1 Starts") } icon: { IconBadge(systemName: "calendar", color: .red) }
                }
                Button("Move Program") { confirmReanchor = true }
                    .disabled(!store.canEdit)
                    .confirmationDialog("Re-anchor the program?", isPresented: $confirmReanchor, titleVisibility: .visible) {
                        Button("Move it") {
                            store.mutate { $0.setProgramStart(DateKey.mondayKey(startMonday)) }
                        }
                    } message: {
                        Text("Week 1 starts \(DateKey.label(DateKey.mondayKey(startMonday), "MMM d")).")
                    }
            }
        } header: {
            Text("Program")
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section {
            if let url = exportURL() {
                ShareLink(item: url) { Label { Text("Export Backup") } icon: { IconBadge(systemName: "square.and.arrow.up", color: .indigo) } }
            }
        } header: {
            Text("Data")
        }
    }

    private func exportURL() -> URL? {
        let url = URL.temporaryDirectory.appending(path: "gymtrak-backup-\(DateKey.key(Date())).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store.db), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

/// Accent swatches, a custom color picker, and the matte black background switch.
private struct AppearanceSection: View {
    @State private var look = Appearance.shared
    @State private var custom: Color = Appearance.shared.accent

    var body: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(Appearance.presets) { p in
                    swatch(Color(hex: p.hex), name: p.name, selected: look.accentID == p.id, matte: p.id == "matte") {
                        look.accentID = p.id
                    }
                }
            }
            .padding(.vertical, 6)
            ColorPicker(selection: Binding(get: { custom }, set: { custom = $0; look.setCustom($0) }), supportsOpacity: false) {
                Label { Text("Custom Color") } icon: {
                    IconBadge(systemName: "paintpalette.fill", color: look.accentID == "custom" ? look.accent : .gray)
                }
            }
            Toggle(isOn: $look.matteBackground) {
                Label { Text("Matte Black Background") } icon: { IconBadge(systemName: "moon.fill", color: Color(hex: 0x3A3A3C)) }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(look.matteBackground ? "Always dark." : "Follows your phone's light or dark mode.")
        }
    }

    private func swatch(_ color: Color, name: String, selected: Bool, matte: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(matte ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3A3A3C), .black], startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(color.gradient))
                        .overlay(Circle().strokeBorder(matte ? color.opacity(0.5) : .clear, lineWidth: 1.5))
                        .frame(width: 40, height: 40)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(matte ? .white : (color.isLight ? .black : .white))
                    }
                }
                .overlay(Circle().stroke(selected ? Color.primary.opacity(0.6) : .clear, lineWidth: 2).padding(-4))
                Text(name).font(.caption2).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.selection, trigger: selected)
    }
}
