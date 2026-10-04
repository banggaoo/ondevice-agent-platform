import Foundation

/// Conservative development bounds, not calibrated model or device capacity.
public enum PlatformLimits {
    public static let activeInference = 1
    public static let pendingInference = 4
    public static let requestBodyBytes = 24 * 1024 * 1024
    public static let requestHeaderBytes = 16 * 1024
    public static let connections = 32
    public static let connectionReadSeconds: TimeInterval = 5
    /// Agent-sized generations can run minutes on a small local model; the
    /// deadline is a runaway bound, not a latency target.
    public static let inferenceDeadlineSeconds: TimeInterval = 300
    /// Queued work survives resource deferrals (fair thermal, low power)
    /// for this long; deferrals re-evaluate on each resource sample.
    public static let queueDeadlineSeconds: TimeInterval = 60
    public static let cancellationGraceSeconds: TimeInterval = 5
    public static let resourceSampleSeconds: TimeInterval = 1
    public static let resourceMaxAgeSeconds: TimeInterval = 5
    /// Global ceiling and default for one completion; per-profile
    /// `maxOutputTokens` caps lower. Agentic clients need multi-KB edits.
    public static let outputTokens = 8_192
    public static let chatMessages = 256
    public static let chatTextBytes = 256 * 1024
    /// Declared tool definitions per request (schemas count toward
    /// chatTextBytes) and tool calls carried by a single assistant message.
    public static let chatTools = 64
    public static let chatToolCallsPerMessage = 16
    public static let chatImagesPerRequest = 4
    /// Decoded image bytes per request (base64 is undone before this counts).
    public static let chatImageBytes = 16 * 1024 * 1024
    /// Conservative input bounds, not a calibrated device-memory guarantee.
    public static let chatImageDimension = 8_192
    public static let chatImagePixels = 8 * 1024 * 1024
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
