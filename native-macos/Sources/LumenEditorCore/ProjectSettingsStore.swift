import Darwin
@preconcurrency import Foundation

public struct ProjectSettingsSnapshot: Equatable, Sendable {
    public let settings: ProjectSettings
    public let revision: String?

    public init(settings: ProjectSettings, revision: String?) {
        self.settings = settings
        self.revision = revision
    }
}

public struct ProjectSettingsWriteResult: Equatable, Sendable {
    public let revision: String
    public let wroteBytes: Bool

    public init(revision: String, wroteBytes: Bool) {
        self.revision = revision
        self.wroteBytes = wroteBytes
    }
}

public enum ProjectSettingsStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidWorkspace(URL)
    case workspaceChanged(URL)
    case symbolicLinkEncountered
    case notARegularFile
    case hardLinkedFile
    case fileTooLarge(actualBytes: Int64, maximumBytes: Int)
    case changedDuringRead
    case invalidContents(reason: ProjectSettingsParseError, revision: String)
    case conflict(actualRevision: String?)
    case invalidExpectedRevision
    case fileSystem(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidWorkspace(url):
            "The project workspace is not a safe local directory: \(url.path)"
        case let .workspaceChanged(url):
            "The project workspace path no longer identifies the authorised directory: \(url.path)"
        case .symbolicLinkEncountered:
            ".lumen-project.json must not be a symbolic link."
        case .notARegularFile:
            ".lumen-project.json must be a regular file."
        case .hardLinkedFile:
            ".lumen-project.json must not have multiple hard links."
        case let .fileTooLarge(actual, maximum):
            "Project settings use \(actual) bytes; the maximum is \(maximum) bytes."
        case .changedDuringRead:
            "Project settings changed while they were being read."
        case .invalidContents(let reason, _):
            reason.localizedDescription
        case .conflict:
            "Project settings changed on disk after they were loaded."
        case .invalidExpectedRevision:
            "The expected project-settings revision is invalid."
        case let .fileSystem(operation, code):
            "Project settings file operation ‘\(operation)’ failed (errno \(code))."
        }
    }
}

/// Descriptor-anchored `.lumen-project.json` persistence. The workspace and
/// target are opened with `O_NOFOLLOW`; writes use a synced same-directory
/// temporary file followed by one atomic rename and directory sync.
///
/// Saves take an advisory lock on the pinned workspace descriptor so every
/// Lumen process performs revision-check and rename as one cooperative critical
/// section. The destination is revalidated immediately before atomic rename.
public final class ProjectSettingsStore: @unchecked Sendable {
    public static let fileName = ".lumen-project.json"
    public static let maximumSerializedBytes = ProjectSettingsSanitizer.maximumSerializedBytes

    public let workspaceURL: URL
    public var settingsURL: URL {
        workspaceURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private static let persistenceLock = NSLock()
    private let workspaceDescriptor: Int32
    private let workspaceDevice: UInt64
    private let workspaceInode: UInt64

    public init(workspaceURL: URL) {
        let standardized = workspaceURL.standardizedFileURL
        self.workspaceURL = standardized
        let descriptor = standardized.isFileURL && standardized.path.hasPrefix("/")
            ? Self.openDirectoryWithoutSymbolicLinks(standardized.path)
            : -1
        var status = stat()
        if descriptor >= 0, fstat(descriptor, &status) == 0 {
            workspaceDescriptor = descriptor
            workspaceDevice = UInt64(status.st_dev)
            workspaceInode = UInt64(status.st_ino)
        } else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            workspaceDescriptor = -1
            workspaceDevice = 0
            workspaceInode = 0
        }
    }

    deinit {
        if workspaceDescriptor >= 0 { _ = Darwin.close(workspaceDescriptor) }
    }

    public func load() throws -> ProjectSettingsSnapshot {
        try Self.withLock {
            let workspace = try openWorkspace()
            guard let data = try readCurrentData(in: workspace.rawValue) else {
                return ProjectSettingsSnapshot(settings: .empty, revision: nil)
            }
            let revision = TextFileCodec.revision(of: data)
            let settings: ProjectSettings
            do {
                settings = try ProjectSettingsSanitizer.parse(data)
            } catch let error as ProjectSettingsParseError {
                throw ProjectSettingsStoreError.invalidContents(
                    reason: error, revision: revision
                )
            }
            return ProjectSettingsSnapshot(
                settings: settings, revision: revision
            )
        }
    }

