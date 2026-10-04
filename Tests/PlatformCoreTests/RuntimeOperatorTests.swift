import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// The optional read-only Operator: absent unless explicitly registered on a
/// qualified MLX alias, and its harness makes exactly one bounded model call
/// with the compiled-in instructions plus a read-only snapshot - no tools,
/// no administrative authority, no ML calls.
final class RuntimeOperatorTests: XCTestCase {

    private func mlxStack() async throws -> (TestStack, FakeLLMProvider) {
        let stack = try await makeStack()
        await registerStandardPrincipals(stack.supervisor)
        let provider = FakeLLMProvider(providerID: MLXProviderContract.id,
                                       content: "Runtime explanation.",
                                       autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "qwen3.8-9b", providerID: MLXProviderContract.id,
                         kind: .llm, task: "chat",
                         purposes: ["runtime-explanation"], maxOutputTokens: 4096,
                         source: ModelSource(repo: "nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
                                             revision: "e827c31fbd588828f43180a87ab34415a6d8a4bf")),
            provider: provider)
        return (stack, provider)
    }

    /// Lock-confined capture for model requests a harness submits.
    private final class RequestBag: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ChatRequest] = []
        func append(_ r: ChatRequest) {
            lock.lock(); items.append(r); lock.unlock()
        }
        var all: [ChatRequest] {
            lock.lock(); defer { lock.unlock() }; return items
        }
    }

    private func context(model: @escaping @Sendable (ChatRequest) async throws -> ChatResult,
                         mlCount: Counter,
                         snapshot: JSONValue = .object(["resource": .object([
                            "thermal": .string("nominal"),
                            "memoryPressure": .string("normal")])]),
                         cancelled: @escaping @Sendable () -> Bool = { false }) -> AgentContext {
        AgentContext(
            sessionID: "s", runID: "r",
            statusSnapshot: { snapshot },
            model: ModelClient(model),
            ml: MLClient { _ in
                mlCount.increment()
                throw PlatformError(.internal)
            },
            isCancelled: cancelled)
    }

    // MARK: registration

    func testAbsentUnlessExplicitlyRegistered() async throws {
        let (stack, _) = try await mlxStack()
        defer { stack.root.releaseLock() }
        let ids = await stack.supervisor.agentService.profileIDs()
        XCTAssertFalse(ids.contains("operator"))
        try await expectPlatformError(.notFound) {
            _ = try await stack.supervisor.agentService.newSession(
                agentID: "operator", consumerID: "c", connectionID: "k")
        }
        try await expectPlatformError(.invalidRequest) {
            try await stack.supervisor.registerRuntimeOperator(modelAlias: "")
        }
        try await expectPlatformError(.notFound) {
            try await stack.supervisor.registerRuntimeOperator(modelAlias: "ghost")
        }
        let idsAfter = await stack.supervisor.agentService.profileIDs()
        XCTAssertFalse(idsAfter.contains("operator"))
    }

    func testValidMLXAliasRegistersPinnedOperator() async throws {
        let (stack, _) = try await mlxStack()
        defer { stack.root.releaseLock() }
        try await stack.supervisor.registerRuntimeOperator(modelAlias: "qwen3.8-9b")
        let profile = await stack.supervisor.agentService.profile(id: "operator")
        XCTAssertEqual(profile?.modelProfileAlias, "qwen3.8-9b")
        XCTAssertEqual(profile?.harnessID, RuntimeOperatorHarness.id)
        XCTAssertEqual(profile?.harnessVersion, 1)
        XCTAssertEqual(profile?.version, 1)
        XCTAssertEqual(profile?.stateSchemaVersion, 1)
        XCTAssertEqual(profile?.toolScope, [])
        XCTAssertEqual(profile?.implementationRef, "builtin:operator.runtime")
        let ids = await stack.supervisor.agentService.profileIDs()
        XCTAssertTrue(ids.contains("operator"))
    }

    /// The Apple system route is a valid Operator binding: a live
    /// `apple-foundation-models` provider registers the pinned profile, and
    /// its harness sends the same bounded request to that alias.
    func testAppleAliasRegistersPinnedOperator() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await registerStandardPrincipals(stack.supervisor)
        let provider = FakeLLMProvider(providerID: AppleFoundationProvider.id,
                                       content: "Runtime explanation.",
                                       autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "apple-foundation-model",
                         providerID: AppleFoundationProvider.id,
                         kind: .llm, task: "chat", capabilities: ["text"]),
            provider: provider)
        try await stack.supervisor.registerRuntimeOperator(modelAlias: "apple-foundation-model")
        let profile = await stack.supervisor.agentService.profile(id: "operator")
        XCTAssertEqual(profile?.modelProfileAlias, "apple-foundation-model")

        let session = try await stack.supervisor.agentService.newSession(
            agentID: "operator", consumerID: agentPrincipal.id, connectionID: "k")
        let harness = try await stack.supervisor.agentService.harness(for: session)
        let token = CancellationToken()
        let supervisor = stack.supervisor
        let ctx = AgentContext(
            sessionID: session.id, runID: "run-1",
            statusSnapshot: { await supervisor.statusSnapshot() },
            model: ModelClient { request in
                try await supervisor.submitLLM(principal: agentPrincipal,
                                               request: request, parentID: "run-1",
                                               cancellation: token)
            },
            ml: MLClient { _ in throw PlatformError(.internal) },
            isCancelled: { token.isCancelled })
        let stop = await harness.run(
            input: [.text("Explain runtime status.")], context: ctx, emit: { _ in })
        XCTAssertEqual(stop, .endTurn)
        XCTAssertEqual(provider.invocations.first?.model, "apple-foundation-model")
    }

    func testNonMLXOrUnavailableAliasRejected() async throws {
        let (stack, _) = try await mlxStack()
        defer { stack.root.releaseLock() }
        // ML-kind profile: not an LLM route.
        let predictor = FakeMLPredictor()
        await stack.supervisor.registerModel(
            ModelProfile(alias: "test-ml", providerID: predictor.providerID,
                         kind: .ml, task: "classify"),
            predictor: predictor)
        try await expectPlatformError(.notFound) {
            try await stack.supervisor.registerRuntimeOperator(modelAlias: "test-ml")
        }
        // LLM route on a third-party provider: the Operator binds only the
        // local MLX or Apple system routes.
        let apple = FakeLLMProvider(providerID: "other-provider", autoFinish: true)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "other-llm", providerID: "other-provider",
                         kind: .llm, task: "chat"),
            provider: apple)
        try await expectPlatformError(.providerUnavailable) {
            try await stack.supervisor.registerRuntimeOperator(modelAlias: "other-llm")
        }
        // Declared mlx route whose provider was never wired.
        await stack.supervisor.registerModel(
            ModelProfile(alias: "mlx-unwired", providerID: "mlx-missing",
                         kind: .llm, task: "chat"))
        try await expectPlatformError(.providerUnavailable) {
            try await stack.supervisor.registerRuntimeOperator(modelAlias: "mlx-unwired")
        }
        // None of the failures registered an operator profile.
        let ids = await stack.supervisor.agentService.profileIDs()
        XCTAssertFalse(ids.contains("operator"))
    }

    func testCoreWorksWithoutOperator() async throws {
        let (stack, provider) = try await mlxStack()
        defer { stack.root.releaseLock() }
        let result = try await stack.supervisor.submitLLM(
            principal: modelPrincipal,
            request: ChatRequest(model: "qwen3.8-9b",
                                 messages: [ChatMessage(role: .user, parts: ["hi"])],
                                 maxOutputTokens: 8))
        XCTAssertEqual(result.content, "Runtime explanation.")
        XCTAssertEqual(provider.invocations.count, 1)
    }

    // MARK: harness behavior

    func testHarnessSendsExactBoundedRequestOnce() async throws {
        let bag = RequestBag()
        let mlCount = Counter()
        let ctx = context(model: { request in
            bag.append(request)
            return ChatResult(modelIdentity: "mlx", content: "Runtime explanation.",
                              finishReason: .stop,
                              usage: ChatUsage(promptTokens: 10, completionTokens: 4))
        }, mlCount: mlCount)
        let chunks = StringBag()
        let stop = await RuntimeOperatorHarness(modelAlias: "qwen3.8-9b").run(
            input: [.text("Explain runtime status.")], context: ctx,
            emit: { if case .messageChunk(let t) = $0 { chunks.append(t) } })
        XCTAssertEqual(stop, .endTurn)
        XCTAssertEqual(chunks.all, ["Runtime explanation."])

        let requests = bag.all
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.model, "qwen3.8-9b")
        XCTAssertEqual(request.maxOutputTokens, 512)
        XCTAssertEqual(request.temperature, 0)
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertEqual(request.messages.count, 3)
        XCTAssertEqual(request.messages[0].role, .system)
        XCTAssertEqual(request.messages[0].combinedText, OperatorPrompt.instructions)
        XCTAssertEqual(request.messages[1].role, .user)
        XCTAssertTrue(request.messages[1].combinedText
            .hasPrefix("Read-only platform snapshot:"))
        XCTAssertTrue(request.messages[1].combinedText.contains("nominal"))
        XCTAssertEqual(request.messages[2].role, .user)
        XCTAssertEqual(request.messages[2].combinedText, "Explain runtime status.")
        XCTAssertEqual(mlCount.count, 0)
    }

    func testHarnessEmptyAndPrecancelledMakeNoModelCalls() async throws {
        let bag = RequestBag()
        let mlCount = Counter()
        let model = ModelClient { r in
            bag.append(r)
            return ChatResult(modelIdentity: "mlx", content: "x", finishReason: .stop)
        }
        let ctx = context(model: { r in try await model.complete(r) }, mlCount: mlCount)
        let harness = RuntimeOperatorHarness(modelAlias: "qwen3.8-9b")

        for input: [PromptBlock] in [[], [.text("   \n  ")],
                                     [.resourceLink(uri: "file:///x", name: nil)]] {
            let stop = await harness.run(input: input, context: ctx, emit: { _ in })
            XCTAssertEqual(stop, .refusal)
        }
        let cancelledCtx = context(model: { r in try await model.complete(r) },
                                   mlCount: mlCount, cancelled: { true })
        let cancelled = await harness.run(
            input: [.text("Explain runtime status.")], context: cancelledCtx, emit: { _ in })
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertTrue(bag.all.isEmpty)
        XCTAssertEqual(mlCount.count, 0)
    }

    func testHarnessErrorPathsAreSafe() async throws {
        let mlCount = Counter()
        let harness = RuntimeOperatorHarness(modelAlias: "qwen3.8-9b")
        let input: [PromptBlock] = [.text("Explain runtime status.")]

        // Platform errors surface safe info as text and end as .error.
        let denied = StringBag()
        let deniedStop = await harness.run(input: input, context: context(
            model: { _ in throw PlatformError(.resourceDenied) },
            mlCount: mlCount), emit: {
                if case .messageChunk(let t) = $0 { denied.append(t) }
            })
        XCTAssertEqual(deniedStop, .error)
        XCTAssertEqual(denied.all.count, 1)
        XCTAssertTrue(denied.all[0].hasPrefix("Operator unavailable"))

        // Cancellation maps to cancelled - never an error chunk.
        let cancelledChunks = StringBag()
        let cancelledStop = await harness.run(input: input, context: context(
            model: { _ in throw PlatformError(.cancelled) },
            mlCount: mlCount), emit: {
                if case .messageChunk(let t) = $0 { cancelledChunks.append(t) }
            })
        XCTAssertEqual(cancelledStop, .cancelled)
        XCTAssertTrue(cancelledChunks.all.isEmpty)

        // Unknown errors emit a generic line and end as .error.
        struct Boom: Error {}
        let generic = StringBag()
        let genericStop = await harness.run(input: input, context: context(
            model: { _ in throw Boom() },
            mlCount: mlCount), emit: {
                if case .messageChunk(let t) = $0 { generic.append(t) }
            })
        XCTAssertEqual(genericStop, .error)
        XCTAssertEqual(generic.all, ["Operator error."])

        // A snapshot that cannot encode ends truthfully as .error with no
        // model call attempted.
        let bag = RequestBag()
        let badSnapshot: JSONValue = .object(["x": .double(.infinity)])
        let snapshotStop = await harness.run(input: input, context: context(
            model: { r in
                bag.append(r)
                return ChatResult(modelIdentity: "mlx", content: "x", finishReason: .stop)
            },
            mlCount: mlCount, snapshot: badSnapshot), emit: { _ in })
        XCTAssertEqual(snapshotStop, .error)
        XCTAssertTrue(bag.all.isEmpty)
        XCTAssertEqual(mlCount.count, 0)
    }

    /// Provider finish reasons map to truthful stop reasons: nonempty stop is
    /// a normal end, length is a partial token-limited answer, content filter
    /// is a refusal, and error / unsolicited tool calls / empty output are
    /// errors - never silent success, never executed actions.
    func testHarnessFinishReasonMapping() async throws {
        let mlCount = Counter()
        let harness = RuntimeOperatorHarness(modelAlias: "qwen3.8-9b")
        let input: [PromptBlock] = [.text("Explain runtime status.")]
        func run(result: ChatResult) async -> (AgentStopReason, [String]) {
            let chunks = StringBag()
            let stop = await harness.run(input: input, context: context(
                model: { _ in result }, mlCount: mlCount), emit: {
                    if case .messageChunk(let t) = $0 { chunks.append(t) }
                })
            return (stop, chunks.all)
        }
        func chat(_ finish: FinishReason, content: String = "ok",
                  tools: [ChatToolCall] = []) -> ChatResult {
            ChatResult(modelIdentity: "mlx", content: content,
                       finishReason: finish, toolCalls: tools)
        }
        var (stop, chunks) = await run(result: chat(.stop, content: "answer"))
        XCTAssertEqual(stop, .endTurn); XCTAssertEqual(chunks, ["answer"])
        (stop, chunks) = await run(result: chat(.length, content: "partial"))
        XCTAssertEqual(stop, .maxTokens); XCTAssertEqual(chunks, ["partial"])
        (stop, _) = await run(result: chat(.contentFilter))
        XCTAssertEqual(stop, .refusal)
        (stop, _) = await run(result: chat(.error, content: "junk"))
        XCTAssertEqual(stop, .error)
        (stop, chunks) = await run(result: chat(.toolCalls,
            tools: [ChatToolCall(id: "t1", name: "noop", arguments: .object([:]))]))
        XCTAssertEqual(stop, .error)
        XCTAssertTrue(chunks.contains { $0.contains("cannot execute tool calls") })
        (stop, _) = await run(result: chat(.stop, content: "   "))
        XCTAssertEqual(stop, .error)
        XCTAssertEqual(mlCount.count, 0)
    }

    /// End-to-end through real admission: an operator session's model step
    /// reaches the scoped provider through submitLLM.
    func testOperatorRunThroughAdmission() async throws {
        let (stack, provider) = try await mlxStack()
        defer { stack.root.releaseLock() }
        try await stack.supervisor.registerRuntimeOperator(modelAlias: "qwen3.8-9b")
        let session = try await stack.supervisor.agentService.newSession(
            agentID: "operator", consumerID: agentPrincipal.id, connectionID: "k")
        let harness = try await stack.supervisor.agentService.harness(for: session)
        let token = CancellationToken()
        let supervisor = stack.supervisor
        let ctx = AgentContext(
            sessionID: session.id, runID: "run-1",
            statusSnapshot: { await supervisor.statusSnapshot() },
            model: ModelClient { request in
                try await supervisor.submitLLM(principal: agentPrincipal,
                                               request: request, parentID: "run-1",
                                               cancellation: token)
            },
            ml: MLClient { _ in throw PlatformError(.internal) },
            isCancelled: { token.isCancelled })
        let chunks = StringBag()
        let stop = await harness.run(
            input: [.text("Explain runtime status.")], context: ctx,
            emit: { if case .messageChunk(let t) = $0 { chunks.append(t) } })
        XCTAssertEqual(stop, .endTurn)
        XCTAssertEqual(chunks.all, ["Runtime explanation."])
        XCTAssertEqual(provider.invocations.count, 1)
        XCTAssertEqual(provider.invocations.first?.model, "qwen3.8-9b")
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.contains { $0.parentID == "run-1" && $0.state == .completed })
    }
}
