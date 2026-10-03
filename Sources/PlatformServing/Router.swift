import Foundation
import PlatformCore

/// Route dispatch for the loopback boundary. Authentication runs after
/// framing validation but before any route work; rate limits apply per
/// credential identity.
public actor Router {
    private let supervisor: PlatformSupervisor
    private let sessions: ConsoleSessions
    private let acp: ACPService
    private let clock: Clock
    private let expectedHost: String
    private let expectedOrigin: String
    private var consumerWindows: [String: [Date]] = [:]
    private var eventSubscribers = 0

    public init(supervisor: PlatformSupervisor, sessions: ConsoleSessions,
                acp: ACPService, port: UInt16, clock: Clock) {
        self.supervisor = supervisor
        self.sessions = sessions
        self.acp = acp
        self.clock = clock
        self.expectedHost = "127.0.0.1:\(port)"
        self.expectedOrigin = "http://127.0.0.1:\(port)"
    }

    public func handle(_ request: HTTPRequest,
                       respond: @escaping @Sendable (HTTPResponse) -> Void) async {
        guard request.header("Host") == expectedHost else {
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

    private func requireOrigin(_ request: HTTPRequest) throws {
        if let origin = request.header("Origin"), origin != expectedOrigin {
            throw PlatformError(.forbidden)
        }
    }

    private func bearerPrincipal(_ request: HTTPRequest) async throws -> Principal {
        guard let auth = request.header("Authorization"),
              auth.hasPrefix("Bearer ") else { throw PlatformError(.unauthorized) }
        let token = String(auth.dropFirst(7))
        guard let principal = await supervisor.authenticate(token: token) else {
            throw PlatformError(.unauthorized)
        }
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
        case ("POST", "/api/session"): return try await login(request)
        case ("GET", "/api/session"): return try await sessionInfo(request)
        case ("POST", "/api/logout"): return try await logout(request)
        case ("GET", "/api/status"): return try await adminJSON(request) { await self.supervisor.statusSnapshot() }
        case ("GET", "/api/registry"): return try await adminJSON(request) { await self.supervisor.registrySnapshot() }
        case ("GET", "/api/jobs"): return try await adminJobs(request)
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

    // MARK: - console auth

    private func login(_ request: HTTPRequest) async throws -> HTTPResponse {
        try requireOrigin(request)
        guard await sessions.loginAllowed() else { throw PlatformError(.rateLimited) }
        let root = try JSONValue.decode(request.body)
        guard let credential = root.objectValue?["credential"]?.stringValue else {
            throw PlatformError(.invalidRequest)
        }
        guard let principal = await supervisor.authenticate(token: credential),
              principal.scope == .console else {
            throw PlatformError(.unauthorized)
        }
        let session = try await sessions.create()
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

    private func consoleAuth(_ request: HTTPRequest, mutation: Bool) async throws -> ConsoleSessions.Session {
        try requireOrigin(request)
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
        let session = try await consoleAuth(request, mutation: false)
        return .json(.object([
            "session": .string(session.id),
            "csrf": .string(session.csrf),
            "expiresAt": .double(session.expiresAt.timeIntervalSince1970),
        ]))
    }

    private func logout(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = try await consoleAuth(request, mutation: true)
        await sessions.logout(session.id)
        return .json(.object(["ok": .bool(true)]))
    }

    // MARK: - admin reads

    private func adminJSON(_ request: HTTPRequest,
                           _ produce: () async throws -> JSONValue) async throws -> HTTPResponse {
        if let session = try? await consoleAuth(request, mutation: false) {
            _ = session
            return .json(try await produce())
        }
        let principal = try await bearerPrincipal(request)
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
        // A presented session cookie takes the console path; auth/CSRF
        // failures must surface (403 for a missing CSRF token), not silently
        // fall through to a bearer check that returns 401.
        if request.header("Cookie")?.contains("platform_session=") == true {
            _ = try await consoleAuth(request, mutation: true)
            let console = Principal(id: "console", scope: .console)
            try await supervisor.cancelJob(principal: console, jobID: jobID)
            return .json(.object(["ok": .bool(true)]))
        }
        let principal = try await bearerPrincipal(request)
        try await supervisor.cancelJob(principal: principal, jobID: jobID)
        return .json(.object(["ok": .bool(true)]))
    }

    // MARK: - events (SSE)

    private func events(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = try await consoleAuth(request, mutation: false)
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
        let principal = try await bearerPrincipal(request)
        let chat = try OpenAIAdapter.parseChatRequest(request.body)
        do {
            let result = try await supervisor.submitLLM(principal: principal, request: chat)
            return .json(OpenAIAdapter.chatResponse(result, requestedModel: chat.model))
        } catch let e as PlatformError {
            return .json(OpenAIAdapter.errorBody(e), status: statusCode(e),
                         reason: HTTPResponse.reason(for: statusCode(e)))
        }
    }

    private func listModels(_ request: HTTPRequest) async throws -> HTTPResponse {
        let principal = try await bearerPrincipal(request)
        try await supervisor.require(.llmInfer, principal: principal)
        let models = await supervisor.registeredModels(kind: .llm)
        return .json(OpenAIAdapter.modelsResponse(models))
    }

    private func mlPredict(_ request: HTTPRequest) async throws -> HTTPResponse {
        let principal = try await bearerPrincipal(request)
        try await supervisor.require(.mlPredict, principal: principal)
        let prediction = try MLAdapter.parseRequest(request.body)
        let result = try await supervisor.submitML(principal: principal, request: prediction)
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
        let principal = try await bearerPrincipal(request)
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
                await acpRef.handle(connectionID: connID, message: message) { out in
                    guard let data = try? JSONRPC.line(for: out) else { return }
                    await sender.send(data)
                }
            }
        }
        return response
    }
}
