import Foundation
import PlatformCore

/// Validated M1 subset of POST /v1/chat/completions and GET /v1/models.
/// Unsupported options are explicit 400s - never discarded or translated.
public enum OpenAIAdapter {
    static let allowedTopLevel: Set<String> = [
        "model", "messages", "max_tokens", "max_completion_tokens",
        "stream", "n", "temperature", "top_p", "stop", "user",
        "frequency_penalty", "presence_penalty", "seed", "logprobs",
        "top_logprobs", "logit_bias", "parallel_tool_calls", "metadata",
        "store", "service_tier", "reasoning_effort",
    ]
    /// Fields the M1 subset refuses with 400 rather than executing/ignoring.
    static let refusedFields: Set<String> = [
        "tools", "tool_choice", "functions", "function_call",
        "response_format", "stream_options", "audio", "modalities",
        "prediction", "web_search_options",
    ]
    static let messageRoles: Set<String> = ["system", "developer", "user", "assistant"]
    static let messageFields: Set<String> = ["role", "content", "name"]

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
        guard let rawMessages = object["messages"]?.arrayValue, !rawMessages.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "messages required")
        }
        guard rawMessages.count <= PlatformLimits.chatMessages else {
            throw PlatformError(.invalidRequest, detail: "too many messages")
        }
        var messages: [ChatMessage] = []
        var totalText = 0
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
            let parts: [String]
            switch m["content"] {
            case .string(let s)?:
                parts = [s]
            case .array(let arr)?:
                var collected: [String] = []
                for part in arr {
                    guard let p = part.objectValue,
                          p["type"]?.stringValue == "text",
                          let text = p["text"]?.stringValue else {
                        throw PlatformError(.invalidRequest, detail: "unsupported content part")
                    }
                    for key in p.keys where key != "type" && key != "text" {
                        throw PlatformError(.invalidRequest, detail: "unsupported part field")
                    }
                    collected.append(text)
                }
                guard !collected.isEmpty else { throw PlatformError(.invalidRequest) }
                parts = collected
            default:
                throw PlatformError(.invalidRequest, detail: "content required")
            }
            for p in parts { totalText += p.utf8.count }
            messages.append(ChatMessage(role: role, parts: parts))
        }
        guard totalText <= PlatformLimits.chatTextBytes else {
            throw PlatformError(.payloadTooLarge)
        }
        return ChatRequest(model: model, messages: messages, maxOutputTokens: maxTokens)
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
