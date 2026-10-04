import Foundation
import PlatformCore

/// Validated subset of POST /v1/chat/completions and GET /v1/models.
/// Unsupported options are explicit 400s - never discarded or translated.
/// Sampling hints (temperature, top_p, seed, penalties) are carried to the
/// provider and honored where the provider supports them; `user`,
/// `metadata`, `store`, and `service_tier` are non-generative identity
/// fields accepted and ignored by contract.
///
/// Tools are a pass-through contract: schemas render into the provider's
/// chat template, parsed model tool calls come back in `tool_calls`, and
/// `tool` messages carry the caller's own tool results. The platform never
/// executes a tool call - a model's call is a suggestion to the client.
public enum OpenAIAdapter {
    static let allowedTopLevel: Set<String> = [
        "model", "messages", "max_tokens", "max_completion_tokens",
        "stream", "stream_options", "n", "temperature", "top_p", "seed",
        "user", "tools", "tool_choice",
        "frequency_penalty", "presence_penalty", "response_format",
        "metadata", "store", "service_tier",
    ]
    /// Fields refused with 400 rather than executed or silently ignored.
    /// `reasoning_effort`, `stop`, `logit_bias`, and `logprobs` family are
    /// refused because no provider honors them yet - accepted-but-ignored
    /// generative fields would lie about the serving contract. The legacy
    /// `functions`/`function_call` spellings stay refused; clients must use
    /// the `tools` form. `parallel_tool_calls` is refused for the same
    /// reason as other unenforced generative flags.
    static let refusedFields: Set<String> = [
        "functions", "function_call", "audio", "modalities",
        "prediction", "web_search_options", "stop",
        "logprobs", "top_logprobs", "logit_bias", "parallel_tool_calls",
        "reasoning_effort",
    ]
    static let messageRoles: Set<String> =
        ["system", "developer", "user", "assistant", "tool"]
    static let messageFields: Set<String> =
        ["role", "content", "name", "tool_calls", "tool_call_id"]
    /// Keys allowed on a `tools[]` entry and inside `function`.
    static let toolEntryKeys: Set<String> = ["type", "function"]
    static let toolFunctionKeys: Set<String> = ["name", "description", "parameters"]
    /// Keys allowed on an assistant `tool_calls[]` entry and its function.
    static let toolCallKeys: Set<String> = ["id", "type", "function"]
    static let toolCallFunctionKeys: Set<String> = ["name", "arguments"]
    /// Remote image URLs are refused: the platform never fetches caller
    /// URLs. Images must arrive inline as bounded data URIs.
    static let imageMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    /// A validated chat request plus its transport flags. `stream` selects
    /// SSE framing at the router and `includeUsage` asks for a trailing
    /// usage chunk; neither flag reaches the provider.
    public struct ParsedChatRequest: Sendable {
        public let request: ChatRequest
        public let stream: Bool
        public let includeUsage: Bool
    }

