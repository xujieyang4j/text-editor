import Foundation
import XCTest
@testable import LumenEditorCore

final class WindowSessionTests: XCTestCase {
    func testCompleteVersionTwoSnapshotRoundTrips() throws {
        let first = WindowSessionDocument(
            documentID: "document-a",
            path: "/workspace/a.swift",
            name: "a.swift",
            pinned: true,
            language: "Swift",
            languageLocked: true,
            draft: "draft \u{1f642}",
            formatDirty: true,
            baseRevision: "sha256:\(String(repeating: "a", count: 64))",
            encoding: .utf16leNoBom,
            diskEncoding: .utf8bom,
            encodingLocked: true,
            encodingIssue: .uncertain,
            eol: .crlf,
            eolOverride: .crlf,
            bookmarks: [1, 42],
            views: [
                WindowSessionViewState(
                    group: 0,
                    selections: [
                        WindowSessionSelection(anchor: 8, head: 2),
                        WindowSessionSelection(anchor: 12, head: 12)
                    ],
                    mainIndex: 1,
                    scrollX: 25,
                    scrollY: 75
                ),
                WindowSessionViewState(
                    group: 1,
                    selections: [WindowSessionSelection(anchor: 3, head: 9)],
                    mainIndex: 0,
                    scrollX: 1,
                    scrollY: 2
                )
            ]
        )
        let second = WindowSessionDocument(
            documentID: "document-b",
            path: nil,
            name: "Untitled-2",
            language: "Plain Text",
            draft: "notes",
            encoding: .utf8,
            diskEncoding: .utf8,
            eol: .lf,
            views: [WindowSessionViewState(
                group: 1,
                selections: [WindowSessionSelection(anchor: 5, head: 0)],
                mainIndex: 0,
                scrollX: 0,
                scrollY: 10
            )]
        )
        let project = WindowSessionProject([
            "exclude": .array([.string("build/**"), .string(".git/**")]),
            "buildCommand": .string("swift build"),
            "enabled": .bool(true),
            "nested": .object(["count": .number(2), "nothing": .null])
        ])
        let session = WindowSession(
            documents: [first, second],
            activeDocumentID: "document-b",
            folder: "/workspace",
            folders: ["/workspace", "/shared"],
            project: project,
            layout: WindowSessionLayout(
                kind: .columns2,
                activeGroup: 1,
                groups: [
                    WindowSessionGroup(
                        documentIDs: ["document-a"],
                        activeDocumentID: "document-a"
                    ),
                    WindowSessionGroup(
                        documentIDs: ["document-b", "document-a"],
                        activeDocumentID: "document-b"
                    )
                ]
            )
        )

        let data = try session.encodedData()
        let decoded = try WindowSession.decodeValidated(from: data)

        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertEqual(decoded.documents[0].views[0].selections[0].anchor, 8)
        XCTAssertEqual(decoded.documents[0].views[0].selections[0].head, 2)
        XCTAssertEqual(decoded.documents[0].views[0].mainIndex, 1)
        XCTAssertEqual(decoded.documents[0].views[0].scrollLeft, 25)
        XCTAssertEqual(decoded.documents[0].views[0].scrollTop, 75)
        XCTAssertEqual(decoded.layout.groups[1].documentIDs, ["document-b", "document-a"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["documents"])
        XCTAssertNil(object["openFiles"])
        let layout = try XCTUnwrap(object["layout"] as? [String: Any])
        let groups = try XCTUnwrap(layout["groups"] as? [[String: Any]])
        XCTAssertEqual(groups[1]["docIDs"] as? [String], ["document-b", "document-a"])
    }

    func testDocumentEncodingIsSparseAndViewDecoderAcceptsElectronScrollKeys() throws {
        let document = WindowSessionDocument(
            documentID: "clean",
            path: "/tmp/clean.txt",
            name: "clean.txt"
        )
        let data = try JSONEncoder().encode(document)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(object["draft"])
        XCTAssertNil(object["recoveryContent"])
        XCTAssertNil(object["baseRevision"])
        XCTAssertNil(object["pinned"])
        XCTAssertNil(object["encodingLocked"])
        XCTAssertNil(object["bookmarks"])
        XCTAssertNil(object["views"])

        let electronJSON = Data("""
        {
          "group": 0,
          "selections": [{ "anchor": 9, "head": 2 }],
          "mainIndex": 0,
          "scrollLeft": 11,
          "scrollTop": 22
        }
        """.utf8)
        let view = try JSONDecoder().decode(WindowSessionViewState.self, from: electronJSON)
        XCTAssertEqual(view.scrollX, 11)
        XCTAssertEqual(view.scrollY, 22)
        XCTAssertEqual(view.selections, [WindowSessionSelection(anchor: 9, head: 2)])
        let nativeViewObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(view))
                as? [String: Any]
        )
        XCTAssertEqual(nativeViewObject["scrollLeft"] as? Int, 11)
        XCTAssertEqual(nativeViewObject["scrollTop"] as? Int, 22)
        XCTAssertNil(nativeViewObject["scrollX"])
        XCTAssertNil(nativeViewObject["scrollY"])

