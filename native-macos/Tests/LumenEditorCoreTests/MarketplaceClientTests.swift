import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LumenEditorCore

final class MarketplaceClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockMarketplaceURLProtocol.reset()
    }

    override func tearDown() {
        MockMarketplaceURLProtocol.reset()
        super.tearDown()
    }

    func testProductionConfigurationIsEphemeralAndCredentialFree() {
        let configuration = MarketplaceClient.makeEphemeralConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.httpAdditionalHeaders?.count, 0)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
    }

    func testCatalogFetchUsesHTTPSGETWithoutCookieOrAuthorizationAndParsesBoundedBody() async throws {
        let source = try XCTUnwrap(URL(string: "https://market.example.test/index.json"))
        MockMarketplaceURLProtocol.handler = { request in
            XCTAssertEqual(request.url, source)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return .init(data: try JSONSerialization.data(withJSONObject: [[
                "id": "sample",
                "name": "Sample",
                "manifestUrl": "https://market.example.test/sample.json"
            ]]))
        }

        let items = try await client().fetchCatalog(from: source)
        XCTAssertEqual(items.map(\.id), ["sample"])
        XCTAssertEqual(MockMarketplaceURLProtocol.requests.count, 1)
    }

    func testHTTPAndChangedFinalURLAreRejected() async throws {
        let insecure = try XCTUnwrap(URL(string: "http://market.example.test/index.json"))
        do {
            _ = try await client().fetchCatalog(from: insecure)
            XCTFail("HTTP must be rejected before URLSession starts")
        } catch {
            guard case .invalidHTTPSURL = error as? PluginManifestValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(MockMarketplaceURLProtocol.requests.count, 0)

        let original = try XCTUnwrap(URL(string: "https://market.example.test/index.json"))
        let redirected = try XCTUnwrap(URL(string: "https://market.example.test/redirected.json"))
        MockMarketplaceURLProtocol.handler = { _ in
            .init(responseURL: redirected, data: Data("[]".utf8))
        }
        do {
            _ = try await client().fetchCatalog(from: original)
            XCTFail("A changed final URL must be rejected")
        } catch {
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .redirectedResource(
                    expected: original.absoluteString, actual: redirected.absoluteString
                )
            )
        }
    }

    func testRedirectDelegateRejectsBeforeFollowingLocation() throws {
        let original = try XCTUnwrap(URL(string: "https://market.example.test/index.json"))
        let redirected = try XCTUnwrap(URL(string: "https://other.example.test/index.json"))
        let contract = try PluginManifestSecurity.marketplaceCatalogRequest(for: original)
        let delegate = BoundedMarketplaceDownload(
            request: contract,
            maximumBytes: PluginManifestSecurity.maximumMarketplaceCatalogByteCount
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.absoluteString]
        ))
        let request = URLRequest(url: redirected)
        var followed: URLRequest? = request

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        ) { followed = $0 }

        XCTAssertNil(followed)
        session.invalidateAndCancel()
    }

    func testBodyCapStopsOversizedCatalogBeforeParsing() async throws {
        let source = try XCTUnwrap(URL(string: "https://market.example.test/index.json"))
        let oversized = Data(
            repeating: 0x20,
            count: PluginManifestSecurity.maximumMarketplaceCatalogByteCount + 1
        )
        MockMarketplaceURLProtocol.handler = { _ in .init(data: oversized) }

        do {
            _ = try await client().fetchCatalog(from: source)
            XCTFail("Oversized bodies must be cancelled")
        } catch {
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .manifestByteCountOutOfRange(oversized.count)
            )
        }
    }

    func testDownloadVerifiesSameOriginWorkerSRIAndStripsRemoteMetadata() async throws {
        let manifestURL = try XCTUnwrap(
            URL(string: "https://plugins.example.test/plugin.json")
        )
        let workerURL = try XCTUnwrap(
            URL(string: "https://plugins.example.test/assets/worker.js")
        )
        let worker = Data("self.onmessage = () => {}".utf8)
        let manifest = try manifestData(
            id: "verified", workerURL: workerURL, workerData: worker
        )
        MockMarketplaceURLProtocol.handler = { request in
            switch request.url {
            case manifestURL: return .init(data: manifest)
            case workerURL: return .init(data: worker)
            default: throw URLError(.badURL)
            }
        }

        let package = try await client().downloadPlugin(from: manifestURL)

        XCTAssertEqual(package.manifest.id, "verified")
        XCTAssertEqual(package.verifiedWorkerData, worker)
        XCTAssertEqual(package.workerExecutionSupport, .isolatedProcess)
        XCTAssertEqual(MockMarketplaceURLProtocol.requests.compactMap(\.url), [manifestURL, workerURL])
        let installed = try PluginManifest.parse(package.installedManifestData)
        XCTAssertNil(installed.extensionManifest?.workerURL)
        XCTAssertNil(installed.extensionManifest?.workerIntegrity)
        XCTAssertFalse(String(decoding: package.installedManifestData, as: UTF8.self).contains("workerUrl"))
    }

    func testWorkerIntegrityMismatchFailsBeforePackageExists() async throws {
        let manifestURL = try XCTUnwrap(
            URL(string: "https://plugins.example.test/plugin.json")
        )
        let workerURL = try XCTUnwrap(
            URL(string: "https://plugins.example.test/worker.js")
        )
        let expectedWorker = Data("expected".utf8)
        let manifest = try manifestData(
            id: "tampered", workerURL: workerURL, workerData: expectedWorker
        )
        MockMarketplaceURLProtocol.handler = { request in
            request.url == manifestURL
                ? .init(data: manifest)
                : .init(data: Data("tampered".utf8))
        }

        do {
            _ = try await client().downloadPlugin(from: manifestURL)
            XCTFail("Tampered worker bytes must never form an installable package")
        } catch {
            XCTAssertEqual(error as? PluginManifestValidationError, .workerIntegrityMismatch)
        }
    }

    func testCrossOriginAndUnverifiableWorkersFailWithoutFetchingWorker() async throws {
        let manifestURL = try XCTUnwrap(
            URL(string: "https://plugins.example.test/plugin.json")
        )
        let worker = Data("worker".utf8)
        let crossOriginURL = try XCTUnwrap(URL(string: "https://cdn.example.test/worker.js"))
        let crossOrigin = try manifestData(
            id: "cross-origin", workerURL: crossOriginURL, workerData: worker
        )
        MockMarketplaceURLProtocol.handler = { _ in .init(data: crossOrigin) }
        do {
            _ = try await client().downloadPlugin(from: manifestURL)
            XCTFail("Cross-origin workers must be rejected")
        } catch {
            XCTAssertEqual(
                error as? PluginManifestValidationError, .marketplaceWorkerOriginMismatch
            )
        }
        XCTAssertEqual(MockMarketplaceURLProtocol.requests.count, 1)

        MockMarketplaceURLProtocol.reset()
        let localOnly = try JSONSerialization.data(withJSONObject: [
            "id": "local-worker",
            "name": "Local worker",
            "extension": ["worker": "worker.js"]
        ])
        MockMarketplaceURLProtocol.handler = { _ in .init(data: localOnly) }
        do {
            _ = try await client().downloadPlugin(from: manifestURL)
            XCTFail("Marketplace workers without verifiable remote bytes are unsupported")
        } catch {
            XCTAssertEqual(error as? MarketplaceClientError, .marketplaceWorkerUnavailable)
        }
        XCTAssertEqual(MockMarketplaceURLProtocol.requests.count, 1)
    }

    func testCatalogIdentityMustMatchDownloadedManifest() async throws {
        let catalogData = try JSONSerialization.data(withJSONObject: [[
            "id": "catalog-id",
            "name": "Catalog",
            "manifestUrl": "https://market.example.test/plugin.json"
        ]])
        let item = try XCTUnwrap(MarketplaceItem.parseCatalog(catalogData).first)
        MockMarketplaceURLProtocol.handler = { _ in
            .init(data: try JSONSerialization.data(withJSONObject: [
                "id": "different-id", "name": "Different"
            ]))
        }

        do {
            _ = try await client().downloadPlugin(for: item)
            XCTFail("Catalog and manifest identities must agree")
        } catch {
            XCTAssertEqual(
                error as? MarketplaceClientError,
                .manifestIdentityMismatch(expected: "catalog-id", actual: "different-id")
            )
        }
    }

    func testCatalogFailuresPreserveTypedAndVerbatimReasons() async throws {
        let validationSource = try XCTUnwrap(
            URL(string: "https://market.example.test/invalid.json")
        )
        let externalSource = try XCTUnwrap(
            URL(string: "https://market.example.test/external.json")
        )
        MockMarketplaceURLProtocol.handler = { request in
            if request.url == validationSource {
                return .init(statusCode: 503, data: Data())
            }
            throw MarketplaceFixtureFailure.external
        }

        let result = await client().fetchCatalogs(
            from: [validationSource, externalSource]
        )

        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(
            result.failures[0].reason,
            .manifestValidation(.unsuccessfulHTTPStatus(503))
        )
        XCTAssertEqual(
            result.failures[1].reason,
            .verbatim("external marketplace fixture failure")
        )
    }

    private func client() -> MarketplaceClient {
        MarketplaceClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockMarketplaceURLProtocol.self]
            return configuration
        }
    }

    private func manifestData(id: String, workerURL: URL, workerData: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id,
            "name": id,
            "commands": [["id": "insert", "title": "Insert", "insertText": "ok"]],
            "extension": [
                "worker": "dist/worker.js",
                "workerUrl": workerURL.absoluteString,
                "workerIntegrity": SHA256Integrity.digest(of: workerData).rawValue
            ]
        ])
    }
}

private enum MarketplaceFixtureFailure: Error, LocalizedError {
    case external

    var errorDescription: String? { "external marketplace fixture failure" }
}

private final class MockMarketplaceURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let responseURL: URL?
        let statusCode: Int
        let headers: [String: String]?
        let data: Data

        init(
            responseURL: URL? = nil,
            statusCode: Int = 200,
            headers: [String: String]? = nil,
            data: Data
        ) {
            self.responseURL = responseURL
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
        }
    }

    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []
    static var handler: ((URLRequest) throws -> Stub)?

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func reset() {
        lock.lock()
        recordedRequests = []
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: stub.responseURL ?? request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
