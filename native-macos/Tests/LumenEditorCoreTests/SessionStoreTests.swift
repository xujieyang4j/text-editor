import Foundation
import XCTest
@testable import LumenEditorCore

final class SessionStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testRoundTripPreservesEveryPersistedTabField() throws {
        let store = makeStore()
        let session = EditorSession(
            tabs: [
                SessionTab(
                    path: "/tmp/example.txt",
                    name: "example.txt",
                    content: "draft\r\ntext",
                    savedContent: "saved\r\ntext",
                    encoding: .utf8,
                    savedEncoding: .utf8bom,
                    eol: .crlf,
                    savedEOL: .lf,
                    revision: "revision-42",
                    encodingLocked: true,
                    encodingIssue: .uncertain,
                    requiresSave: true,
                    selection: SessionSelection(anchor: 10, head: 3)
                ),
                SessionTab(
                    path: nil,
                    name: "Untitled",
                    content: "你好",
                    savedContent: "",
                    encoding: .utf16leNoBom,
                    eol: .lf,
                    revision: nil,
                    selection: SessionSelection(anchor: 2, head: 2)
                )
            ],
            activeTabIndex: 1
        )

        try store.save(session)

        XCTAssertEqual(store.load(), session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionURL.path))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: store.sessionURL)))
    }

    func testSaveCreatesParentDirectoryAndReplacesExistingSnapshot() throws {
        let store = makeStore(nestedPath: true)
        let first = EditorSession(tabs: [makeTab(content: "first")], activeTabIndex: 0)
        let second = EditorSession(tabs: [makeTab(content: "second")], activeTabIndex: 0)

        try store.save(first)
        try store.save(second)

        XCTAssertEqual(store.load(), second)
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: store.sessionURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(siblingNames, [SessionStore.sessionFileName])
    }

    func testMissingSnapshotReturnsEmptySession() {
        let store = makeStore()

        XCTAssertEqual(store.load(), .empty)
    }

    func testLoadsEarlySnapshotWithoutSavedFormatFields() throws {
        let store = makeStore()
        let json = """
        {
          "formatVersion": 1,
          "tabs": [{
            "name": "Untitled-1",
            "content": "",
            "savedContent": "",
            "encoding": "utf8",
            "eol": "LF",
            "selection": { "anchor": 0, "head": 0 }
          }],
          "activeTabIndex": 0
        }
        """
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: store.sessionURL)

        let session = store.load()

        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertNil(session.tabs[0].savedEncoding)
        XCTAssertNil(session.tabs[0].savedEOL)
        XCTAssertNil(session.tabs[0].encodingLocked)
        XCTAssertNil(session.tabs[0].encodingIssue)
        XCTAssertNil(session.tabs[0].requiresSave)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionURL.path))
    }

    func testMalformedSnapshotReturnsEmptyAndIsQuarantined() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ definitely-not-json".utf8).write(to: store.sessionURL)

        XCTAssertEqual(store.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionURL.path))

        let names = try FileManager.default.contentsOfDirectory(
            atPath: store.sessionURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("\(SessionStore.sessionFileName).corrupt-"))
    }

    func testSaveRejectsMoreThanOneHundredTabsWithoutReplacingGoodSnapshot() throws {
        let store = makeStore()
        let good = EditorSession(tabs: [makeTab(content: "keep me")], activeTabIndex: 0)
        try store.save(good)
        let excessive = EditorSession(tabs: (0...100).map { makeTab(content: "\($0)") })

        XCTAssertThrowsError(try store.save(excessive)) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                .tooManyTabs(actual: 101, maximum: 100)
            )
        }
        XCTAssertEqual(store.load(), good)
    }

    func testDraftLimitCountsUTF8BytesAcrossTabsAndAllowsExactLimit() throws {
        let store = makeStore(limits: .init(maximumTabs: 100, maximumDraftBytes: 5))
        let exactLimit = EditorSession(tabs: [
            makeTab(content: "你"), // Three UTF-8 bytes.
            makeTab(content: "ab")
        ])
        try store.save(exactLimit)

        let tooLarge = EditorSession(tabs: [
            makeTab(content: "你"),
            makeTab(content: "abc")
        ])
        XCTAssertThrowsError(try store.save(tooLarge)) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                .draftDataTooLarge(actualBytes: 6, maximumBytes: 5)
            )
        }
        XCTAssertEqual(store.load(), exactLimit)
    }

    func testDraftLimitIncludesSavedBaselines() throws {
        let store = makeStore(limits: .init(maximumTabs: 100, maximumDraftBytes: 5))
        let tab = SessionTab(
            path: nil,
            name: "Untitled",
            content: "ab",
            savedContent: "cdef",
            encoding: .utf8,
            eol: .lf,
            revision: nil,
            selection: SessionSelection(anchor: 0, head: 0)
        )

        XCTAssertThrowsError(try store.save(EditorSession(tabs: [tab]))) { error in
            XCTAssertEqual(
                error as? SessionStoreError,
                .draftDataTooLarge(actualBytes: 6, maximumBytes: 5)
            )
        }
    }

    func testDecodedSnapshotThatExceedsLimitsIsQuarantined() throws {
        let store = makeStore(limits: .init(maximumTabs: 1, maximumDraftBytes: 2))
        let oversized = EditorSession(tabs: [makeTab(content: "abc")])
        let data = try JSONEncoder().encode(oversized)
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: store.sessionURL)

        XCTAssertEqual(store.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionURL.path))
    }

    func testOversizedSerializedSnapshotIsRejectedBeforeDecode() throws {
        let store = makeStore(limits: .init(
            maximumTabs: 100,
            maximumDraftBytes: 1_024,
            maximumSnapshotBytes: 64
        ))
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x20, count: 65).write(to: store.sessionURL)

        XCTAssertEqual(store.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionURL.path))
    }

    func testSaveRejectsOversizedSerializedSnapshot() throws {
        let store = makeStore(limits: .init(
            maximumTabs: 100,
            maximumDraftBytes: 1_024,
            maximumSnapshotBytes: 64
        ))

        XCTAssertThrowsError(try store.save(EditorSession(
            tabs: [makeTab(content: "small draft")],
            activeTabIndex: 0
        ))) { error in
            guard case SessionStoreError.snapshotTooLarge = error else {
                return XCTFail("Expected snapshotTooLarge, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionURL.path))
    }

    func testDefaultURLUsesApplicationSupportSubdirectory() {
        let url = SessionStore.defaultSessionURL()

        XCTAssertEqual(url.lastPathComponent, SessionStore.sessionFileName)
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            SessionStore.applicationSupportDirectoryName
        )
    }

    func testInvalidActiveTabIndexIsRejectedAndQuarantinedOnLoad() throws {
        let store = makeStore()
        let invalid = EditorSession(
            tabs: [makeTab(content: "draft")],
            activeTabIndex: 4
        )
        XCTAssertThrowsError(try store.save(invalid)) { error in
            XCTAssertEqual(error as? SessionStoreError, .invalidSnapshot)
        }

        let data = try JSONEncoder().encode(invalid)
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: store.sessionURL)

        XCTAssertEqual(store.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionURL.path))
    }

    func testLoadWindowSessionMigratesVersionOneSnapshot() throws {
        let store = makeStore()
        let legacy = EditorSession(
            tabs: [makeTab(content: "migrated draft")],
            activeTabIndex: 0
        )
        try store.save(legacy)

        let migrated = store.loadWindowSession()

        XCTAssertEqual(migrated.formatVersion, WindowSession.currentFormatVersion)
        XCTAssertEqual(migrated.documents.count, 1)
        XCTAssertEqual(migrated.documents[0].documentID, "legacy-document-0")
        XCTAssertEqual(migrated.documents[0].draft, "migrated draft")
        XCTAssertEqual(migrated.activeDocumentID, "legacy-document-0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionURL.path))
    }

    func testLegacySaveEmptyShorthandStillUsesEditorSessionAPI() throws {
        let store = makeStore()

        try store.save(.empty)

        XCTAssertEqual(store.load(), EditorSession.empty)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.sessionURL))
                as? [String: Any]
        )
        XCTAssertEqual(object["formatVersion"] as? Int, EditorSession.currentFormatVersion)
        XCTAssertNotNil(object["tabs"])
        XCTAssertNil(object["documents"])
    }

    func testWindowSessionV2RoundTripUsesSortedPrettyJSON() throws {
        let store = makeStore(nestedPath: true)
        let session = makeWindowSession(draft: "native draft")

        try store.save(session)

        XCTAssertEqual(store.loadWindowSession(), session)
        let persisted = try Data(contentsOf: store.sessionURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertEqual(persisted, try session.encodedData(using: encoder))
        let json = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertTrue(json.contains("\n"))
    }

    func testLegacyLoadDoesNotMisreadOrQuarantineVersionTwoSnapshot() throws {
        let store = makeStore()
        let session = makeWindowSession(draft: "keep V2")
        try store.save(session)

        XCTAssertEqual(store.load(), .empty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionURL.path))
        XCTAssertEqual(store.loadWindowSession(), session)
    }

    func testLegacyLoadQuarantinesInvalidVersionTwoSnapshot() throws {
        let store = makeStore()
        var invalid = makeWindowSession(draft: "invalid V2")
        invalid.activeDocumentID = "missing-document"
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(invalid).write(to: store.sessionURL)

        XCTAssertEqual(store.load(), .empty)
        assertSnapshotWasQuarantined(store)
    }

    func testLoadWindowSessionQuarantinesCorruptSnapshot() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not-a-window-session".utf8).write(to: store.sessionURL)

        XCTAssertEqual(store.loadWindowSession(), .empty)
        assertSnapshotWasQuarantined(store)
    }

    func testLoadWindowSessionQuarantinesOversizedSnapshotBeforeDecode() throws {
        let store = makeStore(limits: .init(
            maximumTabs: 100,
            maximumDraftBytes: 1_024,
            maximumSnapshotBytes: 64
        ))
        try FileManager.default.createDirectory(
            at: store.sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x20, count: 65).write(to: store.sessionURL)

        XCTAssertEqual(store.loadWindowSession(), .empty)
        assertSnapshotWasQuarantined(store)
    }

    func testWindowSessionSaveMapsTabRecoveryAndSnapshotLimits() throws {
        let store = makeStore(limits: .init(
            maximumTabs: 1,
            maximumDraftBytes: 5,
            maximumSnapshotBytes: 10_000
        ))
        let exactLimit = makeWindowSession(draft: "你ab")
        try store.save(exactLimit)

        let tooMany = WindowSession(documents: [
            makeWindowDocument(id: "a", draft: ""),
            makeWindowDocument(id: "b", draft: "")
        ])
        XCTAssertThrowsError(try store.save(tooMany)) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .tooManyTabs(actual: 2, maximum: 1)
            )
        }

        let tooLarge = makeWindowSession(draft: "你abc")
        XCTAssertThrowsError(try store.save(tooLarge)) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .recoveryDataTooLarge(actualBytes: 6, maximumBytes: 5)
            )
        }
        XCTAssertEqual(store.loadWindowSession(), exactLimit)

        let snapshotStore = makeStore(limits: .init(
            maximumTabs: 1,
            maximumDraftBytes: 1_024,
            maximumSnapshotBytes: 64
        ))
        XCTAssertThrowsError(try snapshotStore.save(makeWindowSession(draft: ""))) { error in
            guard case let WindowSessionValidationError.snapshotTooLarge(_, maximum) = error else {
                return XCTFail("Expected snapshotTooLarge, got \(error)")
            }
            XCTAssertEqual(maximum, 64)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotStore.sessionURL.path))
    }

    private func makeStore(
        nestedPath: Bool = false,
        limits: SessionStore.Limits = .default
    ) -> SessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let parent = nestedPath
            ? directory.appendingPathComponent("one/two", isDirectory: true)
            : directory
        return SessionStore(
            sessionURL: parent.appendingPathComponent(SessionStore.sessionFileName),
            limits: limits
        )
    }

    private func makeTab(content: String) -> SessionTab {
        SessionTab(
            path: nil,
            name: "Untitled",
            content: content,
            savedContent: "",
            encoding: .utf8,
            eol: .lf,
            revision: nil,
            selection: SessionSelection(anchor: 0, head: 0)
        )
    }

    private func makeWindowSession(draft: String) -> WindowSession {
        WindowSession(documents: [makeWindowDocument(id: "document-a", draft: draft)])
    }

    private func makeWindowDocument(id: String, draft: String) -> WindowSessionDocument {
        WindowSessionDocument(
            documentID: id,
            path: nil,
            name: "Untitled",
            draft: draft,
            encoding: .utf8,
            eol: .lf,
            views: [WindowSessionViewState(
                group: 0,
                selections: [WindowSessionSelection(anchor: 0, head: 0)],
                mainIndex: 0,
                scrollX: 0,
                scrollY: 0
            )]
        )
    }

    private func assertSnapshotWasQuarantined(
        _ store: SessionStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.sessionURL.path),
            file: file,
            line: line
        )
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: store.sessionURL.deletingLastPathComponent().path
        )) ?? []
        XCTAssertEqual(names.count, 1, file: file, line: line)
        XCTAssertTrue(
            names.first?.hasPrefix("\(SessionStore.sessionFileName).corrupt-") == true,
            file: file,
            line: line
        )
    }
}
