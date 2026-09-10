import Darwin
import Foundation

/// Storage never evaluates worker bytes. Executable support means only that a
/// descriptor-validated package may be handed to the separately approved,
/// isolated runtime.
public enum PluginWorkerExecutionSupport: String, Equatable, Sendable {
    case unsupported
    case isolatedProcess
}

/// Project-owned activation and grants. This state lives beside the workspace,
/// never in user defaults, so opening two projects cannot leak grants between them.
public struct PluginProjectState: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var enabled: [String: Bool]
    public var permissions: [String: [PluginPermission]]
    public var marketplaceSources: [String]

    public init(
        formatVersion: Int = PluginProjectState.currentFormatVersion,
        enabled: [String: Bool] = [:],
        permissions: [String: [PluginPermission]] = [:],
        marketplaceSources: [String] = []
    ) {
        self.formatVersion = formatVersion
        self.enabled = enabled
        self.permissions = permissions
        self.marketplaceSources = marketplaceSources
    }

    public static let empty = PluginProjectState()
}

public struct InstalledPlugin: Equatable, Identifiable, Sendable {
    public var id: String { manifest.id }

    public let manifest: PluginManifest
    public let directoryURL: URL
    public let isEnabled: Bool
    public let grantedPermissions: [PluginPermission]
    public let effectivePermissions: [PluginPermission]
    public let workerExecutionSupport: PluginWorkerExecutionSupport
}

public enum PluginStoreError: Error, Equatable, Sendable {
    case invalidWorkspace(URL)
    case invalidSource(URL)
    case sourceOverlapsPluginStorage(URL)
    case unsafePluginStorage(URL)
    case missingManifest
    case pluginAlreadyInstalled(String)
    case pluginNotInstalled(String)
    case manifestIDDoesNotMatchDirectory(expected: String, actual: String)
    case symbolicLinkEncountered(String)
    case unsupportedFileType(String)
    case copyLimitExceeded
    case sourceChangedDuringInstallation
    case workerFileMissing(String)
    case invalidMarketplacePackage
    case unsupportedStateVersion(Int)
    case stateTooLarge
    case fileSystem(operation: String, path: String, code: Int32)
}

extension PluginStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidWorkspace(url):
            "The plugin workspace is not a real local directory: \(url.path)"
        case let .invalidSource(url):
            "The plugin source is not a real local directory: \(url.path)"
        case let .sourceOverlapsPluginStorage(url):
            "The plugin source overlaps the workspace plugin storage: \(url.path)"
        case let .unsafePluginStorage(url):
            "The workspace plugin storage is not a safe directory: \(url.path)"
        case .missingManifest:
            "The selected directory does not contain a regular plugin.json file."
        case let .pluginAlreadyInstalled(id):
            "Plugin ‘\(id)’ is already installed."
        case let .pluginNotInstalled(id):
            "Plugin ‘\(id)’ is not installed."
        case let .manifestIDDoesNotMatchDirectory(expected, actual):
            "Plugin directory ‘\(expected)’ contains manifest ID ‘\(actual)’."
        case let .symbolicLinkEncountered(path):
            "Plugin packages may not contain symbolic links: \(path)"
        case let .unsupportedFileType(path):
            "Plugin packages may contain only directories and regular files: \(path)"
        case .copyLimitExceeded:
            "The plugin package exceeds the native installation budget."
        case .sourceChangedDuringInstallation:
            "The plugin manifest changed while it was being installed."
        case let .workerFileMissing(path):
            "The declared worker is missing or unsafe: \(path)"
        case .invalidMarketplacePackage:
            "The verified marketplace package is inconsistent."
        case let .unsupportedStateVersion(version):
            "Plugin project state version \(version) is not supported."
        case .stateTooLarge:
            "The plugin project state exceeds the supported size limit."
        case let .fileSystem(operation, path, code):
            "Plugin file operation ‘\(operation)’ failed for \(path) (errno \(code))."
        }
    }
}

/// Workspace-scoped installation and project-state persistence.
///
/// Security-sensitive traversal is anchored to open directory descriptors.
/// Source links and special files are rejected, destination entries are created
/// with `O_NOFOLLOW | O_EXCL`, and a completed staging tree is made visible by
/// one exclusive `renameatx_np`. No plugin-provided program is ever launched.
public final class PluginStore: @unchecked Sendable {
    public static let pluginsDirectoryName = ".lumen-plugins"
    public static let manifestFileName = "plugin.json"
    public static let projectStateFileName = ".lumen-plugin-state.json"
    public static let maximumInstalledPlugins = 100
    public static let maximumPackageEntries = 10_000
    public static let maximumPackageBytes: Int64 = 256 * 1_024 * 1_024
    public static let maximumStateBytes = 1 * 1_024 * 1_024
    public static let workerExecutionSupport: PluginWorkerExecutionSupport = .isolatedProcess

