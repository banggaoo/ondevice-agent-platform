import XCTest
import PlatformTestSupport
@testable import PlatformServing
@testable import PlatformCore

/// End-to-end ACP: an actual stdio fixture subprocess talking over the real
/// loopback daemon. stdout must carry only JSON-RPC lines.
final class ACPIntegrationTests: XCTestCase {

    // MARK: harness

    private actor LineLog {
        private(set) var lines: [JSONValue] = []
        var raw: [String] = []
        private var partial = Data()
        func append(_ line: String) {
            raw.append(line)
            if let data = line.data(using: .utf8),
               let value = try? JSONValue.decode(data) {
                lines.append(value)
            }
        }
        /// Arbitrary-sized pipe chunk: split on newlines, keep the tail.
        func appendChunk(_ chunk: Data) {
            partial.append(chunk)
            while let index = partial.firstIndex(of: 0x0A) {
                let line = partial[..<index]
                partial = partial[partial.index(after: index)...]
                if let text = String(data: line, encoding: .utf8) {
                    append(text)
                }
            }
        }
        func matching(id: JSONValue) -> JSONValue? {
            lines.first { $0.objectValue?["id"] == id }
        }
        func notifications(_ method: String) -> [JSONValue] {
            lines.filter {
                $0.objectValue?["method"]?.stringValue == method
            }
        }
    }

    private struct Fixture {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stderr: FileHandle
        let log = LineLog()
        var task: Task<Void, Never>?

        mutating func startReading() {
            // readabilityHandler is the same mechanism the facade uses for
            // stdin; FileHandle.bytes.lines proved unreliable under test.
            // An AsyncStream keeps chunks in strict arrival order - a Task
            // per chunk could reorder them and corrupt line boundaries.
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            stdout.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield(chunk)
            }
            task = Task { [log] in
                for await chunk in stream {
                    await log.appendChunk(chunk)
                }
            }
        }

        func send(_ value: JSONValue) throws {
            var data = try value.encoded()
            data.append(0x0A)
            try stdin.write(contentsOf: data)
        }

