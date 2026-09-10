import CryptoKit
import Foundation

/// The only capabilities a declarative plugin may request. A manifest request
/// and a project grant are deliberately separate; callers should pass grants
/// through `PluginManifest.effectivePermissions(granted:)` before activation.
public enum PluginPermission: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case documentRead = "document-read"
    case documentEdit = "document-edit"
}

/// A command declared by a plugin. Core only models the bounded insertion; it
/// neither dispatches code nor gives the contribution an executable callback.
/// Instances are parser-produced so callers cannot bypass normalization.
public struct PluginCommandContribution: Equatable, Sendable {
    public let id: String
    public let title: String
    public let insertText: String?
}

public typealias PluginCommand = PluginCommandContribution

/// A bounded, declarative snippet contribution. Parser-only construction keeps
/// its length and trigger invariants centralized.
public struct PluginSnippetContribution: Equatable, Sendable {
    public let label: String
    public let text: String
    public let trigger: String?
    public let scope: String?
}

public typealias PluginSnippet = PluginSnippetContribution

/// An SRI-style SHA-256 value (`sha256-` plus a 32-byte standard Base64 digest).
public struct SHA256Integrity: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 51, rawValue.hasPrefix("sha256-") else {
            return nil
        }
        let encoded = Array(rawValue.dropFirst(7).utf8)
        let encodedString = String(decoding: encoded, as: UTF8.self)
        guard encoded.count == 44, encoded.last == 61,
              encoded.dropLast().allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 43
                      || byte == 47
              }),
              let digest = Data(base64Encoded: encodedString),
              digest.count == 32,
              digest.base64EncodedString() == encodedString else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static func digest(of data: Data) -> SHA256Integrity {
        let encoded = Data(SHA256.hash(data: data)).base64EncodedString()
        // A SHA-256 digest is always 32 bytes and therefore always has the
        // canonical 44-character Base64 shape accepted by the initializer.
        return SHA256Integrity(rawValue: "sha256-" + encoded)!
    }

    public func matches(_ data: Data) -> Bool {
        self == Self.digest(of: data)
    }
}

/// Optional worker metadata remains data only. This parser-produced DTO has no
/// public initializer; this module never creates a worker, evaluates JavaScript,
/// reads its file, or performs a network request.
public struct PluginExtensionManifest: Equatable, Sendable {
    public let worker: String
    public let permissions: [PluginPermission]
    public let workerURL: URL?
    public let workerIntegrity: SHA256Integrity?
}

public typealias PluginExtension = PluginExtensionManifest

/// Sanitized counterpart of the Electron `PluginManifest` IPC DTO. It is
/// intentionally parser-only so unsanitized declarations cannot be constructed.
public struct PluginManifest: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let enabled: Bool
    public let commands: [PluginCommandContribution]
    public let snippets: [PluginSnippetContribution]
    public let extensionManifest: PluginExtensionManifest?

    /// Compatibility spelling for consumers mapping the TypeScript `extension` field.
    public var `extension`: PluginExtensionManifest? { extensionManifest }

    public static func parse(_ data: Data) throws -> PluginManifest {
        try PluginManifestSecurity.parseManifest(data)
    }

    /// Only permissions both requested by this manifest and granted by the
    /// project are effective. Unknown strings never enter either typed list.
    public func effectivePermissions<S: Sequence>(
        granted: S
    ) -> [PluginPermission] where S.Element == PluginPermission {
        let grants = Set(granted)
        var seen = Set<PluginPermission>()
        return (extensionManifest?.permissions ?? []).filter { permission in
            grants.contains(permission) && seen.insert(permission).inserted
        }
    }

    /// Marketplace-only source metadata is never needed after verified bytes
    /// have been installed. Removing it prevents an installed manifest from
    /// being mistaken for another network installation request.
    public func removingMarketplaceMetadata() -> PluginManifest {
        guard let extensionManifest else { return self }
        return PluginManifest(
            id: id,
            name: name,
            version: version,
            enabled: enabled,
            commands: commands,
            snippets: snippets,
            extensionManifest: PluginExtensionManifest(
                worker: extensionManifest.worker,
                permissions: extensionManifest.permissions,
                workerURL: nil,
                workerIntegrity: nil
            )
        )
    }
}

