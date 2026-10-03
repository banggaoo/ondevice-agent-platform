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

/// Credential scopes map to fixed base grant sets. Console can read and stop
/// core state and run agents but cannot call inference directly; the model
/// scope only infers; the agent scope runs agents and consumes model/ML calls
/// inside a run, never administration.
public enum CredentialScope: String, Sendable, CaseIterable {
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

/// An authenticated caller. `id` is a nonsecret stable identifier; the token
/// material itself is never stored on the principal.
public struct Principal: Sendable, Equatable {
    public let id: String
    public let scope: CredentialScope

    public init(id: String, scope: CredentialScope) {
        self.id = id
        self.scope = scope
    }
}
