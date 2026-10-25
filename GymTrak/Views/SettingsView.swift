import SwiftUI

/// Edit code, sync, rest timer, program dates, data backup, and app info.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(RestTimer.self) private var rest
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var startMonday = Date()
    @State private var confirmReanchor = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("Logo").resizable().frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GymTrak").font(.title2.bold())
                            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                accessSection
                syncSection
                Section("Rest timer") {
                    Stepper(value: Binding(get: { rest.defaultSec }, set: { rest.setDefault($0) }),
                            in: RestTimer.minSec...RestTimer.maxSec, step: 15) {
                        Label { LabeledContent("Default Rest", value: fmtClock(Double(rest.defaultSec))) } icon: { IconBadge(systemName: "timer", color: .orange) }
                    }
                }
                programSection
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
        Section {
            if store.canEdit {
                Label { Text("Editing On") } icon: { IconBadge(systemName: "lock.open.fill", color: Theme.lift) }
                Button("Lock", role: .destructive) { store.lock() }
            } else {
                SecureField("Edit code", text: $code).keyboardType(.numberPad)
                Button("Unlock") {
                    store.unlock(code: code)
                    code = ""
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Access")
        } footer: {
            if !store.canEdit { Text("Needed to make changes.") }
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
