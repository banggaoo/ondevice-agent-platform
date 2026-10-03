import Foundation

/// Stable error codes surfaced at every boundary. `safeMessage` is generic on
/// purpose: never echo user content, paths, SQL text, Keychain items, tokens,
/// or raw provider errors to callers.
public enum ErrorCode: String, Sendable, Codable {
    case invalidRequest = "invalid_request"
    case malformedJSON = "malformed_json"
    case unauthorized = "unauthorized"
    case forbidden = "forbidden"
    case notFound = "not_found"
    case conflict = "conflict"
    case payloadTooLarge = "payload_too_large"
    case rateLimited = "rate_limited"
    case providerUnavailable = "provider_unavailable"
    case resourceDenied = "resource_denied"
    case deadlineExceeded = "deadline_exceeded"
    case cancelled = "cancelled"
    case cancellationUnconfirmed = "cancellation_unconfirmed"
    case storageFailure = "storage_failure"
    case storageExhausted = "storage_exhausted"
    case rootUnsafe = "root_unsafe"
    case versionUnsupported = "version_unsupported"
    case sessionClosed = "session_closed"
    case capacityLimited = "capacity_limited"
    case `internal` = "internal"
}

public struct PlatformError: Error, Sendable, Equatable {
    public let code: ErrorCode
    public let safeMessage: String
    public let detail: String?

    public init(_ code: ErrorCode, detail: String? = nil) {
        self.code = code
        self.safeMessage = PlatformError.message(for: code)
        self.detail = detail
    }

    private static func message(for code: ErrorCode) -> String {
        switch code {
        case .invalidRequest: return "request is invalid or unsupported"
        case .malformedJSON: return "body is not valid JSON"
        case .unauthorized: return "authentication required or invalid"
        case .forbidden: return "operation not permitted for this principal"
        case .notFound: return "resource not found"
        case .conflict: return "operation conflicts with current state"
        case .payloadTooLarge: return "request exceeds size limits"
        case .rateLimited: return "rate limit exceeded"
        case .providerUnavailable: return "provider is unavailable or unqualified"
        case .resourceDenied: return "resource conditions deny admission"
        case .deadlineExceeded: return "operation exceeded its deadline"
        case .cancelled: return "operation was cancelled"
        case .cancellationUnconfirmed: return "cancellation could not be confirmed"
        case .storageFailure: return "durable storage operation failed"
        case .storageExhausted: return "durable storage limit reached"
        case .rootUnsafe: return "runtime root is unsafe or not owned"
        case .versionUnsupported: return "version is newer than supported"
        case .sessionClosed: return "session is closed or not loadable"
        case .capacityLimited: return "capacity limit reached"
        case .internal: return "internal error"
        }
    }
}