    /// `expectedRevision == nil` means the file must still be absent. A concrete
    /// revision provides optimistic concurrency against external project edits.
    @discardableResult
    public func save(
        _ settings: ProjectSettings,
        expectedRevision: String?
    ) throws -> ProjectSettingsWriteResult {
        if let expectedRevision, !Self.isRevision(expectedRevision) {
            throw ProjectSettingsStoreError.invalidExpectedRevision
        }
        let data = try ProjectSettingsSanitizer.encodedData(settings)
        let nextRevision = TextFileCodec.revision(of: data)

        return try Self.withLock {
            let workspace = try openWorkspace()
            guard flock(workspace.rawValue, LOCK_EX) == 0 else {
                throw Self.fileSystemError(operation: "lock workspace for project settings")
            }
            defer { _ = flock(workspace.rawValue, LOCK_UN) }
            let initial = try currentRevision(in: workspace.rawValue)
            guard initial == expectedRevision else {
                if initial == nextRevision {
                    return ProjectSettingsWriteResult(revision: nextRevision, wroteBytes: false)
                }
                throw ProjectSettingsStoreError.conflict(actualRevision: initial)
            }

            let temporaryName = ".lumen-project." + UUID().uuidString.lowercased() + ".tmp"
            do {
                try writeTemporary(data, named: temporaryName, in: workspace.rawValue)
                let latest = try currentRevision(in: workspace.rawValue)
                guard latest == expectedRevision else {
                    if latest == nextRevision {
                        _ = unlinkat(workspace.rawValue, temporaryName, 0)
                        return ProjectSettingsWriteResult(
                            revision: nextRevision, wroteBytes: false
                        )
                    }
                    throw ProjectSettingsStoreError.conflict(actualRevision: latest)
                }

                if expectedRevision == nil {
                    guard renameatx_np(
                        workspace.rawValue, temporaryName,
                        workspace.rawValue, Self.fileName, UInt32(RENAME_EXCL)
                    ) == 0 else {
                        if errno == EEXIST {
                            throw ProjectSettingsStoreError.conflict(
                                actualRevision: try currentRevision(in: workspace.rawValue)
                            )
                        }
                        throw Self.fileSystemError(operation: "publish new project settings")
                    }
                } else {
                    guard renameat(
                        workspace.rawValue, temporaryName,
                        workspace.rawValue, Self.fileName
                    ) == 0 else {
                        throw Self.fileSystemError(operation: "replace project settings")
                    }
                }
                guard fsync(workspace.rawValue) == 0 else {
                    throw Self.fileSystemError(operation: "sync workspace directory")
                }
                return ProjectSettingsWriteResult(revision: nextRevision, wroteBytes: true)
            } catch {
                _ = unlinkat(workspace.rawValue, temporaryName, 0)
                throw error
            }
        }
    }

    private final class FileDescriptor {
        let rawValue: Int32
        init(_ rawValue: Int32) { self.rawValue = rawValue }
        deinit { _ = Darwin.close(rawValue) }
    }

