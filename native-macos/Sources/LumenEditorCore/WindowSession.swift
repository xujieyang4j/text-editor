import Foundation

/// A directed selection expressed in UTF-16 offsets. This type deliberately
/// belongs to the session schema instead of sharing editor-transaction types.
public struct WindowSessionSelection: Codable, Equatable, Sendable {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }
}

/// The serialisable view state for one document in one editor group.
public struct WindowSessionViewState: Codable, Equatable, Sendable {
    public var group: Int
    public var selections: [WindowSessionSelection]
    public var mainIndex: Int
    public var scrollX: Int
    public var scrollY: Int

    public init(
        group: Int,
        selections: [WindowSessionSelection],
        mainIndex: Int,
        scrollX: Int,
        scrollY: Int
    ) {
        self.group = group
        self.selections = selections
        self.mainIndex = mainIndex
        self.scrollX = scrollX
        self.scrollY = scrollY
    }

    /// Electron calls these values `scrollLeft` and `scrollTop`. Keep aliases
    /// so adapters can use either vocabulary without another persisted DTO.
    public var scrollLeft: Int {
        get { scrollX }
        set { scrollX = newValue }
    }

    public var scrollTop: Int {
        get { scrollY }
        set { scrollY = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case group
        case selections
        case mainIndex
        case scrollX
        case scrollY
        case scrollLeft
        case scrollTop
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        group = try values.decode(Int.self, forKey: .group)
        selections = try values.decode([WindowSessionSelection].self, forKey: .selections)
        mainIndex = try values.decode(Int.self, forKey: .mainIndex)
        if let decoded = try values.decodeIfPresent(Int.self, forKey: .scrollX) {
            scrollX = decoded
        } else {
            scrollX = try values.decode(Int.self, forKey: .scrollLeft)
        }
        if let decoded = try values.decodeIfPresent(Int.self, forKey: .scrollY) {
            scrollY = decoded
        } else {
            scrollY = try values.decode(Int.self, forKey: .scrollTop)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(group, forKey: .group)
        try values.encode(selections, forKey: .selections)
        try values.encode(mainIndex, forKey: .mainIndex)
        try values.encode(scrollX, forKey: .scrollLeft)
        try values.encode(scrollY, forKey: .scrollTop)
    }
}

/// One open document. Draft text is intentionally sparse: clean disk-backed
/// files carry no text, while dirty text uses `draft` and format-only state can
/// use `recoveryContent` if the source disappears before the next launch.
public struct WindowSessionDocument: Codable, Equatable, Sendable {
    public var documentID: String
    public var path: String?
    public var name: String
    public var pinned: Bool
    public var language: String
    public var languageLocked: Bool
    public var draft: String?
    public var recoveryContent: String?
    public var formatDirty: Bool
    public var baseRevision: String?
    public var encoding: TextEncoding?
    public var diskEncoding: TextEncoding?
    public var encodingLocked: Bool
    public var encodingIssue: EncodingIssue?
    public var eol: LineEnding?
    public var eolOverride: LineEnding?
    public var bookmarks: [Int]
    public var views: [WindowSessionViewState]

    public init(
        documentID: String,
        path: String?,
        name: String,
        pinned: Bool = false,
        language: String = "Plain Text",
        languageLocked: Bool = false,
        draft: String? = nil,
        recoveryContent: String? = nil,
        formatDirty: Bool = false,
        baseRevision: String? = nil,
        encoding: TextEncoding? = nil,
        diskEncoding: TextEncoding? = nil,
        encodingLocked: Bool = false,
        encodingIssue: EncodingIssue? = nil,
        eol: LineEnding? = nil,
        eolOverride: LineEnding? = nil,
        bookmarks: [Int] = [],
        views: [WindowSessionViewState] = []
    ) {
        self.documentID = documentID
        self.path = path
        self.name = name
        self.pinned = pinned
        self.language = language
        self.languageLocked = languageLocked
        self.draft = draft
        self.recoveryContent = recoveryContent
        self.formatDirty = formatDirty
        self.baseRevision = baseRevision
        self.encoding = encoding
        self.diskEncoding = diskEncoding
        self.encodingLocked = encodingLocked
        self.encodingIssue = encodingIssue
        self.eol = eol
        self.eolOverride = eolOverride
        self.bookmarks = bookmarks
        self.views = views
    }

    private enum CodingKeys: String, CodingKey {
        case documentID
        case path
        case name
        case pinned
        case language
        case languageLocked
        case draft
        case recoveryContent
        case formatDirty
        case baseRevision
        case encoding
        case diskEncoding
        case encodingLocked
        case encodingIssue
        case eol
        case eolOverride
        case bookmarks
        case views
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try values.decode(String.self, forKey: .documentID)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        name = try values.decode(String.self, forKey: .name)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "Plain Text"
        languageLocked = try values.decodeIfPresent(Bool.self, forKey: .languageLocked) ?? false
        draft = try values.decodeIfPresent(String.self, forKey: .draft)
        recoveryContent = try values.decodeIfPresent(String.self, forKey: .recoveryContent)
        formatDirty = try values.decodeIfPresent(Bool.self, forKey: .formatDirty) ?? false
        baseRevision = try values.decodeIfPresent(String.self, forKey: .baseRevision)
        encoding = try values.decodeIfPresent(TextEncoding.self, forKey: .encoding)
        diskEncoding = try values.decodeIfPresent(TextEncoding.self, forKey: .diskEncoding)
        encodingLocked = try values.decodeIfPresent(Bool.self, forKey: .encodingLocked) ?? false
        encodingIssue = try values.decodeIfPresent(EncodingIssue.self, forKey: .encodingIssue)
        eol = try values.decodeIfPresent(LineEnding.self, forKey: .eol)
        eolOverride = try values.decodeIfPresent(LineEnding.self, forKey: .eolOverride)
        bookmarks = try values.decodeIfPresent([Int].self, forKey: .bookmarks) ?? []
        views = try values.decodeIfPresent([WindowSessionViewState].self, forKey: .views) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(path, forKey: .path)
        try values.encode(name, forKey: .name)
        if pinned { try values.encode(true, forKey: .pinned) }
        try values.encode(language, forKey: .language)
        try values.encode(languageLocked, forKey: .languageLocked)
        try values.encodeIfPresent(draft, forKey: .draft)
        try values.encodeIfPresent(recoveryContent, forKey: .recoveryContent)
        try values.encode(formatDirty, forKey: .formatDirty)
        if draft != nil || formatDirty {
            // A JSON null records a known no-revision recovery baseline; an
            // omitted key is reserved for documents without recovery intent.
            try values.encode(baseRevision, forKey: .baseRevision)
        } else {
            try values.encodeIfPresent(baseRevision, forKey: .baseRevision)
        }
        try values.encodeIfPresent(encoding, forKey: .encoding)
        try values.encodeIfPresent(diskEncoding, forKey: .diskEncoding)
        if encodingLocked { try values.encode(true, forKey: .encodingLocked) }
        try values.encodeIfPresent(encodingIssue, forKey: .encodingIssue)
        try values.encodeIfPresent(eol, forKey: .eol)
        try values.encodeIfPresent(eolOverride, forKey: .eolOverride)
        if !bookmarks.isEmpty { try values.encode(bookmarks, forKey: .bookmarks) }
        if !views.isEmpty { try values.encode(views, forKey: .views) }
    }
}

public enum WindowSessionLayoutKind: String, CaseIterable, Codable, Equatable, Sendable {
    case single
    case columns2
    case columns3
    case grid4

    public var groupCount: Int {
        switch self {
        case .single: 1
        case .columns2: 2
        case .columns3: 3
        case .grid4: 4
        }
    }
}

/// Ordered tabs and the active tab for one pane. A document may appear in
/// multiple groups, but never more than once within the same group.
public struct WindowSessionGroup: Codable, Equatable, Sendable {
    public var docIDs: [String]
    public var activeDocumentID: String?

    public init(documentIDs: [String] = [], activeDocumentID: String? = nil) {
        self.docIDs = documentIDs
        self.activeDocumentID = activeDocumentID ?? documentIDs.first
    }

    public init(docIDs: [String], activeDocumentID: String? = nil) {
        self.init(documentIDs: docIDs, activeDocumentID: activeDocumentID)
    }

    public var documentIDs: [String] {
        get { docIDs }
        set { docIDs = newValue }
    }
}

public struct WindowSessionLayout: Codable, Equatable, Sendable {
    public var kind: WindowSessionLayoutKind
    public var activeGroup: Int
    public var groups: [WindowSessionGroup]

    public init(
        kind: WindowSessionLayoutKind,
        activeGroup: Int,
        groups: [WindowSessionGroup]
    ) {
        self.kind = kind
        self.activeGroup = activeGroup
        self.groups = groups
    }

    public static func single(
        documentIDs: [String] = [],
        activeDocumentID: String? = nil
    ) -> WindowSessionLayout {
        WindowSessionLayout(
            kind: .single,
            activeGroup: 0,
            groups: [WindowSessionGroup(
                documentIDs: documentIDs,
                activeDocumentID: activeDocumentID
            )]
        )
    }
}

/// A JSON-only project payload. Restricting values to these cases prevents
/// arbitrary Foundation objects from entering a session snapshot.
public indirect enum WindowSessionJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WindowSessionJSONValue])
    case object([String: WindowSessionJSONValue])

    private static let maximumDecodingDepth = 64

    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= Self.maximumDecodingDepth else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Project JSON nesting exceeds the hard decoding limit."
            ))
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let decoded = try? value.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? value.decode(Double.self) {
            self = .number(decoded)
        } else if let decoded = try? value.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? value.decode([WindowSessionJSONValue].self) {
            self = .array(decoded)
        } else if let decoded = try? value.decode([String: WindowSessionJSONValue].self) {
            self = .object(decoded)
        } else {
            throw DecodingError.dataCorruptedError(
                in: value,
                debugDescription: "Project settings must contain JSON values only."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.validateFiniteNumbers(self, codingPath: encoder.codingPath)
        var value = encoder.singleValueContainer()
        switch self {
        case .null:
            try value.encodeNil()
        case let .bool(decoded):
            try value.encode(decoded)
        case let .number(decoded):
            try value.encode(decoded)
        case let .string(decoded):
            try value.encode(decoded)
        case let .array(decoded):
            try value.encode(decoded)
        case let .object(decoded):
            try value.encode(decoded)
        }
    }

    private static func validateFiniteNumbers(
        _ value: WindowSessionJSONValue,
        codingPath: [any CodingKey]
    ) throws {
        switch value {
        case let .number(number) where !number.isFinite:
            throw EncodingError.invalidValue(number, .init(
                codingPath: codingPath,
                debugDescription: "Project settings cannot encode a non-finite number."
            ))
        case let .array(values):
            for child in values {
                try validateFiniteNumbers(child, codingPath: codingPath)
            }
        case let .object(values):
            for child in values.values {
                try validateFiniteNumbers(child, codingPath: codingPath)
            }
        default:
            break
        }
    }
}

