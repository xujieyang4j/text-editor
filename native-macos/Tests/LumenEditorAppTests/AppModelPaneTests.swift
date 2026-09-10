import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class AppModelPaneTests: XCTestCase {
    @MainActor
    func testTwoPanesShareOneBufferWithIndependentSelections() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let document = try XCTUnwrap(model.selectedDocument)
        document.text = "hello"

        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        XCTAssertEqual(model.paneLayout.kind, .columns2)
        XCTAssertEqual(model.referenceCount(for: document), 2)
        XCTAssertTrue(model.setSelections(
            .cursor(at: 1),
            for: document,
            inPaneAt: 0
        ))
        XCTAssertTrue(model.setSelections(
            .cursor(at: 4),
            for: document,
            inPaneAt: 1
        ))

        XCTAssertTrue(model.applyTextChange(
            document: document,
            inPaneAt: 0,
            range: NSRange(location: 1, length: 2),
            replacement: "ey",
            selectedRanges: .cursor(at: 3)
        ))

        XCTAssertEqual(document.text, "heylo")
        XCTAssertTrue(model.activeDocument(inPaneAt: 0) === document)
        XCTAssertTrue(model.activeDocument(inPaneAt: 1) === document)
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 3))
        XCTAssertEqual(model.selection(for: document, inPaneAt: 1), .cursor(at: 4))
        XCTAssertTrue(model.undo(document: document, inPaneAt: 0))
        XCTAssertEqual(document.text, "hello")
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 1))
        XCTAssertEqual(model.selection(for: document, inPaneAt: 1), .cursor(at: 4))
        XCTAssertFalse(
            model.redo(document: document, inPaneAt: 1),
            "Redo is view-scoped and must not replay another pane's branch"
        )
        XCTAssertTrue(model.redo(document: document, inPaneAt: 0))
        XCTAssertEqual(document.text, "heylo")
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 3))
        XCTAssertEqual(model.selection(for: document, inPaneAt: 1), .cursor(at: 4))
    }

    @MainActor
    func testInterleavedPaneUndoRedoTracksPerViewHistory() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let document = try XCTUnwrap(model.selectedDocument)
        document.text = "abcd"

        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        XCTAssertTrue(model.setSelections(.cursor(at: 1), for: document, inPaneAt: 0))
        XCTAssertTrue(model.setSelections(.cursor(at: 3), for: document, inPaneAt: 1))

        XCTAssertTrue(model.applyTextChange(
            document: document,
            inPaneAt: 0,
            range: NSRange(location: 1, length: 0),
            replacement: "L",
            selectedRanges: .cursor(at: 2)
        ))
        XCTAssertTrue(model.applyTextChange(
            document: document,
            inPaneAt: 1,
            range: NSRange(location: 4, length: 0),
            replacement: "R",
            selectedRanges: .cursor(at: 5)
        ))

        XCTAssertEqual(document.text, "aLbcRd")
        XCTAssertTrue(model.undo(document: document, inPaneAt: 0))
        XCTAssertEqual(document.text, "abcRd")
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 1))
        XCTAssertEqual(model.selection(for: document, inPaneAt: 1), .cursor(at: 4))

        XCTAssertTrue(model.undo(document: document, inPaneAt: 1))
        XCTAssertEqual(document.text, "abcd")
        XCTAssertEqual(model.selection(for: document, inPaneAt: 0), .cursor(at: 1))
        XCTAssertEqual(model.selection(for: document, inPaneAt: 1), .cursor(at: 3))

        XCTAssertTrue(model.redo(document: document, inPaneAt: 1))
        XCTAssertEqual(document.text, "abcRd")
        XCTAssertFalse(model.redo(document: document, inPaneAt: 1))
        XCTAssertTrue(model.redo(document: document, inPaneAt: 0))
        XCTAssertEqual(document.text, "aLbcRd")
    }

    @MainActor
    func testNewEditInOtherPaneSafelyInvalidatesStaleRedoBranch() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let document = try XCTUnwrap(model.selectedDocument)
        document.text = "abcd"

        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        XCTAssertTrue(model.setSelections(.cursor(at: 1), for: document, inPaneAt: 0))
        XCTAssertTrue(model.setSelections(.cursor(at: 3), for: document, inPaneAt: 1))

        XCTAssertTrue(model.applyTextChange(
            document: document,
            inPaneAt: 0,
            range: NSRange(location: 1, length: 0),
            replacement: "L",
            selectedRanges: .cursor(at: 2)
        ))
        XCTAssertTrue(model.applyTextChange(
            document: document,
            inPaneAt: 1,
            range: NSRange(location: 4, length: 0),
            replacement: "R",
            selectedRanges: .cursor(at: 5)
        ))
        XCTAssertTrue(model.undo(document: document, inPaneAt: 0))
        XCTAssertEqual(document.text, "abcRd")

        XCTAssertTrue(model.applyTextChange(
            document: document,
            inPaneAt: 1,
            range: NSRange(location: 0, length: 0),
            replacement: "!",
            selectedRanges: .cursor(at: 1)
        ))

        XCTAssertEqual(document.text, "!abcRd")
        XCTAssertFalse(
            model.redo(document: document, inPaneAt: 0),
            "A conflicting edit in another pane must invalidate stale redo safely"
        )
        XCTAssertTrue(model.undo(document: document, inPaneAt: 1))
        XCTAssertEqual(document.text, "abcRd")
        XCTAssertTrue(model.undo(document: document, inPaneAt: 1))
        XCTAssertEqual(document.text, "abcd")
    }

    @MainActor
    func testRemovingOnePaneReferenceKeepsDocumentAndClosingLastRepairsLayout() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let first = try XCTUnwrap(model.selectedDocument)
        _ = model.newDocument()
        XCTAssertTrue(model.selectDocument(first, inPaneAt: 0))
        XCTAssertTrue(model.cloneActiveDocumentToNextPane())

        XCTAssertTrue(model.removeDocument(first, fromPaneAt: 0))
        XCTAssertTrue(model.documents.contains { $0 === first })
        XCTAssertEqual(model.referenceCount(for: first), 1)
        XCTAssertFalse(model.removeDocument(first, fromPaneAt: 1))

        model.requestClose(first)

        XCTAssertFalse(model.documents.contains { $0 === first })
        XCTAssertFalse(model.paneLayout.isDocumentReferenced(first.sessionDocumentID))
        XCTAssertTrue(model.paneLayout.referencedDocumentIDs.allSatisfy { id in
            model.document(forSessionID: id) != nil
        })
        XCTAssertNotNil(model.selectedDocument)
    }

    @MainActor
    func testOpenAlreadyAuthorisedFileDeduplicatesWithoutReadingAgain() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("opened.txt")
        let bytes = Data("authorised".utf8)
        let opened = try TextFileCodec.decode(bytes, sourceURL: url)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)

        let first = try XCTUnwrap(model.open(openedFile: opened))
        let second = try XCTUnwrap(model.open(openedFile: opened))

        XCTAssertTrue(first === second)
        XCTAssertEqual(model.documents.count, 1)
        XCTAssertEqual(model.paneLayout.referenceCount(for: first.sessionDocumentID), 1)
    }

    @MainActor
    func testComparisonSnapshotIsUntitledAndCannotOverwriteItsSourceHint() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let source = fixture.directory.appendingPathComponent("conflicted.swift")

        let document = model.openComparisonSnapshot(
            displayName: "conflicted.swift (Ours)",
            text: "let ours = true\n",
            languageHintURL: source
        )

        XCTAssertNil(document.fileURL)
        XCTAssertTrue(document.isUntitled)
        XCTAssertEqual(document.displayName, "conflicted.swift (Ours)")
        XCTAssertEqual(document.language, "Swift")
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    func testSaveAsRejectsPathOwnedByAnotherOpenDocument() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let firstURL = fixture.directory.appendingPathComponent("first.txt")
        let secondURL = fixture.directory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let openedFirst = await model.open(url: firstURL)
        let first = try XCTUnwrap(openedFirst)
        let openedSecond = await model.open(url: secondURL)
        _ = try XCTUnwrap(openedSecond)

        let saved = await model.saveAs(first, to: secondURL)
        XCTAssertFalse(saved)
        XCTAssertEqual(first.fileURL?.standardizedFileURL, firstURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "second")
        XCTAssertEqual(model.presentedIssue?.title, "Could Not Save File")
        XCTAssertEqual(model.presentedIssue?.titleContent, .saveFile)
        XCTAssertEqual(
            model.presentedIssue?.content, .app(.destinationAlreadyOpen)
        )
        XCTAssertEqual(
            model.presentedIssue.map {
                EditorLocale.zhCN.localizedAppModelIssue($0.content)
            },
            "该路径已在另一个标签页中打开。请关闭该标签页，或选择其他目标位置。"
        )
    }

    @MainActor
    func testScrollPositionIsPerPaneAndDocument() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let document = try XCTUnwrap(model.selectedDocument)
        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        let left = model.paneLayout.panes[0].viewID
        let right = model.paneLayout.panes[1].viewID

        model.setScrollPosition(
            x: 12, y: 34,
            for: document.sessionDocumentID, viewID: left
        )
        model.setScrollPosition(
            x: 56, y: 78,
            for: document.sessionDocumentID, viewID: right
        )

        XCTAssertEqual(
            model.scrollPosition(for: document.sessionDocumentID, viewID: left),
            EditorPaneScrollPosition(x: 12, y: 34)
        )
        XCTAssertEqual(
            model.scrollPosition(for: document.sessionDocumentID, viewID: right),
            EditorPaneScrollPosition(x: 56, y: 78)
        )
    }

    @MainActor
    func testPinReordersEveryPaneAndBulkTargetsSkipPinnedTabs() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let first = try XCTUnwrap(model.selectedDocument)
        let second = model.newDocument()
        let third = model.newDocument()
        XCTAssertTrue(model.selectDocument(first, inPaneAt: 0))

        XCTAssertTrue(model.togglePin(second))
        XCTAssertEqual(
            model.paneLayout.panes[0].documentIDs,
            [second, first, third].map(\.sessionDocumentID)
        )
        XCTAssertEqual(model.documentsToClose(.others).map(\.id), [third.id])
        XCTAssertEqual(model.documentsToClose(.right).map(\.id), [third.id])
        XCTAssertEqual(model.documentsToClose(.all).map(\.id), [first.id, third.id])

        XCTAssertFalse(model.togglePin(second))
        XCTAssertEqual(
            model.paneLayout.panes[0].documentIDs,
            [second, first, third].map(\.sessionDocumentID),
            "Unpinning stable-partitions without disturbing unpinned order"
        )
    }

    @MainActor
    func testNumberedSelectionAndSelectedBlockReorderingUsePaneOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let first = try XCTUnwrap(model.selectedDocument)
        let second = model.newDocument()
        let third = model.newDocument()
        let fourth = model.newDocument()

        XCTAssertTrue(model.toggleTabSelection(second))
        XCTAssertTrue(model.toggleTabSelection(fourth))
        XCTAssertTrue(model.reorderTabs(
            inPaneAt: 0,
            draggedDocumentID: second.sessionDocumentID,
            relativeTo: first.sessionDocumentID,
            position: .before
        ))
        XCTAssertEqual(
            model.paneLayout.panes[0].documentIDs,
            [second, fourth, first, third].map(\.sessionDocumentID)
        )
        XCTAssertEqual(model.paneLayout.selectedDocumentIDs, Set([
            second.sessionDocumentID, fourth.sessionDocumentID
        ]))

        XCTAssertEqual(model.selectTab(number: 3)?.id, first.id)
        XCTAssertEqual(model.selectedDocument?.id, first.id)
        XCTAssertNil(model.selectTab(number: 0))
        XCTAssertNil(model.selectTab(number: 9))
        XCTAssertNil(model.selectTab(number: 10))
        XCTAssertEqual(model.selectedDocument?.id, first.id)
    }

    @MainActor
    func testDragReorderCannotCrossThePinnedBoundary() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let first = try XCTUnwrap(model.selectedDocument)
        let second = model.newDocument()
        let third = model.newDocument()
        XCTAssertTrue(model.togglePin(first))
        let originalOrder = model.paneLayout.panes[0].documentIDs

        XCTAssertFalse(model.reorderTabs(
            inPaneAt: 0,
            draggedDocumentID: third.sessionDocumentID,
            relativeTo: first.sessionDocumentID,
            position: .before
        ))
        XCTAssertEqual(model.paneLayout.panes[0].documentIDs, originalOrder)

        XCTAssertTrue(model.reorderTabs(
            inPaneAt: 0,
            draggedDocumentID: third.sessionDocumentID,
            relativeTo: second.sessionDocumentID,
            position: .before
        ))
        XCTAssertEqual(
            model.paneLayout.panes[0].documentIDs,
            [first, third, second].map(\.sessionDocumentID)
        )
    }

    @MainActor
    func testGlobalMixedPinSelectionOnlyMovesTheSourcePaneSubset() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let first = try XCTUnwrap(model.selectedDocument)
        let second = model.newDocument()
        let third = model.newDocument()
        XCTAssertTrue(model.selectDocument(first, inPaneAt: 0))
        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        let otherPaneOnly = model.newDocument()
        XCTAssertTrue(model.togglePin(otherPaneOnly))
        XCTAssertTrue(model.toggleTabSelection(otherPaneOnly))
        XCTAssertTrue(model.focusPane(at: 0))
        XCTAssertTrue(model.toggleTabSelection(third))

        XCTAssertTrue(model.reorderTabs(
            inPaneAt: 0,
            draggedDocumentID: third.sessionDocumentID,
            relativeTo: second.sessionDocumentID,
            position: .before
        ))
        XCTAssertEqual(
            model.paneLayout.panes[0].documentIDs,
            [first, third, second].map(\.sessionDocumentID)
        )
    }

    @MainActor
    func testReviewedBulkCloseIsAtomicAndRecordsSavedFilesInLIFOOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let firstURL = fixture.directory.appendingPathComponent("first.txt")
        let secondURL = fixture.directory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let firstFile = try TextFileCodec.read(from: firstURL)
        let secondFile = try TextFileCodec.read(from: secondURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let first = try XCTUnwrap(model.open(openedFile: firstFile))
        let second = try XCTUnwrap(model.open(openedFile: secondFile))
        second.text = "changed"

        XCTAssertFalse(model.commitReviewedTabClose(
            documentIDs: [first.id, second.id],
            fromPaneAt: 0
        ))
        XCTAssertEqual(model.documents.count, 2, "A failed review must not close a prefix")

        XCTAssertTrue(model.commitReviewedTabClose(
            documentIDs: [first.id, second.id],
            fromPaneAt: 0,
            reviewedDirtyDocumentRevisions: [second.id: second.buffer.revision]
        ))
        XCTAssertEqual(model.documents.count, 1, "The empty workspace receives one placeholder")
        XCTAssertEqual(model.recentlyClosedTabCount, 2)
        XCTAssertEqual(model.mostRecentlyClosedTab?.url, secondURL)
        XCTAssertTrue(model.consumeRecentlyClosedTab(
            id: try XCTUnwrap(model.mostRecentlyClosedTab?.id)
        ))
        XCTAssertEqual(model.mostRecentlyClosedTab?.url, firstURL)
    }

    @MainActor
    func testClosingOnlyOnePaneOccurrenceDoesNotCreateAReopenEntry() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("shared.txt")
        try Data("shared".utf8).write(to: url)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(
            model.open(openedFile: TextFileCodec.read(from: url))
        )
        XCTAssertTrue(model.cloneActiveDocumentToNextPane())

        model.requestClose(document, fromPaneAt: 0)

        XCTAssertEqual(model.referenceCount(for: document), 1)
        XCTAssertFalse(model.canReopenClosedTab)
    }

    @MainActor
    func testBulkCloseRecordsOnlyDocumentsWhoseFinalReferenceWasRemoved() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let sharedURL = fixture.directory.appendingPathComponent("shared.txt")
        let localURL = fixture.directory.appendingPathComponent("local.txt")
        try Data("shared".utf8).write(to: sharedURL)
        try Data("local".utf8).write(to: localURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let shared = try XCTUnwrap(
            model.open(openedFile: TextFileCodec.read(from: sharedURL))
        )
        XCTAssertTrue(model.cloneActiveDocumentToNextPane())
        XCTAssertTrue(model.focusPane(at: 0))
        let local = try XCTUnwrap(
            model.open(openedFile: TextFileCodec.read(from: localURL))
        )

        XCTAssertTrue(model.commitReviewedTabClose(
            documentIDs: [shared.id, local.id],
            fromPaneAt: 0
        ))

        XCTAssertEqual(model.referenceCount(for: shared), 1)
        XCTAssertEqual(model.recentlyClosedTabCount, 1)
        XCTAssertEqual(model.mostRecentlyClosedTab?.url, localURL)
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelPaneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return Fixture(
            directory: directory,
            store: SessionStore(
                sessionURL: directory.appendingPathComponent(SessionStore.sessionFileName)
            )
        )
    }

    private struct Fixture {
        let directory: URL
        let store: SessionStore

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
