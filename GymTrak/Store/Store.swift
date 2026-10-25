import Foundation
import Observation

/// The app's single source of truth: the whole database in memory, saved to a JSON
/// file on every change and mirrored to Supabase (last write wins, like the PWA).
@MainActor
@Observable
final class Store {
    enum SyncStatus: Equatable { case offline, idle, syncing, synced, error(String) }

    private(set) var db: Snapshot
    private(set) var syncStatus: SyncStatus
    private(set) var lastSyncedAt: Date?
    /// True once the edit code is saved on this device. Without it the app is read-only.
    private(set) var canEdit: Bool

    private let fileURL: URL
    private let client: SupabaseClient?
    private var cursor: Double = 0 // cloud `updated_at` reflected locally
    private var hasCloudRow = false
    /// Local edits not yet pushed. Persisted so an edit made offline survives a relaunch.
    private var dirty: Bool {
        get { UserDefaults.standard.bool(forKey: "gt_dirty") }
        set { UserDefaults.standard.set(newValue, forKey: "gt_dirty") }
    }
    private var pushTask: Task<Void, Never>?

    private static let codeKey = "gt_edit_pw"
    private static let cursorKey = "gt_cursor"

    /// Launch with `-demo` for a local-only sandbox: no sync, its own file, editing on.
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")

    init(fileURL: URL? = nil, client: SupabaseClient? = SupabaseClient.fromBundle(), seedIfEmpty: Bool = true) {
        let url = fileURL ?? URL.documentsDirectory.appending(path: Self.isDemo ? "gymtrak-demo.json" : "gymtrak.json")
        self.fileURL = url
        self.client = Self.isDemo ? nil : client
        self.canEdit = Self.isDemo || UserDefaults.standard.string(forKey: Self.codeKey) != nil
        self.syncStatus = self.client == nil ? .offline : .idle
        self.cursor = UserDefaults.standard.double(forKey: Self.cursorKey)
        if let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            db = snap
        } else {
            // With sync configured, the first pull fills the DB; seed only when offline.
            db = seedIfEmpty && self.client == nil ? seedSnapshot() : Snapshot(programWeeks: [], schema: 2)
        }
    }

    // MARK: Mutation

    /// Apply a change, save it, and schedule a push. No-op in read-only mode.
    @discardableResult
    func mutate<T>(_ change: (inout Snapshot) -> T) -> T? {
        guard canEdit else { return nil }
        let result = change(&db)
        db.schema = 2
        save()
        dirty = true
        schedulePush()
        return result
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(db)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            syncStatus = .error("Couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: Edit code

    /// Save the edit code. It is verified by the server on the next push.
    func unlock(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.codeKey)
        canEdit = true
        if db.days.isEmpty && client != nil && !hasCloudRow {
            // Brand-new install with no cloud data yet: seed so there is something to show.
            db = seedSnapshot()
            save()
            dirty = true
        }
        Task { await sync() }
    }

    func lock() {
        UserDefaults.standard.removeObject(forKey: Self.codeKey)
        canEdit = false
    }

    private var code: String? { UserDefaults.standard.string(forKey: Self.codeKey) }

    // MARK: Sync

    private func setCursor(_ value: Double) {
        cursor = value
        UserDefaults.standard.set(value, forKey: Self.cursorKey)
    }

    private var hasRecentOpenSession: Bool { db.openLift() != nil }

    /// Reconcile with the cloud: adopt it when it's newer, push when this device is.
    func sync() async {
        guard let client else { return }
        if pushTask != nil { return } // a push is pending; it wins
        syncStatus = .syncing
        do {
            guard let remote = try await client.fetch() else {
                hasCloudRow = false
                if db.days.isEmpty { db = seedSnapshot(); save() }
                if canEdit { try await push() } else { syncStatus = .synced }
                return
            }
            hasCloudRow = true
            if canEdit && (dirty || hasRecentOpenSession) {
                // Unsent edits or a live workout on this device: push, never clobber it.
                try await push()
            } else if remote.updatedAt > cursor || db.days.isEmpty {
                adopt(remote)
            } else {
                syncStatus = .synced
                lastSyncedAt = Date()
            }
        } catch {
            handle(error)
        }
    }

    private func adopt(_ remote: SupabaseClient.Remote) {
        var incoming = remote.data
        // Absent programWeeks (older writer) means "keep ours", not "clear".
        if incoming.programWeeks == nil { incoming.programWeeks = db.programWeeks }
        db = incoming
        save()
        setCursor(remote.updatedAt)
        dirty = false
        lastSyncedAt = Date()
        syncStatus = .synced
    }

    private func schedulePush() {
        guard client != nil, canEdit else { return }
        syncStatus = .syncing
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            self.pushTask = nil
            do { try await self.push() } catch { self.handle(error) }
        }
    }

    private func push() async throws {
        guard let client, let code, canEdit else { return }
        syncStatus = .syncing
        if hasCloudRow && cursor > 0, let remoteAt = try await client.fetchUpdatedAt(), remoteAt > cursor {
            syncStatus = .error("Another device has newer changes. Pull to refresh first.")
            return
        }
        let ts = try await client.save(db, code: code)
        setCursor(ts)
        hasCloudRow = true
        dirty = false
        lastSyncedAt = Date()
        syncStatus = .synced
    }

    /// Throw away local edits and take the cloud copy (used after a conflict).
    func forcePull() async {
        guard let client else { return }
        syncStatus = .syncing
        do {
            if let remote = try await client.fetch() { adopt(remote) } else { syncStatus = .synced }
        } catch { handle(error) }
    }

    private func handle(_ error: Error) {
        if case SupabaseClient.SyncError.invalidCode = error {
            lock()
        }
        if (error as? URLError)?.code == .notConnectedToInternet {
            syncStatus = .offline
        } else {
            syncStatus = .error(error.localizedDescription)
        }
    }
}