    public let workspaceURL: URL

    public var pluginsURL: URL {
        workspaceURL.appendingPathComponent(Self.pluginsDirectoryName, isDirectory: true)
    }

    public var projectStateURL: URL {
        workspaceURL.appendingPathComponent(Self.projectStateFileName, isDirectory: false)
    }

    private let fileManager: FileManager
    private let trashHandler: any WorkspaceTrashHandling
    private let stateWriteFailureInjector: (@Sendable () throws -> Void)?
    private let lock = NSLock()

    public init(
        workspaceURL: URL,
        fileManager: FileManager = .default,
        trashHandler: any WorkspaceTrashHandling = SystemWorkspaceTrashHandler()
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.fileManager = fileManager
        self.trashHandler = trashHandler
        stateWriteFailureInjector = nil
    }

    /// Test-only fault injection for failures immediately before the atomic
    /// project-state write. Keeping this initializer internal prevents a
    /// production caller from bypassing the store's persistence path.
    init(
        workspaceURL: URL,
        fileManager: FileManager = .default,
        trashHandler: any WorkspaceTrashHandling,
        stateWriteFailureInjector: @escaping @Sendable () throws -> Void
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.fileManager = fileManager
        self.trashHandler = trashHandler
        self.stateWriteFailureInjector = stateWriteFailureInjector
    }

    /// Loads valid installations only. Corrupt, linked, partially staged, and
    /// ID-mismatched directories are ignored instead of poisoning the project.
    public func listInstalledPlugins() throws -> [InstalledPlugin] {
        try synchronized {
            let workspace = try openWorkspace()
            guard let plugins = try openPluginsDirectory(in: workspace, create: false) else {
                return []
            }
            let state = try loadProjectState(in: workspace)
            var result: [InstalledPlugin] = []

            for name in try directoryEntryNames(plugins.rawValue).sorted() {
                guard result.count < Self.maximumInstalledPlugins,
                      !name.hasPrefix("."),
                      PluginManifestSecurity.isValidPluginID(name),
                      let pluginDirectory = try? openDirectory(
                          named: name,
                          relativeTo: plugins.rawValue,
                          missingIsNil: true
                      ),
                      let data = try? readRegularFile(
                          components: [Self.manifestFileName],
                          relativeTo: pluginDirectory.rawValue,
                          maximumBytes: PluginManifestSecurity.maximumManifestByteCount
                      ),
                      let manifest = try? PluginManifest.parse(data),
                      manifest.id == name else {
                    continue
                }

                let grants = sanitizedPermissions(
                    state.permissions[manifest.id] ?? [],
                    requestedBy: manifest
                )
                result.append(InstalledPlugin(
                    manifest: manifest.removingMarketplaceMetadata(),
                    directoryURL: pluginsURL.appendingPathComponent(name, isDirectory: true),
                    isEnabled: state.enabled[manifest.id] ?? manifest.enabled,
                    grantedPermissions: grants,
                    effectivePermissions: manifest.effectivePermissions(granted: grants),
                    workerExecutionSupport: manifest.extensionManifest == nil
                        ? .unsupported : .isolatedProcess
                ))
            }
            return result
        }
    }

    /// Copies a local package into an unguessable staging directory within this
    /// workspace's plugin directory, validates it there, then publishes it with
    /// one exclusive atomic rename.
    @discardableResult
    public func installLocalPlugin(from sourceURL: URL) throws -> InstalledPlugin {
        try synchronized {
            let workspace = try openWorkspace()
            let plugins = try requirePluginsDirectory(in: workspace)
            let source = try openSourceDirectory(sourceURL)
            try rejectStorageOverlap(sourceURL)

            let manifestData: Data
            do {
                manifestData = try readRegularFile(
                    components: [Self.manifestFileName],
                    relativeTo: source.rawValue,
                    maximumBytes: PluginManifestSecurity.maximumManifestByteCount
                )
            } catch let error as PluginStoreError {
                if case .fileSystem(_, _, ENOENT) = error { throw PluginStoreError.missingManifest }
                throw error
            }
            let manifest = try PluginManifest.parse(manifestData)
            try requireAvailablePluginID(manifest.id, in: plugins.rawValue)

            let stagingName = ".installing-" + UUID().uuidString.lowercased()
            let stagingURL = pluginsURL.appendingPathComponent(stagingName, isDirectory: true)
            try createDirectory(named: stagingName, relativeTo: plugins.rawValue)
            defer { try? fileManager.removeItem(at: stagingURL) }

            let staging = try requireDirectory(named: stagingName, relativeTo: plugins.rawValue)
            var budget = CopyBudget()
            try copyDirectoryContents(
                source: source.rawValue,
                destination: staging.rawValue,
                relativePath: "",
                depth: 0,
                budget: &budget
            )
            try validateStagedManifest(
                expectedManifest: manifest,
                in: staging.rawValue
            )
            let state = try commitStagedInstallation(
                manifest: manifest,
                stagingName: stagingName,
                workspace: workspace,
                plugins: plugins.rawValue
            )
            return installedPlugin(manifest: manifest, state: state)
        }
    }

