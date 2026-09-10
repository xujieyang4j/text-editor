import SwiftUI

struct MacroSnippetView: View {
    @ObservedObject var controller: MacroSnippetController
    let onDismiss: () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: iconName).accessibilityHidden(true)
                TextField(placeholder, text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(accept)
                    .accessibilityLabel(queryAccessibilityLabel)
                    .accessibilityHint(queryAccessibilityHint)
                    .accessibilityIdentifier(Accessibility.query)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(appLocale.text(
                        "Close Macro and Snippet Picker",
                        zh: "关闭宏和代码片段选择器"
                    ))
                    .accessibilityIdentifier(Accessibility.close)
            }
            .padding(12)
            Divider()
            content
            if let issue = controller.issue {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(issueForeground)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(appLocale.localizedMacroSnippetIssueTitle(issue.titleContent))
                            .font(.headline)
                        Text(appLocale.localizedMacroSnippetIssue(issue.content))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(appLocale.text("Dismiss", zh: "忽略")) {
                        controller.dismissIssue()
                    }
                    .accessibilityIdentifier(Accessibility.dismissIssue)
                }
                .padding(10)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(Accessibility.issue)
            }
        }
        .frame(minWidth: 480, idealWidth: 620, maxWidth: 780)
        .frame(minHeight: 280, idealHeight: 430, maxHeight: 620)
        .onAppear { inputFocused = true }
        .onMoveCommand { direction in
            switch direction {
            case .down: controller.moveSelection(by: 1)
            case .up: controller.moveSelection(by: -1)
            default: break
            }
        }
        .onExitCommand(perform: dismiss)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panelAccessibilityLabel)
        .accessibilityIdentifier(Accessibility.panel)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.presentation {
        case .saveName:
            VStack(alignment: .leading, spacing: 12) {
                Text(appLocale.text(
                    "Save the recorded macro with a project-local name.",
                    zh: "使用项目内名称保存已录制的宏。"
                ))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(appLocale.text("Cancel", zh: "取消"), action: dismiss)
                        .accessibilityIdentifier(Accessibility.cancel)
                    Spacer()
                    Button(appLocale.text("Save", zh: "保存")) {
                        if controller.saveMacro(named: controller.query) { onDismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint(appLocale.text(
                        "Saves the recorded macro in the current workspace.",
                        zh: "将已录制的宏保存到当前工作区。"
                    ))
                    .accessibilityIdentifier(Accessibility.save)
                }
            }
            .padding(16)
        case .savedMacros:
            resultList(count: controller.macroItems.count) { index in
                let item = controller.macroItems[index]
                Button {
                    controller.selectItem(at: index)
                    Task {
                        if await controller.runSavedMacro(id: item.id) { onDismiss() }
                    }
                } label: {
                    resultLabel(
                        item.label,
                        detail: localizedMacroDetail(item),
                        selected: controller.selectedIndex == index
                    )
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .accessibilityValue(resultAccessibilityValue(
                        detail: localizedMacroDetail(item),
                        selected: controller.selectedIndex == index
                    ))
                    .accessibilityHint(appLocale.text(
                        "Runs this saved macro.",
                        zh: "运行此已保存的宏。"
                    ))
                    .accessibilityIdentifier(Accessibility.item + item.id)
                    .accessibilityAddTraits(
                        controller.selectedIndex == index ? .isSelected : []
                    )
            }
        case .snippets:
            resultList(count: controller.snippetItems.count) { index in
                let item = controller.snippetItems[index]
                Button {
                    controller.selectItem(at: index)
                    if controller.insertSnippet(id: item.id) { onDismiss() }
                } label: {
                    resultLabel(
                        localizedSnippetTitle(item),
                        detail: item.snippet.trigger,
                        selected: controller.selectedIndex == index
                    )
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localizedSnippetTitle(item))
                    .accessibilityValue(resultAccessibilityValue(
                        detail: item.snippet.trigger.map {
                            appLocale.text("Trigger: \($0)", zh: "触发词：\($0)")
                        },
                        selected: controller.selectedIndex == index
                    ))
                    .accessibilityHint(appLocale.text(
                        "Inserts this snippet.",
                        zh: "插入此代码片段。"
                    ))
                    .accessibilityIdentifier(Accessibility.item + item.id)
                    .accessibilityAddTraits(
                        controller.selectedIndex == index ? .isSelected : []
                    )
            }
        case .none:
            ContentUnavailableView(
                appLocale.text("Nothing to Show", zh: "没有可显示的内容"),
                systemImage: "text.badge.xmark"
            )
            .accessibilityIdentifier(Accessibility.empty)
        }
    }

    private func resultList<Row: View>(
        count: Int, @ViewBuilder row: @escaping (Int) -> Row
    ) -> some View {
        ScrollView {
            if count == 0 {
                ContentUnavailableView(
                    appLocale.text("No Matches", zh: "没有匹配项"),
                    systemImage: "magnifyingglass",
                    description: Text(appLocale.text(
                        "Try a different search.",
                        zh: "请尝试其他搜索内容。"
                    ))
                )
                .accessibilityIdentifier(Accessibility.empty)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<count, id: \.self) { index in row(index) }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(resultsAccessibilityLabel)
        .accessibilityIdentifier(Accessibility.results)
    }

    private func resultLabel(
        _ title: String, detail: String?, selected: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(selectionOpacity) : .clear)
        )
        .overlay {
            if selected && colorSchemeContrast == .increased {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func accept() {
        switch controller.presentation {
        case .saveName:
            if controller.saveMacro(named: controller.query) { onDismiss() }
        case .savedMacros:
            guard let index = controller.selectedIndex,
                  controller.macroItems.indices.contains(index) else { return }
            Task {
                if await controller.runSavedMacro(id: controller.macroItems[index].id) {
                    onDismiss()
                }
            }
        case .snippets:
            guard let index = controller.selectedIndex,
                  controller.snippetItems.indices.contains(index) else { return }
            if controller.insertSnippet(id: controller.snippetItems[index].id) { onDismiss() }
        case .none:
            break
        }
    }

    private func dismiss() {
        controller.dismissPresentation()
        onDismiss()
    }

    private var placeholder: String {
        switch controller.presentation {
        case .saveName: appLocale.text("Macro name", zh: "宏名称")
        case .savedMacros: appLocale.text("Filter saved macros", zh: "筛选已保存的宏")
        case .snippets: appLocale.text("Filter snippets", zh: "筛选代码片段")
        case .none: appLocale.text("Search", zh: "搜索")
        }
    }

    private var iconName: String {
        switch controller.presentation {
        case .saveName, .savedMacros: "record.circle"
        case .snippets: "curlybraces"
        case .none: "text.badge.xmark"
        }
    }

    private var panelAccessibilityLabel: String {
        switch controller.presentation {
        case .saveName: appLocale.text("Save Macro", zh: "保存宏")
        case .savedMacros: appLocale.text("Saved Macro Picker", zh: "已保存宏选择器")
        case .snippets: appLocale.text("Snippet Picker", zh: "代码片段选择器")
        case .none: appLocale.text("Macro and Snippet Picker", zh: "宏和代码片段选择器")
        }
    }

    private var queryAccessibilityLabel: String {
        switch controller.presentation {
        case .saveName: appLocale.text("Macro name", zh: "宏名称")
        case .savedMacros: appLocale.text("Saved macro filter", zh: "已保存宏筛选")
        case .snippets: appLocale.text("Snippet filter", zh: "代码片段筛选")
        case .none: appLocale.text("Search", zh: "搜索")
        }
    }

    private var queryAccessibilityHint: String {
        switch controller.presentation {
        case .saveName:
            appLocale.text(
                "Enter a project-local name for the recorded macro.",
                zh: "输入已录制宏的项目内名称。"
            )
        case .savedMacros:
            appLocale.text("Filters the saved macro list.", zh: "筛选已保存宏列表。")
        case .snippets:
            appLocale.text("Filters the snippet list.", zh: "筛选代码片段列表。")
        case .none:
            appLocale.text("Searches available items.", zh: "搜索可用项目。")
        }
    }

    private var resultsAccessibilityLabel: String {
        switch controller.presentation {
        case .savedMacros: appLocale.text("Saved macros", zh: "已保存的宏")
        case .snippets: appLocale.text("Snippets", zh: "代码片段")
        case .saveName, .none: appLocale.text("Results", zh: "结果")
        }
    }

    private var selectionOpacity: Double {
        colorSchemeContrast == .increased ? 0.34 : 0.18
    }

    private var issueForeground: Color {
        colorSchemeContrast == .increased ? .primary : .orange
    }

    private func localizedMacroDetail(_ item: MacroPickerItem) -> String {
        let count = item.macro.replayOperations.count
        return appLocale.text(
            "\(count) step\(count == 1 ? "" : "s")",
            zh: "\(count) 个步骤"
        )
    }

    private func localizedSnippetTitle(_ item: SnippetPickerItem) -> String {
        switch item.snippet.source {
        case .builtIn:
            switch item.id {
            case "built-in:console-log": return appLocale.text("Console log", zh: "控制台日志")
            case "built-in:function": return appLocale.text("Function", zh: "函数")
            case "built-in:try-catch": return appLocale.text("Try / catch", zh: "尝试 / 捕获")
            default: return item.snippet.label
            }
        case .project:
            return appLocale.text(
                "Project: \(item.snippet.label)",
                zh: "项目：\(item.snippet.label)"
            )
        case let .plugin(_, name):
            return "\(name): \(item.snippet.label)"
        }
    }

    private func resultAccessibilityValue(detail: String?, selected: Bool) -> String {
        let selectedText = selected ? appLocale.text("Selected", zh: "已选择") : nil
        return [detail, selectedText].compactMap { $0 }.joined(separator: ", ")
    }

    enum Accessibility {
        static let panel = "panel.macroSnippet"
        static let query = "panel.macroSnippet.query"
        static let close = "panel.macroSnippet.close"
        static let results = "panel.macroSnippet.results"
        static let item = "panel.macroSnippet.item."
        static let cancel = "panel.macroSnippet.cancel"
        static let save = "panel.macroSnippet.save"
        static let empty = "panel.macroSnippet.empty"
        static let issue = "panel.macroSnippet.issue"
        static let dismissIssue = "panel.macroSnippet.dismissIssue"
    }
}
