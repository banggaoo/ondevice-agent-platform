import Foundation

public enum ChatRole: String, Sendable, Codable {
    case system
    case developer
    case user
    case assistant
}

/// A decoded image attached to a message. `data` holds the decoded bytes
/// (base64 already undone at the adapter); `mediaType` is the declared
/// image MIME type. Only `user` messages may carry images.
public struct ChatImage: Sendable, Equatable {
    public let data: Data
    public let mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }
}

/// Text parts preserve order. Images attach to the message that carried
/// them (user turns only); other part types are rejected at validation,
/// never converted.
public struct ChatMessage: Sendable, Equatable {
    public let role: ChatRole
    public let parts: [String]
    public let images: [ChatImage]

    public init(role: ChatRole, parts: [String], images: [ChatImage] = []) {
        self.role = role
        self.parts = parts
        self.images = images
    }

    public var combinedText: String { parts.joined(separator: "\n") }
}

/// Requested output shape. `jsonObject`/`jsonSchema` are provider
/// guidance, not enforced decoding - the platform has no grammar
/// constraint engine, so the schema is injected as instructions and the
/// contract does not promise parseable output. Consumers needing
/// guaranteed JSON must validate downstream.
public enum ResponseFormat: Sendable, Equatable {
    case jsonObject
    case jsonSchema(name: String?, schema: JSONValue)
}

/// Validated model request. Provider receives this unmodified.
public struct ChatRequest: Sendable, Equatable {
    public let model: String
    public let messages: [ChatMessage]
    public let maxOutputTokens: Int
    /// Optional sampling hints, honored where the provider supports them.
    /// Nil means the provider default (MLX defaults to greedy).
    public let temperature: Double?
    public let topP: Double?
    public let seed: UInt64?
    public let presencePenalty: Double?
    public let frequencyPenalty: Double?
    public let responseFormat: ResponseFormat?

    public init(model: String, messages: [ChatMessage], maxOutputTokens: Int,
                temperature: Double? = nil, topP: Double? = nil,
                seed: UInt64? = nil, presencePenalty: Double? = nil,
                frequencyPenalty: Double? = nil,
                responseFormat: ResponseFormat? = nil) {
        self.model = model
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.responseFormat = responseFormat
    }

    public var hasImages: Bool { messages.contains { !$0.images.isEmpty } }
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
