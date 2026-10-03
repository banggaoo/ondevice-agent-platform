import XCTest
import PlatformTestSupport
@testable import PlatformServing
@testable import PlatformCore

/// Lock-confined late binding for the router (bound port known after listen).
final class RouterRef: @unchecked Sendable {
    private let lock = NSLock()
    private var _router: Router?
    var router: Router? { lock.lock(); defer { lock.unlock() }; return _router }
    func assign(_ r: Router) { lock.lock(); _router = r; lock.unlock() }
}

/// Actual loopback HTTP integration through URLSession: login, CSRF, model
/// and ML errors, status, events, cancellation, and disconnect handling.
final class HTTPIntegrationTests: XCTestCase {

    struct Server {
        let stack: TestStack
        let server: HTTPServer
        let port: UInt16
        let base: URL
        let http: URLSession

        func stop() { server.stop(); stack.root.releaseLock() }
    }

    private func startServer(enableReferenceAgent: Bool = false) async throws -> Server {
        let stack = try await makeStack(enableReferenceAgent: enableReferenceAgent)
        await registerStandardPrincipals(stack.supervisor)
        let sessions = ConsoleSessions(clock: stack.clock.clock)
        let acp = ACPService(supervisor: stack.supervisor, clock: stack.clock.clock)
        let ref = RouterRef()
        let server = HTTPServer { request, respond in
            guard let router = ref.router else {
                respond(.error(PlatformError(.internal), status: 500))
                return
            }
            Task { await router.handle(request, respond: respond) }
        }
        try server.start(port: 0)
        let port = try server.waitForPort()
        ref.assign(Router(supervisor: stack.supervisor, sessions: sessions,
                          acp: acp, port: port, clock: stack.clock.clock))
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        return Server(stack: stack, server: server, port: port,
                      base: URL(string: "http://127.0.0.1:\(port)")!,
                      http: URLSession(configuration: config))
    }

    private static func request(_ s: Server, _ path: String, method: String = "GET",
                         token: String? = nil, cookie: String? = nil,
                         origin: String? = nil, csrf: String? = nil,
                         json: JSONValue? = nil) -> URLRequest {
        let url = path.isEmpty ? s.base
            : URL(string: s.base.absoluteString + "/" + path)!
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let cookie { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let origin { r.setValue(origin, forHTTPHeaderField: "Origin") }
        if let csrf { r.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? json.encoded()
        }
        return r
    }

    private static func origin(_ s: Server) -> String { "http://127.0.0.1:\(s.port)" }

    private static func status(_ s: Server, _ r: URLRequest) async throws -> (Int, JSONValue?, HTTPURLResponse) {
        let (data, response) = try await s.http.data(for: r)
        let http = response as! HTTPURLResponse
        return (http.statusCode, try? JSONValue.decode(data), http)
    }

    private static func login(_ s: Server, credential: String = consoleToken) async throws -> (cookie: String, csrf: String)? {
        let (code, body, http) = try await Self.status(s, Self.request(
            s, "api/session", method: "POST", origin: Self.origin(s),
            json: .object(["credential": .string(credential)])))
        guard code == 200 else { return nil }
        let cookieHeader = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        let cookie = cookieHeader.split(separator: ";").first.map(String.init) ?? ""
        guard let csrf = body?.objectValue?["csrf"]?.stringValue else { return nil }
        return (cookie, csrf)
    }

    // MARK: static + login

    func testStaticAssetSafeHeaders() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let (code, _, http) = try await Self.status(s, Self.request(s, ""))
        XCTAssertEqual(code, 200)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Security-Policy"))
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
        try await expectEqual(try await Self.status(s, Self.request(s, "styles.css")).0, 200)
        try await expectEqual(try await Self.status(s, Self.request(s, "app.js")).0, 200)
        try await expectEqual(try await Self.status(s, Self.request(s, "..%2Fetc%2Fpasswd")).0, 404)
        try await expectEqual(try await Self.status(s, Self.request(s, "etc/passwd")).0, 404)
    }

