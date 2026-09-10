import Foundation
import Combine
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class NavigationControllerTests: XCTestCase {
    func testProductionGotoAnythingOmitsProjectExcludedFiles() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-navigation-exclusions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Generated"),
            withIntermediateDirectories: true
        )
        try Data("visible".utf8).write(to: rootURL.appendingPathComponent("visible.txt"))
        try Data("hidden".utf8).write(
            to: rootURL.appendingPathComponent("Generated/hidden.txt")
        )
        let workspace = WorkspaceController(service: WorkspaceService(), openFile: { _ in })
        XCTAssertTrue(await workspace.addRoot(rootURL))
        workspace.setProjectExclusions(["Generated/**"])
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: rootURL.appendingPathComponent("session.json")
            ),
            createInitialDocument: false
        )
        let actions = EditorActionController(model: model, workspace: workspace)
        let controller = NativeFeatureCoordinator.makeNavigationController(
            model: model, workspace: workspace, actions: actions
        )

        controller.present(.file)
        await controller.waitForPendingResults()

        XCTAssertTrue(controller.items.map(\.label).contains("visible.txt"))
        XCTAssertFalse(controller.items.map(\.label).contains("hidden.txt"))
    }

    func testSnapshotComputesUTF16LocationForTheActivePane() {
        let document = NavigationDocumentSnapshot(
            documentID: "shared", url: URL(fileURLWithPath: "/workspace/shared.swift"),
            displayName: "shared.swift", text: "🙂a\nsecond"
        )
        let snapshot = NavigationAppSnapshot(
            documents: [document],
            panes: [
                NavigationPaneSnapshot(
                    groupID: 4, activeDocumentID: document.id, cursorUTF16Offset: 1
                ),
                NavigationPaneSnapshot(
                    groupID: 9, activeDocumentID: document.id, cursorUTF16Offset: 4
                )
            ],
            activeGroupID: 9
        )

        XCTAssertEqual(
            snapshot.currentLocation,
            location("shared", path: "/workspace/shared.swift", group: 9, line: 2, column: 1)
        )
        XCTAssertEqual(document.utf16Offset(line: 2, column: 99), 10)
    }

    func testAnythingFuzzyFileLineColumnUsesUTF16OffsetsAndOpenSnapshot() async throws {
        let source = document("source", path: "/workspace/source.swift", text: "source")
        let box = SnapshotBox(snapshot(
            documents: [source], activeDocumentID: source.id, group: 7, offset: 0
        ))
        let targetURL = URL(fileURLWithPath: "/workspace/🙂main.swift")
        var openRequests: [NavigationOpenRequest] = []
        let controller = NavigationController(
            snapshot: { box.value },
            workspaceFiles: { suppliedSnapshot in
                XCTAssertEqual(suppliedSnapshot, box.value)
                return [NavigationFileSnapshot(
                    url: targetURL, displayPath: "🙂main.swift"
                )]
            },
            selectDestination: { _ in
                XCTFail("An unopened URL must use the open callback")
                return nil
            },
            openURL: { request in
                openRequests.append(request)
                let opened = self.document(
                    "opened", path: targetURL.path,
                    text: Array(repeating: "12345678", count: 42).joined(separator: "\n")
                )
                box.value = self.snapshot(
                    documents: [source, opened], activeDocumentID: opened.id,
                    group: request.groupID,
                    offset: SnapshotBox.utf16Offset(
                        line: request.line ?? 1, column: request.column ?? 1,
                        text: opened.text
                    )
                )
                return self.location(
                    "opened", path: targetURL.path, group: request.groupID,
                    line: request.line ?? 1, column: request.column ?? 1
                )
            }
        )

        controller.present(.anything, query: "🙂m:42:8")
        await controller.waitForPendingResults()

        XCTAssertEqual(controller.effectiveMode, .file)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertEqual(item.label, "🙂main.swift")
        XCTAssertEqual(item.searchText, "🙂main.swift")
        XCTAssertEqual(item.matchedUTF16Offsets, [0, 1, 2])
        XCTAssertEqual(item.destination.line, 42)
        XCTAssertEqual(item.destination.column, 8)
        XCTAssertEqual(item.destination.groupID, 7)

        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        let request = try XCTUnwrap(openRequests.first)
        XCTAssertEqual(request.snapshot.documents, [source])
        XCTAssertEqual(request.url.standardizedFileURL.path, targetURL.path)
        XCTAssertEqual(request.groupID, 7)
        XCTAssertEqual(request.line, 42)
        XCTAssertEqual(request.column, 8)
        XCTAssertEqual(controller.backEntries, [
            location("source", path: "/workspace/source.swift", group: 7)
        ])
        XCTAssertFalse(controller.isPresented)
    }

    func testFileModeRanksPathsAndSelectionWraps() async {
        let active = document("active", path: "/workspace/active.swift", text: "x")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 2
        ))
        let controller = NavigationController(
            snapshot: { box.value },
            workspaceFiles: { _ in [
                NavigationFileSnapshot(
                    url: URL(fileURLWithPath: "/workspace/src/main.swift"),
                    displayPath: "src/main.swift"
                ),
                NavigationFileSnapshot(
                    url: URL(fileURLWithPath: "/workspace/tests/mainTests.swift"),
                    displayPath: "tests/mainTests.swift"
                )
            ] },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )

        controller.present(.file, query: "mt")
        await controller.waitForPendingResults()

        XCTAssertEqual(controller.items.count, 2)
        XCTAssertEqual(controller.selectedIndex, 0)
        controller.moveSelection(-1)
        XCTAssertEqual(controller.selectedIndex, 1)
        controller.moveSelection(by: 1)
        XCTAssertEqual(controller.selectedIndex, 0)
    }

    func testAnythingSymbolUsesExtractorOffsetAndPaneAwareSelection() async throws {
        let text = "🙂\nclass Alpha {}\nfunc beta() {}"
        let active = document("active", path: "/workspace/app.swift", text: text)
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 22
        ))
        var selections: [NavigationSelectionRequest] = []
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { request in
                selections.append(request)
                return self.location(
                    request.documentID, path: "/workspace/app.swift",
                    group: request.groupID, line: request.line ?? 1, column: 1
                )
            },
            openURL: { _ in nil }
        )

        controller.present(.anything, query: "@bt")

        XCTAssertEqual(controller.effectiveMode, .symbol)
        let item = try XCTUnwrap(controller.items.first)
        let extracted = try XCTUnwrap(
            SymbolExtractor.extract(from: text).first { $0.label == "beta" }
        )
        XCTAssertEqual(item.label, "beta")
        XCTAssertEqual(item.matchedUTF16Offsets, [0, 2])
        XCTAssertEqual(item.destination.utf16Offset, extracted.position)
        XCTAssertEqual(item.destination.groupID, 22)

        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        let request = try XCTUnwrap(selections.first)
        XCTAssertEqual(request.documentID, active.id)
        XCTAssertEqual(request.paneID, 22)
        XCTAssertEqual(request.utf16Offset, extracted.position)
    }

    func testAnythingLineModeUsesCoreRelativeLineResolver() async throws {
        let active = document(
            "active", path: nil, text: "one\ntwo\nthree\nfour"
        )
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 3, offset: 4
        ))
        var request: NavigationSelectionRequest?
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { value in
                request = value
                return self.location(
                    value.documentID, group: value.groupID,
                    line: value.line ?? 1, column: value.column ?? 1
                )
            },
            openURL: { _ in nil }
        )

        controller.present(.anything, query: " :+1:3".trimmingCharacters(in: .whitespaces))

        XCTAssertEqual(controller.effectiveMode, .line)
        XCTAssertEqual(controller.items.first?.label, "Go to 3:3")
        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        XCTAssertEqual(request?.documentID, active.id)
        XCTAssertEqual(request?.groupID, 3)
        XCTAssertEqual(request?.line, 3)
        XCTAssertEqual(request?.column, 3)

        controller.present(.line, query: "not-a-line")
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertNil(controller.selectedIndex)
    }

    func testProjectSymbolProviderBuildsUTF16FuzzyRowsAndOpenRequest() async throws {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 5,
            roots: [URL(fileURLWithPath: "/workspace")]
        ))
        let targetURL = URL(fileURLWithPath: "/workspace/Sources/run.swift")
        var opened: NavigationOpenRequest?
        let controller = NavigationController(
            snapshot: { box.value },
            projectSymbols: { suppliedSnapshot in
                XCTAssertEqual(suppliedSnapshot.workspaceRoots, box.value.workspaceRoots)
                return [NavigationProjectSymbolSnapshot(
                    label: "🙂Runner", url: targetURL,
                    displayPath: "Sources/run.swift", line: 12, column: 4,
                    utf16Offset: 90
                )]
            },
            selectDestination: { _ in nil },
            openURL: { request in
                opened = request
                let openedDocument = self.document(
                    "run", path: targetURL.path,
                    text: Array(repeating: "symbol", count: 12).joined(separator: "\n")
                )
                box.value = self.snapshot(
                    documents: [active, openedDocument],
                    activeDocumentID: openedDocument.id, group: request.groupID,
                    offset: SnapshotBox.utf16Offset(
                        line: request.line ?? 1, column: request.column ?? 1,
                        text: openedDocument.text
                    )
                )
                return self.location(
                    "run", path: targetURL.path, group: request.groupID,
                    line: request.line ?? 1, column: request.column ?? 1
                )
            }
        )

        controller.present(.anything, query: "#🙂r")
        await controller.waitForPendingResults()

        XCTAssertEqual(controller.effectiveMode, .projectSymbol)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertEqual(item.matchedUTF16Offsets, [0, 1, 2])
        XCTAssertEqual(item.searchText, "🙂Runner Sources/run.swift")
        XCTAssertEqual(item.destination.utf16Offset, 90)
        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        XCTAssertEqual(opened?.snapshot.activeDocument, active)
        XCTAssertEqual(opened?.groupID, 5)
        XCTAssertEqual(opened?.line, 12)
        XCTAssertEqual(opened?.column, 4)
    }

    func testProjectSymbolsUseTheElectronTwoHundredResultLimitInBothModes() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let symbols = (0..<550).map { index in
            NavigationProjectSymbolSnapshot(
                label: "Symbol \(index)",
                url: URL(fileURLWithPath: "/workspace/file\(index).swift"),
                line: index + 1
            )
        }
        let controller = NavigationController(
            snapshot: { box.value },
            projectSymbols: { _ in symbols },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )

        controller.present(.projectSymbol)
        await controller.waitForPendingResults()
        XCTAssertEqual(controller.items.count, 200)

        controller.present(.anything, query: "#")
        await controller.waitForPendingResults()
        XCTAssertEqual(controller.items.count, 200)
    }

    func testSelectedIdentifierSupportsSelectionCursorUnicodeAndBounds() {
        let text = "let $ascii_name = cafe\u{301} + 变量42"
        let asciiRange = (text as NSString).range(of: "$ascii_name")
        let unicodeRange = (text as NSString).range(of: "变量42")
        let accentRange = (text as NSString).range(of: "cafe\u{301}")

        XCTAssertEqual(
            NativeFeatureCoordinator.selectedIdentifier(
                in: text, selection: .single(
                    anchor: asciiRange.location, head: NSMaxRange(asciiRange)
                )
            ),
            "$ascii_name"
        )
        XCTAssertEqual(
            NativeFeatureCoordinator.selectedIdentifier(
                in: text, selection: .cursor(at: unicodeRange.location + 1)
            ),
            "变量42"
        )
        XCTAssertEqual(
            NativeFeatureCoordinator.selectedIdentifier(
                in: text, selection: .cursor(at: NSMaxRange(accentRange))
            ),
            "cafe\u{301}"
        )
        XCTAssertNil(NativeFeatureCoordinator.selectedIdentifier(
            in: "42name", selection: .cursor(at: 2)
        ))
        XCTAssertNil(NativeFeatureCoordinator.selectedIdentifier(
            in: String(repeating: "a", count: 257),
            selection: .cursor(at: 128)
        ))
        XCTAssertEqual(NativeFeatureCoordinator.selectedIdentifier(
            in: String(repeating: "a", count: 256),
            selection: .single(anchor: 256, head: 0)
        ), String(repeating: "a", count: 256))
        XCTAssertNil(NativeFeatureCoordinator.selectedIdentifier(
            in: "🙂name", selection: .single(anchor: 0, head: 1)
        ))
        XCTAssertTrue(
            NativeFeatureCoordinator.isCaseSensitiveReferenceIdentifier(
                "HTTPClient"
            )
        )
        XCTAssertFalse(
            NativeFeatureCoordinator.isCaseSensitiveReferenceIdentifier(
                "httpClient"
            )
        )
    }

    func testLocalDefinitionRequiresExactSymbolLabel() {
        let text = "func runner() {}\nfunc run() {}"

        XCTAssertEqual(
            NativeFeatureCoordinator.localDefinition(named: "run", in: text),
            DocumentSymbol(label: "run", position: 17, line: 2)
        )
        XCTAssertNil(
            NativeFeatureCoordinator.localDefinition(named: "Run", in: text)
        )
    }

    func testExactProjectSymbolNavigatesOneMatchAndPresentsAmbiguity() async throws {
        let active = document(
            "active", path: "/workspace/active.swift", text: "run()"
        )
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 4,
            roots: [URL(fileURLWithPath: "/workspace")]
        ))
        let first = NavigationProjectSymbolSnapshot(
            label: "run", url: URL(fileURLWithPath: "/workspace/a.swift"),
            line: 3
        )
        let second = NavigationProjectSymbolSnapshot(
            label: "run", url: URL(fileURLWithPath: "/workspace/b.swift"),
            line: 7
        )
        var symbols = [first]
        var opened: [NavigationOpenRequest] = []
        let controller = NavigationController(
            snapshot: { box.value },
            exactProjectSymbols: { _, label in
                XCTAssertEqual(label, "run")
                return symbols
            },
            selectDestination: { _ in nil },
            openURL: { request in
                opened.append(request)
                return self.location(
                    "target", path: request.url.path, group: request.groupID,
                    line: request.line ?? 1, column: request.column ?? 1
                )
            }
        )

        XCTAssertEqual(
            try await controller.openExactProjectSymbol(named: "run"),
            .navigated
        )
        XCTAssertEqual(opened.map(\.url), [first.url])
        XCTAssertFalse(controller.isPresented)

        symbols = []
        XCTAssertEqual(
            try await controller.openExactProjectSymbol(named: "run"),
            .notFound
        )
        XCTAssertFalse(controller.isPresented)

        symbols = [first, second]
        XCTAssertEqual(
            try await controller.openExactProjectSymbol(named: "run"),
            .presented(matchCount: 2)
        )
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.effectiveMode, .projectSymbol)
        XCTAssertEqual(controller.items.map(\.label), ["run", "run"])
        XCTAssertEqual(controller.items.map(\.destination.line), [3, 7])
    }

    func testExactProjectSymbolFiltersProviderResultsByExactLabel() async throws {
        let active = document(
            "active", path: "/workspace/active.swift", text: "runner()"
        )
        let controller = NavigationController(
            snapshot: { self.snapshot(
                documents: [active], activeDocumentID: active.id, group: 0,
                roots: [URL(fileURLWithPath: "/workspace")]
            ) },
            exactProjectSymbols: { _, _ in [
                NavigationProjectSymbolSnapshot(
                    label: "runner",
                    url: URL(fileURLWithPath: "/workspace/runner.swift"),
                    line: 1
                ),
                NavigationProjectSymbolSnapshot(
                    label: "run",
                    url: URL(fileURLWithPath: "/workspace/run.swift"),
                    line: 2
                )
            ] },
            selectDestination: { _ in nil },
            openURL: { request in
                self.location(
                    "run", path: request.url.path, group: request.groupID,
                    line: request.line ?? 1, column: request.column ?? 1
                )
            }
        )

        XCTAssertEqual(
            try await controller.openExactProjectSymbol(named: "run"),
            .navigated
        )
    }

    func testSlowProviderCannotOverwriteNewerQueryResults() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let provider = ControlledFileProvider()
        let controller = NavigationController(
            snapshot: { box.value },
            workspaceFiles: { snapshot in await provider.load(snapshot) },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )

        controller.present(.file, query: "old")
        await provider.waitForCallCount(1)
        controller.query = "new"
        await provider.waitForCallCount(2)

        await provider.resume(
            call: 1, files: [NavigationFileSnapshot(
                url: URL(fileURLWithPath: "/workspace/new.swift"),
                displayPath: "new.swift"
            )]
        )
        await controller.waitForPendingResults()
        XCTAssertEqual(controller.items.map(\.label), ["new.swift"])

        await provider.resume(
            call: 0, files: [NavigationFileSnapshot(
                url: URL(fileURLWithPath: "/workspace/old.swift"),
                displayPath: "old.swift"
            )]
        )
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.items.map(\.label), ["new.swift"])
        XCTAssertFalse(controller.isBusy)
    }

    func testOldProviderCompletionCannotPublishAfterContextGenerationChanges() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let context = NavigationContextGenerationBox()
        let provider = ControlledFileProvider()
        let controller = NavigationController(
            contextGeneration: { context.value },
            contextGenerationChanges: context.publisher,
            snapshot: { box.value },
            workspaceFiles: { snapshot in await provider.load(snapshot) },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )

        controller.present(.file, query: "stale")
        await provider.waitForCallCount(1)
        XCTAssertTrue(controller.isBusy)

        context.advance()
        await Task.yield()
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(controller.isBusy)

        await provider.resume(
            call: 0, files: [NavigationFileSnapshot(
                url: URL(fileURLWithPath: "/workspace/stale.swift"),
                displayPath: "stale.swift"
            )]
        )
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(controller.isPresented)
    }

    func testProviderCompletionClosesStaleContextWithoutChangePublisher() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let context = NavigationContextGenerationBox()
        let provider = ControlledFileProvider()
        let controller = NavigationController(
            contextGeneration: { context.value },
            snapshot: { box.value },
            workspaceFiles: { snapshot in await provider.load(snapshot) },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )

        controller.present(.file)
        await provider.waitForCallCount(1)
        context.advance()
        await provider.resume(
            call: 0, files: [NavigationFileSnapshot(
                url: URL(fileURLWithPath: "/workspace/stale.swift")
            )]
        )
        await controller.waitForPendingResults()

        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(controller.isPresented)
    }

    func testRootChangeDuringFileProviderCannotPublishResults() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let roots = NavigationRootSnapshotBox()
        let provider = ControlledFileProvider()
        let controller = NavigationController(
            workspaceRootSnapshot: { roots.value },
            workspaceRootChanges: roots.publisher,
            snapshot: { box.value },
            workspaceFiles: { snapshot in await provider.load(snapshot) },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )

        controller.present(.file)
        await provider.waitForCallCount(1)
        roots.advance()
        await Task.yield()
        await provider.resume(call: 0, files: [NavigationFileSnapshot(
            url: URL(fileURLWithPath: "/workspace/stale.swift")
        )])
        await Task.yield()

        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isBusy)
    }

    func testAcceptSynchronouslyRejectsDisplayedProjectSymbolAfterRootChange() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let roots = NavigationRootSnapshotBox()
        var opened = false
        let controller = NavigationController(
            workspaceRootSnapshot: { roots.value },
            snapshot: { box.value },
            projectSymbols: { _ in [NavigationProjectSymbolSnapshot(
                label: "OldSymbol",
                url: URL(fileURLWithPath: "/workspace/old.swift"),
                line: 4
            )] },
            selectDestination: { _ in nil },
            openURL: { _ in opened = true; return nil }
        )

        controller.present(.projectSymbol)
        await controller.waitForPendingResults()
        XCTAssertEqual(controller.items.count, 1)
        roots.advanceWithoutNotifying()

        let accepted = await controller.acceptSelection()
        XCTAssertFalse(accepted)
        XCTAssertFalse(opened)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(controller.isPresented)
    }

    func testAcceptRejectsDisplayedFileAfterContextGenerationChanges() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let context = NavigationContextGenerationBox()
        var opened: [NavigationOpenRequest] = []
        let controller = NavigationController(
            contextGeneration: { context.value },
            // Intentionally omit the publisher to exercise the mandatory
            // synchronous accept-time generation check.
            snapshot: { box.value },
            workspaceFiles: { _ in [NavigationFileSnapshot(
                url: URL(fileURLWithPath: "/workspace/now-excluded.swift"),
                displayPath: "now-excluded.swift"
            )] },
            selectDestination: { _ in nil },
            openURL: { request in
                opened.append(request)
                return nil
            }
        )

        controller.present(.file)
        await controller.waitForPendingResults()
        XCTAssertEqual(controller.items.map(\.label), ["now-excluded.swift"])

        context.advance()
        let accepted = await controller.acceptSelection()

        XCTAssertFalse(accepted)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(controller.isPresented)
    }

    func testContextChangeClosesDisplayedProjectSymbolResults() async {
        let active = document("active", path: nil, text: "draft")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 3,
            roots: [URL(fileURLWithPath: "/workspace")]
        ))
        let context = NavigationContextGenerationBox()
        var opened = false
        let controller = NavigationController(
            contextGeneration: { context.value },
            contextGenerationChanges: context.publisher,
            snapshot: { box.value },
            projectSymbols: { _ in [NavigationProjectSymbolSnapshot(
                label: "HiddenAfterRefresh",
                url: URL(fileURLWithPath: "/workspace/generated.swift"),
                line: 9
            )] },
            selectDestination: { _ in nil },
            openURL: { _ in
                opened = true
                return nil
            }
        )

        controller.present(.projectSymbol)
        await controller.waitForPendingResults()
        XCTAssertEqual(controller.items.map(\.label), ["HiddenAfterRefresh"])

        context.advance()
        await Task.yield()

        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(controller.isPresented)
        let accepted = await controller.acceptSelection()
        XCTAssertFalse(accepted)
        XCTAssertFalse(opened)
    }

    func testOnlyVerifiedSuccessfulArrivalIsRecordedInHistory() async {
        let source = document("source", path: "/workspace/source.swift", text: "source")
        let target = document(
            "target", path: "/workspace/target.swift", text: "first\nsecond"
        )
        let box = SnapshotBox(snapshot(
            documents: [source, target], activeDocumentID: source.id, group: 1
        ))
        var results: [NavigationLocation?] = [
            nil,
            location("target", path: "/workspace/target.swift", group: 99),
            location("target", path: "/workspace/target.swift", group: 1, line: 1),
            location("target", path: "/workspace/target.swift", group: 1, line: 2)
        ]
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { _ in results.removeFirst() },
            openURL: { _ in nil }
        )
        let destination = NavigationDestination(
            target: .document(id: target.id), groupID: 1, line: 2, column: 1
        )

        let nilResult = await controller.navigate(to: destination)
        XCTAssertFalse(nilResult)
        XCTAssertTrue(controller.backEntries.isEmpty)
        let wrongPaneResult = await controller.navigate(to: destination)
        XCTAssertFalse(wrongPaneResult)
        XCTAssertTrue(controller.backEntries.isEmpty)
        let wrongPositionResult = await controller.navigate(to: destination)
        XCTAssertFalse(wrongPositionResult)
        XCTAssertTrue(controller.backEntries.isEmpty)
        let successfulResult = await controller.navigate(to: destination)
        XCTAssertTrue(successfulResult)
        XCTAssertEqual(controller.backEntries, [
            location("source", path: "/workspace/source.swift", group: 1)
        ])
    }

    func testGoToFileCarriesAWorkspaceMatchSelectionIntoNavigation() async {
        let source = document("source", path: "/workspace/source.swift", text: "source")
        let target = document(
            "target", path: "/workspace/target.swift", text: "zero needle end"
        )
        let box = SnapshotBox(snapshot(
            documents: [source], activeDocumentID: source.id, group: 1
        ))
        var received: NavigationOpenRequest?
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { request in box.apply(request) },
            openURL: { request in
                received = request
                box.value = self.snapshot(
                    documents: [source, target],
                    activeDocumentID: target.id, group: request.groupID, offset: 11
                )
                return self.location(
                    target.id, path: "/workspace/target.swift",
                    group: request.groupID, line: 1, column: 12
                )
            }
        )

        let didNavigate = await controller.goToFile(
            URL(fileURLWithPath: "/workspace/target.swift"),
            utf16Offset: 5, selectionUTF16Length: 6
        )
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(received?.utf16Offset, 5)
        XCTAssertEqual(received?.selectionUTF16Length, 6)
        XCTAssertEqual(controller.backEntries, [
            location("source", path: "/workspace/source.swift", group: 1)
        ])
    }

    func testBackForwardCommitTransactionsAfterArrival() async {
        let a = location("a", path: "/workspace/a.swift", group: 1, line: 1)
        let b = location("b", path: "/workspace/b.swift", group: 1, line: 2)
        let c = location("c", path: "/workspace/c.swift", group: 1, line: 3)
        let documents = [
            document("a", path: a.path, text: "a1\na2\na3"),
            document("b", path: b.path, text: "b1\nb2\nb3"),
            document("c", path: c.path, text: "c1\nc2\nc3")
        ]
        let box = SnapshotBox(snapshot(
            documents: documents, activeDocumentID: "c", group: 1, offset: 6
        ))
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { request in box.apply(request) },
            openURL: { _ in nil }
        )
        controller.recordSuccessfulJump(source: a, target: b)
        controller.recordSuccessfulJump(source: b, target: c)

        let wentBack = await controller.goBack()
        XCTAssertTrue(wentBack)
        XCTAssertEqual(box.value.currentLocation, b)
        XCTAssertEqual(controller.backEntries, [a])
        XCTAssertEqual(controller.forwardEntries, [c])

        let wentForward = await controller.goForward()
        XCTAssertTrue(wentForward)
        XCTAssertEqual(box.value.currentLocation, c)
        XCTAssertEqual(controller.backEntries, [a, b])
        XCTAssertTrue(controller.forwardEntries.isEmpty)
    }

    func testBackRequestsAreSerialized() async {
        let a = location("a", group: 0, line: 1)
        let b = location("b", group: 0, line: 2)
        let c = location("c", group: 0, line: 3)
        let documents = [
            document("a", path: nil, text: "1\n2\n3"),
            document("b", path: nil, text: "1\n2\n3"),
            document("c", path: nil, text: "1\n2\n3")
        ]
        let box = SnapshotBox(snapshot(
            documents: documents, activeDocumentID: "c", group: 0, offset: 4
        ))
        let gate = ControlledSelectionGate()
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { request in
                await gate.suspend(request)
                return box.apply(request)
            },
            openURL: { _ in nil }
        )
        controller.recordSuccessfulJump(source: a, target: b)
        controller.recordSuccessfulJump(source: b, target: c)

        let first = Task { @MainActor in await controller.goBack() }
        await gate.waitForCallCount(1)
        let second = Task { @MainActor in await controller.goBack() }
        await Task.yield()
        let callsWhileFirstIsPending = await gate.callCount
        XCTAssertEqual(callsWhileFirstIsPending, 1)

        await gate.resume(call: 0)
        await gate.waitForCallCount(2)
        let requestedDocuments = await gate.requestedDocumentIDs
        XCTAssertEqual(requestedDocuments, ["b", "a"])
        await gate.resume(call: 1)

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertTrue(controller.backEntries.isEmpty)
        XCTAssertEqual(controller.forwardEntries, [c, b])
    }

    func testNewIntentMakesInFlightTraversalStaleWithoutCommitting() async {
        let a = location("a", group: 0, line: 1)
        let b = location("b", group: 0, line: 2)
        let c = location("c", group: 0, line: 3)
        let documents = [
            document("a", path: nil, text: "1\n2\n3"),
            document("b", path: nil, text: "1\n2\n3"),
            document("c", path: nil, text: "1\n2\n3")
        ]
        let box = SnapshotBox(snapshot(
            documents: documents, activeDocumentID: "c", group: 0, offset: 4
        ))
        let gate = ControlledSelectionGate()
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { request in
                await gate.suspend(request)
                return box.apply(request)
            },
            openURL: { _ in nil }
        )
        controller.recordSuccessfulJump(source: a, target: b)
        controller.recordSuccessfulJump(source: b, target: c)

        let traversal = Task { @MainActor in await controller.goBack() }
        await gate.waitForCallCount(1)
        controller.invalidateNavigationIntents()
        await gate.resume(call: 0)

        let traversalResult = await traversal.value
        XCTAssertFalse(traversalResult)
        XCTAssertEqual(controller.backEntries, [a, b])
        XCTAssertTrue(controller.forwardEntries.isEmpty)
    }

    func testLifecycleAPIsKeepFallbackPathsValidAndRemoveDeadEntries() {
        let untitled = location("untitled", group: 0)
        let child = location(
            "child", path: "/workspace/old/child.swift", group: 0, line: 2
        )
        let target = location(
            "target", path: "/workspace/target.swift", group: 0, line: 3
        )
        let active = document("active", path: nil, text: "")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )
        controller.recordSuccessfulJump(source: untitled, target: child)
        controller.recordSuccessfulJump(source: child, target: target)

        controller.documentDidSave(
            documentID: "untitled", url: URL(fileURLWithPath: "/workspace/saved.swift")
        )
        controller.pathDidMove(
            from: URL(fileURLWithPath: "/workspace/old"),
            to: URL(fileURLWithPath: "/workspace/new")
        )
        XCTAssertEqual(controller.backEntries.map(\.path), [
            "/workspace/saved.swift", "/workspace/new/child.swift"
        ])

        controller.pathDidDelete(URL(fileURLWithPath: "/workspace/new"))
        XCTAssertEqual(controller.backEntries.map(\.documentID), ["untitled"])
        controller.documentDidClose(documentID: "untitled", url: nil)
        XCTAssertTrue(controller.backEntries.isEmpty)
        XCTAssertFalse(controller.canGoBack)
    }

    func testCommandRegistrationOwnsSixRoutesAndLeavesMatchingBracketToEditor() async throws {
        let active = document("active", path: nil, text: "func run() {}")
        let box = SnapshotBox(snapshot(
            documents: [active], activeDocumentID: active.id, group: 0
        ))
        let controller = NavigationController(
            snapshot: { box.value },
            selectDestination: { _ in nil },
            openURL: { _ in nil }
        )
        controller.recordSuccessfulJump(
            source: location("previous", group: 0),
            target: location("active", group: 0, line: 2)
        )
        let router = CommandRouter()

        let tokens = try controller.registerCommands(on: router)

        XCTAssertEqual(tokens.map(\.commandID), NavigationController.commandIDs)
        XCTAssertEqual(NavigationController.catalogNavigationCommandIDs.count, 7)
        XCTAssertEqual(
            router.status(
                for: NavigationController.matchingBracketCommandID,
                context: CommandRoutingContext(hasDocument: true)
            ),
            .unsupported
        )
        XCTAssertEqual(
            router.status(
                for: "navigate-back",
                context: CommandRoutingContext(hasNavigationHistory: true)
            ),
            .enabled
        )

        let result = await router.execute(
            "goto-symbol", context: CommandRoutingContext(hasDocument: true)
        )
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.mode, .symbol)
        XCTAssertEqual(controller.items.map(\.label), ["run"])
    }

    func testPalettePublishesStableAccessibilityContract() {
        XCTAssertEqual(NavigationPaletteView.Accessibility.palette, "Navigation Palette")
        XCTAssertEqual(NavigationPaletteView.Accessibility.query, "Navigation Query")
        XCTAssertEqual(NavigationPaletteView.Accessibility.loading, "Loading Navigation Results")
        XCTAssertEqual(NavigationPaletteView.Accessibility.results, "Navigation Results")
        XCTAssertEqual(
            NavigationPaletteView.Accessibility.openHint,
            "Opens this navigation location"
        )
        XCTAssertEqual(
            NavigationPaletteView.Accessibility.dismissIssue,
            "Dismiss Navigation Error"
        )
    }

    func testNavigationIssueCopyRerendersAndPreservesExternalFailures() {
        XCTAssertEqual(
            EditorLocale.enUS.localizedNavigationIssueTitle(.staleNavigation),
            "Stale Navigation"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedNavigationIssueTitle(.staleNavigation),
            "导航记录已过期"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedNavigationIssue(
                .workspace(.tooManyRoots(maximum: 3))
            ),
            "一个工作区最多支持 3 个根目录。"
        )
        let external = NavigationPresentationIssue.Message.verbatim(
            "The selected navigation location could not be opened."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedNavigationIssue(external),
            "The selected navigation location could not be opened."
        )
    }

    private func document(
        _ id: String, path: String?, text: String
    ) -> NavigationDocumentSnapshot {
        NavigationDocumentSnapshot(
            documentID: id,
            url: path.map { URL(fileURLWithPath: $0) },
            displayName: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? id,
            text: text
        )
    }

    private func snapshot(
        documents: [NavigationDocumentSnapshot],
        activeDocumentID: String?,
        group: Int,
        offset: Int = 0,
        roots: [URL] = []
    ) -> NavigationAppSnapshot {
        NavigationAppSnapshot(
            documents: documents,
            panes: [NavigationPaneSnapshot(
                groupID: group, activeDocumentID: activeDocumentID,
                cursorUTF16Offset: offset
            )],
            activeGroupID: group,
            workspaceRoots: roots
        )
    }

    private func location(
        _ id: String,
        path: String? = nil,
        group: Int,
        line: Int = 1,
        column: Int = 1
    ) -> NavigationLocation {
        NavigationLocation(
            documentID: id, path: path, groupID: group, line: line, column: column
        )
    }
}

