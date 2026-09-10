import Combine
import Foundation
import LumenEditorCore

/// The registry a recent-item row belongs to. Keeping the kind on every row
/// prevents a file row from accidentally being routed through the broader
/// project-opening capability (or vice versa).
enum RecentItemKind: String, CaseIterable, Hashable, Sendable {
    case file
    case project
}

/// The two list presentations owned by `RecentItemsController`.
enum RecentItemsPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case files
    case projects

    var id: String { rawValue }

    var itemKind: RecentItemKind {
        switch self {
        case .files: .file
        case .projects: .project
        }
    }

    var title: String {
        switch self {
        case .files: "Open Recent File"
        case .projects: "Open Recent Project"
        }
    }

    var emptyMessage: String {
        switch self {
        case .files: "No recent files are available."
        case .projects: "No recent projects are available."
        }
    }
}

/// Immutable, presentation-safe projection of the Core persistence model.
/// `id` includes the registry kind because the same path may legitimately be
/// present in both recent-files.json and recent-projects.json.
struct RecentPresentationItem: Identifiable, Equatable, Hashable, Sendable {
    let kind: RecentItemKind
    let path: String
    let lastOpened: Double

    var id: String { "\(kind.rawValue):\(path)" }
    var url: URL { URL(fileURLWithPath: path) }
    var label: String {
        let component = url.lastPathComponent
        return component.isEmpty ? path : component
    }
    var detail: String { path }
    var lastOpenedDate: Date { Date(timeIntervalSince1970: lastOpened / 1_000) }

    init(kind: RecentItemKind, path: String, lastOpened: Double) {
        self.kind = kind
        self.path = path
        self.lastOpened = lastOpened
    }

    init(kind: RecentItemKind, item: RecentItem) {
        self.init(kind: kind, path: item.path, lastOpened: item.lastOpened)
    }
}

/// Compatibility-friendly spelling for presentation call sites that prefer
/// the model noun first.
typealias RecentItemPresentation = RecentPresentationItem
typealias RecentPresentationMode = RecentItemsPresentationMode

/// Errors are values so a SwiftUI/AppKit shell can render and recover without
/// retaining an arbitrary Error object. A failed opener includes the exact row
/// that may be removed by an explicit user action.
struct RecentItemsPresentationIssue: Identifiable, Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        case store(RecentItemsStoreError)
        case verbatim(String)
    }

    enum Title: Equatable, Sendable {
        case couldNotRemove(RecentItemKind)
        case unavailable(RecentItemKind)
        case opened(RecentItemKind)
        case couldNotOpen(RecentItemKind)
        case couldNotRecord(RecentItemKind)
    }

    enum Message: Equatable, Sendable {
        case noOpenHandler(RecentItemKind)
        case wrongKind(RecentItemKind)
        case missingFromStore(RecentItemKind)
        case couldNotOpen(RecentItemKind)
        case openedButCouldNotRecord(kind: RecentItemKind, cause: Cause)
        case openFailure(
            kind: RecentItemKind, cause: Cause?, removed: Bool,
            removalFailure: Cause?
        )
        case store(RecentItemsStoreError)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message
    let removableItem: RecentPresentationItem?

    init(
        id: UUID = UUID(),
        title: Title,
        content: Message,
        removableItem: RecentPresentationItem? = nil
    ) {
        self.id = id
        titleContent = title
        self.content = content
        self.removableItem = removableItem
    }

    var title: String { EditorLocale.enUS.localizedRecentIssueTitle(titleContent) }
    var message: String { EditorLocale.enUS.localizedRecentIssue(content) }

    var canRemoveStaleItem: Bool { removableItem != nil }
}

typealias RecentPresentationIssue = RecentItemsPresentationIssue

/// Main-actor recent-file/project coordinator. The Core store remains the only
/// persistence owner. Application capabilities are supplied as narrow async
/// callbacks, so this type never reaches into AppModel or WorkspaceController.
@MainActor
final class RecentItemsController: ObservableObject {
    typealias OpenFile = @MainActor (URL) async throws -> Bool
    typealias OpenProject = @MainActor (URL) async throws -> Bool
    typealias Now = @MainActor () -> Date

