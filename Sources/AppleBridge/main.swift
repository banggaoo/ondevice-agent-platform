import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// oap-apple-bridge: the only native piece the Python core still needs.
/// Reads one JSON chat request per stdin line and writes one JSON result
/// per stdout line. Wire contract (kept in sync with
/// python/src/ondevice_agent_platform/providers/apple.py):
///
///   in : {"messages":[{"role":"system|developer|user|assistant",
///         "content":"..."}], "maxTokens": int, "temperature": double,
///         "formatGuidance"?: "..."}
///   out: {"content":"...","tokens":int,"finish":"stop|length",
///         "model":"apple-foundation-models"}
///        or {"error":"...","code":"invalid_request|provider_unavailable"}
///
/// Transcript mapping mirrors AppleFoundationProvider.map: system and
/// developer text joins into one leading instructions entry; the final
/// message must be a user turn and becomes the respond(to:) prompt; an
/// assistant-final transcript is refused rather than invented.

struct BridgeError: Error, CustomStringConvertible {
    let code: String
    let message: String
    var description: String { message }
}

func writeLine(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object),
       let line = String(data: data, encoding: .utf8) {
        // FileHandle writes are unbuffered; a pipe cannot be fsync'd.
        FileHandle.standardOutput.write(
            (line + "\n").data(using: .utf8)!)
    }
}

func fail(_ error: BridgeError) {
    writeLine(["error": error.message, "code": error.code])
}

func invalid(_ message: String) -> BridgeError {
    BridgeError(code: "invalid_request", message: message)
}

func handle(_ payload: [String: Any]) async throws -> [String: Any] {
#if canImport(FoundationModels)
    guard SystemLanguageModel.default.availability == .available else {
        throw BridgeError(code: "provider_unavailable",
                          message: "apple foundation model unavailable")
    }
    guard let rawMessages = payload["messages"] as? [[String: Any]],
          !rawMessages.isEmpty else {
        throw invalid("messages required")
    }
    let maxTokens = (payload["maxTokens"] as? Int) ?? 512
    let temperature = (payload["temperature"] as? Double) ?? 0.0
    var entries: [Transcript.Entry] = []
    var instructions: [String] = []
    var promptText: String?
    let last = rawMessages.count - 1
    for (index, raw) in rawMessages.enumerated() {
        guard let role = raw["role"] as? String else {
            throw invalid("message role required")
        }
        let text = (raw["content"] as? String) ?? ""
        switch role {
        case "system", "developer":
            if !text.isEmpty { instructions.append(text) }
        case "user":
            if index == last { promptText = text }
            else {
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(.init(content: text))])))
            }
        case "assistant":
            guard index != last else {
                throw invalid("final message must be a user turn")
            }
            entries.append(.response(Transcript.Response(
                assetIDs: [], segments: [.text(.init(content: text))])))
        default:
            throw invalid("role not expressible: \(role)")
        }
    }
    if let guidance = payload["formatGuidance"] as? String, !guidance.isEmpty {
        instructions.append(guidance)
    }
    guard let promptText,
          !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw invalid("final user message required")
    }
    if !instructions.isEmpty {
        entries.insert(.instructions(Transcript.Instructions(
            segments: [.text(.init(content: instructions.joined(
                separator: "\n")))], toolDefinitions: [])), at: 0)
    }
    let options = GenerationOptions(temperature: temperature,
                                    maximumResponseTokens: maxTokens)
    let session = LanguageModelSession(transcript: Transcript(entries: entries))
    let response = try await session.respond(to: Prompt(promptText),
                                             options: options)
    let tokens = response.usage.output.totalTokenCount
    return ["content": response.content,
            "tokens": tokens,
            "finish": tokens >= maxTokens ? "length" : "stop",
            "model": "apple-foundation-models"]
#else
    throw BridgeError(code: "provider_unavailable",
                      message: "FoundationModels framework absent")
#endif
}

let stdin = FileHandle.standardInput
var buffer = Data()
while true {
    // availableData returns as soon as bytes arrive (read(upToCount:)
    // would wait for the full count or EOF - that hangs a live pipe).
    let chunk = stdin.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)
    while let nl = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: 0..<nl)
        buffer.removeSubrange(0...nl)
        guard !line.isEmpty else { continue }
        // The Python provider serializes calls on its lock, so requests
        // never overlap; a plain await keeps one-line-in, one-line-out.
        do {
            guard let payload = try JSONSerialization
                .jsonObject(with: line) as? [String: Any] else {
                throw invalid("request must be a JSON object")
            }
            writeLine(try await handle(payload))
        } catch let e as BridgeError {
            fail(e)
        } catch is CancellationError {
            fail(BridgeError(code: "cancelled", message: "cancelled"))
        } catch {
            fail(BridgeError(code: "provider_unavailable",
                             message: "\(error)"))
        }
    }
}
exit(0)
