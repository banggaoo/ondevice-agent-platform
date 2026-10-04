import Foundation

/// Per-run model-output budget for a hosted agent turn. Reservations are
/// monotonic: the requested output bound is charged before the call
/// suspends and never refunded, because actual usage is unknown until the
/// provider returns. Closing a budget (turn end, cancel, deadline) rejects
/// every further reservation.
public actor AgentRunBudget {
    private var reserved = 0
    private var closed = false
    private let maxTokens: Int

    public init(maxTokens: Int = PlatformLimits.agentGeneratedTokenReservations) {
        self.maxTokens = maxTokens
    }

    public func reserveModel(_ tokens: Int) throws {
        guard !closed else { throw PlatformError(.cancelled) }
        guard tokens > 0 else {
            throw PlatformError(.invalidRequest,
                                detail: "token reservation must be positive")
        }
        // A misconfigured bound fails the reservation, never the init.
        guard maxTokens >= 0 else {
            throw PlatformError(.invalidRequest, detail: "invalid token budget")
        }
        // Subtract first: `reserved + tokens` could overflow Int.
        guard tokens <= maxTokens - reserved else {
            throw PlatformError(.capacityLimited,
                                detail: "agent token budget exhausted")
        }
        reserved += tokens
    }

    public func close() { closed = true }
}
