import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// Registry-declared open-weight LLM routes: strict source validation and
/// truthful profile shape. The artifact itself is never loaded here - the
/// registry declares intent; `model pull` materializes it.
final class LLMRegistryTests: XCTestCase {

    private func registry(_ models: [JSONValue]) -> JSONValue {
        .object(["schemaVersion": .int(1), "models": .array(models)])
    }

    private func entry(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "alias": .string("qwen-small"),
            "kind": .string("llm"),
            "provider": .string("mlx"),
            "task": .string("chat"),
            "purposes": .array([.string("reasoning")]),
            "capabilities": .array([.string("text")]),
            "source": .object([
                "repo": .string("mlx-community/Qwen3-0.6B-4bit"),
                "revision": .string("main"),
            ]),
        ]
        object.merge(extra) { _, new in new }
        return .object(object)
    }

    func testLLMEntryParses() throws {
        let entries = try ModelRegistry.parse(registry([entry()]))
        XCTAssertEqual(entries.count, 1)
        let profile = entries[0].profile
        XCTAssertEqual(profile.alias, "qwen-small")
        XCTAssertEqual(profile.providerID, "mlx")
        XCTAssertEqual(profile.kind, .llm)
        XCTAssertEqual(profile.task, "chat")
        XCTAssertEqual(profile.purposes, ["reasoning"])
        XCTAssertEqual(profile.source,
                       ModelSource(repo: "mlx-community/Qwen3-0.6B-4bit", revision: "main"))
        XCTAssertNil(entries[0].mlPredictor)
    }

    func testLLMEntryRequiresSource() {
        let malformed = entry(["source": .null])
            .mergingJSONObject(["source": nil])
        XCTAssertThrowsError(try ModelRegistry.parse(registry([malformed]))) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .invalidRequest)
        }
    }

    func testLLMEntryRejectsUnknownProvider() {
        XCTAssertThrowsError(try ModelRegistry.parse(registry([entry(["provider": .string("ollama")])])))
    }

    func testLLMEntryRejectsTraversalSource() {
        for repo in ["../escape", "a/b/c", "a//b", ".hidden/x", "no-slash"] {
            let bad = entry(["source": .object([
                "repo": .string(repo), "revision": .string("main")])])
            XCTAssertThrowsError(try ModelRegistry.parse(registry([bad])),
                                 "repo \(repo) must be rejected")
        }
    }

    func testLLMEntryRejectsBadRevision() {
        for rev in ["", "../x", "rev with space", "-weird/"] {
            let bad = entry(["source": .object([
                "repo": .string("mlx-community/Qwen3-0.6B-4bit"),
                "revision": .string(rev)])])
            XCTAssertThrowsError(try ModelRegistry.parse(registry([bad])),
                                 "revision \(rev) must be rejected")
        }
    }

    func testLLMEntryRejectsLinearKeys() {
        XCTAssertThrowsError(try ModelRegistry.parse(registry([
            entry(["linear": .object([:])])])))
        XCTAssertThrowsError(try ModelRegistry.parse(registry([
            entry(["inputSchema": .object(["x": .string("number")])])])))
    }

    func testLinearEntryRejectsLLMKeys() {
        let ml = JSONValue.object([
            "alias": .string("triage"), "kind": .string("ml"),
            "task": .string("classification"), "provider": .string("builtin.linear"),
            "inputSchema": .object(["x": .string("number")]),
            "outputSchema": .object(["label": .string("string"), "confidence": .string("number")]),
            "linear": .object([
                "features": .array([.string("x")]),
                "labels": .array([.string("pos")]),
                "weights": .array([.array([.double(1.0)])]),
            ]),
            "source": .object(["repo": .string("a/b"), "revision": .string("main")]),
        ])
        XCTAssertThrowsError(try ModelRegistry.parse(registry([ml])))
    }

    func testLLMEntryBoundsOutputTokens() {
        let ok = try? ModelRegistry.parse(registry([entry(["maxOutputTokens": .int(2048)])]))
        XCTAssertEqual(ok?.first?.profile.maxOutputTokens, 2048)
        XCTAssertThrowsError(try ModelRegistry.parse(registry([
            entry(["maxOutputTokens": .int(0)])])))
        XCTAssertThrowsError(try ModelRegistry.parse(registry([
            entry(["maxOutputTokens": .int(100_000)])])))
    }

    func testDuplicateAliasAcrossKindsRejected() {
        let second = entry(["provider": .string("builtin.linear"), "kind": .string("ml")])
        XCTAssertThrowsError(try ModelRegistry.parse(registry([entry(), second])))
    }

    func testCategoryReflectsMLXRoute() async throws {
        let stack = try await makeStack()
        let supervisor = stack.supervisor
        var snapshot = await supervisor.statusSnapshot()
        XCTAssertEqual(snapshot.objectValue?["categories"]?.objectValue?["ownedOpenWeight"],
                       .string("notConfigured"))
        let store = ModelStoreProbe.empty()
        let provider = ProbeMLXProvider(store: store)
        await supervisor.registerModel(
            ModelProfile(alias: "qwen-small", providerID: MLXProviderContract.id,
                         kind: .llm, task: "chat",
                         source: ModelSource(repo: "a/b", revision: "main")),
            provider: provider)
        snapshot = await supervisor.statusSnapshot()
        XCTAssertEqual(snapshot.objectValue?["categories"]?.objectValue?["ownedOpenWeight"],
                       .string("observing"))
        store.ready = true
        snapshot = await supervisor.statusSnapshot()
        XCTAssertEqual(snapshot.objectValue?["categories"]?.objectValue?["ownedOpenWeight"],
                       .string("qualified"))
    }
}

/// Minimal ProviderReadiness stand-in: the category check must reflect the
/// store's actual artifact state, not the provider's presence alone.
private final class ProbeMLXProvider: LLMProvider, ProviderReadiness, @unchecked Sendable {
    let store: ModelStoreProbe
    let providerID = MLXProviderContract.id
    init(store: ModelStoreProbe) { self.store = store }
    var hasReadyArtifact: Bool { store.ready }
    func complete(_ request: ChatRequest, profile: ModelProfile) async throws -> ChatResult {
        throw PlatformError(.providerUnavailable)
    }
}

private final class ModelStoreProbe: @unchecked Sendable {
    var ready = false
    static func empty() -> ModelStoreProbe { ModelStoreProbe() }
}

private extension JSONValue {
    /// Removes a key when the value is nil; merges otherwise.
    func mergingJSONObject(_ patch: [String: JSONValue?]) -> JSONValue {
        guard case .object(var object) = self else { return self }
        for (key, value) in patch {
            if let value { object[key] = value } else { object.removeValue(forKey: key) }
        }
        return .object(object)
    }
}
