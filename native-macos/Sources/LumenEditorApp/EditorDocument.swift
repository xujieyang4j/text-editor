import Combine
import Foundation
import LumenEditorCore

/// A disk change that cannot be applied without an explicit user decision.
///
/// The optional snapshot is present when the new disk value could still be
/// decoded as text. Keeping the reason separate lets the UI explain why
/// compare/reload may not be available without throwing away the local draft.
public struct ExternalConflict: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case modified
        case missing
        case binary
        case tooLarge
        case hardLinked
        case unreadable
    }

    public let kind: Kind
    public let url: URL
    public let diskFile: OpenedTextFile?
    public let actualRevision: String?
    public let detail: String?

    public init(
        kind: Kind,
        url: URL,
        diskFile: OpenedTextFile? = nil,
        actualRevision: String? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.diskFile = diskFile
        self.actualRevision = actualRevision ?? diskFile?.revision
        self.detail = detail
    }

    public var canCompareOrReload: Bool {
        kind == .modified && diskFile != nil
    }
}

/// One editor tab and its last-known on-disk baseline.
///
/// Dirty state is derived rather than toggled. This is important when a save
/// is in flight: only the exact snapshot that was written becomes the new
/// baseline, so edits arriving during the write remain dirty.
@MainActor
public final class EditorDocument: ObservableObject, Identifiable {
    public nonisolated let id: UUID
    /// Stable identity persisted by the version-two window session.
    public nonisolated let sessionDocumentID: String
    public let buffer: DocumentBuffer

    @Published public private(set) var fileURL: URL?
    @Published public private(set) var displayName: String
    @Published public var encoding: TextEncoding
    @Published public var lineEnding: LineEnding
    @Published public var eolOverride: LineEnding?
    @Published public private(set) var encodingLocked: Bool
    @Published public private(set) var encodingIssue: EncodingIssue?
    @Published public var pinned: Bool
    @Published public var language: String
    @Published public var languageLocked: Bool
    @Published public var bookmarks: [Int]
    @Published public private(set) var editorConfig: ResolvedEditorConfig?
    @Published public private(set) var externalConflict: ExternalConflict?
    @Published public private(set) var isSaving = false
    @Published public private(set) var isEditingLocked = false
    private var editingLockOwners: [EditingLockOwner: Int] = [:]

    enum EditingLockOwner: Hashable {
        case termination
        case gitMutation(UUID)
        case renameMutation(UUID)
    }

    @Published public private(set) var savedText: String
    @Published public private(set) var savedEncoding: TextEncoding
    @Published public private(set) var savedLineEnding: LineEnding
    @Published public private(set) var diskRevision: String?
    @Published public private(set) var requiresSave: Bool

    public init(
        id: UUID = UUID(),
        sessionDocumentID: String = UUID().uuidString.lowercased(),
        fileURL: URL?,
        displayName: String,
        text: String,
        savedText: String,
        encoding: TextEncoding = .utf8,
        savedEncoding: TextEncoding? = nil,
        lineEnding: LineEnding = .lf,
        savedLineEnding: LineEnding? = nil,
        eolOverride: LineEnding? = nil,
        diskRevision: String? = nil,
        encodingLocked: Bool = false,
        encodingIssue: EncodingIssue? = nil,
        requiresSave: Bool = false,
        selection: SessionSelection = SessionSelection(anchor: 0, head: 0),
        selectionSet: SelectionSet? = nil,
        pinned: Bool = false,
        language: String = "Plain Text",
        languageLocked: Bool = false,
        bookmarks: [Int] = [],
        editorConfig: ResolvedEditorConfig? = nil,
        externalConflict: ExternalConflict? = nil
    ) {
        precondition(!sessionDocumentID.isEmpty, "A session document ID cannot be empty")
        self.id = id
        self.sessionDocumentID = sessionDocumentID
        self.fileURL = fileURL
        self.displayName = displayName
        let initialSelection = selectionSet
            ?? .single(anchor: selection.anchor, head: selection.head)
        self.buffer = DocumentBuffer(
            text: text,
            selection: initialSelection.clamped(toUTF16Length: text.utf16.count)
        )
        self.savedText = savedText
        self.encoding = encoding
        self.savedEncoding = savedEncoding ?? encoding
        self.lineEnding = lineEnding
        self.savedLineEnding = savedLineEnding ?? lineEnding
        self.eolOverride = eolOverride
        self.diskRevision = diskRevision
        self.encodingLocked = encodingLocked
        self.encodingIssue = encodingIssue
        self.requiresSave = requiresSave
        self.pinned = pinned
        self.language = (!languageLocked && fileURL != nil)
            ? LanguageCatalog.builtIn.detect(fileName: displayName).name
            : language
        self.languageLocked = languageLocked
        self.bookmarks = bookmarks
        self.editorConfig = editorConfig
        self.externalConflict = externalConflict
    }

