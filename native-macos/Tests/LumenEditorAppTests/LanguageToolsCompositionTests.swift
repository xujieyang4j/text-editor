import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class LanguageToolsCompositionTests: XCTestCase {
    func testBuildsFormattingRequestForExactCurrentLanguage() {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let file = root.appendingPathComponent("main.swift")
        let snapshot = LanguageToolDocumentSnapshot(
            documentID: "document", paneIndex: 0, viewID: "view",
            bufferRevision: 9, text: "let value = 1", language: "Swift",
            fileURL: file, workspaceRoot: root
        )
        let config = LanguageServerConfig(command: "sourcekit-lsp", args: ["--stdio"])

        let request = LanguageToolsComposition.languageServerRequest(
            snapshot: snapshot,
            project: ProjectSettings(languageServers: ["Swift": config])
        )

        XCTAssertEqual(request?.root, root.path)
        XCTAssertEqual(request?.filePath, file.path)
        XCTAssertEqual(request?.content, snapshot.text)
        XCTAssertEqual(request?.languageId, "swift")
        XCTAssertEqual(request?.config, config)
        XCTAssertNil(LanguageToolsComposition.languageServerRequest(
            snapshot: snapshot,
            project: ProjectSettings(languageServers: ["swift": config])
        ), "Language display-name lookup remains exact for project compatibility")

        let outside = LanguageToolDocumentSnapshot(
            documentID: snapshot.documentID,
            paneIndex: snapshot.paneIndex,
            viewID: snapshot.viewID,
            bufferRevision: snapshot.bufferRevision,
            text: snapshot.text,
            language: snapshot.language,
            fileURL: URL(fileURLWithPath: "/tmp/outside.swift"),
            workspaceRoot: root
        )
        XCTAssertNil(LanguageToolsComposition.languageServerRequest(
            snapshot: outside,
            project: ProjectSettings(languageServers: ["Swift": config])
        ))
    }

    func testConvertsZeroBasedUTF16FormattingEditsAtomically() throws {
        let source = "first🙂\nsecond\nthird"
        let result = LanguageServerResult(
            edits: [
                LanguageServerTextEdit(
                    startLine: 0, startCharacter: 5,
                    endLine: 0, endCharacter: 7,
                    newText: "!"
                ),
                LanguageServerTextEdit(
                    startLine: 1, startCharacter: 0,
                    endLine: 1, endCharacter: 6,
                    newText: "SECOND"
                )
            ],
            diagnostics: [LanguageServerDiagnostic(
                line: 2, column: 1, severity: .warning, message: "style"
            )]
        )

        let converted = try LanguageToolsComposition.languageToolResult(
            from: result, source: source
        )

        XCTAssertEqual(converted.content, "first!\nSECOND\nthird")
        XCTAssertEqual(converted.diagnostics, [LanguageToolDiagnostic(
            line: 2, column: 1, severity: .warning, message: "style"
        )])
    }

    func testRejectsOutOfRangeAndOverlappingFormattingEdits() {
        let outOfRange = LanguageServerResult(edits: [LanguageServerTextEdit(
            startLine: 20, startCharacter: 0,
            endLine: 20, endCharacter: 1,
            newText: "x"
        )], diagnostics: [])
        XCTAssertThrowsError(try LanguageToolsComposition.languageToolResult(
            from: outOfRange, source: "one line"
        ))

        let overlapping = LanguageServerResult(edits: [
            LanguageServerTextEdit(
                startLine: 0, startCharacter: 0,
                endLine: 0, endCharacter: 3,
                newText: "a"
            ),
            LanguageServerTextEdit(
                startLine: 0, startCharacter: 2,
                endLine: 0, endCharacter: 5,
                newText: "b"
            )
        ], diagnostics: [])
        XCTAssertThrowsError(try LanguageToolsComposition.languageToolResult(
            from: overlapping, source: "abcdef"
        ))
    }

    func testLSPNoEditsPreservesDiagnosticsWithoutReplacingText() throws {
        let result = try LanguageToolsComposition.languageToolResult(
            from: LanguageServerResult(
                edits: [],
                diagnostics: [LanguageServerDiagnostic(
                    line: 1, column: 2, endLine: 1, endColumn: 4,
                    severity: .info, message: "hint"
                )]
            ),
            source: "unchanged"
        )

        XCTAssertNil(result.content)
        XCTAssertEqual(result.diagnostics, [LanguageToolDiagnostic(
            line: 1, column: 2, endLine: 1, endColumn: 4,
            severity: .info, message: "hint"
        )])
    }

    @MainActor
    func testExecutablePickerReceivesCurrentInjectedLocale() async {
        let sessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanguageToolsCompositionTests-\(UUID().uuidString)")
        let model = AppModel(
            sessionStore: SessionStore(sessionURL: sessionURL),
            createInitialDocument: false
        )
        let workspace = WorkspaceController(
            maximumEditableByteCount: model.maximumEditableByteCount,
            openDocumentURLs: { [] },
            openFile: { _ in }
        )
        let projectSettings = ProjectSettingsController()
        let approvals = ToolApprovalStore()
        let scope = ToolApprovalScope(windowID: "test-window", sessionID: "test-session")
        let languageServers = LanguageServerController()
        var currentLocale: EditorLocale = .zhCN
        var receivedLocales: [EditorLocale] = []

        let controller = LanguageToolsComposition.makeController(
            model: model,
            workspace: workspace,
            projectSettings: projectSettings,
            approvals: approvals,
            approvalScope: scope,
            languageServers: languageServers,
            locale: { currentLocale },
            chooseExecutable: { locale in
                receivedLocales.append(locale)
                return nil
            }
        )

        await controller.chooseExecutable()
        currentLocale = .enUS
        await controller.chooseExecutable()

        XCTAssertEqual(receivedLocales, [.zhCN, .enUS])
    }
}
