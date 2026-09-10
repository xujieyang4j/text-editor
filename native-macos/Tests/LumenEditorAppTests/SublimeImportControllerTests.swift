import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class SublimeImportControllerTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/picked/Demo.sublime-project")
    private let settingsURL = URL(fileURLWithPath: "/picked/Preferences.sublime-settings")
    private let keymapURL = URL(fileURLWithPath: "/picked/Default.sublime-keymap")
    private let snippetURL = URL(fileURLWithPath: "/picked/Print.sublime-snippet")

    @MainActor
    func testPreviewAndCancellationNeverInvokeMutationCapabilities() async throws {
        let mutations = MutationBox()
        let controller = makeController(counts: mutations)

        let prepared = await controller.prepareImport(
            .project, sourceURL: projectURL, data: projectData
        )

        XCTAssertTrue(prepared)
        XCTAssertEqual(controller.status, .awaitingConfirmation(.project))
        XCTAssertTrue(controller.isPresented)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.presentation?.kind, .project)
        XCTAssertEqual(controller.presentation?.sourceURL, projectURL.standardizedFileURL)
        XCTAssertEqual(mutations.value, MutationCounts())

        guard case let .project(preview)? = controller.preview else {
            return XCTFail("Expected a typed project preview")
        }
        XCTAssertEqual(preview.roots.map(\.path), ["/picked/src", "/shared"])
        XCTAssertEqual(preview.exclusions, ["*.tmp"])
        XCTAssertEqual(preview.buildSystems.map(\.name), ["Tests"])
        XCTAssertTrue(controller.presentation?.message.contains("will not run") == true)

        let token = try XCTUnwrap(controller.confirmationToken)
        XCTAssertTrue(controller.cancel(token: token))
        XCTAssertEqual(controller.status, .cancelled(.project))
        XCTAssertNil(controller.presentation)
        XCTAssertNil(controller.preview)
        XCTAssertEqual(mutations.value, MutationCounts())
        let reused = await controller.confirm(token: token)
        XCTAssertFalse(reused)
        XCTAssertEqual(mutations.value, MutationCounts())
    }

    @MainActor
    func testPickerCancellationDoesNotParseApplyOrPresentAnIssue() async {
        var parseCount = 0
        let mutations = MutationBox()
        let controller = makeController(
            counts: mutations,
            requestSource: { kind in
                XCTAssertEqual(kind, .settings)
                return nil
            },
            parse: { _, _, _ in
                parseCount += 1
                throw TestFailure.parse
            }
        )

        let imported = await controller.requestImport(.settings)
        XCTAssertFalse(imported)
        XCTAssertEqual(controller.status, .cancelled(.settings))
        XCTAssertEqual(parseCount, 0)
        XCTAssertEqual(mutations.value, MutationCounts())
        XCTAssertNil(controller.presentation)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testSourceFailurePublishesIssueWithoutParsingOrApplying() async {
        var parseCount = 0
        let mutations = MutationBox()
        let controller = makeController(
            counts: mutations,
            requestSource: { _ in throw TestFailure.source },
            parse: { _, _, _ in
                parseCount += 1
                throw TestFailure.parse
            }
        )

        let imported = await controller.requestImport(.settings)
        XCTAssertFalse(imported)
        XCTAssertEqual(controller.status, .failed(.settings))
        XCTAssertEqual(controller.issue?.title, "Could Not Read Sublime Settings")
        XCTAssertEqual(controller.issue?.message, TestFailure.source.localizedDescription)
        XCTAssertEqual(controller.issue?.content, .verbatim("Injected source failure"))
        XCTAssertEqual(parseCount, 0)
        XCTAssertEqual(mutations.value, MutationCounts())
    }

    @MainActor
    func testWrongTokenDoesNotConsumePreviewAndValidTokenIsSingleUse() async throws {
        let validToken = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var applied: [SublimeSettingsImport] = []
        let controller = SublimeImportController(
            currentSettings: { .default },
            hasWorkspace: { true },
            applySettings: { applied.append($0) },
            makeToken: { validToken }
        )
        let prepared = await controller.prepareImport(
            .settings, sourceURL: settingsURL, data: settingsData
        )
        XCTAssertTrue(prepared)

        let wrongTokenAccepted = await controller.confirm(token: UUID())
        XCTAssertFalse(wrongTokenAccepted)
        XCTAssertEqual(controller.confirmationToken, validToken)
        XCTAssertEqual(applied.count, 0)
        XCTAssertEqual(
            controller.issue?.message,
            SublimeImportControllerError.invalidConfirmationToken.localizedDescription
        )

        let confirmed = await controller.confirm(token: validToken)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.settings.fontSize, 18)
        XCTAssertEqual(controller.status, .completed(.settings))
        XCTAssertNil(controller.presentation)

        let reused = await controller.confirm(token: validToken)
        XCTAssertFalse(reused)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(
            controller.issue?.message,
            SublimeImportControllerError.noPendingConfirmation.localizedDescription
        )
    }

    @MainActor
    func testExpiredTokenIsConsumedWithoutApplying() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var applyCount = 0
        let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let controller = SublimeImportController(
            currentSettings: { .default },
            hasWorkspace: { true },
            applySettings: { _ in applyCount += 1 },
            confirmationLifetime: 60,
            clock: { now },
            makeToken: { token }
        )
        let prepared = await controller.prepareImport(
            .settings, sourceURL: settingsURL, data: settingsData
        )
        XCTAssertTrue(prepared)
        XCTAssertEqual(
            controller.presentation?.expiresAt,
            Date(timeIntervalSince1970: 1_060)
        )

        now = Date(timeIntervalSince1970: 1_061)
        let expired = await controller.confirm(token: token)
        XCTAssertFalse(expired)
        XCTAssertEqual(applyCount, 0)
        XCTAssertNil(controller.presentation)
        XCTAssertEqual(controller.status, .failed(.settings))
        XCTAssertEqual(
            controller.issue?.message,
            SublimeImportControllerError.confirmationExpired.localizedDescription
        )

        now = Date(timeIntervalSince1970: 1_001)
        let reused = await controller.confirm(token: token)
        XCTAssertFalse(reused)
        XCTAssertEqual(applyCount, 0)
    }

    @MainActor
    func testStaleParseCannotReplaceNewerPreviewOrStatus() async throws {
        let parser = ControlledImportParser()
        let mutations = MutationBox()
        let controller = makeController(
            counts: mutations,
            parse: { kind, source, settings in
                try await parser.parse(kind: kind, source: source, settings: settings)
            }
        )
        let oldSource = SublimeImportSource(
            sourceURL: projectURL, data: Data("old".utf8)
        )
        let newSource = SublimeImportSource(
            sourceURL: snippetURL, data: Data("new".utf8)
        )

        let oldTask = Task { @MainActor in
            await controller.prepareImport(.project, source: oldSource)
        }
        await parser.waitForCall("old")
        let newTask = Task { @MainActor in
            await controller.prepareImport(.snippet, source: newSource)
        }
        await parser.waitForCall("new")

        let newPreview = SublimeSnippetImport(
            sourceURL: snippetURL, label: "New", text: "new body", trigger: "new"
        )
        await parser.resume("new", with: .success(.snippet(newPreview)))
        let newerAccepted = await newTask.value
        XCTAssertTrue(newerAccepted)
        let currentToken = try XCTUnwrap(controller.confirmationToken)
        XCTAssertEqual(controller.status, .awaitingConfirmation(.snippet))

        let stalePreview = SublimeProjectImport(
            sourceURL: projectURL,
            roots: [URL(fileURLWithPath: "/old-root")],
            exclusions: [],
            buildSystems: []
        )
        await parser.resume("old", with: .success(.project(stalePreview)))
        let staleAccepted = await oldTask.value
        XCTAssertFalse(staleAccepted)

        XCTAssertEqual(controller.confirmationToken, currentToken)
        XCTAssertEqual(controller.status, .awaitingConfirmation(.snippet))
        XCTAssertEqual(controller.preview, .snippet(newPreview))
        XCTAssertNil(controller.issue)
        XCTAssertEqual(mutations.value, MutationCounts())
    }

    @MainActor
    func testSecondRequestIsRejectedWhileSourcePickerIsActive() async {
        let gate = SourceRequestGate()
        let controller = SublimeImportController(
            requestSource: { _ in await gate.wait(); return nil },
            hasWorkspace: { true }
        )
        let first = Task { @MainActor in
            await controller.requestImport(.settings)
        }
        await gate.waitUntilRequested()

        let second = await controller.requestImport(.project)
        XCTAssertFalse(second)
        XCTAssertEqual(controller.status, .requestingSource(.settings))
        XCTAssertNil(controller.issue)

        await gate.resume()
        _ = await first.value
        XCTAssertEqual(controller.status, .cancelled(.settings))
    }

    @MainActor
    func testEachTypedPreviewCallsOnlyItsMatchingApplyCapability() async throws {
        var projectValues: [SublimeProjectImport] = []
        var settingsValues: [SublimeSettingsImport] = []
        var keymapValues: [SublimeKeymapImport] = []
        var snippetValues: [SublimeSnippetImport] = []
        var buildValues: [SublimeBuildImport] = []
        let authorisedRoots = [URL(fileURLWithPath: "/authorised/src")]
        var current = EditorSettings.default
        current.showMinimap = false
        let controller = SublimeImportController(
            currentSettings: { current },
            hasWorkspace: { true },
            applyProject: { value in
                projectValues.append(value)
                return authorisedRoots
            },
            applySettings: { settingsValues.append($0) },
            applyKeymap: { keymapValues.append($0) },
            applySnippet: { snippetValues.append($0) },
            applyBuild: { buildValues.append($0) }
        )

        try await prepareAndConfirm(
            controller, kind: .project, url: projectURL, data: projectData
        )
        XCTAssertEqual(projectValues.count, 1)
        XCTAssertEqual(projectValues[0].buildSystems.first?.command, "swift")
        XCTAssertEqual(controller.completion?.projectRoots, authorisedRoots)
        XCTAssertEqual(
            settingsValues.count + keymapValues.count + snippetValues.count
                + buildValues.count,
            0
        )

        try await prepareAndConfirm(
            controller, kind: .settings, url: settingsURL, data: settingsData
        )
        XCTAssertEqual(settingsValues.count, 1)
        XCTAssertEqual(settingsValues[0].settings.fontSize, 18)
        XCTAssertFalse(settingsValues[0].settings.showMinimap)
        XCTAssertNil(controller.completion?.projectRoots)
        XCTAssertEqual(
            projectValues.count + keymapValues.count + snippetValues.count
                + buildValues.count,
            1
        )

        try await prepareAndConfirm(
            controller, kind: .keymap, url: keymapURL, data: keymapData
        )
        XCTAssertEqual(keymapValues.count, 1)
        XCTAssertEqual(keymapValues[0].overrides.map(\.commandID), ["save"])
        XCTAssertEqual(
            projectValues.count + settingsValues.count + snippetValues.count
                + buildValues.count,
            2
        )

        try await prepareAndConfirm(
            controller, kind: .snippet, url: snippetURL, data: snippetData
        )
        XCTAssertEqual(snippetValues.count, 1)
        XCTAssertEqual(snippetValues[0].label, "Print")
        XCTAssertEqual(snippetValues[0].text, "print(${1:value})")
        XCTAssertEqual(
            projectValues.count + settingsValues.count + keymapValues.count
                + buildValues.count,
            3
        )
        XCTAssertEqual(controller.status, .completed(.snippet))
    }

    @MainActor
    func testStandaloneBuildUsesTwoPhaseConfirmationAndMatchingCapability() async throws {
        let buildURL = URL(fileURLWithPath: "/picked/Swift.sublime-build")
        var applied: [SublimeBuildImport] = []
        let controller = SublimeImportController(
            hasWorkspace: { true },
            applyBuild: { applied.append($0) }
        )

        let prepared = await controller.prepareImport(
            .build, sourceURL: buildURL,
            data: Data(#"{"cmd":["swift","test"]}"#.utf8)
        )
        XCTAssertTrue(prepared)
        XCTAssertTrue(applied.isEmpty)
        guard case let .build(preview)? = controller.preview else {
            return XCTFail("Expected a build preview")
        }
        XCTAssertEqual(preview.system.name, "Swift")
        XCTAssertEqual(preview.system.command, "swift")
        XCTAssertTrue(controller.presentation?.message.contains("does not run") == true)

        let token = try XCTUnwrap(controller.confirmationToken)
        let confirmed = await controller.confirm(token: token)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(applied, [preview])
        XCTAssertEqual(controller.status, .completed(.build))
    }

    @MainActor
    func testWorkspaceImportsAreDisabledAndRejectedWithoutWorkspace() async {
        var requestedKinds: [SublimeImportKind] = []
        let mutations = MutationBox()
        let controller = makeController(
            counts: mutations,
            hasWorkspace: { false },
            requestSource: { kind in
                requestedKinds.append(kind)
                return nil
            }
        )
        let router = CommandRouter()
        _ = try? controller.registerCommands(on: router)
        let context = CommandRoutingContext(hasWorkspace: true)

        XCTAssertEqual(
            router.status(for: "import-sublime-keymap", context: context),
            .disabled(.handler(reason: "No workspace"))
        )
        XCTAssertEqual(
            router.status(for: "import-sublime-snippet", context: context),
            .disabled(.handler(reason: "No workspace"))
        )
        let prepared = await controller.prepareImport(
            .keymap, sourceURL: keymapURL, data: keymapData
        )
        XCTAssertFalse(prepared)
        XCTAssertEqual(controller.issue?.title, "No Workspace Open")
        XCTAssertEqual(controller.status, .failed(.keymap))
        XCTAssertTrue(requestedKinds.isEmpty)
        XCTAssertEqual(mutations.value, MutationCounts())
        XCTAssertEqual(
            controller.issue?.content,
            .controller(.workspaceRequired(.keymap))
        )
    }

    @MainActor
    func testParseFailurePublishesIssueAndPresentationStatusContract() async {
        let mutations = MutationBox()
        let controller = makeController(
            counts: mutations,
            parse: { _, _, _ in throw TestFailure.parse }
        )

        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(controller.statusMessage, "Ready to import from Sublime Text.")
        let prepared = await controller.prepareImport(
            .settings, sourceURL: settingsURL, data: Data()
        )
        XCTAssertFalse(prepared)
        XCTAssertEqual(controller.status, .failed(.settings))
        XCTAssertEqual(controller.statusMessage, "Sublime settings import failed.")
        XCTAssertEqual(controller.issue?.title, "Could Not Read Sublime Settings")
        XCTAssertEqual(controller.issue?.message, TestFailure.parse.localizedDescription)
        XCTAssertNil(controller.presentation)
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(mutations.value, MutationCounts())

        controller.dismissIssue()
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testTypedImportFailuresRerenderAndExternalFailuresStayVerbatim() async {
        let controller = makeController(
            counts: MutationBox(),
            parse: { _, _, _ in throw SublimeImportError.invalidJSON }
        )
        let prepared = await controller.prepareImport(
            .settings, sourceURL: settingsURL, data: Data()
        )
        XCTAssertFalse(prepared)
        guard let issue = controller.issue else {
            return XCTFail("Expected a typed Sublime import issue")
        }
        XCTAssertEqual(issue.titleContent, .couldNotRead(.settings))
        XCTAssertEqual(issue.content, .parser(.invalidJSON))
        XCTAssertEqual(
            EditorLocale.zhCN.localizedSublimeImportIssueTitle(issue.titleContent),
            "无法读取 Sublime 设置"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedSublimeImportIssue(issue.content),
            "所选 Sublime 文件不是有效的 JSON。"
        )

        let external = SublimeImportController.presentationMessage(
            for: ExternalImportFailure()
        )
        XCTAssertEqual(
            external,
            .verbatim("The selected Sublime file is not valid JSON.")
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedSublimeImportIssue(external),
            "The selected Sublime file is not valid JSON."
        )
    }

    @MainActor
    func testRegistersExactlyFiveCommandsAndRoutesSourceRequests() async throws {
        var requestedKinds: [SublimeImportKind] = []
        let controller = SublimeImportController(
            requestSource: { kind in
                requestedKinds.append(kind)
                return nil
            },
            hasWorkspace: { true }
        )
        let router = CommandRouter()
        let tokens = try controller.registerCommands(on: router)

        XCTAssertEqual(SublimeImportController.commandIDs, [
            "import-sublime-project",
            "import-sublime-settings",
            "import-sublime-keymap",
            "import-sublime-snippet",
            "import-sublime-build"
        ])
        XCTAssertEqual(tokens.map(\.commandID), SublimeImportController.commandIDs)
        XCTAssertTrue(SublimeImportController.commandIDs.contains("import-sublime-build"))

        for kind in SublimeImportKind.allCases {
            let result = await router.execute(
                kind.commandID,
                context: CommandRoutingContext(hasWorkspace: true)
            )
            guard case .noChange(commandID: kind.commandID) = result else {
                return XCTFail("Cancelling the picker must report no change")
            }
        }
        XCTAssertEqual(requestedKinds, SublimeImportKind.allCases)
    }

    @MainActor
    func testPartialCommandRegistrationRollsBackControllerOwnership() throws {
        let controller = SublimeImportController(hasWorkspace: { true })
        let router = CommandRouter()
        _ = try router.register("import-sublime-keymap") { _ in }

        XCTAssertThrowsError(try controller.registerCommands(on: router)) { error in
            XCTAssertEqual(
                error as? CommandRegistrationError,
                .alreadyRegistered("import-sublime-keymap")
            )
        }
        let context = CommandRoutingContext(hasWorkspace: true)
        XCTAssertEqual(
            router.status(for: "import-sublime-project", context: context),
            .unsupported
        )
        XCTAssertEqual(
            router.status(for: "import-sublime-settings", context: context),
            .unsupported
        )
        XCTAssertEqual(
            router.status(for: "import-sublime-keymap", context: context),
            .enabled
        )
        XCTAssertEqual(
            router.status(for: "import-sublime-snippet", context: context),
            .unsupported
        )
        XCTAssertEqual(
            router.status(for: "import-sublime-build", context: context),
            .unsupported
        )
    }

    @MainActor
    private func prepareAndConfirm(
        _ controller: SublimeImportController,
        kind: SublimeImportKind,
        url: URL,
        data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let prepared = await controller.prepareImport(
            kind, sourceURL: url, data: data
        )
        XCTAssertTrue(prepared, file: file, line: line)
        let token = try XCTUnwrap(
            controller.confirmationToken, file: file, line: line
        )
        let confirmed = await controller.confirm(token: token)
        XCTAssertTrue(confirmed, file: file, line: line)
    }

    @MainActor
    private func makeController(
        counts: MutationBox,
        hasWorkspace: @escaping SublimeImportController.WorkspaceAvailability = { true },
        requestSource: @escaping SublimeImportController.RequestSource = { _ in nil },
        parse: @escaping SublimeImportController.ParseAction = SublimeImportController.defaultParse
    ) -> SublimeImportController {
        // A reference box lets escaping callbacks mutate test-observable state
        // without retaining an escaping inout capture.
        let controller = SublimeImportController(
            requestSource: requestSource,
            currentSettings: { .default },
            hasWorkspace: hasWorkspace,
            parse: parse,
            applyProject: { _ in counts.value.project += 1; return [] },
            applySettings: { _ in counts.value.settings += 1 },
            applyKeymap: { _ in counts.value.keymap += 1 },
            applySnippet: { _ in counts.value.snippet += 1 },
            applyBuild: { _ in counts.value.build += 1 }
        )
        return controller
    }

    private var projectData: Data {
        Data(#"""
        {
          "folders": [
            {"path": "src", "file_exclude_patterns": ["*.tmp"]},
            {"path": "../shared"}
          ],
          "build_systems": [
            {"name": "Tests", "cmd": ["swift", "test"]}
          ]
        }
        """#.utf8)
    }

    private var settingsData: Data {
        Data(#"{"font_size":18,"tab_size":2}"#.utf8)
    }

    private var keymapData: Data {
        Data(#"[{"keys":["super+s"],"command":"save"}]"#.utf8)
    }

    private var snippetData: Data {
        Data("""
        <snippet>
          <content><![CDATA[print(${1:value})]]></content>
          <tabTrigger>log</tabTrigger>
          <scope>source.swift</scope>
        </snippet>
        """.utf8)
    }
}

private struct MutationCounts: Equatable {
    var project = 0
    var settings = 0
    var keymap = 0
    var snippet = 0
    var build = 0
}

@MainActor
private final class MutationBox {
    var value: MutationCounts
    init(_ value: MutationCounts = MutationCounts()) { self.value = value }
}

private enum TestFailure: Error, LocalizedError {
    case parse
    case source

    var errorDescription: String? {
        switch self {
        case .parse: "Injected parse failure"
        case .source: "Injected source failure"
        }
    }
}

private struct ExternalImportFailure: LocalizedError {
    let errorDescription: String? = "The selected Sublime file is not valid JSON."
}

private actor ControlledImportParser {
    private var continuations: [
        String: CheckedContinuation<SublimeImportPreview, any Error>
    ] = [:]
    private var calls: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func parse(
        kind: SublimeImportKind,
        source: SublimeImportSource,
        settings: EditorSettings
    ) async throws -> SublimeImportPreview {
        _ = kind
        _ = settings
        let key = String(decoding: source.data, as: UTF8.self)
        calls.insert(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        return try await withCheckedThrowingContinuation { continuations[key] = $0 }
    }

    func waitForCall(_ key: String) async {
        guard !calls.contains(key) else { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func resume(
        _ key: String,
        with result: Result<SublimeImportPreview, any Error>
    ) {
        continuations.removeValue(forKey: key)?.resume(with: result)
    }
}

private actor SourceRequestGate {
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var requested = false

    func wait() async {
        requested = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func waitUntilRequested() async {
        guard !requested else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        requestContinuation?.resume()
        requestContinuation = nil
    }
}
