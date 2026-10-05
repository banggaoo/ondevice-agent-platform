import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// Typed-ML validation and resource admission policy.
final class MLAndResourceTests: XCTestCase {

    private func mlProfile() -> ModelProfile {
        ModelProfile(alias: "test-ml", providerID: "fake-ml", kind: .ml,
                     task: "classify",
                     inputSchema: ["name": .string, "score": .number, "flag": .boolean],
                     outputSchema: ["label": .string])
    }

    private static func mlRequest(_ inputs: [String: JSONValue],
                                  task: String = "classify",
                                  model: String = "test-ml") -> PredictionRequest {
        PredictionRequest(model: model, task: task, inputs: inputs)
    }

    private func stackWithML(predictor: FakeMLPredictor? = FakeMLPredictor()) async throws -> TestStack {
        let stack = try await makeStack()
        await stack.supervisor.registerModel(mlProfile(), predictor: predictor)
        await stack.supervisor.registerPrincipal(modelPrincipal)
        return stack
    }

    private func expectCode(_ code: ErrorCode,
                            _ body: () async throws -> PredictionResult,
                            file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testStrictTaskAndInputValidation() async throws {
        let stack = try await stackWithML()
        defer { stack.root.releaseLock() }
        let good: [String: JSONValue] = ["name": .string("a"), "score": .double(0.5),
                                       "flag": .bool(true)]
        await expectCode(.invalidRequest) {   // task mismatch
            try await stack.supervisor.submitML(principal: modelPrincipal,
                                                request: Self.mlRequest(good, task: "other"))
        }
        await expectCode(.invalidRequest) {   // missing field
            try await stack.supervisor.submitML(principal: modelPrincipal,
                request: Self.mlRequest(["name": .string("a"), "score": .double(1)]))
        }
        await expectCode(.invalidRequest) {   // extra field
            try await stack.supervisor.submitML(principal: modelPrincipal,
                request: Self.mlRequest(good.merging(["extra": .int(1)]) { a, _ in a }))
        }
        await expectCode(.invalidRequest) {   // type mismatch
            try await stack.supervisor.submitML(principal: modelPrincipal,
                request: Self.mlRequest(["name": .int(3), "score": .double(1), "flag": .bool(true)]))
        }
        await expectCode(.notFound) {         // unknown alias
            try await stack.supervisor.submitML(principal: modelPrincipal,
                                                request: Self.mlRequest(good, model: "nope"))
        }
        await expectCode(.notFound) {         // llm alias refused on ML seam
            try await stack.supervisor.submitML(principal: modelPrincipal,
                                                request: Self.mlRequest(good, model: "test-ml2"))
        }
    }

    func testMLUnavailableProviderIsTruthful() async throws {
        let stack = try await stackWithML(predictor: nil)
        defer { stack.root.releaseLock() }
        await expectCode(.providerUnavailable) {
            try await stack.supervisor.submitML(principal: modelPrincipal,
                request: Self.mlRequest(["name": .string("a"), "score": .double(1),
                                    "flag": .bool(false)]))
        }
    }

    func testOutputSchemaViolationFailsTruthfully() async throws {
        let stack = try await makeStack()
        defer { stack.root.releaseLock() }
        let bad = FakeMLPredictor(outputs: ["wrong": .int(1)])
        await stack.supervisor.registerModel(mlProfile(), predictor: bad)
        await stack.supervisor.registerPrincipal(modelPrincipal)
        let t = Task<Result<PredictionResult, Error>, Never> {
            do {
                return .success(try await stack.supervisor.submitML(
                    principal: modelPrincipal,
                    request: Self.mlRequest(["name": .string("a"), "score": .double(1),
                                        "flag": .bool(true)])))
            } catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil { bad.invocations.count == 1 })
        bad.finishNext()
        if case .failure(let e) = await t.value {
            XCTAssertEqual((e as? PlatformError)?.code, .invalidRequest)
        } else { XCTFail("expected invalidRequest") }
    }

    /// A prediction label is data; it cannot authorize administration.
    func testPredictionLabelCannotGrantAdmin() async throws {
        let stack = try await stackWithML()
        defer { stack.root.releaseLock() }
        let labelled = FakeMLPredictor(providerID: "fake-ml2",
                                       outputs: ["label": .string("admin")])
        await stack.supervisor.registerModel(
            ModelProfile(alias: "test-ml2", providerID: "fake-ml2", kind: .ml,
                         task: "classify", inputSchema: ["x": .number],
                         outputSchema: ["label": .string]),
            predictor: labelled)
        let t = Task { try? await stack.supervisor.submitML(
            principal: modelPrincipal,
            request: PredictionRequest(model: "test-ml2", task: "classify",
                                       inputs: ["x": .int(1)])) }
        try await expectTrue(await pollUntil { labelled.invocations.count == 1 })
        labelled.finishNext()
        _ = await t.value
        try await expectPlatformError(.forbidden) {
            try await stack.supervisor.require(.adminRead, principal: modelPrincipal)
        }
        do {
            _ = try await stack.supervisor.cancelJob(
                principal: modelPrincipal, jobID: "job-nonexistent")
            XCTFail("expected notFound, not admin")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .notFound)
        }
    }