    static let commandIDs = ["open-recent-file", "open-recent-project"]

    @Published private(set) var mode: RecentItemsPresentationMode
    @Published var query: String {
        didSet {
            guard query != oldValue else { return }
            applyFilter(preservingSelectionID: selectedItem?.id)
        }
    }
    @Published private(set) var recentFiles: [RecentPresentationItem] = []
    @Published private(set) var recentProjects: [RecentPresentationItem] = []
    @Published private(set) var items: [RecentPresentationItem] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var isPresented = false
    @Published private(set) var isBusy = false
    @Published private(set) var issue: RecentItemsPresentationIssue?
    /// Changes every time a presentation is requested, allowing a view to
    /// focus its query field even when the same mode is already visible.
    @Published private(set) var focusGeneration: UInt64 = 0

    private let store: RecentItemsStore
    private let openFileAction: OpenFile?
    private let openProjectAction: OpenProject?
    private let now: Now
    private var operationGeneration: UInt64 = 0

    init(
        store: RecentItemsStore = RecentItemsStore(),
        mode: RecentItemsPresentationMode = .files,
        query: String = "",
        openFile: OpenFile? = nil,
        openProject: OpenProject? = nil,
        now: @escaping Now = { Date() }
    ) {
        self.store = store
        self.mode = mode
        self.query = query
        openFileAction = openFile
        openProjectAction = openProject
        self.now = now
        reloadSnapshots()
    }

    var selectedItem: RecentPresentationItem? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var presentationTitle: String { mode.title }
    var emptyMessage: String { mode.emptyMessage }

    /// Opens (or retargets) the presentation and synchronously refreshes the
    /// registry snapshot. Presentation changes supersede pending opens.
    func present(_ mode: RecentItemsPresentationMode, query initialQuery: String = "") {
        invalidatePendingOpen()
        self.mode = mode
        query = initialQuery
        issue = nil
        isPresented = true
        focusGeneration &+= 1
        reloadSnapshots()
    }

    func presentFiles(query: String = "") {
        present(.files, query: query)
    }

    func presentProjects(query: String = "") {
        present(.projects, query: query)
    }

    func dismiss() {
        invalidatePendingOpen()
        isPresented = false
    }

    func dismissIssue() {
        issue = nil
    }

    /// Reloads both bounded Core registries and reapplies the active filter.
    @discardableResult
    func load() -> [RecentPresentationItem] {
        invalidatePendingOpen()
        reloadSnapshots()
        return items
    }

    /// Changes the active list and reloads both registries.
    @discardableResult
    func load(_ mode: RecentItemsPresentationMode) -> [RecentPresentationItem] {
        invalidatePendingOpen()
        self.mode = mode
        reloadSnapshots()
        return items
    }

    @discardableResult
    func loadFiles() -> [RecentPresentationItem] {
        invalidatePendingOpen()
        recentFiles = store.loadRecentFiles().map {
            RecentPresentationItem(kind: .file, item: $0)
        }
        if mode == .files { applyFilter(preservingSelectionID: selectedItem?.id) }
        return recentFiles
    }

    @discardableResult
    func loadProjects() -> [RecentPresentationItem] {
        invalidatePendingOpen()
        recentProjects = store.loadRecentProjects().map {
            RecentPresentationItem(kind: .project, item: $0)
        }
        if mode == .projects { applyFilter(preservingSelectionID: selectedItem?.id) }
        return recentProjects
    }

    /// Applies a case/diacritic-insensitive name-or-path filter.
    @discardableResult
    func filter(_ query: String) -> [RecentPresentationItem] {
        if self.query == query {
            applyFilter(preservingSelectionID: selectedItem?.id)
        } else {
            self.query = query
        }
        return items
    }

    @discardableResult
    func filter(query: String) -> [RecentPresentationItem] {
        filter(query)
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex.flatMap { items.indices.contains($0) ? $0 : nil } ?? 0
        selectedIndex = ((current + delta) % items.count + items.count) % items.count
    }

    func moveSelection(_ delta: Int) {
        moveSelection(by: delta)
    }