    /// Installs only bytes returned by `MarketplaceClient` after transport,
    /// origin and integrity validation. The worker remains inert in this layer.
    @discardableResult
    public func installMarketplacePlugin(
        _ package: MarketplacePluginPackage
    ) throws -> InstalledPlugin {
        try synchronized {
            try validateMarketplacePackage(package)
            let workspace = try openWorkspace()
            let plugins = try requirePluginsDirectory(in: workspace)
            try requireAvailablePluginID(package.manifest.id, in: plugins.rawValue)

            let stagingName = ".installing-" + UUID().uuidString.lowercased()
            let stagingURL = pluginsURL.appendingPathComponent(stagingName, isDirectory: true)
            try createDirectory(named: stagingName, relativeTo: plugins.rawValue)
            defer { try? fileManager.removeItem(at: stagingURL) }

            let staging = try requireDirectory(named: stagingName, relativeTo: plugins.rawValue)
            try writeRegularFile(
                package.installedManifestData,
                components: [Self.manifestFileName],
                relativeTo: staging.rawValue
            )
            if let worker = package.verifiedWorkerData,
               let path = package.manifest.extensionManifest?.worker {
                try writeRegularFile(
                    worker,
                    components: path.split(separator: "/").map(String.init),
                    relativeTo: staging.rawValue
                )
            }
            try validateStagedManifest(
                expectedManifest: package.manifest.removingMarketplaceMetadata(),
                in: staging.rawValue
            )
            let state = try commitStagedInstallation(
                manifest: package.manifest,
                stagingName: stagingName,
                workspace: workspace,
                plugins: plugins.rawValue
            )
            return installedPlugin(manifest: package.manifest, state: state)
        }
    }

    /// The entry is first atomically detached under an unguessable name. State
    /// is committed while that entry remains recoverable, and only then does
    /// the system Trash receive it. Either failure path restores the directory.
    public func uninstallPlugin(id: String) throws {
        try synchronized {
            guard PluginManifestSecurity.isValidPluginID(id) else {
                throw PluginStoreError.pluginNotInstalled(id)
            }
            let workspace = try openWorkspace()
            guard let plugins = try openPluginsDirectory(in: workspace, create: false) else {
                throw PluginStoreError.pluginNotInstalled(id)
            }
            guard let installed = try openDirectory(
                named: id, relativeTo: plugins.rawValue, missingIsNil: true
            ) else {
                throw PluginStoreError.pluginNotInstalled(id)
            }
            _ = installed
            let previousState = try loadProjectState(in: workspace)
            var updatedState = previousState
            updatedState.enabled[id] = nil
            updatedState.permissions[id] = nil

            let removingName = ".removing-" + UUID().uuidString.lowercased()
            try renameExclusively(
                from: id,
                to: removingName,
                relativeTo: plugins.rawValue,
                displayPath: pluginsURL.path
            )
            let removingURL = pluginsURL.appendingPathComponent(removingName, isDirectory: true)
            do {
                try syncPluginDirectory(plugins.rawValue)
                try saveProjectState(updatedState, in: workspace)
            } catch {
                let commitError = error
                try restoreDetachedPlugin(
                    removingName: removingName,
                    pluginID: id,
                    plugins: plugins.rawValue
                )
                throw commitError
            }

            do {
                try trashHandler.trashItem(at: removingURL)
            } catch {
                let trashError = error
                try restoreDetachedPlugin(
                    removingName: removingName,
                    pluginID: id,
                    plugins: plugins.rawValue
                )
                try saveProjectState(previousState, in: workspace)
                throw trashError
            }
        }
    }

    public func loadProjectState() throws -> PluginProjectState {
        try synchronized {
            let workspace = try openWorkspace()
            return try loadProjectState(in: workspace)
        }
    }

