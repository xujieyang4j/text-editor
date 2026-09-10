import AppKit
import LumenEditorCore
import SwiftUI
import UniformTypeIdentifiers

enum EditorPaneQuickAction: String, CaseIterable, Equatable, Sendable {
    case toggleMarkdownPreview = "toggle-preview"
    case openHTMLInBrowser = "open-in-browser"
    case formatJSON = "format-json"
    case compactJSON = "compact-json"
    case toggleJSONView = "toggle-json-view"

    var commandID: String { rawValue }

    var systemImage: String {
        switch self {
        case .toggleMarkdownPreview: "doc.richtext"
        case .openHTMLInBrowser: "globe"
        case .formatJSON: "text.alignleft"
        case .compactJSON: "text.justify"
        case .toggleJSONView: "curlybraces"
        }
    }
}

/// Pure visibility/state planning for the pane-local editor chrome. A file
/// extension and a manually selected syntax are intentionally peers.
enum EditorPaneQuickActionPlan {
    @MainActor
    static func actions(
        for document: EditorDocument, distractionFree: Bool
    ) -> [EditorPaneQuickAction] {
        actions(
            isMarkdown: NativeFeatureCoordinator.isMarkdown(document),
            isHTML: HTMLBrowserPreview.supports(
                sourceURL: document.fileURL, language: document.language
            ),
            isJSON: NativeFeatureCoordinator.isJSON(document),
            distractionFree: distractionFree
        )
    }

    static func actions(
        isMarkdown: Bool, isHTML: Bool, isJSON: Bool,
        distractionFree: Bool
    ) -> [EditorPaneQuickAction] {
        guard !distractionFree else { return [] }
        var actions: [EditorPaneQuickAction] = []
        if isMarkdown {
            actions.append(.toggleMarkdownPreview)
        }
        if isHTML {
            actions.append(.openHTMLInBrowser)
        }
        if isJSON {
            actions.append(contentsOf: [
                .formatJSON, .compactJSON, .toggleJSONView
            ])
        }
        return actions
    }
}

struct EditorPaneTabPathPlan: Equatable, Sendable {
    let fileURL: URL?
    let workspaceRoot: URL?

    var canCopyAbsolutePath: Bool { fileURL != nil }
    var canCopyRelativePath: Bool { fileURL != nil && workspaceRoot != nil }

    static func make(fileURL: URL?, workspaceRoots: [URL]) -> Self {
        guard let fileURL else {
            return Self(fileURL: nil, workspaceRoot: nil)
        }
        let fileURL = fileURL.standardizedFileURL
        let root = workspaceRoots
            .map { $0.standardizedFileURL }
            .filter { contains($0, fileURL) }
            .max { $0.pathComponents.count < $1.pathComponents.count }
        return Self(fileURL: fileURL, workspaceRoot: root)
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy {
            $0.0 == $0.1
        }
    }
}

struct EditorPaneTabPathAction: Equatable, Sendable {
    let documentID: String
    let fileURL: URL?

    init(documentID: String, fileURL: URL?) {
        self.documentID = documentID
        self.fileURL = fileURL?.standardizedFileURL
    }

    @discardableResult
    func perform(
        relativeToWorkspace: Bool,
        copyPath: @MainActor (URL, Bool) async -> Bool
    ) async -> Bool {
        guard let fileURL else { return false }
        return await copyPath(fileURL, relativeToWorkspace)
    }
}

struct EditorPaneQuickActionTarget: Equatable, Sendable {
    let paneIndex: Int
    let paneID: String
    let documentID: String

    func isCurrent(
        paneIndex currentPaneIndex: Int?,
        paneID currentPaneID: String?,
        paneContainsDocument: Bool
    ) -> Bool {
        currentPaneIndex == paneIndex
            && currentPaneID == paneID
            && paneContainsDocument
    }
}

