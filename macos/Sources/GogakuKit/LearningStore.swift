import Foundation
import CSQLite

public struct LearningEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let source: String
    public let target: String
    public let direction: Direction
    public let category: String
    public var issues: [SpellingIssue]
    public let application: String
    public init(id: UUID, source: String, target: String, direction: Direction, category: String, issues: [SpellingIssue], application: String, now: Date = Date()) {
        self.id = id; createdAt = now; expiresAt = now.addingTimeInterval(30 * 24 * 60 * 60)
        self.source = source; self.target = target; self.direction = direction
        self.category = category; self.issues = issues; self.application = application
    }
}
public enum StoreError: Error { case unavailable, query }
/// 输入只做有界入队；SQLite 操作、过期维护及读列表均在独立队列。
public final class LearningStore {
    private let queue = DispatchQueue(label: "org.gogaku.records", qos: .utility)
    private let capacity = DispatchSemaphore(value: 256)
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var paused = false
    private var excluded = Set<String>()
    private let directory: URL
    public var onFailure: (() -> Void)?
    public init(directory: URL = Paths.support) { self.directory = directory }
    private func database() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        let path = directory.appendingPathComponent("learning.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw StoreError.unavailable
        }
        do {
            sqlite3_busy_timeout(db, 20)
            try execute(db, "PRAGMA journal_mode=WAL")
            try execute(db, "CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, expires REAL NOT NULL, app TEXT NOT NULL, payload BLOB NOT NULL)")
            try execute(db, "CREATE TABLE IF NOT EXISTS tombstones(id TEXT PRIMARY KEY)")
            try execute(db, "DELETE FROM events WHERE expires <= strftime('%s','now')")
            return db
        } catch { sqlite3_close(db); throw error }
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.query }
    }
    public func policy(recording: Bool, excludedApplications: Set<String>) {
        lock.lock(); paused = !recording; excluded = excludedApplications; epoch &+= 1; lock.unlock()
    }
    @discardableResult public func append(_ event: LearningEvent) -> Bool {
        lock.lock(); let generation = epoch, allowed = !paused && !excluded.contains(event.application); lock.unlock()
        guard allowed else { return false }
        guard capacity.wait(timeout: .now()) == .success else { onFailure?(); return false }
        queue.async {
            defer { self.capacity.signal() }
            self.lock.lock(); let valid = self.epoch == generation && !self.paused && !self.excluded.contains(event.application); self.lock.unlock()
            guard valid else { return }
            // 设置进程暂停/排除也作用于尚未写入的任务。
            if self.directory == Paths.support {
                let settings = Settings.load()
                guard settings.recording, !settings.excludedApplications.contains(event.application) else { return }
            }
            do {
                let db = try self.database(); defer { sqlite3_close(db) }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO events SELECT ?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM tombstones WHERE id=?)", -1, &statement, nil) == SQLITE_OK else { throw StoreError.query }
                defer { sqlite3_finalize(statement) }
                let data = try JSONEncoder().encode(event)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, event.id.uuidString, -1, transient)
                sqlite3_bind_double(statement, 2, event.expiresAt.timeIntervalSince1970)
                sqlite3_bind_text(statement, 3, event.application, -1, transient)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), transient) }
                sqlite3_bind_text(statement, 5, event.id.uuidString, -1, transient)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.query }
            } catch { self.onFailure?() }
        }
        return true
    }
    public func list(now: Date = Date(), completion: @escaping (Result<[LearningEvent], Error>) -> Void) {
        queue.async {
            do {
                let db = try self.database(); defer { sqlite3_close(db) }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT payload FROM events WHERE expires > ? ORDER BY rowid DESC LIMIT 1000", -1, &statement, nil) == SQLITE_OK else { throw StoreError.query }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                var records: [LearningEvent] = []
                var step = sqlite3_step(statement)
                while step == SQLITE_ROW {
                    let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
                    records.append(try JSONDecoder().decode(LearningEvent.self, from: data)); step = sqlite3_step(statement)
                }
                guard step == SQLITE_DONE else { throw StoreError.query }
                completion(.success(records))
            } catch { completion(.failure(error)) }
        }
    }
    public func delete(ids: [UUID], completion: @escaping (Bool) -> Void) {
        lock.lock(); epoch &+= 1; lock.unlock()
        queue.async {
            do {
                let db = try self.database(); defer { sqlite3_close(db) }
                try self.execute(db, "BEGIN IMMEDIATE")
                do {
                    for id in ids {
                        // UUID 只能含十六进制与连字符；不拼接用户文字。
                        try self.execute(db, "INSERT OR IGNORE INTO tombstones VALUES('\(id.uuidString)')")
                        try self.execute(db, "DELETE FROM events WHERE id='\(id.uuidString)'")
                    }
                    try self.execute(db, "COMMIT"); completion(true)
                } catch { try? self.execute(db, "ROLLBACK"); throw error }
            } catch { completion(false) }
        }
    }
    public func dismissIssues(id: UUID, completion: @escaping (Bool) -> Void) {
        queue.async {
            do {
                let db = try self.database(); defer { sqlite3_close(db) }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT payload FROM events WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.query }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
                guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); throw StoreError.query }
                let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
                sqlite3_finalize(statement)
                var event = try JSONDecoder().decode(LearningEvent.self, from: data); event.issues = []
                let updated = try JSONEncoder().encode(event)
                guard sqlite3_prepare_v2(db, "UPDATE events SET payload=? WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw StoreError.query }
                defer { sqlite3_finalize(statement) }
                _ = updated.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(updated.count), transient) }
                sqlite3_bind_text(statement, 2, id.uuidString, -1, transient)
                completion(sqlite3_step(statement) == SQLITE_DONE)
            } catch { completion(false) }
        }
    }
}
