import AppKit
import Combine
import Foundation
import LumenEditorCore

struct RenameWriteCommitIssue: Equatable {
    let durabilityConfirmed: Bool
    let cleanupCompleted: Bool
    let recoveryArtifact: URL?
}

enum NativeFeatureIntegrationError: Error, LocalizedError {
    case renameRequiresReview(editCount: Int)
    case renameUnavailable(String)
    case renameInvalidRange(URL)
    case renameOverlappingEdits(URL)
    case renameRollbackFailed(URL)
    case renameCommitIncomplete(
        target: URL, issue: RenameWriteCommitIssue, rollbackFailure: String?
    )
    case renameStateIndeterminate(
        target: URL, recoveryArtifact: URL?, rollbackFailure: String?
    )
    case renamePrecommitCleanupFailed(
        target: URL, recoveryArtifact: URL?, rollbackFailure: String?
    )

    var errorDescription: String? {
        switch self {
        case let .renameRequiresReview(count):
            return "The language server proposed \(count) rename edits. A safe cross-file review is required before they can be applied."
        case let .renameUnavailable(message): return message
        case let .renameInvalidRange(url):
            return "The language server returned an invalid range for \(url.lastPathComponent)."
        case let .renameOverlappingEdits(url):
            return "The language server returned overlapping edits for \(url.lastPathComponent)."
        case let .renameRollbackFailed(url):
            return "Rename failed and \(url.lastPathComponent) could not be restored automatically."
        case let .renameCommitIncomplete(target, issue, rollbackFailure):
            var uncertainties: [String] = []
            if !issue.durabilityConfirmed {
                uncertainties.append("the directory commit's durability was not confirmed")
            }
            if !issue.cleanupCompleted {
                uncertainties.append("cleanup was not confirmed")
            }
            let reason = uncertainties.isEmpty
                ? "the write result was incomplete" : uncertainties.joined(separator: " and ")
            return "Rename wrote \(target.lastPathComponent), but \(reason)."
                + Self.recoveryDetail(
                    issue.recoveryArtifact, cleanupWasUncertain: !issue.cleanupCompleted,
                    rollbackFailure: rollbackFailure
                )
        case let .renameStateIndeterminate(target, artifact, rollbackFailure):
            return "Rename left \(target.lastPathComponent) in an indeterminate state."
                + Self.recoveryDetail(
                    artifact, cleanupWasUncertain: false,
                    rollbackFailure: rollbackFailure
                )
        case let .renamePrecommitCleanupFailed(target, artifact, rollbackFailure):
            return "Rename did not commit \(target.lastPathComponent), and pre-commit cleanup failed."
                + Self.recoveryDetail(
                    artifact, cleanupWasUncertain: true,
                    rollbackFailure: rollbackFailure
                )
        }
    }

    func localizedDescription(for locale: EditorLocale) -> String {
        guard locale.isSimplifiedChinese else { return errorDescription ?? "" }
        switch self {
        case let .renameRequiresReview(count):
            return "语言服务器提出了 \(count) 项重命名编辑。应用前必须进行安全的跨文件审查。"
        case let .renameUnavailable(message):
            return message
        case let .renameInvalidRange(url):
            return "语言服务器为 \(url.lastPathComponent) 返回了无效范围。"
        case let .renameOverlappingEdits(url):
            return "语言服务器为 \(url.lastPathComponent) 返回了重叠编辑。"
        case let .renameRollbackFailed(url):
            return "重命名失败，且无法自动恢复 \(url.lastPathComponent)。"
        case let .renameCommitIncomplete(target, issue, rollbackFailure):
            var uncertainties: [String] = []
            if !issue.durabilityConfirmed { uncertainties.append("目录提交持久性尚未确认") }
            if !issue.cleanupCompleted { uncertainties.append("清理尚未确认") }
            let reason = uncertainties.isEmpty
                ? "写入结果不完整" : uncertainties.joined(separator: "，且")
            return "已写入 \(target.lastPathComponent)，但\(reason)。"
                + Self.localizedRecoveryDetail(
                    issue.recoveryArtifact, cleanupWasUncertain: !issue.cleanupCompleted,
                    rollbackFailure: rollbackFailure
                )
        case let .renameStateIndeterminate(target, artifact, rollbackFailure):
            return "重命名后 \(target.lastPathComponent) 的状态无法确定。"
                + Self.localizedRecoveryDetail(
                    artifact, cleanupWasUncertain: false,
                    rollbackFailure: rollbackFailure
                )
        case let .renamePrecommitCleanupFailed(target, artifact, rollbackFailure):
            return "未提交 \(target.lastPathComponent) 的重命名，且提交前清理失败。"
                + Self.localizedRecoveryDetail(
                    artifact, cleanupWasUncertain: true,
                    rollbackFailure: rollbackFailure
                )
        }
    }

    private static func recoveryDetail(
        _ artifact: URL?, cleanupWasUncertain: Bool, rollbackFailure: String?
    ) -> String {
        let recovery = artifact.map { " Recovery data is available at \($0.path)." }
            ?? (cleanupWasUncertain
                ? " Cleanup is uncertain, but no recovery artifact path is available."
                : " No recovery artifact path is available.")
        return recovery + rollbackFailure.map {
            " Automatic rollback also failed: \($0)"
        }.orEmpty
    }

