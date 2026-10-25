import Foundation
import Observation
import Supabase

/// The app's single source of truth: the whole database in memory, saved to a JSON
/// file on every change and mirrored to the signed-in user's private Supabase row.
@MainActor
@Observable
final class Store {
    enum SyncStatus: Equatable { case offline, idle, syncing, synced, error(String) }
    enum SignIn: Equatable { case signedOut, linkSent(String), signedIn(String) }

    private(set) var db: Snapshot
    private(set) var syncStatus: SyncStatus
    private(set) var lastSyncedAt: Date?
    private(set) var signIn: SignIn = .signedOut

    /// Editing needs an account (or demo mode).
    var canEdit: Bool { Self.isDemo || isSignedIn }
    var isSignedIn: Bool { if case .signedIn = signIn { true } else { false } }
    var email: String? { if case .signedIn(let e) = signIn { e } else { nil } }

    private let fileURL: URL
    let supabase: SupabaseClient?
    private var cursor: Double {
        get { UserDefaults.standard.double(forKey: "gt_user_cursor") }
        set { UserDefaults.standard.set(newValue, forKey: "gt_user_cursor") }
    }
    /// Local edits not yet pushed. Persisted so an offline edit survives a relaunch.
    private var dirty: Bool {
        get { UserDefaults.standard.bool(forKey: "gt_dirty") }
        set { UserDefaults.standard.set(newValue, forKey: "gt_dirty") }
    }
    private var pushTask: Task<Void, Never>?

    static let redirectURL = URL(string: "gymtrak://login")!

    /// Launch with `-demo` for a local-only sandbox: no sync, its own file, editing on.
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")

    init(fileURL: URL? = nil, seedIfEmpty: Bool = true) {
        let url = fileURL ?? URL.documentsDirectory.appending(path: Self.isDemo ? "gymtrak-demo.json" : "gymtrak.json")
        self.fileURL = url
        self.supabase = Self.isDemo ? nil : Self.makeClient()
        self.syncStatus = supabase == nil ? .offline : .idle
        if let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            db = snap
        } else {
            db = seedIfEmpty && (Self.isDemo || supabase == nil) ? seedSnapshot() : Snapshot(programWeeks: [], schema: 2)
        }
        if let user = supabase?.auth.currentUser { signIn = .signedIn(user.email ?? "Signed in") }
    }

    private static func makeClient() -> SupabaseClient? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let host = info["SupabaseHost"] as? String, !host.isEmpty, !host.contains("$("),
              let key = info["SupabaseKey"] as? String, !key.isEmpty, !key.contains("$("),
              let url = URL(string: "https://\(host)") else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key,
                              options: .init(auth: .init(redirectToURL: redirectURL, flowType: .pkce,
                                                         emitLocalSessionAsInitialSession: true)))
    }

    // MARK: Mutation

    /// Apply a change, save it, and schedule a push. No-op when signed out.
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
            try JSONEncoder().encode(db).write(to: fileURL, options: .atomic)
        } catch {
            syncStatus = .error("Couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: Account

    /// Email a one-tap sign-in link.
    func sendLink(to email: String) async {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard let supabase, e.contains("@") else { return }
        do {
            try await supabase.auth.signInWithOTP(email: e, redirectTo: Self.redirectURL)
            signIn = .linkSent(e)
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    /// The link from the email opens the app here.
    func handle(_ url: URL) async {
        guard let supabase else { return }
        do {
            let session = try await supabase.auth.session(from: url)
            signIn = .signedIn(session.user.email ?? "Signed in")
            await sync()
        } catch {
            syncStatus = .error("Sign-in link didn't work: \(error.localizedDescription)")
        }
    }

    func cancelLink() { if case .linkSent = signIn { signIn = .signedOut } }

    /// Sign out and clear this device's copy (it lives in the cloud).
    func signOut() async {
        try? await supabase?.auth.signOut()
        signIn = .signedOut
        db = Snapshot(programWeeks: [], schema: 2)
        save()
        cursor = 0
        dirty = false
    }

    // MARK: Sync

    private struct Row: Decodable { let data: Snapshot; let updated_at: Double }
    private struct SaveParams: Encodable { let p_data: Snapshot; let p_expected: Int64? }

    private func fetchOwnRow() async throws -> Row? {
        let rows: [Row] = try await supabase!.from("gt_user_state").select("data,updated_at").limit(1).execute().value
        return rows.first
    }

    /// The web app's shared row — imported once into a brand-new account.
    private func fetchLegacyRow() async -> Snapshot? {
        let rows: [Row]? = try? await supabase!.from("gt_state").select("data,updated_at").eq("id", value: 1).execute().value
        return rows?.first?.data
    }

    /// Reconcile: adopt the cloud when it's newer, push when this device is.
    func sync() async {
        guard let supabase, isSignedIn, pushTask == nil else { return }
        syncStatus = .syncing
        do {
            _ = try await supabase.auth.session // refreshes an expired token
            guard let remote = try await fetchOwnRow() else {
                // First sign-in: bring over the web app's data, or start fresh.
                if db.days.isEmpty { db = await fetchLegacyRow() ?? seedSnapshot(); save() }
                cursor = 0
                try await push()
                return
            }
            if dirty || db.openLift() != nil {
                try await push() // never clobber unsent edits or a live workout
            } else if remote.updated_at > cursor || db.days.isEmpty {
                adopt(remote.data, at: remote.updated_at)
            } else {
                syncStatus = .synced
                lastSyncedAt = Date()
            }
        } catch {
            handle(error)
        }
    }

    private func adopt(_ incoming: Snapshot, at updatedAt: Double) {
        var incoming = incoming
        if incoming.programWeeks == nil { incoming.programWeeks = db.programWeeks }
        db = incoming
        save()
        cursor = updatedAt
        dirty = false
        lastSyncedAt = Date()
        syncStatus = .synced
    }

    private func schedulePush() {
        guard supabase != nil, isSignedIn else { return }
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
        guard let supabase, isSignedIn else { return }
        syncStatus = .syncing
        let ts: Double = try await supabase
            .rpc("save_user_state", params: SaveParams(p_data: db, p_expected: cursor > 0 ? Int64(cursor) : nil))
            .execute().value
        cursor = ts
        dirty = false
        lastSyncedAt = Date()
        syncStatus = .synced
    }

    /// Throw away local edits and take the cloud copy (used after a conflict).
    func forcePull() async {
        guard supabase != nil, isSignedIn else { return }
        syncStatus = .syncing
        do {
            if let remote = try await fetchOwnRow() { adopt(remote.data, at: remote.updated_at) } else { syncStatus = .synced }
        } catch { handle(error) }
    }

    private func handle(_ error: Error) {
        let text = String(describing: error)
        if (error as? URLError)?.code == .notConnectedToInternet {
            syncStatus = .offline
        } else if text.contains("conflict") {
            syncStatus = .error("Another device saved newer changes. Use Reset from Cloud.")
        } else if text.contains("gt_user_state") || text.contains("save_user_state") {
            syncStatus = .error("Account storage isn't set up yet (run supabase/001_user_state.sql).")
        } else if let auth = error as? AuthError, case .sessionMissing = auth {
            signIn = .signedOut
            syncStatus = .idle
        } else {
            syncStatus = .error(error.localizedDescription)
        }
    }
}
