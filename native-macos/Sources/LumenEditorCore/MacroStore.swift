import Darwin
@preconcurrency import Foundation

public enum MacroStoreError: Error, Equatable, LocalizedError {
    case invalidWorkspace(URL)
    case workspaceChanged(URL)
    case symbolicLinkEncountered
    case notARegularFile
    case hardLinkedFile
    case wrongOwner
    case fileTooLarge(actualBytes: Int64, maximumBytes: Int)
    case changedDuringRead
    case changedDuringWrite
    case invalidMacro
    case fileSystem(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidWorkspace(url):
            return "The macro workspace is not a safe local directory: \(url.path)"
        case let .workspaceChanged(url):
            return "The authorised macro workspace changed: \(url.path)"
        case .symbolicLinkEncountered:
            return ".lumen-macros.json must not be a symbolic link."
        case .notARegularFile:
            return ".lumen-macros.json must be a regular file."
        case .hardLinkedFile:
            return ".lumen-macros.json must not have multiple hard links."
        case .wrongOwner:
            return ".lumen-macros.json must be owned by the current user."
        case let .fileTooLarge(actual, maximum):
            return "Macro data uses \(actual) bytes; the maximum is \(maximum) bytes."
        case .changedDuringRead:
            return "The macro file changed while it was being read."
        case .changedDuringWrite:
            return "The macro file changed while it was being saved."
        case .invalidMacro:
            return "The macro name or steps are invalid."
        case let .fileSystem(operation, code):
            return "Macro file operation ‘\(operation)’ failed (errno \(code))."
        }
    }
}

/// Descriptor-anchored storage for the Electron-compatible
/// `.lumen-macros.json` file in one authorised workspace. Reads and writes
/// never follow the workspace path or destination through a symbolic link.
public final class MacroStore: @unchecked Sendable {
    public static let fileName = ".lumen-macros.json"

    public let workspaceURL: URL
    public let limits: MacroLimits
    public var macrosURL: URL {
        workspaceURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private static let persistenceLock = NSLock()
    private let workspaceDescriptor: Int32
    private let workspaceDevice: UInt64
    private let workspaceInode: UInt64

    public init(workspaceURL: URL, limits: MacroLimits = .standard) {
        let standardized = workspaceURL.standardizedFileURL
        self.workspaceURL = standardized
        self.limits = limits
        let descriptor = standardized.isFileURL && standardized.path.hasPrefix("/")
            ? Self.openDirectoryWithoutSymbolicLinks(standardized.path) : -1
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

    public func load() throws -> [SavedMacro] {
        try Self.withLock {
            let workspace = try openWorkspace()
            guard let data = try readCurrentData(in: workspace.rawValue) else { return [] }
            return try MacroSanitizer.parse(data, limits: limits)
        }
    }

    /// Inserts or replaces by sanitized name and keeps the newest macro first,
    /// matching Electron. A malformed existing file is never overwritten.
    @discardableResult
    public func save(_ macro: SavedMacro) throws -> [SavedMacro] {
        guard let next = MacroSanitizer.sanitize(macro, limits: limits) else {
            throw MacroStoreError.invalidMacro
        }
        return try Self.withLock {
            let workspace = try openWorkspace()
            let currentData = try readCurrentData(in: workspace.rawValue)
            let current = try currentData.map {
                try MacroSanitizer.parse($0, limits: limits)
            } ?? []
            let macros = Array(([next] + current.filter { $0.name != next.name })
                .prefix(limits.maximumMacros))
            let data = try MacroSanitizer.encodedData(macros, limits: limits)
            try write(
                data, expectedRevision: currentData.map { TextFileCodec.revision(of: $0) },
                in: workspace.rawValue
            )
            return macros
        }
    }

    private final class FileDescriptor {
        let rawValue: Int32
        init(_ rawValue: Int32) { self.rawValue = rawValue }
        deinit { _ = Darwin.close(rawValue) }
    }

    private func openWorkspace() throws -> FileDescriptor {
        guard workspaceDescriptor >= 0 else {
            throw MacroStoreError.invalidWorkspace(workspaceURL)
        }
        let pathDescriptor = Self.openDirectoryWithoutSymbolicLinks(workspaceURL.path)
        guard pathDescriptor >= 0 else {
            throw MacroStoreError.workspaceChanged(workspaceURL)
        }
        defer { _ = Darwin.close(pathDescriptor) }
        var status = stat()
        guard fstat(pathDescriptor, &status) == 0,
              UInt64(status.st_dev) == workspaceDevice,
              UInt64(status.st_ino) == workspaceInode else {
            throw MacroStoreError.workspaceChanged(workspaceURL)
        }
        let descriptor = Darwin.dup(workspaceDescriptor)
        guard descriptor >= 0 else { throw MacroStoreError.invalidWorkspace(workspaceURL) }
        return FileDescriptor(descriptor)
    }

    private func readCurrentData(in workspace: Int32) throws -> Data? {
        var entry = stat()
        guard fstatat(workspace, Self.fileName, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.fileSystemError("inspect macro file")
        }
        try validate(entry)
        let descriptor = openat(
            workspace, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw MacroStoreError.symbolicLinkEncountered }
            throw Self.fileSystemError("open macro file")
        }
        let file = FileDescriptor(descriptor)
        var opened = stat()
        guard fstat(file.rawValue, &opened) == 0 else {
            throw Self.fileSystemError("inspect opened macro file")
        }
        try validate(opened)
        guard entry.st_dev == opened.st_dev, entry.st_ino == opened.st_ino,
              entry.st_size == opened.st_size,
              entry.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              entry.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw MacroStoreError.changedDuringRead
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(file.rawValue, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw Self.fileSystemError("read macro file")
            }
            if count == 0 { break }
            guard data.count + count <= limits.maximumSerializedBytes else {
                throw MacroStoreError.fileTooLarge(
                    actualBytes: Int64(data.count + count),
                    maximumBytes: limits.maximumSerializedBytes
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var final = stat()
        guard fstat(file.rawValue, &final) == 0 else {
            throw Self.fileSystemError("reinspect macro file")
        }
        guard opened.st_size == final.st_size,
              opened.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              opened.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec else {
            throw MacroStoreError.changedDuringRead
        }
        return data
    }

    private func write(
        _ data: Data, expectedRevision: String?, in workspace: Int32
    ) throws {
        let temporaryName = ".lumen-macros."
            + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(
            workspace, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw Self.fileSystemError("create macro temporary file") }
        let temporary = FileDescriptor(descriptor)
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        temporary.rawValue, bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard count >= 0 else {
                        if errno == EINTR { continue }
                        throw Self.fileSystemError("write macro temporary file")
                    }
                    offset += count
                }
            }
            guard fsync(temporary.rawValue) == 0 else {
                throw Self.fileSystemError("sync macro temporary file")
            }

            let latest = try readCurrentData(in: workspace).map {
                TextFileCodec.revision(of: $0)
            }
            guard latest == expectedRevision else { throw MacroStoreError.changedDuringWrite }
            if expectedRevision == nil {
                guard renameatx_np(
                    workspace, temporaryName, workspace, Self.fileName, UInt32(RENAME_EXCL)
                ) == 0 else {
                    if errno == EEXIST { throw MacroStoreError.changedDuringWrite }
                    throw Self.fileSystemError("publish macro file")
                }
            } else {
                try replaceExistingAtomically(
                    temporaryName: temporaryName,
                    expectedRevision: expectedRevision!,
                    in: workspace
                )
            }
            guard fsync(workspace) == 0 else {
                throw Self.fileSystemError("sync macro workspace")
            }
        } catch {
            _ = unlinkat(workspace, temporaryName, 0)
            throw error
        }
    }