    private static func localizedRecoveryDetail(
        _ artifact: URL?, cleanupWasUncertain: Bool, rollbackFailure: String?
    ) -> String {
        let recovery = artifact.map { " 恢复数据位于：\($0.path)。" }
            ?? (cleanupWasUncertain
                ? " 清理状态不确定，且没有可用的恢复文件路径。"
                : " 没有可用的恢复文件路径。")
        return recovery + rollbackFailure.map {
            " 自动回滚也失败：\($0)"
        }.orEmpty
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// Composition helpers shared by the native command, find, navigation, and
/// preview controllers. Keeping these adapters in one place makes pane identity
/// and revision checks explicit at every asynchronous boundary.
@MainActor
enum NativeFeatureCoordinator {
    enum RenameWriteDisposition: Equatable {
        case notWritten(actualRevision: String)
        case written(revision: String, issue: RenameWriteCommitIssue?)
    }

    static let maximumSymbolIdentifierUTF16Length = 256
    static let maximumIndexedDefinitionResults = 200

    /// Returns the explicit main selection when it is an identifier, otherwise
    /// the identifier under (or immediately before) the main cursor. Offsets
    /// are UTF-16, matching AppModel selections and NSString/AppKit APIs.
    static func selectedIdentifier(
        in text: String,
        selection: SelectionSet,
        maximumUTF16Length: Int = maximumSymbolIdentifierUTF16Length
    ) -> String? {
        guard maximumUTF16Length > 0 else { return nil }
        let source = text as NSString
        let selectedRange = selection.main.range
        if selectedRange.length > 0 {
            return identifier(
                in: source, range: selectedRange,
                maximumUTF16Length: maximumUTF16Length
            )
        }

        let cursor = selection.main.head
        guard cursor >= 0, cursor <= source.length else { return nil }
        var seed: NSRange?
        if cursor < source.length {
            let candidate = source.rangeOfComposedCharacterSequence(at: cursor)
            if isIdentifierContinuation(source.substring(with: candidate)) {
                seed = candidate
            }
        }
        if seed == nil, cursor > 0 {
            let candidate = source.rangeOfComposedCharacterSequence(at: cursor - 1)
            if isIdentifierContinuation(source.substring(with: candidate)) {
                seed = candidate
            }
        }
        guard var range = seed else { return nil }

        while range.location > 0 {
            let previous = source.rangeOfComposedCharacterSequence(
                at: range.location - 1
            )
            guard isIdentifierContinuation(source.substring(with: previous)) else { break }
            let nextLength = NSMaxRange(range) - previous.location
            guard nextLength <= maximumUTF16Length else { return nil }
            range = NSRange(location: previous.location, length: nextLength)
        }
        while NSMaxRange(range) < source.length {
            let next = source.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
            guard isIdentifierContinuation(source.substring(with: next)) else { break }
            let nextLength = NSMaxRange(next) - range.location
            guard nextLength <= maximumUTF16Length else { return nil }
            range.length = nextLength
        }
        return identifier(
            in: source, range: range, maximumUTF16Length: maximumUTF16Length
        )
    }

    static func localDefinition(
        named identifier: String, in text: String
    ) -> DocumentSymbol? {
        SymbolExtractor.extract(from: text).first { $0.label == identifier }
    }

    static func isCaseSensitiveReferenceIdentifier(_ identifier: String) -> Bool {
        identifier.rangeOfCharacter(from: .uppercaseLetters) != nil
    }

    private static func identifier(
        in source: NSString, range: NSRange, maximumUTF16Length: Int
    ) -> String? {
        guard range.location >= 0, range.length > 0,
              range.length <= maximumUTF16Length else { return nil }
        let end = range.location.addingReportingOverflow(range.length)
        guard !end.overflow, end.partialValue <= source.length,
              NSEqualRanges(
                  source.rangeOfComposedCharacterSequences(for: range), range
              ) else { return nil }
        let value = source.substring(with: range)
        for (index, character) in value.enumerated() {
            guard isIdentifierCluster(
                String(character), allowsLeadingNumber: index > 0
            ) else { return nil }
        }
        return value
    }

    private static func isIdentifierContinuation(_ cluster: String) -> Bool {
        isIdentifierCluster(cluster, allowsLeadingNumber: true)
    }

    private static func isIdentifierCluster(
        _ cluster: String, allowsLeadingNumber: Bool
    ) -> Bool {
        guard let first = cluster.unicodeScalars.first else { return false }
        let isMarker = first.value == 0x5F || first.value == 0x24
        let isLetter = CharacterSet.letters.contains(first)
        let isNumber = CharacterSet.decimalDigits.contains(first)
        guard isMarker || isLetter || (allowsLeadingNumber && isNumber) else {
            return false
        }
        return cluster.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.nonBaseCharacters.contains($0)
        }
    }

    static func navigationLocation(
        model: AppModel, document: EditorDocument, utf16Offset: Int
    ) -> NavigationLocation? {
        guard let paneIndex = model.paneLayout.panes.firstIndex(where: {
            $0.viewID == model.paneLayout.activeViewID
                && $0.contains(document.sessionDocumentID)
        }) else { return nil }
        let snapshot = NavigationDocumentSnapshot(
            documentID: document.sessionDocumentID, url: document.fileURL,
            displayName: document.displayName, text: document.buffer.text
        )
        let position = snapshot.lineColumn(atUTF16Offset: utf16Offset)
        return NavigationLocation(
            documentID: document.sessionDocumentID,
            path: document.fileURL?.path, groupID: paneIndex,
            line: position.line, column: position.column
        )
    }

    static func makeFindController(model: AppModel) -> FindBarController {
        FindBarController(
            snapshot: { findSnapshot(model: model) },
            selectMatch: { request in
                guard let document = matchingDocument(
                    request.identity, expectedRevision: request.expectedBufferRevision,
                    model: model
                ) else { return false }
                let range = request.selectedRange
                let selection = SelectionSet.single(
                    anchor: range.location,
                    head: range.location + range.length
                )
                return model.setSelections(
                    selection, for: document, inPaneAt: request.identity.paneIndex
                )
            },
            applyEdits: { request in
                guard let document = matchingDocument(
                    request.identity, expectedRevision: request.expectedBufferRevision,
                    model: model
                ) else { return false }
                let selection = request.selectionAfter.map { range in
                    SelectionSet.single(
                        anchor: range.location,
                        head: range.location + range.length
                    )
                }
                guard let transaction = try? TextTransaction(
                    edits: request.edits,
                    selection: selection,
                    expectedRevision: request.expectedBufferRevision
                ) else { return false }
                return model.apply(
                    transaction, to: document, inPaneAt: request.identity.paneIndex
                )
            }
        )
    }

    static func findSnapshot(model: AppModel) -> FindDocumentSnapshot? {
        let paneIndex = model.paneLayout.activePaneIndex
        guard model.paneLayout.panes.indices.contains(paneIndex),
              let document = model.activeDocument(inPaneAt: paneIndex) else { return nil }
        let viewID = model.paneLayout.panes[paneIndex].viewID
        return FindDocumentSnapshot(
            documentID: document.sessionDocumentID,
            viewID: viewID,
            paneIndex: paneIndex,
            text: document.buffer.text,
            selectedRange: model.selection(
                for: document.sessionDocumentID, viewID: viewID
            ).main.range,
            bufferRevision: document.buffer.revision
        )
    }

    static func makeNavigationController(
        model: AppModel,
        workspace: WorkspaceController,
        actions: EditorActionController
    ) -> NavigationController {
        NavigationController(
            workspaceRootSnapshot: {
                workspace.rootSnapshot
            },
            workspaceRootChanges: workspace.$rootSnapshot
                .eraseToAnyPublisher(),
            contextGeneration: {
                workspace.projectExclusionGeneration
            },
            contextGenerationChanges: workspace.$projectExclusionSnapshot
                .map(\.generation)
                .eraseToAnyPublisher(),
            snapshot: { navigationSnapshot(model: model, workspace: workspace) },
            workspaceFiles: { snapshot in
                let exclusionSnapshot = workspace.projectExclusionSnapshot
                let roots = await workspace.service.registeredRoots()
                let listing = try await workspace.service.recursiveFiles(
                    in: roots.map(\.id),
                    exclusions: exclusionSnapshot.policy
                )
                return listing.files.map { url in
                    NavigationFileSnapshot(
                        url: url,
                        displayPath: displayPath(for: url, roots: roots)
                    )
                }
            },
            projectSymbols: { _ in
                let exclusionSnapshot = workspace.projectExclusionSnapshot
                try await indexedProjectSymbols(
                    workspace: workspace, exclusions: exclusionSnapshot.policy
                )
            },
            exactProjectSymbols: { _, label in
                let exclusionSnapshot = workspace.projectExclusionSnapshot
                try await indexedProjectSymbols(
                    workspace: workspace, exclusions: exclusionSnapshot.policy,
                    exactLabel: label
                )
            },
            selectDestination: { request in
                guard request.snapshot == navigationSnapshot(model: model, workspace: workspace),
                      model.paneLayout.panes.indices.contains(request.groupID),
                      let document = model.document(sessionDocumentID: request.documentID),
                      model.selectDocument(document, inPaneAt: request.groupID)
                else { return nil }
                return selectNavigationDestination(
                    request.destination, document: document, paneIndex: request.groupID, model: model
                )
            },
            openURL: { request in
                guard request.snapshot == navigationSnapshot(model: model, workspace: workspace),
                      model.paneLayout.panes.indices.contains(request.groupID) else { return nil }
                _ = model.focusPane(at: request.groupID)
                guard let document = await actions.openWorkspaceFile(at: request.url) else {
                    return nil
                }
                return selectNavigationDestination(
                    request.destination, document: document, paneIndex: request.groupID, model: model
                )
            }
        )
    }

    static func navigationSnapshot(
        model: AppModel, workspace: WorkspaceController
    ) -> NavigationAppSnapshot {
        let documents = model.documents.map { document in
            NavigationDocumentSnapshot(
                documentID: document.sessionDocumentID, url: document.fileURL,
                displayName: document.displayName, text: document.buffer.text
            )
        }
        let panes = model.paneLayout.panes.enumerated().map { index, pane in
            let cursor = pane.activeDocumentID.map { documentID in
                model.selection(for: documentID, viewID: pane.viewID).main.head
            } ?? 0
            return NavigationPaneSnapshot(
                groupID: index, activeDocumentID: pane.activeDocumentID,
                cursorUTF16Offset: cursor
            )
        }
        return NavigationAppSnapshot(
            documents: documents, panes: panes,
            activeGroupID: model.paneLayout.activePaneIndex,
            workspaceRoots: workspace.roots.map(\.url)
        )
    }

    static func indexedProjectSymbols(
        workspace: WorkspaceController,
        exclusions: WorkspaceExclusionPolicy,
        exactLabel: String? = nil,
        maximumResults: Int = maximumIndexedDefinitionResults
    ) async throws -> [NavigationProjectSymbolSnapshot] {
        let roots = await workspace.service.registeredRoots()
        let listing = try await workspace.service.recursiveFiles(
            in: roots.map(\.id),
            exclusions: exclusions
        )
        let limit = max(1, maximumResults)
        var result: [NavigationProjectSymbolSnapshot] = []
        result.reserveCapacity(min(listing.files.count, limit))
        for url in listing.files {
            if Task.isCancelled { throw CancellationError() }
            guard result.count < limit,
                  let opened = try? await workspace.service.openFile(url),
                  !opened.isBinary, !opened.isTooLarge,
                  opened.byteLength <= WorkspaceSearch.maximumFileByteCount
            else { continue }
            let path = displayPath(for: url, roots: roots)
            for symbol in SymbolExtractor.extract(from: opened.content) {
                guard exactLabel == nil || symbol.label == exactLabel else { continue }
                result.append(NavigationProjectSymbolSnapshot(
                    label: symbol.label, url: url, displayPath: path,
                    line: symbol.line, column: 1, utf16Offset: symbol.position
                ))
                if result.count >= limit { break }
            }
        }
        return result
    }

    static func makePreviewController(model: AppModel) -> PreviewController {
        PreviewController(
            applyTransaction: { transaction in
                guard let document = model.selectedDocument else { return false }
                return model.apply(
                    transaction, to: document,
                    inPaneAt: model.paneLayout.activePaneIndex
                )
            },
            openURL: { NSWorkspace.shared.open($0) },
            currentDocumentSnapshot: {
                guard let document = model.selectedDocument else { return nil }
                return JSONEditorDocumentSnapshot(
                    documentID: document.sessionDocumentID,
                    source: document.buffer.text,
                    revision: document.buffer.revision
                )
            }
        )
    }

    static func isMarkdown(_ document: EditorDocument) -> Bool {
        let extensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
        return extensions.contains(document.fileURL?.pathExtension.lowercased() ?? "")
            || document.language.caseInsensitiveCompare("Markdown") == .orderedSame
    }

    static func isJSON(_ document: EditorDocument) -> Bool {
        let extensions = ["json", "jsonc", "geojson", "har"]
        return extensions.contains(document.fileURL?.pathExtension.lowercased() ?? "")
            || document.language.caseInsensitiveCompare("JSON") == .orderedSame
    }

    static func insertText(
        _ text: String, model: AppModel
    ) -> Bool {
        guard let document = model.selectedDocument else { return false }
        let paneIndex = model.paneLayout.activePaneIndex
        let selection = model.selection(
            for: document.sessionDocumentID, viewID: model.paneLayout.activeViewID
        )
        let edits = selection.ranges.map {
            TextEdit(from: $0.from, to: $0.to, insert: text)
        }
        guard let transaction = try? TextTransaction(
            edits: edits, expectedRevision: document.buffer.revision
        ) else { return false }
        return model.apply(transaction, to: document, inPaneAt: paneIndex)
    }

    static func languageServerConfig(
        for document: EditorDocument, project: WindowSessionProject?
    ) -> LanguageServerConfig? {
        languageServerConfig(language: document.language, project: project)
    }

    private static func languageServerConfig(
        language: String, project: WindowSessionProject?
    ) -> LanguageServerConfig? {
        if let project,
           let typed = ProjectSettingsSanitizer.sanitize(project).languageServers[language] {
            return typed
        }
        guard let project,
              case let .object(servers)? = project.values["languageServers"],
              case let .object(raw)? = servers[language],
              case let .string(command)? = raw["command"],
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let args: [String]
        if case let .array(values)? = raw["args"] {
            args = values.compactMap { value in
                if case let .string(argument) = value { return argument }
                return nil
            }
        } else {
            args = []
        }
        return LanguageServerConfig(command: command, args: Array(args.prefix(50)))
    }

    static func buildSystems(from settings: ProjectSettings) -> [BuildSystem] {
        settings.buildSystems.compactMap { system in
            let variants = system.variants.compactMap { variant in
                try? BuildVariant(
                    name: variant.name, command: variant.command,
                    arguments: variant.args, workingDirectory: variant.workingDirectory,
                    fileRegex: variant.fileRegex, environment: variant.env,
                    shell: variant.shell
                )
            }
            return try? BuildSystem(
                name: system.name, command: system.command, arguments: system.args,
                workingDirectory: system.workingDirectory, fileRegex: system.fileRegex,
                saveBeforeBuild: system.saveBeforeBuild ?? false,
                shell: system.shell ?? false, environment: system.env,
                variants: variants
            )
        }
    }

    static func languageServerRequest(
        method: LanguageServerMethod,
        newName: String? = nil,
        model: AppModel,
        workspace: WorkspaceController
    ) -> LanguageServerInteractiveRequest? {
        guard let document = model.selectedDocument, let fileURL = document.fileURL,
              let root = workspace.roots
                .filter({ contains($0.url, fileURL) })
                .max(by: { $0.url.path.count < $1.url.path.count }),
              let config = languageServerConfig(for: document, project: model.sessionProject)
        else { return nil }
        let cursor = model.selection(
            for: document.sessionDocumentID, viewID: model.paneLayout.activeViewID
        ).main.head
        let position = zeroBasedLineAndCharacter(
            atUTF16Offset: cursor, in: document.buffer.text
        )
        return LanguageServerInteractiveRequest(
            root: root.url.path, config: config, content: document.buffer.text,
            filePath: fileURL.path,
            languageId: document.language.lowercased().replacingOccurrences(of: " ", with: "-"),
            method: method, line: position.line, character: position.character,
            newName: newName
        )
    }

    static func languageServerRequest(
        snapshot: CompletionDocumentSnapshot, query: CompletionQuery
    ) -> LanguageServerInteractiveRequest? {
        guard snapshot.documentID == query.documentID,
              snapshot.viewID == query.viewID,
              snapshot.revision == query.revision,
              snapshot.text == query.text,
              snapshot.cursorUTF16Offset == query.cursorUTF16Offset,
              let fileURL = snapshot.fileURL,
              let root = snapshot.workspaceRoots
                .filter({ contains($0.url, fileURL) })
                .max(by: { $0.url.path.count < $1.url.path.count }),
              let config = languageServerConfig(
                language: snapshot.language, project: snapshot.project
              )
        else { return nil }
        let position = zeroBasedLineAndCharacter(
            atUTF16Offset: query.cursorUTF16Offset, in: query.text
        )
        return LanguageServerInteractiveRequest(
            root: root.url.path, config: config, content: query.text,
            filePath: fileURL.path,
            languageId: snapshot.language.lowercased().replacingOccurrences(
                of: " ", with: "-"
            ),
            method: .completion, line: position.line, character: position.character
        )
    }

    static func workspaceCompletionWords(
        workspace: WorkspaceController
    ) async -> [String]? {
        do {
            let roots = await workspace.service.registeredRoots()
            guard !roots.isEmpty else { return nil }
            let listing = try await workspace.service.recursiveFiles(in: roots.map(\.id))
            var result: [String] = []
            result.reserveCapacity(min(CompletionPlanner.maximumWorkspaceWords, 1_024))
            var seen = Set<String>()
            for url in listing.files {
                guard result.count < CompletionPlanner.maximumWorkspaceWords else { break }
                if Task.isCancelled { return nil }
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                ), values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      Int64(fileSize) <= CompletionPlanner.maximumWorkspaceFileBytes
                else { continue }
                guard let opened = try? await workspace.service.openFile(url),
                      !opened.isBinary, !opened.isTooLarge,
                      opened.encodingIssue != .invalidBytes,
                      opened.byteLength <= CompletionPlanner.maximumWorkspaceFileBytes
                else { continue }
                for word in CompletionPlanner.words(in: opened.content) {
                    guard seen.insert(word).inserted else { continue }
                    result.append(word)
                    if result.count >= CompletionPlanner.maximumWorkspaceWords { break }
                }
            }
            return result.sorted()
        } catch {
            return nil
        }
    }

