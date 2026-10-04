import Foundation
import PlatformCore

/// One HTTP/1.1 request per connection. Strict, bounded framing: duplicate or
/// conflicting lengths, transfer-encoding, absolute-form targets, pipelined
/// bytes, and unsupported Expect are refused before auth ever runs.
public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String          // origin-form path + query
    public let version: String
    public let headers: [(String, String)]
    public let body: Data
    /// Client-lifetime token: the server cancels it when the connection
    /// dies, so queued or in-flight model/ML work stops rather than
    /// completing for a peer that is gone.
    public let cancellation: CancellationToken

    public init(method: String, target: String, version: String,
                headers: [(String, String)], body: Data,
                cancellation: CancellationToken = CancellationToken()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
        self.cancellation = cancellation
    }

    public func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.0.lowercased() == lowered }?.1
    }

    public var path: String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    public var query: [String: String] {
        guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            out[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }
        return out
    }
}

public enum HTTPParseError: Error {
    case malformed
    case unsupportedFraming
    case tooLarge
    case incomplete
    case closing
}

public enum HTTPParser {
    /// Parses one complete request or throws; returns nil while incomplete.
    /// Consumed bytes are reported so the connection can verify no trailing
    /// pipelined data remains.
    public static func parse(_ buffer: Data) throws -> (request: HTTPRequest, consumed: Int)? {
        guard let headerEnd = buffer.range(of: Data([13, 10, 13, 10])) else {
            if buffer.count > PlatformLimits.requestHeaderBytes { throw HTTPParseError.tooLarge }
            // Bare LF is not a valid line ending for this server.
            var i = buffer.startIndex
            while i < buffer.endIndex {
                if buffer[i] == 0x0A {
                    let prev = i > buffer.startIndex ? buffer[i - 1] : 0
                    if prev != 0x0D { throw HTTPParseError.malformed }
                }
                i += 1
            }
            return nil
        }
        let headerBytes = buffer[..<headerEnd.lowerBound]
        if headerBytes.count > PlatformLimits.requestHeaderBytes { throw HTTPParseError.tooLarge }
        guard let headerText = String(data: headerBytes, encoding: .utf8),
              headerText.utf8.allSatisfy({ $0 >= 0x20 || $0 == 0x0D || $0 == 0x0A || $0 == 0x09 }) else {
            throw HTTPParseError.malformed
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.malformed }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw HTTPParseError.malformed }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw HTTPParseError.malformed }
        guard !method.isEmpty, method.allSatisfy({ !$0.isWhitespace }) else {
            throw HTTPParseError.malformed
        }
        // Origin-form only: refuse absolute-form and authority-form targets.
        guard target.hasPrefix("/") else { throw HTTPParseError.unsupportedFraming }

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformed }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.allSatisfy({ !$0.isWhitespace }) else {
                throw HTTPParseError.malformed
            }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append((name, value))
        }

        // Framing validation.
        let hostValues = headers.filter { $0.0.lowercased() == "host" }
        if version == "HTTP/1.1" && hostValues.count != 1 { throw HTTPParseError.malformed }
        if hostValues.count > 1 { throw HTTPParseError.malformed }
        if headers.contains(where: { $0.0.lowercased() == "transfer-encoding" }) {
            throw HTTPParseError.unsupportedFraming
        }
        if let expect = headers.first(where: { $0.0.lowercased() == "expect" })?.1.lowercased(),
           !expect.isEmpty {
            throw HTTPParseError.unsupportedFraming
        }
        let lengths = headers.filter { $0.0.lowercased() == "content-length" }
        var contentLength = 0
        if !lengths.isEmpty {
            let unique = Set(lengths.map(\.1))
            guard unique.count == 1, let raw = unique.first,
                  let n = Int(raw), n >= 0, n <= PlatformLimits.requestBodyBytes else {
                throw HTTPParseError.unsupportedFraming
            }
            contentLength = n
        }
        let bodyStart = headerEnd.upperBound
        let total = bodyStart + contentLength
        if buffer.count < total { return nil }
        if buffer.count > total { throw HTTPParseError.closing }   // pipelined bytes
        let body = buffer[bodyStart..<total]
        return (HTTPRequest(method: method, target: target, version: version,
                            headers: headers, body: Data(body)), total)
    }
}

/// Sender handed to a streaming response producer. `send` writes raw body
/// bytes and completes only after the connection processed them, so a
/// following `close` can never discard queued data (connection-close
/// delimits the body; used for SSE/NDJSON only); `close` ends the response;
/// `onPeerClose` fires when the client disconnects.
public struct StreamSender: Sendable {
    public let send: @Sendable (Data) async -> Void
    public let close: @Sendable () -> Void
    public let onPeerClose: @Sendable (@escaping @Sendable () -> Void) -> Void
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let reason: String
    public var headers: [(String, String)]
    public var body: Data
    /// When set, the response streams body chunks until closed.
    public var stream: (@Sendable (StreamSender) -> Void)?

    public init(status: Int, reason: String,
                headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        let data = (try? value.encoded()) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: reason, headers: [
            ("Content-Type", "application/json"),
            ("Cache-Control", "no-store"),
        ], body: data)
    }

    public static func error(_ error: PlatformError, status: Int) -> HTTPResponse {
        .json(.object([
            "error": .object([
                "code": .string(error.code.rawValue),
                "message": .string(error.safeMessage),
            ]),
        ]), status: status, reason: reason(for: status))
    }

    public static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"; case 201: return "Created"
        case 400: return "Bad Request"; case 401: return "Unauthorized"
        case 403: return "Forbidden"; case 404: return "Not Found"
        case 405: return "Method Not Allowed"; case 409: return "Conflict"
        case 413: return "Payload Too Large"; case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"; case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }

    public func serialize() -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if stream == nil {
            text += "Content-Length: \(body.count)\r\n"
        } else {
            // Streams use chunked so the message boundary never depends on
            // connection-close timing (used for SSE/NDJSON only).
            text += "Transfer-Encoding: chunked\r\n"
        }
        text += "Connection: close\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
