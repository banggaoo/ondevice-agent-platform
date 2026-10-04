import Foundation
import CSQLite

/// SQLite durable store. Schema v1 holds content-free job/session/profile
/// metadata only. WAL + FULL sync + foreign keys + bounded busy timeout.
/// Newer on-disk schema fails rather than downgrading. Storage exhaustion
/// refuses new records; it never silently deletes history.
public actor StateStore {
    public static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?
    private let dbURL: URL
    private let databaseBytesCap: Int

    public init(url: URL, databaseBytesCap: Int = PlatformLimits.databaseBytes) {
        self.dbURL = url
        self.databaseBytesCap = databaseBytesCap
    }

    public func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            if let h = handle { sqlite3_close(h) }
            throw PlatformError(.storageFailure, detail: "sqlite open failed")
        }
        db = h
        sqlite3_busy_timeout(h, 1_000)
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=FULL")
            try exec("PRAGMA foreign_keys=ON")
            try migrate()
            try markInterruptedOnOpen()
        } catch {
            sqlite3_close(h)
            db = nil
            throw error
        }
        // WAL/shm sidecar files are created by SQLite itself, not openOwned;
        // they carry the same content as the db so they get the same mode.
        for suffix in ["-wal", "-shm"] {
            let path = dbURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    public func close() {
        if let h = db {
            sqlite3_close_v2(h)
            db = nil
        }
    }

    private func exec(_ sql: String) throws {
        guard let h = db else { throw PlatformError(.storageFailure, detail: "db closed") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw PlatformError(.storageFailure, detail: "exec: \(msg)")
        }
    }

    private func migrate() throws {
        var version: Int32 = 0
        try query("PRAGMA user_version") { stmt in
            version = sqlite3_column_int(stmt, 0)
        }
        if version > StateStore.schemaVersion {
            throw PlatformError(.versionUnsupported, detail: "db schema \(version)")
        }
        if version < StateStore.schemaVersion {
            try transaction {
                try self.exec("""
                    CREATE TABLE IF NOT EXISTS jobs(
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        consumer_id TEXT NOT NULL,
                        parent_id TEXT,
                        state TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        provider_finished INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                try self.exec("""
                    CREATE TABLE IF NOT EXISTS sessions(
                        id TEXT PRIMARY KEY,
                        agent_id TEXT NOT NULL,
                        agent_version INTEGER NOT NULL,
                        harness_id TEXT NOT NULL,
                        harness_version INTEGER NOT NULL,
                        consumer_id TEXT NOT NULL,
                        state TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """)
                try self.exec("""
                    CREATE TABLE IF NOT EXISTS counters(
                        name TEXT PRIMARY KEY,
                        value INTEGER NOT NULL
                    )
                    """)
                try exec("PRAGMA user_version=\(StateStore.schemaVersion)")
            }
        }
    }

    /// Restart semantics: unfinished rows become interrupted, never replayed.
    private func markInterruptedOnOpen() throws {
        try exec("""
            UPDATE jobs SET state='interrupted', updated_at=\(Date().timeIntervalSince1970)
            WHERE state IN ('queued','active','cancel_requested')
            """)
        try exec("""
            UPDATE sessions SET state='closed', updated_at=\(Date().timeIntervalSince1970)
            WHERE state IN ('open','active')
            """)
    }

    private func query(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil,
                       row: (OpaquePointer) throws -> Void) throws {
        guard let h = db else { throw PlatformError(.storageFailure, detail: "db closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw PlatformError(.storageFailure, detail: "prepare failed")
        }
        defer { sqlite3_finalize(s) }
        bind?(s)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { try row(s) }
            else if rc == SQLITE_DONE { return }
            else { throw PlatformError(.storageFailure, detail: "step \(rc)") }
        }
    }

    private func bind(_ stmt: OpaquePointer, index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ stmt: OpaquePointer, index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer, index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func runStatement(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let h = db else { throw PlatformError(.storageFailure, detail: "db closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw PlatformError(.storageFailure, detail: "prepare failed")
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw PlatformError(.storageFailure, detail: "statement failed")
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Refuses new durable work at the configured caps instead of deleting.
    private func checkCapacity() throws {
        var count = 0
        try query("SELECT COUNT(*) FROM jobs") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        if count >= PlatformLimits.durableRecords {
            throw PlatformError(.storageExhausted, detail: "record cap")
        }
        if let size = try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64,
           size > Int64(databaseBytesCap) {
            throw PlatformError(.storageExhausted, detail: "db bytes cap")
        }
    }

    /// Highest `job-<n>` suffix already persisted, so a restarted daemon
    /// never re-issues an id that collides with a durable row.
    public func maxJobSequence() throws -> Int {
        var maxN = 0
        try query("SELECT id FROM jobs") { stmt in
            let id = String(cString: sqlite3_column_text(stmt, 0))
            if id.hasPrefix("job-"), let n = Int(id.dropFirst(4)) {
                maxN = max(maxN, n)
            }
        }
        return maxN
    }

    /// Test seam: an optional hook awaited inside insertJob before the row
    /// is written, letting tests deterministically hold storage insertion
    /// while concurrent submissions race. Production leaves it nil.
    var beforeInsertJob: (@Sendable () async throws -> Void)?

    func setBeforeInsertJob(_ callback: (@Sendable () async throws -> Void)?) {
        beforeInsertJob = callback
    }

    public func insertJob(_ job: JobRecord) async throws {
        if let hook = beforeInsertJob { try await hook() }
        try checkCapacity()
        try runStatement("""
            INSERT INTO jobs(id,kind,consumer_id,parent_id,state,created_at,updated_at,provider_finished)
            VALUES(?,?,?,?,?,?,?,?)
            """) { s in
            self.bind(s, index: 1, job.id)
            self.bind(s, index: 2, job.kind.rawValue)
            self.bind(s, index: 3, job.consumerID)
            if let p = job.parentID { self.bind(s, index: 4, p) }
            else { sqlite3_bind_null(s, 4) }
            self.bind(s, index: 5, job.state.rawValue)
            self.bind(s, index: 6, job.createdAt.timeIntervalSince1970)
            self.bind(s, index: 7, job.updatedAt.timeIntervalSince1970)
            self.bind(s, index: 8, Int64(job.providerFinished ? 1 : 0))
        }
    }

    public func updateJob(_ job: JobRecord) throws {
        try runStatement(
            "UPDATE jobs SET state=?,updated_at=?,provider_finished=? WHERE id=?") { s in
            self.bind(s, index: 1, job.state.rawValue)
            self.bind(s, index: 2, job.updatedAt.timeIntervalSince1970)
            self.bind(s, index: 3, Int64(job.providerFinished ? 1 : 0))
            self.bind(s, index: 4, job.id)
        }
    }

    private func rowToJob(_ stmt: OpaquePointer) -> JobRecord {
        var parent: String?
        if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
            parent = String(cString: sqlite3_column_text(stmt, 3))
        }
        return JobRecord(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            kind: JobKind(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .llm,
            consumerID: String(cString: sqlite3_column_text(stmt, 2)),
            parentID: parent,
            state: JobState(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .failed,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            providerFinished: sqlite3_column_int64(stmt, 7) != 0
        )
    }

    public func job(id: String) throws -> JobRecord? {
        var found: JobRecord?
        try query(
            "SELECT id,kind,consumer_id,parent_id,state,created_at,updated_at,provider_finished FROM jobs WHERE id=?",
            bind: { self.bind($0, index: 1, id) }
        ) { stmt in
            found = rowToJob(stmt)
        }
        return found
    }

    public func jobs(limit: Int = 100) throws -> [JobRecord] {
        var out: [JobRecord] = []
        try query("""
            SELECT id,kind,consumer_id,parent_id,state,created_at,updated_at,provider_finished
            FROM jobs ORDER BY created_at DESC LIMIT ?
            """,
            bind: { self.bind($0, index: 1, Int64(max(0, min(limit, 1000)))) }
        ) { stmt in
            out.append(rowToJob(stmt))
        }
        return out
    }

    public func insertSession(id: String, agent: AgentProfile, consumerID: String, now: Date) throws {
        try runStatement("""
            INSERT INTO sessions(id,agent_id,agent_version,harness_id,harness_version,consumer_id,state,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """) { s in
            self.bind(s, index: 1, id)
            self.bind(s, index: 2, agent.id)
            self.bind(s, index: 3, Int64(agent.version))
            self.bind(s, index: 4, agent.harnessID)
            self.bind(s, index: 5, Int64(agent.harnessVersion))
            self.bind(s, index: 6, consumerID)
            self.bind(s, index: 7, "open")
            self.bind(s, index: 8, now.timeIntervalSince1970)
            self.bind(s, index: 9, now.timeIntervalSince1970)
        }
    }

    public func closeSession(id: String, now: Date) throws {
        try runStatement("UPDATE sessions SET state='closed',updated_at=? WHERE id=?") { s in
            self.bind(s, index: 1, now.timeIntervalSince1970)
            self.bind(s, index: 2, id)
        }
    }

    public func incrementCounter(_ name: String) throws {
        try runStatement("""
            INSERT INTO counters(name,value) VALUES(?,1)
            ON CONFLICT(name) DO UPDATE SET value=value+1
            """) { s in
            self.bind(s, index: 1, name)
        }
    }

    public func counter(_ name: String) throws -> Int64 {
        var value: Int64 = 0
        try query("SELECT value FROM counters WHERE name=?",
                  bind: { self.bind($0, index: 1, name) }) { stmt in
            value = sqlite3_column_int64(stmt, 0)
        }
        return value
    }
}