/// Project settings remain deliberately opaque to Core, but their root must
/// be a JSON object and validation applies strict depth, node and byte budgets.
public struct WindowSessionProject: Codable, Equatable, Sendable {
    public var values: [String: WindowSessionJSONValue]

    public init(_ values: [String: WindowSessionJSONValue] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        values = try [String: WindowSessionJSONValue](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }
}

public struct WindowSessionLimits: Equatable, Sendable {
    public static let defaultMaximumTabs = 100
    public static let defaultMaximumDraftBytes = 200 * 1_024 * 1_024
    public static let defaultMaximumSnapshotBytes = 208 * 1_024 * 1_024
    public static let `default` = WindowSessionLimits()

    public var maximumTabs: Int
    public var maximumRecoveryBytes: Int
    public var maximumSnapshotBytes: Int
    public var maximumFolders: Int
    public var maximumProjectDepth: Int
    public var maximumProjectNodes: Int
    public var maximumProjectBytes: Int

    public var maximumDocuments: Int { maximumTabs }
    public var maximumDraftBytes: Int { maximumRecoveryBytes }

    public init(
        maximumTabs: Int = WindowSessionLimits.defaultMaximumTabs,
        maximumRecoveryBytes: Int = WindowSessionLimits.defaultMaximumDraftBytes,
        maximumSnapshotBytes: Int = WindowSessionLimits.defaultMaximumSnapshotBytes,
        maximumFolders: Int = 20,
        maximumProjectDepth: Int = 32,
        maximumProjectNodes: Int = 50_000,
        maximumProjectBytes: Int = 8 * 1_024 * 1_024
    ) {
        precondition(maximumTabs >= 0)
        precondition(maximumRecoveryBytes >= 0)
        precondition(maximumSnapshotBytes >= 0)
        precondition(maximumFolders >= 0)
        precondition(maximumProjectDepth >= 0)
        precondition(maximumProjectNodes >= 1)
        precondition(maximumProjectBytes >= 0)
        self.maximumTabs = maximumTabs
        self.maximumRecoveryBytes = maximumRecoveryBytes
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.maximumFolders = maximumFolders
        self.maximumProjectDepth = maximumProjectDepth
        self.maximumProjectNodes = maximumProjectNodes
        self.maximumProjectBytes = maximumProjectBytes
    }
}

public enum WindowSessionValidationError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case tooManyTabs(actual: Int, maximum: Int)
    case recoveryDataTooLarge(actualBytes: Int, maximumBytes: Int)
    case snapshotTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidDocumentID(String)
    case duplicateDocumentID(String)
    case invalidDocument(String)
    case invalidActiveDocumentID(String)
    case invalidLegacyActiveTabIndex(Int)
    case invalidFolder(String)
    case tooManyFolders(actual: Int, maximum: Int)
    case invalidLayout
    case invalidView(documentID: String, group: Int)
    case invalidBookmark(documentID: String, line: Int)
    case projectTooDeep(actual: Int, maximum: Int)
    case projectTooComplex(actualNodes: Int, maximumNodes: Int)
    case projectTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidProjectNumber
}

