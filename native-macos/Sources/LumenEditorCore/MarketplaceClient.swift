import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MarketplaceCatalogFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case marketplaceClient(MarketplaceClientError)
        case manifestValidation(PluginManifestValidationError)
        case verbatim(String)
    }

    public let sourceURL: URL
    public let reason: Reason

    /// Stable English text retained for non-UI diagnostics. Presentation
    /// layers should render `reason` using their current runtime locale.
    public var message: String {
        switch reason {
        case let .marketplaceClient(error): error.localizedDescription
        case let .manifestValidation(error): error.localizedDescription
        case let .verbatim(message): message
        }
    }

    public init(sourceURL: URL, reason: Reason) {
        self.sourceURL = sourceURL
        self.reason = reason
    }

    public init(sourceURL: URL, message: String) {
        self.init(sourceURL: sourceURL, reason: .verbatim(message))
    }
}

public struct MarketplaceCatalogResult: Equatable, Sendable {
    public let items: [MarketplaceItem]
    public let failures: [MarketplaceCatalogFailure]
}

/// A package whose remote bytes have already passed the manifest transport,
/// same-origin and SRI checks. Its initializer is module-internal so production
/// callers obtain it through `MarketplaceClient`; `PluginStore` nevertheless
/// revalidates the proof before committing it to disk.
public struct MarketplacePluginPackage: Equatable, Sendable {
    public let manifest: PluginManifest
    public let sourceManifestURL: URL
    public let verifiedWorkerData: Data?
    public let installedManifestData: Data
    public let workerExecutionSupport: PluginWorkerExecutionSupport

    init(
        manifest: PluginManifest,
        sourceManifestURL: URL,
        verifiedWorkerData: Data?,
        installedManifestData: Data
    ) {
        self.manifest = manifest
        self.sourceManifestURL = sourceManifestURL
        self.verifiedWorkerData = verifiedWorkerData
        self.installedManifestData = installedManifestData
        self.workerExecutionSupport = manifest.extensionManifest == nil
            ? .unsupported : .isolatedProcess
    }
}

public enum MarketplaceClientError: Error, Equatable, Sendable {
    case unexpectedResponse
    case authenticationRejected
    case transport(URLError.Code)
    case manifestIdentityMismatch(expected: String, actual: String)
    case marketplaceWorkerUnavailable
}

extension MarketplaceClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            "The marketplace returned a non-HTTP response."
        case .authenticationRejected:
            "Marketplace authentication is unsupported; credentials were not supplied."
        case let .transport(code):
            "The marketplace request failed (URL error \(code.rawValue))."
        case let .manifestIdentityMismatch(expected, actual):
            "The downloaded manifest ID ‘\(actual)’ does not match catalog ID ‘\(expected)’."
        case .marketplaceWorkerUnavailable:
            "A marketplace worker declaration requires a same-origin HTTPS URL and SHA-256 integrity."
        }
    }
}

/// HTTPS-only, credential-free transport for declarative plugin marketplaces.
///
/// Every request gets a fresh ephemeral URLSession. Cookies, cache and shared
/// credential storage are disabled, redirects and authentication challenges are
/// rejected, and the delegate stops receiving a body as soon as its cap is hit.
/// Downloaded workers are verified and stored as inert bytes. Execution remains
/// a separate, explicitly approved responsibility of the isolated app runtime.
public final class MarketplaceClient: @unchecked Sendable {
    public static let workerExecutionSupport: PluginWorkerExecutionSupport = .isolatedProcess
    public static let maximumCatalogItems = 1_000

    private let configurationFactory: @Sendable () -> URLSessionConfiguration

    public convenience init() {
        self.init(configurationFactory: { Self.makeEphemeralConfiguration() })
    }

    init(
        configurationFactory: @escaping @Sendable () -> URLSessionConfiguration
    ) {
        self.configurationFactory = configurationFactory
    }