/// Sanitized counterpart of the Electron `MarketplaceItem` IPC DTO. It is
/// intentionally parser-only.
public struct MarketplaceItem: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let manifestURL: URL

    public static func parseCatalog(_ data: Data) throws -> [MarketplaceItem] {
        try PluginManifestSecurity.parseMarketplaceCatalog(data)
    }
}

/// Metadata a future transport must obey. It is intentionally separate from a
/// URLSession implementation so parsing and verification cannot initiate I/O.
public enum MarketplaceResourceKind: String, Equatable, Sendable {
    case catalog
    case manifest
    case worker
}

public enum MarketplaceRedirectPolicy: String, Equatable, Sendable {
    case reject
}

/// Parser-produced transport contract. A future HTTP client must disable
/// automatic redirects and validate every response against this value.
public struct MarketplaceResourceRequest: Equatable, Sendable {
    public let kind: MarketplaceResourceKind
    public let url: URL
    public let redirectPolicy: MarketplaceRedirectPolicy
    public let timeoutSeconds: TimeInterval
    public let requiresSuccessfulHTTPStatus: Bool
    public let minimumByteCount: Int?
    public let maximumByteCount: Int?
    public let expectedIntegrity: SHA256Integrity?
}

public enum PluginManifestValidationError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidManifest
    case manifestByteCountOutOfRange(Int)
    case invalidHTTPSURL(String)
    case invalidWorkerPath(String)
    case incompleteMarketplaceWorkerMetadata
    case marketplaceWorkerOriginMismatch
    case redirectedResource(expected: String, actual: String)
    case unsuccessfulHTTPStatus(Int)
    case missingWorkerData
    case workerByteCountOutOfRange(Int)
    case workerIntegrityMismatch
}

extension PluginManifestValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "The plugin data is not valid JSON."
        case .invalidManifest:
            "The plugin manifest is invalid."
        case let .manifestByteCountOutOfRange(count):
            "The plugin manifest byte count is outside the allowed range: \(count)."
        case let .invalidHTTPSURL(value):
            "The marketplace URL must be an absolute HTTPS URL: \(value)"
        case let .invalidWorkerPath(value):
            "The extension worker path is invalid: \(value)"
        case .incompleteMarketplaceWorkerMetadata:
            "Marketplace workers require both an HTTPS URL and a SHA-256 integrity value."
        case .marketplaceWorkerOriginMismatch:
            "The marketplace worker must have the same HTTPS origin as its manifest."
        case .redirectedResource:
            "Marketplace redirects are not allowed."
        case let .unsuccessfulHTTPStatus(status):
            "The marketplace resource returned HTTP status \(status)."
        case .missingWorkerData:
            "The marketplace worker response has no body."
        case let .workerByteCountOutOfRange(count):
            "The extension worker byte count is outside the allowed range: \(count)."
        case .workerIntegrityMismatch:
            "The marketplace worker failed its SHA-256 integrity check."
        }
    }
}

/// Pure parsing and validation for plugin and marketplace data. This namespace
/// deliberately has no APIs that execute JavaScript or perform network access.
public enum PluginManifestSecurity {
    public static let maximumPluginNameUTF16Count = 200
    public static let maximumVersionUTF16Count = 50
    public static let maximumCommands = 50
    public static let maximumCommandIDUTF16Count = 100
    public static let maximumCommandTitleUTF16Count = 200
    public static let maximumInsertionUTF16Count = 10_000
    public static let maximumSnippets = 100
    public static let maximumSnippetLabelUTF16Count = 200
    public static let maximumSnippetTextUTF16Count = 10_000
    public static let maximumSnippetTriggerASCIIByteCount = 80
    public static let maximumSnippetScopeUTF16Count = 100
    public static let maximumMarketplaceDescriptionUTF16Count = 500
    public static let maximumMarketplaceSources = 20
    public static let maximumMarketplaceSourceURLUTF16Count = 2_000
    /// Native-only defence in depth. Electron currently has no explicit JSON
    /// response cap, but Core must not hand an unbounded body to JSONSerialization.
    public static let maximumManifestByteCount = 1_024 * 1_024
    public static let maximumMarketplaceCatalogByteCount = 4 * 1_024 * 1_024
    public static let maximumWorkerByteCount = 512 * 1_024
    public static let networkTimeoutSeconds: TimeInterval = 10

