import Foundation

/// Distinct injectable seams. Empty registries are valid; test fixtures live
/// in test support, never as default serving aliases.
public protocol LLMProvider: Sendable {
    var providerID: String { get }
    /// Provider-specific option check, called by the core after shared
    /// RequestValidation and before admission. A provider that does not
    /// honor a sampling field must reject it here rather than silently
    /// ignore it.
    func validate(_ request: ChatRequest, profile: ModelProfile) throws
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
    /// Default: the provider accepts every shared-validated request.
    func validate(_ request: ChatRequest, profile: ModelProfile) throws {}
    func cancel(jobID: String) async {}
}

public extension MLPredictor {
    func cancel(jobID: String) async {}
}

/// Provider id shared by the registry parser, the supervisor's category
/// status, and the PlatformMLX provider implementation. Declared in the core
/// so all three sides agree without the core importing the MLX runtime.
public enum MLXProviderContract {
    public static let id = "mlx"
}

/// Optional readiness reporting for providers whose weights are external
/// artifacts. The supervisor uses it to report truthful category status:
/// a registered provider with no usable artifact is `observing`, not
/// `qualified`.
public protocol ProviderReadiness: Sendable {
    /// True when at least one declared model artifact is present and valid
    /// under the managed store. Must be cheap (filesystem stat only).
    var hasReadyArtifact: Bool { get }
    /// Per-profile artifact readiness, independent of category readiness.
    /// Nil means this provider cannot verify the profile's artifact.
    func artifactReady(for profile: ModelProfile) -> Bool?
}

public extension ProviderReadiness {
    func artifactReady(for profile: ModelProfile) -> Bool? { nil }
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