    static func makeEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.timeoutIntervalForRequest = PluginManifestSecurity.networkTimeoutSeconds
        configuration.timeoutIntervalForResource = PluginManifestSecurity.networkTimeoutSeconds
        return configuration
    }

    public func fetchCatalog(from sourceURL: URL) async throws -> [MarketplaceItem] {
        let request = try PluginManifestSecurity.marketplaceCatalogRequest(for: sourceURL)
        let data = try await fetch(request, accept: "application/json")
        return Array(try MarketplaceItem.parseCatalog(data).prefix(Self.maximumCatalogItems))
    }

    /// Fetches independent sources concurrently. One failed source does not hide
    /// other results; cross-source duplicate IDs use last-source-wins while
    /// retaining the first position, matching the parser's catalog semantics.
    public func fetchCatalogs(from sourceURLs: [URL]) async -> MarketplaceCatalogResult {
        let bounded = PluginManifestSecurity.sanitizeMarketplaceSourceURLs(
            sourceURLs.map(\.absoluteString)
        )
        let responses = await withTaskGroup(
            of: (Int, URL, Result<[MarketplaceItem], Error>).self,
            returning: [(Int, URL, Result<[MarketplaceItem], Error>)].self
        ) { group in
            for (index, url) in bounded.enumerated() {
                group.addTask { [self] in
                    do { return (index, url, .success(try await fetchCatalog(from: url))) }
                    catch { return (index, url, .failure(error)) }
                }
            }
            var values: [(Int, URL, Result<[MarketplaceItem], Error>)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }

        var items: [MarketplaceItem] = []
        var indexes: [String: Int] = [:]
        var failures: [MarketplaceCatalogFailure] = []
        for (_, source, result) in responses {
            switch result {
            case let .success(sourceItems):
                for item in sourceItems {
                    if let index = indexes[item.id] {
                        items[index] = item
                    } else {
                        indexes[item.id] = items.count
                        items.append(item)
                    }
                    if items.count == Self.maximumCatalogItems { break }
                }
            case let .failure(error):
                failures.append(MarketplaceCatalogFailure(
                    sourceURL: source,
                    reason: catalogFailureReason(for: error)
                ))
            }
        }
        return MarketplaceCatalogResult(items: items, failures: failures)
    }

    private func catalogFailureReason(
        for error: any Error
    ) -> MarketplaceCatalogFailure.Reason {
        if let error = error as? MarketplaceClientError {
            return .marketplaceClient(error)
        }
        if let error = error as? PluginManifestValidationError {
            return .manifestValidation(error)
        }
        return .verbatim(error.localizedDescription)
    }

    public func downloadPlugin(for item: MarketplaceItem) async throws -> MarketplacePluginPackage {
        let package = try await downloadPlugin(from: item.manifestURL)
        guard package.manifest.id == item.id else {
            throw MarketplaceClientError.manifestIdentityMismatch(
                expected: item.id, actual: package.manifest.id
            )
        }
        return package
    }

    public func downloadPlugin(from manifestURL: URL) async throws -> MarketplacePluginPackage {
        let manifestRequest = try PluginManifestSecurity.marketplaceManifestRequest(for: manifestURL)
        let manifestData = try await fetch(manifestRequest, accept: "application/json")
        let manifest = try PluginManifest.parse(manifestData)

        let workerRequest = try PluginManifestSecurity.marketplaceWorkerRequest(
            for: manifest,
            manifestURL: manifestURL
        )
        if manifest.extensionManifest != nil, workerRequest == nil {
            throw MarketplaceClientError.marketplaceWorkerUnavailable
        }

        let workerData: Data?
        if let workerRequest {
            // `fetch` invokes validateResponse on the original bytes, including
            // exact SRI comparison, before this package can be constructed.
            workerData = try await fetch(workerRequest, accept: "application/javascript")
        } else {
            workerData = nil
        }

        return MarketplacePluginPackage(
            manifest: manifest,
            sourceManifestURL: manifestURL,
            verifiedWorkerData: workerData,
            installedManifestData: try installedManifestData(for: manifest)
        )
    }

    fileprivate func fetch(
        _ contract: MarketplaceResourceRequest,
        accept: String
    ) async throws -> Data {
        let maximumBytes = contract.maximumByteCount ?? 0
        let delegate = BoundedMarketplaceDownload(
            request: contract,
            maximumBytes: maximumBytes
        )
        let configuration = configurationFactory()
        // Re-assert the non-persistent policy even for test/custom factories.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: queue
        )
        var urlRequest = URLRequest(
            url: contract.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: contract.timeoutSeconds
        )
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: urlRequest)

        do {
            let (data, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.begin(
                        session: session, task: task, continuation: continuation
                    )
                }
            } onCancel: {
                delegate.cancel()
            }
            try PluginManifestSecurity.validateResponse(
                statusCode: response.statusCode,
                finalURL: response.url ?? contract.url,
                data: data,
                against: contract
            )
            return data
        } catch let error as PluginManifestValidationError {
            throw error
        } catch let error as MarketplaceClientError {
            throw error
        } catch let error as URLError {
            throw MarketplaceClientError.transport(error.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    /// Emits only parser-sanitized fields. Marketplace URLs, integrity strings,
    /// ignored install scripts and any other unknown keys never reach disk.
    private func installedManifestData(for manifest: PluginManifest) throws -> Data {
        let commands: [[String: Any]] = manifest.commands.map { command in
            var value: [String: Any] = ["id": command.id, "title": command.title]
            if let insertText = command.insertText { value["insertText"] = insertText }
            return value
        }
        let snippets: [[String: Any]] = manifest.snippets.map { snippet in
            var value: [String: Any] = ["label": snippet.label, "text": snippet.text]
            if let trigger = snippet.trigger { value["trigger"] = trigger }
            if let scope = snippet.scope { value["scope"] = scope }
            return value
        }
        var object: [String: Any] = [
            "id": manifest.id,
            "name": manifest.name,
            "version": manifest.version,
            "enabled": manifest.enabled,
            "commands": commands,
            "snippets": snippets
        ]
        if let extensionManifest = manifest.extensionManifest {
            object["extension"] = [
                "worker": extensionManifest.worker,
                "permissions": extensionManifest.permissions.map(\.rawValue)
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard try PluginManifest.parse(data) == manifest.removingMarketplaceMetadata() else {
            throw MarketplaceClientError.unexpectedResponse
        }
        return data
    }
}

final class BoundedMarketplaceDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: MarketplaceResourceRequest
    private let maximumBytes: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var isFinished = false
    private var cancellationRequested = false

    init(request: MarketplaceResourceRequest, maximumBytes: Int) {
        self.request = request
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
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(MarketplaceClientError.unexpectedResponse))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(PluginManifestValidationError.unsuccessfulHTTPStatus(
                response.statusCode
            )))
            return
        }
        guard response.url?.absoluteString == request.url.absoluteString else {
            completionHandler(.cancel)
            finish(.failure(PluginManifestValidationError.redirectedResource(
                expected: request.url.absoluteString,
                actual: response.url?.absoluteString ?? "<unknown>"
            )))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(sizeError(maximumBytes + 1)))
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
        didReceive data: Data
    ) {
        lock.lock()
        let nextCount = self.data.count + data.count
        guard !isFinished, nextCount <= maximumBytes else {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(sizeError(nextCount)))
            return
        }
        self.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest redirectedRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        task.cancel()
        finish(.failure(PluginManifestValidationError.redirectedResource(
            expected: request.url.absoluteString,
            actual: redirectedRequest.url?.absoluteString
                ?? response.url?.absoluteString
                ?? "<unknown>"
        )))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            task.cancel()
            finish(.failure(MarketplaceClientError.authenticationRejected))
        }
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
            finish(.failure(MarketplaceClientError.unexpectedResponse))
            return
        }
        finish(.success((data, response)))
    }

    private func sizeError(_ count: Int) -> PluginManifestValidationError {
        request.kind == .worker
            ? .workerByteCountOutOfRange(count)
            : .manifestByteCountOutOfRange(count)
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}
