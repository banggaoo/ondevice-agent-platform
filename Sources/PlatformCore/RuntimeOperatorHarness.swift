import Foundation

/// Optional read-only runtime Operator. Explains the platform snapshot and
/// answers runtime questions through exactly one bounded model call: no
/// tools, no administrative authority, no state, no loops. The snapshot and
/// the user text are data, never instructions that grant rights. Registered
/// only behind an explicit opt-in bound to a qualified model alias.
public struct RuntimeOperatorHarness: AgentHarness {
    public static let id = "operator.runtime"
    public static let version = 1
    private static let maxOutputTokens = 512

    private let modelAlias: String

    public init(modelAlias: String) {
        self.modelAlias = modelAlias
    }

    public func run(input: [PromptBlock], context: AgentContext,
                    emit: @escaping @Sendable (AgentEvent) -> Void) async -> AgentStopReason {
        var texts: [String] = []
        for block in input {
            switch block {
            case .text(let t): texts.append(t)
            case .resourceLink: continue   // bounded metadata; never fetched
            }
        }
        let prompt = texts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            emit(.messageChunk("No question to answer."))
            return .refusal
        }
        if context.isCancelled() { return .cancelled }
        do {
            try Task.checkCancellation()
            let snapshot = await context.statusSnapshot()
            try Task.checkCancellation()
            let snapshotText = try OperatorPrompt.snapshotMessage(snapshot)
            if context.isCancelled() { return .cancelled }
            // One scoped model call: instructions, snapshot, user text.
            let result = try await context.model.complete(ChatRequest(
                model: modelAlias,
                messages: [
                    ChatMessage(role: .system, parts: [OperatorPrompt.instructions]),
                    ChatMessage(role: .user, parts: [snapshotText]),
                    ChatMessage(role: .user, parts: [prompt]),
                ],
                maxOutputTokens: Self.maxOutputTokens,
                temperature: 0))
            if context.isCancelled() { return .cancelled }
            try Task.checkCancellation()
            guard result.toolCalls.isEmpty else {
                emit(.messageChunk("Operator cannot execute tool calls. Nothing was applied."))
                return .error
            }
            switch result.finishReason {
            case .contentFilter:
                emit(.messageChunk(result.content.isEmpty
                    ? "Operator response was refused." : result.content))
                return .refusal
            case .error, .toolCalls:
                emit(.messageChunk("Operator model returned an unusable response."))
                return .error
            case .stop, .length:
                break
            }
            guard !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                emit(.messageChunk("Operator model returned no usable text."))
                return .error
            }
            emit(.messageChunk(result.content))
            return result.finishReason == .length ? .maxTokens : .endTurn
        } catch is CancellationError {
            return .cancelled
        } catch let error as PlatformError {
            if error.code == .cancelled { return .cancelled }
            emit(.messageChunk("Operator unavailable: \(error.safeMessage)"))
            return .error
        } catch {
            emit(.messageChunk("Operator error."))
            return .error
        }
    }
}
