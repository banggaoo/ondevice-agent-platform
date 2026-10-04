import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// Admission reservations across storage suspension and the cancellation
/// token seam: a submit burst cannot overrun capacity, a request cancelled
/// while its insert is held records a cancelled row and never launches, a
/// queued cancel never reaches the provider, and a noncooperative provider
/// keeps its slot until it really finishes.
final class CoreHardeningTests: XCTestCase {

    private static func llmProfile(providerID: String = "fake-llm") -> ModelProfile {
        ModelProfile(alias: "test-llm", providerID: providerID,
                     kind: .llm, task: "chat")
    }

    private static func chatRequest() -> ChatRequest {
        ChatRequest(model: "test-llm",
                    messages: [ChatMessage(role: .user, parts: ["hi"])],
                    maxOutputTokens: 8)
    }

    /// Deterministic storage-insertion gate installed through the
    /// supervisor's test seam; held submissions suspend before the row write.
    private final class InsertGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if released {
                    lock.unlock()
                    cont.resume()
                    return
                }
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

    private func stack(provider: FakeLLMProvider) async throws -> TestStack {
        let stack = try await makeStack()
        await registerStandardPrincipals(stack.supervisor)
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        return stack
    }

    private func submit(_ stack: TestStack,
                        cancellation: CancellationToken? = nil)
        -> Task<Result<ChatResult, Error>, Never> {
        Task {
            do {
                return .success(try await stack.supervisor.submitLLM(
                    principal: modelPrincipal, request: Self.chatRequest(),
                    cancellation: cancellation))
            } catch { return .failure(error) }
        }
    }

    // MARK: burst admission reservations

    func testBurstAdmissionReservesAcrossInsertSuspension() async throws {
        let provider = FakeLLMProvider()
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        let gate = InsertGate()
        await stack.supervisor.setInsertGate { await gate.wait() }
        let capacity = PlatformLimits.activeInference + PlatformLimits.pendingInference

        var tasks: [Task<Result<ChatResult, Error>, Never>] = []
        for _ in 0..<20 {
            tasks.append(submit(stack))
        }
        // Outstanding inserts count toward the slot bound; the rest of the
        // burst is capacity-limited without touching storage.
        try await expectTrue(await pollUntil {
            await stack.supervisor.insertionReservations == capacity
        }, "reservations never reached capacity")
        let rejectedJobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(rejectedJobs.isEmpty,
                      "capacity-rejected submissions must not persist rows")
        gate.release()

        // Drain the provider for each admitted job as it dispatches.
        for step in 1...capacity {
            try await expectTrue(await pollUntil {
                provider.invocations.count >= step
            }, "admitted job \(step) never invoked the provider")
            provider.finishNext()
        }
        var ok = 0
        var rejected = 0
        for t in tasks {
            switch await t.value {
            case .success: ok += 1
            case .failure(let e):
                XCTAssertEqual((e as? PlatformError)?.code, .capacityLimited)
                rejected += 1
            }
        }
        XCTAssertEqual(ok, capacity)
        XCTAssertEqual(rejected, 20 - capacity)
        XCTAssertEqual(provider.invocations.count, capacity)
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertEqual(jobs.count, capacity)
        XCTAssertTrue(jobs.allSatisfy { $0.state == .completed })
        let snap = await stack.supervisor.admissionSnapshot()
        XCTAssertEqual(snap.active, 0)
        XCTAssertEqual(snap.pending, 0)
    }

    // MARK: cancellation token seam

    func testPreCancelledTokenNeverStoresOrInvokes() async throws {
        let provider = FakeLLMProvider()
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        let token = CancellationToken()
        token.cancel()
        switch await submit(stack, cancellation: token).value {
        case .failure(let e):
            XCTAssertEqual((e as? PlatformError)?.code, .cancelled)
        case .success: XCTFail("pre-cancelled submission must not succeed")
        }
        XCTAssertTrue(provider.invocations.isEmpty)
        let cancelledJobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(cancelledJobs.isEmpty)
    }