    static func languageServerSyncRequest(
        model: AppModel, workspace: WorkspaceController
    ) -> LanguageServerSyncRequest? {
        guard let document = model.selectedDocument, let fileURL = document.fileURL,
              let root = workspace.roots
                .filter({ contains($0.url, fileURL) })
                .max(by: { $0.url.path.count < $1.url.path.count }),
              let config = languageServerConfig(for: document, project: model.sessionProject)
        else { return nil }
        return LanguageServerSyncRequest(
            root: root.url.path, config: config, content: document.buffer.text,
            filePath: fileURL.path,
            languageId: document.language.lowercased().replacingOccurrences(of: " ", with: "-"),
            version: Int(min(document.buffer.revision, UInt64(Int.max)))
        )
    }

    static func applyRenamePreview(
        _ preview: LanguageServerRenamePreview,
        model: AppModel,
        workspace: WorkspaceController,
        locale: EditorLocale
    ) async throws {
        guard !workspace.isApplicationTerminationPrepared,
              !model.isTextEditingLocked else { throw CancellationError() }
        guard !preview.edits.isEmpty else {
            throw NativeFeatureIntegrationError.renameUnavailable(
                "The language server returned no rename edits."
            )
        }
        let grouped = Dictionary(grouping: preview.edits, by: \.filePath)
        let alert = NSAlert()
        alert.messageText = locale.localizedApp(.applyRename)
        alert.informativeText = locale.localizedApp(
            .applyRenameEditCount(
                editCount: preview.edits.count,
                fileCount: grouped.count
            )
        )
        alert.addButton(withTitle: locale.localizedApp(.apply))
        alert.addButton(withTitle: locale.localized(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CancellationError()
        }
        guard !workspace.isApplicationTerminationPrepared,
              !model.isTextEditingLocked else { throw CancellationError() }

        struct Plan {
            let url: URL
            let originalData: Data
            let replacementData: Data
            let replacementText: String
            let encoding: TextEncoding
            let lineEnding: LineEnding
            let expectedRevision: String
            let document: EditorDocument?
            let documentID: EditorDocument.ID?
            let expectedBufferRevision: UInt64?
            let expectedDocumentDiskRevision: String?
        }
        let lockID = UUID()
        let targetURLs = grouped.keys.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let lockedDocuments = model.documents.filter { document in
            guard let url = document.fileURL else { return false }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            return targetURLs.contains { target in
                target.resolvingSymlinksInPath() == canonicalURL
            }
        }
        guard model.acquireRenameEditingLock(lockID, documents: lockedDocuments) else {
            throw CancellationError()
        }
        defer { model.releaseRenameEditingLock(lockID, documents: lockedDocuments) }

        var plans: [Plan] = []
        plans.reserveCapacity(grouped.count)
        for (path, edits) in grouped.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let document = model.documents.first {
                $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath()
                    == url.resolvingSymlinksInPath()
            }
            let source: String
            let encoding: TextEncoding
            let lineEnding: LineEnding
            let revision: String?
            if let document {
                guard !document.isSaving, document.externalConflict == nil,
                      document.encodingIssue == nil else {
                    throw NativeFeatureIntegrationError.renameUnavailable(
                        "Resolve the open-file conflict or encoding warning for \(url.lastPathComponent) first."
                    )
                }
                source = document.buffer.text
                encoding = document.encoding
                lineEnding = document.eolOverride ?? document.lineEnding
                revision = document.diskRevision
            } else {
                let opened = try await workspace.service.openFile(url)
                guard !opened.isBinary, !opened.isTooLarge, opened.encodingIssue == nil else {
                    throw NativeFeatureIntegrationError.renameUnavailable(
                        "\(url.lastPathComponent) is not safely editable text."
                    )
                }
                source = opened.content
                encoding = opened.encoding
                lineEnding = opened.lineEnding
                revision = opened.revision
            }
            guard let revision else {
                throw NativeFeatureIntegrationError.renameUnavailable(
                    "\(url.lastPathComponent) has no disk revision."
                )
            }
            let textEdits = try edits.map { edit -> TextEdit in
                let from = utf16Offset(
                    zeroBasedLine: edit.startLine, character: edit.startCharacter, in: source
                )
                let to = utf16Offset(
                    zeroBasedLine: edit.endLine, character: edit.endCharacter, in: source
                )
                guard from <= to else {
                    throw NativeFeatureIntegrationError.renameInvalidRange(url)
                }
                return TextEdit(from: from, to: to, insert: edit.newText)
            }.sorted { left, right in
                left.from == right.from ? left.to < right.to : left.from < right.from
            }
            for index in textEdits.indices.dropFirst() where textEdits[index - 1].to > textEdits[index].from {
                throw NativeFeatureIntegrationError.renameOverlappingEdits(url)
            }
            let transaction = try TextTransaction(
                edits: textEdits, expectedRevision: document?.buffer.revision
            )
            let replacement = try transaction.applying(to: source)
            plans.append(Plan(
                url: url,
                originalData: try TextFileCodec.encode(
                    source, encoding: encoding, lineEnding: lineEnding
                ),
                replacementData: try TextFileCodec.encode(
                    replacement, encoding: encoding, lineEnding: lineEnding
                ),
                replacementText: replacement, encoding: encoding,
                lineEnding: lineEnding, expectedRevision: revision, document: document,
                documentID: document?.id,
                expectedBufferRevision: document?.buffer.revision,
                expectedDocumentDiskRevision: document?.diskRevision
            ))
        }

        // No suspension is allowed between this complete snapshot check and
        // the first write. The rename owner prevents later user edits/saves;
        // this catches identity, URL, revision, save, or conflict changes that
        // won a race before the owner was installed.
        guard !workspace.isApplicationTerminationPrepared,
              model.validateRenameEditingLock(
                  lockID, lockedDocuments: lockedDocuments,
                  plannedBindings: plans.map { ($0.url, $0.document) }
              ),
              plans.allSatisfy({ plan in
                  guard let document = plan.document else { return true }
                  return plan.documentID == document.id
                      && model.documents.contains(where: { $0 === document })
                      && document.fileURL?.standardizedFileURL
                          .resolvingSymlinksInPath()
                          == plan.url.resolvingSymlinksInPath()
                      && document.buffer.revision == plan.expectedBufferRevision
                      && document.diskRevision == plan.expectedDocumentDiskRevision
                      && !document.isSaving
                      && document.externalConflict == nil
              }) else { throw CancellationError() }

        var committed: [(plan: Plan, revision: String)] = []
        var uncertainPlan: Plan?
        do {
            for plan in plans {
                do {
                    let result = try AtomicFileWriter.write(
                        plan.replacementData, to: plan.url,
                        expectedRevision: plan.expectedRevision
                    )
                    switch renameWriteDisposition(result) {
                    case let .notWritten(actualRevision):
                        // An idempotent writer result means another actor
                        // already installed the proposed bytes. This rename
                        // never owned that path and must not roll it back.
                        throw FileWriteFailure.conflict(
                            actualRevision: actualRevision
                        )
                    case let .written(revision, issue):
                        // Once bytes were installed, record ownership before
                        // checking post-commit durability/cleanup. An
                        // incomplete commit must include this file in rollback.
                        committed.append((plan, revision))
                        if let issue {
                            throw NativeFeatureIntegrationError.renameCommitIncomplete(
                                target: plan.url, issue: issue, rollbackFailure: nil
                            )
                        }
                    }
                } catch let failure as FileWriteCommitFailure {
                    switch failure {
                    case .cleanupFailedBeforeCommit:
                        break
                    case .stateIndeterminate:
                        uncertainPlan = plan
                    }
                    throw renameIntegrationError(
                        for: failure, target: plan.url
                    )
                }
            }
        } catch {
            var rollbackConflicts: [(plan: Plan, error: any Error)] = []
            for item in committed.reversed() {
                do {
                    let rollback = try AtomicFileWriter.write(
                        item.plan.originalData, to: item.plan.url,
                        expectedRevision: item.revision
                    )
                    if let issue = renameWriteCommitIssue(rollback) {
                        rollbackConflicts.append((
                            item.plan,
                            NativeFeatureIntegrationError.renameCommitIncomplete(
                                target: item.plan.url, issue: issue,
                                rollbackFailure: "The original bytes were written back, but the rollback result was incomplete."
                            )
                        ))
                    }
                } catch let rollbackFailure as FileWriteCommitFailure {
                    rollbackConflicts.append((
                        item.plan,
                        renameIntegrationError(
                            for: rollbackFailure, target: item.plan.url
                        )
                    ))
                } catch let rollbackFailure {
                    rollbackConflicts.append((item.plan, rollbackFailure))
                }
            }
            if let plan = uncertainPlan, let document = plan.document {
                // The path may contain either side (or a third writer's bytes).
                // Keep the editor's exact pre-rename buffer and force explicit
                // conflict resolution instead of claiming a clean rollback.
                document.setExternalConflict(ExternalConflict(
                    kind: .unreadable, url: plan.url,
                    detail: error.localizedDescription
                ))
            }
            for rollbackConflict in rollbackConflicts {
                if let document = rollbackConflict.plan.document {
                    document.setExternalConflict(ExternalConflict(
                        kind: .unreadable, url: rollbackConflict.plan.url,
                        detail: rollbackConflict.error.localizedDescription
                    ))
                }
            }
            if let rollbackConflict = rollbackConflicts.first {
                if let enriched = renameIntegrationError(
                    error, addingRollbackFailure:
                        rollbackConflict.error.localizedDescription
                ) {
                    throw enriched
                }
                if let integrationError = rollbackConflict.error
                    as? NativeFeatureIntegrationError {
                    throw integrationError
                }
                throw NativeFeatureIntegrationError.renameRollbackFailed(
                    rollbackConflict.plan.url
                )
            }
            throw error
        }

        for item in committed {
            guard let document = item.plan.document else { continue }
            guard document.replaceWithDiskFile(OpenedTextFile(
                url: item.plan.url, content: item.plan.replacementText,
                encoding: item.plan.encoding, lineEnding: item.plan.lineEnding,
                revision: item.revision,
                byteLength: Int64(item.plan.replacementData.count),
                isBinary: false, isTooLarge: false, encodingLocked: true
            ), renameMutationID: lockID) else {
                document.setExternalConflict(ExternalConflict(
                    kind: .unreadable, url: item.plan.url,
                    detail: "The renamed file changed while its editor was being synchronized."
                ))
            }
        }
        workspace.refreshWorkspace()
        _ = model.flushSession()
    }

