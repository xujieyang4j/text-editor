import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class ProjectSettingsControllerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    @MainActor
    func testWorkspaceLoadDraftSaveAndCommitCallback() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(
            ProjectSettings(exclude: ["**/.build/**"], buildCommand: "swift build"),
            expectedRevision: nil
        )
        var commits: [ProjectSettings] = []
        let controller = ProjectSettingsController(didCommit: { settings, root in
            XCTAssertEqual(root, workspace)
            commits.append(settings)
        })

        controller.updateWorkspace(workspace, store: store)
        XCTAssertEqual(controller.settings.buildCommand, "swift build")
        XCTAssertEqual(controller.draft.excludeText, "**/.build/**")
        XCTAssertEqual(commits.count, 1)

        controller.setDraft("swift test", for: \.buildCommand)
        controller.setDraft("plugin-one\ninvalid id", for: \.pluginsText)
        controller.setDraft(
            "https://plugins.example.test/index.json\nhttp://insecure.test",
            for: \.marketplaceURLsText
        )
        XCTAssertTrue(controller.hasPendingChanges)
        XCTAssertTrue(controller.save())

        XCTAssertEqual(controller.settings.buildCommand, "swift test")
        XCTAssertEqual(controller.settings.plugins, ["plugin-one"])
        XCTAssertEqual(
            controller.settings.marketplaceUrls,
            ["https://plugins.example.test/index.json"]
        )
        XCTAssertFalse(controller.hasPendingChanges)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(try store.load().settings, controller.settings)
    }

    @MainActor
    func testCommittedExclusionsPublishOnLoadSaveAndRootClear() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(ProjectSettings(exclude: ["Generated/**"]), expectedRevision: nil)
        var snapshots: [[String]] = []
        let controller = ProjectSettingsController(
            exclusionsDidChange: { snapshots.append($0) }
        )

        controller.updateWorkspace(workspace, store: store)
        controller.setDraft("Vendor/**", for: \.excludeText)
        XCTAssertTrue(controller.save())
        controller.updateWorkspace(nil)

        XCTAssertEqual(snapshots, [["Generated/**"], ["Vendor/**"], []])
    }

    @MainActor
    func testInvalidNestedJSONKeepsDraftAndDoesNotWrite() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        controller.setDraft("[{", for: \.buildSystemsJSON)

        XCTAssertFalse(controller.save())
        XCTAssertEqual(controller.issue?.titleContent, .save)
        guard case .draft(.invalidJSONArray("Build systems"))? = controller.issue?.content else {
            return XCTFail("Expected a typed build-systems draft issue")
        }
        XCTAssertEqual(controller.issue?.title, "Could Not Save Project Settings")
        XCTAssertEqual(
            controller.issue.map {
                EditorLocale.zhCN.localizedProjectSettingsIssue($0.content)
            },
            "构建系统必须是有效的 JSON 数组。"
        )
        XCTAssertEqual(controller.draft.buildSystemsJSON, "[{")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsURL.path))
    }

    @MainActor
    func testCancelDiscardsUncommittedDraft() throws {
        let workspace = try temporaryDirectory()
        let controller = ProjectSettingsController()
        controller.updateWorkspace(
            workspace, store: ProjectSettingsStore(workspaceURL: workspace)
        )
        controller.present()
        controller.setDraft("unsaved", for: \.buildCommand)

        controller.dismiss()

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.draft.buildCommand, "")
        XCTAssertFalse(controller.hasPendingChanges)
    }

    @MainActor
    func testRepeatedSameWorkspaceUpdatePreservesPendingDraft() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(ProjectSettings(buildCommand: "persisted"), expectedRevision: nil)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        controller.setDraft("unsaved command", for: \.buildCommand)

        controller.updateWorkspace(workspace)

        XCTAssertEqual(controller.settings.buildCommand, "persisted")
        XCTAssertEqual(controller.draft.buildCommand, "unsaved command")
        XCTAssertTrue(controller.hasPendingChanges)
    }

    @MainActor
    func testAdoptPersistedSettingsUsesKnownRevisionWithoutReload() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let imported = ProjectSettings(
            exclude: ["*.tmp"],
            buildSystems: [ProjectBuildSystem(name: "Tests", command: "swift")]
        )
        let result = try store.save(imported, expectedRevision: nil)
        var commits: [ProjectSettings] = []
        let controller = ProjectSettingsController(didCommit: { settings, _ in
            commits.append(settings)
        })

        controller.adoptPersistedSettings(
            imported, revision: result.revision,
            workspaceURL: workspace, store: store
        )

        XCTAssertEqual(controller.settings, imported)
        XCTAssertFalse(controller.hasPendingChanges)
        XCTAssertNil(controller.issue)
        XCTAssertEqual(commits, [imported])
        controller.setDraft("swift test", for: \.buildCommand)
        XCTAssertTrue(controller.save())
    }

    @MainActor
    func testMalformedExistingFileCanBeExplicitlyRepairedWithoutBlindOverwrite() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        try Data("{not-json".utf8).write(to: store.settingsURL)
        let controller = ProjectSettingsController()

        controller.updateWorkspace(workspace, store: store)
        XCTAssertEqual(controller.issue?.title, "Could Not Load Project Settings")
        controller.setDraft("swift test", for: \.buildCommand)
        XCTAssertTrue(controller.save())
        XCTAssertEqual(try store.load().settings.buildCommand, "swift test")
    }

    @MainActor
    func testConflictKeepsDraftUntilExplicitReload() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(ProjectSettings(buildCommand: "initial"), expectedRevision: nil)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        controller.setDraft("my pending edit", for: \.buildCommand)
        try ProjectSettingsSanitizer.encodedData(ProjectSettings(buildCommand: "external"))
            .write(to: store.settingsURL)

        XCTAssertFalse(controller.save())
        XCTAssertTrue(controller.canReloadAfterConflict)
        XCTAssertEqual(controller.draft.buildCommand, "my pending edit")
        XCTAssertEqual(try store.load().settings.buildCommand, "external")

        XCTAssertTrue(controller.reload())
        XCTAssertEqual(controller.settings.buildCommand, "external")
        XCTAssertEqual(controller.draft.buildCommand, "external")
        XCTAssertFalse(controller.canReloadAfterConflict)
    }

    @MainActor
    func testWorkspaceSwitchClearsPriorStateAndRejectsMismatchedStore() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        let firstStore = ProjectSettingsStore(workspaceURL: first)
        _ = try firstStore.save(
            ProjectSettings(buildCommand: "first"), expectedRevision: nil
        )
        let controller = ProjectSettingsController()
        controller.updateWorkspace(first, store: firstStore)
        XCTAssertEqual(controller.settings.buildCommand, "first")

        controller.updateWorkspace(second, store: firstStore)
        XCTAssertEqual(controller.settings, .empty)
        XCTAssertEqual(controller.issue?.title, "Could Not Load Project Settings")

        controller.updateWorkspace(nil)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertEqual(controller.settings, .empty)
        controller.present()
        XCTAssertEqual(controller.issue?.titleContent, .noWorkspace)
        XCTAssertEqual(controller.issue?.content, .app(.noWorkspace))
        XCTAssertEqual(controller.issue?.title, "No Workspace Open")
    }

    @MainActor
    func testCommandRegistrationRequiresWorkspaceAndPresentsPanel() async throws {
        let workspace = try temporaryDirectory()
        let controller = ProjectSettingsController()
        let router = CommandRouter()
        _ = try controller.registerCommand(on: router)
        let noWorkspace = CommandRoutingContext(hasWorkspace: false)
        XCTAssertEqual(
            router.status(for: "project-settings", context: noWorkspace),
            .disabled(.handler(reason: "No workspace"))
        )

        controller.updateWorkspace(
            workspace, store: ProjectSettingsStore(workspaceURL: workspace)
        )
        let context = CommandRoutingContext(hasWorkspace: true)
        XCTAssertEqual(router.status(for: "project-settings", context: context), .enabled)
        let result = await router.execute("project-settings", context: context)
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    func testDraftRoundTripPreservesStructuredSections() throws {
        let expected = ProjectSettings(
            keyBindings: ["Mod+B": "build"],
            pluginPermissions: ["team": [.documentRead]],
            languageTools: ["Swift": LanguageToolConfig(command: "fmt", args: ["-"])],
            languageServers: ["Swift": LanguageServerConfig(command: "lsp", args: [])],
            buildSystems: [ProjectBuildSystem(name: "Tests", command: "swift", args: ["test"])],
            keyBindingRules: [ProjectKeyBindingRule(
                keys: ["Mod+K", "Mod+C"], command: "toggle-line-comment", when: .editor
            )],
            snippets: [ProjectSnippet(label: "Log", text: "print($0)")]
        )

        XCTAssertEqual(try ProjectSettingsDraft(settings: expected).validatedSettings(), expected)
    }

    @MainActor
    func testTypedLanguageToolAPISavesUpdatesAndRemovesWithRevisionPinning() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        let configured = LanguageToolConfig(
            command: "/usr/local/bin/formatter",
            args: ["--stdin"],
            shell: false,
            workingDirectory: "Sources",
            env: ["MODE": "format"]
        )

        XCTAssertTrue(controller.saveLanguageTool(configured, for: "Swift"))
        XCTAssertEqual(controller.languageTool(for: "Swift"), configured)
        XCTAssertEqual(try store.load().settings.languageTools["Swift"], configured)

        XCTAssertTrue(controller.saveLanguageTool(nil, for: "Swift"))
        XCTAssertNil(controller.languageTool(for: "Swift"))
        XCTAssertNil(try store.load().settings.languageTools["Swift"])
    }

    @MainActor
    func testBuildCommandAPIPersistsWithoutCommittingOtherDraftFields() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(
            ProjectSettings(exclude: ["kept"], buildCommand: "old"),
            expectedRevision: nil
        )
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        controller.setDraft("unsaved exclusion", for: \.excludeText)

        try controller.persistBuildCommand(
            "npm test", approvedWorkspaceRoot: workspace
        )

        XCTAssertEqual(controller.settings.buildCommand, "npm test")
        XCTAssertEqual(controller.settings.exclude, ["kept"])
        XCTAssertEqual(controller.draft.buildCommand, "npm test")
        XCTAssertEqual(controller.draft.excludeText, "unsaved exclusion")
        XCTAssertTrue(controller.hasPendingChanges)
        XCTAssertEqual(try store.load().settings.buildCommand, "npm test")
        XCTAssertEqual(try store.load().settings.exclude, ["kept"])
    }

    @MainActor
    func testBuildCommandAPIUsesRevisionPinning() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(ProjectSettings(buildCommand: "old"), expectedRevision: nil)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        _ = try store.save(
            ProjectSettings(buildCommand: "external"), expectedRevision: nil
        )

        XCTAssertThrowsError(try controller.persistBuildCommand(
            "approved", approvedWorkspaceRoot: workspace
        ))

        XCTAssertTrue(controller.canReloadAfterConflict)
        XCTAssertEqual(controller.settings.buildCommand, "old")
        XCTAssertEqual(try store.load().settings.buildCommand, "external")
    }

    @MainActor
    func testBuildCommandAPIRejectsApprovedRootMismatch() throws {
        let workspace = try temporaryDirectory()
        let otherWorkspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)

        XCTAssertThrowsError(try controller.persistBuildCommand(
            "npm test", approvedWorkspaceRoot: otherWorkspace
        )) { error in
            guard let persistenceError = error as? ProjectBuildCommandPersistenceError,
                  case let .workspaceMismatch(expected, actual) = persistenceError else {
                return XCTFail("Expected a typed workspace mismatch")
            }
            XCTAssertEqual(
                expected, otherWorkspace.standardizedFileURL.resolvingSymlinksInPath()
            )
            XCTAssertEqual(
                actual, workspace.standardizedFileURL.resolvingSymlinksInPath()
            )
        }
        XCTAssertEqual(controller.settings.buildCommand, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsURL.path))
    }

    @MainActor
    func testBuildCommandRollbackConflictKeepsCommittedControllerState() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(ProjectSettings(buildCommand: "old"), expectedRevision: nil)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        let receipt = try controller.persistBuildCommand(
            "approved", approvedWorkspaceRoot: workspace
        )
        let committed = try store.load()
        _ = try store.save(
            ProjectSettings(buildCommand: "external"),
            expectedRevision: committed.revision
        )

        XCTAssertThrowsError(try controller.rollbackBuildCommand(receipt))

        XCTAssertEqual(controller.settings.buildCommand, "approved")
        XCTAssertEqual(controller.draft.buildCommand, "approved")
        XCTAssertEqual(try store.load().settings.buildCommand, "external")
        XCTAssertEqual(controller.issue?.title, "Could Not Roll Back Build Command")
        XCTAssertEqual(controller.issue?.titleContent, .rollbackBuildCommand)
        guard case .store(.conflict)? = controller.issue?.content else {
            return XCTFail("Expected a typed project-settings conflict")
        }
    }

    @MainActor
    func testExternalAuthorizationFailureRemainsVerbatimAcrossLocales() async throws {
        struct ExternalFailure: LocalizedError {
            var errorDescription: String? {
                "Choose an existing executable file for the language server."
            }
        }

        let workspace = try temporaryDirectory()
        let executable = workspace.appendingPathComponent("external-lsp")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path, contents: Data(),
            attributes: [.posixPermissions: 0o700]
        ))
        let controller = ProjectSettingsController(
            chooseLanguageServerExecutable: { executable },
            authorizeLanguageServerExecutable: { _ in throw ExternalFailure() },
            securityScopedAccess: SecurityScopedAccessController(
                store: SecurityScopedBookmarkStore(directoryURL: try temporaryDirectory()),
                provider: ProjectSettingsBookmarkProvider(),
                requiresSecurityScope: { false }
            )
        )
        controller.updateWorkspace(
            workspace, store: ProjectSettingsStore(workspaceURL: workspace)
        )

        await controller.chooseLanguageServerExecutable()

        guard let issue = controller.issue else {
            return XCTFail("Expected an authorization issue")
        }
        XCTAssertEqual(issue.titleContent, .authorizeLanguageServerExecutable)
        XCTAssertEqual(
            issue.content,
            .verbatim("Choose an existing executable file for the language server.")
        )
        XCTAssertEqual(EditorLocale.zhCN.localizedProjectSettingsIssue(issue.content), issue.message)
    }

    @MainActor
    func testTypedLanguageToolAPIRejectsExternalRevisionConflict() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let controller = ProjectSettingsController()
        controller.updateWorkspace(workspace, store: store)
        _ = try store.save(ProjectSettings(buildCommand: "external"), expectedRevision: nil)

        XCTAssertFalse(controller.saveLanguageTool(
            LanguageToolConfig(command: "xcrun", args: ["formatter"]),
            for: "Swift"
        ))
        XCTAssertTrue(controller.canReloadAfterConflict)
        XCTAssertNil(controller.languageTool(for: "Swift"))
        XCTAssertEqual(try store.load().settings.buildCommand, "external")
    }

    @MainActor
    func testLanguageServerExecutableRequiresTrustedPickerAndRetainsLease() async throws {
        let workspace = try temporaryDirectory()
        let executable = workspace.appendingPathComponent("clangd")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700]
        ))
        let bookmarkDirectory = try temporaryDirectory()
        let provider = ProjectSettingsBookmarkProvider()
        let access = SecurityScopedAccessController(
            store: SecurityScopedBookmarkStore(directoryURL: bookmarkDirectory),
            provider: provider, requiresSecurityScope: { true }
        )
        var authorized: [URL] = []
        let controller = ProjectSettingsController(
            chooseLanguageServerExecutable: { executable },
            authorizeLanguageServerExecutable: { url in
                authorized.append(url)
                return url.standardizedFileURL.resolvingSymlinksInPath()
            },
            securityScopedAccess: access
        )
        controller.updateWorkspace(
            workspace, store: ProjectSettingsStore(workspaceURL: workspace)
        )

        await controller.chooseLanguageServerExecutable()

        XCTAssertEqual(authorized, [executable])
        XCTAssertEqual(controller.authorizedLanguageServerExecutableURLs, [executable])
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertEqual(provider.stopCount, 0)
        XCTAssertEqual(controller.settings.languageServers, [:])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ProjectSettingsStore(workspaceURL: workspace).settingsURL.path
        ), "Executable selection must not mutate or execute project settings")

        await controller.releaseLanguageServerExecutableAccess()
        XCTAssertEqual(provider.stopCount, 1)
        XCTAssertEqual(controller.authorizedLanguageServerExecutableURLs, [])
    }

    @MainActor
    func testProjectLanguageServerDeclarationDoesNotInvokeExecutableAuthorization() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        _ = try store.save(ProjectSettings(languageServers: [
            "C++": LanguageServerConfig(command: "/tmp/untrusted/clangd", args: [])
        ]), expectedRevision: nil)
        var authorizationCount = 0
        let controller = ProjectSettingsController(
            authorizeLanguageServerExecutable: { url in
                authorizationCount += 1
                return url
            }
        )

        controller.updateWorkspace(workspace, store: store)
        XCTAssertTrue(controller.save())

        XCTAssertEqual(authorizationCount, 0)
        XCTAssertEqual(controller.authorizedLanguageServerExecutableURLs, [])
        XCTAssertEqual(
            controller.settings.languageServers["C++"]?.command,
            "/tmp/untrusted/clangd"
        )
    }

    @MainActor
    func testViewPublishesStableAccessibilityContract() {
        XCTAssertEqual(ProjectSettingsView.Accessibility.panel, "Project Settings")
        XCTAssertEqual(ProjectSettingsView.Accessibility.exclude, "Project Exclude Patterns")
        XCTAssertEqual(
            ProjectSettingsView.Accessibility.chooseLanguageServerExecutable,
            "Choose Language Server Executable"
        )
        XCTAssertEqual(ProjectSettingsView.Accessibility.save, "Save Project Settings")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-settings-controller-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }
}

private final class ProjectSettingsBookmarkProvider:
    SecurityScopedBookmarkProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func makeBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
        ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