/// Renders the pane-local tab rows and editing surfaces for one window.
/// Window-wide chrome such as conflict banners and the status bar stays with
/// `EditorWindowView`.
struct EditorPaneView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var actions: EditorActionController
    @ObservedObject var settings: SettingsController
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var commandRouter: CommandRouter
    @ObservedObject var previewController: PreviewController
    @ObservedObject var languageServerController: LanguageServerController
    @ObservedObject var workspaceCompletionCache: WorkspaceCompletionCache
    let codeMirrorParserCoordinator: CodeMirrorParserCoordinator
    let editorCommandController: EditorCommandController
    var applyTextTransaction: ((TextTransaction) -> Bool)? = nil
    var navigateSnippetPlaceholder: ((SnippetNavigationDirection) -> Bool)? = nil
    var cancelSnippetSession: (() -> Bool)? = nil
    var incrementalDiffMarkers: ((EditorDocument, Int) -> [IncrementalDiffMarker])? = nil
    var findHighlightSnapshot: ((EditorDocument, EditorViewID, Int) -> FindHighlightSnapshot?)? = nil
    var foldSnapshot: ((EditorDocument, EditorViewID) -> TextKitFoldSnapshot?)? = nil
    var toggleFoldMarker: ((String, EditorViewID, UInt64, String) -> Bool)? = nil
    var revealFoldedContent: ((String, EditorViewID, Int) -> Bool)? = nil
    var activeEditorFocusRequest: UInt64 = 0
    var showsTabBar = true

    var body: some View {
        Group {
            switch model.paneLayout.kind {
            case .single:
                pane(at: 0)
            case .columns2:
                HStack(spacing: 0) {
                    pane(at: 0)
                    Divider()
                    pane(at: 1)
                }
            case .columns3:
                HStack(spacing: 0) {
                    pane(at: 0)
                    Divider()
                    pane(at: 1)
                    Divider()
                    pane(at: 2)
                }
            case .grid4:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        pane(at: 0)
                        Divider()
                        pane(at: 1)
                    }
                    Divider()
                    HStack(spacing: 0) {
                        pane(at: 2)
                        Divider()
                        pane(at: 3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pane(at index: Int) -> some View {
        if model.paneLayout.panes.indices.contains(index) {
            EditorPane(
                model: model,
                actions: actions,
                settings: settings,
                workspace: workspace,
                commandRouter: commandRouter,
                previewController: previewController,
                languageServerController: languageServerController,
                workspaceCompletionCache: workspaceCompletionCache,
                codeMirrorParserCoordinator: codeMirrorParserCoordinator,
                editorCommandController: editorCommandController,
                applyTextTransaction: applyTextTransaction,
                navigateSnippetPlaceholder: navigateSnippetPlaceholder,
                cancelSnippetSession: cancelSnippetSession,
                incrementalDiffMarkers: incrementalDiffMarkers,
                findHighlightSnapshot: findHighlightSnapshot,
                foldSnapshot: foldSnapshot,
                toggleFoldMarker: toggleFoldMarker,
                revealFoldedContent: revealFoldedContent,
                activeEditorFocusRequest: activeEditorFocusRequest,
                showsTabBar: showsTabBar,
                pane: model.paneLayout.panes[index],
                paneIndex: index
            )
            .id(model.paneLayout.panes[index].viewID)
            .frame(
                minWidth: 0,
                maxWidth: .infinity,
                minHeight: 0,
                maxHeight: .infinity
            )
        }
    }
}

private struct EditorPane: View {
    @Environment(\.appLocale) private var appLocale
    @ObservedObject var model: AppModel
    @ObservedObject var actions: EditorActionController
    @ObservedObject var settings: SettingsController
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var commandRouter: CommandRouter
    @ObservedObject var previewController: PreviewController
    @ObservedObject var languageServerController: LanguageServerController
    @ObservedObject var workspaceCompletionCache: WorkspaceCompletionCache
    let codeMirrorParserCoordinator: CodeMirrorParserCoordinator
    let editorCommandController: EditorCommandController
    let applyTextTransaction: ((TextTransaction) -> Bool)?
    let navigateSnippetPlaceholder: ((SnippetNavigationDirection) -> Bool)?
    let cancelSnippetSession: (() -> Bool)?
    let incrementalDiffMarkers: ((EditorDocument, Int) -> [IncrementalDiffMarker])?
    let findHighlightSnapshot: ((
        EditorDocument, EditorViewID, Int
    ) -> FindHighlightSnapshot?)?
    let foldSnapshot: ((EditorDocument, EditorViewID) -> TextKitFoldSnapshot?)?
    let toggleFoldMarker: ((String, EditorViewID, UInt64, String) -> Bool)?
    let revealFoldedContent: ((String, EditorViewID, Int) -> Bool)?
    let activeEditorFocusRequest: UInt64
    let showsTabBar: Bool

    let pane: PaneLayout.Pane
    let paneIndex: Int
    @State private var editorFocusRequest = 0

    private var isActivePane: Bool {
        model.paneLayout.activePaneIndex == paneIndex
            && model.paneLayout.panes.indices.contains(paneIndex)
            && model.paneLayout.panes[paneIndex].viewID == pane.viewID
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsTabBar {
                PaneTabBar(
                    model: model,
                    actions: actions,
                    workspace: workspace,
                    pane: pane,
                    paneIndex: paneIndex,
                    focusEditor: { editorFocusRequest &+= 1 }
                )
                Divider()
            }

            if let document = activeDocument {
                PaneDocumentEditor(
                    model: model,
                    actions: actions,
                    settings: settings,
                    workspace: workspace,
                    commandRouter: commandRouter,
                    previewController: previewController,
                    languageServerController: languageServerController,
                    workspaceCompletionCache: workspaceCompletionCache,
                    codeMirrorParserCoordinator: codeMirrorParserCoordinator,
                    editorCommandController: editorCommandController,
                    applyTextTransaction: applyTextTransaction,
                    navigateSnippetPlaceholder: navigateSnippetPlaceholder,
                    cancelSnippetSession: cancelSnippetSession,
                    incrementalDiffMarkers: incrementalDiffMarkers,
                    findHighlightSnapshot: findHighlightSnapshot,
                    foldSnapshot: foldSnapshot,
                    toggleFoldMarker: toggleFoldMarker,
                    revealFoldedContent: revealFoldedContent,
                    activeEditorFocusRequest: activeEditorFocusRequest,
                    document: document,
                    paneIndex: paneIndex,
                    viewID: pane.viewID,
                    focusRequest: editorFocusRequest
                )
                .id(document.sessionDocumentID)
            } else {
                emptyPane
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            Rectangle()
                .stroke(
                    isActivePane ? Color.accentColor.opacity(0.75) : .clear,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
    }

    private var activeDocument: EditorDocument? {
        guard let documentID = pane.activeDocumentID else { return nil }
        return model.document(sessionDocumentID: documentID)
    }

    private var emptyPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(appLocale.text("No Document", zh: "没有打开的文档"))
                .foregroundStyle(.secondary)
            Button(appLocale.text("New Document", zh: "新建文档")) {
                focusPane()
                actions.newDocument()
            }
            .accessibilityHint(appLocale.text(
                "Creates a new untitled document in this pane.",
                zh: "在此编辑窗格中新建一个未命名文档。"
            ))
            .accessibilityIdentifier(
                EditorPaneAccessibility.emptyNewDocumentID(pane.viewID.rawValue)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocale.text(
            "Empty editor pane", zh: "空编辑窗格"
        ))
        .accessibilityIdentifier(
            EditorPaneAccessibility.emptyPaneID(pane.viewID.rawValue)
        )
        .onTapGesture { focusPane() }
    }

    private func focusPane() {
        guard let index = currentPaneIndex,
              model.paneLayout.activePaneIndex != index else { return }
        _ = model.focusPane(at: index)
    }

    private var currentPaneIndex: Int? {
        model.paneLayout.panes.firstIndex { $0.viewID == pane.viewID }
    }
}

private struct PaneTabBar: View {
    @Environment(\.appLocale) private var appLocale
    @ObservedObject var model: AppModel
    @ObservedObject var actions: EditorActionController
    @ObservedObject var workspace: WorkspaceController

    let pane: PaneLayout.Pane
    let paneIndex: Int
    let focusEditor: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(pane.documentIDs, id: \.self) { documentID in
                        if let document = model.document(
                            sessionDocumentID: documentID
                        ) {
                            PaneDocumentTab(
                                document: document,
                                paneID: pane.viewID.rawValue,
                                isActive: pane.activeDocumentID == documentID,
                                isSelected: model.paneLayout.selectedDocumentIDs
                                    .contains(documentID),
                                isPaneFocused: isActivePane,
                                select: { select(document) },
                                toggleSelection: {
                                    if !actions.hasBlockingInteraction {
                                        _ = model.toggleTabSelection(document)
                                    }
                                },
                                togglePin: { togglePin(document) },
                                close: { close(document) },
                                closeOthers: { close(.others, relativeTo: document) },
                                closeRight: { close(.right, relativeTo: document) },
                                closeAll: { close(.all, relativeTo: document) },
                                copyAbsolutePath: { copyPath(of: document, relative: false) },
                                copyRelativePath: { copyPath(of: document, relative: true) },
                                pathPlan: EditorPaneTabPathPlan.make(
                                    fileURL: document.fileURL,
                                    workspaceRoots: workspace.roots.map(\.url)
                                ),
                                pathActionsEnabled: !actions.hasBlockingInteraction
                                    && !workspace.isBusy,
                                reorder: { draggedID, position in
                                    reorder(
                                        draggedDocumentID: draggedID,
                                        relativeTo: document,
                                        position: position
                                    )
                                }
                            )
                            .id(documentID)
                        }
                    }

                    Button(action: createDocument) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(appLocale.text(
                        "New Document (⌘N)", zh: "新建文档 (⌘N)"
                    ))
                    .accessibilityLabel(appLocale.text(
                        "New Document", zh: "新建文档"
                    ))
                    .accessibilityHint(appLocale.text(
                        "Creates a new untitled document in this pane.",
                        zh: "在此编辑窗格中新建一个未命名文档。"
                    ))
                    .accessibilityIdentifier(
                        EditorPaneAccessibility.tabBarNewDocumentID(
                            pane.viewID.rawValue
                        )
                    )
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)
            .onChange(of: pane.activeDocumentID) { _, documentID in
                guard let documentID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(documentID, anchor: .center)
                }
            }
        }
        .frame(height: 36)
        .background(isActivePane ? Color.accentColor.opacity(0.055) : Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocale.text("Document tabs", zh: "文档标签页"))
        .accessibilityIdentifier(
            EditorPaneAccessibility.tabBarID(pane.viewID.rawValue)
        )
        .onTapGesture { focusPane() }
    }

    private var isActivePane: Bool {
        model.paneLayout.activePaneIndex == currentPaneIndex
    }

    private var currentPaneIndex: Int? {
        model.paneLayout.panes.firstIndex { $0.viewID == pane.viewID }
    }

    private func focusPane() {
        guard let index = currentPaneIndex,
              model.paneLayout.activePaneIndex != index else { return }
        _ = model.focusPane(at: index)
    }

    private func select(_ document: EditorDocument) {
        guard !actions.hasBlockingInteraction else { return }
        guard let index = currentPaneIndex else { return }
        _ = model.selectDocument(document, inPaneAt: index)
        focusEditor()
    }

    private func createDocument() {
        guard !actions.hasBlockingInteraction else { return }
        focusPane()
        actions.newDocument()
    }

    private func close(_ document: EditorDocument) {
        guard !actions.hasBlockingInteraction else { return }
        guard let index = currentPaneIndex else { return }
        actions.requestClose(document, fromPaneAt: index)
    }

    private func togglePin(_ document: EditorDocument) {
        guard !actions.hasBlockingInteraction else { return }
        guard let index = currentPaneIndex else { return }
        _ = model.selectDocument(document, inPaneAt: index)
        _ = model.togglePin(document)
        focusEditor()
    }

    private func close(_ scope: TabCloseScope, relativeTo document: EditorDocument) {
        guard !actions.hasBlockingInteraction else { return }
        guard let index = currentPaneIndex else { return }
        _ = model.selectDocument(document, inPaneAt: index)
        switch scope {
        case .others: actions.requestCloseOtherTabs()
        case .right: actions.requestCloseTabsToRight()
        case .all: actions.requestCloseAllTabs()
        }
    }

    private func copyPath(of document: EditorDocument, relative: Bool) {
        guard !actions.hasBlockingInteraction, !workspace.isBusy,
              document.fileURL != nil else { return }
        let target = EditorPaneTabPathAction(
            documentID: document.sessionDocumentID,
            fileURL: document.fileURL
        )
        Task {
            _ = await target.perform(relativeToWorkspace: relative) { url, relative in
                await workspace.copyPath(url, relativeToWorkspace: relative)
            }
        }
    }

    private func reorder(
        draggedDocumentID: String,
        relativeTo document: EditorDocument,
        position: PaneLayout.TabDropPosition
    ) -> Bool {
        guard !actions.hasBlockingInteraction else { return false }
        guard let index = currentPaneIndex else { return false }
        return model.reorderTabs(
            inPaneAt: index,
            draggedDocumentID: draggedDocumentID,
            relativeTo: document.sessionDocumentID,
            position: position
        )
    }

}

