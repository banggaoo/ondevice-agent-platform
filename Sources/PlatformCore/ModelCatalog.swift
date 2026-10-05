import Foundation

/// One curated model choice offered by `setup`. The catalog is code-owned:
/// sources are pinned repo/revision pairs the owner can review, and selecting
/// an entry declares it in registry.json - it never pulls by itself.
public struct CatalogModel: Sendable {
    public let alias: String
    public let summary: String
    public let purposes: [String]
    public let capabilities: [String]
    public let maxOutputTokens: Int
    public let approxBytes: Int64
    public let source: ModelSource

    /// Registry entry payload matching ModelRegistry's llm schema.
    public var registryValue: JSONValue {
        .object([
            "alias": .string(alias),
            "kind": .string("llm"),
            "provider": .string(MLXProviderContract.id),
            "task": .string("chat"),
            "purposes": .array(purposes.map { .string($0) }),
            "capabilities": .array(capabilities.map { .string($0) }),
            "maxOutputTokens": .int(Int64(maxOutputTokens)),
            "source": .object([
                "repo": .string(source.repo),
                "revision": .string(source.revision),
            ]),
        ])
    }
}

/// Curated, code-owned model choices. Every entry is a route verified live on
/// the development host; sizes are approximate pull sizes for display only.
public enum ModelCatalog {
    public static let entries: [CatalogModel] = [
        CatalogModel(
            alias: "qwen3.8-9b",
            summary: "text reasoning, coding, tool-capable (Qwen3.8-9B-Distill, 4-bit MLX)",
            purposes: ["reasoning", "coding", "runtime-explanation"],
            capabilities: ["text"],
            maxOutputTokens: 4096,
            approxBytes: 5_400_000_000,
            source: ModelSource(
                repo: "nvythong/Qwen3.8-9B-Distill-mlx-4Bit",
                revision: "e827c31fbd588828f43180a87ab34415a6d8a4bf")),
        CatalogModel(
            alias: "qwen-vl",
            summary: "vision + text (Qwen3-VL-2B-Instruct, 4-bit MLX)",
            purposes: ["vision"],
            capabilities: ["text", "vision"],
            maxOutputTokens: 1024,
            approxBytes: 1_800_000_000,
            source: ModelSource(
                repo: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
                revision: "main")),
    ]

    public static func entry(alias: String) -> CatalogModel? {
        entries.first { $0.alias == alias }
    }

    /// Merge selected catalog entries into the existing registry payload.
    /// Same-alias entries are replaced; every other declaration (including
    /// typed-ML entries) is preserved. The merged result is re-validated
    /// through ModelRegistry.parse before callers persist it.
    public static func mergedRegistry(existing: JSONValue?,
                                      selection: [CatalogModel]) throws -> JSONValue {
        var models: [JSONValue] = []
        if let object = existing?.objectValue {
            for key in object.keys where !["schemaVersion", "models"].contains(key) {
                throw PlatformError(.invalidRequest, detail: "unknown registry key: \(key)")
            }
            if let declared = object["models"] {
                guard let array = declared.arrayValue else {
                    throw PlatformError(.invalidRequest, detail: "registry models malformed")
                }
                models = array
            }
        } else if existing != nil {
            throw PlatformError(.invalidRequest, detail: "registry malformed")
        }
        let selected = Set(selection.map { $0.alias })
        models.removeAll { value in
            guard let alias = value.objectValue?["alias"]?.stringValue else { return false }
            return selected.contains(alias)
        }
        models.append(contentsOf: selection.map { $0.registryValue })
        let merged = JSONValue.object([
            "schemaVersion": .int(1),
            "models": .array(models),
        ])
        _ = try ModelRegistry.parse(merged)
        return merged
    }
}
