import AppKit
import LumenEditorCore
import SwiftUI

/// A self-contained Find/Replace in Files panel. It is intentionally not wired
/// into `EditorWindowView` here: the shell chooses sheet, popover, or side-panel
/// presentation and owns opening a selected match in the editor.
struct WorkspaceSearchPanelView: View {
    @ObservedObject var controller: WorkspaceSearchController
    let onDismiss: () -> Void

    @FocusState private var focusedField: Field?
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        controller: WorkspaceSearchController,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            statusBar
            Divider()
            results
        }
        .frame(minWidth: 520, idealWidth: 700, maxWidth: 900)
        .frame(minHeight: 390, idealHeight: 560, maxHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "在文件中查找和替换"))
        .accessibilityIdentifier(AppAccessibility.id("workspace search panel"))
        .onAppear { focusedField = .query }
        .onExitCommand { dismiss() }
        .alert(
            l("Apply Replacement Preview?", "应用替换预览？"),
            isPresented: confirmationBinding
        ) {
            Button(l("Cancel", "取消"), role: .cancel) {
                controller.cancelApplyConfirmation()
            }
            Button(appLocale.localized(.replaceAll), role: .destructive) {
                _ = controller.confirmApplyPreview()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker(l("Mode", "模式"), selection: $controller.mode) {
                ForEach(WorkspaceSearchMode.allCases) { mode in
                    Text(mode == .find ? appLocale.localized(.find) : appLocale.localized(.replace))
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .accessibilityLabel(l(Accessibility.mode, "搜索模式"))
            .accessibilityIdentifier(AppAccessibility.id("workspace search mode"))

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .disabled(controller.isMutatingFiles)
            .help(l("Close Find in Files", "关闭在文件中查找"))
            .accessibilityLabel(l(Accessibility.close, "关闭在文件中查找"))
            .accessibilityIdentifier(AppAccessibility.id("workspace search close"))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var form: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(l("Search workspace", "搜索工作区"), text: $controller.query)
                    .focused($focusedField, equals: .query)
                    .onSubmit { _ = controller.performPrimaryAction() }
                    .accessibilityLabel(l(Accessibility.query, "搜索查询"))
                    .accessibilityHint(l(
                        "Enter text or a regular expression to find in authorised workspace roots.",
                        "输入文本或正则表达式，在已授权的工作区根目录中查找。"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id("workspace search query"))
                if !controller.searchHistory.isEmpty {
                    historyMenu(
                        items: controller.searchHistory,
                        title: l(Accessibility.searchHistory, "最近搜索"),
                        identifier: AppAccessibility.id("workspace search history")
                    ) { controller.query = $0 }
                }
            }

            if controller.mode == .replace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(l("Replace with", "替换为"), text: $controller.replacement)
                        .focused($focusedField, equals: .replacement)
                        .onSubmit { _ = controller.previewReplacement() }
                        .accessibilityLabel(l(Accessibility.replacement, "替换文本"))
                        .accessibilityHint(l(
                            "Replacement text. Regular expression mode supports capture references such as dollar one.",
                            "替换文本。正则表达式模式支持类似美元符号加一的捕获引用。"
                        ))
                        .accessibilityIdentifier(AppAccessibility.id("workspace search replacement"))
                    if !controller.replaceHistory.isEmpty {
                        historyMenu(
                            items: controller.replaceHistory,
                            title: l(Accessibility.replaceHistory, "最近替换"),
                            identifier: AppAccessibility.id("workspace replace history"),
                            labelsEmptyValue: true
                        ) { controller.replacement = $0 }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(appLocale.localized(.includePlaceholder), text: $controller.includePattern)
                    .accessibilityLabel(l(Accessibility.include, "要包含的文件"))
                    .accessibilityIdentifier(AppAccessibility.id("workspace search include"))
                TextField(appLocale.localized(.excludePlaceholder), text: $controller.excludePattern)
                    .accessibilityLabel(l(Accessibility.exclude, "要排除的文件"))
                    .accessibilityIdentifier(AppAccessibility.id("workspace search exclude"))
            }

            HStack(spacing: 14) {
                Toggle(l("Match Case", "区分大小写"), isOn: $controller.isCaseSensitive)
                    .accessibilityLabel(l(Accessibility.caseSensitive, "区分大小写"))
                Toggle(l("Whole Word", "全字匹配"), isOn: $controller.isWholeWord)
                    .accessibilityLabel(l(Accessibility.wholeWord, "全字匹配"))
                Toggle(l("Regular Expression", "正则表达式"), isOn: $controller.usesRegularExpression)
                    .accessibilityLabel(l(Accessibility.regularExpression, "使用正则表达式"))

                Spacer(minLength: 8)

                if controller.isCancelable {
                    Button(l("Cancel", "取消")) { controller.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(l(Accessibility.cancel, "取消工作区搜索"))
                        .accessibilityIdentifier(AppAccessibility.id("workspace search cancel"))
                }

                Button(primaryActionTitle) {
                    _ = controller.performPrimaryAction()
                }
                .disabled(!primaryActionEnabled)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Self.primaryActionAccessibilityLabel(
                    mode: controller.mode, locale: appLocale
                ))
                .accessibilityIdentifier(AppAccessibility.id("workspace search primary action"))

                if controller.mode == .replace {
                    Button(l("Apply Preview", "应用预览")) {
                        _ = controller.requestApplyPreview()
                    }
                    .disabled(!controller.canApplyPreview || previewReplacementCount == 0)
                    .accessibilityLabel(l(Accessibility.applyPreview, "应用替换预览"))
                    .accessibilityIdentifier(AppAccessibility.id("workspace search apply preview"))
                }

                Button(l("Undo Replace", "撤销替换")) {
                    _ = controller.undoLastReplacement()
                }
                .disabled(!controller.canUndo)
                .accessibilityLabel(l(Accessibility.undo, "撤销上次工作区替换"))
                .accessibilityIdentifier(AppAccessibility.id("workspace search undo"))
            }
            .toggleStyle(.checkbox)
        }
        .padding(14)
        .disabled(controller.isMutatingFiles)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if controller.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(l(Accessibility.progress, "工作区搜索忙碌"))
                }
                Text(localizedStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(localizedStatusMessage)
            }

            if let issue = controller.issue {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedIssueTitle(issue.titleContent))
                            .font(.caption.weight(.semibold))
                        Text(appLocale.localizedWorkspaceSearchIssue(issue.content))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 4)
                    Button { controller.dismissIssue() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l(Accessibility.dismissError, "关闭工作区搜索错误"))
                    .accessibilityIdentifier(AppAccessibility.id("workspace search dismiss error"))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    "\(localizedIssueTitle(issue.titleContent)). \(appLocale.localizedWorkspaceSearchIssue(issue.content))"
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func historyMenu(
        items: [String],
        title: String,
        identifier: String,
        labelsEmptyValue: Bool = false,
        select: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(Array(items.prefix(50).enumerated()), id: \.offset) { _, item in
                Button(labelsEmptyValue && item.isEmpty
                    ? l("Empty replacement", "空替换文本")
                    : item) {
                    select(item)
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if controller.matches.isEmpty {
                    ContentUnavailableView(
                        l("No Results", "没有结果"),
                        systemImage: "text.magnifyingglass",
                        description: Text(emptyResultsMessage)
                    )
                    .padding(24)
                    .accessibilityLabel(emptyResultsMessage)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.matches.enumerated()), id: \.offset) { index, match in
                            resultRow(match, index: index)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
            }
            .accessibilityLabel(l(Accessibility.results, "工作区搜索结果"))
            .accessibilityIdentifier(AppAccessibility.id("workspace search results"))
            .onChange(of: controller.selectedResultIndex) { _, index in
                guard let index else { return }
                withAnimation(AppAccessibility.animation(reduceMotion: reduceMotion, duration: 0.1)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .down:
                _ = controller.moveResult(by: 1)
            case .up:
                _ = controller.moveResult(by: -1)
            default:
                break
            }
        }
    }

    private func resultRow(_ match: WorkspaceMatch, index: Int) -> some View {
        let selected = controller.selectedResultIndex == index
        return Button {
            Task { @MainActor in
                _ = await controller.navigate(to: index)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(match.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(match.line):\(match.column)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(match.url.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(match.lineText)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected
                        ? Color.accentColor.opacity(
                            AppAccessibility.selectionOpacity(for: colorSchemeContrast)
                        )
                        : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l(
            "\(match.url.lastPathComponent), line \(match.line), column \(match.column)",
            "\(match.url.lastPathComponent)，第 \(match.line) 行，第 \(match.column) 列"
        ))
        .accessibilityValue(match.lineText)
        .accessibilityHint(l("Opens this search result", "打开此搜索结果"))
    }

    private var primaryActionEnabled: Bool {
        controller.mode == .find ? controller.canSearch : controller.canPreviewReplacement
    }

    private var previewReplacementCount: Int {
        guard case let .previewReady(_, replacements, _) = controller.status else { return 0 }
        return replacements
    }

    private var confirmationMessage: String {
        guard case let .previewReady(files, replacements, truncated) = controller.status else {
            return l("Apply the previewed replacements?", "应用预览中的替换？")
        }
        if appLocale == .zhCN {
            return "替换 \(files) 个文件中的 \(replacements) 个匹配项？"
                + (truncated ? " 只会更改受限预览中的内容。" : "")
        }
        let limitWarning = truncated ? " Only the bounded preview will be changed." : ""
        return "Replace \(replacements) match\(replacements == 1 ? "" : "es") in \(files) file\(files == 1 ? "" : "s")?\(limitWarning)"
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { controller.isApplyConfirmationPresented },
            set: { if !$0 { controller.cancelApplyConfirmation() } }
        )
    }

    private var emptyResultsMessage: String {
        switch controller.status {
        case .idle:
            return l("Enter a query, then search the authorised workspace roots.", "输入查询，然后搜索已授权的工作区根目录。")
        case .searching, .previewing:
            return l("Results will appear here.", "结果将显示在这里。")
        case .cancelled:
            return l("The operation was cancelled.", "操作已取消。")
        case .applying, .undoing:
            return l("The file operation is still running.", "文件操作仍在进行中。")
        default:
            return l("No matching text was found.", "未找到匹配文本。")
        }
    }

    private var primaryActionTitle: String {
        controller.mode == .find ? appLocale.localized(.findAll) : l("Preview Replace", "预览替换")
    }

    private var localizedStatusMessage: String {
        appLocale.localizedWorkspaceSearchStatus(
            controller.status,
            hasRoots: !controller.rootIDs.isEmpty,
            purpose: .visible
        )
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    private func localizedIssueTitle(
        _ title: WorkspaceSearchPresentationIssue.Title
    ) -> String {
        appLocale.localizedWorkspaceSearchIssueTitle(title)
    }

    static func primaryActionAccessibilityLabel(
        mode: WorkspaceSearchMode, locale: EditorLocale
    ) -> String {
        switch mode {
        case .find:
            locale.text(Accessibility.primaryAction, zh: "运行工作区搜索")
        case .replace:
            locale.text(Accessibility.previewReplacement, zh: "预览工作区替换")
        }
    }

    private func dismiss() {
        guard !controller.isMutatingFiles else { return }
        controller.dismiss()
        onDismiss()
    }

    private enum Field: Hashable {
        case query
        case replacement
    }

    enum Accessibility {
        static let panel = "Find and Replace in Files"
        static let mode = "Search Mode"
        static let query = "Search Query"
        static let replacement = "Replacement Text"
        static let searchHistory = "Recent Workspace Searches"
        static let replaceHistory = "Recent Workspace Replacements"
        static let include = "Files to Include"
        static let exclude = "Files to Exclude"
        static let caseSensitive = "Match Case"
        static let wholeWord = "Match Whole Word"
        static let regularExpression = "Use Regular Expression"
        static let primaryAction = "Run Workspace Search"
        static let previewReplacement = "Preview Workspace Replacement"
        static let applyPreview = "Apply Replacement Preview"
        static let undo = "Undo Last Workspace Replacement"
        static let cancel = "Cancel Workspace Search"
        static let close = "Close Find in Files"
        static let progress = "Workspace Search Busy"
        static let results = "Workspace Search Results"
        static let dismissError = "Dismiss Workspace Search Error"
    }
}