    static func renameWriteDisposition(
        _ result: FileWriteResult
    ) -> RenameWriteDisposition {
        guard result.wroteBytes else {
            return .notWritten(actualRevision: result.revision)
        }
        return .written(
            revision: result.revision,
            issue: renameWriteCommitIssue(result)
        )
    }

    static func renameWriteCommitIssue(
        _ result: FileWriteResult
    ) -> RenameWriteCommitIssue? {
        guard !result.durabilityConfirmed || !result.cleanupCompleted else {
            return nil
        }
        return RenameWriteCommitIssue(
            durabilityConfirmed: result.durabilityConfirmed,
            cleanupCompleted: result.cleanupCompleted,
            recoveryArtifact: result.recoveryArtifact
        )
    }

    static func renameWriteResultIsComplete(_ result: FileWriteResult) -> Bool {
        renameWriteCommitIssue(result) == nil
    }

    static func renameIntegrationError(
        _ error: any Error, addingRollbackFailure rollbackFailure: String
    ) -> NativeFeatureIntegrationError? {
        guard let integrationError = error as? NativeFeatureIntegrationError else {
            return nil
        }
        switch integrationError {
        case let .renameCommitIncomplete(target, issue, _):
            return .renameCommitIncomplete(
                target: target, issue: issue, rollbackFailure: rollbackFailure
            )
        case let .renameStateIndeterminate(target, artifact, _):
            return .renameStateIndeterminate(
                target: target, recoveryArtifact: artifact,
                rollbackFailure: rollbackFailure
            )
        case let .renamePrecommitCleanupFailed(target, artifact, _):
            return .renamePrecommitCleanupFailed(
                target: target, recoveryArtifact: artifact,
                rollbackFailure: rollbackFailure
            )
        default:
            return nil
        }
    }