    public func setEnabled(_ enabled: Bool, forPluginID id: String) throws {
        try synchronized {
            let workspace = try openWorkspace()
            _ = try requireInstalledPlugin(id, workspace: workspace)
            var state = try loadProjectState(in: workspace)
            state.enabled[id] = enabled
            try saveProjectState(state, in: workspace)
        }
    }

    /// Persists only requested typed permissions. Revoked and unknown values
    /// therefore cannot survive a manifest change.
    public func setGrantedPermissions(
        _ permissions: [PluginPermission],
        forPluginID id: String
    ) throws {
        try synchronized {
            let workspace = try openWorkspace()
            let manifest = try requireInstalledPlugin(id, workspace: workspace)
            var state = try loadProjectState(in: workspace)
            state.permissions[id] = sanitizedPermissions(permissions, requestedBy: manifest)
            try saveProjectState(state, in: workspace)
        }
    }

    public func setMarketplaceSources(_ values: [String]) throws {
        try synchronized {
            let workspace = try openWorkspace()
            var state = try loadProjectState(in: workspace)
            state.marketplaceSources = PluginManifestSecurity
                .sanitizeMarketplaceSourceURLs(values)
                .map(\.absoluteString)
            try saveProjectState(state, in: workspace)
        }
    }

    /// Reads a worker only through the already trusted installation tree. The
    /// manifest is reparsed under the same descriptor and every worker path
    /// component is opened with `O_NOFOLLOW`, preventing a post-listing swap
    /// from changing the code that receives execution approval.
    public func loadWorkerPackage(forPluginID id: String) throws -> PluginWorkerPackage {
        guard let plugin = try listInstalledPlugins().first(where: { $0.id == id }) else {
            throw PluginStoreError.pluginNotInstalled(id)
        }
        return try loadWorkerPackage(for: plugin)
    }

    public func loadWorkerPackage(for plugin: InstalledPlugin) throws -> PluginWorkerPackage {
        try synchronized {
            let workspace = try openWorkspace()
            let id = plugin.id
            guard PluginManifestSecurity.isValidPluginID(id),
                  let plugins = try openPluginsDirectory(in: workspace, create: false),
                  let pluginDirectory = try openDirectory(
                      named: id, relativeTo: plugins.rawValue, missingIsNil: true
                  ) else {
                throw PluginStoreError.pluginNotInstalled(id)
            }
            let manifestData = try readRegularFile(
                components: [Self.manifestFileName],
                relativeTo: pluginDirectory.rawValue,
                maximumBytes: PluginManifestSecurity.maximumManifestByteCount
            )
            let manifest = try PluginManifest.parse(manifestData)
                .removingMarketplaceMetadata()
            guard manifest.id == id else {
                throw PluginStoreError.manifestIDDoesNotMatchDirectory(
                    expected: id, actual: manifest.id
                )
            }
            guard manifest == plugin.manifest.removingMarketplaceMetadata() else {
                throw PluginWorkerPackageError.manifestChanged
            }
            guard let extensionManifest = manifest.extensionManifest else {
                throw PluginWorkerPackageError.workerUnavailable
            }
            let source: Data
            do {
                source = try readRegularFile(
                    components: extensionManifest.worker.split(separator: "/").map(String.init),
                    relativeTo: pluginDirectory.rawValue,
                    maximumBytes: PluginManifestSecurity.maximumWorkerByteCount
                )
                try PluginManifestSecurity.validateInstalledWorkerData(source)
            } catch let error as PluginManifestValidationError {
                throw error
            } catch {
                throw PluginStoreError.workerFileMissing(extensionManifest.worker)
            }
            guard String(data: source, encoding: .utf8) != nil else {
                throw PluginWorkerPackageError.invalidWorkerEncoding
            }
            let state = try loadProjectState(in: workspace)
            let grants = sanitizedPermissions(
                state.permissions[id] ?? [],
                requestedBy: manifest
            )
            guard state.enabled[id] ?? manifest.enabled else {
                throw PluginWorkerPackageError.workerUnavailable
            }
            return PluginWorkerPackage(
                pluginID: id,
                pluginName: manifest.name,
                source: source,
                sourceIntegrity: .digest(of: source),
                permissions: grants
            )
        }
    }

    // MARK: - Marketplace proof validation

