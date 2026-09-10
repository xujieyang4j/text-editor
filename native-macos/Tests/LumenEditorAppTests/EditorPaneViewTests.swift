import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class EditorPaneViewTests: XCTestCase {
    func testQuickActionsMatchDocumentCapabilitiesInStableOrder() {
        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                isMarkdown: true, isHTML: false, isJSON: false,
                distractionFree: false
            ),
            [.toggleMarkdownPreview]
        )
        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                isMarkdown: false, isHTML: true, isJSON: false,
                distractionFree: false
            ),
            [.openHTMLInBrowser]
        )
        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                isMarkdown: false, isHTML: false, isJSON: true,
                distractionFree: false
            ),
            [.formatJSON, .compactJSON, .toggleJSONView]
        )
    }

    func testQuickActionsUseManualLanguageCapabilitiesAndFollowChromeRule() {
        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                isMarkdown: true, isHTML: true, isJSON: false,
                distractionFree: false
            ),
            [.toggleMarkdownPreview, .openHTMLInBrowser]
        )
        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                isMarkdown: true, isHTML: true, isJSON: true,
                distractionFree: true
            ),
            []
        )
    }

    @MainActor
    func testQuickActionsClassifyExtensionsAndManualLanguages() {
        let markdownByExtension = document(
            id: "markdown-file", fileURL: URL(fileURLWithPath: "/tmp/README.MDX"),
            language: "Plain Text", languageLocked: false
        )
        let htmlByLanguage = document(
            id: "manual-html", fileURL: nil, language: "html"
        )
        let jsonByLanguage = document(
            id: "manual-json", fileURL: URL(fileURLWithPath: "/tmp/data.txt"),
            language: "json"
        )

        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                for: markdownByExtension, distractionFree: false
            ),
            [.toggleMarkdownPreview]
        )
        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                for: htmlByLanguage, distractionFree: false
            ),
            [.openHTMLInBrowser]
        )
        XCTAssertEqual(
            EditorPaneQuickActionPlan.actions(
                for: jsonByLanguage, distractionFree: false
            ),
            [.formatJSON, .compactJSON, .toggleJSONView]
        )
    }

    func testUntitledTabCannotCopyEitherPath() {
        let plan = EditorPaneTabPathPlan.make(
            fileURL: nil, workspaceRoots: [URL(fileURLWithPath: "/work")]
        )

        XCTAssertFalse(plan.canCopyAbsolutePath)
        XCTAssertFalse(plan.canCopyRelativePath)
        XCTAssertNil(plan.fileURL)
        XCTAssertNil(plan.workspaceRoot)
    }

    func testSavedTabOutsideWorkspaceCanCopyOnlyAbsolutePath() {
        let fileURL = URL(fileURLWithPath: "/external/notes.txt")
        let plan = EditorPaneTabPathPlan.make(
            fileURL: fileURL, workspaceRoots: [URL(fileURLWithPath: "/work")]
        )

        XCTAssertTrue(plan.canCopyAbsolutePath)
        XCTAssertFalse(plan.canCopyRelativePath)
        XCTAssertEqual(plan.fileURL?.path, fileURL.path)
        XCTAssertNil(plan.workspaceRoot)
    }

    func testRelativePathUsesMostSpecificNestedWorkspaceRoot() {
        let outer = URL(fileURLWithPath: "/work", isDirectory: true)
        let nested = outer.appendingPathComponent("Packages/Feature", isDirectory: true)
        let fileURL = nested.appendingPathComponent("Sources/View.swift")
        let plan = EditorPaneTabPathPlan.make(
            fileURL: fileURL, workspaceRoots: [outer, nested]
        )

        XCTAssertTrue(plan.canCopyAbsolutePath)
        XCTAssertTrue(plan.canCopyRelativePath)
        XCTAssertEqual(plan.workspaceRoot?.path, nested.path)
    }

    func testWorkspaceContainmentDoesNotUseAmbiguousStringPrefixes() {
        let plan = EditorPaneTabPathPlan.make(
            fileURL: URL(fileURLWithPath: "/workspace-other/file.txt"),
            workspaceRoots: [URL(fileURLWithPath: "/workspace")]
        )

        XCTAssertFalse(plan.canCopyRelativePath)
    }

    @MainActor
    func testTabPathActionCapturesBackgroundTabInsteadOfLaterSelection() async {
        let selectedURL = URL(fileURLWithPath: "/work/selected.txt")
        let backgroundURL = URL(fileURLWithPath: "/work/background.txt")
        let target = EditorPaneTabPathAction(
            documentID: "background", fileURL: backgroundURL
        )
        var copied: [(URL, Bool)] = []

        XCTAssertTrue(await target.perform(relativeToWorkspace: true) { url, relative in
            copied.append((url, relative))
            return true
        })

        XCTAssertEqual(target.documentID, "background")
        XCTAssertEqual(copied.map { $0.0.path }, [backgroundURL.path])
        XCTAssertEqual(copied.map(\.1), [true])
        XCTAssertNotEqual(copied.first?.0, selectedURL)
    }

    @MainActor
    func testUntitledTabPathActionDoesNotInvokeClipboardSeam() async {
        let target = EditorPaneTabPathAction(
            documentID: "untitled", fileURL: nil
        )
        var invocationCount = 0

        XCTAssertFalse(await target.perform(relativeToWorkspace: false) { _, _ in
            invocationCount += 1
            return true
        })
        XCTAssertEqual(invocationCount, 0)
    }

    func testEveryQuickActionForwardsToAProductionCommandID() {
        XCTAssertEqual(
            EditorPaneQuickAction.allCases.map(\.commandID),
            [
                "toggle-preview", "open-in-browser", "format-json",
                "compact-json", "toggle-json-view"
            ]
        )
        XCTAssertTrue(EditorPaneQuickAction.allCases.allSatisfy { action in
            CommandCatalog.command(id: action.commandID) != nil
        })
    }

    func testQuickActionTargetRequiresTheOriginalPaneAndDocument() {
        let target = EditorPaneQuickActionTarget(
            paneIndex: 1, paneID: "pane-b", documentID: "document-b"
        )

        XCTAssertTrue(target.isCurrent(
            paneIndex: 1, paneID: "pane-b", paneContainsDocument: true
        ))
        XCTAssertFalse(target.isCurrent(
            paneIndex: 0, paneID: "pane-a", paneContainsDocument: true
        ))
        XCTAssertFalse(target.isCurrent(
            paneIndex: 1, paneID: "replacement-pane",
            paneContainsDocument: true
        ))
        XCTAssertFalse(target.isCurrent(
            paneIndex: 1, paneID: "pane-b", paneContainsDocument: false
        ))
    }

    @MainActor
    private func document(
        id: String, fileURL: URL?, language: String, languageLocked: Bool = true
    ) -> EditorDocument {
        EditorDocument(
            sessionDocumentID: id, fileURL: fileURL,
            displayName: fileURL?.lastPathComponent ?? "Untitled",
            text: "", savedText: "", language: language,
            languageLocked: languageLocked
        )
    }
}
