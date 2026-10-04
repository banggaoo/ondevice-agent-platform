import Foundation
import CoreImage
import MLXLMCommon
import MLXLLM
import MLXVLM
import PlatformCore
import Tokenizers

/// Owned open-weight LLM route over MLX Swift. Registered only for
/// registry-declared `provider: "mlx"` profiles; every such profile carries a
/// `ModelSource` that must resolve to a pulled, verified artifact in the
/// `ModelStore`. A declared-but-unpulled model fails providerUnavailable -
/// nothing is downloaded at request time, nothing is fabricated.
///
/// Message mapping: system/developer messages become one `instructions`
/// entry; user/assistant/tool turns keep their order as structured
/// `Chat.Message`s, including assistant tool calls and tool-result ids.
/// The final message must be a nonempty user turn or a tool result.
/// Generation runs through `ChatSession.streamDetails` so real token
/// counts and the true stop reason are reported. Declared tools render
/// through the tokenizer's chat template (`tools:` parameter); parsed
/// `.toolCall` events are returned to the caller verbatim - the provider
/// executes nothing. `maxTokens` is the request's output bound; unset
/// sampling hints mean the platform default, greedy.
public final class MLXProvider: LLMProvider, ProviderReadiness, @unchecked Sendable {
    public static let id = MLXProviderContract.id
    public let providerID = MLXProviderContract.id

    /// The store this provider resolves artifacts from. Exposed so startup
    /// wiring can report pull state truthfully without inference.
    public let store: ModelStore
    private let lock = NSLock()
    /// Loaded containers keyed by store directory name; models load lazily on
    /// first use (inside admission) and stay resident for the daemon's life.
    private var containers: [String: ModelContainer] = [:]
    private var pendingLoads: [String: Task<ModelContainer, Error>] = [:]
    /// Single in-flight generation (admission is single-slot); cancel() hints
    /// it via task cancellation which terminates the stream cooperatively.
    private var inFlight: Task<ChatResult, Error>?

    public init(store: ModelStore) {
        self.store = store
    }

    public var hasReadyArtifact: Bool { store.hasReadyArtifact }

    /// A call loads weights only when no container is cached and no load is
    /// already in flight; attaching to a pending load adds no second load.
    /// An unresolvable artifact cannot load at all - the job dispatches and
    /// fails truthfully rather than queuing under `defer_load` until expiry.
    public func requiresLoad(for profile: ModelProfile) -> Bool {
        guard let source = profile.source,
              let dir = try? store.validatedDirectory(for: source) else { return false }
        let key = dir.lastPathComponent
        lock.lock(); defer { lock.unlock() }
        return containers[key] == nil && pendingLoads[key] == nil
    }

    public func artifactReady(for profile: ModelProfile) -> Bool? {
        guard profile.providerID == Self.id, let source = profile.source else { return false }
        return store.isReady(source: source)
    }

