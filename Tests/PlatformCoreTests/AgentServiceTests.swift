import XCTest
import PlatformTestSupport
@testable import PlatformCore

/// Agent runtime: versioned profiles, session pinning, connection binding,
/// and the deterministic reference harness.
final class AgentServiceTests: XCTestCase {

    private func profile(id: String, version: Int,
                         harnessVersion: Int) -> AgentProfile {
        AgentProfile(id: id, version: version,
                     harnessID: "test.closure", harnessVersion: harnessVersion,
                     stateSchemaVersion: 1, implementationRef: "test:closure-\(harnessVersion)")
    }

    private func entry(version: Int) -> AgentService.HarnessEntry {
        AgentService.HarnessEntry(
            make: { ClosureHarness { _, _, emit in
                emit(.messageChunk("v\(version)"))
                return .endTurn
            } },
            harnessID: "test.closure", harnessVersion: version)
    }

    func testVersionPinningAcrossTurnsAndRollback() async throws {
        let service = AgentService(clock: Clock())
        await service.register(profile: profile(id: "test.agent", version: 1,
                                                harnessVersion: 1),
                               harness: entry(version: 1))
        let s1 = try await service.newSession(agentID: "test.agent",
                                              consumerID: "c", connectionID: "conn-1")
        XCTAssertEqual(s1.profile.version, 1)

        await service.register(profile: profile(id: "test.agent", version: 2,
                                                harnessVersion: 2),
                               harness: entry(version: 2))
        let s2 = try await service.newSession(agentID: "test.agent",
                                              consumerID: "c", connectionID: "conn-1")
        XCTAssertEqual(s2.profile.version, 2)
        // Existing session keeps its pinned v1 snapshot.
        let pinned = await service.session(s1.id, consumerID: "c",
                                           connectionID: "conn-1")
        XCTAssertEqual(pinned?.profile.version, 1)

        // Programmatic rollback: re-register v1 as the latest profile.
        await service.register(profile: profile(id: "test.agent", version: 1,
                                                harnessVersion: 1),
                               harness: entry(version: 1))
        let s3 = try await service.newSession(agentID: "test.agent",
                                              consumerID: "c", connectionID: "conn-1")
        XCTAssertEqual(s3.profile.version, 1)
    }

    func testSessionBoundToConsumerAndConnection() async throws {
        let service = AgentService(clock: Clock())
        await service.register(profile: profile(id: "test.agent", version: 1,
                                                harnessVersion: 1),
                               harness: entry(version: 1))
        let s = try await service.newSession(agentID: "test.agent",
                                             consumerID: "c1", connectionID: "conn-1")
        // Same consumer, different connection: denied.
        let crossConn = await service.session(s.id, consumerID: "c1", connectionID: "conn-2")
        XCTAssertNil(crossConn)
        // Different consumer entirely: denied.
        let crossConsumer = await service.session(s.id, consumerID: "c2", connectionID: "conn-1")
        XCTAssertNil(crossConsumer)
        let own = await service.session(s.id, consumerID: "c1", connectionID: "conn-1")
        XCTAssertNotNil(own)
    }

