import XCTest
@testable import PlatformCore

/// Curated setup catalog: entry validity and registry merge semantics.
final class ModelCatalogTests: XCTestCase {

    func testCatalogEntriesParseThroughRegistry() throws {
        let registry = try ModelCatalog.mergedRegistry(
            existing: nil, selection: ModelCatalog.entries)
        let parsed = try ModelRegistry.parse(registry)
        XCTAssertEqual(parsed.count, ModelCatalog.entries.count)
        for model in ModelCatalog.entries {
            let entry = try XCTUnwrap(parsed.first { $0.profile.alias == model.alias })
            XCTAssertEqual(entry.profile.providerID, MLXProviderContract.id)
            XCTAssertEqual(entry.profile.source, model.source)
            XCTAssertEqual(entry.profile.capabilities, model.capabilities)
            XCTAssertEqual(entry.profile.maxOutputTokens, model.maxOutputTokens)
        }
    }

    func testMergePreservesUnrelatedEntries() throws {
        let existing = JSONValue.object([
            "schemaVersion": .int(1),
            "models": .array([
                .object([
                    "alias": .string("my-linear"),
                    "kind": .string("ml"),
                    "provider": .string(LinearPredictor.id),
                    "task": .string("classification"),
                    "inputSchema": .object(["x": .string("number")]),
                    "outputSchema": .object([
                        "label": .string("string"),
                        "confidence": .string("number"),
                    ]),
                    "linear": .object([
                        "features": .array([.string("x")]),
                        "labels": .array([.string("a"), .string("b")]),
                        "weights": .array([
                            .array([.int(1)]),
                            .array([.int(-1)]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let merged = try ModelCatalog.mergedRegistry(
            existing: existing, selection: [ModelCatalog.entries[0]])
        let parsed = try ModelRegistry.parse(merged)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertNotNil(parsed.first { $0.profile.alias == "my-linear" })
        XCTAssertNotNil(parsed.first { $0.profile.alias == ModelCatalog.entries[0].alias })
    }

    func testMergeReplacesSameAlias() throws {
        let model = ModelCatalog.entries[0]
        let stale = JSONValue.object([
            "schemaVersion": .int(1),
            "models": .array([
                .object([
                    "alias": .string(model.alias),
                    "kind": .string("llm"),
                    "provider": .string(MLXProviderContract.id),
                    "source": .object([
                        "repo": .string("someone/older-repo"),
                        "revision": .string("main"),
                    ]),
                ]),
            ]),
        ])
        let merged = try ModelCatalog.mergedRegistry(
            existing: stale, selection: [model])
        let parsed = try ModelRegistry.parse(merged)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].profile.source, model.source)
    }

    func testEmptySelectionOnEmptyRootProducesValidRegistry() throws {
        let merged = try ModelCatalog.mergedRegistry(existing: nil, selection: [])
        let parsed = try ModelRegistry.parse(merged)
        XCTAssertTrue(parsed.isEmpty)
    }

    func testMalformedExistingRegistryThrows() {
        let bad = JSONValue.object(["models": .string("not-an-array")])
        XCTAssertThrowsError(
            try ModelCatalog.mergedRegistry(existing: bad,
                                            selection: ModelCatalog.entries))
    }
}
