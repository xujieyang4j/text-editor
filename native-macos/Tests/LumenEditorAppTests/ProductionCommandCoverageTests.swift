import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class ProductionCommandCoverageTests: XCTestCase {
    @MainActor
    func testProductionCompositionWiresLanguageServerExecutablePicker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProductionLSPExecutable-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        let executable = directory.appendingPathComponent("clangd")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700]
        ))
        let recentItems = RecentItemsStore(directoryURL: directory)
        let coordinator = WindowSessionCoordinator(recentItemsStore: recentItems)
        let session = try coordinator.composition(for: .legacy)
        let settings = SettingsController(store: SettingsStore(
            settingsURL: directory.appendingPathComponent("settings.json")
        ))
        var pickerLocales: [EditorLocale] = []
        let composition = EditorWindowComposition(
            session: session, settings: settings,
            chooseLanguageServerExecutable: { locale in
                pickerLocales.append(locale)
                return executable
            },
            languageServerSecurityScopedAccess: SecurityScopedAccessController(
                store: SecurityScopedBookmarkStore(directoryURL: directory),
                provider: ProductionCommandBookmarkProvider(),
                requiresSecurityScope: { true }
            )
        )
        addTeardownBlock { @MainActor in
            await composition.finalizeTermination()
            try? session.close()
            try? FileManager.default.removeItem(at: directory)
        }
        composition.projectSettingsController.updateWorkspace(
            directory, store: ProjectSettingsStore(workspaceURL: directory)
        )

        await composition.projectSettingsController.chooseLanguageServerExecutable()

        XCTAssertEqual(pickerLocales, [settings.settings.locale])
        XCTAssertEqual(
            composition.projectSettingsController.authorizedLanguageServerExecutableURLs,
            [executable]
        )
        let key = await composition.languageServerController.start(
            root: directory,
            config: LanguageServerConfig(command: executable.path, args: ["--stdio"])
        )
        XCTAssertNil(key)
        XCTAssertEqual(
            composition.languageServerController.pendingApproval?.configuration.executableURL,
            executable
        )
    }

    @MainActor
    func testEveryCatalogCommandHasAProductionWindowRoute() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        XCTAssertEqual(
            composition.buildController.freeFormCommand,
            fixture.settings.settings.buildCommand
        )
        let allRequirements = CommandRequirements(rawValue: UInt16.max)
        let context = CommandRoutingContext(availableRequirements: allRequirements)

        let unsupported = CommandCatalog.all.compactMap { command -> String? in
            composition.commandRouter.status(for: command.id, context: context)
                == .unsupported ? command.id : nil
        }

        XCTAssertEqual(CommandCatalog.all.count, 169)
        XCTAssertEqual(unsupported, [], "Every public command needs a production route")
        XCTAssertTrue(EditingCommands.unsupportedCommandIDs.isEmpty)
        for commandID in [
            "select-parent-syntax", "expand-selection",
            "shrink-selection", "reindent-selection"
        ] {
            XCTAssertEqual(
                composition.commandRouter.status(for: commandID, context: context),
                .enabled,
                "A bounded Core implementation must not retain legacy syntax-tree disablement"
            )
        }
    }

    @MainActor
    func testProductionFindRoutePublishesExactActiveEditorHighlightSnapshot() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        await composition.actions.restoreSessionIfNeeded()
        let document = composition.model.selectedDocument ?? composition.model.newDocument()
        document.text = "Cat cat catalog CAT"
        let paneIndex = composition.model.paneLayout.activePaneIndex
        let viewID = composition.model.paneLayout.panes[paneIndex].viewID
        _ = composition.model.setSelections(.cursor(at: 0), for: document, inPaneAt: paneIndex)
        composition.findController.query = "c.t"
        composition.findController.usesRegularExpression = true
        composition.findController.isCaseSensitive = true
        composition.findController.isWholeWord = true

        let result = await composition.commandRouter.execute(
            "find", context: composition.actions.commandRoutingContext()
        )
        XCTAssertTrue(result.didExecuteSuccessfully)
        await composition.findController.waitForCurrentSearch()

        let highlight = try XCTUnwrap(composition.findController.highlightSnapshot(
            documentID: document.sessionDocumentID, viewID: viewID,
            paneIndex: paneIndex, documentRevision: document.buffer.revision
        ))
        XCTAssertEqual(highlight.matches.map(\.range), [NSRange(location: 4, length: 3)])
        XCTAssertNil(highlight.selectedMatchIndex)
    }

    @MainActor
    func testProductionBuildWiringPersistsApprovedFreeFormCommandGloballyAndInProject() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        let workspaceRoot = fixture.directory.appendingPathComponent(
            "build-workspace", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceRoot, withIntermediateDirectories: false
        )
        let projectStore = ProjectSettingsStore(workspaceURL: workspaceRoot)
        composition.projectSettingsController.updateWorkspace(
            workspaceRoot, store: projectStore
        )
        await composition.buildController.updateWorkspaceRoot(workspaceRoot)
        composition.buildController.freeFormCommand = "  true  "

        let requestOutcome = await composition.buildController.requestFreeFormBuild()
        XCTAssertEqual(requestOutcome, .awaitingApproval)
        XCTAssertEqual(fixture.settings.settings.buildCommand, "")
        XCTAssertEqual(composition.projectSettingsController.settings.buildCommand, "")

        await composition.buildController.confirmPendingBuild()
        await composition.buildController.waitForCurrentBuild()

        XCTAssertEqual(composition.buildController.exitCode, 0)
        XCTAssertEqual(fixture.settings.settings.buildCommand, "true")
        XCTAssertTrue(fixture.settings.flush())
        XCTAssertEqual(
            SettingsStore(
                settingsURL: fixture.directory.appendingPathComponent("settings.json")
            ).load().buildCommand,
            "true"
        )
        XCTAssertEqual(
            composition.projectSettingsController.settings.buildCommand, "true"
        )
        XCTAssertEqual(try projectStore.load().settings.buildCommand, "true")
    }

    @MainActor
    func testProductionRoutesReportPanelVisibilityAndSideEffects() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition

        let workspaceRoot = fixture.directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceRoot, withIntermediateDirectories: true
        )
        let fileURL = workspaceRoot.appendingPathComponent("main.swift")
        try Data("let value = 1\n".utf8).write(to: fileURL)

        XCTAssertTrue(await composition.workspace.addRoot(workspaceRoot))
        composition.model.configureSessionWorkspace(
            folders: [workspaceRoot.path],
            primaryFolder: workspaceRoot.path,
            project: WindowSessionProject([
                "languageServers": .object([
                    "Swift": .object([
                        "command": .string("/usr/bin/true"),
                        "args": .array([])
                    ])
                ])
            ])
        )
        let opened = try TextFileCodec.decode(Data(contentsOf: fileURL), sourceURL: fileURL)
        let document = try XCTUnwrap(composition.model.open(openedFile: opened))
        XCTAssertTrue(composition.model.selectDocument(document, inPaneAt: 0))
        fixture.settings.set(true, for: .distractionFree)
        XCTAssertTrue(fixture.settings.flush())

        let context = composition.actions.commandRoutingContext(
            hasFindResults: composition.workspaceSearch.hasResults,
            hasGitRepository: composition.gitController.isRepositoryAvailable,
            hasNavigationHistory: composition.navigationController.canGoBack
                || composition.navigationController.canGoForward,
            hasLanguageService: composition.languageServerController.runningServerCount > 0
        )

        let reveal = await composition.commandRouter.execute(
            "reveal-active-file-in-sidebar", context: context
        )
        guard case .executed = reveal else {
            return XCTFail("Reveal active file should execute when the active file is in the workspace")
        }
        XCTAssertEqual(
            composition.workspace.selectedURL?.standardizedFileURL,
            fileURL.standardizedFileURL
        )
        XCTAssertTrue(composition.workspace.isSidebarVisible)
        XCTAssertFalse(fixture.settings.settings.distractionFree)
        XCTAssertFalse(SettingsStore(
            settingsURL: fixture.directory.appendingPathComponent("settings.json")
        ).load().distractionFree)

        composition.buildController.synchronizeFreeFormCommand("swift test")
        let build = await composition.commandRouter.execute("build", context: context)
        guard case .visiblePanel(commandID: "build") = build else {
            return XCTFail("Build should surface the build panel when it starts or awaits approval")
        }
        XCTAssertEqual(composition.actions.transientPanel, .build)
        XCTAssertNotNil(composition.buildController.pendingApproval)

        composition.actions.dismissTransientPanel()
        let lspHover = await composition.commandRouter.execute(
            "lsp-hover", context: context
        )
        guard case .visiblePanel(commandID: "lsp-hover") = lspHover else {
            return XCTFail("LSP hover should surface the language-server panel when approval is required")
        }
        XCTAssertEqual(composition.actions.transientPanel, .languageServers)
        XCTAssertNotNil(composition.languageServerController.pendingApproval)

        composition.actions.dismissTransientPanel()
        let lspReferences = await composition.commandRouter.execute(
            "lsp-references", context: context
        )
        guard case .visiblePanel(commandID: "lsp-references") = lspReferences else {
            return XCTFail("LSP references should surface the language-server panel when approval is required")
        }
        XCTAssertEqual(composition.actions.transientPanel, .languageServers)
        XCTAssertNotNil(composition.languageServerController.pendingApproval)
    }

    @MainActor
    func testRevealRoutePreservesWorkspacePresentationContent() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        await composition.actions.restoreSessionIfNeeded()
        _ = composition.model.newDocument()
        fixture.settings.set(true, for: .distractionFree)
        XCTAssertTrue(fixture.settings.flush())

        let context = CommandRoutingContext(
            hasDocument: true, hasSavedDocument: true, hasWorkspace: true
        )
        let result = await composition.commandRouter.execute(
            "reveal-active-file-in-sidebar", context: context
        )

        guard case let .failed(commandID, error) = result,
              let signal = error as? CommandHandlerSignal,
              case let .failedPresentation(.workspace(content)) = signal else {
            return XCTFail("Reveal should preserve its workspace presentation content")
        }
        XCTAssertEqual(commandID, "reveal-active-file-in-sidebar")
        XCTAssertEqual(
            content,
            .app(
                english: "Save the active document inside an open workspace first.",
                chinese: "请先将活动文档保存到已打开的工作区中。"
            )
        )
        XCTAssertTrue(fixture.settings.settings.distractionFree)
    }

    @MainActor
    func testRevealRouteFailsClosedWhenDistractionFreeCannotPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProductionRevealSettingsFailure-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        let blockedParent = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let settings = SettingsController(
            store: SettingsStore(
                settingsURL: blockedParent.appendingPathComponent("settings.json")
            ),
            saveDebounceNanoseconds: 60_000_000_000
        )
        settings.set(true, for: .distractionFree)
        let coordinator = WindowSessionCoordinator(
            recentItemsStore: RecentItemsStore(directoryURL: directory)
        )
        let session = try coordinator.composition(for: .legacy)
        let composition = EditorWindowComposition(session: session, settings: settings)
        addTeardownBlock { @MainActor in
            await composition.finalizeTermination()
            try? session.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let root = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("main.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        XCTAssertTrue(await composition.workspace.addRoot(root))
        if composition.workspace.isSidebarVisible {
            composition.workspace.toggleSidebar()
        }
        let opened = try TextFileCodec.decode(Data(contentsOf: file), sourceURL: file)
        let document = try XCTUnwrap(composition.model.open(openedFile: opened))
        XCTAssertTrue(composition.model.selectDocument(document, inPaneAt: 0))

        let result = await composition.commandRouter.execute(
            "reveal-active-file-in-sidebar",
            context: composition.actions.commandRoutingContext()
        )

        guard case let .failed(commandID, _) = result else {
            return XCTFail("Reveal must fail when distraction-free state cannot persist")
        }
        XCTAssertEqual(commandID, "reveal-active-file-in-sidebar")
        XCTAssertTrue(settings.settings.distractionFree)
        XCTAssertNotNil(settings.persistenceIssue)
        XCTAssertFalse(composition.workspace.isSidebarVisible)
        XCTAssertNil(composition.workspace.selectedURL)
    }

    @MainActor
    func testProductionGitRoutesDifferentiateNoChangeAndUnavailableStates() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        let context = composition.actions.commandRoutingContext(
            hasFindResults: composition.workspaceSearch.hasResults,
            hasGitRepository: true,
            hasNavigationHistory: false,
            hasLanguageService: false
        )

        let noRepository = await composition.commandRouter.execute(
            "refresh-git", context: context
        )
        guard case let .unavailable(status) = noRepository else {
            return XCTFail("Refreshing Git without a repository should be rejected before execution")
        }
        XCTAssertEqual(
            status,
            .disabled(.handler(reason: "The primary workspace is not a Git repository."))
        )
        XCTAssertNil(composition.gitController.issue)

        let conflicts = await composition.commandRouter.execute(
            "open-git-conflicts", context: context
        )
        guard case let .unavailable(status) = conflicts else {
            return XCTFail("Opening Git conflicts without a repository should be rejected before execution")
        }
        XCTAssertEqual(
            status,
            .disabled(.handler(reason: "The primary workspace is not a Git repository."))
        )
        XCTAssertNil(composition.actions.transientPanel)
        XCTAssertNil(composition.actions.dropNotice)
    }

    @MainActor
    func testProductionDefinitionFallsBackWithoutLanguageServer() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        await composition.actions.restoreSessionIfNeeded()
        let workspaceRoot = fixture.directory.appendingPathComponent(
            "definition-workspace", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceRoot, withIntermediateDirectories: true
        )
        let fileURL = workspaceRoot.appendingPathComponent("main.swift")
        let source = "func target() {}\ntarget()\n"
        try Data(source.utf8).write(to: fileURL)
        XCTAssertTrue(await composition.workspace.addRoot(workspaceRoot))
        await Task.yield()
        await Task.yield()
        let opened = try TextFileCodec.decode(
            Data(contentsOf: fileURL), sourceURL: fileURL
        )
        let document = try XCTUnwrap(composition.model.open(openedFile: opened))
        _ = composition.model.selectDocument(document, inPaneAt: 0)
        XCTAssertEqual(composition.model.selectedDocument?.id, document.id)
        let callRange = (source as NSString).range(
            of: "target", options: [], range: NSRange(location: 15, length: 8)
        )
        XCTAssertNotEqual(callRange.location, NSNotFound)
        XCTAssertTrue(composition.model.setSelections(
            .cursor(at: callRange.location + 2), for: document, inPaneAt: 0
        ))
        let context = composition.actions.commandRoutingContext()

        XCTAssertEqual(
            composition.commandRouter.status(
                for: "lsp-definition", context: context
            ),
            .enabled
        )
        let result = await composition.commandRouter.execute(
            "lsp-definition", context: context
        )

        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertEqual(
            composition.model.selection(
                for: document, inPaneAt: 0
            ).main.head,
            0
        )
        XCTAssertNil(composition.languageServerController.pendingApproval)
    }

    @MainActor
    func testProductionReferencesFallBackToLiteralWholeWordSearch() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        await composition.actions.restoreSessionIfNeeded()
        let workspaceRoot = fixture.directory.appendingPathComponent(
            "references-workspace", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceRoot, withIntermediateDirectories: true
        )
        let fileURL = workspaceRoot.appendingPathComponent("main.swift")
        let source = "let HTTPClient = 1\nprint(HTTPClient)\n"
        try Data(source.utf8).write(to: fileURL)
        XCTAssertTrue(await composition.workspace.addRoot(workspaceRoot))
        await Task.yield()
        await Task.yield()
        let opened = try TextFileCodec.decode(
            Data(contentsOf: fileURL), sourceURL: fileURL
        )
        let document = try XCTUnwrap(composition.model.open(openedFile: opened))
        _ = composition.model.selectDocument(document, inPaneAt: 0)
        XCTAssertEqual(composition.model.selectedDocument?.id, document.id)
        let reference = (source as NSString).range(of: "HTTPClient", options: [], range: NSRange(
            location: 19, length: (source as NSString).length - 19
        ))
        XCTAssertNotEqual(reference.location, NSNotFound)
        XCTAssertTrue(composition.model.setSelections(
            .cursor(at: reference.location), for: document, inPaneAt: 0
        ))
        let context = composition.actions.commandRoutingContext()
        XCTAssertEqual(
            composition.commandRouter.status(
                for: "lsp-references", context: context
            ),
            .enabled
        )

        let result = await composition.commandRouter.execute(
            "lsp-references", context: context
        )
        guard case .visiblePanel(commandID: "lsp-references") = result else {
            return XCTFail("References fallback should open workspace results")
        }
        XCTAssertEqual(composition.actions.transientPanel, .workspaceSearch)
        XCTAssertEqual(composition.workspaceSearch.query, "HTTPClient")
        XCTAssertTrue(composition.workspaceSearch.isCaseSensitive)
        XCTAssertTrue(composition.workspaceSearch.isWholeWord)
        XCTAssertFalse(composition.workspaceSearch.usesRegularExpression)
        await composition.workspaceSearch.waitForCurrentOperation()
        XCTAssertEqual(composition.workspaceSearch.matches.count, 2)
        XCTAssertNil(composition.languageServerController.pendingApproval)
    }

    @MainActor
    func testProductionDefinitionFallbackPresentsExactProjectMatches() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { await fixture.cleanup() }
        let composition = fixture.composition
        await composition.actions.restoreSessionIfNeeded()
        let workspaceRoot = fixture.directory.appendingPathComponent(
            "project-symbol-workspace", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceRoot, withIntermediateDirectories: true
        )
        let callerURL = workspaceRoot.appendingPathComponent("caller.swift")
        let firstURL = workspaceRoot.appendingPathComponent("first.swift")
        let secondURL = workspaceRoot.appendingPathComponent("second.swift")
        try Data("target()\n".utf8).write(to: callerURL)
        try Data("func target() {}\n".utf8).write(to: firstURL)
        try Data("func target() {}\n".utf8).write(to: secondURL)
        XCTAssertTrue(await composition.workspace.addRoot(workspaceRoot))
        await Task.yield()
        await Task.yield()
        let opened = try TextFileCodec.decode(
            Data(contentsOf: callerURL), sourceURL: callerURL
        )
        let document = try XCTUnwrap(composition.model.open(openedFile: opened))
        _ = composition.model.selectDocument(document, inPaneAt: 0)
        XCTAssertEqual(composition.model.selectedDocument?.id, document.id)
        XCTAssertTrue(composition.model.setSelections(
            .cursor(at: 2), for: document, inPaneAt: 0
        ))

        let result = await composition.commandRouter.execute(
            "lsp-definition",
            context: composition.actions.commandRoutingContext()
        )
        guard case .visiblePanel(commandID: "lsp-definition") = result else {
            return XCTFail("Ambiguous exact definitions should open the symbol palette")
        }
        XCTAssertEqual(composition.actions.transientPanel, .navigation)
        XCTAssertEqual(
            Set(composition.navigationController.items.map(\.destination.line)),
            [1]
        )
        XCTAssertEqual(composition.navigationController.items.count, 2)
        XCTAssertTrue(composition.navigationController.items.allSatisfy {
            $0.label == "target"
        })
    }

    private struct Fixture {
        let directory: URL
        let session: WindowSessionComposition
        let settings: SettingsController
        let composition: EditorWindowComposition

        @MainActor
        func cleanup() async {
            await composition.languageServerController.stopAll()
            await composition.pluginController.deactivateWorkers()
            try? session.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProductionCommandCoverageTests-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )

        let recentItems = RecentItemsStore(directoryURL: directory)
        let coordinator = WindowSessionCoordinator(recentItemsStore: recentItems)
        let session = try coordinator.composition(for: .legacy)
        let settings = SettingsController(store: SettingsStore(
            settingsURL: directory.appendingPathComponent("settings.json")
        ))
        let composition = EditorWindowComposition(session: session, settings: settings)
        return Fixture(
            directory: directory,
            session: session,
            settings: settings,
            composition: composition
        )
    }
}

private struct ProductionCommandBookmarkProvider: SecurityScopedBookmarkProviding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
