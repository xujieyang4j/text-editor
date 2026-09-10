import Darwin
import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class WorkspaceControllerMutationTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    @MainActor
    func testRootLimitFailureKeepsTypedRuntimeLocalizablePayload() async throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        let controller = WorkspaceController(
            service: WorkspaceService(limits: .init(maximumRoots: 1)),
            openFile: { _ in }
        )

        XCTAssertTrue(await controller.addRoot(first))
        XCTAssertFalse(await controller.addRoot(second))

        let issue = try XCTUnwrap(controller.issue)
        XCTAssertEqual(issue.title, "Could Not Add Folder")
        XCTAssertEqual(
            issue.content,
            .workspaceError(.tooManyRoots(maximum: 1), context: second.lastPathComponent)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceIssue(issue.content),
            "\(second.lastPathComponent): A workspace supports at most 1 roots."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(issue.content),
            "\(second.lastPathComponent)：一个工作区最多支持 1 个根目录。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedWorkspaceIssueTitle(issue.titleContent),
            "Could Not Add Folder"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssueTitle(issue.titleContent),
            "无法添加文件夹"
        )
    }

    @MainActor
    func testDirectoryFailurePayloadSeparatesWorkspaceAndExternalErrors() {
        let typed = WorkspaceController.presentationMessage(
            for: WorkspaceServiceError.tooManyRoots(maximum: 3)
        )
        XCTAssertEqual(
            typed,
            .workspaceError(.tooManyRoots(maximum: 3), context: nil)
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(typed),
            "一个工作区最多支持 3 个根目录。"
        )

        struct ExternalFailure: LocalizedError {
            let errorDescription: String? = "A workspace root must be an existing directory."
        }
        let external = WorkspaceController.presentationMessage(for: ExternalFailure())
        XCTAssertEqual(
            external,
            .verbatim("A workspace root must be an existing directory.")
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(external),
            "A workspace root must be an existing directory."
        )
    }

    @MainActor
    func testRevealPreparesSidebarBeforeMutatingPresentationState() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("main.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in }
        )
        XCTAssertTrue(await controller.addRoot(root))
        controller.toggleSidebar()
        XCTAssertFalse(controller.isSidebarVisible)
        var preparations = 0

        XCTAssertFalse(await controller.revealActiveFile(file) {
            preparations += 1
            return false
        })
        XCTAssertEqual(preparations, 1)
        XCTAssertFalse(controller.isSidebarVisible)
        XCTAssertNil(controller.selectedURL)

        XCTAssertTrue(await controller.revealActiveFile(file) {
            preparations += 1
            return true
        })
        XCTAssertEqual(preparations, 2)
        XCTAssertTrue(controller.isSidebarVisible)
        XCTAssertEqual(controller.selectedURL?.standardizedFileURL, file.standardizedFileURL)
    }

    @MainActor
    func testDirectoryStateKeepsTypedWorkspaceServiceFailure() async throws {
        let root = try temporaryDirectory()
        let service = WorkspaceService(beforeOpeningFileDescriptor: { _ in
            throw WorkspaceServiceError.tooManyDirectFileAuthorizations(maximum: 4)
        })
        let controller = WorkspaceController(service: service, openFile: { _ in })
        XCTAssertTrue(await controller.addRoot(root))

        controller.loadChildren(of: root)
        await waitForDirectory(controller, url: root)

        XCTAssertEqual(controller.state(for: root).loadState, .failed)
        XCTAssertEqual(
            controller.state(for: root).errorContent,
            .workspaceError(
                .tooManyDirectFileAuthorizations(maximum: 4), context: nil
            )
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedWorkspaceIssue(
                try XCTUnwrap(controller.state(for: root).errorContent)
            ),
            "最多可为 4 个文件授予直接访问权限。"
        )
    }

    @MainActor
    func testCommittedProjectExclusionsFilterFileTreeEnumeration() async throws {
        let root = try temporaryDirectory()
        let visible = root.appendingPathComponent("visible.txt")
        let generated = root.appendingPathComponent("Generated", isDirectory: true)
        try Data("visible".utf8).write(to: visible)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: generated.appendingPathComponent("hidden.txt"))
        let controller = WorkspaceController(service: WorkspaceService(), openFile: { _ in })
        XCTAssertTrue(await controller.addRoot(root))

        controller.setProjectExclusions(["Generated/**"])
        controller.loadChildren(of: root)
        await waitForDirectory(controller, url: root)

        XCTAssertEqual(controller.state(for: root).entries.map(\.name), ["visible.txt"])
    }

    @MainActor
    func testProjectExclusionSnapshotAdvancesOnlyForCommittedChanges() {
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in }
        )

        XCTAssertEqual(
            controller.projectExclusionSnapshot,
            WorkspaceProjectExclusionSnapshot(exclusions: [], generation: 0)
        )

        controller.setProjectExclusions(["  Generated/**  ", "", "   "])
        let committed = controller.projectExclusionSnapshot

        XCTAssertEqual(committed.exclusions, ["Generated/**"])
        XCTAssertEqual(committed.generation, 1)
        XCTAssertEqual(controller.projectExclusions, committed.exclusions)
        XCTAssertEqual(controller.projectExclusionGeneration, committed.generation)
        XCTAssertEqual(controller.projectExclusionPolicy, committed.policy)

        controller.setProjectExclusions(["Generated/**"])
        XCTAssertEqual(controller.projectExclusionSnapshot, committed)
    }

    @MainActor
    func testExclusionChangeRejectsInFlightDirectoryCompletion() async throws {
        let root = try temporaryDirectory()
        try Data("visible".utf8).write(
            to: root.appendingPathComponent("visible.txt")
        )
        try Data("generated".utf8).write(
            to: root.appendingPathComponent("generated.tmp")
        )
        let gate = ControllerDirectoryReadGate()
        defer { gate.releaseAll() }
        let service = WorkspaceService(beforeOpeningFileDescriptor: { _ in
            gate.intercept()
        })
        let controller = WorkspaceController(service: service, openFile: { _ in })
        XCTAssertTrue(await controller.addRoot(root))

        controller.loadChildren(of: root)
        await waitForDirectoryRead(gate, count: 1)
        controller.setProjectExclusions(["*.tmp"])
        gate.releaseFirst()
        await waitForDirectoryRead(gate, count: 2)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(controller.state(for: root).loadState, .loading)
        XCTAssertTrue(controller.state(for: root).entries.isEmpty)

        gate.releaseSecond()
        await waitForDirectory(controller, url: root)
        XCTAssertEqual(controller.state(for: root).entries.map(\.name), ["visible.txt"])
    }

    @MainActor
    func testCreateRenameMoveAndTrashCoordinateCallbacksAndTreeState() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let trashDirectory = container.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: false
        )
        let trash = ControllerTestTrash(destinationDirectory: trashDirectory)
        let service = WorkspaceService(trashHandler: trash)
        var proposed: [WorkspaceMutationEvent] = []
        var committed: [WorkspaceMutationEvent] = []
        var opened: [URL] = []
        let controller = WorkspaceController(
            service: service,
            openFile: { opened.append($0.url) },
            authorizeMutation: { proposed.append($0) },
            didMutate: { committed.append($0) }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let createdFolder = await controller.createDirectory(in: root, named: "Sources")
        let folder = try XCTUnwrap(createdFolder)
        let createdFile = await controller.createFile(in: root, named: "draft.txt")
        let created = try XCTUnwrap(createdFile)
        XCTAssertEqual(opened, [created.url])
        XCTAssertEqual(controller.selectedURL, created.url)
        XCTAssertEqual(
            Set(controller.state(for: root).entries.map(\.name)),
            ["Sources", "draft.txt"]
        )

        let renamedURL = await controller.rename(created.url, toName: "renamed.txt")
        let renamed = try XCTUnwrap(renamedURL)
        XCTAssertEqual(controller.selectedURL, renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))

        let movedURL = await controller.move(renamed, toDirectory: folder.url)
        let moved = try XCTUnwrap(movedURL)
        XCTAssertEqual(moved, folder.url.appendingPathComponent("renamed.txt"))
        XCTAssertEqual(controller.selectedURL, moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))

        let didTrash = await controller.moveToTrash(moved)
        XCTAssertTrue(didTrash)
        XCTAssertNil(controller.selectedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(trash.trashedURLs, [moved])

        let expected: [WorkspaceMutationEvent] = [
            .created(url: folder.url, isDirectory: true),
            .created(url: created.url, isDirectory: false),
            .renamed(from: created.url, to: renamed),
            .moved(from: renamed, to: moved),
            .trashed(moved)
        ]
        XCTAssertEqual(proposed, expected)
        XCTAssertEqual(committed, expected)
        XCTAssertFalse(controller.isMutatingItems)
    }

    @MainActor
    func testAuthorizationCanRejectTrashBeforeDiskMutation() async throws {
        let root = try temporaryDirectory()
        let protected = root.appendingPathComponent("dirty.txt")
        try Data("draft".utf8).write(to: protected)
        var committed: [WorkspaceMutationEvent] = []
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openDocumentURLs: { [protected] },
            openFile: { _ in },
            authorizeMutation: { event in
                guard case .trashed = event else { return }
                throw WorkspaceMutationAuthorizationError.rejected(
                    "Save or close the dirty document before moving it to the Trash."
                )
            },
            didMutate: { committed.append($0) }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let didTrash = await controller.moveToTrash(protected)
        XCTAssertFalse(didTrash)

        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(controller.issue?.title, "Could Not Move Item to Trash")
        XCTAssertTrue(controller.issue?.message.contains("dirty document") == true)
        XCTAssertFalse(controller.isMutatingItems)
    }

    @MainActor
    func testDefaultPreflightRefusesPathChangesAffectingOpenDocuments() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let openFile = folder.appendingPathComponent("dirty.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("draft".utf8).write(to: openFile)
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openDocumentURLs: { [openFile] },
            openFile: { _ in }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let renamed = await controller.rename(folder, toName: "Renamed")
        let didTrash = await controller.moveToTrash(folder)

        XCTAssertNil(renamed)
        XCTAssertFalse(didTrash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: openFile.path))
        XCTAssertTrue(controller.issue?.message.contains("Close affected open documents") == true)
    }

    @MainActor
    func testFailedRenameDoesNotPublishCommittedMutation() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let collision = root.appendingPathComponent("collision.txt")
        try Data("source".utf8).write(to: source)
        try Data("collision".utf8).write(to: collision)
        var proposed: [WorkspaceMutationEvent] = []
        var committed: [WorkspaceMutationEvent] = []
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openFile: { _ in },
            authorizeMutation: { proposed.append($0) },
            didMutate: { committed.append($0) }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let renamed = await controller.rename(source, toName: collision.lastPathComponent)
        XCTAssertNil(renamed)

        XCTAssertEqual(proposed, [.renamed(from: source, to: collision)])
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(try String(contentsOf: source), "source")
        XCTAssertEqual(try String(contentsOf: collision), "collision")
        XCTAssertEqual(controller.issue?.title, "Could Not Rename Item")
    }

    @MainActor
    func testInvalidNameIsRejectedBeforePreflightReceivesNormalizedPath() async throws {
        let root = try temporaryDirectory()
        var proposed: [WorkspaceMutationEvent] = []
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openFile: { _ in },
            authorizeMutation: { proposed.append($0) }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let created = await controller.createFile(in: root, named: "../escape.txt")

        XCTAssertNil(created)
        XCTAssertTrue(proposed.isEmpty)
        XCTAssertEqual(controller.issue?.title, "Could Not Create File")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent()
                    .appendingPathComponent("escape.txt").path
            )
        )
    }

    @MainActor
    func testMutationCallbacksStraddleDiskChangeBeforeTreePublication() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("renamed.txt")
        try Data("source".utf8).write(to: source)
        let service = WorkspaceService()
        let probe = WorkspaceMutationTimingProbe(source: source, target: target)
        let controller = WorkspaceController(
            service: service,
            openFile: { _ in },
            authorizeMutation: { event in probe.authorize(event) },
            didMutate: { event in probe.commit(event) }
        )
        probe.controller = controller
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)
        controller.loadChildren(of: root)
        await waitForDirectory(controller, url: root)

        let renamed = await controller.rename(source, toName: target.lastPathComponent)

        XCTAssertEqual(renamed, target)
        XCTAssertTrue(probe.preflightSawOriginal)
        XCTAssertTrue(probe.postflightSawCommittedDiskAndOldTree)
        XCTAssertEqual(controller.state(for: root).entries.map(\.url), [target])
    }

    @MainActor
    func testPostflightFailureIsVisibleAfterDiskAndTreeCommit() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("renamed.txt")
        try Data("source".utf8).write(to: source)
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openFile: { _ in },
            didMutate: { _ in
                throw WorkspaceMutationAuthorizationError.rejected(
                    "Open document paths could not be updated."
                )
            }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let renamed = await controller.rename(source, toName: target.lastPathComponent)

        XCTAssertEqual(renamed, target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(
            controller.issue?.title,
            "Item Changed but Open Documents Could Not Update"
        )
        XCTAssertTrue(controller.issue?.message.contains("could not be updated") == true)
        XCTAssertEqual(controller.state(for: root).entries.map(\.url), [target])
    }

    @MainActor
    func testProgrammaticMoveCannotForgeAnExternalDirectoryGrant() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        var proposed: [WorkspaceMutationEvent] = []
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openFile: { _ in },
            authorizeMutation: { proposed.append($0) }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let moved = await controller.move(source, toDirectory: outside)

        XCTAssertNil(moved)
        XCTAssertTrue(proposed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent(source.lastPathComponent).path
            )
        )
        XCTAssertEqual(controller.issue?.title, "Could Not Move Item")
    }

    @MainActor
    func testTrustedPickerMovesDirectoryOutsideWorkspaceAndRewritesDescendantState() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let source = root.appendingPathComponent("Folder", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        let child = nested.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: child)
        let sessionStore = SessionStore(
            sessionURL: container.appendingPathComponent("session.json")
        )
        let model = AppModel(sessionStore: sessionStore, createInitialDocument: false)
        let opened = try TextFileCodec.decode(Data(contentsOf: child), sourceURL: child)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        let navigation = NavigationController(
            snapshot: { NavigationAppSnapshot(
                documents: [], panes: [NavigationPaneSnapshot(
                    groupID: 0, activeDocumentID: nil, cursorUTF16Offset: 0
                )], activeGroupID: 0
            ) },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )
        navigation.recordSuccessfulJump(
            source: NavigationLocation(
                documentID: document.sessionDocumentID, path: child.path,
                groupID: 0, line: 1, column: 1
            ),
            target: NavigationLocation(
                documentID: "other", path: root.appendingPathComponent("other.txt").path,
                groupID: 0, line: 1, column: 1
            )
        )
        let mutationRelay = WorkspaceMutationRelay(model: model)
        mutationRelay.navigationController = navigation
        var proposed: [WorkspaceMutationEvent] = []
        var committed: [WorkspaceMutationEvent] = []
        var pickerCopy: WorkspaceFolderPanelCopy?
        var pickerInitialDirectory: URL?
        let scopedAccess = controllerMutationScopedAccess(in: container)
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openDocumentURLs: { model.documents.compactMap(\.fileURL) },
            openFile: { _ in },
            authorizeMutation: { event in
                XCTAssertTrue(model.canApplyWorkspaceMutation(event))
                proposed.append(event)
            },
            didMutate: { event in
                committed.append(event)
                try mutationRelay.apply(event)
            },
            securityScopedAccess: scopedAccess,
            chooseFolder: { copy, initialDirectory in
                pickerCopy = copy
                pickerInitialDirectory = initialDirectory
                return outside
            }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)
        controller.expandedDirectories = [source, nested]
        controller.selectFile(child)

        let moved = await controller.move(source, locale: .enUS)
        let expectedFolder = outside.appendingPathComponent("Folder", isDirectory: true)
        let expectedChild = expectedFolder.appendingPathComponent("Nested/child.txt")
        let event = WorkspaceMutationEvent.moved(from: source, to: expectedFolder)

        XCTAssertEqual(moved?.path, expectedFolder.path)
        XCTAssertEqual(proposed, [event])
        XCTAssertEqual(committed, [event])
        XCTAssertEqual(pickerInitialDirectory?.path, root.path)
        XCTAssertEqual(pickerCopy?.prompt, "Move")
        XCTAssertNil(controller.selectedURL)
        XCTAssertTrue(controller.expandedDirectories.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: expectedChild, encoding: .utf8), "child")
        XCTAssertEqual(document.fileURL?.path, expectedChild.path)
        XCTAssertEqual(navigation.backEntries.first?.path, expectedChild.path)
        XCTAssertEqual(
            sessionStore.loadWindowSession().documents.first?.path,
            expectedChild.path
        )
    }

    @MainActor
    func testTrustedPickerMovesFileOutsideWorkspace() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        var committed: [WorkspaceMutationEvent] = []
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            didMutate: { committed.append($0) },
            securityScopedAccess: controllerMutationScopedAccess(in: container),
            chooseFolder: { _, _ in outside }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let moved = await controller.move(source, locale: .enUS)
        let target = outside.appendingPathComponent("source.txt")

        XCTAssertEqual(moved, target)
        XCTAssertEqual(committed, [.moved(from: source, to: target)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "source")
    }

    @MainActor
    func testMovePreflightRebasesExactSymlinkBookmarkBeforeDiskMutation() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let source = root.appendingPathComponent("Folder", isDirectory: true)
        let secret = container.appendingPathComponent("secret.txt")
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let store = SecurityScopedBookmarkStore(
            directoryURL: container.appendingPathComponent("bookmarks", isDirectory: true)
        )
        let provider = ControllerMutationBookmarkProvider()
        let scopedAccess = SecurityScopedAccessController(
            store: store, provider: provider, requiresSecurityScope: { false }
        )
        let sessionStore = SessionStore(
            sessionURL: container.appendingPathComponent("session.json")
        )
        let model = AppModel(
            sessionStore: sessionStore,
            createInitialDocument: false
        )
        let opened = try TextFileCodec.decode(Data(contentsOf: link), sourceURL: link)
        let document = try XCTUnwrap(model.open(openedFile: opened))
        let service = WorkspaceService()
        let controller = WorkspaceController(
            service: service,
            openDocumentURLs: { model.documents.compactMap(\.fileURL) },
            openFile: { _ in },
            authorizeMutation: { event in
                XCTAssertTrue(model.canApplyWorkspaceMutation(event))
            },
            prepareMutation: { event in try model.prepareWorkspaceMutation(event) },
            didMutate: { try model.applyWorkspaceMutation($0) },
            securityScopedAccess: scopedAccess,
            chooseFolder: { _, _ in outside }
        )
        _ = EditorActionController(
            model: model, workspace: controller, securityScopedAccess: scopedAccess
        )
        XCTAssertTrue(await controller.addRoot(root, accessSource: .userSelected))
        model.retainSecurityScopedAccess(
            try scopedAccess.accessUserSelectedURL(link, kind: .file),
            for: document
        )
        try await service.authorizeFile(link)

        let moveResult = await controller.move(source, locale: .enUS)
        let moved = try XCTUnwrap(moveResult)
        let movedLink = moved.appendingPathComponent("link.txt")

        XCTAssertEqual(document.fileURL?.path, movedLink.path)
        XCTAssertEqual(store.match(
            for: movedLink, kind: .file, allowingDirectoryAncestor: true
        )?.record.kind, .file)
        XCTAssertFalse(provider.stoppedPaths.contains(secret.path))
        let reopened = try await service.openFile(movedLink)
        XCTAssertEqual(reopened.content, "secret")
        document.text = "updated"
        XCTAssertTrue(await model.save(document))
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "updated")
        model.requestClose(document)
        XCTAssertTrue(provider.stoppedPaths.contains(secret.path))
    }

    @MainActor
    func testExactBookmarkCollisionRejectsMoveBeforeDiskMutation() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let source = root.appendingPathComponent("Folder", isDirectory: true)
        let occupied = outside.appendingPathComponent("Folder", isDirectory: true)
        let sourceTarget = container.appendingPathComponent("source-target.txt")
        let occupiedTarget = container.appendingPathComponent("occupied-target.txt")
        let sourceLink = source.appendingPathComponent("link.txt")
        let occupiedLink = occupied.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceTarget)
        try Data("occupied".utf8).write(to: occupiedTarget)
        try FileManager.default.createSymbolicLink(
            at: sourceLink, withDestinationURL: sourceTarget
        )
        try FileManager.default.createSymbolicLink(
            at: occupiedLink, withDestinationURL: occupiedTarget
        )
        let store = SecurityScopedBookmarkStore(
            directoryURL: container.appendingPathComponent("bookmarks", isDirectory: true)
        )
        let scopedAccess = SecurityScopedAccessController(
            store: store, provider: ControllerMutationBookmarkProvider(),
            requiresSecurityScope: { false }
        )
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: container.appendingPathComponent("session.json")
            ),
            createInitialDocument: false
        )
        let document = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data(contentsOf: sourceLink), sourceURL: sourceLink
        )))
        model.retainSecurityScopedAccess(
            try scopedAccess.accessUserSelectedURL(sourceLink, kind: .file),
            for: document
        )
        try scopedAccess.accessUserSelectedURL(occupiedLink, kind: .file).invalidate()
        let service = WorkspaceService()
        try await service.authorizeFile(sourceLink)
        let controller = WorkspaceController(
            service: service,
            openDocumentURLs: { model.documents.compactMap(\.fileURL) },
            openFile: { _ in },
            prepareMutation: { event in try model.prepareWorkspaceMutation(event) },
            didMutate: { try model.applyWorkspaceMutation($0) },
            securityScopedAccess: controllerMutationScopedAccess(
                in: container.appendingPathComponent("destination-access")
            ),
            chooseFolder: { _, _ in outside }
        )
        _ = EditorActionController(
            model: model, workspace: controller, securityScopedAccess: scopedAccess
        )
        XCTAssertTrue(await controller.addRoot(root, accessSource: .userSelected))

        XCTAssertNil(await controller.move(source, locale: .enUS))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path))
        XCTAssertEqual(store.match(
            for: sourceLink, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data(sourceTarget.path.utf8))
        XCTAssertEqual(store.match(
            for: occupiedLink, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data(occupiedTarget.path.utf8))
    }

    @MainActor
    func testBookmarkPersistenceFailureRejectsMoveBeforeDiskMutation() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let source = root.appendingPathComponent("Folder", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let link = source.appendingPathComponent("link.txt")
        let secret = container.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let bookmarkDirectory = container.appendingPathComponent(
            "bookmarks", isDirectory: true
        )
        let bootstrap = SecurityScopedBookmarkStore(directoryURL: bookmarkDirectory)
        _ = try bootstrap.record(Data(secret.path.utf8), for: link, kind: .file)
        let initialBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: bootstrap.fileURL.path)[.size]
                as? NSNumber
        ).intValue
        let boundedStore = SecurityScopedBookmarkStore(
            directoryURL: bookmarkDirectory,
            limits: .init(
                maximumRecords: 4, maximumBookmarkBytes: 4_096,
                maximumTotalBookmarkBytes: 16_384,
                maximumSerializedBytes: initialBytes, maximumAliasesPerRecord: 4
            )
        )
        let scopedAccess = SecurityScopedAccessController(
            store: boundedStore, provider: ControllerMutationBookmarkProvider(),
            requiresSecurityScope: { false }
        )
        let model = AppModel(
            sessionStore: SessionStore(sessionURL: container.appendingPathComponent("session.json")),
            createInitialDocument: false
        )
        _ = model.open(openedFile: try TextFileCodec.decode(
            Data(contentsOf: link), sourceURL: link
        ))
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let controller = WorkspaceController(
            service: service,
            openDocumentURLs: { model.documents.compactMap(\.fileURL) },
            openFile: { _ in },
            prepareMutation: { event in try model.prepareWorkspaceMutation(event) },
            didMutate: { try model.applyWorkspaceMutation($0) },
            securityScopedAccess: controllerMutationScopedAccess(
                in: container.appendingPathComponent("destination-access")
            ),
            chooseFolder: { _, _ in outside }
        )
        _ = EditorActionController(
            model: model, workspace: controller, securityScopedAccess: scopedAccess
        )

        let moveResult = await controller.move(source, locale: .enUS)

        XCTAssertNil(moveResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("Folder").path
        ))
        XCTAssertEqual(boundedStore.match(
            for: link, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data(secret.path.utf8))
    }

    @MainActor
    func testDestinationCollisionAbortsPreparedBookmarkRebase() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let source = root.appendingPathComponent("Folder", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let collision = outside.appendingPathComponent("Folder", isDirectory: true)
        let secret = container.appendingPathComponent("secret.txt")
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let store = SecurityScopedBookmarkStore(
            directoryURL: container.appendingPathComponent("bookmarks", isDirectory: true)
        )
        let scopedAccess = SecurityScopedAccessController(
            store: store, provider: ControllerMutationBookmarkProvider(),
            requiresSecurityScope: { false }
        )
        let model = AppModel(
            sessionStore: SessionStore(sessionURL: container.appendingPathComponent("session.json")),
            createInitialDocument: false
        )
        let document = try XCTUnwrap(model.open(openedFile: try TextFileCodec.decode(
            Data(contentsOf: link), sourceURL: link
        )))
        model.retainSecurityScopedAccess(
            try scopedAccess.accessUserSelectedURL(link, kind: .file),
            for: document
        )
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        try await service.authorizeFile(link)
        let controller = WorkspaceController(
            service: service,
            openDocumentURLs: { model.documents.compactMap(\.fileURL) },
            openFile: { _ in }, authorizeMutation: { _ in },
            prepareMutation: { try model.prepareWorkspaceMutation($0) },
            didMutate: { try model.applyWorkspaceMutation($0) },
            securityScopedAccess: controllerMutationScopedAccess(
                in: container.appendingPathComponent("destination-access")
            ),
            chooseFolder: { _, _ in outside }
        )
        _ = EditorActionController(
            model: model, workspace: controller, securityScopedAccess: scopedAccess
        )

        XCTAssertNil(await controller.move(source, locale: .enUS))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(store.match(
            for: link, kind: .file, allowingDirectoryAncestor: false
        )?.record.bookmarkData, Data(secret.path.utf8))
        XCTAssertNil(store.match(
            for: collision.appendingPathComponent("link.txt"),
            kind: .file, allowingDirectoryAncestor: false
        ))
    }

    @MainActor
    func testRollbackFailureAtCommittedTargetStillPublishesMove() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("renamed.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("value".utf8).write(to: source)
        let service = WorkspaceService(
            afterMoveBeforeValidation: { _ in throw CocoaError(.fileReadUnknown) },
            rollbackMoveFailure: { _, _, _, _ in EIO }
        )
        var committed: [WorkspaceMutationEvent] = []
        let controller = WorkspaceController(
            service: service, openFile: { _ in },
            didMutate: { committed.append($0) }
        )
        XCTAssertTrue(await controller.addRoot(root))

        let result = await controller.rename(source, toName: target.lastPathComponent)

        XCTAssertEqual(result, target)
        XCTAssertEqual(committed, [.renamed(from: source, to: target)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(controller.issue?.title, "Item Moved but Recovery Failed")
    }

    @MainActor
    func testIndeterminateRollbackRefreshesWithoutPublishingMove() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("target.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("value".utf8).write(to: source)
        let service = WorkspaceService(
            afterMoveBeforeValidation: { _ in throw CocoaError(.fileReadUnknown) },
            rollbackMoveFailure: { _, _, _, _ in EIO },
            rollbackIdentityObservationFailure: { url in
                url.path == source.path ? EACCES : nil
            }
        )
        var committed: [WorkspaceMutationEvent] = []
        let controller = WorkspaceController(
            service: service, openFile: { _ in },
            didMutate: { committed.append($0) }
        )
        XCTAssertTrue(await controller.addRoot(root))
        controller.loadChildren(of: root)
        await waitForDirectory(controller, url: root)

        let result = await controller.rename(source, toName: target.lastPathComponent)

        XCTAssertNil(result)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(controller.state(for: root).entries.map(\.url), [target])
        XCTAssertEqual(controller.issue?.title, "Could Not Rename Item")
        XCTAssertTrue(controller.issue?.message.contains("uncertain") == true)
    }

    @MainActor
    func testLeaseRefreshFailureRelocatesAllDocumentsAndNavigationTogether() throws {
        let container = try temporaryDirectory()
        let source = container.appendingPathComponent("Folder", isDirectory: true)
        let target = container.appendingPathComponent("Moved", isDirectory: true)
        let firstURL = source.appendingPathComponent("first.txt")
        let secondURL = source.appendingPathComponent("second.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let sessionStore = SessionStore(
            sessionURL: container.appendingPathComponent("lease-failure-session.json")
        )
        let model = AppModel(
            sessionStore: sessionStore, createInitialDocument: false
        )
        let first = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data(contentsOf: firstURL), sourceURL: firstURL
        )))
        let second = try XCTUnwrap(model.open(openedFile: TextFileCodec.decode(
            Data(contentsOf: secondURL), sourceURL: secondURL
        )))
        var acquired = 0
        let released = WorkspaceMutationLockedCounter()
        model.securityScopedFileAccessDidMove = { _, destination in
            acquired += 1
            if acquired == 2 { throw CocoaError(.fileReadNoPermission) }
            return SecurityScopedResourceLease(url: destination) { released.increment() }
        }
        let navigation = NavigationController(
            snapshot: { NavigationAppSnapshot(
                documents: [], panes: [NavigationPaneSnapshot(
                    groupID: 0, activeDocumentID: nil, cursorUTF16Offset: 0
                )], activeGroupID: 0
            ) },
            selectDestination: { _ in nil }, openURL: { _ in nil }
        )
        navigation.recordSuccessfulJump(
            source: .init(
                documentID: first.sessionDocumentID, path: firstURL.path,
                groupID: 0, line: 1, column: 1
            ),
            target: .init(
                documentID: "other", path: "/tmp/other",
                groupID: 0, line: 1, column: 1
            )
        )
        let relay = WorkspaceMutationRelay(model: model)
        relay.navigationController = navigation

        XCTAssertThrowsError(try relay.apply(.moved(from: source, to: target)))

        XCTAssertEqual(first.fileURL, target.appendingPathComponent("first.txt"))
        XCTAssertEqual(second.fileURL, target.appendingPathComponent("second.txt"))
        XCTAssertEqual(
            navigation.backEntries.first?.path,
            target.appendingPathComponent("first.txt").path
        )
        XCTAssertEqual(
            Set(sessionStore.loadWindowSession().documents.compactMap(\.path)),
            Set([
                target.appendingPathComponent("first.txt").path,
                target.appendingPathComponent("second.txt").path
            ])
        )
        XCTAssertEqual(released.value, 1)
    }

    @MainActor
    func testProductionMutationWiringRewritesNavigationForRenameAndMove() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let source = root.appendingPathComponent("Folder", isDirectory: true)
        let child = source.appendingPathComponent("child.txt")
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: child)
        let metadataDirectory = container.appendingPathComponent(
            "metadata", isDirectory: true
        )
        let recentItems = RecentItemsStore(directoryURL: metadataDirectory)
        let coordinator = WindowSessionCoordinator(recentItemsStore: recentItems)
        let session = try coordinator.composition(for: .legacy)
        defer { try? session.close() }
        let settings = SettingsController(store: SettingsStore(
            settingsURL: metadataDirectory.appendingPathComponent("settings.json")
        ))
        let composition = EditorWindowComposition(session: session, settings: settings)
        defer {
            composition.workspace.shutdown()
            composition.model.releaseAllSecurityScopedAccess()
        }
        let didAddRoot = await composition.workspace.addRoot(root)
        XCTAssertTrue(didAddRoot)
        let opened = try TextFileCodec.decode(Data(contentsOf: child), sourceURL: child)
        let document = try XCTUnwrap(composition.model.open(openedFile: opened))
        composition.navigationController.recordSuccessfulJump(
            source: NavigationLocation(
                documentID: document.sessionDocumentID, path: child.path,
                groupID: 0, line: 1, column: 1
            ),
            target: NavigationLocation(
                documentID: "unrelated", path: root.appendingPathComponent("other.txt").path,
                groupID: 0, line: 1, column: 1
            )
        )

        let renameResult = await composition.workspace.rename(
            source, toName: "Renamed"
        )
        let renamed = try XCTUnwrap(renameResult)
        let renamedChild = renamed.appendingPathComponent("child.txt")
        XCTAssertEqual(composition.model.document(forSessionID: document.sessionDocumentID)?.fileURL, renamedChild)
        XCTAssertEqual(composition.navigationController.backEntries.first?.path, renamedChild.path)

        let moveResult = await composition.workspace.move(
            renamed, toDirectory: destination
        )
        let moved = try XCTUnwrap(moveResult)
        let movedChild = moved.appendingPathComponent("child.txt")
        XCTAssertEqual(composition.model.document(forSessionID: document.sessionDocumentID)?.fileURL, movedChild)
        XCTAssertEqual(composition.navigationController.backEntries.first?.path, movedChild.path)
        XCTAssertEqual(
            session.sessionStore.loadWindowSession().documents.first?.path,
            movedChild.path
        )
    }

    @MainActor
    func testWorkspaceMutationRelayRewritesNavigationPrefixesForRenameAndMove() throws {
        let container = try temporaryDirectory()
        let store = SessionStore(
            sessionURL: container.appendingPathComponent("session.json")
        )
        let model = AppModel(sessionStore: store, createInitialDocument: false)
        let controller = NavigationController(
            snapshot: { NavigationAppSnapshot(
                documents: [], panes: [NavigationPaneSnapshot(
                    groupID: 0, activeDocumentID: nil, cursorUTF16Offset: 0
                )], activeGroupID: 0
            ) },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )
        let source = URL(fileURLWithPath: "/workspace/Folder", isDirectory: true)
        let renamed = URL(fileURLWithPath: "/workspace/Renamed", isDirectory: true)
        let moved = URL(fileURLWithPath: "/workspace/Destination/Renamed", isDirectory: true)
        controller.recordSuccessfulJump(
            source: NavigationLocation(
                documentID: "child", path: source.appendingPathComponent("Nested/child.txt").path,
                groupID: 0, line: 1, column: 1
            ),
            target: NavigationLocation(
                documentID: "other", path: "/workspace/other.txt",
                groupID: 0, line: 1, column: 1
            )
        )
        let relay = WorkspaceMutationRelay(model: model)
        relay.navigationController = controller

        try relay.apply(.renamed(from: source, to: renamed))
        XCTAssertEqual(
            controller.backEntries.first?.path,
            renamed.appendingPathComponent("Nested/child.txt").path
        )

        try relay.apply(.moved(from: renamed, to: moved))
        XCTAssertEqual(
            controller.backEntries.first?.path,
            moved.appendingPathComponent("Nested/child.txt").path
        )
    }

    @MainActor
    func testDirectoryRenameRewritesExpandedDescendantAndSelection() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        let file = nested.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("value".utf8).write(to: file)
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openFile: { _ in }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)
        controller.expandedDirectories = [folder, nested]
        controller.selectFile(file)

        let renamed = await controller.rename(folder, toName: "Renamed")
        let expectedFolder = root.appendingPathComponent("Renamed", isDirectory: true)
        let expectedNested = expectedFolder.appendingPathComponent("Nested", isDirectory: true)
        let expectedFile = expectedNested.appendingPathComponent("file.txt")

        XCTAssertEqual(renamed?.path, expectedFolder.path)
        XCTAssertEqual(controller.selectedURL?.path, expectedFile.path)
        XCTAssertEqual(
            Set(controller.expandedDirectories.map(\.path)),
            Set([expectedFolder.path, expectedNested.path])
        )
    }

    @MainActor
    func testCopyAndFinderRevealValidateCapabilitiesAndUseRelativePath() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("project", isDirectory: true)
        let child = root.appendingPathComponent("Sources/File.swift")
        let outside = container.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(
            at: child.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("inside".utf8).write(to: child)
        try Data("outside".utf8).write(to: outside)
        var clipboard: [String] = []
        var revealed: [URL] = []
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openFile: { _ in },
            revealInFinder: { revealed.append($0) },
            writeClipboard: { value in
                clipboard.append(value)
                return true
            }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        let copiedAbsolute = await controller.copyPath(child)
        let copiedRelative = await controller.copyPath(
            child,
            relativeToWorkspace: true
        )
        let didRevealChild = await controller.revealInFinder(child)
        XCTAssertTrue(copiedAbsolute)
        XCTAssertTrue(copiedRelative)
        XCTAssertTrue(didRevealChild)
        XCTAssertEqual(clipboard, [child.path, "Sources/File.swift"])
        XCTAssertEqual(revealed, [child])

        let copiedOutside = await controller.copyPath(outside)
        let copiedOutsideRelative = await controller.copyPath(
            outside, relativeToWorkspace: true
        )
        let revealedOutside = await controller.revealInFinder(outside)
        XCTAssertTrue(copiedOutside)
        XCTAssertFalse(copiedOutsideRelative)
        XCTAssertFalse(revealedOutside)
        XCTAssertEqual(clipboard, [
            child.path, "Sources/File.swift", outside.path
        ])
        XCTAssertEqual(revealed, [child])
    }

    @MainActor
    func testAutomaticActiveFileSyncClearsUnavailableSelectionWithoutIssue() async throws {
        let container = try temporaryDirectory()
        let root = container.appendingPathComponent("project", isDirectory: true)
        let child = root.appendingPathComponent("Sources/File.swift")
        let outside = container.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(
            at: child.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("inside".utf8).write(to: child)
        try Data("outside".utf8).write(to: outside)
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openFile: { _ in }
        )
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)

        await controller.synchronizeActiveFile(child)
        XCTAssertEqual(controller.selectedURL, child)
        XCTAssertNil(controller.issue)

        await controller.synchronizeActiveFile(outside)
        XCTAssertNil(controller.selectedURL)
        XCTAssertNil(controller.issue)

        await controller.synchronizeActiveFile(nil)
        XCTAssertNil(controller.selectedURL)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testOpenDocumentCountUsesPathComponentBoundaries() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let sibling = root.appendingPathComponent("folder-other", isDirectory: true)
        let nested = folder.appendingPathComponent("nested.txt")
        let other = sibling.appendingPathComponent("other.txt")
        let controller = WorkspaceController(
            service: WorkspaceService(),
            openDocumentURLs: { [nested, other] },
            openFile: { _ in }
        )

        XCTAssertEqual(controller.openDocumentCount(under: folder), 1)
        XCTAssertEqual(controller.openDocumentCount(under: nested), 1)
        XCTAssertEqual(controller.openDocumentCount(under: root), 2)
    }

    @MainActor
    func testRestoreContinuesAfterMissingRootAndKeepsValidSibling() async throws {
        let container = try temporaryDirectory()
        let missing = container.appendingPathComponent("missing", isDirectory: true)
        let valid = container.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(
            at: valid, withIntermediateDirectories: false
        )
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in }
        )

        await controller.restoreRoots([missing, valid], primaryURL: valid)

        XCTAssertEqual(controller.roots.map { $0.url.standardizedFileURL }, [valid])
        XCTAssertEqual(controller.roots.first?.isPrimary, true)
        XCTAssertEqual(controller.issue?.title, "Could Not Restore Folder")
        XCTAssertTrue(controller.issue?.message.contains("missing") == true)
    }

    @MainActor
    func testFailedReplacementRestoreKeepsExistingWorkspace() async throws {
        let container = try temporaryDirectory()
        let existing = container.appendingPathComponent("existing", isDirectory: true)
        let missing = container.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing, withIntermediateDirectories: false
        )
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in }
        )
        let didAddRoot = await controller.addRoot(existing, makePrimary: true)
        XCTAssertTrue(didAddRoot)

        await controller.restoreRoots([missing], primaryURL: missing)

        XCTAssertEqual(
            controller.roots.map { $0.url.standardizedFileURL }, [existing]
        )
        XCTAssertEqual(controller.roots.first?.isPrimary, true)
        XCTAssertEqual(controller.issue?.title, "Could Not Restore Folder")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceControllerMutationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        temporaryDirectories.append(directory)
        return directory
    }

    @MainActor
    private func waitForDirectory(_ controller: WorkspaceController, url: URL) async {
        for _ in 0..<100 {
            if controller.state(for: url).loadState != .loading { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for workspace directory")
    }

    @MainActor
    private func waitForDirectoryRead(
        _ gate: ControllerDirectoryReadGate, count: Int
    ) async {
        for _ in 0..<1_000 {
            if gate.callCount >= count { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controlled directory read")
    }
}

private final class ControllerDirectoryReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstRelease = DispatchSemaphore(value: 0)
    private let secondRelease = DispatchSemaphore(value: 0)
    private var interceptedCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return interceptedCount
    }

    func intercept() {
        lock.lock()
        interceptedCount += 1
        let call = interceptedCount
        lock.unlock()
        if call == 1 {
            firstRelease.wait()
        } else if call == 2 {
            secondRelease.wait()
        }
    }

    func releaseFirst() { firstRelease.signal() }
    func releaseSecond() { secondRelease.signal() }

    func releaseAll() {
        firstRelease.signal()
        secondRelease.signal()
    }
}

private func controllerMutationScopedAccess(
    in directory: URL
) -> SecurityScopedAccessController {
    SecurityScopedAccessController(
        store: SecurityScopedBookmarkStore(
            directoryURL: directory.appendingPathComponent("bookmarks", isDirectory: true)
        ),
        provider: ControllerMutationBookmarkProvider(),
        requiresSecurityScope: { false }
    )
}

private final class ControllerMutationBookmarkProvider:
    SecurityScopedBookmarkProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private var starts: [String] = []
    private var stops: [String] = []

    var startedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stoppedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func makeBookmark(for url: URL) throws -> Data {
        Data(url.resolvingSymlinksInPath().standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.lock()
        starts.append(url.standardizedFileURL.path)
        lock.unlock()
        return true
    }
    func stopAccessing(_ url: URL) {
        lock.lock()
        stops.append(url.standardizedFileURL.path)
        lock.unlock()
    }
}

private final class WorkspaceMutationLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class ControllerTestTrash: WorkspaceTrashHandling, @unchecked Sendable {
    private let destinationDirectory: URL
    private let lock = NSLock()
    private var storage: [URL] = []

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    var trashedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func trashItem(at url: URL) throws {
        let destination = destinationDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}

@MainActor
private final class WorkspaceMutationTimingProbe {
    let source: URL
    let target: URL
    weak var controller: WorkspaceController?
    private(set) var preflightSawOriginal = false
    private(set) var postflightSawCommittedDiskAndOldTree = false

    init(source: URL, target: URL) {
        self.source = source
        self.target = target
    }

    func authorize(_ event: WorkspaceMutationEvent) {
        XCTAssertEqual(event, .renamed(from: source, to: target))
        preflightSawOriginal = FileManager.default.fileExists(atPath: source.path)
            && !FileManager.default.fileExists(atPath: target.path)
    }

    func commit(_ event: WorkspaceMutationEvent) {
        XCTAssertEqual(event, .renamed(from: source, to: target))
        postflightSawCommittedDiskAndOldTree =
            !FileManager.default.fileExists(atPath: source.path)
            && FileManager.default.fileExists(atPath: target.path)
            && controller?.state(for: source.deletingLastPathComponent())
                .entries.contains(where: { $0.url == source }) == true
    }
}
