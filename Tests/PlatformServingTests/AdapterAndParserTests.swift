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
        let request = try OpenAIAdapter.parseChatRequest(chatBody())
        XCTAssertEqual(request.messages.map(\.role),
                       [.system, .developer, .user, .assistant])
        XCTAssertEqual(request.messages[2].parts, ["a", "b"])
        XCTAssertEqual(request.maxOutputTokens, PlatformLimits.outputTokens)
    }

    func testRejectedOpenAIFields() {
        let cases: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("tools", { $0["tools"] = .array([]) }),
            ("tool role", { $0["messages"] = .array([
                .object(["role": .string("tool"), "content": .string("x")])]) }),
            ("image part", { $0["messages"] = .array([
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("image_url"),
                             "image_url": .object(["url": .string("x")])])])])]) }),
            ("response_format", { $0["response_format"] = .object([:]) }),
            ("stream true", { $0["stream"] = .bool(true) }),
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

    /// A prompt containing "refresh" stays an ordinary message; nothing in
    /// validation maps it to administration.
    func testRefreshPromptIsModelRequest() throws {
        let request = try OpenAIAdapter.parseChatRequest(chatBody {
            $0["messages"] = .array([
                .object(["role": .string("user"),
                         "content": .string("refresh")])
            ])
        })
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
}
