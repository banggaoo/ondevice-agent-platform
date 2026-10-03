import Foundation

/// Bounded single-completion reference agent: forwards the prompt text to
/// the scoped model client exactly once, emits the reply, and stops. It
/// demonstrates the hosted-agent model path the optional Operator will use -
/// no loops, no tools, no extra authority. Not the Operator.
public struct ReferenceEchoHarness: AgentHarness {
    public static let id = "reference.echo"
    public static let version = 1
    private static let maxOutputTokens = 256

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
        let prompt = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            emit(.messageChunk("No text to forward."))
            return .refusal
        }
        if context.isCancelled() { return .cancelled }
        do {
            let result = try await context.model.complete(ChatRequest(
                model: modelAlias,
                messages: [ChatMessage(role: .user, parts: [prompt])],
                maxOutputTokens: Self.maxOutputTokens))
            if context.isCancelled() { return .cancelled }
            emit(.messageChunk(result.content))
            return .endTurn
        } catch let error as PlatformError {
            emit(.messageChunk("model unavailable: \(error.safeMessage)"))
            return .error
        } catch {
            emit(.messageChunk("model error"))
            return .error
        }
    }
}
