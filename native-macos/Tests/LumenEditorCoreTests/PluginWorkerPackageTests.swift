import Foundation
import XCTest
@testable import LumenEditorCore

final class PluginWorkerPackageTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testStoreLoadsBoundedWorkerAndEffectivePermissions() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        let worker = Data("self.onmessage = function () {}".utf8)
        try manifestData(id: "worker").write(
            to: source.appendingPathComponent(PluginStore.manifestFileName)
        )
        try worker.write(to: source.appendingPathComponent("worker.js"))
        let store = PluginStore(
            workspaceURL: workspace, trashHandler: WorkerPackageTrash()
        )
        _ = try store.installLocalPlugin(from: source)
        try store.setGrantedPermissions(
            [.documentRead, .documentEdit], forPluginID: "worker"
        )

        let package = try store.loadWorkerPackage(forPluginID: "worker")

        XCTAssertEqual(package.pluginID, "worker")
        XCTAssertEqual(package.pluginName, "Worker")
        XCTAssertEqual(package.source, worker)
        XCTAssertEqual(package.sourceIntegrity, .digest(of: worker))
        XCTAssertEqual(package.permissions, [.documentRead, .documentEdit])
        XCTAssertEqual(
            try store.listInstalledPlugins().first?.workerExecutionSupport,
            .isolatedProcess
        )
    }

    func testStoreRejectsWorkerSymlinkInsertedAfterInstallation() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        let external = try temporaryDirectory().appendingPathComponent("outside.js")
        try Data("safe".utf8).write(to: source.appendingPathComponent("worker.js"))
        try Data("secret".utf8).write(to: external)
        try manifestData(id: "linked").write(
            to: source.appendingPathComponent(PluginStore.manifestFileName)
        )
        let store = PluginStore(
            workspaceURL: workspace, trashHandler: WorkerPackageTrash()
        )
        let installed = try store.installLocalPlugin(from: source)
        let installedWorker = installed.directoryURL.appendingPathComponent("worker.js")
        try FileManager.default.removeItem(at: installedWorker)
        try FileManager.default.createSymbolicLink(
            at: installedWorker, withDestinationURL: external
        )

        XCTAssertThrowsError(try store.loadWorkerPackage(forPluginID: "linked"))
    }

    func testStoreRejectsWorkerManifestChangedAfterListing() throws {
        let workspace = try temporaryDirectory()
        let source = try temporaryDirectory()
        try Data("safe".utf8).write(to: source.appendingPathComponent("worker.js"))
        try manifestData(id: "changed").write(
            to: source.appendingPathComponent(PluginStore.manifestFileName)
        )
        let store = PluginStore(
            workspaceURL: workspace, trashHandler: WorkerPackageTrash()
        )
        let installed = try store.installLocalPlugin(from: source)
        let snapshot = try XCTUnwrap(store.listInstalledPlugins().first)
        try manifestData(id: "changed", name: "Changed Name").write(
            to: installed.directoryURL.appendingPathComponent(PluginStore.manifestFileName)
        )

        XCTAssertThrowsError(try store.loadWorkerPackage(for: snapshot)) { error in
            XCTAssertEqual(error as? PluginWorkerPackageError, .manifestChanged)
        }
    }

    private func manifestData(id: String, name: String = "Worker") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id, "name": name,
            "extension": [
                "worker": "worker.js",
                "permissions": ["document-read", "document-edit"]
            ]
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PluginWorkerPackageTests-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false
        )
        temporaryDirectories.append(url)
        return url
    }
}

private struct WorkerPackageTrash: WorkspaceTrashHandling, Sendable {
    func trashItem(at url: URL) throws {}
}
