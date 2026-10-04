import Foundation

/// Harness outcomes. `error` is internal and must use JSON-RPC's error rail,
/// not an unsupported ACP stop reason.
public enum AgentStopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case refusal
    case cancelled
    case error
}

/// Typed events a harness may emit; streamed to the client as session/update.
public enum AgentEvent: Sendable {
    case messageChunk(String)
    case note(String)
}

/// Scoped context handed to a harness. It exposes a status snapshot, the
/// scoped model/ML clients, and cancellation - never a direct Supervisor,
/// database, or admin reference.
public struct AgentContext: Sendable {
    public let sessionID: String
    public let runID: String
    public let statusSnapshot: @Sendable () async -> JSONValue
    public let model: ModelClient
    public let ml: MLClient
    public let isCancelled: @Sendable () -> Bool

    public init(sessionID: String, runID: String,
                statusSnapshot: @escaping @Sendable () async -> JSONValue,
                model: ModelClient, ml: MLClient,
                isCancelled: @escaping @Sendable () -> Bool) {
        self.sessionID = sessionID
        self.runID = runID
        self.statusSnapshot = statusSnapshot
        self.model = model
        self.ml = ml
        self.isCancelled = isCancelled
    }
}

/// Prompt content accepted in M1: text blocks plus resource links carried as
/// bounded metadata (never fetched or read locally). Richer types are refused.
public enum PromptBlock: Sendable, Equatable {
    case text(String)
    case resourceLink(uri: String, name: String?)
}

/// Versioned harness contract. Deterministic steps may complete with zero
/// model calls; model steps are explicit and budgeted.
public protocol AgentHarness: Sendable {
    static var id: String { get }
    static var version: Int { get }
    func run(input: [PromptBlock], context: AgentContext,
             emit: @escaping @Sendable (AgentEvent) -> Void) async -> AgentStopReason
}

/// Scoped model client for harnesses: submits through the same validation
/// and core admission as external callers - no SDK bypass.
public struct ModelClient: Sendable {
    private let submit: @Sendable (ChatRequest) async throws -> ChatResult

    public init(_ submit: @escaping @Sendable (ChatRequest) async throws -> ChatResult) {
        self.submit = submit
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResult {
        try await submit(request)
    }
}

public struct MLClient: Sendable {
    private let submit: @Sendable (PredictionRequest) async throws -> PredictionResult

    public init(_ submit: @escaping @Sendable (PredictionRequest) async throws -> PredictionResult) {
        self.submit = submit
    }

    public func predict(_ request: PredictionRequest) async throws -> PredictionResult {
        try await submit(request)
    }
}
