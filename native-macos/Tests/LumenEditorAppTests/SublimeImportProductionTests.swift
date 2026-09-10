import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class SublimeImportProductionTests: XCTestCase {
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func withValue<Result>(_ action: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return action(&value)
        }
    }

    func testPanelCopyLocalizesEverySublimeSourceKind() {
        let cases: [(SublimeImportKind, String, String)] = [
            (.project, "项目", "sublime-project"),
            (.settings, "设置", "sublime-settings"),
            (.keymap, "快捷键映射", "sublime-keymap"),
            (.snippet, "代码片段", "sublime-snippet"),
            (.build, "构建系统", "sublime-build")
        ]

        for (kind, chineseName, fileExtension) in cases {
            XCTAssertEqual(
                SublimeImportPanelCopy.source(kind: kind, locale: .enUS),
                .init(
                    title: "Import Sublime \(kind.displayName)",
                    message: "Choose a .\(fileExtension) file to preview. Nothing is imported until you confirm.",
                    prompt: "Preview"
                )
            )
            XCTAssertEqual(
                SublimeImportPanelCopy.source(kind: kind, locale: .zhCN),
                .init(
                    title: "导入 Sublime \(chineseName)",
                    message: "选择一个 .\(fileExtension) 文件进行预览。确认前不会导入任何内容。",
                    prompt: "预览"
                )
            )
        }
    }

    func testProjectAuthorizationPanelCopyLocalizesDynamicPath() {
        let expected = URL(fileURLWithPath: "/workspace/示例")

        XCTAssertEqual(
            SublimeImportPanelCopy.projectAuthorization(
                expected: expected, locale: .enUS
            ),
            .init(
                title: "Authorize Sublime Project Folder",
                message: "Confirm access to the folder declared by the project: /workspace/示例",
                prompt: "Authorize"
            )
        )
        XCTAssertEqual(
            SublimeImportPanelCopy.projectAuthorization(
                expected: expected, locale: .zhCN
            ),
            .init(
                title: "授权 Sublime 项目文件夹",
                message: "确认访问项目声明的文件夹：/workspace/示例",
                prompt: "授权"
            )
        )
    }

    func testDescriptorReaderReadsAtBoundAndRejectsOversizeDirectoryAndSymlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Preferences.sublime-settings")
        try Data("12345678".utf8).write(to: source)
        let reader = SublimeImportDescriptorReader()

        XCTAssertEqual(try reader.read(source, maximumByteCount: 8), Data("12345678".utf8))
        XCTAssertThrowsError(try reader.read(source, maximumByteCount: 7)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                SublimeImportProductionError.sourceTooLarge(
                    actualBytes: 8, maximumBytes: 7
                ).localizedDescription
            )
        }
        XCTAssertThrowsError(try reader.read(directory, maximumByteCount: 100)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                SublimeImportProductionError.sourceIsNotRegularFile.localizedDescription
            )
        }
        let link = directory.appendingPathComponent("Alias.sublime-settings")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try reader.read(link, maximumByteCount: 100))
    }

    @MainActor
    func testPickerBoundsByKindAndBalancesSecurityScopeOnSuccessAndFailure() async throws {
        let url = URL(fileURLWithPath: "/picked/Print.sublime-snippet")
        var starts: [URL] = []
        var stops: [URL] = []
        let observedMaximum = LockedBox<Int?>(nil)
        let picker = SublimeImportSourcePicker(
            chooseURL: { kind in
                XCTAssertEqual(kind, .snippet)
                return url
            },
            readBytes: { _, maximum in
                observedMaximum.withValue { $0 = maximum }
                return Data("snippet".utf8)
            },
            startSecurityScope: { starts.append($0); return true },
            stopSecurityScope: { stops.append($0) }
        )

        let source = try await picker.requestSource(for: .snippet)
        XCTAssertEqual(source?.data, Data("snippet".utf8))
        XCTAssertEqual(
            observedMaximum.withValue { $0 },
            SublimeImportLimits.default.maximumSnippetBytes
        )
        XCTAssertEqual(starts, [url])
        XCTAssertEqual(stops, [url])
        XCTAssertFalse(picker.isPresenting)

        let failing = SublimeImportSourcePicker(
            chooseURL: { _ in url },
            readBytes: { _, _ in throw TestFailure.read },
            startSecurityScope: { _ in true },
            stopSecurityScope: { stops.append($0) }
        )
        await XCTAssertThrowsErrorAsync(try await failing.requestSource(for: .settings))
        XCTAssertEqual(stops, [url, url])
        XCTAssertFalse(failing.isPresenting)
    }

    @MainActor
    func testProjectTransactionRollsBackOnlyNewRootsWhenPersistenceFails() async {
        let existing = URL(fileURLWithPath: "/workspace/existing")
        let first = URL(fileURLWithPath: "/workspace/first")
        let second = URL(fileURLWithPath: "/workspace/second")
        var authorized: [URL] = []
        var revoked: [URL] = []
        var restoredPrimary: [URL?] = []
        let transaction = SublimeProjectImportTransaction(
            existingRoots: { .init(urls: [existing], primaryURL: existing) },
            authorizeRoot: { url, _ in authorized.append(url); return url },
            revokeRoot: { revoked.append($0) },
            restorePrimaryRoot: { restoredPrimary.append($0) },
            persistProject: { _, _ in throw TestFailure.persist }
        )
        let imported = SublimeProjectImport(
            sourceURL: URL(fileURLWithPath: "/picked/Demo.sublime-project"),
            roots: [existing, first, second], exclusions: [], buildSystems: []
        )

        await XCTAssertThrowsErrorAsync(try await transaction.apply(imported))
        XCTAssertEqual(authorized, [first, second])
        XCTAssertEqual(revoked, [second, first])
        XCTAssertEqual(restoredPrimary, [existing])
    }

    @MainActor
    func testProjectTransactionReportsExactAcceptedRootsAfterAtomicPersistence() async throws {
        let first = URL(fileURLWithPath: "/workspace/first")
        let second = URL(fileURLWithPath: "/workspace/second")
        var persistedRoot: URL?
        var primaryRoot: URL?
        let transaction = SublimeProjectImportTransaction(
            existingRoots: { .init(urls: [], primaryURL: nil) },
            authorizeRoot: { url, _ in url },
            revokeRoot: { _ in XCTFail("Successful transaction must not roll back") },
            setPrimaryRoot: { primaryRoot = $0 },
            persistProject: { root, _ in persistedRoot = root }
        )
        let imported = SublimeProjectImport(
            sourceURL: URL(fileURLWithPath: "/picked/Demo.sublime-project"),
            roots: [first, second, first], exclusions: ["*.tmp"], buildSystems: []
        )

        let accepted = try await transaction.apply(imported)
        XCTAssertEqual(accepted, [first, second])
        XCTAssertEqual(persistedRoot, first)
        XCTAssertEqual(primaryRoot, first)
    }

    @MainActor
    func testCompositionRejectsInjectedMismatchedTrustedRootBeforeGrant() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let declared = container.appendingPathComponent("declared", isDirectory: true)
        let selected = container.appendingPathComponent("different", isDirectory: true)
        try FileManager.default.createDirectory(at: declared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let settings = SettingsController(store: SettingsStore(
            settingsURL: container.appendingPathComponent("settings.json")
        ))
        let workspace = WorkspaceController(openFile: { _ in })
        let projectSettings = ProjectSettingsController()
        let composition = SublimeImportComposition.production(
            settings: settings, workspace: workspace, projectSettings: projectSettings,
            currentKeyBindings: { [] }, applyKeyBindings: { _ in },
            authorizeProjectRoot: { _ in selected }
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "folders": [["path": declared.path]]
        ])
        let prepared = await composition.controller.prepareImport(
            .project,
            sourceURL: container.appendingPathComponent("Demo.sublime-project"),
            data: data
        )
        XCTAssertTrue(prepared)
        let token = try XCTUnwrap(composition.controller.confirmationToken)

        let confirmed = await composition.controller.confirm(token: token)
        XCTAssertFalse(confirmed)
        XCTAssertTrue(workspace.roots.isEmpty)
        XCTAssertEqual(composition.controller.status, .failed(.project))
    }

    func testProjectMergePreservesUnrelatedSettingsAndMergesDeclarations() throws {
        let existing = ProjectSettings(
            exclude: ["old"], buildCommand: "make",
            plugins: ["plugin.example"],
            languageTools: ["Swift": LanguageToolConfig(
                command: "swift-format", args: []
            )],
            buildSystems: [ProjectBuildSystem(name: "Old", command: "old")],
            marketplaceUrls: ["https://example.com/index.json"],
            snippets: [ProjectSnippet(label: "Kept", text: "kept")]
        )
        let imported = SublimeProjectImport(
            sourceURL: URL(fileURLWithPath: "/picked/Demo.sublime-project"),
            roots: [URL(fileURLWithPath: "/workspace")],
            exclusions: ["*.tmp"],
            buildSystems: [SublimeBuildSystemImport(name: "Tests", command: "swift")]
        )

        let result = SublimeImportProjectSettingsMerge.project(imported, into: existing)
        XCTAssertEqual(result.exclude, ["*.tmp"])
        XCTAssertEqual(result.buildSystems.map(\.name), ["Tests", "Old"])
        XCTAssertEqual(result.buildCommand, "make")
        XCTAssertEqual(result.plugins, ["plugin.example"])
        XCTAssertEqual(result.languageTools["Swift"]?.command, "swift-format")
        XCTAssertEqual(result.marketplaceUrls, ["https://example.com/index.json"])
        XCTAssertEqual(result.snippets.map(\.label), ["Kept"])
    }

    func testKeymapSnippetAndStandaloneBuildMergeWithoutExecutingAnything() throws {
        let binding = KeyBindingOverride(
            commandID: "save",
            binding: CommandKeyBinding(sequence: [
                CommandKeyEquivalent(key: "s", modifiers: .command)
            ])
        )
        let keymap = SublimeKeymapImport(
            sourceURL: URL(fileURLWithPath: "/picked/Default.sublime-keymap"),
            overrides: [binding], skipped: 0, inspected: 1, wasTruncated: false
        )
        var settings = SublimeImportProjectSettingsMerge.keymap(
            keymap, into: ProjectSettings(
                keyBindingRules: [ProjectKeyBindingRule(keys: ["Mod+O"], command: "open-file")]
            )
        )
        XCTAssertEqual(settings.keyBindingRules.map(\.command), ["open-file", "save"])
        XCTAssertEqual(
            SublimeImportProjectSettingsMerge.keyBindingOverrides(
                from: settings.keyBindingRules
            ).last,
            binding
        )

        let snippet = SublimeSnippetImport(
            sourceURL: URL(fileURLWithPath: "/picked/Print.sublime-snippet"),
            label: "Print", text: "print($0)", trigger: "log"
        )
        settings.snippets = [ProjectSnippet(label: "Print", text: "old")]
        settings = SublimeImportProjectSettingsMerge.snippet(snippet, into: settings)
        XCTAssertEqual(settings.snippets, [
            ProjectSnippet(label: "Print", text: "print($0)", trigger: "log")
        ])

        let build = SublimeBuildImport(
            sourceURL: URL(fileURLWithPath: "/picked/Swift.sublime-build"),
            system: SublimeBuildSystemImport(name: "Swift", command: "swift")
        )
        settings = SublimeImportProjectSettingsMerge.build(build, into: settings)
        XCTAssertEqual(settings.buildSystems.first?.name, "Swift")
        XCTAssertEqual(settings.buildSystems.first?.command, "swift")
    }

    @MainActor
    func testSettingsConfirmationRebasesPreviewChangesOntoLatestSettings() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsController(store: SettingsStore(
            settingsURL: directory.appendingPathComponent("settings.json")
        ), saveDebounceNanoseconds: 60_000_000_000)
        let composition = SublimeImportComposition.production(
            settings: settings, workspace: WorkspaceController(openFile: { _ in }),
            projectSettings: ProjectSettingsController(),
            currentKeyBindings: { [] }, applyKeyBindings: { _ in }
        )
        let prepared = await composition.controller.prepareImport(
            .settings,
            sourceURL: directory.appendingPathComponent("Preferences.sublime-settings"),
            data: Data(#"{"font_size":21}"#.utf8)
        )
        XCTAssertTrue(prepared)
        settings.set(false, for: \.showMinimap)
        let token = try XCTUnwrap(composition.controller.confirmationToken)

        let confirmed = await composition.controller.confirm(token: token)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(settings.settings.fontSize, 21)
        XCTAssertFalse(settings.settings.showMinimap)
        XCTAssertEqual(SettingsStore(
            settingsURL: directory.appendingPathComponent("settings.json")
        ).load(), settings.settings)
    }

    @MainActor
    func testCompositionRegistersAllFiveRoutesAndPresentsPreviewOnlyAfterSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsStore = SettingsStore(
            settingsURL: directory.appendingPathComponent("settings.json")
        )
        let settings = SettingsController(store: settingsStore, saveDebounceNanoseconds: 0)
        let workspace = WorkspaceController(openFile: { _ in })
        let projectSettings = ProjectSettingsController()
        var selectionCount = 0
        let picker = SublimeImportSourcePicker(
            chooseURL: { kind in
                selectionCount += 1
                return kind == .settings
                    ? URL(fileURLWithPath: "/picked/Preferences.sublime-settings")
                    : nil
            },
            readBytes: { _, _ in Data(#"{"font_size":19}"#.utf8) },
            startSecurityScope: { _ in false },
            stopSecurityScope: { _ in XCTFail("No scope was started") }
        )
        let composition = SublimeImportComposition.production(
            settings: settings, workspace: workspace, projectSettings: projectSettings,
            currentKeyBindings: { [] }, applyKeyBindings: { _ in },
            sourcePicker: picker
        )
        let router = CommandRouter()
        var presentationCount = 0
        let tokens = try composition.registerCommands(
            on: router, present: { presentationCount += 1 }
        )
        XCTAssertEqual(tokens.map(\.commandID), SublimeImportController.commandIDs)

        let result = await router.execute(
            "import-sublime-settings", context: CommandRoutingContext()
        )
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertEqual(selectionCount, 1)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(composition.controller.status, .awaitingConfirmation(.settings))
    }

    func testViewPublishesStableAccessibilityContract() {
        XCTAssertEqual(SublimeImportView.Accessibility.panel, "Sublime Import Preview")
        XCTAssertEqual(SublimeImportView.Accessibility.confirm, "Confirm Sublime Import")
        XCTAssertEqual(SublimeImportView.Accessibility.cancel, "Cancel Sublime Import")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SublimeImportProductionTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum TestFailure: Error {
    case read
    case persist
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
