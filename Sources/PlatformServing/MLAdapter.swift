import Foundation
import PlatformCore

/// POST /api/ml/predictions: platform-specific typed ML seam, deliberately not
/// an OpenAI endpoint. Strict flat input features; no artifact paths.
public enum MLAdapter {
    static let allowedFields: Set<String> = ["model", "task", "inputs"]

    public static func parseRequest(_ body: Data) throws -> PredictionRequest {
        let root = try JSONValue.decode(body)
        guard let object = root.objectValue else { throw PlatformError(.invalidRequest) }
        for key in object.keys where !allowedFields.contains(key) {
            throw PlatformError(.invalidRequest, detail: "unknown field: \(key)")
        }
        guard let model = object["model"]?.stringValue, !model.isEmpty,
              let task = object["task"]?.stringValue, !task.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "model and task required")
        }
        guard let inputs = object["inputs"]?.objectValue else {
            throw PlatformError(.invalidRequest, detail: "inputs required")
        }
        let size = (try? object["inputs"]?.encoded().count) ?? Int.max
        guard size <= PlatformLimits.mlInputBytes else {
            throw PlatformError(.payloadTooLarge)
        }
        for (name, value) in inputs {
            switch value {
            case .string, .bool, .int: break
            case .double(let d): guard d.isFinite else { throw PlatformError(.invalidRequest) }
            default: throw PlatformError(.invalidRequest, detail: "nested input: \(name)")
            }
        }
        return PredictionRequest(model: model, task: task, inputs: inputs)
    }

    public static func response(_ result: PredictionResult) -> JSONValue {
        .object([
            "model": .string(result.modelIdentity),
            "outputs": .object(result.outputs),
        ])
    }
}
