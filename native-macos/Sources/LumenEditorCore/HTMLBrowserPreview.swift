import Darwin
import Foundation

/// Immutable input captured from an editor document before opening a browser.
public struct HTMLBrowserPreviewRequest: Equatable, @unchecked Sendable {
    public let sourceURL: URL?
    public let content: String
    public let isDirty: Bool
    public let language: String

    public init(
        sourceURL: URL?,
        content: String,
        isDirty: Bool,
        language: String
    ) {
        self.sourceURL = sourceURL
        self.content = content
        self.isDirty = isDirty
        self.language = language
    }
}

public enum HTMLBrowserPreviewTargetKind: String, Equatable, Sendable {
    case savedFile
    case temporarySnapshot
}

/// A file URL safe to hand to the system browser. It is never an http(s) URL
/// and is never loaded inside a privileged application WebView.
public struct HTMLBrowserPreviewTarget: Equatable, @unchecked Sendable {
    public let url: URL
    public let kind: HTMLBrowserPreviewTargetKind

    public init(url: URL, kind: HTMLBrowserPreviewTargetKind) {
        self.url = url
        self.kind = kind
    }
}

public enum HTMLBrowserPreviewError: Error, Equatable, @unchecked Sendable {
    case unsupportedDocument
    case invalidSourceURL(URL)
    case invalidTemporaryDirectory(URL)
    case snapshotTooLarge(actual: Int, maximum: Int)
    case storeClosed
    case tooManyTemporaryDirectoryCollisions
    case fileSystem(operation: String, path: String, code: Int32)
}

extension HTMLBrowserPreviewError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedDocument:
            "Open in Browser is available only for HTML documents."
        case let .invalidSourceURL(url):
            "The HTML source is not an absolute local file: \(url.absoluteString)"
        case let .invalidTemporaryDirectory(url):
            "The browser-preview temporary directory is unsafe: \(url.path)"
        case let .snapshotTooLarge(actual, maximum):
            "The HTML preview is \(actual) bytes; the limit is \(maximum) bytes."
        case .storeClosed:
            "The browser-preview store has already shut down."
        case .tooManyTemporaryDirectoryCollisions:
            "Could not allocate a private browser-preview directory."
        case let .fileSystem(operation, path, code):
            "Browser-preview operation ‘\(operation)’ failed for \(path) (errno \(code))."
        }
    }
}

/// Pure HTML classification and snapshot rendering policy.
public enum HTMLBrowserPreview {
    public static let fileExtensions: Set<String> = ["htm", "html", "xhtml"]
    public static let defaultMaximumSnapshotByteCount = 20 * 1_024 * 1_024

    public static func supports(sourceURL: URL?, language: String) -> Bool {
        let extensionMatches = sourceURL.map {
            fileExtensions.contains($0.pathExtension.lowercased())
        } ?? false
        return extensionMatches || language.caseInsensitiveCompare("HTML") == .orderedSame
    }

    /// Clean, saved HTML paths can be opened without copying. Untitled, dirty,
    /// or manually-typed HTML documents use a snapshot so the browser sees the
    /// exact editor buffer without triggering Save or touching source bytes.
    public static func requiresSnapshot(_ request: HTMLBrowserPreviewRequest) throws -> Bool {
        guard supports(sourceURL: request.sourceURL, language: request.language) else {
            throw HTMLBrowserPreviewError.unsupportedDocument
        }
        guard let sourceURL = request.sourceURL else { return true }
        guard isAbsoluteLocalFileURL(sourceURL) else {
            throw HTMLBrowserPreviewError.invalidSourceURL(sourceURL)
        }
        return request.isDirty
            || !fileExtensions.contains(sourceURL.pathExtension.lowercased())
    }

