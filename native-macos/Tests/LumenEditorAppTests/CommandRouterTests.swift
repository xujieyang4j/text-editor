import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class CommandRouterTests: XCTestCase {
    @MainActor
    func testCatalogCommandsAreUnsupportedUntilAHandlerIsRegistered() async {
        let router = CommandRouter()
        let context = CommandRoutingContext()

        XCTAssertEqual(CommandCatalog.all.count, 169)
        XCTAssertTrue(
            CommandCatalog.all.allSatisfy {
                router.status(for: $0.id, context: context) == .unsupported
            }
        )
        XCTAssertNil(router.status(for: "not-a-command", context: context))

        let result = await router.execute("save", context: context)
        guard case .unavailable(.unsupported) = result else {
            return XCTFail("An unregistered command must not report success")
        }
        XCTAssertFalse(result.didExecuteSuccessfully)
    }

    @MainActor
    func testRequirementsAreCheckedBeforeExecution() async throws {
        let router = CommandRouter()
        var executionCount = 0
        _ = try router.register("save") { invocation in
            XCTAssertEqual(invocation.command.id, "save")
            executionCount += 1
        }

        XCTAssertEqual(
            router.status(for: "save", context: CommandRoutingContext()),
            .disabled(.missingRequirements(.document))
        )
        let unavailable = await router.execute("save", context: CommandRoutingContext())
        guard case let .unavailable(.disabled(.missingRequirements(missing))) = unavailable else {
            return XCTFail("Missing document state should disable Save")
        }
        XCTAssertEqual(missing, .document)
        XCTAssertEqual(executionCount, 0)

        let documentContext = CommandRoutingContext(hasDocument: true)
        XCTAssertEqual(router.status(for: "save", context: documentContext), .enabled)
        let executed = await router.execute("save", context: documentContext)
        XCTAssertTrue(executed.didExecuteSuccessfully)
        XCTAssertEqual(executionCount, 1)
    }

    @MainActor
    func testSavedDocumentContextAlsoProvidesDocumentRequirement() async throws {
        let router = CommandRouter()
        _ = try router.register("reopen-with-encoding") { _ in }

        XCTAssertEqual(
            router.status(
                for: "reopen-with-encoding",
                context: CommandRoutingContext(hasSavedDocument: true)
            ),
            .enabled
        )
    }

    @MainActor
    func testHandlerEnablementAndThrownFailureNeverReportSuccess() async throws {
        struct SampleFailure: Error {}

        let router = CommandRouter()
        var handlerWasCalled = false
        _ = try router.register(
            "toggle-sidebar",
            enablement: { _ in .disabled(reason: "Transition in progress") }
        ) { _ in
            handlerWasCalled = true
        }

        let disabled = await router.execute(
            "toggle-sidebar",
            context: CommandRoutingContext()
        )
        guard case let .unavailable(.disabled(.handler(reason))) = disabled else {
            return XCTFail("Handler enablement should be preserved")
        }
        XCTAssertEqual(reason, "Transition in progress")
        XCTAssertFalse(handlerWasCalled)

        _ = try router.register("toggle-sidebar", replaceExisting: true) { _ in
            throw SampleFailure()
        }
        let failed = await router.execute(
            "toggle-sidebar",
            context: CommandRoutingContext()
        )
        guard case let .failed(commandID, error) = failed else {
            return XCTFail("A thrown handler must report failure")
        }
        XCTAssertEqual(commandID, "toggle-sidebar")
        XCTAssertTrue(error is SampleFailure)
        XCTAssertFalse(failed.didExecuteSuccessfully)
    }

    @MainActor
    func testTypedFailurePreservesPresentationPayloadThroughRouter() async throws {
        let expected = WorkspacePresentationIssue.Message.workspaceError(
            .tooManyRoots(maximum: 3), context: "second-root"
        )
        let router = CommandRouter()
        _ = try router.register("toggle-sidebar") { _ in
            throw CommandHandlerSignal.failed(.workspace(expected))
        }

        let result = await router.execute(
            "toggle-sidebar", context: CommandRoutingContext()
        )

        guard case let .failed(commandID, error) = result,
              let signal = error as? CommandHandlerSignal,
              case let .failedPresentation(presentation) = signal else {
            return XCTFail("Expected the typed command failure to reach the router")
        }
        XCTAssertEqual(commandID, "toggle-sidebar")
        XCTAssertEqual(presentation, .workspace(expected))
    }

    @MainActor
    func testNoChangeSignalIsTypedAndObserverSeesFailure() async throws {
        let router = CommandRouter()
        var observations: [CommandExecutionObservation] = []
        router.setExecutionObserver { commandID, observation in
            XCTAssertEqual(commandID, "toggle-sidebar")
            observations.append(observation)
        }
        _ = try router.register("toggle-sidebar") { _ in
            throw CommandHandlerSignal.noChange
        }

        let result = await router.execute(
            "toggle-sidebar", context: CommandRoutingContext()
        )

        guard case .noChange(commandID: "toggle-sidebar") = result else {
            return XCTFail("Expected a typed no-change result")
        }
        XCTAssertFalse(result.didExecuteSuccessfully)
        XCTAssertEqual(observations, [.began, .finished(succeeded: false)])
    }

    @MainActor
    func testVisiblePanelSignalIsTypedAndCountsAsSuccessfulExecution() async throws {
        let router = CommandRouter()
        var observations: [CommandExecutionObservation] = []
        router.setExecutionObserver { commandID, observation in
            XCTAssertEqual(commandID, "toggle-sidebar")
            observations.append(observation)
        }
        _ = try router.register("toggle-sidebar") { _ in
            throw CommandHandlerSignal.visiblePanel
        }

        let result = await router.execute(
            "toggle-sidebar", context: CommandRoutingContext()
        )

        guard case .visiblePanel(commandID: "toggle-sidebar") = result else {
            return XCTFail("Expected a typed visible-panel result")
        }
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertEqual(observations, [.began, .finished(succeeded: true)])
    }

    @MainActor
    func testObserverSkipsPreflightRejectionAndReportsSuccessfulCompletion() async throws {
        let router = CommandRouter()
        var observations: [CommandExecutionObservation] = []
        router.setExecutionObserver { commandID, observation in
            XCTAssertEqual(commandID, "save")
            observations.append(observation)
        }
        _ = try router.register("save") { _ in }

        let unavailable = await router.execute(
            "save", context: CommandRoutingContext()
        )
        guard case .unavailable = unavailable else {
            return XCTFail("Missing requirements must reject before observation")
        }
        XCTAssertEqual(observations, [])

        let executed = await router.execute(
            "save", context: CommandRoutingContext(hasDocument: true)
        )
        XCTAssertTrue(executed.didExecuteSuccessfully)
        XCTAssertEqual(observations, [.began, .finished(succeeded: true)])
    }

    @MainActor
    func testRegistrationRejectsUnknownAndDuplicateRoutesAndTokensAreOwnershipSafe() async throws {
        let router = CommandRouter()

        XCTAssertThrowsError(try router.register("missing-command") { _ in }) { error in
            XCTAssertEqual(
                error as? CommandRegistrationError,
                .unknownCommand("missing-command")
            )
        }

        let oldToken = try router.register("new-file") { _ in }
        XCTAssertThrowsError(try router.register("new-file") { _ in }) { error in
            XCTAssertEqual(
                error as? CommandRegistrationError,
                .alreadyRegistered("new-file")
            )
        }

        let newToken = try router.register("new-file", replaceExisting: true) { _ in }
        XCTAssertFalse(router.unregister(oldToken))
        XCTAssertEqual(
            router.status(for: "new-file", context: CommandRoutingContext()),
            .enabled
        )
        XCTAssertTrue(router.unregister(newToken))
        XCTAssertEqual(
            router.status(for: "new-file", context: CommandRoutingContext()),
            .unsupported
        )
    }

    @MainActor
    func testSearchIsLocalizedFuzzyAndReflectsStatusAndOverrides() async throws {
        let chord = CommandKeyBinding(sequence: [
            CommandKeyEquivalent(key: "k", modifiers: .command),
            CommandKeyEquivalent(key: "s", modifiers: .command)
        ])
        let router = CommandRouter(keyBindingOverrides: [
            KeyBindingOverride(commandID: "save", binding: chord, when: .editor)
        ])
        _ = try router.register("save") { _ in }

        let results = router.search(
            "保存",
            locale: .simplifiedChinese,
            context: CommandRoutingContext(hasDocument: true)
        )
        let save = try XCTUnwrap(results.first(where: { $0.id == "save" }))
        XCTAssertEqual(save.command.title(for: .simplifiedChinese), "文件：保存")
        XCTAssertEqual(save.status, .enabled)
        XCTAssertEqual(save.effectiveKeyBinding, chord)
        XCTAssertEqual(save.shortcutHint, "⌘K ⌘S")
        XCTAssertFalse(save.fuzzyResult.matches.isEmpty)

        let unsupported = try XCTUnwrap(
            results.first(where: { $0.id != "save" })
        )
        XCTAssertEqual(unsupported.status, .unsupported)
    }

    @MainActor
    func testExplicitUnbindHidesShortcutHint() async throws {
        let router = CommandRouter(keyBindingOverrides: [
            .unbind("save", when: .editor)
        ])
        let result = try XCTUnwrap(
            router.search(
                "save",
                locale: .english,
                context: CommandRoutingContext(hasDocument: true)
            ).first(where: { $0.id == "save" })
        )
        XCTAssertNil(result.effectiveKeyBinding)
        XCTAssertNil(result.shortcutHint)
    }

    func testKeyboardChordCompletesWithinOnePointFiveSeconds() {
        let chord = CommandKeyBinding(sequence: [
            CommandKeyEquivalent(key: "k", modifiers: .command),
            CommandKeyEquivalent(key: "s", modifiers: .command)
        ])
        var state = CommandKeyboardState(overrides: [
            KeyBindingOverride(commandID: "save", binding: chord, when: .editor)
        ])

        XCTAssertEqual(
            state.process(
                CommandKeyEquivalent(key: "K", modifiers: .command),
                at: 10,
                context: .editor
            ),
            .awaitingChord(
                sequence: [CommandKeyEquivalent(key: "k", modifiers: .command)],
                deadline: 11.5
            )
        )
        XCTAssertEqual(state.pendingDisplayString, "⌘K")
        XCTAssertEqual(
            state.process(
                CommandKeyEquivalent(key: "s", modifiers: .command),
                at: 11.49,
                context: .editor
            ),
            .command("save")
        )
        XCTAssertFalse(state.isAwaitingChord)
        XCTAssertNil(state.deadline)
    }

    func testKeyboardChordExpiresAndDoesNotExecuteStaleSequence() {
        let chord = CommandKeyBinding(sequence: [
            CommandKeyEquivalent(key: "k", modifiers: .command),
            CommandKeyEquivalent(key: "s", modifiers: .command)
        ])
        var state = CommandKeyboardState(overrides: [
            KeyBindingOverride(commandID: "save", binding: chord, when: .editor)
        ])

        _ = state.process(
            CommandKeyEquivalent(key: "k", modifiers: .command),
            at: 5,
            context: .editor
        )
        XCTAssertEqual(
            state.process(
                CommandKeyEquivalent(key: "s", modifiers: .command),
                at: 6.5,
                context: .editor
            ),
            .noMatch
        )
        XCTAssertFalse(state.isAwaitingChord)
    }

    func testKeyboardOverridesRespectContextUnbindAndCatalogFallback() {
        let overrides = [KeyBindingOverride.unbind("save", when: .editor)]
        var state = CommandKeyboardState(overrides: overrides)
        let commandS = CommandKeyEquivalent(key: "s", modifiers: .command)

        XCTAssertEqual(state.process(commandS, at: 1, context: .editor), .noMatch)
        XCTAssertEqual(
            state.process(commandS, at: 2, context: .git),
            .command("save")
        )
    }

    func testKeyboardConflictIsReportedAsAmbiguousInsteadOfExecutingArbitrarily() {
        let chord = CommandKeyBinding(sequence: [
            CommandKeyEquivalent(key: "k", modifiers: .command),
            CommandKeyEquivalent(key: "x", modifiers: .command)
        ])
        var state = CommandKeyboardState(overrides: [
            KeyBindingOverride(commandID: "save", binding: chord),
            KeyBindingOverride(commandID: "new-file", binding: chord)
        ])

        _ = state.process(
            CommandKeyEquivalent(key: "k", modifiers: .command),
            at: 20
        )
        XCTAssertEqual(
            state.process(
                CommandKeyEquivalent(key: "x", modifiers: .command),
                at: 21
            ),
            .ambiguous(["new-file", "save"])
        )
        XCTAssertFalse(state.isAwaitingChord)
    }

    func testDefaultF2ConflictIsDeferredForRouteStatusResolution() {
        let f2 = CommandKeyEquivalent(key: "f2")
        var state = CommandKeyboardState()

        XCTAssertEqual(
            state.process(f2, at: 1),
            .defaultConflict(["next-bookmark", "lsp-rename"])
        )
    }

    @MainActor
    func testDefaultF2UsesEnabledLSPRouteOtherwiseFallsBackToBookmark() async throws {
        let router = CommandRouter()
        _ = try router.register("next-bookmark") { _ in }
        _ = try router.register(
            "lsp-rename",
            enablement: { _ in
                .disabled(reason: "No language server is configured for this document.")
            }
        ) { _ in }
        let context = CommandRoutingContext(
            availableRequirements: [
                .document, .savedDocument, .workspace, .languageService
            ]
        )
        let controller = CommandKeyboardController(
            router: router, context: { context }
        )
        let defaultConflict = ["next-bookmark", "lsp-rename"]

        // A different document may have a running server, so the window-wide
        // requirement is present even though rename is disabled for this one.
        XCTAssertEqual(
            controller.resolveDefaultConflict(defaultConflict, context: context),
            "next-bookmark"
        )

        _ = try router.register("lsp-rename", replaceExisting: true) { _ in }
        XCTAssertEqual(
            controller.resolveDefaultConflict(defaultConflict, context: context),
            "lsp-rename"
        )
    }

    func testExplicitF2OverrideRetainsAmbiguityDetection() {
        let f2 = CommandKeyBinding(CommandKeyEquivalent(key: "f2"))
        var state = CommandKeyboardState(overrides: [
            KeyBindingOverride(commandID: "next-bookmark", binding: f2),
            KeyBindingOverride(commandID: "lsp-rename", binding: f2)
        ])

        XCTAssertEqual(
            state.process(
                CommandKeyEquivalent(key: "f2"), at: 1
            ),
            .ambiguous(["next-bookmark", "lsp-rename"])
        )
    }
}
