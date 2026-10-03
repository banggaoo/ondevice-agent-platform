import Foundation
import PlatformCore

/// In-memory console sessions: expiring HttpOnly cookie plus an in-memory
/// CSRF token. Sessions are never persisted and never contain the credential.
public actor ConsoleSessions {
    public struct Session: Sendable {
        public let id: String
        public let csrf: String
        public let expiresAt: Date
    }

    private var sessions: [String: Session] = [:]
    private var sequence = 0
    private var loginAttempts: [Date] = []
    private let clock: Clock

    public init(clock: Clock) {
        self.clock = clock
    }

    /// Sliding-window login rate limit from PlatformLimits.
    public func loginAllowed() -> Bool {
        let cutoff = clock.now.addingTimeInterval(-60)
        loginAttempts.removeAll { $0 < cutoff }
        if loginAttempts.count >= PlatformLimits.loginAttemptsPerMinute { return false }
        loginAttempts.append(clock.now)
        return true
    }

    public func create() throws -> Session {
        let cutoff = clock.now
        sessions = sessions.filter { $0.value.expiresAt > cutoff }
        guard sessions.count < PlatformLimits.consoleSessions else {
            throw PlatformError(.rateLimited)
        }
        sequence += 1
        let session = Session(
            id: "csess-\(sequence)-\(try SecretGenerator.token().prefix(16))",
            csrf: try SecretGenerator.token(),
            expiresAt: clock.now.addingTimeInterval(PlatformLimits.consoleSessionSeconds)
        )
        sessions[session.id] = session
        return session
    }

    public func lookup(_ id: String) -> Session? {
        guard let s = sessions[id], s.expiresAt > clock.now else {
            if sessions[id] != nil { sessions.removeValue(forKey: id) }
            return nil
        }
        return s
    }

    public func logout(_ id: String) {
        sessions.removeValue(forKey: id)
    }

    public func session(_ id: String, csrf: String?) -> Session? {
        guard let s = lookup(id), csrf == s.csrf else { return nil }
        return s
    }
}
