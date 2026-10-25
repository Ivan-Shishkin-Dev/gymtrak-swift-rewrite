import SwiftUI
import AuthenticationServices
import UniformTypeIdentifiers

/// Appearance, connections, coach, rest timer, data backup, and app info.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest
    @Environment(Connections.self) private var connections
    @Environment(Spotify.self) private var spotify
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importError: String?
    @State private var coachTick = 0
    @AppStorage(RestTimer.autoKey) private var restAuto = true
    @AppStorage("gt_name") private var name = "Ivan"

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
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.givenName)
                } header: { Text("Your name") } footer: { Text("For the greeting on Today.") }
                AppearanceSection()
                connectionsSection
                Section {
                    Toggle(isOn: Binding(get: { Coach.autoApply }, set: { Coach.autoApply = $0; coachTick += 1 })) {
                        Label { Text("Auto-Set Weights") } icon: { IconBadge(systemName: "scope", color: Theme.lift) }
                    }
                    .id(coachTick)
                } header: { Text("Coach") } footer: { Text("Fills each workout with the coach's targets.") }
                NotificationsSection()
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
            .pageBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    // MARK: Sections

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
            HStack {
                Label { Text("Spotify") } icon: { IconBadge(systemName: "music.note", color: Theme.lift) }
                Spacer()
                if spotify.connected {
                    Text("Connected").foregroundStyle(.secondary)
                } else if spotify.configured {
                    Button("Connect") { Task { await spotify.connect { try await webAuth.authenticate(using: $0, callbackURLScheme: $1) } } }
                } else {
                    Text("Needs client ID").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .swipeActions { if spotify.connected { Button("Disconnect", role: .destructive) { spotify.disconnect() } } }
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

    @ViewBuilder private var dataSection: some View {
        Section {
            if let url = exportURL() {
                ShareLink(item: url) { Label { Text("Export Backup") } icon: { IconBadge(systemName: "square.and.arrow.up", color: .indigo) } }
            }
            Button { importing = true } label: {
                Label { Text("Import Backup") } icon: { IconBadge(systemName: "square.and.arrow.down", color: .indigo) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { try store.importBackup(from: result.get()); importError = nil }
                catch { importError = "Not a GymTrak backup." }
            }
            if let error = importError ?? store.saveError {
                Text(error).font(.footnote).foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Saved on this iPhone and in its iCloud Backup. Import replaces everything.")
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

/// Reminder switches and times. Any change re-plans the next week of notifications.
private struct NotificationsSection: View {
    @Environment(Store.self) private var store
    @Environment(Connections.self) private var connections
    typealias K = NotificationPrefs.Key
    private static let d = NotificationPrefs()

    @AppStorage(K.workout) private var workout = d.workout
    @AppStorage(K.workoutTime) private var workoutTime = d.workoutTime
    @AppStorage(K.missed) private var missed = d.missed
    @AppStorage(K.missedTime) private var missedTime = d.missedTime
    @AppStorage(K.recap) private var recap = d.recap
    @AppStorage(K.rest) private var rest = d.rest
    @State private var denied = false

    var body: some View {
        Section {
            if denied {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label { Text("Allow Notifications") } icon: { IconBadge(systemName: "bell.slash.fill", color: Theme.warning) }
                }
            }
            row("Workout Reminder", "dumbbell.fill", Theme.lift, isOn: $workout, time: $workoutTime)
            row("Not Logged Yet", "exclamationmark.circle.fill", .orange, isOn: $missed, time: $missedTime)
            Toggle(isOn: $recap) {
                Label { LabeledContent("Weekly Recap", value: "Sun 7 PM") } icon: { IconBadge(systemName: "chart.bar.fill", color: Theme.run) }
            }
            Toggle(isOn: $rest) {
                Label { Text("Rest Over") } icon: { IconBadge(systemName: "timer", color: .orange) }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Training days only. Skipped once you've logged it.")
        }
        .task { denied = await Notifier.isDenied() }
        .onChange(of: [workout, missed, recap, rest]) { _, new in apply(askIfNeeded: new.contains(true)) }
        .onChange(of: [workoutTime, missedTime]) { apply(askIfNeeded: false) }
    }

    @ViewBuilder
    private func row(_ title: String, _ icon: String, _ color: Color, isOn: Binding<Bool>, time: Binding<Int>) -> some View {
        Toggle(isOn: isOn) {
            Label { Text(title) } icon: { IconBadge(systemName: icon, color: color) }
        }
        if isOn.wrappedValue {
            DatePicker("Time", selection: Binding(
                get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(time.wrappedValue * 60)) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); time.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
            ), displayedComponents: .hourAndMinute)
            .padding(.leading, 46)
        }
    }

    private func apply(askIfNeeded: Bool) {
        let db = store.db, runs = connections.runs
        Task {
            if askIfNeeded { _ = await Notifier.requestPermission() }
            denied = await Notifier.isDenied()
            await Notifier.reschedule(db, runs: runs)
        }
    }
}
