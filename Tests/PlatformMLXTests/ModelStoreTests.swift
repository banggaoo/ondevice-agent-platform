import XCTest
import PlatformTestSupport
@testable import PlatformMLX
@testable import PlatformCore

/// Store-level artifact governance: manifest validation, staging hygiene,
/// path safety, and readiness reporting. Pull itself is exercised live in
/// MLXLiveTests; these tests never touch the network.
final class ModelStoreTests: XCTestCase {

    private func store() throws -> (ModelStore, URL) {
        let base = tempRootURL()
        let models = base.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        return (ModelStore(modelsDir: models), base)
    }

    private let source = ModelSource(repo: "mlx-community/Qwen3-0.6B-4bit", revision: "main")

    func testDirNameIsDeterministicAndSafe() {
        let name = ModelStore.dirName(repo: "mlx-community/Qwen3-0.6B-4bit", revision: "main")
        XCTAssertEqual(name, "mlx-community--Qwen3-0.6B-4bit__main")
        XCTAssertFalse(name.contains("/"))
        let tagged = ModelStore.dirName(repo: "a/b", revision: "v1.2/branch")
        XCTAssertFalse(tagged.contains("/"))
    }

    func testMissingArtifactIsNotReadyAndThrowsUnavailable() throws {
        let (store, _) = try store()
        XCTAssertFalse(store.isReady(source: source))
        XCTAssertFalse(store.hasReadyArtifact)
        XCTAssertThrowsError(try store.validatedDirectory(for: source)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .providerUnavailable)
        }
    }

    func testCompleteManifestIsReady() throws {
        let (store, _) = try store()
        let dir = store.directory(for: source)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let weight = dir.appendingPathComponent("model.safetensors")
        try Data(repeating: 7, count: 64).write(to: weight)
        let manifest = ModelStore.Manifest(
            schemaVersion: 1, repo: source.repo, revision: source.revision,
            resolvedRevision: "abc123", pulledAt: 0,
            files: [.init(path: "model.safetensors", size: 64, sha256: nil, oid: nil)])
        try JSONEncoder().encode(manifest)
            .write(to: dir.appendingPathComponent(ModelStore.manifestName))
        XCTAssertTrue(store.isReady(source: source))
        XCTAssertTrue(store.hasReadyArtifact)
        XCTAssertEqual(try store.validatedDirectory(for: source), dir)
        XCTAssertEqual(store.list().count, 1)
    }

    func testSizeMismatchIsRejected() throws {
        let (store, _) = try store()
        let dir = store.directory(for: source)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 32).write(to: dir.appendingPathComponent("w.safetensors"))
        let manifest = ModelStore.Manifest(
            schemaVersion: 1, repo: source.repo, revision: source.revision,
            resolvedRevision: nil, pulledAt: 0,
            files: [.init(path: "w.safetensors", size: 64, sha256: nil, oid: nil)])
        try JSONEncoder().encode(manifest)
            .write(to: dir.appendingPathComponent(ModelStore.manifestName))
        XCTAssertFalse(store.isReady(source: source))
    }

    func testSymlinkedFileIsRejected() throws {
        let (store, base) = try store()
        let dir = store.directory(for: source)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside.bin")
        try Data(repeating: 9, count: 16).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("w.safetensors"),
            withDestinationURL: outside)
        let manifest = ModelStore.Manifest(
            schemaVersion: 1, repo: source.repo, revision: source.revision,
            resolvedRevision: nil, pulledAt: 0,
            files: [.init(path: "w.safetensors", size: 16, sha256: nil, oid: nil)])
        try JSONEncoder().encode(manifest)
            .write(to: dir.appendingPathComponent(ModelStore.manifestName))
        XCTAssertFalse(store.isReady(source: source))
        XCTAssertThrowsError(try store.validatedDirectory(for: source)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .rootUnsafe)
        }
    }

    func testStagingDirectoryNeverCountsAsReady() throws {
        let (store, _) = try store()
        let staging = store.modelsDir
            .appendingPathComponent(".staging-\(ModelStore.dirName(repo: source.repo, revision: source.revision))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertFalse(store.isReady(source: source))
        XCTAssertFalse(store.hasReadyArtifact)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testManifestWithUnsafePathIsRejected() throws {
        let (store, base) = try store()
        let dir = store.directory(for: source)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A file the manifest claims lives outside the model dir.
        try Data(repeating: 1, count: 8).write(to: base.appendingPathComponent("escape"))
        let manifest = ModelStore.Manifest(
            schemaVersion: 1, repo: source.repo, revision: source.revision,
            resolvedRevision: nil, pulledAt: 0,
            files: [.init(path: "../escape", size: 8, sha256: nil, oid: nil)])
        try JSONEncoder().encode(manifest)
            .write(to: dir.appendingPathComponent(ModelStore.manifestName))
        XCTAssertThrowsError(try store.validatedDirectory(for: source)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .rootUnsafe)
        }
    }

    func testRemoveDeletesPulledModel() throws {
        let (store, _) = try store()
        let dir = store.directory(for: source)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("x"))
        try store.remove(source: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertThrowsError(try store.remove(source: source)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .notFound)
        }
    }

    func testProviderMapping() {
        let request = ChatRequest(model: "q", messages: [
            ChatMessage(role: .system, parts: ["be terse"]),
            ChatMessage(role: .user, parts: ["hi"]),
            ChatMessage(role: .assistant, parts: ["hello"]),
            ChatMessage(role: .user, parts: ["what is 2+2?"]),
        ], maxOutputTokens: 8)
        let mapped = try? MLXProvider.map(request)
        XCTAssertEqual(mapped?.instructions, "be terse")
        XCTAssertEqual(mapped?.history.count, 2)
        XCTAssertEqual(mapped?.prompt, "what is 2+2?")
    }

    func testProviderMappingRejectsAssistantFinal() {
        let request = ChatRequest(model: "q", messages: [
            ChatMessage(role: .user, parts: ["hi"]),
            ChatMessage(role: .assistant, parts: ["done"]),
        ], maxOutputTokens: 8)
        XCTAssertThrowsError(try MLXProvider.map(request))
    }

    func testProviderUnavailableWithoutArtifact() async throws {
        let (store, _) = try store()
        let provider = MLXProvider(store: store)
        let profile = ModelProfile(alias: "q", providerID: MLXProviderContract.id,
                                   kind: .llm, task: "chat", source: source)
        await XCTAssertThrowsErrorAsync(try await provider.complete(
            ChatRequest(model: "q",
                        messages: [ChatMessage(role: .user, parts: ["hi"])],
                        maxOutputTokens: 8), profile: profile)) { error in
            XCTAssertEqual((error as? PlatformError)?.code, .providerUnavailable)
        }
        XCTAssertFalse(provider.hasReadyArtifact)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ check: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected throw")
    } catch {
        check(error)
    }
}
