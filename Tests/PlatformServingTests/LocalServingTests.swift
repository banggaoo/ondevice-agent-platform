import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// Local-trust CLI regression: the actual `ondevice-agent-platform` binary
/// serves and bridges ACP on a fresh root with no credential command,
/// environment, files, or Authorization header anywhere in the flow.
/// The suite only creates and removes its own subprocesses and temp root.
final class LocalServingTests: XCTestCase {

    /// Incrementally-parsed output lines for a spawned process: raw text
    /// plus any JSON-RPC values decoded per NDJSON line.
    private actor LineLog {
        private(set) var text: [String] = []
        private(set) var json: [JSONValue] = []
        private var partial = Data()
        func append(_ chunk: Data) {
            partial.append(chunk)
            while let index = partial.firstIndex(of: 0x0A) {
                let line = partial[..<index]
                partial = partial[partial.index(after: index)...]
                if let string = String(data: line, encoding: .utf8) {
                    text.append(string)
                    if let data = string.data(using: .utf8),
                       let value = try? JSONValue.decode(data) {
                        json.append(value)
                    }
                }
            }
        }
        func contains(_ needle: String) -> Bool {
            text.contains { $0.contains(needle) }
        }
        func response(id: JSONValue) -> JSONValue? {
            json.first { $0.objectValue?["id"] == id }
        }
        func notifications(_ method: String) -> [JSONValue] {
            json.filter { $0.objectValue?["method"]?.stringValue == method }
        }
    }

    /// Ordered chunk delivery: readabilityHandler fires serially, but a
    /// Task per chunk could reorder; an AsyncStream keeps arrival order.
    private func attach(_ handle: FileHandle, to log: LineLog) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { file in
            let chunk = file.availableData
            if chunk.isEmpty {
                file.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(chunk)
        }
        Task {
            for await chunk in stream { await log.append(chunk) }
        }
    }

