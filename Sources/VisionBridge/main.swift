import Foundation
import ImageIO
import Vision

/// oap-vision-bridge: native OCR helper for the Python vision-hybrid
/// route (the Vision framework has no Python binding). Reads one JSON
/// OCR request per stdin line and writes one JSON result per stdout
/// line. Wire contract (kept in sync with
/// python/src/ondevice_agent_platform/providers/vision_hybrid.py):
///
///   in : {"image":"<base64 image bytes>"}
///   out: {"lines":[{"text":"...","confidence":0.98,
///                   "position":[{"x":..,"y":..} x4 pixel TL,TR,BR,BL]}]}
///        or {"error":"...","code":"invalid_request|provider_unavailable"}
///
/// One line in, one line out; the Python provider serializes calls on
/// its io lock so requests never overlap.

struct BridgeError: Error, CustomStringConvertible {
    let code: String
    let message: String
    var description: String { message }
}

func writeLine(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object),
       let line = String(data: data, encoding: .utf8) {
        FileHandle.standardOutput.write(
            (line + "\n").data(using: .utf8)!)
    }
}

func fail(_ error: BridgeError) {
    writeLine(["error": error.message, "code": error.code])
}

func handle(_ payload: [String: Any]) throws -> [String: Any] {
    guard let encoded = payload["image"] as? String,
          let data = Data(base64Encoded: encoded) else {
        throw BridgeError(code: "invalid_request",
                          message: "image required (base64)")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [String: Any],
          let width = (props[kCGImagePropertyPixelWidth as String]
            as? NSNumber)?.doubleValue,
          let height = (props[kCGImagePropertyPixelHeight as String]
            as? NSNumber)?.doubleValue else {
        throw BridgeError(code: "invalid_request",
                          message: "image dimensions not decodable")
    }
    // Vision bounding boxes are normalized with a bottom-left origin;
    // emit pixel-space vertices in boundingPoly order TL,TR,BR,BL.
    func vertices(_ box: CGRect) -> [[String: Int]] {
        let x0 = Int((box.origin.x * width).rounded())
        let x1 = Int(((box.origin.x + box.size.width) * width).rounded())
        let top = Int(((1.0 - box.origin.y - box.size.height)
            * height).rounded())
        let bot = Int(((1.0 - box.origin.y) * height).rounded())
        return [["x": x0, "y": top], ["x": x1, "y": top],
                ["x": x1, "y": bot], ["x": x0, "y": bot]]
    }
    var lines: [[String: Any]] = []
    let request = VNRecognizeTextRequest { request, _ in
        for observation in
                (request.results as? [VNRecognizedTextObservation]) ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { continue }
            lines.append(["text": candidate.string,
                          "confidence": Double(candidate.confidence),
                          "position": vertices(observation.boundingBox)])
        }
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(data: data, options: [:])
    do {
        try handler.perform([request])
    } catch {
        throw BridgeError(code: "invalid_request",
                          message: "image not decodable: \(error)")
    }
    return ["lines": lines]
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
        do {
            guard let payload = try JSONSerialization
                .jsonObject(with: line) as? [String: Any] else {
                throw BridgeError(code: "invalid_request",
                                  message: "request must be a JSON object")
            }
            writeLine(try handle(payload))
        } catch let e as BridgeError {
            fail(e)
        } catch {
            fail(BridgeError(code: "provider_unavailable",
                             message: "\(error)"))
        }
    }
}
exit(0)
