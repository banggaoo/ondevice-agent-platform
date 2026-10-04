import XCTest
import PlatformTestSupport
@testable import PlatformServing
@testable import PlatformCore

/// Wire-format and adapter validation: strict HTTP/1.1 framing and the exact
/// OpenAI/ML request subsets.
final class AdapterAndParserTests: XCTestCase {

    // MARK: HTTP parser

    private func parse(_ text: String) throws -> (request: HTTPRequest, consumed: Int)? {
        try HTTPParser.parse(Data(text.utf8))
    }

    func testValidRequestParses() throws {
        let raw = "POST /api/x?q=1 HTTP/1.1\r\nHost: 127.0.0.1:9\r\nContent-Length: 4\r\n\r\nbody"
        let parsed = try parse(raw)
        XCTAssertEqual(parsed?.request.method, "POST")
        XCTAssertEqual(parsed?.request.path, "/api/x")
        XCTAssertEqual(parsed?.request.body, Data("body".utf8))
        XCTAssertEqual(parsed?.consumed, raw.utf8.count)
    }

    func testFramingDenials() {
        let cases: [String] = [
            // Duplicate Host
            "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
            // Missing Host on 1.1
            "GET / HTTP/1.1\r\n\r\n",
            // Transfer-Encoding refused
            "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            // Conflicting Content-Length
            "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
            // Negative Content-Length
            "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n",
            // Absolute-form target refused
            "GET http://evil.example/ HTTP/1.1\r\nHost: a\r\n\r\n",
            // Unsupported Expect
            "POST / HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\n\r\n",
        ]
        for raw in cases {
            XCTAssertThrowsError(try parse(raw), "should reject: \(raw.prefix(40))")
        }
    }

    func testBareLFAndPipeliningRefused() {
        XCTAssertThrowsError(try HTTPParser.parse(
            Data("GET / HTTP/1.1\nHost: a\n\n".utf8)))
        let pipelined = "GET / HTTP/1.1\r\nHost: a\r\n\r\nGET /b HTTP/1.1\r\nHost: a\r\n\r\n"
        XCTAssertThrowsError(try parse(pipelined)) { error in
            XCTAssertEqual(error as? HTTPParseError, .closing)
        }
    }

    func testOversizedHeaderAndBodyRefused() {
        let bigHeader = "GET / HTTP/1.1\r\nHost: a\r\nX-Fill: "
            + String(repeating: "x", count: PlatformLimits.requestHeaderBytes)
            + "\r\n\r\n"
        XCTAssertThrowsError(try parse(bigHeader)) { error in
            XCTAssertEqual(error as? HTTPParseError, .tooLarge)
        }
        let bigBody = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: "
            + "\(PlatformLimits.requestBodyBytes + 1)\r\n\r\n"
        XCTAssertThrowsError(try parse(bigBody))
    }

    // MARK: OpenAI adapter

    private func chatBody(_ modify: (inout [String: JSONValue]) -> Void = { _ in }) -> Data {
        var object: [String: JSONValue] = [
            "model": .string("m"),
            "messages": .array([
                .object(["role": .string("system"), "content": .string("s")]),
                .object(["role": .string("developer"), "content": .string("d")]),
                .object(["role": .string("user"),
                         "content": .array([
                            .object(["type": .string("text"), "text": .string("a")]),
                            .object(["type": .string("text"), "text": .string("b")]),
                         ])]),
                .object(["role": .string("assistant"), "content": .string("r")]),
            ]),
        ]
        modify(&object)
        return (try? JSONValue.object(object).encoded()) ?? Data()
    }

    func testOrderedRolesAndTextPartsPreserved() throws {
        let parsed = try OpenAIAdapter.parseChatRequest(chatBody())
        let request = parsed.request
        XCTAssertFalse(parsed.stream)
        XCTAssertFalse(parsed.includeUsage)
        XCTAssertEqual(request.messages.map(\.role),
                       [.system, .developer, .user, .assistant])
        XCTAssertEqual(request.messages[2].parts, ["a", "b"])
        XCTAssertEqual(request.maxOutputTokens, PlatformLimits.outputTokens)
    }

