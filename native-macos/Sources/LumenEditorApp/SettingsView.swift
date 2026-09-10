import LumenEditorCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: SettingsController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var rulerColumns = ""
    @State private var hasRulerValidationError = false

    private var locale: EditorLocale { controller.settings.locale }

    var body: some View {
        Form {
            generalSection
            editingSection
            displaySection
            filesAndAutomationSection
            workspaceSection
            historySection

            if let issue = controller.persistenceIssue {
                persistenceSection(issue)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .frame(minHeight: 620, idealHeight: 720)
        .disabled(controller.isApplicationTerminationCommitted)
        .safeAreaInset(edge: .bottom) { saveStatusBar }
        .onAppear(perform: synchronizeRulerColumns)
        .onDisappear { _ = controller.flush() }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(locale.text("Settings", zh: "设置"))
        .accessibilityIdentifier(Accessibility.panel)
        .appLocale(locale)
    }

    // These 21 rows cover all 22 cross-platform settings fields. Search and
    // replace history intentionally share one management row. The native-only
    // formatVersion is persistence metadata and is not user-editable.
    private var generalSection: some View {
        Section {
            Picker(
                locale.text("Interface Language", zh: "界面语言"),
                selection: binding(for: \.locale)
            ) {
                ForEach(EditorLocale.allCases, id: \.rawValue) { locale in
                    Text(localeTitle(locale)).tag(locale)
                }
            }
            .accessibilityIdentifier(Accessibility.locale)

            Picker(locale.text("Theme", zh: "主题"), selection: binding(for: \.theme)) {
                ForEach(EditorTheme.allCases, id: \.rawValue) { theme in
                    Text(themeTitle(theme)).tag(theme)
                }
            }
            .accessibilityIdentifier(Accessibility.theme)

            Picker(
                locale.text("Editor Color Scheme", zh: "编辑器配色方案"),
                selection: binding(for: \.colorScheme)
            ) {
                ForEach(EditorColorScheme.allCases, id: \.rawValue) { scheme in
                    Text(colorSchemeTitle(scheme)).tag(scheme)
                }
            }
            .accessibilityIdentifier(Accessibility.colorScheme)
        } header: {
            Text(locale.text("General", zh: "常规"))
        } footer: {
            Text(
                locale.text(
                    "Theme, interface language, and editor color scheme are applied immediately.",
                    zh: "主题、界面语言和编辑器配色方案会立即应用。"
                )
            )
        }
    }

    private var editingSection: some View {
        Section {
            Stepper(
                locale.text(
                    "Font Size: \(controller.settings.fontSize) pt",
                    zh: "字号：\(controller.settings.fontSize) 磅"
                ),
                value: binding(for: \.fontSize),
                in: 8...40
            )
            .accessibilityIdentifier(Accessibility.fontSize)

            Stepper(
                locale.text(
                    "Tab Width: \(controller.settings.tabSize)",
                    zh: "制表符宽度：\(controller.settings.tabSize)"
                ),
                value: binding(for: \.tabSize),
                in: 1...16
            )
            .accessibilityIdentifier(Accessibility.tabWidth)

            Toggle(
                locale.text("Insert Spaces", zh: "插入空格"),
                isOn: binding(for: \.insertSpaces)
            )
            .accessibilityIdentifier(Accessibility.insertSpaces)

            Toggle(locale.text("Word Wrap", zh: "自动换行"), isOn: binding(for: \.wordWrap))
                .accessibilityIdentifier(Accessibility.wordWrap)
            Toggle(locale.text("Spell Check", zh: "拼写检查"), isOn: binding(for: \.spellCheck))
                .accessibilityIdentifier(Accessibility.spellCheck)
        } header: {
            Text(locale.text("Editing", zh: "编辑"))
        } footer: {
            Text(
                locale.text(
                    "Editing preferences update open editors immediately.",
                    zh: "编辑偏好设置会立即更新已打开的编辑器。"
                )
            )
        }
    }

    private var displaySection: some View {
        Section {
            Toggle(locale.text("Show Line Numbers", zh: "显示行号"), isOn: binding(for: \.showLineNumbers))
                .accessibilityIdentifier(Accessibility.showLineNumbers)
            Toggle(
                locale.text("Show Minimap", zh: "显示迷你地图"),
                isOn: binding(for: \.showMinimap)
            )
                .accessibilityIdentifier(Accessibility.showMinimap)
            Toggle(
                locale.text(
                    "Show Indent Guides",
                    zh: "显示缩进参考线"
                ),
                isOn: binding(for: \.showIndentGuides)
            )
                .accessibilityIdentifier(Accessibility.showIndentGuides)
            Toggle(
                locale.text("Show Whitespace", zh: "显示空白字符"),
                isOn: binding(for: \.showWhitespace)
            )
                .accessibilityIdentifier(Accessibility.showWhitespace)
            Toggle(
                locale.text(
                    "Highlight Trailing Whitespace",
                    zh: "高亮行尾空白"
                ),
                isOn: binding(for: \.highlightTrailingWhitespace)
            )
            .accessibilityIdentifier(Accessibility.highlightTrailingWhitespace)

            LabeledContent(locale.text("Rulers", zh: "标尺")) {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        TextField("80, 100", text: $rulerColumns)
                            .frame(width: 150)
                            .onSubmit(commitRulerColumns)
                            .accessibilityLabel(locale.text("Ruler columns", zh: "标尺列"))
                            .accessibilityHint(locale.text(
                                "Enter up to 10 columns separated by commas or spaces.",
                                zh: "输入最多 10 个列号，并用逗号或空格分隔。"
                            ))
                            .accessibilityIdentifier(Accessibility.rulers)
                        Button(locale.text("Apply", zh: "应用"), action: commitRulerColumns)
                            .accessibilityIdentifier(Accessibility.applyRulers)
                    }
                    if hasRulerValidationError {
                        Label(
                            locale.text(
                                "Enter up to 10 whole-number columns from 1 to 500.",
                                zh: "请输入最多 10 个 1 到 500 之间的整数列号。"
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                            .font(.caption)
                            .foregroundStyle(errorForeground)
                            .accessibilityIdentifier(Accessibility.rulerError)
                    }
                }
            }
        } header: {
            Text(locale.text("Display", zh: "显示"))
        } footer: {
            Text(
                locale.text(
                    "Display preferences update open editors immediately. Rulers accept "
                        + "up to 10 columns from 1 to 500.",
                    zh: "显示偏好设置会立即更新已打开的编辑器。标尺最多接受 10 个 "
                        + "1 到 500 之间的列号。"
                )
            )
        }
    }

    private var filesAndAutomationSection: some View {
        Section {
            Stepper(
                locale.text(
                    "Maximum File Size: \(controller.settings.maxFileSizeMB) MB",
                    zh: "最大文件大小：\(controller.settings.maxFileSizeMB) MB"
                ),
                value: binding(for: \.maxFileSizeMB),
                in: 1...200
            )
            .accessibilityIdentifier(Accessibility.maximumFileSize)

            TextField(
                locale.text("Default Build Command", zh: "默认构建命令"),
                text: binding(for: \.buildCommand),
                prompt: Text(locale.text("Optional command", zh: "可选命令"))
            )
            .accessibilityIdentifier(Accessibility.buildCommand)

            Picker(
                locale.text("Auto Save", zh: "自动保存"),
                selection: binding(for: \.autoSave)
            ) {
                ForEach(AutoSaveMode.allCases, id: \.rawValue) { mode in
                    Text(autoSaveTitle(mode)).tag(mode)
                }
            }
            .accessibilityIdentifier(Accessibility.autoSave)

            Stepper(
                locale.text(
                    "Auto-save Delay: \(controller.settings.autoSaveDelayMs) ms",
                    zh: "自动保存延迟：\(controller.settings.autoSaveDelayMs) 毫秒"
                ),
                value: binding(for: \.autoSaveDelayMs),
                in: 250...60_000,
                step: 250
            )
            .disabled(controller.settings.autoSave != .afterDelay)
            .accessibilityIdentifier(Accessibility.autoSaveDelay)
        } header: {
            Text(locale.text("Files and Automation", zh: "文件与自动化"))
        } footer: {
            Text(
                locale.text(
                    "The file-size limit applies to files opened after the next launch; already-open "
                        + "documents are unaffected. The native default is 200 MB. Auto Save and its delay are applied immediately. "
                        + "The default build command is loaded into the Build panel and updated "
                        + "from that field; an active project command takes precedence.",
                    zh: "文件大小限制会作用于下次启动后新打开的文件，已打开的文档不受影响。原生版默认上限为 200 MB。"
                        + "自动保存及其延迟会立即生效。默认构建命令会载入构建面板，"
                        + "并随该输入框更新；活动项目中的命令优先。"
                )
            )
        }
    }

    private var workspaceSection: some View {
        Section {
            Toggle(
                locale.text("Distraction-free Mode", zh: "免打扰模式"),
                isOn: binding(for: \.distractionFree)
            )
            .accessibilityIdentifier(Accessibility.distractionFree)
            Toggle(
                locale.text("Show Outline", zh: "显示大纲"),
                isOn: binding(for: \.showOutline)
            )
                .accessibilityIdentifier(Accessibility.showOutline)
        } header: {
            Text(locale.text("Workspace", zh: "工作区"))
        } footer: {
            Text(locale.text(
                "These layout preferences update the current workspace immediately.",
                zh: "这些布局偏好设置会立即更新当前工作区。"
            ))
        }
    }

    private var historySection: some View {
        Section {
            LabeledContent(locale.text(
                "Search & Replace History",
                zh: "搜索和替换历史记录"
            )) {
                HStack {
                    Text(
                        historyCountDescription
                    )
                    .foregroundStyle(.secondary)
                    Button(locale.text("Clear Both", zh: "全部清除")) {
                        controller.update { settings in
                            settings.searchHistory.removeAll()
                            settings.replaceHistory.removeAll()
                        }
                    }
                    .disabled(
                        controller.settings.searchHistory.isEmpty
                            && controller.settings.replaceHistory.isEmpty
                    )
                    .accessibilityHint(locale.text(
                        "Clears both search and replace history.",
                        zh: "清除搜索和替换历史记录。"
                    ))
                    .accessibilityIdentifier(Accessibility.clearHistory)
                }
            }
        } header: {
            Text(locale.text("History", zh: "历史记录"))
        } footer: {
            Text(locale.text(
                "Successful Find and Find in Files actions update bounded history. "
                    + "Use the clock menus beside search fields to reuse entries.",
                zh: "成功的查找和在文件中查找操作会更新有界历史记录。"
                    + "可使用搜索输入框旁的时钟菜单复用记录。"
            ))
        }
    }

    private func persistenceSection(_ issue: SettingsPersistenceIssue) -> some View {
        Section {
            Label(
                locale.localizedSettingsPersistenceIssue(issue.content),
                systemImage: "exclamationmark.triangle.fill"
            )
                .foregroundStyle(errorForeground)
                .textSelection(.enabled)
                .accessibilityIdentifier(Accessibility.persistenceIssue)

            HStack {
                Button(locale.text("Retry Save", zh: "重试保存")) { _ = controller.retrySave() }
                    .accessibilityIdentifier(Accessibility.retrySave)
                Button(locale.text("Dismiss", zh: "忽略")) { controller.dismissPersistenceIssue() }
                    .accessibilityIdentifier(Accessibility.dismissIssue)
            }
        } header: {
            Text(locale.localizedApp(issue.titleContent))
        }
    }

    private var saveStatusBar: some View {
        HStack {
            if controller.persistenceIssue != nil {
                Label(
                    locale.text("Settings have unsaved changes", zh: "设置包含未保存的更改"),
                    systemImage: "exclamationmark.triangle"
                )
                    .foregroundStyle(errorForeground)
            } else if controller.hasPendingSave {
                Label(
                    locale.text("Settings have unsaved changes", zh: "设置包含未保存的更改"),
                    systemImage: "clock"
                )
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    locale.text("Settings saved automatically", zh: "设置已自动保存"),
                    systemImage: "checkmark.circle"
                )
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button(locale.text("Save Now", zh: "立即保存")) { _ = controller.flush() }
                .disabled(!controller.hasPendingSave)
                .accessibilityIdentifier(Accessibility.saveNow)
        }
        .accessibilityIdentifier(Accessibility.saveStatus)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func binding<Value>(
        for keyPath: WritableKeyPath<EditorSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { controller.set($0, for: keyPath) }
        )
    }

    private func synchronizeRulerColumns() {
        rulerColumns = controller.settings.rulers.map(String.init).joined(separator: ", ")
        hasRulerValidationError = false
    }

    private func commitRulerColumns() {
        let tokens = rulerColumns.split { character in
            character == "," || character.isWhitespace
        }
        let values = tokens.compactMap { Int($0) }
        guard values.count == tokens.count,
              values.count <= 10,
              values.allSatisfy({ (1...500).contains($0) })
        else {
            hasRulerValidationError = true
            return
        }

        controller.set(values, for: \.rulers)
        synchronizeRulerColumns()
    }

    private func localeTitle(_ locale: EditorLocale) -> String {
        switch locale {
        case .zhCN: "简体中文"
        case .enUS: "English"
        }
    }

    private func colorSchemeTitle(_ scheme: EditorColorScheme) -> String {
        switch scheme {
        case .dark: locale.text("Dark", zh: "深色")
        case .light: locale.text("Light", zh: "浅色")
        case .solarizedDark: locale.text("Solarized Dark", zh: "Solarized 深色")
        case .dracula: "Dracula"
        }
    }

    private func themeTitle(_ theme: EditorTheme) -> String {
        switch theme {
        case .dark: locale.text("Dark", zh: "深色")
        case .light: locale.text("Light", zh: "浅色")
        }
    }

    private func autoSaveTitle(_ mode: AutoSaveMode) -> String {
        switch mode {
        case .off: locale.text("Off", zh: "关闭")
        case .afterDelay: locale.text("After Delay", zh: "延迟后")
        case .onFocusChange: locale.text("On Focus Change", zh: "焦点变化时")
        }
    }

    private var historyCountDescription: String {
        locale.text(
            "Search \(controller.settings.searchHistory.count), "
                + "replace \(controller.settings.replaceHistory.count)",
            zh: "搜索 \(controller.settings.searchHistory.count) 条，"
                + "替换 \(controller.settings.replaceHistory.count) 条"
        )
    }

    private var errorForeground: Color {
        colorSchemeContrast == .increased ? .primary : .red
    }

    enum Accessibility {
        static let panel = "panel.settings"
        static let locale = "panel.settings.locale"
        static let theme = "panel.settings.theme"
        static let colorScheme = "panel.settings.colorScheme"
        static let fontSize = "panel.settings.fontSize"
        static let tabWidth = "panel.settings.tabWidth"
        static let insertSpaces = "panel.settings.insertSpaces"
        static let wordWrap = "panel.settings.wordWrap"
        static let spellCheck = "panel.settings.spellCheck"
        static let showLineNumbers = "panel.settings.showLineNumbers"
        static let showMinimap = "panel.settings.showMinimap"
        static let showIndentGuides = "panel.settings.showIndentGuides"
        static let showWhitespace = "panel.settings.showWhitespace"
        static let highlightTrailingWhitespace = "panel.settings.highlightTrailingWhitespace"
        static let rulers = "panel.settings.rulers"
        static let applyRulers = "panel.settings.rulers.apply"
        static let rulerError = "panel.settings.rulers.error"
        static let maximumFileSize = "panel.settings.maximumFileSize"
        static let buildCommand = "panel.settings.buildCommand"
        static let autoSave = "panel.settings.autoSave"
        static let autoSaveDelay = "panel.settings.autoSaveDelay"
        static let distractionFree = "panel.settings.distractionFree"
        static let showOutline = "panel.settings.showOutline"
        static let clearHistory = "panel.settings.history.clear"
        static let persistenceIssue = "panel.settings.persistenceIssue"
        static let retrySave = "panel.settings.retrySave"
        static let dismissIssue = "panel.settings.dismissIssue"
        static let saveStatus = "panel.settings.saveStatus"
        static let saveNow = "panel.settings.saveNow"
    }
}