        let dirtyWithoutRevision = WindowSessionDocument(
            documentID: "dirty", path: nil, name: "Untitled", draft: "text"
        )
        let dirtyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(dirtyWithoutRevision))
                as? [String: Any]
        )
        XCTAssertTrue(dirtyObject["baseRevision"] is NSNull)
    }

    func testMigrationIsPureDeterministicAndPreservesDirtyState() throws {
        let revision = "sha256:\(String(repeating: "b", count: 64))"
        let legacy = EditorSession(
            tabs: [
                legacyTab(
                    path: "/tmp/dirty.txt",
                    name: "dirty.txt",
                    content: "edited",
                    savedContent: "saved",
                    encoding: .utf16leNoBom,
                    savedEncoding: .utf8bom,
                    eol: .crlf,
                    savedEOL: .lf,
                    revision: revision,
                    encodingLocked: true,
                    encodingIssue: .uncertain,
                    requiresSave: true,
                    selection: SessionSelection(anchor: 6, head: 1)
                ),
                legacyTab(
                    path: nil,
                    name: "Untitled-4",
                    content: "scratch",
                    savedContent: "",
                    encoding: .utf8,
                    eol: .lf,
                    selection: SessionSelection(anchor: 7, head: 7)
                )
            ],
            activeTabIndex: 1
        )

        let first = try WindowSession.migrate(from: legacy)
        let second = try WindowSession.migrate(from: legacy)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.documents.map(\.documentID), [
            "legacy-document-0", "legacy-document-1"
        ])
        XCTAssertEqual(first.activeDocumentID, "legacy-document-1")
        XCTAssertEqual(first.layout.kind, .single)
        XCTAssertEqual(first.layout.groups[0].documentIDs, first.documents.map(\.documentID))
        XCTAssertEqual(first.layout.groups[0].activeDocumentID, "legacy-document-1")

        let dirty = first.documents[0]
        XCTAssertEqual(dirty.draft, "edited")
        XCTAssertNil(dirty.recoveryContent)
        XCTAssertTrue(dirty.formatDirty)
        XCTAssertEqual(dirty.baseRevision, revision)
        XCTAssertEqual(dirty.encoding, .utf16leNoBom)
        XCTAssertEqual(dirty.diskEncoding, .utf8bom)
        XCTAssertTrue(dirty.encodingLocked)
        XCTAssertEqual(dirty.encodingIssue, .uncertain)
        XCTAssertEqual(dirty.eol, .crlf)
        XCTAssertEqual(dirty.eolOverride, .crlf)
        XCTAssertEqual(
            dirty.views[0].selections,
            [WindowSessionSelection(anchor: 6, head: 1)]
        )
        XCTAssertEqual(first.documents[1].draft, "scratch")
    }

    func testMigrationMakesCleanFilesSparseAndRetainsFormatOnlyFallback() throws {
        let formatRevision = "sha256:\(String(repeating: "c", count: 64))"
        let clean = legacyTab(
            path: "/tmp/clean.txt",
            name: "clean.txt",
            content: "same",
            savedContent: "same",
            encoding: .utf8,
            savedEncoding: .utf8,
            eol: .lf,
            savedEOL: .lf,
            revision: "clean-revision"
        )
        let formatOnly = legacyTab(
            path: "/tmp/format.txt",
            name: "format.txt",
            content: "same",
            savedContent: "same",
            encoding: .utf16le,
            savedEncoding: .utf8,
            eol: .crlf,
            savedEOL: .lf,
            revision: formatRevision
        )

        let migrated = try WindowSession.migrate(from: EditorSession(
            tabs: [clean, formatOnly],
            activeTabIndex: 0
        ))

        XCTAssertNil(migrated.documents[0].draft)
        XCTAssertNil(migrated.documents[0].recoveryContent)
        XCTAssertFalse(migrated.documents[0].formatDirty)
        XCTAssertNil(migrated.documents[0].baseRevision)

        XCTAssertNil(migrated.documents[1].draft)
        XCTAssertEqual(migrated.documents[1].recoveryContent, "same")
        XCTAssertTrue(migrated.documents[1].formatDirty)
        XCTAssertEqual(migrated.documents[1].baseRevision, formatRevision)
        XCTAssertEqual(migrated.documents[1].diskEncoding, .utf8)
        XCTAssertEqual(migrated.documents[1].eolOverride, .crlf)
    }

    func testMigrationRejectsUnsupportedVersionAndInvalidActiveIndex() {
        XCTAssertThrowsError(try WindowSession.migrate(from: EditorSession(formatVersion: 9))) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .unsupportedFormatVersion(9)
            )
        }
        XCTAssertThrowsError(try WindowSession.migrate(from: EditorSession(
            tabs: [legacyTab(name: "one")],
            activeTabIndex: 2
        ))) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .invalidLegacyActiveTabIndex(2)
            )
        }
    }

    func testDecodingEntryPointMigratesVersionOneJSON() throws {
        let legacy = EditorSession(
            tabs: [legacyTab(
                path: nil,
                name: "Untitled-1",
                content: "draft",
                selection: SessionSelection(anchor: 5, head: 1)
            )],
            activeTabIndex: 0
        )
        let data = try JSONEncoder().encode(legacy)

        let migrated = try WindowSession.decodeMigratingLegacy(from: data)

        XCTAssertEqual(migrated.formatVersion, 2)
        XCTAssertEqual(migrated.activeDocumentID, "legacy-document-0")
        XCTAssertEqual(migrated.documents[0].draft, "draft")
        XCTAssertEqual(
            migrated.documents[0].views[0].selections[0],
            WindowSessionSelection(anchor: 5, head: 1)
        )
    }

    func testMigrationDefaultsMissingLegacyActiveIndexToFirstDocument() throws {
        let migrated = try WindowSession.migrate(from: EditorSession(
            tabs: [legacyTab(name: "one"), legacyTab(name: "two")],
            activeTabIndex: nil
        ))

        XCTAssertEqual(migrated.activeDocumentID, "legacy-document-0")
        XCTAssertEqual(migrated.layout.groups[0].activeDocumentID, "legacy-document-0")
    }

    func testMigrationPreservesRequiresSaveWithoutTextDifference() throws {
        let migrated = try WindowSession.migrate(from: EditorSession(
            tabs: [legacyTab(
                path: "/tmp/recovered.txt",
                name: "recovered.txt",
                content: "unchanged but must save",
                savedContent: "unchanged but must save",
                revision: nil,
                requiresSave: true
            )],
            activeTabIndex: 0
        ))

        XCTAssertEqual(migrated.documents[0].draft, "unchanged but must save")
        XCTAssertNil(migrated.documents[0].baseRevision)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migrated.encodedData())
                as? [String: Any]
        )
        let documents = try XCTUnwrap(object["documents"] as? [[String: Any]])
        XCTAssertTrue(documents[0]["baseRevision"] is NSNull)
    }

    func testMigrationDropsOpaqueLegacyRevisionButKeepsRecoveryText() throws {
        let migrated = try WindowSession.migrate(from: EditorSession(
            tabs: [legacyTab(
                path: "/tmp/legacy.txt",
                name: "legacy.txt",
                content: "local",
                savedContent: "disk",
                revision: "legacy-opaque-revision"
            )],
            activeTabIndex: 0
        ))

        XCTAssertEqual(migrated.documents[0].draft, "local")
        XCTAssertNil(migrated.documents[0].baseRevision)
    }

    func testValidationAcceptsExactTabAndRecoveryBudgets() throws {
        let limits = WindowSessionLimits(
            maximumTabs: 2,
            maximumRecoveryBytes: 5,
            maximumSnapshotBytes: 10_000,
            maximumFolders: 0,
            maximumProjectDepth: 4,
            maximumProjectNodes: 20,
            maximumProjectBytes: 200
        )
        let documents = [
            WindowSessionDocument(
                documentID: "a", path: nil, name: "A", draft: "你"
            ),
            WindowSessionDocument(
                documentID: "b", path: nil, name: "B", draft: "ab"
            )
        ]
        let exact = WindowSession(documents: documents)

        XCTAssertNoThrow(try exact.validate(limits: limits))

        var tooMany = exact
        tooMany.documents.append(WindowSessionDocument(
            documentID: "c", path: nil, name: "C"
        ))
        tooMany.layout = .single(documentIDs: tooMany.documents.map(\.documentID))
        XCTAssertThrowsError(try tooMany.validate(limits: limits)) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .tooManyTabs(actual: 3, maximum: 2)
            )
        }

        var tooLarge = exact
        tooLarge.documents[1].draft = "abc"
        XCTAssertThrowsError(try tooLarge.validate(limits: limits)) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .recoveryDataTooLarge(actualBytes: 6, maximumBytes: 5)
            )
        }
    }

    func testDecodeRejectsSnapshotBeforeParsingWhenOverByteLimit() {
        let data = Data(repeating: 0x20, count: 65)
        let limits = WindowSessionLimits(
            maximumTabs: 100,
            maximumRecoveryBytes: 1_024,
            maximumSnapshotBytes: 64
        )

        XCTAssertThrowsError(try WindowSession.decodeValidated(from: data, limits: limits)) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .snapshotTooLarge(actualBytes: 65, maximumBytes: 64)
            )
        }
    }

    func testValidationRejectsBrokenDocumentAndLayoutReferences() {
        let document = WindowSessionDocument(
            documentID: "a",
            path: "relative.txt",
            name: "a"
        )
        XCTAssertThrowsError(try WindowSession(documents: [document]).validate()) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .invalidDocument("a")
            )
        }

        let valid = WindowSessionDocument(documentID: "a", path: nil, name: "a")
        let missingReference = WindowSession(
            documents: [valid],
            layout: .single(documentIDs: ["missing"])
        )
        XCTAssertThrowsError(try missingReference.validate()) { error in
            XCTAssertEqual(error as? WindowSessionValidationError, .invalidLayout)
        }

        let duplicateIDs = WindowSession(documents: [valid, valid])
        XCTAssertThrowsError(try duplicateIDs.validate()) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .duplicateDocumentID("a")
            )
        }

        var formatOnlyWithoutFallback = WindowSession(
            documents: [WindowSessionDocument(
                documentID: "format",
                path: "/tmp/format.txt",
                name: "format.txt",
                formatDirty: true,
                encoding: .utf16le,
                diskEncoding: .utf8
            )]
        )
        XCTAssertThrowsError(try formatOnlyWithoutFallback.validate()) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .invalidDocument("format")
            )
        }
        formatOnlyWithoutFallback.documents[0].recoveryContent = "fallback"
        XCTAssertNoThrow(try formatOnlyWithoutFallback.validate())

        var invalidRevision = WindowSession(
            documents: [WindowSessionDocument(
                documentID: "revision",
                path: nil,
                name: "revision",
                draft: "draft",
                baseRevision: "SHA256:not-a-digest"
            )]
        )
        XCTAssertThrowsError(try invalidRevision.validate()) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .invalidDocument("revision")
            )
        }
        invalidRevision.documents[0].baseRevision =
            "sha256:\(String(repeating: "d", count: 64))"
        XCTAssertNoThrow(try invalidRevision.validate())
    }

    func testValidationRejectsInvalidViewBookmarkAndFolders() {
        let invalidView = WindowSessionDocument(
            documentID: "a",
            path: nil,
            name: "a",
            bookmarks: [0],
            views: [WindowSessionViewState(
                group: 0,
                selections: [WindowSessionSelection(anchor: 0, head: 0)],
                mainIndex: 0,
                scrollX: 0,
                scrollY: 0
            )]
        )
        XCTAssertThrowsError(try WindowSession(documents: [invalidView]).validate()) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .invalidBookmark(documentID: "a", line: 0)
            )
        }

        var badSelection = invalidView
        badSelection.bookmarks = []
        badSelection.views[0].selections[0].anchor = 200_000_001
        XCTAssertThrowsError(try WindowSession(documents: [badSelection]).validate()) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .invalidView(documentID: "a", group: 0)
            )
        }

        let badFolder = WindowSession(
            folder: "/workspace",
            folders: ["relative"]
        )
        XCTAssertThrowsError(try badFolder.validate()) { error in
            XCTAssertEqual(
                error as? WindowSessionValidationError,
                .invalidFolder("relative")
            )
        }
    }

    func testProjectJSONRoundTripsAndHonorsDepthNodeAndByteBounds() throws {
        let project = WindowSessionProject([
            "nested": .object([
                "array": .array([.number(1), .bool(false), .null])
            ])
        ])
        let session = WindowSession(project: project)
        XCTAssertEqual(
            try WindowSession.decodeValidated(from: session.encodedData()).project,
            project
        )

        let tightDepth = WindowSessionLimits(
            maximumProjectDepth: 1,
            maximumProjectNodes: 20,
            maximumProjectBytes: 1_024
        )
        XCTAssertThrowsError(try session.validate(limits: tightDepth)) { error in
            guard case WindowSessionValidationError.projectTooDeep = error else {
                return XCTFail("Expected projectTooDeep, got \(error)")
            }
        }

        let tightNodes = WindowSessionLimits(
            maximumProjectDepth: 10,
            maximumProjectNodes: 3,
            maximumProjectBytes: 1_024
        )
        XCTAssertThrowsError(try session.validate(limits: tightNodes)) { error in
            guard case WindowSessionValidationError.projectTooComplex = error else {
                return XCTFail("Expected projectTooComplex, got \(error)")
            }
        }

        let byteHeavy = WindowSession(project: WindowSessionProject([
            "message": .string("1234567890")
        ]))
        let tightBytes = WindowSessionLimits(
            maximumProjectDepth: 10,
            maximumProjectNodes: 10,
            maximumProjectBytes: 10
        )
        XCTAssertThrowsError(try byteHeavy.validate(limits: tightBytes)) { error in
            guard case WindowSessionValidationError.projectTooLarge = error else {
                return XCTFail("Expected projectTooLarge, got \(error)")
            }
        }
    }

    func testEveryLayoutKindEnforcesItsGroupCount() throws {
        for kind in WindowSessionLayoutKind.allCases {
            let groups = Array(repeating: WindowSessionGroup(), count: kind.groupCount)
            XCTAssertNoThrow(try WindowSession(
                layout: WindowSessionLayout(kind: kind, activeGroup: 0, groups: groups)
            ).validate())

            let invalidGroups = Array(
                repeating: WindowSessionGroup(),
                count: max(0, kind.groupCount - 1)
            )
            XCTAssertThrowsError(try WindowSession(
                layout: WindowSessionLayout(
                    kind: kind,
                    activeGroup: 0,
                    groups: invalidGroups
                )
            ).validate())
        }
    }

    private func legacyTab(
        path: String? = nil,
        name: String = "Untitled",
        content: String = "",
        savedContent: String = "",
        encoding: TextEncoding = .utf8,
        savedEncoding: TextEncoding? = nil,
        eol: LineEnding = .lf,
        savedEOL: LineEnding? = nil,
        revision: String? = nil,
        encodingLocked: Bool? = nil,
        encodingIssue: EncodingIssue? = nil,
        requiresSave: Bool? = nil,
        selection: SessionSelection = SessionSelection(anchor: 0, head: 0)
    ) -> SessionTab {
        SessionTab(
            path: path,
            name: name,
            content: content,
            savedContent: savedContent,
            encoding: encoding,
            savedEncoding: savedEncoding,
            eol: eol,
            savedEOL: savedEOL,
            revision: revision,
            encodingLocked: encodingLocked,
            encodingIssue: encodingIssue,
            requiresSave: requiresSave,
            selection: selection
        )
    }
}
