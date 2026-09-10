import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

private enum BuildPersistenceTestError: Error { case failed }

@MainActor
final class BuildControllerTests: XCTestCase {
    func testInvalidPrimaryCommandReportsTypedFailure() async {
        let controller = BuildController(workspaceRoot: root)
        controller.synchronizeFreeFormCommand("")

        let outcome = await controller.runPrimaryAction()

        guard case let .failed(message) = outcome else {
            return XCTFail("An invalid build request must report failure")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotNil(controller.issue)
    }

    func testPrimaryCommandReportsAwaitingApproval() async {
        let controller = BuildController(workspaceRoot: root)
        controller.synchronizeFreeFormCommand("swift test")

        let outcome = await controller.runPrimaryAction()

        XCTAssertEqual(outcome, .awaitingApproval)
        XCTAssertTrue(outcome.wasAccepted)
        XCTAssertNotNil(controller.pendingApproval)
        XCTAssertFalse(controller.isRunning)
    }

    func testFreeFormCommandBindingHydratesAndEditingRemainsAnInMemoryDraft() {
        let controller = BuildController(workspaceRoot: root)
        var persisted: [String] = []
        controller.bindFreeFormCommand(
            initialValue: "swift test",
            persistApprovedCommand: { persisted.append($0.executable) }
        )

        XCTAssertEqual(controller.freeFormCommand, "swift test")
        XCTAssertTrue(persisted.isEmpty, "Startup hydration must not write settings back")

        controller.freeFormCommand = "swift build"
        XCTAssertTrue(persisted.isEmpty, "Typing must not persist an incomplete command")

        controller.freeFormCommand = String(repeating: "x", count: 1_001)
        XCTAssertEqual(controller.freeFormCommand.utf16.count, 1_000)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testProgrammaticBuildCommandSynchronizationDoesNotWriteBack() {
        let controller = BuildController(workspaceRoot: root)
        var persisted: [String] = []
        controller.bindFreeFormCommand(initialValue: "global") { configuration in
            persisted.append(configuration.executable)
        }

        controller.synchronizeFreeFormCommand("project override")

        XCTAssertEqual(controller.freeFormCommand, "project override")
        XCTAssertTrue(persisted.isEmpty)
    }

    func testSelectingBuildSystemUpdatesPanelWithoutPersistingFreeFormCommand() throws {
        let controller = BuildController(workspaceRoot: root)
        var persisted: [String] = []
        controller.bindFreeFormCommand(initialValue: "global") { configuration in
            persisted.append(configuration.executable)
        }
        let system = try BuildSystem(name: "Swift", command: "swift")

        controller.selectBuildSystem(system)

        XCTAssertEqual(controller.freeFormCommand, "swift")
        XCTAssertTrue(persisted.isEmpty)
    }

    func testProjectCommandTemporarilyOverridesGlobalAndClearingRestoresIt() {
        let controller = BuildController(workspaceRoot: root)
        var persisted: [String] = []
        controller.bindFreeFormCommand(initialValue: "global") { configuration in
            persisted.append(configuration.executable)
        }

        controller.synchronizeProjectBuildCommand("project")
        XCTAssertEqual(controller.freeFormCommand, "project")
        controller.freeFormCommand = "draft command"
        controller.synchronizePersistedFreeFormCommand("new global")
        XCTAssertEqual(controller.freeFormCommand, "draft command")
        controller.synchronizeProjectBuildCommand("")

        XCTAssertEqual(controller.freeFormCommand, "new global")
        XCTAssertTrue(persisted.isEmpty)
    }

    func testSelectedBuildSystemAndVariantPersistUntilRun() async throws {
        let root = FileManager.default.temporaryDirectory
        let variant = try BuildVariant(name: "Release", command: "swift", arguments: ["build"])
        let system = try BuildSystem(
            name: "Tests", command: "swift", arguments: ["test"], variants: [variant]
        )
        let controller = BuildController(workspaceRoot: root)

        controller.selectBuildSystem(system, variantName: "Release")

        XCTAssertEqual(controller.selectedBuildSystem, system)
        XCTAssertEqual(controller.selectedBuildVariantName, "Release")
        XCTAssertEqual(controller.freeFormCommand, "swift")
    }

    func testBuildSystemPaletteFlattensBaseAndVariantsInElectronOrder() throws {
        let controller = BuildController(workspaceRoot: root)
        let swift = try BuildSystem(
            name: "Swift", command: "swift", arguments: ["build"], variants: [
                try BuildVariant(
                    name: "Release", arguments: ["build", "-c", "release"]
                )
            ]
        )
        let web = try BuildSystem(name: "Web", command: "npm", arguments: ["test"])

        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: [swift, web]))
        XCTAssertTrue(controller.isBuildSystemPalettePresented)
        XCTAssertEqual(
            controller.buildSystemPaletteItems.map(\.label),
            ["Swift", "Swift: Release", "Web"]
        )
        // Electron displays only the effective command in the secondary row.
        XCTAssertEqual(
            controller.buildSystemPaletteItems.map(\.detail),
            ["swift", "swift", "npm"]
        )
        XCTAssertEqual(controller.selectedBuildSystemPaletteIndex, 0)
    }

