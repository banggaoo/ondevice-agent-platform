import Foundation

/// Deterministic shared core: authentication, scopes, registry, admission,
/// scheduling, cancellation, durable records, and resource gating. Contains
/// no provider/model/agent loop; administration never needs inference.
public actor PlatformSupervisor {
    public struct Options: Sendable {
        public var enableReferenceAgent: Bool
        /// When set and the reference agent is enabled, also registers the
        /// bounded model-step `reference.echo` harness bound to this alias.
        public var referenceEchoModelAlias: String?
        public init(enableReferenceAgent: Bool = false, referenceEchoModelAlias: String? = nil) {
            self.enableReferenceAgent = enableReferenceAgent
            self.referenceEchoModelAlias = referenceEchoModelAlias
        }
    }

    let root: RuntimeRoot
    let store: StateStore
    let credentials: any CredentialStore
    let resourceSource: any ResourceSource
    let clock: Clock
    let options: Options

    // Authentication: expected tokens per scope plus test-injected principals.
    var scopeTokens: [CredentialScope: String] = [:]
    var customPrincipals: [String: Principal] = [:]
    var grants: [String: Set<Grant>] = [:]

    // Registries.
    var modelProfiles: [String: ModelProfile] = [:]
    var llmProviders: [String: any LLMProvider] = [:]
    var mlPredictors: [String: any MLPredictor] = [:]
    public nonisolated let agentService: AgentService

    // Admission state (see Supervisor+Admission.swift).
    var pendingJobs: [JobRecord] = []
    var activeJobs: [String: JobRecord] = [:]   // at most activeInference
    var pendingWork: [String: WorkItem] = [:]
    var runningWork: [String: WorkItem] = [:]
    var runningProviders: [String: Task<Void, Never>] = [:]
    var waiters: [String: CheckedContinuation<WorkResult, Error>] = [:]
    var jobSequence = 0
    var nextConsumerIndex = 0
    var inferenceBlocked = false
    var shuttingDown = false
    var latestSnapshot: ResourceSnapshot = .unknown

    public init(root: RuntimeRoot,
                credentials: any CredentialStore,
                resourceSource: any ResourceSource,
                clock: Clock = Clock(),
                options: Options = Options()) {
        self.root = root
        self.store = StateStore(url: root.databaseURL)
        self.credentials = credentials
        self.resourceSource = resourceSource
        self.clock = clock
        self.options = options
        self.agentService = AgentService(clock: clock)
    }

    /// Boot the core: prepared root, state store, credential presence, monitor.
    public func start() async throws {
        try await store.open()
        latestSnapshot = resourceSource.currentSnapshot()
        resourceSource.start { [weak self] snapshot in
            Task { await self?.resourceChanged(snapshot) }
        }
        if options.enableReferenceAgent {
            await agentService.registerBuiltInReference()
            if let alias = options.referenceEchoModelAlias {
                await agentService.registerBuiltInEcho(modelAlias: alias)
            }
        }
    }

    public func shutdown() async {
        shuttingDown = true
        await cancelAll(reason: PlatformError(.cancelled))
        try? await Task.sleep(for: .milliseconds(200))
        resourceSource.stop()
        await agentService.closeAll()
        await store.close()
        root.releaseLock()
    }

    // MARK: - Authentication and grants

    public func loadCredentials() async throws {
        for scope in CredentialScope.allCases {
            let key = CredentialKey.key(root: root.url, scope: scope)
            if let data = try credentials.secret(forKey: key),
               let token = String(data: data, encoding: .utf8) {
                scopeTokens[scope] = token
            }
        }
    }

    /// Test hook: register a principal directly under a token value.
    public func registerPrincipal(token: String, principal: Principal) {
        customPrincipals[token] = principal
        grants[principal.id] = principal.scope.baseGrants
    }

    /// Test/admin hook: remove a grant, effective at the next check.
    public func revokeGrant(_ grant: Grant, from principalID: String) {
        grants[principalID]?.remove(grant)
    }

    public func authenticate(token: String?) -> Principal? {
        guard let token, !token.isEmpty else { return nil }
        for (scope, expected) in scopeTokens where expected == token {
            let principal = Principal(id: scope.rawValue, scope: scope)
            if grants[principal.id] == nil { grants[principal.id] = scope.baseGrants }
            return principal
        }
        if let p = customPrincipals[token] { return p }
        return nil
    }

    public func has(_ grant: Grant, principal: Principal) -> Bool {
        let current = grants[principal.id] ?? principal.scope.baseGrants
        return current.contains(grant)
    }

    public func require(_ grant: Grant, principal: Principal) throws {
        guard has(grant, principal: principal) else { throw PlatformError(.forbidden) }
    }

    // MARK: - Registry

    public func registerModel(_ profile: ModelProfile, provider: (any LLMProvider)? = nil,
                              predictor: (any MLPredictor)? = nil) {
        modelProfiles[profile.alias] = profile
        if let provider { llmProviders[provider.providerID] = provider }
        if let predictor { mlPredictors[predictor.providerID] = predictor }
    }

    public func registeredModels(kind: ModelKind) -> [ModelProfile] {
        modelProfiles.values.filter { $0.kind == kind }.sorted { $0.alias < $1.alias }
    }

    // MARK: - Status and administration (never inference)

    public func statusSnapshot() -> JSONValue {
        .object([
            "version": .string("0.1.0-m1"),
            "resource": .object([
                "thermal": .string(latestSnapshot.thermal.rawValue),
                "memoryPressure": .string(latestSnapshot.memoryPressure.rawValue),
                "lowPowerMode": latestSnapshot.lowPowerMode.map { .bool($0) } ?? .null,
                "capturedAt": .double(latestSnapshot.capturedAt.timeIntervalSince1970),
            ]),
            "appleAvailability": .string(AppleModelAvailability.status().rawValue),
            "categories": .object([
                "appleFoundationModels": .string(CategoryStatus.observing.rawValue),
                "ownedOpenWeight": .string(CategoryStatus.notConfigured.rawValue),
                "typedML": .string(CategoryStatus.notConfigured.rawValue),
            ]),
            "counts": .object([
                "activeInference": .int(Int64(activeJobs.count)),
                "pendingInference": .int(Int64(pendingJobs.count)),
                "inferenceBlocked": .bool(inferenceBlocked),
            ]),
        ])
    }

    public func registrySnapshot() async -> JSONValue {
        .object([
            "models": .array(registeredModels(kind: .llm).map { .string($0.alias) }
                + registeredModels(kind: .ml).map { .string($0.alias) }),
            "agents": .array(await agentService.profileIDs().map { .string($0) }),
        ])
    }

    public func listJobs() async throws -> [JobRecord] {
        try await store.jobs()
    }

    private func resourceChanged(_ snapshot: ResourceSnapshot) {
        latestSnapshot = snapshot
        if ResourcePolicy.evaluate(snapshot, at: clock.now) == .denyAndCancel {
            cancelChildrenForResourceDenial()
        }
        dispatch()
    }
}
