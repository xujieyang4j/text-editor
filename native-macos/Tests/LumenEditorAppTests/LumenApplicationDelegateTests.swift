import AppKit
import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class LumenApplicationDelegateTests: XCTestCase {
    private final class WindowDelegateVeto: NSObject, NSWindowDelegate {
        var shouldCloseCount = 0
        var allowsClose = false

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldCloseCount += 1
            return allowsClose
        }
    }

    private final class DeferredCloseWindow: NSWindow {
        var performCloseCount = 0

        override func performClose(_ sender: Any?) {
            performCloseCount += 1
        }
    }

    func testWindowCloseForwardedVetoRunsBeforePreparingDestructiveClose() {
        let forwarded = WindowDelegateVeto()
        let window = DeferredCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.closable], backing: .buffered, defer: false
        )
        window.delegate = forwarded
        var prepareCount = 0
        let coordinator = WindowCloseGuard.Coordinator(
            prepareToClose: { completion in
                prepareCount += 1
                completion(true)
            },
            session: nil, becameKey: {}, resignedKey: {}, willClose: { _ in }
        )
        coordinator.attach(to: window)
        defer { coordinator.detach() }

        XCTAssertFalse(coordinator.windowShouldClose(window))
        XCTAssertEqual(forwarded.shouldCloseCount, 1)
        XCTAssertEqual(prepareCount, 0)
    }

    func testWindowCloseDoesNotRepeatForwardedVetoAfterPreparedCommit() async {
        let forwarded = WindowDelegateVeto()
        forwarded.allowsClose = true
        let window = DeferredCloseWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.closable], backing: .buffered, defer: false
        )
        window.delegate = forwarded
        var prepareCount = 0
        var willCloseCount = 0
        let coordinator = WindowCloseGuard.Coordinator(
            prepareToClose: { completion in
                prepareCount += 1
                completion(true)
            },
            session: nil, becameKey: {}, resignedKey: {},
            willClose: { _ in willCloseCount += 1 }
        )
        coordinator.attach(to: window)
        defer { coordinator.detach() }

        XCTAssertFalse(coordinator.windowShouldClose(window))
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(forwarded.shouldCloseCount, 1)
        XCTAssertEqual(window.performCloseCount, 1)
        XCTAssertTrue(coordinator.windowShouldClose(window))
        XCTAssertEqual(forwarded.shouldCloseCount, 1)
        XCTAssertEqual(willCloseCount, 0)

        coordinator.windowWillClose(Notification(
            name: NSWindow.willCloseNotification, object: window
        ))
        XCTAssertEqual(willCloseCount, 1)
    }

    func testApplicationWillTerminateDoesNotRepeatSuccessfulFlushes() async throws {
        let id = try WindowSessionID(validating: "will-terminate-window")
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        var globalFlushCount = 0
        var windowFlushCount = 0
        delegate.flushGlobalState = {
            globalFlushCount += 1
            return true
        }
        delegate.connect(
            windowID: id, openURLs: { _ in },
            flushSession: {
                windowFlushCount += 1
                return true
            },
            preflightTerminationPersistence: { true },
            prepareToTerminate: { $0(true) },
            commitTerminationPreparation: {},
            finalizeTermination: {}
        )

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        await waitUntil { reply != nil }
        delegate.applicationWillTerminate(Notification(
            name: NSApplication.willTerminateNotification
        ))

        XCTAssertEqual(reply, true)
        XCTAssertEqual(globalFlushCount, 1)
        XCTAssertEqual(windowFlushCount, 0)
    }

    func testApplicationWillTerminateAfterCancelledQuitFlushesLiveState() async throws {
        let id = try WindowSessionID(validating: "cancelled-will-terminate-window")
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        var globalFlushCount = 0
        var windowFlushCount = 0
        delegate.flushGlobalState = {
            globalFlushCount += 1
            return true
        }
        delegate.connect(
            windowID: id, openURLs: { _ in },
            flushSession: {
                windowFlushCount += 1
                return true
            },
            preflightTerminationPersistence: { true },
            prepareToTerminate: { $0(false) },
            commitTerminationPreparation: {},
            finalizeTermination: {}
        )

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        await waitUntil { reply != nil }
        delegate.applicationWillTerminate(Notification(
            name: NSApplication.willTerminateNotification
        ))

        XCTAssertEqual(reply, false)
        XCTAssertEqual(globalFlushCount, 2)
        XCTAssertEqual(windowFlushCount, 1)
    }

    func testSecondWindowCancellationAbortsFirstPreparedDiscard() async throws {
        let firstFixture = try makeFixture(named: "first")
        let secondFixture = try makeFixture(named: "second")
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }

        let firstModel = AppModel(
            sessionStore: firstFixture.store, createInitialDocument: false
        )
        let secondModel = AppModel(
            sessionStore: secondFixture.store, createInitialDocument: false
        )
        let firstActions = EditorActionController(model: firstModel)
        let secondActions = EditorActionController(model: secondModel)
        await firstActions.restoreSessionIfNeeded()
        await secondActions.restoreSessionIfNeeded()
        let firstDocument = try openDirtyDocument(
            named: "first.txt", in: firstFixture.directory, model: firstModel
        )
        let secondDocument = try openDirtyDocument(
            named: "second.txt", in: secondFixture.directory, model: secondModel
        )

        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        let firstID = try WindowSessionID(validating: "a-window")
        let secondID = try WindowSessionID(validating: "b-window")
        var commitCount = 0
        var firstAbortCount = 0
        var finalizeCount = 0
        delegate.connect(
            windowID: firstID,
            openURLs: { _ in },
            flushSession: { firstModel.flushSession() },
            preflightTerminationPersistence: {
                firstActions.preflightApplicationTerminationPersistence()
            },
            prepareToTerminate: { completion in
                firstActions.prepareForApplicationTermination(completion: completion)
            },
            validateTerminationPreparation: {
                firstActions.validateApplicationTerminationPreparation()
            },
            commitTerminationPreparation: {
                commitCount += 1
                firstActions.commitApplicationTerminationPreparation()
            },
            abortTerminationPreparation: {
                firstAbortCount += 1
                await firstActions.abortApplicationTerminationPreparation()
            },
            finalizeTermination: { finalizeCount += 1 }
        )
        delegate.connect(
            windowID: secondID,
            openURLs: { _ in },
            flushSession: { secondModel.flushSession() },
            preflightTerminationPersistence: {
                secondActions.preflightApplicationTerminationPersistence()
            },
            prepareToTerminate: { completion in
                secondActions.prepareForApplicationTermination(completion: completion)
            },
            validateTerminationPreparation: {
                secondActions.validateApplicationTerminationPreparation()
            },
            commitTerminationPreparation: {
                commitCount += 1
                secondActions.commitApplicationTerminationPreparation()
            },
            abortTerminationPreparation: {
                await secondActions.abortApplicationTerminationPreparation()
            },
            finalizeTermination: { finalizeCount += 1 }
        )

        var terminationReply: Bool?
        let immediateReply = delegate.beginApplicationTermination {
            terminationReply = $0
        }

        XCTAssertEqual(immediateReply, .terminateLater)
        XCTAssertEqual(
            firstModel.pendingCloseRequest?.documentID, firstDocument.id
        )
        XCTAssertNil(secondModel.pendingCloseRequest)

        // Window A accepts Discard. Its document must remain recoverable while
        // the application is still collecting Window B's decision.
        await firstActions.resolvePendingCloseByDiscarding()
        await waitUntil {
            secondModel.pendingCloseRequest?.documentID == secondDocument.id
        }
        XCTAssertTrue(firstModel.documents.contains { $0 === firstDocument })
        XCTAssertTrue(firstDocument.isDirty)
        XCTAssertNil(terminationReply)

        await secondActions.cancelPendingClose()
        await waitUntil { terminationReply != nil }

        XCTAssertEqual(terminationReply, false)
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(firstAbortCount, 1)
        XCTAssertEqual(finalizeCount, 0)
        XCTAssertFalse(firstActions.isClosingApplicationOrWindow)
        XCTAssertFalse(secondActions.isClosingApplicationOrWindow)
        XCTAssertTrue(firstModel.documents.contains { $0 === firstDocument })
        XCTAssertTrue(secondModel.documents.contains { $0 === secondDocument })
        XCTAssertTrue(firstDocument.isDirty)
        XCTAssertTrue(secondDocument.isDirty)
    }

    func testRevisionValidationFailureAbortsAllWindowsBeforeAnyCommit() async throws {
        let firstFixture = try makeFixture(named: "revision-first")
        let secondFixture = try makeFixture(named: "revision-second")
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }

        let firstModel = AppModel(
            sessionStore: firstFixture.store, createInitialDocument: false
        )
        let secondModel = AppModel(
            sessionStore: secondFixture.store, createInitialDocument: false
        )
        let firstActions = EditorActionController(model: firstModel)
        let secondActions = EditorActionController(model: secondModel)
        await firstActions.restoreSessionIfNeeded()
        await secondActions.restoreSessionIfNeeded()
        let firstDocument = try openDirtyDocument(
            named: "first.txt", in: firstFixture.directory, model: firstModel
        )
        let secondDocument = try openDirtyDocument(
            named: "second.txt", in: secondFixture.directory, model: secondModel
        )

        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        var commitCount = 0
        var abortCount = 0
        connect(
            delegate, id: try WindowSessionID(validating: "a-revision-window"),
            model: firstModel, actions: firstActions,
            commitCount: { commitCount += 1 },
            abortCount: { abortCount += 1 }
        )
        connect(
            delegate, id: try WindowSessionID(validating: "b-revision-window"),
            model: secondModel, actions: secondActions,
            didPrepare: {
                let transaction = try? TextTransaction(edits: [
                    TextEdit(from: 0, to: 0, insert: "changed after review " )
                ])
                if let transaction {
                    _ = try? firstDocument.buffer.apply(transaction)
                }
            },
            commitCount: { commitCount += 1 },
            abortCount: { abortCount += 1 }
        )

        var terminationReply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { terminationReply = $0 },
            .terminateLater
        )
        await firstActions.resolvePendingCloseByDiscarding()
        await waitUntil {
            secondModel.pendingCloseRequest?.documentID == secondDocument.id
        }
        await secondActions.resolvePendingCloseByDiscarding()
        await waitUntil { terminationReply != nil }

        XCTAssertEqual(terminationReply, false)
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(abortCount, 2)
        XCTAssertTrue(firstModel.documents.contains { $0 === firstDocument })
        XCTAssertTrue(secondModel.documents.contains { $0 === secondDocument })
    }

    func testSuccessfulTerminationCommitsEveryPreparedWindowBeforeFinalizing() async throws {
        let firstID = try WindowSessionID(validating: "a-success-window")
        let secondID = try WindowSessionID(validating: "b-success-window")
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        var events: [String] = []
        delegate.flushGlobalState = {
            events.append("flush-global")
            return true
        }
        delegate.beginTerminationPersistenceTransaction = { _ in
            events.append("begin-transaction")
            return true
        }
        delegate.commitTerminationPersistenceTransaction = {
            events.append("commit-transaction")
            return true
        }
        for id in [firstID, secondID] {
            delegate.connect(
                windowID: id,
                openURLs: { _ in },
                flushSession: { true },
                preflightTerminationPersistence: {
                    events.append("flush-\(id.rawValue)")
                    return true
                },
                prepareToTerminate: { completion in
                    events.append("prepare-\(id.rawValue)")
                    completion(true)
                },
                validateTerminationPreparation: {
                    events.append("validate-\(id.rawValue)")
                    return true
                },
                commitTerminationPreparation: {
                    events.append("commit-\(id.rawValue)")
                },
                abortTerminationPreparation: {
                    events.append("abort-\(id.rawValue)")
                },
                finalizeTermination: {
                    events.append("finalize-\(id.rawValue)")
                }
            )
        }

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        await waitUntil { reply != nil }
        delegate.applicationWillTerminate(Notification(
            name: NSApplication.willTerminateNotification
        ))

        XCTAssertEqual(reply, true)
        XCTAssertEqual(events.filter { $0 == "flush-global" }.count, 1)
        XCTAssertEqual(
            events.filter {
                $0 == "flush-a-success-window"
                    || $0 == "flush-b-success-window"
            }.count,
            2
        )
        let lastValidation = try XCTUnwrap(events.lastIndex {
            $0.hasPrefix("validate-")
        })
        let lastFlush = try XCTUnwrap(events.lastIndex {
            $0.hasPrefix("flush-") && $0 != "flush-global"
        })
        let firstCommit = try XCTUnwrap(events.firstIndex {
            $0.hasPrefix("commit-") && $0 != "commit-transaction"
        })
        let transactionCommit = try XCTUnwrap(events.firstIndex(of: "commit-transaction"))
        XCTAssertLessThan(lastValidation, firstCommit)
        XCTAssertLessThan(lastFlush, firstCommit)
        XCTAssertLessThan(transactionCommit, firstCommit)
        XCTAssertEqual(
            events.filter { $0.hasPrefix("commit-") },
            [
                "commit-transaction",
                "commit-a-success-window",
                "commit-b-success-window"
            ]
        )
        XCTAssertEqual(
            events.filter { $0.hasPrefix("finalize-") },
            ["finalize-a-success-window", "finalize-b-success-window"]
        )
        let firstFinalize = try XCTUnwrap(events.firstIndex {
            $0.hasPrefix("finalize-")
        })
        let lastCommit = try XCTUnwrap(events.lastIndex {
            $0.hasPrefix("commit-") && $0 != "commit-transaction"
        })
        XCTAssertGreaterThan(firstFinalize, lastCommit)
        XCTAssertFalse(events.contains { $0.hasPrefix("abort-") })
    }

    func testCommittedWindowGatesStayClosedWhileFirstFinalizerIsSuspended() async throws {
        let fixtures = try [makeFixture(named: "gate-a"), makeFixture(named: "gate-b")]
        defer { fixtures.forEach { $0.remove() } }
        let models = fixtures.map {
            AppModel(sessionStore: $0.store, createInitialDocument: false)
        }
        let actions = models.map { EditorActionController(model: $0) }
        for action in actions { await action.restoreSessionIfNeeded() }
        for (index, model) in models.enumerated() {
            let document = try openDirtyDocument(
                named: "gate-\(index).txt",
                in: fixtures[index].directory, model: model
            )
            document.text += " reviewed"
        }
        let ids = try ["a-gate-window", "b-gate-window"].map {
            try WindowSessionID(validating: $0)
        }
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        delegate.beginTerminationPersistenceTransaction = { _ in true }
        delegate.commitTerminationPersistenceTransaction = { true }
        var releaseFirstFinalize: (() -> Void)?
        var firstFinalizeStarted = false
        for index in ids.indices {
            delegate.connect(
                windowID: ids[index], openURLs: { _ in }, flushSession: { true },
                preflightTerminationPersistence: { true },
                prepareToTerminate: { completion in
                    actions[index].prepareForApplicationTermination(completion: completion)
                },
                validateTerminationPreparation: {
                    actions[index].validateApplicationTerminationPreparation()
                },
                commitTerminationPreparation: {
                    actions[index].commitApplicationTerminationPreparation()
                },
                abortTerminationPreparation: {
                    await actions[index].abortApplicationTerminationPreparation()
                },
                finalizeTermination: {
                    guard index == 0 else { return }
                    firstFinalizeStarted = true
                    await withCheckedContinuation {
                        (continuation: CheckedContinuation<Void, Never>) in
                        releaseFirstFinalize = { continuation.resume() }
                    }
                }
            )
        }

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        for index in actions.indices {
            await waitUntil { models[index].pendingCloseRequest != nil }
            await actions[index].resolvePendingCloseByDiscarding()
            await waitUntil { models[index].pendingCloseRequest == nil }
        }
        await waitUntil { firstFinalizeStarted }

        XCTAssertNil(reply)
        XCTAssertTrue(actions.allSatisfy { $0.isClosingApplicationOrWindow })
        XCTAssertTrue(actions.allSatisfy { !$0.canExecuteRoutedCommand })
        releaseFirstFinalize?()
        await waitUntil { reply != nil }
        XCTAssertEqual(reply, true)
        XCTAssertTrue(actions.allSatisfy { $0.isClosingApplicationOrWindow })
    }

    func testCommittedTerminationRejectsLateWindowConnectionAndReopen() async throws {
        let id = try WindowSessionID(validating: "existing-window")
        let lateID = try WindowSessionID(validating: "late-window")
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        var releaseFinalize: (() -> Void)?
        var finalizeStarted = false
        var openCount = 0
        var lateFlushCount = 0
        delegate.openNewWindow = { openCount += 1 }
        delegate.beginTerminationPersistenceTransaction = { _ in true }
        delegate.commitTerminationPersistenceTransaction = { true }
        delegate.connect(
            windowID: id, openURLs: { _ in }, flushSession: { true },
            preflightTerminationPersistence: { true },
            prepareToTerminate: { $0(true) },
            validateTerminationPreparation: { true },
            commitTerminationPreparation: {},
            finalizeTermination: {
                finalizeStarted = true
                await withCheckedContinuation { continuation in
                    releaseFinalize = { continuation.resume() }
                }
            }
        )

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 }, .terminateLater
        )
        await waitUntil { finalizeStarted }
        XCTAssertTrue(delegate.isApplicationTerminationCommitted)
        XCTAssertNil(reply)

        delegate.applicationShouldHandleReopen(
            NSApplication.shared, hasVisibleWindows: false
        )
        delegate.connect(
            windowID: lateID, openURLs: { _ in },
            flushSession: { lateFlushCount += 1; return true },
            preflightTerminationPersistence: { true },
            prepareToTerminate: { $0(true) },
            finalizeTermination: {}
        )
        XCTAssertEqual(openCount, 0)
        delegate.applicationWillTerminate(Notification(
            name: NSApplication.willTerminateNotification
        ))
        XCTAssertEqual(lateFlushCount, 0)

        releaseFinalize?()
        await waitUntil { reply != nil }
        XCTAssertEqual(reply, true)
    }

    func testSingleWindowPersistenceFailureAbortsBeforeCommit() async throws {
        let id = try WindowSessionID(validating: "single-failure-window")
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        var events: [String] = []
        delegate.connect(
            windowID: id,
            openURLs: { _ in },
            flushSession: { true },
            preflightTerminationPersistence: {
                events.append("flush")
                return false
            },
            prepareToTerminate: { completion in
                events.append("prepare")
                completion(true)
            },
            validateTerminationPreparation: {
                events.append("validate")
                return true
            },
            commitTerminationPreparation: { events.append("commit") },
            abortTerminationPreparation: { events.append("abort") },
            finalizeTermination: { events.append("finalize") }
        )

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        await waitUntil { reply != nil }

        XCTAssertEqual(reply, false)
        XCTAssertEqual(events, ["prepare", "validate", "flush", "abort"])
    }

    func testSecondWindowPersistenceFailureAbortsAllBeforeAnyCommit() async throws {
        let firstID = try WindowSessionID(validating: "a-flush-window")
        let secondID = try WindowSessionID(validating: "b-flush-window")
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        var events: [String] = []
        for (id, succeeds) in [(firstID, true), (secondID, false)] {
            delegate.connect(
                windowID: id,
                openURLs: { _ in },
                flushSession: { true },
                preflightTerminationPersistence: {
                    events.append("flush-\(id.rawValue)")
                    return succeeds
                },
                prepareToTerminate: { completion in
                    events.append("prepare-\(id.rawValue)")
                    completion(true)
                },
                validateTerminationPreparation: {
                    events.append("validate-\(id.rawValue)")
                    return true
                },
                commitTerminationPreparation: {
                    events.append("commit-\(id.rawValue)")
                },
                abortTerminationPreparation: {
                    events.append("abort-\(id.rawValue)")
                },
                finalizeTermination: {
                    events.append("finalize-\(id.rawValue)")
                }
            )
        }

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        await waitUntil { reply != nil }

        XCTAssertEqual(reply, false)
        XCTAssertEqual(
            events.filter { $0.hasPrefix("flush-") },
            ["flush-a-flush-window", "flush-b-flush-window"]
        )
        XCTAssertFalse(events.contains { $0.hasPrefix("commit-") })
        XCTAssertFalse(events.contains { $0.hasPrefix("finalize-") })
        XCTAssertEqual(
            events.filter { $0.hasPrefix("abort-") },
            ["abort-a-flush-window", "abort-b-flush-window"]
        )
    }

    func testSecondWindowStagingFailureLeavesFirstLiveDraftOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminationTransactionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let recentItems = RecentItemsStore(directoryURL: root)
        let coordinator = WindowSessionCoordinator(recentItemsStore: recentItems)
        let firstID = try WindowSessionID(validating: "a-staged-window")
        let secondID = try WindowSessionID(validating: "b-staged-window")
        let firstComposition = try coordinator.composition(for: firstID)
        let secondComposition = try coordinator.composition(for: secondID)
        let firstModel = firstComposition.makeAppModel(createInitialDocument: true)
        let secondModel = secondComposition.makeAppModel(createInitialDocument: true)
        let firstActions = EditorActionController(model: firstModel)
        let secondActions = EditorActionController(model: secondModel)
        await firstActions.restoreSessionIfNeeded()
        await secondActions.restoreSessionIfNeeded()
        firstModel.documents[0].text = "recoverable first draft"
        secondModel.documents[0].text = "recoverable second draft"
        XCTAssertTrue(firstModel.flushSession())
        XCTAssertTrue(secondModel.flushSession())
        firstModel.documents[0].text = "discard first draft"
        secondModel.documents[0].text = "discard second draft"

        var firstPrepared: Bool?
        var secondPrepared: Bool?
        firstActions.prepareForApplicationTermination { firstPrepared = $0 }
        secondActions.prepareForApplicationTermination { secondPrepared = $0 }
        await firstActions.resolvePendingCloseByDiscarding()
        await secondActions.resolvePendingCloseByDiscarding()
        await waitUntil { firstPrepared == true && secondPrepared == true }

        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        delegate.beginTerminationPersistenceTransaction = { ids in
            coordinator.beginTerminationTransaction(expectedWindowIDs: ids)
        }
        delegate.commitTerminationPersistenceTransaction = {
            coordinator.commitTerminationTransaction()
        }
        delegate.abortTerminationPersistenceTransaction = {
            coordinator.abortTerminationTransaction()
        }
        delegate.connect(
            windowID: firstID, openURLs: { _ in }, flushSession: { true },
            preflightTerminationPersistence: {
                firstActions.preflightApplicationTerminationPersistence()
            },
            prepareToTerminate: { $0(true) },
            validateTerminationPreparation: {
                firstActions.validateApplicationTerminationPreparation()
            },
            commitTerminationPreparation: {
                firstActions.commitApplicationTerminationPreparation()
            },
            abortTerminationPreparation: {
                await firstActions.abortApplicationTerminationPreparation()
            },
            finalizeTermination: {}
        )
        delegate.connect(
            windowID: secondID, openURLs: { _ in }, flushSession: { true },
            preflightTerminationPersistence: { false },
            prepareToTerminate: { $0(true) },
            validateTerminationPreparation: {
                secondActions.validateApplicationTerminationPreparation()
            },
            commitTerminationPreparation: {
                secondActions.commitApplicationTerminationPreparation()
            },
            abortTerminationPreparation: {
                await secondActions.abortApplicationTerminationPreparation()
            },
            finalizeTermination: {}
        )

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        await waitUntil { reply != nil }

        XCTAssertEqual(reply, false)
        let persisted = firstComposition.sessionStore.loadWindowSession()
        XCTAssertEqual(persisted.documents.first?.draft, "discard first draft")
        XCTAssertTrue(firstModel.documents.contains { $0.text == "discard first draft" })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.contains(".termination-") },
            []
        )
    }

    func testSuccessfulStagingPublishesPostCommitSnapshotsForEveryWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminationCommitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let recentItems = RecentItemsStore(directoryURL: root)
        let coordinator = WindowSessionCoordinator(recentItemsStore: recentItems)
        let ids = try ["a-commit-window", "b-commit-window"].map {
            try WindowSessionID(validating: $0)
        }
        var participants: [(WindowSessionID, AppModel, EditorActionController)] = []
        for (index, id) in ids.enumerated() {
            let composition = try coordinator.composition(for: id)
            let model = composition.makeAppModel(createInitialDocument: true)
            let actions = EditorActionController(model: model)
            await actions.restoreSessionIfNeeded()
            if index == 0 { model.documents[0].text = "discard draft" }
            XCTAssertTrue(model.flushSession())
            var prepared: Bool?
            actions.prepareForApplicationTermination { prepared = $0 }
            if index == 0 {
                await actions.resolvePendingCloseByDiscarding()
            }
            await waitUntil { prepared == true }
            participants.append((id, model, actions))
        }

        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        delegate.beginTerminationPersistenceTransaction = { windowIDs in
            coordinator.beginTerminationTransaction(expectedWindowIDs: windowIDs)
        }
        delegate.commitTerminationPersistenceTransaction = {
            coordinator.commitTerminationTransaction()
        }
        delegate.abortTerminationPersistenceTransaction = {
            coordinator.abortTerminationTransaction()
        }
        delegate.finalizeTerminationPersistenceTransaction = {
            coordinator.finalizeCommittedTerminationTransaction()
        }
        for (id, model, actions) in participants {
            delegate.connect(
                windowID: id, openURLs: { _ in }, flushSession: { true },
                preflightTerminationPersistence: {
                    actions.preflightApplicationTerminationPersistence()
                },
                prepareToTerminate: { $0(true) },
                validateTerminationPreparation: {
                    actions.validateApplicationTerminationPreparation()
                },
                commitTerminationPreparation: {
                    actions.commitApplicationTerminationPreparation()
                },
                abortTerminationPreparation: {
                    await actions.abortApplicationTerminationPreparation()
                },
                finalizeTermination: {}
            )
            XCTAssertEqual(model.documents.count, 1)
        }

        var reply: Bool?
        XCTAssertEqual(
            delegate.beginApplicationTermination { reply = $0 },
            .terminateLater
        )
        await waitUntil { reply != nil }

        XCTAssertEqual(reply, true)
        let restarted = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: root)
        )
        for (index, id) in ids.enumerated() {
            let session = try restarted.composition(for: id)
                .sessionStore.loadWindowSession()
            if index == 0 {
                XCTAssertTrue(session.documents.isEmpty)
            } else {
                XCTAssertEqual(session.documents.count, 1)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("termination-commit.json").path
        ))
    }

    func testFinderOpenForwardsEverySelectedFileToTheActiveWindow() throws {
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        let windowID = try WindowSessionID(validating: "finder-open-window")
        var delivered: [[URL]] = []
        delegate.connect(
            windowID: windowID,
            openURLs: { delivered.append($0) },
            flushSession: { true },
            preflightTerminationPersistence: { true },
            prepareToTerminate: { $0(true) },
            finalizeTermination: {}
        )

        let first = URL(fileURLWithPath: "/tmp/finder-open-one.swift")
        let second = URL(fileURLWithPath: "/tmp/finder-open-two.swift")
        delegate.application(NSApplication.shared, open: [first, second])

        XCTAssertEqual(delivered, [[first, second]])
    }

    func testFinderOpenQueuesEveryFileUntilTheFirstWindowConnects() throws {
        let delegate = LumenApplicationDelegate(mainMenuProvider: { nil })
        let first = URL(fileURLWithPath: "/tmp/finder-queued-one.swift")
        let second = URL(fileURLWithPath: "/tmp/finder-queued-two.swift")
        delegate.application(NSApplication.shared, open: [first, second])

        var delivered: [[URL]] = []
        delegate.connect(
            windowID: try WindowSessionID(validating: "queued-finder-open-window"),
            openURLs: { delivered.append($0) },
            flushSession: { true },
            preflightTerminationPersistence: { true },
            prepareToTerminate: { $0(true) },
            finalizeTermination: {}
        )

        XCTAssertEqual(delivered, [[first, second]])
    }

    private func connect(
        _ delegate: LumenApplicationDelegate,
        id: WindowSessionID,
        model: AppModel,
        actions: EditorActionController,
        didPrepare: @escaping () -> Void = {},
        commitCount: @escaping () -> Void,
        abortCount: @escaping () -> Void
    ) {
        delegate.connect(
            windowID: id,
            openURLs: { _ in },
            flushSession: { model.flushSession() },
            preflightTerminationPersistence: {
                actions.preflightApplicationTerminationPersistence()
            },
            prepareToTerminate: { completion in
                actions.prepareForApplicationTermination { prepared in
                    if prepared { didPrepare() }
                    completion(prepared)
                }
            },
            validateTerminationPreparation: {
                actions.validateApplicationTerminationPreparation()
            },
            commitTerminationPreparation: {
                commitCount()
                actions.commitApplicationTerminationPreparation()
            },
            abortTerminationPreparation: {
                abortCount()
                await actions.abortApplicationTerminationPreparation()
            },
            finalizeTermination: {}
        )
    }

    private func openDirtyDocument(
        named name: String, directory: URL, model: AppModel
    ) throws -> EditorDocument {
        let url = directory.appendingPathComponent(name)
        try Data("original".utf8).write(to: url)
        let document = try XCTUnwrap(
            model.open(openedFile: TextFileCodec.read(from: url))
        )
        document.text += " dirty"
        return document
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for termination state", file: file, line: line)
    }

    private func makeFixture(named name: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LumenApplicationDelegateTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return Fixture(
            directory: directory,
            store: SessionStore(
                sessionURL: directory.appendingPathComponent(
                    SessionStore.sessionFileName
                )
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
