import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models provider. Registered only through the explicit
/// `serve --enable-apple-model` opt-in (or config key); availability is
/// observed, never assumed. When the framework or device eligibility is
/// absent the provider throws providerUnavailable - it never fabricates a
/// completion.
///
/// Message mapping (M2 seam): system/developer content is gathered into one
/// leading transcript `.instructions` entry; earlier user/assistant messages
/// become `.prompt`/`.response` entries in order; the final message must be a
/// user turn and becomes the `respond(to:)` argument (the session appends it
/// itself, so it must not also sit in the transcript).
///
/// Tool surface: the Foundation Models transcript types cannot express a
/// caller-managed tool loop - declared tools, prior assistant tool calls,
/// and tool-result messages are all refused at validation rather than
/// dropped or faked. `tool_choice: "none"` is honored by withholding the
/// schemas, matching the MLX route.
public final class AppleFoundationProvider: LLMProvider, @unchecked Sendable {
    public static let id = "apple-foundation-models"
    public let providerID = "apple-foundation-models"

    private let lock = NSLock()
    /// The one in-flight generation. Single-slot admission means at most one
    /// is live; `cancel` interrupts it cooperatively via task cancellation.
    private var inFlight: Task<ChatResult, Error>?

    public init() {}

    // Synchronous lock helpers: NSLock cannot be called from async contexts
    // directly, so all locking happens inside non-async methods.
    private func track(_ task: Task<ChatResult, Error>) {
        lock.lock()
        inFlight = task
        lock.unlock()
    }

    private func untrack(_ task: Task<ChatResult, Error>) {
        lock.lock()
        if inFlight == task { inFlight = nil }
        lock.unlock()
    }

    private func tracked() -> Task<ChatResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    /// FoundationModels honors only temperature and the token cap; the
    /// remaining sampling fields are refused explicitly rather than
    /// silently ignored. Tool surface refusal also lives here so a doomed
    /// request fails before it occupies a queue slot.
    public func validate(_ request: ChatRequest, profile: ModelProfile) throws {
        if request.topP != nil || request.seed != nil
            || request.presencePenalty != nil || request.frequencyPenalty != nil {
            throw PlatformError(.invalidRequest,
                                detail: "apple route honors only temperature")
        }
        // "none" withholds schemas (matching MLX); any other tool surface
        // has no truthful transcript representation on this route.
        if request.toolChoice != .none, !request.tools.isEmpty {
            throw PlatformError(.invalidRequest,
                                detail: "apple provider does not accept tools")
        }
        if request.messages.contains(where: {
            $0.role == .tool || !$0.toolCalls.isEmpty
        }) {
            throw PlatformError(.invalidRequest,
                                detail: "tool messages and calls are not expressible")
        }
    }

    public func complete(_ request: ChatRequest, profile: ModelProfile) async throws -> ChatResult {
        #if canImport(FoundationModels)
        try Task.checkCancellation()
        guard AppleModelAvailability.status() == .available else {
            throw PlatformError(.providerUnavailable, detail: "apple foundation model unavailable")
        }
        // Tool declarations the caller asked to use have no truthful
        // transcript representation here; refuse rather than silently
        // generate tool-agnostic text. "none" is honored by withholding.
        if request.toolChoice != .none, !request.tools.isEmpty {
            throw PlatformError(.invalidRequest,
                                detail: "apple provider does not accept tools")
        }
        let mapped = try Self.map(request)
        let task = Task<ChatResult, Error> {
            let session = LanguageModelSession(transcript: mapped.transcript)
            let response = try await session.respond(to: mapped.prompt, options: mapped.options)
            let input = response.usage.input.totalTokenCount
            let output = response.usage.output.totalTokenCount
            let usage = ChatUsage(promptTokens: input, completionTokens: output,
                                  totalTokens: input + output)
            let finish: FinishReason = output >= request.maxOutputTokens ? .length : .stop
            return ChatResult(modelIdentity: AppleFoundationProvider.id, content: response.content,
                              finishReason: finish, usage: usage)
        }
        track(task)
        defer { untrack(task) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        #else
        throw PlatformError(.providerUnavailable, detail: "FoundationModels framework absent")
        #endif
    }

    public func cancel(jobID: String) async {
        tracked()?.cancel()
    }

    #if canImport(FoundationModels)
    /// Maps a validated request to transcript + final prompt + options.
    /// Refuses assistant-final transcripts and empty final user turns rather
    /// than inventing a prompt.
    static func map(_ request: ChatRequest) throws -> (transcript: Transcript,
                                                       prompt: Prompt,
                                                       options: GenerationOptions) {
        var entries: [Transcript.Entry] = []
        var instructions: [String] = []
        var promptText: String?
        let last = request.messages.count - 1
        for (index, message) in request.messages.enumerated() {
            let text = message.combinedText
            switch message.role {
            case .system, .developer:
                if !text.isEmpty { instructions.append(text) }
            case .user:
                if index == last {
                    promptText = text
                } else {
                    entries.append(.prompt(Transcript.Prompt(
                        segments: [.text(.init(content: text))])))
                }
            case .assistant:
                guard index != last else {
                    throw PlatformError(.invalidRequest,
                                        detail: "final message must be a user turn")
                }
                guard message.toolCalls.isEmpty else {
                    throw PlatformError(.invalidRequest,
                                        detail: "assistant tool calls are not expressible")
                }
                entries.append(.response(Transcript.Response(
                    assetIDs: [], segments: [.text(.init(content: text))])))
            case .tool:
                throw PlatformError(.invalidRequest,
                                    detail: "tool messages are not expressible")
            }
        }
        // Response-format guidance is appended to the instruction text so
        // the shared prompt is honored; it is a best-effort hint, never a
        // schema guarantee.
        if let format = request.responseFormat {
            instructions.append(try format.guidance())
        }
        guard let promptText,
              !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlatformError(.invalidRequest,
                                detail: "final user message required")
        }
        if !instructions.isEmpty {
            entries.insert(.instructions(Transcript.Instructions(
                segments: [.text(.init(content: instructions.joined(separator: "\n")))],
                toolDefinitions: [])), at: 0)
        }
        let options = GenerationOptions(temperature: request.temperature,
                                        maximumResponseTokens: request.maxOutputTokens)
        return (Transcript(entries: entries), Prompt(promptText), options)
    }
    #endif
}