    private func replaceExistingAtomically(
        temporaryName: String, expectedRevision: String, in workspace: Int32
    ) throws {
        let renameSwap = UInt32(0x00000002)
        guard renameatx_np(
            workspace, temporaryName, workspace, Self.fileName, renameSwap
        ) == 0 else {
            throw Self.fileSystemError("swap macro file")
        }
        do {
            guard let displaced = try readRegularFile(
                named: temporaryName, in: workspace
            ), TextFileCodec.revision(of: displaced) == expectedRevision else {
                throw MacroStoreError.changedDuringWrite
            }
        } catch {
            guard renameatx_np(
                workspace, temporaryName, workspace, Self.fileName, renameSwap
            ) == 0 else { throw Self.fileSystemError("roll back macro write") }
            throw error
        }
        guard unlinkat(workspace, temporaryName, 0) == 0 else {
            throw Self.fileSystemError("remove replaced macro file")
        }
    }

    private func readRegularFile(named name: String, in workspace: Int32) throws -> Data? {
        let descriptor = openat(workspace, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Self.fileSystemError("open displaced macro file") }
        let file = FileDescriptor(descriptor)
        var status = stat()
        guard fstat(file.rawValue, &status) == 0 else {
            throw Self.fileSystemError("inspect displaced macro file")
        }
        try validate(status)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(file.rawValue, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw Self.fileSystemError("read displaced macro file")
            }
            if count == 0 { break }
            guard data.count + count <= limits.maximumSerializedBytes else {
                throw MacroStoreError.fileTooLarge(
                    actualBytes: Int64(data.count + count),
                    maximumBytes: limits.maximumSerializedBytes
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func validate(_ status: stat) throws {
        let kind = status.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK) { throw MacroStoreError.symbolicLinkEncountered }
        guard kind == mode_t(S_IFREG) else { throw MacroStoreError.notARegularFile }
        guard status.st_nlink == 1 else { throw MacroStoreError.hardLinkedFile }
        guard status.st_uid == geteuid() else { throw MacroStoreError.wrongOwner }
        guard status.st_size >= 0,
              status.st_size <= off_t(limits.maximumSerializedBytes) else {
            throw MacroStoreError.fileTooLarge(
                actualBytes: Int64(status.st_size),
                maximumBytes: limits.maximumSerializedBytes
            )
        }
    }

    private static func openDirectoryWithoutSymbolicLinks(_ path: String) -> Int32 {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.first == "/" else { return -1 }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in components.dropFirst() {
            let next = openat(
                descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
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

    private static func fileSystemError(_ operation: String) -> MacroStoreError {
        .fileSystem(operation: operation, code: errno)
    }

    private static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        return try operation()
    }
}