    func testBuildSystemPaletteKeepsDuplicateNamesAsDistinctRows() throws {
        let controller = BuildController(workspaceRoot: root)
        let first = try BuildSystem(name: "Build", command: "swift")
        let second = try BuildSystem(name: "Build", command: "xcrun")
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: [first, second]))

        XCTAssertEqual(
            controller.buildSystemPaletteItems.map { $0.label }, ["Build", "Build"]
        )
        XCTAssertNotEqual(
            controller.buildSystemPaletteItems[0].id,
            controller.buildSystemPaletteItems[1].id
        )
        controller.selectBuildSystemPaletteItem(at: 1)
        XCTAssertEqual(controller.selectedBuildSystemPaletteItem?.selection.system.command, "xcrun")
    }

    func testBuildSystemPaletteKeepsAllSanitizedVariants() throws {
        let variants = try (0 ..< BuildSystem.maximumVariants).map { index in
            try BuildVariant(name: "Variant " + String(index))
        }
        let systems = try (0 ..< ProjectSettingsSanitizer.maximumBuildSystems).map { index in
            try BuildSystem(
                name: "Build " + String(index), command: "swift", variants: variants
            )
        }

        let controller = BuildController(workspaceRoot: root)
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: systems))
        XCTAssertEqual(
            controller.buildSystemPaletteItems.count,
            ProjectSettingsSanitizer.maximumBuildSystems * (BuildSystem.maximumVariants + 1)
        )
    }

    func testBuildSystemPaletteUsesLabelFuzzySearchAndKeyboardWrap() throws {
        let controller = BuildController(workspaceRoot: root)
        let systems = [
            try BuildSystem(name: "Foo Bar", command: "opaque-command"),
            try BuildSystem(name: "Far Build", command: "other"),
            try BuildSystem(name: "Unrelated", command: "fb")
        ]
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: systems))

        controller.buildSystemQuery = "fb"
        XCTAssertEqual(
            controller.buildSystemPaletteItems.map(\.label),
            ["Foo Bar", "Far Build"]
        )
        XCTAssertEqual(controller.buildSystemPaletteItems.first?.matchedUTF16Offsets, [0, 4])
        XCTAssertEqual(controller.selectedBuildSystemPaletteIndex, 0)

        controller.moveBuildSystemPaletteSelection(by: -1)
        XCTAssertEqual(controller.selectedBuildSystemPaletteIndex, 1)
        controller.moveBuildSystemPaletteSelection(by: 1)
        XCTAssertEqual(controller.selectedBuildSystemPaletteIndex, 0)
    }

    func testBuildSystemPaletteBoundsUnicodeQueryWithoutSplittingScalar() throws {
        let controller = BuildController(workspaceRoot: root)
        let system = try BuildSystem(name: "Unicode", command: "swift")
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: [system]))

        controller.buildSystemQuery = String(repeating: "a", count: 255) + "😀tail"

        XCTAssertEqual(controller.buildSystemQuery.utf16.count, 255)
        XCTAssertFalse(controller.buildSystemQuery.contains("�"))
        XCTAssertTrue(controller.buildSystemPaletteItems.isEmpty)
        XCTAssertNil(controller.selectedBuildSystemPaletteIndex)
    }

    func testBuildSystemPaletteRejectsEmptySourceAndCapsConfiguredSystems() throws {
        let controller = BuildController(workspaceRoot: root)
        XCTAssertFalse(controller.presentBuildSystemPalette(buildSystems: []))
        XCTAssertFalse(controller.isBuildSystemPalettePresented)

        let systems = try (0 ..< ProjectSettingsSanitizer.maximumBuildSystems + 5).map { index in
            try BuildSystem(name: "Build \(index)", command: "swift")
        }
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: systems))
        XCTAssertEqual(
            controller.buildSystemPaletteItems.count,
            ProjectSettingsSanitizer.maximumBuildSystems
        )
    }

    func testBuildSystemPaletteRequiresWorkspace() throws {
        let controller = BuildController()
        XCTAssertFalse(controller.presentBuildSystemPalette(buildSystems: [
            try BuildSystem(name: "Swift", command: "swift")
        ]))
        XCTAssertFalse(controller.isBuildSystemPalettePresented)
    }

    func testWorkspaceChangeDismissesBuildSystemPalette() async throws {
        let controller = BuildController(workspaceRoot: root)
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: [
            try BuildSystem(name: "Swift", command: "swift")
        ]))

        await controller.updateWorkspaceRoot(
            URL(fileURLWithPath: "/tmp/lumen-build-controller-other", isDirectory: true)
        )

        XCTAssertFalse(controller.isBuildSystemPalettePresented)
        XCTAssertTrue(controller.buildSystemPaletteItems.isEmpty)
        XCTAssertNil(controller.selectedBuildSystemPaletteIndex)
    }

    func testAcceptingPaletteVariantSelectsAndRequestsApprovalBeforeExecution() async throws {
        let runner = BuildRunnerStub()
        let approvals = ToolApprovalStore()
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        let system = try BuildSystem(
            name: "Swift", command: "swift", arguments: ["test"], variants: [
                try BuildVariant(
                    name: "Release", command: "swift",
                    arguments: ["build", "-c", "release"]
                )
            ]
        )
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: [system]))

        let accepted = await controller.acceptBuildSystemPaletteItem(at: 1)
        XCTAssertTrue(accepted)

        XCTAssertFalse(controller.isBuildSystemPalettePresented)
        XCTAssertEqual(controller.selectedBuildSystem, system)
        XCTAssertEqual(controller.selectedBuildVariantName, "Release")
        XCTAssertEqual(controller.freeFormCommand, "swift")
        XCTAssertEqual(controller.pendingApproval?.configuration.kind, .buildSystem)
        XCTAssertEqual(
            controller.pendingApproval?.configuration.args,
            ["build", "-c", "release"]
        )
        XCTAssertFalse(controller.isRunning)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testAcceptingApprovedPaletteBuildRunsImmediately() async throws {
        let runner = BuildRunnerStub(results: [.finished(0)])
        let approvals = ToolApprovalStore()
        let system = try BuildSystem(
            name: "Swift", command: "swift", arguments: ["test"]
        )
        let configuration = try system.configuration(root: root).0
        _ = await approvals.approve(configuration, in: scope)
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: [system]))

        let accepted = await controller.acceptBuildSystemPaletteSelection()
        XCTAssertTrue(accepted)
        await controller.waitForCurrentBuild()

        XCTAssertNil(controller.pendingApproval)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(controller.exitCode, 0)
    }

    func testPrimaryBuildActionReusesSelectedSystemLikeElectron() async throws {
        let runner = BuildRunnerStub(results: [.finished(0), .finished(0)])
        let approvals = ToolApprovalStore()
        let system = try BuildSystem(
            name: "Swift", command: "swift", arguments: ["test"]
        )
        let configuration = try system.configuration(root: root).0
        _ = await approvals.approve(configuration, in: scope)
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        XCTAssertTrue(controller.presentBuildSystemPalette(buildSystems: [system]))
        let accepted = await controller.acceptBuildSystemPaletteSelection()
        XCTAssertTrue(accepted)
        await controller.waitForCurrentBuild()

        controller.freeFormCommand = "a command that must not run"
        await controller.runPrimaryAction()
        await controller.waitForCurrentBuild()

        let commands = await runner.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.map(\.arguments), [["test"], ["test"]])
    }

    func testPrimaryBuildActionRemainsAvailableToShowEmptyCommandError() throws {
        let controller = BuildController(workspaceRoot: root)
        XCTAssertTrue(controller.canRunPrimaryAction)
        controller.freeFormCommand = "swift test"
        XCTAssertTrue(controller.canRunPrimaryAction)
        controller.freeFormCommand = ""
        controller.selectBuildSystem(
            try BuildSystem(name: "Swift", command: "swift", arguments: ["test"])
        )
        XCTAssertTrue(controller.canRunPrimaryAction)
    }

    func testBuildSystemPaletteAccessibilityContract() {
        XCTAssertEqual(BuildSystemPaletteView.Accessibility.palette, "Build System Palette")
        XCTAssertEqual(BuildSystemPaletteView.Accessibility.query, "Build System Query")
        XCTAssertEqual(BuildSystemPaletteView.Accessibility.results, "Build System Results")
        XCTAssertEqual(
            BuildSystemPaletteView.Accessibility.itemID("system.0.variant.0"),
            "panel.buildSystem.item.system.0.variant.0"
        )
    }

    private let root = URL(fileURLWithPath: "/tmp/lumen-build-controller-tests", isDirectory: true)
    private let scope = ToolApprovalScope(windowID: "build-window", sessionID: "build-session")

    func testFreeFormCommandPersistsNormalizedValueOnlyWhenApprovedBuildStarts() async throws {
        let runner = BuildRunnerStub(results: [.finished(0)])
        let approvals = ToolApprovalStore()
        var persisted: [String] = []
        var persistedIdentity: ToolExecutionIdentity?
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        controller.bindFreeFormCommand(initialValue: "global") { configuration in
            XCTAssertEqual(
                configuration.root, self.root.standardizedFileURL.resolvingSymlinksInPath()
            )
            XCTAssertEqual(configuration.kind, .buildCommand)
            persisted.append(configuration.executable)
            persistedIdentity = configuration.identity
        }
        controller.freeFormCommand = "  swift test  "

        let outcome = await controller.requestFreeFormBuild()

        XCTAssertEqual(outcome, .awaitingApproval)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(controller.freeFormCommand, "swift test")
        let approvedIdentity = controller.pendingApproval?.configuration.identity

        await controller.confirmPendingBuild()
        await controller.waitForCurrentBuild()

        XCTAssertEqual(persisted, ["swift test"])
        XCTAssertEqual(persistedIdentity, approvedIdentity)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 1)
    }

    func testApprovedFreeFormCommandDoesNotRunWhenPersistenceFails() async throws {
        let runner = BuildRunnerStub()
        let approvals = ToolApprovalStore()
        let configuration = try ToolExecutionConfiguration(
            kind: .buildCommand, root: root, command: "swift test", shell: true
        )
        _ = await approvals.approve(configuration, in: scope)
        var persisted: [String] = []
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        controller.bindFreeFormCommand(initialValue: "global") { configuration in
            persisted.append(configuration.executable)
            throw BuildPersistenceTestError.failed
        }

        let outcome = await controller.requestFreeFormBuild(" swift test " )

        guard case .failed = outcome else {
            return XCTFail("A persistence failure must reject the build")
        }
        XCTAssertEqual(persisted, ["swift test"])
        XCTAssertEqual(controller.issue?.title, "Could Not Save Build Command")
        XCTAssertNil(controller.pendingApproval)
        XCTAssertFalse(controller.isRunning)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testNewlyConfirmedFreeFormCommandDoesNotRunWhenPersistenceFails() async {
        let runner = BuildRunnerStub()
        var persisted: [String] = []
        let controller = BuildController(
            workspaceRoot: root, runner: runner, scope: scope
        )
        controller.bindFreeFormCommand(initialValue: "global") { configuration in
            persisted.append(configuration.executable)
            throw BuildPersistenceTestError.failed
        }

        let requestOutcome = await controller.requestFreeFormBuild("  swift test  ")
        XCTAssertEqual(requestOutcome, .awaitingApproval)
        await controller.confirmPendingBuild()

        XCTAssertEqual(persisted, ["swift test"])
        XCTAssertNil(controller.pendingApproval)
        XCTAssertEqual(controller.issue?.title, "Could Not Save Build Command")
        XCTAssertFalse(controller.isRunning)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testDecliningFreeFormApprovalDoesNotPersistDraft() async {
        var persisted: [String] = []
        let controller = BuildController(workspaceRoot: root, scope: scope)
        controller.bindFreeFormCommand(initialValue: "global") { configuration in
            persisted.append(configuration.executable)
        }
        controller.freeFormCommand = "dangerous --partial"

        await controller.requestFreeFormBuild()
        controller.declinePendingBuild()

        XCTAssertTrue(persisted.isEmpty)
        XCTAssertNil(controller.pendingApproval)
    }

    func testOverlappingWorkspaceUpdatesCannotRestoreAnOlderRoot() async throws {
        let runner = BlockingCancellationBuildRunner()
        let approvals = ToolApprovalStore()
        let configuration = try ToolExecutionConfiguration(
            kind: .buildCommand, root: root, command: "swift test", shell: true
        )
        _ = await approvals.approve(configuration, in: scope)
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        let initialOutcome = await controller.requestFreeFormBuild("swift test")
        XCTAssertEqual(initialOutcome, .started)
        await runner.waitUntilStarted()

        let requestedRoot = URL(
            fileURLWithPath: "/tmp/lumen-build-requested", isDirectory: true
        )
        let olderUpdate = Task { @MainActor in
            await controller.updateWorkspaceRoot(requestedRoot)
        }
        await runner.waitUntilCancellationRequested()
        // Revert to the currently published root while the older B update is
        // suspended in cancellation. This no-op request must still invalidate B.
        await controller.updateWorkspaceRoot(root)
        await runner.releaseCancellation()
        await olderUpdate.value

        XCTAssertEqual(controller.workspaceRoot, root)
    }

    func testWorkspaceIsRequiredBeforeApprovalOrExecution() async {
        let runner = BuildRunnerStub()
        let controller = BuildController(runner: runner, scope: scope)

        await controller.requestFreeFormBuild("swift test")

        XCTAssertEqual(controller.issue?.title, "No Workspace Open")
        XCTAssertNil(controller.pendingApproval)
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testFirstExactIdentityRequiresConfirmationThenApprovalIsReused() async throws {
        let runner = BuildRunnerStub(results: [.finished(0), .finished(0)])
        let approvals = ToolApprovalStore()
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )

        await controller.requestFreeFormBuild("swift test")
        let pending = try XCTUnwrap(controller.pendingApproval)
        XCTAssertEqual(pending.configuration.kind, .buildCommand)
        XCTAssertTrue(pending.configuration.shell)
        XCTAssertEqual(
            pending.title(locale: .enUS), "Confirm free-form build command"
        )
        XCTAssertEqual(
            pending.title(locale: .zhCN), "确认自由构建命令"
        )
        let beforeConfirmation = await runner.runCount
        XCTAssertEqual(beforeConfirmation, 0)

        await controller.confirmPendingBuild()
        await controller.waitForCurrentBuild()
        let firstRunCount = await runner.runCount
        let approvalCount = await approvals.approvalCount(in: scope)
        XCTAssertEqual(firstRunCount, 1)
        XCTAssertEqual(approvalCount, 1)

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()
        XCTAssertNil(controller.pendingApproval)
        let secondRunCount = await runner.runCount
        XCTAssertEqual(secondRunCount, 2)
    }

    func testIdentityChangeRequiresAnotherConfirmation() async throws {
        let runner = BuildRunnerStub(results: [.finished(0)])
        let approvals = ToolApprovalStore()
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        await controller.requestFreeFormBuild("swift test")
        await controller.confirmPendingBuild()
        await controller.waitForCurrentBuild()

        await controller.requestFreeFormBuild("swift build")

        XCTAssertEqual(controller.pendingApproval?.configuration.executable, "swift build")
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 1)
    }

    func testApprovalPresentationEnumeratesCompleteIdentity() async throws {
        let runner = BuildRunnerStub()
        let controller = BuildController(
            workspaceRoot: root, runner: runner, scope: scope
        )
        let system = try BuildSystem(
            name: "Configured", command: "xcrun", arguments: ["swift", "test"],
            workingDirectory: "Sources", shell: false, environment: ["MODE": "debug"]
        )

        await controller.requestBuildSystem(system)
        let request = try XCTUnwrap(controller.pendingApproval)

        XCTAssertEqual(
            request.title(locale: .enUS),
            "Confirm build system ‘Configured’"
        )
        XCTAssertEqual(
            request.title(locale: .zhCN),
            "确认构建系统“Configured”"
        )

        XCTAssertTrue(request.identityDescription.contains("Purpose: build-system"))
        XCTAssertTrue(request.identityDescription.contains(root.path))
        XCTAssertTrue(request.identityDescription.contains("Working directory:"))
        XCTAssertTrue(request.identityDescription.contains("MODE=debug"))
        XCTAssertTrue(request.identityDescription.contains(request.configuration.identity.rawValue))
        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
    }

    func testBuildSystemRejectsMoreThanElectronVariantLimit() throws {
        let variants = try (0...BuildSystem.maximumVariants).map { index in
            try BuildVariant(name: "Variant \(index)")
        }

        XCTAssertThrowsError(try BuildSystem(
            name: "Too Many", command: "xcrun", variants: variants
        )) { error in
            XCTAssertEqual(
                error as? BuildConfigurationError,
                .tooManyVariants(maximum: BuildSystem.maximumVariants)
            )
        }
    }

    func testBuildSystemsRejectCatastrophicProblemRegexes() throws {
        for pattern in [#"^(a+)+$"#, #"^(a|aa)+$"#, #"^(a*){2,}$"#] {
            XCTAssertThrowsError(try BuildSystem(
                name: "Unsafe", command: "swift", fileRegex: pattern
            )) { error in
                XCTAssertEqual(error as? BuildConfigurationError, .unsafeFileRegex)
            }
        }

        // Mutating a value after initialization must not bypass validation at
        // the point where an execution configuration is created.
        var mutated = try BuildSystem(
            name: "Initially Safe", command: "swift",
            fileRegex: #"^([^:]+):(\d+):(\d+): (.*)$"#
        )
        mutated.fileRegex = #"^(a+)+$"#
        XCTAssertThrowsError(try mutated.configuration(root: root)) { error in
            XCTAssertEqual(error as? BuildConfigurationError, .unsafeFileRegex)
        }
    }

    func testStructuredVariantOverridesFieldsAndSavesBeforeExecution() async throws {
        let runner = BuildRunnerStub(results: [.finished(0)])
        let approvals = ToolApprovalStore()
        var saves = 0
        let variant = try BuildVariant(
            name: "Release", arguments: ["build", "-c", "release"],
            workingDirectory: "Sources", environment: ["MODE": "release"]
        )
        let system = try BuildSystem(
            name: "Swift", command: "xcrun", arguments: ["swift", "build"],
            saveBeforeBuild: true, variants: [variant]
        )
        let configuration = try system.configuration(
            for: "Release", root: root, resolver: .system
        ).0
        _ = await approvals.approve(configuration, in: scope)
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope,
            saveBeforeBuild: { saves += 1; return true }
        )

        await controller.requestBuildSystem(system, variantName: "Release")
        await controller.waitForCurrentBuild()

        XCTAssertEqual(saves, 1)
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["build", "-c", "release"])
        XCTAssertEqual(
            command.workingDirectoryURL,
            root.appendingPathComponent("Sources").standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(command.environment["MODE"], "release")
    }

    func testCancelledSaveDoesNotExecute() async throws {
        let runner = BuildRunnerStub()
        let approvals = ToolApprovalStore()
        let system = try BuildSystem(
            name: "Swift", command: "xcrun", arguments: ["swift"], saveBeforeBuild: true
        )
        let configuration = try system.configuration(root: root).0
        _ = await approvals.approve(configuration, in: scope)
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope,
            saveBeforeBuild: { false }
        )

        await controller.requestBuildSystem(system)
        await controller.waitForCurrentBuild()

        let runCount = await runner.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertFalse(controller.isRunning)
    }

    func testStreamingOutputIsBoundedAndProblemsAreLimited() async throws {
        let problemLines = (0..<550).map { "Sources/F\($0).swift:2:3: warning: problem \($0)\n" }.joined()
        let oversized = String(repeating: "x", count: BuildController.maximumLogCharacters + 20)
        let runner = BuildRunnerStub(results: [
            .output([
                (.standardOutput, Data(oversized.utf8)),
                (.standardError, Data(problemLines.utf8))
            ], 1)
        ])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()

        XCTAssertTrue(controller.wasOutputTruncated)
        XCTAssertLessThanOrEqual(controller.outputText.utf16.count, BuildController.maximumLogCharacters)
        XCTAssertEqual(controller.problems.count, BuildController.maximumProblems)
        XCTAssertEqual(controller.problems.first?.severity, .warning)
        XCTAssertEqual(controller.exitCode, 1)
        XCTAssertTrue(controller.logEntries.contains { $0.stream == .standardError })
    }

    func testProblemParsingHandlesThousandsOfSingleByteChunksIncrementally() async throws {
        let expectedCount = 250
        let output = (0 ..< expectedCount).map { index in
            "Sources/Tiny\(index).swift:2:3: warning: problem \(index)\n"
        }.joined()
        let chunks: [(ToolOutputStream, Data)] = output.utf8.map { byte in
            (.standardError, Data([byte]))
        }
        XCTAssertGreaterThan(chunks.count, 10_000)
        let runner = BuildRunnerStub(results: [.output(chunks, 0)])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()

        XCTAssertEqual(controller.problems.count, expectedCount)
        XCTAssertEqual(controller.problems.first?.url.lastPathComponent, "Tiny0.swift")
        XCTAssertEqual(controller.problems.last?.url.lastPathComponent, "Tiny249.swift")
        XCTAssertEqual(controller.problems.last?.message, "warning: problem 249")
    }

    func testUTF8OutputDecodesChineseProblemPathAndEmojiByteByByte() async throws {
        let output = "源码/😀文件.swift:7:9: error: 编译失败🙂\n"
        let chunks: [(ToolOutputStream, Data)] = output.utf8.map { byte in
            (.standardError, Data([byte]))
        }
        let runner = BuildRunnerStub(results: [.output(chunks, 1)])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()

        XCTAssertEqual(controller.outputText, output)
        XCTAssertFalse(controller.outputText.contains("�"))
        XCTAssertEqual(controller.problems.count, 1)
        XCTAssertEqual(controller.problems[0].url.lastPathComponent, "😀文件.swift")
        XCTAssertEqual(controller.problems[0].message, "error: 编译失败🙂")
    }

    func testUTF8OutputHandlesEveryTwoChunkSplit() async throws {
        let sample = "中文🙂/résumé.swift\n"
        let bytes = Array(sample.utf8)
        var chunks: [(ToolOutputStream, Data)] = []
        for split in 1 ..< bytes.count {
            chunks.append((.standardOutput, Data(bytes[..<split])))
            chunks.append((.standardOutput, Data(bytes[split...])))
        }
        let runner = BuildRunnerStub(results: [.output(chunks, 0)])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()

        XCTAssertEqual(controller.outputText, String(repeating: sample, count: bytes.count - 1))
        XCTAssertFalse(controller.outputText.contains("�"))
    }

    func testUTF8OutputMaintainsIndependentStreamTails() async throws {
        let emoji = Array("🙂 stdout\n".utf8)
        let chinese = Array("中 stderr\n".utf8)
        let chunks: [(ToolOutputStream, Data)] = [
            (.standardOutput, Data(emoji[..<2])),
            (.standardError, Data(chinese[..<1])),
            (.standardOutput, Data(emoji[2...])),
            (.standardError, Data(chinese[1...]))
        ]
        let runner = BuildRunnerStub(results: [.output(chunks, 0)])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()

        XCTAssertEqual(controller.outputText, "🙂 stdout\n中 stderr\n")
        XCTAssertEqual(controller.logEntries.map(\.stream), [.standardOutput, .standardError])
    }

    func testUTF8OutputRepairsMalformedAndTruncatedBytesAtEOF() async throws {
        let malformed: [UInt8] = [0xE2, 0x28, 0xA1]
        let truncatedOutput: [UInt8] = [0xF0, 0x9F]
        let truncatedError: [UInt8] = [0xE4]
        let chunks: [(ToolOutputStream, Data)] = [
            (.standardOutput, Data(malformed)),
            (.standardOutput, Data(truncatedOutput)),
            (.standardError, Data(truncatedError))
        ]
        let runner = BuildRunnerStub(results: [.output(chunks, 1)])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()

        let expectedOutput = String(decoding: malformed + truncatedOutput, as: UTF8.self)
        let expectedError = String(decoding: truncatedError, as: UTF8.self)
        XCTAssertEqual(
            controller.logEntries.filter { $0.stream == .standardOutput }.map(\.text).joined(),
            expectedOutput
        )
        XCTAssertEqual(
            controller.logEntries.filter { $0.stream == .standardError }.map(\.text).joined(),
            expectedError
        )
    }

    func testProblemParsingSkipsOversizedLinesAndContinues() async throws {
        let oversized = String(repeating: "x", count: 8_000)
        let output = oversized + "\nSources/After.swift:7:9: error: retained\n"
        let bytes = Array(output.utf8)
        let chunks: [(ToolOutputStream, Data)] = stride(
            from: 0, to: bytes.count, by: 31
        ).map { start in
            (.standardError, Data(bytes[start ..< min(start + 31, bytes.count)]))
        }
        let runner = BuildRunnerStub(results: [.output(chunks, 1)])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()

        XCTAssertEqual(controller.problems.count, 1)
        XCTAssertEqual(controller.problems[0].url.lastPathComponent, "After.swift")
        XCTAssertEqual(controller.problems[0].line, 7)
        XCTAssertEqual(controller.problems[0].column, 9)
    }

    func testLogTrimmingKeepsSurrogatePairsIntact() async throws {
        let runner = BuildRunnerStub(results: [
            .output([(.standardOutput, Data((
                "🙂" + String(repeating: "x", count: BuildController.maximumLogCharacters)
            ).utf8))], 0)
        ])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()
        await drainMainActorTasks()

        XCTAssertFalse(controller.outputText.contains("�"))
        XCTAssertEqual(controller.outputText.utf16.count, BuildController.maximumLogCharacters)
    }

    func testCancelDiscardsLateOutputFromPreviousGeneration() async throws {
        let runner = ControlledBuildRunner()
        let approvals = ToolApprovalStore()
        let controller = BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
        await controller.requestFreeFormBuild("swift test")
        let configuration = try XCTUnwrap(controller.pendingApproval?.configuration)
        _ = await approvals.approve(configuration, in: scope)
        controller.declinePendingBuild()
        await controller.requestFreeFormBuild("swift test")
        await runner.waitUntilStarted()

        let cancellation = Task { @MainActor in await controller.cancel() }
        await runner.waitUntilCancelled()
        await runner.emitAfterCancellation(
            "Sources/Late.swift:1:1: error: late secret output\n"
        )
        await cancellation.value
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(controller.outputText.contains("late secret output"))
        XCTAssertTrue(controller.problems.isEmpty)
        XCTAssertFalse(controller.isRunning)
        let cancelCount = await runner.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testBuildUsesInjectedOneHourTimeoutAndCoreOutputCaps() async throws {
        let runner = BuildRunnerStub(results: [.finished(0)])
        let controller = try await approvedController(runner: runner, command: "swift test")

        await controller.requestFreeFormBuild("swift test")
        await controller.waitForCurrentBuild()

        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.timeout, 60 * 60)
        XCTAssertEqual(command.maximumStandardOutputBytes, ToolExecutionLimits.maximumStandardOutputBytes)
        XCTAssertEqual(command.maximumStandardErrorBytes, ToolExecutionLimits.maximumStandardErrorBytes)
    }

    func testPanelAccessibilityContract() {
        XCTAssertEqual(BuildPanelView.Accessibility.panel, "Build Output")
        XCTAssertEqual(BuildPanelView.Accessibility.output, "Build Log")
        XCTAssertEqual(BuildPanelView.Accessibility.problems, "Build Problems")
        XCTAssertEqual(BuildPanelView.Accessibility.stop, "Stop Build")
    }

    func testBuildPersistenceIssueIsLocalizedWithoutStringMatching() {
        let error = BuildCommandPersistenceError.partialPersistence(
            globalFailure: "disk full", projectRollbackFailure: "conflict"
        )
        let issue = BuildPresentationIssue(persistenceError: error)

        XCTAssertEqual(issue.titleContent, .saveBuildCommand)
        XCTAssertEqual(issue.content, .persistence(error))
        XCTAssertEqual(issue.localizedTitle(locale: .enUS), "Could Not Save Build Command")
        XCTAssertEqual(issue.localizedTitle(locale: .zhCN), "无法保存构建命令")
        XCTAssertTrue(issue.localizedMessage(locale: .enUS).contains(
            "Rolling back project settings also failed"
        ))
        XCTAssertTrue(issue.localizedMessage(locale: .zhCN).contains(
            "回滚项目设置也失败"
        ))
        XCTAssertTrue(issue.localizedMessage(locale: .zhCN).contains(
            "全局与项目构建命令可能不一致"
        ))
    }

    private func approvedController(
        runner: any BuildProcessRunning, command: String
    ) async throws -> BuildController {
        let approvals = ToolApprovalStore()
        let configuration = try ToolExecutionConfiguration(
            kind: .buildCommand, root: root, command: command, shell: true
        )
        _ = await approvals.approve(configuration, in: scope)
        return BuildController(
            workspaceRoot: root, runner: runner, approvals: approvals, scope: scope
        )
    }

    private func drainMainActorTasks() async {
        await Task.yield()
        await Task.yield()
    }
}

