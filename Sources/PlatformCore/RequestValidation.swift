import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared request bounds enforced inside the core before admission, so no
/// entry path (HTTP adapter, ACP bridge, harness model client) can bypass
/// them. The HTTP adapter keeps its own early checks; this is the layer of
/// record. Profile limits are additional bounds and never relax globals.
public enum RequestValidation {
    private static let imageTypes: [String: UTType] = [
        "image/jpeg": .jpeg,
        "image/png": .png,
        "image/webp": .webP,
    ]

    public static func chat(_ request: ChatRequest, profile: ModelProfile) throws {
        let request = request.resolvingDefaultOutputTokens(to: profile.maxOutputTokens)
        guard !request.messages.isEmpty,
              request.messages.count <= PlatformLimits.chatMessages else {
            throw PlatformError(.invalidRequest, detail: "message count out of range")
        }
        let tokenCap = min(PlatformLimits.outputTokens, profile.maxOutputTokens ?? .max)
        guard request.maxOutputTokens > 0, request.maxOutputTokens <= tokenCap else {
            throw PlatformError(.invalidRequest, detail: "max output tokens out of range")
        }
        try bounded(request.temperature, 0...2, "temperature")
        try bounded(request.topP, 0...1, "top_p")
        try bounded(request.presencePenalty, -2...2, "presence_penalty")
        try bounded(request.frequencyPenalty, -2...2, "frequency_penalty")
        if let seed = request.seed, seed > UInt64(Int64.max) {
            throw PlatformError(.invalidRequest, detail: "seed out of range")
        }

        var textBytes = 0
        var imageBytes = 0
        var imageCount = 0
        var totalPixels = 0
        /// Count and total byte caps are enforced in a full pass before any
        /// ImageIO work below, so an oversized batch never reaches a decoder.
        for message in request.messages {
            for image in message.images {
                guard message.role == .user else {
                    throw PlatformError(.invalidRequest,
                                        detail: "images only allowed on user messages")
                }
                guard profile.capabilities.contains("vision") else {
                    throw PlatformError(.invalidRequest,
                                        detail: "model does not accept image input")
                }
                imageCount += 1
                imageBytes += image.data.count
            }
        }
        guard imageCount <= PlatformLimits.chatImagesPerRequest,
              imageBytes <= PlatformLimits.chatImageBytes else {
            throw PlatformError(.payloadTooLarge, detail: "image limits exceeded")
        }
        /// Tool result turns must answer a call an assistant turn made
        /// earlier in the same request; every declared id is unique and an
        /// answered call leaves the outstanding set, so each call is
        /// answered at most once and ids are never invented here.
        var declaredCallIDs = Set<String>()
        var unansweredCallIDs = Set<String>()
        for message in request.messages {
            // A user turn while tool calls are still unanswered is an
            // unrelated generation request, not a tool continuation.
            if message.role == .user, !unansweredCallIDs.isEmpty {
                throw PlatformError(.invalidRequest,
                                    detail: "tool calls unanswered before user turn")
            }
            let hasText = message.parts.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard hasText || !message.images.isEmpty || !message.toolCalls.isEmpty else {
                throw PlatformError(.invalidRequest, detail: "message has no content")
            }
            if !message.toolCalls.isEmpty {
                guard message.role == .assistant else {
                    throw PlatformError(.invalidRequest,
                                        detail: "tool_calls only allowed on assistant messages")
                }
                guard message.toolCalls.count <= PlatformLimits.chatToolCallsPerMessage else {
                    throw PlatformError(.payloadTooLarge, detail: "tool call count exceeded")
                }
            }
            if let id = message.toolCallID {
                guard message.role == .tool else {
                    throw PlatformError(.invalidRequest,
                                        detail: "tool_call_id only allowed on tool messages")
                }
                guard !id.isEmpty, id.utf8.count <= 128 else {
                    throw PlatformError(.invalidRequest, detail: "tool_call_id out of range")
                }
                // The id must answer a still-open call; consuming it means
                // a second tool message for the same call is rejected.
                guard unansweredCallIDs.remove(id) != nil else {
                    throw PlatformError(.invalidRequest,
                                        detail: "tool_call_id has no matching tool call")
                }
            } else if message.role == .tool {
                throw PlatformError(.invalidRequest,
                                    detail: "tool message requires tool_call_id")
            }
            for part in message.parts { textBytes += part.utf8.count }
            for call in message.toolCalls {
                try validateToolCall(call)
                // Tool-call payloads count toward the same text budget the
                // adapter applies at the HTTP boundary.
                textBytes += (call.id?.utf8.count ?? 0) + call.name.utf8.count
                textBytes += try encodedCount(call.arguments, "tool arguments")
                let id = call.id!   // validateToolCall requires non-nil
                guard declaredCallIDs.insert(id).inserted else {
                    throw PlatformError(.invalidRequest,
                                        detail: "duplicate tool call id")
                }
                unansweredCallIDs.insert(id)
            }
            for image in message.images {
                let pixels = try validatedPixels(image)
                let (sum, overflow) = totalPixels.addingReportingOverflow(pixels)
                guard !overflow else {
                    throw PlatformError(.payloadTooLarge,
                                        detail: "image pixel limit exceeded")
                }
                totalPixels = sum
            }
        }
        guard totalPixels <= PlatformLimits.chatImagePixels else {
            throw PlatformError(.payloadTooLarge, detail: "image limits exceeded")
        }
        // A request must end on a turn the model can answer: a user message,
        // or a tool result that leaves no earlier call unanswered. Trailing
        // assistant/system/developer turns are refused before admission.
        switch request.messages.last?.role {
        case .user?: break
        case .tool?:
            guard unansweredCallIDs.isEmpty else {
                throw PlatformError(.invalidRequest,
                                    detail: "unanswered tool calls remain")
            }
        default:
            throw PlatformError(.invalidRequest,
                                detail: "final message must be a user or tool turn")
        }

        guard request.tools.count <= PlatformLimits.chatTools else {
            throw PlatformError(.payloadTooLarge, detail: "tool count exceeded")
        }
        var toolNames = Set<String>()
        for tool in request.tools {
            try validateToolName(tool.name)
            guard toolNames.insert(tool.name).inserted else {
                throw PlatformError(.invalidRequest, detail: "duplicate tool name")
            }
            textBytes += tool.name.utf8.count + (tool.description?.utf8.count ?? 0)
            if let params = tool.parameters {
                guard params.objectValue != nil else {
                    throw PlatformError(.invalidRequest,
                                        detail: "tool schema must be an object")
                }
                textBytes += try encodedCount(params, "tool schema")
            }
        }
        if case .named(let name) = request.toolChoice {
            try validateToolName(name)
            guard toolNames.contains(name) else {
                throw PlatformError(.invalidRequest,
                                    detail: "tool_choice names an undeclared tool")
            }
        }
        if let format = request.responseFormat {
            let guidance: String
            do { guidance = try format.guidance() } catch {
                throw PlatformError(.invalidRequest, detail: "invalid response format")
            }
            textBytes += guidance.utf8.count
        }
        guard textBytes <= PlatformLimits.chatTextBytes else {
            throw PlatformError(.payloadTooLarge, detail: "text limit exceeded")
        }
        if let cap = profile.maxInputBytes, textBytes + imageBytes > cap {
            throw PlatformError(.payloadTooLarge, detail: "model input limit exceeded")
        }
    }