    /// Locate the built CLI product. Never builds here: a nested
    /// `swift build` inside a running `swift test` deadlocks on the
    /// SwiftPM workspace lock, so absence fails with precise guidance.
    private func cliURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/", !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        let candidates = [
            dir.appendingPathComponent(".build/debug/ondevice-agent-platform"),
            dir.appendingPathComponent(
                ".build/arm64-apple-macosx/debug/ondevice-agent-platform"),
        ]
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw PlatformError(.internal,
                detail: "ondevice-agent-platform not built; run `swift build` first")
        }
        return found
    }

    /// Terminate our own spawned process and boundedly wait for exit so
    /// teardown never removes a temp root from under a live child or
    /// leaves an orphan. Synchronous so it is safe inside `defer`.
    private func stopAndAwait(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)   // only our own child
        }
        process.waitUntilExit()
    }

    /// The CLI surface itself: no credential command or flag anywhere in
    /// help output - local operation never asks for a token.
    func testHelpListsNoCredentialCommand() async throws {
        let process = Process()
        process.executableURL = try cliURL()
        process.arguments = ["--help"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let text = String(decoding:
            out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(text.lowercased().contains("credential"), text)
    }

    /// Full local flow on a fresh root: `serve` starts with no credential
    /// step or files, every public surface answers without Authorization,
    /// and the production `acp` facade runs a reference.status turn end to
    /// end, closing its bridge binding on stdin EOF.
    func testFreshRootServeAndACPWithoutCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oap-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let serve = Process()
        serve.executableURL = try cliURL()
        serve.arguments = ["serve", "--data-root", root.path, "--port", "0",
                           "--enable-reference-agent"]
        serve.environment = ["PATH": "/usr/bin:/bin",
                             "HOME": NSHomeDirectory()]
        let outPipe = Pipe(), errPipe = Pipe()
        serve.standardOutput = outPipe
        serve.standardError = errPipe
        let outLog = LineLog(), errLog = LineLog()
        attach(outPipe.fileHandleForReading, to: outLog)
        attach(errPipe.fileHandleForReading, to: errLog)
        try serve.run()
        // SIGTERM triggers graceful shutdown; wait for exit before the
        // deferred temp-root removal runs.
        defer { stopAndAwait(serve) }

        // Readiness is the daemon marker, not stdout: `print` to a pipe is
        // block-buffered, while writeDaemonMarker publishes the bound port
        // immediately - the same marker the production `acp` command reads.
        let markerURL = root.appendingPathComponent("daemon.json")
        func markerPort() -> UInt16? {
            guard let data = try? Data(contentsOf: markerURL),
                  let value = try? JSONValue.decode(data),
                  let raw = value.objectValue?["port"]?.intValue,
                  raw > 0, raw <= 65_535 else { return nil }
            return UInt16(raw)
        }
        var port = markerPort()
        let deadline = Date().addingTimeInterval(30)
        while port == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            port = markerPort()
        }
        guard let port else {
            let err = await errLog.text.joined(separator: "\n")
            XCTFail("serve did not become ready; stderr: \(err)")
            return
        }
        // Startup needed no credential: nothing secret-like exists on disk
        // and stderr never asked for or printed one.
        let entries = (try? FileManager.default
            .contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(entries.contains {
            $0.localizedCaseInsensitiveContains("credential")
                || $0.localizedCaseInsensitiveContains("secret")
                || $0.localizedCaseInsensitiveContains("token")
        }, "unexpected credential file in \(entries)")
        let serveErrHadCredential = await errLog.contains("credential")
        XCTAssertFalse(serveErrHadCredential)

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let http = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:\(port)")!

        // Public local surfaces answer with no Authorization header at all.
        for path in ["api/status", "api/registry", "api/jobs", "v1/models"] {
            let (_, response) = try await http.data(
                for: URLRequest(url: base.appendingPathComponent(path)))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, path)
        }
        // Fresh root: registry holds the reference agent, model list is
        // empty, and no inference job ever ran.
        let (registryData, _) = try await http.data(
            for: URLRequest(url: base.appendingPathComponent("api/registry")))
        let registry = try JSONValue.decode(registryData)
        XCTAssertEqual(registry.objectValue?["agents"],
                       .array([.string("reference.status")]))
        XCTAssertEqual(registry.objectValue?["models"], .array([]))
        let (modelsData, _) = try await http.data(
            for: URLRequest(url: base.appendingPathComponent("v1/models")))
        XCTAssertEqual(try JSONValue.decode(modelsData)
            .objectValue?["data"], .array([]))
        let (jobsData, _) = try await http.data(
            for: URLRequest(url: base.appendingPathComponent("api/jobs")))
        XCTAssertEqual(try JSONValue.decode(jobsData)
            .objectValue?["jobs"], .array([]))

        // Production ACP facade: reads only the daemon marker, needs no
        // token env, and closes its binding on stdin EOF.
        let acp = Process()
        acp.executableURL = try cliURL()
        acp.arguments = ["acp", "--agent", "reference.status",
                         "--data-root", root.path]
        acp.environment = ["PATH": "/usr/bin:/bin"]
        let inPipe = Pipe(), acpOut = Pipe(), acpErr = Pipe()
        acp.standardInput = inPipe
        acp.standardOutput = acpOut
        acp.standardError = acpErr
        let acpLog = LineLog(), acpErrLog = LineLog()
        attach(acpOut.fileHandleForReading, to: acpLog)
        attach(acpErr.fileHandleForReading, to: acpErrLog)
        try acp.run()
        defer { stopAndAwait(acp) }

        func send(_ value: JSONValue) throws {
            var data = try value.encoded()
            data.append(0x0A)
            try inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try send(JSONRPC.request(id: .int(1), method: "initialize",
            params: .object(["protocolVersion": .int(1),
                             "clientCapabilities": .object([:])])))
        guard await pollUntil(15, { await acpLog.response(id: .int(1)) != nil }) else {
            XCTFail("no initialize response")
            return
        }
        let initReply = await acpLog.response(id: .int(1))
        XCTAssertNil(initReply?.objectValue?["error"])
        XCTAssertEqual(initReply?.objectValue?["result"]?
            .objectValue?["protocolVersion"], .int(1))

        try send(JSONRPC.request(id: .int(2), method: "session/new",
            params: .object(["cwd": .string("/"),
                             "mcpServers": .array([])])))
        guard await pollUntil(15, { await acpLog.response(id: .int(2)) != nil }) else {
            XCTFail("no session/new response")
            return
        }
        let newReply = await acpLog.response(id: .int(2))
        XCTAssertNil(newReply?.objectValue?["error"])
        guard let sessionID = newReply?.objectValue?["result"]?
            .objectValue?["sessionId"]?.stringValue else {
            XCTFail("no sessionId")
            return
        }

        try send(JSONRPC.request(id: .int(3), method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object(["type": .string("text"),
                                           "text": .string("status")])]),
            ])))
        guard await pollUntil(15, { await acpLog.response(id: .int(3)) != nil }) else {
            XCTFail("no session/prompt response")
            return
        }
        let promptReply = await acpLog.response(id: .int(3))
        XCTAssertNil(promptReply?.objectValue?["error"])
        XCTAssertEqual(promptReply?.objectValue?["result"]?
            .objectValue?["stopReason"], .string("end_turn"))
        let updates = await acpLog.notifications("session/update")
        XCTAssertFalse(updates.isEmpty)
        XCTAssertTrue(updates.contains {
            $0.objectValue?["params"]?.objectValue?["update"]?
                .objectValue?["sessionUpdate"] == .string("agent_message_chunk")
        })

        // EOF on stdin: the facade posts close and exits cleanly.
        try inPipe.fileHandleForWriting.close()
        guard await pollUntil(15, { !acp.isRunning }) else {
            XCTFail("acp facade did not exit on EOF")
            return
        }
        XCTAssertEqual(acp.terminationStatus, 0)
        let stderrText = await acpErrLog.text.joined(separator: "\n")
        XCTAssertFalse(stderrText.localizedCaseInsensitiveContains("credential"),
                       stderrText)
    }
}
