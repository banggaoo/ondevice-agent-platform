import XCTest
import PlatformTestSupport
@testable import PlatformServing
@testable import PlatformCore

/// Console Operator bridge: the opt-in read-only Operator is reachable only
/// through the cookie-authenticated console route, under a fixed scoped
/// in-process consumer, reusing the shared ACP service. Every model-backed
/// case uses the exact prompt "Explain runtime status.".
final class ConsoleOperatorTests: XCTestCase {

    private static let question = "Explain runtime status."

    struct Server {
        let stack: TestStack
        let server: HTTPServer
        let router: Router
        let acp: ACPService
        let port: UInt16
        let base: URL
        let http: URLSession
        let provider: FakeLLMProvider?

        func stop() { server.stop(); stack.root.releaseLock() }
    }

    /// Server with a fake MLX route bound to the runtime Operator and the
    /// console consumer wired exactly like `serve --enable-operator`.
    private func startServer(operatorEnabled: Bool = true,
                             provider: FakeLLMProvider? = nil) async throws -> Server {
        let stack = try await makeStack()
        await registerStandardPrincipals(stack.supervisor)
        let fake = provider ?? FakeLLMProvider(providerID: MLXProviderContract.id,
                                               autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "qwen3.8-9b", providerID: MLXProviderContract.id,
                         kind: .llm, task: "chat", purposes: ["runtime-explanation"],
                         capabilities: ["text"], maxOutputTokens: 4096),
            provider: fake)
        var principal: Principal?
        if operatorEnabled {
            try await stack.supervisor.registerRuntimeOperator(modelAlias: "qwen3.8-9b")
            principal = await stack.supervisor.registerConsoleOperatorConsumer()
        }
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
                            acp: acp, port: port, clock: stack.clock.clock,
                            consoleOperatorPrincipal: principal)
        ref.assign(router)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        return Server(stack: stack, server: server, router: router, acp: acp,
                      port: port, base: URL(string: "http://127.0.0.1:\(port)")!,
                      http: URLSession(configuration: config), provider: fake)
    }

    private static func request(_ s: Server, _ path: String,
                                method: String = "GET", token: String? = nil,
                                cookie: String? = nil, origin: String? = nil,
                                csrf: String? = nil, fetchSite: String? = nil,
                                json: JSONValue? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: s.base.absoluteString + "/" + path)!)
        r.httpMethod = method
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

    private static func status(_ s: Server, _ r: URLRequest) async throws
        -> (Int, JSONValue?) {
        let (data, response) = try await s.http.data(for: r)
        return ((response as! HTTPURLResponse).statusCode, try? JSONValue.decode(data))
    }

    private static func bootstrap(_ s: Server) async throws
        -> (cookie: String, csrf: String)? {
        let (code, body) = try await Self.status(s, Self.request(
            s, "api/session", method: "POST",
            origin: Self.origin(s), json: .object([:])))
        guard code == 200, let csrf = body?.objectValue?["csrf"]?.stringValue else {
            return nil
        }
        return ("platform_session=\(body?.objectValue?["session"]?.stringValue ?? "")",
                csrf)
    }

    private static func ask(_ s: Server, cookie: String, csrf: String,
                            body: JSONValue? = nil) async throws -> (Int, JSONValue?) {
        try await Self.status(s, Self.request(
            s, "api/console/operator/prompt", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: csrf,
            json: body ?? .object(["text": .string(question)])))
    }

    // MARK: positive path

    /// An enabled Operator answers through the fake MLX route exactly once,
    /// pinned to qwen3.8-9b with the bounded output cap and no tools.
    func testEnabledOperatorAnswersOnce() async throws {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       autoFinish: true)
        let s = try await startServer(provider: provider)
        defer { s.stop() }
        guard let (cookie, csrf) = try await Self.bootstrap(s) else {
            return XCTFail("bootstrap failed")
        }
        let (code, body) = try await Self.ask(s, cookie: cookie, csrf: csrf)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(body?.objectValue?["agent"], .string("operator"))
        XCTAssertEqual(body?.objectValue?["model"], .string("qwen3.8-9b"))
        XCTAssertEqual(body?.objectValue?["stopReason"], .string("end_turn"))
        XCTAssertFalse((body?.objectValue?["text"]?.stringValue ?? "").isEmpty)

        XCTAssertEqual(provider.invocations.count, 1)
        let call = provider.invocations[0]
        XCTAssertEqual(call.model, "qwen3.8-9b")
        XCTAssertEqual(call.maxOutputTokens, 512)
        XCTAssertEqual(call.temperature, 0)
        XCTAssertTrue(call.tools.isEmpty)
        XCTAssertEqual(call.messages.count, 3)
        XCTAssertEqual(call.messages.last?.parts.last, Self.question)
    }

    /// The pinned session is reused across questions on the same cookie.
    func testPinnedSessionReusedAcrossQuestions() async throws {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       autoFinish: true)
        let s = try await startServer(provider: provider)
        defer { s.stop() }
        guard let (cookie, csrf) = try await Self.bootstrap(s) else {
            return XCTFail("bootstrap failed")
        }
        for _ in 0..<2 {
            let (code, body) = try await Self.ask(s, cookie: cookie, csrf: csrf)
            XCTAssertEqual(code, 200)
            XCTAssertEqual(body?.objectValue?["stopReason"], .string("end_turn"))
        }
        XCTAssertEqual(provider.invocations.count, 2)
        // One ACP connection serves both questions.
        try await expectEqual(await s.acp.connectionCount(), 1)
    }

    // MARK: absence and denial

    /// Without the opt-in principal the route answers 503 and no model is
    /// ever invoked.
    func testAbsentOperatorIs503NoLLM() async throws {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       autoFinish: true)
        let s = try await startServer(operatorEnabled: false, provider: provider)
        defer { s.stop() }
        guard let (cookie, csrf) = try await Self.bootstrap(s) else {
            return XCTFail("bootstrap failed")
        }
        let (code, _) = try await Self.ask(s, cookie: cookie, csrf: csrf)
        XCTAssertEqual(code, 503)
        XCTAssertTrue(provider.invocations.isEmpty)
    }

    /// Foreign Origin, missing CSRF, and missing cookie are all refused
    /// before any agent work.
    func testOriginCSRFCookieDenials() async throws {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       autoFinish: true)
        let s = try await startServer(provider: provider)
        defer { s.stop() }
        guard let (cookie, csrf) = try await Self.bootstrap(s) else {
            return XCTFail("bootstrap failed")
        }
        let body = JSONValue.object(["text": .string(Self.question)])
        // Foreign Origin.
        var (code, _) = try await Self.status(s, Self.request(
            s, "api/console/operator/prompt", method: "POST",
            cookie: cookie, origin: "http://evil.local", csrf: csrf, json: body))
        XCTAssertEqual(code, 403)
        // Missing CSRF.
        (code, _) = try await Self.status(s, Self.request(
            s, "api/console/operator/prompt", method: "POST",
            cookie: cookie, origin: Self.origin(s), json: body))
        XCTAssertEqual(code, 403)
        // Missing cookie.
        (code, _) = try await Self.status(s, Self.request(
            s, "api/console/operator/prompt", method: "POST",
            origin: Self.origin(s), csrf: csrf, json: body))
        XCTAssertEqual(code, 401)
        // Cross-site fetch marker fails closed.
        (code, _) = try await Self.status(s, Self.request(
            s, "api/console/operator/prompt", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: csrf,
            fetchSite: "cross-site", json: body))
        XCTAssertEqual(code, 403)
        XCTAssertTrue(provider.invocations.isEmpty)
    }

    /// Unknown keys and oversized/blank text are refused before the harness.
    func testUnsupportedFieldsAndOversizedText() async throws {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       autoFinish: true)
        let s = try await startServer(provider: provider)
        defer { s.stop() }
        guard let (cookie, csrf) = try await Self.bootstrap(s) else {
            return XCTFail("bootstrap failed")
        }
        var (code, _) = try await Self.ask(s, cookie: cookie, csrf: csrf,
            body: .object(["text": .string(Self.question),
                           "model": .string("admin")]))
        XCTAssertEqual(code, 400)
        (code, _) = try await Self.ask(s, cookie: cookie, csrf: csrf,
            body: .object(["text": .string("   ")]))
        XCTAssertEqual(code, 400)
        (code, _) = try await Self.ask(s, cookie: cookie, csrf: csrf,
            body: .object(["text": .string(String(repeating: "x", count: 17 * 1024))]))
        XCTAssertEqual(code, 413)
        XCTAssertTrue(provider.invocations.isEmpty)
    }

    /// The generic local model API needs no API credential: a bare POST
    /// reaches the provider, and a console cookie adds nothing. The
    /// separate console Operator principal still holds only its three
    /// internal grants and can never administrate.
    func testLocalModelAPINeedsNoCredentialAndOperatorStaysScoped() async throws {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       autoFinish: true)
        let s = try await startServer(provider: provider)
        defer { s.stop() }
        let body: JSONValue = .object([
            "model": .string("qwen3.8-9b"),
            "messages": .array([.object([
                "role": .string("user"), "content": .string("x")])]),
        ])
        let (bare, _) = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST", json: body))
        XCTAssertEqual(bare, 200)
        XCTAssertEqual(provider.invocations.count, 1)
        guard let (cookie, csrf) = try await Self.bootstrap(s) else {
            return XCTFail("bootstrap failed")
        }
        let (withCookie, _) = try await Self.status(s, Self.request(
            s, "v1/chat/completions", method: "POST",
            cookie: cookie, origin: Self.origin(s), csrf: csrf, json: body))
        XCTAssertEqual(withCookie, 200)
        // The console Operator consumer is internal: it cannot read or
        // stop administration no matter what a browser presents.
        let operator_ = await s.stack.supervisor.registerConsoleOperatorConsumer()
        try await expectPlatformError(.forbidden) {
            try await s.stack.supervisor.require(.adminRead, principal: operator_)
        }
        try await expectPlatformError(.forbidden) {
            try await s.stack.supervisor.require(.adminStop, principal: operator_)
        }
    }

    // MARK: scoped principal

    /// The fixed console consumer holds only the three scoped grants:
    /// agentRun, agentStatusRead, llmInfer - never admin or typed-ML.
    func testConsolePrincipalScopeIsMinimal() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let p = await stack.supervisor.registerConsoleOperatorConsumer()
        XCTAssertEqual(p.id, "console-operator")
        XCTAssertEqual(p.scope, .agent)
        try await expectTrue(await stack.supervisor.has(.agentRun, principal: p), "")
        try await expectTrue(await stack.supervisor.has(.agentStatusRead, principal: p), "")
        try await expectTrue(await stack.supervisor.has(.llmInfer, principal: p), "")
        try await expectFalse(await stack.supervisor.has(.adminRead, principal: p), "")
        try await expectFalse(await stack.supervisor.has(.adminStop, principal: p), "")
        try await expectFalse(await stack.supervisor.has(.mlPredict, principal: p), "")
    }

    // MARK: concurrency and cancellation (bridge seam)

    /// Suspended-until-released gate for deterministic mid-commit races.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if released { lock.unlock(); cont.resume(); return }
                waiters.append(cont)
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for c in pending { c.resume() }
        }
    }

    /// Bridge + real ConsoleSessions + its own ACP service + a gated
    /// (non-autoFinish) fake MLX provider, wired exactly like
    /// `serve --enable-operator`. Sessions come from `sessions.create()` so
    /// lookup, expiry, and logout all exercise the real session store
    /// under the manual clock.
    private func makeFixture(_ stack: TestStack) async throws
        -> (bridge: ConsoleOperatorBridge, acp: ACPService,
            provider: FakeLLMProvider, sessions: ConsoleSessions) {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "qwen3.8-9b", providerID: MLXProviderContract.id,
                         kind: .llm, task: "chat", maxOutputTokens: 4096),
            provider: provider)
        try await stack.supervisor.registerRuntimeOperator(modelAlias: "qwen3.8-9b")
        let principal = await stack.supervisor.registerConsoleOperatorConsumer()
        let acp = ACPService(supervisor: stack.supervisor, clock: stack.clock.clock)
        let sessions = ConsoleSessions(clock: stack.clock.clock)
        let bridge = ConsoleOperatorBridge(
            acp: acp, supervisor: stack.supervisor, sessions: sessions,
            clock: stack.clock.clock, principal: principal)
        return (bridge, acp, provider, sessions)
    }

    private static let promptBody =
        Data("{\"text\":\"Explain runtime status.\"}".utf8)

    /// One in-flight question per console session: a concurrent second is a
    /// conflict and the provider is invoked exactly once.
    func testConcurrentPromptIs409OneCall() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, _, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        let first = Task { try await bridge.prompt(
            consoleSession: session, body: Self.promptBody,
            cancellation: CancellationToken()) }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 },
                             "first question never reached the provider")
        do {
            _ = try await bridge.prompt(consoleSession: session,
                                        body: Self.promptBody,
                                        cancellation: CancellationToken())
            XCTFail("concurrent question must conflict")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .conflict)
        }
        provider.finishAll()
        let reply = try await first.value
        XCTAssertEqual(reply.objectValue?["stopReason"], .string("end_turn"))
        XCTAssertEqual(provider.invocations.count, 1)
    }

    /// Request abort cancels this console session's own turn through the
    /// turn-scoped token; the gated provider observes cancellation and the
    /// reply rides the standard cancelled rail.
    func testAbortCancelsOwnTurn() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, _, provider, sessions) = try await makeFixture(stack)
        let token = CancellationToken()
        let session = try await sessions.create()
        let turn = Task { try await bridge.prompt(
            consoleSession: session, body: Self.promptBody,
            cancellation: token) }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 },
                             "question never reached the provider")
        token.cancel()
        let reply = try await turn.value
        XCTAssertEqual(reply.objectValue?["stopReason"], .string("cancelled"))
        provider.finishAll()
        try await expectTrue(await pollUntil { !provider.cancelledJobIDs.isEmpty },
                             "provider never saw the cancel")
    }

    /// A request cancelled before it reaches the bridge answers cancelled
    /// with pinned metadata, empty text, and no agent work at all.
    func testPreCancelledRequestDoesNoWork() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, acp, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        let token = CancellationToken()
        token.cancel()
        let reply = try await bridge.prompt(
            consoleSession: session, body: Self.promptBody, cancellation: token)
        XCTAssertEqual(reply.objectValue?["stopReason"], .string("cancelled"))
        XCTAssertEqual(reply.objectValue?["model"], .string("qwen3.8-9b"))
        XCTAssertEqual(reply.objectValue?["text"], .string(""))
        XCTAssertTrue(provider.invocations.isEmpty)
        try await expectEqual(await acp.connectionCount(), 0)
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.isEmpty)
    }

    /// Cancellation during a gated binding creation still answers
    /// cancelled and never submits a model call; the committed binding is
    /// kept for later turns since the console session itself is live.
    func testCancelDuringBindingSetupCancelsBeforeModel() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, _, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        let entered = Counter()
        let proceed = Gate()
        await bridge._testSetBeforeCommit {
            entered.increment()
            await proceed.wait()
        }
        let token = CancellationToken()
        let sessionRef = session
        let turn = Task { try await bridge.prompt(
            consoleSession: sessionRef, body: Self.promptBody,
            cancellation: token) }
        try await expectTrue(await pollUntil { entered.count == 1 },
                             "binding creation never reached the commit seam")
        token.cancel()
        proceed.release()
        let reply = try await turn.value
        XCTAssertEqual(reply.objectValue?["stopReason"], .string("cancelled"))
        XCTAssertEqual(reply.objectValue?["text"], .string(""))
        XCTAssertTrue(provider.invocations.isEmpty)
    }

    /// Turn-scoped cancellation: an old token cancelled after its turn
    /// completed can never hit a later turn reusing the same session.
    func testOldTokenCannotCancelNextTurn() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, _, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        let tokenA = CancellationToken()
        let sessionRef = session
        let turnA = Task { try await bridge.prompt(
            consoleSession: sessionRef, body: Self.promptBody,
            cancellation: tokenA) }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 },
                             "first question never reached the provider")
        provider.finishAll()
        let replyA = try await turnA.value
        XCTAssertEqual(replyA.objectValue?["stopReason"], .string("end_turn"))
        // The finished turn's token is cancelled: a deferred callback
        // design could kill turn B here; turn-scoped cancellation cannot.
        tokenA.cancel()
        let turnB = Task { try await bridge.prompt(
            consoleSession: sessionRef, body: Self.promptBody,
            cancellation: CancellationToken()) }
        try await expectTrue(await pollUntil { provider.invocations.count == 2 },
                             "second question never reached the provider")
        provider.finishAll()
        let replyB = try await turnB.value
        XCTAssertEqual(replyB.objectValue?["stopReason"], .string("end_turn"))
    }

    /// A second console cookie runs its own turn and can only cancel its
    /// own. With one active inference slot B's model call queues as
    /// pending; aborting B cancels that pending turn while A's gated run
    /// stays alive to finish normally.
    func testTwoCookiesCannotCancelEachOther() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, _, provider, sessions) = try await makeFixture(stack)
        let tokenB = CancellationToken()
        let sessionA = try await sessions.create()
        let sessionB = try await sessions.create()
        let turnA = Task { try await bridge.prompt(
            consoleSession: sessionA, body: Self.promptBody,
            cancellation: CancellationToken()) }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 },
                             "first question never reached the provider")
        let turnB = Task { try await bridge.prompt(
            consoleSession: sessionB, body: Self.promptBody,
            cancellation: tokenB) }
        tokenB.cancel()
        let replyB = try await turnB.value
        XCTAssertEqual(replyB.objectValue?["stopReason"], .string("cancelled"))
        provider.finishAll()
        let replyA = try await turnA.value
        XCTAssertEqual(replyA.objectValue?["stopReason"], .string("end_turn"))
    }

    /// Logout closes the binding: the ACP connection count drops and a new
    /// cookie creates a fresh connection.
    func testLogoutClosesBinding() async throws {
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       autoFinish: true)
        let s = try await startServer(provider: provider)
        defer { s.stop() }
        guard let (cookie, csrf) = try await Self.bootstrap(s) else {
            return XCTFail("bootstrap failed")
        }
        _ = try await Self.ask(s, cookie: cookie, csrf: csrf)
        try await expectEqual(await s.acp.connectionCount(), 1)
        let (code, _) = try await Self.status(s, Self.request(
            s, "api/logout", method: "POST", cookie: cookie,
            origin: Self.origin(s), csrf: csrf))
        XCTAssertEqual(code, 200)
        try await expectTrue(await pollUntil { await s.acp.connectionCount() == 0 },
                             "logout left the ACP binding alive")
    }

    /// A console session that expires while its binding is being created
    /// never leaves a resurrected ACP connection behind.
    func testExpiredSessionLeavesNoBinding() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, acp, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        stack.clock.advance(by: PlatformLimits.consoleSessionSeconds + 1)
        do {
            _ = try await bridge.prompt(consoleSession: session,
                                        body: Self.promptBody,
                                        cancellation: CancellationToken())
            XCTFail("expired session must not bind")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .sessionClosed)
        }
        try await expectEqual(await acp.connectionCount(), 0)
        XCTAssertTrue(provider.invocations.isEmpty)
    }

    /// A session logged out before the prompt begins fails sessionClosed:
    /// no binding, no connection, no model call.
    func testLogoutBeforePromptRefusesBinding() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, acp, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        await sessions.logout(session.id)
        do {
            _ = try await bridge.prompt(consoleSession: session,
                                        body: Self.promptBody,
                                        cancellation: CancellationToken())
            XCTFail("logged-out session must not bind")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .sessionClosed)
        }
        try await expectEqual(await acp.connectionCount(), 0)
        XCTAssertTrue(provider.invocations.isEmpty)
    }

    /// Two callers sharing one creation whose cookie is logged out
    /// mid-create both observe the same validated failure: sessionClosed,
    /// zero bindings, zero ACP connections, zero model calls. The commit
    /// seam makes the race deterministic.
    func testSharedCreationLogoutFailsBothWaiters() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, acp, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        let entered = Counter()
        let proceed = Gate()
        await bridge._testSetBeforeCommit {
            entered.increment()
            await proceed.wait()
        }
        let t1 = Task { try await bridge.prompt(
            consoleSession: session, body: Self.promptBody,
            cancellation: CancellationToken()) }
        let t2 = Task { try await bridge.prompt(
            consoleSession: session, body: Self.promptBody,
            cancellation: CancellationToken()) }
        try await expectTrue(await pollUntil { entered.count == 1 },
                             "shared creation never reached the commit seam")
        await sessions.logout(session.id)
        proceed.release()
        for t in [t1, t2] {
            do {
                _ = try await t.value
                XCTFail("logged-out shared creation must fail")
            } catch let e as PlatformError {
                XCTAssertEqual(e.code, .sessionClosed)
            }
        }
        try await expectEqual(await acp.connectionCount(), 0)
        try await expectEqual(await bridge.boundConnectionCount(), 0)
        XCTAssertTrue(provider.invocations.isEmpty)
    }

    /// The expiry twin of the shared-creation logout race: two callers on
    /// one creation whose session expires mid-create both fail
    /// sessionClosed and leave no connection, binding, or model call.
    func testSharedCreationExpiryFailsBothWaiters() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let (bridge, acp, provider, sessions) = try await makeFixture(stack)
        let session = try await sessions.create()
        let entered = Counter()
        let proceed = Gate()
        await bridge._testSetBeforeCommit {
            entered.increment()
            await proceed.wait()
        }
        let t1 = Task { try await bridge.prompt(
            consoleSession: session, body: Self.promptBody,
            cancellation: CancellationToken()) }
        let t2 = Task { try await bridge.prompt(
            consoleSession: session, body: Self.promptBody,
            cancellation: CancellationToken()) }
        try await expectTrue(await pollUntil { entered.count == 1 },
                             "shared creation never reached the commit seam")
        stack.clock.advance(by: PlatformLimits.consoleSessionSeconds + 1)
        proceed.release()
        for t in [t1, t2] {
            do {
                _ = try await t.value
                XCTFail("expired shared creation must fail")
            } catch let e as PlatformError {
                XCTAssertEqual(e.code, .sessionClosed)
            }
        }
        try await expectEqual(await acp.connectionCount(), 0)
        try await expectEqual(await bridge.boundConnectionCount(), 0)
        XCTAssertTrue(provider.invocations.isEmpty)
    }
}
