import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class PluginControllerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    @MainActor
    func testControllerPublishesOnlyEnabledDeclarativeInsertCommandsAndSnippets() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        try writeManifest([
            "id": "declarative",
            "name": "Declarative",
            "commands": [
                ["id": "insert", "title": "Insert", "insertText": "hello"],
                ["id": "no-op", "title": "No insertion"]
            ],
            "snippets": [[
                "label": "Swift log",
                "text": "print(${1:value})",
                "trigger": "log",
                "scope": "Swift"
            ]]
        ], to: source)
        let store = PluginStore(workspaceURL: workspace, trashHandler: AppTestTrash())
        _ = try store.installLocalPlugin(from: source)
        let controller = PluginController()

        controller.updateWorkspace(workspace, store: store)

        XCTAssertEqual(controller.commandRoutes.map(\.id), ["plugin:declarative:0"])
        XCTAssertEqual(controller.commandRoutes.first?.requirements, .document)
        XCTAssertEqual(controller.insertText(for: "plugin:declarative:0"), "hello")
        XCTAssertEqual(controller.snippets(scope: "Swift", trigger: "log").count, 1)
        XCTAssertEqual(controller.snippets(scope: "JavaScript", trigger: "log"), [])
        XCTAssertEqual(controller.workerExecutionSupport, .unsupported)
        XCTAssertEqual(controller.shellSnapshot.workerExecutionSupport, .unsupported)
        XCTAssertEqual(controller.shellSnapshot.workerCommands, [])

        let router = CommandRouter()
        let unavailable = router.searchPluginCommands(
            "insert", routes: controller.commandRoutes, context: CommandRoutingContext()
        )
        XCTAssertEqual(
            unavailable.first?.status,
            .disabled(.missingRequirements(.document))
        )
        XCTAssertEqual(
            router.routePluginCommand(
                "plugin:declarative:0",
                routes: controller.commandRoutes,
                context: CommandRoutingContext(hasDocument: true)
            ),
            .insertText("hello")
        )

        XCTAssertTrue(controller.setEnabled(false, pluginID: "declarative"))
        XCTAssertEqual(controller.commandRoutes, [])
        XCTAssertEqual(controller.snippetRoutes, [])
        XCTAssertNil(controller.insertText(for: "plugin:declarative:0"))
    }

    @MainActor
    func testPermissionChangesAreBoundedByManifestAndStayProjectScoped() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        try writeManifest([
            "id": "permissions",
            "name": "Permissions",
            "extension": [
                "worker": "worker.js",
                "permissions": ["document-read"]
            ]
        ], to: source)
        try Data().write(to: source.appendingPathComponent("worker.js"))
        let store = PluginStore(workspaceURL: workspace, trashHandler: AppTestTrash())
        _ = try store.installLocalPlugin(from: source)
        let controller = PluginController()
        controller.updateWorkspace(workspace, store: store)

        XCTAssertTrue(controller.setPermission(
            .documentRead, granted: true, pluginID: "permissions"
        ))
        XCTAssertEqual(controller.plugins.first?.grantedPermissions, [.documentRead])

        // The store intersects grants with requested permissions; an App caller
        // cannot silently broaden a manifest's capability declaration.
        try store.setGrantedPermissions(
            [.documentRead, .documentEdit], forPluginID: "permissions"
        )
        controller.refresh()
        XCTAssertEqual(controller.plugins.first?.grantedPermissions, [.documentRead])
    }

    @MainActor
    func testWorkspaceSwitchImmediatelyRemovesPreviousDynamicData() throws {
        let firstWorkspace = try temporaryDirectory()
        let secondWorkspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        try writeManifest([
            "id": "first",
            "name": "First",
            "commands": [["id": "insert", "title": "Insert", "insertText": "x"]]
        ], to: source)
        let firstStore = PluginStore(workspaceURL: firstWorkspace, trashHandler: AppTestTrash())
        let secondStore = PluginStore(workspaceURL: secondWorkspace, trashHandler: AppTestTrash())
        _ = try firstStore.installLocalPlugin(from: source)
        let controller = PluginController()
        controller.updateWorkspace(firstWorkspace, store: firstStore)
        XCTAssertEqual(controller.commandRoutes.count, 1)

        controller.updateWorkspace(secondWorkspace, store: secondStore)
        XCTAssertEqual(controller.plugins, [])
        XCTAssertEqual(controller.commandRoutes, [])
        XCTAssertEqual(controller.snippetRoutes, [])

        controller.updateWorkspace(nil)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertFalse(controller.installLocalPlugin(from: source))
        XCTAssertEqual(controller.issue?.title, "No Workspace Open")
    }

    @MainActor
    func testSameWorkspaceContextUpdateDoesNotReloadPluginState() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        try writeManifest([
            "id": "stable",
            "name": "Stable",
            "commands": [[
                "id": "insert", "title": "Insert", "insertText": "x"
            ]]
        ], to: source)
        let store = PluginStore(workspaceURL: workspace, trashHandler: AppTestTrash())
        _ = try store.installLocalPlugin(from: source)
        let controller = PluginController()
        controller.updateWorkspace(workspace, store: store)
        XCTAssertEqual(controller.commandRoutes.count, 1)

        // The editor workspace task also changes when only the selected tab
        // changes. Repeating the same root without an injected replacement
        // store must be a no-op, not a plugin runtime teardown/reload.
        controller.updateWorkspace(workspace)

        XCTAssertEqual(controller.commandRoutes.count, 1)
        XCTAssertEqual(controller.plugins.map(\.id), ["stable"])
    }

    @MainActor
    func testUninstallImmediatelyRemovesRoutes() throws {
        let workspace = try temporaryDirectory()
        let trashDirectory = try temporaryDirectory()
        let source = try temporaryDirectory()
        try writeManifest([
            "id": "remove",
            "name": "Remove",
            "commands": [["id": "insert", "title": "Insert", "insertText": "x"]]
        ], to: source)
        let store = PluginStore(
            workspaceURL: workspace,
            trashHandler: AppTestTrash(destinationDirectory: trashDirectory)
        )
        _ = try store.installLocalPlugin(from: source)
        let controller = PluginController()
        controller.updateWorkspace(workspace, store: store)

        XCTAssertTrue(controller.uninstallPlugin(id: "remove"))
        XCTAssertEqual(controller.plugins, [])
        XCTAssertEqual(controller.commandRoutes, [])
    }

    @MainActor
    func testProductionFactoryExposesIsolatedWorkerSupport() {
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-factory-" + UUID().uuidString)
        temporaryDirectories.append(sessionDirectory)
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: sessionDirectory.appendingPathComponent("session.json")
            ),
            createInitialDocument: false
        )
        let controller = PluginController.production(
            model: model,
            approvals: ToolApprovalStore(),
            scope: ToolApprovalScope(windowID: "window", sessionID: "session")
        )

        XCTAssertEqual(controller.workerExecutionSupport, .isolatedProcess)
        XCTAssertNotNil(controller.workerRuntime)
        XCTAssertEqual(controller.shellSnapshot.workerCommands, [])
    }

    @MainActor
    func testControllerPreservesTypedPluginStoreFailureForRuntimeLocale() throws {
        let workspace = try temporaryDirectory()
        let controller = PluginController()
        let invalidStore = PluginStore(
            workspaceURL: workspace.appendingPathComponent("missing-workspace")
        )

        controller.updateWorkspace(workspace, store: invalidStore)

        let issue = try XCTUnwrap(controller.issue)
        XCTAssertEqual(issue.titleCopy, .couldNotLoadPlugins)
        guard case let .pluginStore(error) = issue.content else {
            return XCTFail("Expected a typed plugin-store failure")
        }
        guard case let .invalidWorkspace(url) = error else {
            return XCTFail("Expected an invalid-workspace error")
        }
        XCTAssertEqual(
            url.standardizedFileURL,
            workspace.appendingPathComponent("missing-workspace").standardizedFileURL
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPluginIssue(issue.content),
            "插件工作区不是实际的本地目录："
                + workspace.appendingPathComponent("missing-workspace").path
        )

        struct ExternalFailure: LocalizedError {
            let errorDescription: String? = "外部插件错误 /tmp/private"
        }

        XCTAssertEqual(
            PluginController.presentationMessage(for: ExternalFailure()),
            .verbatim("外部插件错误 /tmp/private")
        )
    }

    private func writeManifest(_ object: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent(PluginStore.manifestFileName))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-controller-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }
}

private final class AppTestTrash: WorkspaceTrashHandling, @unchecked Sendable {
    private let destinationDirectory: URL?

    init(destinationDirectory: URL? = nil) {
        self.destinationDirectory = destinationDirectory
    }

    func trashItem(at url: URL) throws {
        guard let destinationDirectory else { return }
        try FileManager.default.moveItem(
            at: url, to: destinationDirectory.appendingPathComponent(url.lastPathComponent)
        )
    }
}
