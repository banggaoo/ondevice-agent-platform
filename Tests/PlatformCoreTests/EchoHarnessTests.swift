import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// The bounded model-step harness: one scoped completion, then stop. Model
/// failures surface truthfully; cancellation is honored before and after.
final class EchoHarnessTests: XCTestCase {

    private actor Emitter {
        private(set) var events: [AgentEvent] = []
        func record(_ event: AgentEvent) { events.append(event) }
        var texts: [String] {
            events.compactMap { if case .messageChunk(let t) = $0 { return t }; return nil }
        }
    }

    private func context(cancelled: Bool = false,
                         model: @escaping @Sendable (ChatRequest) async throws -> ChatResult) -> AgentContext {
        AgentContext(
            sessionID: "s", runID: "r",
            statusSnapshot: { .object([:]) },
            model: ModelClient(model),
            ml: MLClient { _ in throw PlatformError(.providerUnavailable) },
            isCancelled: { cancelled })
    }

    private func run(_ input: [PromptBlock], context: AgentContext) async -> (AgentStopReason, [String]) {
        let emitter = Emitter()
        let stop = await ReferenceEchoHarness(modelAlias: "test-model").run(
            input: input, context: context) { event in
            Task { await emitter.record(event) }
        }
        // The emitter tasks are unstructured; drain before asserting.
        for _ in 0..<50 {
            let events = await emitter.events
            if !events.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return (stop, await emitter.texts)
    }

    func testForwardsTextAndEmitsReply() async throws {
        final class Box: @unchecked Sendable { var seen: ChatRequest? }
        let box = Box()
        let ctx = context { request in
            box.seen = request
            return ChatResult(modelIdentity: "fake", content: "hello back",
                              finishReason: .stop, usage: nil)
        }
        let (stop, texts) = await run([.text("hi there")], context: ctx)
        XCTAssertEqual(stop, .endTurn)
        XCTAssertEqual(texts, ["hello back"])
        XCTAssertEqual(box.seen?.model, "test-model")
        XCTAssertEqual(box.seen?.messages.first?.combinedText, "hi there")
        XCTAssertEqual(box.seen?.maxOutputTokens, 256)
    }

    func testModelUnavailableIsTruthfulError() async {
        let ctx = context { _ in throw PlatformError(.providerUnavailable) }
        let (stop, texts) = await run([.text("hi")], context: ctx)
        XCTAssertEqual(stop, .error)
        XCTAssertTrue(texts.first?.contains("unavailable") ?? false)
    }

    func testEmptyInputIsRefusalWithoutModelCall() async {
        let ctx = context { _ in XCTFail("model must not be called"); fatalError() }
        let (stop, _) = await run([.text("   "), .resourceLink(uri: "file:///x", name: nil)],
                                 context: ctx)
        XCTAssertEqual(stop, .refusal)
    }

    func testCancelledBeforeModelCall() async {
        let ctx = context(cancelled: true) { _ in
            XCTFail("model must not be called")
            fatalError()
        }
        let (stop, _) = await run([.text("hi")], context: ctx)
        XCTAssertEqual(stop, .cancelled)
    }

    func testCancelledAfterModelReply() async {
        final class Flag: @unchecked Sendable { var value = false }
        let flag = Flag()
        let ctx = AgentContext(
            sessionID: "s", runID: "r",
            statusSnapshot: { .object([:]) },
            model: ModelClient { _ in
                flag.value = true
                return ChatResult(modelIdentity: "fake", content: "late",
                                  finishReason: .stop, usage: nil)
            },
            ml: MLClient { _ in throw PlatformError(.providerUnavailable) },
            isCancelled: { flag.value })
        let (stop, _) = await run([.text("hi")], context: ctx)
        XCTAssertEqual(stop, .cancelled)
    }
}
