import Foundation

public enum ChatRole: String, Sendable, Codable {
    case system
    case developer
    case user
    case assistant
    /// A tool result turn: the client's reply to an assistant tool call.
    /// Model output never executes; the caller owns actual tool execution.
    case tool
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

/// One assistant function invocation, in either direction: carried on an
/// assistant message in request history, or produced by a provider on a
/// result. `id` correlates with the `tool_call_id` of a later tool message;
/// providers that do not emit ids get deterministic `call_<n>` ids at the
/// adapter. A tool call is a model suggestion, never an execution.
public struct ChatToolCall: Sendable, Equatable {
    public let id: String?
    public let name: String
    /// Decoded argument value (normally an object). The wire shape is a
    /// JSON *string* per OpenAI; the adapter decodes on the way in and
    /// re-encodes on the way out.
    public let arguments: JSONValue

    public init(id: String? = nil, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One offered tool: name, optional description, and the caller-supplied
/// JSON schema object. The platform stores the schema verbatim; only
/// providers with a tool-capable template consume it.
public struct ChatToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let parameters: JSONValue?

    public init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Client tool-use directive. `named`/`required` are honored where the
/// provider supports steering; the MLX route injects them as guidance text -
/// a hint, not a constraint engine.
public enum ToolChoice: Sendable, Equatable {
    case auto
    case none
    case required
    case named(String)
}

/// Text parts preserve order. Images attach to the message that carried
/// them (user turns only); other part types are rejected at validation,
/// never converted. Assistant turns may carry tool calls instead of (or in
/// addition to) text; tool turns carry the tool_call_id they answer.
public struct ChatMessage: Sendable, Equatable {
    public let role: ChatRole
    public let parts: [String]
    public let images: [ChatImage]
    public let toolCalls: [ChatToolCall]
    public let toolCallID: String?

    public init(role: ChatRole, parts: [String], images: [ChatImage] = [],
                toolCalls: [ChatToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.parts = parts
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
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

    public func guidance() throws -> String {
        switch self {
        case .jsonObject:
            return "Respond with a single valid JSON object and no other text."
        case .jsonSchema(let name, let schema):
            guard schema.objectValue != nil else {
                throw PlatformError(.invalidRequest, detail: "JSON schema must be an object")
            }
            let rendered = String(decoding: try schema.encoded(), as: UTF8.self)
            let label = name.map { " named \"\($0)\"" } ?? ""
            return "Respond with a single valid JSON object\(label) matching this JSON schema and no other text: \(rendered)"
        }
    }
}

/// Validated model request. Provider receives this unmodified.
public struct ChatRequest: Sendable, Equatable {
    public let model: String
    public let messages: [ChatMessage]
    public let maxOutputTokens: Int
    public let hasExplicitOutputLimit: Bool
    /// Optional sampling hints, honored where the provider supports them.
    /// Nil means the provider default (MLX defaults to greedy).
    public let temperature: Double?
    public let topP: Double?
    public let seed: UInt64?
    public let presencePenalty: Double?
    public let frequencyPenalty: Double?
    public let responseFormat: ResponseFormat?
    /// Client-declared tools, offered to providers that support tool
    /// templates. Execution stays with the caller; the platform only renders
    /// schemas into the prompt and parses model tool calls back out.
    public let tools: [ChatToolSpec]
    public let toolChoice: ToolChoice

    public init(model: String, messages: [ChatMessage], maxOutputTokens: Int? = nil,
                temperature: Double? = nil, topP: Double? = nil,
                seed: UInt64? = nil, presencePenalty: Double? = nil,
                frequencyPenalty: Double? = nil,
                responseFormat: ResponseFormat? = nil,
                tools: [ChatToolSpec] = [], toolChoice: ToolChoice = .auto) {
        self.model = model
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens ?? PlatformLimits.outputTokens
        self.hasExplicitOutputLimit = maxOutputTokens != nil
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.responseFormat = responseFormat
        self.tools = tools
        self.toolChoice = toolChoice
    }

    public var hasImages: Bool { messages.contains { !$0.images.isEmpty } }

    /// An omitted client limit uses the lower profile ceiling; an explicit
    /// over-limit request remains unchanged so validation can refuse it.
    public func resolvingDefaultOutputTokens(to cap: Int?) -> ChatRequest {
        guard !hasExplicitOutputLimit else { return self }
        return limitingOutputTokens(to: cap)
    }

    /// Per-profile output ceiling: a declared profile cap lowers the
    /// request's bound; an undeclared cap leaves the request's bound. Never
    /// raises it.
    public func limitingOutputTokens(to cap: Int?) -> ChatRequest {
        guard let cap, maxOutputTokens > cap else { return self }
        return ChatRequest(model: model, messages: messages, maxOutputTokens: cap,
                           temperature: temperature, topP: topP, seed: seed,
                           presencePenalty: presencePenalty,
                           frequencyPenalty: frequencyPenalty,
                           responseFormat: responseFormat,
                           tools: tools, toolChoice: toolChoice)
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
    /// The model emitted tool calls; the client is expected to run them and
    /// continue the conversation. Not authority - a requested action.
    case toolCalls = "tool_calls"
}

/// Provider truth. Usage is populated only when the provider measured it.
/// `toolCalls` carries parsed model tool requests; delivering them is the
/// extent of platform involvement - nothing executes them.
public struct ChatResult: Sendable {
    public let modelIdentity: String
    public let content: String
    public let finishReason: FinishReason
    public let usage: ChatUsage?
    public let toolCalls: [ChatToolCall]

    public init(modelIdentity: String, content: String, finishReason: FinishReason,
                usage: ChatUsage? = nil, toolCalls: [ChatToolCall] = []) {
        self.modelIdentity = modelIdentity
        self.content = content
        self.finishReason = finishReason
        self.usage = usage
        self.toolCalls = toolCalls
    }
}
