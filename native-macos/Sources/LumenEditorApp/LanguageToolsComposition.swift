import Foundation
import LumenEditorCore

/// Composition-root helpers for wiring Format Document without giving the Core
/// process layer direct access to AppModel or SwiftUI presentation state.
@MainActor
enum LanguageToolsComposition {
    typealias ChooseExecutable = @MainActor (EditorLocale) async -> URL?

    /// Required composition-root wiring:
    /// 1. Create with the window's shared approval store and scope.
    /// 2. Retain the returned controller as a StateObject.
    /// 3. Retain tokens from registerCommands(replaceExisting: true).
    /// 4. Present LanguageToolsConfigurationView and the exact-approval dialog.
    /// 5. Cancel on workspace replacement and application shutdown.
    static func makeController(
        model: AppModel,
        workspace: WorkspaceController,
        projectSettings: ProjectSettingsController,
        approvals: ToolApprovalStore,
        approvalScope: ToolApprovalScope,
        languageServers: LanguageServerController,
        runner: any ToolCommandRunning = ToolProcessRunner(),
        locale: @escaping @MainActor () -> EditorLocale = { .zhCN },
        chooseExecutable: @escaping ChooseExecutable = { _ in nil },
        securityScopedAccess: SecurityScopedAccessController = .shared
    ) -> LanguageToolsController {
        let service = LanguageToolService(
            runner: runner, approvals: approvals, approvalScope: approvalScope
        )
        return LanguageToolsController(
            tool: service,
            snapshot: { snapshot(model: model, workspace: workspace) },
            workspace: { primaryRoot(workspace) },
            language: { model.selectedDocument?.language ?? LanguageCatalog.plainTextName },
            configuration: { projectSettings.languageTool(for: $0) },
            languageServerConfiguration: {
                projectSettings.settings.languageServers[$0]
            },
            saveConfiguration: { language, configuration in
                guard projectSettings.saveLanguageTool(configuration, for: language) else {
                    throw LanguageToolsCompositionError.projectSettingsSaveFailed(
                        projectSettings.issue?.content
                    )
                }
            },
            applyResult: { apply($0, model: model, workspace: workspace) },
            formatWithLanguageServer: { snapshot in
                guard let request = languageServerRequest(
                        snapshot: snapshot, project: projectSettings.settings
                      ) else { return nil }
                guard let result = try await languageServers.formatForDocument(request) else {
                    return nil
                }
                return try languageToolResult(
                    from: result, source: snapshot.text
                )
            },
            approveLanguageServer: { configuration in
                await languageServers.approveForDocumentFormatting(configuration)
            },
            chooseExecutable: { await chooseExecutable(locale()) },
            securityScopedAccess: securityScopedAccess
        )
    }

    /// LSP precedence is selected only for a saved document contained by its
    /// authorised workspace and configured under the exact display language.
    nonisolated static func languageServerRequest(
        snapshot: LanguageToolDocumentSnapshot,
        project: ProjectSettings
    ) -> LanguageServerRequest? {
        guard let root = snapshot.workspaceRoot,
              let fileURL = snapshot.fileURL,
              contains(root: root, candidate: fileURL),
              let configuration = project.languageServers[snapshot.language]
        else { return nil }
        return LanguageServerRequest(
            root: root.path,
            config: configuration,
            content: snapshot.text,
            filePath: fileURL.path,
            languageId: snapshot.language.lowercased().replacingOccurrences(
                of: " ", with: "-"
            )
        )
    }

    nonisolated static func languageToolResult(
        from result: LanguageServerResult, source: String
    ) throws -> LanguageToolResult {
        guard !result.edits.isEmpty else {
            return LanguageToolResult(
                diagnostics: result.diagnostics.map(languageToolDiagnostic)
            )
        }
        let edits = try result.edits.map { edit -> TextEdit in
            let start = try utf16Offset(
                zeroBasedLine: edit.startLine,
                character: edit.startCharacter,
                in: source
            )
            let end = try utf16Offset(
                zeroBasedLine: edit.endLine,
                character: edit.endCharacter,
                in: source
            )
            guard end >= start else {
                throw LanguageToolsCompositionError.invalidLanguageServerEdit
            }
            return TextEdit(from: start, to: end, insert: edit.newText)
        }
        let transaction = try TextTransaction(edits: edits)
        return LanguageToolResult(
            content: try transaction.applying(to: source),
            diagnostics: result.diagnostics.map(languageToolDiagnostic)
        )
    }