    func testLoginSessionCSRFAndLogout() async throws {
        let s = try await startServer()
        defer { s.stop() }
        // Wrong credential → 401; wrong Origin → 403.
        let bad = try await Self.status(s, Self.request(
            s, "api/session", method: "POST", origin: Self.origin(s),
            json: .object(["credential": .string("wrong")]))).0
        XCTAssertEqual(bad, 401)
        let evilOrigin = try await Self.status(s, Self.request(
            s, "api/session", method: "POST", origin: "http://evil.example",
            json: .object(["credential": .string(consoleToken)]))).0
        XCTAssertEqual(evilOrigin, 403)

        guard let (cookie, csrf) = try await Self.login(s) else {
            XCTFail("login failed"); return
        }
        // Cookie carries a session id, never the credential.
        XCTAssertFalse(cookie.contains(consoleToken))
        XCTAssertTrue(cookie.hasPrefix("platform_session="))

        let status200 = try await Self.status(s, Self.request(s, "api/status", cookie: cookie)).0
        XCTAssertEqual(status200, 200)
        // CSRF-guarded mutation without token → 403; with token → passes CSRF
        // (404 for the unknown job proves we reached authorization logic).
        let noCSRF = try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            cookie: cookie, origin: Self.origin(s))).0
        XCTAssertEqual(noCSRF, 403)
        let withCSRF = try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: csrf)).0
        XCTAssertEqual(withCSRF, 404)

        // Logout invalidates the session.
        let logout = try await Self.status(s, Self.request(
            s, "api/logout", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: csrf)).0
        XCTAssertEqual(logout, 200)
        try await expectEqual(try await Self.status(s, Self.request(s, "api/status", cookie: cookie)).0, 401)
    }

    func testExpiredSessionDenied() async throws {
        let s = try await startServer()
        defer { s.stop() }
        guard let (cookie, _) = try await Self.login(s) else { XCTFail("login"); return }
        s.stack.clock.advance(by: PlatformLimits.consoleSessionSeconds + 60)
        try await expectEqual(try await Self.status(s, Self.request(s, "api/status", cookie: cookie)).0, 401)
    }

    func testLoginRateLimit() async throws {
        let s = try await startServer()
        defer { s.stop() }
        var last = 0
        for _ in 0..<PlatformLimits.loginAttemptsPerMinute + 1 {
            last = try await Self.status(s, Self.request(
                s, "api/session", method: "POST", origin: Self.origin(s),
                json: .object(["credential": .string("x")]))).0
        }
        XCTAssertEqual(last, 429)
    }

    // MARK: bearer + model endpoints

    func testModelErrorsOverHTTP() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider(content: "hi", autoFinish: true)
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat"), provider: provider)
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "ghost", providerID: "nobody",
                         kind: .llm, task: "chat"))
        // No auth → 401. Model token admin → 403.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            json: .object(["model": .string("test-llm")]))).0, 401)
        try await expectEqual(try await Self.status(s, Self.request(s, "api/status", token: modelToken)).0, 403)

        let body: JSONValue = .object([
            "model": .string("test-llm"),
            "messages": .array([
                .object(["role": .string("user"),
                         "content": .string("refresh")])
            ]),
        ])
        let (ok, okBody, _) = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", token: modelToken, json: body))
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(okBody?.objectValue?["model"]?.stringValue, "fake-llm")
        // Prompt text never selected administration: provider saw "refresh".
        XCTAssertEqual(provider.invocations.first?.messages.first?.parts, ["refresh"])

        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", token: modelToken,
            json: .object(["model": .string("nope"),
                           "messages": .array([.object(["role": .string("user"),
                                                        "content": .string("x")])])]))).0, 404)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", token: modelToken,
            json: .object(["model": .string("ghost"),
                           "messages": .array([.object(["role": .string("user"),
                                                        "content": .string("x")])])]))).0, 503)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", token: modelToken,
            json: .object(["model": .string("test-llm"),
                           "messages": .array([.object(["role": .string("user"),
                                                        "content": .string("x")])]),
                           "tools": .array([])]))).0, 400)

        let (code, models, _) = try await Self.status(s, Self.request(
            s, "v1/models", token: modelToken))
        XCTAssertEqual(code, 200)
        let ids = models?.objectValue?["data"]?.arrayValue?
            .compactMap { $0.objectValue?["id"]?.stringValue } ?? []
        XCTAssertEqual(ids, ["ghost", "test-llm"])
    }

    func testMLEndpointOverHTTP() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let ml = FakeMLPredictor(outputs: ["label": .string("cat")])
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-ml", providerID: "fake-ml", kind: .ml,
                         task: "classify", inputSchema: ["x": .number],
                         outputSchema: ["label": .string]), predictor: ml)
        let t = Task {
            try await Self.status(s, Self.request(
                s, "api/ml/predictions", method: "POST", token: modelToken,
                json: .object(["model": .string("test-ml"),
                               "task": .string("classify"),
                               "inputs": .object(["x": .double(2.0)])])))
        }
        try await expectTrue(await pollUntil { ml.invocations.count == 1 })
        ml.finishNext()
        let (code, body, _) = try await t.value
        XCTAssertEqual(code, 200)
        XCTAssertEqual(body?.objectValue?["outputs"]?.objectValue?["label"], .string("cat"))

        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/ml/predictions", method: "POST", token: modelToken,
            json: .object(["model": .string("test-ml"),
                           "task": .string("classify"),
                           "inputs": .object(["x": .string("bad")])]))).0, 400)
    }

    func testQueueFullReturns429() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider()
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat"), provider: provider)
        let body: JSONValue = .object([
            "model": .string("test-llm"),
            "messages": .array([.object(["role": .string("user"), "content": .string("x")])]),
        ])
        var tasks: [Task<Int, Error>] = []
        for _ in 0..<5 {
            tasks.append(Task {
                try await Self.status(s, Self.request(
                    s, "v1/chat/completions", method: "POST",
                    token: modelToken, json: body)).0
            })
        }
        try await expectTrue(await pollUntil {
            let snap = await s.stack.supervisor.admissionSnapshot()
            return snap.active + snap.pending == 5
        })
        let last = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", token: modelToken, json: body)).0
        XCTAssertEqual(last, 429)
        provider.finishAll()
        for t in tasks { _ = try? await t.value }
    }

    // MARK: events + disconnect

    func testEventsStreamAndDisconnect() async throws {
        let s = try await startServer()
        defer { s.stop() }
        guard let (cookie, _) = try await Self.login(s) else { XCTFail("login"); return }
        var req = Self.request(s, "api/events", cookie: cookie)
        req.timeoutInterval = 30
        let task = Task { () -> String? in
            guard let (bytes, response) = try? await s.http.bytes(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            for try await line in bytes.lines where line.hasPrefix("data:") {
                return line
            }
            return nil
        }
        let frame = try await task.value
        XCTAssertNotNil(frame)
        XCTAssertTrue(frame?.contains("\"version\"") == true)
        // Client disconnect: server must not wedge; subsequent requests work.
        try await expectEqual(try await Self.status(s, Self.request(s, "api/status", token: consoleToken)).0, 200)
    }

    /// Bearer consumer can cancel its own job; the console cookie path can
    /// cancel any job via adminStop.
    func testJobCancelOverHTTP() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider()
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat"), provider: provider)
        let inflight = Task {
            try await Self.status(s, Self.request(
                s, "v1/chat/completions", method: "POST", token: modelToken,
                json: .object(["model": .string("test-llm"),
                               "messages": .array([.object(["role": .string("user"),
                                                            "content": .string("x")])])])))
        }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        // Model principal cancels its own job.
        let cancelled = try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST", token: modelToken)).0
        XCTAssertEqual(cancelled, 200)
        let result = try await inflight.value
        XCTAssertEqual(result.0, 503)   // cancelled → OpenAI-shaped 503
        provider.finishAll()
        // Agent token cannot stop another consumer's job (not its own) and
        // has no adminStop: 403.
        let denied = try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST", token: agentToken)).0
        XCTAssertEqual(denied, 403)
    }
}