    func testRejectedOpenAIFields() {
        let cases: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("tool role lacks id", { $0["messages"] = .array([
                .object(["role": .string("tool"), "content": .string("x")])]) }),
            ("image part", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object(["url": .string("x")])])])])]) }),
            ("response_format", { $0["response_format"] = .object([:]) }),
            ("stream nonbool", { $0["stream"] = .string("yes") }),
            ("stream_options unsupported field", {
                $0["stream"] = .bool(true)
                $0["stream_options"] = .object(["bogus": .bool(true)])
            }),
            ("stream_options without stream", {
                $0["stream_options"] = .object(["include_usage": .bool(true)])
            }),
            ("unknown field", { $0["mystery"] = .int(1) }),
            ("both token fields", {
                $0["max_tokens"] = .int(4)
                $0["max_completion_tokens"] = .int(4)
            }),
            ("n>1", { $0["n"] = .int(2) }),
            ("empty messages", { $0["messages"] = .array([]) }),
            ("oversized max", { $0["max_tokens"] = .int(Int64(PlatformLimits.outputTokens) + 1) }),
        ]
        for (name, mutate) in cases {
            XCTAssertThrowsError(try OpenAIAdapter.parseChatRequest(chatBody(mutate)),
                                 "expected rejection: \(name)") { error in
                XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest, name)
            }
        }
    }

    /// The full tool surface OpenCode sends: function schemas, tool_choice,
    /// an assistant turn carrying tool_calls, and the tool results answering
    /// them - each with strict field checking.
    func testToolSurfaceParses() throws {
        let parsed = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["stream"] = .bool(true)
            $0["stream_options"] = .object(["include_usage": .bool(true)])
            $0["tool_choice"] = .string("auto")
            $0["tools"] = .array([
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string("bash"),
                        "description": .string("run a shell command"),
                        "parameters": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "command": .object(["type": .string("string")]),
                            ]),
                            "required": .array([.string("command")]),
                        ]),
                    ]),
                ]),
            ])
            $0["messages"] = .array([
                .object(["role": .string("user"), "content": .string("list files")]),
                .object(["role": .string("assistant"), "content": .null,
                         "tool_calls": .array([
                            .object([
                                "id": .string("call_0"),
                                "type": .string("function"),
                                "function": .object([
                                    "name": .string("bash"),
                                    "arguments": .string("{\"command\":\"ls\"}"),
                                ]),
                            ]),
                         ])]),
                .object(["role": .string("tool"), "tool_call_id": .string("call_0"),
                         "content": .string("file.txt")]),
            ])
        })
        XCTAssertTrue(parsed.stream)
        XCTAssertTrue(parsed.includeUsage)
        let request = parsed.request
        XCTAssertEqual(request.toolChoice, .auto)
        XCTAssertEqual(request.tools.count, 1)
        XCTAssertEqual(request.tools[0].name, "bash")
        XCTAssertEqual(request.tools[0].parameters?.objectValue?["type"], .string("object"))
        let roles = request.messages.map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .tool])
        XCTAssertEqual(request.messages[1].toolCalls.count, 1)
        XCTAssertEqual(request.messages[1].toolCalls[0].id, "call_0")
        XCTAssertEqual(request.messages[1].toolCalls[0].name, "bash")
        XCTAssertEqual(request.messages[1].toolCalls[0].arguments,
                       .object(["command": .string("ls")]))
        XCTAssertEqual(request.messages[2].toolCallID, "call_0")
        XCTAssertEqual(request.messages[2].parts, ["file.txt"])
    }

    func testToolChoiceVariantsAndValidation() throws {
        // "required" and named-object forms parse.
        var parsed = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["tool_choice"] = .string("required")
        })
        XCTAssertEqual(parsed.request.toolChoice, .required)
        parsed = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["tool_choice"] = .object([
                "type": .string("function"),
                "function": .object(["name": .string("bash")]),
            ])
        })
        XCTAssertEqual(parsed.request.toolChoice, .named("bash"))
        parsed = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["tool_choice"] = .string("none")
        })
        XCTAssertEqual(parsed.request.toolChoice, .none)

        let bad: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("tool not function", { $0["tools"] = .array([
                .object(["type": .string("retrieval")])]) }),
            ("tool strict refused", { $0["tools"] = .array([
                .object(["type": .string("function"),
                         "function": .object(["name": .string("x"),
                                              "strict": .bool(true)])])]) }),
            ("tool params nonobject", { $0["tools"] = .array([
                .object(["type": .string("function"),
                         "function": .object(["name": .string("x"),
                                              "parameters": .string("no")])])]) }),
            ("tool_choice unknown", { $0["tool_choice"] = .string("sometimes") }),
            ("tool_call bad args", { $0["messages"] = .array([
                .object(["role": .string("assistant"),
                         "tool_calls": .array([
                            .object(["type": .string("function"),
                                     "function": .object([
                                        "name": .string("f"),
                                        "arguments": .string("not json")])])])])]) }),
            ("tool_calls on user", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .string("x"),
                         "tool_calls": .array([])])]) }),
            ("tool_call_id on user", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .string("x"),
                         "tool_call_id": .string("c")])]) }),
            ("parallel_tool_calls refused", { $0["parallel_tool_calls"] = .bool(true) }),
        ]
        for (name, mutate) in bad {
            XCTAssertThrowsError(try OpenAIAdapter.parseChatRequest(chatBody(mutate)),
                                 "expected rejection: \(name)") { error in
                XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest, name)
            }
        }
    }

    /// Wire emission: non-stream messages omit `index`; stream deltas carry
    /// it; arguments re-encode as a JSON string; a tool-calls-only turn has
    /// null content and finish_reason tool_calls; usage rides the last
    /// chunk when asked for.
    func testToolCallWireEmission() throws {
        let result = ChatResult(
            modelIdentity: "fake-llm", content: "",
            finishReason: .stop,
            usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
            toolCalls: [ChatToolCall(name: "bash",
                                     arguments: .object(["command": .string("ls")]))])
        let message = OpenAIAdapter.chatResponse(result, requestedModel: "m")
        // The wire model is the requested serving alias; ids are unique per
        // response so client history never collides across turns.
        XCTAssertEqual(message.objectValue?["model"], .string("m"))
        let completionID = message.objectValue?["id"]?.stringValue
        XCTAssertNotNil(completionID)
        XCTAssertTrue(completionID?.hasPrefix("chatcmpl-") == true)
        let choice = message.objectValue?["choices"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(choice?["finish_reason"], .string("tool_calls"))
        let msg = choice?["message"]?.objectValue
        XCTAssertEqual(msg?["content"], .null)
        let call = msg?["tool_calls"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(call?["id"], .string("call_\(completionID ?? "")_0"))
        XCTAssertNil(call?["index"])
        XCTAssertEqual(call?["function"]?.objectValue?["arguments"],
                       .string("{\"command\":\"ls\"}"))
        // A second response never reuses the first's completion or call id.
        let again = OpenAIAdapter.chatResponse(result, requestedModel: "m")
        XCTAssertNotEqual(again.objectValue?["id"], message.objectValue?["id"])
        let againCall = again.objectValue?["choices"]?.arrayValue?.first?
            .objectValue?["message"]?.objectValue?["tool_calls"]?
            .arrayValue?.first?.objectValue?["id"]
        XCTAssertNotEqual(againCall, call?["id"])

        let frames = OpenAIAdapter.streamFrames(result, requestedModel: "m",
                                                includeUsage: true)
        let body = frames.map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertTrue(body.hasPrefix("data: "))
        XCTAssertTrue(body.hasSuffix("data: [DONE]\n\n"))
        // Field assertions parse the frames: Dictionary encoding order is
        // unspecified, so substring key-order matches are not a contract.
        let chunks = try Self.sseObjects(body)
        // Every chunk in one stream - deltas and the usage frame - carries
        // the same completion id and the requested alias.
        let streamIDs = Set(chunks.compactMap { $0.objectValue?["id"]?.stringValue })
        XCTAssertEqual(streamIDs.count, 1)
        XCTAssertTrue(streamIDs.first?.hasPrefix("chatcmpl-") == true)
        XCTAssertTrue(chunks.allSatisfy { $0.objectValue?["model"] == .string("m") })
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["choices"]?.arrayValue?.first?
                .objectValue?["finish_reason"] == .string("tool_calls")
        })
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["choices"]?.arrayValue?.first?
                .objectValue?["index"] == .int(0)
        })
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["choices"]?.arrayValue?.first?.objectValue?["delta"]?
                .objectValue?["tool_calls"]?.arrayValue?.first?
                .objectValue?["index"] == .int(0)
        })
        XCTAssertTrue(chunks.contains {
            $0.objectValue?["usage"]?.objectValue?["prompt_tokens"] == .int(10)
        })
        // Without includeUsage there is no usage chunk.
        let noUsage = OpenAIAdapter.streamFrames(result, requestedModel: "m",
                                                 includeUsage: false)
        XCTAssertFalse(noUsage.map { String(decoding: $0, as: UTF8.self) }
            .joined().contains("\"usage\""))
    }

    func testImageDataURIAndSamplingFieldsParse() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let request = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["temperature"] = .double(0.3)
            $0["top_p"] = .double(0.9)
            $0["seed"] = .int(42)
            $0["presence_penalty"] = .double(0.5)
            $0["frequency_penalty"] = .double(-0.5)
            $0["response_format"] = .object(["type": .string("json_object")])
            $0["messages"] = .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object([
                                "url": .string("data:image/png;base64,\(png)")])]),
                    .object(["type": .string("text"), "text": .string("describe")]),
                ])]),
            ])
        }).request
        let user = request.messages[0]
        XCTAssertEqual(user.images.count, 1)
        XCTAssertEqual(user.images[0].mediaType, "image/png")
        XCTAssertEqual(user.images[0].data, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(user.parts, ["describe"])
        XCTAssertTrue(request.hasImages)
        XCTAssertEqual(request.temperature, 0.3)
        XCTAssertEqual(request.topP, 0.9)
        XCTAssertEqual(request.seed, 42)
        XCTAssertEqual(request.responseFormat, .jsonObject)
    }

    func testImageRejections() {
        let png = Data([1, 2, 3]).base64EncodedString()
        let cases: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("remote url", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object([
                                "url": .string("https://x.test/i.png")])])])])]) }),
            ("image on assistant", { $0["messages"] = .array([
                .object(["role": .string("assistant"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object([
                                "url": .string("data:image/png;base64,\(png)")])])])])]) }),
            ("non-base64 data uri", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object([
                                "url": .string("data:image/png,abc")])])])])]) }),
            ("bad media type", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object([
                                "url": .string("data:image/tiff;base64,\(png)")])])])])]) }),
            ("image detail field", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object([
                                "url": .string("data:image/png;base64,\(png)"),
                                "detail": .string("high")])])])])]) }),
        ]
        for (name, mutate) in cases {
            XCTAssertThrowsError(try OpenAIAdapter.parseChatRequest(chatBody(mutate)),
                                 "expected rejection: \(name)") { error in
                XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest, name)
            }
        }
    }

    func testUnhonoredGenerativeFieldsAreRefused() {
        for field in ["stop", "logit_bias", "logprobs", "reasoning_effort"] {
            XCTAssertThrowsError(try OpenAIAdapter.parseChatRequest(chatBody {
                $0[field] = field == "stop" ? .array([.string("x")]) : .int(1)
            }), "expected refusal: \(field)")
        }
    }

    func testResponseFormatJsonSchemaCapturedAsHint() throws {
        let request = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["response_format"] = .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string("out"),
                    "schema": .object(["type": .string("object")]),
                ]),
            ])
        }).request
        guard case .jsonSchema(let name, let schema)? = request.responseFormat else {
            return XCTFail("expected jsonSchema")
        }
        XCTAssertEqual(name, "out")
        XCTAssertEqual(schema.objectValue?["type"], .string("object"))
    }

    /// `strict: true` claims enforced decoding the platform does not have -
    /// refused outright. `strict: false` stays a guidance hint. Invalid
    /// strict/name/description types are rejected rather than dropped.
    func testResponseFormatStrictRefusal() throws {
        func schemaBody(_ inner: [String: JSONValue]) -> (inout [String: JSONValue]) -> Void {
            { $0["response_format"] = .object([
                "type": .string("json_schema"),
                "json_schema": .object(inner),
            ]) }
        }
        let refused: [(String, [String: JSONValue])] = [
            ("strict true", ["name": .string("out"), "strict": .bool(true),
                             "schema": .object(["type": .string("object")])]),
            ("strict nonboolean", ["strict": .int(1),
                                   "schema": .object(["type": .string("object")])]),
            ("name nonstring", ["name": .int(3),
                                "schema": .object(["type": .string("object")])]),
            ("description nonstring", ["description": .bool(true),
                                       "schema": .object(["type": .string("object")])]),
        ]
        for (name, inner) in refused {
            XCTAssertThrowsError(try OpenAIAdapter.parseChatRequest(chatBody(schemaBody(inner))),
                                 "expected rejection: \(name)") { error in
                XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest, name)
            }
        }
        let parsed = try OpenAIAdapter.parseChatRequest(chatBody(schemaBody([
            "name": .string("out"), "strict": .bool(false),
            "schema": .object(["type": .string("object")]),
        ]))).request
        guard case .jsonSchema(let name, _) = parsed.responseFormat else {
            return XCTFail("strict:false must remain a guidance hint")
        }
        XCTAssertEqual(name, "out")
    }

    /// A prompt containing "refresh" stays an ordinary message; nothing in
    /// validation maps it to administration.
    func testRefreshPromptIsModelRequest() throws {
        let request = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["messages"] = .array([
                .object(["role": .string("user"),
                         "content": .string("refresh")])
            ])
        }).request
        XCTAssertEqual(request.messages.first?.parts, ["refresh"])
    }

    // MARK: ML adapter

    func testMLAdapterValidation() {
        let good = #"{"model":"m","task":"t","inputs":{"x":1,"y":"s","z":true}}"#
        XCTAssertNoThrow(try MLAdapter.parseRequest(Data(good.utf8)))

        XCTAssertThrowsError(try MLAdapter.parseRequest(Data(
            #"{"model":"m","task":"t","inputs":{"x":{"nested":1}}}"#.utf8)))
        XCTAssertThrowsError(try MLAdapter.parseRequest(Data(
            #"{"model":"m","task":"t","inputs":{"x":1},"extra":2}"#.utf8)))
        XCTAssertThrowsError(try MLAdapter.parseRequest(Data(
            #"{"model":"m","task":"t"}"#.utf8)))
        let oversized = #"{"model":"m","task":"t","inputs":{"x":""#
            + String(repeating: "y", count: PlatformLimits.mlInputBytes) + #""}}"#
        XCTAssertThrowsError(try MLAdapter.parseRequest(Data(oversized.utf8))) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .payloadTooLarge)
        }
    }

    /// Parse `data: {...}\n\n` SSE frames into objects; the [DONE] sentinel
    /// is skipped. Encoding key order is never asserted.
    private static func sseObjects(_ body: String) throws -> [JSONValue] {
        var objects: [JSONValue] = []
        for frame in body.components(separatedBy: "\n\n") {
            guard frame.hasPrefix("data: ") else { continue }
            let payload = frame.dropFirst(6)
            if payload == "[DONE]" { continue }
            objects.append(try JSONValue.decode(Data(payload.utf8)))
        }
        return objects
    }
}
