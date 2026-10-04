import Foundation
import MLXLMCommon
import MLXLLM
import PlatformCore
import Tokenizers

/// Owned open-weight LLM route over MLX Swift. Registered only for
/// registry-declared `provider: "mlx"` profiles; every such profile carries a
/// `ModelSource` that must resolve to a pulled, verified artifact in the
/// `ModelStore`. A declared-but-unpulled model fails providerUnavailable -
/// nothing is downloaded at request time, nothing is fabricated.
///
/// Message mapping mirrors the Apple provider's contract: system/developer
/// messages become one `instructions` entry, earlier user/assistant turns
/// become ordered chat history, and the final message must be a nonempty user
/// turn. Generation runs through `ChatSession.streamDetails` so real token
/// counts and the true stop reason are reported. `maxTokens` is the request's
/// output bound; temperature is fixed at 0 (greedy) because the serving
/// contract carries no sampling parameters and determinism is the platform's
/// default posture.
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
        guard let source = profile.source else {
            throw PlatformError(.invalidRequest, detail: "mlx profile lacks source")
        }
        let mapped = try Self.map(request)
        let container = try await container(for: source)
        let task = Task<ChatResult, Error> {
            var params = GenerateParameters()
            params.maxTokens = request.maxOutputTokens
            params.temperature = 0
            let session = ChatSession(container, instructions: mapped.instructions,
                                      history: mapped.history,
                                      generateParameters: params)
            var content = ""
            var info: GenerateCompletionInfo?
            for try await generation in session.streamDetails(to: mapped.prompt) {
                switch generation {
                case .chunk(let text): content += text
                case .info(let completion): info = completion
                case .toolCall:
                    // No tools are declared to the model; a parsed tool call
                    // here is unexpected output, not authority. Surface it as
                    // text-free termination rather than acting on it.
                    continue
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
                              finishReason: finish, usage: usage)
        }
        track(task)
        defer { untrack(task) }
        return try await task.value
    }

    public func cancel(jobID: String) async {
        tracked()?.cancel()
    }

    /// Maps a validated request to instructions + ordered history + final
    /// user prompt. Same refusal rules as the Apple route: assistant-final
    /// conversations and empty final turns are rejected, never improvised.
    static func map(_ request: ChatRequest) throws -> (instructions: String?,
                                                       history: [Chat.Message],
                                                       prompt: String) {
        var history: [Chat.Message] = []
        var instructions: [String] = []
        var prompt: String?
        let last = request.messages.count - 1
        for (index, message) in request.messages.enumerated() {
            let text = message.combinedText
            switch message.role {
            case .system, .developer:
                if !text.isEmpty { instructions.append(text) }
            case .user:
                if index == last {
                    prompt = text
                } else {
                    history.append(.user(text))
                }
            case .assistant:
                guard index != last else {
                    throw PlatformError(.invalidRequest,
                                        detail: "final message must be a user turn")
                }
                history.append(.assistant(text))
            }
        }
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlatformError(.invalidRequest, detail: "final user message required")
        }
        return (instructions.isEmpty ? nil : instructions.joined(separator: "\n"),
                history, prompt)
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