    /// Adds a cache-busting query without changing the underlying file path,
    /// matching the Electron preview URL handed to the external browser.
    public static func browserURL(for target: HTMLBrowserPreviewTarget) -> URL {
        guard target.kind == .temporarySnapshot,
              var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)
        else { return target.url }
        components.queryItems = [
            URLQueryItem(
                name: "t",
                value: String(Int(Date().timeIntervalSince1970 * 1_000))
            )
        ]
        return components.url ?? target.url
    }

    /// Mirrors Electron's `withPreviewBase`: preserve an authored base element;
    /// otherwise insert a source-directory file URL into head/html, or prepend
    /// a head element when neither tag exists.
    public static func snapshotHTML(
        _ content: String,
        sourceURL: URL?,
        maximumByteCount: Int = defaultMaximumSnapshotByteCount
    ) throws -> String {
        guard maximumByteCount >= 0 else {
            throw HTMLBrowserPreviewError.snapshotTooLarge(
                actual: content.utf8.count, maximum: maximumByteCount
            )
        }
        let contentCount = content.utf8.count
        guard contentCount <= maximumByteCount else {
            throw HTMLBrowserPreviewError.snapshotTooLarge(
                actual: contentCount, maximum: maximumByteCount
            )
        }
        guard let sourceURL else { return content }
        guard isAbsoluteLocalFileURL(sourceURL) else {
            throw HTMLBrowserPreviewError.invalidSourceURL(sourceURL)
        }
        guard firstMatch(of: #"<base(?:\s|>)"#, in: content) == nil else {
            return content
        }

        let directory = URL(
            fileURLWithPath: sourceURL.deletingLastPathComponent().path,
            isDirectory: true
        )
        let escapedURL = escapeAttribute(directory.absoluteString)
        let base = "<base href=\"\(escapedURL)\">"
        let rendered: String
        if let range = firstMatch(of: #"<head(?:\s[^>]*)?>"#, in: content) {
            rendered = content.replacingCharacters(
                in: range, with: String(content[range]) + "\n" + base
            )
        } else if let range = firstMatch(of: #"<html(?:\s[^>]*)?>"#, in: content) {
            rendered = content.replacingCharacters(
                in: range, with: String(content[range]) + "\n<head>" + base + "</head>"
            )
        } else {
            rendered = "<head>" + base + "</head>\n" + content
        }
        let renderedCount = rendered.utf8.count
        guard renderedCount <= maximumByteCount else {
            throw HTMLBrowserPreviewError.snapshotTooLarge(
                actual: renderedCount, maximum: maximumByteCount
            )
        }
        return rendered
    }

    private static func isAbsoluteLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL
            && url.path.hasPrefix("/")
            && url.host?.isEmpty != false
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }

    private static func firstMatch(of pattern: String, in value: String) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        guard let match = expression.firstMatch(
            in: value, range: NSRange(value.startIndex..., in: value)
        ) else { return nil }
        return Range(match.range, in: value)
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Owns a small, process-lifetime set of private HTML snapshot files. Call
/// `cleanup()` during application termination; deinitialization is a fallback.
public final class HTMLBrowserPreviewStore: @unchecked Sendable {
    public static let defaultMaximumRetainedSnapshots = 8

    public let temporaryRootURL: URL
    public let maximumSnapshotByteCount: Int
    public let maximumRetainedSnapshots: Int

    private let fileManager: FileManager
    private let lock = NSLock()
    private var sessionDirectory: URL?
    private var sessionDirectoryDescriptor: DirectoryDescriptor?
    private var snapshotURLs: [URL] = []
    private var isClosed = false

    public init(
        temporaryRootURL: URL = FileManager.default.temporaryDirectory,
        maximumSnapshotByteCount: Int = HTMLBrowserPreview.defaultMaximumSnapshotByteCount,
        maximumRetainedSnapshots: Int = defaultMaximumRetainedSnapshots,
        fileManager: FileManager = .default
    ) {
        self.temporaryRootURL = temporaryRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.maximumSnapshotByteCount = max(0, maximumSnapshotByteCount)
        self.maximumRetainedSnapshots = max(1, maximumRetainedSnapshots)
        self.fileManager = fileManager
    }

    deinit { shutdown() }

    public var temporaryDirectoryURL: URL? {
        synchronized { sessionDirectory }
    }

    public var retainedSnapshotURLs: [URL] {
        synchronized { snapshotURLs }
    }

    public func prepare(_ request: HTMLBrowserPreviewRequest) throws -> HTMLBrowserPreviewTarget {
        if try !HTMLBrowserPreview.requiresSnapshot(request) {
            return HTMLBrowserPreviewTarget(
                url: request.sourceURL!.standardizedFileURL,
                kind: .savedFile
            )
        }

        let html = try HTMLBrowserPreview.snapshotHTML(
            request.content,
            sourceURL: request.sourceURL,
            maximumByteCount: maximumSnapshotByteCount
        )
        let data = Data(html.utf8)
        return try synchronized {
            guard !isClosed else { throw HTMLBrowserPreviewError.storeClosed }
            let directory = try requireSessionDirectory()
            let finalName = "preview-" + UUID().uuidString.lowercased() + ".html"
            let finalURL = directory.url.appendingPathComponent(
                finalName,
                isDirectory: false
            )
            try writeAtomically(
                data, finalName: finalName,
                directoryURL: directory.url, directoryDescriptor: directory.descriptor
            )
            snapshotURLs.append(finalURL)
            while snapshotURLs.count > maximumRetainedSnapshots {
                let expired = snapshotURLs.removeFirst()
                try? fileManager.removeItem(at: expired)
            }
            return HTMLBrowserPreviewTarget(url: finalURL, kind: .temporarySnapshot)
        }
    }

    /// Removes only this store's unguessable private directory. Safe to repeat
    /// and reuse if an application-termination flow is later cancelled.
    public func cleanup() {
        removeTemporaryFiles(markClosed: false)
    }

