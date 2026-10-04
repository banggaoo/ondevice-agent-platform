import Foundation
import PlatformCore

/// Console-only bridge to the opt-in read-only runtime Operator. It reuses
/// the shared ACP service - the same admission, claiming, and cancellation
/// machinery the local bridge transport uses - under a fixed
/// non-secret console consumer that holds only agentRun/agentStatusRead/
/// llmInfer. It is not a public agent-serving protocol, accepts only a
/// bounded `{"text": ...}` body, and never exposes credentials, tool
/// selection, model selection, cwd, or configuration to the browser.
public actor ConsoleOperatorBridge {
    /// One browser-side console session's live ACP binding. The opaque
    /// connection id is generated per binding and is never a cookie, CSRF,
    /// or any client-supplied value.
    private struct Binding: Sendable {
        let connectionID: String
        let acpSessionID: String
        let profile: AgentProfile
        let expiresAt: Date
    }

    /// Lock-confined wire collector: notifications accumulate bounded text;
    /// the request's own response is captured by id. Emissions arriving
    /// after settle are dropped.
    private final class TurnCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [String] = []
        private var responses: [JSONValue] = []
        private var textBytes = 0
        private var overflowed = false

        /// Bound update count and joined text so a misbehaving turn cannot
        /// grow memory unboundedly.
        private let maxUpdates = 1_024
        private let maxTextBytes = 1 << 20

        func append(_ value: JSONValue) {
            lock.lock()
            defer { lock.unlock() }
            if value.objectValue?["method"]?.stringValue == "session/update" {
                guard updates.count < maxUpdates else {
                    overflowed = true
                    return
                }
                if let text = value.objectValue?["params"]?.objectValue?["update"]?
                    .objectValue?["content"]?.objectValue?["text"]?.stringValue {
                    textBytes += text.utf8.count
                    if textBytes > maxTextBytes {
                        overflowed = true
                        return
                    }
                    updates.append(text)
                }
                return
            }
            responses.append(value)
        }

        var didOverflow: Bool {
            lock.lock()
            defer { lock.unlock() }
            return overflowed
        }

        /// The response carrying this request id, if one arrived.
        func response(id: JSONValue) -> JSONValue? {
            lock.lock()
            defer { lock.unlock() }
            return responses.first { $0.objectValue?["id"] == id }
        }

        var joinedText: String {
            lock.lock()
            defer { lock.unlock() }
            return updates.joined()
        }
    }

    private let acp: ACPService
    private let supervisor: PlatformSupervisor
    private let sessions: ConsoleSessions
    private let clock: Clock
    private let principal: Principal?
    private var bindings: [String: Binding] = [:]            // console cookie id -> binding
    private var creations: [String: Task<Binding, Error>] = [:]
    private var creationCancels: [String: CancelFlag] = [:]
    private var turnOwners: Set<String> = []                  // console cookie ids mid-turn
    private var requestSequence = 0
    private var reaperTask: Task<Void, Never>?
    private var reaperStarted = false

    /// Test seam: runs inside a binding creation right before the final
    /// session/lease revalidation, deterministically forcing a
    /// create-vs-logout race.
    private var _testBeforeCommit: (@Sendable () async -> Void)?

    /// Test-seam setter (actor-isolated property; not for production use).
    func _testSetBeforeCommit(_ hook: (@Sendable () async -> Void)?) {
        _testBeforeCommit = hook
    }

    public init(acp: ACPService, supervisor: PlatformSupervisor,
                sessions: ConsoleSessions, clock: Clock, principal: Principal?) {
        self.acp = acp
        self.supervisor = supervisor
        self.sessions = sessions
        self.clock = clock
        self.principal = principal
    }

    /// Expired bindings are reaped on the shared resource cadence once the
    /// bridge is actually used; only an enabled Operator keeps the loop
    /// alive. Weak self + task cancellation leave no retain cycle.
    private func startReaperIfNeeded() {
        guard !reaperStarted, principal != nil else { return }
        reaperStarted = true
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(PlatformLimits.resourceSampleSeconds))
                guard !Task.isCancelled else { return }
                await self?.reapExpired()
            }
        }
    }

    /// Console cookie id for the current turn's binding, or nil while the
    /// browser has not asked a question yet. Exposed for diagnostics only.
    public func boundConnectionCount() -> Int { bindings.count }

    /// The shared reply shape: pinned Operator metadata plus whatever the
    /// turn produced - empty text when cancellation arrived before any
    /// model submission.
    private static func reply(model: String?, text: String,
                              stopReason: String) -> JSONValue {
        .object([
            "agent": .string("operator"),
            "model": model.map { .string($0) } ?? .null,
            "text": .string(text),
            "stopReason": .string(stopReason),
        ])
    }

    /// Answer one Operator question. The caller has already enforced the
    /// cookie mutation checks; this layer validates the body, the binding,
    /// one active turn per console session, and truthful error mapping.
    /// Request cancellation is scoped to this turn: it rides into the ACP
    /// prompt call directly, so an abort can never target a later turn
    /// that reuses the session.
    public func prompt(consoleSession: ConsoleSessions.Session,
                       body: Data,
                       cancellation: CancellationToken) async throws -> JSONValue {
        guard let principal else {
            throw PlatformError(.providerUnavailable,
                                detail: "operator is not enabled")
        }
        startReaperIfNeeded()
        let text = try parseBody(body)
        if cancellation.isCancelled {
            let profile = await supervisor.agentService.profile(id: "operator")
            return Self.reply(model: profile?.modelProfileAlias, text: "",
                              stopReason: "cancelled")
        }
        let binding = try await binding(for: consoleSession, principal: principal)
        if cancellation.isCancelled {
            return Self.reply(model: binding.profile.modelProfileAlias,
                              text: "", stopReason: "cancelled")
        }
        let cookieID = consoleSession.id
        guard !turnOwners.contains(cookieID) else {
            throw PlatformError(.conflict, detail: "a question is already running")
        }
        turnOwners.insert(cookieID)
        defer { turnOwners.remove(cookieID) }

        requestSequence += 1
        let promptID = "op-\(requestSequence)"
        let collector = TurnCollector()
        // Turn-scoped cancellation: the request token is this run's token.
        // A session/cancel or deadline cancels it; an abort reaches the
        // run directly with no deferred callback. Exactly one prompt call.
        await acp.handle(connectionID: binding.connectionID,
                         message: JSONRPC.request(
            id: .string(promptID), method: "session/prompt",
            params: .object([
                "sessionId": .string(binding.acpSessionID),
                "prompt": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
            ])), cancellation: cancellation) { value in
            collector.append(value)
        }
        guard let response = collector.response(id: .string(promptID)) else {
            throw PlatformError(.providerUnavailable, detail: "no agent response")
        }
        if let error = response.objectValue?["error"]?.objectValue {
            throw Self.rpcError(error)
        }
        guard !collector.didOverflow else {
            throw PlatformError(.providerUnavailable, detail: "response overflow")
        }
        let stop = response.objectValue?["result"]?.objectValue?["stopReason"]?
            .stringValue ?? "error"
        return Self.reply(model: binding.profile.modelProfileAlias,
                          text: collector.joinedText, stopReason: stop)
    }

    /// Close the binding owned by a console session (logout or expiry).
    /// A binding still in creation is marked cancelled; its late-created
    /// ACP connection is closed instead of resurrecting.
    public func connectionClosed(forSession cookieID: String) async {
        creationCancels[cookieID]?.set()
        if let binding = bindings.removeValue(forKey: cookieID) {
            await acp.connectionClosed(binding.connectionID)
        }
    }

    /// Drop bindings whose console session expired.
    private func reapExpired() async {
        let now = clock.now
        let expired = bindings.filter { $0.value.expiresAt <= now }.map(\.key)
        for cookieID in expired {
            await connectionClosed(forSession: cookieID)
        }
    }



    /// Exact `{"text": String}` contract: unknown keys, non-string text,
    /// blank text, and oversized bodies are refused before any agent work.
    private func parseBody(_ body: Data) throws -> String {
        guard let object = (try? JSONValue.decode(body))?.objectValue,
              object.count == 1, let text = object["text"]?.stringValue else {
            throw PlatformError(.invalidRequest, detail: "expected {\"text\": \"...\"}")
        }
        guard text.utf8.count <= PlatformLimits.agentPromptBytes else {
            throw PlatformError(.payloadTooLarge)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlatformError(.invalidRequest, detail: "empty question")
        }
        return text
    }

    /// Existing binding or the shared in-flight creation for this console
    /// session; concurrent questions never create two ACP connections. The
    /// live ConsoleSessions lookup is authoritative: a logged-out or
    /// expired cookie neither reuses nor creates a binding.
    private func binding(for session: ConsoleSessions.Session,
                         principal: Principal) async throws -> Binding {
        guard let live = await sessions.lookup(session.id),
              live.csrf == session.csrf else {
            throw PlatformError(.sessionClosed, detail: "console session ended")
        }
        if let existing = bindings[session.id], existing.expiresAt > clock.now {
            return existing
        }
        if let pending = creations[session.id] {
            // Every waiter receives the shared task's validated, committed
            // outcome - never the raw creation result.
            return try await pending.value
        }
        if bindings.count >= PlatformLimits.consoleSessions {
            // Try to free an expired seat before refusing.
            await reapExpired()
            guard bindings.count < PlatformLimits.consoleSessions else {
                throw PlatformError(.capacityLimited, detail: "operator session limit")
            }
        }
        let lease = CancelFlag()
        creationCancels[session.id] = lease
        let task = Task { [weak self] in
            guard let self else { throw PlatformError(.providerUnavailable) }
            return try await self.createAndCommitBinding(session: session,
                                                         principal: principal,
                                                         lease: lease)
        }
        creations[session.id] = task
        return try await task.value
    }

    /// Shared creation commit, run inside the stored task: validates the
    /// cancel lease and the still-live console session after the last
    /// await before publishing, and closes the fresh ACP connection when
    /// the commit is invalid so a raced logout or expiry cannot resurrect.
    /// Owns the creations/creationCancels cleanup on settle.
    private func createAndCommitBinding(session: ConsoleSessions.Session,
                                        principal: Principal,
                                        lease: CancelFlag) async throws -> Binding {
        defer {
            creations.removeValue(forKey: session.id)
            creationCancels.removeValue(forKey: session.id)
        }
        let created = try await createBinding(session: session,
                                              principal: principal)
        await _testBeforeCommit?()
        let live = await sessions.lookup(session.id)
        guard !lease.isSet,
              live?.id == session.id, live?.csrf == session.csrf,
              live?.expiresAt == session.expiresAt,
              created.expiresAt > clock.now else {
            await acp.connectionClosed(created.connectionID)
            throw PlatformError(.sessionClosed, detail: "console session ended")
        }
        bindings[session.id] = created
        return created
    }

    /// Bind a fresh opaque connection, initialize, and open one pinned ACP
    /// session. The agent profile is captured at bind time so the turn's
    /// reported model metadata can never drift mid-binding.
    private func createBinding(session: ConsoleSessions.Session,
                               principal: Principal) async throws -> Binding {
        guard let profile = await supervisor.agentService.profile(id: "operator") else {
            throw PlatformError(.providerUnavailable, detail: "operator not registered")
        }
        let connectionID = "console-op-\(UUID().uuidString)"
        let collector = TurnCollector()
        try await acp.bind(connectionID: connectionID, agentID: "operator",
                           principal: principal)
        do {
            await acp.handle(connectionID: connectionID, message: JSONRPC.request(
                id: .string("op-init"), method: "initialize",
                params: .object([
                    "protocolVersion": .int(1),
                    "clientCapabilities": .object([:]),
                ]))) { collector.append($0) }
            if let error = collector.response(id: .string("op-init"))?
                .objectValue?["error"]?.objectValue {
                throw Self.rpcError(error)
            }
            await acp.handle(connectionID: connectionID, message: JSONRPC.request(
                id: .string("op-new"), method: "session/new",
                params: .object([
                    "cwd": .string("/"),
                    "mcpServers": .array([]),
                ]))) { collector.append($0) }
            let reply = collector.response(id: .string("op-new"))
            if let error = reply?.objectValue?["error"]?.objectValue {
                throw Self.rpcError(error)
            }
            guard let acpSessionID = reply?.objectValue?["result"]?
                .objectValue?["sessionId"]?.stringValue else {
                throw PlatformError(.providerUnavailable, detail: "no agent session")
            }
            return Binding(connectionID: connectionID, acpSessionID: acpSessionID,
                           profile: profile, expiresAt: session.expiresAt)
        } catch {
            await acp.connectionClosed(connectionID)
            throw error
        }
    }

    /// Map an ACP JSON-RPC error to a truthful platform error: the embedded
    /// platform code wins; an unlabeled failure is provider-unavailable.
    private static func rpcError(_ error: [String: JSONValue]) -> PlatformError {
        if let raw = error["data"]?.objectValue?["platformCode"]?.stringValue,
           let code = ErrorCode(rawValue: raw) {
            return PlatformError(code)
        }
        return PlatformError(.providerUnavailable)
    }
}