@MainActor
private final class SnapshotBox {
    var value: NavigationAppSnapshot

    init(_ value: NavigationAppSnapshot) {
        self.value = value
    }

    func apply(_ request: NavigationSelectionRequest) -> NavigationLocation? {
        guard let document = value.document(id: request.documentID),
              let paneIndex = value.panes.firstIndex(where: {
                  $0.groupID == request.groupID
              }) else { return nil }
        let line = max(1, request.line ?? 1)
        let column = max(1, request.column ?? 1)
        let start = request.utf16Offset
            ?? Self.utf16Offset(line: line, column: column, text: document.text)
        let requestedOffset = start.addingReportingOverflow(
            request.selectionUTF16Length ?? 0
        )
        let offset = min(
            document.text.utf16.count,
            requestedOffset.overflow ? Int.max : requestedOffset.partialValue
        )
        var panes = value.panes
        panes[paneIndex] = NavigationPaneSnapshot(
            groupID: request.groupID, activeDocumentID: document.id,
            cursorUTF16Offset: offset
        )
        value = NavigationAppSnapshot(
            documents: value.documents, panes: panes,
            activeGroupID: request.groupID, workspaceRoots: value.workspaceRoots
        )
        return value.currentLocation
    }

    static func utf16Offset(line: Int, column: Int, text: String) -> Int {
        let units = Array(text.utf16)
        var currentLine = 1
        var index = 0
        while index < units.count, currentLine < line {
            if units[index] == 0x0a { currentLine += 1 }
            index += 1
        }
        return min(units.count, index + column - 1)
    }
}

