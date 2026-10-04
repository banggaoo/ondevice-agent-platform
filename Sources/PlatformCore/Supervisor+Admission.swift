import Foundation

/// Internal work item waiting for the shared inference slot.
enum WorkItem: Sendable {
    case chat(ChatRequest, ModelProfile, any LLMProvider)
    case predict(PredictionRequest, ModelProfile, any MLPredictor)
}

enum WorkResult: Sendable {
    case chat(ChatResult)
    case prediction(PredictionResult)
}

extension PlatformSupervisor {
    /// Consumer-fair admission for LLM work. Grant is checked before queueing
    /// and again at dispatch; prompt text can never select administration.
    public func submitLLM(principal: Principal, request: ChatRequest,
                          parentID: String? = nil) async throws -> ChatResult {
        try require(.llmInfer, principal: principal)
        guard let profile = modelProfiles[request.model], profile.kind == .llm else {
            throw PlatformError(.notFound)
        }
        if request.hasImages, !profile.capabilities.contains("vision") {
            throw PlatformError(.invalidRequest,
                                detail: "model does not accept image input")
        }
        guard let provider = llmProviders[profile.providerID] else {
            throw PlatformError(.providerUnavailable)
        }
        let outcome = try await enqueue(
            kind: .llm, consumerID: principal.id, parentID: parentID,
            work: .chat(request, profile, provider)
        )
        guard case .chat(let result) = outcome else { throw PlatformError(.internal) }
        return result
    }

    public func submitML(principal: Principal, request: PredictionRequest,
                         parentID: String? = nil) async throws -> PredictionResult {
        try require(.mlPredict, principal: principal)
        guard let profile = modelProfiles[request.model], profile.kind == .ml else {
            throw PlatformError(.notFound)
        }
        guard profile.task == request.task else { throw PlatformError(.invalidRequest, detail: "task mismatch") }
        if let schema = profile.inputSchema {
            try FeatureValidation.validate(inputs: request.inputs, schema: schema)
        }
        guard let predictor = mlPredictors[profile.providerID] else {
            throw PlatformError(.providerUnavailable)
        }
        let outcome = try await enqueue(
            kind: .ml, consumerID: principal.id, parentID: parentID,
            work: .predict(request, profile, predictor)
        )
        guard case .prediction(let result) = outcome else { throw PlatformError(.internal) }
        if let outputSchema = profile.outputSchema {
            try FeatureValidation.validate(inputs: result.outputs, schema: outputSchema)
        }
        return result
    }

    private func enqueue(kind: JobKind, consumerID: String, parentID: String?,
                         work: WorkItem) async throws -> WorkResult {
        if shuttingDown { throw PlatformError(.cancelled) }
        if inferenceBlocked { throw PlatformError(.providerUnavailable, detail: "inference blocked") }
        if pendingJobs.count >= PlatformLimits.pendingInference {
            throw PlatformError(.capacityLimited, detail: "queue full")
        }
        let now = clock.now
        let job = JobRecord(id: newJobID(), kind: kind, consumerID: consumerID,
                            parentID: parentID, createdAt: now, updatedAt: now)
        do { try await store.insertJob(job) } catch {
            throw PlatformError(.storageFailure)
        }
        pendingJobs.append(job)
        pendingWork[job.id] = work
        // The waiter is registered BEFORE dispatch: dispatch can finish the
        // job synchronously (grant recheck, resource denial, sweep expiry),
        // and a resume with no registered waiter would lose the result and
        // hang the caller forever.
        return try await withCheckedThrowingContinuation { cont in
            waiters[job.id] = cont
            dispatch()
        }
    }

    func newJobID() -> String {
        jobSequence += 1
        return "job-\(jobSequence)"
    }

    /// Round-robin across consumers with pending work, earliest job first.
    func dispatch() {
        sweepExpired()
        guard !shuttingDown, !inferenceBlocked,
              activeJobs.count < PlatformLimits.activeInference,
              !pendingJobs.isEmpty else { return }
        let consumers = Array(Set(pendingJobs.map(\.consumerID))).sorted()
        let chosen = consumers[nextConsumerIndex % consumers.count]
        nextConsumerIndex += 1
        guard let index = pendingJobs.firstIndex(where: { $0.consumerID == chosen })
                ?? pendingJobs.indices.first else { return }
        var job = pendingJobs.remove(at: index)
        guard let work = pendingWork.removeValue(forKey: job.id) else { return }

        let now = clock.now
        let needed: Grant = job.kind == .llm ? .llmInfer : .mlPredict
        let currentGrants = grants[job.consumerID] ?? []
        guard currentGrants.contains(needed) else {
            finishTerminal(&job, .failed); resume(job.id, .failure(PlatformError(.forbidden)))
            return dispatch()
        }
        let verdict = ResourcePolicy.evaluate(latestSnapshot, at: now)
        guard verdict == .admit else {
            finishTerminal(&job, .failed); resume(job.id, .failure(PlatformError(.resourceDenied)))
            return dispatch()
        }

        job.state = .active
        job.updatedAt = now
        activeJobs[job.id] = job
        runningWork[job.id] = work
        persist(job)
        incrementCount(job.kind)
        launch(job: job, work: work)
        dispatch()
    }

