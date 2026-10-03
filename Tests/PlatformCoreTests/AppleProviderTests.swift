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
