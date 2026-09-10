import AppKit
import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class AutoSaveControllerTests: XCTestCase {
    func testOffModeNeverSchedulesOrSaves() async {
        let settings = AutoSaveSettingsSnapshot(mode: .off, delayMilliseconds: 500)
        let documents = [eligibleDocument()]
        var saved: [UUID] = []
        let delay = ControlledDelay()
        let controller = makeController(
            settings: { settings },
            documents: { documents },
            save: { snapshot in saved.append(snapshot.id); return true },
            delay: delay
        )

        controller.documentStateDidChange()
        controller.windowDidResignKey()
        await drainMainActor()

        XCTAssertFalse(controller.hasPendingDelay)
        XCTAssertFalse(controller.isRunningSavePass)
        XCTAssertEqual(delay.requestCount, 0)
        XCTAssertTrue(saved.isEmpty)
    }

    func testAfterDelayDebouncesAndUsesLatestDelay() async {
        var settings = AutoSaveSettingsSnapshot(mode: .afterDelay, delayMilliseconds: 250)
        var document = eligibleDocument()
        let documentID = document.id
        var saved: [UUID] = []
        let delay = ControlledDelay()
        let controller = makeController(
            settings: { settings },
            documents: { [document] },
            save: { snapshot in
                saved.append(snapshot.id)
                document = self.eligibleDocument(id: snapshot.id, isDirty: false)
                return true
            },
            delay: delay
        )

        controller.documentStateDidChange()
        await drainMainActor()
        XCTAssertEqual(delay.requestedNanoseconds, [250_000_000])

        settings = AutoSaveSettingsSnapshot(mode: .afterDelay, delayMilliseconds: 750)
        controller.settingsDidChange()
        await drainMainActor()
        XCTAssertEqual(delay.requestedNanoseconds, [250_000_000, 750_000_000])

        delay.release(at: 0)
        await drainMainActor()
        XCTAssertTrue(saved.isEmpty, "A superseded debounce must not save")

        delay.release(at: 1)
        await controller.waitForIdle()
        XCTAssertEqual(saved, [documentID])
        XCTAssertFalse(controller.hasPendingDelay)
    }

    func testSwitchingAwayFromAfterDelayCancelsPendingTimer() async {
        var settings = AutoSaveSettingsSnapshot(mode: .afterDelay, delayMilliseconds: 400)
        var saveCount = 0
        let delay = ControlledDelay()
        let controller = makeController(
            settings: { settings },
            documents: { [eligibleDocument()] },
            save: { _ in saveCount += 1; return true },
            delay: delay
        )

        controller.documentStateDidChange()
        await drainMainActor()
        settings = AutoSaveSettingsSnapshot(mode: .off, delayMilliseconds: 400)
        controller.settingsDidChange()
        delay.releaseAll()
        await controller.waitForIdle()

        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(controller.hasPendingDelay)
    }

    func testFocusChangeModeSavesOnlyWhenOwningWindowResignsKey() async {
        let settings = AutoSaveSettingsSnapshot(mode: .onFocusChange, delayMilliseconds: 500)
        let document = eligibleDocument()
        var saved: [UUID] = []
        let delay = ControlledDelay()
        let controller = makeController(
            settings: { settings },
            documents: { [document] },
            save: { snapshot in saved.append(snapshot.id); return true },
            delay: delay
        )

        controller.documentStateDidChange()
        await drainMainActor()
        XCTAssertEqual(delay.requestCount, 0)
        XCTAssertTrue(saved.isEmpty)

        controller.windowDidResignKey()
        await controller.waitForIdle()
        XCTAssertEqual(saved, [document.id])
    }

    func testWindowResignEventIsIgnoredOutsideFocusChangeMode() async {
        var offSaveCount = 0
        var delayedSaveCount = 0
        let offController = makeController(
            settings: { .init(mode: .off, delayMilliseconds: 500) },
            documents: { [self.eligibleDocument()] },
            save: { _ in offSaveCount += 1; return true }
        )
        let delayedController = makeController(
            settings: { .init(mode: .afterDelay, delayMilliseconds: 500) },
            documents: { [self.eligibleDocument()] },
            save: { _ in delayedSaveCount += 1; return true }
        )

        offController.windowDidResignKey()
        delayedController.windowDidResignKey()
        await offController.waitForIdle()
        await delayedController.waitForIdle()

        XCTAssertEqual(offSaveCount, 0)
        XCTAssertEqual(delayedSaveCount, 0)
    }

    func testSameApplicationWindowSwitchSavesOnlyResigningComposition() async {
        let firstDocument = eligibleDocument(
            fileURL: URL(fileURLWithPath: "/tmp/first-window.txt")
        )
        let secondDocument = eligibleDocument(
            fileURL: URL(fileURLWithPath: "/tmp/second-window.txt")
        )
        var firstSaved: [UUID] = []
        var secondSaved: [UUID] = []
        let firstController = makeController(
            settings: { .init(mode: .onFocusChange, delayMilliseconds: 500) },
            documents: { [firstDocument] },
            save: { firstSaved.append($0.id); return true }
        )
        let secondController = makeController(
            settings: { .init(mode: .onFocusChange, delayMilliseconds: 500) },
            documents: { [secondDocument] },
            save: { secondSaved.append($0.id); return true }
        )
        let firstWindow = WindowCloseGuard.Coordinator(
            prepareToClose: { $0(true) }, session: nil, becameKey: {},
            resignedKey: { firstController.windowDidResignKey() },
            willClose: { _ in }
        )
        let secondWindow = WindowCloseGuard.Coordinator(
            prepareToClose: { $0(true) }, session: nil, becameKey: {},
            resignedKey: { secondController.windowDidResignKey() },
            willClose: { _ in }
        )

        // AppKit sends resign-key only to the old key window, then become-key
        // to the new one; the existing delegate seam targets one composition.
        firstWindow.windowDidResignKey(Notification(
            name: NSWindow.didResignKeyNotification
        ))
        secondWindow.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification
        ))
        await firstController.waitForIdle()
        await drainMainActor()

        XCTAssertEqual(firstSaved, [firstDocument.id])
        XCTAssertTrue(secondSaved.isEmpty)
        XCTAssertFalse(secondController.isRunningSavePass)
    }

    func testSavingFlagOnlyChangeDoesNotResetAfterDelayDebounce() async {
        let id = UUID()
        var document = eligibleDocument(id: id, isSaving: false)
        let delay = ControlledDelay()
        let controller = makeController(
            settings: { .init(mode: .afterDelay, delayMilliseconds: 600) },
            documents: { [document] },
            save: { _ in false },
            delay: delay
        )

        controller.documentStateDidChange()
        await drainMainActor()
        document = eligibleDocument(id: id, isSaving: true)
        controller.documentStateDidChange()
        await drainMainActor()

        XCTAssertEqual(delay.requestCount, 1)
        controller.cancel()
        delay.releaseAll()
    }

    func testSavePassFiltersUntitledCleanConflictEncodingIssueAndSavingDocuments() async {
        let eligible = eligibleDocument()
        let snapshots = [
            eligible,
            eligibleDocument(fileURL: nil),
            eligibleDocument(isDirty: false),
            eligibleDocument(hasExternalConflict: true),
            eligibleDocument(hasEncodingIssue: true),
            eligibleDocument(isSaving: true),
            eligibleDocument(isEditingLocked: true)
        ]
        var saved: [UUID] = []
        let controller = makeController(
            settings: { .init(mode: .onFocusChange, delayMilliseconds: 1_000) },
            documents: { snapshots },
            save: { snapshot in saved.append(snapshot.id); return true }
        )

        controller.windowDidResignKey()
        await controller.waitForIdle()

        XCTAssertEqual(saved, [eligible.id])
        XCTAssertTrue(controller.inFlightDocumentIDs.isEmpty)
    }

    func testOverlappingFocusEventsSerializeAndCoalesceSavePasses() async {
        let document = eligibleDocument()
        let saveGate = SaveGate()
        var saveCount = 0
        let controller = makeController(
            settings: { .init(mode: .onFocusChange, delayMilliseconds: 1_000) },
            documents: { [document] },
            save: { _ in
                saveCount += 1
                if saveCount == 1 { await saveGate.wait() }
                return false
            }
        )

        controller.windowDidResignKey()
        await waitUntil { controller.inFlightDocumentIDs.contains(document.id) }
        controller.windowDidResignKey()
        controller.windowDidResignKey()
        saveGate.releaseAll()
        await controller.waitForIdle()

        XCTAssertEqual(saveCount, 2, "Concurrent requests coalesce into one trailing pass")
        XCTAssertFalse(controller.isRunningSavePass)
    }

    func testSuccessfulSaveWithNewDirtyStateQueuesTrailingAfterDelayPass() async {
        let id = UUID()
        var current = eligibleDocument(id: id, revision: 1)
        var saveCount = 0
        let delay = ControlledDelay()
        let controller = makeController(
            settings: { .init(mode: .afterDelay, delayMilliseconds: 300) },
            documents: { [current] },
            save: { _ in
                saveCount += 1
                current = self.eligibleDocument(id: id, revision: 2)
                return true
            },
            delay: delay
        )

        controller.documentStateDidChange()
        await drainMainActor()
        delay.release(at: 0)
        await waitUntil { delay.requestCount == 2 }

        XCTAssertEqual(saveCount, 1)
        XCTAssertTrue(controller.hasPendingDelay)
        controller.cancel()
        delay.releaseAll()
        await controller.waitForIdle()
    }

    func testCancelInvalidatesPendingDelayAndLateSaveCompletion() async {
        var saveCount = 0
        let delay = ControlledDelay()
        let controller = makeController(
            settings: { .init(mode: .afterDelay, delayMilliseconds: 250) },
            documents: { [eligibleDocument()] },
            save: { _ in saveCount += 1; return true },
            delay: delay
        )

        controller.documentStateDidChange()
        await drainMainActor()
        controller.cancel()
        delay.releaseAll()
        await controller.waitForIdle()

        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(controller.hasPendingDelay)
        XCTAssertFalse(controller.isRunningSavePass)
        XCTAssertTrue(controller.inFlightDocumentIDs.isEmpty)
    }

    func testCancelDuringSaveRejectsLateCompletionAndTrailingWork() async {
        let document = eligibleDocument()
        let saveGate = SaveGate()
        let delay = ControlledDelay()
        var saveCount = 0
        let controller = makeController(
            settings: { .init(mode: .afterDelay, delayMilliseconds: 250) },
            documents: { [document] },
            save: { _ in
                saveCount += 1
                await saveGate.wait()
                return true
            },
            delay: delay
        )

        controller.documentStateDidChange()
        await drainMainActor()
        delay.release(at: 0)
        await waitUntil { controller.inFlightDocumentIDs.contains(document.id) }

        controller.cancel()
        saveGate.releaseAll()
        await drainMainActor()

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(delay.requestCount, 1, "Late completion must not schedule a tail")
        XCTAssertFalse(controller.hasPendingDelay)
        XCTAssertFalse(controller.isRunningSavePass)
        XCTAssertTrue(controller.inFlightDocumentIDs.isEmpty)
    }

    func testConnectedControllerIgnoresApplicationResignAndSavesOnWindowResign() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = SettingsController(
            store: SettingsStore(settingsURL: fixture.settingsURL),
            saveDebounceNanoseconds: 0
        )
        settings.set(AutoSaveMode.onFocusChange, for: \.autoSave)
        let model = AppModel(
            sessionStore: SessionStore(sessionURL: fixture.sessionURL),
            createInitialDocument: false
        )
        let url = fixture.directory.appendingPathComponent("connected.txt")
        try Data("before".utf8).write(to: url)
        let opened = try TextFileCodec.read(from: url)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        document.text = "after"
        let controller = AutoSaveController.connected(
            settings: settings,
            model: model
        )

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification, object: nil
        )
        await drainMainActor()
        await controller.waitForIdle()
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before")

        controller.windowDidResignKey()
        await waitUntil { !document.isDirty }
        await controller.waitForIdle()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after")
        XCTAssertFalse(controller.isRunningSavePass)
        controller.shutdown()
        _ = model.flushSession()
        _ = settings.flush()
    }

    func testConnectedWindowResignHonorsApplicationCloseReviewGate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = SettingsController(
            store: SettingsStore(settingsURL: fixture.settingsURL),
            saveDebounceNanoseconds: 0
        )
        settings.set(AutoSaveMode.onFocusChange, for: \.autoSave)
        let model = AppModel(
            sessionStore: SessionStore(sessionURL: fixture.sessionURL),
            createInitialDocument: false
        )
        let url = fixture.directory.appendingPathComponent("focus-close-review.txt")
        try Data("before".utf8).write(to: url)
        let document = try XCTUnwrap(model.open(
            openedFile: TextFileCodec.read(from: url)
        ))
        document.text = "reviewed draft"
        let controller = AutoSaveController.connected(settings: settings, model: model)

        XCTAssertTrue(model.beginApplicationCloseReview())
        await drainMainActor()
        controller.windowDidResignKey()
        await controller.waitForIdle()

        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before")

        model.cancelApplicationCloseReview()
        await drainMainActor()
        controller.windowDidResignKey()
        await waitUntil { !document.isDirty }
        await controller.waitForIdle()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "reviewed draft")
        controller.shutdown()
        _ = model.flushSession()
        _ = settings.flush()
    }

    func testConnectedPendingDelayCannotSaveDuringCloseReviewAndReschedulesAfterCancel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = SettingsController(
            store: SettingsStore(settingsURL: fixture.settingsURL),
            saveDebounceNanoseconds: 0
        )
        settings.set(AutoSaveMode.afterDelay, for: \.autoSave)
        settings.set(250, for: \.autoSaveDelayMs)
        let model = AppModel(
            sessionStore: SessionStore(sessionURL: fixture.sessionURL),
            createInitialDocument: false
        )
        let url = fixture.directory.appendingPathComponent("close-review.txt")
        try Data("before".utf8).write(to: url)
        let document = try XCTUnwrap(model.open(
            openedFile: TextFileCodec.read(from: url)
        ))
        let delay = ControlledDelay()
        let controller = AutoSaveController(
            settings: { AutoSaveSettingsSnapshot(settings.settings) },
            documents: { model.documents.map { AutoSaveDocumentSnapshot($0) } },
            save: { snapshot in
                guard !model.isTextEditingLocked,
                      let candidate = model.documents.first(where: { $0.id == snapshot.id }),
                      AutoSaveDocumentSnapshot(candidate).isEligible else { return false }
                return await model.save(candidate)
            },
            delay: { try await delay.sleep(nanoseconds: $0) }
        )

        document.text = "reviewed draft"
        controller.documentStateDidChange()
        await drainMainActor()
        XCTAssertTrue(model.beginApplicationCloseReview())
        controller.documentStateDidChange()
        await drainMainActor()
        delay.releaseAll()
        await controller.waitForIdle()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before")
        XCTAssertTrue(document.isDirty)

        model.cancelApplicationCloseReview()
        controller.documentStateDidChange()
        await drainMainActor()
        delay.releaseAll()
        await controller.waitForIdle()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "reviewed draft")
    }

    private func makeController(
        settings: @escaping AutoSaveController.SettingsSnapshot,
        documents: @escaping AutoSaveController.DocumentSnapshots,
        save: @escaping AutoSaveController.SaveDocument,
        delay: ControlledDelay? = nil
    ) -> AutoSaveController {
        AutoSaveController(
            settings: settings,
            documents: documents,
            save: save,
            delay: { nanoseconds in
                if let delay {
                    try await delay.sleep(nanoseconds: nanoseconds)
                } else {
                    try Task.checkCancellation()
                }
            }
        )
    }

    private func eligibleDocument(
        id: UUID = UUID(),
        fileURL: URL? = URL(fileURLWithPath: "/tmp/eligible.txt"),
        isDirty: Bool = true,
        hasExternalConflict: Bool = false,
        hasEncodingIssue: Bool = false,
        isSaving: Bool = false,
        isEditingLocked: Bool = false,
        revision: UInt64 = 1,
        encoding: TextEncoding = .utf8,
        lineEnding: LineEnding = .lf,
        eolOverride: LineEnding? = nil
    ) -> AutoSaveDocumentSnapshot {
        AutoSaveDocumentSnapshot(
            id: id,
            fileURL: fileURL,
            isDirty: isDirty,
            hasExternalConflict: hasExternalConflict,
            hasEncodingIssue: hasEncodingIssue,
            isSaving: isSaving,
            isEditingLocked: isEditingLocked,
            revision: revision,
            encoding: encoding,
            lineEnding: lineEnding,
            eolOverride: eolOverride
        )
    }

    private func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}

@MainActor
private final class ControlledDelay {
    private struct Request {
        let nanoseconds: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var requests: [Request?] = []

    var requestCount: Int { requests.count }
    var requestedNanoseconds: [UInt64] { requests.compactMap { $0?.nanoseconds } }

    func sleep(nanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(
                nanoseconds: nanoseconds,
                continuation: continuation
            ))
        }
    }

    func release(at index: Int) {
        guard requests.indices.contains(index), let request = requests[index] else { return }
        requests[index] = nil
        request.continuation.resume()
    }

    func releaseAll() {
        let current = requests.compactMap { $0 }
        for index in requests.indices { requests[index] = nil }
        for request in current { request.continuation.resume() }
    }
}

@MainActor
private final class SaveGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private struct Fixture {
    let directory: URL
    let settingsURL: URL
    let sessionURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-auto-save-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        settingsURL = directory.appendingPathComponent("settings.json")
        sessionURL = directory.appendingPathComponent("session.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