    static func snapshot(
        model: AppModel, workspace: WorkspaceController
    ) -> LanguageToolDocumentSnapshot? {
        let paneIndex = model.paneLayout.activePaneIndex
        guard model.paneLayout.panes.indices.contains(paneIndex),
              let document = model.activeDocument(inPaneAt: paneIndex) else { return nil }
        let root = document.fileURL.flatMap { file in
            workspace.roots
                .filter { contains(root: $0.url, candidate: file) }
                .max { $0.url.path.count < $1.url.path.count }?.url
        } ?? primaryRoot(workspace)
        return LanguageToolDocumentSnapshot(
            documentID: document.sessionDocumentID,
            paneIndex: paneIndex,
            viewID: model.paneLayout.panes[paneIndex].viewID,
            bufferRevision: document.buffer.revision,
            text: document.buffer.text,
            language: document.language,
            fileURL: document.fileURL,
            workspaceRoot: root
        )
    }

    /// Applies exactly one full-document transaction. expectedRevision makes
    /// the mutation fail closed if any edit arrived after the formatter input
    /// snapshot; AppModel supplies the undo/session bookkeeping.
    static func apply(
        _ request: LanguageToolApplyRequest,
        model: AppModel,
        workspace: WorkspaceController
    ) -> Bool {
        guard let current = snapshot(model: model, workspace: workspace),
              current.documentID == request.snapshot.documentID,
              current.paneIndex == request.snapshot.paneIndex,
              current.viewID == request.snapshot.viewID,
              current.bufferRevision == request.snapshot.bufferRevision,
              current.workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath()
                == request.snapshot.workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath(),
              let document = model.document(
                sessionDocumentID: request.snapshot.documentID
              ) else { return false }

        guard let replacement = request.replacementContent else { return true }
        guard let transaction = try? TextTransaction(
            edits: [TextEdit(
                from: 0, to: request.snapshot.text.utf16.count,
                insert: replacement
            )],
            expectedRevision: request.snapshot.bufferRevision
        ) else { return false }
        return model.apply(
            transaction, to: document, inPaneAt: request.snapshot.paneIndex
        )
    }

    private static func primaryRoot(_ workspace: WorkspaceController) -> URL? {
        workspace.roots.first(where: \.isPrimary)?.url ?? workspace.roots.first?.url
    }

    nonisolated private static func contains(root: URL, candidate: URL) -> Bool {
        let root = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let candidate = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidate.count >= root.count else { return false }
        return zip(root, candidate).allSatisfy { $0.0 == $0.1 }
    }

    nonisolated private static func utf16Offset(
        zeroBasedLine: Int, character: Int, in text: String
    ) throws -> Int {
        guard zeroBasedLine >= 0, character >= 0 else {
            throw LanguageToolsCompositionError.invalidLanguageServerEdit
        }
        let units = Array(text.utf16)
        var line = 0
        var start = 0
        while start < units.count, line < zeroBasedLine {
            if units[start] == 0x0a { line += 1 }
            start += 1
        }
        guard line == zeroBasedLine else {
            throw LanguageToolsCompositionError.invalidLanguageServerEdit
        }
        var end = start
        while end < units.count, units[end] != 0x0a { end += 1 }
        guard character <= end - start else {
            throw LanguageToolsCompositionError.invalidLanguageServerEdit
        }
        return start + character
    }

    nonisolated private static func languageToolDiagnostic(
        _ diagnostic: LanguageServerDiagnostic
    ) -> LanguageToolDiagnostic {
        let severity: LanguageToolDiagnosticSeverity = switch diagnostic.severity {
        case .error: .error
        case .warning: .warning
        case .info: .info
        }
        return LanguageToolDiagnostic(
            line: diagnostic.line,
            column: diagnostic.column,
            endLine: diagnostic.endLine,
            endColumn: diagnostic.endColumn,
            severity: severity,
            message: diagnostic.message
        )
    }
}

enum LanguageToolsCompositionError: Error, Equatable, LocalizedError, Sendable {
    case projectSettingsSaveFailed(ProjectSettingsPresentationIssue.Message?)
    case invalidLanguageServerEdit

    var errorDescription: String? {
        switch self {
        case let .projectSettingsSaveFailed(content):
            return content.map(EditorLocale.enUS.localizedProjectSettingsIssue)
                ?? "The language-tool project setting could not be saved."
        case .invalidLanguageServerEdit:
            return "The language server returned an invalid or overlapping formatting edit."
        }
    }
}