    public static func parseChatRequest(_ body: Data) throws -> ParsedChatRequest {
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
        var stream = false
        if let flag = object["stream"] {
            guard case .bool(let s) = flag else {
                throw PlatformError(.invalidRequest, detail: "stream must be a bool")
            }
            stream = s
        }
        var includeUsage = false
        if let options = object["stream_options"] {
            guard let opts = options.objectValue else {
                throw PlatformError(.invalidRequest, detail: "stream_options must be an object")
            }
            for key in opts.keys where key != "include_usage" {
                throw PlatformError(.invalidRequest,
                                    detail: "unsupported stream_options field: \(key)")
            }
            if let flag = opts["include_usage"] {
                guard case .bool(let b) = flag else {
                    throw PlatformError(.invalidRequest,
                                        detail: "include_usage must be a bool")
                }
                includeUsage = b
            }
        }
        if includeUsage, !stream {
            throw PlatformError(.invalidRequest,
                                detail: "stream_options requires stream")
        }
        if let n = object["n"], n != .int(1) {
            throw PlatformError(.invalidRequest, detail: "n must be 1")
        }
        let maxTokens: Int?
        switch (object["max_tokens"], object["max_completion_tokens"]) {
        case (.some, .some):
            throw PlatformError(.invalidRequest, detail: "both token fields set")
        case (.some(let v), .none), (.none, .some(let v)):
            guard let n = v.intValue, n > 0, n <= PlatformLimits.outputTokens else {
                throw PlatformError(.invalidRequest, detail: "max tokens out of range")
            }
            maxTokens = Int(n)
        default:
            maxTokens = nil
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
        let tools = try parseTools(object["tools"])
        let toolChoice = try parseToolChoice(object["tool_choice"])
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
        for tool in tools {
            totalText += tool.name.utf8.count + (tool.description?.utf8.count ?? 0)
            if let params = tool.parameters {
                totalText += ((try? params.encoded()) ?? Data()).count
            }
        }
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
            var toolCalls: [ChatToolCall] = []
            if let rawCalls = m["tool_calls"] {
                guard role == .assistant else {
                    throw PlatformError(.invalidRequest,
                                        detail: "tool_calls only allowed on assistant messages")
                }
                toolCalls = try parseToolCalls(rawCalls)
            }
            var toolCallID: String?
            if let rawID = m["tool_call_id"] {
                guard role == .tool,
                      let id = rawID.stringValue, !id.isEmpty else {
                    throw PlatformError(.invalidRequest,
                                        detail: "tool_call_id only allowed on tool messages")
                }
                toolCallID = id
            }
            if role == .tool, toolCallID == nil {
                throw PlatformError(.invalidRequest,
                                    detail: "tool message requires tool_call_id")
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
            case .none, .null?:
                // An assistant turn that only calls tools has no content.
                guard role == .assistant && !toolCalls.isEmpty else {
                    throw PlatformError(.invalidRequest, detail: "content required")
                }
                parts = []
            default:
                throw PlatformError(.invalidRequest, detail: "content required")
            }
            if parts.isEmpty && images.isEmpty && toolCalls.isEmpty {
                throw PlatformError(.invalidRequest)
            }
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
            for call in toolCalls {
                totalText += (call.id?.utf8.count ?? 0) + call.name.utf8.count
                totalText += ((try? call.arguments.encoded()) ?? Data()).count
            }
            messages.append(ChatMessage(role: role, parts: parts, images: images,
                                        toolCalls: toolCalls, toolCallID: toolCallID))
        }
        guard totalText <= PlatformLimits.chatTextBytes else {
            throw PlatformError(.payloadTooLarge)
        }
        return ParsedChatRequest(
            request: ChatRequest(model: model, messages: messages,
                                 maxOutputTokens: maxTokens,
                                 temperature: temperature, topP: topP, seed: seed,
                                 presencePenalty: presence, frequencyPenalty: frequency,
                                 responseFormat: responseFormat,
                                 tools: tools, toolChoice: toolChoice),
            stream: stream, includeUsage: includeUsage)
    }

    /// OpenAI `tools`: `{"type":"function","function":{name,description?,
    /// parameters?}}`. `strict` and other function keys are refused - the
    /// platform has no constrained decoding, so promising strictness would
    /// lie about the contract.
    private static func parseTools(_ value: JSONValue?) throws -> [ChatToolSpec] {
        guard let value else { return [] }
        guard let arr = value.arrayValue else {
            throw PlatformError(.invalidRequest, detail: "tools must be an array")
        }
        guard arr.count <= PlatformLimits.chatTools else {
            throw PlatformError(.invalidRequest, detail: "too many tools")
        }
        return try arr.map { entry in
            guard let obj = entry.objectValue else {
                throw PlatformError(.invalidRequest, detail: "tool entry malformed")
            }
            for key in obj.keys where !toolEntryKeys.contains(key) {
                throw PlatformError(.invalidRequest, detail: "unsupported tool field: \(key)")
            }
            guard obj["type"] == .string("function"),
                  let fn = obj["function"]?.objectValue else {
                throw PlatformError(.invalidRequest, detail: "tool requires type function")
            }
            for key in fn.keys where !toolFunctionKeys.contains(key) {
                throw PlatformError(.invalidRequest,
                                    detail: "unsupported tool function field: \(key)")
            }
            guard let name = fn["name"]?.stringValue, !name.isEmpty else {
                throw PlatformError(.invalidRequest, detail: "tool name required")
            }
            if let description = fn["description"], description.stringValue == nil {
                throw PlatformError(.invalidRequest, detail: "tool description must be a string")
            }
            if let params = fn["parameters"], params.objectValue == nil {
                throw PlatformError(.invalidRequest,
                                    detail: "tool parameters must be an object")
            }
            return ChatToolSpec(name: name,
                                description: fn["description"]?.stringValue,
                                parameters: fn["parameters"])
        }
    }

