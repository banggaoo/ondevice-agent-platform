import Foundation

/// Strict flat feature schema for typed ML requests in M1.
public enum FeatureType: String, Sendable, Codable, CaseIterable {
    case string
    case number
    case boolean
}

public struct PredictionRequest: Sendable, Equatable {
    public let model: String
    public let task: String
    public let inputs: [String: JSONValue]

    public init(model: String, task: String, inputs: [String: JSONValue]) {
        self.model = model
        self.task = task
        self.inputs = inputs
    }
}

/// Typed prediction output. Labels and confidence remain data; they cannot
/// grant scope or be wrapped as chat completions.
public struct PredictionResult: Sendable {
    public let modelIdentity: String
    public let outputs: [String: JSONValue]

    public init(modelIdentity: String, outputs: [String: JSONValue]) {
        self.modelIdentity = modelIdentity
        self.outputs = outputs
    }
}

public enum FeatureValidation {
    public static func matches(_ value: JSONValue, type: FeatureType) -> Bool {
        switch (value, type) {
        case (.string, .string): return true
        case (.bool, .boolean): return true
        case (.int, .number): return true
        case (.double(let d), .number): return d.isFinite
        default: return false
        }
    }

    /// Validates inputs against a strict flat schema: every declared field
    /// required, no extra fields, types exact, numbers finite.
    public static func validate(inputs: [String: JSONValue],
                                schema: [String: FeatureType]) throws {
        for name in schema.keys {
            guard let value = inputs[name] else {
                throw PlatformError(.invalidRequest, detail: "missing feature")
            }
            guard matches(value, type: schema[name]!) else {
                throw PlatformError(.invalidRequest, detail: "feature type mismatch")
            }
        }
        for name in inputs.keys where schema[name] == nil {
            throw PlatformError(.invalidRequest, detail: "unexpected feature")
        }
    }
}
