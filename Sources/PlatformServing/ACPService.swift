import Foundation
import PlatformCore

/// Lock-confined cancellation flag shared between the ACP connection actor
/// and the harness task.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}
    public func set() { lock.lock(); value = true; lock.unlock() }
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Daemon-side ACP v1 handling for one bound bridge connection. The bridge
/// binds an opaque connection ID plus agent profile at first use; a session
/// is bound to its connection and consumer and is unreachable across
/// connections even for the same consumer.
public actor ACPService {
    private struct Conn {
        let connectionID: String
        let agentID: String
        let principal: Principal
    }

    private var connections: [String: Conn] = [:]
    /// sessionID -> active runID for cancellation routing.
    private var activeRuns: [String: String] = [:]
    private var runFlags: [String: CancelFlag] = [:]
    private var runTokens: [String: CancellationToken] = [:]
    private var runBudgets: [String: AgentRunBudget] = [:]
    /// sessionID -> the setup owner currently between claim and run
    /// registration. A cancel interleaving inside that window is held in
    /// `pendingCancels` and consumed at registration, never dropped; a
    /// conflicting second prompt only removes the marker it owns.
    private var startingClaims: [String: UUID] = [:]
    private var pendingCancels: Set<String> = []
    /// Live plus quarantined runs, bounded by the connection budget: a
    /// noncooperative harness that outlives its deadline (or its
    /// connection) still occupies a slot until it actually returns.
    private var runSlots = 0
    private let supervisor: PlatformSupervisor
    private let clock: Clock
    private var sequence = 0

    public init(supervisor: PlatformSupervisor, clock: Clock) {
        self.supervisor = supervisor
        self.clock = clock
    }

    /// Bind a new bridge connection to one agent profile before any session.
    /// Rebinding a live connection to a different agent or principal is
    /// denied; total live connections are bounded.
    public func bind(connectionID: String, agentID: String,
                     principal: Principal) async throws {
        if let existing = connections[connectionID] {
            guard existing.agentID == agentID,
                  existing.principal.id == principal.id else {
                throw PlatformError(.conflict, detail: "connection already bound")
            }
            return
        }
        guard connections.count < PlatformLimits.agentConnections else {
            throw PlatformError(.capacityLimited,
                                detail: "agent connection limit reached")
        }
        let service = supervisor.agentService
        guard await service.profile(id: agentID) != nil else {
            throw PlatformError(.notFound, detail: "agent not registered")
        }
        // The profile lookup suspended: a racing bind may have inserted or
        // another caller claimed this id. Recheck before inserting.
        if let existing = connections[connectionID] {
            guard existing.agentID == agentID,
                  existing.principal.id == principal.id else {
                throw PlatformError(.conflict, detail: "connection already bound")
            }
            return
        }
        guard connections.count < PlatformLimits.agentConnections else {
            throw PlatformError(.capacityLimited,
                                detail: "agent connection limit reached")
        }
        connections[connectionID] = Conn(connectionID: connectionID,
                                       agentID: agentID, principal: principal)
    }

    /// A decoded JSON-RPC message arrives. `emit` receives response lines and
    /// streamed session/update notifications in wire order. `cancellation`,
    /// when supplied, scopes to the `session/prompt` turn only: it cancels
    /// that run directly rather than queuing a session-wide callback.
    public func handle(connectionID: String, message: JSONValue,
                       cancellation: CancellationToken? = nil,
                       emit: @escaping @Sendable (JSONValue) async -> Void) async {
        let parsed: (id: JSONValue?, method: String, params: JSONValue?, isNotification: Bool)
        do { parsed = try JSONRPC.parse(message) }
        catch {
            await emit(JSONRPC.error(id: .null, code: -32600, message: "invalid request"))
            return
        }
        guard let conn = connections[connectionID] else {
            await emit(JSONRPC.error(id: parsed.id ?? .null, code: -32600,
                                     message: "connection not bound"))
            return
        }
        switch parsed.method {
        case "initialize":
            await respond(conn: conn, id: parsed.id, isNotification: parsed.isNotification,
                          work: { try self.initializeResult(params: parsed.params) }, emit: emit)
        case "session/new":
            await respond(conn: conn, id: parsed.id, isNotification: parsed.isNotification,
                          work: { try await self.sessionNew(conn: conn, params: parsed.params) },
                          emit: emit)
        case "session/prompt":
            await respond(conn: conn, id: parsed.id, isNotification: parsed.isNotification,
                          work: { try await self.sessionPrompt(conn: conn, params: parsed.params,
                                                               cancellation: cancellation,
                                                               emit: emit) },
                          emit: emit)
        case "session/cancel":
            guard parsed.isNotification else {
                await emit(JSONRPC.error(id: parsed.id ?? .null, code: -32600,
                                         message: "cancel is a notification"))
                return
            }
            await sessionCancel(conn: conn, params: parsed.params)
        case "session/update":
            await emit(JSONRPC.error(id: parsed.id ?? .null, code: -32601,
                                     message: "method not found"))
        default:
            if parsed.isNotification { return }   // no response to notifications
            await emit(JSONRPC.error(id: parsed.id ?? .null, code: -32601,
                                     message: "method not found"))
        }
    }

    private func respond(conn: Conn, id: JSONValue?, isNotification: Bool,
                         work: () async throws -> JSONValue,
                         emit: @escaping @Sendable (JSONValue) async -> Void) async {
        if isNotification { return }   // a notification-form call gets no response
        guard let id else {
            await emit(JSONRPC.error(id: .null, code: -32600, message: "id required"))
            return
        }
        do {
            let value = try await work()
            await emit(JSONRPC.result(id: id, value: value))
        } catch let e as PlatformError {
            // The platform code rides in error.data so callers can map
            // truthful statuses; the numeric JSON-RPC code stays coarse.
            await emit(JSONRPC.error(id: id, code: rpcCode(e.code), message: e.safeMessage,
                                     data: .object(["platformCode": .string(e.code.rawValue)])))
        } catch {
            await emit(JSONRPC.error(id: id, code: -32603, message: "internal error"))
        }
    }

    private func rpcCode(_ code: ErrorCode) -> Int {
        switch code {
        case .invalidRequest, .malformedJSON, .payloadTooLarge: return -32602
        case .notFound: return -32602
        case .unauthorized, .forbidden: return -32602
        case .cancelled: return -32800
        default: return -32603
        }
    }

    // MARK: - methods

    private func initializeResult(params: JSONValue?) throws -> JSONValue {
        var requested = 1
        if let p = params?.objectValue, let v = p["protocolVersion"] {
            guard let n = v.intValue, n >= 1 else {
                throw PlatformError(.invalidRequest, detail: "protocolVersion")
            }
            requested = Int(n)
        }
        _ = requested   // draft v2 requests still negotiate v1
        return .object([
            "protocolVersion": .int(1),
            "agentCapabilities": .object([
                "loadSession": .bool(false),
                "promptCapabilities": .object([
                    "audio": .bool(false),
                    "embeddedContext": .bool(false),
                    "image": .bool(false),
                    "video": .bool(false),
                ]),
            ]),
            "authMethods": .array([]),
            "agentInfo": .object([
                "name": .string("ondevice-agent-platform"),
                "version": .string("0.1.0-m1"),
            ]),
        ])
    }

    private func sessionNew(conn: Conn, params: JSONValue?) async throws -> JSONValue {
        guard let p = params?.objectValue,
              let cwd = p["cwd"]?.stringValue, cwd.hasPrefix("/") else {
            throw PlatformError(.invalidRequest, detail: "absolute cwd required")
        }
        guard let mcp = p["mcpServers"]?.arrayValue else {
            throw PlatformError(.invalidRequest, detail: "mcpServers array required")
        }
        // M1 refuses every nonempty MCP configuration before any command,
        // path, or environment value could reach a process boundary.
        guard mcp.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "MCP servers are not supported in M1")
        }
        let session = try await supervisor.agentService.newSession(
            agentID: conn.agentID, consumerID: conn.principal.id,
            connectionID: conn.connectionID)
        return .object(["sessionId": .string(session.id)])
    }

    private func sessionPrompt(conn: Conn, params: JSONValue?,
                               cancellation: CancellationToken?,
                               emit: @escaping @Sendable (JSONValue) async -> Void) async throws -> JSONValue {
        // The turn token is the caller's own cancellation handle when
        // supplied: request abort reaches this run directly, never through
        // a deferred session-wide callback that could hit a later turn.
        let token = cancellation ?? CancellationToken()
        /// Cancelled before any agent work is still a standard result rail.
        let cancelledResult: JSONValue = .object([
            "stopReason": .string(AgentStopReason.cancelled.rawValue)])
        guard let p = params?.objectValue,
              let sessionID = p["sessionId"]?.stringValue else {
            throw PlatformError(.invalidRequest, detail: "sessionId required")
        }
        // Every check that can run before the claim does run before it, so
        // a rejected prompt never touches the session's single-turn slot.
        guard let rawBlocks = p["prompt"]?.arrayValue else {
            throw PlatformError(.invalidRequest, detail: "prompt blocks required")
        }
        var blocks: [PromptBlock] = []
        var totalText = 0
        for raw in rawBlocks {
            guard let b = raw.objectValue, let type = b["type"]?.stringValue else {
                throw PlatformError(.invalidRequest, detail: "bad block")
            }
            switch type {
            case "text":
                guard let t = b["text"]?.stringValue else {
                    throw PlatformError(.invalidRequest, detail: "text required")
                }
                totalText += t.utf8.count
                blocks.append(.text(t))
            case "resource_link":
                guard let uri = b["uri"]?.stringValue, uri.utf8.count <= 4_096 else {
                    throw PlatformError(.invalidRequest, detail: "bad resource link")
                }
                blocks.append(.resourceLink(uri: uri, name: b["name"]?.stringValue))
            default:
                throw PlatformError(.invalidRequest, detail: "unsupported block type")
            }
        }
        guard totalText <= PlatformLimits.agentPromptBytes else {
            throw PlatformError(.payloadTooLarge)
        }
        if token.isCancelled { return cancelledResult }
        try await supervisor.require(.agentRun, principal: conn.principal)
        if token.isCancelled { return cancelledResult }
        // Live and quarantined harness tasks share the connection budget;
        // reserve before the claim await and hold until the harness task
        // really ends.
        guard runSlots < PlatformLimits.agentConnections else {
            throw PlatformError(.capacityLimited, detail: "agent run limit reached")
        }
        runSlots += 1
        var slotHeld = true
        defer { if slotHeld { runSlots -= 1 } }
        // Mark the turn as starting before the claim await so a racing
        // session/cancel is recorded instead of dropped. Only this call's
        // own marker is ever removed.
        let setupClaim = UUID()
        if startingClaims[sessionID] == nil { startingClaims[sessionID] = setupClaim }
        defer {
            if startingClaims[sessionID] == setupClaim {
                startingClaims.removeValue(forKey: sessionID)
            }
        }
        // Atomic claim: binding, consumer, and the one-prompt-per-session
        // rule are checked and the active flag set in a single actor hop,
        // so a racing prompt can never interleave.
        let session = try await supervisor.agentService.beginPrompt(
            sessionID: sessionID, consumerID: conn.principal.id, connectionID: conn.connectionID)
        // Any failure before the run registers releases the claim here;
        // once registered, only the run's own teardown clears it.
        var claimHeld = true
        defer {
            if claimHeld {
                Task { await supervisor.agentService.setPromptActive(sessionID, false) }
            }
        }
        if token.isCancelled { return cancelledResult }
        let harness = try await supervisor.agentService.harness(for: session)
        if token.isCancelled { return cancelledResult }
        sequence += 1
        let runID = "run-\(sequence)"
        let flag = CancelFlag()
        let budget = AgentRunBudget()
        runFlags[runID] = flag
        runTokens[runID] = token
        runBudgets[runID] = budget
        activeRuns[sessionID] = runID
        claimHeld = false
        // The setup window ends at registration: later cancels hit the
        // active-runs path and can never poison a future turn.
        if startingClaims[sessionID] == setupClaim {
            startingClaims.removeValue(forKey: sessionID)
        }
        // A cancel that raced the setup window applies immediately.
        if pendingCancels.remove(session.id) != nil {
            flag.set()
            token.cancel()
            await budget.close()
        }

        let supervisorRef = supervisor
        let boundAlias = session.profile.modelProfileAlias
        let context = AgentContext(
            sessionID: sessionID, runID: runID,
            statusSnapshot: { await supervisorRef.statusSnapshot() },
            model: ModelClient { request in
                if token.isCancelled { throw PlatformError(.cancelled) }
                // A bound profile pins the model alias: a harness cannot
                // reach a different route through its scoped client.
                if let boundAlias, request.model != boundAlias {
                    throw PlatformError(.invalidRequest,
                                        detail: "model not bound to this agent")
                }
                // Reserve the effective bound: an omitted limit resolves to
                // the profile ceiling before the reservation, same rule the
                // supervisor applies at admission.
                let profileCap = await supervisorRef.registeredModels(kind: .llm)
                    .first { $0.alias == request.model }?.maxOutputTokens
                let bound = request.resolvingDefaultOutputTokens(to: profileCap)
                    .maxOutputTokens
                try await budget.reserveModel(bound)
                if token.isCancelled { throw PlatformError(.cancelled) }
                return try await supervisorRef.submitLLM(
                    principal: conn.principal, request: request,
                    parentID: runID, cancellation: token)
            },
            ml: MLClient { request in
                if token.isCancelled { throw PlatformError(.cancelled) }
                return try await supervisorRef.submitML(
                    principal: conn.principal, request: request,
                    parentID: runID, cancellation: token)
            },
            isCancelled: { flag.isSet || token.isCancelled }
        )
        let queue = EmissionQueue()
        let (stop, orphanedHarness) = await runWithDeadline(
            runID: runID, session: session, harness: harness, blocks: blocks,
            context: context, flag: flag, token: token, budget: budget,
            emit: emit, queue: queue)
        // No more emissions are accepted; the run is terminal so every
        // later event and every retained-context call is gated off before
        // the result goes out. Already-queued chunks still flush.
        queue.close()
        flag.set()
        token.cancel()
        await budget.close()
        await supervisor.cancelChildren(parentID: runID)
        await queue.drain()
        // Ownership of the slot moves to runEnded from here on: the defer
        // only covers failures before the run registered.
        slotHeld = false
        if let orphanedHarness {
            // Terminal was reported on timeout while the harness task is
            // still alive: keep the session claimed, the run's state, and
            // the slot until real harness completion, then release.
            Task {
                _ = await orphanedHarness.value
                await self.runEnded(runID: runID, sessionID: sessionID)
            }
        } else {
            await runEnded(runID: runID, sessionID: sessionID)
        }
        // Turn failures are JSON-RPC errors, never a fabricated stop reason
        // (`error` is not a valid ACP stopReason): a quarantined deadline is
        // a deadline error rather than a claimed cancellation, and internal
        // or overflow outcomes surface as provider failure. Real client
        // cancellation still answers `cancelled`; end_turn, max_tokens, and
        // refusal ride the normal result rail.
        if orphanedHarness != nil {
            throw PlatformError(.deadlineExceeded, detail: "agent turn deadline")
        }
        if queue.overflowed || stop == .error {
            throw PlatformError(.providerUnavailable, detail: "agent turn failed")
        }
        return .object(["stopReason": .string(stop.rawValue)])
    }

    /// Run teardown: only the owning run releases the session claim - a
    /// recycled or quarantined run must never clear another turn, and a
    /// stale teardown must never free a slot twice. The claim binding and
    /// the run's own maps are detached and cancelled synchronously before
    /// any suspension, so no interleaving can make this run clear a newer
    /// turn or skip the cancellation reap.
    private func runEnded(runID: String, sessionID: String) async {
        let flag = runFlags.removeValue(forKey: runID)
        let token = runTokens.removeValue(forKey: runID)
        let budget = runBudgets.removeValue(forKey: runID)
        guard flag != nil || token != nil || budget != nil else {
            return   // already reaped: no second slot release
        }
        let heldClaim = activeRuns[sessionID] == runID
        if heldClaim { activeRuns.removeValue(forKey: sessionID) }
        flag?.set()
        token?.cancel()
        runSlots -= 1
        if heldClaim {
            await supervisor.agentService.setPromptActive(sessionID, false)
        }
        await budget?.close()
    }

    /// Live plus quarantined harness runs; test-visible occupancy.
    public func liveRunCount() -> Int { runSlots }

    /// Race the harness against the run deadline through a one-shot result
    /// actor. On timeout the caller is answered a deadline error while the
    /// harness task is cancelled and kept quarantined: the session stays
    /// busy and no slot is released until the task actually finishes.
    /// Returns the stop reason plus the live harness task when it outlived
    /// the response.
    private func runWithDeadline(runID: String, session: AgentSession,
                                 harness: any AgentHarness, blocks: [PromptBlock],
                                 context: AgentContext, flag: CancelFlag,
                                 token: CancellationToken, budget: AgentRunBudget,
                                 emit: @escaping @Sendable (JSONValue) async -> Void,
                                 queue: EmissionQueue)
        async -> (AgentStopReason, Task<AgentStopReason, Never>?) {
        let emitter: @Sendable (AgentEvent) -> Void = { [queue, flag, token] event in
            // Terminal intent gates emissions off: a late chunk after cancel
            // or timeout can never reach the client.
            guard !flag.isSet, !token.isCancelled else { return }
            switch event {
            case .messageChunk(let text):
                let note = JSONRPC.notification(
                    method: "session/update",
                    params: .object([
                        "sessionId": .string(session.id),
                        "update": .object([
                            "sessionUpdate": .string("agent_message_chunk"),
                            "content": .object(["type": .string("text"), "text": .string(text)]),
                        ]),
                    ]))
                queue.enqueue { await emit(note) }
            case .note:
                break
            }
        }
        let race = RunRace()
        let harnessTask = Task {
            await harness.run(input: blocks, context: context, emit: emitter)
        }
        let watcher = Task {
            let stop = await harnessTask.value
            await race.fire(.harness(stop))
        }
        let clockRef = clock
        let deadlineTask = Task {
            try? await clockRef.sleep(PlatformLimits.agentDeadlineSeconds)
            await race.fire(.deadline)
        }
        let outcome = await race.wait()
        deadlineTask.cancel()
        watcher.cancel()
        switch outcome {
        case .harness(let stop):
            return (stop, nil)
        case .deadline:
            flag.set()
            token.cancel()
            await budget.close()
            await supervisor.cancelChildren(parentID: runID)
            harnessTask.cancel()
            return (.cancelled, harnessTask)
        }
    }

    private func sessionCancel(conn: Conn, params: JSONValue?) async {
        guard let p = params?.objectValue,
              let sessionID = p["sessionId"]?.stringValue else { return }
        guard let session = await supervisor.agentService.session(
            sessionID, consumerID: conn.principal.id, connectionID: conn.connectionID) else { return }
        if let runID = activeRuns[session.id] {
            runFlags[runID]?.set()
            runTokens[runID]?.cancel()
            await runBudgets[runID]?.close()
            await supervisor.cancelChildren(parentID: runID)
        } else if startingClaims[session.id] != nil {
            pendingCancels.insert(session.id)
        }
    }

    /// Connection teardown: owned sessions close and active runs cancel.
    public func connectionClosed(_ connectionID: String) async {
        let sessions = await supervisor.agentService.closeConnection(connectionID)
        for s in sessions {
            if let runID = activeRuns[s.id] {
                runFlags[runID]?.set()
                runTokens[runID]?.cancel()
                await runBudgets[runID]?.close()
                await supervisor.cancelChildren(parentID: runID)
            } else if startingClaims[s.id] != nil {
                // A prompt still in setup when the connection died must be
                // cancelled at registration, not orphaned.
                pendingCancels.insert(s.id)
            }
            activeRuns.removeValue(forKey: s.id)
        }
        connections.removeValue(forKey: connectionID)
    }

    public func connectionCount() -> Int { connections.count }
}

