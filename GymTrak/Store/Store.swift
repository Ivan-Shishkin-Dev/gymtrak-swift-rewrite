import Foundation
import Observation

/// The app's single source of truth: the whole database in memory, saved to a JSON file in
/// Documents on every change. That file is included in the iPhone's iCloud Backup.
@MainActor
@Observable
final class Store {
    private(set) var db: Snapshot
    /// Set when the last save failed; Settings shows it.
    private(set) var saveError: String?

    private let fileURL: URL

    /// Launch with `-demo` for a throwaway sandbox with its own file.
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")

    init(fileURL: URL? = nil, seedIfEmpty: Bool = true) {
        let url = fileURL ?? URL.documentsDirectory.appending(path: Self.isDemo ? "gymtrak-demo.json" : "gymtrak.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            db = snap
        } else {
            db = seedIfEmpty ? seedSnapshot() : Snapshot(programWeeks: [], schema: 2)
        }
    }

    /// Apply a change and save it. Optional so callers can chain `?? default`.
    @discardableResult
    func mutate<T>(_ change: (inout Snapshot) -> T) -> T? {
        let result = change(&db)
        db.schema = 2
        save()
        return result
    }

    /// Replace everything with a backup file (Settings → Import Backup).
    func importBackup(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var snap = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        if snap.programWeeks == nil { snap.programWeeks = db.programWeeks }
        db = snap
        save()
    }

    private func save() {
        do {
            try JSONEncoder().encode(db).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
