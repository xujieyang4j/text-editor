import Foundation

/// Immutable worker bytes and the exact effective capabilities read from one
/// descriptor-validated installed plugin.
public struct PluginWorkerPackage: Equatable, Sendable {
    public let pluginID: String
    public let pluginName: String
    public let source: Data
    public let sourceIntegrity: SHA256Integrity
    public let permissions: [PluginPermission]

    public init(
        pluginID: String,
        pluginName: String,
        source: Data,
        sourceIntegrity: SHA256Integrity,
        permissions: [PluginPermission]
    ) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.source = source
        self.sourceIntegrity = sourceIntegrity
        self.permissions = permissions
    }
}

public enum PluginWorkerPackageError: Error, Equatable, LocalizedError, Sendable {
    case workerUnavailable
    case manifestChanged
    case invalidWorkerEncoding

    public var errorDescription: String? {
        switch self {
        case .workerUnavailable:
            "This plugin does not declare an executable worker."
        case .manifestChanged:
            "The installed plugin manifest changed after it was loaded."
        case .invalidWorkerEncoding:
            "The plugin worker must contain valid UTF-8 JavaScript."
        }
    }
}