    /// Opens the selected typed row. By default failures remain in the list so
    /// the user can retry; callers may opt into immediate stale-row removal.
    @discardableResult
    func acceptSelection(removeIfUnavailable: Bool = false) async -> Bool {
        guard let selectedItem else { return false }
        return await open(selectedItem, removeIfUnavailable: removeIfUnavailable)
    }

    @discardableResult
    func acceptItem(at index: Int, removeIfUnavailable: Bool = false) async -> Bool {
        guard items.indices.contains(index) else { return false }
        selectedIndex = index
        return await acceptSelection(removeIfUnavailable: removeIfUnavailable)
    }

    @discardableResult
    func open(
        _ item: RecentPresentationItem,
        removeIfUnavailable: Bool = false
    ) async -> Bool {
        switch item.kind {
        case .file:
            return await openFile(item, removeIfUnavailable: removeIfUnavailable)
        case .project:
            return await openProject(item, removeIfUnavailable: removeIfUnavailable)
        }
    }

    @discardableResult
    func openFile(
        _ item: RecentPresentationItem,
        removeIfUnavailable: Bool = false
    ) async -> Bool {
        guard item.kind == .file else {
            invalidatePendingOpen()
            publishWrongKind(expected: .file)
            return false
        }
        return await performOpen(
            item, kind: .file, removeIfUnavailable: removeIfUnavailable
        )
    }

    @discardableResult
    func openProject(
        _ item: RecentPresentationItem,
        removeIfUnavailable: Bool = false
    ) async -> Bool {
        guard item.kind == .project else {
            invalidatePendingOpen()
            publishWrongKind(expected: .project)
            return false
        }
        return await performOpen(
            item, kind: .project, removeIfUnavailable: removeIfUnavailable
        )
    }

    /// URL overloads are convenient for menus and restoration code, but they
    /// still re-read the store and require exact canonical membership.
    @discardableResult
    func openFile(_ url: URL, removeIfUnavailable: Bool = false) async -> Bool {
        return await openURL(url, kind: .file, removeIfUnavailable: removeIfUnavailable)
    }

    @discardableResult
    func openProject(_ url: URL, removeIfUnavailable: Bool = false) async -> Bool {
        return await openURL(url, kind: .project, removeIfUnavailable: removeIfUnavailable)
    }

    /// Removes an explicitly identified stale row. This never performs an
    /// existence check: only the opener can decide that a capability is stale.
    @discardableResult
    func removeStale(_ item: RecentPresentationItem) -> Bool {
        invalidatePendingOpen()
        do {
            let removed = try removeStoredItem(item)
            reload(kind: item.kind)
            if issue?.removableItem?.id == item.id { issue = nil }
            return removed
        } catch {
            publish(
                error,
                title: .couldNotRemove(item.kind),
                item: item
            )
            return false
        }
    }

    @discardableResult
    func removeStaleItem(_ item: RecentPresentationItem) -> Bool {
        return removeStale(item)
    }

    /// Recovery action for the currently presented open failure.
    @discardableResult
    func removeUnavailableItem() -> Bool {
        guard let item = issue?.removableItem else { return false }
        return removeStale(item)
    }

    @discardableResult
    func removeIfUnavailable() -> Bool {
        return removeUnavailableItem()
    }

    @discardableResult
    func record(_ url: URL, as kind: RecentItemKind, at date: Date? = nil) -> Bool {
        invalidatePendingOpen()
        return record(url, kind: kind, at: date ?? now(), publishingFailure: true)
    }

    @discardableResult
    func recordFile(_ url: URL, at date: Date? = nil) -> Bool {
        return record(url, as: .file, at: date)
    }

    @discardableResult
    func recordProject(_ url: URL, at date: Date? = nil) -> Bool {
        return record(url, as: .project, at: date)
    }

    @discardableResult
    func recordRecentFile(_ url: URL, at date: Date? = nil) -> Bool {
        return recordFile(url, at: date)
    }

    @discardableResult
    func recordRecentProject(_ url: URL, at date: Date? = nil) -> Bool {
        return recordProject(url, at: date)
    }

