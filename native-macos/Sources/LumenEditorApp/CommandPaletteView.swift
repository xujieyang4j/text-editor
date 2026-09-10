import AppKit
import Foundation
import LumenEditorCore
import SwiftUI

/// Presentation-only command palette.  Its caller owns presentation and supplies
/// a current routing-context snapshot, so this view does not depend on AppModel.
struct CommandPaletteView: View {
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ObservedObject private var router: CommandRouter
    let locale: CommandLocale
    let context: CommandRoutingContext
    let pluginRoutes: [PluginCommandRoute]
    let workerPluginRoutes: [PluginWorkerCommandRoute]
    let executePlugin: @MainActor (String) async -> Bool
    let executeWorkerPlugin: @MainActor (String) async -> Bool
    let onDismiss: @MainActor () -> Void

    @State private var query = ""
    @State private var selectedCommandID: String?
    @State private var feedback: CommandPaletteFeedback?
    @State private var isExecuting = false
    @FocusState private var searchIsFocused: Bool

    init(
        router: CommandRouter,
        locale: CommandLocale = .english,
        context: CommandRoutingContext = CommandRoutingContext(),
        pluginRoutes: [PluginCommandRoute] = [],
        workerPluginRoutes: [PluginWorkerCommandRoute] = [],
        executePlugin: @escaping @MainActor (String) async -> Bool = { _ in false },
        executeWorkerPlugin: @escaping @MainActor (String) async -> Bool = { _ in false },
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.router = router
        self.locale = locale
        self.context = context
        self.pluginRoutes = pluginRoutes
        self.workerPluginRoutes = workerPluginRoutes
        self.executePlugin = executePlugin
        self.executeWorkerPlugin = executeWorkerPlugin
        self.onDismiss = onDismiss
    }

    private var results: [RoutedCommandSearchResult] {
        router.search(query, locale: locale, context: context)
    }

    private var selectedResult: RoutedCommandSearchResult? {
        if let selectedCommandID {
            return results.first(where: { $0.id == selectedCommandID })
        }
        return results.first
    }

    private var pluginResults: [RoutedPluginCommandSearchResult] {
        router.searchPluginCommands(query, routes: pluginRoutes, context: context)
    }

    private var resultIDs: [String] {
        results.map(\.id) + pluginResults.map(\.id) + workerPluginResults.map(\.id)
    }

