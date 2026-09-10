import Foundation
@testable import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class MacroSnippetControllerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    @MainActor
    func testMacroFileSystemIssueLocalizesFixedGrammarAndPreservesParameters() {
        let content = MacroSnippetController.presentationMessage(
            for: MacroStoreError.fileSystem(operation: "rename", code: 13)
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedMacroSnippetIssue(content),
            "宏文件操作“rename”失败（errno 13）。"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedMacroSnippetIssue(content),
            "Macro file operation ‘rename’ failed (errno 13)."
        )
    }

    @MainActor
    func testRetainedMacroIssueRerendersForRuntimeLocale() async {
        let controller = makeController()

        let didRun = await controller.runLastMacro()
        XCTAssertFalse(didRun)
        guard let issue = controller.issue else {
            return XCTFail("Expected a retained macro issue")
        }

        XCTAssertEqual(
            EditorLocale.enUS.localizedMacroSnippetIssueTitle(issue.titleContent),
            "Macro Unavailable"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedMacroSnippetIssueTitle(issue.titleContent),
            "宏不可用"
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedMacroSnippetIssue(issue.content),
            "No recorded macro is available."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedMacroSnippetIssue(issue.content),
            "没有可用的已录制宏。"
        )
    }

    func testUnknownMacroErrorThatMatchesAppCopyRemainsVerbatim() {
        struct ExternalFailure: LocalizedError {
            let errorDescription: String? = "No recorded macro is available."
        }
        let content = MacroSnippetController.presentationMessage(
            for: ExternalFailure()
        )

        XCTAssertEqual(content, .verbatim("No recorded macro is available."))
        XCTAssertEqual(
            EditorLocale.zhCN.localizedMacroSnippetIssue(content),
            "No recorded macro is available."
        )
    }

    @MainActor
    func testRecordsTypedCommandsAndEditsThenReplaysInStrictOrder() async throws {
        let events = EventBox()
        let controller = makeController(
            dispatchCommand: { command in
                events.values.append("command:\(command.rawValue)")
                return true
            },
            applyTransaction: { transaction in
                events.values.append("edit:\(transaction.edits.first?.insert ?? "")")
                return true
            }
        )

        XCTAssertTrue(controller.toggleRecording())
        controller.record(command: .toggleComment)
        controller.record(transaction: try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "x")
        ]))
        XCTAssertFalse(controller.toggleRecording())
        XCTAssertEqual(controller.status, .recorded(stepCount: 2))

        let replayed = await controller.runLastMacro()
        XCTAssertTrue(replayed)
        XCTAssertEqual(events.values, ["command:toggle-comment", "edit:x"])
    }

    @MainActor
    func testCommandDispatchSeamSuppressesItsGeneratedTransaction() async throws {
        var controller: MacroSnippetController!
        controller = makeController(
            dispatchCommand: { _ in
                controller.record(transaction: try! TextTransaction(edits: [
                    TextEdit(from: 0, to: 0, insert: "generated")
                ]))
                return true
            }
        )
        controller.toggleRecording()

        let dispatched = await controller.dispatchRecording(.deleteLine)
        XCTAssertTrue(dispatched)
        controller.toggleRecording()
        XCTAssertEqual(controller.recordedSteps, [.command(.deleteLine)])
    }

    @MainActor
    func testRoutedCommandObserverRecordsOnlySuccessfulCompletion() {
        let controller = makeController()
        controller.toggleRecording()

        controller.observeRoutedCommand("delete-line", observation: .began)
        controller.observeRoutedCommand(
            "delete-line", observation: .finished(succeeded: false)
        )
        controller.observeRoutedCommand("move-line-down", observation: .began)
        controller.observeRoutedCommand(
            "move-line-down", observation: .finished(succeeded: true)
        )
        controller.toggleRecording()

        XCTAssertEqual(controller.recordedSteps, [.command(.moveLineDown)])
    }

    @MainActor
    func testDispatchRecordingDoesNotRecordFailedCommand() async {
        let controller = makeController(dispatchCommand: { _ in false })
        controller.toggleRecording()

        let dispatched = await controller.dispatchRecording(.deleteLine)
        XCTAssertFalse(dispatched)
        controller.toggleRecording()

        XCTAssertEqual(controller.recordedSteps, [])
    }

    @MainActor
    func testRouterAndMacroIntegrationDropsNoChangeAndFailedCommands() async throws {
        struct Failure: Error {}
        let controller = makeController()
        let router = CommandRouter()
        router.setExecutionObserver { commandID, observation in
            controller.observeRoutedCommand(commandID, observation: observation)
        }
        _ = try router.register("delete-line") { _ in
            throw CommandHandlerSignal.noChange
        }
        _ = try router.register("move-line-down") { _ in
            throw Failure()
        }
        _ = try router.register("sort-lines") { _ in }
        let context = CommandRoutingContext(hasDocument: true)
        controller.toggleRecording()

        let noChange = await router.execute("delete-line", context: context)
        let failed = await router.execute("move-line-down", context: context)
        let executed = await router.execute("sort-lines", context: context)
        controller.toggleRecording()

        XCTAssertFalse(noChange.didExecuteSuccessfully)
        XCTAssertFalse(failed.didExecuteSuccessfully)
        XCTAssertTrue(executed.didExecuteSuccessfully)
        XCTAssertEqual(controller.recordedSteps, [.command(.sortLines)])
    }

    @MainActor
    func testReplaySuppressesRecursiveRecordingAndStopsOnFirstFailure() async throws {
        let events = EventBox()
        var controller: MacroSnippetController!
        controller = makeController(
            dispatchCommand: { command in
                events.values.append(command.rawValue)
                controller.record(command: .sortLines)
                return false
            },
            applyTransaction: { _ in
                events.values.append("edit")
                return true
            }
        )
        controller.toggleRecording()
        controller.record(command: .deleteLine)
        controller.record(transaction: try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "after")
        ]))

        let replayed = await controller.runLastMacro()
        XCTAssertFalse(replayed)
        XCTAssertEqual(events.values, ["delete-line"])
        XCTAssertEqual(controller.recordedSteps.count, 2)
        XCTAssertFalse(controller.isReplaying)
        XCTAssertEqual(controller.status, .failed)
    }

    @MainActor
    func testSaveAndRunSavedMacroUseWorkspaceStoreAndFuzzyRows() async throws {
        let workspace = try makeWorkspace()
        let events = EventBox()
        let controller = makeController(
            workspace: { workspace },
            dispatchCommand: { command in
                events.values.append(command.rawValue)
                return true
            }
        )
        controller.toggleRecording()
        controller.record(command: .moveLineDown)
        controller.toggleRecording()
        controller.presentSaveMacro()

        XCTAssertEqual(controller.presentation, .saveName)
        XCTAssertTrue(controller.saveMacro(named: "  Move Down  "))
        XCTAssertEqual(controller.status, .saved(name: "Move Down"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".lumen-macros.json").path
        ))

        controller.presentSavedMacros(query: "md")
        XCTAssertEqual(controller.presentation, .savedMacros)
        XCTAssertEqual(controller.macroItems.map(\.label), ["Move Down"])
        let replayed = await controller.runSavedMacro(id: "Move Down")
        XCTAssertTrue(replayed)
        XCTAssertEqual(events.values, ["move-line-down"])
    }

    @MainActor
    func testSavedLegacySnapshotRunsBeforeTypedCommands() async throws {
        let workspace = try makeWorkspace()
        try MacroStore(workspaceURL: workspace).save(SavedMacro(
            name: "Legacy", commands: [.sortLines], text: "snapshot"
        ))
        let events = EventBox()
        let controller = makeController(
            workspace: { workspace },
            dispatchCommand: { command in
                events.values.append("command:\(command.rawValue)")
                return true
            },
            applyLegacyText: { text in
                events.values.append("text:\(text)")
                return true
            }
        )

        controller.presentSavedMacros()
        let replayed = await controller.runSavedMacro(id: "Legacy")
        XCTAssertTrue(replayed)
        XCTAssertEqual(events.values, ["text:snapshot", "command:sort-lines"])
    }

    @MainActor
    func testSnippetPickerMergesSourcesFuzzyFiltersAndAppliesOnePlan() throws {
        let plans = PlanBox()
        let controller = makeController(
            applyTransaction: { transaction in plans.values.append(transaction); return true },
            documentSnapshot: { SnippetDocumentSnapshot(
                documentID: "doc", text: "abc", selection: .cursor(at: 1), revision: 9
            ) },
            planSnippet: { template in
                try SnippetEngine.insertionPlan(
                    template: template, documentUTF16Length: 3,
                    selection: .cursor(at: 1), expectedRevision: 9
                )
            },
            projectSnippets: { [
                ProjectSnippet(label: "Swift log", text: "print(${1:value})")
            ] },
            pluginSnippets: { [
                pluginSnippet(label: "Guard", text: "guard ${1} else {}")
            ] }
        )

        controller.presentSnippets(query: "guard")
        XCTAssertEqual(controller.snippetItems.map(\.label), ["Fixture: Guard"])
        let id = try XCTUnwrap(controller.snippetItems.first?.id)
        XCTAssertTrue(controller.insertSnippet(id: id))
        XCTAssertEqual(plans.values.count, 1)
        XCTAssertEqual(plans.values[0].expectedRevision, 9)
        XCTAssertEqual(plans.values[0].edits.count, 1)
        XCTAssertNil(controller.presentation)
    }

    @MainActor
    func testTriggerExpansionUsesPluginBeforeProjectAndExactScope() {
        let templates = StringBox()
        let controller = makeController(
            applyTransaction: { _ in true },
            documentSnapshot: { SnippetDocumentSnapshot(
                documentID: "doc", text: "log", selection: .cursor(at: 3), revision: 0
            ) },
            planTriggerSnippet: { trigger, template in
                XCTAssertEqual(trigger, "log")
                templates.values.append(template)
                return try SnippetEngine.triggerExpansionPlan(
                    trigger: trigger, template: template,
                    documentText: "log", cursor: 3
                )
            },
            projectSnippets: { [
                ProjectSnippet(label: "Project", text: "project", trigger: "log")
            ] },
            pluginSnippets: { [
                pluginSnippet(
                    label: "Plugin", text: "plugin", trigger: "log", scope: "Swift"
                )
            ] },
            currentLanguage: { "Swift" }
        )

        XCTAssertTrue(controller.expandTrigger("log"))
        XCTAssertEqual(templates.values, ["plugin"])
        XCTAssertFalse(controller.expandTrigger("missing"))
    }

    @MainActor
    func testForwardTabDiscoversTriggerButBacktabDoesNot() {
        let templates = StringBox()
        let controller = makeController(
            applyTransaction: { _ in true },
            documentSnapshot: { SnippetDocumentSnapshot(
                documentID: "doc", text: "log", selection: .cursor(at: 3), revision: 0
            ) },
            planTriggerSnippet: { trigger, template in
                templates.values.append(trigger)
                return try SnippetEngine.triggerExpansionPlan(
                    trigger: trigger, template: template,
                    documentText: "log", cursor: 3
                )
            },
            projectSnippets: { [
                ProjectSnippet(label: "Log", text: "print($0)", trigger: "log")
            ] }
        )

        XCTAssertFalse(controller.navigateSnippetPlaceholder(.previous))
        XCTAssertTrue(controller.navigateSnippetPlaceholder(.next))
        XCTAssertEqual(templates.values, ["log"])
    }

    @MainActor
    func testPlaceholderSessionNavigatesAndCancelsOnDocumentChange() throws {
        let state = EditorStateBox(
            documentID: "doc", text: "", selection: .cursor(at: 0), revision: 0
        )
        let controller = makeController(
            applyTransaction: state.apply,
            documentSnapshot: state.snapshot,
            applySelection: state.select
        )
        controller.presentSnippets(query: "function")
        let functionID = try XCTUnwrap(controller.snippetItems.first?.id)
        XCTAssertTrue(controller.insertSnippet(id: functionID))
        XCTAssertTrue(controller.hasActiveSnippetSession)
        XCTAssertEqual(state.selection, .single(anchor: 9, head: 13))
        XCTAssertTrue(controller.navigateSnippetPlaceholder(.previous))
        XCTAssertEqual(state.selection, .single(anchor: 14, head: 18))
        XCTAssertTrue(controller.navigateSnippetPlaceholder(.previous))
        XCTAssertEqual(state.selection, .single(anchor: 9, head: 13))

        XCTAssertTrue(controller.navigateSnippetPlaceholder(.next))
        XCTAssertEqual(state.selection, .single(anchor: 14, head: 18))
        XCTAssertTrue(controller.navigateSnippetPlaceholder(.next))
        XCTAssertFalse(controller.hasActiveSnippetSession)
        XCTAssertEqual(state.selection, .cursor(at: 24))

        controller.presentSnippets(query: "function")
        XCTAssertTrue(controller.insertSnippet(id: functionID))
        controller.activeEditorDidChange(
            documentID: "doc", viewID: "other-pane", revision: state.revision
        )
        XCTAssertFalse(controller.hasActiveSnippetSession)
        XCTAssertFalse(controller.navigateSnippetPlaceholder(.next))
        XCTAssertFalse(controller.cancelSnippetSession())

        controller.presentSnippets(query: "function")
        XCTAssertTrue(controller.insertSnippet(id: functionID))
        XCTAssertTrue(controller.cancelSnippetSession())
        XCTAssertFalse(controller.cancelSnippetSession())
    }

    @MainActor
    func testPlaceholderSessionCancelsOnUnobservedRevisionChange() throws {
        let state = EditorStateBox(
            documentID: "doc", text: "", selection: .cursor(at: 0), revision: 0
        )
        let controller = makeController(
            applyTransaction: state.apply, documentSnapshot: state.snapshot,
            applySelection: state.select
        )
        controller.presentSnippets(query: "function")
        let id = try XCTUnwrap(controller.snippetItems.first?.id)
        XCTAssertTrue(controller.insertSnippet(id: id))
        XCTAssertTrue(controller.hasActiveSnippetSession)

        controller.activeEditorDidChange(
            documentID: "doc", viewID: .default, revision: state.revision + 1
        )
        XCTAssertFalse(controller.hasActiveSnippetSession)
    }

    @MainActor
    func testEditingFromAnotherPaneAppliesButEndsSnippetSession() throws {
        let state = EditorStateBox(
            documentID: "doc", text: "", selection: .cursor(at: 0), revision: 0
        )
        let controller = makeController(
            applyTransaction: state.apply, documentSnapshot: state.snapshot,
            applySelection: state.select
        )
        controller.presentSnippets(query: "function")
        let id = try XCTUnwrap(controller.snippetItems.first?.id)
        XCTAssertTrue(controller.insertSnippet(id: id))
        state.documentID = "other"

        XCTAssertTrue(controller.applyAndRecord(try TextTransaction(
            edits: [TextEdit(from: 0, to: 0, insert: "x")],
            expectedRevision: state.revision
        )))
        XCTAssertFalse(controller.hasActiveSnippetSession)
        XCTAssertNil(controller.snippetInsertion)
    }

    @MainActor
    func testApplyAndRecordMirrorsRepeatedPlaceholderInOneTransaction() throws {
        let state = EditorStateBox(
            documentID: "doc", text: "", selection: .cursor(at: 0), revision: 0
        )
        let controller = makeController(
            applyTransaction: state.apply,
            documentSnapshot: state.snapshot,
            applySelection: state.select,
            planSnippet: { _ in
                try SnippetEngine.insertionPlan(
                    template: "${1:foo} + ${1:foo}${0}",
                    documentUTF16Length: state.text.utf16.count,
                    selection: state.selection, expectedRevision: state.revision
                )
            },
            projectSnippets: { [ProjectSnippet(label: "Mirror", text: "unused")] }
        )
        controller.toggleRecording()
        controller.presentSnippets(query: "mirror")
        let id = try XCTUnwrap(controller.snippetItems.first?.id)
        XCTAssertTrue(controller.insertSnippet(id: id))
        XCTAssertEqual(state.text, "foo + foo")
        XCTAssertEqual(state.applyCount, 1)
        XCTAssertEqual(state.selection, .single(anchor: 0, head: 3))

        let edit = try TextTransaction(
            edits: [TextEdit(from: 0, to: 3, insert: "bar")],
            selection: .cursor(at: 3), expectedRevision: state.revision
        )
        XCTAssertTrue(controller.applyAndRecord(edit))
        XCTAssertEqual(state.text, "bar + bar")
        XCTAssertEqual(state.applyCount, 2, "mirror must be folded into the user transaction")
        XCTAssertEqual(controller.recordedSteps.count, 2)
        XCTAssertEqual(controller.recordedSteps.last?.edits?.count, 2)
    }

    @MainActor
    func testFailedMirroredTransactionDoesNotCommitMappedSession() throws {
        let state = EditorStateBox(
            documentID: "doc", text: "", selection: .cursor(at: 0), revision: 0
        )
        var rejectNext = false
        let controller = makeController(
            applyTransaction: { transaction in
                if rejectNext { rejectNext = false; return false }
                return state.apply(transaction)
            },
            documentSnapshot: state.snapshot,
            applySelection: state.select,
            planSnippet: { _ in
                try SnippetEngine.insertionPlan(
                    template: "${1:foo} + ${1:foo}${0}",
                    documentUTF16Length: state.text.utf16.count,
                    selection: state.selection, expectedRevision: state.revision
                )
            },
            projectSnippets: { [ProjectSnippet(label: "Mirror", text: "unused")] }
        )
        controller.presentSnippets(query: "mirror")
        let id = try XCTUnwrap(controller.snippetItems.first?.id)
        XCTAssertTrue(controller.insertSnippet(id: id))
        rejectNext = true
        XCTAssertFalse(controller.applyAndRecord(try TextTransaction(
            edits: [TextEdit(from: 0, to: 3, insert: "bar")],
            selection: .cursor(at: 3), expectedRevision: state.revision
        )))
        XCTAssertEqual(state.text, "foo + foo")
        XCTAssertEqual(controller.activeSnippetPlaceholder?.range, NSRange(location: 0, length: 3))
    }

    @MainActor
    func testRoutedCommandObserverRecordsOnlyOutermostSupportedCommand() {
        let controller = makeController()
        controller.toggleRecording()
        controller.observeRoutedCommand("save", observation: .began)
        controller.observeRoutedCommand("delete-line", observation: .began)
        controller.observeRoutedCommand(
            "delete-line", observation: .finished(succeeded: true)
        )
        controller.observeRoutedCommand("save", observation: .finished(succeeded: true))
        controller.observeRoutedCommand("run-macro", observation: .began)
        controller.observeRoutedCommand(
            "run-macro", observation: .finished(succeeded: true)
        )
        controller.toggleRecording()

        XCTAssertEqual(controller.recordedSteps, [.command(.deleteLine)])
    }

    @MainActor
    func testRouterObserverPreventsReplayRecursionAndEditDuplication() async throws {
        let state = EditorStateBox(
            documentID: "doc", text: "x", selection: .cursor(at: 0), revision: 0
        )
        var controller: MacroSnippetController!
        controller = makeController(
            dispatchCommand: { command in
                controller.observeRoutedCommand(command.rawValue, observation: .began)
                let transaction = try! TextTransaction(edits: [
                    TextEdit(from: 0, to: 1, insert: "y")
                ], expectedRevision: state.revision)
                let applied = controller.applyAndRecord(transaction)
                controller.observeRoutedCommand(
                    command.rawValue, observation: .finished(succeeded: applied)
                )
                return applied
            },
            applyTransaction: state.apply,
            documentSnapshot: state.snapshot,
            applySelection: state.select
        )
        controller.toggleRecording()
        controller.observeRoutedCommand("delete-line", observation: .began)
        let commandTransaction = try TextTransaction(edits: [
            TextEdit(from: 0, to: 1, insert: "z")
        ], expectedRevision: state.revision)
        XCTAssertTrue(controller.applyAndRecord(commandTransaction))
        controller.observeRoutedCommand(
            "delete-line", observation: .finished(succeeded: true)
        )
        controller.toggleRecording()
        XCTAssertEqual(controller.recordedSteps, [.command(.deleteLine)])

        let replayed = await controller.runLastMacro()
        XCTAssertTrue(replayed)
        XCTAssertEqual(state.text, "y")
        XCTAssertEqual(controller.recordedSteps, [.command(.deleteLine)])
    }

    @MainActor
    func testRouterObserverSuppressesCommandGeneratedTransaction() throws {
        let controller = makeController()
        controller.toggleRecording()
        controller.observeRoutedCommand("delete-line", observation: .began)
        controller.record(transaction: try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "generated")
        ]))
        controller.observeRoutedCommand(
            "delete-line", observation: .finished(succeeded: true)
        )
        controller.toggleRecording()

        XCTAssertEqual(controller.recordedSteps, [.command(.deleteLine)])
    }

    @MainActor
    func testRouterRegistrationCoversFiveCommandsAndRollsBackPartials() async throws {
        let controller = makeController()
        let router = CommandRouter()
        let tokens = try controller.registerCommands(on: router)
        let document = CommandRoutingContext(hasDocument: true)

        XCTAssertEqual(tokens.map(\.commandID), MacroSnippetController.commandIDs)
        XCTAssertEqual(router.status(for: "record-macro", context: document), .enabled)
        XCTAssertEqual(
            router.status(for: "save-macro", context: document),
            .disabled(.missingRequirements(.workspace))
        )
        let routed = await router.execute("record-macro", context: document)
        XCTAssertTrue(routed.didExecuteSuccessfully)
        XCTAssertTrue(controller.isRecording)

        let conflicted = CommandRouter()
        _ = try conflicted.register("run-macro") { _ in }
        XCTAssertThrowsError(try controller.registerCommands(on: conflicted))
        XCTAssertEqual(
            conflicted.status(for: "record-macro", context: document), .unsupported
        )
        XCTAssertEqual(
            conflicted.status(for: "run-macro", context: document), .enabled
        )
    }

    @MainActor
    private func makeController(
        workspace: @escaping MacroSnippetController.WorkspaceProvider = { nil },
        dispatchCommand: @escaping MacroSnippetController.CommandDispatcher = { _ in true },
        applyTransaction: @escaping MacroSnippetController.TransactionApplier = { _ in true },
        documentSnapshot: @escaping MacroSnippetController.DocumentSnapshotProvider = { nil },
        applySelection: @escaping MacroSnippetController.SelectionApplier = { _ in true },
        applyLegacyText: MacroSnippetController.LegacyTextApplier? = nil,
        planSnippet: @escaping MacroSnippetController.SnippetPlanner = { template in
            try SnippetEngine.insertionPlan(
                template: template, documentUTF16Length: 0, selection: .cursor(at: 0)
            )
        },
        planTriggerSnippet: MacroSnippetController.TriggerSnippetPlanner? = nil,
        projectSnippets: @escaping MacroSnippetController.ProjectSnippetsProvider = { [] },
        pluginSnippets: @escaping MacroSnippetController.PluginSnippetsProvider = { [] },
        currentLanguage: @escaping MacroSnippetController.LanguageProvider = { nil }
    ) -> MacroSnippetController {
        MacroSnippetController(
            workspace: workspace,
            dispatchCommand: dispatchCommand, applyTransaction: applyTransaction,
            documentSnapshot: documentSnapshot, applySelection: applySelection,
            applyLegacyText: applyLegacyText, planSnippet: planSnippet,
            planTriggerSnippet: planTriggerSnippet,
            projectSnippets: projectSnippets, pluginSnippets: pluginSnippets,
            currentLanguage: currentLanguage
        )
    }

    private func makeWorkspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacroSnippetControllerTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory.standardizedFileURL
    }
}