    /// Compatibility access for the current single-pane UI. Transactional
    /// integrations should call `apply(_:for:)` instead.
    public var text: String {
        get { buffer.text }
        set {
            guard !isEditingLocked else { return }
            guard newValue != buffer.text else { return }
            let replacement = TextEdit(from: 0, to: buffer.utf16Length, insert: newValue)
            guard let transaction = try? TextTransaction(edits: [replacement]),
                  (try? apply(transaction, for: .default)) != nil else { return }
        }
    }

    /// Compatibility access for the legacy single-selection UI.
    public var selection: SessionSelection {
        get {
            let main = buffer.selection.main
            return SessionSelection(anchor: main.anchor, head: main.head)
        }
        set {
            let selection = SelectionSet.single(
                anchor: max(0, newValue.anchor),
                head: max(0, newValue.head)
            ).clamped(toUTF16Length: buffer.utf16Length)
            try? setSelections(selection, for: .default)
        }
    }

    public convenience init(untitledName: String) {
        self.init(
            fileURL: nil,
            displayName: untitledName,
            text: "",
            savedText: ""
        )
    }

    public convenience init(openedFile: OpenedTextFile) {
        self.init(
            fileURL: openedFile.url,
            displayName: openedFile.url.lastPathComponent,
            text: openedFile.content,
            savedText: openedFile.content,
            encoding: openedFile.encoding,
            lineEnding: openedFile.lineEnding,
            diskRevision: openedFile.revision,
            encodingLocked: openedFile.encodingLocked,
            encodingIssue: openedFile.encodingIssue,
            language: LanguageCatalog.builtIn.detect(url: openedFile.url).name
        )
    }

    public convenience init(
        openedFile: OpenedTextFile,
        sessionDocumentID: String,
        selectionSet: SelectionSet = .cursor(at: 0),
        pinned: Bool = false,
        language: String = "Plain Text",
        languageLocked: Bool = false,
        bookmarks: [Int] = []
    ) {
        self.init(
            sessionDocumentID: sessionDocumentID,
            fileURL: openedFile.url,
            displayName: openedFile.url.lastPathComponent,
            text: openedFile.content,
            savedText: openedFile.content,
            encoding: openedFile.encoding,
            lineEnding: openedFile.lineEnding,
            diskRevision: openedFile.revision,
            encodingLocked: openedFile.encodingLocked,
            encodingIssue: openedFile.encodingIssue,
            selectionSet: selectionSet,
            pinned: pinned,
            language: language,
            languageLocked: languageLocked,
            bookmarks: bookmarks
        )
    }

    public var isUntitled: Bool { fileURL == nil }

    public var hasTextChanges: Bool {
        text != savedText || requiresSave
    }

    public var hasFormatChanges: Bool {
        encoding != savedEncoding || lineEnding != savedLineEnding
    }

    public var isDirty: Bool {
        hasTextChanges || hasFormatChanges || externalConflict != nil
    }