    public static func isValidPluginID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "-"
        }
    }

    public static func isSafeWorkerPath(_ value: String) -> Bool {
        isSafeRelativeWorkerPath(value)
    }

    /// Resolves a worker declaration without touching disk and checks lexical
    /// containment. A file-reading layer must separately reject/resolve symlinks
    /// before treating this as physical containment.
    public static func installedWorkerURL(
        pluginDirectory: URL,
        workerPath: String
    ) throws -> URL {
        guard pluginDirectory.isFileURL, pluginDirectory.path.hasPrefix("/"),
              isSafeRelativeWorkerPath(workerPath) else {
            throw PluginManifestValidationError.invalidWorkerPath(workerPath)
        }
        let directory = pluginDirectory.standardizedFileURL
        let candidate = directory
            .appendingPathComponent(workerPath, isDirectory: false)
            .standardizedFileURL
        let directoryComponents = directory.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= directoryComponents.count,
              Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents else {
            throw PluginManifestValidationError.invalidWorkerPath(workerPath)
        }
        return candidate
    }

    public static func parseManifest(_ data: Data) throws -> PluginManifest {
        guard !data.isEmpty, data.count <= maximumManifestByteCount else {
            throw PluginManifestValidationError.manifestByteCountOutOfRange(data.count)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw PluginManifestValidationError.invalidJSON
        }
        guard let manifest = sanitizeManifest(object) else {
            throw PluginManifestValidationError.invalidManifest
        }
        return manifest
    }

    /// Mirrors Electron's tolerant sanitizer: an invalid root ID/name rejects
    /// the manifest, while malformed optional fields and child contributions
    /// are dropped or defaulted independently.
    public static func sanitizeManifest(_ value: Any) -> PluginManifest? {
        guard let raw = value as? [String: Any],
              let id = raw["id"] as? String,
              isValidPluginID(id),
              let name = raw["name"] as? String else {
            return nil
        }

        let version = truncate(
            raw["version"] as? String ?? "0.0.0",
            maximumUTF16CodeUnits: maximumVersionUTF16Count
        )
        let enabled = jsonBoolean(raw["enabled"]) != false

        return PluginManifest(
            id: id,
            name: truncate(name, maximumUTF16CodeUnits: maximumPluginNameUTF16Count),
            version: version,
            enabled: enabled,
            commands: sanitizeCommands(raw["commands"]),
            snippets: sanitizeSnippets(raw["snippets"]),
            extensionManifest: sanitizeExtension(raw["extension"])
        )
    }

    /// Accepts either a top-level array or `{ "plugins": [...] }`, silently
    /// drops invalid entries, and applies JavaScript Map's last-value-wins ID
    /// de-duplication while preserving each ID's first insertion position.
    public static func parseMarketplaceCatalog(_ data: Data) throws -> [MarketplaceItem] {
        guard !data.isEmpty, data.count <= maximumMarketplaceCatalogByteCount else {
            throw PluginManifestValidationError.manifestByteCountOutOfRange(data.count)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw PluginManifestValidationError.invalidJSON
        }

        let entries: [Any]
        if let array = object as? [Any] {
            entries = array
        } else if let root = object as? [String: Any],
                  let plugins = root["plugins"] as? [Any] {
            entries = plugins
        } else {
            return []
        }

        var items: [MarketplaceItem] = []
        var indexes: [String: Int] = [:]
        for entry in entries {
            guard let item = sanitizeMarketplaceItem(entry) else { continue }
            if let index = indexes[item.id] {
                items[index] = item
            } else {
                indexes[item.id] = items.count
                items.append(item)
            }
        }
        return items
    }

    public static func sanitizeMarketplaceItem(_ value: Any) -> MarketplaceItem? {
        guard let raw = value as? [String: Any],
              let id = raw["id"] as? String,
              isValidPluginID(id),
              let name = raw["name"] as? String,
              let manifestURLString = raw["manifestUrl"] as? String,
              let manifestURL = absoluteHTTPSURL(manifestURLString) else {
            return nil
        }
        return MarketplaceItem(
            id: id,
            name: truncate(name, maximumUTF16CodeUnits: maximumPluginNameUTF16Count),
            version: truncate(
                raw["version"] as? String ?? "0.0.0",
                maximumUTF16CodeUnits: maximumVersionUTF16Count
            ),
            description: (raw["description"] as? String).map {
                truncate($0, maximumUTF16CodeUnits: maximumMarketplaceDescriptionUTF16Count)
            },
            manifestURL: manifestURL
        )
    }

    /// Applies the project-file source limits before any future network layer
    /// sees the URLs. Invalid values are filtered before the 20-source cap, as
    /// in Electron's project-settings sanitizer.
    public static func sanitizeMarketplaceSourceURLs(_ values: [String]) -> [URL] {
        var result: [URL] = []
        for value in values {
            guard value.hasPrefix("https://") else { continue }
            let bounded = truncate(
                value,
                maximumUTF16CodeUnits: maximumMarketplaceSourceURLUTF16Count
            )
            guard let url = absoluteHTTPSURL(bounded) else { continue }
            result.append(url)
            if result.count == maximumMarketplaceSources { break }
        }
        return result
    }

    public static func marketplaceManifestRequest(
        for url: URL
    ) throws -> MarketplaceResourceRequest {
        guard url.absoluteString.hasPrefix("https://"), isAbsoluteHTTPSURL(url) else {
            throw PluginManifestValidationError.invalidHTTPSURL(url.absoluteString)
        }
        return MarketplaceResourceRequest(
            kind: .manifest,
            url: url,
            redirectPolicy: .reject,
            timeoutSeconds: networkTimeoutSeconds,
            requiresSuccessfulHTTPStatus: true,
            minimumByteCount: nil,
            maximumByteCount: maximumManifestByteCount,
            expectedIntegrity: nil
        )
    }

    public static func marketplaceCatalogRequest(
        for url: URL
    ) throws -> MarketplaceResourceRequest {
        guard url.absoluteString.hasPrefix("https://"), isAbsoluteHTTPSURL(url) else {
            throw PluginManifestValidationError.invalidHTTPSURL(url.absoluteString)
        }
        return MarketplaceResourceRequest(
            kind: .catalog,
            url: url,
            redirectPolicy: .reject,
            timeoutSeconds: networkTimeoutSeconds,
            requiresSuccessfulHTTPStatus: true,
            minimumByteCount: nil,
            maximumByteCount: maximumMarketplaceCatalogByteCount,
            expectedIntegrity: nil
        )
    }

    /// Produces worker request metadata after checking pair completeness, HTTPS,
    /// and same-origin policy. A manifest without remote worker fields returns nil.
    public static func marketplaceWorkerRequest(
        for manifest: PluginManifest,
        manifestURL: URL
    ) throws -> MarketplaceResourceRequest? {
        guard manifestURL.absoluteString.hasPrefix("https://"),
              isAbsoluteHTTPSURL(manifestURL) else {
            throw PluginManifestValidationError.invalidHTTPSURL(manifestURL.absoluteString)
        }
        guard let extensionManifest = manifest.extensionManifest else { return nil }
        switch (extensionManifest.workerURL, extensionManifest.workerIntegrity) {
        case (nil, nil):
            return nil
        case (.some, nil), (nil, .some):
            throw PluginManifestValidationError.incompleteMarketplaceWorkerMetadata
        case let (.some(workerURL), .some(integrity)):
            guard workerURL.absoluteString.hasPrefix("https://"),
                  isAbsoluteHTTPSURL(workerURL) else {
                throw PluginManifestValidationError.invalidHTTPSURL(workerURL.absoluteString)
            }
            guard sameOrigin(manifestURL, workerURL) else {
                throw PluginManifestValidationError.marketplaceWorkerOriginMismatch
            }
            return MarketplaceResourceRequest(
                kind: .worker,
                url: workerURL,
                redirectPolicy: .reject,
                timeoutSeconds: networkTimeoutSeconds,
                requiresSuccessfulHTTPStatus: true,
                minimumByteCount: 1,
                maximumByteCount: maximumWorkerByteCount,
                expectedIntegrity: integrity
            )
        }
    }

    /// Verifies transport results without fetching them. Redirect rejection is
    /// an exact final-URL check; worker checks operate on the original bytes.
    public static func validateResponse(
        statusCode: Int = 200,
        finalURL: URL,
        data: Data? = nil,
        against request: MarketplaceResourceRequest
    ) throws {
        if request.requiresSuccessfulHTTPStatus && !(200...299).contains(statusCode) {
            throw PluginManifestValidationError.unsuccessfulHTTPStatus(statusCode)
        }
        guard finalURL.absoluteString == request.url.absoluteString else {
            throw PluginManifestValidationError.redirectedResource(
                expected: request.url.absoluteString,
                actual: finalURL.absoluteString
            )
        }
        if let data {
            let minimum = request.minimumByteCount ?? 0
            let maximum = request.maximumByteCount ?? Int.max
            guard data.count >= minimum, data.count <= maximum else {
                throw request.kind == .worker
                    ? PluginManifestValidationError.workerByteCountOutOfRange(data.count)
                    : PluginManifestValidationError.manifestByteCountOutOfRange(data.count)
            }
        }
        guard request.kind == .worker else { return }
        guard let data else {
            throw PluginManifestValidationError.missingWorkerData
        }
        guard request.expectedIntegrity?.matches(data) == true else {
            throw PluginManifestValidationError.workerIntegrityMismatch
        }
    }

    /// Installed/local workers do not require SRI, but retain the same 512 KiB
    /// ceiling enforced when Electron reads their source. Empty local files are allowed.
    public static func validateInstalledWorkerData(_ data: Data) throws {
        guard data.count <= maximumWorkerByteCount else {
            throw PluginManifestValidationError.workerByteCountOutOfRange(data.count)
        }
    }

    /// Applies the worker registration message bounds used by ExtensionHost.
    /// This remains declarative: no handler or JavaScript callback is accepted.
    public static func sanitizeRegisteredCommand(
        id: String,
        title: String
    ) -> PluginCommandContribution? {
        let id = truncate(id, maximumUTF16CodeUnits: maximumCommandIDUTF16Count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = truncate(title, maximumUTF16CodeUnits: maximumCommandTitleUTF16Count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !title.isEmpty, isSafeCommandID(id) else { return nil }
        return PluginCommandContribution(id: id, title: title, insertText: nil)
    }

    private static func isSafeCommandID(_ id: String) -> Bool {
        id.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte) || byte == 0x2D
                || byte == 0x2E || byte == 0x5F
        }
    }

    public static func sanitizeWorkerNotification(_ text: String) -> String {
        truncate(text, maximumUTF16CodeUnits: 500)
    }

    private static func sanitizeCommands(_ value: Any?) -> [PluginCommandContribution] {
        guard let values = value as? [Any] else { return [] }
        var result: [PluginCommandContribution] = []
        for value in values {
            guard let raw = value as? [String: Any],
                  let id = raw["id"] as? String,
                  let title = raw["title"] as? String else {
                continue
            }
            result.append(PluginCommandContribution(
                id: truncate(id, maximumUTF16CodeUnits: maximumCommandIDUTF16Count),
                title: truncate(title, maximumUTF16CodeUnits: maximumCommandTitleUTF16Count),
                insertText: (raw["insertText"] as? String).map {
                    truncate($0, maximumUTF16CodeUnits: maximumInsertionUTF16Count)
                }
            ))
            if result.count == maximumCommands { break }
        }
        return result
    }

    private static func sanitizeSnippets(_ value: Any?) -> [PluginSnippetContribution] {
        guard let values = value as? [Any] else { return [] }
        var result: [PluginSnippetContribution] = []
        for value in values {
            guard let raw = value as? [String: Any],
                  let label = raw["label"] as? String,
                  let text = raw["text"] as? String else {
                continue
            }
            let rawTrigger = raw["trigger"] as? String
            result.append(PluginSnippetContribution(
                label: truncate(label, maximumUTF16CodeUnits: maximumSnippetLabelUTF16Count),
                text: truncate(text, maximumUTF16CodeUnits: maximumSnippetTextUTF16Count),
                trigger: rawTrigger.flatMap { isValidSnippetTrigger($0) ? $0 : nil },
                scope: (raw["scope"] as? String).map {
                    truncate($0, maximumUTF16CodeUnits: maximumSnippetScopeUTF16Count)
                }
            ))
            if result.count == maximumSnippets { break }
        }
        return result
    }

    private static func sanitizeExtension(_ value: Any?) -> PluginExtensionManifest? {
        guard let raw = value as? [String: Any],
              let worker = raw["worker"] as? String,
              isSafeRelativeWorkerPath(worker) else {
            return nil
        }
        let permissions = (raw["permissions"] as? [Any] ?? []).compactMap { value in
            (value as? String).flatMap(PluginPermission.init(rawValue:))
        }
        let workerURL = (raw["workerUrl"] as? String).flatMap(absoluteHTTPSURL)
        let integrity = (raw["workerIntegrity"] as? String).flatMap(SHA256Integrity.init(rawValue:))
        return PluginExtensionManifest(
            worker: worker,
            permissions: permissions,
            workerURL: workerURL,
            workerIntegrity: integrity
        )
    }

    private static func isValidSnippetTrigger(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maximumSnippetTriggerASCIIByteCount else {
            return false
        }
        return scalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func isSafeRelativeWorkerPath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("..") else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "/"
                || scalar == "-"
        }
    }

    private static func absoluteHTTPSURL(_ value: String) -> URL? {
        // Match the Electron declaration boundary's lowercase HTTPS prefix, then
        // additionally require a parseable absolute URL with a host.
        guard value.hasPrefix("https://"), !value.unicodeScalars.contains(where: { scalar in
            scalar.value <= 0x20 || scalar.value == 0x7f
        }),
              let url = URL(string: value),
              isAbsoluteHTTPSURL(url) else {
            return nil
        }
        return url
    }

    private static func isAbsoluteHTTPSURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && !(url.host ?? "").isEmpty
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
    }

    private static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        guard let leftScheme = left.scheme?.lowercased(),
              let rightScheme = right.scheme?.lowercased(),
              let leftHost = left.host?.lowercased(),
              let rightHost = right.host?.lowercased() else {
            return false
        }
        func effectivePort(_ url: URL, scheme: String) -> Int? {
            if let port = url.port { return port }
            return scheme == "https" ? 443 : nil
        }
        return leftScheme == rightScheme
            && leftHost == rightHost
            && effectivePort(left, scheme: leftScheme) == effectivePort(right, scheme: rightScheme)
    }

    private static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type == "c" || type == "B" else { return nil }
        return number.boolValue
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
    }

    /// JavaScript's String.slice bounds strings in UTF-16 code units. Swift
    /// repairs a split surrogate to U+FFFD instead of retaining invalid Unicode.
    private static func truncate(_ value: String, maximumUTF16CodeUnits: Int) -> String {
        guard value.utf16.count > maximumUTF16CodeUnits else { return value }
        return String(
            decoding: Array(value.utf16.prefix(maximumUTF16CodeUnits)),
            as: UTF16.self
        )
    }
}

/// Focused parser facade for call sites that should not need the rest of the
/// marketplace policy namespace.
public enum PluginManifestParser {
    public static func parse(_ data: Data) throws -> PluginManifest {
        try PluginManifestSecurity.parseManifest(data)
    }

    public static func sanitize(_ value: Any) -> PluginManifest? {
        PluginManifestSecurity.sanitizeManifest(value)
    }
}

/// Focused parser facade for marketplace index responses.
public enum MarketplaceItemParser {
    public static func parseCatalog(_ data: Data) throws -> [MarketplaceItem] {
        try PluginManifestSecurity.parseMarketplaceCatalog(data)
    }

    public static func sanitize(_ value: Any) -> MarketplaceItem? {
        PluginManifestSecurity.sanitizeMarketplaceItem(value)
    }
}
