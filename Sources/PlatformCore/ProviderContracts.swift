import Foundation

/// Distinct injectable seams. Empty registries are valid; test fixtures live
/// in test support, never as default serving aliases.
public protocol LLMProvider: Sendable {
    var providerID: String { get }
    func complete(_ request: ChatRequest, profile: ModelProfile) async throws -> ChatResult
    /// Cooperative cancellation hint; providers that cannot cancel simply
    /// finish and the scheduler keeps the slot until real completion.
    func cancel(jobID: String) async
}

public protocol MLPredictor: Sendable {
    var providerID: String { get }
    func predict(_ request: PredictionRequest, profile: ModelProfile) async throws -> PredictionResult
    func cancel(jobID: String) async
}

public extension LLMProvider {
    func cancel(jobID: String) async {}
}

public extension MLPredictor {
    func cancel(jobID: String) async {}
}

/// Injectable clock for deterministic tests. `sleep` is the only timing
/// source the core uses for deadlines/grace; it is cancellation-aware so
/// task-group deadline timers exit promptly instead of pinning scope exit.
public struct Clock: Sendable {
    private let nowImpl: @Sendable () -> Date
    private let sleepImpl: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date = { Date() },
                sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.nowImpl = now
        self.sleepImpl = sleep ?? { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    public var now: Date { nowImpl() }

    public func sleep(_ seconds: TimeInterval) async throws {
        try await sleepImpl(seconds)
    }
}
