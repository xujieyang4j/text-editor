@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct UpdateInformation: Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String?
    public let releaseURL: URL?
    public let isAvailable: Bool

    public init(
        currentVersion: String,
        latestVersion: String?,
        releaseURL: URL?,
        isAvailable: Bool
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.releaseURL = releaseURL
        self.isAvailable = isAvailable
    }
}

public enum NativeUpdateArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x64

    public static var current: NativeUpdateArchitecture {
        #if arch(arm64)
        .arm64
        #else
        .x64
        #endif
    }
}

public enum UpdateCheckError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case redirected
    case invalidResponse
    case responseTooLarge(maximumBytes: Int)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The update endpoint is not an approved HTTPS URL."
        case .redirected:
            "The update service redirected the request unexpectedly."
        case .invalidResponse:
            "The update service returned an invalid response."
        case let .responseTooLarge(maximumBytes):
            "The update response exceeded \(maximumBytes) bytes."
        case .invalidPayload:
            "The update service returned malformed release metadata."
        }
    }
}

/// Bounded, redirect-free GitHub Releases checker used by the native app.
public final class UpdateService: @unchecked Sendable {
    public static let endpoint = URL(
        string: "https://api.github.com/repos/xujieyang4j/text-editor/releases/latest"
    )!
    public static let maximumResponseBytes = 256 * 1_024
    public static let timeout: TimeInterval = 8

    private let endpointURL: URL
    private let maximumResponseBytes: Int
    private let timeout: TimeInterval
    private let configuration: URLSessionConfiguration

    public init(
        endpointURL: URL = UpdateService.endpoint,
        maximumResponseBytes: Int = UpdateService.maximumResponseBytes,
        timeout: TimeInterval = UpdateService.timeout
    ) {
        precondition(maximumResponseBytes > 0)
        precondition(timeout > 0)
        self.endpointURL = endpointURL
        self.maximumResponseBytes = maximumResponseBytes
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.configuration = configuration
    }

    public func check(currentVersion: String) async throws -> UpdateInformation {
        guard Self.isApprovedEndpoint(endpointURL) else {
            throw UpdateCheckError.invalidEndpoint
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LumenEditorNative/" + currentVersion, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let delegate = BoundedUpdateDownload(
            expectedURL: endpointURL, maximumBytes: maximumResponseBytes
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: queue
        )
        let task = session.dataTask(with: request)
        let (data, http) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(session: session, task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
        return try Self.parse(
            data, currentVersion: currentVersion, responseURL: http.url,
            architecture: .current
        )
    }

    public static func parse(
        _ data: Data,
        currentVersion: String,
        responseURL: URL? = endpoint,
        architecture: NativeUpdateArchitecture = .current
    ) throws -> UpdateInformation {
        guard data.count <= maximumResponseBytes else {
            throw UpdateCheckError.responseTooLarge(
                maximumBytes: maximumResponseBytes
            )
        }
        guard responseURL == endpoint,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTag = root["tag_name"] as? String,
              root["draft"] as? Bool != true,
              root["prerelease"] as? Bool != true else {
            throw UpdateCheckError.invalidPayload
        }
        let latest = normalizedVersion(rawTag)
        guard !latest.isEmpty, latest.utf16.count <= 64,
              !latest.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw UpdateCheckError.invalidPayload }

        let releaseURL = (root["html_url"] as? String)
            .flatMap(URL.init(string:))
            .flatMap { isApprovedReleaseURL($0) ? $0 : nil }
        let expectedAssets = expectedAssetNames(
            version: latest, architecture: architecture
        )
        let availableAssets = Set((root["assets"] as? [[String: Any]] ?? []).compactMap {
            $0["name"] as? String
        })
        let hasNativeArtifact = expectedAssets.isSubset(of: availableAssets)
        return UpdateInformation(
            currentVersion: currentVersion,
            latestVersion: latest,
            releaseURL: hasNativeArtifact ? releaseURL : nil,
            isAvailable: hasNativeArtifact
                && compareVersions(latest, currentVersion) == .orderedDescending
        )
    }

    public static func expectedAssetNames(
        version: String, architecture: NativeUpdateArchitecture
    ) -> Set<String> {
        let prefix = "text-editor-xujieyang-\(normalizedVersion(version))-native-macos-\(architecture.rawValue)"
        return [prefix + ".dmg", prefix + ".zip"]
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(normalizedVersion(lhs))
        let right = versionComponents(normalizedVersion(rhs))
        let count = max(left.numbers.count, right.numbers.count)
        for index in 0..<count {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _?): return .orderedDescending
        case (_?, nil): return .orderedAscending
        case let (a?, b?):
            return a.compare(b, options: [.numeric, .caseInsensitive])
        }
    }

    public static func isApprovedReleaseURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && (url.path == "/xujieyang4j/text-editor/releases"
                || url.path.hasPrefix("/xujieyang4j/text-editor/releases/"))
            && url.user == nil && url.password == nil
    }

    private static func isApprovedEndpoint(_ url: URL) -> Bool {
        url == endpoint && url.scheme == "https"
    }

    private static func normalizedVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first?.lowercased() == "v"
            ? String(trimmed.dropFirst()) : trimmed
    }

    private static func versionComponents(
        _ value: String
    ) -> (numbers: [UInt64], prerelease: String?) {
        let withoutBuild = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = pieces.first.map(String.init) ?? ""
        let prerelease = pieces.count > 1 && !pieces[1].isEmpty ? String(pieces[1]) : nil
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map {
            UInt64($0) ?? 0
        }
        return (numbers, prerelease)
    }
}

private final class BoundedUpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedURL: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var isFinished = false
    private var cancellationRequested = false

    init(expectedURL: URL, maximumBytes: Int) {
        self.expectedURL = expectedURL
        self.maximumBytes = maximumBytes
    }

    func begin(
        session: URLSession,
        task: URLSessionDataTask,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        lock.lock()
        if cancellationRequested {
            isFinished = true
            lock.unlock()
            session.invalidateAndCancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.session = session
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(UpdateCheckError.invalidResponse))
            return
        }
        guard response.url == expectedURL else {
            completionHandler(.cancel)
            finish(.failure(UpdateCheckError.redirected))
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(UpdateCheckError.responseTooLarge(
                maximumBytes: maximumBytes
            )))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive chunk: Data
    ) {
        lock.lock()
        let nextCount = data.count + chunk.count
        guard !isFinished, nextCount <= maximumBytes else {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(UpdateCheckError.responseTooLarge(
                maximumBytes: maximumBytes
            )))
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        task.cancel()
        finish(.failure(UpdateCheckError.redirected))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = self.data
        lock.unlock()
        guard let response else {
            finish(.failure(UpdateCheckError.invalidResponse))
            return
        }
        finish(.success((data, response)))
    }

    private func finish(
        _ result: Result<(Data, HTTPURLResponse), Error>
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
