import XCTest
import PlatformTestSupport
@testable import PlatformMLX
@testable import PlatformCore

/// Live qualification of the open-weight route: real pull, real load, real
/// completion through the shared admission path. Runs only when
/// OAP_LIVE_MLX=1 is set - the artifact is large and the network is real.
final class MLXLiveTests: XCTestCase {

    private let source = ModelSource(repo: "mlx-community/Qwen3-0.6B-4bit",
                                     revision: "main")

    private func live() throws -> Bool {
        ProcessInfo.processInfo.environment["OAP_LIVE_MLX"] == "1"
    }

    /// Pull -> validate -> load -> single completion through submitLLM.
    /// Proves the route end-to-end; latency/memory numbers are recorded in
    /// docs/development.md, not asserted here.
    func testLivePullAndComplete() async throws {
        try XCTSkipUnless(live(), "set OAP_LIVE_MLX=1 to run the live model test")
        let stack = try await makeStack()
        let store = ModelStore(root: stack.root)

        if !store.isReady(source: source) {
            _ = try await store.pull(source: source)
        }
        XCTAssertTrue(store.isReady(source: source))

        let provider = MLXProvider(store: store)
        XCTAssertTrue(provider.hasReadyArtifact)
        let profile = ModelProfile(alias: "qwen-small",
                                   providerID: MLXProviderContract.id,
                                   kind: .llm, task: "chat",
                                   source: source)
        await stack.supervisor.registerModel(profile, provider: provider)
        await registerStandardPrincipals(stack.supervisor)

        let result = try await stack.supervisor.submitLLM(
            principal: modelPrincipal,
            request: ChatRequest(model: "qwen-small",
                                 messages: [
                                    ChatMessage(role: .system, parts: ["Reply with one word."]),
                                    ChatMessage(role: .user, parts: ["What is 2+2?"]),
                                 ],
                                 maxOutputTokens: 32))
        XCTAssertEqual(result.modelIdentity, MLXProviderContract.id)
        XCTAssertFalse(result.content.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertNotNil(result.usage)
        XCTAssertGreaterThan(result.usage?.promptTokens ?? 0, 0)
        XCTAssertGreaterThan(result.usage?.completionTokens ?? 0, 0)
    }

    /// Cancellation through the real seam: submit -> locate the live job ->
    /// cancelJob -> the provider's in-flight task is cancelled and the
    /// awaiting caller sees a thrown cancellation. Asserts it completes
    /// faster than generating the full 512-token response would take.
    func testLiveCancelStopsGeneration() async throws {
        try XCTSkipUnless(live(), "set OAP_LIVE_MLX=1 to run the live model test")
        let stack = try await makeStack()
        let store = ModelStore(root: stack.root)
        if !store.isReady(source: source) {
            _ = try await store.pull(source: source)
        }
        let provider = MLXProvider(store: store)
        let profile = ModelProfile(alias: "qwen-small",
                                   providerID: MLXProviderContract.id,
                                   kind: .llm, task: "chat", source: source)
        await stack.supervisor.registerModel(profile, provider: provider)
        await registerStandardPrincipals(stack.supervisor)

        let request = ChatRequest(model: "qwen-small",
                                  messages: [ChatMessage(
                                     role: .user,
                                     parts: ["Count slowly from 1 to 500, one number per line."])],
                                  maxOutputTokens: 512)
        let started = Date()
        let task = Task {
            try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                 request: request)
        }
        // Wait for the job to exist, then cancel it through the supervisor.
        var jobID: String?
        for _ in 0..<200 {
            let jobs = (try? await stack.supervisor.listJobs()) ?? []
            if let running = jobs.first(where: { $0.kind == .llm && !$0.isTerminal }) {
                jobID = running.id
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let jobID else {
            XCTFail("job never registered")
            task.cancel()
            return
        }
        try await stack.supervisor.cancelJob(principal: modelPrincipal, jobID: jobID)
        let outcome = await task.result
        XCTAssertThrowsError(try outcome.get()) { error in
            guard let e = error as? PlatformError else {
                return XCTFail("expected PlatformError, got \(error)")
            }
            XCTAssertEqual(e.code, .cancelled)
        }
        // Generating all 512 tokens takes many seconds; a cancelled job must
        // finish fast.
        XCTAssertLessThan(Date().timeIntervalSince(started), 60)
    }
}