extension WindowSessionValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(version):
            "Session format version \(version) is not supported."
        case let .tooManyTabs(actual, maximum):
            "A session contains \(actual) tabs; the maximum is \(maximum)."
        case let .recoveryDataTooLarge(actual, maximum):
            "Session recovery text uses \(actual) bytes; the maximum is \(maximum)."
        case let .snapshotTooLarge(actual, maximum):
            "The session snapshot uses \(actual) bytes; the maximum is \(maximum)."
        case let .invalidDocumentID(id):
            "The session contains an invalid document ID: \(id)."
        case let .duplicateDocumentID(id):
            "The session contains the document ID more than once: \(id)."
        case let .invalidDocument(id):
            "The session contains invalid document metadata for \(id)."
        case let .invalidActiveDocumentID(id):
            "The session refers to an unavailable active document: \(id)."
        case let .invalidLegacyActiveTabIndex(index):
            "The version-1 session contains invalid active tab index \(index)."
        case let .invalidFolder(folder):
            "The session contains an invalid workspace folder: \(folder)."
        case let .tooManyFolders(actual, maximum):
            "A session contains \(actual) folders; the maximum is \(maximum)."
        case .invalidLayout:
            "The session contains an invalid editor-group layout."
        case let .invalidView(documentID, group):
            "The session contains invalid view state for \(documentID) in group \(group)."
        case let .invalidBookmark(documentID, line):
            "The session contains invalid bookmark line \(line) for \(documentID)."
        case let .projectTooDeep(actual, maximum):
            "Project settings have nesting depth \(actual); the maximum is \(maximum)."
        case let .projectTooComplex(actual, maximum):
            "Project settings contain \(actual) values; the maximum is \(maximum)."
        case let .projectTooLarge(actual, maximum):
            "Project settings use \(actual) bytes; the maximum is \(maximum)."
        case .invalidProjectNumber:
            "Project settings contain a non-finite number."
        }
    }
}

