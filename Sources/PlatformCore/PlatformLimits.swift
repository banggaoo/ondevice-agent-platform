import Foundation

/// Conservative development bounds, not calibrated model or device capacity.
public enum PlatformLimits {
    public static let activeInference = 1
    public static let pendingInference = 4
    public static let requestBodyBytes = 256 * 1024
    public static let requestHeaderBytes = 16 * 1024
    public static let connections = 32
    public static let connectionReadSeconds: TimeInterval = 5
    public static let inferenceDeadlineSeconds: TimeInterval = 30
    public static let queueDeadlineSeconds: TimeInterval = 10
    public static let cancellationGraceSeconds: TimeInterval = 5
    public static let resourceSampleSeconds: TimeInterval = 1
    public static let resourceMaxAgeSeconds: TimeInterval = 5
    public static let outputTokens = 512
    public static let chatMessages = 64
    public static let chatTextBytes = 64 * 1024
    public static let agentPromptBytes = 16 * 1024
    public static let agentDeadlineSeconds: TimeInterval = 120
    public static let agentGeneratedTokenReservations = 2_048
    public static let agentToolRounds = 6
    public static let mlInputBytes = 16 * 1024
    public static let agentConnections = 16
    public static let sessionsPerConnection = 8
    public static let consoleSessions = 8
    public static let consoleSessionSeconds: TimeInterval = 15 * 60
    public static let eventSubscribers = 8
    public static let loginAttemptsPerMinute = 10
    public static let requestsPerConsumerPerMinute = 120
    public static let durableRecords = 1_000
    public static let databaseBytes = 16 * 1024 * 1024
}