    static func renameIntegrationError(
        for failure: FileWriteCommitFailure, target: URL
    ) -> NativeFeatureIntegrationError {
        switch failure {
        case let .cleanupFailedBeforeCommit(artifact):
            return .renamePrecommitCleanupFailed(
                target: target, recoveryArtifact: artifact,
                rollbackFailure: nil
            )
        case let .stateIndeterminate(artifact):
            return .renameStateIndeterminate(
                target: target, recoveryArtifact: artifact,
                rollbackFailure: nil
            )
        }
    }

    private static func matchingDocument(
        _ identity: FindPaneIdentity, expectedRevision: UInt64, model: AppModel
    ) -> EditorDocument? {
        guard model.paneLayout.panes.indices.contains(identity.paneIndex),
              model.paneLayout.panes[identity.paneIndex].viewID == identity.viewID,
              model.paneLayout.panes[identity.paneIndex].contains(identity.documentID),
              let document = model.document(sessionDocumentID: identity.documentID),
              document.buffer.revision == expectedRevision else { return nil }
        return document
    }

    private static func selectNavigationDestination(
        _ destination: NavigationDestination,
        document: EditorDocument,
        paneIndex: Int,
        model: AppModel
    ) -> NavigationLocation? {
        let selection: SelectionSet
        let offset: Int
        if let requestedOffset = destination.utf16Offset {
            let start = min(document.buffer.utf16Length, max(0, requestedOffset))
            let requestedEnd = start.addingReportingOverflow(
                destination.selectionUTF16Length ?? 0
            )
            let end = min(
                document.buffer.utf16Length,
                max(start, requestedEnd.overflow ? Int.max : requestedEnd.partialValue)
            )
            selection = .single(anchor: start, head: end)
            offset = end
        } else if let line = destination.line {
            offset = utf16Offset(
                line: line, column: destination.column ?? 1, in: document.buffer.text
            )
            selection = .cursor(at: offset)
        } else {
            offset = model.selection(
                for: document.sessionDocumentID, viewID: model.paneLayout.panes[paneIndex].viewID
            ).main.head
            selection = .cursor(at: offset)
        }
        guard model.setSelections(
            selection, for: document, inPaneAt: paneIndex
        ) || model.selection(
            for: document.sessionDocumentID, viewID: model.paneLayout.panes[paneIndex].viewID
        ) == selection else { return nil }
        let location = NavigationDocumentSnapshot(
            documentID: document.sessionDocumentID, url: document.fileURL,
            displayName: document.displayName, text: document.buffer.text
        ).lineColumn(atUTF16Offset: offset)
        return NavigationLocation(
            documentID: document.sessionDocumentID, path: document.fileURL?.path,
            groupID: paneIndex, line: location.line, column: location.column
        )
    }

