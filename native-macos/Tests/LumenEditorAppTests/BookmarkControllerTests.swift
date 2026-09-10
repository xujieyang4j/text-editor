import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class BookmarkControllerTests: XCTestCase {
    @MainActor
    func testToggleUsesOneBasedUTF16LineAndStoresSortedBookmarks() {
        let fixture = Fixture(
            text: "alpha\n🙂 beta\ngamma",
            cursorUTF16Offset: "alpha\n🙂".utf16.count,
            bookmarks: [5, 1, 5]
        )

        XCTAssertTrue(fixture.controller.toggleBookmark())
        XCTAssertEqual(fixture.bookmarks, [1, 2, 5, 5])
        XCTAssertTrue(fixture.controller.toggleBookmark())
        XCTAssertEqual(fixture.bookmarks, [1, 5, 5])
    }

    @MainActor
    func testNextAndPreviousUseStrictComparisonAndCycle() async {
        let fixture = Fixture(
            text: "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight",
            cursorUTF16Offset: lineStart(5, in: "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight"),
            bookmarks: [2, 5, 8]
        )

        let next = await fixture.controller.nextBookmark()
        XCTAssertTrue(next)
        XCTAssertEqual(fixture.navigatedLines, [8])
        let previous = await fixture.controller.previousBookmark()
        XCTAssertTrue(previous)
        XCTAssertEqual(fixture.navigatedLines, [8, 2])

        fixture.cursorUTF16Offset = lineStart(8, in: fixture.text)
        let wrappedNext = await fixture.controller.nextBookmark()
        XCTAssertTrue(wrappedNext)
        XCTAssertEqual(fixture.navigatedLines.last, 2)

        fixture.cursorUTF16Offset = lineStart(2, in: fixture.text)
        let wrappedPrevious = await fixture.controller.previousBookmark()
        XCTAssertTrue(wrappedPrevious)
        XCTAssertEqual(fixture.navigatedLines.last, 8)
    }

    @MainActor
    func testSingleBookmarkOnCurrentLineStillUsesTheCycleTarget() async {
        let fixture = Fixture(text: "one\ntwo", cursorUTF16Offset: 4, bookmarks: [2])

        let next = await fixture.controller.nextBookmark()
        let previous = await fixture.controller.previousBookmark()

        XCTAssertTrue(next)
        XCTAssertTrue(previous)
        XCTAssertEqual(fixture.navigatedLines, [2, 2])
    }

    @MainActor
    func testRestoredUnsortedBookmarkOrderMatchesElectron() async {
        let fixture = Fixture(
            text: "1\n2\n3\n4\n5\n6\n7\n8",
            cursorUTF16Offset: lineStart(5, in: "1\n2\n3\n4\n5\n6\n7\n8"),
            bookmarks: [8, 2, 6]
        )

        let next = await fixture.controller.nextBookmark()
        let previous = await fixture.controller.previousBookmark()

        XCTAssertTrue(next)
        XCTAssertTrue(previous)
        XCTAssertEqual(fixture.navigatedLines, [8, 2])
    }

    @MainActor
    func testNavigationPassesTheSnapshotDocumentAndPaneAndEmptySetIsNoOp() async {
        let fixture = Fixture(
            documentID: "document-a", paneIndex: 3, text: "a\nb",
            cursorUTF16Offset: 0, bookmarks: []
        )

        let emptyNext = await fixture.controller.nextBookmark()
        let emptyPrevious = await fixture.controller.previousBookmark()
        XCTAssertFalse(emptyNext)
        XCTAssertFalse(emptyPrevious)
        XCTAssertTrue(fixture.navigationSnapshots.isEmpty)

        fixture.bookmarks = [2]
        let next = await fixture.controller.nextBookmark()
        XCTAssertTrue(next)
        XCTAssertEqual(fixture.navigationSnapshots.last?.documentID, "document-a")
        XCTAssertEqual(fixture.navigationSnapshots.last?.paneIndex, 3)
        XCTAssertEqual(fixture.navigatedLines, [2])
    }

    @MainActor
    func testUnavailableSnapshotMakesAllOperationsNoOps() async {
        let fixture = Fixture(text: "a", bookmarks: [1])
        fixture.isAvailable = false

        XCTAssertFalse(fixture.controller.toggleBookmark())
        let next = await fixture.controller.nextBookmark()
        let previous = await fixture.controller.previousBookmark()
        XCTAssertFalse(next)
        XCTAssertFalse(previous)
        XCTAssertEqual(fixture.bookmarks, [1])
        XCTAssertTrue(fixture.navigatedLines.isEmpty)
    }

    @MainActor
    func testCommandRegistrationExecutesAllThreeRoutes() async throws {
        let fixture = Fixture(text: "a\nb\nc", bookmarks: [2, 3])
        let router = CommandRouter()
        let tokens = try fixture.controller.registerCommands(on: router)

        XCTAssertEqual(tokens.map(\.commandID), BookmarkController.commandIDs)
        let context = CommandRoutingContext(hasDocument: true)
        XCTAssertEqual(router.status(for: "toggle-bookmark", context: context), .enabled)
        let toggleResult = await router.execute("toggle-bookmark", context: context)
        XCTAssertTrue(toggleResult.didExecuteSuccessfully)
        XCTAssertEqual(fixture.bookmarks, [1, 2, 3])
        let nextResult = await router.execute("next-bookmark", context: context)
        XCTAssertTrue(nextResult.didExecuteSuccessfully)
        XCTAssertEqual(fixture.navigatedLines.last, 2)
        let previousResult = await router.execute("prev-bookmark", context: context)
        XCTAssertTrue(previousResult.didExecuteSuccessfully)
        XCTAssertEqual(fixture.navigatedLines.last, 3)

        fixture.isAvailable = false
        XCTAssertEqual(
            router.status(for: "toggle-bookmark", context: context),
            .disabled(.handler(reason: "No active document"))
        )
    }

    @MainActor
    func testPartialCommandRegistrationRollsBackOwnership() throws {
        let fixture = Fixture(text: "a")
        let router = CommandRouter()
        _ = try router.register("next-bookmark") { _ in }

        XCTAssertThrowsError(try fixture.controller.registerCommands(on: router))
        let context = CommandRoutingContext(hasDocument: true)
        XCTAssertEqual(router.status(for: "toggle-bookmark", context: context), .unsupported)
        XCTAssertEqual(router.status(for: "next-bookmark", context: context), .enabled)
        XCTAssertEqual(router.status(for: "prev-bookmark", context: context), .unsupported)
    }

    @MainActor
    func testReplaceExistingRegistrationTakesOwnershipOfAllRoutes() throws {
        let fixture = Fixture(text: "a")
        let router = CommandRouter()
        let old = try router.register("next-bookmark") { _ in }

        let tokens = try fixture.controller.registerCommands(
            on: router, replaceExisting: true
        )

        XCTAssertEqual(tokens.map(\.commandID), BookmarkController.commandIDs)
        XCTAssertFalse(router.unregister(old))
    }

    @MainActor
    func testProductionAdapterUsesOnlyTheActivePaneAndPersistsBookmarks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(
            sessionURL: directory.appendingPathComponent(SessionStore.sessionFileName)
        )
        let model = AppModel(sessionStore: store)
        let document = try XCTUnwrap(model.selectedDocument)
        document.text = "first\nsecond\nthird"
        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        XCTAssertEqual(model.paneLayout.activePaneIndex, 1)
        XCTAssertTrue(model.setSelections(
            .cursor(at: lineStart(2, in: document.text)),
            for: document, inPaneAt: 1
        ))
        let leftBefore = model.selection(for: document, inPaneAt: 0)
        let controller = BookmarkController(model: model)

        XCTAssertTrue(controller.toggleBookmark())
        XCTAssertEqual(document.bookmarks, [2])
        XCTAssertTrue(model.setSelections(.cursor(at: 0), for: document, inPaneAt: 1))
        let navigated = await controller.nextBookmark()
        XCTAssertTrue(navigated)
        XCTAssertEqual(
            model.selection(for: document, inPaneAt: 1),
            .cursor(at: lineStart(2, in: document.text))
        )
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), leftBefore)

        XCTAssertTrue(model.flushSession())
        XCTAssertEqual(
            store.loadWindowSession().documents.first?.bookmarks,
            [2]
        )
    }

    @MainActor
    func testProductionAdapterClampsRestoredBookmarkPastEndToFinalLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkControllerClampTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: directory.appendingPathComponent(SessionStore.sessionFileName)
            )
        )
        let document = try XCTUnwrap(model.selectedDocument)
        document.text = "first\nsecond"
        document.bookmarks = [99]
        let controller = BookmarkController(model: model)

        let navigated = await controller.nextBookmark()
        XCTAssertTrue(navigated)
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 6))
        XCTAssertEqual(document.bookmarks, [99])
    }

}

