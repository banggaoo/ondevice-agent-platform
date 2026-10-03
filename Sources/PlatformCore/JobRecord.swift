import Foundation

public enum JobKind: String, Sendable, Codable {
    case llm
    case ml
}

public enum JobState: String, Sendable, Codable {
    case queued
    case active
    case cancelRequested = "cancel_requested"
    case completed
    case failed
    case cancelled
    case cancellationUnconfirmed = "cancellation_unconfirmed"
    case interrupted   // set on restart for unfinished rows; never replayed
}

/// Content-free durable job record. No prompts, outputs, or credentials.
public struct JobRecord: Sendable, Equatable {
    public let id: String
    public let kind: JobKind
    public let consumerID: String
    public let parentID: String?
    public var state: JobState
    public let createdAt: Date
    public var updatedAt: Date
    /// Whether the underlying provider unit confirmed termination.
    public var providerFinished: Bool

    public init(id: String, kind: JobKind, consumerID: String, parentID: String?,
                state: JobState = .queued, createdAt: Date, updatedAt: Date,
                providerFinished: Bool = false) {
        self.id = id
        self.kind = kind
        self.consumerID = consumerID
        self.parentID = parentID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerFinished = providerFinished
    }

    public var isTerminal: Bool {
        switch state {
        case .completed, .failed, .cancelled, .cancellationUnconfirmed, .interrupted:
            return true
        case .queued, .active, .cancelRequested:
            return false
        }
    }
}
