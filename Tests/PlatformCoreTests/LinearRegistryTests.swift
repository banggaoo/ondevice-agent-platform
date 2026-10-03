import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// Registry-declared linear models: strict parse validation, real prediction
/// math, and the full submitML admission path including schema enforcement.
final class LinearRegistryTests: XCTestCase {

    private func registry(_ models: [JSONValue]) -> JSONValue {
        .object(["schemaVersion": .int(1), "models": .array(models)])
    }

    private func linear(dropBias: Bool = false, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "features": .array([.string("x"), .string("y")]),
            "labels": .array([.string("neg"), .string("pos")]),
            "weights": .array([
                .array([.double(-1.0), .double(-1.0)]),
                .array([.double(1.0), .double(1.0)]),
            ]),
        ]
        if !dropBias { object["bias"] = .array([.double(0.0), .double(0.0)]) }
        object.merge(extra) { _, new in new }
        return .object(object)
    }

    private func entry(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "alias": .string("triage"),
            "kind": .string("ml"),
            "task": .string("classification"),
            "provider": .string("builtin.linear"),
            "inputSchema": .object(["x": .string("number"), "y": .string("number")]),
            "outputSchema": .object(["label": .string("string"), "confidence": .string("number")]),
            "linear": linear(),
        ]
        object.merge(extra) { _, new in new }
        return .object(object)
    }

    private func expectInvalid(_ body: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("expected invalidRequest", file: file, line: line)
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .invalidRequest, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func confidence(_ result: PredictionResult) -> Double {
        guard case .double(let d) = result.outputs["confidence"] else { return -1 }
        return d
    }

    func testParsesValidEntry() throws {
        let entries = try ModelRegistry.parse(registry([entry()]))
        XCTAssertEqual(entries.count, 1)
        let profile = entries[0].profile
        XCTAssertEqual(profile.alias, "triage")
        XCTAssertEqual(profile.providerID, "builtin.linear")
        XCTAssertEqual(profile.kind, .ml)
        XCTAssertEqual(profile.task, "classification")
        XCTAssertNotNil(entries[0].mlPredictor)
    }

    func testEmptyRegistryIsValid() throws {
        XCTAssertEqual(try ModelRegistry.parse(registry([])).count, 0)
        // schemaVersion is optional-but-constrained; absence is valid.
        XCTAssertEqual(try ModelRegistry.parse(.object(["models": .array([])])).count, 0)
    }

    func testRejectsMalformedEntries() {
        expectInvalid { _ = try ModelRegistry.parse(.object([            // unknown top key
            "schemaVersion": .int(1), "models": .array([]), "extra": .int(1)])) }
        expectInvalid { _ = try ModelRegistry.parse(registry([entry(["kind": .string("llm")])])) }
        expectInvalid { _ = try ModelRegistry.parse(registry([entry(["provider": .string("openai")])])) }
        expectInvalid { _ = try ModelRegistry.parse(registry([entry(["task": .string("regression")])])) }
        expectInvalid { _ = try ModelRegistry.parse(registry([entry(["unknown": .int(1)])])) }
        // features must equal the input schema key set.
        expectInvalid { _ = try ModelRegistry.parse(registry([entry([
            "inputSchema": .object(["x": .string("number")])])])) }
        // non-numeric input features are refused.
        expectInvalid { _ = try ModelRegistry.parse(registry([entry([
            "inputSchema": .object(["x": .string("number"), "y": .string("string")])])])) }
        // output schema must be exactly label+confidence.
        expectInvalid { _ = try ModelRegistry.parse(registry([entry([
            "outputSchema": .object(["label": .string("string")])])])) }
        // ragged weights (one row short of the label count).
        expectInvalid { _ = try ModelRegistry.parse(registry([entry([
            "linear": .object([
                "features": .array([.string("x"), .string("y")]),
                "labels": .array([.string("a"), .string("b")]),
                "weights": .array([.array([.double(1), .double(2)])]),
            ])])])) }
        // duplicate aliases.
        expectInvalid { _ = try ModelRegistry.parse(registry([entry(), entry()])) }
    }

    func testBiasDefaultsToZeroAndPredictsDeterministically() async throws {
        let entries = try ModelRegistry.parse(registry([entry([
            "linear": linear(dropBias: true)])]))
        let predictor = try XCTUnwrap(entries[0].mlPredictor)
        let pos = try await predictor.predict(
            PredictionRequest(model: "triage", task: "classification",
                              inputs: ["x": .double(1), "y": .double(1)]),
            profile: entries[0].profile)
        XCTAssertEqual(pos.outputs["label"], .string("pos"))
        XCTAssertGreaterThan(confidence(pos), 0.5)
        XCTAssertLessThanOrEqual(confidence(pos), 1.0)
        // Same input is fully deterministic.
        let again = try await predictor.predict(
            PredictionRequest(model: "triage", task: "classification",
                              inputs: ["x": .double(1), "y": .double(1)]),
            profile: entries[0].profile)
        XCTAssertEqual(again.outputs, pos.outputs)
        // Reversed evidence flips the label.
        let neg = try await predictor.predict(
            PredictionRequest(model: "triage", task: "classification",
                              inputs: ["x": .double(-1), "y": .double(-1)]),
            profile: entries[0].profile)
        XCTAssertEqual(neg.outputs["label"], .string("neg"))
    }

    /// Full admission path: registry entry -> registerModel -> submitML with
    /// input and output schema enforcement.
    func testSubmitMLThroughAdmission() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let entry = try ModelRegistry.parse(registry([entry()]))[0]
        await stack.supervisor.registerModel(entry.profile, predictor: entry.mlPredictor)
        await registerStandardPrincipals(stack.supervisor)
        let result = try await stack.supervisor.submitML(
            principal: modelPrincipal,
            request: PredictionRequest(model: "triage", task: "classification",
                                       inputs: ["x": .int(2), "y": .double(0.5)]))
        XCTAssertEqual(result.modelIdentity, "builtin.linear")
        XCTAssertEqual(result.outputs["label"], .string("pos"))
        // Missing feature is refused by the declared schema before dispatch.
        do {
            _ = try await stack.supervisor.submitML(
                principal: modelPrincipal,
                request: PredictionRequest(model: "triage", task: "classification",
                                           inputs: ["x": .int(2)]))
            XCTFail("expected invalidRequest")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .invalidRequest)
        }
    }
}
