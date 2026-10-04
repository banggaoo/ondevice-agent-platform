import XCTest
import Dispatch
import PlatformTestSupport
@testable import PlatformCore

/// Native monitor regressions: delivered-event decoding, periodic publish
/// freshness, and start/stop epoch hygiene. Policy verdicts stay in
/// MLAndResourceTests and are unchanged. These tests do not induce global
/// memory pressure; event-bit decoding is tested separately at the static
/// decoder, and observed pressure assertions stay at the honest unknown.
final class NativeResourceMonitorTests: XCTestCase {

    /// Lock-confined capture for monitor callbacks.
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ResourceSnapshot] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var snapshots: [ResourceSnapshot] { lock.lock(); defer { lock.unlock() }; return items }
        func append(_ s: ResourceSnapshot) { lock.lock(); items.append(s); lock.unlock() }
    }

    func testPressureEventDecoder() {
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(for: []), .unknown)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(for: [.normal]), .normal)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(for: [.warning]), .warning)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(for: [.critical]), .critical)
        // Several known bits delivered together resolve to the worst.
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(for: [.normal, .warning]), .warning)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(for: [.normal, .critical]), .critical)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(for: [.warning, .critical]), .critical)
        // Unrecognized raw bits are never silently translated to normal.
        XCTAssertEqual(
            NativeResourceMonitor.pressureLevel(
                for: DispatchSource.MemoryPressureEvent(rawValue: 0x80)), .unknown)
        // A known bit mixed with an unsupported one fails closed too:
        // the whole value is unknown, not the best recognizable reading.
        XCTAssertEqual(
            NativeResourceMonitor.pressureLevel(
                for: [.normal, DispatchSource.MemoryPressureEvent(rawValue: 0x80)]),
            .unknown)
        XCTAssertEqual(
            NativeResourceMonitor.pressureLevel(
                for: [.critical, DispatchSource.MemoryPressureEvent(rawValue: 0x80)]),
            .unknown)
    }

    /// Before monitoring starts, no pressure event can have been delivered,
    /// so the level is unknown - never assumed normal. The sysctl fallback
    /// only applies inside a live epoch.
    func testPreStartSnapshotPressureUnknown() {
        let monitor = NativeResourceMonitor()
        XCTAssertEqual(monitor.currentSnapshot().memoryPressure, .unknown)
    }

    /// The fallback gauge mapping is a pure function of the kernel's
    /// percent-available reading; out-of-range readings stay unknown rather
    /// than manufacturing a normal.
    func testFallbackPercentMapping() {
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: 0), .critical)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: 10), .critical)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: 11), .warning)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: 19), .warning)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: 20), .normal)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: 100), .normal)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: -1), .unknown)
        XCTAssertEqual(NativeResourceMonitor.pressureLevel(forPercentAvailable: 101), .unknown)
    }

    /// A delivered event is authoritative forever: even when the kernel
    /// gauge estimate would report a level, a delivered unknown stays
    /// honestly unknown and is labeled dispatch_event - never replaced by
    /// the estimate.
    func testDeliveredUnknownBeatsFallbackEstimate() {
        let monitor = NativeResourceMonitor()
        monitor._testRecordDeliveredPressure(
            DispatchSource.MemoryPressureEvent(rawValue: 0x80))
        let snap = monitor.currentSnapshot()
        XCTAssertEqual(snap.memoryPressure, .unknown)
        XCTAssertEqual(snap.memoryPressureSource, .dispatchEvent)
        // A delivered known level is also labeled by its true provenance.
        monitor._testRecordDeliveredPressure([.warning])
        let warned = monitor.currentSnapshot()
        XCTAssertEqual(warned.memoryPressure, .warning)
        XCTAssertEqual(warned.memoryPressureSource, .dispatchEvent)
    }

    /// Inside a live epoch with no delivered pressure event, the snapshot's
    /// pressure comes from the kernel gauge instead of staying unknown -
    /// this is the fix for permanent denial on a healthy idle machine.
    func testLiveEpochFallsBackToKernelGauge() async throws {
        let clock = ManualClock()
        let monitor = NativeResourceMonitor(clock: clock.clock)
        defer { monitor.stop() }
        let box = SnapshotBox()
        monitor.start { snap in box.append(snap) }
        try await expectTrue(await pollUntil(3) { box.count >= 1 },
                           "monitor did not publish an initial sample")
        // The fallback reads the same sysctl: when the gauge is readable the
        // sampled pressure is a real level, and when the read fails both
        // stay honestly unknown. Equality-of-availability is the assertion.
        let gauge = NativeResourceMonitor.observedFallbackPressure()
        XCTAssertEqual(box.snapshots[0].memoryPressure == .unknown,
                       gauge == .unknown)
    }

    /// The periodic timer must publish each sample through onChange:
    /// freshness drives admission, and a sample that only updated an
    /// internal field let the supervisor's copy go stale. No thermal or
    /// pressure event needs to arrive for this to work.
    func testTimerPublishesFreshSnapshots() async throws {
        let clock = ManualClock()
        let monitor = NativeResourceMonitor(clock: clock.clock)
        defer { monitor.stop() }
        let box = SnapshotBox()
        monitor.start { snap in box.append(snap) }
        try await expectTrue(await pollUntil(3) { box.count >= 1 },
                           "timer did not publish an initial sample")
        clock.advance(by: PlatformLimits.resourceMaxAgeSeconds + 10)
        let expected = clock.now
        try await expectTrue(await pollUntil(3) {
            box.snapshots.contains { $0.capturedAt == expected }
        }, "no fresh sample after manual time advanced")
    }

    /// End to end: the supervisor's reported resource timestamp must keep
    /// advancing on timer samples alone, even with no pushed thermal or
    /// pressure events.
    func testSupervisorSnapshotAdvancesWithTimer() async throws {
        let clock = ManualClock()
        let monitor = NativeResourceMonitor(clock: clock.clock)
        defer { monitor.stop() }
        let root = try preparedRoot(tempRootURL())
        defer { root.releaseLock() }
        let supervisor = PlatformSupervisor(
            root: root,
            resourceSource: monitor, clock: clock.clock)
        try await supervisor.start()
        clock.advance(by: PlatformLimits.resourceMaxAgeSeconds + 10)
        let expected = clock.now.timeIntervalSince1970
        try await expectTrue(await pollUntil(3) {
            let snap = await supervisor.statusSnapshot()
            guard case .double(let t) = snap.objectValue?["resource"]?
                .objectValue?["capturedAt"] else { return false }
            return t == expected
        }, "supervisor snapshot did not advance with timer samples")
    }

    /// stop() ends periodic callbacks and clears the stored pressure; a
    /// later start() begins a clean epoch rather than inheriting stale
    /// state. The settle window covers a handler already in flight at
    /// stop, so the count assertion is not racy.
    func testStopEndsCallbacksAndNewEpochStartsClean() async throws {
        let clock = ManualClock()
        let monitor = NativeResourceMonitor(clock: clock.clock)
        defer { monitor.stop() }
        let box = SnapshotBox()
        monitor.start { snap in box.append(snap) }
        try await expectTrue(await pollUntil(3) { box.count >= 1 })
        monitor.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let countAfterStop = box.count
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(box.count, countAfterStop)
        // Deterministic: stop() resets the stored level and the bumped
        // generation lets no old handler repopulate it.
        XCTAssertEqual(monitor.currentSnapshot().memoryPressure, .unknown)

        // A new monitoring epoch delivers fresh callbacks again and starts
        // from no inherited pressure observation.
        let second = SnapshotBox()
        monitor.start { snap in second.append(snap) }
        try await expectTrue(await pollUntil(3) { second.count >= 1 },
                           "new epoch did not resume periodic samples")
        monitor.stop()
        XCTAssertEqual(monitor.currentSnapshot().memoryPressure, .unknown)
    }

    /// start() while an epoch is live is a no-op: the original callback
    /// keeps receiving and no second callback stream is allocated.
    /// stop() still ends the epoch.
    func testRepeatedStartIsIdempotentWhileActive() async throws {
        let clock = ManualClock()
        let monitor = NativeResourceMonitor(clock: clock.clock)
        defer { monitor.stop() }
        let first = SnapshotBox()
        monitor.start { snap in first.append(snap) }
        try await expectTrue(await pollUntil(3) { first.count >= 1 })

        let second = SnapshotBox()
        monitor.start { snap in second.append(snap) }
        let countAtRestart = first.count
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(second.count, 0,
                       "repeated start must not allocate a second callback stream")
        XCTAssertGreaterThan(first.count, countAtRestart,
                             "repeated start replaced the live callback")

        monitor.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let countAfterStop = first.count
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(first.count, countAfterStop)
    }
}