    private func openWorkspace() throws -> FileDescriptor {
        guard workspaceDescriptor >= 0 else {
            throw ProjectSettingsStoreError.invalidWorkspace(workspaceURL)
        }
        let pathDescriptor = Self.openDirectoryWithoutSymbolicLinks(workspaceURL.path)
        guard pathDescriptor >= 0 else {
            throw ProjectSettingsStoreError.workspaceChanged(workspaceURL)
        }
        defer { _ = Darwin.close(pathDescriptor) }
        var pathStatus = stat()
        guard fstat(pathDescriptor, &pathStatus) == 0,
              UInt64(pathStatus.st_dev) == workspaceDevice,
              UInt64(pathStatus.st_ino) == workspaceInode else {
            throw ProjectSettingsStoreError.workspaceChanged(workspaceURL)
        }
        let descriptor = Darwin.dup(workspaceDescriptor)
        guard descriptor >= 0 else {
            throw ProjectSettingsStoreError.invalidWorkspace(workspaceURL)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              UInt64(status.st_dev) == workspaceDevice,
              UInt64(status.st_ino) == workspaceInode else {
            _ = Darwin.close(descriptor)
            throw ProjectSettingsStoreError.invalidWorkspace(workspaceURL)
        }
        return FileDescriptor(descriptor)
    }

    private func currentRevision(in workspace: Int32) throws -> String? {
        try readCurrentData(in: workspace).map { TextFileCodec.revision(of: $0) }
    }

    private func readCurrentData(in workspace: Int32) throws -> Data? {
        var entryStatus = stat()
        guard fstatat(workspace, Self.fileName, &entryStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.fileSystemError(operation: "inspect project settings")
        }
        try Self.validateEntry(entryStatus)

        let descriptor = openat(
            workspace, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ProjectSettingsStoreError.symbolicLinkEncountered }
            throw Self.fileSystemError(operation: "open project settings")
        }
        let handle = FileDescriptor(descriptor)
        var openedStatus = stat()
        guard fstat(handle.rawValue, &openedStatus) == 0 else {
            throw Self.fileSystemError(operation: "inspect opened project settings")
        }
        try Self.validateEntry(openedStatus)
        guard entryStatus.st_dev == openedStatus.st_dev,
              entryStatus.st_ino == openedStatus.st_ino else {
            throw ProjectSettingsStoreError.changedDuringRead
        }

        var data = Data()
        data.reserveCapacity(Int(openedStatus.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.rawValue, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw Self.fileSystemError(operation: "read project settings")
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumSerializedBytes else {
                throw ProjectSettingsStoreError.fileTooLarge(
                    actualBytes: Int64(data.count + count),
                    maximumBytes: Self.maximumSerializedBytes
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var finalStatus = stat()
        guard fstat(handle.rawValue, &finalStatus) == 0 else {
            throw Self.fileSystemError(operation: "reinspect project settings")
        }
        guard openedStatus.st_dev == finalStatus.st_dev,
              openedStatus.st_ino == finalStatus.st_ino,
              openedStatus.st_size == finalStatus.st_size,
              openedStatus.st_ctimespec.tv_sec == finalStatus.st_ctimespec.tv_sec,
              openedStatus.st_ctimespec.tv_nsec == finalStatus.st_ctimespec.tv_nsec,
              openedStatus.st_mtimespec.tv_sec == finalStatus.st_mtimespec.tv_sec,
              openedStatus.st_mtimespec.tv_nsec == finalStatus.st_mtimespec.tv_nsec else {
            throw ProjectSettingsStoreError.changedDuringRead
        }
        return data
    }

    private static func validateEntry(_ status: stat) throws {
        let kind = status.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK) {
            throw ProjectSettingsStoreError.symbolicLinkEncountered
        }
        guard kind == mode_t(S_IFREG) else {
            throw ProjectSettingsStoreError.notARegularFile
        }
        guard status.st_nlink == 1 else {
            throw ProjectSettingsStoreError.hardLinkedFile
        }
        guard status.st_uid == geteuid() else {
            throw ProjectSettingsStoreError.notARegularFile
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(Self.maximumSerializedBytes) else {
            throw ProjectSettingsStoreError.fileTooLarge(
                actualBytes: Int64(status.st_size),
                maximumBytes: Self.maximumSerializedBytes
            )
        }
    }

    private func writeTemporary(_ data: Data, named name: String, in workspace: Int32) throws {
        let descriptor = openat(
            workspace, name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Self.fileSystemError(operation: "create project settings temporary file")
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
                    throw Self.fileSystemError(operation: "write project settings temporary file")
                }
                offset += count
            }
        }
        guard fsync(handle.rawValue) == 0 else {
            throw Self.fileSystemError(operation: "sync project settings temporary file")
        }
    }

    private static func isRevision(_ value: String) -> Bool {
        guard value.count == 71, value.hasPrefix("sha256:") else { return false }
        return value.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func openDirectoryWithoutSymbolicLinks(_ path: String) -> Int32 {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.first == "/" else { return -1 }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in components.dropFirst() {
            let next = openat(
                descriptor, component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                _ = Darwin.close(descriptor)
                return -1
            }
            _ = Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func fileSystemError(operation: String) -> ProjectSettingsStoreError {
        .fileSystem(operation: operation, code: errno)
    }

    private static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        return try operation()
    }
}
