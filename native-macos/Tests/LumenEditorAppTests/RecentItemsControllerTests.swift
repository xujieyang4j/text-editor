import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class RecentItemsControllerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    @MainActor
    func testLoadsTypedSnapshotsFiltersAndMaintainsSelection() throws {
        let store = try makeStore()
        try store.recordRecentFile(
            "/tmp/Alpha.swift", at: Date(timeIntervalSince1970: 10)
        )
        try store.recordRecentFile(
            "/tmp/notes/Beta.txt", at: Date(timeIntervalSince1970: 20)
        )
        try store.recordRecentProject(
            "/tmp/MyProject", at: Date(timeIntervalSince1970: 30)
        )

        let controller = RecentItemsController(
            store: store, openFile: { _ in true }, openProject: { _ in true }
        )

        XCTAssertEqual(controller.mode, .files)
        XCTAssertEqual(controller.items.map(\.kind), [.file, .file])
        XCTAssertEqual(controller.items.map(\.label), ["Beta.txt", "Alpha.swift"])
        XCTAssertEqual(controller.selectedIndex, 0)
        controller.selectItem(at: 1)
        XCTAssertEqual(controller.selectedItem?.path, "/tmp/Alpha.swift")

        XCTAssertEqual(controller.filter("ALPHA").map(\.path), ["/tmp/Alpha.swift"])
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(controller.filter("notes/beta").map(\.path), ["/tmp/notes/Beta.txt"])

        controller.present(.projects)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.presentationTitle, "Open Recent Project")
        XCTAssertEqual(controller.items.map(\.kind), [.project])
        XCTAssertEqual(controller.items.map(\.path), ["/tmp/MyProject"])
        XCTAssertEqual(controller.emptyMessage, "No recent projects are available.")
    }

    @MainActor
    func testSuccessfulFileOpenUsesCallbackThenRefreshesRecency() async throws {
        let store = try makeStore()
        try store.recordRecentFile(
            "/tmp/older.swift", at: Date(timeIntervalSince1970: 10)
        )
        try store.recordRecentFile(
            "/tmp/newer.swift", at: Date(timeIntervalSince1970: 20)
        )
        var openedURLs: [URL] = []
        let controller = RecentItemsController(
            store: store,
            openFile: { url in
                openedURLs.append(url)
                return true
            },
            now: { Date(timeIntervalSince1970: 40) }
        )
        controller.presentFiles()
        let older = try XCTUnwrap(controller.items.first { $0.path == "/tmp/older.swift" })

        let opened = await controller.openFile(older)

        XCTAssertTrue(opened)
        XCTAssertEqual(openedURLs.map(\.path), ["/tmp/older.swift"])
        XCTAssertEqual(store.loadRecentFiles().first?.path, "/tmp/older.swift")
        XCTAssertEqual(store.loadRecentFiles().first?.lastOpened, 40_000)
        XCTAssertEqual(controller.recentFiles.first?.path, "/tmp/older.swift")
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testSuccessfulProjectOpenUsesProjectCallbackAndRecordsProjectOnly() async throws {
        let store = try makeStore()
        try store.recordRecentProject(
            "/tmp/workspace", at: Date(timeIntervalSince1970: 5)
        )
        var fileCalls = 0
        var projectURLs: [URL] = []
        let controller = RecentItemsController(
            store: store,
            openFile: { _ in fileCalls += 1; return true },
            openProject: { url in projectURLs.append(url); return true },
            now: { Date(timeIntervalSince1970: 60) }
        )
        controller.presentProjects()

        let opened = await controller.acceptSelection()

        XCTAssertTrue(opened)
        XCTAssertEqual(fileCalls, 0)
        XCTAssertEqual(projectURLs.map(\.path), ["/tmp/workspace"])
        XCTAssertTrue(store.loadRecentFiles().isEmpty)
        XCTAssertEqual(store.loadRecentProjects().first?.lastOpened, 60_000)
    }

    @MainActor
    func testOnlyCurrentExactStoreMembershipCanReachAnOpenCallback() async throws {
        let store = try makeStore()
        try store.recordRecentProject("/tmp/shared")
        try store.recordRecentFile("/tmp/CaseSensitive.swift")
        var fileCalls = 0
        var projectCalls = 0
        let controller = RecentItemsController(
            store: store,
            openFile: { _ in fileCalls += 1; return true },
            openProject: { _ in projectCalls += 1; return true }
        )

        let projectAsFile = await controller.openFile(URL(fileURLWithPath: "/tmp/shared"))
        let wrongCase = await controller.openFile(
            URL(fileURLWithPath: "/tmp/casesensitive.swift")
        )
        let wrongTypedItem = await controller.openProject(
            RecentPresentationItem(kind: .file, path: "/tmp/shared", lastOpened: 0)
        )
        let forgedRelativeItem = await controller.openFile(
            RecentPresentationItem(kind: .file, path: "tmp/CaseSensitive.swift", lastOpened: 0)
        )
        XCTAssertFalse(projectAsFile)
        XCTAssertFalse(wrongCase)
        XCTAssertFalse(wrongTypedItem)
        XCTAssertFalse(forgedRelativeItem)
        XCTAssertEqual(fileCalls, 0)
        XCTAssertEqual(projectCalls, 0)
        XCTAssertNotNil(controller.issue)

        let displayed = try XCTUnwrap(
            controller.recentFiles.first { $0.path == "/tmp/CaseSensitive.swift" }
        )
        XCTAssertTrue(try store.removeRecentFile(displayed.path))
        let removedBeforeOpen = await controller.openFile(displayed)
        XCTAssertFalse(removedBeforeOpen)
        XCTAssertEqual(fileCalls, 0)
        XCTAssertFalse(controller.recentFiles.contains { $0.id == displayed.id })
        XCTAssertTrue(controller.issue?.message.contains("no longer") == true)
    }

    @MainActor
    func testOpenFailureKeepsItemAndExposesExplicitRemovalRecovery() async throws {
        let store = try makeStore()
        try store.recordRecentFile("/tmp/gone.swift")
        let controller = RecentItemsController(
            store: store,
            openFile: { _ in throw RecentOpenFailure.unavailable }
        )
        let item = try XCTUnwrap(controller.items.first)

        let opened = await controller.openFile(item)
        XCTAssertFalse(opened)
        XCTAssertEqual(store.loadRecentFiles().map(\.path), ["/tmp/gone.swift"])
        XCTAssertEqual(controller.issue?.title, "Could Not Open Recent File")
        XCTAssertTrue(controller.issue?.message.contains("fixture unavailable") == true)
        XCTAssertEqual(
            controller.issue?.content,
            .openFailure(
                kind: .file, cause: .verbatim("fixture unavailable"),
                removed: false, removalFailure: nil
            )
        )
        XCTAssertEqual(controller.issue?.removableItem, item)
        XCTAssertTrue(controller.issue?.canRemoveStaleItem == true)

        XCTAssertTrue(controller.removeUnavailableItem())
        XCTAssertTrue(store.loadRecentFiles().isEmpty)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testOpenFailureCanRemoveUnavailableItemImmediately() async throws {
        let store = try makeStore()
        try store.recordRecentProject("/tmp/gone-project")
        let controller = RecentItemsController(
            store: store,
            openProject: { _ in false }
        )
        controller.presentProjects()
        let item = try XCTUnwrap(controller.selectedItem)

        let opened = await controller.openProject(item, removeIfUnavailable: true)
        XCTAssertFalse(opened)
        XCTAssertTrue(store.loadRecentProjects().isEmpty)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertNil(controller.issue?.removableItem)
        XCTAssertTrue(controller.issue?.message.contains("was removed") == true)
    }

    @MainActor
    func testLaterOpenIntentWinsAndLateCompletionCannotPublishOrRefreshRecency() async throws {
        let store = try makeStore()
        try store.recordRecentFile(
            "/tmp/first.swift", at: Date(timeIntervalSince1970: 10)
        )
        try store.recordRecentFile(
            "/tmp/second.swift", at: Date(timeIntervalSince1970: 20)
        )
        let gate = ControlledRecentOpener()
        let controller = RecentItemsController(
            store: store,
            openFile: { url in try await gate.open(url) },
            now: { Date(timeIntervalSince1970: 50) }
        )
        let first = try XCTUnwrap(controller.recentFiles.first {
            $0.path == "/tmp/first.swift"
        })
        let second = try XCTUnwrap(controller.recentFiles.first {
            $0.path == "/tmp/second.swift"
        })

        let firstTask = Task { @MainActor in await controller.openFile(first) }
        await gate.waitForCall("/tmp/first.swift")
        let secondTask = Task { @MainActor in await controller.openFile(second) }
        await gate.waitForCall("/tmp/second.swift")

        await gate.resume("/tmp/second.swift", returning: true)
        let secondOpened = await secondTask.value
        XCTAssertTrue(secondOpened)
        XCTAssertEqual(store.loadRecentFiles().first?.path, "/tmp/second.swift")
        XCTAssertEqual(store.loadRecentFiles().first?.lastOpened, 50_000)

        await gate.resume("/tmp/first.swift", throwing: RecentOpenFailure.unavailable)
        let firstOpened = await firstTask.value
        XCTAssertFalse(firstOpened)
        XCTAssertEqual(store.loadRecentFiles().first?.path, "/tmp/second.swift")
        XCTAssertEqual(
            store.loadRecentFiles().first { $0.path == "/tmp/first.swift" }?.lastOpened,
            10_000
        )
        XCTAssertNil(controller.issue)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testDismissInvalidatesPendingOpenCompletion() async throws {
        let store = try makeStore()
        try store.recordRecentFile(
            "/tmp/pending.swift", at: Date(timeIntervalSince1970: 10)
        )
        let gate = ControlledRecentOpener()
        let controller = RecentItemsController(
            store: store,
            openFile: { url in try await gate.open(url) },
            now: { Date(timeIntervalSince1970: 90) }
        )
        controller.presentFiles()
        let item = try XCTUnwrap(controller.selectedItem)
        let task = Task { @MainActor in await controller.openFile(item) }
        await gate.waitForCall(item.path)

        controller.dismiss()
        await gate.resume(item.path, returning: true)

        let opened = await task.value
        XCTAssertFalse(opened)
        XCTAssertEqual(store.loadRecentFiles().first?.lastOpened, 10_000)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testRecordAndRemoveAPIsPersistThroughInjectedStore() throws {
        let store = try makeStore()
        let controller = RecentItemsController(
            store: store, openFile: { _ in true }, openProject: { _ in true }
        )

        XCTAssertTrue(controller.recordFile(
            URL(fileURLWithPath: "/tmp/dir/../recorded.swift"),
            at: Date(timeIntervalSince1970: 7)
        ))
        XCTAssertTrue(controller.recordProject(
            URL(fileURLWithPath: "/tmp/recorded-project"),
            at: Date(timeIntervalSince1970: 8)
        ))
        XCTAssertEqual(controller.recentFiles.map(\.path), ["/tmp/recorded.swift"])
        XCTAssertEqual(controller.recentProjects.map(\.path), ["/tmp/recorded-project"])

        let project = try XCTUnwrap(controller.recentProjects.first)
        XCTAssertTrue(controller.removeStale(project))
        XCTAssertTrue(store.loadRecentProjects().isEmpty)
        XCTAssertFalse(controller.removeStale(project))
    }

    @MainActor
    func testCommandRegistrationPresentsEachModeAndPublishesContract() async throws {
        let store = try makeStore()
        try store.recordRecentFile("/tmp/file.swift")
        try store.recordRecentProject("/tmp/project")
        let controller = RecentItemsController(
            store: store, openFile: { _ in true }, openProject: { _ in true }
        )
        let router = CommandRouter()

        let tokens = try controller.registerCommands(on: router)

        XCTAssertEqual(tokens.map(\.commandID), RecentItemsController.commandIDs)
        let context = CommandRoutingContext()
        XCTAssertEqual(router.status(for: "open-recent-file", context: context), .enabled)
        XCTAssertEqual(router.status(for: "open-recent-project", context: context), .enabled)

        let fileResult = await router.execute("open-recent-file", context: context)
        XCTAssertTrue(fileResult.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.mode, .files)
        XCTAssertEqual(controller.items.map(\.path), ["/tmp/file.swift"])
        let firstFocusGeneration = controller.focusGeneration

        let projectResult = await router.execute("open-recent-project", context: context)
        XCTAssertTrue(projectResult.didExecuteSuccessfully)
        XCTAssertEqual(controller.mode, .projects)
        XCTAssertEqual(controller.items.map(\.path), ["/tmp/project"])
        XCTAssertGreaterThan(controller.focusGeneration, firstFocusGeneration)
    }

    @MainActor
    func testPartialCommandRegistrationRollsBackOwnership() throws {
        let store = try makeStore()
        let controller = RecentItemsController(store: store)
        let router = CommandRouter()
        _ = try router.register("open-recent-project") { _ in }

        XCTAssertThrowsError(try controller.registerCommands(on: router))
        let context = CommandRoutingContext()
        XCTAssertEqual(
            router.status(for: "open-recent-file", context: context), .unsupported
        )
        XCTAssertEqual(
            router.status(for: "open-recent-project", context: context), .enabled
        )
    }

    func testRecentIssueCopyRerendersAndPreservesExternalFailures() {
        let typed = RecentItemsPresentationIssue.Message.store(
            .serializedDataTooLarge(actualBytes: 17, maximumBytes: 12)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedRecentIssue(typed),
            "Recent-item data uses 17 bytes; the maximum is 12 bytes."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedRecentIssue(typed),
            "最近打开项数据占用 17 字节；上限为 12 字节。"
        )

        let external = RecentItemsPresentationIssue.Message.openFailure(
            kind: .file,
            cause: .verbatim("The selected file could not be opened."),
            removed: true, removalFailure: nil
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedRecentIssue(external),
            "The selected file could not be opened. 不可用项目已从最近使用列表中移除。"
        )
    }

    private func makeStore() throws -> RecentItemsStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecentItemsControllerTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return RecentItemsStore(directoryURL: directory)
    }
}

private enum RecentOpenFailure: Error, LocalizedError {
    case unavailable

    var errorDescription: String? { "fixture unavailable" }
}

private actor ControlledRecentOpener {
    private typealias OpenContinuation = CheckedContinuation<Bool, any Error>

    private var calls: [String] = []
    private var continuations: [String: OpenContinuation] = [:]
    private var callWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func open(_ url: URL) async throws -> Bool {
        let path = url.path
        return try await withCheckedThrowingContinuation { continuation in
            calls.append(path)
            continuations[path] = continuation
            for waiter in callWaiters.removeValue(forKey: path) ?? [] {
                waiter.resume()
            }
        }
    }

    func waitForCall(_ path: String) async {
        guard !calls.contains(path) else { return }
        await withCheckedContinuation { continuation in
            callWaiters[path, default: []].append(continuation)
        }
    }

    func resume(_ path: String, returning value: Bool) {
        continuations.removeValue(forKey: path)?.resume(returning: value)
    }

    func resume(_ path: String, throwing error: any Error) {
        continuations.removeValue(forKey: path)?.resume(throwing: error)
    }
}
