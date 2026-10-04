import XCTest
import ImageIO
import UniformTypeIdentifiers
import PlatformTestSupport
@testable import PlatformCore

/// Shared core request bounds: every malformed/oversized request must fail
/// inside submitLLM/submitML before a provider is invoked or a job row is
/// persisted. Positive image fixtures are real encoded images, not
/// signature-only bytes - the adapter's syntactic parse is a separate layer.
final class RequestValidationTests: XCTestCase {

    private func stack() async throws -> TestStack {
        let stack = try await makeStack()
        await registerStandardPrincipals(stack.supervisor)
        return stack
    }

    private func chat(
        model: String = "test-llm",
        messages: [ChatMessage] = [ChatMessage(role: .user, parts: ["hi"])],
        maxOutputTokens: Int = 8,
        temperature: Double? = nil, topP: Double? = nil, seed: UInt64? = nil,
        presencePenalty: Double? = nil, frequencyPenalty: Double? = nil,
        responseFormat: ResponseFormat? = nil
    ) -> ChatRequest {
        ChatRequest(model: model, messages: messages, maxOutputTokens: maxOutputTokens,
                    temperature: temperature, topP: topP, seed: seed,
                    presencePenalty: presencePenalty, frequencyPenalty: frequencyPenalty,
                    responseFormat: responseFormat)
    }

    private func llm(_ provider: FakeLLMProvider = FakeLLMProvider(),
                     profile: ModelProfile? = nil) async throws -> (TestStack, FakeLLMProvider) {
        let stack = try await stack()
        let profile = profile ?? ModelProfile(alias: "test-llm", providerID: provider.providerID,
                                              kind: .llm, task: "chat")
        await stack.supervisor.registerModel(profile, provider: provider)
        return (stack, provider)
    }

