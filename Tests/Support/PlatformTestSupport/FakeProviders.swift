import Foundation
import PlatformCore

/// Test-only LLM provider. Can answer instantly or suspend until the test
/// releases it; cancellation semantics are switchable to model cooperative
/// and noncooperative providers. Never advertised as a runtime provider.
/// Locking happens only inside synchronous helpers.
public final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    public let providerID: String
    private let lock = NSLock()
    private var invocationsStore: [ChatRequest] = []
    private var gates: [(String, CheckedContinuation<ChatResult, Error>)] = []
    private var cancelledStore: [String] = []
    /// When true, `cancel` releases suspended calls as cancelled.
    public var cooperative: Bool
    /// Result used for every released/immediate call.
    public var result: ChatResult
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

    private func record(_ request: ChatRequest) -> ChatResult? {
        lock.lock()
        invocationsStore.append(request)
        let immediate = autoFinish ? result : nil
        lock.unlock()
        return immediate
    }

    private func appendGate(_ request: ChatRequest,
                            _ cont: CheckedContinuation<ChatResult, Error>) {
        lock.lock()
        gates.append((request.model, cont))
        lock.unlock()
    }

    private func cancelState() -> (pending: [(String, CheckedContinuation<ChatResult, Error>)],
                                   release: Bool) {
        lock.lock()
        let pending = gates
        if cooperative { gates.removeAll() }
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

    public func complete(_ request: ChatRequest, profile: ModelProfile) async throws -> ChatResult {
        if let immediate = record(request) { return immediate }
        return try await withCheckedThrowingContinuation { cont in
            appendGate(request, cont)
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

    private func record(_ request: PredictionRequest) {
        lock.lock()
        invocationsStore.append(request)
        lock.unlock()
    }

    private func appendGate(_ cont: CheckedContinuation<PredictionResult, Error>) {
        lock.lock()
        gates.append(cont)
        lock.unlock()
    }

    private func cancelState() -> ([CheckedContinuation<PredictionResult, Error>], Bool) {
        lock.lock()
        let pending = gates
        if cooperative { gates.removeAll() }
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
        record(request)
        return try await withCheckedThrowingContinuation { cont in
            appendGate(cont)
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
                                 @Sendable (AgentEvent) -> Void) async -> AgentStopReason

    public init(_ body: @escaping @Sendable ([PromptBlock], AgentContext,
                                             @Sendable (AgentEvent) -> Void) async -> AgentStopReason) {
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