    /// Runs the provider as an unstructured task. A separate deadline timer
    /// records terminal intent; a noncooperative provider keeps its slot until
    /// it actually finishes - no task group waits on it indefinitely.
    private func launch(job: JobRecord, work: WorkItem) {
        let jobID = job.id
        let runner = Task { [weak self] in
            do {
                let outcome: WorkResult
                switch work {
                case .chat(let req, let profile, let provider):
                    outcome = .chat(try await provider.complete(req, profile: profile))
                case .predict(let req, let profile, let predictor):
                    outcome = .prediction(try await predictor.predict(req, profile: profile))
                }
                await self?.providerFinished(jobID: jobID, outcome: outcome)
            } catch let e as PlatformError {
                await self?.providerFinished(jobID: jobID, outcome: nil, error: e)
            } catch {
                await self?.providerFinished(jobID: jobID, outcome: nil,
                                             error: PlatformError(.providerUnavailable))
            }
        }
        runningProviders[jobID] = runner
        let deadline = PlatformLimits.inferenceDeadlineSeconds
        Task { [weak self, clock] in
            try? await clock.sleep(deadline)
            guard !Task.isCancelled else { return }
            await self?.inferenceDeadlineHit(jobID)
        }
    }

    /// Caller gets a bounded deadline error while a retained provider still
    /// finishes in the background; the slot is not released early.
    func inferenceDeadlineHit(_ jobID: String) {
        guard var job = activeJobs[jobID], job.state == .active else { return }
        job.state = .failed
        job.updatedAt = clock.now
        activeJobs[jobID] = job   // retained until providerFinished
        persist(job)
        resume(jobID, .failure(PlatformError(.deadlineExceeded)))
        askProviderCancel(jobID)
    }

    /// Provider returned. Terminal intent recorded earlier (cancel, deadline)
    /// always wins: late or double completions only release the slot and
    /// never overwrite a terminal state.
    func providerFinished(jobID: String, outcome: WorkResult?, error: Error? = nil) {
        runningProviders.removeValue(forKey: jobID)
        runningWork.removeValue(forKey: jobID)
        guard var job = activeJobs[jobID] else { return }   // stale/double ignored
        job.providerFinished = true
        job.updatedAt = clock.now

        switch job.state {
        case .cancelRequested:
            activeJobs.removeValue(forKey: jobID)
            job.state = .cancelled
            persist(job)
            resume(jobID, .failure(PlatformError(.cancelled)))
            refreshBlocked()
            dispatch()
        case .cancellationUnconfirmed:
            activeJobs.removeValue(forKey: jobID)
            persist(job)   // stays unconfirmed; slot released
            refreshBlocked()
            dispatch()
        case .active:
            activeJobs.removeValue(forKey: jobID)
            if let error {
                finishTerminal(&job, .failed)
                resume(job.id, .failure(error))
            } else if let outcome {
                finishTerminal(&job, .completed)
                resume(job.id, .success(outcome))
            } else {
                finishTerminal(&job, .failed)
                resume(job.id, .failure(PlatformError(.deadlineExceeded)))
            }
            refreshBlocked()
            dispatch()
        default:
            // Terminal retained job (deadline-failed): release slot only.
            activeJobs.removeValue(forKey: jobID)
            persist(job)
            refreshBlocked()
            dispatch()
        }
    }

    /// Expire queued work past its queue deadline; cancels are also reaped here.
    func sweepExpired() {
        let now = clock.now
        var kept: [JobRecord] = []
        for var job in pendingJobs {
            if now.timeIntervalSince(job.createdAt) > PlatformLimits.queueDeadlineSeconds {
                pendingWork.removeValue(forKey: job.id)
                finishTerminal(&job, .failed)
                resume(job.id, .failure(PlatformError(.deadlineExceeded)))
            } else {
                kept.append(job)
            }
        }
        pendingJobs = kept
    }

    /// Cancel one job. Admin may cancel anything; a consumer may cancel only
    /// its own work and only with a work-scope grant, never admin rights.
    public func cancelJob(principal: Principal, jobID: String) async throws {
        guard let job = try await jobRecord(jobID) else { throw PlatformError(.notFound) }
        let admin = has(.adminStop, principal: principal)
        let own = job.consumerID == principal.id
        let ownWork = has(.llmInfer, principal: principal) || has(.mlPredict, principal: principal)
            || has(.agentRun, principal: principal)
        guard admin || (own && ownWork) else { throw PlatformError(.forbidden) }
        try cancelJobRecord(jobID, error: PlatformError(.cancelled))
    }

