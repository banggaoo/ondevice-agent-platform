import Foundation

/// Minimal JSON-RPC 2.0 message handling shared by the daemon bridge and the
/// stdio facade. IDs are integers or strings; other ID types are rejected.
public enum JSONRPC {
    public static let version = "2.0"

    public static func request(id: JSONValue, method: String, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string(version),
            "id": id,
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    public static func notification(method: String, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string(version),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    public static func result(id: JSONValue, value: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string(version),
            "id": id,
            "result": value,
        ])
    }

    public static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string(version),
            "id": id,
            "error": .object([
                "code": .int(Int64(code)),
                "message": .string(message),
            ]),
        ])
    }

    /// Validates an inbound message. Returns (id?, method, params?, isNotification).
    /// ID presence distinguishes requests from notifications.
    public static func parse(_ value: JSONValue) throws
        -> (id: JSONValue?, method: String, params: JSONValue?, isNotification: Bool) {
        guard let object = value.objectValue,
              object["jsonrpc"] == .string(version),
              let method = object["method"]?.stringValue, !method.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "not a JSON-RPC 2.0 message")
        }
        for key in object.keys where !["jsonrpc", "id", "method", "params"].contains(key) {
            throw PlatformError(.invalidRequest, detail: "unexpected field")
        }
        var id: JSONValue?
        var isNotification = true
        if let rawID = object["id"] {
            isNotification = false
            switch rawID {
            case .int, .string, .null: id = rawID
            default: throw PlatformError(.invalidRequest, detail: "invalid id type")
            }
        }
        return (id, method, object["params"], isNotification)
    }

    public static func line(for value: JSONValue) throws -> Data {
        var data = try value.encoded()
        data.append(0x0A)
        return data
    }
}