    // MARK: resource policy

    func testResourceVerdicts() {
        let now = Date(timeIntervalSince1970: 1_000)
        func snap(thermal: ThermalLevel = .nominal,
                  pressure: MemoryPressureLevel = .normal,
                  lowPower: Bool? = false,
                  age: TimeInterval = 0) -> ResourceSnapshot {
            ResourceSnapshot(thermal: thermal, memoryPressure: pressure,
                             lowPowerMode: lowPower,
                             capturedAt: now.addingTimeInterval(-age))
        }
        XCTAssertEqual(ResourcePolicy.evaluate(snap(), at: now), .admit)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(thermal: .unknown), at: now), .denyAndCancel)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(pressure: .unknown), at: now), .denyAndCancel)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(age: PlatformLimits.resourceMaxAgeSeconds + 1), at: now), .denyAndCancel)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(pressure: .warning), at: now), .denyAndCancel)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(pressure: .critical), at: now), .denyAndCancel)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(thermal: .serious), at: now), .denyAndCancel)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(thermal: .critical), at: now), .denyAndCancel)
        // Fair thermal or low power defers truthfully: no reduced profile is
        // qualified in M1.
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(thermal: .fair), at: now), .deferLoad)
        XCTAssertEqual(ResourcePolicy.evaluate(
            snap(lowPower: true), at: now), .deferLoad)
    }

    /// A defer verdict leaves work queued, not failed: the job dispatches
    /// when a healthy snapshot arrives. Denial still fails immediately.
    func testDeferralKeepsJobPendingUntilAdmitted() async throws {
        let clock = ManualClock()
        let resources = FakeResourceSource(
            ResourceSnapshot(thermal: .fair, memoryPressure: .normal,
                             lowPowerMode: false, capturedAt: clock.now))
        let root = try preparedRoot(tempRootURL())
        defer { root.releaseLock() }
        let supervisor = PlatformSupervisor(
            root: root,
            resourceSource: resources, clock: clock.clock)
        try await supervisor.start()
        let provider = FakeLLMProvider(autoFinish: true)
        await supervisor.registerModel(
            ModelProfile(alias: "m", providerID: "fake-llm", kind: .llm, task: "chat"),
            provider: provider)
        await supervisor.registerPrincipal(modelPrincipal)

        let task = Task {
            try await supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(model: "m",
                                     messages: [ChatMessage(role: .user, parts: ["hi"])],
                                     maxOutputTokens: 4))
        }
        // Deferred: queued, never dispatched to the provider, never failed.
        try await expectTrue(await pollUntil {
            await supervisor.admissionSnapshot().pending == 1
        }, "job should queue under deferLoad")
        XCTAssertEqual(provider.invocations.count, 0)

        // A healthy snapshot retries dispatch and the job completes.
        resources.push(ResourceSnapshot(thermal: .nominal, memoryPressure: .normal,
                                        lowPowerMode: false, capturedAt: clock.now))
        let result = try await task.value
        XCTAssertEqual(result.content, "ok")
        XCTAssertEqual(provider.invocations.count, 1)
    }

    /// A job queued under deferral expires at its queue deadline instead of
    /// waiting forever: sweepExpired is the bounded-wait guarantee.
    func testDeferralStillExpiresAtQueueDeadline() async throws {
        let clock = ManualClock()
        let resources = FakeResourceSource(
            ResourceSnapshot(thermal: .fair, memoryPressure: .normal,
                             lowPowerMode: false, capturedAt: clock.now))
        let root = try preparedRoot(tempRootURL())
        defer { root.releaseLock() }
        let supervisor = PlatformSupervisor(
            root: root,
            resourceSource: resources, clock: clock.clock)
        try await supervisor.start()
        await supervisor.registerModel(
            ModelProfile(alias: "m", providerID: "fake-llm", kind: .llm, task: "chat"),
            provider: FakeLLMProvider(autoFinish: true))
        await supervisor.registerPrincipal(modelPrincipal)

        let task = Task<Result<ChatResult, Error>, Never> {
            do {
                return .success(try await supervisor.submitLLM(
                    principal: modelPrincipal,
                    request: ChatRequest(model: "m",
                                         messages: [ChatMessage(role: .user, parts: ["hi"])],
                                         maxOutputTokens: 4)))
            } catch { return .failure(error) }
        }
        try await expectTrue(await pollUntil {
            await supervisor.admissionSnapshot().pending == 1
        }, "job should queue under deferLoad")
        clock.advance(by: PlatformLimits.queueDeadlineSeconds + 1)
        // Force a re-dispatch so the sweep observes the expiry.
        resources.push(ResourceSnapshot(thermal: .fair, memoryPressure: .normal,
                                        lowPowerMode: false, capturedAt: clock.now))
        if case .failure(let error) = await task.value {
            XCTAssertEqual((error as? PlatformError)?.code, .deadlineExceeded)
        } else {
            XCTFail("expected deadlineExceeded")
        }
    }

    /// deferLoad defers weight loads only: a call whose provider reports no
    /// pending load (resident container or system-managed route) dispatches
    /// under fair thermal, while a load-bearing job for another consumer
    /// stays queued until a healthy snapshot arrives.
    func testDeferralDefersLoadsNotResidentCalls() async throws {
        let clock = ManualClock()
        let resources = FakeResourceSource(
            ResourceSnapshot(thermal: .fair, memoryPressure: .normal,
                             lowPowerMode: false, capturedAt: clock.now))
        let root = try preparedRoot(tempRootURL())
        defer { root.releaseLock() }
        let supervisor = PlatformSupervisor(
            root: root,
            resourceSource: resources, clock: clock.clock)
        try await supervisor.start()
        let resident = FakeLLMProvider(providerID: "resident-llm", autoFinish: true)
        resident.requiresLoadResult = false
        let loading = FakeLLMProvider(providerID: "loading-llm", autoFinish: true)
        await supervisor.registerModel(
            ModelProfile(alias: "resident", providerID: "resident-llm", kind: .llm, task: "chat"),
            provider: resident)
        await supervisor.registerModel(
            ModelProfile(alias: "loading", providerID: "loading-llm", kind: .llm, task: "chat"),
            provider: loading)
        await supervisor.registerPrincipal(modelPrincipal)
        await supervisor.registerPrincipal(agentPrincipal)

        // No-load call runs under the defer verdict.
        let result = try await supervisor.submitLLM(
            principal: modelPrincipal,
            request: ChatRequest(model: "resident",
                                 messages: [ChatMessage(role: .user, parts: ["hi"])],
                                 maxOutputTokens: 4))
        XCTAssertEqual(result.content, "ok")
        XCTAssertEqual(resident.invocations.count, 1)

        // Load-bearing call for another consumer queues behind it.
        let task = Task {
            try await supervisor.submitLLM(
                principal: agentPrincipal,
                request: ChatRequest(model: "loading",
                                     messages: [ChatMessage(role: .user, parts: ["hi"])],
                                     maxOutputTokens: 4))
        }
        try await expectTrue(await pollUntil {
            await supervisor.admissionSnapshot().pending == 1
        }, "load-bearing job should queue under deferLoad")
        XCTAssertEqual(loading.invocations.count, 0)

        // A healthy snapshot dispatches the deferred load.
        resources.push(ResourceSnapshot(thermal: .nominal, memoryPressure: .normal,
                                        lowPowerMode: false, capturedAt: clock.now))
        _ = try await task.value
        XCTAssertEqual(loading.invocations.count, 1)
    }

    /// A deny verdict sheds resident model caches so the host can recover,
    /// while ordinary snapshots run the idle trim instead - the provider's
    /// cache policy is never the caller's concern.
    func testPressureEscalationShedsModelCaches() async throws {
        let clock = ManualClock()
        let resources = FakeResourceSource(
            ResourceSnapshot(thermal: .nominal, memoryPressure: .normal,
                             lowPowerMode: false, capturedAt: clock.now))
        let root = try preparedRoot(tempRootURL())
        defer { root.releaseLock() }
        let supervisor = PlatformSupervisor(
            root: root,
            resourceSource: resources, clock: clock.clock)
        try await supervisor.start()
        let provider = FakeLLMProvider(autoFinish: true)
        await supervisor.registerModel(
            ModelProfile(alias: "m", providerID: "fake-llm", kind: .llm, task: "chat"),
            provider: provider)
        await supervisor.registerPrincipal(modelPrincipal)

        // A healthy push runs the idle trim, never the shed.
        resources.push(ResourceSnapshot(thermal: .nominal, memoryPressure: .normal,
                                        lowPowerMode: false, capturedAt: clock.now))
        try await expectTrue(await pollUntil { provider.evictIdleCalls >= 1 },
                             "snapshot should run idle trim")
        XCTAssertEqual(provider.evictResidentCalls, 0)

        // Warning pressure escalates: children cancel AND caches shed.
        resources.push(ResourceSnapshot(thermal: .nominal, memoryPressure: .warning,
                                        lowPowerMode: false, capturedAt: clock.now))
        try await expectTrue(await pollUntil { provider.evictResidentCalls == 1 },
                             "deny verdict should shed resident caches")
    }

    func testUnhealthySnapshotDeniesNewInference() async throws {
        let clock = ManualClock()
        let resources = FakeResourceSource(
            ResourceSnapshot(thermal: .nominal, memoryPressure: .warning,
                             lowPowerMode: false, capturedAt: clock.now))
        let root = try preparedRoot(tempRootURL())
        defer { root.releaseLock() }
        let supervisor = PlatformSupervisor(
            root: root,
            resourceSource: resources, clock: clock.clock)
        try await supervisor.start()
        let provider = FakeLLMProvider(autoFinish: true)
        await supervisor.registerModel(
            ModelProfile(alias: "m", providerID: "fake-llm", kind: .llm, task: "chat"),
            provider: provider)
        await supervisor.registerPrincipal(modelPrincipal)
        do {
            _ = try await supervisor.submitLLM(
                principal: modelPrincipal,
                request: ChatRequest(model: "m",
                                     messages: [ChatMessage(role: .user, parts: ["hi"])],
                                     maxOutputTokens: 4))
            XCTFail("expected resourceDenied")
        } catch let e as PlatformError {
            XCTAssertEqual(e.code, .resourceDenied)
        }
    }
}