/// Deterministic serialized emission queue: a chunk reserves its slot under
/// the lock before hopping to a task, so wire order is exactly emit order
/// and the prompt result can never overtake its own notifications. The
/// bound counts outstanding work - each unit decrements when it finishes -
/// so a slow sender caps the backlog, while a healthy one drains freely.
/// A refused enqueue sets `overflowed`: the run must surface that as an
/// error, never as a silently truncated answer.
final class EmissionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var closed = false
    private var outstanding = 0
    private let bound: Int
    private var didOverflow = false

    /// True only when healthy work was refused at the bound; a late enqueue
    /// after close is a quiet drop, not an overflow.
    var overflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }

    init(bound: Int = 64) { self.bound = bound }

    /// Reserve a serialized slot and run `work` after everything already
    /// queued. Returns false when the queue is closed (quietly) or full
    /// (recorded as overflow).
    @discardableResult
    func enqueue(_ work: @escaping @Sendable () async -> Void) -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        guard outstanding < bound else {
            didOverflow = true
            lock.unlock()
            return false
        }
        outstanding += 1
        let prev = tail
        let next = Task { [weak self] in
            await prev?.value
            await work()
            self?.finished()
        }
        tail = next
        lock.unlock()
        return true
    }

    private func finished() {
        lock.lock()
        outstanding -= 1
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// Await every emission already enqueued; nothing enqueues after close.
    func drain() async {
        let last: Task<Void, Never>? = {
            lock.lock()
            defer { lock.unlock() }
            return tail
        }()
        await last?.value
    }
}

/// One-shot race between the harness task and the run deadline: the first
/// outcome wins, later results are dropped, and the waiter never blocks on
/// the loser.
private actor RunRace {
    enum Outcome {
        case harness(AgentStopReason)
        case deadline
    }

    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func fire(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume(returning: outcome) }
    }

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
