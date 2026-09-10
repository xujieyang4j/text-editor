import Foundation
import LumenEditorMobileCore

struct MobileFileReference: Sendable {
    let url: URL
    let bookmarkData: Data
}

struct MobileVerifiedWrite: Sendable {
    let revision: String
    let byteCount: Int
}

enum MobileFileAccessError: Error, Equatable, LocalizedError {
    case permissionDenied
    case coordinatedReadFailed
    case coordinatedWriteFailed
    case verificationFailed(attemptedRevision: String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "file_access_denied")
        case .coordinatedReadFailed: String(localized: "file_read_failed")
        case .coordinatedWriteFailed: String(localized: "file_write_failed")
        case .verificationFailed: String(localized: "file_verify_failed")
        case .fileTooLarge: String(localized: "file_too_large")
        }
    }
}

/// All provider I/O is coordinated. Individual operations acquire their own
/// security scope; file presenters separately retain a scope while registered.
actor MobileFileAccess {
    func reference(forPickedURL url: URL) throws -> MobileFileReference {
        try withSecurityScope(url) {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: [.nameKey],
                relativeTo: nil
            )
            return MobileFileReference(url: url, bookmarkData: bookmark)
        }
    }

    func resolve(_ bookmarkData: Data) throws -> MobileFileReference {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard isStale else { return MobileFileReference(url: url, bookmarkData: bookmarkData) }
        return try reference(forPickedURL: url)
    }

    func read(_ reference: MobileFileReference) throws -> Data {
        try withSecurityScope(reference.url) { try coordinatedRead(reference.url) }
    }

    func open(
        _ reference: MobileFileReference,
        forcedEncoding: MobileTextEncoding? = nil
    ) throws -> MobileOpenedTextFile {
        try MobileTextCodec.decode(
            read(reference),
            forcedEncoding: forcedEncoding
        )
    }

    func decodeRecoveryData(
        _ data: Data,
        forcedEncoding: MobileTextEncoding
    ) throws -> MobileOpenedTextFile {
        try MobileTextCodec.decode(data, forcedEncoding: forcedEncoding)
    }

    func encode(
        _ content: String,
        encoding: MobileTextEncoding,
        lineEnding: MobileLineEnding
    ) throws -> Data {
        let data = try MobileTextCodec.encode(
            content, encoding: encoding, lineEnding: lineEnding
        )
        guard Int64(data.count) <= MobileTextCodec.defaultMaximumByteCount else {
            throw MobileFileAccessError.fileTooLarge
        }
        return data
    }

    func encodeAndWriteVerified(
        _ content: String,
        encoding: MobileTextEncoding,
        lineEnding: MobileLineEnding,
        to reference: MobileFileReference,
        expectedRevision: String?
    ) throws -> MobileVerifiedWrite {
        let data = try encode(content, encoding: encoding, lineEnding: lineEnding)
        return try writeVerified(data, to: reference, expectedRevision: expectedRevision)
    }

    func writeVerified(
        _ data: Data,
        to reference: MobileFileReference,
        expectedRevision: String?
    ) throws -> MobileVerifiedWrite {
        guard Int64(data.count) <= MobileTextCodec.defaultMaximumByteCount else {
            throw MobileFileAccessError.fileTooLarge
        }
        return try withSecurityScope(reference.url) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var operationError: Error?
            var result: MobileVerifiedWrite?
            coordinator.coordinate(
                writingItemAt: reference.url,
                options: .forReplacing,
                error: &coordinationError
            ) { writeURL in
                do {
                    let current = try readBounded(
                        writeURL, maximumByteCount: MobileTextCodec.defaultMaximumByteCount
                    )
                    try MobileSavePreflight.validate(
                        expectedRevision: expectedRevision,
                        currentRevision: MobileTextCodec.revision(of: current)
                    )
                    // Write the coordinated provider URL itself. The private
                    // recovery checkpoint is the crash-safe copy; a path-level
                    // atomic rename is not assumed to work across providers.
                    try data.write(to: writeURL, options: [])
                    let intendedRevision = MobileTextCodec.revision(of: data)
                    let installed: Data
                    do {
                        installed = try readBounded(
                            writeURL, maximumByteCount: Int64(data.count)
                        )
                    } catch {
                        throw MobileFileAccessError.verificationFailed(
                            attemptedRevision: intendedRevision
                        )
                    }
                    guard installed == data else {
                        throw MobileFileAccessError.verificationFailed(
                            attemptedRevision: intendedRevision
                        )
                    }
                    result = MobileVerifiedWrite(
                        revision: MobileTextCodec.revision(of: installed),
                        byteCount: installed.count
                    )
                } catch {
                    operationError = error
                }
            }
            if let operationError { throw operationError }
            if let coordinationError { throw coordinationError }
            guard let result else { throw MobileFileAccessError.coordinatedWriteFailed }
            return result
        }
    }

    func verifyExportedData(_ data: Data, at url: URL) throws -> MobileFileReference {
        let installed = try withSecurityScope(url) { try coordinatedRead(url) }
        guard installed == data else {
            throw MobileFileAccessError.verificationFailed(
                attemptedRevision: MobileTextCodec.revision(of: data)
            )
        }
        return try reference(forPickedURL: url)
    }

    /// Creates an app-owned snapshot so the system share sheet never depends
    /// on a File Provider security scope remaining open. Sharing does not
    /// change the document's save baseline or source-file binding.
    func makeShareSnapshot(_ data: Data, suggestedName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try? protectedDirectory.setResourceValues(directoryValues)

        let basename = URL(fileURLWithPath: suggestedName).lastPathComponent
        let filename = basename.isEmpty || basename == "." ? "document.txt" : basename
        let snapshotURL = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try data.write(
                to: snapshotURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return snapshotURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func removeShareSnapshot(at url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("LumenShare-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func cleanupAbandonedShareSnapshots() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for candidate in candidates where candidate.lastPathComponent.hasPrefix("LumenShare-") {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var result: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                result = try readBounded(
                    readURL, maximumByteCount: MobileTextCodec.defaultMaximumByteCount
                )
            }
            catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        guard let result else { throw MobileFileAccessError.coordinatedReadFailed }
        return result
    }

    private func withSecurityScope<T>(_ url: URL, operation: () throws -> T) throws -> T {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        // Local app-container URLs legitimately return false. Coordinated access
        // still determines whether the URL can actually be read or written.
        return try operation()
    }

    private func readBounded(_ url: URL, maximumByteCount: Int64) throws -> Data {
        guard maximumByteCount >= 0, maximumByteCount < Int64(Int.max) else {
            throw MobileFileAccessError.fileTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(Int(min(maximumByteCount, 1_048_576)))
        while true {
            let remaining = maximumByteCount - Int64(data.count)
            let requested = Int(min(Int64(64 * 1_024), remaining + 1))
            let chunk = try handle.read(upToCount: requested) ?? Data()
            if chunk.isEmpty { break }
            guard Int64(chunk.count) <= remaining else {
                throw MobileFileAccessError.fileTooLarge
            }
            data.append(chunk)
        }
        return data
    }
}
