import Foundation
import Dispatch

/// ProcessInfo thermal/power and DispatchSource memory-pressure observations.
/// The startup kernel percent-gauge fallback is a platform policy estimate,
/// reported separately from delivered OS pressure events; it is not calibrated
/// model headroom or an OS-documented pressure classification.
///
/// Pressure semantics: `DispatchSource.data` is the set of *delivered*
/// pressure events and is only meaningful inside that source's event
/// handler; `mask` is the constant subscription set, never an observation.
/// The last delivered level is stored and stays authoritative once seen.
/// macOS does not deliver an initial event to a fresh subscriber, so a
/// healthy machine would otherwise sit at `.unknown` forever and fail
/// admission closed indefinitely. While an epoch is live and no event has
/// been delivered, `sample()` reads the kernel's percent-available gauge
/// instead; a sysctl failure keeps the honestly-unknown state.
public final class NativeResourceMonitor: ResourceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: DispatchSourceTimer?
    private var thermalObs: NSObjectProtocol?
    private var powerObs: NSObjectProtocol?
    /// Last pressure level actually delivered by a source event; unknown
    /// until the OS delivers one and reset on every stop/start epoch.
    private var lastPressure: MemoryPressureLevel = .unknown
    private var receivedPressureEvent = false
    /// Epoch counter: handlers from a stopped or superseded start() bail.
    private var generation = 0
    /// True while an epoch's sources/observers are live; a repeated start()
    /// must not overwrite them.
    private var monitoring = false
    private let clock: Clock

    public init(clock: Clock = Clock()) {
        self.clock = clock
    }

    /// Maps delivered memory-pressure event bits to a level. Critical wins
    /// over warning over normal when several known bits arrive together.
    /// Any unrecognized bit fails closed: the whole value is unknown, never
    /// partially normal.
    static func pressureLevel(for events: DispatchSource.MemoryPressureEvent)
        -> MemoryPressureLevel {
        let known: DispatchSource.MemoryPressureEvent = [.normal, .warning, .critical]
        guard events.isSubset(of: known) else { return .unknown }
        if events.contains(.critical) { return .critical }
        if events.contains(.warning) { return .warning }
        if events.contains(.normal) { return .normal }
        return .unknown
    }

    /// Reads `kern.memorystatus_level`, the kernel's percent-of-memory-
    /// available gauge (the same gauge WebKit's memory-pressure handler
    /// polls). Consulted only while a monitoring epoch is live and no
    /// pressure event has been delivered yet; any read failure leaves the
    /// pressure honestly unknown. Thresholds below are platform policy
    /// constants, not OS-documented semantics.
    static func observedFallbackPressure() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else {
            return .unknown
        }
        return pressureLevel(forPercentAvailable: Int(level))
    }

    /// Maps the percent-available gauge to a level. Values observed on the
    /// development host: ~35 under sustained build load, higher when idle.
    /// Conservative cutoffs err toward reporting pressure when memory is
    /// genuinely scarce rather than masking it; a gauge value outside
    /// 0-100 is malformed and stays honestly unknown.
    static func pressureLevel(forPercentAvailable percent: Int) -> MemoryPressureLevel {
        switch percent {
        case 0...10: return .critical
        case 11...19: return .warning
        case 20...100: return .normal
        default: return .unknown
        }
    }

    public func currentSnapshot() -> ResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return sample()
    }

    public func start(onChange: @escaping @Sendable (ResourceSnapshot) -> Void) {
        let notify: @Sendable (ResourceSnapshot) -> Void = { snapshot in onChange(snapshot) }
        lock.lock()
        // A second start while an epoch is live is a no-op: its sources,
        // observers, and callback must not be replaced. start after stop
        // begins a fresh epoch.
        guard !monitoring else { lock.unlock(); return }
        monitoring = true
        generation += 1
        let gen = generation
        lastPressure = .unknown
        receivedPressureEvent = false

        // Subscribe to normal as well so a recovery is observable; the mask
        // is a subscription, and only .data read inside the handler is a
        // delivered observation.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.lock.lock()
            guard self.generation == gen else { self.lock.unlock(); return }
            self.recordDeliveredPressure(events)
            let snap = self.sample()
            self.lock.unlock()
            notify(snap)
        }
        source.resume()
        pressureSource = source

        // The periodic sampler also publishes: freshness drives admission,
        // so a snapshot that only updates a local field would go stale.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: PlatformLimits.resourceSampleSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.generation == gen else { self.lock.unlock(); return }
            let snap = self.sample()
            self.lock.unlock()
            notify(snap)
        }
        timer.resume()
        self.timer = timer

        thermalObs = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            guard self.generation == gen else { self.lock.unlock(); return }
            let snap = self.sample()
            self.lock.unlock()
            notify(snap)
        }
        powerObs = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            guard self.generation == gen else { self.lock.unlock(); return }
            let snap = self.sample()
            self.lock.unlock()
            notify(snap)
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        monitoring = false
        generation += 1
        lastPressure = .unknown
        receivedPressureEvent = false
        pressureSource?.cancel()
        timer?.cancel()
        pressureSource = nil
        timer = nil
        if let t = thermalObs { NotificationCenter.default.removeObserver(t) }
        if let p = powerObs { NotificationCenter.default.removeObserver(p) }
        thermalObs = nil
        powerObs = nil
        lock.unlock()
    }

    /// Records a delivered pressure event. Must be called under `lock`.
    private func recordDeliveredPressure(
        _ events: DispatchSource.MemoryPressureEvent) {
        receivedPressureEvent = true
        lastPressure = Self.pressureLevel(for: events)
    }

    /// Test seam: record what the pressure event handler would record.
    func _testRecordDeliveredPressure(
        _ events: DispatchSource.MemoryPressureEvent) {
        lock.lock()
        recordDeliveredPressure(events)
        lock.unlock()
    }

    /// Reads ProcessInfo fresh plus the stored last-delivered pressure.
    /// Must be called under `lock`; never touches .mask or .data.
    /// Before the epoch's first delivered event, the kernel percent gauge
    /// stands in for the missing observation so a healthy machine is not
    /// denied forever; pre-start samples stay honestly unknown.
    private func sample() -> ResourceSnapshot {
        let info = ProcessInfo.processInfo
        let thermal: ThermalLevel = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        default: .unknown
        }
        let pressure: MemoryPressureLevel
        let pressureSource: MemoryPressureSource
        if receivedPressureEvent {
            pressure = lastPressure
            pressureSource = .dispatchEvent
        } else if monitoring {
            pressure = Self.observedFallbackPressure()
            pressureSource = pressure == .unknown ? .unavailable : .availablePercentEstimate
        } else {
            pressure = .unknown
            pressureSource = .unavailable
        }
        return ResourceSnapshot(
            thermal: thermal,
            memoryPressure: pressure,
            lowPowerMode: info.isLowPowerModeEnabled,
            capturedAt: clock.now,
            memoryPressureSource: pressureSource
        )
    }
}
