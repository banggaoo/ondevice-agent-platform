import XCTest
import PlatformTestSupport
@testable import PlatformCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple provider seam: request mapping is exercised without any model call;
/// the provider itself reports truthful unavailability and never fabricates.
final class AppleProviderTests: XCTestCase {

    func testProviderIdentityStable() {
        let provider = AppleFoundationProvider()
        XCTAssertEqual(provider.providerID, "apple-foundation-models")
    }

    #if canImport(FoundationModels)
    func testMapBuildsOrderedTranscriptAndFinalPrompt() throws {
        let request = ChatRequest(model: "apple-foundation-model", messages: [
            ChatMessage(role: .system, parts: ["be terse"]),
            ChatMessage(role: .user, parts: ["hello"]),
            ChatMessage(role: .assistant, parts: ["hi"]),
            ChatMessage(role: .user, parts: ["status?"]),
        ], maxOutputTokens: 16)
        let mapped = try AppleFoundationProvider.map(request)
        XCTAssertEqual(mapped.options.maximumResponseTokens, 16)
        guard mapped.transcript.count == 3 else {
            return XCTFail("expected 3 transcript entries, got \(mapped.transcript.count)")
        }
        if case .instructions = mapped.transcript[0] {} else {
            XCTFail("first entry must be instructions")
        }
        if case .prompt = mapped.transcript[1] {} else {
            XCTFail("second entry must be a user prompt")
        }
        if case .response = mapped.transcript[2] {} else {
            XCTFail("third entry must be an assistant response")
        }
    }

