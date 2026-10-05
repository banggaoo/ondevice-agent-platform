import XCTest
import Network
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

/// Actual loopback HTTP integration: automatic session bootstrap, CSRF and
/// Origin guards, model and ML errors, status, events, cancellation, and
/// disconnect handling.
final class HTTPIntegrationTests: XCTestCase {

    struct Server {
        let stack: TestStack
        let server: HTTPServer
        let router: Router
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
        let router = Router(supervisor: stack.supervisor, sessions: sessions,
                            acp: acp, port: port, clock: stack.clock.clock)
        ref.assign(router)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        return Server(stack: stack, server: server, router: router, port: port,
                      base: URL(string: "http://127.0.0.1:\(port)")!,
                      http: URLSession(configuration: config))
    }

    private static func request(_ s: Server, _ path: String, method: String = "GET",
                         token: String? = nil, cookie: String? = nil,
                         origin: String? = nil, csrf: String? = nil,
                         fetchSite: String? = nil, host: String? = nil,
                         json: JSONValue? = nil) -> URLRequest {
        let url = path.isEmpty ? s.base
            : URL(string: s.base.absoluteString + "/" + path)!
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let host { r.setValue(host, forHTTPHeaderField: "Host") }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let cookie { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let origin { r.setValue(origin, forHTTPHeaderField: "Origin") }
        if let csrf { r.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        if let fetchSite { r.setValue(fetchSite, forHTTPHeaderField: "Sec-Fetch-Site") }
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

    /// Automatic console session bootstrap: an empty POST with the exact
    /// same-origin Origin. No credential is ever involved.
    private static func bootstrap(_ s: Server, cookie: String? = nil) async throws
        -> (cookie: String, csrf: String, session: String, setCookie: String)? {
        let (code, body, http) = try await Self.status(s, Self.request(
            s, "api/session", method: "POST", cookie: cookie,
            origin: Self.origin(s), json: .object([:])))
        guard code == 200 else { return nil }
        let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        let cookie = setCookie.split(separator: ";").first.map(String.init) ?? ""
        guard let csrf = body?.objectValue?["csrf"]?.stringValue,
              let session = body?.objectValue?["session"]?.stringValue else { return nil }
        return (cookie, csrf, session, setCookie)
    }

    // MARK: static assets

    func testStaticAssetSafeHeaders() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let (data, response) = try await s.http.data(for: Self.request(s, ""))
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "Content-Security-Policy"))
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
        // The dashboard must not carry a credential/login form or the old
        // M1 tagline; it opens directly for the trusted local user.
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(html.contains("password"))
        XCTAssertFalse(html.contains("login"))
        XCTAssertFalse(html.contains("credential"))
        XCTAssertFalse(html.contains("M1"))
        XCTAssertTrue(html.contains("Local models and agents"))
        try await expectEqual(try await Self.status(s, Self.request(s, "styles.css")).0, 200)
        try await expectEqual(try await Self.status(s, Self.request(s, "app.js")).0, 200)
        try await expectEqual(try await Self.status(s, Self.request(s, "..%2Fetc%2Fpasswd")).0, 404)
        try await expectEqual(try await Self.status(s, Self.request(s, "etc/passwd")).0, 404)
    }

