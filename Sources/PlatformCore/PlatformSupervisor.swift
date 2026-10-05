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
    let resourceSource: any ResourceSource
    let clock: Clock
    let options: Options

    // Internal grant map keyed by code-owned principal id. The local-trust
    // design issues no tokens: identities are fixed in code, never minted,
    // stored, or presented by a caller.
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
    /// Outstanding storage insertions count against admission capacity so a
    /// submission burst cannot overrun the queue across suspension.
    var insertionReservations = 0
    /// Per-job cancellation token + observer while a job is pending or
    /// active; dispatch checks the token synchronously before launching.
    var jobCancellations: [String: (token: CancellationToken, observer: UUID)] = [:]
    var jobSequence = 0
    var nextConsumerIndex = 0
    var inferenceBlocked = false
    var shuttingDown = false
    var latestSnapshot: ResourceSnapshot = .unknown

    public init(root: RuntimeRoot,
                resourceSource: any ResourceSource,
                clock: Clock = Clock(),
                options: Options = Options()) {
        self.root = root
        self.store = StateStore(url: root.databaseURL)
        self.resourceSource = resourceSource
        self.clock = clock
        self.options = options
        self.agentService = AgentService(clock: clock)
    }

    /// Boot the core: prepared root, state store, local consumers, monitor.
    public func start() async throws {
        try await store.open()
        jobSequence = try await store.maxJobSequence()
        // Fixed local-trust consumers hold their scope's base grants from
        // the start so grant checks and revocation are deterministic.
        for consumer in [LocalConsumers.model, LocalConsumers.agent,
                         LocalConsumers.administration] {
            grants[consumer.id] = consumer.scope.baseGrants
        }
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

    // MARK: - Grants

    /// Register a code-owned consumer under its scope's base grants.
    public func registerPrincipal(_ principal: Principal) {
        grants[principal.id] = principal.scope.baseGrants
    }

    /// Console-only in-process consumer of the enabled read-only Operator.
    /// No credential is issued and no admin or typed-ML grant is added.
    public func registerConsoleOperatorConsumer() -> Principal {
        let principal = Principal(id: "console-operator", scope: .agent)
        grants[principal.id] = [.agentRun, .agentStatusRead, .llmInfer]
        return principal
    }

    /// Test/admin hook: remove a grant, effective at the next check.
    public func revokeGrant(_ grant: Grant, from principalID: String) {
        grants[principalID]?.remove(grant)
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

    /// Opt-in runtime Operator: the named alias must be an actual LLM route
    /// on a locally served provider (owned open-weight MLX or the system
    /// Apple Foundation Models route) with a live provider - verified here
    /// before the agent profile registers, never assumed or fabricated.
    public func registerRuntimeOperator(modelAlias: String) async throws {
        guard !modelAlias.isEmpty else {
            throw PlatformError(.invalidRequest, detail: "operator model alias required")
        }
        guard let profile = modelProfiles[modelAlias], profile.kind == .llm else {
            throw PlatformError(.notFound, detail: "operator model alias not registered")
        }
        guard profile.providerID == MLXProviderContract.id
              || profile.providerID == AppleFoundationProvider.id,
              llmProviders[profile.providerID] != nil else {
            throw PlatformError(.providerUnavailable,
                                detail: "operator requires the MLX or Apple route")
        }
        await agentService.registerRuntimeOperator(modelAlias: modelAlias)
    }

    // MARK: - Status and administration (never inference)

    public func statusSnapshot() -> JSONValue {
        .object([
            "version": .string("0.1.0-m1"),
            "resource": .object([
                "thermal": .string(latestSnapshot.thermal.rawValue),
                "memoryPressure": .string(latestSnapshot.memoryPressure.rawValue),
                "memoryPressureSource": .string(latestSnapshot.memoryPressureSource.rawValue),
                "lowPowerMode": latestSnapshot.lowPowerMode.map { .bool($0) } ?? .null,
                "capturedAt": .double(latestSnapshot.capturedAt.timeIntervalSince1970),
                /// The evaluated admission verdict is the single truthful
                /// resource signal for consumers; the console must not
                /// re-derive policy thresholds from raw fields.
                "admission": .string(ResourcePolicy.evaluate(
                    latestSnapshot, at: clock.now).rawValue),
            ]),
            "appleAvailability": .string(AppleModelAvailability.status().rawValue),
            "categories": .object([
                "appleFoundationModels": .string(appleCategory().rawValue),
                "ownedOpenWeight": .string(openWeightCategory().rawValue),
                "typedML": .string(mlPredictors.isEmpty
                                   ? CategoryStatus.notConfigured.rawValue
                                   : CategoryStatus.qualified.rawValue),
            ]),
            "counts": .object([
                "activeInference": .int(Int64(activeJobs.count)),
                "pendingInference": .int(Int64(pendingJobs.count)),
                "inferenceBlocked": .bool(inferenceBlocked),
            ]),
            "models": .array(modelProfileSummaries()),
            "jobs": .object([
                "active": .array(activeJobs.values.sorted { $0.id < $1.id }.map(jobSummary)),
                "pending": .array(pendingJobs.map(jobSummary)),
            ]),
        ])
    }

    private func jobSummary(_ job: JobRecord) -> JSONValue {
        .object([
            "id": .string(job.id),
            "kind": .string(job.kind.rawValue),
            "state": .string(job.state.rawValue),
            "parentId": job.parentID.map { .string($0) } ?? .null,
        ])
    }

    private func modelProfileSummaries() -> [JSONValue] {
        modelProfiles.values.sorted { $0.alias < $1.alias }.map { profile in
            let registered: Bool
            let artifactReady: Bool?
            if profile.kind == .ml {
                registered = mlPredictors[profile.providerID] != nil
                artifactReady = registered
            } else if let provider = llmProviders[profile.providerID] {
                registered = true
                artifactReady = (provider as? ProviderReadiness)?.artifactReady(for: profile)
            } else {
                registered = false
                artifactReady = false
            }
            return .object([
                "alias": .string(profile.alias),
                "kind": .string(profile.kind.rawValue),
                "provider": .string(profile.providerID),
                "task": .string(profile.task),
                "purposes": .array(profile.purposes.sorted().map { .string($0) }),
                "capabilities": .array(profile.capabilities.sorted().map { .string($0) }),
                "providerRegistered": .bool(registered),
                "artifactReady": artifactReady.map { .bool($0) } ?? .null,
                "maxOutputTokens": .int(Int64(min(
                    PlatformLimits.outputTokens, profile.maxOutputTokens ?? PlatformLimits.outputTokens))),
                "source": profile.source.map {
                    .object(["repo": .string($0.repo), "revision": .string($0.revision)])
                } ?? .null,
            ])
        }
    }

    /// Truthful category status: qualified only when a real provider instance
    /// is registered; observing when availability is observable but nothing
    /// is qualified; notConfigured when neither holds.
    private func appleCategory() -> CategoryStatus {
        if llmProviders[AppleFoundationProvider.id] != nil { return .qualified }
        return AppleModelAvailability.status() == .notPresent ? .notConfigured : .observing
    }

    /// The MLX route is qualified only when a pulled, validated artifact
    /// exists under the managed store. A registered provider with nothing
    /// pulled reports `observing`; no route at all reports `notConfigured`.
    private func openWeightCategory() -> CategoryStatus {
        guard let provider = llmProviders[MLXProviderContract.id] else {
            return modelProfiles.values.contains {
                $0.providerID == MLXProviderContract.id
            } ? .observing : .notConfigured
        }
        return (provider as? ProviderReadiness)?.hasReadyArtifact == true
            ? .qualified : .observing
    }

    public func registrySnapshot() async -> JSONValue {
        let agents = await agentService.profileSummaries()
        return .object([
            "models": .array(registeredModels(kind: .llm).map { .string($0.alias) }
                + registeredModels(kind: .ml).map { .string($0.alias) }),
            "agents": .array(agents.compactMap { $0.objectValue?["id"] }),
            "modelProfiles": .array(modelProfileSummaries()),
            "agentProfiles": .array(agents),
        ])
    }

    public func listJobs() async throws -> [JobRecord] {
        try await store.jobs()
    }

    /// Source callbacks publish off-lock and may arrive out of order, so a
    /// strictly older sample must never overwrite a newer observation. An
    /// equal timestamp still applies - it carries new information.
    /// Internal for @testable regression coverage.
    func resourceChanged(_ snapshot: ResourceSnapshot) {
        guard snapshot.capturedAt >= latestSnapshot.capturedAt else { return }
        latestSnapshot = snapshot
        if ResourcePolicy.evaluate(snapshot, at: clock.now) == .denyAndCancel {
            cancelChildrenForResourceDenial()
            // The host needs memory back: shed resident weight caches so
            // pressure can actually recover instead of staying denied.
            for provider in llmProviders.values {
                (provider as? ModelCacheEvicting)?.evictResident()
            }
        } else {
            // Idle trim on every snapshot: a model unused past the bound
            // releases its memory; the next request reloads on demand.
            let cutoff = clock.now.addingTimeInterval(-PlatformLimits.modelIdleSeconds)
            for provider in llmProviders.values {
                (provider as? ModelCacheEvicting)?.evictIdle(olderThan: cutoff)
            }
        }
        dispatch()
    }
}