    private var workerPluginResults: [PluginWorkerCommandRoute] {
        CommandFuzzyMatcher.filter(query: query, items: workerPluginRoutes) { route in
            route.pluginName + ": " + route.title
        }.map { $0.item }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultList
            if let feedback {
                Divider()
                feedbackView(feedback)
            }
        }
        .frame(minWidth: 480, idealWidth: 620, maxWidth: 760)
        .frame(minHeight: 300, idealHeight: 440, maxHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.paletteTitle)
        .accessibilityIdentifier(Accessibility.paletteID)
        .onAppear {
            synchronizeSelection()
            searchIsFocused = true
        }
        .onChange(of: query) { _, _ in
            feedback = nil
            selectedCommandID = resultIDs.first
        }
        .onChange(of: router.revision) { _, _ in
            synchronizeSelection()
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: onDismiss)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(copy.searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .onSubmit(acceptSelection)
                .accessibilityLabel(copy.searchLabel)
                .accessibilityHint(copy.searchHint)
                .accessibilityIdentifier(Accessibility.queryID)

            if isExecuting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(copy.executing)
                    .accessibilityIdentifier(Accessibility.executingID)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if resultIDs.isEmpty {
                    Text(copy.noResults)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(28)
                        .accessibilityLabel(copy.noResults)
                        .accessibilityIdentifier(Accessibility.emptyID)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { result in
                            resultRow(result)
                                .id(result.id)
                        }
                        ForEach(pluginResults) { result in
                            pluginResultRow(result)
                                .id(result.id)
                        }
                        ForEach(workerPluginResults) { route in
                            workerPluginResultRow(route)
                                .id(route.id)
                        }
                    }
                    .padding(6)
                }
            }
            .accessibilityLabel(copy.resultsLabel)
            .accessibilityIdentifier(Accessibility.resultsID)
            .onChange(of: selectedCommandID) { _, commandID in
                guard let commandID else { return }
                withAnimation(AppAccessibility.animation(
                    reduceMotion: reduceMotion, duration: 0.1
                )) {
                    proxy.scrollTo(commandID, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ result: RoutedCommandSearchResult) -> some View {
        let isSelected = selectedCommandID == result.id
        return Button {
            selectedCommandID = result.id
            execute(result)
        } label: {
            HStack(spacing: 12) {
                Text(result.command.title(for: locale))
                    .lineLimit(1)
                    .foregroundStyle(result.status.isEnabled ? .primary : .secondary)

                Spacer(minLength: 12)

                if let shortcutHint = result.shortcutHint {
                    Text(shortcutHint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("\(copy.shortcut): \(shortcutHint)")
                }

                if !result.status.isEnabled {
                    Text(statusText(result.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(selectionOpacity) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected && colorSchemeContrast == .increased
                            ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!result.status.isEnabled || isExecuting)
        .accessibilityLabel(result.command.title(for: locale))
        .accessibilityValue(statusText(result.status))
        .accessibilityHint(
            result.status.isEnabled ? copy.executeHint : statusText(result.status)
        )
        .accessibilityIdentifier(Accessibility.itemID(result.id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pluginResultRow(
        _ result: RoutedPluginCommandSearchResult
    ) -> some View {
        let selected = selectedCommandID == result.id
        return Button {
            selectedCommandID = result.id
            executePluginResult(result)
        } label: {
            HStack(spacing: 12) {
                Text(
                    "\(copy.plugin): \(result.route.pluginName): \(result.route.title)"
                )
                    .lineLimit(1)
                    .foregroundStyle(result.status.isEnabled ? .primary : .secondary)
                Spacer(minLength: 12)
                if !result.status.isEnabled {
                    Text(statusText(result.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(selectionOpacity) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        selected && colorSchemeContrast == .increased
                            ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!result.status.isEnabled || isExecuting)
        .accessibilityLabel(
            "\(copy.plugin) \(result.route.pluginName), \(result.route.title)"
        )
        .accessibilityValue(statusText(result.status))
        .accessibilityHint(
            result.status.isEnabled ? copy.executeHint : statusText(result.status)
        )
        .accessibilityIdentifier(Accessibility.itemID(result.id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func feedbackView(_ feedback: CommandPaletteFeedback) -> some View {
        let message = localizedFeedback(feedback)
        return Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .accessibilityLabel(message)
            .accessibilityIdentifier(Accessibility.feedbackID)
    }

    private func workerPluginResultRow(_ route: PluginWorkerCommandRoute) -> some View {
        let selected = selectedCommandID == route.id
        return Button {
            selectedCommandID = route.id
            executeWorkerPluginResult(route)
        } label: {
            HStack(spacing: 12) {
                Text("\(copy.plugin): \(route.pluginName): \(route.title)")
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(copy.worker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(selectionOpacity) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .accessibilityLabel(
            "\(copy.plugin) \(route.pluginName), \(route.title)"
        )
        .accessibilityHint(copy.executeHint)
        .accessibilityIdentifier(Accessibility.itemID(route.id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func synchronizeSelection() {
        let ids = resultIDs
        guard !ids.isEmpty else {
            selectedCommandID = nil
            return
        }
        if let selectedCommandID, ids.contains(selectedCommandID) {
            return
        }
        selectedCommandID = ids.first
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .down:
            moveSelection(by: 1)
        case .up:
            moveSelection(by: -1)
        default:
            return
        }
    }

    private func moveSelection(by offset: Int) {
        let ids = resultIDs
        guard !ids.isEmpty else { return }
        let currentIndex = selectedCommandID.flatMap(ids.firstIndex(of:)) ?? 0
        let nextIndex = (currentIndex + offset + ids.count) % ids.count
        selectedCommandID = ids[nextIndex]
    }

    private func acceptSelection() {
        guard !isExecuting else { return }
        if let selectedCommandID,
           let worker = workerPluginResults.first(where: { $0.id == selectedCommandID }) {
            executeWorkerPluginResult(worker)
            return
        }
        if let selectedCommandID,
           let plugin = pluginResults.first(where: { $0.id == selectedCommandID }) {
            executePluginResult(plugin)
            return
        }
        guard let selectedResult else { return }
        guard selectedResult.status.isEnabled else {
            feedback = .routeStatus(selectedResult.status)
            return
        }
        execute(selectedResult)
    }

    private func executePluginResult(_ result: RoutedPluginCommandSearchResult) {
        guard result.status.isEnabled, !isExecuting else {
            feedback = .routeStatus(result.status)
            return
        }
        isExecuting = true
        Task { @MainActor in
            let succeeded = await executePlugin(result.id)
            isExecuting = false
            if succeeded { onDismiss() }
            else { feedback = .app(.commandPaletteUnavailable) }
        }
    }

    private func executeWorkerPluginResult(_ route: PluginWorkerCommandRoute) {
        guard !isExecuting else { return }
        isExecuting = true
        Task { @MainActor in
            let succeeded = await executeWorkerPlugin(route.id)
            isExecuting = false
            if succeeded { onDismiss() }
            else { feedback = .app(.commandPaletteUnavailable) }
        }
    }

    private func execute(_ result: RoutedCommandSearchResult) {
        guard !isExecuting else { return }
        guard result.status.isEnabled else {
            feedback = .routeStatus(result.status)
            return
        }

        isExecuting = true
        feedback = nil
        Task { @MainActor in
            let execution = await router.execute(result.command.id, context: context)
            isExecuting = false
            switch execution {
            case .executed:
                onDismiss()
            case .visiblePanel:
                onDismiss()
            case .noChange:
                feedback = .app(.commandPaletteNoChange)
            case let .unavailable(status):
                feedback = .routeStatus(status)
            case .unknownCommand:
                feedback = .app(.commandPaletteUnknownCommand)
            case let .failed(_, error):
                feedback = .from(error: error)
            }
        }
    }

    private func localizedFeedback(_ feedback: CommandPaletteFeedback) -> String {
        feedback.localized(locale: appLocale)
    }

    private func statusText(_ status: CommandRouteStatus) -> String {
        CommandPaletteFeedback.routeStatus(status).localized(locale: appLocale)
    }

    private var selectionOpacity: Double {
        colorSchemeContrast == .increased ? 0.34 : 0.16
    }

    private var copy: Copy { Copy(appLocale: appLocale) }

    enum Accessibility {
        static let paletteID = "panel.commandPalette"
        static let queryID = "panel.commandPalette.query"
        static let executingID = "panel.commandPalette.executing"
        static let resultsID = "panel.commandPalette.results"
        static let emptyID = "panel.commandPalette.empty"
        static let feedbackID = "panel.commandPalette.feedback"

        static func itemID(_ id: String) -> String {
            "panel.commandPalette.item." + id
        }
    }
}

private struct Copy {
    let appLocale: EditorLocale

    var paletteTitle: String { text("Command Palette", "命令面板") }
    var searchPlaceholder: String { text("Type a command…", "输入命令…") }
    var searchLabel: String { text("Search commands", "搜索命令") }
    var searchHint: String {
        text(
            "Type to filter; use Up and Down to select, Return to run, and Escape to close",
            "输入以筛选；使用上下方向键选择，按回车键执行，按 Esc 键关闭。"
        )
    }
    var resultsLabel: String { text("Command results", "命令结果") }
    var noResults: String { text("No matching commands", "没有匹配的命令") }
    var shortcut: String { text("Shortcut", "快捷键") }
    var executing: String { text("Executing command", "正在执行命令") }
    var executeHint: String { text("Runs this command", "执行此命令") }
    var available: String { text("Available", "可用") }
    var unavailable: String { appLocale.localizedApp(.commandPaletteUnavailable) }
    var unsupported: String { appLocale.localizedApp(.commandPaletteUnsupported) }
    var plugin: String { text("Plugin", "插件") }
    var worker: String { text("Worker", "Worker") }

    private func text(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }
}

enum CommandPaletteFeedback: Equatable {
    case app(AppLocalizedCopy)
    case routeStatus(CommandRouteStatus)
    case failure(CommandPresentation)

    static func from(error: any Error) -> Self {
        if let signal = error as? CommandHandlerSignal,
           case let .failedPresentation(presentation) = signal {
            return .failure(presentation)
        }
        if let error = error as? any AppPresentationError {
            return .failure(.app(error.presentationText))
        }
        return .failure(CommandPresentation(error.localizedDescription))
    }

    func localized(locale: EditorLocale) -> String {
        switch self {
        case let .app(copy):
            return locale.localizedApp(copy)
        case let .routeStatus(status):
            return Self.localized(status: status, locale: locale)
        case let .failure(content):
            return locale.localizedCommandPresentation(content)
        }
    }

    private static func localized(
        status: CommandRouteStatus,
        locale: EditorLocale
    ) -> String {
        switch status {
        case .enabled:
            return locale.text("Available", zh: "可用")
        case .unsupported:
            return locale.localizedApp(.commandPaletteUnsupported)
        case let .disabled(.handler(reason)):
            return reason.map { localizedHandlerReason($0, locale: locale) }
                ?? locale.localizedApp(.commandPaletteUnavailable)
        case .disabled(.missingRequirements):
            return locale.localizedApp(.commandPaletteUnavailable)
        }
    }

    private static func localizedHandlerReason(
        _ reason: String,
        locale: EditorLocale
    ) -> String {
        guard locale.isSimplifiedChinese else { return reason }
        return switch reason {
        case "Document format selection unavailable": "文档格式选择不可用"
        case "No editable document": "没有可编辑的文档"
        case "No saved document": "没有已保存的文档"
        case "No active document", "No active document.": "没有活动文档"
        case "Outline is updating": "大纲正在更新"
        case "No workspace", "No workspace.": "没有工作区"
        case "Project settings are being saved": "正在保存项目设置"
        case "Requires an HTML document.": "需要 HTML 文档。"
        case "Macro controller unavailable": "宏控制器不可用"
        case "A macro is being replayed": "正在重放宏"
        case "No document or workspace": "没有文档或工作区"
        case "No editable document is active.": "没有活动的可编辑文档。"
        case "There are no other tabs to close.": "没有其他可关闭的标签页。"
        case "There are no tabs to the right.": "右侧没有可关闭的标签页。"
        case "There are no tabs to close.": "没有可关闭的标签页。"
        case "Finish the current interaction first.": "请先完成当前交互。"
        case "Open a workspace before adding another folder.":
            "请先打开工作区，再添加其他文件夹。"
        case "There is no project folder to remove.": "没有可移除的项目文件夹。"
        case "There are no unsaved documents.": "没有未保存的文档。"
        case "There is no recently closed tab.": "没有最近关闭的标签页。"
        case "Save the document before reopening it.": "请先保存文档，再重新打开。"
        case "The active document has no file path.": "活动文档没有文件路径。"
        case "The active file is outside the workspace.": "活动文件不在工作区内。"
        case "The command palette is already open.": "命令面板已打开。"
        case "Workspace search is already open.": "工作区搜索已打开。"
        case "There is no workspace replacement to undo.": "没有可撤销的工作区替换。"
        case "Git changes are already open.": "Git 更改面板已打开。"
        case "The primary workspace is not a Git repository.": "主工作区不是 Git 仓库。"
        case "A workspace build is unavailable right now.": "工作区构建当前不可用。"
        case "Open a workspace before selecting a build system.":
            "请先打开工作区，再选择构建系统。"
        case "There is no build output to show.": "没有可显示的构建输出。"
        case "No build systems are configured.": "未配置构建系统。"
        case "Open a workspace before using the terminal.": "请先打开工作区，再使用终端。"
        case "The active document is not JSON.": "活动文档不是 JSON。"
        case "Open a workspace first.": "请先打开工作区。"
        case "No language server is configured for this document.":
            "此文档未配置语言服务器。"
        case "Open a saved file in a workspace before using symbol navigation.":
            "请先打开工作区中的已保存文件，再使用符号导航。"
        case "Maximum zoom reached.": "已达到最大缩放级别。"
        case "Minimum zoom reached.": "已达到最小缩放级别。"
        case "The editor is already at actual size.": "编辑器已处于实际大小。"
        case "Recent items unavailable": "最近打开项不可用"
        case "No recent-file opener": "没有最近文件打开器"
        case "No recent-project opener": "没有最近项目打开器"
        case "Requires syntax-tree support": "需要语法树支持"
        case "Language selection unavailable": "语言选择不可用"
        case "Color scheme selection unavailable": "配色方案选择不可用"
        case "Editor command controller unavailable": "编辑器命令控制器不可用"
        case "Outline unavailable": "大纲不可用"
        case "Language tools unavailable.": "语言工具不可用。"
        case "A language tool operation is active.": "语言工具操作正在进行。"
        case "Sublime import unavailable": "Sublime 导入不可用"
        case "A Sublime import is in progress": "正在进行 Sublime 导入"
        case "Incremental diff unavailable": "增量差异不可用"
        case "Save the document first": "请先保存文档"
        case "Resolve the external file conflict first": "请先解决外部文件冲突"
        case "Find unavailable": "查找不可用"
        case "Bookmarks unavailable": "书签不可用"
        case "Update service unavailable": "更新服务不可用"
        case "An update check is already running": "更新检查正在进行"
        case "Navigation unavailable": "导航不可用"
        case "No back navigation location": "没有上一处导航位置"
        case "No forward navigation location": "没有下一处导航位置"
        default: reason
        }
    }
}