    /// The console serves under either loopback spelling: `localhost`
    /// works end-to-end (page, bootstrap Origin, admin reads) while a
    /// rebound foreign hostname is refused at the Host gate.
    func testLoopbackHostSpellingsAcceptedForeignRefused() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let localHost = "localhost:\(s.port)"
        try await expectEqual(
            try await Self.status(s, Self.request(s, "", host: localHost)).0, 200)
        let (code, body, _) = try await Self.status(s, Self.request(
            s, "api/session", method: "POST",
            origin: "http://\(localHost)", host: localHost, json: .object([:])))
        XCTAssertEqual(code, 200)
        XCTAssertNotNil(body?.objectValue?["csrf"])
        try await expectEqual(
            try await Self.status(s, Self.request(s, "api/status", host: localHost)).0, 200)
        // A rebound DNS name never reaches routing.
        try await expectEqual(try await Self.status(
            s, Self.request(s, "", host: "evil.local:\(s.port)")).0, 400)
        try await expectEqual(try await Self.status(
            s, Self.request(s, "api/status", host: "evil.local:\(s.port)")).0, 400)
    }

    // MARK: automatic session bootstrap

    func testAutomaticBootstrapSetsCookieAndReusesSession() async throws {
        let s = try await startServer()
        defer { s.stop() }
        // No bearer token or body credential is needed anywhere.
        guard let first = try await Self.bootstrap(s) else {
            XCTFail("bootstrap failed"); return
        }
        XCTAssertTrue(first.setCookie.hasPrefix("platform_session="))
        XCTAssertTrue(first.setCookie.contains("HttpOnly"))
        XCTAssertTrue(first.setCookie.contains("SameSite=Strict"))
        XCTAssertTrue(first.setCookie.contains("Path=/"))

        // A still-valid presented cookie reuses the same session and CSRF
        // instead of allocating a new session per page load.
        guard let second = try await Self.bootstrap(s, cookie: first.cookie) else {
            XCTFail("bootstrap reuse failed"); return
        }
        XCTAssertEqual(second.session, first.session)
        XCTAssertEqual(second.csrf, first.csrf)

        // GET returns the same existing session; no cookie -> 401 and GET
        // never creates sessions.
        let (code, body, _) = try await Self.status(s, Self.request(
            s, "api/session", cookie: first.cookie))
        XCTAssertEqual(code, 200)
        XCTAssertEqual(body?.objectValue?["session"]?.stringValue, first.session)
        XCTAssertEqual(body?.objectValue?["csrf"]?.stringValue, first.csrf)
        try await expectEqual(try await Self.status(s, Self.request(s, "api/session")).0, 401)
    }

    func testBootstrapOriginAndFetchSiteGuards() async throws {
        let s = try await startServer()
        defer { s.stop() }
        // Missing Origin -> 403: bootstrap requires an explicit exact Origin.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/session", method: "POST", json: .object([:]))).0, 403)
        // Foreign Origin -> 403.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/session", method: "POST", origin: "http://evil.example",
            json: .object([:]))).0, 403)
        // The opaque "null" Origin is not exact -> 403.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/session", method: "POST", origin: "null",
            json: .object([:]))).0, 403)
        // Exact Origin with non-same-origin fetch metadata -> 403.
        for marker in ["cross-site", "same-site", "none"] {
            try await expectEqual(try await Self.status(s, Self.request(
                s, "api/session", method: "POST", origin: Self.origin(s),
                fetchSite: marker, json: .object([:]))).0, 403)
        }
        // Exact Origin + same-origin marker -> 200.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/session", method: "POST", origin: Self.origin(s),
            fetchSite: "same-origin", json: .object([:]))).0, 200)
    }

    /// The exact-Host gate runs at Router.handle before any route work.
    func testWrongHostRejected() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let request = HTTPRequest(method: "GET", target: "/api/status",
                                  version: "HTTP/1.1",
                                  headers: [("Host", "127.0.0.1:1")], body: Data())
        let status = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            Task { await s.router.handle(request) { cont.resume(returning: $0.status) } }
        }
        XCTAssertEqual(status, 400)
    }

    /// Local-trust reads: the console cookie still works, but the fixed
    /// local consumers need no credential and an Authorization header is
    /// ignored rather than selecting a different principal.
    func testCookieConsoleReadsAndLocalConsumers() async throws {
        let s = try await startServer()
        defer { s.stop() }
        guard let (cookie, _, _, _) = try await Self.bootstrap(s) else {
            XCTFail("bootstrap failed"); return
        }
        for path in ["api/status", "api/registry", "api/jobs"] {
            try await expectEqual(try await Self.status(s, Self.request(
                s, path, cookie: cookie)).0, 200)
        }
        // No credential at all -> the fixed administration consumer reads.
        try await expectEqual(try await Self.status(s, Self.request(s, "api/status")).0, 200)
        // An Authorization header is ignored outright - same route result.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/status", token: "old-client-value")).0, 200)
        // Model APIs need no API credential; a console cookie adds nothing.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/models", cookie: cookie)).0, 200)
        try await expectEqual(try await Self.status(s, Self.request(s, "v1/models")).0, 200)
    }

    func testCookieMutationRequiresOriginAndCSRF() async throws {
        let s = try await startServer()
        defer { s.stop() }
        guard let (cookie, csrf, _, _) = try await Self.bootstrap(s) else {
            XCTFail("bootstrap failed"); return
        }
        // Missing CSRF -> 403 even with cookie + Origin.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            cookie: cookie, origin: Self.origin(s))).0, 403)
        // Wrong CSRF -> 403.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: "wrong")).0, 403)
        // Missing Origin -> 403 even with the correct CSRF.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            cookie: cookie, csrf: csrf)).0, 403)
        // Foreign Origin -> 403 even with the correct CSRF.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            cookie: cookie, origin: "http://evil.example", csrf: csrf)).0, 403)
        // Valid cookie + CSRF + exact Origin -> reaches authorization
        // (404 for the unknown job proves we got past the guards).
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: csrf)).0, 404)
        // An arbitrary bearer cannot bypass CSRF on the browser path, and
        // with the correct triple it is simply ignored - same result.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST", token: "arbitrary",
            cookie: cookie, origin: Self.origin(s))).0, 403)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST", token: "arbitrary",
            cookie: cookie, origin: Self.origin(s), csrf: csrf)).0, 404)
    }

    /// Origin/fetch-site guards apply before any work on every public
    /// route class: foreign or `null` origins and cross-site fetch
    /// metadata are rejected with 403 even with a stale credential
    /// attached, and no provider/harness work happens. Bodies are valid so
    /// a 403 proves the guard fired, not request validation.
    func testOriginAndFetchGuardsOnLocalRoutes() async throws {
        let s = try await startServer(enableReferenceAgent: true)
        defer { s.stop() }
        let provider = FakeLLMProvider(autoFinish: true)
        await registerLLM(s, provider)
        let predictor = FakeMLPredictor()
        await registerML(s, predictor)
        // Valid ACP bridge wrapper: connectionId + agentId + JSON-RPC init.
        let acpJSON: JSONValue = .object([
            "connectionId": .string("guard-conn"),
            "agentId": .string("reference.status"),
            "message": JSONRPC.request(id: .int(1), method: "initialize",
                params: .object(["protocolVersion": .int(1),
                                 "clientCapabilities": .object([:])])),
        ])
        for path in ["v1/models", "api/status", "api/registry", "api/jobs"] {
            for origin in ["http://evil.example", "null"] {
                try await expectEqual(try await Self.status(s, Self.request(
                    s, path, origin: origin)).0, 403)
                try await expectEqual(try await Self.status(s, Self.request(
                    s, path, token: modelToken, origin: origin)).0, 403)
            }
            try await expectEqual(try await Self.status(s, Self.request(
                s, path, fetchSite: "cross-site")).0, 403)
        }
        for (path, json) in [("v1/chat/completions", Self.chatJSON),
                             ("api/ml/predictions", Self.predictJSON),
                             ("_bridge/acp", acpJSON)] {
            for origin in ["http://evil.example", "null"] {
                try await expectEqual(try await Self.status(s, Self.request(
                    s, path, method: "POST", origin: origin, json: json)).0, 403)
            }
            try await expectEqual(try await Self.status(s, Self.request(
                s, path, method: "POST", fetchSite: "cross-site", json: json)).0, 403)
        }
        // Cancel with browser markers is denied before job handling: foreign
        // Origin, `null`, and cross-site fetch all fail; a bad cookie plus a
        // bearer header cannot bypass CSRF.
        for origin in ["http://evil.example", "null"] {
            try await expectEqual(try await Self.status(s, Self.request(
                s, "api/jobs/job-1/cancel", method: "POST",
                token: agentToken, origin: origin)).0, 403)
        }
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            token: agentToken, fetchSite: "cross-site")).0, 403)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST", token: agentToken,
            cookie: "bogus", origin: Self.origin(s))).0, 401)
        // Guard rejections happened before any provider or harness work.
        XCTAssertEqual(provider.invocations.count, 0)
        XCTAssertEqual(predictor.invocations.count, 0)
    }

    func testLogoutInvalidatesSessionAndEvents() async throws {
        let s = try await startServer()
        defer { s.stop() }
        guard let (cookie, csrf, _, _) = try await Self.bootstrap(s) else {
            XCTFail("bootstrap failed"); return
        }
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/logout", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: csrf)).0, 200)
        // Local administrative reads stay open after invalidation; the
        // session-bound surfaces (events, session info) do not resurrect.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/status", cookie: cookie)).0, 200)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/events", cookie: cookie)).0, 401)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/session", cookie: cookie)).0, 401)
    }

    func testExpiredSessionDeniedAndRebootstrap() async throws {
        let s = try await startServer()
        defer { s.stop() }
        guard let first = try await Self.bootstrap(s) else {
            XCTFail("bootstrap failed"); return
        }
        s.stack.clock.advance(by: PlatformLimits.consoleSessionSeconds + 60)
        // Expired sessions fail only the browser-guarded surfaces; local
        // status stays readable because it requires no session at all.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/session", cookie: first.cookie)).0, 401)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/status", cookie: first.cookie)).0, 200)
        // A fresh automatic bootstrap recovers with no credential; the dead
        // cookie is ignored rather than resurrected.
        guard let second = try await Self.bootstrap(s, cookie: first.cookie) else {
            XCTFail("re-bootstrap failed"); return
        }
        XCTAssertNotEqual(second.session, first.session)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/status", cookie: second.cookie)).0, 200)
    }

    /// The browser session guard applies only to browser-bound surfaces:
    /// absent or bogus cookies deny `api/session`, `api/events`, and the
    /// console Operator route, while the local read/model APIs serve.
    func testSessionGuardOnlyOnBrowserSurfaces() async throws {
        let s = try await startServer()
        defer { s.stop() }
        for path in ["api/session", "api/events"] {
            try await expectEqual(try await Self.status(s, Self.request(
                s, path)).0, 401)
            try await expectEqual(try await Self.status(s, Self.request(
                s, path, cookie: "bogus")).0, 401)
        }
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/console/operator/prompt", method: "POST",
            cookie: "bogus", origin: Self.origin(s), csrf: "x",
            json: .object(["prompt": .string("hi")]))).0, 401)
        for path in ["api/status", "api/registry", "api/jobs", "v1/models"] {
            try await expectEqual(try await Self.status(s, Self.request(
                s, path)).0, 200)
            try await expectEqual(try await Self.status(s, Self.request(
                s, path, cookie: "bogus")).0, 200)
        }
    }

    func testBootstrapRateLimit() async throws {
        let s = try await startServer()
        defer { s.stop() }
        var last = 0
        for _ in 0..<PlatformLimits.loginAttemptsPerMinute + 1 {
            last = try await Self.status(s, Self.request(
                s, "api/session", method: "POST", origin: Self.origin(s),
                json: .object([:]))).0
        }
        XCTAssertEqual(last, 429)
    }

    // MARK: model endpoints (fixed local consumers)

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
        // No credential is needed: a malformed body fails validation, not
        // authentication.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            json: .object(["model": .string("test-llm")]))).0, 400)

        let body: JSONValue = .object([
            "model": .string("test-llm"),
            "messages": .array([
                .object(["role": .string("user"),
                         "content": .string("refresh")])
            ]),
        ])
        let (ok, okBody, _) = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", json: body))
        XCTAssertEqual(ok, 200)
        // The wire model field is the requested serving alias, not the
        // provider's internal engine identity.
        XCTAssertEqual(okBody?.objectValue?["model"]?.stringValue, "test-llm")
        // Prompt text never selected administration: provider saw "refresh".
        XCTAssertEqual(provider.invocations.first?.messages.first?.parts, ["refresh"])
        // A stale client Authorization header is ignored: identical call,
        // identical result, no different principal.
        let (okWithAuth, _, _) = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            token: "old-client-value", json: body))
        XCTAssertEqual(okWithAuth, 200)
        // Both jobs persisted under the fixed local-model consumer - the
        // header never selected or escalated a principal. Poll because the
        // durable record write is asynchronous relative to the response.
        let persistedBoth = await pollUntil {
            let jobs = try await s.stack.supervisor.listJobs()
            return jobs.filter { $0.kind == .llm }.count == 2
        }
        XCTAssertTrue(persistedBoth, "expected two persisted llm jobs")
        let jobs = try await s.stack.supervisor.listJobs()
        let consumers = jobs.filter { $0.kind == .llm }.map { $0.consumerID }
        XCTAssertEqual(consumers, [LocalConsumers.model.id, LocalConsumers.model.id])

        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            json: .object(["model": .string("nope"),
                           "messages": .array([.object(["role": .string("user"),
                                                        "content": .string("x")])])]))).0, 404)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            json: .object(["model": .string("ghost"),
                           "messages": .array([.object(["role": .string("user"),
                                                        "content": .string("x")])])]))).0, 503)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            json: .object(["model": .string("test-llm"),
                           "messages": .array([.object(["role": .string("user"),
                                                        "content": .string("x")])]),
                           "parallel_tool_calls": .bool(true)]))).0, 400)

        let (code, models, _) = try await Self.status(s, Self.request(
            s, "v1/models"))
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
                s, "api/ml/predictions", method: "POST",
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
            s, "api/ml/predictions", method: "POST",
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
                    json: body)).0
            })
        }
        try await expectTrue(await pollUntil {
            let snap = await s.stack.supervisor.admissionSnapshot()
            return snap.active + snap.pending == 5
        })
        let last = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", json: body)).0
        XCTAssertEqual(last, 429)
        provider.finishAll()
        for t in tasks { _ = try? await t.value }
    }

    /// `stream: true` returns chunked SSE: role delta, content delta,
    /// tool_calls delta, finish chunk, optional usage chunk, [DONE]. The
    /// provider is single-shot so deltas carry the completed result.
    func testStreamingChatEmitsSSEFrames() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider(content: "hi", autoFinish: true)
        provider.result = ChatResult(
            modelIdentity: "fake-llm", content: "hi", finishReason: .stop,
            usage: ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
            toolCalls: [ChatToolCall(name: "bash",
                                     arguments: .object(["command": .string("ls")]))])
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat"), provider: provider)

        var req = Self.request(s, "v1/chat/completions", method: "POST",
                               json: .object([
                                "model": .string("test-llm"),
                                "stream": .bool(true),
                                "stream_options": .object(["include_usage": .bool(true)]),
                                "tools": .array([.object([
                                    "type": .string("function"),
                                    "function": .object(["name": .string("bash")]),
                                ])]),
                                "tool_choice": .string("auto"),
                                "messages": .array([.object([
                                    "role": .string("user"),
                                    "content": .string("x")])]),
                               ]))
        req.timeoutInterval = 30
        let (data, response) = try await s.http.data(for: req)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"),
                       "text/event-stream")
        let body = String(decoding: data, as: UTF8.self)
        // Chunked transfer is reassembled by URLSession; frames remain.
        XCTAssertTrue(body.hasPrefix("data: "), body)
        XCTAssertTrue(body.hasSuffix("data: [DONE]\n\n"), body)
        // Parse the frames for field assertions: Dictionary encoding order
        // is unspecified, so key-order substrings are not a contract.
        var chunks: [JSONValue] = []
        for frame in body.components(separatedBy: "\n\n") {
            guard frame.hasPrefix("data: ") else { continue }
            let payload = frame.dropFirst(6)
            if payload == "[DONE]" { continue }
            chunks.append(try JSONValue.decode(Data(payload.utf8)))
        }
        func deltas(_ key: String) -> [JSONValue] {
            chunks.compactMap {
                $0.objectValue?["choices"]?.arrayValue?.first?
                    .objectValue?["delta"]?.objectValue?[key]
            }
        }
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["object"] == .string("chat.completion.chunk")
        }, body)
        XCTAssertTrue(deltas("role").contains(.string("assistant")), body)
        XCTAssertTrue(deltas("content").contains(.string("hi")), body)
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["choices"]?.arrayValue?.first?.objectValue?["delta"]?
                .objectValue?["tool_calls"]?.arrayValue?.first?.objectValue?["function"]?
                .objectValue?["name"] == .string("bash")
        }, body)
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["choices"]?.arrayValue?.first?
                .objectValue?["finish_reason"] == .string("tool_calls")
        }, body)
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["usage"]?.objectValue?["prompt_tokens"] == .int(3)
        }, body)
        // The provider saw the declared tool spec.
        XCTAssertEqual(provider.invocations.first?.tools.first?.name, "bash")
    }

    // MARK: events + disconnect

    func testEventsStreamAndDisconnect() async throws {
        let s = try await startServer()
        defer { s.stop() }
        guard let (cookie, _, _, _) = try await Self.bootstrap(s) else {
            XCTFail("bootstrap failed"); return
        }
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
        try await expectEqual(try await Self.status(s, Self.request(s, "api/status")).0, 200)
    }

    /// Marker-free local calls cancel under the fixed administration
    /// consumer; browser-marked calls keep the cookie+Origin+CSRF checks.
    func testJobCancelOverHTTP() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider()
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat"), provider: provider)
        let inflight = Task {
            try await Self.status(s, Self.request(
                s, "v1/chat/completions", method: "POST",
                json: .object(["model": .string("test-llm"),
                               "messages": .array([.object(["role": .string("user"),
                                                            "content": .string("x")])])])))
        }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        // A marker-free native cancel runs under the fixed administration
        // consumer: the device owner stops local work with no token.
        let cancelled = try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST")).0
        XCTAssertEqual(cancelled, 200)
        let result = try await inflight.value
        XCTAssertEqual(result.0, 503)   // cancelled -> OpenAI-shaped 503
        provider.finishAll()
        // A supplied Authorization header is ignored: it does not change
        // the principal or the cancel policy - same administration path.
        let ignoredAuth = try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST", token: agentToken)).0
        XCTAssertEqual(ignoredAuth, 200)
        // An Origin (any Origin) makes this a browser-style mutation: the
        // console guards take over and there is no native fallback.
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            origin: "http://evil.example")).0, 403)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            origin: Self.origin(s))).0, 401)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "api/jobs/job-1/cancel", method: "POST",
            fetchSite: "cross-site")).0, 403)
    }

    // MARK: client-disconnect cancellation

    /// Raw TCP POST returning the open connection so the test can drop it
    /// mid-flight; URLSession cannot express an abort without a timeout.
    private func rawPost(_ s: Server, _ path: String,
                         json: JSONValue) async throws -> NWConnection {
        let body = try json.encoded()
        var bytes = Data("POST \(path) HTTP/1.1\r\n".utf8)
        bytes.append(Data("Host: 127.0.0.1:\(s.port)\r\n".utf8))
        bytes.append(Data("Content-Type: application/json\r\n".utf8))
        bytes.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        bytes.append(body)
        let conn = NWConnection(host: "127.0.0.1",
                                port: NWEndpoint.Port(rawValue: s.port)!,
                                using: .tcp)
        let ready = Counter()
        conn.stateUpdateHandler = { state in
            if case .ready = state { ready.increment() }
        }
        conn.start(queue: .global())
        try await expectTrue(await pollUntil { ready.count == 1 },
                             "raw connection never became ready")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: bytes, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
        return conn
    }

    private func registerLLM(_ s: Server, _ provider: FakeLLMProvider) async {
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: provider.providerID,
                         kind: .llm, task: "chat"), provider: provider)
    }

    private func registerML(_ s: Server, _ predictor: FakeMLPredictor) async {
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "test-ml", providerID: predictor.providerID,
                         kind: .ml, task: "classify",
                         inputSchema: ["x": .number],
                         outputSchema: ["label": .string]), predictor: predictor)
    }

    private static let chatJSON: JSONValue = .object([
        "model": .string("test-llm"),
        "messages": .array([.object(["role": .string("user"),
                                     "content": .string("hi")])]),
    ])
    private static let predictJSON: JSONValue = .object([
        "model": .string("test-ml"),
        "task": .string("classify"),
        "inputs": .object(["x": .double(1)]),
    ])

    /// A client that vanishes while its model job is active cancels the
    /// provider cooperatively; the job ends cancelled and frees the slot.
    func testModelDisconnectCancelsActiveJob() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider(cooperative: true)
        await registerLLM(s, provider)
        let conn = try await rawPost(s, "/v1/chat/completions", json: Self.chatJSON)
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        conn.cancel()
        try await expectTrue(await pollUntil {
            provider.cancelledJobIDs == ["job-1"]
        }, "provider never recorded the disconnect cancel")
        try await expectTrue(await pollUntil {
            let snap = await s.stack.supervisor.admissionSnapshot()
            return snap.active == 0 && snap.pending == 0
        })
        let jobs = try await s.stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.id == "job-1" && $0.state == .cancelled })
    }

    /// A client that vanishes while queued never reaches the provider, even
    /// after the active slot frees.
    func testQueuedModelDisconnectNeverInvokesProvider() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider(cooperative: true)
        await registerLLM(s, provider)
        let conn1 = try await rawPost(s, "/v1/chat/completions", json: Self.chatJSON)
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        let conn2 = try await rawPost(s, "/v1/chat/completions", json: Self.chatJSON)
        try await expectTrue(await pollUntil {
            await s.stack.supervisor.admissionSnapshot().pending == 1
        }, "second request never queued")
        conn2.cancel()
        try await expectTrue(await pollUntil {
            await s.stack.supervisor.admissionSnapshot().pending == 0
        })
        // Finish the first job; the disconnected queued job must not launch.
        provider.finishNext()
        try await expectTrue(await pollUntil {
            await s.stack.supervisor.admissionSnapshot().active == 0
        })
        XCTAssertEqual(provider.invocations.count, 1)
        let jobs = try await s.stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.id == "job-2" && $0.state == .cancelled })
        conn1.cancel()
    }

    /// Same disconnect semantics for the typed-ML route.
    func testMLDisconnectCancelsActiveJob() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let predictor = FakeMLPredictor()
        await registerML(s, predictor)
        let conn = try await rawPost(s, "/api/ml/predictions", json: Self.predictJSON)
        try await expectTrue(await pollUntil { predictor.invocations.count == 1 })
        conn.cancel()
        try await expectTrue(await pollUntil {
            predictor.cancelledJobIDs == ["job-1"]
        }, "predictor never recorded the disconnect cancel")
        try await expectTrue(await pollUntil {
            let snap = await s.stack.supervisor.admissionSnapshot()
            return snap.active == 0 && snap.pending == 0
        })
        let jobs = try await s.stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.id == "job-1" && $0.state == .cancelled })
    }

    /// A queued ML request from a disconnected client is never invoked.
    func testQueuedMLDisconnectNeverInvokesPredictor() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let predictor = FakeMLPredictor()
        await registerML(s, predictor)
        let conn1 = try await rawPost(s, "/api/ml/predictions", json: Self.predictJSON)
        try await expectTrue(await pollUntil { predictor.invocations.count == 1 })
        let conn2 = try await rawPost(s, "/api/ml/predictions", json: Self.predictJSON)
        try await expectTrue(await pollUntil {
            await s.stack.supervisor.admissionSnapshot().pending == 1
        }, "second request never queued")
        conn2.cancel()
        try await expectTrue(await pollUntil {
            await s.stack.supervisor.admissionSnapshot().pending == 0
        })
        predictor.finishNext()
        try await expectTrue(await pollUntil {
            await s.stack.supervisor.admissionSnapshot().active == 0
        })
        XCTAssertEqual(predictor.invocations.count, 1)
        let jobs = try await s.stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.id == "job-2" && $0.state == .cancelled })
        conn1.cancel()
    }

    /// Omitted max fields on the wire resolve against the declared profile
    /// cap before admission; an explicit over-cap value is refused.
    func testProfileCapDefaultsOverHTTP() async throws {
        let s = try await startServer()
        defer { s.stop() }
        let provider = FakeLLMProvider(content: "ok", autoFinish: true)
        await s.stack.supervisor.registerModel(
            ModelProfile(alias: "capped-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat", maxOutputTokens: 32),
            provider: provider)
        let message: JSONValue = .object(["role": .string("user"),
                                          "content": .string("hi")])
        let (ok, _, _) = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            json: .object(["model": .string("capped-llm"),
                           "messages": .array([message])])))
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(provider.invocations.count, 1)
        XCTAssertEqual(provider.invocations[0].maxOutputTokens, 32)
        try await expectEqual(try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            json: .object(["model": .string("capped-llm"),
                           "messages": .array([message]),
                           "max_tokens": .int(33)]))).0, 400)
        XCTAssertEqual(provider.invocations.count, 1)
    }
}
