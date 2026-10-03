import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Observed - not generated - Apple Foundation Models availability. Framework
/// presence is not a qualified serving route and never fabricates a profile.
public enum AppleModelAvailability: Sendable {
    public enum Status: String, Sendable {
        case available
        case unavailable
        case notPresent
    }

    public static func status() -> Status {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable:
            return .unavailable
        @unknown default:
            return .unavailable
        }
        #else
        return .notPresent
        #endif
    }
}
