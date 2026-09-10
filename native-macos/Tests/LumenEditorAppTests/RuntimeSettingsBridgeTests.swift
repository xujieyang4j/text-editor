import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class RuntimeSettingsBridgeTests: XCTestCase {
    func testBuildCommandHydratesCommitsOnApprovedStartAndFollowsSettingsChanges() async throws {
        let fixture = try Fixture(settings: EditorSettings(buildCommand: "swift test"))
        defer { fixture.remove() }
        let workspace = fixture.directory.appendingPathComponent(
            "workspace", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: false
        )
        let projectStore = ProjectSettingsStore(workspaceURL: workspace)
        _ = try projectStore.save(
            ProjectSettings(buildCommand: "project build"), expectedRevision: nil
        )
        let runner = RuntimeBuildRunnerStub()
        let approvals = ToolApprovalStore()
        let scope = ToolApprovalScope(
            windowID: "runtime-settings", sessionID: UUID().uuidString
        )
        let build = BuildController(
            workspaceRoot: workspace, runner: runner, approvals: approvals, scope: scope
        )
        let find = findController()
        let workspaceSearch = workspaceSearchController()
        let project = ProjectSettingsController()
        project.updateWorkspace(workspace, store: projectStore)
        let bridge = RuntimeSettingsBridge(
            settings: fixture.settings,
            build: build,
            find: find,
            workspaceSearch: workspaceSearch,
            projectSettings: project
        )
        _ = bridge

        XCTAssertEqual(build.freeFormCommand, "project build")
        build.freeFormCommand = "  npm test  "
        XCTAssertEqual(fixture.settings.settings.buildCommand, "swift test")
        XCTAssertEqual(project.settings.buildCommand, "project build")
        XCTAssertEqual(try projectStore.load().settings.buildCommand, "project build")
        fixture.settings.set("global edit while typing", for: \.buildCommand)
        XCTAssertEqual(
            build.freeFormCommand, "  npm test  ",
            "Typing must not clear the active project override"
        )

        let requestOutcome = await build.requestFreeFormBuild()
        XCTAssertEqual(requestOutcome, .awaitingApproval)
        XCTAssertEqual(fixture.settings.settings.buildCommand, "global edit while typing")
        XCTAssertEqual(project.settings.buildCommand, "project build")

        await build.confirmPendingBuild()
        await build.waitForCurrentBuild()
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(build.freeFormCommand, "npm test")
        XCTAssertEqual(fixture.settings.settings.buildCommand, "npm test")
        XCTAssertEqual(fixture.store.load().buildCommand, "npm test")
        XCTAssertEqual(project.settings.buildCommand, "npm test")
        XCTAssertEqual(try projectStore.load().settings.buildCommand, "npm test")

        fixture.settings.set("xcodebuild", for: .buildCommand)
        XCTAssertEqual(build.freeFormCommand, "npm test")
        try project.persistBuildCommand(
            "project override", approvedWorkspaceRoot: workspace
        )
        XCTAssertEqual(build.freeFormCommand, "project override")
        try project.persistBuildCommand("", approvedWorkspaceRoot: workspace)
        XCTAssertEqual(build.freeFormCommand, "xcodebuild")

        project.updateWorkspace(nil)
        build.freeFormCommand = "echo unavailable"
        let unavailableOutcome = await build.requestFreeFormBuild()
        XCTAssertEqual(unavailableOutcome, .awaitingApproval)
        await build.confirmPendingBuild()
        let unchangedRunCount = await runner.runCount
        XCTAssertEqual(unchangedRunCount, 1)
        XCTAssertNil(build.pendingApproval)
        XCTAssertEqual(build.issue?.title, "Could Not Save Build Command")
        XCTAssertTrue(build.issue?.message.contains("Project settings are not ready") == true)
        XCTAssertEqual(fixture.settings.settings.buildCommand, "xcodebuild")

        let rollbackFailure = BuildCommandPersistenceError.partialPersistence(
            globalFailure: "disk full", projectRollbackFailure: "conflict"
        ).localizedDescription
        XCTAssertTrue(rollbackFailure.contains("Rolling back project settings also failed"))
        XCTAssertTrue(rollbackFailure.contains("Global and project build commands may differ"))
    }

    func testPersistenceTransactionReportsRollbackFailureWithoutHidingPartialCommit() {
        enum Failure: Error { case global, rollback }
        var rolledBackEvents: [String] = []
        XCTAssertThrowsError(try BuildCommandPersistenceTransaction.commit(
            persistProject: { rolledBackEvents.append("project"); return 11 },
            persistGlobal: { rolledBackEvents.append("global"); throw Failure.global },
            rollbackProject: { receipt in
                XCTAssertEqual(receipt, 11)
                rolledBackEvents.append("rollback")
            }
        )) { error in
            guard case .globalWriteFailed = error as? BuildCommandPersistenceError else {
                return XCTFail("Expected a global-write failure after successful rollback")
            }
        }
        XCTAssertEqual(rolledBackEvents, ["project", "global", "rollback"])

        var partialEvents: [String] = []
        let globalCommand = "old global"
        var projectCommand = "old project"

        XCTAssertThrowsError(try BuildCommandPersistenceTransaction.commit(
            persistProject: {
                partialEvents.append("project")
                projectCommand = "new command"
                return 17
            },
            persistGlobal: { partialEvents.append("global"); throw Failure.global },
            rollbackProject: { receipt in
                XCTAssertEqual(receipt, 17)
                partialEvents.append("rollback")
                throw Failure.rollback
            }
        )) { error in
            guard case let .partialPersistence(globalFailure, rollbackFailure) =
                error as? BuildCommandPersistenceError else {
                return XCTFail("Expected typed partial-persistence failure")
            }
            XCTAssertFalse(globalFailure.isEmpty)
            XCTAssertFalse(rollbackFailure.isEmpty)
        }
        XCTAssertEqual(partialEvents, ["project", "global", "rollback"])
        XCTAssertEqual(globalCommand, "old global")
        XCTAssertEqual(
            projectCommand, "new command",
            "A failed rollback must not make in-memory state claim the old value"
        )
    }

    func testPrepareSidebarRevealPersistsDistractionFreeBeforePublishing() throws {
        let fixture = try Fixture(settings: EditorSettings(distractionFree: true))
        defer { fixture.remove() }
        let bridge = RuntimeSettingsBridge(
            settings: fixture.settings,
            build: BuildController(
                workspaceRoot: nil, runner: RuntimeBuildRunnerStub(),
                approvals: ToolApprovalStore(),
                scope: ToolApprovalScope(windowID: "reveal", sessionID: "success")
            ),
            find: findController(), workspaceSearch: workspaceSearchController(),
            projectSettings: ProjectSettingsController()
        )

        XCTAssertTrue(bridge.prepareSidebarReveal())
        XCTAssertFalse(fixture.settings.settings.distractionFree)
        XCTAssertFalse(fixture.store.load().distractionFree)
    }

    func testPrepareSidebarRevealFailsClosedWhenPersistenceFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuntimeSettingsRevealFailure-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let settings = SettingsController(store: SettingsStore(
            settingsURL: blockedParent.appendingPathComponent("settings.json")
        ))
        settings.set(true, for: .distractionFree)
        let bridge = RuntimeSettingsBridge(
            settings: settings,
            build: BuildController(
                workspaceRoot: nil, runner: RuntimeBuildRunnerStub(),
                approvals: ToolApprovalStore(),
                scope: ToolApprovalScope(windowID: "reveal", sessionID: "failure")
            ),
            find: findController(), workspaceSearch: workspaceSearchController(),
            projectSettings: ProjectSettingsController()
        )

        XCTAssertFalse(bridge.prepareSidebarReveal())
        XCTAssertTrue(settings.settings.distractionFree)
        XCTAssertNotNil(settings.persistenceIssue)
    }

    func testGlobalWriteFailureRollsProjectBackAndPreventsExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuntimeSettingsBridgeFailure-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedParent)
        let settings = SettingsController(store: SettingsStore(
            settingsURL: blockedParent.appendingPathComponent("settings.json")
        ))
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: false
        )
        let projectStore = ProjectSettingsStore(workspaceURL: workspace)
        _ = try projectStore.save(
            ProjectSettings(buildCommand: "project old"), expectedRevision: nil
        )
        let project = ProjectSettingsController()
        project.updateWorkspace(workspace, store: projectStore)
        let runner = RuntimeBuildRunnerStub()
        let approvals = ToolApprovalStore()
        let scope = ToolApprovalScope(
            windowID: "runtime-settings-failure", sessionID: UUID().uuidString
        )
        let configuration = try ToolExecutionConfiguration(
            kind: .buildCommand, root: workspace, command: "echo approved", shell: true
        )
        _ = await approvals.approve(configuration, in: scope)
        let build = BuildController(
            workspaceRoot: workspace, runner: runner, approvals: approvals, scope: scope
        )
        let bridge = RuntimeSettingsBridge(
            settings: settings, build: build, find: findController(),
            workspaceSearch: workspaceSearchController(), projectSettings: project
        )
        _ = bridge

        let outcome = await build.requestFreeFormBuild("echo approved")

        guard case .failed = outcome else {
            return XCTFail("A global persistence failure must reject the build")
        }
        XCTAssertNil(build.pendingApproval)
        XCTAssertFalse(build.isRunning)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(settings.settings.buildCommand, "")
        XCTAssertEqual(project.settings.buildCommand, "project old")
        XCTAssertEqual(try projectStore.load().settings.buildCommand, "project old")
        XCTAssertTrue(build.issue?.message.contains("project build command was restored") == true)
    }

    func testSharedHistoryIsBoundedDeduplicatedAndVisibleToBothSearchSurfaces() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let build = BuildController()
        let find = findController()
        let workspaceSearch = workspaceSearchController()
        let project = ProjectSettingsController()
        let bridge = RuntimeSettingsBridge(
            settings: fixture.settings,
            build: build,
            find: find,
            workspaceSearch: workspaceSearch,
            projectSettings: project
        )
        _ = bridge

        for index in 0 ..< 55 {
            fixture.settings.rememberSearchHistory("query-\(index)")
        }
        fixture.settings.rememberSearchHistory("query-50", replacement: "")

        XCTAssertEqual(fixture.settings.settings.searchHistory.count, 50)
        XCTAssertEqual(fixture.settings.settings.searchHistory.first, "query-50")
        XCTAssertEqual(fixture.settings.settings.replaceHistory.first, "")
        XCTAssertEqual(find.searchHistory, fixture.settings.settings.searchHistory)
        XCTAssertEqual(find.replaceHistory, fixture.settings.settings.replaceHistory)
        XCTAssertEqual(workspaceSearch.searchHistory, fixture.settings.settings.searchHistory)
        XCTAssertEqual(workspaceSearch.replaceHistory, fixture.settings.settings.replaceHistory)
    }

    private func findController() -> FindBarController {
        FindBarController(
            snapshot: { nil },
            selectMatch: { _ in false },
            applyEdits: { _ in false }
        )
    }

    private func workspaceSearchController() -> WorkspaceSearchController {
        WorkspaceSearchController(
            rootIDs: [],
            search: { _ in WorkspaceSearchResult(matches: [], isTruncated: false) },
            preview: { _ in throw TestError.unexpected },
            apply: { _ in throw TestError.unexpected },
            undo: { _ in throw TestError.unexpected }
        )
    }

    private enum TestError: Error { case unexpected }

    private struct Fixture {
        let directory: URL
        let store: SettingsStore
        let settings: SettingsController

        init(settings initial: EditorSettings = .default) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RuntimeSettingsBridgeTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            store = SettingsStore(
                settingsURL: directory.appendingPathComponent("settings.json")
            )
            try store.save(initial)
            settings = SettingsController(store: store, saveDebounceNanoseconds: 0)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

private actor RuntimeBuildRunnerStub: BuildProcessRunning {
    private(set) var runCount = 0

    func run(
        _ command: ToolCommand, onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> ToolProcessResult {
        runCount += 1
        return ToolProcessResult(
            standardOutput: Data(), standardError: Data(), exitCode: 0
        )
    }

    func cancelAll() async {}
}
