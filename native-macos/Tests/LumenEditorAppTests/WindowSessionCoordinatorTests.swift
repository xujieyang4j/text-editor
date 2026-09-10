import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class WindowSessionCoordinatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSessionIDRejectsUnsafeValuesAndRoundTripsAsAWindowGroupValue() throws {
        for invalid in ["", "../escape", "a/b", "under_score", "窗口"] {
            XCTAssertNil(WindowSessionID(rawValue: invalid))
            XCTAssertThrowsError(try WindowSessionID(validating: invalid))
        }

        let id = try WindowSessionID(validating: "window-AbC-123")
        let value = WindowSessionSceneValue(
            id: id,
            presentation: WindowSessionPresentation(
                bounds: WindowSessionBounds(x: 10, y: 20, width: 1_080, height: 720),
                state: .maximized
            )
        )
        XCTAssertEqual(try JSONDecoder().decode(
            WindowSessionSceneValue.self,
            from: JSONEncoder().encode(value)
        ), value)
    }

    func testEmptyRegistryStartsOneLegacyWindowAndMigratesVersionOneSession() throws {
        let fixture = makeFixture()
        let legacyStore = SessionStore(
            sessionURL: fixture.directory.appendingPathComponent(
                SessionStore.sessionFileName
            )
        )
        try legacyStore.save(EditorSession(
            tabs: [SessionTab(
                path: nil,
                name: "Migrated",
                content: "draft",
                savedContent: "",
                encoding: .utf8,
                eol: .lf,
                revision: nil,
                selection: SessionSelection(anchor: 2, head: 2)
            )],
            activeTabIndex: 0
        ))

        XCTAssertEqual(
            try fixture.coordinator.startupRestorationIDs(),
            [.legacy]
        )
        XCTAssertEqual(try fixture.coordinator.startupPlan().primary.id, .legacy)
        XCTAssertEqual(try fixture.coordinator.startupPlan().additional, [])
        let composition = try fixture.coordinator.composition(for: .legacy)
        XCTAssertEqual(composition.sessionStore.sessionURL, legacyStore.sessionURL)
        let migrated = composition.sessionStore.loadWindowSession()
        XCTAssertEqual(migrated.formatVersion, WindowSession.currentFormatVersion)
        XCTAssertEqual(migrated.documents.map(\.documentID), ["legacy-document-0"])
        XCTAssertEqual(migrated.documents.first?.draft, "draft")

        try composition.sessionStore.save(migrated)
        try fixture.coordinator.didPersist(.legacy)
        XCTAssertEqual(fixture.store.windowSessionIDs(), ["legacy"])
        try composition.close()
    }

    func testCleanFirstLaunchUsesANonLegacyPerWindowID() throws {
        let fixture = makeFixture(ids: ["fresh-window"])

        XCTAssertEqual(
            try fixture.coordinator.startupRestorationIDs().map(\.rawValue),
            ["fresh-window"]
        )
    }

    func testCleanFirstLaunchPlanIsIdempotent() {
        let fixture = makeFixture(ids: ["fresh-one", "fresh-two"])

        let first = try! fixture.coordinator.startupPlan()
        let second = try! fixture.coordinator.startupPlan()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.primary.id.rawValue, "fresh-one")
    }

    func testRestorationUsesNewestFirstRegistryOrderCapsAtTwelveAndCarriesPresentation() throws {
        let fixture = makeFixture()
        for index in 0..<14 {
            let presentation = WindowSessionPresentation(
                bounds: WindowSessionBounds(
                    x: Double(index),
                    y: Double(index + 1),
                    width: 800,
                    height: 600
                ),
                state: index == 13 ? .fullScreen : .normal
            )
            try fixture.store.registerWindowSession(
                "window-\(index)",
                presentation: presentation,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
            let url = try fixture.store.windowSessionURL(for: "window-\(index)")
            try SessionStore(sessionURL: url).save(WindowSession.empty)
        }

        let values = try fixture.coordinator.startupSceneValues()
        XCTAssertEqual(values.count, RecentItemsStore.maximumWindowSessions)
        XCTAssertEqual(values.map { $0.id.rawValue }, (2..<14).reversed().map { "window-\($0)" })
        XCTAssertEqual(values.first?.presentation?.bounds?.x, 13)
        XCTAssertEqual(values.first?.presentation?.state, .fullScreen)
        let plan = try fixture.coordinator.startupPlan()
        XCTAssertEqual(plan.all, values)
        XCTAssertEqual(try fixture.coordinator.startupPlan(), plan)
    }

    func testStaleRegistryEntriesWithoutSnapshotsAreSkipped() throws {
        let fixture = makeFixture(ids: ["fresh-after-stale"])
        try fixture.store.registerWindowSession(
            "missing",
            at: Date(timeIntervalSince1970: 9)
        )

        XCTAssertEqual(
            try fixture.coordinator.startupRestorationIDs().map(\.rawValue),
            ["fresh-after-stale"]
        )
        XCTAssertEqual(fixture.store.windowSessions(), [])
    }

    func testStaleEntriesAreSkippedWithoutDroppingValidRestorationOrder() throws {
        let fixture = makeFixture()
        try fixture.store.registerWindowSession(
            "valid-old", at: Date(timeIntervalSince1970: 1)
        )
        try SessionStore(
            sessionURL: fixture.store.windowSessionURL(for: "valid-old")
        ).save(WindowSession.empty)
        try fixture.store.registerWindowSession(
            "missing-new", at: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(
            try fixture.coordinator.startupRestorationIDs().map(\.rawValue),
            ["valid-old"]
        )
        XCTAssertEqual(fixture.store.windowSessionIDs(), ["valid-old"])
    }

    func testStartupPlanIsStableAfterRegistryChanges() throws {
        let fixture = makeFixture(ids: ["initial-window"])
        let first = try fixture.coordinator.startupPlan()
        try fixture.store.registerWindowSession("late-entry")
        try SessionStore(
            sessionURL: fixture.store.windowSessionURL(for: "late-entry")
        ).save(WindowSession.empty)

        XCTAssertEqual(try fixture.coordinator.startupPlan(), first)
    }

    @MainActor
    func testCompositionInjectsAnIsolatedStoreAndRegistersAfterSuccessfulModelSave() throws {
        let fixture = makeFixture(ids: ["window-one", "window-two"])
        let firstValue = try fixture.coordinator.newSceneValue()
        let secondValue = try fixture.coordinator.newSceneValue()
        let first = try fixture.coordinator.composition(for: firstValue)
        let second = try fixture.coordinator.composition(for: secondValue)

        XCTAssertEqual(first.sessionStore.sessionURL.lastPathComponent, "session-window-one.json")
        XCTAssertEqual(second.sessionStore.sessionURL.lastPathComponent, "session-window-two.json")
        XCTAssertNotEqual(first.sessionStore.sessionURL, second.sessionStore.sessionURL)
        XCTAssertEqual(fixture.store.windowSessions(), [])

        let firstModel = first.makeAppModel(createInitialDocument: true)
        let secondModel = second.makeAppModel(createInitialDocument: true)
        firstModel.documents[0].text = "first draft"
        secondModel.documents[0].text = "second draft"
        XCTAssertTrue(firstModel.persistSession())
        XCTAssertTrue(secondModel.persistSession())

        XCTAssertEqual(Set(fixture.store.windowSessionIDs()), ["window-one", "window-two"])
        XCTAssertEqual(first.sessionStore.loadWindowSession().documents.first?.draft, "first draft")
        XCTAssertEqual(second.sessionStore.loadWindowSession().documents.first?.draft, "second draft")
        try first.close()
        try second.close()
    }

    @MainActor
    func testFailedSnapshotDoesNotCreateRegistryEntry() throws {
        let fixture = makeFixture(
            ids: ["window-fails"],
            sessionLimits: SessionStore.Limits(
                maximumTabs: 0,
                maximumDraftBytes: 1_024
            )
        )
        let composition = try fixture.coordinator.composition(
            for: fixture.coordinator.newSceneValue()
        )
        let model = composition.makeAppModel(createInitialDocument: true)

        XCTAssertFalse(model.persistSession())
        XCTAssertEqual(fixture.store.windowSessions(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: composition.sessionStore.sessionURL.path
        ))
        try composition.close()
    }

    func testPresentationBeforeFirstSaveIsDeferredThenPersisted() throws {
        let fixture = makeFixture(ids: ["window-bounds"])
        let composition = try fixture.coordinator.composition(
            for: fixture.coordinator.newSceneValue()
        )
        let presentation = WindowSessionPresentation(
            bounds: WindowSessionBounds(x: -100, y: 42, width: 1_200, height: 800),
            state: .maximized
        )

        XCTAssertFalse(try composition.updatePresentation(presentation))
        XCTAssertEqual(fixture.store.windowSessions(), [])
        try composition.saveSession(.empty)

        XCTAssertEqual(fixture.store.windowSessions().first?.presentation, presentation)
        try composition.close()
    }

    func testStagedPresentationIsCommittedByTheNextSnapshotSave() throws {
        let fixture = makeFixture(ids: ["window-staged"])
        let composition = try fixture.coordinator.composition(
            for: fixture.coordinator.newSceneValue()
        )
        let presentation = WindowSessionPresentation(
            bounds: WindowSessionBounds(x: 20, y: 30, width: 950, height: 650),
            state: .normal
        )

        composition.stagePresentation(presentation)
        XCTAssertEqual(fixture.store.windowSessions(), [])
        try composition.saveSession(.empty)
        XCTAssertEqual(fixture.store.windowSessions().first?.presentation, presentation)
        try composition.close()
    }

    func testClosePreservesRecoverableSessionUnlessDiscardIsExplicit() throws {
        let fixture = makeFixture(ids: ["window-close"])
        let id = try fixture.coordinator.newWindowID()
        let first = try fixture.coordinator.composition(for: id)
        try first.saveSession(.empty)
        try first.close()

        XCTAssertEqual(fixture.store.windowSessionIDs(), [id.rawValue])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.sessionStore.sessionURL.path))
        XCTAssertFalse(fixture.coordinator.isLive(id))

        let reopened = try fixture.coordinator.composition(for: id)
        try reopened.close(.discardEmptySession)
        XCTAssertEqual(fixture.store.windowSessions(), [])
        // Registry removal is deliberately independent of the recoverable
        // snapshot; a later cleanup policy may safely reap this orphan.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.sessionStore.sessionURL.path))
    }

    func testLatePersistenceAfterCloseCannotResurrectDiscardedRegistryEntry() throws {
        let fixture = makeFixture(ids: ["window-late"])
        let composition = try fixture.coordinator.composition(
            for: fixture.coordinator.newSceneValue()
        )
        try composition.saveSession(.empty)
        try composition.close(.discardEmptySession)

        try fixture.coordinator.didPersist(composition.id)
        XCTAssertEqual(fixture.store.windowSessions(), [])
        XCTAssertFalse(try composition.updatePresentation(WindowSessionPresentation()))
    }

    @MainActor
    func testFailedModelSaveReleasesCoordinatorPersistenceGate() throws {
        let fixture = makeFixture(
            ids: ["window-retry-close"],
            sessionLimits: SessionStore.Limits(
                maximumTabs: 0, maximumDraftBytes: 1_024
            )
        )
        let composition = try fixture.coordinator.composition(
            for: fixture.coordinator.newSceneValue()
        )
        let model = composition.makeAppModel(createInitialDocument: true)

        XCTAssertFalse(model.persistSession())
        XCTAssertNoThrow(try composition.close())
        XCTAssertFalse(fixture.coordinator.isLive(composition.id))
    }

    func testRepeatedCompositionForTheSameSceneReusesOneSessionOwnerUntilClose() throws {
        let fixture = makeFixture()
        let first = try fixture.coordinator.composition(for: .legacy)
        let duplicate = try fixture.coordinator.composition(for: .legacy)
        XCTAssertTrue(first === duplicate)
        try first.close()
        let reopened = try fixture.coordinator.composition(for: .legacy)
        XCTAssertFalse(first === reopened)
        try reopened.close()
    }

    func testGeneratedIDsRetryInvalidReservedAndRegisteredCandidates() throws {
        let fixture = makeFixture(ids: [
            "../bad", "legacy", "window-existing",
            "window-unique", "window-unique", "window-next"
        ])
        try fixture.store.registerWindowSession("window-existing")

        let first = try fixture.coordinator.newSceneValue()
        let second = try fixture.coordinator.newSceneValue()
        XCTAssertEqual(first.id.rawValue, "window-unique")
        XCTAssertEqual(second.id.rawValue, "window-next")
        fixture.coordinator.releaseUnmaterializedScene(first)
        fixture.coordinator.releaseUnmaterializedScene(second)
    }

    func testConcurrentWindowCreationAndPersistenceUsesUniqueFilesWithoutLostRegistryUpdates() {
        let counter = LockedCounter()
        let fixture = makeFixture(idGenerator: {
            "concurrent-\(counter.next())"
        })
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 8
        let results = LockedResults()

        for _ in 0..<24 {
            queue.addOperation {
                do {
                    let value = try fixture.coordinator.newSceneValue()
                    let composition = try fixture.coordinator.composition(for: value)
                    try composition.saveSession(.empty)
                    results.append(id: value.id, url: composition.sessionStore.sessionURL)
                    try composition.close()
                } catch {
                    results.append(error: error)
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        XCTAssertEqual(results.errors.count, 0)
        XCTAssertEqual(results.ids.count, 24)
        XCTAssertEqual(Set(results.ids).count, 24)
        XCTAssertEqual(Set(results.urls).count, 24)
        XCTAssertEqual(fixture.store.windowSessions().count, 12)
        XCTAssertEqual(Set(fixture.store.windowSessionIDs()).count, 12)
        XCTAssertTrue(results.urls.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @MainActor
    func testRestartWithoutCommitMarkerCleansStagingAndKeepsLiveSnapshot() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "uncommitted-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "live draft"
        XCTAssertTrue(model.flushSession())
        model.documents[0].text = "discarded draft"
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [
                model.documents[0].id: model.documents[0].buffer.revision
            ]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        let restored = try restarted.composition(for: id)
        XCTAssertEqual(restored.sessionStore.loadWindowSession().documents.first?.draft,
                       "discarded draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
    }

    @MainActor
    func testCompleteCommitMarkerActivatesEveryStagedSnapshot() throws {
        let fixture = makeFixture()
        let ids = try ["a-committed-window", "b-committed-window"].map {
            try WindowSessionID(validating: $0)
        }
        let compositions = try ids.map {
            try fixture.coordinator.composition(for: $0)
        }
        let models = compositions.map { $0.makeAppModel(createInitialDocument: true) }
        for (index, model) in models.enumerated() {
            model.documents[0].text = "live draft \(index)"
            XCTAssertTrue(model.flushSession())
            model.documents[0].text = "committed draft \(index)"
        }
        for id in ids { try fixture.coordinator.didPersist(id) }
        let liveURLs = compositions.map { $0.sessionStore.sessionURL }
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: Set(ids)
        ))
        for model in models {
            let document = model.documents[0]
            XCTAssertTrue(model.preflightApplicationClosePersistence(
                documentRevisions: [document.id: document.buffer.revision]
            ))
        }
        let stagedURLs = try ids.map { id in
            try XCTUnwrap(
                fixture.coordinator.terminationTransactionArtifactURLs(for: id)
            ).snapshot
        }
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertEqual(Set(try restarted.startupRestorationIDs()), Set(ids))
        for (index, id) in ids.enumerated() {
            let restored = try restarted.composition(for: id)
            XCTAssertEqual(restored.sessionStore.sessionURL, liveURLs[index])
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: stagedURLs[index].path
            ))
            XCTAssertEqual(restored.sessionStore.loadWindowSession().documents.first?.draft,
                           "committed draft \(index)")
        }
    }

    @MainActor
    func testReopenedCommittedGenerationSurvivesOrdinarySaveAndSecondRestart() async throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "saved-generation-window")
        let initial = try fixture.coordinator.composition(for: id)
        let initialModel = initial.makeAppModel(createInitialDocument: true)
        initialModel.documents[0].text = "first generation"
        XCTAssertTrue(initialModel.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(initialModel.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()

        let firstRestart = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        let reopened = try firstRestart.composition(for: id)
        let reopenedModel = reopened.makeAppModel(createInitialDocument: false)
        await reopenedModel.restoreSession()
        XCTAssertEqual(reopenedModel.documents.first?.text, "first generation")
        reopenedModel.documents[0].text = "saved after restart"
        XCTAssertTrue(reopenedModel.flushSession())

        let secondRestart = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        let restored = try secondRestart.composition(for: id)
        XCTAssertEqual(
            restored.sessionStore.loadWindowSession().documents.first?.draft,
            "saved after restart"
        )
    }

    @MainActor
    func testCleanReopenedGenerationCanCommitAnotherTermination() async throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "second-quit-window")
        let initial = try fixture.coordinator.composition(for: id)
        let initialModel = initial.makeAppModel(createInitialDocument: true)
        XCTAssertTrue(initialModel.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(initialModel.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        let reopened = try restarted.composition(for: id)
        let reopenedModel = reopened.makeAppModel(createInitialDocument: false)
        await reopenedModel.restoreSession()
        XCTAssertTrue(restarted.beginTerminationTransaction(expectedWindowIDs: [id]))
        XCTAssertTrue(reopenedModel.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(restarted.commitTerminationTransaction())
        restarted.finalizeCommittedTerminationTransaction()
    }

    @MainActor
    func testSecondQuitDoesNotRegressRegisteredWindowNotParticipating() async throws {
        let fixture = makeFixture()
        let firstID = try WindowSessionID(validating: "carry-forward-window")
        let secondID = try WindowSessionID(validating: "active-second-window")
        let first = try fixture.coordinator.composition(for: firstID)
        let second = try fixture.coordinator.composition(for: secondID)
        let firstModel = first.makeAppModel(createInitialDocument: true)
        let secondModel = second.makeAppModel(createInitialDocument: true)
        firstModel.documents[0].text = "carried draft"
        secondModel.documents[0].text = "second draft"
        XCTAssertTrue(firstModel.flushSession())
        XCTAssertTrue(secondModel.flushSession())
        try fixture.coordinator.didPersist(firstID)
        try fixture.coordinator.didPersist(secondID)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [firstID, secondID]
        ))
        XCTAssertTrue(firstModel.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(secondModel.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()

        let restartedStore = RecentItemsStore(directoryURL: fixture.directory)
        let restarted = WindowSessionCoordinator(recentItemsStore: restartedStore)
        let reopenedSecond = try restarted.composition(for: secondID)
        let reopenedSecondModel = reopenedSecond.makeAppModel(createInitialDocument: false)
        await reopenedSecondModel.restoreSession()
        XCTAssertTrue(restarted.beginTerminationTransaction(
            expectedWindowIDs: [secondID]
        ))
        XCTAssertTrue(reopenedSecondModel.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(restarted.commitTerminationTransaction())
        restarted.finalizeCommittedTerminationTransaction()

        let twiceRestarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertEqual(
            try twiceRestarted.composition(for: firstID)
                .sessionStore.loadWindowSession().documents.first?.draft,
            "carried draft"
        )
        XCTAssertEqual(
            try twiceRestarted.composition(for: secondID)
                .sessionStore.loadWindowSession().documents.first?.draft,
            "second draft"
        )
    }

    @MainActor
    func testRestartRemovesStaleSidecarBesideValidCommittedGeneration() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "active-generation-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "active generation"
        XCTAssertTrue(model.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let activeArtifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        let staleURL = try fixture.store.windowSessionURL(for: id.rawValue)
            .appendingPathExtension(
                "termination-\(UUID().uuidString.lowercased())"
            )
        try Data("stale".utf8).write(to: staleURL, options: .atomic)

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        _ = try restarted.startupPlan()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: activeArtifacts.snapshot.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    }

    func testRestartCleansSidecarFromCrashedNewTransactionAfterOlderCommit() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "crashed-next-generation-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "committed generation"
        XCTAssertTrue(model.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        let staleURL = try fixture.store.windowSessionURL(for: id.rawValue)
            .appendingPathExtension(
                "termination-\(UUID().uuidString.lowercased())"
            )
        try Data("new transaction crashed".utf8).write(
            to: staleURL, options: .atomic
        )

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        _ = try restarted.startupPlan()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertEqual(
            try restarted.composition(for: id)
                .sessionStore.loadWindowSession().documents.first?.draft,
            "committed generation"
        )
    }

    @MainActor
    func testMissingCommittedSidecarKeepsEveryLiveSnapshotAndRegistryEntry() throws {
        let fixture = makeFixture()
        let ids = try ["a-incomplete-window", "b-incomplete-window"].map {
            try WindowSessionID(validating: $0)
        }
        let compositions = try ids.map {
            try fixture.coordinator.composition(for: $0)
        }
        let models = compositions.map { $0.makeAppModel(createInitialDocument: true) }
        for (index, model) in models.enumerated() {
            model.documents[0].text = "live draft \(index)"
            XCTAssertTrue(model.flushSession())
            model.documents[0].text = "discarded draft \(index)"
        }
        for id in ids { try fixture.coordinator.didPersist(id) }
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: Set(ids)
        ))
        for model in models {
            let document = model.documents[0]
            XCTAssertTrue(model.preflightApplicationClosePersistence(
                documentRevisions: [document.id: document.buffer.revision]
            ))
        }
        let firstArtifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: ids[0])
        )
        let secondArtifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: ids[1])
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        try FileManager.default.removeItem(at: secondArtifacts.snapshot)

        let restartedStore = RecentItemsStore(directoryURL: fixture.directory)
        let restarted = WindowSessionCoordinator(recentItemsStore: restartedStore)
        XCTAssertEqual(Set(try restarted.startupRestorationIDs()), Set(ids))
        XCTAssertEqual(Set(restartedStore.windowSessionIDs()), Set(ids.map(\.rawValue)))
        for (index, id) in ids.enumerated() {
            let restored = try restarted.composition(for: id)
            XCTAssertEqual(restored.sessionStore.sessionURL,
                           try restartedStore.windowSessionURL(for: id.rawValue))
            XCTAssertEqual(restored.sessionStore.loadWindowSession().documents.first?.draft,
                           "discarded draft \(index)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstArtifacts.marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstArtifacts.snapshot.path))
    }

    @MainActor
    func testCorruptCommitMarkerFailsClosedAndPreservesRecoveryArtifacts() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "corrupt-marker-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "canonical draft"
        XCTAssertTrue(model.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        try Data("not json".utf8).write(to: artifacts.marker, options: .atomic)

        let restartedStore = RecentItemsStore(directoryURL: fixture.directory)
        let restarted = WindowSessionCoordinator(recentItemsStore: restartedStore)
        XCTAssertThrowsError(try restarted.startupRestorationIDs())
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
    }

    @MainActor
    func testCommitRequiresEveryExpectedWindowIncludingCleanWindow() throws {
        let fixture = makeFixture()
        let dirtyID = try WindowSessionID(validating: "dirty-window")
        let cleanID = try WindowSessionID(validating: "clean-window")
        let dirty = try fixture.coordinator.composition(for: dirtyID)
        let clean = try fixture.coordinator.composition(for: cleanID)
        let dirtyModel = dirty.makeAppModel(createInitialDocument: true)
        let cleanModel = clean.makeAppModel(createInitialDocument: true)
        dirtyModel.documents[0].text = "dirty draft"
        XCTAssertTrue(dirtyModel.flushSession())
        XCTAssertTrue(cleanModel.flushSession())
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [dirtyID, cleanID]
        ))
        let dirtyDocument = dirtyModel.documents[0]
        XCTAssertTrue(dirtyModel.preflightApplicationClosePersistence(
            documentRevisions: [
                dirtyDocument.id: dirtyDocument.buffer.revision
            ]
        ))
        XCTAssertFalse(fixture.coordinator.commitTerminationTransaction())
        XCTAssertTrue(cleanModel.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
    }

    @MainActor
    func testInterruptedMaterializationRetainsTransactionForIdempotentRetry() throws {
        let fixture = makeFixture()
        let ids = try ["a-replay-window", "b-replay-window"].map {
            try WindowSessionID(validating: $0)
        }
        let compositions = try ids.map {
            try fixture.coordinator.composition(for: $0)
        }
        let models = compositions.map { $0.makeAppModel(createInitialDocument: true) }
        for (index, model) in models.enumerated() {
            model.documents[0].text = "old draft \(index)"
            XCTAssertTrue(model.flushSession())
            model.documents[0].text = "new draft \(index)"
        }
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: Set(ids)
        ))
        for model in models {
            let document = model.documents[0]
            XCTAssertTrue(model.preflightApplicationClosePersistence(
                documentRevisions: [document.id: document.buffer.revision]
            ))
        }
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: ids[0])
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()

        let interrupted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertFalse(interrupted.materializeCommittedTerminationForTesting {
            $0 == 0
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.marker.path))
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(
                SessionStore(
                    sessionURL: try fixture.store.windowSessionURL(for: id.rawValue)
                ).loadWindowSession().documents.first?.draft,
                "new draft \(index)"
            )
        }
        XCTAssertThrowsError(try interrupted.startupPlan()) { error in
            XCTAssertEqual(
                error as? WindowSessionCoordinatorError,
                .terminationRecoveryFailed
            )
        }
        XCTAssertThrowsError(try interrupted.composition(for: ids[0])) { error in
            XCTAssertEqual(
                error as? WindowSessionCoordinatorError,
                .terminationRecoveryFailed
            )
        }

        let retried = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertEqual(Set(try retried.startupRestorationIDs()), Set(ids))
        for (index, id) in ids.enumerated() {
            let session = try retried.composition(for: id)
                .sessionStore.loadWindowSession()
            XCTAssertTrue(session.documents.isEmpty, "window \(index)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.marker.path))
    }

    @MainActor
    func testOversizedCommitMarkerFailsClosedWithoutDroppingCanonical() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "oversized-marker-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "canonical survives"
        XCTAssertTrue(model.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        try Data(repeating: 65, count: 64 * 1_024 + 1).write(
            to: artifacts.marker, options: .atomic
        )

        let restartedStore = RecentItemsStore(directoryURL: fixture.directory)
        let restarted = WindowSessionCoordinator(recentItemsStore: restartedStore)
        XCTAssertThrowsError(try restarted.startupRestorationIDs())
        XCTAssertEqual(
            composition.sessionStore.loadWindowSession().documents.first?.draft,
            "canonical survives"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
    }

    @MainActor
    func testMaterializedMarkerRepairsAConflictingCanonicalFromCommittedSidecar() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "materialized-marker-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "staged value"
        XCTAssertTrue(model.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()

        var marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: artifacts.marker)
            ) as? [String: Any]
        )
        marker["state"] = "materialized"
        try JSONSerialization.data(withJSONObject: marker).write(
            to: artifacts.marker, options: .atomic
        )
        model.documents[0].text = "new canonical value"
        XCTAssertTrue(model.flushSession())

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        _ = try restarted.startupPlan()
        XCTAssertEqual(
            try restarted.composition(for: id)
                .sessionStore.loadWindowSession().documents.first?.draft,
            "staged value"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
    }

    @MainActor
    func testPostMaterializedCanonicalCorruptionBlocksMarkerConsumption() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "post-marker-fault-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "committed value"
        XCTAssertTrue(model.flushSession())
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        let canonical = try fixture.store.windowSessionURL(for: id.rawValue)

        XCTAssertFalse(
            WindowSessionCoordinator(
                recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
            ).materializeCommittedTerminationWithPostWriteFaultForTesting {
                try Data("corrupt canonical".utf8).write(
                    to: canonical, options: .atomic
                )
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
    }

    @MainActor
    func testStartupRecoveryControllerRetriesAfterRecoverableFailure() throws {
        let fixture = makeFixture()
        var attempts = 0
        let controller = StartupRecoveryController(
            coordinator: fixture.coordinator,
            loadPlan: {
                attempts += 1
                if attempts == 1 {
                    throw WindowSessionCoordinatorError.terminationRecoveryFailed
                }
                return try fixture.coordinator.retryStartupPlan()
            }
        )
        XCTAssertNil(controller.plan)
        XCTAssertEqual(
            controller.error as? WindowSessionCoordinatorError,
            .terminationRecoveryFailed
        )
        controller.retry()

        XCTAssertNotNil(controller.plan)
        XCTAssertNil(controller.error)
    }

    @MainActor
    func testCanonicalFallbackPreservesTransactionArtifactsInArchive() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "recovery-ui-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "canonical draft"
        XCTAssertTrue(model.flushSession())
        try fixture.coordinator.didPersist(id)
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        try Data("corrupt sidecar".utf8).write(
            to: artifacts.snapshot, options: .atomic
        )
        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        let controller = StartupRecoveryController(
            coordinator: restarted,
            startImmediately: false,
            initialError: WindowSessionCoordinatorError.terminationRecoveryFailed
        )
        XCTAssertNil(controller.plan)
        XCTAssertEqual(
            controller.error as? WindowSessionCoordinatorError,
            .terminationRecoveryFailed
        )
        XCTAssertTrue(controller.hasFailedCommittedTransaction)

        controller.preserveTransactionAndUseCanonicalSnapshots()

        let archive = try XCTUnwrap(controller.preservedArchiveURL)
        XCTAssertNotNil(controller.plan)
        XCTAssertFalse(controller.hasFailedCommittedTransaction)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.appendingPathComponent(
                artifacts.marker.lastPathComponent
            ).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.appendingPathComponent(
                artifacts.snapshot.lastPathComponent
            ).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.marker.path))
    }

    func testCommittedApplicationGateRejectsNewSceneAndComposition() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "existing-before-quit")
        _ = try fixture.coordinator.composition(for: id)

        fixture.coordinator.markApplicationTerminationCommitted()

        XCTAssertThrowsError(try fixture.coordinator.newSceneValue())
        XCTAssertThrowsError(try fixture.coordinator.composition(
            for: try WindowSessionID(validating: "late-after-quit")
        ))
    }

    @MainActor
    func testMaterializingFallbackRestoresPreviousCanonicalGeneration() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "fallback-old-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "previous draft"
        XCTAssertTrue(model.flushSession())
        model.documents[0].text = "committed draft"
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        let interrupted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertFalse(interrupted.materializeCommittedTerminationForTesting { _ in
            false
        })
        var marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: artifacts.marker)
            ) as? [String: Any]
        )
        marker["state"] = "materializing"
        try JSONSerialization.data(withJSONObject: marker).write(
            to: artifacts.marker, options: .atomic
        )
        try FileManager.default.removeItem(at: artifacts.snapshot)

        let fallback = try interrupted
            .preserveFailedTerminationAndUseCanonicalSnapshots()

        XCTAssertEqual(fallback.plan.primary.id, id)
        XCTAssertEqual(
            composition.sessionStore.loadWindowSession().documents.first?.draft,
            "committed draft"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.marker.path))
    }

    @MainActor
    func testFallbackFailureRetainsActiveRecoveryArtifacts() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "fallback-failure-window")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "previous draft"
        XCTAssertTrue(model.flushSession())
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: [id]
        ))
        XCTAssertTrue(model.preflightApplicationClosePersistence(
            documentRevisions: [:]
        ))
        let artifacts = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: id)
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        let interrupted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertFalse(interrupted.materializeCommittedTerminationForTesting { _ in
            false
        })
        var marker = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: artifacts.marker)
            ) as? [String: Any]
        )
        marker["state"] = "materializing"
        try JSONSerialization.data(withJSONObject: marker).write(
            to: artifacts.marker, options: .atomic
        )
        try? FileManager.default.removeItem(at: artifacts.backup)

        XCTAssertThrowsError(
            try interrupted.preserveFailedTerminationAndUseCanonicalSnapshots()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
    }

    @MainActor
    func testCorruptMarkerFallbackRejectsIncompleteBackupGeneration() throws {
        let fixture = makeFixture()
        let ids = try ["corrupt-backup-a", "corrupt-backup-b"].map {
            try WindowSessionID(validating: $0)
        }
        let models = try ids.map { id in
            try fixture.coordinator.composition(for: id)
                .makeAppModel(createInitialDocument: true)
        }
        for (index, model) in models.enumerated() {
            model.documents[0].text = "old \(index)"
            XCTAssertTrue(model.flushSession())
            model.documents[0].text = "new \(index)"
        }
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: Set(ids)
        ))
        for model in models {
            XCTAssertTrue(model.preflightApplicationClosePersistence(
                documentRevisions: [:]
            ))
        }
        let first = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: ids[0])
        )
        let second = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: ids[1])
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        try Data("corrupt marker".utf8).write(to: first.marker, options: .atomic)
        try FileManager.default.removeItem(at: second.snapshot)
        let interrupted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )

        XCTAssertThrowsError(
            try interrupted.preserveFailedTerminationAndUseCanonicalSnapshots()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.snapshot.path))
    }

    @MainActor
    func testStandaloneCloseCrashRestoresLiveSnapshotBeforeOpeningWindow() throws {
        let fixture = makeFixture()
        // Exercise the legacy `session.json` filename as well as the ordinary
        // `session-<id>.json` cases below.
        let id = WindowSessionID.legacy
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "dirty draft survives crash"
        XCTAssertTrue(model.flushSession())
        let document = model.documents[0]

        XCTAssertTrue(model.persistApplicationCloseSnapshot(
            documentRevisions: [document.id: document.buffer.revision]
        ))
        XCTAssertTrue(model.commitApplicationCloseSnapshot())
        let artifacts = try XCTUnwrap(
            fixture.coordinator.windowCloseTransactionArtifactURLs(for: id)
        )
        XCTAssertTrue(composition.sessionStore.loadWindowSession().documents.isEmpty)

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        _ = try restarted.startupPlan()
        XCTAssertEqual(
            try restarted.composition(for: id)
                .sessionStore.loadWindowSession().documents.first?.draft,
            "dirty draft survives crash"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.backup.path))
    }

    @MainActor
    func testActualStandaloneCloseKeepsProjectionAndConsumesRecoveryArtifacts() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "standalone-close-complete")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "discarded at close"
        XCTAssertTrue(model.flushSession())
        let document = model.documents[0]
        XCTAssertTrue(model.persistApplicationCloseSnapshot(
            documentRevisions: [document.id: document.buffer.revision]
        ))
        XCTAssertTrue(model.commitApplicationCloseSnapshot())
        let artifacts = try XCTUnwrap(
            fixture.coordinator.windowCloseTransactionArtifactURLs(for: id)
        )

        try composition.close(.preserve)

        XCTAssertTrue(composition.sessionStore.loadWindowSession().documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.backup.path))
    }

    @MainActor
    func testStandaloneCloseMissingArtifactFailsClosedWithoutDeletingBackup() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "standalone-close-incomplete")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "recoverable dirty draft"
        XCTAssertTrue(model.flushSession())
        let document = model.documents[0]
        XCTAssertTrue(model.persistApplicationCloseSnapshot(
            documentRevisions: [document.id: document.buffer.revision]
        ))
        XCTAssertTrue(model.commitApplicationCloseSnapshot())
        let artifacts = try XCTUnwrap(
            fixture.coordinator.windowCloseTransactionArtifactURLs(for: id)
        )
        try FileManager.default.removeItem(at: artifacts.snapshot)

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertThrowsError(try restarted.startupPlan())
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.backup.path))
    }

    @MainActor
    func testStandaloneCloseMalformedMarkerNameFailsClosedAndKeepsBackup() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "standalone-close-bad-name")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "recoverable name failure"
        XCTAssertTrue(model.flushSession())
        let document = model.documents[0]
        XCTAssertTrue(model.persistApplicationCloseSnapshot(
            documentRevisions: [document.id: document.buffer.revision]
        ))
        XCTAssertTrue(model.commitApplicationCloseSnapshot())
        let artifacts = try XCTUnwrap(
            fixture.coordinator.windowCloseTransactionArtifactURLs(for: id)
        )
        let canonical = try fixture.store.windowSessionURL(for: id.rawValue)
        let malformed = canonical.appendingPathExtension(
            "window-close-marker-not-a-uuid"
        )
        try FileManager.default.moveItem(at: artifacts.marker, to: malformed)

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertThrowsError(try restarted.startupPlan())
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.backup.path))
    }

    @MainActor
    func testStandaloneCloseMalformedMarkerPayloadFailsClosedAndKeepsBackup() throws {
        let fixture = makeFixture()
        let id = try WindowSessionID(validating: "standalone-close-bad-marker")
        let composition = try fixture.coordinator.composition(for: id)
        let model = composition.makeAppModel(createInitialDocument: true)
        model.documents[0].text = "recoverable marker failure"
        XCTAssertTrue(model.flushSession())
        let document = model.documents[0]
        XCTAssertTrue(model.persistApplicationCloseSnapshot(
            documentRevisions: [document.id: document.buffer.revision]
        ))
        XCTAssertTrue(model.commitApplicationCloseSnapshot())
        let artifacts = try XCTUnwrap(
            fixture.coordinator.windowCloseTransactionArtifactURLs(for: id)
        )
        try Data("not json".utf8).write(to: artifacts.marker, options: .atomic)

        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )
        XCTAssertThrowsError(try restarted.startupPlan())
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.backup.path))
    }

    @MainActor
    func testCorruptGlobalMarkerFallbackRejectsMissingParticipantArtifacts() throws {
        let fixture = makeFixture()
        let ids = try ["missing-both-a", "missing-both-b"].map {
            try WindowSessionID(validating: $0)
        }
        let models = try ids.map { id in
            try fixture.coordinator.composition(for: id)
                .makeAppModel(createInitialDocument: true)
        }
        for (index, model) in models.enumerated() {
            model.documents[0].text = "old \(index)"
            XCTAssertTrue(model.flushSession())
            model.documents[0].text = "new \(index)"
        }
        XCTAssertTrue(fixture.coordinator.beginTerminationTransaction(
            expectedWindowIDs: Set(ids)
        ))
        for model in models {
            XCTAssertTrue(model.preflightApplicationClosePersistence(
                documentRevisions: [:]
            ))
        }
        let first = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: ids[0])
        )
        let second = try XCTUnwrap(
            fixture.coordinator.terminationTransactionArtifactURLs(for: ids[1])
        )
        XCTAssertTrue(fixture.coordinator.commitTerminationTransaction())
        fixture.coordinator.finalizeCommittedTerminationTransaction()
        try Data(contentsOf: fixture.store.windowSessionURL(for: ids[0].rawValue))
            .write(to: first.backup, options: .atomic)
        try Data(contentsOf: fixture.store.windowSessionURL(for: ids[1].rawValue))
            .write(to: second.backup, options: .atomic)
        try Data("corrupt marker".utf8).write(to: first.marker, options: .atomic)
        try FileManager.default.removeItem(at: second.backup)
        try FileManager.default.removeItem(at: second.snapshot)
        let interrupted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: fixture.directory)
        )

        XCTAssertThrowsError(
            try interrupted.preserveFailedTerminationAndUseCanonicalSnapshots()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.backup.path))
    }

    private func makeFixture(
        ids: [String] = [],
        sessionLimits: SessionStore.Limits = .default,
        idGenerator: WindowSessionCoordinator.IDGenerator? = nil
    ) -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WindowSessionCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        temporaryDirectories.append(directory)
        let store = RecentItemsStore(directoryURL: directory)
        let sequence = LockedStringSequence(ids)
        let generator = idGenerator ?? { sequence.next() }
        let coordinator = WindowSessionCoordinator(
            recentItemsStore: store,
            sessionLimits: sessionLimits,
            idGenerator: generator,
            now: { Date() }
        )
        return Fixture(directory: directory, store: store, coordinator: coordinator)
    }
}

private struct Fixture: @unchecked Sendable {
    let directory: URL
    let store: RecentItemsStore
    let coordinator: WindowSessionCoordinator
}

private final class LockedStringSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? UUID().uuidString.lowercased() : values.removeFirst()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIDs: [WindowSessionID] = []
    private var storedURLs: [URL] = []
    private var storedErrors: [any Error] = []

    var ids: [WindowSessionID] { withLock { storedIDs } }
    var urls: [URL] { withLock { storedURLs } }
    var errors: [any Error] { withLock { storedErrors } }

    func append(id: WindowSessionID, url: URL) {
        withLock {
            storedIDs.append(id)
            storedURLs.append(url)
        }
    }

    func append(error: any Error) {
        withLock { storedErrors.append(error) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