    public var encodingStatusText: String {
        encoding.displayName + (encodingIssue == nil ? "" : " [warning]")
    }

    public var lineEndingStatusText: String { effectiveLineEnding.rawValue }

    /// Explicit document choice wins; otherwise EditorConfig is a save-time
    /// suggestion over the physical newline convention detected on disk.
    public var effectiveLineEnding: LineEnding {
        eolOverride ?? editorConfig?.endOfLine ?? lineEnding
    }

    /// Selecting a save encoding is metadata-only and deliberately does not
    /// reinterpret the current text. Reopening with an encoding is a separate
    /// destructive operation coordinated by `AppModel`.
    public func chooseEncodingForSave(_ newEncoding: TextEncoding) {
        guard !isEditingLocked else { return }
        encoding = newEncoding
        encodingLocked = true
        if encodingIssue == .uncertain {
            encodingIssue = nil
        }
    }

    public func chooseLineEndingForSave(_ newLineEnding: LineEnding) {
        guard !isEditingLocked else { return }
        lineEnding = newLineEnding
        eolOverride = newLineEnding
    }

    /// Applies an explicit syntax choice. Matching Electron semantics, Plain
    /// Text means "return to automatic detection" while any other language
    /// remains locked across tab changes, renames, saves, and session restore.
    @discardableResult
    func chooseLanguage(
        _ requestedName: String,
        catalog: LanguageCatalog = .builtIn
    ) -> Bool {
        guard !isEditingLocked else { return false }
        guard let selected = catalog.language(named: requestedName) else { return false }
        let locked = !selected.isPlainText
        if language != selected.name { language = selected.name }
        if languageLocked != locked { languageLocked = locked }
        return true
    }

    /// Reconciles an unlocked document with its current filename. A locked
    /// language is never overwritten, including when Save As changes suffix.
    @discardableResult
    func refreshAutomaticLanguage(
        using catalog: LanguageCatalog = .builtIn
    ) -> Bool {
        guard !languageLocked else { return false }
        let detected = catalog.detect(fileName: displayName).name
        guard detected != language else { return false }
        language = detected
        return true
    }

    public func selectionSet(for viewID: EditorViewID = .default) -> SelectionSet? {
        buffer.selection(for: viewID)
    }

    public func registerView(
        _ viewID: EditorViewID,
        selection: SelectionSet = .cursor(at: 0)
    ) throws {
        try buffer.registerView(
            viewID,
            selection: selection.clamped(toUTF16Length: buffer.utf16Length)
        )
    }

    public func removeView(_ viewID: EditorViewID) {
        buffer.removeView(viewID)
    }

    @discardableResult
    public func setSelections(
        _ selections: SelectionSet,
        for viewID: EditorViewID = .default
    ) throws -> Bool {
        let before = buffer.selection(for: viewID)
        try buffer.setSelection(selections, for: viewID)
        guard before != selections else { return false }
        objectWillChange.send()
        return true
    }

    @discardableResult
    public func apply(
        _ transaction: TextTransaction,
        for viewID: EditorViewID = .default
    ) throws -> Bool {
        guard !isEditingLocked else { return false }
        let beforeRevision = buffer.revision
        let beforeSelection = buffer.selection(for: viewID)
        _ = try buffer.apply(transaction, for: viewID)
        let changed = buffer.revision != beforeRevision
            || buffer.selection(for: viewID) != beforeSelection
        if changed { objectWillChange.send() }
        return changed
    }

