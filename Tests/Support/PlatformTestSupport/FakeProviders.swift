import Foundation
import PlatformCore

/// Test-only LLM provider. Can answer instantly or suspend until the test
/// releases it; cancellation semantics are switchable to model cooperative
/// and noncooperative providers. Never advertised as a runtime provider.
/// Locking happens only inside synchronous helpers.
public final class FakeLLMProvider: LLMProvider, ModelCacheEvicting, @unchecked Sendable {
    public let providerID: String
    private let lock = NSLock()
    private var invocationsStore: [ChatRequest] = []
    private var gates: [(String, CheckedContinuation<ChatResult, Error>)] = []
    private var cancelledStore: [String] = []
    /// ModelCacheEvicting counters: the fake holds no real caches but
    /// records supervisor eviction calls so tests can observe escalation.
    public private(set) var evictResidentCalls = 0
    public private(set) var evictIdleCalls = 0
    public private(set) var lastEvictIdleCutoff: Date?
    /// When true, `cancel` releases suspended calls as cancelled.
    public var cooperative: Bool
    /// Result used for every released/immediate call.
    public var result: ChatResult
    /// Test knob for defer_load semantics: a fake defaults to the
    /// conservative "would load weights" answer; tests modelling a
    /// resident or system-managed route set it false.
    public var requiresLoadResult = true
    private let autoFinish: Bool

    public init(providerID: String = "fake-llm", cooperative: Bool = true,
                content: String = "ok", autoFinish: Bool = false) {
        self.providerID = providerID
        self.cooperative = cooperative
        self.result = ChatResult(modelIdentity: providerID, content: content,
                                 finishReason: .stop)
        self.autoFinish = autoFinish
    }

    public var invocations: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return invocationsStore
    }

    public var cancelledJobIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledStore
    }

    public var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return gates.count
    }

    /// Set by a cooperative cancel only when no call was pending to release:
    /// under the single inference slot that means the cancelled job's own
    /// provider call may still be in transit, so the next late arrival
    /// resolves as cancelled instead of hanging in a gate nobody will
    /// release. A released gate proves the call already arrived, and a
    /// later job must not inherit the cancel.
    private var cancelArmed = false

    private func cancelState() -> (pending: [(String, CheckedContinuation<ChatResult, Error>)],
                                   release: Bool) {
        lock.lock()
        let pending = gates
        if cooperative { gates.removeAll(); cancelArmed = pending.isEmpty }
        let release = cooperative
        lock.unlock()
        return (pending, release)
    }

    private func markCancelled(_ jobID: String) {
        lock.lock()
        cancelledStore.append(jobID)
        lock.unlock()
    }

    private func popGate() -> (CheckedContinuation<ChatResult, Error>, ChatResult)? {
        lock.lock()
        let gate = gates.isEmpty ? nil : gates.removeFirst().1
        let value = result
        lock.unlock()
        return gate.map { ($0, value) }
    }

    private func drainGates() -> ([(String, CheckedContinuation<ChatResult, Error>)], ChatResult) {
        lock.lock()
        let pending = gates
        gates.removeAll()
        let value = result
        lock.unlock()
        return (pending, value)
    }

    private func recordAndReturn(_ request: ChatRequest) -> ChatResult {
        lock.lock()
        invocationsStore.append(request)
        let value = result
        lock.unlock()
        return value
    }

    public func complete(_ request: ChatRequest, profile: ModelProfile) async throws -> ChatResult {
        // The invocation record and the gate registration move under one
        // lock: a finishNext/cancel observing the record can never lose its
        // wake between the two.
        if autoFinish {
            return recordAndReturn(request)
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            invocationsStore.append(request)
            // A cooperative cancel that already fired still reaches a call
            // that arrives after it. The arm is one-shot: a job gets at
            // most one provider call, so consuming it cannot poison the
            // next job's call.
            let alreadyCancelled = cooperative && cancelArmed
            if alreadyCancelled { cancelArmed = false }
            if !alreadyCancelled { gates.append((request.model, cont)) }
            lock.unlock()
            if alreadyCancelled {
                cont.resume(throwing: PlatformError(.cancelled))
            }
        }
    }

    public func cancel(jobID: String) async {
        markCancelled(jobID)
        let (pending, release) = cancelState()
        guard release else { return }
        for (_, cont) in pending {
            cont.resume(throwing: PlatformError(.cancelled))
        }
    }

    public func requiresLoad(for profile: ModelProfile) -> Bool { requiresLoadResult }

    @discardableResult
    public func evictResident() -> Int {
        lock.lock(); defer { lock.unlock() }
        evictResidentCalls += 1
        return 0
    }

    @discardableResult
    public func evictIdle(olderThan cutoff: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        evictIdleCalls += 1
        lastEvictIdleCutoff = cutoff
        return 0
    }

    /// Release the first suspended call with a result.
    public func finishNext(result: ChatResult? = nil) {
        if let (cont, fallback) = popGate() {
            cont.resume(returning: result ?? fallback)
        }
    }

    /// Release every suspended call with an error.
    public func failAll(_ error: Error = PlatformError(.providerUnavailable)) {
        let (pending, _) = drainGates()
        for (_, cont) in pending { cont.resume(throwing: error) }
    }

    public func finishAll() {
        let (pending, value) = drainGates()
        for (_, cont) in pending { cont.resume(returning: value) }
    }
}

