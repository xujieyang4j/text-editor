import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class AppModelSessionTests: XCTestCase {
    @MainActor
    func testSessionPersistenceHooksWrapSuccessfulSaveInOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var events: [String] = []
        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: true,
            sessionWillPersist: { events.append("will") },
            sessionDidPersist: { events.append("did") }
        )

        XCTAssertTrue(model.persistSession())
        XCTAssertEqual(events, ["will", "did"])
    }

    @MainActor
    func testFailedSessionSaveDoesNotInvokeDidPersistHook() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppModelSessionHookTests-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(
            sessionURL: directory.appendingPathComponent("session.json"),
            limits: SessionStore.Limits(maximumTabs: 0, maximumDraftBytes: 1_024)
        )
        var events: [String] = []
        let model = AppModel(
            sessionStore: store,
            createInitialDocument: true,
            sessionWillPersist: { events.append("will") },
            sessionPersistenceDidFail: { events.append("failed") },
            sessionDidPersist: { events.append("did") }
        )

        XCTAssertFalse(model.persistSession())
        XCTAssertEqual(events, ["will", "failed"])
        XCTAssertEqual(model.presentedIssue?.titleContent, .saveSession)
        XCTAssertEqual(
            model.presentedIssue?.content,
            .sessionStore(.tooManyTabs(actual: 1, maximum: 0), context: nil)
        )
        XCTAssertEqual(
            model.presentedIssue.map {
                EditorLocale.zhCN.localizedAppModelIssue($0.content)
            },
            "会话包含 1 个标签页；上限为 0 个。"
        )
    }

    @MainActor
    func testVersionTwoRoundTripPreservesStableIDsLayoutViewsAndScroll() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let left = WindowSessionViewState(
            group: 0,
            selections: [WindowSessionSelection(anchor: 5, head: 1)],
            mainIndex: 0,
            scrollX: 11,
            scrollY: 22
        )
        let right = WindowSessionViewState(
            group: 1,
            selections: [
                WindowSessionSelection(anchor: 2, head: 2),
                WindowSessionSelection(anchor: 7, head: 4)
            ],
            mainIndex: 1,
            scrollX: 33,
            scrollY: 44
        )
        let session = WindowSession(
            documents: [WindowSessionDocument(
                documentID: "stable-a",
                path: nil,
                name: "Draft",
                pinned: true,
                language: "Swift",
                languageLocked: true,
                draft: "0\n1\n2\n3\n4\n5",
                encoding: .utf8,
                diskEncoding: .utf8,
                eol: .lf,
                bookmarks: [2, 5],
                views: [left, right]
            )],
            activeDocumentID: "stable-a",
            folder: "/workspace/primary",
            folders: ["/workspace/primary", "/workspace/secondary"],
            project: WindowSessionProject(["build": .string("swift build")]),
            layout: WindowSessionLayout(
                kind: .columns2,
                activeGroup: 1,
                groups: [
                    WindowSessionGroup(documentIDs: ["stable-a"], activeDocumentID: "stable-a"),
                    WindowSessionGroup(documentIDs: ["stable-a"], activeDocumentID: "stable-a")
                ]
            )
        )
        try fixture.store.save(session)

        let first = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        await first.restoreSession()
        let document = try XCTUnwrap(first.document(forSessionID: "stable-a"))
        XCTAssertEqual(first.paneLayout.kind, .columns2)
        XCTAssertEqual(first.paneLayout.activePaneIndex, 1)
        XCTAssertEqual(first.workspaceFolder, "/workspace/primary")
        XCTAssertEqual(first.workspaceFolders, ["/workspace/primary", "/workspace/secondary"])
        XCTAssertEqual(first.sessionProject, WindowSessionProject([
            "build": .string("swift build")
        ]))
        XCTAssertEqual(first.selection(for: document, inPaneAt: 0),
                       SelectionSet.single(anchor: 5, head: 1))
        XCTAssertEqual(first.selection(for: document, inPaneAt: 1), SelectionSet(
            ranges: [
                DirectedSelection(anchor: 2, head: 2),
                DirectedSelection(anchor: 7, head: 4)
            ],
            mainIndex: 1
        ))
        XCTAssertEqual(first.scrollPosition(for: document, inPaneAt: 0),
                       EditorPaneScrollPosition(x: 11, y: 22))
        XCTAssertEqual(first.scrollPosition(for: document, inPaneAt: 1),
                       EditorPaneScrollPosition(x: 33, y: 44))
        XCTAssertTrue(document.pinned)
        XCTAssertEqual(document.language, "Swift")
        XCTAssertTrue(document.languageLocked)
        XCTAssertEqual(document.bookmarks, [2, 5])

        XCTAssertTrue(first.persistSession())
        let persisted = fixture.store.loadWindowSession()
        XCTAssertEqual(persisted.formatVersion, 2)
        XCTAssertEqual(persisted.activeDocumentID, "stable-a")
        XCTAssertEqual(persisted.layout.kind, .columns2)
        XCTAssertEqual(persisted.layout.activeGroup, 1)
        XCTAssertEqual(persisted.folder, "/workspace/primary")
        XCTAssertEqual(persisted.folders, ["/workspace/primary", "/workspace/secondary"])
        XCTAssertEqual(persisted.project, session.project)
        XCTAssertEqual(persisted.documents[0].views.map(\.scrollX), [11, 33])
        XCTAssertEqual(persisted.documents[0].views.map(\.scrollY), [22, 44])

        let second = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        await second.restoreSession()
        XCTAssertNotNil(second.document(forSessionID: "stable-a"))
        XCTAssertEqual(second.paneLayout.kind, .columns2)
        XCTAssertEqual(second.paneLayout.referenceCount(for: "stable-a"), 2)
    }

    @MainActor
    func testEmptySessionCreatesOneReferencedUntitledDocument() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)

        await model.restoreSession()

        let document = try XCTUnwrap(model.documents.first)
        XCTAssertEqual(model.documents.count, 1)
        XCTAssertEqual(model.selectedDocumentID, document.id)
        XCTAssertEqual(
            model.paneLayout.referencedDocumentIDs,
            Set([document.sessionDocumentID])
        )
    }

    @MainActor
    func testSaveUsesEditorConfigEOLWithoutPreSaveDirtyState() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("configured.txt")
        let initialData = Data("one\ntwo\n".utf8)
        try initialData.write(to: fileURL)
        let opened = try TextFileCodec.decode(initialData, sourceURL: fileURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        document.setEditorConfig(ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf),
            sources: [fixture.directory.appendingPathComponent(".editorconfig")]
        ))

        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.effectiveLineEnding, .crlf)
        let saved = await model.save(document)
        XCTAssertTrue(saved)

        XCTAssertEqual(try Data(contentsOf: fileURL), Data("one\r\ntwo\r\n".utf8))
        XCTAssertEqual(document.savedLineEnding, .crlf)
        XCTAssertEqual(document.lineEnding, .crlf)
        XCTAssertNil(document.eolOverride)
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    func testExplicitEOLOverrideWinsOverEditorConfigWhenSaving() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("explicit.txt")
        let initialData = Data("one\ntwo\n".utf8)
        try initialData.write(to: fileURL)
        let opened = try TextFileCodec.decode(initialData, sourceURL: fileURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        document.setEditorConfig(ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf)
        ))
        document.chooseLineEndingForSave(.cr)

        let saved = await model.save(document)
        XCTAssertTrue(saved)

        XCTAssertEqual(try Data(contentsOf: fileURL), Data("one\rtwo\r".utf8))
        XCTAssertEqual(document.lineEnding, .cr)
        XCTAssertEqual(document.savedLineEnding, .cr)
        XCTAssertEqual(document.eolOverride, .cr)
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    func testUnconfirmedSaveUpdatesDiskRevisionButKeepsDocumentDirty() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("uncertain.txt")
        let original = Data("old".utf8)
        try original.write(to: fileURL)
        let opened = try TextFileCodec.decode(original, sourceURL: fileURL)
        let revision = TextFileCodec.revision(of: Data("new".utf8))
        let recovery = fixture.directory.appendingPathComponent("recovery-copy")
        let model = AppModel(
            sessionStore: fixture.store, createInitialDocument: false,
            atomicWrite: { _, _, _ in
                FileWriteResult(
                    revision: revision, wroteBytes: true,
                    durabilityConfirmed: false, cleanupCompleted: false,
                    recoveryArtifact: recovery
                )
            }
        )
        let document = try XCTUnwrap(model.open(openedFile: opened))
        document.text = "new"

        XCTAssertFalse(await model.save(document))

        XCTAssertEqual(document.diskRevision, revision)
        XCTAssertEqual(document.fileURL?.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(document.savedText, "old")
        XCTAssertTrue(document.requiresSave)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(
            model.fileSaveNotice,
            .durabilityUnconfirmed(
                documentID: document.id, displayName: fileURL.lastPathComponent,
                recoveryArtifact: recovery
            )
        )
    }

    @MainActor
    func testCleanupWarningKeepsCommittedSaveCleanAndVisible() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("cleanup.txt")
        let original = Data("old".utf8)
        try original.write(to: fileURL)
        let opened = try TextFileCodec.decode(original, sourceURL: fileURL)
        let replacement = Data("new".utf8)
        let revision = TextFileCodec.revision(of: replacement)
        let recovery = fixture.directory.appendingPathComponent("retained-old-version")
        let model = AppModel(
            sessionStore: fixture.store, createInitialDocument: false,
            atomicWrite: { _, _, _ in
                FileWriteResult(
                    revision: revision, wroteBytes: true,
                    cleanupCompleted: false, recoveryArtifact: recovery
                )
            }
        )
        let document = try XCTUnwrap(model.open(openedFile: opened))
        document.text = "new"

        XCTAssertTrue(await model.save(document))

        XCTAssertEqual(document.diskRevision, revision)
        XCTAssertEqual(document.savedText, "new")
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(
            model.fileSaveNotice,
            .cleanupIncomplete(
                documentID: document.id, displayName: fileURL.lastPathComponent,
                recoveryArtifact: recovery
            )
        )
        model.dismissFileSaveNotice()
        XCTAssertNil(model.fileSaveNotice)
    }

    @MainActor
    func testPersistAndRestorePreserveCurrentAndSavedFormatBaselinesAndRequiresSave() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let originalTab = SessionTab(
            path: nil,
            name: "Recovered draft",
            content: "unchanged text\n",
            savedContent: "unchanged text\n",
            encoding: .utf16leNoBom,
            savedEncoding: .utf8bom,
            eol: .crlf,
            savedEOL: .lf,
            revision: nil,
            // There is no disk baseline for an untitled tab.
            encodingLocked: false,
            requiresSave: true,
            selection: SessionSelection(anchor: 4, head: 2)
        )
        try fixture.store.save(EditorSession(tabs: [originalTab], activeTabIndex: 0))

        let firstModel = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false
        )
        await firstModel.restoreSession()

        let firstDocument = try XCTUnwrap(firstModel.documents.first)
        assertRestoredFormatState(firstDocument)
        XCTAssertEqual(firstModel.selectedDocumentID, firstDocument.id)

        // Replace the seed snapshot so the following assertions exercise
        // AppModel's own serialization rather than merely re-reading it.
        try fixture.store.save(WindowSession.empty)
        XCTAssertTrue(firstModel.persistSession())

        let persisted = fixture.store.loadWindowSession()
        XCTAssertEqual(persisted.formatVersion, 2)
        XCTAssertEqual(persisted.documents.count, 1)
        XCTAssertEqual(persisted.activeDocumentID, firstDocument.sessionDocumentID)
        let persistedDocument = try XCTUnwrap(persisted.documents.first)
        XCTAssertEqual(persistedDocument.documentID, firstDocument.sessionDocumentID)
        XCTAssertEqual(persistedDocument.encoding, .utf16leNoBom)
        XCTAssertEqual(persistedDocument.diskEncoding, .utf8bom)
        XCTAssertEqual(persistedDocument.eol, .crlf)
        XCTAssertEqual(persistedDocument.eolOverride, .crlf)
        XCTAssertFalse(persistedDocument.encodingLocked)
        XCTAssertNotNil(persistedDocument.draft)

        let secondModel = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false
        )
        await secondModel.restoreSession()

        XCTAssertEqual(secondModel.documents.count, 1)
        let secondDocument = try XCTUnwrap(secondModel.documents.first)
        assertRestoredFormatState(secondDocument)
        XCTAssertEqual(secondModel.selectedDocumentID, secondDocument.id)
        XCTAssertEqual(secondDocument.sessionDocumentID, firstDocument.sessionDocumentID)
    }

    @MainActor
    func testFileSessionUsesSavedEncodingToDecodeDiskInsteadOfPendingSaveEncoding() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let fileURL = fixture.directory.appendingPathComponent("windows-1252-source.txt")
        let diskText = "café\n"
        let diskData = Data([0x63, 0x61, 0x66, 0xe9, 0x0a])
        try diskData.write(to: fileURL)
        let revision = TextFileCodec.revision(of: diskData)

        let tab = SessionTab(
            path: fileURL.path,
            name: fileURL.lastPathComponent,
            content: diskText,
            savedContent: diskText,
            encoding: .utf16leNoBom,
            savedEncoding: .windows1252,
            eol: .lf,
            savedEOL: .lf,
            revision: revision,
            // This lock belongs to the saved Windows-1252 disk baseline, not the
            // pending UTF-16 save format.
            encodingLocked: true,
            requiresSave: false,
            selection: SessionSelection(anchor: 0, head: 0)
        )
        try fixture.store.save(EditorSession(tabs: [tab], activeTabIndex: 0))

        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false
        )
        await model.restoreSession()

        XCTAssertEqual(model.documents.count, 1)
        let document = try XCTUnwrap(model.documents.first)
        XCTAssertEqual(document.fileURL?.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(document.text, diskText)
        XCTAssertEqual(document.savedText, diskText)
        XCTAssertEqual(document.encoding, .utf16leNoBom)
        XCTAssertEqual(document.savedEncoding, .windows1252)
        XCTAssertEqual(document.lineEnding, .lf)
        XCTAssertEqual(document.savedLineEnding, .lf)
        XCTAssertFalse(document.hasTextChanges)
        XCTAssertTrue(document.hasFormatChanges)
        XCTAssertTrue(document.isDirty)
        XCTAssertFalse(document.requiresSave)
        XCTAssertTrue(document.encodingLocked)
        XCTAssertNil(document.encodingIssue)
        XCTAssertEqual(document.diskRevision, revision)
        XCTAssertNil(document.externalConflict)
    }

    @MainActor
    func testRestoreRecoversFormatOnlyDraftWhenSourceFileIsMissing() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let missingURL = fixture.directory.appendingPathComponent("missing.txt")
        let unchangedText = "Only the save encoding changed.\n"
        let tab = SessionTab(
            path: missingURL.path,
            name: missingURL.lastPathComponent,
            content: unchangedText,
            savedContent: unchangedText,
            encoding: .utf8bom,
            savedEncoding: .utf8,
            eol: .lf,
            savedEOL: .lf,
            revision: "sha256:\(String(repeating: "a", count: 64))",
            // The UTF-8 disk baseline was auto-detected; the pending UTF-8 BOM
            // save choice must not turn this into an explicit-read lock.
            encodingLocked: false,
            requiresSave: false,
            selection: SessionSelection(anchor: 5, head: 5)
        )
        try fixture.store.save(EditorSession(tabs: [tab], activeTabIndex: 0))

        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false
        )
        await model.restoreSession()

        XCTAssertEqual(model.documents.count, 1)
        let document = try XCTUnwrap(model.documents.first)
        XCTAssertNil(document.fileURL)
        XCTAssertEqual(document.displayName, "missing.txt (Recovered)")
        XCTAssertEqual(document.text, unchangedText)
        XCTAssertEqual(document.savedText, "")
        XCTAssertEqual(document.encoding, .utf8bom)
        XCTAssertEqual(document.savedEncoding, .utf8)
        XCTAssertEqual(document.lineEnding, .lf)
        XCTAssertEqual(document.savedLineEnding, .lf)
        XCTAssertFalse(document.encodingLocked)
        XCTAssertNil(document.encodingIssue)
        XCTAssertEqual(document.selection, SessionSelection(anchor: 5, head: 5))
        XCTAssertTrue(document.requiresSave)
        XCTAssertTrue(document.hasFormatChanges)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(model.selectedDocumentID, document.id)
    }

    @MainActor
    func testRestoreMissingFileDraftPreservesInvalidEncodingIssueAndRequiresSave() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let missingURL = fixture.directory.appendingPathComponent("invalid-bytes.txt")
        let draftText = "Recovered replacement character: \u{fffd}\n"
        let tab = SessionTab(
            path: missingURL.path,
            name: missingURL.lastPathComponent,
            content: draftText,
            savedContent: "original text\n",
            encoding: .utf8,
            savedEncoding: .utf8,
            eol: .lf,
            savedEOL: .lf,
            revision: "sha256:\(String(repeating: "b", count: 64))",
            // The damaged UTF-8 baseline was auto-detected, so it was not
            // explicitly locked to an encoding.
            encodingLocked: false,
            encodingIssue: .invalidBytes,
            requiresSave: true,
            selection: SessionSelection(anchor: 10, head: 10)
        )
        try fixture.store.save(EditorSession(tabs: [tab], activeTabIndex: 0))

        let model = AppModel(
            sessionStore: fixture.store,
            createInitialDocument: false
        )
        await model.restoreSession()

        XCTAssertEqual(model.documents.count, 1)
        let document = try XCTUnwrap(model.documents.first)
        XCTAssertNil(document.fileURL)
        XCTAssertEqual(document.displayName, "invalid-bytes.txt (Recovered)")
        XCTAssertEqual(document.text, draftText)
        XCTAssertEqual(document.savedText, "")
        XCTAssertEqual(document.encoding, .utf8)
        XCTAssertFalse(document.encodingLocked)
        XCTAssertEqual(document.encodingIssue, .invalidBytes)
        XCTAssertTrue(document.requiresSave)
        XCTAssertTrue(document.hasTextChanges)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.selection, SessionSelection(anchor: 10, head: 10))
        XCTAssertEqual(model.selectedDocumentID, document.id)
    }

    @MainActor
    func testFormatOnlyRecoveryUsesSavedFallbackWhenDiskChanged() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("format-only.txt")
        let original = "original text\n"
        try Data("changed on disk\n".utf8).write(to: fileURL)
        let session = WindowSession(
            documents: [WindowSessionDocument(
                documentID: "format-only",
                path: fileURL.path,
                name: fileURL.lastPathComponent,
                recoveryContent: original,
                formatDirty: true,
                baseRevision: "sha256:" + String(repeating: "a", count: 64),
                encoding: .utf8bom,
                diskEncoding: .utf8,
                eol: .lf,
                views: [WindowSessionViewState(
                    group: 0,
                    selections: [WindowSessionSelection(anchor: 8, head: 8)],
                    mainIndex: 0,
                    scrollX: 0,
                    scrollY: 0
                )]
            )],
            activeDocumentID: "format-only",
            layout: .single(
                documentIDs: ["format-only"],
                activeDocumentID: "format-only"
            )
        )
        try fixture.store.save(session)

        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        await model.restoreSession()

        let document = try XCTUnwrap(model.documents.first)
        XCTAssertEqual(document.text, original)
        XCTAssertEqual(document.savedText, "changed on disk\n")
        XCTAssertEqual(document.externalConflict?.kind, .modified)
        XCTAssertTrue(document.isDirty)
    }

    @MainActor
    func testSessionRestoreClampsBookmarksToCurrentTextAndDeduplicates() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("shortened.txt")
        try Data("one\ntwo".utf8).write(to: fileURL)
        let session = WindowSession(
            documents: [WindowSessionDocument(
                documentID: "shortened-bookmarks",
                path: fileURL.path,
                name: fileURL.lastPathComponent,
                encoding: .utf8,
                diskEncoding: .utf8,
                eol: .lf,
                bookmarks: [2, 99, 1, 2],
                views: [WindowSessionViewState(
                    group: 0,
                    selections: [WindowSessionSelection(anchor: 0, head: 0)],
                    mainIndex: 0,
                    scrollX: 0,
                    scrollY: 0
                )]
            )],
            activeDocumentID: "shortened-bookmarks",
            layout: .single(
                documentIDs: ["shortened-bookmarks"],
                activeDocumentID: "shortened-bookmarks"
            )
        )
        try fixture.store.save(session)

        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        await model.restoreSession()

        XCTAssertEqual(try XCTUnwrap(model.documents.first).bookmarks, [2, 1])
        XCTAssertTrue(model.persistSession())
        XCTAssertEqual(
            fixture.store.loadWindowSession().documents.first?.bookmarks,
                [2, 1]
        )
    }

    @MainActor
    func testUntitledSessionRestoreClampsBookmarksToRecoveredDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let session = WindowSession(
            documents: [WindowSessionDocument(
                documentID: "draft-bookmarks",
                path: nil,
                name: "Draft",
                draft: "one\ntwo\nthree",
                encoding: .utf8,
                diskEncoding: .utf8,
                eol: .lf,
                bookmarks: [3, 4, 3, 1],
                views: [WindowSessionViewState(
                    group: 0,
                    selections: [WindowSessionSelection(anchor: 0, head: 0)],
                    mainIndex: 0,
                    scrollX: 0,
                    scrollY: 0
                )]
            )],
            activeDocumentID: "draft-bookmarks",
            layout: .single(
                documentIDs: ["draft-bookmarks"],
                activeDocumentID: "draft-bookmarks"
            )
        )
        try fixture.store.save(session)

        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        await model.restoreSession()

        XCTAssertEqual(try XCTUnwrap(model.documents.first).bookmarks, [3, 1])
    }

    @MainActor
    func testCleanMissingFileRemainsAsConflictPlaceholder() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let missingURL = fixture.directory.appendingPathComponent("clean-missing.txt")
        let session = WindowSession(
            documents: [WindowSessionDocument(
                documentID: "clean-missing",
                path: missingURL.path,
                name: missingURL.lastPathComponent,
                encoding: .utf8,
                diskEncoding: .utf8,
                eol: .lf,
                views: [WindowSessionViewState(
                    group: 0,
                    selections: [WindowSessionSelection(anchor: 0, head: 0)],
                    mainIndex: 0,
                    scrollX: 0,
                    scrollY: 0
                )]
            )],
            activeDocumentID: "clean-missing",
            layout: .single(
                documentIDs: ["clean-missing"],
                activeDocumentID: "clean-missing"
            )
        )
        try fixture.store.save(session)

        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        await model.restoreSession()

        let document = try XCTUnwrap(model.documents.first)
        XCTAssertEqual(document.fileURL, missingURL)
        XCTAssertEqual(document.externalConflict?.kind, .missing)
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(model.persistSession())
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.documentID, "clean-missing")
    }

    @MainActor
    private func assertRestoredFormatState(
        _ document: EditorDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(document.text, "unchanged text\n", file: file, line: line)
        XCTAssertEqual(document.savedText, "", file: file, line: line)
        XCTAssertEqual(document.encoding, .utf16leNoBom, file: file, line: line)
        XCTAssertEqual(document.savedEncoding, .utf8bom, file: file, line: line)
        XCTAssertEqual(document.lineEnding, .crlf, file: file, line: line)
        XCTAssertEqual(document.savedLineEnding, .lf, file: file, line: line)
        XCTAssertFalse(document.encodingLocked, file: file, line: line)
        XCTAssertTrue(document.requiresSave, file: file, line: line)
        XCTAssertEqual(
            document.selection,
            SessionSelection(anchor: 4, head: 2),
            file: file,
            line: line
        )
        XCTAssertTrue(document.hasTextChanges, file: file, line: line)
        XCTAssertTrue(document.hasFormatChanges, file: file, line: line)
        XCTAssertTrue(document.isDirty, file: file, line: line)
    }

    // MARK: - EncodingNotice transitions

    @MainActor
    func testOpenPublishesInvalidAndUncertainEncodingNotices() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let invalidURL = fixture.directory.appendingPathComponent("invalid.txt")
        let uncertainURL = fixture.directory.appendingPathComponent("utf16.txt")
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)

        let invalid = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data([0xf0, 0x9f, 0x98]), sourceURL: invalidURL
        )))
        XCTAssertEqual(model.encodingNotice, .invalidBytesAfterOpen(
            documentID: invalid.id, encoding: .utf8
        ))

        let uncertainBytes = try TextFileCodec.encode(
            "hello world 中文", encoding: .utf16leNoBom, lineEnding: .lf
        )
        let uncertain = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            uncertainBytes, sourceURL: uncertainURL
        )))
        XCTAssertEqual(uncertain.encodingIssue, .uncertain)
        XCTAssertEqual(model.encodingNotice, .uncertainEncodingAfterOpen(
            documentID: uncertain.id, encoding: .utf16leNoBom
        ))
    }

    @MainActor
    func testReopenSetsReopenSuccessNoticeForCleanFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("clean.txt")
        try Data("hello\n".utf8).write(to: fileURL)
        let opened = try TextFileCodec.decode(
            Data("hello\n".utf8), sourceURL: fileURL
        )
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        XCTAssertNil(model.encodingNotice)

        let reopened = await model.reopen(document, using: .utf8)
        XCTAssertTrue(reopened)
        XCTAssertEqual(model.encodingNotice, .reopenSuccess(
            documentID: document.id, requestedEncoding: .utf8,
            actualEncoding: .utf8,
            displayName: "clean.txt"
        ))
    }

    @MainActor
    func testReopenSetsInvalidBytesNoticeWhenDecodingFails() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("broken.txt")
        // Incomplete UTF-8 sequence triggers invalidBytes.
        try Data([0xf0, 0x9f, 0x98]).write(to: fileURL)
        let opened = try TextFileCodec.decode(
            Data([0xf0, 0x9f, 0x98]), sourceURL: fileURL
        )
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        XCTAssertEqual(document.encodingIssue, .invalidBytes)
        XCTAssertEqual(
            model.encodingNotice, .invalidBytesAfterOpen(
                documentID: document.id, encoding: .utf8
            )
        )

        let reopened = await model.reopen(document, using: .utf8)
        XCTAssertTrue(reopened)
        XCTAssertEqual(model.encodingNotice, .invalidBytesAfterReopen(
            documentID: document.id, requestedEncoding: .utf8
        ))
    }

    @MainActor
    func testCheckForExternalChangeSetsNoticeWhenCleanDocumentAutoReloadsWithInvalidBytes() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("external.txt")
        try Data("clean\n".utf8).write(to: fileURL)
        let opened = try TextFileCodec.decode(
            Data("clean\n".utf8), sourceURL: fileURL
        )
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        model.selectDocument(id: document.id)
        XCTAssertNil(document.encodingIssue)
        XCTAssertNil(model.encodingNotice)

        // Write malformed bytes to disk so the next poll sees a changed file.
        try Data([0xf0, 0x9f, 0x98]).write(to: fileURL)
        await model.checkForExternalChange(document)

        XCTAssertEqual(document.encodingIssue, .invalidBytes)
        XCTAssertEqual(model.encodingNotice, .invalidBytesAfterExternalReload(
            documentID: document.id, encoding: .utf8
        ))
    }

    @MainActor
    func testCheckForExternalChangeDoesNotSetNoticeForNonActiveDocument() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let backgroundURL = fixture.directory.appendingPathComponent("bg.txt")
        let foregroundURL = fixture.directory.appendingPathComponent("front.txt")
        try Data("bg\n".utf8).write(to: backgroundURL)
        try Data("front\n".utf8).write(to: foregroundURL)
        let backgroundFile = try TextFileCodec.decode(
            Data("bg\n".utf8), sourceURL: backgroundURL
        )
        let foregroundFile = try TextFileCodec.decode(
            Data("front\n".utf8), sourceURL: foregroundURL
        )
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let backgroundDocument = try XCTUnwrap(model.open(openedFile: backgroundFile))
        let foregroundDocument = try XCTUnwrap(model.open(openedFile: foregroundFile))
        XCTAssertEqual(model.selectedDocumentID, foregroundDocument.id)
        XCTAssertNil(model.encodingNotice)

        try Data([0xf0, 0x9f, 0x98]).write(to: backgroundURL)
        await model.checkForExternalChange(backgroundDocument)

        XCTAssertEqual(backgroundDocument.encodingIssue, .invalidBytes)
        // Notice must not fire for a non-active document.
        XCTAssertNil(model.encodingNotice)
    }

    @MainActor
    func testDismissEncodingNoticeClearsNotice() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("dismiss.txt")
        try Data("hello\n".utf8).write(to: fileURL)
        let opened = try TextFileCodec.decode(
            Data("hello\n".utf8), sourceURL: fileURL
        )
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        _ = await model.reopen(document, using: .utf8)
        XCTAssertNotNil(model.encodingNotice)

        model.dismissEncodingNotice()
        XCTAssertNil(model.encodingNotice)
    }

    @MainActor
    func testSelectingAnotherDocumentClearsDocumentScopedEncodingNotice() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let warnedURL = fixture.directory.appendingPathComponent("warned.txt")
        let otherURL = fixture.directory.appendingPathComponent("other.txt")
        try Data("warned\n".utf8).write(to: warnedURL)
        try Data("other\n".utf8).write(to: otherURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let warned = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data("warned\n".utf8), sourceURL: warnedURL
        )))
        let other = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data("other\n".utf8), sourceURL: otherURL
        )))

        model.selectDocument(id: warned.id)
        let reopened = await model.reopen(warned, using: .utf8)
        XCTAssertTrue(reopened)
        XCTAssertEqual(model.encodingNotice?.documentID, warned.id)

        model.selectDocument(id: other.id)

        XCTAssertEqual(model.selectedDocumentID, other.id)
        XCTAssertNil(model.encodingNotice)
    }

    @MainActor
    func testReopeningBackgroundDocumentDoesNotPublishWindowNotice() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let backgroundURL = fixture.directory.appendingPathComponent("background.txt")
        let foregroundURL = fixture.directory.appendingPathComponent("foreground.txt")
        try Data("background\n".utf8).write(to: backgroundURL)
        try Data("foreground\n".utf8).write(to: foregroundURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let background = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data("background\n".utf8), sourceURL: backgroundURL
        )))
        let foreground = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data("foreground\n".utf8), sourceURL: foregroundURL
        )))
        XCTAssertEqual(model.selectedDocumentID, foreground.id)

        let reopened = await model.reopen(background, using: .utf8)

        XCTAssertTrue(reopened)
        XCTAssertEqual(model.selectedDocumentID, foreground.id)
        XCTAssertNil(model.encodingNotice)
    }

    @MainActor
    func testClosingNoticeDocumentClearsDocumentScopedEncodingNotice() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("closing.txt")
        try Data("closing\n".utf8).write(to: fileURL)
        let model = AppModel(sessionStore: fixture.store, createInitialDocument: false)
        let document = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data("closing\n".utf8), sourceURL: fileURL
        )))
        let reopened = await model.reopen(document, using: .utf8)
        XCTAssertTrue(reopened)
        XCTAssertEqual(model.encodingNotice?.documentID, document.id)

        model.requestClose(document)

        XCTAssertFalse(model.documents.contains(where: { $0.id == document.id }))
        XCTAssertNil(model.encodingNotice)
    }

    @MainActor
    func testSaveActionOutcomePreservesTypedAppModelFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let fileURL = fixture.directory.appendingPathComponent("typed-save.txt")
        let original = Data("old".utf8)
        try original.write(to: fileURL)
        let model = AppModel(
            sessionStore: fixture.store, createInitialDocument: false,
            atomicWrite: { _, _, _ in
                throw FileWriteFailure.invalidExpectedRevision
            }
        )
        let actions = EditorActionController(model: model)
        await actions.restoreSessionIfNeeded()
        let document = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            original, sourceURL: fileURL
        )))
        document.text = "new"

        let outcome = await actions.saveCurrentDocumentOutcome()

        guard case let .failedPresentation(.appModel(issue)) = outcome else {
            return XCTFail("Expected a typed AppModel save failure")
        }
        XCTAssertEqual(issue.titleContent, .saveFile)
        XCTAssertEqual(
            issue.content,
            .fileWrite(.invalidExpectedRevision, context: "typed-save.txt")
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedCommandPresentation(.appModel(issue)),
            "typed-save.txt：预期的文件修订版本无效。"
        )
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LumenEditorAppTests-\(UUID().uuidString)",
                isDirectory: true
            )
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
