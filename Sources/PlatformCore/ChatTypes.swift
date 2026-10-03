import Foundation

public enum ChatRole: String, Sendable, Codable {
    case system
    case developer
    case user
    case assistant
}

/// Text content only in M1. Parts preserve order; images and other part types
/// are rejected at validation, never converted.
public struct ChatMessage: Sendable, Equatable {
    public let role: ChatRole
    public let parts: [String]

    public init(role: ChatRole, parts: [String]) {
        self.role = role
        self.parts = parts
    }

    public var combinedText: String { parts.joined(separator: "\n") }
}

/// Validated model request. Provider receives this unmodified.
public struct ChatRequest: Sendable, Equatable {
    public let model: String
    public let messages: [ChatMessage]
    public let maxOutputTokens: Int

    public init(model: String, messages: [ChatMessage], maxOutputTokens: Int) {
        self.model = model
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ChatUsage: Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public enum FinishReason: String, Sendable {
    case stop
    case length
    case contentFilter = "content_filter"
    case error
}

/// Provider truth. Usage is populated only when the provider measured it.
public struct ChatResult: Sendable {
    public let modelIdentity: String
    public let content: String
    public let finishReason: FinishReason
    public let usage: ChatUsage?

    public init(modelIdentity: String, content: String, finishReason: FinishReason,
                usage: ChatUsage? = nil) {
        self.modelIdentity = modelIdentity
        self.content = content
        self.finishReason = finishReason
        self.usage = usage
    }
}
