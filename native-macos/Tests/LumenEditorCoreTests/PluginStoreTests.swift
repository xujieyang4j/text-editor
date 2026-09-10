import Foundation
import XCTest
@testable import LumenEditorCore

final class PluginStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testLocalInstallStagesCopiesAndPublishesProjectScopedPlugin() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        try writeManifest(
            [
                "id": "sample-plugin",
                "name": "Sample",
                "commands": [[
                    "id": "insert-heading",
                    "title": "Insert heading",
                    "insertText": "# Heading\n"
                ]],
                "snippets": [["label": "Log", "text": "print($0)"]]
            ],
            to: source
        )
        let asset = source.appendingPathComponent("assets/note.txt")
        try FileManager.default.createDirectory(
            at: asset.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("copied".utf8).write(to: asset)

        let store = PluginStore(workspaceURL: workspace, trashHandler: RecordingPluginTrash())
        let installed = try store.installLocalPlugin(from: source)

        XCTAssertEqual(installed.id, "sample-plugin")
        XCTAssertTrue(installed.isEnabled)
        XCTAssertEqual(installed.workerExecutionSupport, .unsupported)
        XCTAssertEqual(
            try String(contentsOf: installed.directoryURL.appendingPathComponent("assets/note.txt")),
            "copied"
        )
        XCTAssertEqual(try store.listInstalledPlugins().map(\.id), ["sample-plugin"])
        let storageNames = try FileManager.default.contentsOfDirectory(
            atPath: store.pluginsURL.path
        )
        XCTAssertFalse(storageNames.contains { $0.hasPrefix(".installing-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.projectStateURL.path))
    }

    func testInstallRejectsSymlinkAnywhereAndLeavesNoPartialPlugin() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        try writeManifest(["id": "linked", "name": "Linked"], to: source)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )

        let store = PluginStore(workspaceURL: workspace, trashHandler: RecordingPluginTrash())
        XCTAssertThrowsError(try store.installLocalPlugin(from: source)) { error in
            XCTAssertEqual(error as? PluginStoreError, .symbolicLinkEncountered("escape.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.pluginsURL.appendingPathComponent("linked").path
        ))
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.pluginsURL.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".installing-") })
    }

    func testInstallRejectsLinkedManifestAndLinkedPluginStorage() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        let manifestTarget = try temporaryDirectory().appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["id": "linked", "name": "Linked"])
            .write(to: manifestTarget)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent(PluginStore.manifestFileName),
            withDestinationURL: manifestTarget
        )
        let store = PluginStore(workspaceURL: workspace, trashHandler: RecordingPluginTrash())
        XCTAssertThrowsError(try store.installLocalPlugin(from: source)) { error in
            XCTAssertEqual(error as? PluginStoreError, .symbolicLinkEncountered("plugin.json"))
        }

        let linkedWorkspace = try temporaryDirectory()
        let other = try temporaryDirectory()
        let linkedStore = PluginStore(
            workspaceURL: linkedWorkspace, trashHandler: RecordingPluginTrash()
        )
        try FileManager.default.createSymbolicLink(at: linkedStore.pluginsURL, withDestinationURL: other)
        XCTAssertThrowsError(
            try linkedStore.installLocalPlugin(from: try validSource(id: "safe"))
        ) { error in
            XCTAssertEqual(error as? PluginStoreError, .unsafePluginStorage(linkedStore.pluginsURL))
        }
    }

    func testDuplicateInstallDoesNotReplaceExistingDirectory() throws {
        let workspace = try temporaryDirectory()
        let first = try validSource(id: "duplicate", name: "First")
        let second = try validSource(id: "duplicate", name: "Second")
        let store = PluginStore(workspaceURL: workspace, trashHandler: RecordingPluginTrash())

        _ = try store.installLocalPlugin(from: first)
        XCTAssertThrowsError(try store.installLocalPlugin(from: second)) { error in
            XCTAssertEqual(error as? PluginStoreError, .pluginAlreadyInstalled("duplicate"))
        }
        XCTAssertEqual(try store.listInstalledPlugins().first?.manifest.name, "First")
    }

    func testLocalInstallStateWriteFailureRollsBackPublishedDirectory() throws {
        let workspace = try temporaryDirectory()
        let source = try validSource(id: "local-state-failure")
        let store = failingStateWriteStore(workspace: workspace)

        XCTAssertThrowsError(try store.installLocalPlugin(from: source)) { error in
            XCTAssertTrue(error is InjectedStateWriteFailure)
        }

        XCTAssertEqual(try store.listInstalledPlugins(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.pluginsURL.appendingPathComponent("local-state-failure").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.projectStateURL.path))
        try assertNoTransactionEntries(in: store)
    }

    func testEnabledAndPermissionStateAreProjectScopedAndFiltered() throws {
        let firstWorkspace = try temporaryDirectory()
        let secondWorkspace = try temporaryDirectory()
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

        let first = PluginStore(workspaceURL: firstWorkspace, trashHandler: RecordingPluginTrash())
        let second = PluginStore(workspaceURL: secondWorkspace, trashHandler: RecordingPluginTrash())
        _ = try first.installLocalPlugin(from: source)
        _ = try second.installLocalPlugin(from: source)
        try first.setEnabled(false, forPluginID: "permissions")
        try first.setGrantedPermissions(
            [.documentEdit, .documentRead, .documentRead],
            forPluginID: "permissions"
        )

        let firstPlugin = try XCTUnwrap(first.listInstalledPlugins().first)
        XCTAssertFalse(firstPlugin.isEnabled)
        XCTAssertEqual(firstPlugin.grantedPermissions, [.documentRead])
        XCTAssertEqual(firstPlugin.effectivePermissions, [.documentRead])
        let secondPlugin = try XCTUnwrap(second.listInstalledPlugins().first)
        XCTAssertTrue(secondPlugin.isEnabled)
        XCTAssertEqual(secondPlugin.grantedPermissions, [])
    }

    func testUninstallUsesRecoverableTrashAndClearsProjectState() throws {
        let workspace = try temporaryDirectory()
        let trashDirectory = try temporaryDirectory()
        let trash = RecordingPluginTrash(destinationDirectory: trashDirectory)
        let store = PluginStore(workspaceURL: workspace, trashHandler: trash)
        _ = try store.installLocalPlugin(from: try validSource(id: "remove-me"))
        try store.setEnabled(false, forPluginID: "remove-me")

        try store.uninstallPlugin(id: "remove-me")

        XCTAssertEqual(try store.listInstalledPlugins(), [])
        XCTAssertEqual(trash.trashedNames.count, 1)
        XCTAssertTrue(trash.trashedNames[0].hasPrefix(".removing-"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: trashDirectory.appendingPathComponent(trash.trashedNames[0]).path
        ))
        XCTAssertNil(try store.loadProjectState().enabled["remove-me"])
    }

    func testTrashFailureRollsPluginBackAndKeepsState() throws {
        struct TrashFailure: Error {}
        let workspace = try temporaryDirectory()
        let trash = RecordingPluginTrash(error: TrashFailure())
        let store = PluginStore(workspaceURL: workspace, trashHandler: trash)
        _ = try store.installLocalPlugin(from: try validSource(id: "rollback"))
        try store.setEnabled(false, forPluginID: "rollback")
        let stateBeforeFailure = try Data(contentsOf: store.projectStateURL)

        XCTAssertThrowsError(try store.uninstallPlugin(id: "rollback"))
        XCTAssertEqual(try store.listInstalledPlugins().map(\.id), ["rollback"])
        XCTAssertFalse(try XCTUnwrap(store.listInstalledPlugins().first).isEnabled)
        XCTAssertEqual(try Data(contentsOf: store.projectStateURL), stateBeforeFailure)
        try assertNoTransactionEntries(in: store)
    }

    func testUninstallStateWriteFailureRestoresDirectoryBeforeTrash() throws {
        let workspace = try temporaryDirectory()
        let healthyStore = PluginStore(
            workspaceURL: workspace, trashHandler: RecordingPluginTrash()
        )
        _ = try healthyStore.installLocalPlugin(
            from: try validSource(id: "stateful-removal")
        )
        try healthyStore.setEnabled(false, forPluginID: "stateful-removal")
        let stateBeforeFailure = try Data(contentsOf: healthyStore.projectStateURL)
        let trash = RecordingPluginTrash()
        let failingStore = failingStateWriteStore(workspace: workspace, trashHandler: trash)

        XCTAssertThrowsError(try failingStore.uninstallPlugin(id: "stateful-removal")) { error in
            XCTAssertTrue(error is InjectedStateWriteFailure)
        }

        XCTAssertEqual(try Data(contentsOf: failingStore.projectStateURL), stateBeforeFailure)
        XCTAssertEqual(try failingStore.listInstalledPlugins().map(\.id), ["stateful-removal"])
        XCTAssertFalse(try XCTUnwrap(failingStore.listInstalledPlugins().first).isEnabled)
        XCTAssertEqual(trash.trashedNames, [])
        try assertNoTransactionEntries(in: failingStore)
    }

    func testMarketplaceSourcesAreSanitizedInsideProjectState() throws {
        let workspace = try temporaryDirectory()
        let store = PluginStore(workspaceURL: workspace, trashHandler: RecordingPluginTrash())
        try store.setMarketplaceSources([
            "http://insecure.example/index.json",
            "https://plugins.example/index.json"
        ])
        XCTAssertEqual(
            try store.loadProjectState().marketplaceSources,
            ["https://plugins.example/index.json"]
        )
    }

    func testMarketplacePackageIsReverifiedBeforeAtomicInstall() throws {
        let workspace = try temporaryDirectory()
        let store = PluginStore(workspaceURL: workspace, trashHandler: RecordingPluginTrash())
        let manifestURL = URL(string: "https://plugins.example.test/plugin.json")!
        let workerURL = URL(string: "https://plugins.example.test/worker.js")!
        let expectedWorker = Data("expected worker".utf8)
        let remoteData = try JSONSerialization.data(withJSONObject: [
            "id": "marketplace",
            "name": "Marketplace",
            "extension": [
                "worker": "worker.js",
                "workerUrl": workerURL.absoluteString,
                "workerIntegrity": SHA256Integrity.digest(of: expectedWorker).rawValue
            ]
        ])
        let remoteManifest = try PluginManifest.parse(remoteData)
        let installedData = try JSONSerialization.data(withJSONObject: [
            "id": "marketplace",
            "name": "Marketplace",
            "extension": ["worker": "worker.js", "permissions": []]
        ])
        let forged = MarketplacePluginPackage(
            manifest: remoteManifest,
            sourceManifestURL: manifestURL,
            verifiedWorkerData: Data("tampered".utf8),
            installedManifestData: installedData
        )
        XCTAssertThrowsError(try store.installMarketplacePlugin(forged)) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .workerIntegrityMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.pluginsURL.appendingPathComponent("marketplace").path
        ))

        let verified = MarketplacePluginPackage(
            manifest: remoteManifest,
            sourceManifestURL: manifestURL,
            verifiedWorkerData: expectedWorker,
            installedManifestData: installedData
        )
        let installed = try store.installMarketplacePlugin(verified)
        XCTAssertEqual(installed.workerExecutionSupport, .isolatedProcess)
        XCTAssertEqual(
            try Data(contentsOf: installed.directoryURL.appendingPathComponent("worker.js")),
            expectedWorker
        )
        let installedManifest = try Data(
            contentsOf: installed.directoryURL.appendingPathComponent("plugin.json")
        )
        XCTAssertFalse(String(decoding: installedManifest, as: UTF8.self).contains("workerUrl"))
    }

    func testMarketplaceInstallStateWriteFailureRollsBackPublishedDirectory() throws {
        let workspace = try temporaryDirectory()
        let store = failingStateWriteStore(workspace: workspace)
        let manifestData = try JSONSerialization.data(withJSONObject: [
            "id": "marketplace-state-failure",
            "name": "Marketplace Failure"
        ])
        let package = MarketplacePluginPackage(
            manifest: try PluginManifest.parse(manifestData),
            sourceManifestURL: URL(
                string: "https://plugins.example.test/marketplace-state-failure.json"
            )!,
            verifiedWorkerData: nil,
            installedManifestData: manifestData
        )

        XCTAssertThrowsError(try store.installMarketplacePlugin(package)) { error in
            XCTAssertTrue(error is InjectedStateWriteFailure)
        }

        XCTAssertEqual(try store.listInstalledPlugins(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.pluginsURL.appendingPathComponent("marketplace-state-failure").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.projectStateURL.path))
        try assertNoTransactionEntries(in: store)
    }

    private func failingStateWriteStore(
        workspace: URL,
        trashHandler: any WorkspaceTrashHandling = RecordingPluginTrash()
    ) -> PluginStore {
        PluginStore(
            workspaceURL: workspace,
            trashHandler: trashHandler,
            stateWriteFailureInjector: { throw InjectedStateWriteFailure() }
        )
    }

    private func assertNoTransactionEntries(in store: PluginStore) throws {
        let pluginNames = try FileManager.default.contentsOfDirectory(atPath: store.pluginsURL.path)
        XCTAssertFalse(pluginNames.contains {
            $0.hasPrefix(".installing-") || $0.hasPrefix(".removing-")
        })
        let workspaceNames = try FileManager.default.contentsOfDirectory(
            atPath: store.workspaceURL.path
        )
        XCTAssertFalse(workspaceNames.contains { $0.hasPrefix(".plugin-state-") })
    }

    private func validSource(id: String, name: String = "Plugin") throws -> URL {
        let source = try temporaryDirectory()
        try writeManifest(["id": id, "name": name], to: source)
        return source
    }

    private func writeManifest(_ object: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent(PluginStore.manifestFileName))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-store-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }
}

private struct InjectedStateWriteFailure: Error, Sendable {}

private final class RecordingPluginTrash: WorkspaceTrashHandling, @unchecked Sendable {
    private let lock = NSLock()
    private let destinationDirectory: URL?
    private let error: (any Error)?
    private var names: [String] = []

    init(destinationDirectory: URL? = nil, error: (any Error)? = nil) {
        self.destinationDirectory = destinationDirectory
        self.error = error
    }

    var trashedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func trashItem(at url: URL) throws {
        if let error { throw error }
        lock.lock()
        names.append(url.lastPathComponent)
        lock.unlock()
        if let destinationDirectory {
            try FileManager.default.moveItem(
                at: url,
                to: destinationDirectory.appendingPathComponent(url.lastPathComponent)
            )
        }
    }
}
