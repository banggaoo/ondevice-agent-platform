import Foundation

public enum ModelKind: String, Sendable, Codable {
    case llm
    case ml
}

/// Provider category availability is reported independently of registered
/// model aliases; availability is never fabricated as a serving profile.
public enum ProviderCategory: String, Sendable, Codable, CaseIterable {
    case appleFoundationModels
    case ownedOpenWeight
    case typedML
}

public enum CategoryStatus: String, Sendable, Codable {
    case qualified       // at least one executable route is registered
    case observing       // platform can observe availability, nothing qualified
    case notConfigured   // no registered/qualified profile exists
}

/// Immutable registered model record. `inputSchema`/`outputSchema` apply to
/// kind .ml; context/output token bounds apply to kind .llm.
public struct ModelProfile: Sendable, Codable, Equatable {
    public let alias: String
    public let providerID: String
    public let kind: ModelKind
    public let task: String
    public let purposes: [String]
    public let inputSchema: [String: FeatureType]?
    public let outputSchema: [String: FeatureType]?
    public let capabilities: [String]
    public let maxInputBytes: Int?
    public let maxOutputTokens: Int?

    public init(alias: String, providerID: String, kind: ModelKind, task: String,
                purposes: [String] = [], inputSchema: [String: FeatureType]? = nil,
                outputSchema: [String: FeatureType]? = nil, capabilities: [String] = [],
                maxInputBytes: Int? = nil, maxOutputTokens: Int? = nil) {
        self.alias = alias
        self.providerID = providerID
        self.kind = kind
        self.task = task
        self.purposes = purposes
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.capabilities = capabilities
        self.maxInputBytes = maxInputBytes
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Immutable agent registration. `implementationRef` names reviewed,
/// compiled-in code - never an arbitrary loadable path.
public struct AgentProfile: Sendable, Codable, Equatable {
    public let id: String
    public let version: Int
    public let harnessID: String
    public let harnessVersion: Int
    public let stateSchemaVersion: Int
    public let toolScope: [String]
    public let modelProfileAlias: String?
    public let implementationRef: String

    public init(id: String, version: Int, harnessID: String, harnessVersion: Int,
                stateSchemaVersion: Int, toolScope: [String] = [],
                modelProfileAlias: String? = nil, implementationRef: String) {
        self.id = id
        self.version = version
        self.harnessID = harnessID
        self.harnessVersion = harnessVersion
        self.stateSchemaVersion = stateSchemaVersion
        self.toolScope = toolScope
        self.modelProfileAlias = modelProfileAlias
        self.implementationRef = implementationRef
    }
}
