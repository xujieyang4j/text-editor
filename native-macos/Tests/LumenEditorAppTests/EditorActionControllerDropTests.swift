import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class EditorActionControllerDropTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testDropLoadSummaryNormalizesDeduplicatesAndTracksTruncation() {
        let base = URL(fileURLWithPath: "/tmp/drop-summary")
        let duplicate = base.appendingPathComponent("folder/../file.txt")
        let canonical = base.appendingPathComponent("file.txt").standardizedFileURL
        let extraURLs = (0..<40).map { index in
            base.appendingPathComponent("extra-\(index).txt")
        }

        let summary = DropLoadSummary.plan(
            urls: [duplicate, canonical, URL(string: "https://example.com")!] + extraURLs,
            providerCount: 40,
            parseFailureCount: 3
        )

        XCTAssertEqual(summary.providerCount, 40)
        XCTAssertEqual(summary.truncatedCount, 8)
        XCTAssertEqual(summary.parseFailureCount, 3)
        XCTAssertEqual(summary.urls.first, canonical)
        XCTAssertEqual(Set(summary.urls).count, summary.urls.count)
        XCTAssertEqual(summary.urls.count, DropLoadSummary.maximumItems)
    }

    func testHandleDroppedURLsPublishesNoticeForPartialSuccess() async throws {
        let fixture = try makeFixture(named: "partial-success")
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()

        let textFile = fixture.directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: textFile)
        let binaryFile = fixture.directory.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: binaryFile)
        let missingFile = fixture.directory.appendingPathComponent("missing.txt")

        let summary = DropLoadSummary(
            providerCount: 5,
            truncatedCount: 1,
            parseFailureCount: 1,
            urls: [textFile, binaryFile, missingFile]
        )

        await actions.handleDroppedURLs(summary)

        XCTAssertNil(actions.presentedIssue)
        XCTAssertNil(model.presentedIssue)
        XCTAssertEqual(actions.dropNotice?.message, """
1 succeeded, 2 rejected, 1 truncated, 0 folders added, 0 folders failed, 1 files opened, 1 files missing, 1 files invalid, 0 files failed to open, 1 drop items could not be parsed.
""")
        XCTAssertEqual(model.documents.map(\.fileURL?.standardizedFileURL), [textFile.standardizedFileURL])
    }

    func testHandleDroppedURLsPresentsIssueWhenEverythingFails() async throws {
        let fixture = try makeFixture(named: "all-failed")
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()

        let missingFile = fixture.directory.appendingPathComponent("missing.txt")
        let binaryFile = fixture.directory.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binaryFile)

        let summary = DropLoadSummary(
            providerCount: 3,
            truncatedCount: 0,
            parseFailureCount: 1,
            urls: [missingFile, binaryFile]
        )

        await actions.handleDroppedURLs(summary)

        XCTAssertEqual(actions.presentedIssue?.title, "Could Not Open Dropped Items")
        XCTAssertEqual(actions.presentedIssue?.message, """
0 succeeded, 2 rejected, 0 truncated, 0 folders added, 0 folders failed, 0 files opened, 1 files missing, 1 files invalid, 0 files failed to open, 1 drop items could not be parsed.
""")
        XCTAssertNil(actions.dropNotice)
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertNil(model.presentedIssue)
    }

    func testEditorDropOutcomeSeparatesRejectedFromFailures() {
        let outcome = EditorDropOutcome(
            providerCount: 7,
            truncatedCount: 1,
            parseFailureCount: 1,
            directoryRootSuccessCount: 1,
            directoryRootFailureCount: 1,
            fileOpenSuccessCount: 1,
            fileOpenFailureCount: 1,
            fileNotFoundCount: 1,
            fileInvalidCount: 1
        )

        XCTAssertEqual(outcome.successCount, 2)
        XCTAssertEqual(outcome.rejectedCount, 2)
        XCTAssertEqual(outcome.failedCount, 3)
        XCTAssertFalse(outcome.allFailed)
    }

    private func makeFixture(named name: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EditorActionControllerDropTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
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
    }
}
