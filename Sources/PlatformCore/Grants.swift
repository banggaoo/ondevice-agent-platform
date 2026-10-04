import Foundation

/// Scoped capabilities. Grant checks happen before provider work, at queued
/// dispatch, and at every child step; capabilities or prompt text never add
/// scope.
public enum Grant: String, Sendable, Codable, CaseIterable {
    case adminRead
    case adminStop
    case llmInfer
    case mlPredict
    case agentRun
    case agentStatusRead
}

/// Consumer scopes map to fixed base grant sets. These are internal
/// code-owned permissions, not OS-user authentication: console can read and
/// stop core state and run agents but cannot call inference directly; the
/// model scope only infers; the agent scope runs agents and consumes
/// model/ML calls inside a run, never administration.
public enum ConsumerScope: String, Sendable, CaseIterable {
    case console
    case model
    case agent

    public var baseGrants: Set<Grant> {
        switch self {
        case .console: return [.adminRead, .adminStop, .agentRun, .agentStatusRead]
        case .model: return [.llmInfer, .mlPredict]
        case .agent: return [.agentRun, .agentStatusRead, .llmInfer, .mlPredict]
        }
    }
}

/// A code-owned consumer identity. `id` is a nonsecret stable identifier;
/// the platform issues no tokens, so nothing secret is ever attached to a
/// principal.
public struct Principal: Sendable, Equatable {
    public let id: String
    public let scope: ConsumerScope

    public init(id: String, scope: ConsumerScope) {
        self.id = id
        self.scope = scope
    }
}

/// The fixed local-trust consumers. Every loopback route binds to one of
/// these identities rather than authenticating the caller: request headers,
/// body fields, and user metadata never select a principal. The user runs
/// the platform on their own device; no API tokens exist to copy or leak.
public enum LocalConsumers {
    /// Model API routes (`/v1/models`, chat completions, typed ML).
    public static let model = Principal(id: "local-model", scope: .model)
    /// Private ACP bridge consumer for hosted-agent turns.
    public static let agent = Principal(id: "local-agent", scope: .agent)
    /// Administrative reads and local job cancellation.
    public static let administration = Principal(id: "local-admin", scope: .console)
}