    private func validateMarketplacePackage(_ package: MarketplacePluginPackage) throws {
        guard package.sourceManifestURL.scheme == "https",
              let parsed = try? PluginManifest.parse(package.installedManifestData),
              parsed.id == package.manifest.id,
              parsed == package.manifest.removingMarketplaceMetadata() else {
            throw PluginStoreError.invalidMarketplacePackage
        }
        let workerRequest = try PluginManifestSecurity.marketplaceWorkerRequest(
            for: package.manifest,
            manifestURL: package.sourceManifestURL
        )
        switch (workerRequest, package.verifiedWorkerData) {
        case (nil, nil) where package.manifest.extensionManifest == nil:
            return
        case let (.some(request), .some(data)):
            try PluginManifestSecurity.validateResponse(
                finalURL: request.url,
                data: data,
                against: request
            )
        default:
            throw PluginStoreError.invalidMarketplacePackage
        }
    }

    // MARK: - Project state

    private func loadProjectState(in workspace: FileDescriptor) throws -> PluginProjectState {
        let data: Data
        do {
            data = try readRegularFile(
                components: [Self.projectStateFileName],
                relativeTo: workspace.rawValue,
                maximumBytes: Self.maximumStateBytes
            )
        } catch let error as PluginStoreError {
            if case .fileSystem(_, _, ENOENT) = error { return .empty }
            throw error
        }
        let decoded: PluginProjectState
        do {
            decoded = try JSONDecoder().decode(PluginProjectState.self, from: data)
        } catch {
            return .empty
        }
        guard decoded.formatVersion == PluginProjectState.currentFormatVersion else {
            throw PluginStoreError.unsupportedStateVersion(decoded.formatVersion)
        }
        return sanitizedState(decoded)
    }

    private func saveProjectState(
        _ state: PluginProjectState,
        in workspace: FileDescriptor
    ) throws {
        let sanitized = sanitizedState(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sanitized)
        guard data.count <= Self.maximumStateBytes else { throw PluginStoreError.stateTooLarge }

        let temporaryName = ".plugin-state-" + UUID().uuidString.lowercased()
        do {
            try writeRegularFile(
                data,
                components: [temporaryName],
                relativeTo: workspace.rawValue
            )
            try stateWriteFailureInjector?()
            guard renameat(
                workspace.rawValue, temporaryName,
                workspace.rawValue, Self.projectStateFileName
            ) == 0 else {
                throw fileSystemError(
                    operation: "rename state",
                    path: projectStateURL.path
                )
            }
            _ = fsync(workspace.rawValue)
        } catch {
            _ = unlinkat(workspace.rawValue, temporaryName, 0)
            throw error
        }
    }

    private func sanitizedState(_ state: PluginProjectState) -> PluginProjectState {
        var enabled: [String: Bool] = [:]
        for key in state.enabled.keys.sorted() where enabled.count < Self.maximumInstalledPlugins {
            if PluginManifestSecurity.isValidPluginID(key) { enabled[key] = state.enabled[key] }
        }

        var permissions: [String: [PluginPermission]] = [:]
        for key in state.permissions.keys.sorted() where permissions.count < Self.maximumInstalledPlugins {
            guard PluginManifestSecurity.isValidPluginID(key) else { continue }
            var seen = Set<PluginPermission>()
            permissions[key] = (state.permissions[key] ?? []).filter { seen.insert($0).inserted }
        }
        return PluginProjectState(
            enabled: enabled,
            permissions: permissions,
            marketplaceSources: PluginManifestSecurity
                .sanitizeMarketplaceSourceURLs(state.marketplaceSources)
                .map(\.absoluteString)
        )
    }

    // MARK: - Descriptor-anchored installation

    private struct CopyBudget {
        var entries = 0
        var bytes: Int64 = 0
    }

    private func copyDirectoryContents(
        source: Int32,
        destination: Int32,
        relativePath: String,
        depth: Int,
        budget: inout CopyBudget
    ) throws {
        guard depth <= 64 else { throw PluginStoreError.copyLimitExceeded }
        for name in try directoryEntryNames(source).sorted() {
            budget.entries += 1
            guard budget.entries <= Self.maximumPackageEntries else {
                throw PluginStoreError.copyLimitExceeded
            }
            let childPath = relativePath.isEmpty ? name : relativePath + "/" + name
            var status = stat()
            guard fstatat(source, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw fileSystemError(operation: "inspect source", path: childPath)
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) {
                throw PluginStoreError.symbolicLinkEncountered(childPath)
            }
            if kind == mode_t(S_IFDIR) {
                let sourceChild = try requireDirectory(named: name, relativeTo: source)
                try createDirectory(named: name, relativeTo: destination)
                let destinationChild = try requireDirectory(named: name, relativeTo: destination)
                try copyDirectoryContents(
                    source: sourceChild.rawValue,
                    destination: destinationChild.rawValue,
                    relativePath: childPath,
                    depth: depth + 1,
                    budget: &budget
                )
                _ = fsync(destinationChild.rawValue)
            } else if kind == mode_t(S_IFREG) {
                guard status.st_size >= 0 else {
                    throw PluginStoreError.unsupportedFileType(childPath)
                }
                budget.bytes += Int64(status.st_size)
                guard budget.bytes <= Self.maximumPackageBytes else {
                    throw PluginStoreError.copyLimitExceeded
                }
                try copyRegularFile(
                    named: name,
                    source: source,
                    destination: destination,
                    displayPath: childPath,
                    budget: &budget
                )
            } else {
                throw PluginStoreError.unsupportedFileType(childPath)
            }
        }
    }

