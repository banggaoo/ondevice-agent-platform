import Foundation
import Dispatch

/// Public-API observations only: ProcessInfo thermal/low-power and a
/// DispatchSource memory-pressure listener. No private sysctls and no
/// os_proc_available_memory (unavailable on macOS in this SDK).
public final class NativeResourceMonitor: ResourceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: DispatchSourceTimer?
    private var thermalObs: NSObjectProtocol?
    private var powerObs: NSObjectProtocol?
    private var latest: ResourceSnapshot = .unknown
    private let clock: Clock

    public init(clock: Clock = Clock()) {
        self.clock = clock
    }

    public func currentSnapshot() -> ResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return sample()
    }

    public func start(onChange: @escaping @Sendable (ResourceSnapshot) -> Void) {
        let notify: @Sendable (ResourceSnapshot) -> Void = { snapshot in onChange(snapshot) }
        lock.lock()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.latest = self.sample()
            let snap = self.latest
            self.lock.unlock()
            notify(snap)
        }
        source.resume()
        pressureSource = source

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: PlatformLimits.resourceSampleSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.latest = self.sample()
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer

        thermalObs = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.latest = self.sample()
            let snap = self.latest
            self.lock.unlock()
            notify(snap)
        }
        powerObs = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.latest = self.sample()
            let snap = self.latest
            self.lock.unlock()
            notify(snap)
        }
        latest = sample()
        lock.unlock()
    }

    public func stop() {
        lock.lock()
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

    private func sample() -> ResourceSnapshot {
        let info = ProcessInfo.processInfo
        let thermal: ThermalLevel = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        default: .unknown
        }
        var pressure: MemoryPressureLevel = .normal
        if let src = pressureSource {
            if src.mask.contains(.critical) { pressure = .critical }
            else if src.mask.contains(.warning) { pressure = .warning }
        }
        return ResourceSnapshot(
            thermal: thermal,
            memoryPressure: pressure,
            lowPowerMode: info.isLowPowerModeEnabled,
            capturedAt: clock.now
        )
    }
}
