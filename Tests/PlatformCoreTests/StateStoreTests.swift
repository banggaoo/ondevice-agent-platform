import XCTest
import PlatformTestSupport
import CSQLite
@testable import PlatformCore

/// Durable-store and runtime-root safety: restart interruption, schema
/// versioning, exclusive lock, symlink refusal, permissions, and bounded
/// records.
final class StateStoreTests: XCTestCase {

    private func job(_ id: String, state: JobState = .queued) -> JobRecord {
        JobRecord(id: id, kind: .llm, consumerID: "c", parentID: nil,
                  state: state, createdAt: Date(), updatedAt: Date())
    }

    func testRestartMarksUnfinishedInterruptedAndNeverReplays() async throws {
        let url = tempRootURL()
        let root = try preparedRoot(url)
        defer { root.releaseLock() }
        let db = root.databaseURL
        let store = StateStore(url: db)
        try await store.open()
        try await store.insertJob(job("j-active", state: .active))
        try await store.insertJob(job("j-queued", state: .queued))
        try await store.insertJob(job("j-done", state: .completed))
        await store.close()

        let reopened = StateStore(url: db)
        try await reopened.open()
        defer { Task { await reopened.close() } }
        let active = try await reopened.job(id: "j-active")
        let queued = try await reopened.job(id: "j-queued")
        let done = try await reopened.job(id: "j-done")
        XCTAssertEqual(active?.state, .interrupted)
        XCTAssertEqual(queued?.state, .interrupted)
        XCTAssertEqual(done?.state, .completed)   // finished rows untouched
    }

    func testNewerSchemaVersionRefused() async throws {
        let url = tempRootURL()
        let root = try preparedRoot(url)
        defer { root.releaseLock() }
        let store = StateStore(url: root.databaseURL)
        // Open once to create schema, then bump user_version externally.
        try await store.open()
        await store.close()

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.databaseURL.path, &handle,
                                     SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version=2", nil, nil, nil),
                       SQLITE_OK)
        sqlite3_close(handle)

        do {
            try await store.open()
            XCTFail("expected versionUnsupported")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .versionUnsupported)
        }
    }

    func testExclusiveRootLockDeniedForSecondOwner() throws {
        let url = tempRootURL()
        let first = try preparedRoot(url)
        defer { first.releaseLock() }
        let second = RuntimeRoot(url: url)
        XCTAssertThrowsError(try second.acquireLock()) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .conflict)
        }
    }

    func testSymlinkedStateAndLockRefusedWithoutTouchingTarget() throws {
        let url = tempRootURL()
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let target = tempRootURL("target").appendingPathComponent("victim.txt")
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try "precious".write(to: target, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: target.deletingLastPathComponent()) }

        // Symlink the db file and the lock file; both must be refused.
        try fm.createSymbolicLink(at: url.appendingPathComponent("state.sqlite3"),
                                  withDestinationURL: target)
        let root = RuntimeRoot(url: url)
        XCTAssertThrowsError(try root.checkStateFiles()) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .rootUnsafe)
        }
        try fm.removeItem(at: url.appendingPathComponent("state.sqlite3"))
        try fm.createSymbolicLink(at: url.appendingPathComponent("lock.fd"),
                                  withDestinationURL: target)
        XCTAssertThrowsError(try root.acquireLock()) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .rootUnsafe)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "precious")
        try fm.removeItem(at: url)
    }

    func testRootPermissionsAndOwnedFileModes() throws {
        let url = tempRootURL()
        let root = try preparedRoot(url)
        defer { root.releaseLock() }
        let fm = FileManager.default
        let dirMode = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
                       as? NSNumber)?.intValue
        XCTAssertEqual(dirMode, 0o700)
        try root.writeOwnedJSON(.object(["k": .int(1)]), to: root.configURL)
        let fileMode = (try fm.attributesOfItem(atPath: root.configURL.path)[.posixPermissions]
                        as? NSNumber)?.intValue
        XCTAssertEqual(fileMode, 0o600)
        // No sessions directory is created; only owned state lives here.
        let entries = try fm.contentsOfDirectory(atPath: url.path)
        XCTAssertFalse(entries.contains("sessions"))
    }

    func testUnrelatedNonEmptyRootRefused() throws {
        let url = tempRootURL()
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try "x".write(to: url.appendingPathComponent("unrelated.txt"),
                      atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: url) }
        XCTAssertThrowsError(try RuntimeRoot(url: url).prepare()) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .rootUnsafe)
        }
        // The unrelated file is not modified.
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("unrelated.txt"),
                                  encoding: .utf8), "x")
    }

    func testDurableRecordCapRefusesNewWork() async throws {
        let url = tempRootURL()
        let root = try preparedRoot(url)
        defer { root.releaseLock() }
        let store = StateStore(url: root.databaseURL)
        try await store.open()
        defer { Task { await store.close() } }
        for i in 0..<PlatformLimits.durableRecords {
            try await store.insertJob(job("j-\(i)", state: .completed))
        }
        do {
            try await store.insertJob(job("j-overflow", state: .completed))
            XCTFail("expected storageExhausted")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .storageExhausted)
        }
    }

    /// Job records carry no prompt/output/credential content; the schema has
    /// no free-text content columns.
    func testJobSchemaIsContentFree() async throws {
        let url = tempRootURL()
        let root = try preparedRoot(url)
        defer { root.releaseLock() }
        let store = StateStore(url: root.databaseURL)
        try await store.open()
        try await store.insertJob(JobRecord(
            id: "j1", kind: .llm, consumerID: "c", parentID: nil,
            state: .completed, createdAt: Date(), updatedAt: Date()))
        await store.close()

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.databaseURL.path, &handle,
                                     SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA table_info(jobs)",
                                        -1, &stmt, nil), SQLITE_OK)
        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            columns.insert(String(cString: sqlite3_column_text(stmt, 1)))
        }
        sqlite3_finalize(stmt)
        sqlite3_close(handle)
        let forbidden: Set<String> = ["prompt", "content", "output", "messages",
                                      "response", "token", "secret", "credential",
                                      "body", "payload"]
        XCTAssertTrue(columns.isDisjoint(with: forbidden),
                      "unexpected content column: \(columns)")
    }
}
