import Foundation
import PlatformCore

/// In-memory credential store for tests; never touches Keychain.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    public init() {}

    public func secret(forKey key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[key]
    }

    public func setSecret(_ secret: Data, forKey key: String) throws {
        lock.lock()
        secrets[key] = secret
        lock.unlock()
    }
}

/// Deterministic clock: `advance` fires registered sleepers in wake order;
/// cancellation resumes a sleeper immediately so task-group timers exit.
public final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let wakeAt: Date
        let cont: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var nowValue: Date
    private var sleepers: [Sleeper] = []
    private var cancelled = Set<Int>()
    private var nextID = 0

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        nowValue = now
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return nowValue
    }

    /// Count of registered sleepers; tests poll this before `advance` so a
    /// spawned timer task cannot miss an advance that raced its registration.
    public var pendingSleepers: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    public var clock: Clock {
        Clock(now: { [weak self] in self?.now ?? Date() },
              sleep: { [weak self] seconds in
                  guard let self else { return }
                  try await self.sleep(seconds)
              })
    }

    public func set(_ date: Date) {
        lock.lock()
        nowValue = max(nowValue, date)
        let due = sleepers.filter { $0.wakeAt <= nowValue }.sorted { $0.wakeAt < $1.wakeAt }
        sleepers.removeAll { $0.wakeAt <= nowValue }
        lock.unlock()
        for s in due { s.cont.resume() }
    }

    public func advance(by seconds: TimeInterval) {
        set(now.addingTimeInterval(seconds))
    }

    private func nextSleeperID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    private func registerSleeper(id: Int, seconds: TimeInterval,
                                 cont: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled.contains(id) else { return false }
        sleepers.append(Sleeper(id: id, wakeAt: nowValue.addingTimeInterval(seconds), cont: cont))
        return true
    }

    private func cancelSleeper(id: Int) {
        lock.lock()
        cancelled.insert(id)
        var found: Sleeper?
        if let index = sleepers.firstIndex(where: { $0.id == id }) {
            found = sleepers.remove(at: index)
        }
        lock.unlock()
        found?.cont.resume(throwing: CancellationError())
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let id = nextSleeperID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if !registerSleeper(id: id, seconds: seconds, cont: cont) {
                    cont.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancelSleeper(id: id)
        }
    }
}

/// Settable resource observation source.
public final class FakeResourceSource: ResourceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ResourceSnapshot
    private var onChange: (@Sendable (ResourceSnapshot) -> Void)?

    public init(_ snapshot: ResourceSnapshot = .unknown) {
        self.snapshot = snapshot
    }

    public func currentSnapshot() -> ResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func start(onChange: @escaping @Sendable (ResourceSnapshot) -> Void) {
        lock.lock()
        self.onChange = onChange
        lock.unlock()
    }

    public func stop() {}

    public func push(_ snapshot: ResourceSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snapshot)
    }
}

public func healthySnapshot(at date: Date) -> ResourceSnapshot {
    ResourceSnapshot(thermal: .nominal, memoryPressure: .normal,
                     lowPowerMode: false, capturedAt: date)
}

/// Fresh isolated runtime root under /private/tmp for tests.
public func tempRootURL(_ name: String = UUID().uuidString) -> URL {
    let url = URL(fileURLWithPath: "/private/tmp/oap-test-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    return url
}

public func preparedRoot(_ url: URL) throws -> RuntimeRoot {
    let root = RuntimeRoot(url: url)
    try root.prepare()
    try root.acquireLock()
    try root.checkStateFiles()
    return root
}

public struct TestStack: Sendable {
    public let root: RuntimeRoot
    public let clock: ManualClock
    public let resources: FakeResourceSource
    public let supervisor: PlatformSupervisor
}

/// A running supervisor with in-memory credentials and a manual clock.
/// Healthy observation is pushed at the manual clock's current time.
public func makeStack(enableReferenceAgent: Bool = false,
                      healthy: Bool = true) async throws -> TestStack {
    let clock = ManualClock()
    let resources = FakeResourceSource(
        healthy ? healthySnapshot(at: clock.now) : .unknown)
    let root = try preparedRoot(tempRootURL())
    let supervisor = PlatformSupervisor(
        root: root, credentials: MemoryCredentialStore(),
        resourceSource: resources, clock: clock.clock,
        options: .init(enableReferenceAgent: enableReferenceAgent))
    try await supervisor.start()
    return TestStack(root: root, clock: clock, resources: resources,
                     supervisor: supervisor)
}

/// Poll a condition with short real sleeps; deterministic clock advances are
/// separate from task scheduling, so async state needs a bounded settle.
public func pollUntil(_ timeout: TimeInterval = 5,
                      _ condition: @escaping @Sendable () async throws -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return (try? await condition()) == true
}

// MARK: - async assertion helpers (XCTest autoclosures are not async)

/// Thrown by the expect* helpers; XCTest reports it as a test failure.
public struct ExpectationFailed: Error, CustomStringConvertible {
    public let description: String
    public init(_ what: String, _ message: String = "",
                file: StaticString = #filePath, line: UInt = #line) {
        self.description = "\(file):\(line): expected \(what) \(message)"
    }
}

public func expectTrue(_ expression: @autoclosure () async throws -> Bool,
                       _ message: String = "",
                       file: StaticString = #filePath, line: UInt = #line) async throws {
    guard try await expression() else {
        throw ExpectationFailed("true", message, file: file, line: line)
    }
}

public func expectFalse(_ expression: @autoclosure () async throws -> Bool,
                        _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
    guard try await !(expression()) else {
        throw ExpectationFailed("false", message, file: file, line: line)
    }
}

public func expectEqual<T: Equatable>(
    _ a: @autoclosure () async throws -> T,
    _ b: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line) async throws {
    let av = try await a()
    let bv = try await b()
    guard av == bv else {
        throw ExpectationFailed("\(av) == \(bv)", message, file: file, line: line)
    }
}

public func expectNil(_ expression: @autoclosure () async throws -> Any?,
                      _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) async throws {
    guard try await expression() == nil else {
        throw ExpectationFailed("nil", message, file: file, line: line)
    }
}

public func expectNotNil(_ expression: @autoclosure () async throws -> Any?,
                         _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) async throws {
    guard try await expression() != nil else {
        throw ExpectationFailed("non-nil", message, file: file, line: line)
    }
}

public func expectPlatformError(_ code: PlatformCore.ErrorCode,
                                _ body: () async throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
    do {
        try await body()
    } catch let e as PlatformError {
        guard e.code == code else {
            throw ExpectationFailed("\(code), got \(e.code)", file: file, line: line)
        }
        return
    } catch {
        throw ExpectationFailed("\(code), got \(error)", file: file, line: line)
    }
    throw ExpectationFailed("\(code), no error thrown", file: file, line: line)
}

public let modelToken = "test-model-token"
public let consoleToken = "test-console-token"
public let agentToken = "test-agent-token"
public let modelPrincipal = Principal(id: "model-1", scope: .model)
public let consolePrincipal = Principal(id: "console", scope: .console)
public let agentPrincipal = Principal(id: "agent-1", scope: .agent)

public func registerStandardPrincipals(_ supervisor: PlatformSupervisor) async {
    await supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)
    await supervisor.registerPrincipal(token: consoleToken, principal: consolePrincipal)
    await supervisor.registerPrincipal(token: agentToken, principal: agentPrincipal)
}
