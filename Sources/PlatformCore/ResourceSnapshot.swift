import Foundation

public enum ThermalLevel: String, Sendable, Codable {
    case unknown
    case nominal
    case fair
    case serious
    case critical
}

public enum MemoryPressureLevel: String, Sendable, Codable {
    case unknown
    case normal
    case warning
    case critical
}

/// Point-in-time native observation. Unknown is a real state - never
/// substituted with an invented "normal" reading.
public struct ResourceSnapshot: Sendable, Equatable {
    public let thermal: ThermalLevel
    public let memoryPressure: MemoryPressureLevel
    public let lowPowerMode: Bool?
    public let capturedAt: Date

    public init(thermal: ThermalLevel, memoryPressure: MemoryPressureLevel,
                lowPowerMode: Bool?, capturedAt: Date) {
        self.thermal = thermal
        self.memoryPressure = memoryPressure
        self.lowPowerMode = lowPowerMode
        self.capturedAt = capturedAt
    }

    public static let unknown = ResourceSnapshot(
        thermal: .unknown, memoryPressure: .unknown,
        lowPowerMode: nil, capturedAt: .distantPast
    )
}

public enum ResourceVerdict: Sendable, Equatable {
    case admit
    case deferLoad          // truthful deferral: reduced profile unqualified
    case denyAndCancel      // block new inference and cancel children
}

public enum ResourcePolicy {
    /// M1 admits only on fresh, known-healthy observations. No qualified
    /// reduced-power profile exists, so fair thermal or low power defers.
    public static func evaluate(_ snapshot: ResourceSnapshot, at now: Date) -> ResourceVerdict {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        if snapshot.thermal == .unknown || snapshot.memoryPressure == .unknown { return .denyAndCancel }
        if age > PlatformLimits.resourceMaxAgeSeconds { return .denyAndCancel }
        switch snapshot.thermal {
        case .serious, .critical: return .denyAndCancel
        case .fair:
            if snapshot.lowPowerMode == true { return .deferLoad }
            return .deferLoad
        case .nominal, .unknown: break
        }
        if snapshot.lowPowerMode == true { return .deferLoad }
        switch snapshot.memoryPressure {
        case .warning, .critical: return .denyAndCancel
        case .normal, .unknown: break
        }
        return .admit
    }
}

/// Source of observations, injectable for deterministic tests.
public protocol ResourceSource: Sendable {
    func currentSnapshot() -> ResourceSnapshot
    func start(onChange: @escaping @Sendable (ResourceSnapshot) -> Void)
    func stop()
}