@MainActor
private func pluginSnippet(
    label: String, text: String, trigger: String? = nil, scope: String? = nil
) -> PluginSnippetRoute {
    var snippet: [String: Any] = ["label": label, "text": text]
    if let trigger { snippet["trigger"] = trigger }
    if let scope { snippet["scope"] = scope }
    let data = try! JSONSerialization.data(withJSONObject: [
        "id": "fixture", "name": "Fixture",
        "version": "1.0.0", "snippets": [snippet]
    ])
    let manifest = try! PluginManifest.parse(data)
    let plugin = InstalledPlugin(
        manifest: manifest, directoryURL: URL(fileURLWithPath: "/fixture"),
        isEnabled: true, grantedPermissions: [], effectivePermissions: [],
        workerExecutionSupport: .unsupported
    )
    return PluginSnippetRoute(
        plugin: plugin, contribution: manifest.snippets[0], index: 0
    )
}

@MainActor private final class EventBox { var values: [String] = [] }
@MainActor private final class StringBox { var values: [String] = [] }
@MainActor private final class PlanBox { var values: [TextTransaction] = [] }

@MainActor
private final class EditorStateBox {
    var documentID: String
    var text: String
    var selection: SelectionSet
    var revision: UInt64
    var applyCount = 0

    init(documentID: String, text: String, selection: SelectionSet, revision: UInt64) {
        self.documentID = documentID
        self.text = text
        self.selection = selection
        self.revision = revision
    }

    func snapshot() -> SnippetDocumentSnapshot? {
        SnippetDocumentSnapshot(
            documentID: documentID, text: text, selection: selection, revision: revision
        )
    }

    func apply(_ transaction: TextTransaction) -> Bool {
        guard transaction.expectedRevision == nil || transaction.expectedRevision == revision,
              let next = try? transaction.applying(to: text) else { return false }
        text = next
        if let nextSelection = transaction.selection { selection = nextSelection }
        revision += 1
        applyCount += 1
        return true
    }

    func select(_ selection: SelectionSet) -> Bool {
        guard selection.isValid(forUTF16Length: text.utf16.count) else { return false }
        self.selection = selection
        return true
    }
}