    func testUnregisteredAndMissingHarnessRefused() async throws {
        let service = AgentService(clock: Clock())
        do {
            _ = try await service.newSession(agentID: "ghost",
                                             consumerID: "c", connectionID: "k")
            XCTFail("expected notFound")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .notFound) }
    }

    func testCloseConnectionRemovesOnlyOwnedSessions() async throws {
        let service = AgentService(clock: Clock())
        await service.register(profile: profile(id: "test.agent", version: 1,
                                                harnessVersion: 1),
                               harness: entry(version: 1))
        let s1 = try await service.newSession(agentID: "test.agent",
                                              consumerID: "c", connectionID: "conn-1")
        let s2 = try await service.newSession(agentID: "test.agent",
                                              consumerID: "c", connectionID: "conn-2")
        let closed = await service.closeConnection("conn-1")
        XCTAssertEqual(closed.map(\.id), [s1.id])
        let gone = await service.session(s1.id, consumerID: "c", connectionID: "conn-1")
        XCTAssertNil(gone)
        let kept = await service.session(s2.id, consumerID: "c", connectionID: "conn-2")
        XCTAssertNotNil(kept)
    }

    /// Reference harness: deterministic, zero model calls, refuses anything
    /// other than the single `status` command.
    func testReferenceHarnessMakesZeroModelCalls() async throws {
        let modelCalls = Counter()
        let counting = ModelClient { _ in
            modelCalls.increment()
            throw PlatformError(.internal)
        }
        let mlCounting = MLClient { _ in
            modelCalls.increment()
            throw PlatformError(.internal)
        }
        let context = AgentContext(
            sessionID: "s", runID: "r",
            statusSnapshot: { .object(["resource": .object([
                "thermal": .string("nominal"),
                "memoryPressure": .string("normal")]),
                "counts": .object(["activeInference": .int(0), "pendingInference": .int(0)]),
                "appleAvailability": .string("unavailable")]) },
            model: counting, ml: mlCounting, isCancelled: { false })

        let chunks = StringBag()
        let stop = await ReferenceStatusHarness().run(
            input: [.text("status")], context: context,
            emit: { if case .messageChunk(let t) = $0 { chunks.append(t) } })
        XCTAssertEqual(stop, .endTurn)
        XCTAssertTrue(chunks.all.contains { $0.contains("thermal=nominal") })
        XCTAssertEqual(modelCalls.count, 0)

        let refusal = await ReferenceStatusHarness().run(
            input: [.text("do something else")], context: context,
            emit: { _ in })
        XCTAssertEqual(refusal, .refusal)
        XCTAssertEqual(modelCalls.count, 0)

        // Resource links are accepted metadata and never fetched.
        let withLink = await ReferenceStatusHarness().run(
            input: [.resourceLink(uri: "file:///etc/passwd", name: "x"),
                    .text("status")],
            context: context, emit: { _ in })
        XCTAssertEqual(withLink, .endTurn)
    }

    /// Live sessions per connection are bounded; other connections are
    /// unaffected.
    func testSessionCountBoundPerConnection() async throws {
        let service = AgentService(clock: Clock())
        await service.register(profile: profile(id: "test.agent", version: 1,
                                                harnessVersion: 1),
                               harness: entry(version: 1))
        for _ in 0..<PlatformLimits.sessionsPerConnection {
            _ = try await service.newSession(agentID: "test.agent",
                                             consumerID: "c", connectionID: "conn-1")
        }
        do {
            _ = try await service.newSession(agentID: "test.agent",
                                             consumerID: "c", connectionID: "conn-1")
            XCTFail("expected capacityLimited")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .capacityLimited) }
        // A different connection still opens sessions.
        _ = try await service.newSession(agentID: "test.agent",
                                         consumerID: "c", connectionID: "conn-2")
    }

    /// beginPrompt claims the single turn atomically: a second turn on the
    /// same session is a conflict until the first turn's teardown releases.
    func testBeginPromptAtomicClaimAndRelease() async throws {
        let service = AgentService(clock: Clock())
        await service.register(profile: profile(id: "test.agent", version: 1,
                                                harnessVersion: 1),
                               harness: entry(version: 1))
        let s = try await service.newSession(agentID: "test.agent",
                                             consumerID: "c", connectionID: "conn-1")
        // Wrong binding is refused before the claim is even considered.
        do {
            _ = try await service.beginPrompt(sessionID: s.id, consumerID: "c",
                                              connectionID: "conn-2")
            XCTFail("expected sessionClosed")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .sessionClosed) }
        do {
            _ = try await service.beginPrompt(sessionID: s.id, consumerID: "c2",
                                              connectionID: "conn-1")
            XCTFail("expected sessionClosed")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .sessionClosed) }

        let claimed = try await service.beginPrompt(
            sessionID: s.id, consumerID: "c", connectionID: "conn-1")
        XCTAssertTrue(claimed.promptActive)
        // A racing turn conflicts while the first is claimed.
        do {
            _ = try await service.beginPrompt(sessionID: s.id, consumerID: "c",
                                              connectionID: "conn-1")
            XCTFail("expected conflict")
        } catch let e as PlatformError { XCTAssertEqual(e.code, .conflict) }
        // The first turn's teardown releases the slot.
        await service.setPromptActive(s.id, false)
        _ = try await service.beginPrompt(sessionID: s.id, consumerID: "c",
                                          connectionID: "conn-1")
    }

    /// Reference agent only exists when explicitly enabled.
    func testReferenceAgentGatedOnOption() async throws {
        let off = try await makeStack(enableReferenceAgent: false)
        defer { off.root.releaseLock() }
        let registry = await off.supervisor.registrySnapshot()
        XCTAssertEqual(registry.objectValue?["agents"], .array([]))

        let on = try await makeStack(enableReferenceAgent: true)
        defer { on.root.releaseLock() }
        let ids = await on.supervisor.agentService.profileIDs()
        XCTAssertEqual(ids, ["reference.status"])
    }
}