    static func utf16Offset(line: Int, column: Int, in text: String) -> Int {
        let units = Array(text.utf16)
        let targetLine = max(1, line)
        var currentLine = 1
        var start = 0
        while start < units.count, currentLine < targetLine {
            if units[start] == 0x0a { currentLine += 1 }
            start += 1
        }
        var end = start
        while end < units.count, units[end] != 0x0a { end += 1 }
        return min(end, start + max(0, column - 1))
    }

    private static func utf16Offset(
        zeroBasedLine requestedLine: Int, character requestedCharacter: Int, in text: String
    ) -> Int {
        utf16Offset(
            line: max(0, requestedLine) + 1,
            column: max(0, requestedCharacter) + 1,
            in: text
        )
    }

    private static func displayPath(for url: URL, roots: [WorkspaceRoot]) -> String {
        let path = url.standardizedFileURL.path
        let candidates = roots.compactMap { root -> String? in
            let rootPath = root.url.standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
            let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            return roots.count > 1 ? root.displayName + "/" + relative : relative
        }
        return candidates.min(by: { $0.count < $1.count }) ?? path
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func zeroBasedLineAndCharacter(
        atUTF16Offset requested: Int, in text: String
    ) -> (line: Int, character: Int) {
        let units = Array(text.utf16)
        let offset = min(units.count, max(0, requested))
        var line = 0
        var lineStart = 0
        for index in 0..<offset where units[index] == 0x0a {
            line += 1
            lineStart = index + 1
        }
        return (line, offset - lineStart)
    }
}