    // Lock helpers stay synchronous; NSLock must not be used across awaits.
    private func cached(_ key: String) -> ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        return containers[key]
    }

    private func pending(_ key: String) -> Task<ModelContainer, Error>? {
        lock.lock(); defer { lock.unlock() }
        return pendingLoads[key]
    }

    private func trackLoad(_ key: String, _ task: Task<ModelContainer, Error>) {
        lock.lock(); pendingLoads[key] = task; lock.unlock()
    }

    private func untrackLoad(_ key: String, _ task: Task<ModelContainer, Error>,
                             result: ModelContainer?) {
        lock.lock()
        if pendingLoads[key] == task { pendingLoads[key] = nil }
        if let result { containers[key] = result }
        lock.unlock()
    }

    private func track(_ task: Task<ChatResult, Error>) {
        lock.lock(); inFlight = task; lock.unlock()
    }

    private func untrack(_ task: Task<ChatResult, Error>) {
        lock.lock(); if inFlight == task { inFlight = nil }; lock.unlock()
    }

    private func tracked() -> Task<ChatResult, Error>? {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    private func container(for source: ModelSource) async throws -> ModelContainer {
        let dir = try store.validatedDirectory(for: source)
        let key = dir.lastPathComponent
        if let cached = cached(key) { return cached }
        if let pending = pending(key) { return try await pending.value }
        let task = Task<ModelContainer, Error> {
            try await loadModelContainer(from: dir, using: AutoTokenizerLoader())
        }
        trackLoad(key, task)
        do {
            let container = try await task.value
            untrackLoad(key, task, result: container)
            return container
        } catch {
            untrackLoad(key, task, result: nil)
            throw error
        }
    }

    public func complete(_ request: ChatRequest, profile: ModelProfile) async throws -> ChatResult {
        try Task.checkCancellation()
        guard let source = profile.source else {
            throw PlatformError(.invalidRequest, detail: "mlx profile lacks source")
        }
        let mapped = try Self.map(request)
        let container = try await container(for: source)
        // A cancel that landed during container load must not reach
        // generation; the slot releases without invoking the model.
        try Task.checkCancellation()
        let task = Task<ChatResult, Error> {
            var params = GenerateParameters()
            params.maxTokens = request.maxOutputTokens
            // Unset sampling hints mean the platform default: greedy.
            params.temperature = Float(request.temperature ?? 0)
            if let topP = request.topP { params.topP = Float(topP) }
            if let seed = request.seed { params.seed = seed }
            if let presence = request.presencePenalty {
                params.presencePenalty = Float(presence)
            }
            if let frequency = request.frequencyPenalty {
                params.frequencyPenalty = Float(frequency)
            }
            var instructions = mapped.instructions
            if let format = request.responseFormat {
                let guidance = try format.guidance()
                instructions = instructions.map { $0 + "\n" + guidance } ?? guidance
            }
            let tools = Self.toolSpecs(for: request)
            if !tools.isEmpty, let steer = Self.toolChoiceGuidance(request.toolChoice) {
                instructions = instructions.map { $0 + "\n" + steer } ?? steer
            }
            let session = ChatSession(container, instructions: instructions,
                                      generateParameters: params,
                                      tools: tools.isEmpty ? nil : tools)
            var content = ""
            var calls: [ChatToolCall] = []
            var info: GenerateCompletionInfo?
            for try await generation in session.streamDetails(to: mapped.messages) {
                switch generation {
                case .chunk(let text): content += text
                case .info(let completion): info = completion
                case .toolCall(let call):
                    // A parsed tool call is model output handed to the
                    // caller - toolDispatch stays nil so nothing executes.
                    calls.append(ChatToolCall(
                        id: call.id, name: call.function.name,
                        arguments: .object(call.function.arguments
                            .mapValues(Self.platformJSON))))
                }
            }
            let finish: FinishReason
            switch info?.stopReason {
            case .length: finish = .length
            case .cancelled: throw CancellationError()
            case .stop, nil: finish = .stop
            }
            let usage = info.map {
                ChatUsage(promptTokens: $0.promptTokenCount,
                          completionTokens: $0.generationTokenCount,
                          totalTokens: $0.promptTokenCount + $0.generationTokenCount)
            }
            return ChatResult(modelIdentity: MLXProvider.id, content: content,
                              finishReason: calls.isEmpty ? finish : .toolCalls,
                              usage: usage, toolCalls: calls)
        }
        track(task)
        defer { untrack(task) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancel(jobID: String) async {
        tracked()?.cancel()
    }

    /// Maps a validated request to one `instructions` entry plus the full
    /// ordered turn list as structured `Chat.Message`s - assistant tool
    /// calls and tool-result ids included. Same refusal discipline as the
    /// Apple route: the final message must be a nonempty user turn or a
    /// tool result; an assistant-final conversation is rejected, never
    /// improvised. Images attach to the user turn that carried them.
    static func map(_ request: ChatRequest) throws -> (instructions: String?,
                                                       messages: [Chat.Message]) {
        var messages: [Chat.Message] = []
        var instructions: [String] = []
        for message in request.messages {
            let text = message.combinedText
            switch message.role {
            case .system, .developer:
                if !text.isEmpty { instructions.append(text) }
            case .user:
                let mlxImages = try message.images.map { try image($0) }
                messages.append(.user(text, images: mlxImages))
            case .assistant:
                let calls: [ToolCall]? = message.toolCalls.isEmpty ? nil
                    : message.toolCalls.map { call in
                        ToolCall(function: .init(name: call.name,
                                                 arguments: sendableArgs(call.arguments)),
                                 id: call.id)
                    }
                messages.append(.assistant(text, toolCalls: calls))
            case .tool:
                messages.append(.tool(text, id: message.toolCallID))
            }
        }
        switch request.messages.last?.role {
        case .user?:
            let text = request.messages.last?.combinedText ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(request.messages.last?.images.isEmpty ?? true) else {
                throw PlatformError(.invalidRequest, detail: "final user message required")
            }
        case .tool?:
            break   // a tool result continues the turn
        default:
            throw PlatformError(.invalidRequest,
                                detail: "final message must be a user turn or tool result")
        }
        return (instructions.isEmpty ? nil : instructions.joined(separator: "\n"),
                messages)
    }

    /// Client-declared tools → `ToolSpec` dicts in the shape chat templates
    /// consume. `toolChoice: .none` withholds the schemas entirely - the
    /// truthful way to express "no tools" to a template-driven model.
    static func toolSpecs(for request: ChatRequest) -> [ToolSpec] {
        guard request.toolChoice != .none else { return [] }
        return request.tools.map { spec in
            var function: [String: any Sendable] = ["name": spec.name]
            if let description = spec.description {
                function["description"] = description
            }
            if let parameters = spec.parameters {
                function["parameters"] = sendable(parameters)
            }
            return ["type": "function", "function": function] as ToolSpec
        }
    }

    /// `required`/`named` choices have no enforcement machinery - they are
    /// appended to instructions as explicit guidance text, documented as a
    /// best-effort steer, not a guarantee.
    static func toolChoiceGuidance(_ choice: ToolChoice) -> String? {
        switch choice {
        case .required:
            return "You must respond by calling one of the provided tools."
        case .named(let name):
            return "You must respond by calling the tool named \"\(name)\"."
        case .auto, .none:
            return nil
        }
    }

    /// Platform JSON → Sendable for tool schemas and tool-call arguments.
    static func sendable(_ value: PlatformCore.JSONValue) -> any Sendable {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return Int(i)
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(sendable)
        case .object(let o): return o.mapValues(sendable)
        }
    }

    static func sendableArgs(_ arguments: PlatformCore.JSONValue) -> [String: any Sendable] {
        switch arguments {
        case .object(let o): return o.mapValues(sendable)
        case .null: return [:]
        default:
            // A non-object arguments value keeps its content under a
            // conventional key rather than failing the whole turn.
            return ["value": sendable(arguments)]
        }
    }

    /// MLX JSON → platform JSON, for tool-call arguments coming back out.
    static func platformJSON(_ value: MLXLMCommon.JSONValue) -> PlatformCore.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(Int64(i))
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(platformJSON))
        case .object(let o): return .object(o.mapValues(platformJSON))
        }
    }

    /// Decode a validated image payload to a CIImage. Decoded data that is
    /// not a real image fails here, before generation consumes a slot.
    private static func image(_ image: ChatImage) throws -> UserInput.Image {
        guard let ciImage = CIImage(data: image.data),
              !ciImage.extent.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "image data is not a decodable image")
        }
        return .ciImage(ciImage)
    }
}

/// Loads a HF-format tokenizer from a local directory. Equivalent to the
/// `#huggingFaceTokenizerLoader()` macro output, spelled out so this target
/// does not depend on the macro plugin module.
public struct AutoTokenizerLoader: TokenizerLoader {
    public init() {}
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Adapts `Tokenizers.Tokenizer` to `MLXLMCommon.Tokenizer` (same shape the
/// `adaptHuggingFaceTokenizer` macro generates).
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