private struct PaneDocumentTab: View {
    @Environment(\.appLocale) private var appLocale
    @ObservedObject var document: EditorDocument

    let paneID: String
    let isActive: Bool
    let isSelected: Bool
    let isPaneFocused: Bool
    let select: () -> Void
    let toggleSelection: () -> Void
    let togglePin: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let closeRight: () -> Void
    let closeAll: () -> Void
    let copyAbsolutePath: () -> Void
    let copyRelativePath: () -> Void
    let pathPlan: EditorPaneTabPathPlan
    let pathActionsEnabled: Bool
    let reorder: (String, PaneLayout.TabDropPosition) -> Bool
    @State private var tabWidth: CGFloat = 1

    var body: some View {
        HStack(spacing: 6) {
            Button { activateFromCurrentEvent() } label: {
                HStack(spacing: 6) {
                    documentState
                    Text(document.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(document.displayName)
            .accessibilityValue(documentStateDescription)
            .accessibilityHint(appLocale.text(
                "Activates this document tab.",
                zh: "激活此文档标签页。"
            ))
            .accessibilityIdentifier(
                EditorPaneAccessibility.tabID(
                    paneID: paneID, documentID: document.sessionDocumentID
                )
            )
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { togglePin() }
            )

            Button { togglePin() } label: {
                Image(systemName: document.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinActionLabel)
            .accessibilityLabel(pinActionLabel)
            .accessibilityHint(document.pinned
                ? appLocale.text(
                    "Allows this document tab to close normally.",
                    zh: "允许正常关闭此文档标签页。"
                )
                : appLocale.text(
                    "Keeps this document tab open.",
                    zh: "保持此文档标签页打开。"
                )
            )
            .accessibilityIdentifier(
                EditorPaneAccessibility.pinTabID(
                    paneID: paneID, documentID: document.sessionDocumentID
                )
            )

            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(closeActionLabel)
            .accessibilityLabel(closeActionLabel)
            .accessibilityHint(appLocale.text(
                "Closes this document tab.",
                zh: "关闭此文档标签页。"
            ))
            .accessibilityIdentifier(
                EditorPaneAccessibility.closeTabID(
                    paneID: paneID, documentID: document.sessionDocumentID
                )
            )
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 104, maxWidth: 210, minHeight: 26)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(tabBackground)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { tabWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in
                        tabWidth = width
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isActive
                        ? (isPaneFocused
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(0.13))
                        : .clear,
                    lineWidth: 1
                )
        }
        .help(document.fileURL?.path ?? document.displayName)
        .onDrag {
            let payload = PaneTabDragPayload(
                paneID: paneID,
                documentID: document.sessionDocumentID
            )
            let data = try? JSONEncoder().encode(payload)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.lumenEditorTab.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        .onDrop(
            of: [UTType.lumenEditorTab.identifier],
            delegate: PaneTabDropDelegate(
                paneID: paneID,
                targetDocumentID: document.sessionDocumentID,
                targetWidth: tabWidth,
                reorder: reorder
            )
        )
        .contextMenu {
            Button(pinActionLabel) { togglePin() }
            Divider()
            Button(commandTitle(
                "copy-file-path", fallback: "Copy File Path"
            )) { copyAbsolutePath() }
            .disabled(!pathActionsEnabled || !pathPlan.canCopyAbsolutePath)
            .accessibilityIdentifier(
                EditorPaneAccessibility.tabCopyAbsolutePathID(
                    paneID: paneID, documentID: document.sessionDocumentID
                )
            )
            Button(commandTitle(
                "copy-relative-file-path", fallback: "Copy Relative File Path"
            )) { copyRelativePath() }
            .disabled(!pathActionsEnabled || !pathPlan.canCopyRelativePath)
            .accessibilityIdentifier(
                EditorPaneAccessibility.tabCopyRelativePathID(
                    paneID: paneID, documentID: document.sessionDocumentID
                )
            )
            Divider()
            Button(appLocale.text("Close Tab", zh: "关闭标签页")) { close() }
            Button(appLocale.text("Close Other Tabs", zh: "关闭其他标签页")) {
                closeOthers()
            }
            Button(appLocale.text(
                "Close Tabs to the Right", zh: "关闭右侧标签页"
            )) { closeRight() }
            Button(appLocale.text("Close All Tabs", zh: "关闭全部标签页")) {
                closeAll()
            }
        }
    }

    private var pinActionLabel: String {
        document.pinned
            ? appLocale.text("Unpin Tab", zh: "取消固定标签页")
            : appLocale.text("Pin Tab", zh: "固定标签页")
    }

    private func commandTitle(_ commandID: String, fallback: String) -> String {
        Localization.commandLabel(
            for: commandID, locale: appLocale, fallback: fallback
        )
    }

    private var closeActionLabel: String {
        appLocale.text(
            "Close \(document.displayName)",
            zh: "关闭 \(document.displayName)"
        )
    }

    private var documentStateDescription: String {
        if document.isSaving {
            return appLocale.text("Saving", zh: "正在保存")
        }
        if document.externalConflict != nil {
            return appLocale.text("Changed on disk", zh: "已在磁盘上更改")
        }
        if document.isDirty {
            return appLocale.text("Unsaved", zh: "未保存")
        }
        if document.pinned {
            return appLocale.text("Pinned", zh: "已固定")
        }
        return ""
    }

    private var tabBackground: Color {
        if isActive { return Color(nsColor: .controlBackgroundColor) }
        if isSelected { return Color.accentColor.opacity(0.14) }
        return .clear
    }

    private func activateFromCurrentEvent() {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            toggleSelection()
        } else {
            select()
        }
    }

    @ViewBuilder
    private var documentState: some View {
        if document.isSaving {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(appLocale.text(
                    "Saving", zh: "正在保存"
                ))
        } else if document.externalConflict != nil {
            Text("!")
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .accessibilityLabel(appLocale.text(
                    "Changed on disk", zh: "已在磁盘上更改"
                ))
        } else if document.isDirty {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(appLocale.text("Unsaved", zh: "未保存"))
        } else if document.pinned {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(appLocale.text("Pinned", zh: "已固定"))
        } else {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private enum EditorPaneAccessibility {
    static func emptyPaneID(_ paneID: String) -> String {
        "editor.pane." + paneID + ".empty"
    }

    static func emptyNewDocumentID(_ paneID: String) -> String {
        "editor.pane." + paneID + ".empty.newDocument"
    }

    static func tabBarID(_ paneID: String) -> String {
        "editor.pane." + paneID + ".tabs"
    }

    static func tabBarNewDocumentID(_ paneID: String) -> String {
        "editor.pane." + paneID + ".tabs.newDocument"
    }

    static func quickActionBarID(_ paneID: String) -> String {
        "editor.pane." + paneID + ".quickActions"
    }

    static func quickActionID(
        paneID: String, action: EditorPaneQuickAction
    ) -> String {
        "editor.pane." + paneID + ".quickAction." + action.commandID
    }

    static func tabID(paneID: String, documentID: String) -> String {
        tabControlID("tab", paneID: paneID, documentID: documentID)
    }

    static func pinTabID(paneID: String, documentID: String) -> String {
        tabControlID("pin", paneID: paneID, documentID: documentID)
    }

    static func closeTabID(paneID: String, documentID: String) -> String {
        tabControlID("close", paneID: paneID, documentID: documentID)
    }

    static func tabCopyAbsolutePathID(
        paneID: String, documentID: String
    ) -> String {
        tabControlID("copy.absolute.path", paneID: paneID, documentID: documentID)
    }

    static func tabCopyRelativePathID(
        paneID: String, documentID: String
    ) -> String {
        tabControlID("copy.relative.path", paneID: paneID, documentID: documentID)
    }

    private static func tabControlID(
        _ control: String, paneID: String, documentID: String
    ) -> String {
        "editor.pane." + paneID + ".tab." + documentID + "." + control
    }
}

private struct PaneTabDropDelegate: DropDelegate {
    let paneID: String
    let targetDocumentID: String
    let targetWidth: CGFloat
    let reorder: (String, PaneLayout.TabDropPosition) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.lumenEditorTab.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(
            for: [UTType.lumenEditorTab.identifier]
        ).first else { return false }
        let position: PaneLayout.TabDropPosition = info.location.x < targetWidth / 2
            ? .before : .after
        let targetDocumentID = targetDocumentID
        let reorder = reorder
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.lumenEditorTab.identifier
        ) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(
                    PaneTabDragPayload.self,
                    from: data
                  ),
                  payload.paneID == paneID,
                  payload.documentID != targetDocumentID else { return }
            Task { @MainActor in
                _ = reorder(payload.documentID, position)
            }
        }
        return true
    }
}

private struct PaneTabDragPayload: Codable {
    let paneID: String
    let documentID: String
}

private extension UTType {
    static let lumenEditorTab = UTType(exportedAs: "com.lumen.editor.native.tab")
}

@MainActor
private struct PaneDocumentEditor: View {
    @Environment(\.appLocale) private var appLocale
    @ObservedObject var model: AppModel
    @ObservedObject var actions: EditorActionController
    @ObservedObject var settings: SettingsController
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var commandRouter: CommandRouter
    @ObservedObject var previewController: PreviewController
    @ObservedObject var languageServerController: LanguageServerController
    @ObservedObject var workspaceCompletionCache: WorkspaceCompletionCache
    @ObservedObject var document: EditorDocument
    let codeMirrorParserCoordinator: CodeMirrorParserCoordinator
    let editorCommandController: EditorCommandController
    let applyTextTransaction: ((TextTransaction) -> Bool)?
    let navigateSnippetPlaceholder: ((SnippetNavigationDirection) -> Bool)?
    let cancelSnippetSession: (() -> Bool)?
    let incrementalDiffMarkers: ((EditorDocument, Int) -> [IncrementalDiffMarker])?
    let findHighlightSnapshot: ((
        EditorDocument, EditorViewID, Int
    ) -> FindHighlightSnapshot?)?
    let foldSnapshot: ((EditorDocument, EditorViewID) -> TextKitFoldSnapshot?)?
    let toggleFoldMarker: ((String, EditorViewID, UInt64, String) -> Bool)?
    let revealFoldedContent: ((String, EditorViewID, Int) -> Bool)?
    let activeEditorFocusRequest: UInt64

    let paneIndex: Int
    let viewID: EditorViewID
    let focusRequest: Int
    @State private var isEditorFocused = false
    @State private var parsedHighlighting: NativeSyntaxHighlighter.ParsedSnapshot?
    @State private var parsedIndentation: CodeMirrorIndentationSnapshot?
    @StateObject private var completionController: CompletionController

    init(
        model: AppModel, actions: EditorActionController,
        settings: SettingsController,
        workspace: WorkspaceController,
        commandRouter: CommandRouter,
        previewController: PreviewController,
        languageServerController: LanguageServerController,
        workspaceCompletionCache: WorkspaceCompletionCache,
        codeMirrorParserCoordinator: CodeMirrorParserCoordinator,
        editorCommandController: EditorCommandController,
        applyTextTransaction: ((TextTransaction) -> Bool)?,
        navigateSnippetPlaceholder: ((SnippetNavigationDirection) -> Bool)?,
        cancelSnippetSession: (() -> Bool)?,
        incrementalDiffMarkers: ((EditorDocument, Int) -> [IncrementalDiffMarker])?,
        findHighlightSnapshot: ((
            EditorDocument, EditorViewID, Int
        ) -> FindHighlightSnapshot?)?,
        foldSnapshot: ((EditorDocument, EditorViewID) -> TextKitFoldSnapshot?)?,
        toggleFoldMarker: ((String, EditorViewID, UInt64, String) -> Bool)?,
        revealFoldedContent: ((String, EditorViewID, Int) -> Bool)?,
        activeEditorFocusRequest: UInt64,
        document: EditorDocument, paneIndex: Int, viewID: EditorViewID,
        focusRequest: Int
    ) {
        self.model = model
        self.actions = actions
        self.settings = settings
        self.workspace = workspace
        self.commandRouter = commandRouter
        self.previewController = previewController
        self.languageServerController = languageServerController
        self.workspaceCompletionCache = workspaceCompletionCache
        self.codeMirrorParserCoordinator = codeMirrorParserCoordinator
        self.editorCommandController = editorCommandController
        self.applyTextTransaction = applyTextTransaction
        self.navigateSnippetPlaceholder = navigateSnippetPlaceholder
        self.cancelSnippetSession = cancelSnippetSession
        self.incrementalDiffMarkers = incrementalDiffMarkers
        self.findHighlightSnapshot = findHighlightSnapshot
        self.foldSnapshot = foldSnapshot
        self.toggleFoldMarker = toggleFoldMarker
        self.revealFoldedContent = revealFoldedContent
        self.activeEditorFocusRequest = activeEditorFocusRequest
        self.document = document
        self.paneIndex = paneIndex
        self.viewID = viewID
        self.focusRequest = focusRequest
        _completionController = StateObject(wrappedValue: CompletionController(
            workspaceCache: workspaceCompletionCache
        ))
        _parsedHighlighting = State(initialValue: nil)
        _parsedIndentation = State(initialValue: nil)
    }

    var body: some View {
        NativeTextEditor(
            text: document.text,
            documentID: document.sessionDocumentID,
            documentDisplayName: document.displayName,
            fileURL: document.fileURL,
            viewID: viewID,
            paneIndex: paneIndex,
            documentRevision: document.buffer.revision,
            selections: model.selection(
                for: document.sessionDocumentID,
                viewID: viewID
            ),
            scrollPosition: nativeScrollPosition,
            isFocused: focusBinding,
            // Stop native key/IME input as soon as this window enters the Quit
            // review. AppModel's irreversible lock remains the commit-time
            // backstop for callbacks that already escaped the view layer.
            isEditable: !actions.isClosingApplicationOrWindow
                && !model.isTextEditingLocked
                && !document.isEditingLocked,
            fontSize: CGFloat(settings.settings.fontSize),
            tabWidth: effectiveIndentation.tabWidth,
            indentWidth: effectiveIndentation.indentSize,
            insertSpaces: effectiveIndentation.insertSpaces,
            softWrap: settings.settings.wordWrap,
            showLineNumbers: settings.settings.showLineNumbers,
            showWhitespace: settings.settings.showWhitespace,
            showIndentGuides: settings.settings.showIndentGuides,
            highlightTrailingWhitespace: settings.settings.highlightTrailingWhitespace,
            rulers: settings.settings.rulers,
            spellChecking: settings.settings.spellCheck && isProseDocument,
            theme: settings.settings.theme,
            colorScheme: settings.settings.colorScheme,
            language: document.language,
            parsedHighlighting: parsedHighlighting,
            parsedIndentation: parsedIndentation,
            diagnosticSnapshot: editorDiagnosticSnapshot,
            showMinimap: settings.settings.showMinimap,
            incrementalDiffMarkers: incrementalDiffMarkers?(document, paneIndex) ?? [],
            findHighlightSnapshot: findHighlightSnapshot?(document, viewID, paneIndex),
            foldSnapshot: foldSnapshot?(document, viewID),
            onToggleFoldMarker: { regionID in
                toggleFoldMarker?(
                    document.sessionDocumentID, viewID,
                    document.buffer.revision, regionID
                ) == true
            },
            onRevealFoldedContent: { offset in
                revealFoldedContent?(
                    document.sessionDocumentID, viewID, offset
                ) == true
            },
            onSnippetNavigation: navigateSnippetPlaceholder,
            onCancelSnippetSession: cancelSnippetSession,
            completionController: completionController,
            locale: settings.settings.locale,
            onTextChange: { transaction in
                let applied = applyTextTransaction?(transaction) ?? model.apply(
                    transaction, to: document, inPaneAt: paneIndex
                )
                if applied, !transaction.edits.isEmpty {
                    editorCommandController.resetSelectionHistory(
                        documentID: document.sessionDocumentID, viewID: viewID
                    )
                }
                return applied
            },
            onSelectionChange: { selection in
                model.setSelection(
                    selection,
                    for: document.sessionDocumentID,
                    viewID: viewID
                )
            },
            onManualSelectionChange: { previous, selection in
                editorCommandController.recordSelectionChange(
                    documentID: document.sessionDocumentID, viewID: viewID,
                    documentRevision: document.buffer.revision,
                    from: previous, to: selection
                )
            },
            onScrollChange: { position in
                model.setScrollPosition(
                    x: position.x,
                    y: position.y,
                    for: document.sessionDocumentID,
                    viewID: viewID
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if !quickActions.isEmpty {
                quickActionToolbar
                    .padding(.top, 10)
                    .padding(.trailing, settings.settings.showMinimap ? 132 : 12)
            }
        }
        .task(id: parserBaseRequestKey) {
            let key = parserBaseRequestKey
            let source = document.buffer.text
            // A source/settings change invalidates both products. Selection-only
            // changes are intentionally excluded from this task so moving the
            // caret cannot discard highlighting or restart the base parse.
            parsedHighlighting = nil
            parsedIndentation = nil
            guard key == parserBaseRequestKey, document.buffer.text == source else { return }
            let analysis = await codeMirrorParserCoordinator.analyze(
                text: source, language: key.language, revision: key.revision,
                tabWidth: key.tabWidth, indentWidth: key.indentWidth,
                insertSpaces: key.insertSpaces
            )
            guard !Task.isCancelled, key == parserBaseRequestKey,
                  document.buffer.text == source else { return }
            parsedHighlighting = analysis?.syntaxHighlightSnapshot(
                documentID: key.documentID, documentRevision: key.revision
            )
            let baseIndentation = CodeMirrorParserCoordinator
                .parsedIndentationSnapshot(
                    from: analysis, text: source, language: key.language,
                    revision: key.revision, tabWidth: key.tabWidth,
                    indentWidth: key.indentWidth, insertSpaces: key.insertSpaces
                )
            // A slower base worker must not overwrite a cursor-specific result
            // that completed while it was running.
            if parsedIndentation == nil { parsedIndentation = baseIndentation }
        }
        .task(id: parserProbeRequestKey) {
            let key = parserProbeRequestKey
            let source = document.buffer.text
            guard !key.newlineIndentationPositions.isEmpty else { return }
            let analysis = await codeMirrorParserCoordinator.analyzeAfterProbeDebounce(
                text: source, language: key.language, revision: key.revision,
                tabWidth: key.tabWidth, indentWidth: key.indentWidth,
                insertSpaces: key.insertSpaces,
                newlineIndentationPositions: key.newlineIndentationPositions
            )
            guard !Task.isCancelled, key == parserProbeRequestKey,
                  document.buffer.text == source else { return }
            // Only an exact revision/position result replaces indentation. The
            // base highlighting remains independent of cursor churn.
            parsedIndentation = CodeMirrorParserCoordinator
                .parsedIndentationSnapshot(
                    from: analysis, text: source, language: key.language,
                    revision: key.revision, tabWidth: key.tabWidth,
                    indentWidth: key.indentWidth, insertSpaces: key.insertSpaces
                )
        }
        .onAppear {
            completionController.connect(
                model: model, actions: actions, workspace: workspace,
                languageServers: languageServerController,
                documentID: document.sessionDocumentID, viewID: viewID,
                paneIndex: paneIndex,
                applyTextTransaction: { _ in false },
                presentApproval: { request, confirm, decline in
                    if actions.canPresentLanguageServerApproval(
                        ownerID: completionController.id
                    ) {
                        actions.presentLanguageServerApproval(
                            request, ownerID: completionController.id,
                            confirm: confirm, decline: decline
                        )
                    } else {
                        decline()
                    }
                }
            )
            if isActivePane { isEditorFocused = true }
        }
        .onChange(of: model.paneLayout.activeViewID) { _, _ in
            isEditorFocused = isActivePane
            if !isActivePane {
                actions.withdrawLanguageServerApproval(ownerID: completionController.id)
                completionController.activeEditorDidChange()
            }
        }
        .onChange(of: focusRequest) { _, _ in
            if isActivePane { isEditorFocused = true }
        }
        .onChange(of: activeEditorFocusRequest) { _, _ in
            if isActivePane { isEditorFocused = true }
        }
        .onDisappear {
            actions.withdrawLanguageServerApproval(ownerID: completionController.id)
            completionController.shutdown()
        }
    }

    private var nativeScrollPosition: NativeTextEditorScrollPosition {
        let position = model.scrollPosition(
            for: document.sessionDocumentID,
            viewID: viewID
        )
        return NativeTextEditorScrollPosition(x: position.x, y: position.y)
    }

    private var focusBinding: Binding<Bool> {
        Binding(
            get: { isEditorFocused },
            set: { focused in
                if isEditorFocused != focused {
                    isEditorFocused = focused
                }
                guard focused, let currentIndex,
                      model.paneLayout.activePaneIndex != currentIndex else { return }
                _ = model.focusPane(at: currentIndex)
            }
        )
    }

    private var currentPaneIndex: Int? {
        model.paneLayout.panes.firstIndex { $0.viewID == viewID }
    }

    private var isActivePane: Bool {
        currentPaneIndex == model.paneLayout.activePaneIndex
    }

    private var quickActions: [EditorPaneQuickAction] {
        EditorPaneQuickActionPlan.actions(
            for: document,
            distractionFree: settings.settings.distractionFree
        )
    }

    private var quickActionToolbar: some View {
        HStack(spacing: 3) {
            ForEach(quickActions, id: \.self) { action in
                Button { executeQuickAction(action) } label: {
                    Label(
                        quickActionTitle(action),
                        systemImage: action.systemImage
                    )
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    quickActionIsPressed(action)
                        ? Color.white : Color.secondary
                )
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(quickActionIsPressed(action) ? Color.accentColor : .clear)
                }
                .help(quickActionTitle(action))
                .disabled(!quickActionIsEnabled(action))
                .accessibilityLabel(quickActionTitle(action))
                .accessibilityValue(quickActionIsPressed(action)
                    ? appLocale.text("On", zh: "已开启")
                    : appLocale.text("Off", zh: "已关闭")
                )
                .accessibilityAddTraits(
                    quickActionIsPressed(action) ? .isSelected : []
                )
                .accessibilityIdentifier(
                    EditorPaneAccessibility.quickActionID(
                        paneID: viewID.rawValue, action: action
                    )
                )
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55))
        }
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocale.text(
            "Document quick actions", zh: "文档快捷操作"
        ))
        .accessibilityIdentifier(
            EditorPaneAccessibility.quickActionBarID(viewID.rawValue)
        )
    }

    private func quickActionTitle(_ action: EditorPaneQuickAction) -> String {
        let fallback: String
        switch action {
        case .toggleMarkdownPreview:
            fallback = "Toggle Markdown Preview"
        case .openHTMLInBrowser:
            fallback = "Open in Browser"
        case .formatJSON:
            return appLocale.localized(.formatJson)
        case .compactJSON:
            return appLocale.localized(.compactJson)
        case .toggleJSONView:
            return appLocale.localized(.jsonView)
        }
        return Localization.commandLabel(
            for: action.commandID, locale: appLocale, fallback: fallback
        )
    }

    private func quickActionIsPressed(_ action: EditorPaneQuickAction) -> Bool {
        switch action {
        case .toggleMarkdownPreview:
            previewController.isMarkdownPreviewVisible
        case .toggleJSONView:
            previewController.isJSONViewVisible
        case .openHTMLInBrowser, .formatJSON, .compactJSON:
            false
        }
    }

    private func quickActionIsEnabled(_ action: EditorPaneQuickAction) -> Bool {
        commandRouter.status(
            for: action.commandID,
            context: actions.commandRoutingContext()
        )?.isEnabled == true
    }

    private func executeQuickAction(_ action: EditorPaneQuickAction) {
        let target = EditorPaneQuickActionTarget(
            paneIndex: paneIndex, paneID: viewID.rawValue,
            documentID: document.sessionDocumentID
        )
        guard let currentPaneIndex else { return }
        let currentPane = model.paneLayout.panes[currentPaneIndex]
        guard target.isCurrent(
            paneIndex: currentPaneIndex, paneID: currentPane.viewID.rawValue,
            paneContainsDocument: currentPane.contains(target.documentID)
        ) else { return }
        guard model.selectDocument(document, inPaneAt: currentPaneIndex) else {
            return
        }
        Task {
            guard target.isCurrent(
                paneIndex: model.paneLayout.panes.firstIndex {
                    $0.viewID.rawValue == target.paneID
                },
                paneID: model.paneLayout.panes.first(where: {
                    $0.viewID.rawValue == target.paneID
                })?.viewID.rawValue,
                paneContainsDocument: model.paneLayout.panes.first(where: {
                    $0.viewID.rawValue == target.paneID
                })?.contains(target.documentID) == true
            ), model.selectedDocument?.sessionDocumentID == target.documentID else {
                return
            }
            let result = await commandRouter.execute(
                action.commandID, context: actions.commandRoutingContext()
            )
            actions.handleCommandExecutionResult(result)
        }
    }

    private var isProseDocument: Bool {
        guard let extensionName = document.fileURL?.pathExtension.lowercased() else {
            return true
        }
        return ["", "txt", "text", "md", "markdown", "mdown", "mkd"]
            .contains(extensionName)
    }

    private var effectiveIndentation: IndentationPreferences {
        EditorConfig.resolveIndentation(
            config: document.editorConfig?.properties,
            detected: IndentationPreferences(
                indentSize: settings.settings.tabSize,
                insertSpaces: settings.settings.insertSpaces
            ),
            defaultTabWidth: settings.settings.tabSize
        )
    }

    private var editorDiagnosticSnapshot: LanguageServerDiagnosticPresentationSnapshot? {
        guard let root = diagnosticServerRoot,
              let config = NativeFeatureCoordinator.languageServerConfig(
                for: document, project: model.sessionProject
              ) else { return nil }
        return languageServerController.diagnosticPresentationSnapshot(
            documentID: document.sessionDocumentID, fileURL: document.fileURL,
            documentRevision: document.buffer.revision,
            serverKey: LanguageServerInstanceKey(root: root, config: config)
        )
    }

    private var diagnosticServerRoot: URL? {
        guard let fileURL = document.fileURL else { return nil }
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return workspace.roots.filter { root in
            let rootComponents = root.url.standardizedFileURL
                .resolvingSymlinksInPath().pathComponents
            return fileComponents.count >= rootComponents.count
                && zip(rootComponents, fileComponents).allSatisfy { $0.0 == $0.1 }
        }.max(by: { $0.url.path.count < $1.url.path.count })?.url
    }

    private struct ParserBaseRequestKey: Hashable {
        let documentID: String
        let revision: UInt64
        let language: String
        let tabWidth: Int
        let indentWidth: Int
        let insertSpaces: Bool
    }

    private struct ParserProbeRequestKey: Hashable {
        let base: ParserBaseRequestKey
        let newlineIndentationPositions: [Int]

        var documentID: String { base.documentID }
        var revision: UInt64 { base.revision }
        var language: String { base.language }
        var tabWidth: Int { base.tabWidth }
        var indentWidth: Int { base.indentWidth }
        var insertSpaces: Bool { base.insertSpaces }
    }

    private var parserBaseRequestKey: ParserBaseRequestKey {
        ParserBaseRequestKey(
            documentID: document.sessionDocumentID,
            revision: document.buffer.revision, language: document.language,
            tabWidth: effectiveIndentation.tabWidth,
            indentWidth: effectiveIndentation.indentSize,
            insertSpaces: effectiveIndentation.insertSpaces
        )
    }

    private var parserProbeRequestKey: ParserProbeRequestKey {
        ParserProbeRequestKey(
            base: parserBaseRequestKey,
            newlineIndentationPositions: CodeMirrorIndentationSnapshot.probePositions(
                for: model.selection(
                    for: document.sessionDocumentID, viewID: viewID
                ),
                textUTF16Length: document.buffer.text.utf16.count
            )
        )
    }
}
