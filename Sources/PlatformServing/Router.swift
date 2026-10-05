import Foundation
import PlatformCore

/// Route dispatch for the loopback boundary. Local-trust serving: routes
/// bind to fixed code-owned consumers rather than authenticating callers;
/// Origin/fetch guards and rate limits apply before any route work.
public actor Router {
    private let supervisor: PlatformSupervisor
    private let sessions: ConsoleSessions
    private let acp: ACPService
    private let clock: Clock
    private let bridge: ConsoleOperatorBridge
    private let port: UInt16
    private var consumerWindows: [String: [Date]] = [:]
    private var eventSubscribers = 0

    public init(supervisor: PlatformSupervisor, sessions: ConsoleSessions,
                acp: ACPService, port: UInt16, clock: Clock,
                consoleOperatorPrincipal: Principal? = nil) {
        self.supervisor = supervisor
        self.sessions = sessions
        self.acp = acp
        self.clock = clock
        self.bridge = ConsoleOperatorBridge(acp: acp, supervisor: supervisor,
                                            sessions: sessions, clock: clock,
                                            principal: consoleOperatorPrincipal)
        self.port = port
    }

    /// The listener binds IPv4 loopback only, so the two reachable
    /// spellings are `127.0.0.1` and `localhost` - both accepted; a
    /// rebound DNS name still fails here before routing.
    private func isValidHost(_ host: String?) -> Bool {
        host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// The page's expected Origin is whichever loopback name served it;
    /// Host is already validated by handle() before this runs.
    private func expectedOrigin(_ request: HTTPRequest) -> String {
        "http://\(request.header("Host") ?? "")"
    }

    public func handle(_ request: HTTPRequest,
                       respond: @escaping @Sendable (HTTPResponse) -> Void) async {
        guard isValidHost(request.header("Host")) else {
            respond(.error(PlatformError(.invalidRequest), status: 400))
            return
        }
        do {
            respond(try await route(request))
        } catch let e as PlatformError {
            respond(.error(e, status: statusCode(e)))
        } catch {
            respond(.error(PlatformError(.internal), status: 500))
        }
    }

    private func statusCode(_ e: PlatformError) -> Int {
        switch e.code {
        case .invalidRequest, .malformedJSON, .versionUnsupported: return 400
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .conflict: return 409
        case .payloadTooLarge: return 413
        case .rateLimited, .capacityLimited: return 429
        case .providerUnavailable, .resourceDenied, .cancelled,
             .cancellationUnconfirmed, .storageFailure, .storageExhausted: return 503
        case .deadlineExceeded: return 504
        case .sessionClosed: return 410
        case .internal, .rootUnsafe: return 500
        }
    }

    /// A supplied Origin must be exact - a foreign or "null" value is a
    /// truthful 403; an absent header is a marker-free native caller.
    private func requireOrigin(_ request: HTTPRequest) throws {
        if let origin = request.header("Origin"), origin != expectedOrigin(request) {
            throw PlatformError(.forbidden)
        }
    }

    /// Session bootstrap and cookie-guarded mutations require an
    /// explicit exact Origin; an absent header cannot be distinguished
    /// from a cross-site form post.
    private func requireExactOrigin(_ request: HTTPRequest) throws {
        guard request.header("Origin") == expectedOrigin(request) else {
            throw PlatformError(.forbidden)
        }
    }

    /// Fetch-metadata defense in depth: a supplied cross-site marker fails
    /// closed on cookie-guarded routes. Header-less clients are not
    /// penalized; Origin and CSRF carry the actual checks.
    private func requireSameSiteFetch(_ request: HTTPRequest) throws {
        if request.header("Sec-Fetch-Site") == "cross-site" {
            throw PlatformError(.forbidden)
        }
    }

    /// Fixed local-trust identity for one route family. Any supplied Origin
    /// must be exact (a foreign or "null" value is refused) and a supplied
    /// cross-site fetch marker fails closed; the per-consumer rate limit
    /// then applies. An incoming Authorization header is ignored outright -
    /// no header or body value can select a different principal.
    private func localRoute(_ request: HTTPRequest,
                            as principal: Principal) throws -> Principal {
        try requireOrigin(request)
        try requireSameSiteFetch(request)
        try consumerRateLimit(principal.id)
        return principal
    }

    private func consumerRateLimit(_ id: String) throws {
        let cutoff = clock.now.addingTimeInterval(-60)
        var window = (consumerWindows[id] ?? []).filter { $0 >= cutoff }
        guard window.count < PlatformLimits.requestsPerConsumerPerMinute else {
            throw PlatformError(.rateLimited)
        }
        window.append(clock.now)
        consumerWindows[id] = window
    }

    private func cookieSession(_ request: HTTPRequest) async -> ConsoleSessions.Session? {
        guard let cookie = request.header("Cookie") else { return nil }
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
                .split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "platform_session" {
                return await sessions.lookup(String(kv[1]))
            }
        }
        return nil
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"): return staticAsset("index.html", contentType: "text/html; charset=utf-8")
        case ("GET", "/styles.css"): return staticAsset("styles.css", contentType: "text/css; charset=utf-8")
        case ("GET", "/app.js"): return staticAsset("app.js", contentType: "text/javascript; charset=utf-8")
        case ("POST", "/api/session"): return try await bootstrap(request)
        case ("GET", "/api/session"): return try await sessionInfo(request)
        case ("POST", "/api/logout"): return try await logout(request)
        case ("GET", "/api/status"): return try await adminJSON(request) { await self.supervisor.statusSnapshot() }
        case ("GET", "/api/registry"): return try await adminJSON(request) { await self.supervisor.registrySnapshot() }
        case ("GET", "/api/jobs"): return try await adminJobs(request)
        case ("POST", "/api/console/operator/prompt"): return try await operatorPrompt(request)
        case ("POST", "/v1/chat/completions"): return try await chatCompletions(request)
        case ("GET", "/v1/models"): return try await listModels(request)
        case ("POST", "/api/ml/predictions"): return try await mlPredict(request)
        case ("POST", "/_bridge/acp"): return try await bridgeACP(request)
        default:
            if request.method == "POST", request.path.hasPrefix("/api/jobs/"),
               request.path.hasSuffix("/cancel") {
                return try await cancelJob(request)
            }
            if request.method == "GET", request.path == "/api/events" {
                return try await events(request)
            }
            throw PlatformError(.notFound)
        }
    }

    // MARK: - static assets (public, no auth)

    private func staticAsset(_ name: String, contentType: String) -> HTTPResponse {
        let url = Bundle.module.url(forResource: name, withExtension: nil,
                                    subdirectory: "Console")
            ?? Bundle.module.url(forResource: name, withExtension: nil)
        guard let url, let data = try? Data(contentsOf: url) else {
            return .error(PlatformError(.notFound), status: 404)
        }
        return HTTPResponse(status: 200, reason: "OK", headers: [
            ("Content-Type", contentType),
            ("Content-Security-Policy", "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; font-src 'self'"),
            ("X-Content-Type-Options", "nosniff"),
            ("X-Frame-Options", "DENY"),
            ("Cache-Control", "no-store"),
        ], body: data)
    }

    // MARK: - console browser guards

    /// Local-console session bootstrap: this is a trusted single-user
    /// development surface, so no credential is exchanged. An exact Origin
    /// is a browser-origin check, not caller identity: browsers cannot
    /// forge it cross-origin, while a local native client can set any
    /// header and is intentionally trusted by this local design. Fetch
    /// metadata, when supplied, must confirm same-origin. A valid
    /// presented cookie reuses its session instead of allocating a new one;
    /// only real creation consumes the bounded attempt/session limits.
    private func bootstrap(_ request: HTTPRequest) async throws -> HTTPResponse {
        try requireExactOrigin(request)
        if let site = request.header("Sec-Fetch-Site"), site != "same-origin" {
            throw PlatformError(.forbidden)
        }
        if let session = await cookieSession(request) {
            return sessionResponse(session)
        }
        guard await sessions.loginAllowed() else { throw PlatformError(.rateLimited) }
        return sessionResponse(try await sessions.create())
    }

    private func sessionResponse(_ session: ConsoleSessions.Session) -> HTTPResponse {
        var response = HTTPResponse.json(.object([
            "session": .string(session.id),
            "csrf": .string(session.csrf),
            "expiresAt": .double(session.expiresAt.timeIntervalSince1970),
        ]))
        // Loopback development HTTP cannot use Secure cookies; SameSite=Strict
        // plus exact-Origin mutation checks are the M1 control. Not a
        // hardened distribution posture - see docs.
        response.headers.append(("Set-Cookie",
            "platform_session=\(session.id); Path=/; HttpOnly; SameSite=Strict"))
        return response
    }

    /// Browser request guard, not authentication: the automatic cookie
    /// session, exact Origin, and CSRF checks bound mutations to the served
    /// page. An absent or expired nonce is a 401 the page bootstraps past.
    private func requireConsoleSession(_ request: HTTPRequest, mutation: Bool) async throws -> ConsoleSessions.Session {
        if mutation {
            try requireExactOrigin(request)
        } else {
            try requireOrigin(request)
        }
        try requireSameSiteFetch(request)
        guard let session = await cookieSession(request) else {
            throw PlatformError(.unauthorized)
        }
        if mutation {
            guard request.header("X-CSRF-Token") == session.csrf else {
                throw PlatformError(.forbidden)
            }
        }
        return session
    }

    private func sessionInfo(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = try await requireConsoleSession(request, mutation: false)
        return .json(.object([
            "session": .string(session.id),
            "csrf": .string(session.csrf),
            "expiresAt": .double(session.expiresAt.timeIntervalSince1970),
        ]))
    }

    private func logout(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = try await requireConsoleSession(request, mutation: true)
        // Invalidate the console session first so a racing bridge lookup
        // can never validate a logged-out cookie, then drop the binding.
        await sessions.logout(session.id)
        await bridge.connectionClosed(forSession: session.id)
        return .json(.object(["ok": .bool(true)]))
    }

    /// Console-only Operator question: cookie session + exact Origin +
    /// CSRF + fetch checks (inside requireConsoleSession mutation), a shared
    /// per-consumer rate limit, then the in-process ACP bridge. No API
    /// credential exists; the fixed console Operator consumer holds only
    /// its three scoped grants.
    private func operatorPrompt(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = try await requireConsoleSession(request, mutation: true)
        try consumerRateLimit("console-operator")
        let reply = try await bridge.prompt(consoleSession: session,
                                            body: request.body,
                                            cancellation: request.cancellation)
        return .json(reply)
    }

    // MARK: - admin reads

    private func adminJSON(_ request: HTTPRequest,
                           _ produce: () async throws -> JSONValue) async throws -> HTTPResponse {
        // Administrative reads run under the fixed local administration
        // consumer: no cookie or credential is required, while supplied
        // Origin/fetch metadata still fails closed inside localRoute.
        let principal = try localRoute(request, as: LocalConsumers.administration)
        try await supervisor.require(.adminRead, principal: principal)
        return .json(try await produce())
    }

    private func adminJobs(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await adminJSON(request) {
            let jobs = try await self.supervisor.listJobs()
            return .object(["jobs": .array(jobs.map { j in
                .object([
                    "id": .string(j.id),
                    "kind": .string(j.kind.rawValue),
                    "consumer": .string(j.consumerID),
                    "state": .string(j.state.rawValue),
                    "parentId": j.parentID.map { .string($0) } ?? .null,
                    "createdAt": .double(j.createdAt.timeIntervalSince1970),
                    "updatedAt": .double(j.updatedAt.timeIntervalSince1970),
                ])
            })])
        }
    }

    // MARK: - job cancel

    private func cancelJob(_ request: HTTPRequest) async throws -> HTTPResponse {
        let jobID = String(request.path.dropFirst("/api/jobs/".count)
            .dropLast("/cancel".count))
        guard !jobID.isEmpty,
              jobID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw PlatformError(.invalidRequest)
        }
        // Any browser marker - the session cookie, an Origin, or fetch
        // metadata - routes through the console mutation checks with no
        // fallback: a bad cookie or missing CSRF is a real failure, never a
        // silent native cancellation, and a supplied Authorization header
        // cannot bypass CSRF.
        if request.header("Cookie")?.contains("platform_session=") == true
            || request.header("Origin") != nil
            || request.header("Sec-Fetch-Site") != nil {
            _ = try await requireConsoleSession(request, mutation: true)
            try await supervisor.cancelJob(
                principal: LocalConsumers.administration, jobID: jobID)
            return .json(.object(["ok": .bool(true)]))
        }
        // Marker-free native caller: the trusted device owner stops local
        // jobs under the fixed administration consumer.
        let principal = try localRoute(request, as: LocalConsumers.administration)
        try await supervisor.cancelJob(principal: principal, jobID: jobID)
        return .json(.object(["ok": .bool(true)]))
    }

    // MARK: - events (SSE)

    private func events(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = try await requireConsoleSession(request, mutation: false)
        guard eventSubscribers < PlatformLimits.eventSubscribers else {
            throw PlatformError(.rateLimited)
        }
        eventSubscribers += 1
        let supervisorRef = supervisor
        var response = HTTPResponse(status: 200, reason: "OK", headers: [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
        ])
        let sessionsRef = sessions
        response.stream = { sender in
            let cancelled = CancelFlag()
            sender.onPeerClose { cancelled.set() }
            Task {
                defer { sender.close() }
                while !cancelled.isSet {
                    guard let live = await sessionsRef.lookup(session.id) else { break }
                    _ = live
                    let status = await supervisorRef.statusSnapshot()
                    let data = (try? status.encoded()) ?? Data("{}".utf8)
                    var frame = Data("data: ".utf8)
                    frame.append(data)
                    frame.append(Data("\n\n".utf8))
                    await sender.send(frame)
                    try? await Task.sleep(for: .seconds(2))
                }
                await self.eventSubscribersDone()
            }
        }
        return response
    }

    private func eventSubscribersDone() { eventSubscribers -= 1 }

    // MARK: - OpenAI + ML

    private func chatCompletions(_ request: HTTPRequest) async throws -> HTTPResponse {
        let principal = try localRoute(request, as: LocalConsumers.model)
        let chat = try OpenAIAdapter.parseChatRequest(request.body)
        do {
            // The provider boundary is single-shot: the job resolves to one
            // completed result, so request-level failures (auth, admission,
            // deadlines) keep truthful HTTP status codes instead of becoming
            // mid-stream SSE errors.
            let result = try await supervisor.submitLLM(principal: principal, request: chat.request,
                                                        cancellation: request.cancellation)
            guard chat.stream else {
                return .json(OpenAIAdapter.chatResponse(result, requestedModel: chat.request.model))
            }
            var response = HTTPResponse(status: 200, reason: "OK", headers: [
                ("Content-Type", "text/event-stream"),
                ("Cache-Control", "no-store"),
                ("X-Content-Type-Options", "nosniff"),
            ])
            let frames = OpenAIAdapter.streamFrames(result, requestedModel: chat.request.model,
                                                    includeUsage: chat.includeUsage)
            response.stream = { sender in
                Task {
                    defer { sender.close() }
                    for frame in frames {
                        await sender.send(frame)
                    }
                }
            }
            return response
        } catch let e as PlatformError {
            return .json(OpenAIAdapter.errorBody(e), status: statusCode(e),
                         reason: HTTPResponse.reason(for: statusCode(e)))
        }
    }

    private func listModels(_ request: HTTPRequest) async throws -> HTTPResponse {
        let principal = try localRoute(request, as: LocalConsumers.model)
        try await supervisor.require(.llmInfer, principal: principal)
        let models = await supervisor.registeredModels(kind: .llm)
        return .json(OpenAIAdapter.modelsResponse(models))
    }

    private func mlPredict(_ request: HTTPRequest) async throws -> HTTPResponse {
        let principal = try localRoute(request, as: LocalConsumers.model)
        try await supervisor.require(.mlPredict, principal: principal)
        let prediction = try MLAdapter.parseRequest(request.body)
        let result = try await supervisor.submitML(principal: principal, request: prediction,
                                                   cancellation: request.cancellation)
        return .json(MLAdapter.response(result))
    }

    // MARK: - private ACP bridge (NDJSON wrapper, not a standard ACP transport)

    /// Private bridge: each POST carries one wrapped JSON-RPC message
    /// `{connectionId, agentId?, message}` or `{connectionId, close: true}`.
    /// The response streams that message's NDJSON updates and result, then
    /// closes. The client owns the opaque connectionId across POSTs; the first
    /// message binds it to one agent profile. This is a platform transport,
    /// not a standardized ACP HTTP transport.
    private func bridgeACP(_ request: HTTPRequest) async throws -> HTTPResponse {
        let principal = try localRoute(request, as: LocalConsumers.agent)
        try await supervisor.require(.agentRun, principal: principal)
        let wrapper = try JSONValue.decode(request.body)
        guard let w = wrapper.objectValue,
              let connID = w["connectionId"]?.stringValue, !connID.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "connectionId required")
        }
        let acpRef = acp
        if w["close"] == .bool(true) {
            await acpRef.connectionClosed(connID)
            return .json(.object(["ok": .bool(true)]))
        }
        if let agentID = w["agentId"]?.stringValue {
            try await acpRef.bind(connectionID: connID, agentID: agentID,
                                  principal: principal)
        }
        guard let message = w["message"] else {
            return .json(.object(["ok": .bool(true)]))
        }
        var response = HTTPResponse(status: 200, reason: "OK", headers: [
            ("Content-Type", "application/x-ndjson"),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
        ])
        response.stream = { sender in
            Task {
                defer { sender.close() }
                await acpRef.handle(connectionID: connID, message: message,
                                    cancellation: request.cancellation) { out in
                    guard let data = try? JSONRPC.line(for: out) else { return }
                    await sender.send(data)
                }
            }
        }
        return response
    }
}