    func testCancelDuringHeldInsertRecordsCancelledWithoutProvider() async throws {
        let provider = FakeLLMProvider()
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        let gate = InsertGate()
        await stack.supervisor.setInsertGate { await gate.wait() }
        let token = CancellationToken()
        let task = submit(stack, cancellation: token)
        try await expectTrue(await pollUntil {
            await stack.supervisor.insertionReservations == 1
        }, "insert never reached the held gate")
        token.cancel()
        gate.release()
        switch await task.value {
        case .failure(let e):
            XCTAssertEqual((e as? PlatformError)?.code, .cancelled)
        case .success: XCTFail("cancelled-during-insert must not succeed")
        }
        XCTAssertTrue(provider.invocations.isEmpty)
        // The row exists and is recorded cancelled - the job was admitted,
        // then cancelled before queueing.
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.state, .cancelled)
        XCTAssertTrue(jobs.first?.providerFinished == true)
    }

    func testQueuedCancellationNeverInvokesProvider() async throws {
        let provider = FakeLLMProvider(cooperative: true)
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        let taskA = submit(stack)
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        let tokenB = CancellationToken()
        let taskB = submit(stack, cancellation: tokenB)
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().pending == 1
        }, "second job never queued")
        tokenB.cancel()
        switch await taskB.value {
        case .failure(let e):
            XCTAssertEqual((e as? PlatformError)?.code, .cancelled)
        case .success: XCTFail("queued-cancelled submission must not succeed")
        }
        // Releasing the active job must not dispatch the cancelled one.
        provider.finishNext()
        _ = await taskA.value
        XCTAssertEqual(provider.invocations.count, 1)
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.id == "job-2" && $0.state == .cancelled })
    }

    func testActiveCooperativeCancellation() async throws {
        let provider = FakeLLMProvider(cooperative: true)
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        let token = CancellationToken()
        let task = submit(stack, cancellation: token)
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        token.cancel()
        try await expectTrue(await pollUntil {
            provider.cancelledJobIDs == ["job-1"]
        }, "provider never recorded the cancel")
        switch await task.value {
        case .failure(let e):
            XCTAssertEqual((e as? PlatformError)?.code, .cancelled)
        case .success: XCTFail("cancelled active job must not succeed")
        }
        try await expectTrue(await pollUntil {
            let snap = await stack.supervisor.admissionSnapshot()
            return snap.active == 0 && snap.pending == 0
        })
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.id == "job-1" && $0.state == .cancelled })
    }

    func testNoncooperativeRetainsSlotThroughGrace() async throws {
        let provider = FakeLLMProvider(cooperative: false)
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        let token = CancellationToken()
        let task = submit(stack, cancellation: token)
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        token.cancel()
        // Grace timer plus the launch deadline timer must both be armed
        // before advancing the manual clock.
        try await expectTrue(await pollUntil { stack.clock.pendingSleepers >= 2 },
                             "grace timer never armed")
        stack.clock.advance(by: PlatformLimits.cancellationGraceSeconds + 1)
        switch await task.value {
        case .failure(let e):
            XCTAssertEqual((e as? PlatformError)?.code, .cancellationUnconfirmed)
        case .success: XCTFail("unconfirmed cancellation must not succeed")
        }
        // The slot stays retained and new inference is blocked.
        switch await submit(stack).value {
        case .failure(let e):
            XCTAssertEqual((e as? PlatformError)?.code, .providerUnavailable)
        case .success: XCTFail("blocked inference must not be admitted")
        }
        // Real provider completion releases the slot and unblocks.
        provider.finishNext()
        try await expectTrue(await pollUntil {
            let snap = await stack.supervisor.admissionSnapshot()
            return !snap.blocked && snap.active == 0
        })
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains {
            $0.id == "job-1" && $0.state == .cancellationUnconfirmed && $0.providerFinished
        })
    }

    /// A storage failure must release the admission reservation so later
    /// submissions are not permanently starved.
    func testFailedInsertReleasesReservation() async throws {
        let provider = FakeLLMProvider(autoFinish: true)
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        struct Boom: Error {}
        await stack.supervisor.setInsertGate { throw Boom() }
        switch await submit(stack).value {
        case .failure(let e):
            XCTAssertEqual((e as? PlatformError)?.code, .storageFailure)
        case .success: XCTFail("failed insert must not succeed")
        }
        try await expectEqual(await stack.supervisor.insertionReservations, 0)
        // Reservation released: a fresh submission admits normally.
        await stack.supervisor.setInsertGate(nil)
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                 request: Self.chatRequest())
        XCTAssertEqual(provider.invocations.count, 1)
        // Terminal persistence is a spawned task; poll rather than assume
        // the completed row has flushed before listJobs reads it.
        try await expectTrue(await pollUntil {
            let jobs = try await stack.supervisor.listJobs()
            return jobs.contains { $0.state == .completed }
        }, "completed row never persisted")
    }

    /// Settled durable rows are terminal and complete once all calls return.
    func testSettledJobsAreDurableAndTerminal() async throws {
        let provider = FakeLLMProvider(autoFinish: true)
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        var tasks: [Task<Result<ChatResult, Error>, Never>] = []
        for _ in 0..<3 { tasks.append(submit(stack)) }
        for t in tasks {
            switch await t.value {
            case .success: break
            case .failure(let e): XCTFail("settle failed: \(e)")
            }
        }
        try await expectTrue(await pollUntil {
            let jobs = try await stack.supervisor.listJobs()
            return jobs.count == 3 && jobs.allSatisfy { $0.isTerminal }
        }, "jobs never settled to durable terminal rows")
    }

    // MARK: token observer semantics

    /// Registration racing cancellation fires each handler at most once,
    /// and a pre-cancelled token still fires a late registration inline.
    func testConcurrentObserverCancelFiresAtMostOnce() async {
        for _ in 0..<100 {
            let token = CancellationToken()
            let counter = Counter()
            let observer = Task { token.observe { counter.increment() } }
            let canceller = Task { token.cancel() }
            _ = await (observer.value, canceller.value)
            XCTAssertEqual(counter.count, 1,
                           "raced observe+cancel must fire exactly once")
            token.observe { counter.increment() }
            token.cancel()
            XCTAssertEqual(counter.count, 2)
        }
    }

    func testObserverRegistrationCancelRaceFiresExactlyOnce() {
        let token = CancellationToken()
        let counter = Counter()
        token.observe { counter.increment() }
        token.cancel()
        // Registration after cancel fires the handler once, inline.
        token.observe { counter.increment() }
        token.cancel()   // idempotent
        XCTAssertEqual(counter.count, 2)
    }

    func testReentrantObserverDoesNotDeadlock() {
        let token = CancellationToken()
        let counter = Counter()
        token.observe {
            counter.increment()
            // Reentrant registration and cancel inside a running handler:
            // handlers always run outside the lock.
            token.observe { counter.increment() }
            token.cancel()
        }
        token.cancel()
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: deferred queue bound

    private static func deferredSnapshot(_ stack: TestStack) -> ResourceSnapshot {
        ResourceSnapshot(thermal: .fair, memoryPressure: .normal,
                         lowPowerMode: false, capturedAt: stack.clock.now)
    }

    private static func verdict(_ stack: TestStack) async -> String? {
        await stack.supervisor.statusSnapshot()
            .objectValue?["resource"]?.objectValue?["admission"]?.stringValue
    }

    /// With a defer verdict there is no dispatchable slot, so the queue
    /// bound is the pending cap alone: a held-insert burst admits at most
    /// pendingInference, extra submissions fail without persisting rows,
    /// and nothing reaches the provider.
    func testDeferredQueueCapsPendingBelowTotal() async throws {
        let provider = FakeLLMProvider()
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        stack.resources.push(Self.deferredSnapshot(stack))
        try await expectTrue(await pollUntil {
            await Self.verdict(stack) == "defer_load"
        }, "deferred verdict never landed")
        let gate = InsertGate()
        await stack.supervisor.setInsertGate { await gate.wait() }

        var tasks: [Task<Result<ChatResult, Error>, Never>] = []
        for _ in 0..<20 { tasks.append(submit(stack)) }
        try await expectTrue(await pollUntil {
            await stack.supervisor.insertionReservations
                == PlatformLimits.pendingInference
        }, "deferred reservations never reached the pending cap")
        let earlyJobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(earlyJobs.isEmpty,
                      "capacity-rejected submissions must not persist rows")
        gate.release()
        // Exactly the pending cap queues; the provider is never invoked.
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().pending
                == PlatformLimits.pendingInference
        }, "deferred queue did not settle at the pending cap")
        XCTAssertTrue(provider.invocations.isEmpty)
        let queued = try await stack.supervisor.listJobs()
        XCTAssertEqual(queued.count, PlatformLimits.pendingInference)
        XCTAssertTrue(queued.allSatisfy { !$0.isTerminal })
        // Queue expiry drains the deferred waiters; a fresh verdict sample
        // re-triggers the sweep.
        stack.clock.advance(by: PlatformLimits.queueDeadlineSeconds + 1)
        stack.resources.push(Self.deferredSnapshot(stack))
        var expired = 0
        var rejected = 0
        for t in tasks {
            switch await t.value {
            case .success: XCTFail("deferred submission must not succeed")
            case .failure(let e):
                switch (e as? PlatformError)?.code {
                case .deadlineExceeded: expired += 1
                case .capacityLimited: rejected += 1
                default: XCTFail("unexpected outcome: \(e)")
                }
            }
        }
        XCTAssertEqual(expired, PlatformLimits.pendingInference)
        XCTAssertEqual(rejected, 20 - PlatformLimits.pendingInference)
    }

    /// A burst admitted under a healthy verdict while storage is held must
    /// still respect the pending cap when the verdict flips to defer
    /// before the inserts land: the overflow insert completes but its row
    /// is failed, never queued or invoked.
    func testDeferredDuringHeldInsertRecheckFailsOverflow() async throws {
        let provider = FakeLLMProvider()
        let stack = try await stack(provider: provider)
        defer { stack.root.releaseLock() }
        let gate = InsertGate()
        await stack.supervisor.setInsertGate { await gate.wait() }
        let capacity = PlatformLimits.activeInference
            + PlatformLimits.pendingInference

        var tasks: [Task<Result<ChatResult, Error>, Never>] = []
        for _ in 0..<capacity { tasks.append(submit(stack)) }
        try await expectTrue(await pollUntil {
            await stack.supervisor.insertionReservations == capacity
        }, "healthy reservations never reached total capacity")
        // The verdict flips while every insert is still suspended.
        stack.resources.push(Self.deferredSnapshot(stack))
        try await expectTrue(await pollUntil {
            await Self.verdict(stack) == "defer_load"
        }, "deferred verdict never landed")
        gate.release()

        // pending cap rows queue; the overflow row lands failed.
        try await expectTrue(await pollUntil {
            let jobs = try await stack.supervisor.listJobs()
            return jobs.count == capacity
                && jobs.contains { $0.state == .failed }
        }, "overflow insert did not settle failed")
        let snap = await stack.supervisor.admissionSnapshot()
        XCTAssertEqual(snap.pending, PlatformLimits.pendingInference)
        XCTAssertTrue(provider.invocations.isEmpty)
        // The remaining queued waiters settle at queue expiry.
        stack.clock.advance(by: PlatformLimits.queueDeadlineSeconds + 1)
        stack.resources.push(Self.deferredSnapshot(stack))
        var capacityRejected = 0
        var expired = 0
        for t in tasks {
            switch await t.value {
            case .success: XCTFail("deferred submission must not succeed")
            case .failure(let e):
                switch (e as? PlatformError)?.code {
                case .capacityLimited: capacityRejected += 1
                case .deadlineExceeded: expired += 1
                default: XCTFail("unexpected outcome: \(e)")
                }
            }
        }
        XCTAssertEqual(capacityRejected, 1)
        XCTAssertEqual(expired, PlatformLimits.pendingInference)
    }

    // MARK: AgentRunBudget

    /// Reservations are monotonic and overflow-safe: the exact boundary is
    /// accepted, an Int.max request trips the cap without arithmetic
    /// overflow, a closed budget answers cancelled, and a misconfigured
    /// bound fails the reservation rather than the initializer.
    func testAgentRunBudgetBoundsOverflowAndClose() async throws {
        let limit = PlatformLimits.agentGeneratedTokenReservations
        let budget = AgentRunBudget()
        try await budget.reserveModel(512)
        do {
            try await budget.reserveModel(.max)
            XCTFail("expected capacityLimited")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .capacityLimited)
        }
        // Exact remaining boundary still accepted; one more is not.
        try await budget.reserveModel(limit - 512)
        do {
            try await budget.reserveModel(1)
            XCTFail("expected capacityLimited")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .capacityLimited)
        }
        await budget.close()
        do {
            try await budget.reserveModel(1)
            XCTFail("expected cancelled")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .cancelled)
        }
        let invalid = AgentRunBudget(maxTokens: -1)
        do {
            try await invalid.reserveModel(1)
            XCTFail("expected invalidRequest")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .invalidRequest)
        }
        do {
            try await AgentRunBudget().reserveModel(0)
            XCTFail("expected invalidRequest")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .invalidRequest)
        }
    }

    /// An omitted client output bound resolves to the lower profile cap
    /// before the provider is invoked; an explicit over-cap request is
    /// refused as invalidRequest and never reaches the provider.
    func testProfileCapNormalizesOmittedLimit() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await registerStandardPrincipals(stack.supervisor)
        let provider = FakeLLMProvider(autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "m-capped", providerID: provider.providerID,
                         kind: .llm, task: "chat", maxOutputTokens: 32),
            provider: provider)
        let messages = [ChatMessage(role: .user, parts: ["hi"])]
        _ = try await stack.supervisor.submitLLM(
            principal: modelPrincipal,
            request: ChatRequest(model: "m-capped", messages: messages))
        try await expectEqual(provider.invocations.count, 1)
        try await expectEqual(provider.invocations[0].maxOutputTokens, 32)
        try await expectPlatformError(.invalidRequest) {
            _ = try await stack.supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(model: "m-capped", messages: messages,
                                     maxOutputTokens: 33))
        }
        try await expectEqual(provider.invocations.count, 1)
    }

    /// The status snapshot projects real registration and readiness state
    /// plus job summaries without secrets or paths: artifactReady is null
    /// for providers that cannot report readiness, false for absent
    /// providers, and provenance is always labeled.
    func testStatusSnapshotProjectionIsTruthful() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await registerStandardPrincipals(stack.supervisor)
        let provider = FakeLLMProvider()
        await stack.supervisor.registerModel(
            ModelProfile(alias: "m-live", providerID: provider.providerID,
                         kind: .llm, task: "chat", purposes: ["demo"],
                         capabilities: ["text"], maxOutputTokens: 32),
            provider: provider)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "m-dead", providerID: "nobody",
                         kind: .llm, task: "chat"))
        // Hold one inference active so the jobs projection has a row.
        let call = Task {
            try await stack.supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(model: "m-live",
                                     messages: [ChatMessage(role: .user, parts: ["hi"])]))
        }
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().active == 1
        }, "provider never invoked")

        let snap = await stack.supervisor.statusSnapshot()
        let models = snap.objectValue?["models"]?.arrayValue ?? []
        let live = models.first { $0.objectValue?["alias"] == .string("m-live") }
        let dead = models.first { $0.objectValue?["alias"] == .string("m-dead") }
        XCTAssertEqual(live?.objectValue?["providerRegistered"], .bool(true))
        XCTAssertEqual(live?.objectValue?["artifactReady"], .null)
        XCTAssertEqual(live?.objectValue?["maxOutputTokens"], .int(32))
        XCTAssertEqual(live?.objectValue?["purposes"], .array([.string("demo")]))
        XCTAssertEqual(dead?.objectValue?["providerRegistered"], .bool(false))
        XCTAssertEqual(dead?.objectValue?["artifactReady"], .bool(false))
        // Job summaries carry only id/kind/state/parentId: no consumer,
        // credential, or path material.
        let allowed: Set<String> = ["id", "kind", "state", "parentId"]
        let jobs = snap.objectValue?["jobs"]?.objectValue
        let active = jobs?["active"]?.arrayValue ?? []
        XCTAssertEqual(active.count, 1)
        for row in active + (jobs?["pending"]?.arrayValue ?? []) {
            XCTAssertEqual(Set((row.objectValue ?? [:]).keys), allowed)
        }
        XCTAssertNotNil(snap.objectValue?["resource"]?
            .objectValue?["memoryPressureSource"]?.stringValue)

        provider.finishAll()
        _ = try await call.value
    }
}
