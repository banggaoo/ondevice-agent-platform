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
    /// A cancel can interleave while `session/prompt` is still in setup
    /// (before the run is registered); it is held here and consumed at
    /// registration so it can never be dropped. A cancel that arrives with no
    /// active or starting turn stays a no-op per the notification contract.
    private var startingSessions: Set<String> = []
    private var pendingCancels: Set<String> = []
    private let supervisor: PlatformSupervisor
    private let clock: Clock
    private var sequence = 0

    public init(supervisor: PlatformSupervisor, clock: Clock) {
        self.supervisor = supervisor
        self.clock = clock
    }

    /// Bind a new bridge connection to one agent profile before any session.
    /// Rebinding a live connection to a different agent is denied.
    public func bind(connectionID: String, agentID: String,
                     principal: Principal) async throws {
        if let existing = connections[connectionID] {
            guard existing.agentID == agentID else {
                throw PlatformError(.conflict, detail: "connection already bound")
            }
            return
        }
        let service = supervisor.agentService
        guard await service.profile(id: agentID) != nil else {
            throw PlatformError(.notFound, detail: "agent not registered")
        }
        connections[connectionID] = Conn(connectionID: connectionID,
                                       agentID: agentID, principal: principal)
    }

    /// A decoded JSON-RPC message arrives. `emit` receives response lines and
    /// streamed session/update notifications in wire order.
    public func handle(connectionID: String, message: JSONValue,
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
            await emit(JSONRPC.error(id: id, code: rpcCode(e.code), message: e.safeMessage))
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
                               emit: @escaping @Sendable (JSONValue) async -> Void) async throws -> JSONValue {
        guard let p = params?.objectValue,
              let sessionID = p["sessionId"]?.stringValue else {
            throw PlatformError(.invalidRequest, detail: "sessionId required")
        }
        // Mark the turn as starting before any suspension point so a racing
        // session/cancel is recorded instead of dropped.
        startingSessions.insert(sessionID)
        defer { startingSessions.remove(sessionID) }
        guard let session = await supervisor.agentService.session(
            sessionID, consumerID: conn.principal.id, connectionID: conn.connectionID) else {
            throw PlatformError(.sessionClosed)
        }
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
        try await supervisor.require(.agentRun, principal: conn.principal)
        let harness = try await supervisor.agentService.harness(for: session)
        sequence += 1
        let runID = "run-\(sequence)"
        let flag = CancelFlag()
        runFlags[runID] = flag
        activeRuns[sessionID] = runID
        // The setup window ends at registration: later cancels hit the
        // active-runs path and can never poison a future turn.
        startingSessions.remove(sessionID)
        // A cancel that raced the setup window applies immediately.
        if pendingCancels.remove(session.id) != nil {
            flag.set()
        }
        await supervisor.agentService.setPromptActive(sessionID, true)
        defer {
            Task {
                await self.runEnded(runID: runID, sessionID: sessionID)
            }
        }

        let supervisorRef = supervisor
        let context = AgentContext(
            sessionID: sessionID, runID: runID,
            statusSnapshot: { await supervisorRef.statusSnapshot() },
            model: ModelClient { request in
                try await supervisorRef.submitLLM(principal: conn.principal,
                                                request: request, parentID: runID)
            },
            ml: MLClient { request in
                try await supervisorRef.submitML(principal: conn.principal,
                                                 request: request, parentID: runID)
            },
            isCancelled: { flag.isSet }
        )
        let pending = EmissionTracker()
        let stop = await runWithDeadline(runID: runID, session: session,
                                         harness: harness, blocks: blocks,
                                         context: context, flag: flag, emit: emit,
                                         pending: pending)
        // Update notifications are emitted before the prompt result, never
        // after the response stream closes.
        await pending.drain()
        return .object(["stopReason": .string(stop.rawValue)])
    }

    private func runEnded(runID: String, sessionID: String) async {
        await supervisor.agentService.setPromptActive(sessionID, false)
        runFlags.removeValue(forKey: runID)
        activeRuns.removeValue(forKey: sessionID)
    }

    private func runWithDeadline(runID: String, session: AgentSession,
                                 harness: any AgentHarness, blocks: [PromptBlock],
                                 context: AgentContext, flag: CancelFlag,
                                 emit: @escaping @Sendable (JSONValue) async -> Void,
                                 pending: EmissionTracker) async -> AgentStopReason {
        let emitter: @Sendable (AgentEvent) -> Void = { [pending] event in
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
                Task { await pending.begin()
                    await emit(note)
                    await pending.end()
                }
            case .note:
                break
            }
        }
        let deadline = PlatformLimits.agentDeadlineSeconds
        let clockRef = clock
        return await withTaskGroup(of: AgentStopReason?.self) { group in
            group.addTask {
                await harness.run(input: blocks, context: context, emit: emitter)
            }
            group.addTask {
                try? await clockRef.sleep(deadline)
                if !Task.isCancelled { flag.set() }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return (first ?? nil) ?? .cancelled
        }
    }

    private func sessionCancel(conn: Conn, params: JSONValue?) async {
        guard let p = params?.objectValue,
              let sessionID = p["sessionId"]?.stringValue else { return }
        guard let session = await supervisor.agentService.session(
            sessionID, consumerID: conn.principal.id, connectionID: conn.connectionID) else { return }
        if let runID = activeRuns[session.id] {
            runFlags[runID]?.set()
            await supervisor.cancelChildren(parentID: runID)
        } else if startingSessions.contains(session.id) {
            pendingCancels.insert(session.id)
        }
    }

    /// Connection teardown: owned sessions close and active runs cancel.
    public func connectionClosed(_ connectionID: String) async {
        let sessions = await supervisor.agentService.closeConnection(connectionID)
        for s in sessions {
            if let runID = activeRuns[s.id] {
                runFlags[runID]?.set()
                await supervisor.cancelChildren(parentID: runID)
            } else if startingSessions.contains(s.id) {
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

/// Tracks detached session/update emissions so the prompt result cannot
/// overtake its own notifications on the wire.
actor EmissionTracker {
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() { inFlight += 1 }

    func end() {
        inFlight = max(0, inFlight - 1)
        if inFlight == 0 {
            let pending = waiters
            waiters.removeAll()
            for w in pending { w.resume() }
        }
    }

    func drain() async {
        if inFlight == 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