@MainActor
private final class NavigationContextGenerationBox {
    @Published private(set) var value: UInt64 = 0

    var publisher: AnyPublisher<UInt64, Never> {
        $value.eraseToAnyPublisher()
    }

    func advance() { value &+= 1 }
}

@MainActor
private final class NavigationRootSnapshotBox {
    @Published private(set) var value = WorkspaceRootSnapshot.empty

    var publisher: AnyPublisher<WorkspaceRootSnapshot, Never> {
        $value.eraseToAnyPublisher()
    }

    func advance() {
        value = WorkspaceRootSnapshot(
            roots: value.roots, generation: value.generation &+ 1
        )
    }

    func advanceWithoutNotifying() {
        // Direct backing storage gives the synchronous provider a newer value
        // while intentionally omitting a subscription from the controller.
        value = WorkspaceRootSnapshot(
            roots: value.roots, generation: value.generation &+ 1
        )
    }
}

private actor ControlledFileProvider {
    private var nextCall = 0
    private var continuations: [
        Int: CheckedContinuation<[NavigationFileSnapshot], Never>
    ] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(_ snapshot: NavigationAppSnapshot) async -> [NavigationFileSnapshot] {
        _ = snapshot
        let call = nextCall
        nextCall += 1
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
            resumeSatisfiedWaiters()
        }
    }

    var callCount: Int { nextCall }

    func waitForCallCount(_ count: Int) async {
        guard nextCall < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func resume(call: Int, files: [NavigationFileSnapshot]) {
        continuations.removeValue(forKey: call)?.resume(returning: files)
    }

    private func resumeSatisfiedWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in waiters {
            if nextCall >= count {
                continuation.resume()
            } else {
                pending.append((count, continuation))
            }
        }
        waiters = pending
    }
}

private actor ControlledSelectionGate {
    private var requests: [NavigationSelectionRequest] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspend(_ request: NavigationSelectionRequest) async {
        let call = requests.count
        requests.append(request)
        await withCheckedContinuation { continuation in
            continuations[call] = continuation
            resumeSatisfiedWaiters()
        }
    }

    var callCount: Int { requests.count }
    var requestedDocumentIDs: [String] { requests.map(\.documentID) }

    func waitForCallCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func resume(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }

    private func resumeSatisfiedWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in waiters {
            if requests.count >= count {
                continuation.resume()
            } else {
                pending.append((count, continuation))
            }
        }
        waiters = pending
    }
}
