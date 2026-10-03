import Foundation

/// One validated registry entry: a profile plus the executable route for it.
public struct RegistryEntry: Sendable {
    public let profile: ModelProfile
    public let mlPredictor: (any MLPredictor)?
}

/// Validates registry.json model declarations. The file is bounded data, so
/// every key is checked explicitly; a malformed registry fails startup loudly
/// rather than silently registering a different model than the owner wrote.
/// Only `builtin.linear` typed-ML entries are loadable from JSON; LLM routes
/// are registered in code behind their own opt-ins.
public enum ModelRegistry {
    private static let topKeys: Set<String> = ["schemaVersion", "models"]
    private static let modelKeys: Set<String> = [
        "alias", "kind", "task", "provider", "purposes", "capabilities",
        "inputSchema", "outputSchema", "maxInputBytes", "linear",
    ]

    public static func parse(_ root: JSONValue) throws -> [RegistryEntry] {
        guard let object = root.objectValue else {
            throw PlatformError(.invalidRequest, detail: "registry malformed")
        }
        for key in object.keys where !topKeys.contains(key) {
            throw PlatformError(.invalidRequest, detail: "unknown registry key: \(key)")
        }
        if let version = object["schemaVersion"]?.intValue {
            guard version == 1 else { throw PlatformError(.versionUnsupported) }
        }
        guard let models = object["models"]?.arrayValue else {
            throw PlatformError(.invalidRequest, detail: "registry models missing")
        }
        var entries: [RegistryEntry] = []
        var aliases: Set<String> = []
        for value in models {
            let entry = try parseEntry(value)
            guard aliases.insert(entry.profile.alias).inserted else {
                throw PlatformError(.invalidRequest, detail: "duplicate alias: \(entry.profile.alias)")
            }
            entries.append(entry)
        }
        return entries
    }

    private static func parseEntry(_ value: JSONValue) throws -> RegistryEntry {
        guard let object = value.objectValue else {
            throw PlatformError(.invalidRequest, detail: "registry entry malformed")
        }
        for key in object.keys where !modelKeys.contains(key) {
            throw PlatformError(.invalidRequest, detail: "unknown model key: \(key)")
        }
        guard let alias = object["alias"]?.stringValue, !alias.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "model alias required")
        }
        guard object["kind"]?.stringValue == "ml" else {
            throw PlatformError(.invalidRequest, detail: "only ml registry models supported")
        }
        guard object["provider"]?.stringValue == LinearPredictor.id else {
            throw PlatformError(.invalidRequest, detail: "unknown model provider")
        }
        guard object["task"]?.stringValue == "classification" else {
            throw PlatformError(.invalidRequest, detail: "linear models require task classification")
        }
        let inputSchema = try schema(object["inputSchema"], numeric: true)
        let outputSchema = try schema(object["outputSchema"], numeric: false)
        guard outputSchema == ["label": .string, "confidence": .number] else {
            throw PlatformError(.invalidRequest,
                                detail: "linear output schema must be {label: string, confidence: number}")
        }
        let spec = try parseLinear(object["linear"], inputSchema: inputSchema)
        let purposes = try strings(object["purposes"], field: "purposes")
        let capabilities = try strings(object["capabilities"], field: "capabilities")
        var maxInputBytes: Int?
        if let raw = object["maxInputBytes"]?.intValue {
            guard raw > 0, raw <= Int64(PlatformLimits.requestBodyBytes) else {
                throw PlatformError(.invalidRequest, detail: "maxInputBytes out of bounds")
            }
            maxInputBytes = Int(raw)
        }
        let profile = ModelProfile(
            alias: alias, providerID: LinearPredictor.id,
            kind: .ml, task: "classification", purposes: purposes,
            inputSchema: inputSchema, outputSchema: outputSchema,
            capabilities: capabilities, maxInputBytes: maxInputBytes)
        return RegistryEntry(profile: profile, mlPredictor: LinearPredictor(spec: spec))
    }

    /// Strict flat schema; for linear models every feature must be numeric.
    private static func schema(_ value: JSONValue?, numeric: Bool) throws -> [String: FeatureType] {
        guard let object = value?.objectValue, !object.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "schema required")
        }
        var result: [String: FeatureType] = [:]
        for (name, raw) in object {
            guard let type = FeatureType(rawValue: raw.stringValue ?? "") else {
                throw PlatformError(.invalidRequest, detail: "unknown feature type")
            }
            if numeric, type != .number {
                throw PlatformError(.invalidRequest, detail: "linear features must be numbers")
            }
            result[name] = type
        }
        return result
    }

    private static func parseLinear(_ value: JSONValue?, inputSchema: [String: FeatureType]) throws -> LinearModelSpec {
        guard let object = value?.objectValue else {
            throw PlatformError(.invalidRequest, detail: "linear spec required")
        }
        for key in object.keys where !["features", "labels", "weights", "bias"].contains(key) {
            throw PlatformError(.invalidRequest, detail: "unknown linear key: \(key)")
        }
        let features = try strings(object["features"], field: "features")
        guard !features.isEmpty, Set(features).count == features.count else {
            throw PlatformError(.invalidRequest, detail: "features must be unique")
        }
        guard Set(features) == Set(inputSchema.keys) else {
            throw PlatformError(.invalidRequest, detail: "features must match input schema")
        }
        let labels = try strings(object["labels"], field: "labels")
        guard !labels.isEmpty, Set(labels).count == labels.count else {
            throw PlatformError(.invalidRequest, detail: "labels must be unique")
        }
        guard let weightRows = object["weights"]?.arrayValue,
              weightRows.count == labels.count else {
            throw PlatformError(.invalidRequest, detail: "weights must have one row per label")
        }
        var weights: [[Double]] = []
        for row in weightRows {
            guard let cells = row.arrayValue, cells.count == features.count else {
                throw PlatformError(.invalidRequest, detail: "weight row must match feature count")
            }
            weights.append(try cells.map { try number($0) })
        }
        let bias = try (object["bias"]?.arrayValue ?? []).map { try number($0) }
        guard bias.isEmpty || bias.count == labels.count else {
            throw PlatformError(.invalidRequest, detail: "bias must have one value per label")
        }
        return LinearModelSpec(features: features, labels: labels,
                               weights: weights,
                               bias: bias.isEmpty ? [Double](repeating: 0, count: labels.count) : bias)
    }

    private static func number(_ value: JSONValue) throws -> Double {
        switch value {
        case .int(let i): return Double(i)
        case .double(let d) where d.isFinite: return d
        default: throw PlatformError(.invalidRequest, detail: "weight must be a finite number")
        }
    }

    private static func strings(_ value: JSONValue?, field: String) throws -> [String] {
        guard let value else { return [] }
        guard let items = value.arrayValue else {
            throw PlatformError(.invalidRequest, detail: "\(field) must be an array")
        }
        return try items.map {
            guard let s = $0.stringValue, !s.isEmpty else {
                throw PlatformError(.invalidRequest, detail: "\(field) entries must be strings")
            }
            return s
        }
    }
}
