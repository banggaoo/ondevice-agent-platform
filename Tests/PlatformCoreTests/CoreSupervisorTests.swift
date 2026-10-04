import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// Core-independence and admission contract: queue bounds, fairness,
/// cancellation semantics, deadlines, and grant rechecks.
final class CoreSupervisorTests: XCTestCase {

    private static func llmProfile(_ alias: String = "test-llm",
                                   provider: String = "fake-llm") -> ModelProfile {
        ModelProfile(alias: alias, providerID: provider, kind: .llm,
                     task: "chat", maxOutputTokens: 512)
    }

    private static func chatRequest(_ model: String = "test-llm",
                                    _ text: String = "hello") -> ChatRequest {
        ChatRequest(model: model,
                    messages: [ChatMessage(role: .user, parts: [text])],
                    maxOutputTokens: 16)
    }

    // MARK: independence

    func testEmptyRegistryAdminWorksWithZeroInference() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let status = await stack.supervisor.statusSnapshot()
        XCTAssertNotNil(status.objectValue?["categories"])
        let registry = await stack.supervisor.registrySnapshot()
        XCTAssertEqual(registry.objectValue?["models"], .array([]))
        XCTAssertEqual(registry.objectValue?["agents"], .array([]))
        let counts = await stack.supervisor.counters()
        XCTAssertEqual(counts.llm, 0)
        XCTAssertEqual(counts.ml, 0)
        _ = try await stack.supervisor.listJobs()
        let admission = await stack.supervisor.admissionSnapshot()
        XCTAssertEqual(admission.active, 0)
        XCTAssertEqual(admission.pending, 0)
    }

    func testUnknownAlias404AndRegisteredWithoutProvider503() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await stack.supervisor.registerModel(Self.llmProfile())
        do {
            _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                     request: Self.chatRequest("missing"))
            XCTFail("expected notFound")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .notFound) }
        do {
            _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                     request: Self.chatRequest())
            XCTFail("expected providerUnavailable")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .providerUnavailable) }
    }

    // MARK: grants

    func testWrongCredentialAndScopeGrants() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await registerStandardPrincipals(stack.supervisor)
        let bad = await stack.supervisor.authenticate(token: "not-a-token")
        XCTAssertNil(bad)
        let good = await stack.supervisor.authenticate(token: modelToken)
        XCTAssertNotNil(good)
        // Model token cannot administrate; agent token has no admin rights.
        try await expectPlatformError(.forbidden) {
            try await stack.supervisor.require(.adminRead, principal: modelPrincipal)
        }
        try await expectPlatformError(.forbidden) {
            try await stack.supervisor.require(.adminStop, principal: agentPrincipal)
        }
        try await expectPlatformError(.forbidden) {
            try await stack.supervisor.require(.llmInfer, principal: consolePrincipal)
        }
    }

    func testRevokedGrantDeniedAtSubmit() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(autoFinish: true)
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)
        await stack.supervisor.revokeGrant(.llmInfer, from: modelPrincipal.id)
        do {
            _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                     request: Self.chatRequest())
            XCTFail("expected forbidden")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .forbidden) }
    }

    /// Restart regression: a new supervisor on the same root must continue
    /// the persisted job id sequence, not collide with `job-1`.
    func testRestartedSupervisorContinuesJobSequence() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await stack.supervisor.registerModel(Self.llmProfile(),
                                             provider: FakeLLMProvider(autoFinish: true))
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                 request: Self.chatRequest())
        await stack.supervisor.shutdown()

        let second = PlatformSupervisor(
            root: stack.root, credentials: MemoryCredentialStore(),
            resourceSource: stack.resources, clock: stack.clock.clock)
        try await second.start()
        await second.registerModel(Self.llmProfile(),
                                   provider: FakeLLMProvider(autoFinish: true))
        await second.registerPrincipal(token: modelToken, principal: modelPrincipal)
        _ = try await second.submitLLM(principal: modelPrincipal,
                                       request: Self.chatRequest())
        let jobs = try await second.listJobs()
        XCTAssertTrue(jobs.contains { $0.id == "job-2" })
        await second.shutdown()
    }

    // MARK: admission queue

    func testActivePlusFourPendingThen429() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider()
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)

        let req = Self.chatRequest()
        var tasks: [Task<Result<ChatResult, Error>, Never>] = []
        for _ in 0..<5 {
            tasks.append(Task {
                do { return .success(try await stack.supervisor.submitLLM(
                    principal: modelPrincipal, request: req)) }
                catch { return .failure(error) }
            })
        }
        let settled = await pollUntil {
            let s = await stack.supervisor.admissionSnapshot()
            return s.active == 1 && s.pending == 4
        }
        XCTAssertTrue(settled, "expected 1 active + 4 pending")
        do {
            _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                     request: Self.chatRequest())
            XCTFail("expected capacity error")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .capacityLimited) }
        // Each queued job only invokes the provider once the slot frees, so
        // release every dispatch as it lands rather than a single drain.
        provider.finishNext()
        for expected in 2...tasks.count {
            try await expectTrue(await pollUntil { provider.invocations.count >= expected },
                                 "queued job \(expected) never dispatched")
            provider.finishNext()
        }
        for t in tasks { _ = await t.value }
    }

    func testRoundRobinConsumerFairness() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider()
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        let a = Principal(id: "a-consumer", scope: .model)
        let b = Principal(id: "b-consumer", scope: .model)
        await stack.supervisor.registerPrincipal(token: "ta", principal: a)
        await stack.supervisor.registerPrincipal(token: "tb", principal: b)

        let r1 = Self.chatRequest("test-llm", "A1")
        let t1 = Task { try? await stack.supervisor.submitLLM(principal: a, request: r1) }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        let r2 = Self.chatRequest("test-llm", "A2")
        let t2 = Task { try? await stack.supervisor.submitLLM(principal: a, request: r2) }
        let r3 = Self.chatRequest("test-llm", "B1")
        let t3 = Task { try? await stack.supervisor.submitLLM(principal: b, request: r3) }
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().pending == 2
        })
        provider.finishNext()
        try await expectTrue(await pollUntil { provider.invocations.count >= 2 })
        // Second dispatch must prefer the other consumer even though A2 was
        // queued before B1.
        XCTAssertEqual(provider.invocations[1].combinedText, "B1")
        provider.finishNext()
        try await expectTrue(await pollUntil { provider.invocations.count >= 3 },
                             "queued A2 never dispatched")
        provider.finishNext()
        _ = await (t1.value, t2.value, t3.value)
    }

    func testQueuedJobExpiryAndQueuedCancel() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider()
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)

        let r4 = Self.chatRequest()
        let t1 = Task { try? await stack.supervisor.submitLLM(principal: modelPrincipal, request: r4) }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        // Submit queued work serially so job IDs map to tasks deterministically.
        let t2 = Task<Result<ChatResult, Error>, Never> {
            do { return .success(try await stack.supervisor.submitLLM(
                principal: modelPrincipal, request: Self.chatRequest())) }
            catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().pending == 1
        })
        let t3 = Task<Result<ChatResult, Error>, Never> {
            do { return .success(try await stack.supervisor.submitLLM(
                principal: modelPrincipal, request: Self.chatRequest())) }
            catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().pending == 2
        })
        // Cancel the queued job-2 directly.
        try await stack.supervisor.cancelJob(principal: consolePrincipal, jobID: "job-2")
        if case .failure(let e) = await t2.value {
            XCTAssertEqual((e as? PlatformError)?.code, .cancelled)
        } else { XCTFail("expected cancelled") }

        // Age the remaining queued job past the queue deadline; finishing the
        // active job triggers the sweep.
        stack.clock.advance(by: PlatformLimits.queueDeadlineSeconds + 1)
        provider.finishNext()
        if case .failure(let e) = await t3.value {
            XCTAssertEqual((e as? PlatformError)?.code, .deadlineExceeded)
        } else { XCTFail("expected deadlineExceeded") }
        _ = await t1.value
    }

    func testCooperativeCancelReleasesSlot() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(cooperative: true)
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)

        let t1 = Task<Result<ChatResult, Error>, Never> {
            do { return .success(try await stack.supervisor.submitLLM(
                principal: modelPrincipal, request: Self.chatRequest())) }
            catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        // Queue the second job only after t1 is active so it is job-2.
        let t2 = Task<Result<ChatResult, Error>, Never> {
            do { return .success(try await stack.supervisor.submitLLM(
                principal: modelPrincipal, request: Self.chatRequest())) }
            catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().pending == 1
        })
        try await stack.supervisor.cancelJob(principal: consolePrincipal, jobID: "job-1")
        if case .failure(let e) = await t1.value {
            XCTAssertEqual((e as? PlatformError)?.code, .cancelled)
        } else { XCTFail("expected cancelled") }
        // Slot released: queued job-2 dispatches without blocked state.
        try await expectTrue(await pollUntil { provider.invocations.count == 2 })
        provider.finishAll()
        if case .failure(let e) = await t2.value {
            XCTFail("queued job should have completed: \(e)")
        }
        let final = await stack.supervisor.admissionSnapshot()
        XCTAssertFalse(final.blocked)
    }

    func testNoncooperativeProviderBlocksAfterGraceUntilRealFinish() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(cooperative: false)
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)

        let t1 = Task<Result<ChatResult, Error>, Never> {
            do { return .success(try await stack.supervisor.submitLLM(
                principal: modelPrincipal, request: Self.chatRequest())) }
            catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        try await stack.supervisor.cancelJob(principal: consolePrincipal, jobID: "job-1")
        // The grace timer is a spawned task; wait until both it and the job's
        // deadline timer have registered sleepers so the advance cannot miss it.
        try await expectTrue(await pollUntil { stack.clock.pendingSleepers >= 2 },
                             "grace timer never armed")
        // Provider ignored cancel; grace expiry makes it unconfirmed.
        stack.clock.advance(by: PlatformLimits.cancellationGraceSeconds + 1)
        if case .failure(let e) = await t1.value {
            XCTAssertEqual((e as? PlatformError)?.code, .cancellationUnconfirmed)
        } else { XCTFail("expected cancellationUnconfirmed") }

        // New inference blocked while the provider still holds its unit.
        do {
            _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                     request: Self.chatRequest())
            XCTFail("expected blocked")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .providerUnavailable) }
        // Administration stays available.
        _ = await stack.supervisor.statusSnapshot()

        // Real completion releases the slot and unblocks admission.
        provider.finishNext()
        try await expectTrue(await pollUntil {
            let s = await stack.supervisor.admissionSnapshot()
            return !s.blocked && s.active == 0
        })
    }

    func testDeadlineAndLateCompletionCannotOverwriteTerminal() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(cooperative: false)
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)

        let t1 = Task<Result<ChatResult, Error>, Never> {
            do { return .success(try await stack.supervisor.submitLLM(
                principal: modelPrincipal, request: Self.chatRequest())) }
            catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil { provider.invocations.count == 1 })
        // Deadline timer is a spawned task; wait for its sleeper before advancing.
        try await expectTrue(await pollUntil { stack.clock.pendingSleepers >= 1 },
                             "deadline timer never armed")
        stack.clock.advance(by: PlatformLimits.inferenceDeadlineSeconds + 1)
        if case .failure(let e) = await t1.value {
            XCTAssertEqual((e as? PlatformError)?.code, .deadlineExceeded)
        } else { XCTFail("expected deadlineExceeded") }

        // Late provider completion must not resurrect the failed record.
        provider.finishNext(result: ChatResult(modelIdentity: "fake-llm",
                                               content: "late", finishReason: .stop))
        try await expectTrue(await pollUntil {
            let jobs = try await stack.supervisor.listJobs()
            return jobs.contains { $0.id == "job-1" && $0.state == .failed }
        })
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertFalse(jobs.contains { $0.id == "job-1" && $0.state == .completed })
    }

    // MARK: prompt text is data

    func testPromptTextNeverSelectsAdministration() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let provider = FakeLLMProvider(autoFinish: true)
        await stack.supervisor.registerModel(Self.llmProfile(), provider: provider)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)
        let req = ChatRequest(model: "test-llm", messages: [
            ChatMessage(role: .system, parts: ["sys"]),
            ChatMessage(role: .developer, parts: ["dev"]),
            ChatMessage(role: .user, parts: ["refresh", "more"]),
            ChatMessage(role: .assistant, parts: ["ack"]),
        ], maxOutputTokens: 16)
        let result = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                        request: req)
        XCTAssertEqual(result.modelIdentity, "fake-llm")
        // Ordered roles and text parts reach the provider unmodified.
        XCTAssertEqual(provider.invocations.count, 1)
        XCTAssertEqual(provider.invocations[0].messages, req.messages)
        XCTAssertEqual(provider.invocations[0].maxOutputTokens, 16)
    }

    func testSeparateLLMAndMLCountersSharedAdmission() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let llm = FakeLLMProvider()
        let ml = FakeMLPredictor()
        await stack.supervisor.registerModel(Self.llmProfile(), provider: llm)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "test-ml", providerID: "fake-ml", kind: .ml,
                         task: "classify",
                         inputSchema: ["x": .number], outputSchema: ["label": .string]),
            predictor: ml)
        await stack.supervisor.registerPrincipal(token: modelToken, principal: modelPrincipal)

        let r5 = Self.chatRequest()
        let t1 = Task { try? await stack.supervisor.submitLLM(principal: modelPrincipal, request: r5) }
        try await expectTrue(await pollUntil { llm.invocations.count == 1 })
        let t2 = Task { try? await stack.supervisor.submitML(
            principal: modelPrincipal,
            request: PredictionRequest(model: "test-ml", task: "classify",
                                       inputs: ["x": .double(1.0)])) }
        try await expectTrue(await pollUntil {
            await stack.supervisor.admissionSnapshot().pending == 1
        })
        // Single active slot shared across kinds: ML stays queued.
        let snap = await stack.supervisor.admissionSnapshot()
        XCTAssertEqual(snap.active, 1)
        XCTAssertEqual(snap.pending, 1)
        llm.finishNext()
        try await expectTrue(await pollUntil { ml.invocations.count == 1 })
        ml.finishNext()
        _ = await (t1.value, t2.value)
        try await expectTrue(await pollUntil {
            let c = await stack.supervisor.counters()
            return c.llm == 1 && c.ml == 1
        })
    }
}

private extension ChatRequest {
    var combinedText: String { messages.flatMap(\.parts).joined(separator: "\n") }
}