private actor BuildRunnerStub: BuildProcessRunning {
    enum Stub {
        case finished(Int32)
        case output([(ToolOutputStream, Data)], Int32)
    }

    private var results: [Stub]
    private(set) var commands: [ToolCommand] = []
    private(set) var cancelCount = 0
    var runCount: Int { commands.count }

    init(results: [Stub] = []) { self.results = results }

    func run(
        _ command: ToolCommand, onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> ToolProcessResult {
        commands.append(command)
        let result = results.isEmpty ? .finished(0) : results.removeFirst()
        switch result {
        case let .finished(code):
            return ToolProcessResult(standardOutput: Data(), standardError: Data(), exitCode: code)
        case let .output(chunks, code):
            for (stream, data) in chunks { onOutput(stream, data) }
            return ToolProcessResult(standardOutput: Data(), standardError: Data(), exitCode: code)
        }
    }

    func cancelAll() async { cancelCount += 1 }
}

private actor ControlledBuildRunner: BuildProcessRunning {
    private var output: ToolProcessOutputHandler?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var runContinuation: CheckedContinuation<ToolProcessResult, any Error>?
    private var didStart = false
    private var didCancel = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelCount = 0

    func run(
        _ command: ToolCommand, onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> ToolProcessResult {
        output = onOutput
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { runContinuation = $0 }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func emitAfterCancellation(_ text: String) {
        output?(.standardOutput, Data(text.utf8))
    }

    func waitUntilCancelled() async {
        if didCancel { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func cancelAll() async {
        cancelCount += 1
        didCancel = true
        let waiters = cancelWaiters
        cancelWaiters = []
        waiters.forEach { $0.resume() }
        runContinuation?.resume(throwing: ToolExecutionError.cancelled)
        runContinuation = nil
    }
}

private actor BlockingCancellationBuildRunner: BuildProcessRunning {
    private var runContinuation: CheckedContinuation<ToolProcessResult, any Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationRelease: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didRequestCancellation = false

    func run(
        _ command: ToolCommand, onOutput: @escaping ToolProcessOutputHandler
    ) async throws -> ToolProcessResult {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { runContinuation = $0 }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func waitUntilCancellationRequested() async {
        if didRequestCancellation { return }
        await withCheckedContinuation { cancellationContinuation = $0 }
    }

    func releaseCancellation() {
        cancellationRelease?.resume()
        cancellationRelease = nil
    }

    func cancelAll() async {
        didRequestCancellation = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
        await withCheckedContinuation { cancellationRelease = $0 }
        runContinuation?.resume(throwing: ToolExecutionError.cancelled)
        runContinuation = nil
    }
}