    public static func prediction(_ request: PredictionRequest, profile: ModelProfile) throws {
        guard let encoded = try? JSONValue.object(request.inputs).encoded() else {
            throw PlatformError(.invalidRequest, detail: "inputs not encodable")
        }
        let cap = min(PlatformLimits.mlInputBytes, profile.maxInputBytes ?? .max)
        guard encoded.count <= cap else {
            throw PlatformError(.payloadTooLarge, detail: "ml input limit exceeded")
        }
    }

    /// Per-image bounds checked before the multiply so dimension overflow
    /// cannot occur; callers accumulate totals with checked arithmetic.
    static func imagePixels(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0,
              width <= PlatformLimits.chatImageDimension,
              height <= PlatformLimits.chatImageDimension else {
            throw PlatformError(.payloadTooLarge, detail: "image dimensions out of range")
        }
        let pixels = width * height
        guard pixels <= PlatformLimits.chatImagePixels else {
            throw PlatformError(.payloadTooLarge, detail: "image pixel limit exceeded")
        }
        return pixels
    }

    /// Header-only inspection through ImageIO: declared MIME must match the
    /// container format, exactly one frame, and bounded dimensions. No
    /// pixel decode and no image cache.
    private static func validatedPixels(_ image: ChatImage) throws -> Int {
        guard let expected = imageTypes[image.mediaType] else {
            throw PlatformError(.invalidRequest, detail: "unsupported image media type")
        }
        guard let source = CGImageSourceCreateWithData(
                image.data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else {
            throw PlatformError(.invalidRequest, detail: "not a single-frame image")
        }
        guard let uti = CGImageSourceGetType(source) as String?,
              let actual = UTType(uti), actual.conforms(to: expected) else {
            throw PlatformError(.invalidRequest,
                                detail: "image format does not match declared type")
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw PlatformError(.invalidRequest, detail: "image properties unreadable")
        }
        return try imagePixels(width: width, height: height)
    }

    private static func bounded(_ value: Double?, _ range: ClosedRange<Double>,
                                _ field: String) throws {
        guard let value else { return }
        guard value.isFinite, range.contains(value) else {
            throw PlatformError(.invalidRequest, detail: "\(field) out of range")
        }
    }

    /// Function/tool names follow the OpenAI identifier contract: ASCII
    /// letters, digits, `-` and `_`, 1...64 characters.
    private static func validateToolName(_ name: String) throws {
        guard (1...64).contains(name.utf8.count),
              name.utf8.allSatisfy({
                  $0 == 0x2D || $0 == 0x5F
                      || (0x30...0x39).contains($0)
                      || (0x41...0x5A).contains($0)
                      || (0x61...0x7A).contains($0)
              }) else {
            throw PlatformError(.invalidRequest, detail: "invalid tool name")
        }
    }

    private static func validateToolCall(_ call: ChatToolCall) throws {
        // Request-side call history always carries the id the tool result
        // will reference; an id-less call can never be answered.
        guard let id = call.id, !id.isEmpty, id.utf8.count <= 128 else {
            throw PlatformError(.invalidRequest, detail: "tool call id out of range")
        }
        try validateToolName(call.name)
        // Arguments decode as a JSON value; the contract requires an object.
        guard call.arguments.objectValue != nil else {
            throw PlatformError(.invalidRequest,
                                detail: "tool arguments must be an object")
        }
    }

    /// Explicit encode so a nonfinite value inside a schema or argument
    /// object is a clear rejection, never silently zero-counted.
    private static func encodedCount(_ value: JSONValue, _ field: String) throws -> Int {
        do { return try value.encoded().count }
        catch { throw PlatformError(.invalidRequest, detail: "\(field) not encodable") }
    }
}