    func testMapRejectsAssistantFinal() {
        let request = ChatRequest(model: "apple-foundation-model", messages: [
            ChatMessage(role: .user, parts: ["hi"]),
            ChatMessage(role: .assistant, parts: ["done"]),
        ], maxOutputTokens: 8)
        XCTAssertThrowsError(try AppleFoundationProvider.map(request)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest)
        }
    }

    func testMapRejectsEmptyFinalUser() {
        let request = ChatRequest(model: "apple-foundation-model", messages: [
            ChatMessage(role: .user, parts: ["   "]),
        ], maxOutputTokens: 8)
        XCTAssertThrowsError(try AppleFoundationProvider.map(request))
    }

    func testMapRejectsNoUserTurn() {
        let request = ChatRequest(model: "apple-foundation-model", messages: [
            ChatMessage(role: .system, parts: ["only instructions"]),
        ], maxOutputTokens: 8)
        XCTAssertThrowsError(try AppleFoundationProvider.map(request))
    }

    /// Tool-bearing history has no truthful transcript form on this
    /// provider: assistant tool calls and tool results are refused at the
    /// mapping seam, never silently dropped.
    func testMapRejectsToolTurns() {
        var request = ChatRequest(model: "apple-foundation-model", messages: [
            ChatMessage(role: .user, parts: ["hi"]),
            ChatMessage(role: .assistant, parts: [], toolCalls: [
                ChatToolCall(id: "c1", name: "bash", arguments: .object([:])),
            ]),
            ChatMessage(role: .user, parts: ["then?"]),
        ], maxOutputTokens: 8)
        XCTAssertThrowsError(try AppleFoundationProvider.map(request)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest)
        }
        request = ChatRequest(model: "apple-foundation-model", messages: [
            ChatMessage(role: .user, parts: ["hi"]),
            ChatMessage(role: .tool, parts: ["out"], toolCallID: "c1"),
            ChatMessage(role: .user, parts: ["then?"]),
        ], maxOutputTokens: 8)
        XCTAssertThrowsError(try AppleFoundationProvider.map(request)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest)
        }
    }
    #endif

    /// A caller declaring tools gets a platform error either way: refused
    /// as an unsupported surface when the model is available, or the
    /// existing providerUnavailable when it is not. Never a fake reply.
    func testDeclaredToolsErrorTruthfully() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        await stack.supervisor.registerModel(
            ModelProfile(alias: "apple-test", providerID: AppleFoundationProvider.id,
                         kind: .llm, task: "chat"),
            provider: AppleFoundationProvider())
        await registerStandardPrincipals(stack.supervisor)
        do {
            _ = try await stack.supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(model: "apple-test",
                                     messages: [ChatMessage(role: .user, parts: ["hi"])],
                                     maxOutputTokens: 4,
                                     tools: [ChatToolSpec(name: "bash")]))
            XCTFail("expected a platform error")
        } catch let e as PlatformError {
            XCTAssertTrue([.invalidRequest, .providerUnavailable].contains(e.code),
                          "unexpected \(e.code)")
        }
        // tool_choice "none" withholds the declarations: plain chat works
        // (or reports unavailability) exactly as before.
        do {
            _ = try await stack.supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(model: "apple-test",
                                     messages: [ChatMessage(role: .user, parts: ["hi"])],
                                     maxOutputTokens: 4,
                                     tools: [ChatToolSpec(name: "bash")],
                                     toolChoice: .none))
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .providerUnavailable)
        }
    }

    /// The Apple route honors only temperature: other sampling fields are
    /// explicit rejections, never silently ignored.
    func testValidateRejectsUnsupportedSamplers() {
        let provider = AppleFoundationProvider()
        let profile = ModelProfile(alias: "apple-test",
                                   providerID: AppleFoundationProvider.id,
                                   kind: .llm, task: "chat")
        func request(topP: Double? = nil, seed: UInt64? = nil,
                     presencePenalty: Double? = nil,
                     frequencyPenalty: Double? = nil) -> ChatRequest {
            ChatRequest(model: "apple-test",
                        messages: [ChatMessage(role: .user, parts: ["hi"])],
                        maxOutputTokens: 8, temperature: 0.5, topP: topP,
                        seed: seed, presencePenalty: presencePenalty,
                        frequencyPenalty: frequencyPenalty)
        }
        XCTAssertNoThrow(try provider.validate(request(), profile: profile))
        for r in [request(topP: 0.9), request(seed: 7),
                  request(presencePenalty: 0.5), request(frequencyPenalty: -0.5)] {
            XCTAssertThrowsError(try provider.validate(r, profile: profile)) {
                XCTAssertEqual(($0 as? PlatformError)?.code, .invalidRequest)
            }
        }
    }

    #if canImport(FoundationModels)
    /// Response-format guidance is appended to mapped instructions so the
    /// shared hint text actually reaches the session.
    func testMapAppendsSharedResponseFormatGuidance() throws {
        let request = ChatRequest(model: "apple-foundation-model", messages: [
            ChatMessage(role: .user, parts: ["hi"]),
        ], maxOutputTokens: 8, responseFormat: .jsonObject)
        let mapped = try AppleFoundationProvider.map(request)
        guard let first = mapped.transcript.first,
              case .instructions(let instructions) = first else {
            return XCTFail("expected an instructions entry")
        }
        let text = instructions.segments.compactMap { segment -> String? in
            if case .text(let t) = segment { return t.content }
            return nil
        }.joined(separator: "\n")
        XCTAssertTrue(text.contains(
            "Respond with a single valid JSON object and no other text."))
    }
    #endif

    /// The provider never fabricates a completion: on this host the model is
    /// either unavailable (throws PlatformError) or available and returns a
    /// real result through shared admission - both are truthful outcomes.
    func testCompleteIsTruthfulEitherWay() async throws {
        let stack = try await makeStack()
        await stack.supervisor.registerModel(
            ModelProfile(alias: "apple-test", providerID: AppleFoundationProvider.id,
                         kind: .llm, task: "chat"),
            provider: AppleFoundationProvider())
        await registerStandardPrincipals(stack.supervisor)
        do {
            let chat = try await stack.supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(model: "apple-test",
                                     messages: [ChatMessage(role: .user, parts: ["hi"])],
                                     maxOutputTokens: 4))
            XCTAssertFalse(chat.content.isEmpty)
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .providerUnavailable)
        }
    }
}
