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

public enum MemoryPressureSource: String, Sendable, Codable {
    case dispatchEvent = "dispatch_event"
    case availablePercentEstimate = "available_percent_estimate"
    case unavailable
    case unspecified
}

/// Point-in-time resource state with explicit observation provenance.
public struct ResourceSnapshot: Sendable, Equatable {
    public let thermal: ThermalLevel
    public let memoryPressure: MemoryPressureLevel
    public let lowPowerMode: Bool?
    public let capturedAt: Date
    public let memoryPressureSource: MemoryPressureSource

    public init(thermal: ThermalLevel, memoryPressure: MemoryPressureLevel,
                lowPowerMode: Bool?, capturedAt: Date,
                memoryPressureSource: MemoryPressureSource = .unspecified) {
        self.thermal = thermal
        self.memoryPressure = memoryPressure
        self.lowPowerMode = lowPowerMode
        self.capturedAt = capturedAt
        self.memoryPressureSource = memoryPressureSource
    }

    public static let unknown = ResourceSnapshot(
        thermal: .unknown, memoryPressure: .unknown,
        lowPowerMode: nil, capturedAt: .distantPast
    )
}

public enum ResourceVerdict: String, Sendable {
    case admit = "admit"
    case deferLoad = "defer_load"        // truthful deferral: reduced profile unqualified
    case denyAndCancel = "deny_and_cancel"  // block new inference and cancel children
}

public enum ResourcePolicy {
    /// M1 admits only on fresh, known-healthy observations. No qualified
    /// reduced-power profile exists, so fair thermal or low power defers.
    public static func evaluate(_ snapshot: ResourceSnapshot, at now: Date) -> ResourceVerdict {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        if snapshot.thermal == .unknown || snapshot.memoryPressure == .unknown { return .denyAndCancel }
        guard age.isFinite, age >= 0, age <= PlatformLimits.resourceMaxAgeSeconds,
              let lowPowerMode = snapshot.lowPowerMode else {
            return .denyAndCancel
        }
        // Pressure escalation must win over a reduced-power deferral.
        if snapshot.thermal == .serious || snapshot.thermal == .critical
            || snapshot.memoryPressure == .warning || snapshot.memoryPressure == .critical {
            return .denyAndCancel
        }
        if snapshot.thermal == .fair || lowPowerMode {
            return .deferLoad
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
