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
                accessSection
                syncSection
                Section("Rest timer") {
                    Stepper(value: Binding(get: { rest.defaultSec }, set: { rest.setDefault($0) }),
                            in: RestTimer.minSec...RestTimer.maxSec, step: 15) {
                        LabeledContent("Default rest", value: fmtClock(Double(rest.defaultSec)))
                    }
                    Text("Exercises with their own rest time (set in a workout's Edit mode) use that instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                programSection
                dataSection
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    LabeledContent("Lift days", value: "\(store.db.activeDays.count)")
                    LabeledContent("Workouts logged", value: "\(store.db.sessions.filter { $0.finishedAt != nil && !$0.isDeleted }.count)")
                    Link("Source on GitHub", destination: URL(string: "https://github.com/Ivan-Shishkin-Dev/gymtrak-swift-rewrite")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if let first = store.db.weeks.first { startMonday = DateKey.date(first.startDate) }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    @ViewBuilder private var accessSection: some View {
        Section {
            if store.canEdit {
                Label("Editing unlocked on this device", systemImage: "lock.open.fill").foregroundStyle(Theme.volt)
                Button("Lock (view only)", role: .destructive) { store.lock() }
            } else {
                SecureField("Edit code", text: $code).keyboardType(.numberPad)
                Button("Unlock editing") {
                    store.unlock(code: code)
                    code = ""
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Access")
        } footer: {
            Text("Without the edit code the app is read-only. The code is checked by the server the next time it saves.")
        }
    }

    @ViewBuilder private var syncSection: some View {
        Section("Cloud sync") {
            LabeledContent("Status") {
                switch store.syncStatus {
                case .offline: Text("Offline")
                case .idle: Text("Idle")
                case .syncing: ProgressView()
                case .synced: Text("Up to date").foregroundStyle(Theme.volt)
                case .error: Text("Error").foregroundStyle(Theme.amber)
                }
            }
            if case .error(let message) = store.syncStatus {
                Text(message).font(.footnote).foregroundStyle(Theme.amber)
            }
            if let last = store.lastSyncedAt {
                LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .shortened))
            }
            Button("Sync now") { Task { await store.sync() } }
            Button("Replace this device's data with the cloud copy", role: .destructive) { confirmReset = true }
                .confirmationDialog("Use the cloud copy?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Replace local data", role: .destructive) { Task { await store.forcePull() } }
                } message: { Text("Any edits on this device that haven't synced are lost.") }
        }
    }

    @ViewBuilder private var programSection: some View {
        Section {
            if store.db.weeks.isEmpty {
                Text("No program installed.").foregroundStyle(.secondary)
            } else {
                DatePicker("Week 1 starts", selection: $startMonday, displayedComponents: .date)
                Button("Move the program to this date") { confirmReanchor = true }
                    .disabled(!store.canEdit)
                    .confirmationDialog("Re-anchor the program?", isPresented: $confirmReanchor, titleVisibility: .visible) {
                        Button("Move it") {
                            store.mutate { $0.setProgramStart(DateKey.mondayKey(startMonday)) }
                        }
                    } message: {
                        Text("Week 1 will start on the Monday of \(startMonday.formatted(date: .abbreviated, time: .omitted)). Logged workouts don't change.")
                    }
            }
        } header: {
            Text("Program")
        } footer: {
            Text("Any date snaps to the Monday of its week.")
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section {
            if let url = exportURL() {
                ShareLink(item: url) { Label("Export backup (JSON)", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Data")
        } footer: {
            Text("The same format the web app syncs, so it can be restored anywhere.")
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