    /// Internal cancel used by resource denial, parent cancellation, shutdown.
    func cancelJobRecord(_ jobID: String, error: PlatformError) throws {
        if let index = pendingJobs.firstIndex(where: { $0.id == jobID }) {
            var job = pendingJobs.remove(at: index)
            pendingWork.removeValue(forKey: jobID)
            finishTerminal(&job, .cancelled)
            resume(jobID, .failure(error))
            return
        }
        guard var job = activeJobs[jobID] else { return }
        if job.state == .active {
            job.state = .cancelRequested
            job.updatedAt = clock.now
            activeJobs[jobID] = job
            persist(job)
            askProviderCancel(jobID)
            scheduleGrace(jobID)
        }
    }

    private func askProviderCancel(_ jobID: String) {
        if let work = runningWork[jobID] {
            Task {
                switch work {
                case .chat(_, _, let provider): await provider.cancel(jobID: jobID)
                case .predict(_, _, let predictor): await predictor.cancel(jobID: jobID)
                }
            }
        } else {
            runningProviders[jobID]?.cancel()
        }
    }

    /// After the grace period an unfinished provider is unconfirmed: the job
    /// transitions terminally, the slot stays retained, and new inference is
    /// blocked until the provider actually reports completion.
    private func scheduleGrace(_ jobID: String) {
        let grace = PlatformLimits.cancellationGraceSeconds
        Task { [weak self, clock] in
            try? await clock.sleep(grace)
            guard !Task.isCancelled else { return }
            await self?.graceExpired(jobID)
        }
    }

    func graceExpired(_ jobID: String) {
        guard var job = activeJobs[jobID], job.state == .cancelRequested else { return }
        job.state = .cancellationUnconfirmed
        job.updatedAt = clock.now
        activeJobs[jobID] = job
        persist(job)
        inferenceBlocked = true
        resume(jobID, .failure(PlatformError(.cancellationUnconfirmed)))
    }

    /// New inference stays blocked while an unconfirmed cancellation still
    /// retains its provider; it clears once those providers actually finish.
    private func refreshBlocked() {
        inferenceBlocked = activeJobs.values.contains {
            $0.state == .cancellationUnconfirmed
        }
    }

    func cancelChildrenForResourceDenial() {
        for job in pendingJobs + Array(activeJobs.values) {
            try? cancelJobRecord(job.id, error: PlatformError(.resourceDenied))
        }
    }

    /// Cancel all child work of a parent run or session.
    public func cancelChildren(parentID: String) {
        for job in pendingJobs where job.parentID == parentID {
            try? cancelJobRecord(job.id, error: PlatformError(.cancelled))
        }
        for job in activeJobs.values where job.parentID == parentID {
            try? cancelJobRecord(job.id, error: PlatformError(.cancelled))
        }
    }

    func cancelAll(reason: PlatformError) async {
        for job in pendingJobs { try? cancelJobRecord(job.id, error: reason) }
        for job in activeJobs.values { try? cancelJobRecord(job.id, error: reason) }
    }

    func jobRecord(_ jobID: String) async throws -> JobRecord? {
        if let j = pendingJobs.first(where: { $0.id == jobID }) { return j }
        if let j = activeJobs[jobID] { return j }
        return try await store.job(id: jobID)
    }

    // MARK: - helpers

    func finishTerminal(_ job: inout JobRecord, _ state: JobState) {
        job.state = state
        job.updatedAt = clock.now
        if state == .failed || state == .cancelled || state == .completed {
            job.providerFinished = true
        }
        persist(job)
    }

    func persist(_ job: JobRecord) {
        let copy = job
        Task { [store] in try? await store.updateJob(copy) }
    }

    func resume(_ jobID: String, _ result: Result<WorkResult, Error>) {
        waiters.removeValue(forKey: jobID)?.resume(with: result)
    }

    private func incrementCount(_ kind: JobKind) {
        let name = kind == .llm ? "llm_calls" : "ml_predictions"
        Task { [store] in try? await store.incrementCounter(name) }
    }

    public func counters() async -> (llm: Int64, ml: Int64) {
        let llm = (try? await store.counter("llm_calls")) ?? 0
        let ml = (try? await store.counter("ml_predictions")) ?? 0
        return (llm, ml)
    }

    /// Test-visible summary of admission state.
    public func admissionSnapshot() -> (active: Int, pending: Int, blocked: Bool) {
        (activeJobs.count, pendingJobs.count, inferenceBlocked)
    }
}