    @discardableResult
    public func applyReplacingUTF16Range(
        _ range: NSRange,
        replacement: String,
        viewID: EditorViewID = .default,
        selectionsAfter: SelectionSet? = nil
    ) throws -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0, range.length >= 0,
              range.length <= Int.max - range.location else {
            throw EditorTransactionError.invalidEditRange(
                TextEdit(from: range.location, to: range.location, insert: replacement)
            )
        }
        let transaction = try TextTransaction(
            edits: [TextEdit(
                from: range.location,
                to: range.location + range.length,
                insert: replacement
            )],
            selection: selectionsAfter
        )
        return try apply(transaction, for: viewID)
    }

    @discardableResult
    public func undo(for viewID: EditorViewID = .default) -> Bool {
        guard !isEditingLocked else { return false }
        guard buffer.canUndo(for: viewID) else { return false }
        let changed = buffer.undo(for: viewID)
        if changed { objectWillChange.send() }
        return changed
    }

    @discardableResult
    public func redo(for viewID: EditorViewID = .default) -> Bool {
        guard !isEditingLocked else { return false }
        guard buffer.canRedo(for: viewID) else { return false }
        let changed = buffer.redo(for: viewID)
        if changed { objectWillChange.send() }
        return changed
    }

    func setSaving(_ saving: Bool) {
        isSaving = saving
    }

    func setExternalConflict(_ conflict: ExternalConflict?) {
        externalConflict = conflict
    }

    func setEditorConfig(_ config: ResolvedEditorConfig?) {
        editorConfig = config
    }

    /// Public adapter entry point for independently-owned workspace/config
    /// coordinators. Applying a suggestion intentionally changes no dirty
    /// baseline and never mutates text.
    public func applyEditorConfig(_ config: ResolvedEditorConfig?) {
        setEditorConfig(config)
    }

    /// Rebinds an open document after a capability-scoped workspace rename or
    /// move. The text/baseline remain unchanged because the filesystem
    /// operation moved the same inode rather than rewriting its bytes.
    func relocate(to url: URL) {
        fileURL = url.standardizedFileURL
        displayName = url.lastPathComponent
        _ = refreshAutomaticLanguage()
        externalConflict = nil
        editorConfig = nil
    }

    /// Replace all editor and baseline values with a freshly read disk file.
    func replaceWithDiskFile(_ file: OpenedTextFile) {
        guard !isEditingLocked else { return }
        replaceWithDiskFileValues(file)
    }

    func replaceWithDiskFile(_ file: OpenedTextFile, gitMutationID: UUID) -> Bool {
        // A termination review may layer its own lock over the Git transaction.
        // Possession of this transaction's owner token authorizes only this
        // disk reconciliation; releasing it never releases another owner.
        guard editingLockOwners[.gitMutation(gitMutationID), default: 0] > 0 else {
            return false
        }
        replaceWithDiskFileValues(file)
        return true
    }

    private func replaceWithDiskFileValues(_ file: OpenedTextFile) {
        let selections = buffer.viewSelections.mapValues {
            $0.clamped(toUTF16Length: file.content.utf16.count)
        }
        try? buffer.reset(text: file.content, viewSelections: selections)
        fileURL = file.url
        displayName = file.url.lastPathComponent
        _ = refreshAutomaticLanguage()
        savedText = file.content
        encoding = file.encoding
        savedEncoding = file.encoding
        lineEnding = file.lineEnding
        savedLineEnding = file.lineEnding
        eolOverride = nil
        diskRevision = file.revision
        encodingLocked = file.encodingLocked
        encodingIssue = file.encodingIssue
        requiresSave = false
        externalConflict = nil
        editorConfig = nil
    }

    /// Acknowledge a newer disk value while preserving the local editor value.
    /// The next normal save may then safely use the acknowledged revision.
    func keepLocal(against file: OpenedTextFile) {
        guard !isEditingLocked else { return }
        savedText = file.content
        savedEncoding = file.encoding
        savedLineEnding = file.lineEnding
        diskRevision = file.revision
        encodingLocked = file.encodingLocked
        encodingIssue = file.encodingIssue
        requiresSave = false
        externalConflict = nil
    }

    /// Commit exactly the values captured at the start of a successful save.
    func recordSuccessfulSave(
        to url: URL,
        text savedText: String,
        encoding savedEncoding: TextEncoding,
        lineEnding savedLineEnding: LineEnding,
        startedEOLOverride: LineEnding?,
        revision: String
    ) {
        fileURL = url
        displayName = url.lastPathComponent
        _ = refreshAutomaticLanguage()
        self.savedText = savedText
        self.savedEncoding = savedEncoding
        self.savedLineEnding = savedLineEnding
        // Clear only the explicit line-ending choice that this write
        // consumed. A newer choice made while the asynchronous save was in
        // flight must remain pending and keep the document dirty.
        if eolOverride == startedEOLOverride {
            lineEnding = savedLineEnding
        }
        diskRevision = revision
        encodingLocked = savedEncoding.needsExplicitRead
        encodingIssue = nil
        requiresSave = false
        externalConflict = nil
    }

    /// Records the bytes currently observed at the destination without
    /// advancing the clean baseline. This is used when the atomic writer
    /// installed the requested bytes but could not confirm the parent
    /// directory fsync. Keeping `requiresSave` set prevents close/quit from
    /// treating the document as safely persisted; the new disk revision lets
    /// a retry verify and confirm the same bytes without a false conflict.
    func recordDurabilityUnconfirmedSave(to url: URL, revision: String) {
        fileURL = url
        displayName = url.lastPathComponent
        _ = refreshAutomaticLanguage()
        diskRevision = revision
        encodingLocked = encoding.needsExplicitRead
        encodingIssue = nil
        requiresSave = true
        externalConflict = nil
    }

    func markRecovered(name: String? = nil) {
        guard !isEditingLocked else { return }
        fileURL = nil
        if let name {
            displayName = name
        }
        savedText = ""
        savedEncoding = encoding
        savedLineEnding = lineEnding
        diskRevision = nil
        encodingLocked = false
        encodingIssue = nil
        requiresSave = true
        externalConflict = nil
        editorConfig = nil
    }

    /// Freezes mutations while a window/application close is being reviewed.
    /// The model may reverse this lock if the coordinated close is cancelled;
    /// after commit it deliberately keeps the lock for the document lifetime.
    func lockEditingForTermination() {
        guard editingLockOwners[.termination] == nil else { return }
        acquireEditingLock(.termination)
    }

    /// Reopens this document when a prepared close is cancelled before its
    /// irreversible commit point.
    func unlockEditingAfterTerminationCancellation() {
        releaseEditingLock(.termination)
    }

    func lockEditingForGitMutation(_ id: UUID) {
        acquireEditingLock(.gitMutation(id))
    }

    func unlockEditingAfterGitMutation(_ id: UUID) {
        releaseEditingLock(.gitMutation(id))
    }

    func lockEditingForRenameMutation(_ id: UUID) {
        acquireEditingLock(.renameMutation(id))
    }

    func unlockEditingAfterRenameMutation(_ id: UUID) {
        releaseEditingLock(.renameMutation(id))
    }

    func hasRenameEditingLock(_ id: UUID) -> Bool {
        editingLockOwners[.renameMutation(id), default: 0] > 0
    }

    func replaceWithDiskFile(_ file: OpenedTextFile, renameMutationID: UUID) -> Bool {
        guard hasRenameEditingLock(renameMutationID) else {
            return false
        }
        replaceWithDiskFileValues(file)
        return true
    }

    private func acquireEditingLock(_ owner: EditingLockOwner) {
        editingLockOwners[owner, default: 0] += 1
        isEditingLocked = !editingLockOwners.isEmpty
    }

    private func releaseEditingLock(_ owner: EditingLockOwner) {
        guard let count = editingLockOwners[owner] else { return }
        if count > 1 {
            editingLockOwners[owner] = count - 1
        } else {
            editingLockOwners[owner] = nil
        }
        isEditingLocked = !editingLockOwners.isEmpty
    }

}
