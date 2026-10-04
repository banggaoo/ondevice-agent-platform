import Foundation
import PlatformCore

/// Validated subset of POST /v1/chat/completions and GET /v1/models.
/// Unsupported options are explicit 400s - never discarded or translated.
/// Sampling hints (temperature, top_p, seed, penalties) are carried to the
/// provider and honored where the provider supports them; `user`,
/// `metadata`, `store`, and `service_tier` are non-generative identity
/// fields accepted and ignored by contract.
public enum OpenAIAdapter {
    static let allowedTopLevel: Set<String> = [
        "model", "messages", "max_tokens", "max_completion_tokens",
        "stream", "n", "temperature", "top_p", "seed", "user",
        "frequency_penalty", "presence_penalty", "response_format",
        "metadata", "store", "service_tier",
    ]
    /// Fields refused with 400 rather than executed or silently ignored.
    /// `reasoning_effort`, `stop`, `logit_bias`, and `logprobs` family are
    /// refused because no provider honors them yet - accepted-but-ignored
    /// generative fields would lie about the serving contract.
    static let refusedFields: Set<String> = [
        "tools", "tool_choice", "functions", "function_call",
        "stream_options", "audio", "modalities",
        "prediction", "web_search_options", "stop",
        "logprobs", "top_logprobs", "logit_bias", "parallel_tool_calls",
        "reasoning_effort",
    ]
    static let messageRoles: Set<String> = ["system", "developer", "user", "assistant"]
    static let messageFields: Set<String> = ["role", "content", "name"]
    /// Remote image URLs are refused: the platform never fetches caller
    /// URLs. Images must arrive inline as bounded data URIs.
    static let imageMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    public static func parseChatRequest(_ body: Data) throws -> ChatRequest {
        let root = try JSONValue.decode(body)
        guard let object = root.objectValue else { throw PlatformError(.invalidRequest) }
        for key in object.keys {
            if refusedFields.contains(key) {
                throw PlatformError(.invalidRequest, detail: "unsupported option: \(key)")
            }
            if !allowedTopLevel.contains(key) {
                throw PlatformError(.invalidRequest, detail: "unknown field: \(key)")
            }
        }
        guard let model = object["model"]?.stringValue, !model.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "model required")
        }
        if object["stream"] == .bool(true) {
            throw PlatformError(.invalidRequest, detail: "stream unsupported")
        }
        if let n = object["n"], n != .int(1) {
            throw PlatformError(.invalidRequest, detail: "n must be 1")
        }
        let maxTokens: Int
        switch (object["max_tokens"], object["max_completion_tokens"]) {
        case (.some, .some):
            throw PlatformError(.invalidRequest, detail: "both token fields set")
        case (.some(let v), .none), (.none, .some(let v)):
            guard let n = v.intValue, n > 0, n <= PlatformLimits.outputTokens else {
                throw PlatformError(.invalidRequest, detail: "max tokens out of range")
            }
            maxTokens = Int(n)
        default:
            maxTokens = PlatformLimits.outputTokens
        }
        let temperature = try boundedDouble(object["temperature"], field: "temperature", min: 0, max: 2)
        let topP = try boundedDouble(object["top_p"], field: "top_p", min: 0, max: 1)
        let presence = try boundedDouble(object["presence_penalty"], field: "presence_penalty", min: -2, max: 2)
        let frequency = try boundedDouble(object["frequency_penalty"], field: "frequency_penalty", min: -2, max: 2)
        var seed: UInt64?
        if let raw = object["seed"] {
            guard let n = raw.intValue, n >= 0 else {
                throw PlatformError(.invalidRequest, detail: "seed must be a nonnegative integer")
            }
            seed = UInt64(n)
        }
        let responseFormat = try parseResponseFormat(object["response_format"])
        guard let rawMessages = object["messages"]?.arrayValue, !rawMessages.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "messages required")
        }
        guard rawMessages.count <= PlatformLimits.chatMessages else {
            throw PlatformError(.invalidRequest, detail: "too many messages")
        }
        var messages: [ChatMessage] = []
        var totalText = 0
        var totalImageBytes = 0
        var imageCount = 0
        for raw in rawMessages {
            guard let m = raw.objectValue,
                  let roleName = m["role"]?.stringValue,
                  let role = ChatRole(rawValue: roleName),
                  messageRoles.contains(roleName) else {
                throw PlatformError(.invalidRequest, detail: "invalid role")
            }
            for key in m.keys where !messageFields.contains(key) {
                throw PlatformError(.invalidRequest, detail: "unsupported message field")
            }
            var parts: [String] = []
            var images: [ChatImage] = []
            switch m["content"] {
            case .string(let s)?:
                parts = [s]
            case .array(let arr)?:
                for part in arr {
                    guard let p = part.objectValue,
                          let type = p["type"]?.stringValue else {
                        throw PlatformError(.invalidRequest, detail: "unsupported content part")
                    }
                    switch type {
                    case "text":
                        for key in p.keys where key != "type" && key != "text" {
                            throw PlatformError(.invalidRequest, detail: "unsupported part field")
                        }
                        guard let text = p["text"]?.stringValue else {
                            throw PlatformError(.invalidRequest, detail: "text part lacks text")
                        }
                        parts.append(text)
                    case "image_url":
                        for key in p.keys where key != "type" && key != "image_url" {
                            throw PlatformError(.invalidRequest, detail: "unsupported part field")
                        }
                        images.append(try parseImage(p["image_url"]))
                    default:
                        throw PlatformError(.invalidRequest, detail: "unsupported content part")
                    }
                }
            default:
                throw PlatformError(.invalidRequest, detail: "content required")
            }
            if parts.isEmpty && images.isEmpty { throw PlatformError(.invalidRequest) }
            if !images.isEmpty {
                guard role == .user else {
                    throw PlatformError(.invalidRequest,
                                        detail: "images only allowed on user messages")
                }
                imageCount += images.count
                for image in images { totalImageBytes += image.data.count }
                guard imageCount <= PlatformLimits.chatImagesPerRequest,
                      totalImageBytes <= PlatformLimits.chatImageBytes else {
                    throw PlatformError(.payloadTooLarge, detail: "image limits exceeded")
                }
            }
            for p in parts { totalText += p.utf8.count }
            messages.append(ChatMessage(role: role, parts: parts, images: images))
        }
        guard totalText <= PlatformLimits.chatTextBytes else {
            throw PlatformError(.payloadTooLarge)
        }
        return ChatRequest(model: model, messages: messages, maxOutputTokens: maxTokens,
                           temperature: temperature, topP: topP, seed: seed,
                           presencePenalty: presence, frequencyPenalty: frequency,
                           responseFormat: responseFormat)
    }

    /// `data:image/...;base64,...` only - never a remote fetch.
    private static func parseImage(_ value: JSONValue?) throws -> ChatImage {
        guard let obj = value?.objectValue else {
            throw PlatformError(.invalidRequest, detail: "image_url object required")
        }
        for key in obj.keys where key != "url" && key != "detail" {
            throw PlatformError(.invalidRequest, detail: "unsupported image_url field")
        }
        if let detail = obj["detail"]?.stringValue {
            guard detail == "auto" else {
                throw PlatformError(.invalidRequest, detail: "image detail not honored")
            }
        }
        guard let url = obj["url"]?.stringValue else {
            throw PlatformError(.invalidRequest, detail: "image url required")
        }
        guard url.hasPrefix("data:") else {
            throw PlatformError(.invalidRequest,
                                detail: "remote image urls are never fetched; use a data URI")
        }
        let parts = url.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else {
            throw PlatformError(.invalidRequest, detail: "malformed data uri")
        }
        let header = String(parts[0])
        guard header.hasSuffix(";base64") else {
            throw PlatformError(.invalidRequest, detail: "image data uri must be base64")
        }
        let mediaType = String(header.dropFirst(5).dropLast(7))
        guard imageMediaTypes.contains(mediaType) else {
            throw PlatformError(.invalidRequest, detail: "unsupported image media type")
        }
        guard let data = Data(base64Encoded: String(parts[1]),
                              options: .ignoreUnknownCharacters) else {
            throw PlatformError(.invalidRequest, detail: "image base64 malformed")
        }
        return ChatImage(data: data, mediaType: mediaType)
    }

    private static func boundedDouble(_ value: JSONValue?, field: String,
                                      min: Double, max: Double) throws -> Double? {
        guard let value else { return nil }
        let n: Double?
        switch value {
        case .int(let i): n = Double(i)
        case .double(let d): n = d
        default: n = nil
        }
        guard let n, n.isFinite, n >= min, n <= max else {
            throw PlatformError(.invalidRequest, detail: "\(field) out of range")
        }
        return n
    }

    /// `{"type":"text"}` is trivially satisfied; `json_object`/`json_schema`
    /// are accepted as provider guidance (the platform has no constrained
    /// decoding - this is a best-effort hint, never a promise of valid JSON).
    private static func parseResponseFormat(_ value: JSONValue?) throws -> ResponseFormat? {
        guard let value else { return nil }
        guard let obj = value.objectValue,
              let type = obj["type"]?.stringValue else {
            throw PlatformError(.invalidRequest, detail: "response_format malformed")
        }
        switch type {
        case "text":
            return nil
        case "json_object":
            return .jsonObject
        case "json_schema":
            guard let schema = obj["json_schema"]?.objectValue else {
                throw PlatformError(.invalidRequest, detail: "json_schema requires json_schema object")
            }
            for key in schema.keys where !["name", "description", "schema", "strict"].contains(key) {
                throw PlatformError(.invalidRequest, detail: "unsupported json_schema field")
            }
            guard let body = schema["schema"], body.objectValue != nil else {
                throw PlatformError(.invalidRequest, detail: "json_schema.schema required")
            }
            return .jsonSchema(name: schema["name"]?.stringValue, schema: body)
        default:
            throw PlatformError(.invalidRequest, detail: "unsupported response_format type")
        }
    }

    public static func chatResponse(_ result: ChatResult, requestedModel: String) -> JSONValue {
        var usage: JSONValue = .null
        if let u = result.usage {
            var fields: [String: JSONValue] = [:]
            if let p = u.promptTokens { fields["prompt_tokens"] = .int(Int64(p)) }
            if let c = u.completionTokens { fields["completion_tokens"] = .int(Int64(c)) }
            if let t = u.totalTokens { fields["total_tokens"] = .int(Int64(t)) }
            usage = .object(fields)
        }
        return .object([
            "id": .string("chatcmpl-local"),
            "object": .string("chat.completion"),
            "created": .int(Int64(Date().timeIntervalSince1970)),
            "model": .string(result.modelIdentity),
            "choices": .array([.object([
                "index": .int(0),
                "message": .object([
                    "role": .string("assistant"),
                    "content": .string(result.content),
                ]),
                "finish_reason": .string(result.finishReason.rawValue),
            ])]),
            "usage": usage,
        ])
    }

    public static func modelsResponse(_ profiles: [ModelProfile]) -> JSONValue {
        .object([
            "object": .string("list"),
            "data": .array(profiles.map { profile in
                .object([
                    "id": .string(profile.alias),
                    "object": .string("model"),
                    "created": .int(0),
                    "owned_by": .string(profile.providerID),
                ])
            }),
        ])
    }

    /// OpenAI-shaped error body.
    public static func errorBody(_ error: PlatformError, param: String? = nil) -> JSONValue {
        .object(["error": .object([
            "message": .string(error.safeMessage),
            "type": .string(error.code.rawValue),
            "param": param.map { .string($0) } ?? .null,
            "code": .string(error.code.rawValue),
        ])])
    }
}
