import XCTest
import PlatformTestSupport
@testable import PlatformMLX
@testable import PlatformCore

/// Live qualification of the opt-in runtime Operator: real Qwen generation
/// through the harness's scoped ModelClient into shared-supervisor admission
/// (the harness/model path - not the ACP wire path), with fake resources for
/// the provider function only - not native-daemon admission proof. Runs only
/// when OAP_LIVE_OPERATOR=1 and OAP_LIVE_MLX_STORE points at an
/// already-pulled models dir; it never downloads and skips truthfully on a
/// missing artifact.
final class OperatorLiveTests: XCTestCase {

    func testLiveOperatorRuntimeQwen() async throws {
        guard ProcessInfo.processInfo.environment["OAP_LIVE_OPERATOR"] == "1" else {
            throw XCTSkip("set OAP_LIVE_OPERATOR=1 to run the live operator test")
        }
        guard let dir = ProcessInfo.processInfo.environment["OAP_LIVE_MLX_STORE"] else {
            throw XCTSkip("set OAP_LIVE_MLX_STORE to a pulled models dir")
        }
        let store = ModelStore(modelsDir: URL(fileURLWithPath: dir))
        let source = ModelSource(repo: "nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
                                 revision: "e827c31fbd588828f43180a87ab34415a6d8a4bf")
        guard store.isReady(source: source) else {
            throw XCTSkip("artifact not pulled: \(source.repo)@\(source.revision)")
        }
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await registerStandardPrincipals(stack.supervisor)
        let provider = MLXProvider(store: store)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "qwen3.8-9b", providerID: MLXProviderContract.id,
                         kind: .llm, task: "chat", maxOutputTokens: 4096,
                         source: source),
            provider: provider)
        try await stack.supervisor.registerRuntimeOperator(modelAlias: "qwen3.8-9b")

        let session = try await stack.supervisor.agentService.newSession(
            agentID: "operator", consumerID: agentPrincipal.id, connectionID: "live")
        let harness = try await stack.supervisor.agentService.harness(for: session)
        let token = CancellationToken()
        let mlCalls = Counter()
        let supervisor = stack.supervisor
        let context = AgentContext(
            sessionID: session.id, runID: "run-live",
            statusSnapshot: { await supervisor.statusSnapshot() },
            model: ModelClient { request in
                try await supervisor.submitLLM(principal: agentPrincipal,
                                               request: request, parentID: "run-live",
                                               cancellation: token)
            },
            ml: MLClient { _ in
                mlCalls.increment()
                throw PlatformError(.internal)
            },
            isCancelled: { token.isCancelled })
        let chunks = StringBag()
        let stop = await harness.run(
            input: [.text("Explain runtime status.")], context: context,
            emit: { if case .messageChunk(let t) = $0 { chunks.append(t) } })
        XCTAssertEqual(stop, .endTurn)
        XCTAssertFalse(chunks.all.joined().trimmingCharacters(in: .whitespaces).isEmpty,
                       "operator produced no output")
        let counters = await stack.supervisor.counters()
        XCTAssertGreaterThan(counters.llm, 0, "no real LLM call recorded")
        XCTAssertEqual(mlCalls.count, 0)
    }
}