    /// Permanently closes the store after removing snapshots. Used only once
    /// the application really is terminating, and as a deinit fallback.
    public func shutdown() {
        removeTemporaryFiles(markClosed: true)
    }

    private func removeTemporaryFiles(markClosed: Bool) {
        synchronized {
            if markClosed { isClosed = true }
            let directory = sessionDirectory
            sessionDirectory = nil
            sessionDirectoryDescriptor?.close()
            sessionDirectoryDescriptor = nil
            snapshotURLs.removeAll(keepingCapacity: false)
            if let directory { try? fileManager.removeItem(at: directory) }
        }
    }

    /// Removes a snapshot whose browser launch failed. Only URLs previously
    /// emitted by this store are accepted, so callers cannot turn cleanup into
    /// an arbitrary file deletion primitive.
    public func discardTemporarySnapshot(at url: URL) {
        synchronized {
            guard let index = snapshotURLs.firstIndex(of: url) else { return }
            snapshotURLs.remove(at: index)
            try? fileManager.removeItem(at: url)
        }
    }

    private func requireSessionDirectory() throws -> (url: URL, descriptor: Int32) {
        if let sessionDirectory, let sessionDirectoryDescriptor {
            return (sessionDirectory, sessionDirectoryDescriptor.rawValue)
        }
        guard temporaryRootURL.isFileURL, temporaryRootURL.path.hasPrefix("/"),
              temporaryRootURL.host?.isEmpty != false,
              temporaryRootURL.query == nil, temporaryRootURL.fragment == nil,
              !isSymbolicLink(temporaryRootURL),
              (try? temporaryRootURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else {
            throw HTMLBrowserPreviewError.invalidTemporaryDirectory(temporaryRootURL)
        }
        let rootDescriptorValue = Darwin.open(
            temporaryRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptorValue >= 0 else {
            throw HTMLBrowserPreviewError.invalidTemporaryDirectory(temporaryRootURL)
        }
        let rootDescriptor = DirectoryDescriptor(rootDescriptorValue)

        for _ in 0..<8 {
            let name = "lumen-html-preview-" + UUID().uuidString.lowercased()
            let candidate = temporaryRootURL.appendingPathComponent(
                name,
                isDirectory: true
            )
            if mkdirat(rootDescriptor.rawValue, name, mode_t(S_IRWXU)) == 0 {
                let descriptor = openat(
                    rootDescriptor.rawValue, name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    _ = unlinkat(rootDescriptor.rawValue, name, AT_REMOVEDIR)
                    throw fileSystemError(
                        operation: "open private directory", url: candidate
                    )
                }
                let ownedDescriptor = DirectoryDescriptor(descriptor)
                guard fchmod(ownedDescriptor.rawValue, mode_t(S_IRWXU)) == 0 else {
                    _ = unlinkat(rootDescriptor.rawValue, name, AT_REMOVEDIR)
                    throw fileSystemError(
                        operation: "protect private directory", url: candidate
                    )
                }
                sessionDirectory = candidate
                sessionDirectoryDescriptor = ownedDescriptor
                return (candidate, ownedDescriptor.rawValue)
            }
            if errno != EEXIST {
                throw fileSystemError(operation: "create private directory", url: candidate)
            }
        }
        throw HTMLBrowserPreviewError.tooManyTemporaryDirectoryCollisions
    }

    private func writeAtomically(
        _ data: Data,
        finalName: String,
        directoryURL: URL,
        directoryDescriptor: Int32
    ) throws {
        let temporaryName = ".writing-" + UUID().uuidString.lowercased()
        let temporaryURL = directoryURL.appendingPathComponent(
            temporaryName,
            isDirectory: false
        )
        let descriptor = openat(
            directoryDescriptor, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw fileSystemError(operation: "create snapshot", url: temporaryURL)
        }
        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporary { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw fileSystemError(operation: "write snapshot", url: temporaryURL)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw fileSystemError(operation: "sync snapshot", url: temporaryURL)
        }
        guard renameatx_np(
            directoryDescriptor, temporaryName,
            directoryDescriptor, finalName, UInt32(RENAME_EXCL)
        ) == 0 else {
            throw fileSystemError(
                operation: "publish snapshot",
                url: directoryURL.appendingPathComponent(finalName)
            )
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            _ = unlinkat(directoryDescriptor, finalName, 0)
            throw fileSystemError(operation: "sync snapshot directory", url: directoryURL)
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func fileSystemError(
        operation: String,
        url: URL
    ) -> HTMLBrowserPreviewError {
        .fileSystem(operation: operation, path: url.path, code: errno)
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private final class DirectoryDescriptor {
        private(set) var rawValue: Int32

        init(_ rawValue: Int32) { self.rawValue = rawValue }

        func close() {
            guard rawValue >= 0 else { return }
            _ = Darwin.close(rawValue)
            rawValue = -1
        }

        deinit { close() }
    }
}