@MainActor
private final class Fixture {
    var documentID: String
    var paneIndex: Int
    var text: String
    var cursorUTF16Offset: Int
    var bookmarks: [Int]
    var isAvailable = true
    var acceptUpdates = true
    var acceptNavigation = true
    var navigationSnapshots: [BookmarkSnapshot] = []
    var navigatedLines: [Int] = []
    lazy var controller = BookmarkController(
        snapshot: { [unowned self] in
            guard self.isAvailable else { return nil }
            return BookmarkSnapshot(
                documentID: self.documentID, paneIndex: self.paneIndex, text: self.text,
                cursorUTF16Offset: self.cursorUTF16Offset, bookmarks: self.bookmarks
            )
        },
        updateBookmarks: { [unowned self] _, updated in
            guard self.acceptUpdates else { return false }
            self.bookmarks = updated
            return true
        },
        navigate: { [unowned self] snapshot, line in
            self.navigationSnapshots.append(snapshot)
            self.navigatedLines.append(line)
            return self.acceptNavigation
        }
    )

    init(
        documentID: String = "document",
        paneIndex: Int = 0,
        text: String,
        cursorUTF16Offset: Int = 0,
        bookmarks: [Int] = []
    ) {
        self.documentID = documentID
        self.paneIndex = paneIndex
        self.text = text
        self.cursorUTF16Offset = cursorUTF16Offset
        self.bookmarks = bookmarks
    }
}

private func lineStart(_ requestedLine: Int, in text: String) -> Int {
    let units = Array(text.utf16)
    var line = 1
    var offset = 0
    while offset < units.count, line < requestedLine {
        if units[offset] == 0x0a { line += 1 }
        offset += 1
    }
    return offset
}
