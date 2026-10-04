import XCTest
import Foundation
import PlatformTestSupport
@testable import PlatformMLX
@testable import PlatformCore
@testable import PlatformServing

/// Live ACP-wire qualification of the opt-in runtime Operator: a real
/// loopback HTTPServer + Router + shared ACPService and the private
/// `/_bridge/acp` NDJSON transport drive
/// initialize -> session/new -> session/prompt against a real pulled Qwen
/// artifact. This qualifies the protocol path end to end under injected
/// healthy resources - it is controlled-wire evidence, NOT native-daemon
/// admission proof, and draws no quality or performance conclusions. Runs
/// only when OAP_LIVE_OPERATOR=1 and OAP_LIVE_MLX_STORE points at an
/// already-pulled models dir; it never downloads and skips truthfully on a
/// missing artifact.
final class OperatorWireLiveTests: XCTestCase {

    /// Lock-confined late binding for the router (bound port known after listen).
    private final class RouterRef: @unchecked Sendable {
        private let lock = NSLock()
        private var _router: Router?
        var router: Router? { lock.lock(); defer { lock.unlock() }; return _router }
        func assign(_ r: Router) { lock.lock(); _router = r; lock.unlock() }
    }

    /// Decode every NDJSON line of a bridge response body.
    private static func frames(_ data: Data) -> [JSONValue] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONValue.decode(Data($0.utf8)) }
    }

    private static func post(_ http: URLSession, base: URL,
                             wrapper: JSONValue) async throws -> [JSONValue] {
        var request = URLRequest(url: base.appendingPathComponent("_bridge/acp"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try wrapper.encoded()
        let (data, response) = try await http.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        return frames(data)
    }

    private static func response(id: String, in frames: [JSONValue]) -> JSONValue? {
        frames.first { $0.objectValue?["id"] == .string(id) }
    }

    func testLiveOperatorACPNdjsonWire() async throws {
        guard ProcessInfo.processInfo.environment["OAP_LIVE_OPERATOR"] == "1" else {
            throw XCTSkip("set OAP_LIVE_OPERATOR=1 to run the live wire test")
        }
        guard let dir = ProcessInfo.processInfo.environment["OAP_LIVE_MLX_STORE"]
        else {
            throw XCTSkip("set OAP_LIVE_MLX_STORE to a pulled models dir")
        }
        let store = ModelStore(modelsDir: URL(fileURLWithPath: dir))
        let source = ModelSource(repo: "nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
                                 revision: "e827c31fbd588828f43180a87ab34415a6d8a4bf")
        guard store.isReady(source: source) else {
            throw XCTSkip("artifact not pulled: \(source.repo)@\(source.revision)")
        }
        let stack = try await makeStack()   // injected healthy resources
        defer { stack.root.releaseLock() }
        await registerStandardPrincipals(stack.supervisor)
        let provider = MLXProvider(store: store)
        await stack.supervisor.registerModel(
            ModelProfile(alias: "qwen3.8-9b", providerID: MLXProviderContract.id,
                         kind: .llm, task: "chat", maxOutputTokens: 4096,
                         source: source),
            provider: provider)
        try await stack.supervisor.registerRuntimeOperator(modelAlias: "qwen3.8-9b")

        // Real loopback server with the shared ACP service.
        let sessions = ConsoleSessions(clock: stack.clock.clock)
        let acp = ACPService(supervisor: stack.supervisor, clock: stack.clock.clock)
        let ref = RouterRef()
        let server = HTTPServer { request, respond in
            guard let router = ref.router else {
                respond(.error(PlatformError(.internal), status: 500))
                return
            }
            Task { await router.handle(request, respond: respond) }
        }
        try server.start(port: 0)
        defer { server.stop() }
        let port = try server.waitForPort()
        let router = Router(supervisor: stack.supervisor, sessions: sessions,
                            acp: acp, port: port, clock: stack.clock.clock)
        ref.assign(router)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 150
        let http = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let connID = "live-wire-\(UUID().uuidString)"

        var transcript: [String: [JSONValue]] = [:]

        // initialize
        transcript["initialize"] = try await Self.post(http, base: base,
            wrapper: .object([
                "connectionId": .string(connID),
                "agentId": .string("operator"),
                "message": JSONRPC.request(
                    id: .string("w-init"), method: "initialize",
                    params: .object([
                        "protocolVersion": .int(1),
                        "clientCapabilities": .object([:]),
                    ])),
            ]))
        let initReply = Self.response(id: "w-init", in: transcript["initialize"] ?? [])
        XCTAssertNil(initReply?.objectValue?["error"])
        XCTAssertEqual(initReply?.objectValue?["result"]?
            .objectValue?["protocolVersion"], .int(1))

        // session/new
        transcript["sessionNew"] = try await Self.post(http, base: base,
            wrapper: .object([
                "connectionId": .string(connID),
                "message": JSONRPC.request(
                    id: .string("w-new"), method: "session/new",
                    params: .object([
                        "cwd": .string("/"),
                        "mcpServers": .array([]),
                    ])),
            ]))
        let newReply = Self.response(id: "w-new", in: transcript["sessionNew"] ?? [])
        XCTAssertNil(newReply?.objectValue?["error"])
        guard let sessionID = newReply?.objectValue?["result"]?
            .objectValue?["sessionId"]?.stringValue else {
            XCTFail("no sessionId in session/new result")
            return
        }

        // session/prompt - the exact operator question, nothing else.
        transcript["prompt"] = try await Self.post(http, base: base,
            wrapper: .object([
                "connectionId": .string(connID),
                "message": JSONRPC.request(
                    id: .string("w-prompt"), method: "session/prompt",
                    params: .object([
                        "sessionId": .string(sessionID),
                        "prompt": .array([.object([
                            "type": .string("text"),
                            "text": .string("Explain runtime status."),
                        ])]),
                    ])),
            ]))
        let promptFrames = transcript["prompt"] ?? []
        let updates = promptFrames.filter {
            $0.objectValue?["method"]?.stringValue == "session/update"
        }
        let texts = updates.compactMap {
            $0.objectValue?["params"]?.objectValue?["update"]?
                .objectValue?["content"]?.objectValue?["text"]?.stringValue
        }
        let joined = texts.joined()
        XCTAssertFalse(joined.trimmingCharacters(in: .whitespaces).isEmpty,
                       "no agent_message_chunk text on the wire")
        XCTAssertFalse(joined.hasPrefix("Operator unavailable"),
                       "operator surfaced an availability error")
        let promptReply = Self.response(id: "w-prompt", in: promptFrames)
        XCTAssertNil(promptReply?.objectValue?["error"])
        let stopReason = promptReply?.objectValue?["result"]?
            .objectValue?["stopReason"]?.stringValue
        XCTAssertTrue(stopReason == "end_turn" || stopReason == "max_tokens",
                      "unexpected stopReason \(stopReason ?? "nil")")

        // Truthful counters: exactly one LLM job, no ML, recorded with the
        // run as parent.
        let counters = await stack.supervisor.counters()
        XCTAssertEqual(counters.llm, 1)
        XCTAssertEqual(counters.ml, 0)
        let jobs = try await stack.supervisor.listJobs()
        let children = jobs.filter { $0.parentID != nil && $0.state == .completed }
        XCTAssertEqual(children.count, 1)

        // Persist the decoded wire transcript for review.
        if let out = ProcessInfo.processInfo.environment["OAP_LIVE_WIRE_LOG"] {
            let record: JSONValue = .object([
                "initialize": .array(transcript["initialize"] ?? []),
                "sessionNew": .array(transcript["sessionNew"] ?? []),
                "prompt": .array(promptFrames),
                "counters": .object(["llm": .int(Int64(counters.llm)),
                                     "ml": .int(Int64(counters.ml))]),
                "jobs": .array(children.map { .object([
                    "id": .string($0.id), "kind": .string($0.kind.rawValue),
                    "state": .string($0.state.rawValue),
                    "parentId": .string($0.parentID ?? "")]) }),
            ])
            try? record.encoded().write(to: URL(fileURLWithPath: out),
                                        options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: URL(fileURLWithPath: out).path)
        }

        // Close the bound connection.
        _ = try await Self.post(http, base: base,
            wrapper: .object(["connectionId": .string(connID),
                              "close": .bool(true)]))
    }
}
