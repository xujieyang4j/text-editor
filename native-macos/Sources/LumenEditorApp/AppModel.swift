import Combine
import Foundation
import LumenEditorCore

public enum CloseDecision: Equatable, Sendable {
    case save
    case discard
    case cancel
}

/// The pane-local tab set affected by a bulk close command.
public enum TabCloseScope: Equatable, Sendable {
    case others
    case right
    case all
}

/// One runtime-only entry in the reopen-closed-tab stack. The token lets an
/// asynchronous reopen consume the entry it started with without accidentally
/// popping a newer close that happened while the file was being read.
public struct RecentlyClosedTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let encoding: TextEncoding?

    public init(id: UUID = UUID(), url: URL, encoding: TextEncoding? = nil) {
        self.id = id
        self.url = url
        self.encoding = encoding
    }
}

public struct CloseRequest: Identifiable, Equatable, Sendable {
    public var id: UUID { documentID }
    public let documentID: UUID
    public let displayName: String

    public init(documentID: UUID, displayName: String) {
        self.documentID = documentID
        self.displayName = displayName
    }
}

public struct AppModelIssue: Identifiable, Equatable, Sendable {
    public enum Title: Equatable, Sendable {
        case updateSelection
        case editDocument
        case openFile
        case reopenFile
        case chooseSaveLocation
        case saveFile
        case confirmEncoding
        case saveSession
        case resolveExternalChange
        case saveDestinationChanged
        case binaryFile
        case fileTooLarge
    }

    public enum Message: Equatable, Sendable {
        case app(AppModelAppIssue)
        case editorTransaction(EditorTransactionError, context: String?)
        case textFileCodec(TextFileCodecError, context: String?)
        case sessionStore(SessionStoreError, context: String?)
        case fileWrite(FileWriteFailure, context: String?)
        case fileWriteCommit(FileWriteCommitFailure, context: String?)
        case verbatim(context: String?, message: String)
    }

    public let id: UUID
    public let titleContent: Title
    public let content: Message

    public var title: String {
        EditorLocale.enUS.localizedAppModelIssueTitle(titleContent)
    }
    public var message: String {
        EditorLocale.enUS.localizedAppModelIssue(content)
    }

    public init(id: UUID = UUID(), title: Title, appIssue: AppModelAppIssue) {
        self.id = id
        titleContent = title
        content = .app(appIssue)
    }

    public init(
        id: UUID = UUID(), title: Title, error: any Error, context: String? = nil
    ) {
        self.id = id
        titleContent = title
        if let transactionError = error as? EditorTransactionError {
            content = .editorTransaction(transactionError, context: context)
        } else if let codecError = error as? TextFileCodecError {
            content = .textFileCodec(codecError, context: context)
        } else if let sessionError = error as? SessionStoreError {
            content = .sessionStore(sessionError, context: context)
        } else if let writeError = error as? FileWriteFailure {
            content = .fileWrite(writeError, context: context)
        } else if let commitError = error as? FileWriteCommitFailure {
            content = .fileWriteCommit(commitError, context: context)
        } else {
            content = .verbatim(
                context: context, message: error.localizedDescription
            )
        }
    }
}

public enum AppModelAppIssue: Equatable, Sendable {
    case saveLocationRequired(displayName: String)
    case destinationAlreadyOpen
    case encodingRequiredForLocalVersion
    case destinationMustBeLocal
    case externalChangeMustBeResolved
    case encodingRequiredForSave
    case hardLinkedDestination
    case destinationChanged
    case binaryFile(name: String)
    case fileTooLarge(name: String, maximumMegabytes: Int)
}

/// A typed, non-blocking notice produced by the model layer so that every
/// caller of `reopen` or `checkForExternalChange` — including production
/// watchers, workspace search, and Git discard — gets consistent feedback
/// without needing to know about the UI banner.
public enum EncodingNotice: Identifiable, Equatable, Sendable {
    case invalidBytesAfterOpen(documentID: UUID, encoding: TextEncoding)
    case uncertainEncodingAfterOpen(documentID: UUID, encoding: TextEncoding)
    case reopenSuccess(
        documentID: UUID,
        requestedEncoding: TextEncoding?,
        actualEncoding: TextEncoding,
        displayName: String
    )
    case invalidBytesAfterReopen(
        documentID: UUID, requestedEncoding: TextEncoding?
    )
    case invalidBytesAfterExternalReload(
        documentID: UUID, encoding: TextEncoding
    )

    public var documentID: UUID {
        switch self {
        case let .invalidBytesAfterOpen(documentID, _),
             let .uncertainEncodingAfterOpen(documentID, _),
             let .reopenSuccess(documentID, _, _, _),
             let .invalidBytesAfterReopen(documentID, _),
             let .invalidBytesAfterExternalReload(documentID, _):
            return documentID
        }
    }

    public var id: String {
        let kind: String
        switch self {
        case .invalidBytesAfterOpen: kind = "invalidBytesAfterOpen"
        case .uncertainEncodingAfterOpen: kind = "uncertainEncodingAfterOpen"
        case .reopenSuccess: kind = "reopenSuccess"
        case .invalidBytesAfterReopen: kind = "invalidBytesAfterReopen"
        case .invalidBytesAfterExternalReload: kind = "invalidBytesAfterExternalReload"
        }
        return "\(kind):\(documentID.uuidString)"
    }
}

/// A non-blocking warning for a save whose target bytes are known, but whose
/// durability or temporary-artifact cleanup needs user attention. The typed
/// payload is rendered using the current runtime locale.
public enum FileSaveNotice: Identifiable, Equatable, Sendable {
    case durabilityUnconfirmed(
        documentID: UUID, displayName: String, recoveryArtifact: URL?
    )
    case cleanupIncomplete(
        documentID: UUID, displayName: String, recoveryArtifact: URL?
    )

    public var documentID: UUID {
        switch self {
        case let .durabilityUnconfirmed(documentID, _, _),
             let .cleanupIncomplete(documentID, _, _):
            documentID
        }
    }

    public var id: String {
        switch self {
        case let .durabilityUnconfirmed(documentID, _, artifact):
            "durability:\(documentID.uuidString):\(artifact?.path ?? "none")"
        case let .cleanupIncomplete(documentID, _, artifact):
            "cleanup:\(documentID.uuidString):\(artifact?.path ?? "none")"
        }
    }

    public var recoveryArtifact: URL? {
        switch self {
        case let .durabilityUnconfirmed(_, _, artifact),
             let .cleanupIncomplete(_, _, artifact):
            artifact
        }
    }

    var englishMessage: String {
        switch self {
        case let .durabilityUnconfirmed(_, displayName, artifact):
            let recovery = artifact.map {
                " A complete recovery copy remains at \($0.path)."
            } ?? ""
            return "\(displayName) contains the requested bytes, but macOS could not confirm the directory update on disk. Keep the document open and retry saving.\(recovery)"
        case let .cleanupIncomplete(_, displayName, artifact):
            let recovery = artifact.map {
                " A complete recovery copy remains at \($0.path)."
            } ?? ""
            return "\(displayName) was saved, but a temporary recovery item could not be completely removed.\(recovery)"
        }
    }
}

enum DocumentSaveOutcome: Equatable, Sendable {
    case complete
    case completeWithCleanupWarning(FileSaveNotice)
    case durabilityUnconfirmed(FileSaveNotice)
    case failed

    var didComplete: Bool {
        switch self {
        case .complete, .completeWithCleanupWarning: true
        case .durabilityUnconfirmed, .failed: false
        }
    }

    var reachedDestination: Bool {
        if case .failed = self { return false }
        return true
    }

    var notice: FileSaveNotice? {
        switch self {
        case .complete, .failed: nil
        case let .completeWithCleanupWarning(notice),
             let .durabilityUnconfirmed(notice): notice
        }
    }
}

/// Scroll coordinates are persisted as bounded integer points in the V2
/// session. NativeTextEditor owns conversion to and from CGFloat.
public struct EditorPaneScrollPosition: Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int = 0, y: Int = 0) {
        self.x = min(100_000_000, max(0, x))
        self.y = min(100_000_000, max(0, y))
    }

    public static let zero = EditorPaneScrollPosition()
}

