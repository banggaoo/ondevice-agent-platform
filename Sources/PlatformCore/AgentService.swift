import Foundation

/// A live ACP-bound agent session. Profile and harness versions are pinned at
/// creation; registering a newer version affects only new sessions.
public struct AgentSession: Sendable {
    public let id: String
    public let profile: AgentProfile
    public let consumerID: String
    public let connectionID: String
    public let createdAt: Date
    public var promptActive: Bool

    public init(id: String, profile: AgentProfile, consumerID: String,
                connectionID: String, createdAt: Date, promptActive: Bool = false) {
        self.id = id
        self.profile = profile
        self.consumerID = consumerID
        self.connectionID = connectionID
        self.createdAt = createdAt
        self.promptActive = promptActive
    }
}

/// Hosted-agent runtime. Sessions are bound to a single connection and
/// consumer; a session is not accessible from any other connection, even for
/// the same consumer. Registered implementations are reviewed, compiled-in
/// code resolved by reference name - never arbitrary path loading.
public actor AgentService {
    public struct HarnessEntry: Sendable {
        public let make: @Sendable () -> any AgentHarness
        public let harnessID: String
        public let harnessVersion: Int
    }

    private var profiles: [String: AgentProfile] = [:]          // id -> latest registered
    private var versions: [String: [Int: AgentProfile]] = [:]   // id -> version -> profile
    private var harnesses: [String: HarnessEntry] = [:]         // implementationRef
    private var sessions: [String: AgentSession] = [:]
    private var sequence = 0
    private let clock: Clock
    var cancelledRuns: Set<String> = []

    public init(clock: Clock) {
        self.clock = clock
    }

    /// Register reviewed implementation code plus its profile metadata.
    public func register(profile: AgentProfile, harness: HarnessEntry) {
        versions[profile.id, default: [:]][profile.version] = profile
        profiles[profile.id] = profile
        harnesses[profile.implementationRef] = harness
    }

    public func registerBuiltInReference() {
        register(
            profile: AgentProfile(
                id: "reference.status", version: 1,
                harnessID: ReferenceStatusHarness.id,
                harnessVersion: ReferenceStatusHarness.version,
                stateSchemaVersion: 1,
                toolScope: [], modelProfileAlias: nil,
                implementationRef: "builtin:reference.status"
            ),
            harness: HarnessEntry(
                make: { ReferenceStatusHarness() },
                harnessID: ReferenceStatusHarness.id,
                harnessVersion: ReferenceStatusHarness.version
            )
        )
    }

    public func profileIDs() -> [String] { profiles.keys.sorted() }

    public func profile(id: String) -> AgentProfile? { profiles[id] }

    /// Bind a new session to one connection/consumer and the newest profile.
    public func newSession(agentID: String, consumerID: String,
                           connectionID: String) throws -> AgentSession {
        guard let profile = profiles[agentID], harnesses[profile.implementationRef] != nil else {
            throw PlatformError(.notFound, detail: "agent not registered")
        }
        sequence += 1
        let session = AgentSession(
            id: "sess-\(sequence)", profile: profile,
            consumerID: consumerID, connectionID: connectionID,
            createdAt: clock.now
        )
        sessions[session.id] = session
        return session
    }

    /// Sessions are bound to their connection; no cross-connection access.
    public func session(_ id: String, consumerID: String,
                        connectionID: String) -> AgentSession? {
        guard let s = sessions[id],
              s.consumerID == consumerID,
              s.connectionID == connectionID else { return nil }
        return s
    }

    public func harness(for session: AgentSession) throws -> any AgentHarness {
        guard let entry = harnesses[session.profile.implementationRef] else {
            throw PlatformError(.providerUnavailable, detail: "harness missing")
        }
        return entry.make()
    }

    public func markCancelled(runID: String) { cancelledRuns.insert(runID) }
    public func isCancelled(runID: String) -> Bool { cancelledRuns.contains(runID) }
    public func clearRun(runID: String) { cancelledRuns.remove(runID) }

    public func setPromptActive(_ sessionID: String, _ active: Bool) {
        sessions[sessionID]?.promptActive = active
    }

    /// Disconnect semantics: owned sessions of a connection are closed; their
    /// child work is cancelled by the caller via the supervisor.
    public func closeConnection(_ connectionID: String) -> [AgentSession] {
        let owned = sessions.values.filter { $0.connectionID == connectionID }
        for s in owned { sessions.removeValue(forKey: s.id) }
        return owned.sorted { $0.id < $1.id }
    }

    public func closeAll() {
        sessions.removeAll()
        cancelledRuns.removeAll()
    }
}
