import Foundation
import PlatformCore

/// Client side of the private ACP bridge: forwards newline-delimited JSON-RPC
/// between stdin/stdout and a running daemon's `/_bridge/acp` endpoint. The
/// bridge POST wraps each message as `{connectionId, agentId?, message}` and
/// streams that message's NDJSON updates and result back, which are written
/// to stdout unchanged. Diagnostics go to stderr only; stdout carries only
/// protocol lines. The local-trust bridge takes no credential; used by the
/// production `acp` command and by the test fixture.
public struct ACPStdioFacade: Sendable {
    public init() {}

    /// Runs the facade until stdin reaches EOF, then closes owned sessions on
    /// the bridge and returns.
    public func run(agentID: String, bridgeURL: URL) async -> Never {
        let connectionID = "facade-\(UUID().uuidString)"
        let stdout = Stdout()
        let session = URLSession(configuration: .ephemeral)
        let finished = ContinuationBox()
        let slots = SemaphoreBox(value: PlatformLimits.agentConnections)
        let pending = PendingLines()

        let stdin = FileHandle.standardInput
        stdin.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                stdin.readabilityHandler = nil
                Task {
                    try? await Self.postClose(url: bridgeURL,
                                              connectionID: connectionID, session: session)
                    try? await Task.sleep(for: .milliseconds(100))
                    finished.resume()
                }
                return
            }
            for line in pending.append(chunk) {
                guard line.count <= PlatformLimits.requestBodyBytes else { continue }
                Task {
                    await slots.wait()
                    defer { Task { await slots.signal() } }
                    do {
                        guard let message = try? JSONValue.decode(line) else {
                            let err = JSONRPC.error(id: .null, code: -32700, message: "parse error")
                            try await stdout.write(JSONRPC.line(for: err))
                            return
                        }
                        try await Self.forward(message: message, agentID: agentID,
                                               connectionID: connectionID, url: bridgeURL,
                                               session: session, stdout: stdout)
                    } catch {
                        let err = JSONRPC.error(id: .null, code: -32603,
                                                message: "bridge unreachable")
                        try? await stdout.write(JSONRPC.line(for: err))
                    }
                }
            }
        }

        await finished.wait()
        exit(0)
    }

    static func forward(message: JSONValue, agentID: String,
                        connectionID: String, url: URL,
                        session: URLSession, stdout: Stdout) async throws {
        let wrapper = JSONValue.object([
            "connectionId": .string(connectionID),
            "agentId": .string(agentID),
            "message": message,
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try wrapper.encoded()
        request.timeoutInterval = PlatformLimits.agentDeadlineSeconds + 30
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let err = JSONRPC.error(id: .null, code: -32603, message: "bridge error")
            try await stdout.write(JSONRPC.line(for: err))
            return
        }
        for try await line in bytes.lines {
            if let data = line.data(using: .utf8), !line.isEmpty {
                await stdout.write(data + Data([0x0A]))
            }
        }
    }

    static func postClose(url: URL,
                          connectionID: String, session: URLSession) async throws {
        let wrapper = JSONValue.object([
            "connectionId": .string(connectionID),
            "close": .bool(true),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try wrapper.encoded()
        let (_, response) = try await session.data(for: request)
        _ = response
    }

    /// Serialized stdout writer: only protocol lines ever pass through.
    public actor Stdout {
        public init() {}
        func write(_ data: Data) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/// Lock-confined buffer for stdin line assembly on the readability queue.
/// `scanned` is the first byte not yet checked for a newline, so repeated
/// appends never rescan earlier data. A partial line already over
/// `requestBodyBytes` can never satisfy the per-line guard, so the pending
/// bytes are dropped instead of growing without bound.
final class PendingLines: @unchecked Sendable {
    private var buffer = Data()
    private var scanned: Data.Index
    private let lock = NSLock()

    init() {
        scanned = buffer.startIndex
    }

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [Data] = []
        while let index = buffer[scanned...].firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<index]))
            buffer = Data(buffer[buffer.index(after: index)...])
            scanned = buffer.startIndex
        }
        scanned = buffer.endIndex
        if buffer.count > PlatformLimits.requestBodyBytes {
            buffer.removeAll(keepingCapacity: false)
            scanned = buffer.startIndex
        }
        return lines
    }
}

/// Single-shot resumable wait for the EOF/close handshake.
final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if resumed { cont.resume() } else { continuation = cont }
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        resumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// Counting semaphore for bounded concurrent bridge posts.
actor SemaphoreBox {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(value: Int) { count = value }
    func wait() async {
        if count > 0 { count -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            count += 1
        }
    }
}
