import Foundation
import LumenEditorCore

/// The pane-local state needed by the three bookmark commands. Bookmark line
/// numbers intentionally remain 1-based to match both Electron and the window
/// session format.
struct BookmarkSnapshot: Equatable, Sendable {
    let documentID: String
    let paneIndex: Int
    let text: String
    let cursorUTF16Offset: Int
    let bookmarks: [Int]

    init(
        documentID: String,
        paneIndex: Int,
        text: String,
        cursorUTF16Offset: Int,
        bookmarks: [Int]
    ) {
        self.documentID = documentID
        self.paneIndex = paneIndex
        self.text = text
        self.cursorUTF16Offset = cursorUTF16Offset
        self.bookmarks = bookmarks
    }

    var currentLine: Int {
        let units = text.utf16
        let offset = min(units.count, max(0, cursorUTF16Offset))
        var line = 1
        var index = units.startIndex
        for _ in 0 ..< offset {
            if units[index] == 0x0a { line += 1 }
            index = units.index(after: index)
        }
        return line
    }
}

/// Owns Electron-compatible bookmark mutation and cyclic navigation.
///
/// The controller works from immutable snapshots so every operation stays
/// bound to the document and pane that were active when it began. Production
/// wiring can route `navigate` through NavigationController to include bookmark
/// jumps in the shared back/forward history.
@MainActor
final class BookmarkController {
    typealias SnapshotProvider = @MainActor () -> BookmarkSnapshot?
    typealias BookmarkUpdater = @MainActor (BookmarkSnapshot, [Int]) -> Bool
    typealias Navigator = @MainActor (BookmarkSnapshot, Int) async -> Bool

    static let commandIDs = [
        "toggle-bookmark",
        "next-bookmark",
        "prev-bookmark"
    ]

    private let snapshotProvider: SnapshotProvider
    private let updateBookmarks: BookmarkUpdater
    private let navigate: Navigator

    init(
        snapshot: @escaping SnapshotProvider,
        updateBookmarks: @escaping BookmarkUpdater,
        navigate: @escaping Navigator
    ) {
        snapshotProvider = snapshot
        self.updateBookmarks = updateBookmarks
        self.navigate = navigate
    }

    /// Adds or removes the active 1-based line, then restores Electron's sorted
    /// storage invariant.
    @discardableResult
    func toggleBookmark() -> Bool {
        guard let snapshot = snapshotProvider() else { return false }
        let line = snapshot.currentLine
        var bookmarks = snapshot.bookmarks
        if let index = bookmarks.firstIndex(of: line) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(line)
        }
        bookmarks.sort()
        return updateBookmarks(snapshot, bookmarks)
    }

    /// Selects the first bookmark strictly after the active line, wrapping to
    /// the first bookmark when needed.
    @discardableResult
    func nextBookmark() async -> Bool {
        await moveBookmark(forward: true)
    }

    /// Selects the last bookmark strictly before the active line, wrapping to
    /// the last bookmark when needed.
    @discardableResult
    func previousBookmark() async -> Bool {
        await moveBookmark(forward: false)
    }

    /// Installs the three catalog routes. Partial registration is rolled back
    /// so a caller never retains only part of the bookmark command family.
    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false
    ) throws -> [CommandHandlerToken] {
        let available: CommandRouter.Enablement = { [weak self] _ in
            guard let self else {
                return .disabled(reason: "Bookmarks unavailable")
            }
            return self.snapshotProvider() == nil
                ? .disabled(reason: "No active document") : .enabled
        }
        var tokens: [CommandHandlerToken] = []
        do {
            tokens.append(try router.register(
                "toggle-bookmark",
                replaceExisting: replaceExisting,
                enablement: available
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Bookmarks unavailable")
                }
                guard self.toggleBookmark() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "next-bookmark",
                replaceExisting: replaceExisting,
                enablement: available
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Bookmarks unavailable")
                }
                guard await self.nextBookmark() else { throw CommandHandlerSignal.noChange }
            })
            tokens.append(try router.register(
                "prev-bookmark",
                replaceExisting: replaceExisting,
                enablement: available
            ) { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(reason: "Bookmarks unavailable")
                }
                guard await self.previousBookmark() else { throw CommandHandlerSignal.noChange }
            })
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    /// Production adapter. Passing the window's NavigationController preserves
    /// the shared history semantics; direct AppModel navigation is also useful
    /// for shells that do not expose history.
    convenience init(
        model: AppModel,
        navigation navigationController: NavigationController? = nil
    ) {
        self.init(
            snapshot: {
                let paneIndex = model.paneLayout.activePaneIndex
                guard model.paneLayout.panes.indices.contains(paneIndex),
                      let document = model.activeDocument(inPaneAt: paneIndex) else {
                    return nil
                }
                return BookmarkSnapshot(
                    documentID: document.sessionDocumentID,
                    paneIndex: paneIndex,
                    text: document.buffer.text,
                    cursorUTF16Offset: model.selection(
                        for: document, inPaneAt: paneIndex
                    ).main.head,
                    bookmarks: document.bookmarks
                )
            },
            updateBookmarks: { snapshot, bookmarks in
                guard model.paneLayout.panes.indices.contains(snapshot.paneIndex),
                      model.paneLayout.activePaneIndex == snapshot.paneIndex,
                      let document = model.activeDocument(inPaneAt: snapshot.paneIndex),
                      document.sessionDocumentID == snapshot.documentID,
                      document.buffer.text == snapshot.text,
                      document.bookmarks == snapshot.bookmarks else { return false }
                document.bookmarks = bookmarks
                return true
            },
            navigate: { snapshot, line in
                guard model.paneLayout.panes.indices.contains(snapshot.paneIndex),
                      model.paneLayout.activePaneIndex == snapshot.paneIndex,
                      let document = model.activeDocument(inPaneAt: snapshot.paneIndex),
                      document.sessionDocumentID == snapshot.documentID,
                      document.buffer.text == snapshot.text,
                      document.bookmarks == snapshot.bookmarks else { return false }
                if let navigationController {
                    return await navigationController.navigate(to: NavigationDestination(
                        target: .document(id: snapshot.documentID),
                        groupID: snapshot.paneIndex,
                        line: line,
                        column: 1
                    ))
                }
                let offset = Self.utf16OffsetForLine(line, in: document.buffer.text)
                return model.setSelections(
                    .cursor(at: offset), for: document, inPaneAt: snapshot.paneIndex
                ) || model.selection(
                    for: document, inPaneAt: snapshot.paneIndex
                ).main.head == offset
            }
        )
    }

    private func moveBookmark(forward: Bool) async -> Bool {
        guard let snapshot = snapshotProvider() else { return false }
        // Session restore preserves the stored array order, so use it exactly
        // as Electron does. A normal toggle sorts the array for future moves.
        let bookmarks = snapshot.bookmarks
        guard let first = bookmarks.first, let last = bookmarks.last else { return false }
        let current = snapshot.currentLine
        let target: Int
        if forward {
            target = bookmarks.first(where: { $0 > current }) ?? first
        } else {
            target = bookmarks.last(where: { $0 < current }) ?? last
        }
        return await navigate(snapshot, target)
    }

    private static func utf16OffsetForLine(_ requestedLine: Int, in text: String) -> Int {
        let targetLine = max(1, requestedLine)
        guard targetLine > 1 else { return 0 }
        var currentLine = 1
        var offset = 0
        var finalLineStart = 0
        for unit in text.utf16 {
            offset += 1
            guard unit == 0x0a else { continue }
            currentLine += 1
            finalLineStart = offset
            if currentLine == targetLine { return offset }
        }
        return finalLineStart
    }
}
