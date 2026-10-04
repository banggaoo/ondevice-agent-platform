import Foundation
import Network
import PlatformCore

/// Loopback-only HTTP/1.1 server on Network.framework. One request per
/// connection; connection and read limits apply before authentication.
/// Lock-confined shared state is documented per property; the handler is
/// invoked off the connection queue.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    private let queue = DispatchQueue(label: "platform.http")
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var connectionMap: [ObjectIdentifier: NWConnection] = [:]
    private var peerCloseCallbacks: [ObjectIdentifier: @Sendable () -> Void] = [:]
    /// Request-scoped cancellation tokens: stored when a request is handed
    /// to the router and cancelled when its connection drops.
    private var requestTokens: [ObjectIdentifier: CancellationToken] = [:]
    /// Read-idle deadline state: `readGeneration` bumps on every receive so a
    /// stale timer can't kill a connection that just got bytes; `responding`
    /// marks connections handed to the router so the timer never murders an
    /// in-flight response or an open stream.
    private var readGeneration: [ObjectIdentifier: Int] = [:]
    private var responding: Set<ObjectIdentifier> = []
    private let lock = NSLock()
    private let handler: Handler
    private var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    public private(set) var boundPort: UInt16 = 0

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        )
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let self, let port = listener?.port {
                self.boundPort = port.rawValue
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let conns = connectionMap.values
        let tokens = requestTokens.values
        connectionMap.removeAll()
        connections.removeAll()
        requestTokens.removeAll()
        lock.unlock()
        for token in tokens { token.cancel() }
        for c in conns { c.cancel() }
        listener?.cancel()
        listener = nil
    }

    /// Waits (bounded) until the listener reports a bound port.
    public func waitForPort(timeout: TimeInterval = 5) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if boundPort != 0 { return boundPort }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw PlatformError(.internal, detail: "listener not ready")
    }

    private func accept(_ connection: NWConnection) {
        guard connectionCount < PlatformLimits.connections else {
            connection.cancel()
            return
        }
        // Defense in depth: local-only accept plus loopback remote check.
        if case .hostPort(let host, _) = connection.endpoint,
           host != .ipv4(.loopback) && host != .ipv6(.loopback) && host != .name("localhost", nil) {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        lock.lock()
        connections.insert(id)
        connectionMap[id] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.drop(id, matching: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        read(connection: connection, buffer: Data())
    }

    /// Removes and cancels a connection. `matching` must be the instance that
    /// produced this teardown: NWConnection objects are recycled quickly, so
    /// an ObjectIdentifier can be reused by a newer live connection before a
    /// delayed close fires; comparing instances prevents killing the wrong
    /// connection.
    private func drop(_ id: ObjectIdentifier, matching match: NWConnection? = nil) {
        lock.lock()
        if let match, let mapped = connectionMap[id], mapped !== match {
            lock.unlock()
            return
        }
        connections.remove(id)
        let conn = connectionMap.removeValue(forKey: id)
        let onClose = peerCloseCallbacks.removeValue(forKey: id)
        let token = requestTokens.removeValue(forKey: id)
        readGeneration.removeValue(forKey: id)
        responding.remove(id)
        lock.unlock()
        token?.cancel()
        onClose?()
        (match ?? conn)?.cancel()
    }

    private func read(connection: NWConnection, buffer: Data) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        let generation = (readGeneration[id] ?? 0) + 1
        readGeneration[id] = generation
        lock.unlock()
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: PlatformLimits.requestBodyBytes + PlatformLimits.requestHeaderBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || isComplete {
                self.drop(id, matching: connection)
                return
            }
            do {
                if let (request, _) = try HTTPParser.parse(buffer) {
                    lock.lock()
                    self.responding.insert(id)
                    self.requestTokens[id] = request.cancellation
                    lock.unlock()
                    // Watch the peer while the handler runs: one request
                    // per connection, so a received byte is a pipelining
                    // violation and EOF or error means the client is gone.
                    // Either way the request's cancellation token fires.
                    connection.receive(minimumIncompleteLength: 1,
                                       maximumLength: 1) { [weak self] _, _, _, _ in
                        self?.drop(id, matching: connection)
                    }
                    self.handler(request) { [weak self] response in
                        guard let self else { return }
                        self.queue.async { [self] in
                            if let stream = response.stream {
                                connection.send(content: response.serialize(),
                                                completion: .contentProcessed { _ in })
                                let sender = StreamSender(
                                    send: { chunk in
                                        // Suspend until the connection
                                        // processed this chunk; close then
                                        // cannot cancel unsent data.
                                        var framed = Data(String(chunk.count, radix: 16).utf8)
                                        framed.append(Data("\r\n".utf8))
                                        framed.append(chunk)
                                        framed.append(Data("\r\n".utf8))
                                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                            connection.send(content: framed,
                                                            completion: .contentProcessed { _ in
                                                cont.resume()
                                            })
                                        }
                                    },
                                    close: { [weak self] in
                                        // Graceful close: an empty final
                                        // frame flushes queued chunks, then
                                        // the connection drops after a grace
                                        // interval. Cancelling immediately
                                        // after queueing RSTs the socket and
                                        // can discard body bytes the peer has
                                        // not consumed yet.
                                        connection.send(content: Data("0\r\n\r\n".utf8),
                                                        contentContext: .finalMessage,
                                                        isComplete: true,
                                                        completion: .contentProcessed { [weak self] _ in
                                            guard let self else { return }
                                            self.queue.asyncAfter(
                                                deadline: .now() + 0.25) { [weak self] in
                                                guard let self else { return }
                                                self.drop(id, matching: connection)
                                            }
                                        })
                                    },
                                    onPeerClose: { [weak self] cb in
                                        self?.lock.lock()
                                        self?.peerCloseCallbacks[id] = cb
                                        self?.lock.unlock()
                                    }
                                )
                                stream(sender)
                            } else {
                                connection.send(content: response.serialize(),
                                                completion: .contentProcessed { [weak self] _ in
                                    self?.drop(id, matching: connection)
                                })
                            }
                        }
                    }
                    return
                }
            } catch {
                let status = (error as? HTTPParseError) == .tooLarge ? 413 : 400
                let response = HTTPResponse(
                    status: status, reason: HTTPResponse.reason(for: status),
                    headers: [("Connection", "close")])
                connection.send(content: response.serialize(),
                                completion: .contentProcessed { [weak self] _ in
                    self?.drop(id, matching: connection)
                })
                return
            }
            if buffer.count > PlatformLimits.requestHeaderBytes + PlatformLimits.requestBodyBytes {
                self.drop(id, matching: connection)
                return
            }
            self.read(connection: connection, buffer: buffer)
        }
        // Idle-read deadline: fires only if no further bytes arrived (stale
        // generation) and the request was never handed to the router. Live
        // responses and streams are never killed by this timer.
        queue.asyncAfter(deadline: .now() + PlatformLimits.connectionReadSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillIdle = self.readGeneration[id] == generation
                && !self.responding.contains(id)
            self.lock.unlock()
            if stillIdle { self.drop(id, matching: connection) }
        }
    }
}