/// A complete, independently persistable native window snapshot.
public struct WindowSession: Codable, Equatable, Sendable {
    public typealias Limits = WindowSessionLimits
    public typealias ValidationError = WindowSessionValidationError

    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var documents: [WindowSessionDocument]
    public var activeDocumentID: String?
    public var folder: String?
    public var folders: [String]
    public var project: WindowSessionProject?
    public var layout: WindowSessionLayout

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case documents
        case openFiles
        case activeDocumentID
        case activeIndex
        case folder
        case folders
        case project
        case layout
    }

    public init(
        formatVersion: Int = WindowSession.currentFormatVersion,
        documents: [WindowSessionDocument] = [],
        activeDocumentID: String? = nil,
        folder: String? = nil,
        folders: [String] = [],
        project: WindowSessionProject? = nil,
        layout: WindowSessionLayout? = nil
    ) {
        let layoutActiveDocumentID = layout.flatMap { candidate in
            candidate.groups.indices.contains(candidate.activeGroup)
                ? candidate.groups[candidate.activeGroup].activeDocumentID
                : nil
        }
        let resolvedActiveDocumentID = activeDocumentID
            ?? layoutActiveDocumentID
            ?? documents.first?.documentID
        self.formatVersion = formatVersion
        self.documents = documents
        self.activeDocumentID = resolvedActiveDocumentID
        self.folder = folder
        self.folders = folders
        self.project = project
        self.layout = layout ?? .single(
            documentIDs: documents.map(\.documentID),
            activeDocumentID: resolvedActiveDocumentID
        )
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        if let decoded = try values.decodeIfPresent(
            [WindowSessionDocument].self,
            forKey: .documents
        ) {
            documents = decoded
        } else {
            documents = try values.decode(
                [WindowSessionDocument].self,
                forKey: .openFiles
            )
        }
        if let decoded = try values.decodeIfPresent(String.self, forKey: .activeDocumentID) {
            activeDocumentID = decoded
        } else if let index = try values.decodeIfPresent(Int.self, forKey: .activeIndex),
                  documents.indices.contains(index) {
            activeDocumentID = documents[index].documentID
        } else {
            activeDocumentID = nil
        }
        folder = try values.decodeIfPresent(String.self, forKey: .folder)
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? []
        project = try values.decodeIfPresent(WindowSessionProject.self, forKey: .project)
        layout = try values.decodeIfPresent(WindowSessionLayout.self, forKey: .layout)
            ?? .single(documentIDs: documents.map(\.documentID),
                       activeDocumentID: activeDocumentID)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(formatVersion, forKey: .formatVersion)
        try values.encode(documents, forKey: .documents)
        try values.encodeIfPresent(activeDocumentID, forKey: .activeDocumentID)
        try values.encode(folder, forKey: .folder)
        try values.encode(folders, forKey: .folders)
        try values.encodeIfPresent(project, forKey: .project)
        try values.encode(layout, forKey: .layout)
    }

    public static var empty: WindowSession { WindowSession() }

    /// Validates all referential and resource bounds, including the encoded
    /// 208 MiB snapshot ceiling. No files or application state are touched.
    public func validate(limits: Limits = .default) throws {
        _ = try encodedData(limits: limits)
    }

    /// Encodes only after semantic validation, then applies the final snapshot
    /// budget. Callers can atomically persist the returned bytes.
    public func encodedData(
        using encoder: JSONEncoder? = nil,
        limits: Limits = .default
    ) throws -> Data {
        try validateStructure(limits: limits)
        let encoder = encoder ?? JSONEncoder()
        let data = try encoder.encode(self)
        guard data.count <= limits.maximumSnapshotBytes else {
            throw ValidationError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: limits.maximumSnapshotBytes
            )
        }
        return data
    }

    /// Compatibility aliases for code translating the Electron Session DTO.
    public var openFiles: [WindowSessionDocument] {
        get { documents }
        set { documents = newValue }
    }

    public var activeIndex: Int {
        get {
            guard let activeDocumentID,
                  let index = documents.firstIndex(where: {
                      $0.documentID == activeDocumentID
                  }) else { return 0 }
            return index
        }
        set {
            activeDocumentID = documents.indices.contains(newValue)
                ? documents[newValue].documentID
                : nil
        }
    }

    /// Checks the byte ceiling before decoding, then validates the decoded
    /// graph. This is the safe entry point for untrusted on-disk snapshots.
    public static func decodeValidated(
        from data: Data,
        using decoder: JSONDecoder? = nil,
        limits: Limits = .default
    ) throws -> WindowSession {
        guard data.count <= limits.maximumSnapshotBytes else {
            throw ValidationError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: limits.maximumSnapshotBytes
            )
        }
        let decoder = decoder ?? JSONDecoder()
        let version = try decoder.decode(VersionEnvelope.self, from: data).formatVersion
        guard version == currentFormatVersion else {
            throw ValidationError.unsupportedFormatVersion(version)
        }
        try preflightProject(in: data, limits: limits)
        let session = try decoder.decode(WindowSession.self, from: data)
        try session.validateStructure(limits: limits)
        return session
    }

    /// Decodes V2 directly or migrates a version-1 `EditorSession` without
    /// touching disk. It is suitable for a future store's version dispatch.
    public static func decodeMigratingLegacy(
        from data: Data,
        using decoder: JSONDecoder? = nil,
        limits: Limits = .default
    ) throws -> WindowSession {
        guard data.count <= limits.maximumSnapshotBytes else {
            throw ValidationError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: limits.maximumSnapshotBytes
            )
        }
        let decoder = decoder ?? JSONDecoder()
        let version = try decoder.decode(VersionEnvelope.self, from: data).formatVersion
        switch version {
        case currentFormatVersion:
            return try decodeValidated(from: data, using: decoder, limits: limits)
        case EditorSession.currentFormatVersion:
            return try migrate(
                from: decoder.decode(EditorSession.self, from: data),
                limits: limits
            )
        default:
            throw ValidationError.unsupportedFormatVersion(version)
        }
    }

    public static func decodeOrMigrate(
        from data: Data,
        using decoder: JSONDecoder? = nil,
        limits: Limits = .default
    ) throws -> WindowSession {
        try decodeMigratingLegacy(from: data, using: decoder, limits: limits)
    }

    /// Pure, deterministic migration from the native version-1 snapshot.
    /// Clean disk files shed their duplicated text; dirty and recovery-critical
    /// text is retained in the corresponding sparse V2 fields.
    public static func migrate(
        from legacy: EditorSession,
        limits: Limits = .default
    ) throws -> WindowSession {
        guard legacy.formatVersion == EditorSession.currentFormatVersion else {
            throw ValidationError.unsupportedFormatVersion(legacy.formatVersion)
        }
        if let active = legacy.activeTabIndex, !legacy.tabs.indices.contains(active) {
            throw ValidationError.invalidLegacyActiveTabIndex(active)
        }

        let documents = legacy.tabs.enumerated().map { index, tab in
            migrate(tab: tab, documentID: "legacy-document-\(index)")
        }
        let activeDocumentID = legacy.activeTabIndex.map { documents[$0].documentID }
            ?? documents.first?.documentID
        let migrated = WindowSession(
            documents: documents,
            activeDocumentID: activeDocumentID,
            layout: .single(
                documentIDs: documents.map(\.documentID),
                activeDocumentID: activeDocumentID
            )
        )
        try migrated.validate(limits: limits)
        return migrated
    }

    public static func migrated(
        from legacy: EditorSession,
        limits: Limits = .default
    ) throws -> WindowSession {
        try migrate(from: legacy, limits: limits)
    }

    public init(
        migrating legacy: EditorSession,
        limits: Limits = .default
    ) throws {
        self = try Self.migrate(from: legacy, limits: limits)
    }

    private static func migrate(
        tab: SessionTab,
        documentID: String
    ) -> WindowSessionDocument {
        let savedEncoding = tab.savedEncoding ?? tab.encoding
        let savedEOL = tab.savedEOL ?? tab.eol
        let contentDirty = tab.content != tab.savedContent
        let formatDirty = tab.encoding != savedEncoding || tab.eol != savedEOL
        let keepDraft = contentDirty
            || tab.requiresSave == true
            || (tab.path == nil && !tab.content.isEmpty)
        let hasRecoveryIntent = keepDraft || formatDirty
        let baseRevision = hasRecoveryIntent && isValidRevision(tab.revision)
            ? tab.revision
            : nil

        return WindowSessionDocument(
            documentID: documentID,
            path: tab.path,
            name: tab.name,
            language: "Plain Text",
            languageLocked: false,
            draft: keepDraft ? tab.content : nil,
            recoveryContent: formatDirty && !keepDraft && tab.path != nil
                ? tab.content
                : nil,
            formatDirty: formatDirty,
            baseRevision: baseRevision,
            encoding: tab.encoding,
            diskEncoding: savedEncoding,
            encodingLocked: tab.encodingLocked ?? savedEncoding.needsExplicitRead,
            encodingIssue: tab.encodingIssue,
            eol: tab.eol,
            eolOverride: tab.eol != savedEOL ? tab.eol : nil,
            views: [WindowSessionViewState(
                group: 0,
                selections: [WindowSessionSelection(
                    anchor: tab.selection.anchor,
                    head: tab.selection.head
                )],
                mainIndex: 0,
                scrollX: 0,
                scrollY: 0
            )]
        )
    }

    private func validateStructure(limits: Limits) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ValidationError.unsupportedFormatVersion(formatVersion)
        }
        guard documents.count <= limits.maximumTabs else {
            throw ValidationError.tooManyTabs(
                actual: documents.count,
                maximum: limits.maximumTabs
            )
        }

        var documentIDs = Set<String>()
        var recoveryBytes = 0
        for document in documents {
            guard !document.documentID.isEmpty,
                  document.documentID.lengthOfBytes(using: .utf8) <= 255 else {
                throw ValidationError.invalidDocumentID(document.documentID)
            }
            guard documentIDs.insert(document.documentID).inserted else {
                throw ValidationError.duplicateDocumentID(document.documentID)
            }
            if let path = document.path, !(path as NSString).isAbsolutePath {
                throw ValidationError.invalidDocument(document.documentID)
            }
            guard document.name.utf16.count <= 255,
                  document.language.utf16.count <= 100,
                  !document.encodingLocked || document.diskEncoding != nil,
                  document.bookmarks.count <= 10_000 else {
                throw ValidationError.invalidDocument(document.documentID)
            }
            let validRecoveryFallback = document.recoveryContent == nil
                || (document.path != nil && document.draft == nil && document.formatDirty)
            let hasFormatOnlyFallback = !document.formatDirty
                || document.draft != nil
                || document.path == nil
                || document.recoveryContent != nil
            let validBaseRevision = document.baseRevision == nil
                || Self.isValidRevision(document.baseRevision)
            let formatDifferenceRequiresIntent = document.draft != nil
                || document.formatDirty
                || (document.encoding == document.diskEncoding
                    && document.eolOverride == nil)
            guard validRecoveryFallback,
                  hasFormatOnlyFallback,
                  validBaseRevision,
                  formatDifferenceRequiresIntent else {
                throw ValidationError.invalidDocument(document.documentID)
            }
            for line in document.bookmarks where line < 1 || line > 10_000_000 {
                throw ValidationError.invalidBookmark(
                    documentID: document.documentID,
                    line: line
                )
            }
            for text in [document.draft, document.recoveryContent].compactMap({ $0 }) {
                let bytes = text.lengthOfBytes(using: .utf8)
                let sum = recoveryBytes.addingReportingOverflow(bytes)
                let actual = sum.overflow ? Int.max : sum.partialValue
                guard !sum.overflow, actual <= limits.maximumRecoveryBytes else {
                    throw ValidationError.recoveryDataTooLarge(
                        actualBytes: actual,
                        maximumBytes: limits.maximumRecoveryBytes
                    )
                }
                recoveryBytes = actual
            }
        }

        try validateLayoutGroups(documentIDs: documentIDs)
        if let activeDocumentID, !documentIDs.contains(activeDocumentID) {
            throw ValidationError.invalidActiveDocumentID(activeDocumentID)
        }
        if let folder, !(folder as NSString).isAbsolutePath {
            throw ValidationError.invalidFolder(folder)
        }
        guard folders.count <= limits.maximumFolders else {
            throw ValidationError.tooManyFolders(
                actual: folders.count,
                maximum: limits.maximumFolders
            )
        }
        var uniqueFolders = Set<String>()
        for item in folders {
            guard (item as NSString).isAbsolutePath, uniqueFolders.insert(item).inserted else {
                throw ValidationError.invalidFolder(item)
            }
        }
        if let folder, !folders.isEmpty, !uniqueFolders.contains(folder) {
            throw ValidationError.invalidFolder(folder)
        }

        try validateLayoutActiveDocument()
        try validateViews()
        if let project {
            try validate(project: project, limits: limits)
        }
    }

    private static func preflightProject(
        in data: Data,
        limits: Limits
    ) throws {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any], let project = object["project"] else {
            return
        }
        if project is NSNull { return }
        guard project is [String: Any] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Project settings must be a JSON object."
            ))
        }
        let projectData = try JSONSerialization.data(withJSONObject: project)
        guard projectData.count <= limits.maximumProjectBytes else {
            throw ValidationError.projectTooLarge(
                actualBytes: projectData.count,
                maximumBytes: limits.maximumProjectBytes
            )
        }

        var nodes = 1
        var stack: [(Any, Int)] = [(project, 0)]
        while let (value, depth) = stack.popLast() {
            guard depth <= limits.maximumProjectDepth else {
                throw ValidationError.projectTooDeep(
                    actual: depth,
                    maximum: limits.maximumProjectDepth
                )
            }
            if depth > 0 {
                let incremented = nodes.addingReportingOverflow(1)
                nodes = incremented.overflow ? Int.max : incremented.partialValue
                guard !incremented.overflow, nodes <= limits.maximumProjectNodes else {
                    throw ValidationError.projectTooComplex(
                        actualNodes: nodes,
                        maximumNodes: limits.maximumProjectNodes
                    )
                }
            }
            if let array = value as? [Any] {
                stack.append(contentsOf: array.map { ($0, depth + 1) })
            } else if let object = value as? [String: Any] {
                stack.append(contentsOf: object.values.map { ($0, depth + 1) })
            }
        }
    }

    private func validateLayoutGroups(documentIDs: Set<String>) throws {
        guard layout.groups.count == layout.kind.groupCount,
              layout.groups.indices.contains(layout.activeGroup) else {
            throw ValidationError.invalidLayout
        }

        var referenced = Set<String>()
        for group in layout.groups {
            var groupIDs = Set<String>()
            for id in group.documentIDs {
                guard documentIDs.contains(id), groupIDs.insert(id).inserted else {
                    throw ValidationError.invalidLayout
                }
                referenced.insert(id)
            }
            guard group.documentIDs.isEmpty == (group.activeDocumentID == nil) else {
                throw ValidationError.invalidLayout
            }
            if let active = group.activeDocumentID, !groupIDs.contains(active) {
                throw ValidationError.invalidLayout
            }
        }
        guard referenced == documentIDs else {
            throw ValidationError.invalidLayout
        }
    }

    private func validateLayoutActiveDocument() throws {
        guard documents.isEmpty == (activeDocumentID == nil) else {
            throw ValidationError.invalidLayout
        }
        let activeGroup = layout.groups[layout.activeGroup]
        if activeGroup.activeDocumentID != activeDocumentID {
            throw ValidationError.invalidLayout
        }
        if let activeDocumentID, !activeGroup.documentIDs.contains(activeDocumentID) {
            throw ValidationError.invalidLayout
        }
    }

    private func validateViews() throws {
        let maximumOffset = 200_000_000
        let maximumScroll = 100_000_000
        for document in documents {
            var groups = Set<Int>()
            for view in document.views {
                guard view.group >= 0,
                      view.group < layout.kind.groupCount,
                      layout.groups[view.group].documentIDs.contains(document.documentID),
                      groups.insert(view.group).inserted,
                      !view.selections.isEmpty,
                      view.selections.count <= 100,
                      view.selections.indices.contains(view.mainIndex),
                      view.scrollX >= 0, view.scrollX <= maximumScroll,
                      view.scrollY >= 0, view.scrollY <= maximumScroll,
                      view.selections.allSatisfy({ selection in
                          selection.anchor >= 0 && selection.anchor <= maximumOffset
                              && selection.head >= 0 && selection.head <= maximumOffset
                      }) else {
                    throw ValidationError.invalidView(
                        documentID: document.documentID,
                        group: view.group
                    )
                }
            }
        }
    }

    private func validate(project: WindowSessionProject, limits: Limits) throws {
        var nodeCount = 1 // The root object.
        var approximateBytes = 0
        var stack: [(WindowSessionJSONValue, Int)] = []
        for (key, value) in project.values {
            approximateBytes = try Self.addProjectBytes(
                key.lengthOfBytes(using: .utf8),
                to: approximateBytes,
                maximum: limits.maximumProjectBytes
            )
            stack.append((value, 1))
        }

        while let (value, depth) = stack.popLast() {
            guard depth <= limits.maximumProjectDepth else {
                throw ValidationError.projectTooDeep(
                    actual: depth,
                    maximum: limits.maximumProjectDepth
                )
            }
            let incremented = nodeCount.addingReportingOverflow(1)
            nodeCount = incremented.overflow ? Int.max : incremented.partialValue
            guard !incremented.overflow, nodeCount <= limits.maximumProjectNodes else {
                throw ValidationError.projectTooComplex(
                    actualNodes: nodeCount,
                    maximumNodes: limits.maximumProjectNodes
                )
            }

            switch value {
            case .null, .bool(_):
                break
            case let .number(number):
                guard number.isFinite else {
                    throw ValidationError.invalidProjectNumber
                }
            case let .string(string):
                approximateBytes = try Self.addProjectBytes(
                    string.lengthOfBytes(using: .utf8),
                    to: approximateBytes,
                    maximum: limits.maximumProjectBytes
                )
            case let .array(values):
                stack.append(contentsOf: values.map { ($0, depth + 1) })
            case let .object(values):
                for (key, child) in values {
                    approximateBytes = try Self.addProjectBytes(
                        key.lengthOfBytes(using: .utf8),
                        to: approximateBytes,
                        maximum: limits.maximumProjectBytes
                    )
                    stack.append((child, depth + 1))
                }
            }
        }

        let encoded = try JSONEncoder().encode(project)
        guard encoded.count <= limits.maximumProjectBytes else {
            throw ValidationError.projectTooLarge(
                actualBytes: encoded.count,
                maximumBytes: limits.maximumProjectBytes
            )
        }
    }

    private static func addProjectBytes(
        _ bytes: Int,
        to current: Int,
        maximum: Int
    ) throws -> Int {
        let sum = current.addingReportingOverflow(bytes)
        let actual = sum.overflow ? Int.max : sum.partialValue
        guard !sum.overflow, actual <= maximum else {
            throw ValidationError.projectTooLarge(
                actualBytes: actual,
                maximumBytes: maximum
            )
        }
        return actual
    }

    private static func isValidRevision(_ revision: String?) -> Bool {
        guard let revision, revision.hasPrefix("sha256:") else { return false }
        let digest = revision.dropFirst(7)
        guard digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private struct VersionEnvelope: Decodable {
        let formatVersion: Int
    }
}