/// Main-window state and the safety-critical document lifecycle.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var documents: [EditorDocument] = []
    @Published public private(set) var selectedDocumentID: EditorDocument.ID?
    @Published public private(set) var paneLayout: PaneLayout
    @Published public private(set) var pendingCloseRequest: CloseRequest?
    @Published private var recentlyClosedTabs: [RecentlyClosedTab] = []
    @Published public private(set) var presentedIssue: AppModelIssue?
    @Published public private(set) var encodingNotice: EncodingNotice?
    @Published public private(set) var fileSaveNotice: FileSaveNotice?
    @Published public private(set) var isRestoringSession = false
    @Published public private(set) var workspaceFolder: String?
    @Published public private(set) var workspaceFolders: [String]
    @Published public private(set) var sessionProject: WindowSessionProject?
    @Published public private(set) var isTextEditingLocked = false
    private enum TextEditingLockOwner: Hashable {
        case termination
        case gitMutation(UUID)
    }
    private var textEditingLockOwners: [TextEditingLockOwner: Int] = [:]
    /// Invalidates async file-open results that started before a global Git or
    /// termination lock. A cancelled lock still advances the generation: its
    /// reviewed document set must not later gain a stale in-flight open.
    private var documentOpenAdmissionGeneration: UInt64 = 0
    struct DocumentOpenAdmission: Equatable {
        fileprivate let generation: UInt64
    }

    public let maximumEditableByteCount: Int64

    private let sessionStore: SessionStore
    private let sessionWillPersist: (() throws -> Void)?
    private let sessionPersistenceDidFail: (() -> Void)?
    private let sessionDidPersist: (() throws -> Void)?
    private let terminationSnapshotWillPersist: ((WindowSession) throws -> Void)?
    private let applicationCloseSnapshotWillPersist: (() throws -> Void)?
    private let applicationCloseSnapshotStager: ((WindowSession) throws -> Void)?
    private let applicationCloseSnapshotCommitter: (() throws -> Void)?
    private let applicationCloseSnapshotAborter: (() -> Void)?
    private let atomicWrite: @Sendable (Data, URL, String?) throws -> FileWriteResult
    /// Optional App-Sandbox bridge. The model retains one lease for every
    /// live file-backed document and asks this callback to restore grants
    /// before reading paths from a hot-exit snapshot.
    var restoreSecurityScopedFileAccess: ((URL) throws -> SecurityScopedResourceLease)?
    var securityScopedFileAccessDidEnd: ((URL) -> Void)?
    var prepareSecurityScopedFileAccessMoves: ((
        [SecurityScopedFileAccessMove]
    ) throws -> PreparedSecurityScopedBookmarkRebase?)?
    var securityScopedFileAccessDidMove: ((URL, URL) throws -> SecurityScopedResourceLease)?
    private var securityScopedDocumentLeases: [EditorDocument.ID: SecurityScopedResourceLease] = [:]
    private var isApplicationCloseCommitted = false
    private var processRequiresSecurityScopedAccess: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
    private var documentSubscriptions: [EditorDocument.ID: AnyCancellable] = [:]
    private var sessionSaveTask: Task<Void, Never>?
    private struct PaneDocumentKey: Hashable {
        let viewID: EditorViewID
        let documentID: String
    }
    private var scrollPositions: [PaneDocumentKey: EditorPaneScrollPosition] = [:]

    public init(
        sessionStore: SessionStore = SessionStore(),
        maximumEditableByteCount: Int64 = TextFileCodec.defaultMaximumByteCount,
        createInitialDocument: Bool = true,
        sessionWillPersist: (() throws -> Void)? = nil,
        sessionPersistenceDidFail: (() -> Void)? = nil,
        sessionDidPersist: (() throws -> Void)? = nil,
        terminationSnapshotWillPersist: ((WindowSession) throws -> Void)? = nil,
        applicationCloseSnapshotWillPersist: (() throws -> Void)? = nil,
        applicationCloseSnapshotStager: ((WindowSession) throws -> Void)? = nil,
        applicationCloseSnapshotCommitter: (() throws -> Void)? = nil,
        applicationCloseSnapshotAborter: (() -> Void)? = nil,
        atomicWrite: @escaping @Sendable (Data, URL, String?) throws -> FileWriteResult = {
            try AtomicFileWriter.write($0, to: $1, expectedRevision: $2)
        }
    ) {
        self.sessionStore = sessionStore
        self.sessionWillPersist = sessionWillPersist
        self.sessionPersistenceDidFail = sessionPersistenceDidFail
        self.sessionDidPersist = sessionDidPersist
        self.terminationSnapshotWillPersist = terminationSnapshotWillPersist
        self.applicationCloseSnapshotWillPersist = applicationCloseSnapshotWillPersist
        self.applicationCloseSnapshotStager = applicationCloseSnapshotStager
        self.applicationCloseSnapshotCommitter = applicationCloseSnapshotCommitter
        self.applicationCloseSnapshotAborter = applicationCloseSnapshotAborter
        self.atomicWrite = atomicWrite
        self.maximumEditableByteCount = maximumEditableByteCount
        self.paneLayout = PaneLayout()
        self.workspaceFolder = nil
        self.workspaceFolders = []
        self.sessionProject = nil
        if createInitialDocument {
            let document = EditorDocument(untitledName: "Untitled-1")
            documents = [document]
            paneLayout = PaneLayout(
                documentIDs: [document.sessionDocumentID],
                activeDocumentID: document.sessionDocumentID
            )
            observe(document)
            synchronizeBufferViewsWithLayout()
            synchronizeSelectedDocument()
        }
    }

    public var selectedDocument: EditorDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    public var currentDocument: EditorDocument? { selectedDocument }

    public var hasDirtyDocuments: Bool {
        documents.contains { $0.isDirty }
    }

    public var canReopenClosedTab: Bool { !recentlyClosedTabs.isEmpty }

    public var recentlyClosedTabCount: Int { recentlyClosedTabs.count }

    public var mostRecentlyClosedTab: RecentlyClosedTab? {
        recentlyClosedTabs.last
    }

    func retainSecurityScopedAccess(
        _ lease: SecurityScopedResourceLease,
        for document: EditorDocument
    ) {
        guard contains(document) else {
            lease.invalidate()
            return
        }
        securityScopedDocumentLeases[document.id] = lease
    }

    public var statusEncodingText: String {
        selectedDocument?.encodingStatusText ?? "--"
    }

    public var statusLineEndingText: String {
        selectedDocument?.lineEndingStatusText ?? "--"
    }

    public var statusLanguageText: String {
        selectedDocument?.language ?? LanguageCatalog.plainTextName
    }

    /// Applies a catalog-owned manual language choice to a live document. The
    /// document publisher drives the existing debounced session update.
    @discardableResult
    func selectLanguage(
        _ name: String,
        for document: EditorDocument? = nil,
        using catalog: LanguageCatalog = .builtIn
    ) -> Bool {
        guard let document = document ?? selectedDocument, contains(document) else {
            return false
        }
        return document.chooseLanguage(name, catalog: catalog)
    }

    /// Re-runs extension detection for a live, unlocked document.
    @discardableResult
    func refreshAutomaticLanguage(
        for document: EditorDocument? = nil,
        using catalog: LanguageCatalog = .builtIn
    ) -> Bool {
        guard let document = document ?? selectedDocument, contains(document) else {
            return false
        }
        return document.refreshAutomaticLanguage(using: catalog)
    }

    public func configureSessionWorkspace(
        folders: [String],
        primaryFolder: String? = nil,
        project: WindowSessionProject? = nil
    ) {
        var seen = Set<String>()
        let normalized = folders.filter { path in
            (path as NSString).isAbsolutePath && seen.insert(path).inserted
        }
        workspaceFolders = normalized
        workspaceFolder = primaryFolder.flatMap { normalized.contains($0) ? $0 : nil }
            ?? normalized.first
        sessionProject = project
        persistSession()
    }

    /// Returns false when a destructive workspace mutation would touch an
    /// unsaved or otherwise unresolved open document.
    func canApplyWorkspaceMutation(_ event: WorkspaceMutationEvent) -> Bool {
        guard let source = event.sourceURL else { return true }
        let sourcePath = source.standardizedFileURL.path
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        let affected = documents.filter { document in
            guard let path = document.fileURL?.standardizedFileURL.path else { return false }
            return path == sourcePath || path.hasPrefix(prefix)
        }
        return affected.allSatisfy { !$0.isDirty && !$0.isSaving }
    }

    func prepareWorkspaceMutation(
        _ event: WorkspaceMutationEvent
    ) throws -> PreparedWorkspaceMutation? {
        guard let prepareSecurityScopedFileAccessMoves else { return nil }
        switch event {
        case let .renamed(from, to), let .moved(from, to):
            let sourcePath = from.standardizedFileURL.path
            let targetPath = to.standardizedFileURL.path
            let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            let moves = documents.compactMap { document -> SecurityScopedFileAccessMove? in
                guard let url = document.fileURL?.standardizedFileURL else { return nil }
                let destination: URL
                if url.path == sourcePath {
                    destination = URL(fileURLWithPath: targetPath)
                } else if url.path.hasPrefix(prefix) {
                    let suffix = String(url.path.dropFirst(prefix.count))
                    destination = URL(fileURLWithPath: targetPath, isDirectory: true)
                        .appendingPathComponent(suffix)
                } else {
                    return nil
                }
                return SecurityScopedFileAccessMove(
                    source: url, destination: destination
                )
            }
            guard let prepared = try prepareSecurityScopedFileAccessMoves(moves) else {
                return nil
            }
            return PreparedWorkspaceMutation(
                commit: { prepared.commit() },
                abort: { try prepared.abort() }
            )
        case .created, .trashed:
            return nil
        }
    }

    /// Reconciles document identities only after WorkspaceService has committed
    /// the corresponding rename/move/trash operation.
    func applyWorkspaceMutation(_ event: WorkspaceMutationEvent) throws {
        var coordinationError: (any Error)?
        switch event {
        case .created:
            break
        case let .renamed(from, to), let .moved(from, to):
            do {
                try relocateOpenDocuments(from: from, to: to)
            } catch {
                coordinationError = error
            }
        case let .trashed(url):
            let sourcePath = url.standardizedFileURL.path
            let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            let affected = documents.filter { document in
                guard let path = document.fileURL?.standardizedFileURL.path else { return false }
                return path == sourcePath || path.hasPrefix(prefix)
            }
            // Workspace trash already represents an intentional filesystem
            // removal, not a user tab-close action that should be reopenable.
            for document in affected {
                removeDocument(document, rememberingClosed: false)
            }
        }
        persistSession()
        if let coordinationError { throw coordinationError }
    }

    private func relocateOpenDocuments(from source: URL, to target: URL) throws {
        let sourcePath = source.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        var relocations: [(EditorDocument, URL, URL)] = []
        for document in documents {
            guard let originalURL = document.fileURL?.standardizedFileURL else { continue }
            let original = originalURL.path
            if original == sourcePath {
                let destination = URL(fileURLWithPath: targetPath)
                relocations.append((document, originalURL, destination))
            } else if original.hasPrefix(prefix) {
                let suffix = String(original.dropFirst(prefix.count))
                let destination = URL(fileURLWithPath: targetPath, isDirectory: true)
                    .appendingPathComponent(suffix)
                relocations.append((document, originalURL, destination))
            }
        }

        var replacementLeases: [EditorDocument.ID: SecurityScopedResourceLease] = [:]
        var leaseError: (any Error)?
        if let securityScopedFileAccessDidMove {
            do {
                for (document, original, destination) in relocations {
                    replacementLeases[document.id] = try securityScopedFileAccessDidMove(
                        original, destination
                    )
                }
            } catch {
                for lease in replacementLeases.values { lease.invalidate() }
                replacementLeases.removeAll()
                leaseError = error
            }
        }

        for (document, _, destination) in relocations {
            if let lease = replacementLeases.removeValue(forKey: document.id) {
                securityScopedDocumentLeases[document.id] = lease
            }
            document.relocate(to: destination)
        }
        if let leaseError { throw leaseError }
    }

    @discardableResult
    public func newDocument() -> EditorDocument {
        let document = EditorDocument(untitledName: nextUntitledName())
        appendAndSelect(document)
        persistSession()
        return document
    }

    /// Opens generated comparison content (for example Git index conflict
    /// sides) as an untitled snapshot. The user may edit or Save As, but it has
    /// no file URL or save baseline pointing at repository metadata.
    @discardableResult
    public func openComparisonSnapshot(
        displayName: String,
        text: String,
        languageHintURL: URL? = nil,
        encoding: TextEncoding = .utf8,
        lineEnding: LineEnding = .lf
    ) -> EditorDocument {
        let document = EditorDocument(
            fileURL: nil, displayName: displayName, text: text, savedText: text,
            encoding: encoding, lineEnding: lineEnding,
            language: LanguageCatalog.builtIn.detect(url: languageHintURL).name
        )
        appendAndSelect(document)
        persistSession()
        return document
    }

    public func selectDocument(id: EditorDocument.ID) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        _ = selectDocument(document, inPaneAt: paneLayout.activePaneIndex)
    }

    public func document(forSessionID id: String) -> EditorDocument? {
        documents.first { $0.sessionDocumentID == id }
    }

    public func document(sessionDocumentID id: String) -> EditorDocument? {
        document(forSessionID: id)
    }

    public func document(forSessionDocumentID id: String) -> EditorDocument? {
        document(forSessionID: id)
    }

    public func activeDocument(inPaneAt paneIndex: Int) -> EditorDocument? {
        guard paneLayout.panes.indices.contains(paneIndex),
              let id = paneLayout.panes[paneIndex].activeDocumentID else { return nil }
        return document(forSessionID: id)
    }

    @discardableResult
    public func selectDocument(
        _ document: EditorDocument,
        inPaneAt paneIndex: Int
    ) -> Bool {
        guard contains(document), paneLayout.panes.indices.contains(paneIndex) else { return false }
        var layout = paneLayout
        let changed: Bool
        if layout.panes[paneIndex].contains(document.sessionDocumentID) {
            changed = layout.selectTab(
                documentID: document.sessionDocumentID,
                inPaneAt: paneIndex
            )
        } else {
            let selection = document.selectionSet(for: layout.panes[paneIndex].viewID)
                ?? document.selectionSet(for: .default)
                ?? .cursor(at: 0)
            changed = layout.activate(
                documentID: document.sessionDocumentID,
                inPaneAt: paneIndex,
                selection: selection
            )
        }
        guard changed else { return false }
        layout.organizePinnedTabs(
            Set(documents.lazy.filter(\.pinned).map(\.sessionDocumentID))
        )
        paneLayout = layout
        synchronizeBufferViewsWithLayout()
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func selectDocument(
        sessionDocumentID: String,
        inPaneAt paneIndex: Int
    ) -> Bool {
        guard let document = document(forSessionID: sessionDocumentID) else { return false }
        return selectDocument(document, inPaneAt: paneIndex)
    }

    public func selection(
        for document: EditorDocument,
        inPaneAt paneIndex: Int
    ) -> SelectionSet {
        guard paneLayout.panes.indices.contains(paneIndex) else { return .cursor(at: 0) }
        let viewID = paneLayout.panes[paneIndex].viewID
        return document.selectionSet(for: viewID)
            ?? paneLayout.selection(
                forDocumentID: document.sessionDocumentID,
                inPaneAt: paneIndex
            )
            ?? .cursor(at: 0)
    }

    public func selection(
        for documentID: String,
        viewID: EditorViewID
    ) -> SelectionSet {
        guard let document = document(forSessionID: documentID) else { return .cursor(at: 0) }
        return document.selectionSet(for: viewID) ?? .cursor(at: 0)
    }

    @discardableResult
    public func setSelections(
        _ selections: SelectionSet,
        for document: EditorDocument,
        inPaneAt paneIndex: Int
    ) -> Bool {
        guard contains(document), paneLayout.panes.indices.contains(paneIndex),
              paneLayout.panes[paneIndex].contains(document.sessionDocumentID) else { return false }
        let clamped = selections.clamped(toUTF16Length: document.buffer.utf16Length)
        let viewID = paneLayout.panes[paneIndex].viewID
        do {
            let changed = try document.setSelections(clamped, for: viewID)
            var layout = paneLayout
            _ = layout.setSelection(
                clamped,
                forDocumentID: document.sessionDocumentID,
                inPaneAt: paneIndex
            )
            paneLayout = layout
            if changed { persistSession() }
            return changed
        } catch {
            present(error, title: .updateSelection)
            return false
        }
    }

    @discardableResult
    public func setSelection(
        _ selection: SelectionSet,
        for documentID: String,
        viewID: EditorViewID
    ) -> Bool {
        guard let document = document(forSessionID: documentID),
              let paneIndex = paneLayout.panes.firstIndex(where: { $0.viewID == viewID }) else {
            return false
        }
        return setSelections(selection, for: document, inPaneAt: paneIndex)
    }

    @discardableResult
    public func applyTextChange(
        document: EditorDocument,
        inPaneAt paneIndex: Int,
        range: NSRange,
        replacement: String,
        selectedRanges: SelectionSet
    ) -> Bool {
        guard !isTextEditingLocked, contains(document),
              paneLayout.panes.indices.contains(paneIndex),
              paneLayout.panes[paneIndex].contains(document.sessionDocumentID) else { return false }
        let viewID = paneLayout.panes[paneIndex].viewID
        do {
            let changed = try document.applyReplacingUTF16Range(
                range,
                replacement: replacement,
                viewID: viewID,
                selectionsAfter: selectedRanges
            )
            synchronizeLayoutSelections(for: document)
            if changed { persistSession() }
            return changed
        } catch {
            present(error, title: .editDocument)
            return false
        }
    }

    @discardableResult
    public func apply(
        edit: TextEdit,
        selection: SelectionSet,
        documentID: String,
        viewID: EditorViewID
    ) -> Bool {
        guard !isTextEditingLocked,
              let document = document(forSessionID: documentID),
              let paneIndex = paneLayout.panes.firstIndex(where: { $0.viewID == viewID }) else {
            return false
        }
        return applyTextChange(
            document: document,
            inPaneAt: paneIndex,
            range: edit.range,
            replacement: edit.insert,
            selectedRanges: selection
        )
    }

    @discardableResult
    public func apply(
        _ transaction: TextTransaction,
        to document: EditorDocument,
        inPaneAt paneIndex: Int
    ) -> Bool {
        guard !isTextEditingLocked, contains(document),
              paneLayout.panes.indices.contains(paneIndex),
              paneLayout.panes[paneIndex].contains(document.sessionDocumentID) else { return false }
        do {
            let changed = try document.apply(
                transaction,
                for: paneLayout.panes[paneIndex].viewID
            )
            synchronizeLayoutSelections(for: document)
            if changed { persistSession() }
            return changed
        } catch {
            present(error, title: .editDocument)
            return false
        }
    }

    @discardableResult
    public func undo(
        document: EditorDocument? = nil,
        inPaneAt paneIndex: Int? = nil
    ) -> Bool {
        guard !isTextEditingLocked else { return false }
        let index = paneIndex ?? paneLayout.activePaneIndex
        guard paneLayout.panes.indices.contains(index) else { return false }
        let viewID = paneLayout.panes[index].viewID
        guard let document = document ?? activeDocument(inPaneAt: index),
              contains(document), document.undo(for: viewID) else { return false }
        synchronizeLayoutSelections(for: document)
        persistSession()
        return true
    }

    @discardableResult
    public func undo(documentID: String, viewID: EditorViewID) -> Bool {
        guard let document = document(forSessionID: documentID),
              let paneIndex = paneLayout.panes.firstIndex(where: { $0.viewID == viewID }) else {
            return false
        }
        return undo(document: document, inPaneAt: paneIndex)
    }

    @discardableResult
    public func redo(
        document: EditorDocument? = nil,
        inPaneAt paneIndex: Int? = nil
    ) -> Bool {
        guard !isTextEditingLocked else { return false }
        let index = paneIndex ?? paneLayout.activePaneIndex
        guard paneLayout.panes.indices.contains(index) else { return false }
        let viewID = paneLayout.panes[index].viewID
        guard let document = document ?? activeDocument(inPaneAt: index),
              contains(document), document.redo(for: viewID) else { return false }
        synchronizeLayoutSelections(for: document)
        persistSession()
        return true
    }

    @discardableResult
    public func redo(documentID: String, viewID: EditorViewID) -> Bool {
        guard let document = document(forSessionID: documentID),
              let paneIndex = paneLayout.panes.firstIndex(where: { $0.viewID == viewID }) else {
            return false
        }
        return redo(document: document, inPaneAt: paneIndex)
    }

    public func scrollPosition(
        for document: EditorDocument,
        inPaneAt paneIndex: Int
    ) -> EditorPaneScrollPosition {
        guard paneLayout.panes.indices.contains(paneIndex) else { return .zero }
        return scrollPositions[PaneDocumentKey(
            viewID: paneLayout.panes[paneIndex].viewID,
            documentID: document.sessionDocumentID
        )] ?? .zero
    }

    public func scrollPosition(
        for documentID: String,
        viewID: EditorViewID
    ) -> EditorPaneScrollPosition {
        scrollPositions[PaneDocumentKey(viewID: viewID, documentID: documentID)] ?? .zero
    }

    public func scroll(
        for documentID: String,
        viewID: EditorViewID
    ) -> (x: Int, y: Int) {
        let position = scrollPosition(for: documentID, viewID: viewID)
        return (position.x, position.y)
    }

    public func setScrollPosition(
        _ position: EditorPaneScrollPosition,
        for document: EditorDocument,
        inPaneAt paneIndex: Int
    ) {
        guard contains(document), paneLayout.panes.indices.contains(paneIndex),
              paneLayout.panes[paneIndex].contains(document.sessionDocumentID) else { return }
        let key = PaneDocumentKey(
            viewID: paneLayout.panes[paneIndex].viewID,
            documentID: document.sessionDocumentID
        )
        let normalized = EditorPaneScrollPosition(x: position.x, y: position.y)
        guard scrollPositions[key] != normalized else { return }
        scrollPositions[key] = normalized
        scheduleSessionPersistence()
    }

    public func setScrollPosition(
        x: Int,
        y: Int,
        for documentID: String,
        viewID: EditorViewID
    ) {
        guard let document = document(forSessionID: documentID),
              let paneIndex = paneLayout.panes.firstIndex(where: { $0.viewID == viewID }) else {
            return
        }
        setScrollPosition(
            EditorPaneScrollPosition(x: x, y: y),
            for: document,
            inPaneAt: paneIndex
        )
    }

    public func setScroll(
        x: Int,
        y: Int,
        for documentID: String,
        viewID: EditorViewID
    ) {
        setScrollPosition(x: x, y: y, for: documentID, viewID: viewID)
    }

    public func referenceCount(for document: EditorDocument) -> Int {
        paneLayout.referenceCount(for: document.sessionDocumentID)
    }

    @discardableResult
    public func setLayout(_ kind: PaneLayoutKind) -> Bool {
        var layout = paneLayout
        guard layout.setLayout(kind) else { return false }
        layout.organizePinnedTabs(pinnedSessionDocumentIDs)
        paneLayout = layout
        synchronizeBufferViewsWithLayout()
        pruneScrollPositions()
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func toggleSplit() -> Bool {
        var layout = paneLayout
        guard layout.toggleSplitEditor() else { return false }
        layout.organizePinnedTabs(pinnedSessionDocumentIDs)
        paneLayout = layout
        synchronizeBufferViewsWithLayout()
        pruneScrollPositions()
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func toggleSplitEditor() -> Bool { toggleSplit() }

    @discardableResult
    public func splitSelectedTabs() -> Bool {
        var layout = paneLayout
        guard layout.splitSelectedTabs() else { return false }
        layout.organizePinnedTabs(pinnedSessionDocumentIDs)
        paneLayout = layout
        synchronizeBufferViewsWithLayout()
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func moveActiveDocumentToNextPane() -> Bool {
        var layout = paneLayout
        guard layout.moveActiveDocumentToNextPane() else { return false }
        layout.organizePinnedTabs(pinnedSessionDocumentIDs)
        paneLayout = layout
        synchronizeBufferViewsWithLayout()
        pruneScrollPositions()
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func cloneActiveDocumentToNextPane() -> Bool {
        var layout = paneLayout
        guard layout.cloneActiveDocumentToNextPane() else { return false }
        layout.organizePinnedTabs(pinnedSessionDocumentIDs)
        paneLayout = layout
        synchronizeBufferViewsWithLayout()
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func focusPane(at index: Int) -> Bool {
        var layout = paneLayout
        guard layout.focusPane(at: index) else { return false }
        paneLayout = layout
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func focusNextPane() -> Bool {
        var layout = paneLayout
        guard layout.focusNextPane() else { return false }
        paneLayout = layout
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func focusPreviousPane() -> Bool {
        var layout = paneLayout
        guard layout.focusPreviousPane() else { return false }
        paneLayout = layout
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    @discardableResult
    public func cycleActiveDocument(by delta: Int) -> EditorDocument? {
        var layout = paneLayout
        guard let documentID = layout.cycleActiveTab(by: delta) else { return nil }
        paneLayout = layout
        synchronizeSelectedDocument()
        persistSession()
        return document(forSessionID: documentID)
    }

    @discardableResult
    public func selectNextDocument() -> EditorDocument? {
        cycleActiveDocument(by: 1)
    }

    @discardableResult
    public func selectPreviousDocument() -> EditorDocument? {
        cycleActiveDocument(by: -1)
    }

    /// Select a one-based tab number in one pane. This is the model-side API
    /// used by Cmd-1 through Cmd-9; out-of-range values are harmless.
    @discardableResult
    public func selectTab(
        number: Int,
        inPaneAt paneIndex: Int? = nil
    ) -> EditorDocument? {
        let index = paneIndex ?? paneLayout.activePaneIndex
        guard (1...9).contains(number),
              paneLayout.panes.indices.contains(index) else { return nil }
        let ids = paneLayout.panes[index].documentIDs
        guard ids.indices.contains(number - 1),
              let document = document(forSessionID: ids[number - 1]) else { return nil }
        _ = selectDocument(document, inPaneAt: index)
        return document
    }

    /// Compatibility spelling for keyboard adapters that name the document.
    @discardableResult
    public func selectDocument(
        atTabNumber number: Int,
        inPaneAt paneIndex: Int? = nil
    ) -> EditorDocument? {
        selectTab(number: number, inPaneAt: paneIndex)
    }

    /// Toggle pinning and immediately stable-partition every pane's tab row.
    @discardableResult
    public func togglePin(_ document: EditorDocument) -> Bool {
        guard contains(document) else { return false }
        document.pinned.toggle()
        organizePinnedTabs()
        persistSession()
        return document.pinned
    }

    @discardableResult
    public func togglePinForSelectedDocument() -> Bool? {
        guard let selectedDocument else { return nil }
        return togglePin(selectedDocument)
    }

    /// Cmd-click selection is shared across panes, matching the Electron tab
    /// model. A normal tab activation clears it through PaneLayout.selectTab.
    @discardableResult
    public func toggleTabSelection(_ document: EditorDocument) -> Bool {
        guard contains(document) else { return false }
        var layout = paneLayout
        let selected = layout.toggleTabSelection(document.sessionDocumentID)
        guard layout != paneLayout else { return selected }
        paneLayout = layout
        return selected
    }

    public func clearTabSelection() {
        var layout = paneLayout
        layout.clearTabSelection()
        if layout != paneLayout { paneLayout = layout }
    }

    /// Reorder a single tab, or the selected block when the dragged tab is
    /// selected. Pinned and unpinned tabs remain in their respective regions.
    @discardableResult
    public func reorderTabs(
        inPaneAt paneIndex: Int,
        draggedDocumentID: String,
        relativeTo targetDocumentID: String? = nil,
        position: PaneLayout.TabDropPosition = .before
    ) -> Bool {
        var layout = paneLayout
        guard layout.panes.indices.contains(paneIndex),
              layout.panes[paneIndex].contains(draggedDocumentID) else { return false }
        let paneDocumentIDs = layout.panes[paneIndex].documentIDs
        let movingIDs = layout.selectedDocumentIDs.contains(draggedDocumentID)
            ? Set(paneDocumentIDs.filter(layout.selectedDocumentIDs.contains))
            : Set([draggedDocumentID])
        let draggedIsPinned = pinnedSessionDocumentIDs.contains(draggedDocumentID)
        guard movingIDs.allSatisfy({
            pinnedSessionDocumentIDs.contains($0) == draggedIsPinned
        }) else { return false }
        guard let targetDocumentID,
              pinnedSessionDocumentIDs.contains(targetDocumentID)
                == draggedIsPinned else { return false }
        guard layout.reorderTabs(
            inPaneAt: paneIndex,
            draggedDocumentID: draggedDocumentID,
            relativeTo: targetDocumentID,
            position: position
        ) else { return false }
        guard layout != paneLayout else { return false }
        paneLayout = layout
        persistSession()
        return true
    }

    /// Resolve the unpinned, pane-local targets for a bulk close command using
    /// the exact order currently visible to the user.
    public func documentsToClose(
        _ scope: TabCloseScope,
        inPaneAt paneIndex: Int? = nil
    ) -> [EditorDocument] {
        let index = paneIndex ?? paneLayout.activePaneIndex
        guard paneLayout.panes.indices.contains(index),
              let activeID = paneLayout.panes[index].activeDocumentID,
              let activeIndex = paneLayout.panes[index].documentIDs.firstIndex(
                of: activeID
              ) else { return [] }
        return paneLayout.panes[index].documentIDs.enumerated().compactMap { offset, id in
            let included: Bool
            switch scope {
            case .others: included = id != activeID
            case .right: included = offset > activeIndex
            case .all: included = true
            }
            guard included, let document = document(forSessionID: id),
                  !document.pinned else { return nil }
            return document
        }
    }

    public func documentsToClose(
        _ scope: TabCloseScope,
        relativeTo document: EditorDocument,
        inPaneAt paneIndex: Int
    ) -> [EditorDocument] {
        guard contains(document), paneLayout.panes.indices.contains(paneIndex),
              paneLayout.panes[paneIndex].contains(document.sessionDocumentID) else {
            return []
        }
        let ids = paneLayout.panes[paneIndex].documentIDs
        guard let activeIndex = ids.firstIndex(of: document.sessionDocumentID) else {
            return []
        }
        return ids.enumerated().compactMap { offset, id in
            let included: Bool
            switch scope {
            case .others: included = id != document.sessionDocumentID
            case .right: included = offset > activeIndex
            case .all: included = true
            }
            guard included, let candidate = self.document(forSessionID: id),
                  !candidate.pinned else { return nil }
            return candidate
        }
    }

    /// Removes one pane reference only. This low-level layout primitive does
    /// not create a reopen-stack entry; user close gestures should call the
    /// pane-aware `requestClose` overload below.
    @discardableResult
    public func removeDocument(
        _ document: EditorDocument,
        fromPaneAt paneIndex: Int
    ) -> Bool {
        guard contains(document),
              paneLayout.referenceCount(for: document.sessionDocumentID) > 1 else {
            return false
        }
        let removedViewID = paneLayout.panes.indices.contains(paneIndex)
            ? paneLayout.panes[paneIndex].viewID : nil
        var layout = paneLayout
        guard layout.removeDocument(
            document.sessionDocumentID,
            fromPaneAt: paneIndex
        ) else { return false }
        paneLayout = layout
        if let removedViewID {
            document.removeView(removedViewID)
            scrollPositions.removeValue(forKey: PaneDocumentKey(
                viewID: removedViewID,
                documentID: document.sessionDocumentID
            ))
        }
        synchronizeSelectedDocument()
        persistSession()
        return true
    }

    /// Close one pane occurrence while preserving dirty confirmation for the
    /// document's final reference. This is the shared tab-button API.
    public func requestClose(
        _ document: EditorDocument,
        fromPaneAt paneIndex: Int
    ) {
        guard contains(document), paneLayout.panes.indices.contains(paneIndex),
              paneLayout.panes[paneIndex].contains(document.sessionDocumentID) else { return }
        if referenceCount(for: document) > 1 {
            _ = removeDocument(document, fromPaneAt: paneIndex)
        } else {
            requestClose(document)
        }
    }

    public func clearPresentedIssue() {
        presentedIssue = nil
    }

    public func dismissEncodingNotice() {
        encodingNotice = nil
    }

    public func dismissFileSaveNotice() {
        fileSaveNotice = nil
    }

    @discardableResult
    public func open(
        url: URL,
        forcedEncoding: TextEncoding? = nil
    ) async -> EditorDocument? {
        guard let admission = prepareDocumentOpenAdmission() else { return nil }
        if let existing = document(at: url) {
            _ = selectDocument(existing, inPaneAt: paneLayout.activePaneIndex)
            return existing
        }

        do {
            let file = try await Self.readFile(
                at: url,
                forcedEncoding: forcedEncoding,
                maximumByteCount: maximumEditableByteCount
            )
            let document = completeDocumentOpen(file, admission: admission)
            if let document, let restoreSecurityScopedFileAccess,
               let lease = try? restoreSecurityScopedFileAccess(file.url) {
                retainSecurityScopedAccess(lease, for: document)
            }
            return document
        } catch {
            present(error, title: .openFile, context: url.lastPathComponent)
            return nil
        }
    }

    @discardableResult
    public func open(
        urls: [URL],
        forcedEncoding: TextEncoding? = nil
    ) async -> [EditorDocument] {
        var opened: [EditorDocument] = []
        for url in urls {
            if let document = await open(url: url, forcedEncoding: forcedEncoding) {
                opened.append(document)
            }
        }
        return opened
    }

    /// Accepts bytes already read through an authorised workspace service.
    /// This avoids resolving and opening the same path a second time.
    @discardableResult
    public func open(openedFile: OpenedTextFile) -> EditorDocument? {
        guard let admission = prepareDocumentOpenAdmission() else { return nil }
        return completeDocumentOpen(openedFile, admission: admission)
    }

    func prepareDocumentOpenAdmission() -> DocumentOpenAdmission? {
        guard canAdmitOpenedDocument else { return nil }
        return DocumentOpenAdmission(generation: documentOpenAdmissionGeneration)
    }

    @discardableResult
    func completeDocumentOpen(
        _ openedFile: OpenedTextFile, admission: DocumentOpenAdmission
    ) -> EditorDocument? {
        guard canAdmitOpenedDocument,
              admission.generation == documentOpenAdmissionGeneration else {
            return nil
        }
        return insertOpenedFile(openedFile)
    }

    private func insertOpenedFile(_ openedFile: OpenedTextFile) -> EditorDocument? {
        if let existing = document(at: openedFile.url) {
            _ = selectDocument(existing, inPaneAt: paneLayout.activePaneIndex)
            return existing
        }
        guard validateEditable(openedFile) else { return nil }
        let document = EditorDocument(openedFile: openedFile)
        appendAndSelect(document)
        persistSession()
        switch openedFile.encodingIssue {
        case .invalidBytes:
            encodingNotice = .invalidBytesAfterOpen(
                documentID: document.id, encoding: openedFile.encoding
            )
        case .uncertain:
            encodingNotice = .uncertainEncodingAfterOpen(
                documentID: document.id, encoding: openedFile.encoding
            )
        case nil:
            encodingNotice = nil
        }
        return document
    }

    /// Discards the current buffer and reads the original bytes again. A nil
    /// encoding restores automatic detection; a value explicitly locks the
    /// document to that encoding. The caller is responsible for confirmation.
    @discardableResult
    public func reopen(
        _ document: EditorDocument,
        using encoding: TextEncoding?
    ) async -> Bool {
        guard contains(document), let url = document.fileURL else { return false }
        let expectedBufferRevision = document.buffer.revision
        let expectedDiskRevision = document.diskRevision
        do {
            let file = try await Self.readFile(
                at: url,
                forcedEncoding: encoding,
                maximumByteCount: maximumEditableByteCount
            )
            // File reads run away from the main actor. Do not let a stale
            // result overwrite edits, a completed save, Save As, or a close
            // that happened while the bytes were being decoded.
            guard contains(document),
                  !document.isSaving,
                  document.fileURL.map({ sameFile($0, url) }) == true,
                  document.buffer.revision == expectedBufferRevision,
                  document.diskRevision == expectedDiskRevision else {
                return false
            }
            guard validateEditable(file) else { return false }
            document.replaceWithDiskFile(file)
            persistSession()
            // A caller may reopen a background document (for example after a
            // multi-file Git discard). Never publish a window-wide notice for
            // a tab that is no longer active when the asynchronous read wins.
            if document.id == selectedDocumentID {
                if document.encodingIssue == .invalidBytes {
                    encodingNotice = .invalidBytesAfterReopen(
                        documentID: document.id, requestedEncoding: encoding
                    )
                } else {
                    encodingNotice = .reopenSuccess(
                        documentID: document.id,
                        requestedEncoding: encoding,
                        actualEncoding: document.encoding,
                        displayName: document.displayName
                    )
                }
            }
            return true
        } catch {
            guard contains(document),
                  !document.isSaving,
                  document.fileURL.map({ sameFile($0, url) }) == true,
                  document.buffer.revision == expectedBufferRevision,
                  document.diskRevision == expectedDiskRevision else {
                return false
            }
            present(error, title: .reopenFile, context: document.displayName)
            return false
        }
    }

    /// Reloads a clean document after a Git disk mutation while retaining the
    /// Git mutation lock throughout the asynchronous read. A concurrent Quit
    /// review can add its own owner without blocking this already-authorized
    /// reconciliation; neither owner can release the other's lock.
    @discardableResult
    func reopenAfterGitMutation(
        _ document: EditorDocument,
        lockID: UUID,
        using encoding: TextEncoding?
    ) async -> Bool {
        defer { document.unlockEditingAfterGitMutation(lockID) }
        guard contains(document), let url = document.fileURL else { return false }
        let expectedBufferRevision = document.buffer.revision
        let expectedDiskRevision = document.diskRevision
        do {
            let file = try await Self.readFile(
                at: url, forcedEncoding: encoding,
                maximumByteCount: maximumEditableByteCount
            )
            guard contains(document), !document.isSaving,
                  document.fileURL.map({ sameFile($0, url) }) == true,
                  document.buffer.revision == expectedBufferRevision,
                  document.diskRevision == expectedDiskRevision else { return false }
            if file.isBinary || file.isTooLarge {
                document.setExternalConflict(ExternalConflict(
                    kind: file.isBinary ? .binary : .tooLarge,
                    url: url, diskFile: file
                ))
                persistSession()
                _ = validateEditable(file)
                return false
            }
            guard
                  document.replaceWithDiskFile(file, gitMutationID: lockID) else {
                return false
            }
            persistSession()
            return true
        } catch {
            guard contains(document), !document.isSaving,
                  document.fileURL.map({ sameFile($0, url) }) == true,
                  document.buffer.revision == expectedBufferRevision,
                  document.diskRevision == expectedDiskRevision else { return false }
            document.setExternalConflict(ExternalConflict(
                kind: Self.isMissingFileError(error) ? .missing : .unreadable,
                url: url, detail: error.localizedDescription
            ))
            persistSession()
            present(error, title: .reopenFile, context: document.displayName)
            return false
        }
    }

    @discardableResult
    public func save(_ document: EditorDocument) async -> Bool {
        guard let url = document.fileURL else {
            presentedIssue = AppModelIssue(
                title: .chooseSaveLocation,
                appIssue: .saveLocationRequired(displayName: document.displayName)
            )
            return false
        }
        return (await performSave(document, to: url, isSaveAs: false)).didComplete
    }

    @discardableResult
    public func saveCurrentDocument() async -> Bool {
        guard let selectedDocument else { return false }
        return await save(selectedDocument)
    }

    @discardableResult
    public func saveAs(_ document: EditorDocument, to url: URL) async -> Bool {
        if let existing = self.document(at: url), existing !== document {
            presentedIssue = AppModelIssue(
                title: .saveFile, appIssue: .destinationAlreadyOpen
            )
            return false
        }
        return (await performSave(document, to: url, isSaveAs: true)).didComplete
    }

    /// Save adapter for a coordinator that freshly resolved EditorConfig at
    /// the actual destination, including a not-yet-created Save As path.
    @discardableResult
    public func save(
        _ document: EditorDocument,
        to destination: URL,
        usingResolvedLineEnding lineEnding: LineEnding,
        isSaveAs: Bool
    ) async -> Bool {
        (await saveOutcome(
            document, to: destination,
            usingResolvedLineEnding: lineEnding, isSaveAs: isSaveAs
        )).didComplete
    }

    func saveOutcome(
        _ document: EditorDocument,
        to destination: URL,
        usingResolvedLineEnding lineEnding: LineEnding,
        isSaveAs: Bool
    ) async -> DocumentSaveOutcome {
        if isSaveAs, let existing = self.document(at: destination), existing !== document {
            presentedIssue = AppModelIssue(
                title: .saveFile, appIssue: .destinationAlreadyOpen
            )
            return .failed
        }
        return await performSave(
            document,
            to: destination,
            isSaveAs: isSaveAs,
            resolvedLineEnding: lineEnding
        )
    }

    @discardableResult
    public func saveAll() async -> Bool {
        for document in documents where document.isDirty {
            // Untitled tabs require UI-owned destination selection.
            guard document.fileURL != nil, await save(document) else { return false }
        }
        return true
    }

    /// Closes a clean tab immediately, otherwise publishes a request for the
    /// UI to resolve with Save, Discard, or Cancel.
    public func requestClose(_ document: EditorDocument) {
        guard contains(document) else { return }
        // A document may be visible in multiple panes, but a close request is
        // document-wide. UI that intends to close only one pane occurrence
        // calls `removeDocument(_:fromPaneAt:)` instead.
        if document.isDirty {
            if let paneIndex = paneLayout.panes.firstIndex(where: {
                $0.contains(document.sessionDocumentID)
            }) {
                _ = selectDocument(document, inPaneAt: paneIndex)
            } else {
                selectedDocumentID = document.id
            }
            pendingCloseRequest = CloseRequest(
                documentID: document.id,
                displayName: document.displayName
            )
        } else {
            removeDocument(document, rememberingClosed: true)
        }
    }

    /// Returns true only when the requested tab was actually closed. A failed
    /// save deliberately leaves both the tab and close request in place.
    @discardableResult
    public func resolveClose(
        _ decision: CloseDecision,
        saveAsURL: URL? = nil,
        resolvedLineEnding: LineEnding? = nil
    ) async -> Bool {
        guard
            let request = pendingCloseRequest,
            let document = documents.first(where: { $0.id == request.documentID })
        else {
            pendingCloseRequest = nil
            return false
        }

        switch decision {
        case .cancel:
            pendingCloseRequest = nil
            return false
        case .discard:
            pendingCloseRequest = nil
            removeDocument(document, rememberingClosed: true)
            return true
        case .save:
            let saved: Bool
            if let saveAsURL {
                saved = (await performSave(
                    document,
                    to: saveAsURL,
                    isSaveAs: true,
                    resolvedLineEnding: resolvedLineEnding
                )).didComplete
            } else {
                guard let url = document.fileURL else { return false }
                saved = (await performSave(
                    document,
                    to: url,
                    isSaveAs: false,
                    resolvedLineEnding: resolvedLineEnding
                )).didComplete
            }
            // An edit can land while the asynchronous write is in flight.
            // The written snapshot is then a valid new baseline, but closing
            // would still discard the newer edit. Keep the request open.
            guard saved, !document.isDirty else { return false }
            pendingCloseRequest = nil
            removeDocument(document, rememberingClosed: true)
            return true
        }
    }

    /// Remove a pre-reviewed set in one commit. The IDs are a snapshot from a
    /// pane-local bulk-close request; pinned documents and documents that have
    /// become dirty again are rechecked to prevent a stale operation from
    /// discarding state.
    @discardableResult
    public func commitReviewedTabClose(
        documentIDs: [EditorDocument.ID],
        fromPaneAt paneIndex: Int,
        reviewedDirtyDocumentRevisions: [EditorDocument.ID: UInt64] = [:]
    ) -> Bool {
        guard pendingCloseRequest == nil,
              paneLayout.panes.indices.contains(paneIndex) else { return false }
        var seen = Set<EditorDocument.ID>()
        let orderedIDs = documentIDs.filter { seen.insert($0).inserted }
        let targets = orderedIDs.compactMap { id in
            documents.first(where: { $0.id == id })
        }
        guard !targets.isEmpty,
              targets.count == orderedIDs.count,
              targets.allSatisfy({ document in
                  paneLayout.panes[paneIndex].contains(document.sessionDocumentID)
                      && !document.pinned
                      && !document.isSaving
                      && (referenceCount(for: document) > 1
                          || !document.isDirty
                          || reviewedDirtyDocumentRevisions[document.id]
                              == document.buffer.revision)
              }) else {
            return false
        }
        // Validation above is all-or-nothing. Build the complete value-state
        // mutation first so no persistence failure between targets can leave
        // the user-visible tab set half closed.
        var layout = paneLayout
        for document in targets {
            _ = layout.removeDocument(
                document.sessionDocumentID,
                fromPaneAt: paneIndex
            )
        }
        let unreferencedIDs = Set(targets.compactMap { document in
            layout.referenceCount(for: document.sessionDocumentID) == 0
                ? document.id : nil
        })
        let unreferencedSessionIDs = Set(targets.compactMap { document in
            unreferencedIDs.contains(document.id)
                ? document.sessionDocumentID : nil
        })
        for document in targets where unreferencedIDs.contains(document.id) {
            rememberClosed(document)
        }
        paneLayout = layout
        for document in targets where unreferencedIDs.contains(document.id) {
            documentSubscriptions[document.id] = nil
            securityScopedDocumentLeases.removeValue(forKey: document.id)?.invalidate()
        }
        let closedURLs = targets.compactMap { document in
            unreferencedIDs.contains(document.id) ? document.fileURL : nil
        }
        documents.removeAll { unreferencedIDs.contains($0.id) }
        for url in closedURLs { securityScopedFileAccessDidEnd?(url) }
        scrollPositions = scrollPositions.filter {
            !unreferencedSessionIDs.contains($0.key.documentID)
        }
        synchronizeSelectedDocument()
        ensureDocumentExists()
        persistSession()
        return true
    }

    /// Compatibility overload for callers that operate on whole-window
    /// document identities. Prefer the pane-aware overload for tab commands.
    @discardableResult
    public func commitReviewedTabClose(
        documentIDs: [EditorDocument.ID]
    ) -> Bool {
        commitReviewedTabClose(
            documentIDs: documentIDs,
            fromPaneAt: paneLayout.activePaneIndex
        )
    }

    /// Removes application-termination discards as one in-memory mutation.
    /// Every document identity and revision is validated before the first
    /// document is removed. Validation is intentionally separate so an
    /// application-wide coordinator can validate every window before the
    /// first irreversible mutation. Once validated on the main actor, this
    /// commit performs only synchronous in-memory teardown and cannot fail.
    func validateReviewedApplicationClose(
        documentRevisions: [EditorDocument.ID: UInt64]
    ) -> Bool {
        guard !isApplicationCloseCommitted, pendingCloseRequest == nil else { return false }
        let targets = documents.filter { documentRevisions[$0.id] != nil }
        return targets.count == documentRevisions.count
            && targets.allSatisfy { document in
                !document.isSaving
                    && documentRevisions[document.id] == document.buffer.revision
            }
    }

    /// Freeze edits as soon as close review begins. This also makes queued
    /// auto-save work ineligible before a reviewed Don't Save decision can be
    /// written back to the source file.
    @discardableResult
    func beginApplicationCloseReview() -> Bool {
        guard !isApplicationCloseCommitted, textEditingLockOwners[.termination] == nil else {
            return false
        }
        acquireTextEditingLock(.termination)
        for document in documents { document.lockEditingForTermination() }
        return true
    }

    /// A cancelled review has no commit point, so editing and auto-save may
    /// resume for every still-live document.
    func cancelApplicationCloseReview() {
        guard !isApplicationCloseCommitted, textEditingLockOwners[.termination] != nil else {
            return
        }
        for document in documents {
            document.unlockEditingAfterTerminationCancellation()
        }
        releaseTextEditingLock(.termination)
    }

    /// Git and termination are independent owners. They can overlap, and each
    /// release removes only its own acquisition. A committed termination is the
    /// sole state that rejects a newly starting Git transaction.
    func acquireGitEditingLock(_ id: UUID) -> Bool {
        guard !isApplicationCloseCommitted else { return false }
        acquireTextEditingLock(.gitMutation(id))
        return true
    }

    func releaseGitEditingLock(_ id: UUID) {
        releaseTextEditingLock(.gitMutation(id))
    }

    /// A rename locks only the open documents named by its reviewed edit set.
    /// Each document carries an independent owner token, so unrelated tabs
    /// remain editable and overlapping lifecycle locks cannot release it.
    func acquireRenameEditingLock(_ id: UUID, documents targets: [EditorDocument]) -> Bool {
        let targetIDs = Set(targets.map { ObjectIdentifier($0) })
        guard !isApplicationCloseCommitted, !isTextEditingLocked,
              targetIDs.count == targets.count,
              targets.allSatisfy({ contains($0) && !$0.hasRenameEditingLock(id) })
        else { return false }
        for document in targets { document.lockEditingForRenameMutation(id) }
        return true
    }

    func releaseRenameEditingLock(_ id: UUID, documents targets: [EditorDocument]) {
        for document in targets { document.unlockEditingAfterRenameMutation(id) }
    }

    /// Verifies the complete open-document view of a reviewed rename at its
    /// synchronous commit boundary. Planning may suspend while reading a
    /// closed target, so a tab for that target can appear after the original
    /// lock snapshot. The current target documents, planned bindings, and
    /// locked documents must remain the exact same identity set, and every
    /// member must still own this rename token.
    func validateRenameEditingLock(
        _ id: UUID,
        lockedDocuments: [EditorDocument],
        plannedBindings: [(url: URL, document: EditorDocument?)]
    ) -> Bool {
        guard !isApplicationCloseCommitted, !isTextEditingLocked else { return false }

        let canonicalTargets = plannedBindings.map { Self.canonicalURL($0.url) }
        guard Set(canonicalTargets).count == canonicalTargets.count else { return false }
        let targetSet = Set(canonicalTargets)
        let currentDocuments = documents.filter { document in
            guard let url = document.fileURL else { return false }
            return targetSet.contains(Self.canonicalURL(url))
        }
        let plannedDocuments = plannedBindings.compactMap { $0.document }

        let lockedIDs = Set(lockedDocuments.map { ObjectIdentifier($0) })
        let plannedIDs = Set(plannedDocuments.map { ObjectIdentifier($0) })
        let currentIDs = Set(currentDocuments.map { ObjectIdentifier($0) })
        guard lockedIDs.count == lockedDocuments.count,
              plannedIDs.count == plannedDocuments.count,
              currentIDs.count == currentDocuments.count,
              lockedIDs == plannedIDs, plannedIDs == currentIDs,
              lockedDocuments.allSatisfy({
                  contains($0) && $0.hasRenameEditingLock(id)
              }) else { return false }

        return plannedBindings.allSatisfy { binding in
            let matching = documents.filter { document in
                document.fileURL.map {
                    Self.canonicalURL($0) == Self.canonicalURL(binding.url)
                } == true
            }
            guard matching.count <= 1 else { return false }
            switch (binding.document, matching.first) {
            case (nil, nil):
                return true
            case let (planned?, current?):
                return planned === current && planned.hasRenameEditingLock(id)
            default:
                return false
            }
        }
    }

    private func acquireTextEditingLock(_ owner: TextEditingLockOwner) {
        if textEditingLockOwners[owner] == nil {
            documentOpenAdmissionGeneration += 1
        }
        textEditingLockOwners[owner, default: 0] += 1
        isTextEditingLocked = !textEditingLockOwners.isEmpty
    }

    private func releaseTextEditingLock(_ owner: TextEditingLockOwner) {
        guard let count = textEditingLockOwners[owner] else { return }
        if count > 1 {
            textEditingLockOwners[owner] = count - 1
        } else {
            textEditingLockOwners[owner] = nil
        }
        isTextEditingLocked = !textEditingLockOwners.isEmpty
    }

    private var canAdmitOpenedDocument: Bool {
        !isApplicationCloseCommitted && !isTextEditingLocked
    }

    func commitValidatedApplicationClose(
        documentRevisions: [EditorDocument.ID: UInt64]
    ) {
        // This is the application's irreversible commit point. The review
        // already froze every document; make that lock permanent before any
        // async finalizer can yield the main actor.
        isApplicationCloseCommitted = true
        acquireTextEditingLock(.termination)
        for document in documents { document.lockEditingForTermination() }
        guard !documentRevisions.isEmpty else { return }
        let targets = documents.filter { documentRevisions[$0.id] != nil }
        let removedIDs = Set(targets.map(\.id))
        let removedSessionIDs = Set(targets.map(\.sessionDocumentID))
        let closedURLs = targets.compactMap(\.fileURL)
        var layout = paneLayout
        for document in targets {
            _ = layout.removeDocumentEverywhere(document.sessionDocumentID)
        }
        paneLayout = layout
        for document in targets {
            documentSubscriptions[document.id] = nil
            securityScopedDocumentLeases.removeValue(forKey: document.id)?.invalidate()
        }
        documents.removeAll { removedIDs.contains($0.id) }
        for url in closedURLs { securityScopedFileAccessDidEnd?(url) }
        scrollPositions = scrollPositions.filter {
            !removedSessionIDs.contains($0.key.documentID)
        }
        synchronizeSelectedDocument()
    }

    /// The top entry is read before asynchronous I/O. It is consumed only
    /// after a successful open (or focus of an already-open matching file).
    @discardableResult
    public func consumeRecentlyClosedTab(id: RecentlyClosedTab.ID) -> Bool {
        guard let index = recentlyClosedTabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        recentlyClosedTabs.remove(at: index)
        return true
    }

    /// Refreshes a tab after a file-system notification or periodic poll.
    /// Clean buffers follow disk automatically; dirty buffers retain both
    /// versions until the user makes an explicit conflict decision.
    public func checkForExternalChange(_ document: EditorDocument) async {
        guard contains(document), let url = document.fileURL, !document.isSaving else { return }
        let expectedRevision = document.diskRevision
        do {
            let file = try await Self.readFile(
                at: url,
                forcedEncoding: document.encodingLocked ? document.savedEncoding : nil,
                maximumByteCount: maximumEditableByteCount
            )
            guard
                contains(document),
                !document.isSaving,
                document.fileURL.map({ sameFile($0, url) }) == true,
                document.diskRevision == expectedRevision
            else { return }
            if file.revision == expectedRevision { return }
            if file.isBinary || file.isTooLarge {
                document.setExternalConflict(ExternalConflict(
                    kind: file.isBinary ? .binary : .tooLarge,
                    url: url,
                    diskFile: file
                ))
            } else if document.isDirty {
                document.setExternalConflict(ExternalConflict(
                    kind: .modified,
                    url: url,
                    diskFile: file
                ))
            } else {
                document.replaceWithDiskFile(file)
                if document.id == selectedDocumentID {
                    encodingNotice = document.encodingIssue == .invalidBytes
                        ? .invalidBytesAfterExternalReload(
                            documentID: document.id, encoding: document.encoding
                        )
                        : nil
                }
            }
            persistSession()
        } catch {
            // Failed reads are asynchronous too. Ignore an obsolete poll
            // after Save As, save, close, or another baseline transition.
            guard contains(document),
                  !document.isSaving,
                  document.fileURL.map({ sameFile($0, url) }) == true,
                  document.diskRevision == expectedRevision else { return }
            let missing = Self.isMissingFileError(error)
            document.setExternalConflict(ExternalConflict(
                kind: missing ? .missing : .unreadable,
                url: url,
                detail: error.localizedDescription
            ))
            persistSession()
        }
    }

    public func checkForExternalChanges() async {
        for document in documents {
            await checkForExternalChange(document)
        }
    }

    @discardableResult
    public func reloadDiskVersion(for document: EditorDocument) -> Bool {
        guard
            contains(document),
            let conflict = document.externalConflict,
            conflict.canCompareOrReload,
            let file = conflict.diskFile
        else { return false }
        document.replaceWithDiskFile(file)
        persistSession()
        return true
    }

    @discardableResult
    public func keepLocalVersion(for document: EditorDocument) -> Bool {
        guard
            contains(document),
            let conflict = document.externalConflict,
            conflict.kind == .modified,
            let file = conflict.diskFile
        else { return false }
        guard document.encodingIssue == nil, file.encodingIssue == nil else {
            presentedIssue = AppModelIssue(
                title: .confirmEncoding,
                appIssue: .encodingRequiredForLocalVersion
            )
            return false
        }
        document.keepLocal(against: file)
        persistSession()
        return true
    }

    /// Adds a separate, initially clean tab containing the conflicting disk
    /// value. Neither side is modified by comparison.
    @discardableResult
    public func compareDiskVersion(for document: EditorDocument) -> EditorDocument? {
        guard
            let conflict = document.externalConflict,
            conflict.canCompareOrReload,
            let file = conflict.diskFile
        else { return nil }
        let comparison = EditorDocument(
            fileURL: nil,
            displayName: "\(document.displayName) (Disk Version)",
            text: file.content,
            savedText: file.content,
            encoding: file.encoding,
            lineEnding: file.lineEnding,
            encodingLocked: file.encodingLocked,
            encodingIssue: file.encodingIssue
        )
        appendAndSelect(comparison)
        persistSession()
        return comparison
    }

    /// Loads a hot-exit snapshot and validates every file against current disk
    /// bytes. A changed file with a draft is restored as an explicit conflict;
    /// a missing file with a draft becomes a recoverable untitled tab.
    public func restoreSession() async {
        guard !isRestoringSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        isRestoringSession = true
        defer { isRestoringSession = false }

        let session = sessionStore.loadWindowSession()
        workspaceFolders = session.folders.isEmpty
            ? session.folder.map { [$0] } ?? []
            : session.folders
        workspaceFolder = session.folder ?? workspaceFolders.first
        sessionProject = session.project
        securityScopedDocumentLeases.removeAll()
        var restored: [(sourceID: String, document: EditorDocument)] = []

        for savedDocument in session.documents {
            if let path = savedDocument.path {
                let requestedURL = URL(fileURLWithPath: path)
                let restoredLease: SecurityScopedResourceLease?
                if let restoreSecurityScopedFileAccess {
                    restoredLease = try? restoreSecurityScopedFileAccess(requestedURL)
                } else {
                    restoredLease = nil
                }
                let accessWasDenied = processRequiresSecurityScopedAccess
                    && restoreSecurityScopedFileAccess != nil
                    && restoredLease == nil
                let url = restoredLease?.url ?? requestedURL
                let hasRecoverableDraft = savedDocument.draft != nil
                    || savedDocument.formatDirty
                do {
                    if accessWasDenied {
                        throw SecurityScopedAccessError.missingBookmark(requestedURL.path)
                    }
                    let disk = try await Self.readFile(
                        at: url,
                        forcedEncoding: savedDocument.encodingLocked
                            ? savedDocument.diskEncoding : nil,
                        maximumByteCount: maximumEditableByteCount
                    )
                    if disk.isBinary || disk.isTooLarge {
                        let kind: ExternalConflict.Kind = disk.isBinary
                            ? .binary : .tooLarge
                        let preservedText = savedDocument.draft
                            ?? savedDocument.recoveryContent
                            ?? ""
                        let document = unavailableDocument(
                            from: savedDocument,
                            at: url,
                            preservedText: preservedText,
                            conflict: ExternalConflict(
                                kind: kind,
                                url: url,
                                diskFile: disk
                            )
                        )
                        restored.append((
                            savedDocument.documentID,
                            document
                        ))
                        if let restoredLease {
                            securityScopedDocumentLeases[document.id] = restoredLease
                        }
                        continue
                    }

                    let hasDraft = savedDocument.draft != nil
                    let hasFormatIntent = hasDraft || savedDocument.formatDirty
                    let diskChanged = hasRecoverableDraft
                        && (savedDocument.baseRevision == nil
                            || savedDocument.baseRevision != disk.revision)
                    // `recoveryContent` is the pre-exit text required to
                    // preserve a format-only change if the underlying file
                    // changed while the app was closed. For an unchanged
                    // file, use the fresh disk bytes just like Electron.
                    let restoredText = diskChanged
                        ? (savedDocument.draft
                            ?? savedDocument.recoveryContent
                            ?? disk.content)
                        : (savedDocument.draft ?? disk.content)
                    let initialSelection = restoredSelection(
                        for: savedDocument,
                        preferredGroup: session.layout.groups.indices.contains(
                            session.layout.activeGroup
                        ) ? session.layout.activeGroup : 0,
                        textLength: restoredText.utf16.count
                    )
                    let document = EditorDocument(
                        sessionDocumentID: savedDocument.documentID,
                        fileURL: url,
                        displayName: savedDocument.name,
                        text: restoredText,
                        savedText: disk.content,
                        encoding: hasFormatIntent
                            ? (savedDocument.encoding ?? disk.encoding)
                            : ((savedDocument.encodingLocked
                                ? savedDocument.diskEncoding : nil) ?? disk.encoding),
                        savedEncoding: savedDocument.encodingLocked
                            ? (savedDocument.diskEncoding ?? disk.encoding)
                            : disk.encoding,
                        lineEnding: hasFormatIntent
                            ? (savedDocument.eolOverride ?? savedDocument.eol ?? disk.lineEnding)
                            : disk.lineEnding,
                        savedLineEnding: disk.lineEnding,
                        eolOverride: savedDocument.eolOverride
                            ?? (savedDocument.formatDirty
                                && savedDocument.eol != nil
                                && savedDocument.eol != disk.lineEnding
                                ? savedDocument.eol : nil),
                        diskRevision: diskChanged ? savedDocument.baseRevision : disk.revision,
                        encodingLocked: (savedDocument.encodingLocked
                            && savedDocument.diskEncoding != nil)
                            || disk.encodingLocked,
                        encodingIssue: hasRecoverableDraft
                            ? (savedDocument.encodingIssue ?? disk.encodingIssue)
                            : disk.encodingIssue,
                        requiresSave: false,
                        selectionSet: initialSelection,
                        pinned: savedDocument.pinned,
                        language: savedDocument.language,
                        languageLocked: savedDocument.languageLocked,
                        bookmarks: restoredBookmarks(
                            savedDocument.bookmarks, in: restoredText
                        ),
                        externalConflict: diskChanged
                            ? ExternalConflict(kind: .modified, url: url, diskFile: disk)
                            : nil
                    )
                    restored.append((savedDocument.documentID, document))
                    if let restoredLease {
                        securityScopedDocumentLeases[document.id] = restoredLease
                    }
                } catch {
                    if hasRecoverableDraft {
                        restoredLease?.invalidate()
                        restored.append((
                            savedDocument.documentID,
                            recoveredDocument(from: savedDocument)
                        ))
                    } else {
                        let kind: ExternalConflict.Kind = Self.isMissingFileError(error)
                            ? .missing : .unreadable
                        let document = unavailableDocument(
                            from: savedDocument,
                            at: url,
                            preservedText: "",
                            conflict: ExternalConflict(
                                kind: kind,
                                url: url,
                                detail: error.localizedDescription
                            )
                        )
                        restored.append((
                            savedDocument.documentID,
                            document
                        ))
                        if let restoredLease {
                            securityScopedDocumentLeases[document.id] = restoredLease
                        }
                    }
                }
            } else {
                let document = EditorDocument(
                    sessionDocumentID: savedDocument.documentID,
                    fileURL: nil,
                    displayName: savedDocument.name,
                    text: savedDocument.draft ?? savedDocument.recoveryContent ?? "",
                    savedText: "",
                    encoding: savedDocument.encoding ?? .utf8,
                    savedEncoding: savedDocument.diskEncoding ?? .utf8,
                    lineEnding: savedDocument.eolOverride ?? savedDocument.eol ?? .lf,
                    savedLineEnding: .lf,
                    eolOverride: savedDocument.eolOverride,
                    diskRevision: nil,
                    encodingLocked: false,
                    encodingIssue: savedDocument.encodingIssue,
                    requiresSave: savedDocument.draft != nil
                        || savedDocument.formatDirty
                        || savedDocument.name.hasSuffix(" (Recovered)"),
                    selectionSet: restoredSelection(
                        for: savedDocument,
                        preferredGroup: session.layout.activeGroup,
                        textLength: (savedDocument.draft
                            ?? savedDocument.recoveryContent ?? "").utf16.count
                    ),
                    pinned: savedDocument.pinned,
                    language: savedDocument.language,
                    languageLocked: savedDocument.languageLocked,
                    bookmarks: restoredBookmarks(
                        savedDocument.bookmarks,
                        in: savedDocument.draft ?? savedDocument.recoveryContent ?? ""
                    )
                )
                restored.append((savedDocument.documentID, document))
            }
        }

        documentSubscriptions.removeAll()
        documents = restored.map(\.document)
        for document in documents { observe(document) }
        if documents.isEmpty {
            ensureDocumentExists()
            return
        }
        let restoredIDs = Set(documents.map(\.sessionDocumentID))
        paneLayout = restoredPaneLayout(
            from: session,
            retaining: restoredIDs,
            fallbackDocumentID: documents.first?.sessionDocumentID
        )
        organizePinnedTabs()
        restoreViewState(from: session)
        synchronizeBufferViewsWithLayout()
        synchronizeSelectedDocument()
    }

    /// Flushes a sparse V2 window snapshot. Clean file text is omitted; dirty
    /// text and format-only recovery content retain hot-exit safety.
    @discardableResult
    public func persistSession() -> Bool {
        guard !isTextEditingLocked else { return true }
        synchronizeAllLayoutSelections()
        return persistSession(makeWindowSession(
            documents: documents, layout: paneLayout
        ))
    }

    private func persistSession(_ session: WindowSession) -> Bool {
        do {
            try sessionWillPersist?()
        } catch {
            present(error, title: .saveSession)
            return false
        }
        do {
            try sessionStore.save(session)
        } catch {
            sessionPersistenceDidFail?()
            present(error, title: .saveSession)
            return false
        }
        do {
            try sessionDidPersist?()
            return true
        } catch {
            present(error, title: .saveSession)
            return false
        }
    }

    /// Cancels a pending debounce and synchronously flushes the latest state.
    /// Call this from the application/window termination path.
    @discardableResult
    public func flushSession() -> Bool {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        return persistSession()
    }

    /// Stages the exact post-commit snapshot without overwriting the last safe
    /// live snapshot, discarding documents, or releasing sandbox leases. The
    /// application coordinator publishes that staging transaction only after
    /// every window succeeds.
    @discardableResult
    func preflightApplicationClosePersistence(
        documentRevisions: [EditorDocument.ID: UInt64]
    ) -> Bool {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        guard validateReviewedApplicationClose(
            documentRevisions: documentRevisions
        ) else { return false }

        synchronizeAllLayoutSelections()
        // Refresh the safe generation with the latest dirty text before
        // staging a destructive post-commit projection. A later window may
        // still fail, in which case this live snapshot remains authoritative.
        guard persistSession(makeWindowSession(
            documents: documents, layout: paneLayout
        )) else { return false }

        let removedIDs = Set(documentRevisions.keys)
        let removedSessionIDs = Set(documents.compactMap { document in
            removedIDs.contains(document.id) ? document.sessionDocumentID : nil
        })
        let retainedDocuments = documents.filter { !removedIDs.contains($0.id) }
        var projectedLayout = paneLayout
        for documentID in removedSessionIDs {
            _ = projectedLayout.removeDocumentEverywhere(documentID)
        }
        if retainedDocuments.isEmpty {
            projectedLayout = PaneLayout(kind: projectedLayout.kind)
        }
        if projectedLayout.panes[projectedLayout.activePaneIndex].activeDocumentID == nil,
           let fallbackIndex = projectedLayout.panes.firstIndex(where: {
               $0.activeDocumentID != nil
           }) {
            _ = projectedLayout.focusPane(at: fallbackIndex)
        }
        let projectedSession = makeWindowSession(
            documents: retainedDocuments, layout: projectedLayout
        )
        guard let terminationSnapshotWillPersist else { return false }
        do {
            try terminationSnapshotWillPersist(projectedSession)
            return true
        } catch {
            present(error, title: .saveSession)
            return false
        }
    }

    /// Stages the standalone-window post-close projection while retaining the
    /// canonical live snapshot. Production compositions publish a durable close
    /// marker only after the caller revalidates the reviewed revisions.
    @discardableResult
    func persistApplicationCloseSnapshot(
        documentRevisions: [EditorDocument.ID: UInt64]
    ) -> Bool {
        guard validateReviewedApplicationClose(
            documentRevisions: documentRevisions
        ) else { return false }
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        synchronizeAllLayoutSelections()
        guard persistSession(makeWindowSession(
            documents: documents, layout: paneLayout
        )) else { return false }
        let removedIDs = Set(documentRevisions.keys)
        let retainedDocuments = documents.filter { !removedIDs.contains($0.id) }
        var layout = paneLayout
        for document in documents where removedIDs.contains(document.id) {
            _ = layout.removeDocumentEverywhere(document.sessionDocumentID)
        }
        if retainedDocuments.isEmpty {
            layout = PaneLayout(kind: layout.kind)
        }
        if layout.panes[layout.activePaneIndex].activeDocumentID == nil,
           let fallbackIndex = layout.panes.firstIndex(where: {
               $0.activeDocumentID != nil
           }) {
            _ = layout.focusPane(at: fallbackIndex)
        }
        do {
            try applicationCloseSnapshotWillPersist?()
            guard validateReviewedApplicationClose(
                documentRevisions: documentRevisions
            ) else { return false }
            let projected = makeWindowSession(
                documents: retainedDocuments, layout: layout
            )
            if let applicationCloseSnapshotStager {
                try applicationCloseSnapshotStager(projected)
            } else {
                // Compatibility for isolated model tests and embedders without
                // a WindowSessionComposition. Production always injects the
                // crash-recoverable staging transaction.
                try sessionStore.save(projected)
            }
            return true
        } catch {
            present(error, title: .saveSession)
            return false
        }
    }

    /// Publishes the already-staged standalone close snapshot. After this
    /// returns true, startup recovery owns materialization if the process exits
    /// before AppKit completes the close.
    func commitApplicationCloseSnapshot() -> Bool {
        guard let applicationCloseSnapshotCommitter else { return true }
        do {
            try applicationCloseSnapshotCommitter()
            return true
        } catch {
            present(error, title: .saveSession)
            return false
        }
    }

    func abortApplicationCloseSnapshot() {
        applicationCloseSnapshotAborter?()
    }

    /// Releases sandbox extensions retained for this window's open files.
    /// Call only after the final close/termination snapshot has been written.
    func releaseAllSecurityScopedAccess() {
        securityScopedDocumentLeases.removeAll()
    }

    private struct SaveSnapshot: Sendable {
        let text: String
        let encoding: TextEncoding
        let lineEnding: LineEnding
        let eolOverride: LineEnding?
        let expectedRevision: String?
        let originalURL: URL?
    }

    private enum WriteExpectation: Sendable {
        case documentRevision(String?)
        case currentDestination
    }

    private func performSave(
        _ document: EditorDocument,
        to destination: URL,
        isSaveAs: Bool,
        resolvedLineEnding: LineEnding? = nil
    ) async -> DocumentSaveOutcome {
        // Editing locks also freeze save initiation. An already-running save is
        // observed by Git preflight through `isSaving`; a save requested after
        // Git or termination acquired an owner must never race its disk write.
        guard !isTextEditingLocked, !document.isEditingLocked,
              contains(document), !document.isSaving else {
            return .failed
        }
        guard destination.isFileURL else {
            presentedIssue = AppModelIssue(
                title: .saveFile, appIssue: .destinationMustBeLocal
            )
            return .failed
        }
        if !isSaveAs, document.externalConflict != nil {
            presentedIssue = AppModelIssue(
                title: .resolveExternalChange,
                appIssue: .externalChangeMustBeResolved
            )
            return .failed
        }
        if document.encodingIssue != nil {
            if !isSaveAs || document.fileURL.map({ sameFile($0, destination) }) == true {
                presentedIssue = AppModelIssue(
                    title: .confirmEncoding, appIssue: .encodingRequiredForSave
                )
                return .failed
            }
        }

        let snapshot = SaveSnapshot(
            text: document.text,
            encoding: document.encoding,
            lineEnding: resolvedLineEnding ?? document.effectiveLineEnding,
            eolOverride: document.eolOverride,
            expectedRevision: document.diskRevision,
            originalURL: document.fileURL
        )
        let sameAsOriginal = snapshot.originalURL.map { sameFile($0, destination) } == true
        let expectation: WriteExpectation = (!isSaveAs || sameAsOriginal)
            ? .documentRevision(snapshot.expectedRevision)
            : .currentDestination

        document.setSaving(true)
        defer { document.setSaving(false) }
        do {
            let result = try await Self.write(
                snapshot, to: destination, expectation: expectation,
                atomicWrite: atomicWrite
            )
            if !result.durabilityConfirmed {
                let retainedArtifact = result.recoveryArtifact
                    ?? fileSaveNotice.flatMap { notice in
                        notice.documentID == document.id
                            ? notice.recoveryArtifact : nil
                    }
                document.recordDurabilityUnconfirmedSave(
                    to: destination, revision: result.revision
                )
                let notice = FileSaveNotice.durabilityUnconfirmed(
                    documentID: document.id, displayName: document.displayName,
                    recoveryArtifact: retainedArtifact
                )
                fileSaveNotice = notice
                persistSession()
                return .durabilityUnconfirmed(notice)
            }
            document.recordSuccessfulSave(
                to: destination,
                text: snapshot.text,
                encoding: snapshot.encoding,
                lineEnding: snapshot.lineEnding,
                startedEOLOverride: snapshot.eolOverride,
                revision: result.revision
            )
            if !result.cleanupCompleted {
                let notice = FileSaveNotice.cleanupIncomplete(
                    documentID: document.id, displayName: document.displayName,
                    recoveryArtifact: result.recoveryArtifact
                )
                fileSaveNotice = notice
                persistSession()
                return .completeWithCleanupWarning(notice)
            }
            if fileSaveNotice?.documentID == document.id {
                if let retainedArtifact = fileSaveNotice?.recoveryArtifact {
                    let notice = FileSaveNotice.cleanupIncomplete(
                        documentID: document.id,
                        displayName: document.displayName,
                        recoveryArtifact: retainedArtifact
                    )
                    fileSaveNotice = notice
                    persistSession()
                    return .completeWithCleanupWarning(notice)
                }
                fileSaveNotice = nil
            }
            persistSession()
            return .complete
        } catch let failure as FileWriteFailure {
            switch failure {
            case let .conflict(actualRevision):
                await attachSaveConflict(
                    to: document,
                    at: destination,
                    actualRevision: actualRevision,
                    appliesToOriginal: !isSaveAs || sameAsOriginal
                )
            case .hardLinked:
                if !isSaveAs || sameAsOriginal {
                    document.setExternalConflict(ExternalConflict(
                        kind: .hardLinked,
                        url: destination
                    ))
                }
                presentedIssue = AppModelIssue(
                    title: .saveFile, appIssue: .hardLinkedDestination
                )
            case .invalidExpectedRevision:
                present(failure, title: .saveFile, context: document.displayName)
            }
            persistSession()
            return .failed
        } catch {
            present(error, title: .saveFile, context: document.displayName)
            return .failed
        }
    }

    private func attachSaveConflict(
        to document: EditorDocument,
        at url: URL,
        actualRevision: String?,
        appliesToOriginal: Bool
    ) async {
        guard appliesToOriginal else {
            presentedIssue = AppModelIssue(
                title: .saveDestinationChanged, appIssue: .destinationChanged
            )
            return
        }
        guard actualRevision != nil else {
            document.setExternalConflict(ExternalConflict(kind: .missing, url: url))
            return
        }
        do {
            let disk = try await Self.readFile(
                at: url,
                forcedEncoding: document.encodingLocked ? document.savedEncoding : nil,
                maximumByteCount: maximumEditableByteCount
            )
            let kind: ExternalConflict.Kind = disk.isBinary
                ? .binary
                : (disk.isTooLarge ? .tooLarge : .modified)
            document.setExternalConflict(ExternalConflict(
                kind: kind,
                url: url,
                diskFile: disk,
                actualRevision: actualRevision
            ))
        } catch {
            document.setExternalConflict(ExternalConflict(
                kind: .unreadable,
                url: url,
                actualRevision: actualRevision,
                detail: error.localizedDescription
            ))
        }
    }

    private func validateEditable(_ file: OpenedTextFile) -> Bool {
        if file.isBinary {
            presentedIssue = AppModelIssue(
                title: .binaryFile,
                appIssue: .binaryFile(name: file.url.lastPathComponent)
            )
            return false
        }
        if file.isTooLarge {
            let megabytes = max(1, maximumEditableByteCount / (1_024 * 1_024))
            presentedIssue = AppModelIssue(
                title: .fileTooLarge,
                appIssue: .fileTooLarge(
                    name: file.url.lastPathComponent, maximumMegabytes: megabytes
                )
            )
            return false
        }
        return true
    }

    private func recoveredDocument(
        from saved: WindowSessionDocument
    ) -> EditorDocument {
        let text = saved.draft ?? saved.recoveryContent ?? ""
        return EditorDocument(
            sessionDocumentID: saved.documentID,
            fileURL: nil,
            displayName: saved.name.hasSuffix(" (Recovered)")
                ? saved.name
                : "\(saved.name) (Recovered)",
            text: text,
            savedText: "",
            encoding: saved.encoding ?? .utf8,
            savedEncoding: saved.diskEncoding ?? .utf8,
            lineEnding: saved.eolOverride ?? saved.eol ?? .lf,
            savedLineEnding: .lf,
            eolOverride: saved.eolOverride,
            encodingLocked: false,
            encodingIssue: saved.encodingIssue,
            requiresSave: true,
            selectionSet: restoredSelection(
                for: saved,
                preferredGroup: saved.views.first?.group ?? 0,
                textLength: text.utf16.count
            ),
            pinned: saved.pinned,
            language: saved.language,
            languageLocked: saved.languageLocked,
            bookmarks: restoredBookmarks(saved.bookmarks, in: text)
        )
    }

    /// Retains a clean file tab when its bytes cannot currently be opened.
    /// The explicit conflict makes the placeholder dirty for close-review and
    /// keeps it in the next sparse session instead of silently forgetting it.
    private func unavailableDocument(
        from saved: WindowSessionDocument,
        at url: URL,
        preservedText: String,
        conflict: ExternalConflict
    ) -> EditorDocument {
        return EditorDocument(
            sessionDocumentID: saved.documentID,
            fileURL: url,
            displayName: saved.name,
            text: preservedText,
            savedText: preservedText,
            encoding: saved.encoding ?? saved.diskEncoding ?? .utf8,
            savedEncoding: saved.diskEncoding ?? saved.encoding ?? .utf8,
            lineEnding: saved.eolOverride ?? saved.eol ?? .lf,
            savedLineEnding: saved.eol ?? .lf,
            eolOverride: saved.eolOverride,
            diskRevision: saved.baseRevision,
            encodingLocked: saved.encodingLocked,
            encodingIssue: saved.encodingIssue,
            requiresSave: false,
            selectionSet: restoredSelection(
                for: saved,
                preferredGroup: saved.views.first?.group ?? 0,
                textLength: preservedText.utf16.count
            ),
            pinned: saved.pinned,
            language: saved.language,
            languageLocked: saved.languageLocked,
            bookmarks: restoredBookmarks(saved.bookmarks, in: preservedText),
            externalConflict: conflict
        )
    }

    private func restoredSelection(
        for document: WindowSessionDocument,
        preferredGroup: Int,
        textLength: Int
    ) -> SelectionSet {
        let view = document.views.first { $0.group == preferredGroup }
            ?? document.views.first
        guard let view, !view.selections.isEmpty else { return .cursor(at: 0) }
        let ranges = view.selections.map {
            DirectedSelection(anchor: $0.anchor, head: $0.head)
                .clamped(toUTF16Length: textLength)
        }
        let mainIndex = ranges.indices.contains(view.mainIndex) ? view.mainIndex : 0
        return SelectionSet(ranges: ranges, mainIndex: mainIndex)
    }

    /// Session bookmarks are 1-based physical line numbers. A file may have
    /// changed while the app was closed, so clamp positions to the exact text
    /// shown by this document. Preserve the stored order for Electron-compatible
    /// next/previous traversal while removing duplicate resulting locations.
    private func restoredBookmarks(_ bookmarks: [Int], in text: String) -> [Int] {
        let lineCount = 1 + text.utf16.reduce(into: 0) { count, unit in
            if unit == 0x0A { count += 1 }
        }
        var seen = Set<Int>()
        return bookmarks.compactMap { line in
            let clamped = min(lineCount, max(1, line))
            return seen.insert(clamped).inserted ? clamped : nil
        }
    }

    private func restoredPaneLayout(
        from session: WindowSession,
        retaining documentIDs: Set<String>,
        fallbackDocumentID: String?
    ) -> PaneLayout {
        var groups = session.layout.groups.map { group -> WindowSessionGroup in
            let ids = group.documentIDs.filter { documentIDs.contains($0) }
            let active = group.activeDocumentID.flatMap { ids.contains($0) ? $0 : nil }
                ?? ids.first
            return WindowSessionGroup(documentIDs: ids, activeDocumentID: active)
        }
        if let fallbackDocumentID {
            for index in groups.indices where groups[index].documentIDs.isEmpty {
                groups[index] = WindowSessionGroup(
                    documentIDs: [fallbackDocumentID],
                    activeDocumentID: fallbackDocumentID
                )
            }
        }
        let activeGroup = groups.indices.contains(session.layout.activeGroup)
            ? session.layout.activeGroup : 0
        let layout = WindowSessionLayout(
            kind: session.layout.kind,
            activeGroup: activeGroup,
            groups: groups
        )
        var selectionsByGroup: [Int: [String: SelectionSet]] = [:]
        for saved in session.documents where documentIDs.contains(saved.documentID) {
            guard let liveDocument = document(forSessionID: saved.documentID) else { continue }
            for view in saved.views where groups.indices.contains(view.group)
            && groups[view.group].documentIDs.contains(saved.documentID) {
                selectionsByGroup[view.group, default: [:]][saved.documentID] =
                    restoredSelection(
                        for: saved,
                        preferredGroup: view.group,
                        textLength: liveDocument.buffer.utf16Length
                    )
            }
        }
        return PaneLayout(
            windowSessionLayout: layout,
            selectionsByGroup: selectionsByGroup
        )
    }

    private func restoreViewState(from session: WindowSession) {
        scrollPositions.removeAll(keepingCapacity: true)
        for saved in session.documents {
            for view in saved.views where paneLayout.panes.indices.contains(view.group) {
                let pane = paneLayout.panes[view.group]
                guard pane.contains(saved.documentID) else { continue }
                scrollPositions[PaneDocumentKey(
                    viewID: pane.viewID,
                    documentID: saved.documentID
                )] = EditorPaneScrollPosition(x: view.scrollX, y: view.scrollY)
            }
        }
    }

    private func makeWindowSession(
        documents: [EditorDocument],
        layout: PaneLayout
    ) -> WindowSession {
        let activeSessionID = layout.panes[layout.activePaneIndex].activeDocumentID
        return WindowSession(
            documents: documents.map {
                makeWindowSessionDocument($0, layout: layout)
            },
            activeDocumentID: activeSessionID,
            folder: workspaceFolder,
            folders: workspaceFolders,
            project: sessionProject,
            layout: layout.toWindowSessionLayout()
        )
    }

    private func makeWindowSessionDocument(
        _ document: EditorDocument,
        layout: PaneLayout
    ) -> WindowSessionDocument {
        let contentDirty = document.text != document.savedText
        let formatDirty = document.hasFormatChanges
        let keepDraft = contentDirty || document.externalConflict != nil
            || document.requiresSave || (document.isUntitled && !document.text.isEmpty)
        let recoveryContent = formatDirty && !keepDraft && !document.isUntitled
            ? document.text : nil
        let views = layout.panes.indices.compactMap { paneIndex -> WindowSessionViewState? in
            let pane = layout.panes[paneIndex]
            guard pane.contains(document.sessionDocumentID) else { return nil }
            let selection = (document.selectionSet(for: pane.viewID)
                ?? pane.selection(for: document.sessionDocumentID)
                ?? .cursor(at: 0))
                .clamped(toUTF16Length: min(document.buffer.utf16Length, 200_000_000))
            let scroll = scrollPositions[PaneDocumentKey(
                viewID: pane.viewID,
                documentID: document.sessionDocumentID
            )] ?? .zero
            return WindowSessionViewState(
                group: paneIndex,
                selections: selection.ranges.map {
                    WindowSessionSelection(anchor: $0.anchor, head: $0.head)
                },
                mainIndex: selection.mainIndex,
                scrollX: scroll.x,
                scrollY: scroll.y
            )
        }
        return WindowSessionDocument(
            documentID: document.sessionDocumentID,
            path: document.fileURL?.path,
            name: document.displayName,
            pinned: document.pinned,
            language: document.language,
            languageLocked: document.languageLocked,
            draft: keepDraft ? document.text : nil,
            recoveryContent: recoveryContent,
            formatDirty: formatDirty,
            baseRevision: (contentDirty || formatDirty || document.externalConflict != nil)
                ? document.diskRevision : nil,
            encoding: document.encoding,
            diskEncoding: document.savedEncoding,
            encodingLocked: document.encodingLocked,
            encodingIssue: document.encodingIssue,
            eol: document.lineEnding,
            eolOverride: document.eolOverride,
            bookmarks: document.bookmarks,
            views: views
        )
    }

    private func synchronizeBufferViewsWithLayout() {
        for document in documents {
            let liveViewIDs = Set(paneLayout.panes.compactMap { pane in
                pane.contains(document.sessionDocumentID) ? pane.viewID : nil
            })
            for viewID in document.buffer.viewSelections.keys
            where viewID != .default && !liveViewIDs.contains(viewID) {
                document.removeView(viewID)
            }
            for pane in paneLayout.panes where pane.contains(document.sessionDocumentID) {
                let selection = pane.selection(for: document.sessionDocumentID)
                    ?? .cursor(at: 0)
                let clamped = selection.clamped(
                    toUTF16Length: document.buffer.utf16Length
                )
                if document.selectionSet(for: pane.viewID) == nil {
                    try? document.registerView(
                        pane.viewID,
                        selection: clamped
                    )
                } else {
                    try? document.buffer.setSelection(clamped, for: pane.viewID)
                }
            }
        }
    }

    private func synchronizeLayoutSelections(for document: EditorDocument) {
        var layout = paneLayout
        for index in layout.panes.indices {
            let pane = layout.panes[index]
            guard pane.contains(document.sessionDocumentID),
                  let selection = document.selectionSet(for: pane.viewID) else { continue }
            _ = layout.setSelection(
                selection,
                forDocumentID: document.sessionDocumentID,
                inPaneAt: index
            )
        }
        if layout != paneLayout { paneLayout = layout }
    }

    private func synchronizeAllLayoutSelections() {
        for document in documents { synchronizeLayoutSelections(for: document) }
    }

    private func synchronizeSelectedDocument() {
        if let active = activeDocument(inPaneAt: paneLayout.activePaneIndex) {
            selectedDocumentID = active.id
            if encodingNotice?.documentID != active.id { encodingNotice = nil }
            return
        }
        guard let fallbackIndex = paneLayout.panes.firstIndex(where: {
            $0.activeDocumentID != nil
        }) else {
            selectedDocumentID = nil
            encodingNotice = nil
            return
        }
        var layout = paneLayout
        _ = layout.focusPane(at: fallbackIndex)
        paneLayout = layout
        selectedDocumentID = activeDocument(inPaneAt: fallbackIndex)?.id
        if encodingNotice?.documentID != selectedDocumentID { encodingNotice = nil }
    }

    private func pruneScrollPositions() {
        let liveKeys = Set(paneLayout.panes.flatMap { pane in
            pane.documentIDs.map {
                PaneDocumentKey(viewID: pane.viewID, documentID: $0)
            }
        })
        scrollPositions = scrollPositions.filter { liveKeys.contains($0.key) }
    }

    private func appendAndSelect(_ document: EditorDocument) {
        documents.append(document)
        observe(document)
        var layout = paneLayout
        _ = layout.addDocument(
            document.sessionDocumentID,
            toPaneAt: layout.activePaneIndex,
            selection: document.selectionSet(for: .default) ?? .cursor(at: 0),
            activate: true
        )
        layout.organizePinnedTabs(pinnedSessionDocumentIDs)
        paneLayout = layout
        synchronizeBufferViewsWithLayout()
        synchronizeSelectedDocument()
    }

    private var pinnedSessionDocumentIDs: Set<String> {
        Set(documents.lazy.filter(\.pinned).map(\.sessionDocumentID))
    }

    private func organizePinnedTabs() {
        var layout = paneLayout
        layout.organizePinnedTabs(pinnedSessionDocumentIDs)
        if layout != paneLayout { paneLayout = layout }
    }

    private func observe(_ document: EditorDocument) {
        documentSubscriptions[document.id] = document.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.scheduleSessionPersistence()
            }
        }
    }

    private func scheduleSessionPersistence() {
        guard !isRestoringSession, !isTextEditingLocked else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard !self.isTextEditingLocked else { return }
            self.sessionSaveTask = nil
            _ = self.persistSession()
        }
    }

    private func removeDocument(
        _ document: EditorDocument,
        rememberingClosed: Bool
    ) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        if rememberingClosed { rememberClosed(document) }
        var layout = paneLayout
        _ = layout.removeDocumentEverywhere(document.sessionDocumentID)
        paneLayout = layout
        documents.remove(at: index)
        documentSubscriptions[document.id] = nil
        securityScopedDocumentLeases.removeValue(forKey: document.id)?.invalidate()
        if let url = document.fileURL { securityScopedFileAccessDidEnd?(url) }
        scrollPositions = scrollPositions.filter {
            $0.key.documentID != document.sessionDocumentID
        }
        synchronizeSelectedDocument()
        ensureDocumentExists()
        persistSession()
    }

    private func rememberClosed(_ document: EditorDocument) {
        guard let url = document.fileURL else { return }
        let canonicalURL = Self.canonicalURL(url)
        recentlyClosedTabs.removeAll {
            Self.canonicalURL($0.url) == canonicalURL
        }
        if recentlyClosedTabs.count >= 100 {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - 99)
        }
        recentlyClosedTabs.append(RecentlyClosedTab(
            url: url,
            encoding: document.encodingLocked ? document.savedEncoding : nil
        ))
    }

    private func ensureDocumentExists() {
        guard documents.isEmpty else { return }
        let document = EditorDocument(untitledName: "Untitled-1")
        documents = [document]
        observe(document)
        paneLayout = PaneLayout(
            kind: paneLayout.kind,
            documentIDs: [document.sessionDocumentID],
            activeDocumentID: document.sessionDocumentID
        )
        synchronizeBufferViewsWithLayout()
        synchronizeSelectedDocument()
    }

    private func contains(_ document: EditorDocument) -> Bool {
        documents.contains { $0 === document }
    }

    private func document(at url: URL) -> EditorDocument? {
        documents.first { document in
            document.fileURL.map { sameFile($0, url) } == true
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        Self.canonicalURL(lhs) == Self.canonicalURL(rhs)
    }

    private func nextUntitledName() -> String {
        let names = Set(documents.map(\.displayName))
        var number = 1
        while names.contains("Untitled-\(number)") { number += 1 }
        return "Untitled-\(number)"
    }

    private func present(
        _ error: any Error, title: AppModelIssue.Title, context: String? = nil
    ) {
        presentedIssue = AppModelIssue(
            title: title, error: error, context: context
        )
    }

    private nonisolated static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private nonisolated static func isMissingFileError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
    }

    private nonisolated static func readFile(
        at url: URL,
        forcedEncoding: TextEncoding?,
        maximumByteCount: Int64
    ) async throws -> OpenedTextFile {
        try await Task.detached(priority: .userInitiated) {
            try TextFileCodec.read(
                from: url,
                forcedEncoding: forcedEncoding,
                maximumByteCount: maximumByteCount
            )
        }.value
    }

    private nonisolated static func write(
        _ snapshot: SaveSnapshot,
        to url: URL,
        expectation: WriteExpectation,
        atomicWrite: @escaping @Sendable (Data, URL, String?) throws -> FileWriteResult
    ) async throws -> FileWriteResult {
        try await Task.detached(priority: .userInitiated) {
            let data = try TextFileCodec.encode(
                snapshot.text,
                encoding: snapshot.encoding,
                lineEnding: snapshot.lineEnding
            )
            let expectedRevision: String?
            switch expectation {
            case let .documentRevision(revision):
                expectedRevision = revision
            case .currentDestination:
                if FileManager.default.fileExists(atPath: url.path) {
                    expectedRevision = try TextFileCodec.revision(ofFileAt: url)
                } else {
                    expectedRevision = nil
                }
            }
            return try atomicWrite(data, url, expectedRevision)
        }.value
    }
}