    private func copyRegularFile(
        named name: String,
        source: Int32,
        destination: Int32,
        displayPath: String,
        budget: inout CopyBudget
    ) throws {
        let sourceFD = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else {
            if errno == ELOOP { throw PluginStoreError.symbolicLinkEncountered(displayPath) }
            throw fileSystemError(operation: "open source file", path: displayPath)
        }
        let sourceHandle = FileDescriptor(sourceFD)
        var status = stat()
        guard fstat(sourceHandle.rawValue, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw PluginStoreError.unsupportedFileType(displayPath)
        }

        let destinationFD = openat(
            destination, name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationFD >= 0 else {
            throw fileSystemError(operation: "create staged file", path: displayPath)
        }
        let destinationHandle = FileDescriptor(destinationFD)
        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceHandle.rawValue, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw fileSystemError(operation: "read source file", path: displayPath)
            }
            if count == 0 { break }
            copied += Int64(count)
            if copied > Int64(status.st_size) {
                budget.bytes += Int64(count)
                guard budget.bytes <= Self.maximumPackageBytes else {
                    throw PluginStoreError.copyLimitExceeded
                }
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationHandle.rawValue,
                        bytes.baseAddress?.advanced(by: offset),
                        count - offset
                    )
                }
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw fileSystemError(operation: "write staged file", path: displayPath)
                }
                offset += written
            }
        }
        guard fsync(destinationHandle.rawValue) == 0 else {
            throw fileSystemError(operation: "sync staged file", path: displayPath)
        }
    }

    private func validateStagedManifest(
        expectedManifest: PluginManifest,
        in staging: Int32
    ) throws {
        let copied = try readRegularFile(
            components: [Self.manifestFileName],
            relativeTo: staging,
            maximumBytes: PluginManifestSecurity.maximumManifestByteCount
        )
        let reparsed = try PluginManifest.parse(copied)
        guard reparsed.id == expectedManifest.id else {
            throw PluginStoreError.manifestIDDoesNotMatchDirectory(
                expected: expectedManifest.id, actual: reparsed.id
            )
        }
        // Marketplace installation intentionally strips remote source metadata;
        // every other declaration must remain byte-semantically equivalent.
        guard reparsed == expectedManifest else {
            throw PluginStoreError.sourceChangedDuringInstallation
        }
        if let worker = expectedManifest.extensionManifest?.worker {
            do {
                let data = try readRegularFile(
                    components: worker.split(separator: "/").map(String.init),
                    relativeTo: staging,
                    maximumBytes: PluginManifestSecurity.maximumWorkerByteCount
                )
                try PluginManifestSecurity.validateInstalledWorkerData(data)
            } catch {
                throw PluginStoreError.workerFileMissing(worker)
            }
        }
    }

    /// Publishes the staged package only while its old staging name remains
    /// available as a rollback target. Existing plugin directories are never
    /// replaced (`renameExclusively` enforces that invariant), so rolling the
    /// publication back cannot discard an older installed version.
    private func commitStagedInstallation(
        manifest: PluginManifest,
        stagingName: String,
        workspace: FileDescriptor,
        plugins: Int32
    ) throws -> PluginProjectState {
        var state = try loadProjectState(in: workspace)
        state.enabled[manifest.id] = manifest.enabled
        state.permissions[manifest.id] = []

        var published = false
        do {
            try renameExclusively(
                from: stagingName,
                to: manifest.id,
                relativeTo: plugins,
                displayPath: pluginsURL.path
            )
            published = true
            try syncPluginDirectory(plugins)
            try saveProjectState(state, in: workspace)
            return state
        } catch {
            let commitError = error
            if published {
                try restorePublishedInstallation(
                    pluginID: manifest.id,
                    stagingName: stagingName,
                    plugins: plugins
                )
            }
            throw commitError
        }
    }

    private func restorePublishedInstallation(
        pluginID: String,
        stagingName: String,
        plugins: Int32
    ) throws {
        try renameExclusively(
            from: pluginID,
            to: stagingName,
            relativeTo: plugins,
            displayPath: pluginsURL.path
        )
        try syncPluginDirectory(plugins)
    }

    private func restoreDetachedPlugin(
        removingName: String,
        pluginID: String,
        plugins: Int32
    ) throws {
        try renameExclusively(
            from: removingName,
            to: pluginID,
            relativeTo: plugins,
            displayPath: pluginsURL.path
        )
        try syncPluginDirectory(plugins)
    }

    private func syncPluginDirectory(_ plugins: Int32) throws {
        guard fsync(plugins) == 0 else {
            throw fileSystemError(operation: "sync plugin directory", path: pluginsURL.path)
        }
    }

    private func renameExclusively(
        from: String,
        to: String,
        relativeTo directory: Int32,
        displayPath: String
    ) throws {
        guard renameatx_np(directory, from, directory, to, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw PluginStoreError.pluginAlreadyInstalled(to) }
            throw fileSystemError(operation: "atomic rename", path: displayPath + "/" + to)
        }
    }

    // MARK: - Descriptor helpers

    private final class FileDescriptor {
        let rawValue: Int32
        init(_ rawValue: Int32) { self.rawValue = rawValue }
        deinit { _ = Darwin.close(rawValue) }
    }

    private func openWorkspace() throws -> FileDescriptor {
        guard workspaceURL.isFileURL, workspaceURL.path.hasPrefix("/") else {
            throw PluginStoreError.invalidWorkspace(workspaceURL)
        }
        let descriptor = Darwin.open(
            workspaceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw PluginStoreError.invalidWorkspace(workspaceURL) }
        return FileDescriptor(descriptor)
    }

    private func openSourceDirectory(_ url: URL) throws -> FileDescriptor {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw PluginStoreError.invalidSource(url)
        }
        let descriptor = Darwin.open(
            standardized.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw PluginStoreError.invalidSource(url) }
        return FileDescriptor(descriptor)
    }

    private func rejectStorageOverlap(_ sourceURL: URL) throws {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let storage = pluginsURL.resolvingSymlinksInPath().standardizedFileURL
        if Self.contains(source, storage) || Self.contains(storage, source) {
            throw PluginStoreError.sourceOverlapsPluginStorage(sourceURL)
        }
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func requirePluginsDirectory(in workspace: FileDescriptor) throws -> FileDescriptor {
        try openPluginsDirectory(in: workspace, create: true)!
    }

    private func openPluginsDirectory(
        in workspace: FileDescriptor,
        create: Bool
    ) throws -> FileDescriptor? {
        if create, mkdirat(
            workspace.rawValue, Self.pluginsDirectoryName,
            mode_t(S_IRWXU)
        ) != 0, errno != EEXIST {
            throw fileSystemError(operation: "create plugin storage", path: pluginsURL.path)
        }
        do {
            return try openDirectory(
                named: Self.pluginsDirectoryName,
                relativeTo: workspace.rawValue,
                missingIsNil: !create
            )
        } catch {
            throw PluginStoreError.unsafePluginStorage(pluginsURL)
        }
    }

    private func openDirectory(
        named name: String,
        relativeTo directory: Int32,
        missingIsNil: Bool
    ) throws -> FileDescriptor? {
        let descriptor = openat(
            directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, missingIsNil, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw PluginStoreError.symbolicLinkEncountered(name) }
            throw fileSystemError(operation: "open directory", path: name)
        }
        return FileDescriptor(descriptor)
    }

    private func requireDirectory(named name: String, relativeTo directory: Int32) throws -> FileDescriptor {
        try openDirectory(named: name, relativeTo: directory, missingIsNil: false)!
    }

    private func createDirectory(named name: String, relativeTo directory: Int32) throws {
        guard mkdirat(directory, name, mode_t(S_IRWXU)) == 0 else {
            throw fileSystemError(operation: "create directory", path: name)
        }
    }

    private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw fileSystemError(operation: "enumerate directory", path: "<descriptor>")
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let nameCapacity = MemoryLayout.size(ofValue: entry.d_name)
            let name = withUnsafePointer(to: &entry.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: nameCapacity
                ) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else {
            throw fileSystemError(operation: "enumerate directory", path: "<descriptor>")
        }
        return names
    }

    private func readRegularFile(
        components: [String],
        relativeTo root: Int32,
        maximumBytes: Int
    ) throws -> Data {
        guard !components.isEmpty, components.allSatisfy(Self.isSafeComponent) else {
            throw PluginStoreError.unsupportedFileType(components.joined(separator: "/"))
        }
        var current = FileDescriptor(Darwin.dup(root))
        guard current.rawValue >= 0 else {
            throw fileSystemError(operation: "duplicate directory", path: "<descriptor>")
        }
        for component in components.dropLast() {
            current = try requireDirectory(named: component, relativeTo: current.rawValue)
        }
        let name = components.last!
        let descriptor = openat(
            current.rawValue, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw PluginStoreError.symbolicLinkEncountered(components.joined(separator: "/"))
            }
            throw fileSystemError(
                operation: "open regular file",
                path: components.joined(separator: "/")
            )
        }
        let handle = FileDescriptor(descriptor)
        var status = stat()
        guard fstat(handle.rawValue, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw PluginStoreError.unsupportedFileType(components.joined(separator: "/"))
        }
        guard status.st_size >= 0, status.st_size <= maximumBytes else {
            throw PluginStoreError.copyLimitExceeded
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.rawValue, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw fileSystemError(
                    operation: "read regular file",
                    path: components.joined(separator: "/")
                )
            }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else {
                throw PluginStoreError.copyLimitExceeded
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func writeRegularFile(
        _ data: Data,
        components: [String],
        relativeTo root: Int32
    ) throws {
        guard !components.isEmpty, components.allSatisfy(Self.isSafeComponent) else {
            throw PluginStoreError.invalidMarketplacePackage
        }
        var current = FileDescriptor(Darwin.dup(root))
        guard current.rawValue >= 0 else {
            throw fileSystemError(operation: "duplicate directory", path: "<descriptor>")
        }
        for component in components.dropLast() {
            if mkdirat(current.rawValue, component, mode_t(S_IRWXU)) != 0, errno != EEXIST {
                throw fileSystemError(operation: "create staged directory", path: component)
            }
            current = try requireDirectory(named: component, relativeTo: current.rawValue)
        }
        let name = components.last!
        let descriptor = openat(
            current.rawValue, name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw fileSystemError(operation: "create staged file", path: components.joined(separator: "/"))
        }
        let handle = FileDescriptor(descriptor)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    handle.rawValue,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw fileSystemError(
                        operation: "write staged file",
                        path: components.joined(separator: "/")
                    )
                }
                offset += count
            }
        }
        guard fsync(handle.rawValue) == 0 else {
            throw fileSystemError(operation: "sync staged file", path: components.joined(separator: "/"))
        }
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\0")
    }

    private func requireAvailablePluginID(_ id: String, in plugins: Int32) throws {
        var status = stat()
        if fstatat(plugins, id, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            throw PluginStoreError.pluginAlreadyInstalled(id)
        }
        guard errno == ENOENT else {
            throw fileSystemError(operation: "inspect plugin destination", path: id)
        }
    }

    private func requireInstalledPlugin(
        _ id: String,
        workspace: FileDescriptor
    ) throws -> PluginManifest {
        guard PluginManifestSecurity.isValidPluginID(id),
              let plugins = try openPluginsDirectory(in: workspace, create: false),
              let directory = try openDirectory(
                  named: id, relativeTo: plugins.rawValue, missingIsNil: true
              ) else {
            throw PluginStoreError.pluginNotInstalled(id)
        }
        let data = try readRegularFile(
            components: [Self.manifestFileName],
            relativeTo: directory.rawValue,
            maximumBytes: PluginManifestSecurity.maximumManifestByteCount
        )
        let manifest = try PluginManifest.parse(data)
        guard manifest.id == id else {
            throw PluginStoreError.manifestIDDoesNotMatchDirectory(expected: id, actual: manifest.id)
        }
        return manifest
    }

    private func installedPlugin(
        manifest: PluginManifest,
        state: PluginProjectState
    ) -> InstalledPlugin {
        let grants = sanitizedPermissions(
            state.permissions[manifest.id] ?? [], requestedBy: manifest
        )
        return InstalledPlugin(
            manifest: manifest.removingMarketplaceMetadata(),
            directoryURL: pluginsURL.appendingPathComponent(manifest.id, isDirectory: true),
            isEnabled: state.enabled[manifest.id] ?? manifest.enabled,
            grantedPermissions: grants,
            effectivePermissions: manifest.effectivePermissions(granted: grants),
            workerExecutionSupport: manifest.extensionManifest == nil
                ? .unsupported : .isolatedProcess
        )
    }

    private func sanitizedPermissions(
        _ permissions: [PluginPermission],
        requestedBy manifest: PluginManifest
    ) -> [PluginPermission] {
        manifest.effectivePermissions(granted: permissions)
    }

    private func fileSystemError(operation: String, path: String) -> PluginStoreError {
        .fileSystem(operation: operation, path: path, code: errno)
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