    /// Installs the two menu/catalog routes. The returned ownership tokens must
    /// be retained by the shell and unregistered when its window closes.
    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false
    ) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        do {
            tokens.append(try router.register(
                "open-recent-file",
                replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self else {
                        return .disabled(reason: "Recent items unavailable")
                    }
                    return self.openFileAction == nil
                        ? .disabled(reason: "No recent-file opener") : .enabled
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(
                        reason: "Recent items unavailable"
                    )
                }
                self.present(.files)
            })
            tokens.append(try router.register(
                "open-recent-project",
                replaceExisting: replaceExisting,
                enablement: { [weak self] _ in
                    guard let self else {
                        return .disabled(reason: "Recent items unavailable")
                    }
                    return self.openProjectAction == nil
                        ? .disabled(reason: "No recent-project opener") : .enabled
                }
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(
                        reason: "Recent items unavailable"
                    )
                }
                self.present(.projects)
            })
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    // MARK: - Private operations

    private func openURL(
        _ url: URL,
        kind: RecentItemKind,
        removeIfUnavailable: Bool
    ) async -> Bool {
        guard let path = canonicalPath(for: url) else {
            invalidatePendingOpen()
            publishMissingMembership(kind: kind)
            return false
        }
        return await performOpen(
            RecentPresentationItem(kind: kind, path: path, lastOpened: 0),
            kind: kind,
            removeIfUnavailable: removeIfUnavailable
        )
    }

    private func performOpen(
        _ requestedItem: RecentPresentationItem,
        kind: RecentItemKind,
        removeIfUnavailable: Bool
    ) async -> Bool {
        operationGeneration &+= 1
        let generation = operationGeneration
        isBusy = true
        issue = nil

        // Do not trust a previously displayed row. Re-read the registry at the
        // capability boundary and match the normalized path exactly.
        guard let path = canonicalPath(forPath: requestedItem.path),
              let stored = storedItems(for: kind).first(where: { $0.path == path }) else {
            guard generation == operationGeneration else { return false }
            isBusy = false
            reload(kind: kind)
            publishMissingMembership(kind: kind)
            return false
        }

        let item = RecentPresentationItem(kind: kind, item: stored)
        let url = URL(fileURLWithPath: stored.path).standardizedFileURL
        let action: (@MainActor (URL) async throws -> Bool)?
        switch kind {
        case .file: action = openFileAction
        case .project: action = openProjectAction
        }
        guard let action else {
            guard generation == operationGeneration else { return false }
            isBusy = false
            issue = RecentItemsPresentationIssue(
                title: .unavailable(kind),
                content: .noOpenHandler(kind)
            )
            return false
        }
        do {
            let opened = try await action(url)
            guard generation == operationGeneration else { return false }
            guard opened else {
                completeUnavailable(
                    item, removeIfUnavailable: removeIfUnavailable, error: nil
                )
                return false
            }

            // The callback has already succeeded. Recheck immediately before
            // persisting so a dismissal/new intent that arrived during the
            // callback cannot refresh a stale item's recency.
            let recordError: (any Error)?
            do {
                switch kind {
                case .file:
                    try store.recordRecentFile(url, at: now())
                case .project:
                    try store.recordRecentProject(url, at: now())
                }
                recordError = nil
            } catch {
                recordError = error
            }
            reload(kind: kind)
            isBusy = false
            isPresented = false
            if let recordError {
                issue = RecentItemsPresentationIssue(
                    title: .opened(kind),
                    content: .openedButCouldNotRecord(
                        kind: kind,
                        cause: Self.presentationCause(for: recordError)
                    )
                )
            } else {
                issue = nil
            }
            return true
        } catch {
            guard generation == operationGeneration else { return false }
            completeUnavailable(
                item, removeIfUnavailable: removeIfUnavailable, error: error
            )
            return false
        }
    }

    private func completeUnavailable(
        _ item: RecentPresentationItem,
        removeIfUnavailable: Bool,
        error: (any Error)?
    ) {
        isBusy = false
        var wasRemoved = false
        var removalError: (any Error)?
        if removeIfUnavailable {
            do {
                wasRemoved = try removeStoredItem(item)
                reload(kind: item.kind)
            } catch {
                removalError = error
            }
        }

        issue = RecentItemsPresentationIssue(
            title: .couldNotOpen(item.kind),
            content: .openFailure(
                kind: item.kind, cause: error.map(Self.presentationCause(for:)),
                removed: wasRemoved,
                removalFailure: removalError.map(Self.presentationCause(for:))
            ),
            removableItem: wasRemoved ? nil : item
        )
    }

    private func publishWrongKind(expected kind: RecentItemKind) {
        issue = RecentItemsPresentationIssue(
            title: .unavailable(kind),
            content: .wrongKind(kind)
        )
    }

    private func publishMissingMembership(kind: RecentItemKind) {
        issue = RecentItemsPresentationIssue(
            title: .unavailable(kind),
            content: .missingFromStore(kind)
        )
    }

    private func publish(
        _ error: any Error,
        title: RecentItemsPresentationIssue.Title,
        item: RecentPresentationItem? = nil
    ) {
        issue = RecentItemsPresentationIssue(
            title: title,
            content: Self.presentationMessage(for: error),
            removableItem: item
        )
    }

    private func record(
        _ url: URL,
        kind: RecentItemKind,
        at date: Date,
        publishingFailure: Bool
    ) -> Bool {
        do {
            switch kind {
            case .file:
                try store.recordRecentFile(url, at: date)
            case .project:
                try store.recordRecentProject(url, at: date)
            }
            reload(kind: kind)
            return true
        } catch {
            if publishingFailure {
                publish(error, title: .couldNotRecord(kind))
            }
            return false
        }
    }

    private static func presentationMessage(
        for error: any Error
    ) -> RecentItemsPresentationIssue.Message {
        if let error = error as? RecentItemsStoreError { return .store(error) }
        return .verbatim((error as NSError).localizedDescription)
    }

    private static func presentationCause(
        for error: any Error
    ) -> RecentItemsPresentationIssue.Cause {
        if let error = error as? RecentItemsStoreError { return .store(error) }
        return .verbatim((error as NSError).localizedDescription)
    }

    private func removeStoredItem(_ item: RecentPresentationItem) throws -> Bool {
        switch item.kind {
        case .file:
            return try store.removeRecentFile(item.path)
        case .project:
            return try store.removeRecentProject(item.path)
        }
    }

    private func storedItems(for kind: RecentItemKind) -> [RecentItem] {
        switch kind {
        case .file: store.loadRecentFiles()
        case .project: store.loadRecentProjects()
        }
    }

    private func reloadSnapshots() {
        let selectedID = selectedItem?.id
        recentFiles = store.loadRecentFiles().map {
            RecentPresentationItem(kind: .file, item: $0)
        }
        recentProjects = store.loadRecentProjects().map {
            RecentPresentationItem(kind: .project, item: $0)
        }
        applyFilter(preservingSelectionID: selectedID)
    }

    private func reload(kind: RecentItemKind) {
        let selectedID = selectedItem?.id
        switch kind {
        case .file:
            recentFiles = store.loadRecentFiles().map {
                RecentPresentationItem(kind: .file, item: $0)
            }
        case .project:
            recentProjects = store.loadRecentProjects().map {
                RecentPresentationItem(kind: .project, item: $0)
            }
        }
        if mode.itemKind == kind { applyFilter(preservingSelectionID: selectedID) }
    }

    private func applyFilter(preservingSelectionID selectedID: String?) {
        let source = mode == .files ? recentFiles : recentProjects
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            items = source
        } else {
            items = source.filter { item in
                item.label.range(
                    of: needle, options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil || item.path.range(
                    of: needle, options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = items.isEmpty ? nil : 0
        }
    }

    private func canonicalPath(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return canonicalPath(forPath: url.path)
    }

    private func canonicalPath(forPath path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0"), path.hasPrefix("/"),
              (path as NSString).isAbsolutePath else { return nil }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return storedPathIsCanonical(standardizedPath) ? standardizedPath : nil
    }

    private func storedPathIsCanonical(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.contains("\0")
            && (path as NSString).isAbsolutePath
    }

    private func noun(for kind: RecentItemKind) -> String {
        switch kind {
        case .file: "File"
        case .project: "Project"
        }
    }

    private func invalidatePendingOpen() {
        operationGeneration &+= 1
        isBusy = false
    }
}
