import Foundation
import Observation

/// Writes snapshots to disk off the main thread, one at a time, never letting an older one land on a newer one.
final class DiskWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0

    func write(_ snap: Snapshot, generation: Int, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard generation > written else { return }
        try JSONEncoder().encode(snap).write(to: url, options: .atomic)
        written = generation
    }
}

/// One dated copy of the data file, kept in Documents/Backups.
struct BackupCopy: Identifiable, Hashable {
    var date: String
    var url: URL
    var id: String { date }
}

/// The app's single source of truth: the whole database in memory, saved to a JSON file in
/// Documents shortly after every change. That file is included in the iPhone's iCloud Backup.
@MainActor
@Observable
final class Store {
    private(set) var db: Snapshot
    /// Set when the last save failed; Settings shows it.
    private(set) var saveError: String?
    /// Set when the data file was there but couldn't be read. A copy of it is kept next to it.
    private(set) var loadError: String?

    private let fileURL: URL
    @ObservationIgnored private let writer = DiskWriter()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Launch with `-demo` for a throwaway sandbox with its own file.
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
    /// How long changes wait to be written together (a burst of +/− taps is one write).
    static let saveDelay: Duration = .milliseconds(250)
    static let backupsKept = 7

    init(fileURL: URL? = nil, seedIfEmpty: Bool = true) {
        let url = fileURL ?? URL.documentsDirectory.appending(path: Self.isDemo ? "gymtrak-demo.json" : "gymtrak.json")
        self.fileURL = url
        let data = try? Data(contentsOf: url)
        if let data, let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            db = snap
            backupIfNeeded(data)
        } else {
            db = seedIfEmpty ? seedSnapshot() : Snapshot(programWeeks: [], schema: 2)
            // A file that exists but won't read is never thrown away: the next save would overwrite it.
            if let data {
                let copy = url.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: copy, options: .atomic)
                loadError = "Couldn't read your data. The original was kept as \(copy.lastPathComponent)."
            }
        }
    }

    /// Apply a change and save it. Optional so callers can chain `?? default`.
    @discardableResult
    func mutate<T>(_ change: (inout Snapshot) -> T) -> T? {
        let result = change(&db)
        db.schema = 2
        scheduleSave()
        return result
    }

    /// Replace everything with a backup file (Settings → Import Backup, or one of the daily copies).
    /// What was there is kept as "…-before-restore.json" in Backups.
    func importBackup(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var snap = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        if snap.programWeeks == nil { snap.programWeeks = db.programWeeks }
        if let current = try? JSONEncoder().encode(db) {
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try? current.write(to: backupDir.appending(path: "\(stem)-before-restore.json"), options: .atomic)
        }
        db = snap
        dirty = true
        flush()
    }

    // MARK: Saving

    /// Write soon, off the main thread. Taps never wait on the disk.
    private func scheduleSave() {
        dirty = true
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.generation += 1
            let snap = self.db, gen = self.generation, url = self.fileURL, writer = self.writer
            let error: String? = await Task.detached(priority: .utility) {
                do { try writer.write(snap, generation: gen, to: url); return nil }
                catch { return "Couldn't save: \(error.localizedDescription)" }
            }.value
            if gen == self.generation {
                self.saveError = error
                if error == nil { self.dirty = false }
            }
        }
    }

    /// Write right now if anything is waiting. Called when the app leaves the foreground.
    func flush() {
        pending?.cancel()
        pending = nil
        if dirty {
            generation += 1
            do {
                try writer.write(db, generation: generation, to: fileURL)
                saveError = nil
                dirty = false
            } catch {
                saveError = "Couldn't save: \(error.localizedDescription)"
            }
        }
        if !FileManager.default.fileExists(atPath: backupURL(DateKey.key(Date())).path()),
           let data = try? JSONEncoder().encode(db) {
            backupIfNeeded(data)
        }
    }

    // MARK: Daily backups

    private var stem: String { fileURL.deletingPathExtension().lastPathComponent }
    private var backupDir: URL { fileURL.deletingLastPathComponent().appending(path: "Backups") }
    private func backupURL(_ date: String) -> URL { backupDir.appending(path: "\(stem)-\(date).json") }

    /// The dated copies on this phone, newest first.
    func backups() -> [BackupCopy] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path())) ?? []
        let prefix = "\(stem)-"
        return names.compactMap { name -> BackupCopy? in
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
            let date = String(name.dropFirst(prefix.count).dropLast(5))
            guard date.count == 10, date.first?.isNumber == true else { return nil }
            return BackupCopy(date: date, url: backupDir.appending(path: name))
        }
        .sorted { $0.date > $1.date }
    }

    /// One copy per day, made the first time the app has data that day. Keeps the newest `backupsKept`.
    private func backupIfNeeded(_ data: Data) {
        let dest = backupURL(DateKey.key(Date()))
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path()) else { return }
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
        for old in backups().dropFirst(Self.backupsKept) { try? fm.removeItem(at: old.url) }
    }
}
