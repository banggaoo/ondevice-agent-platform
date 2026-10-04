import XCTest
import PlatformTestSupport
@testable import PlatformServing
@testable import PlatformCore

/// ACP run safety: atomic one-turn claims, bound model aliases, per-run
/// token budgets, cancellation through held storage inserts, and
/// noncooperative harness quarantine after the deadline.
final class ACPHardeningTests: XCTestCase {

    private actor LineSink {
        private(set) var lines: [JSONValue] = []
        func append(_ v: JSONValue) { lines.append(v) }
        func response(id: JSONValue) -> JSONValue? {
            lines.first { $0.objectValue?["id"] == id }
        }
        func updates() -> [JSONValue] {
            lines.filter {
                $0.objectValue?["method"]?.stringValue == "session/update"
            }
        }
    }

    /// Suspended-until-released gate for harness and storage seams.
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

    /// Lock-confined error-code capture for harness closures.
    private final class CodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ErrorCode?
        func set(_ code: ErrorCode?) {
            lock.lock(); value = code; lock.unlock()
        }
        var code: ErrorCode? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    /// Lock-confined capture for values handed to a harness once.
    private final class RefBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T?
        func set(_ new: T) { lock.lock(); v = new; lock.unlock() }
        var value: T? { lock.lock(); defer { lock.unlock() }; return v }
    }

    private func stackAndService() async throws
        -> (TestStack, ACPService, LineSink) {
        let stack = try await makeStack()
        await registerStandardPrincipals(stack.supervisor)
        let acp = ACPService(supervisor: stack.supervisor, clock: stack.clock.clock)
        return (stack, acp, LineSink())
    }

    private func register(_ stack: TestStack, agentID: String,
                          modelProfileAlias: String? = nil,
                          harness: @escaping @Sendable ([PromptBlock], AgentContext,
                                                       @escaping @Sendable (AgentEvent) -> Void) async -> AgentStopReason) async {
        await stack.supervisor.agentService.register(
            profile: AgentProfile(id: agentID, version: 1,
                                  harnessID: "test.closure", harnessVersion: 1,
                                  stateSchemaVersion: 1,
                                  modelProfileAlias: modelProfileAlias,
                                  implementationRef: "test:\(agentID)"),
            harness: .init(make: { ClosureHarness(harness) },
                           harnessID: "test.closure", harnessVersion: 1))
    }

    private func newSession(_ acp: ACPService, _ sink: LineSink,
                            conn: String = "c1", requestID: Int = 1) async throws -> String {
        await acp.handle(connectionID: conn, message: JSONRPC.request(
            id: .int(Int64(requestID)), method: "session/new",
            params: .object(["cwd": .string("/"), "mcpServers": .array([])])),
            emit: { await sink.append($0) })
        guard let sessionID = await sink.response(id: .int(Int64(requestID)))?
            .objectValue?["result"]?.objectValue?["sessionId"]?.stringValue else {
            throw ExpectationFailed("sessionId", "no session created")
        }
        return sessionID
    }

    private func prompt(_ id: Int, session: String,
                        text: String = "go") -> JSONValue {
        JSONRPC.request(id: .int(Int64(id)), method: "session/prompt",
                        params: .object([
                            "sessionId": .string(session),
                            "prompt": .array([.object(["type": .string("text"),
                                                       "text": .string(text)])]),
                        ]))
    }

    private func stopReason(_ sink: LineSink, id: Int) async -> String? {
        await sink.response(id: .int(Int64(id)))?
            .objectValue?["result"]?.objectValue?["stopReason"]?.stringValue
    }

    // MARK: turn claiming

    /// A second prompt on a session already running is a conflict; once the
    /// first turn ends the session accepts the next prompt.
    func testConcurrentPromptIsConflict() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let gate = Gate()
        let started = Counter()
        await register(stack, agentID: "test.waiter") { _, _, emit in
            started.increment()
            await gate.wait()
            emit(.messageChunk("done"))
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.waiter",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)

        let firstPrompt = prompt(3, session: sessionID)
        let first = Task {
            await acp.handle(connectionID: "c1", message: firstPrompt,
                             emit: { await sink.append($0) })
        }
        try await expectTrue(await pollUntil { started.count == 1 },
                             "first turn never started")
        await acp.handle(connectionID: "c1", message: prompt(4, session: sessionID),
                         emit: { await sink.append($0) })
        let denied = await sink.response(id: .int(4))
        XCTAssertNotNil(denied?.objectValue?["error"],
                        "concurrent prompt must be an error")

        gate.release()
        await first.value
        try await expectEqual(await stopReason(sink, id: 3), "end_turn")
        // Released session takes the next turn.
        await acp.handle(connectionID: "c1", message: prompt(5, session: sessionID),
                         emit: { await sink.append($0) })
        try await expectEqual(await stopReason(sink, id: 5), "end_turn")
    }

    /// A caller-supplied token that is already cancelled answers the
    /// standard cancelled result before the harness ever runs: no slot is
    /// held, no update is emitted, no model job exists.
    func testPreCancelledTokenAnswersCancelledNoWork() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let started = Counter()
        await register(stack, agentID: "test.never") { _, _, _ in
            started.increment()
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.never",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)
        let token = CancellationToken()
        token.cancel()
        await acp.handle(connectionID: "c1", message: prompt(3, session: sessionID),
                         cancellation: token,
                         emit: { await sink.append($0) })
        try await expectEqual(await stopReason(sink, id: 3), "cancelled")
        XCTAssertEqual(started.count, 0)
        try await expectEqual(await acp.liveRunCount(), 0)
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.isEmpty)
    }

    /// The turn token is per-call state: cancelling the finished turn's
    /// token can never reach a later prompt on the same ACP session.
    func testFinishedTurnTokenCannotCancelNextPrompt() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let gate = Gate()
        let started = Counter()
        await register(stack, agentID: "test.twice") { _, _, emit in
            started.increment()
            await gate.wait()
            emit(.messageChunk("ok"))
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.twice",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)

        let tokenA = CancellationToken()
        let msgA = prompt(3, session: sessionID)
        let turnA = Task {
            await acp.handle(connectionID: "c1", message: msgA,
                             cancellation: tokenA,
                             emit: { await sink.append($0) })
        }
        try await expectTrue(await pollUntil { started.count == 1 },
                             "first turn never started")
        gate.release()
        await turnA.value
        try await expectEqual(await stopReason(sink, id: 3), "end_turn")

        // A deferred-callback design could let this cancel poison the
        // session's next turn; the per-call token cannot.
        tokenA.cancel()
        let msgB = prompt(4, session: sessionID)
        let tokenB = CancellationToken()
        await acp.handle(connectionID: "c1", message: msgB,
                         cancellation: tokenB,
                         emit: { await sink.append($0) })
        try await expectEqual(await stopReason(sink, id: 4), "end_turn")
        XCTAssertEqual(started.count, 2)
    }

    // MARK: bound model alias

    /// A profile-bound agent can only reach its pinned alias through the
    /// scoped model client; another alias is refused before the provider.
    func testBoundAliasCannotSelectOtherModel() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let allowed = FakeLLMProvider(providerID: "fake-llm", autoFinish: true)
        let other = FakeLLMProvider(providerID: "other-llm", autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "allowed-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat"), provider: allowed)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "other-llm", providerID: "other-llm",
                         kind: .llm, task: "chat"), provider: other)
        let errBox = CodeBox()
        await register(stack, agentID: "test.bound",
                       modelProfileAlias: "allowed-llm") { _, context, emit in
            do {
                _ = try await context.model.complete(ChatRequest(
                    model: "other-llm",
                    messages: [ChatMessage(role: .user, parts: ["hi"])],
                    maxOutputTokens: 8))
            } catch let e as PlatformError {
                errBox.set(e.code)
            } catch {
                errBox.set(nil)
            }
            let ok = try? await context.model.complete(ChatRequest(
                model: "allowed-llm",
                messages: [ChatMessage(role: .user, parts: ["hi"])],
                maxOutputTokens: 8))
            emit(.messageChunk(ok?.content ?? "failed"))
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.bound",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)
        await acp.handle(connectionID: "c1", message: prompt(3, session: sessionID),
                         emit: { await sink.append($0) })
        try await expectEqual(await stopReason(sink, id: 3), "end_turn")
        XCTAssertEqual(errBox.code, .invalidRequest)
        XCTAssertEqual(allowed.invocations.count, 1)
        XCTAssertTrue(other.invocations.isEmpty)
    }

    // MARK: run token budget

    /// Model reservations are charged against the per-run bound: four
    /// 512-token calls fit the 2048 budget, the fifth is capacity-limited.
    func testRunModelBudgetBounded() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: provider.providerID,
                         kind: .llm, task: "chat"), provider: provider)
        let errBox = CodeBox()
        await register(stack, agentID: "test.budget",
                       modelProfileAlias: "test-llm") { _, context, _ in
            for _ in 0..<4 {
                _ = try? await context.model.complete(ChatRequest(
                    model: "test-llm",
                    messages: [ChatMessage(role: .user, parts: ["hi"])],
                    maxOutputTokens: 512))
            }
            do {
                _ = try await context.model.complete(ChatRequest(
                    model: "test-llm",
                    messages: [ChatMessage(role: .user, parts: ["hi"])],
                    maxOutputTokens: 512))
            } catch let e as PlatformError {
                errBox.set(e.code)
            } catch {
                errBox.set(nil)
            }
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.budget",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)
        await acp.handle(connectionID: "c1", message: prompt(3, session: sessionID),
                         emit: { await sink.append($0) })
        try await expectEqual(await stopReason(sink, id: 3), "end_turn")
        XCTAssertEqual(errBox.code, .capacityLimited)
        XCTAssertEqual(provider.invocations.count, 4)
    }

    // MARK: cancellation

    /// A cancel landing while a child model submit is suspended inside
    /// storage insertion cancels the job without ever invoking the provider.
    func testCancelDuringHeldInsertNeverLaunches() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: provider.providerID,
                         kind: .llm, task: "chat"), provider: provider)
        await register(stack, agentID: "test.modeluser",
                       modelProfileAlias: "test-llm") { _, context, _ in
            do {
                _ = try await context.model.complete(ChatRequest(
                    model: "test-llm",
                    messages: [ChatMessage(role: .user, parts: ["hi"])],
                    maxOutputTokens: 8))
                return .endTurn
            } catch let e as PlatformError where e.code == .cancelled {
                return .cancelled
            } catch {
                return .error
            }
        }
        let gate = Gate()
        await stack.supervisor.setInsertGate { await gate.wait() }
        try await acp.bind(connectionID: "c1", agentID: "test.modeluser",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)
        let runPrompt = prompt(3, session: sessionID)
        let run = Task {
            await acp.handle(connectionID: "c1", message: runPrompt,
                             emit: { await sink.append($0) })
        }
        try await expectTrue(await pollUntil {
            await stack.supervisor.insertionReservations == 1
        }, "child submit never reached held insert")
        await acp.handle(connectionID: "c1", message: JSONRPC.notification(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])),
            emit: { await sink.append($0) })
        gate.release()
        await run.value
        try await expectEqual(await stopReason(sink, id: 3), "cancelled")
        XCTAssertTrue(provider.invocations.isEmpty,
                      "cancelled-during-insert child invoked the provider")
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.state == .cancelled })
    }

    /// A noncooperative harness outlives the deadline: the prompt answers a
    /// deadline error without waiting (never a fabricated `cancelled`), the
    /// session stays claimed until the harness actually returns, and a late
    /// emission is dropped.
    func testDeadlineQuarantinesNoncooperativeHarness() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let gate = Gate()
        let finished = Counter()
        await register(stack, agentID: "test.hang") { _, _, emit in
            // Noncooperative: ignores context.isCancelled and its own task
            // cancellation until the test releases it.
            await gate.wait()
            emit(.messageChunk("late"))
            finished.increment()
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.hang",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)

        let hangPrompt = prompt(3, session: sessionID)
        let run = Task {
            await acp.handle(connectionID: "c1", message: hangPrompt,
                             emit: { await sink.append($0) })
        }
        try await expectTrue(await pollUntil {
            stack.clock.pendingSleepers >= 1
        }, "deadline timer never armed")
        stack.clock.advance(by: PlatformLimits.agentDeadlineSeconds + 1)
        await run.value
        let deadlineError = await sink.response(id: .int(3))
        XCTAssertNil(deadlineError?.objectValue?["result"],
                     "deadline must not fabricate a stop reason")
        XCTAssertEqual(deadlineError?.objectValue?["error"]?.objectValue?["data"]?
            .objectValue?["platformCode"], .string("deadline_exceeded"))

        // Session is still claimed while the harness runs.
        await acp.handle(connectionID: "c1", message: prompt(4, session: sessionID),
                         emit: { await sink.append($0) })
        let denied = await sink.response(id: .int(4))
        XCTAssertNotNil(denied?.objectValue?["error"],
                        "quarantined session accepted a new turn")

        // Releasing the harness lets teardown run; the late emission is
        // gated off and never reaches the client.
        gate.release()
        try await expectTrue(await pollUntil { finished.count == 1 },
                             "harness never finished")
        // Teardown trails the harness return; retry the next turn briefly.
        var turn = 5
        var reason: String?
        for _ in 0..<50 {
            await acp.handle(connectionID: "c1",
                             message: prompt(turn, session: sessionID),
                             emit: { await sink.append($0) })
            if let r = await stopReason(sink, id: turn) {
                reason = r
                break
            }
            turn += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(reason, "end_turn",
                       "session stayed quarantined after harness completion")
        // Exactly one chunk total: the late turn-1 emission was dropped;
        // the surviving turn's run emitted once.
        let updateCount = await sink.updates().count
        XCTAssertEqual(updateCount, 1)
    }

    // MARK: bind

    func testBindRejectsDifferentPrincipalAndCapsConnections() async throws {
        let (stack, acp, _) = try await stackAndService()
        defer { stack.root.releaseLock() }
        await register(stack, agentID: "test.agent") { _, _, _ in .endTurn }
        try await acp.bind(connectionID: "c1", agentID: "test.agent",
                           principal: agentPrincipal)
        // Same connection, different principal id: conflict.
        do {
            try await acp.bind(connectionID: "c1", agentID: "test.agent",
                               principal: Principal(id: "agent-2", scope: .agent))
            XCTFail("expected conflict")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .conflict) }
        // Same principal rebinding to a different agent: conflict.
        do {
            try await acp.bind(connectionID: "c1", agentID: "other.agent",
                               principal: agentPrincipal)
            XCTFail("expected conflict")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .conflict) }

        // Total bound connections are capped.
        for i in 0..<(PlatformLimits.agentConnections - 1) {
            try await acp.bind(connectionID: "extra-\(i)", agentID: "test.agent",
                               principal: agentPrincipal)
        }
        do {
            try await acp.bind(connectionID: "overflow", agentID: "test.agent",
                               principal: agentPrincipal)
            XCTFail("expected capacityLimited")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .capacityLimited) }
    }

    /// A racing bind burst can never exceed the connection cap, and two
    /// agents racing the same connection id leave exactly one binding.
    func testConcurrentBindsRespectCapAndConflict() async throws {
        let (stack, acp, _) = try await stackAndService()
        defer { stack.root.releaseLock() }
        await register(stack, agentID: "test.agent") { _, _, _ in .endTurn }
        await register(stack, agentID: "other.agent") { _, _, _ in .endTurn }
        var accepted = 0
        var denied = 0
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<32 {
                group.addTask {
                    do {
                        try await acp.bind(connectionID: "burst-\(i)",
                                           agentID: "test.agent",
                                           principal: agentPrincipal)
                        return true
                    } catch { return false }
                }
            }
            for await ok in group {
                if ok { accepted += 1 } else { denied += 1 }
            }
        }
        XCTAssertEqual(accepted, PlatformLimits.agentConnections)
        XCTAssertEqual(denied, 32 - PlatformLimits.agentConnections)

        // Two agents racing one connection id: one binds, one conflicts.
        // A slot is freed first so the loser sees the binding, not the cap.
        await acp.connectionClosed("burst-0")
        var won = 0
        var conflicted = 0
        await withTaskGroup(of: Int.self) { group in
            for agent in ["test.agent", "other.agent"] {
                group.addTask {
                    do {
                        try await acp.bind(connectionID: "shared", agentID: agent,
                                           principal: agentPrincipal)
                        return 0
                    } catch let e as PlatformError where e.code == .conflict {
                        return 1
                    } catch { return 2 }
                }
            }
            for await r in group {
                if r == 0 { won += 1 } else if r == 1 { conflicted += 1 }
            }
        }
        XCTAssertEqual(won, 1)
        XCTAssertEqual(conflicted, 1)
    }

    // MARK: run teardown

    /// Normal termination retires the run state: a detached harness
    /// closure holding the context cannot reach the model or ML clients
    /// after end_turn, and a late emission is dropped.
    func testNormalTerminationRetiresRunState() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: provider.providerID,
                         kind: .llm, task: "chat"), provider: provider)
        let ctxBox = RefBox<AgentContext>()
        let emitBox = RefBox<@Sendable (AgentEvent) -> Void>()
        await register(stack, agentID: "test.normal",
                       modelProfileAlias: "test-llm") { _, context, emit in
            ctxBox.set(context)
            emitBox.set(emit)
            emit(.messageChunk("one"))
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.normal",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)
        await acp.handle(connectionID: "c1", message: prompt(3, session: sessionID),
                         emit: { await sink.append($0) })
        try await expectEqual(await stopReason(sink, id: 3), "end_turn")

        // The context is retired: model and ML calls answer cancelled and
        // no provider invocation ever happens.
        guard let context = ctxBox.value, let emit = emitBox.value else {
            return XCTFail("context never captured")
        }
        for attempt in 0..<2 {
            do {
                if attempt == 0 {
                    _ = try await context.model.complete(ChatRequest(
                        model: "test-llm",
                        messages: [ChatMessage(role: .user, parts: ["late"])],
                        maxOutputTokens: 8))
                } else {
                    _ = try await context.ml.predict(PredictionRequest(
                        model: "test-llm", task: "chat", inputs: [:]))
                }
                XCTFail("retired context reached a child client")
            } catch let e as PlatformError {
                XCTAssertEqual(e.code, .cancelled)
            }
        }
        XCTAssertTrue(provider.invocations.isEmpty)
        // A late emission is gated off and never reaches the client.
        emit(.messageChunk("late"))
        let settled = await pollUntil { await sink.updates().count > 1 }
        XCTAssertFalse(settled, "late emission reached the wire")
        let updateCount = await sink.updates().count
        XCTAssertEqual(updateCount, 1)
    }

    /// A saturated emission queue refuses work instead of silently
    /// truncating the answer: the turn reports error, not end_turn.
    func testEmissionOverflowTurnsRunToError() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        await register(stack, agentID: "test.chatty") { _, _, emit in
            for _ in 0..<70 { emit(.messageChunk("chunk")) }
            return .endTurn
        }
        try await acp.bind(connectionID: "c1", agentID: "test.chatty",
                           principal: agentPrincipal)
        let sessionID = try await newSession(acp, sink)
        // The sender stalls on the first chunk so the backlog fills the
        // 64-slot queue; releases once the run is waiting on the drain.
        let emitGate = Gate()
        let attempts = Counter()
        let msg3 = prompt(3, session: sessionID)
        let run = Task {
            await acp.handle(connectionID: "c1", message: msg3,
                             emit: { v in
                                 attempts.increment()
                                 await emitGate.wait()
                                 await sink.append(v)
                             })
        }
        try await expectTrue(await pollUntil { attempts.count >= 1 },
                           "first emission never reached the blocked sender")
        emitGate.release()
        await run.value
        let overflowError = await sink.response(id: .int(3))
        XCTAssertNil(overflowError?.objectValue?["result"],
                     "overflow must not fabricate a stop reason")
        XCTAssertEqual(overflowError?.objectValue?["error"]?.objectValue?["data"]?
            .objectValue?["platformCode"], .string("provider_unavailable"))
    }

    // MARK: emission queue unit bounds

    /// The bound counts outstanding work: 64 queued behind a blocked sender
    /// lease, the 65th is refused and recorded, drained work frees slots.
    func testEmissionQueueBoundsOutstanding() async throws {
        let queue = EmissionQueue()
        let gate = Gate()
        let count = Counter()
        XCTAssertTrue(queue.enqueue { await gate.wait(); count.increment() })
        for _ in 0..<63 {
            XCTAssertTrue(queue.enqueue { count.increment() })
        }
        XCTAssertFalse(queue.enqueue { count.increment() },
                       "65th outstanding emission must be refused")
        XCTAssertTrue(queue.overflowed)
        gate.release()
        await queue.drain()
        XCTAssertEqual(count.count, 64)
        queue.close()
        XCTAssertFalse(queue.enqueue { count.increment() })
    }

    /// Sequentially drained emissions never accumulate: 100 emissions
    /// through a drained queue all land without overflow.
    func testEmissionQueueDrainsIncrementally() async throws {
        let queue = EmissionQueue()
        let count = Counter()
        for _ in 0..<100 {
            XCTAssertTrue(queue.enqueue { count.increment() })
            await queue.drain()
        }
        XCTAssertEqual(count.count, 100)
        XCTAssertFalse(queue.overflowed)
        queue.close()
    }

    // MARK: quarantine budget

    /// Live and quarantined harnesses share the connection budget: a closed
    /// connection frees its binding but not the harness's slot, so repeated
    /// orphaned runs still bound the next turn until they really end.
    func testRunSlotsBoundQuarantinedHarnesses() async throws {
        let (stack, acp, sink) = try await stackAndService()
        defer { stack.root.releaseLock() }
        let gate = Gate()
        let started = Counter()
        await register(stack, agentID: "test.hung") { _, _, _ in
            started.increment()
            await gate.wait()
            return .endTurn
        }
        let conns = (0..<PlatformLimits.agentConnections).map { "h\($0)" }
        var sessions: [String] = []
        for (i, conn) in conns.enumerated() {
            try await acp.bind(connectionID: conn, agentID: "test.hung",
                               principal: agentPrincipal)
            sessions.append(try await newSession(acp, sink, conn: conn,
                                                 requestID: 100 + i))
        }
        let msgs = sessions.map { prompt(3, session: $0) }
        var turns: [Task<Void, Never>] = []
        for i in sessions.indices {
            turns.append(Task {
                await acp.handle(connectionID: conns[i], message: msgs[i],
                                 emit: { await sink.append($0) })
            })
        }
        try await expectTrue(await pollUntil {
            started.count == PlatformLimits.agentConnections
        }, "gated harnesses never all started")
        try await expectEqual(await acp.liveRunCount(),
                              PlatformLimits.agentConnections)
        // Closing one connection frees the binding; the gated harness
        // still holds its run slot.
        await acp.connectionClosed(conns[0])
        try await acp.bind(connectionID: "extra", agentID: "test.hung",
                           principal: agentPrincipal)
        let extraSession = try await newSession(acp, sink, conn: "extra",
                                                requestID: 200)
        await acp.handle(connectionID: "extra",
                         message: prompt(99, session: extraSession),
                         emit: { await sink.append($0) })
        let denied = await sink.response(id: .int(99))
        XCTAssertNotNil(denied?.objectValue?["error"],
                        "17th live/quarantined run must be capacity-limited")
        // Releasing the harnesses frees slots and the next turn runs.
        gate.release()
        for t in turns { await t.value }
        try await expectTrue(await pollUntil { await acp.liveRunCount() == 0 },
                           "run slots never released")
        let sessionID2 = try await newSession(acp, sink, conn: "extra",
                                              requestID: 201)
        await acp.handle(connectionID: "extra",
                         message: prompt(4, session: sessionID2),
                         emit: { await sink.append($0) })
        try await expectEqual(await stopReason(sink, id: 4), "end_turn")
    }
}