    /// The request must be refused before provider invocation and before a
    /// job row exists.
    private func expectRejected(_ code: ErrorCode, _ stack: TestStack,
                                _ provider: FakeLLMProvider, _ request: ChatRequest,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        try await expectPlatformError(code, {
            _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                     request: request)
        }, file: file, line: line)
        XCTAssertTrue(provider.invocations.isEmpty,
                      "rejected request reached the provider", file: file, line: line)
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.isEmpty, "rejected request persisted a job",
                      file: file, line: line)
    }

    // MARK: token/message/sampling bounds

    func testOutputTokenBounds() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(maxOutputTokens: 0))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(maxOutputTokens: PlatformLimits.outputTokens + 1))
        // Global boundary equality is accepted.
        let ok = try await stack.supervisor.submitLLM(
            principal: modelPrincipal,
            request: chat(maxOutputTokens: PlatformLimits.outputTokens))
        XCTAssertEqual(ok.content, "ok")
    }

    func testProfileOutputCap() async throws {
        let capped = FakeLLMProvider(autoFinish: true)
        let (stack, provider) = try await llm(capped, profile: ModelProfile(
            alias: "test-llm", providerID: capped.providerID, kind: .llm,
            task: "chat", maxOutputTokens: 32))
        defer { stack.root.releaseLock() }
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(maxOutputTokens: 33))
        _ = try await stack.supervisor.submitLLM(
            principal: modelPrincipal, request: chat(maxOutputTokens: 32))
    }

    func testMessageCountAndEmptyContent() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        try await expectRejected(.invalidRequest, stack, provider, chat(messages: []))
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: (0...PlatformLimits.chatMessages).map {
                _ in ChatMessage(role: .user, parts: ["hi"])
            }))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(messages: [ChatMessage(role: .user, parts: [])]))
        // Exactly the message bound is admitted.
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: (0..<PlatformLimits.chatMessages).map {
                _ in ChatMessage(role: .user, parts: ["hi"])
            }))
    }

    func testTextByteLimits() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        try await expectRejected(.payloadTooLarge, stack, provider, chat(
            messages: [ChatMessage(
                role: .user,
                parts: [String(repeating: "a", count: PlatformLimits.chatTextBytes + 1)])]))
        // Exactly the global text bound is admitted.
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: [ChatMessage(
                role: .user,
                parts: [String(repeating: "a", count: PlatformLimits.chatTextBytes)])]))
    }

    func testProfileInputBound() async throws {
        let capped = FakeLLMProvider(autoFinish: true)
        let (stack, provider) = try await llm(capped, profile: ModelProfile(
            alias: "test-llm", providerID: capped.providerID, kind: .llm,
            task: "chat", maxInputBytes: 8))
        defer { stack.root.releaseLock() }
        try await expectRejected(.payloadTooLarge, stack, provider, chat(
            messages: [ChatMessage(role: .user, parts: ["123456789"])]))
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: [ChatMessage(role: .user, parts: ["12345678"])]))
    }

    func testSamplingBounds() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(temperature: .nan))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(temperature: 2.1))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(topP: -0.1))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(topP: 1.1))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(presencePenalty: 2.1))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(frequencyPenalty: -2.1))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(seed: UInt64.max))
        // Boundary values and the Int64-range seed are accepted.
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal,
                                                 request: chat(temperature: 0, topP: 1,
                                                               seed: UInt64(Int64.max),
                                                               presencePenalty: -2,
                                                               frequencyPenalty: 2))
    }

    // MARK: images

    /// Real PNG bytes for a solid `width`x`height` image. `frames` > 1 emits
    /// an animated PNG (APNG); `padding` appends a tEXt chunk before IEND.
    private func png(width: Int, height: Int, frames: Int = 1,
                     padding: Int = 0) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, frames, nil)!
        for _ in 0..<frames {
            CGImageDestinationAddImage(
                dest, image,
                frames > 1 ? [kCGImagePropertyAPNGDelayTime: 0.1] as CFDictionary : nil)
        }
        CGImageDestinationFinalize(dest)
        var data = out as Data
        if padding > 0 {
            var body = Data("tEXt".utf8)
            body.append(Data(repeating: 0x41, count: padding))
            var len = UInt32(padding).bigEndian
            var chunk = Data(bytes: &len, count: 4)
            chunk.append(body)
            var crc = Self.pngCRC(body).bigEndian
            chunk.append(Data(bytes: &crc, count: 4))
            data.insert(contentsOf: chunk, at: data.count - 12)   // before IEND
        }
        return data
    }

    private static func pngCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
        }
        return crc ^ 0xFFFFFFFF
    }

    private func visionChat(_ data: Data, mime: String = "image/png") -> ChatRequest {
        chat(messages: [ChatMessage(
            role: .user, parts: ["hi"],
            images: [ChatImage(data: data, mediaType: mime)])])
    }

    private func visionStack() async throws -> (TestStack, FakeLLMProvider) {
        let provider = FakeLLMProvider(autoFinish: true)
        return try await llm(provider, profile: ModelProfile(
            alias: "test-llm", providerID: provider.providerID, kind: .llm,
            task: "chat", capabilities: ["vision"]))
    }

    func testValidOnePixelPNGIsAdmitted() async throws {
        let (stack, provider) = try await visionStack()
        defer { stack.root.releaseLock() }
        let result = try await stack.supervisor.submitLLM(
            principal: modelPrincipal, request: visionChat(png(width: 1, height: 1)))
        XCTAssertEqual(result.content, "ok")
        XCTAssertEqual(provider.invocations.count, 1)
    }

    func testImageRoleAndCapability() async throws {
        let (stack, provider) = try await visionStack()
        defer { stack.root.releaseLock() }
        let data = png(width: 1, height: 1)
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [ChatMessage(role: .assistant, parts: ["hi"],
                                   images: [ChatImage(data: data, mediaType: "image/png")])]))
        // A vision request against a text-only profile is rejected too.
        let plain = FakeLLMProvider()
        let (textStack, textProvider) = try await llm(plain)
        defer { textStack.root.releaseLock() }
        try await expectRejected(.invalidRequest, textStack, textProvider,
                                 visionChat(data))
    }

    func testBadImageBytesAndMimeMismatch() async throws {
        let (stack, provider) = try await visionStack()
        defer { stack.root.releaseLock() }
        try await expectRejected(.invalidRequest, stack, provider,
                                 visionChat(Data([0x00, 0x11, 0x22, 0x33])))
        // PNG bytes declared as JPEG: actual format must match the MIME.
        try await expectRejected(.invalidRequest, stack, provider,
                                 visionChat(png(width: 1, height: 1), mime: "image/jpeg"))
        // Animated PNG: exactly one frame is allowed.
        try await expectRejected(.invalidRequest, stack, provider,
                                 visionChat(png(width: 1, height: 1, frames: 2)))
    }

    func testImageCountAndByteCaps() async throws {
        let (stack, provider) = try await visionStack()
        defer { stack.root.releaseLock() }
        let one = png(width: 1, height: 1)
        try await expectRejected(.payloadTooLarge, stack, provider, chat(
            messages: [ChatMessage(
                role: .user, parts: ["hi"],
                images: (0...PlatformLimits.chatImagesPerRequest).map {
                    _ in ChatImage(data: one, mediaType: "image/png")
                })]))
        // Decoded image bytes above the 16 MiB cap, even though the image
        // itself is a valid 1x1 PNG.
        let big = png(width: 1, height: 1, padding: PlatformLimits.chatImageBytes)
        XCTAssertGreaterThan(big.count, PlatformLimits.chatImageBytes)
        try await expectRejected(.payloadTooLarge, stack, provider, visionChat(big))
    }

    func testImageDimensionAndPixelCaps() async throws {
        let (stack, provider) = try await visionStack()
        defer { stack.root.releaseLock() }
        let dim = PlatformLimits.chatImageDimension
        // One pixel over the dimension bound.
        try await expectRejected(.payloadTooLarge, stack, provider,
                                 visionChat(png(width: dim + 1, height: 1)))
        // Per-image pixel cap: the helper checks bounds before multiplying.
        XCTAssertThrowsError(try RequestValidation.imagePixels(width: dim, height: dim)) {
            XCTAssertEqual(($0 as? PlatformError)?.code, .payloadTooLarge)
        }
        XCTAssertThrowsError(try RequestValidation.imagePixels(width: dim + 1, height: 1)) {
            XCTAssertEqual(($0 as? PlatformError)?.code, .payloadTooLarge)
        }
        XCTAssertThrowsError(try RequestValidation.imagePixels(width: 0, height: 1)) {
            XCTAssertEqual(($0 as? PlatformError)?.code, .payloadTooLarge)
        }
        // Equality at the dimension bound passes when pixels fit exactly.
        XCTAssertEqual(try RequestValidation.imagePixels(
            width: dim, height: PlatformLimits.chatImagePixels / dim),
                       PlatformLimits.chatImagePixels)
        // Aggregate pixels over the cap across individually-valid images:
        // each side^2 is under the per-image cap, three of them exceed it.
        let side = Int(Double(PlatformLimits.chatImagePixels / 2).squareRoot()) + 1
        let large = png(width: side, height: side)
        try await expectRejected(.payloadTooLarge, stack, provider, chat(
            messages: [ChatMessage(
                role: .user, parts: ["hi"],
                images: (0..<3).map { _ in ChatImage(data: large, mediaType: "image/png") })]))
    }

    // MARK: response format byte accounting

    func testGuidanceCountsTowardTextAndInputBounds() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        // Text exactly at the global bound passes alone, then fails once the
        // guidance string pushes it over.
        let full = PlatformLimits.chatTextBytes
        let guidance = try ResponseFormat.jsonObject.guidance()
        try await expectRejected(.payloadTooLarge, stack, provider, chat(
            messages: [ChatMessage(
                role: .user,
                parts: [String(repeating: "a", count: full - guidance.utf8.count + 1)])],
            responseFormat: .jsonObject))
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: [ChatMessage(
                role: .user,
                parts: [String(repeating: "a", count: full - guidance.utf8.count)])],
            responseFormat: .jsonObject))
        // Same accounting against a profile input cap.
        let capped = FakeLLMProvider(autoFinish: true)
        let (capStack, cappedProvider) = try await llm(capped, profile: ModelProfile(
            alias: "test-llm", providerID: capped.providerID, kind: .llm, task: "chat",
            maxInputBytes: "hi".utf8.count + guidance.utf8.count))
        defer { capStack.root.releaseLock() }
        try await expectRejected(.payloadTooLarge, capStack, cappedProvider, chat(
            messages: [ChatMessage(role: .user, parts: ["hi!"])],
            responseFormat: .jsonObject))
        _ = try await capStack.supervisor.submitLLM(
            principal: modelPrincipal, request: chat(responseFormat: .jsonObject))
    }

    func testMalformedResponseFormatSchema() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(responseFormat: .jsonSchema(name: nil, schema: .array([]))))
        try await expectRejected(.invalidRequest, stack, provider,
                                 chat(responseFormat: .jsonSchema(
                                    name: nil, schema: .object(["x": .double(.nan)]))))
    }

    // MARK: empty content and tool surface

    /// Whitespace-only parts carry no content; an image or a tool call can
    /// still make a message valid on its own.
    func testEmptyStringOnlyMessagesRejected() async throws {
        let (stack, provider) = try await visionStack()
        defer { stack.root.releaseLock() }
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [ChatMessage(role: .user, parts: ["", "  \t ", "\n"])]))
        // Empty text is valid when the user turn carries a real image.
        let one = png(width: 1, height: 1)
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: [ChatMessage(role: .user, parts: [""],
                                   images: [ChatImage(data: one, mediaType: "image/png")])]))
        // An assistant turn whose only content is a tool call is valid.
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [""], toolCalls: [
                    ChatToolCall(id: "c1", name: "f", arguments: .object([:])),
                ]),
                ChatMessage(role: .tool, parts: ["done"], toolCallID: "c1"),
                ChatMessage(role: .user, parts: ["next"]),
            ]))
    }

    /// Byte/count image caps must reject before any ImageIO decode: bad
    /// bytes still answer payloadTooLarge, never invalidRequest.
    func testImageCapsRejectBeforeDecode() async throws {
        let (stack, provider) = try await visionStack()
        defer { stack.root.releaseLock() }
        // Count cap: five garbage images - decode never runs.
        try await expectRejected(.payloadTooLarge, stack, provider, chat(
            messages: [ChatMessage(
                role: .user, parts: ["hi"],
                images: (0...PlatformLimits.chatImagesPerRequest).map {
                    _ in ChatImage(data: Data([0x00, 0x11]), mediaType: "image/png")
                })]))
        // Byte cap: a single garbage blob over the cap.
        try await expectRejected(.payloadTooLarge, stack, provider, visionChat(
            Data(repeating: 0xAB, count: PlatformLimits.chatImageBytes + 1)))
    }

    /// Tool-call/message-shape rules enforced inside the core even for
    /// non-HTTP callers.
    func testToolMessageShapeValidation() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        func call(id: String? = "c1", name: String = "fn",
                  arguments: JSONValue = .object([:])) -> ChatToolCall {
            ChatToolCall(id: id, name: name, arguments: arguments)
        }
        // tool_calls only on assistant messages.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [ChatMessage(role: .user, parts: ["hi"], toolCalls: [call()])]))
        // tool_call_id only on tool messages, and tool messages require it.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [ChatMessage(role: .user, parts: ["hi"], toolCallID: "c1")]))
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .tool, parts: ["done"]),
            ]))
        // Uncorrelated tool_call_id has no matching earlier assistant call.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .tool, parts: ["done"], toolCallID: "ghost"),
            ]))
        // Name/id shape: ASCII function names, bounded ids.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [],
                            toolCalls: [call(name: "bad name!")]),
                ChatMessage(role: .tool, parts: ["x"], toolCallID: "c1"),
                ChatMessage(role: .user, parts: ["hi"]),
            ]))
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [call(name: "")]),
                ChatMessage(role: .user, parts: ["hi"]),
            ]))
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [
                    call(id: String(repeating: "x", count: 129)),
                ]),
                ChatMessage(role: .user, parts: ["hi"]),
            ]))
        // Arguments must be an object and encodable (no silent zero-count).
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [call(arguments: .string("x"))]),
                ChatMessage(role: .user, parts: ["hi"]),
            ]))
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [
                    call(arguments: .object(["v": .double(.infinity)])),
                ]),
                ChatMessage(role: .user, parts: ["hi"]),
            ]))
        // Per-message tool-call count bound.
        try await expectRejected(.payloadTooLarge, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [],
                            toolCalls: (0...PlatformLimits.chatToolCallsPerMessage).map {
                                i in call(id: "c\(i)")
                            }),
                ChatMessage(role: .user, parts: ["hi"]),
            ]))
    }

    /// Request call history must carry unique, present ids; a tool result
    /// answers exactly one outstanding call, and an unresolved call cannot
    /// be followed by an unrelated user turn.
    func testToolCallIDRules() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        func call(_ id: String?, name: String = "f") -> ChatToolCall {
            ChatToolCall(id: id, name: name, arguments: .object([:]))
        }
        // Missing id: the call can never be answered.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [call(nil)]),
                ChatMessage(role: .tool, parts: ["x"], toolCallID: "c1"),
            ]))
        // Duplicate ids inside one assistant turn.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [],
                            toolCalls: [call("c1"), call("c1")]),
                ChatMessage(role: .tool, parts: ["x"], toolCallID: "c1"),
            ]))
        // Re-declaring an already-answered id is still a duplicate.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [call("c1")]),
                ChatMessage(role: .tool, parts: ["x"], toolCallID: "c1"),
                ChatMessage(role: .assistant, parts: [], toolCalls: [call("c1")]),
                ChatMessage(role: .tool, parts: ["y"], toolCallID: "c1"),
                ChatMessage(role: .user, parts: ["next"]),
            ]))
        // A second tool message cannot answer the same call twice.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [call("c1")]),
                ChatMessage(role: .tool, parts: ["x"], toolCallID: "c1"),
                ChatMessage(role: .tool, parts: ["y"], toolCallID: "c1"),
                ChatMessage(role: .user, parts: ["next"]),
            ]))
        // An unrelated user turn while calls are unanswered is refused.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [call("c1")]),
                ChatMessage(role: .user, parts: ["skipping the reply"]),
            ]))
        // Fully correlated history still admits.
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [],
                            toolCalls: [call("c1"), call("c2")]),
                ChatMessage(role: .tool, parts: ["a"], toolCallID: "c1"),
                ChatMessage(role: .tool, parts: ["b"], toolCallID: "c2"),
                ChatMessage(role: .user, parts: ["and now?"]),
            ]))
    }

    /// Declared tool list bounds: count, unique valid names, object schemas,
    /// and a named tool_choice that must reference a declared tool.
    func testToolsListValidation() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        func request(tools: [ChatToolSpec], choice: ToolChoice = .auto) -> ChatRequest {
            ChatRequest(model: "test-llm",
                        messages: [ChatMessage(role: .user, parts: ["hi"])],
                        maxOutputTokens: 8, tools: tools, toolChoice: choice)
        }
        try await expectRejected(.payloadTooLarge, stack, provider, request(
            tools: (0...PlatformLimits.chatTools).map {
                ChatToolSpec(name: "f\($0)", parameters: .object([:]))
            }))
        try await expectRejected(.invalidRequest, stack, provider, request(
            tools: [ChatToolSpec(name: "dup"), ChatToolSpec(name: "dup")]))
        try await expectRejected(.invalidRequest, stack, provider, request(
            tools: [ChatToolSpec(name: "not a name")]))
        try await expectRejected(.invalidRequest, stack, provider, request(
            tools: [ChatToolSpec(name: "f", parameters: .array([]))]))
        try await expectRejected(.invalidRequest, stack, provider, request(
            tools: [ChatToolSpec(name: "f",
                                 parameters: .object(["v": .double(.nan)]))]))
        try await expectRejected(.invalidRequest, stack, provider, request(
            tools: [ChatToolSpec(name: "f")], choice: .named("ghost")))
        // Valid declarations and a matching named choice are admitted.
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: request(
            tools: [ChatToolSpec(name: "f", parameters: .object(["type": .string("object")]))],
            choice: .named("f")))
    }

    /// A request must end on a turn the model can answer.
    func testFinalMessageContract() async throws {
        let (stack, provider) = try await llm(FakeLLMProvider(autoFinish: true))
        defer { stack.root.releaseLock() }
        // System-only and trailing assistant/developer turns are refused.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [ChatMessage(role: .system, parts: ["rules"])]))
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: ["reply"]),
            ]))
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .developer, parts: ["note"]),
            ]))
        // A trailing tool result is allowed only correlated to a prior call.
        try await expectRejected(.invalidRequest, stack, provider, chat(
            messages: [
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .tool, parts: ["done"], toolCallID: "ghost"),
            ]))
        _ = try await stack.supervisor.submitLLM(principal: modelPrincipal, request: chat(
            messages: [
                ChatMessage(role: .system, parts: ["rules"]),
                ChatMessage(role: .user, parts: ["hi"]),
                ChatMessage(role: .assistant, parts: [], toolCalls: [
                    ChatToolCall(id: "c1", name: "f", arguments: .object([:])),
                ]),
                ChatMessage(role: .tool, parts: ["done"], toolCallID: "c1"),
            ]))
    }

    // MARK: ML bounds

    func testPredictionBoundsBeforeInvocation() async throws {
        let stack = try await stack()
        let predictor = FakeMLPredictor()
        await stack.supervisor.registerModel(ModelProfile(
            alias: "test-ml", providerID: predictor.providerID, kind: .ml,
            task: "classify", inputSchema: ["x": .string],
            outputSchema: ["label": .string], maxInputBytes: 32),
            predictor: predictor)
        defer { stack.root.releaseLock() }

        func predict(_ request: PredictionRequest) async throws {
            _ = try await stack.supervisor.submitML(principal: modelPrincipal,
                                                    request: request)
        }
        try await expectPlatformError(.invalidRequest) {
            try await predict(PredictionRequest(model: "test-ml", task: "other",
                                                inputs: ["x": .string("y")]))
        }
        try await expectPlatformError(.invalidRequest) {
            try await predict(PredictionRequest(model: "test-ml", task: "classify",
                                                inputs: ["x": .double(1)]))
        }
        // Schema-valid but serialized above the profile input bound.
        try await expectPlatformError(.payloadTooLarge) {
            try await predict(PredictionRequest(
                model: "test-ml", task: "classify",
                inputs: ["x": .string(String(repeating: "y", count: 64))]))
        }
        XCTAssertTrue(predictor.invocations.isEmpty)
        let jobs = try await stack.supervisor.listJobs()
        XCTAssertTrue(jobs.isEmpty)
    }
}