    /// `auto`, `none`, `required`, or `{"type":"function","function":{"name":...}}`.
    private static func parseToolChoice(_ value: JSONValue?) throws -> ToolChoice {
        guard let value else { return .auto }
        switch value {
        case .string(let s):
            switch s {
            case "auto": return .auto
            case "none": return .none
            case "required": return .required
            default:
                throw PlatformError(.invalidRequest, detail: "unknown tool_choice")
            }
        case .object(let obj):
            for key in obj.keys where key != "type" && key != "function" {
                throw PlatformError(.invalidRequest,
                                    detail: "unsupported tool_choice field: \(key)")
            }
            guard obj["type"] == .string("function"),
                  let fn = obj["function"]?.objectValue,
                  let name = fn["name"]?.stringValue, !name.isEmpty else {
                throw PlatformError(.invalidRequest, detail: "tool_choice malformed")
            }
            for key in fn.keys where key != "name" {
                throw PlatformError(.invalidRequest,
                                    detail: "unsupported tool_choice function field: \(key)")
            }
            return .named(name)
        default:
            throw PlatformError(.invalidRequest, detail: "tool_choice malformed")
        }
    }

    /// Assistant `tool_calls`: `{id?, type:"function", function:{name,
    /// arguments}}`. `arguments` is the OpenAI JSON string (accepted as a
    /// raw object too); it must decode to JSON - malformed argument text is
    /// a client bug, not model output, so it is rejected, not salvaged.
    private static func parseToolCalls(_ value: JSONValue) throws -> [ChatToolCall] {
        guard let arr = value.arrayValue else {
            throw PlatformError(.invalidRequest, detail: "tool_calls must be an array")
        }
        guard arr.count <= PlatformLimits.chatToolCallsPerMessage else {
            throw PlatformError(.invalidRequest, detail: "too many tool calls on one message")
        }
        return try arr.map { entry in
            guard let obj = entry.objectValue else {
                throw PlatformError(.invalidRequest, detail: "tool_call malformed")
            }
            for key in obj.keys where !toolCallKeys.contains(key) {
                throw PlatformError(.invalidRequest,
                                    detail: "unsupported tool_call field: \(key)")
            }
            if let id = obj["id"], id.stringValue == nil {
                throw PlatformError(.invalidRequest, detail: "tool_call id must be a string")
            }
            guard obj["type"] == .string("function"),
                  let fn = obj["function"]?.objectValue else {
                throw PlatformError(.invalidRequest, detail: "tool_call requires type function")
            }
            for key in fn.keys where !toolCallFunctionKeys.contains(key) {
                throw PlatformError(.invalidRequest,
                                    detail: "unsupported tool_call function field: \(key)")
            }
            guard let name = fn["name"]?.stringValue, !name.isEmpty else {
                throw PlatformError(.invalidRequest, detail: "tool_call name required")
            }
            var arguments: JSONValue = .object([:])
            if let raw = fn["arguments"] {
                switch raw {
                case .string(let s):
                    arguments = try JSONValue.decode(Data(s.utf8))
                case .object:
                    arguments = raw
                default:
                    throw PlatformError(.invalidRequest,
                                        detail: "tool_call arguments must be a JSON string")
                }
            }
            return ChatToolCall(id: obj["id"]?.stringValue, name: name,
                                arguments: arguments)
        }
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
            // strict is boolean-only, and strict:true claims constrained
            // decoding this platform does not have - refuse it rather than
            // pretend enforcement. strict:false stays a guidance hint.
            if let strict = schema["strict"] {
                guard case .bool(let flag) = strict else {
                    throw PlatformError(.invalidRequest,
                                        detail: "json_schema.strict must be a boolean")
                }
                if flag {
                    throw PlatformError(.invalidRequest,
                                        detail: "strict json_schema is not supported")
                }
            }
            for field in ["name", "description"] {
                if let value = schema[field], value != .null, value.stringValue == nil {
                    throw PlatformError(.invalidRequest,
                                        detail: "json_schema.\(field) must be a string")
                }
            }
            guard let body = schema["schema"], body.objectValue != nil else {
                throw PlatformError(.invalidRequest, detail: "json_schema.schema required")
            }
            return .jsonSchema(name: schema["name"]?.stringValue, schema: body)
        default:
            throw PlatformError(.invalidRequest, detail: "unsupported response_format type")
        }
    }

    private static func usageObject(_ usage: ChatUsage?) -> JSONValue {
        guard let u = usage else { return .null }
        var fields: [String: JSONValue] = [:]
        if let p = u.promptTokens { fields["prompt_tokens"] = .int(Int64(p)) }
        if let c = u.completionTokens { fields["completion_tokens"] = .int(Int64(c)) }
        if let t = u.totalTokens { fields["total_tokens"] = .int(Int64(t)) }
        return .object(fields)
    }

    /// Wire shape for assistant tool calls: arguments re-encoded as the
    /// JSON string OpenAI clients expect; a missing provider id becomes a
    /// per-response `call_<completionID>_<index>` so ids are unique across
    /// turns and tool messages can correlate. Stream deltas carry `index`;
    /// the non-streaming message shape omits it.
    private static func wireToolCalls(_ calls: [ChatToolCall], indexed: Bool,
                                      completionID: String) -> JSONValue {
        .array(calls.enumerated().map { (index, call) in
            let arguments = String(decoding: (try? call.arguments.encoded())
                                   ?? Data("{}".utf8), as: UTF8.self)
            var entry: [String: JSONValue] = [
                "id": .string(call.id ?? "call_\(completionID)_\(index)"),
                "type": .string("function"),
                "function": .object([
                    "name": .string(call.name),
                    "arguments": .string(arguments),
                ]),
            ]
            if indexed { entry["index"] = .int(Int64(index)) }
            return .object(entry)
        })
    }

    /// The finish reason a result reports: an emit-time tool-call list with
    /// a nominal stop is normalized to `tool_calls` so clients loop.
    private static func wireFinish(_ result: ChatResult) -> FinishReason {
        if !result.toolCalls.isEmpty, result.finishReason == .stop { return .toolCalls }
        return result.finishReason
    }

    /// Assistant message fields shared by the JSON response and the SSE
    /// deltas: content is `null` (not an empty string) when the turn only
    /// carried tool calls, matching OpenAI's representation.
    private static func wireMessageFields(_ result: ChatResult,
                                          completionID: String) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "role": .string("assistant"),
            "content": result.content.isEmpty && !result.toolCalls.isEmpty
                ? .null : .string(result.content),
        ]
        if !result.toolCalls.isEmpty {
            fields["tool_calls"] = wireToolCalls(result.toolCalls, indexed: false,
                                                 completionID: completionID)
        }
        return fields
    }

    /// One completion id per response: every chunk and the usage frame in a
    /// stream share it, so client-side call history never collides across
    /// turns.
    private static func newCompletionID() -> String {
        "chatcmpl-\(UUID().uuidString.lowercased())"
    }

    public static func chatResponse(_ result: ChatResult, requestedModel: String) -> JSONValue {
        let completionID = newCompletionID()
        return .object([
            "id": .string(completionID),
            "object": .string("chat.completion"),
            "created": .int(Int64(Date().timeIntervalSince1970)),
            // The wire model is the serving alias the client requested, not
            // the provider's engine identity.
            "model": .string(requestedModel),
            "choices": .array([.object([
                "index": .int(0),
                "message": .object(wireMessageFields(result, completionID: completionID)),
                "finish_reason": .string(wireFinish(result).rawValue),
            ])]),
            "usage": usageObject(result.usage),
        ])
    }

    /// SSE frames for `stream: true`: role delta, one content delta (the
    /// single-shot provider boundary cannot interleave token deltas), one
    /// tool_calls delta, the finish chunk, an optional usage chunk when the
    /// client asked for it and the provider measured usage, then [DONE].
    public static func streamFrames(_ result: ChatResult, requestedModel: String,
                                    includeUsage: Bool) -> [Data] {
        let created = Int64(Date().timeIntervalSince1970)
        let completionID = newCompletionID()
        func frame(_ delta: JSONValue, finish: FinishReason?) -> Data {
            var frame = Data("data: ".utf8)
            frame.append((try? JSONValue.object([
                "id": .string(completionID),
                "object": .string("chat.completion.chunk"),
                "created": .int(created),
                "model": .string(requestedModel),
                "choices": .array([.object([
                    "index": .int(0),
                    "delta": delta,
                    "finish_reason": finish.map { .string($0.rawValue) } ?? .null,
                ])]),
            ]).encoded()) ?? Data("{}".utf8))
            frame.append(Data("\n\n".utf8))
            return frame
        }
        var frames: [Data] = [
            frame(.object(["role": .string("assistant")]), finish: nil)
        ]
        if !result.content.isEmpty {
            frames.append(frame(.object(["content": .string(result.content)]),
                                finish: nil))
        }
        if !result.toolCalls.isEmpty {
            frames.append(frame(.object([
                "tool_calls": wireToolCalls(result.toolCalls, indexed: true,
                                            completionID: completionID),
            ]), finish: nil))
        }
        frames.append(frame(.object([:]), finish: wireFinish(result)))
        if includeUsage, let usage = result.usage {
            var usageFrame = Data("data: ".utf8)
            usageFrame.append((try? JSONValue.object([
                "id": .string(completionID),
                "object": .string("chat.completion.chunk"),
                "created": .int(created),
                "model": .string(requestedModel),
                "choices": .array([]),
                "usage": usageObject(usage),
            ]).encoded()) ?? Data("{}".utf8))
            usageFrame.append(Data("\n\n".utf8))
            frames.append(usageFrame)
        }
        frames.append(Data("data: [DONE]\n\n".utf8))
        return frames
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