/// Test-only ML predictor with the same gate discipline as the LLM fake.
public final class FakeMLPredictor: MLPredictor, @unchecked Sendable {
    public let providerID: String
    private let lock = NSLock()
    private var invocationsStore: [PredictionRequest] = []
    private var gates: [CheckedContinuation<PredictionResult, Error>] = []
    private var cancelledStore: [String] = []
    public var cooperative = true
    public var result: PredictionResult

    public init(providerID: String = "fake-ml",
                outputs: [String: JSONValue] = ["label": .string("test")]) {
        self.providerID = providerID
        self.result = PredictionResult(modelIdentity: providerID, outputs: outputs)
    }

    public var invocations: [PredictionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return invocationsStore
    }

    public var cancelledJobIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledStore
    }

    /// Same cancellation semantics as the LLM fake: arm only when no call
    /// was pending to release (the cancelled call may still be in transit).
    private var cancelArmed = false

    private func cancelState() -> ([CheckedContinuation<PredictionResult, Error>], Bool) {
        lock.lock()
        let pending = gates
        if cooperative { gates.removeAll(); cancelArmed = pending.isEmpty }
        let release = cooperative
        lock.unlock()
        return (pending, release)
    }

    private func markCancelled(_ jobID: String) {
        lock.lock()
        cancelledStore.append(jobID)
        lock.unlock()
    }

    private func popGate() -> (CheckedContinuation<PredictionResult, Error>, PredictionResult)? {
        lock.lock()
        let gate = gates.isEmpty ? nil : gates.removeFirst()
        let value = result
        lock.unlock()
        return gate.map { ($0, value) }
    }

    private func drainGates() -> [CheckedContinuation<PredictionResult, Error>] {
        lock.lock()
        let pending = gates
        gates.removeAll()
        lock.unlock()
        return pending
    }

    public func predict(_ request: PredictionRequest, profile: ModelProfile) async throws -> PredictionResult {
        // Same single-lock record+gate discipline as the LLM fake.
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            invocationsStore.append(request)
            let alreadyCancelled = cooperative && cancelArmed
            if alreadyCancelled { cancelArmed = false }
            if !alreadyCancelled { gates.append(cont) }
            lock.unlock()
            if alreadyCancelled {
                cont.resume(throwing: PlatformError(.cancelled))
            }
        }
    }

    public func cancel(jobID: String) async {
        markCancelled(jobID)
        let (pending, release) = cancelState()
        guard release else { return }
        for cont in pending { cont.resume(throwing: PlatformError(.cancelled)) }
    }

    public func finishNext(result: PredictionResult? = nil) {
        if let (cont, fallback) = popGate() {
            cont.resume(returning: result ?? fallback)
        }
    }

    public func failAll(_ error: Error = PlatformError(.providerUnavailable)) {
        for cont in drainGates() { cont.resume(throwing: error) }
    }
}

/// Generic harness for agent tests; behavior is a closure so a single type
/// can be registered under several versioned profiles.
public struct ClosureHarness: AgentHarness {
    public static let id = "test.closure"
    public static let version = 1

    private let body: @Sendable ([PromptBlock], AgentContext,
                                 @escaping @Sendable (AgentEvent) -> Void) async -> AgentStopReason

    public init(_ body: @escaping @Sendable ([PromptBlock], AgentContext,
                                             @escaping @Sendable (AgentEvent) -> Void) async -> AgentStopReason) {
        self.body = body
    }

    public func run(input: [PromptBlock], context: AgentContext,
                    emit: @escaping @Sendable (AgentEvent) -> Void) async -> AgentStopReason {
        await body(input, context, emit)
    }
}

/// Lock-confined string collection for harness emit captures.
public final class StringBag: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    public init() {}

    public func append(_ s: String) {
        lock.lock()
        items.append(s)
        lock.unlock()
    }

    public var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Lock-confined counter for tests that count calls across closures.
public final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    public func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