        func sendRaw(_ string: String) throws {
            try stdin.write(contentsOf: Data(string.utf8))
        }
    }

    private struct Daemon {
        let stack: TestStack
        let server: HTTPServer
        let port: UInt16
        func stop() { server.stop(); stack.root.releaseLock() }
    }

    private func startDaemon(enableReferenceAgent: Bool = true) async throws -> Daemon {
        let stack = try await makeStack(enableReferenceAgent: enableReferenceAgent)
        await registerStandardPrincipals(stack.supervisor)
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
        let port = try server.waitForPort()
        ref.assign(Router(supervisor: stack.supervisor, sessions: sessions,
                          acp: acp, port: port, clock: stack.clock.clock))
        return Daemon(stack: stack, server: server, port: port)
    }

    private func fixtureURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/", !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        let candidates = [
            dir.appendingPathComponent(".build/debug/acp-fixture"),
            dir.appendingPathComponent(".build/arm64-apple-macosx/debug/acp-fixture"),
        ]
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        // Build it once (test-only fixture).
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--product", "acp-fixture"]
        build.currentDirectoryURL = dir
        try build.run()
        build.waitUntilExit()
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        throw PlatformError(.internal, detail: "acp-fixture not built")
    }

    private func spawn(agent: String, daemon: Daemon) throws -> Fixture {
        let process = Process()
        process.executableURL = try fixtureURL()
        process.arguments = ["--agent", agent]
        process.environment = [
            "ACP_FIXTURE_PORT": String(daemon.port),
            "PATH": "/usr/bin:/bin",
        ]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        var fixture = Fixture(process: process,
                              stdin: inPipe.fileHandleForWriting,
                              stdout: outPipe.fileHandleForReading,
                              stderr: errPipe.fileHandleForReading)
        fixture.startReading()
        return fixture
    }

    private func waitFor(_ fixture: Fixture,
                         id: JSONValue,
                         timeout: TimeInterval = 10) async -> JSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = await fixture.log.matching(id: id) { return hit }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await fixture.log.matching(id: id)
    }

    private func rpc(_ id: Int, _ method: String,
                     _ params: [String: JSONValue]? = nil) -> JSONValue {
        JSONRPC.request(id: .int(Int64(id)), method: method,
                        params: params.map { .object($0) })
    }

    // MARK: tests

    func testInitializeNewPromptStatusFlow() async throws {
        let daemon = try await startDaemon()
        defer { daemon.stop() }
        let fixture = try spawn(agent: "reference.status", daemon: daemon)
        defer { fixture.process.terminate() }

        // v1 negotiation, accurate capabilities, no optional advertisement.
        try fixture.send(rpc(1, "initialize", ["protocolVersion": .int(1)]))
        guard let initResult = await waitFor(fixture, id: .int(1)) else {
            XCTFail("no initialize result"); return
        }
        let result = initResult.objectValue?["result"]?.objectValue
        XCTAssertEqual(result?["protocolVersion"], .int(1))
        XCTAssertEqual(result?["authMethods"], .array([]))
        XCTAssertEqual(result?["agentCapabilities"]?.objectValue?["loadSession"], .bool(false))
        XCTAssertEqual(result?["agentInfo"]?.objectValue?["name"],
                       .string("ondevice-agent-platform"))

        // A v2 request negotiates down to 1; no draft-v2 behavior.
        try fixture.send(rpc(9, "initialize", ["protocolVersion": .int(2)]))
        let v2 = await waitFor(fixture, id: .int(9))
        XCTAssertEqual(v2?.objectValue?["result"]?.objectValue?["protocolVersion"], .int(1))

        // session/new with required absolute cwd + empty mcpServers.
        try fixture.send(rpc(2, "session/new",
                             ["cwd": .string("/"), "mcpServers": .array([])]))
        guard let newResult = await waitFor(fixture, id: .int(2)),
              let sessionID = newResult.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue else {
            XCTFail("no sessionId"); return
        }

        // session/prompt "status" streams update chunks then end_turn.
        try fixture.send(rpc(3, "session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"),
                                       "text": .string("status")])]),
        ]))
        guard let promptResult = await waitFor(fixture, id: .int(3)) else {
            XCTFail("no prompt result"); return
        }
        XCTAssertEqual(promptResult.objectValue?["result"]?.objectValue?["stopReason"],
                       .string("end_turn"))
        let updates = await fixture.log.notifications("session/update")
        XCTAssertFalse(updates.isEmpty)
        XCTAssertTrue(updates.contains {
            $0.objectValue?["params"]?.objectValue?["update"]?.objectValue?["sessionUpdate"]
                == .string("agent_message_chunk")
        })

        // Non-status instruction → refusal, no side effects.
        try fixture.send(rpc(4, "session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"),
                                       "text": .string("delete everything")])]),
        ]))
        let refusal = await waitFor(fixture, id: .int(4))
        XCTAssertEqual(refusal?.objectValue?["result"]?.objectValue?["stopReason"],
                       .string("refusal"))
    }

    func testProtocolErrorsAndBounds() async throws {
        let daemon = try await startDaemon()
        defer { daemon.stop() }
        let fixture = try spawn(agent: "reference.status", daemon: daemon)
        defer { fixture.process.terminate() }
        try fixture.send(rpc(1, "initialize", ["protocolVersion": .int(1)]))
        _ = await waitFor(fixture, id: .int(1))

        // Unknown method → -32601.
        try fixture.send(rpc(2, "session/load", [:]))
        let unknown = await waitFor(fixture, id: .int(2))
        XCTAssertEqual(unknown?.objectValue?["error"]?.objectValue?["code"], .int(-32601))

        // Malformed JSON → -32700 from the facade.
        try fixture.sendRaw("{not json}\n")
        let parse = await waitFor(fixture, id: .null)
        XCTAssertEqual(parse?.objectValue?["error"]?.objectValue?["code"], .int(-32700))

        // Nonempty MCP list refused before any process semantics.
        try fixture.send(rpc(3, "session/new", [
            "cwd": .string("/"),
            "mcpServers": .array([.object([
                "name": .string("evil"),
                "command": .string("/bin/sh"),
                "args": .array([.string("-c"), .string("touch /tmp/pwned")]),
            ])]),
        ]))
        let denied = await waitFor(fixture, id: .int(3))
        XCTAssertEqual(denied?.objectValue?["error"]?.objectValue?["code"], .int(-32602))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/pwned"))

        // session/cancel is a notification: with an id it errors.
        try fixture.send(rpc(4, "session/cancel",
                             ["sessionId": .string("sess-x")]))
        let badCancel = await waitFor(fixture, id: .int(4))
        XCTAssertEqual(badCancel?.objectValue?["error"]?.objectValue?["code"], .int(-32600))

        // Oversized line is dropped; the fixture stays responsive.
        try fixture.sendRaw(String(repeating: "x",
                                   count: PlatformLimits.requestBodyBytes + 16) + "\n")
        try fixture.send(rpc(5, "initialize", [:]))
        let alive = await waitFor(fixture, id: .int(5))
        XCTAssertNotNil(alive)
    }

    func testCancelNotificationCompletesOriginalCancelled() async throws {
        let daemon = try await startDaemon()
        defer { daemon.stop() }
        // A harness that waits for cancellation.
        await daemon.stack.supervisor.agentService.register(
            profile: AgentProfile(id: "test.waiter", version: 1,
                                  harnessID: "test.closure", harnessVersion: 1,
                                  stateSchemaVersion: 1,
                                  implementationRef: "test:waiter"),
            harness: .init(make: {
                ClosureHarness { _, context, _ in
                    while !context.isCancelled() {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    return .cancelled
                }
            }, harnessID: "test.closure", harnessVersion: 1))

        let fixture = try spawn(agent: "test.waiter", daemon: daemon)
        defer { fixture.process.terminate() }
        try fixture.send(rpc(1, "initialize", [:]))
        _ = await waitFor(fixture, id: .int(1))
        try fixture.send(rpc(2, "session/new",
                             ["cwd": .string("/"), "mcpServers": .array([])]))
        guard let newResult = await waitFor(fixture, id: .int(2)),
              let sessionID = newResult.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue
        else { XCTFail("no session"); return }

        try fixture.send(rpc(3, "session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"),
                                       "text": .string("wait")])]),
        ]))
        try await Task.sleep(nanoseconds: 300_000_000)   // let the run start
        // Cancel notification: no response line for it, and the ORIGINAL
        // prompt completes with stopReason cancelled.
        try fixture.send(JSONRPC.notification(method: "session/cancel",
                                              params: .object(["sessionId": .string(sessionID)])))
        guard let promptResult = await waitFor(fixture, id: .int(3)) else {
            // availableData blocks until EOF; terminate before reading.
            fixture.process.terminate()
            let raw = await fixture.log.raw
            let err = String(data: fixture.stderr.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("no cancelled result; lines=\(raw) stderr=\(err)"); return
        }
        XCTAssertEqual(promptResult.objectValue?["result"]?.objectValue?["stopReason"],
                       .string("cancelled"))
        // The session survives cancellation.
        try fixture.send(rpc(4, "session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"),
                                       "text": .string("again")])]),
        ]))
        let again = await waitFor(fixture, id: .int(4))
        XCTAssertNil(again?.objectValue?["error"])
    }

    func testCrossConnectionSessionDenied() async throws {
        let daemon = try await startDaemon()
        defer { daemon.stop() }
        let first = try spawn(agent: "reference.status", daemon: daemon)
        let second = try spawn(agent: "reference.status", daemon: daemon)
        defer { first.process.terminate(); second.process.terminate() }

        try first.send(rpc(1, "initialize", [:]))
        _ = await waitFor(first, id: .int(1))
        try first.send(rpc(2, "session/new",
                           ["cwd": .string("/"), "mcpServers": .array([])]))
        guard let newResult = await waitFor(first, id: .int(2)),
              let sessionID = newResult.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue
        else {
            let running = first.process.isRunning
            first.process.terminate()
            let raw = await first.log.raw
            let err = String(data: first.stderr.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("no session; running=\(running) fixture lines: \(raw) stderr: \(err)")
            return
        }

        try second.send(rpc(1, "initialize", [:]))
        _ = await waitFor(second, id: .int(1))
        // Second connection cannot prompt the first's session.
        try second.send(rpc(2, "session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"),
                                       "text": .string("status")])]),
        ]))
        let denied = await waitFor(second, id: .int(2))
        XCTAssertNotNil(denied?.objectValue?["error"])
    }

    func testEOFDisconnectCancelsWork() async throws {
        let daemon = try await startDaemon()
        defer { daemon.stop() }
        await daemon.stack.supervisor.agentService.register(
            profile: AgentProfile(id: "test.waiter", version: 1,
                                  harnessID: "test.closure", harnessVersion: 1,
                                  stateSchemaVersion: 1,
                                  implementationRef: "test:waiter"),
            harness: .init(make: {
                ClosureHarness { _, context, _ in
                    while !context.isCancelled() {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    return .cancelled
                }
            }, harnessID: "test.closure", harnessVersion: 1))

        let fixture = try spawn(agent: "test.waiter", daemon: daemon)
        try fixture.send(rpc(1, "initialize", [:]))
        _ = await waitFor(fixture, id: .int(1))
        try fixture.send(rpc(2, "session/new",
                             ["cwd": .string("/"), "mcpServers": .array([])]))
        _ = await waitFor(fixture, id: .int(2))
        try fixture.send(rpc(3, "session/prompt", [
            "sessionId": .string("sess-1"),
            "prompt": .array([.object(["type": .string("text"),
                                       "text": .string("wait")])]),
        ]))
        try await Task.sleep(nanoseconds: 300_000_000)

        // EOF: the facade posts close, exits, and owned sessions are closed.
        try fixture.stdin.close()
        let exited = await pollUntil { !fixture.process.isRunning }
        XCTAssertTrue(exited, "fixture should exit on EOF")
    }

    /// A harness child model call goes through identical validation/admission
    /// and the session itself never holds an inference slot.
    func testChildModelClientSharesAdmission() async throws {
        let daemon = try await startDaemon()
        defer { daemon.stop() }
        let provider = FakeLLMProvider(content: "child-ok", autoFinish: true)
        await daemon.stack.supervisor.registerModel(
            ModelProfile(alias: "test-llm", providerID: "fake-llm",
                         kind: .llm, task: "chat"), provider: provider)
        await daemon.stack.supervisor.agentService.register(
            profile: AgentProfile(id: "test.modeluser", version: 1,
                                  harnessID: "test.closure", harnessVersion: 1,
                                  stateSchemaVersion: 1,
                                  implementationRef: "test:modeluser"),
            harness: .init(make: {
                ClosureHarness { _, context, emit in
                    do {
                        let result = try await context.model.complete(
                            ChatRequest(model: "test-llm",
                                        messages: [ChatMessage(role: .user,
                                                               parts: ["hi"])],
                                        maxOutputTokens: 8))
                        emit(.messageChunk(result.content))
                        return .endTurn
                    } catch {
                        return .error
                    }
                }
            }, harnessID: "test.closure", harnessVersion: 1))

        let fixture = try spawn(agent: "test.modeluser", daemon: daemon)
        defer { fixture.process.terminate() }
        try fixture.send(rpc(1, "initialize", [:]))
        _ = await waitFor(fixture, id: .int(1))
        try fixture.send(rpc(2, "session/new",
                             ["cwd": .string("/"), "mcpServers": .array([])]))
        guard let newResult = await waitFor(fixture, id: .int(2)),
              let sessionID = newResult.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue
        else { XCTFail("no session"); return }
        try fixture.send(rpc(3, "session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"),
                                       "text": .string("go")])]),
        ]))
        let promptResult = await waitFor(fixture, id: .int(3))
        XCTAssertEqual(promptResult?.objectValue?["result"]?.objectValue?["stopReason"],
                       .string("end_turn"))
        // The child used real admission through the same provider.
        XCTAssertEqual(provider.invocations.count, 1)
        // Slot released after the run; no session-held inference.
        let snap = await daemon.stack.supervisor.admissionSnapshot()
        XCTAssertEqual(snap.active, 0)
        XCTAssertEqual(snap.pending, 0)
    }
}
