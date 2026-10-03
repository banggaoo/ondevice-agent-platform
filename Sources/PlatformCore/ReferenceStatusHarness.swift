import Foundation

/// Compiled-in, deterministic, read-only reference agent. Understands exactly
/// one text command, `status`; every other instruction is refused without
/// inference or side effects. Not the Operator.
public struct ReferenceStatusHarness: AgentHarness {
    public static let id = "reference.status"
    public static let version = 1

    public init() {}

    public func run(input: [PromptBlock], context: AgentContext,
                    emit: @escaping @Sendable (AgentEvent) -> Void) async -> AgentStopReason {
        var texts: [String] = []
        for block in input {
            switch block {
            case .text(let t): texts.append(t)
            case .resourceLink: continue   // accepted metadata; never fetched
            }
        }
        let instruction = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard instruction == "status" else {
            emit(.messageChunk("Unsupported instruction. This agent only answers \"status\"."))
            return .refusal
        }
        if context.isCancelled() { return .cancelled }
        let snapshot = await context.statusSnapshot()
        let thermal = snapshot.objectValue?["resource"]?.objectValue?["thermal"]?.stringValue ?? "unknown"
        let pressure = snapshot.objectValue?["resource"]?.objectValue?["memoryPressure"]?.stringValue ?? "unknown"
        let active = snapshot.objectValue?["counts"]?.objectValue?["activeInference"]?.intValue ?? 0
        let pending = snapshot.objectValue?["counts"]?.objectValue?["pendingInference"]?.intValue ?? 0
        let apple = snapshot.objectValue?["appleAvailability"]?.stringValue ?? "unknown"
        let message = "Platform status: thermal=\(thermal) pressure=\(pressure) "
            + "active=\(active) pending=\(pending) appleAvailability=\(apple)."
        emit(.messageChunk(message))
        return .endTurn
    }
}
