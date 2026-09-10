import Foundation

/// The complete set of UI translation keys defined by `src/shared/i18n.ts`.
///
/// Using an enum keeps call sites type-safe, while `rawValue` deliberately
/// preserves the Electron key so parity can be checked mechanically.
public enum LocalizationKey: String, CaseIterable, Codable, Hashable, Sendable {
    case appTitle
    case file
    case edit
    case selection
    case goto
    case view
    case tools
    case preferences
    case project
    case git
    case window
    case help
    case newFile
    case newWindow
    case openFile
    case openFolder
    case openRecentFile
    case openRecentProject
    case save
    case saveAs
    case saveAll
    case pinTab
    case cycleAutoSave
    case closeTab
    case closeOtherTabs
    case closeTabsRight
    case closeAllTabs
    case reopenTab
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    case commandPalette
    case setSyntax
    case toggleSidebar
    case toggleMinimap
    case toggleOutline
    case distractionFree
    case toggleSpellCheck
    case toggleWrap
    case toggleTheme
    case selectColorScheme
    case gotoAnything
    case gotoSymbol
    case gotoProjectSymbol
    case gotoLine
    case back
    case forward
    case find
    case replace
    case findInFiles
    case replaceInFiles
    case findResults
    case build
    case terminal
    case formatDocument
    case selectBuildSystem
    case importSublimeBuild
    case toggleBuildOutput
    case configureLanguageTool
    case importSublimeSettings
    case importSublimeKeymap
    case importSublimeProject
    case importSublimeSnippet
    case toggleGit
    case refreshGit
    case openConflicts
    case checkUpdates
    case languageChinese
    case languageEnglish
    case switchLanguage
    case noFolder
    case plainText
    case line
    case column
    case autoSave
    case noRecentFiles
    case noRecentProjects
    case lineEndingPickerPlaceholder
    case encodingActionPickerPlaceholder
    case encodingPickerPlaceholder
    case reopenEncodingPickerPlaceholder
    case current
    case lineEndingChanged
    case encodingChanged
    case lineEndingAriaLabel
    case encodingAriaLabel
    case run
    case stop
    case gitChanges
    case stage
    case unstage
    case discard
    case commit
    case history
    case blame
    case findPlaceholder
    case replacePlaceholder
    case includePlaceholder
    case excludePlaceholder
    case findAll
    case replaceAll
    case formatJson
    case compactJson
    case jsonView
    case learnMore
}

/// Native counterpart of the shared Electron i18n module.
///
/// Simplified Chinese is intentionally the fallback. This matches the
/// TypeScript rule `locale === 'en-US' ? EN : ZH`, including for nil, malformed,
/// or as-yet unsupported locale identifiers.
public enum Localization {
    public typealias Key = LocalizationKey
    public typealias Arguments = [String: String]

    public static let fallbackLocale = EditorLocale.zhCN
    public static let supportedLocales: [EditorLocale] = [.zhCN, .enUS]

    /// Complete immutable catalogs, exposed read-only for diagnostics and parity tests.
    public static let catalogs: [EditorLocale: [Key: String]] = {
        var chinese: [Key: String] = [:]
        var english: [Key: String] = [:]
        chinese.reserveCapacity(Key.allCases.count)
        english.reserveCapacity(Key.allCases.count)

        for key in Key.allCases {
            let translations = Self.values(for: key)
            chinese[key] = translations.zhCN
            english[key] = translations.enUS
        }
        return [.zhCN: chinese, .enUS: english]
    }()

    /// Resolves an external locale using the same exact-match rule as Electron.
    public static func resolveLocale(_ identifier: String?) -> EditorLocale {
        identifier == EditorLocale.enUS.rawValue ? .enUS : fallbackLocale
    }

    public static func catalog(for locale: EditorLocale) -> [Key: String] {
        catalogs[locale] ?? catalogs[fallbackLocale]!
    }

    public static func catalog(forLocaleIdentifier identifier: String?) -> [Key: String] {
        catalog(for: resolveLocale(identifier))
    }

    /// Returns a localized string, falling back to Simplified Chinese and then
    /// to the stable key name if a future incomplete catalog slips through.
    public static func string(
        _ key: Key,
        locale: EditorLocale,
        arguments: Arguments = [:]
    ) -> String {
        let value = catalogs[locale]?[key]
            ?? catalogs[fallbackLocale]?[key]
            ?? key.rawValue
        return interpolate(value, for: key, arguments: arguments)
    }

    public static func string(
        _ key: Key,
        localeIdentifier: String?,
        arguments: Arguments = [:]
    ) -> String {
        string(key, locale: resolveLocale(localeIdentifier), arguments: arguments)
    }

    /// Naming-compatible counterpart of `translate` in `src/shared/i18n.ts`.
    public static func translate(
        _ key: Key,
        locale: EditorLocale,
        arguments: Arguments = [:]
    ) -> String {
        string(key, locale: locale, arguments: arguments)
    }

    public static func translate(
        _ key: Key,
        localeIdentifier: String?,
        arguments: Arguments = [:]
    ) -> String {
        string(key, localeIdentifier: localeIdentifier, arguments: arguments)
    }

    public static func makeTranslator(
        locale: EditorLocale
    ) -> @Sendable (Key) -> String {
        { key in string(key, locale: locale) }
    }

    /// Mirrors `commandLabel` from the shared i18n module without maintaining a
    /// second command dictionary. The caller-provided English label remains the
    /// fallback, exactly as it does in Electron.
    public static func commandLabel(
        for commandID: String,
        locale: EditorLocale,
        fallback: String
    ) -> String {
        guard locale == .zhCN else { return fallback }
        return CommandCatalog.command(id: commandID)?.chineseName ?? fallback
    }

    public static func commandLabel(
        for commandID: String,
        localeIdentifier: String?,
        fallback: String
    ) -> String {
        commandLabel(
            for: commandID,
            locale: resolveLocale(localeIdentifier),
            fallback: fallback
        )
    }

    /// Mirrors `commandTitle` from the shared i18n module. English titles and
    /// unknown commands retain the supplied fallback; Chinese category prefixes
    /// are translated when the fallback has the `Category: Label` shape.
    public static func commandTitle(
        for commandID: String,
        locale: EditorLocale,
        fallback: String
    ) -> String {
        guard locale == .zhCN else { return fallback }

        let components = fallback.components(separatedBy: ": ")
        let hasCategory = components.count > 1
        let joinedFallbackLabel = components.dropFirst().joined(separator: ": ")
        let fallbackLabel = hasCategory && !joinedFallbackLabel.isEmpty
            ? joinedFallbackLabel
            : fallback
        let label = CommandCatalog.command(id: commandID)?.chineseName ?? fallbackLabel

        guard hasCategory, let category = components.first else { return label }
        let localizedCategory = CommandCategory(rawValue: category)?
            .title(for: .simplifiedChinese) ?? category
        return localizedCategory + "：" + label
    }

    public static func commandTitle(
        for commandID: String,
        localeIdentifier: String?,
        fallback: String
    ) -> String {
        commandTitle(
            for: commandID,
            locale: resolveLocale(localeIdentifier),
            fallback: fallback
        )
    }

    /// The current shared catalog represents dynamic status text as a prefix.
    /// Supplying `{ "value": ... }` appends the dynamic value for those four
    /// keys while keeping their no-argument result byte-for-byte compatible with
    /// the TypeScript catalog. Named `{placeholder}` tokens are also supported
    /// for future catalog entries and unresolved placeholders remain visible.
    private static func interpolate(
        _ template: String,
        for key: Key,
        arguments: Arguments
    ) -> String {
        let hasValuePlaceholder = template.contains("{value}")
        var result = replaceNamedArguments(in: template, arguments: arguments)
        if valueSuffixKeys.contains(key),
           !hasValuePlaceholder,
           let value = arguments["value"] {
            result += value
        }
        return result
    }

    private static func replaceNamedArguments(
        in template: String,
        arguments: Arguments
    ) -> String {
        guard !arguments.isEmpty, template.contains("{") else { return template }

        var result = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            guard template[cursor] == "{",
                  let closingBrace = template[cursor...].firstIndex(of: "}")
            else {
                result.append(template[cursor])
                cursor = template.index(after: cursor)
                continue
            }

            let nameStart = template.index(after: cursor)
            let name = String(template[nameStart..<closingBrace])
            if let replacement = arguments[name] {
                result += replacement
            } else {
                result += String(template[cursor...closingBrace])
            }
            cursor = template.index(after: closingBrace)
        }
        return result
    }

    private static let valueSuffixKeys: Set<Key> = [
        .lineEndingChanged,
        .encodingChanged,
        .lineEndingAriaLabel,
        .encodingAriaLabel
    ]

    private static func values(for key: Key) -> (zhCN: String, enUS: String) {
        switch key {
        case .appTitle: return ("文本编辑器(徐洁阳)", "文本编辑器(徐洁阳)")
        case .file: return ("文件", "File")
        case .edit: return ("编辑", "Edit")
        case .selection: return ("选择", "Selection")
        case .goto: return ("转到", "Goto")
        case .view: return ("视图", "View")
        case .tools: return ("工具", "Tools")
        case .preferences: return ("偏好设置", "Preferences")
        case .project: return ("项目", "Project")
        case .git: return ("Git", "Git")
        case .window: return ("窗口", "Window")
        case .help: return ("帮助", "Help")
        case .newFile: return ("新建文件", "New File")
        case .newWindow: return ("新建窗口", "New Window")
        case .openFile: return ("打开文件…", "Open File…")
        case .openFolder: return ("打开文件夹…", "Open Folder…")
        case .openRecentFile: return ("打开最近文件…", "Open Recent File…")
        case .openRecentProject: return ("打开最近项目…", "Open Recent Project…")
        case .save: return ("保存", "Save")
        case .saveAs: return ("另存为…", "Save As…")
        case .saveAll: return ("全部保存", "Save All")
        case .pinTab: return ("固定/取消固定标签页", "Pin / Unpin Tab")
        case .cycleAutoSave: return ("切换自动保存模式", "Cycle Auto Save Mode")
        case .closeTab: return ("关闭标签页", "Close Tab")
        case .closeOtherTabs: return ("关闭其他标签页", "Close Other Tabs")
        case .closeTabsRight: return ("关闭右侧标签页", "Close Tabs to the Right")
        case .closeAllTabs: return ("关闭全部标签页", "Close All Tabs")
        case .reopenTab: return ("重新打开已关闭标签页", "Reopen Closed Tab")
        case .undo: return ("撤销", "Undo")
        case .redo: return ("重做", "Redo")
        case .cut: return ("剪切", "Cut")
        case .copy: return ("复制", "Copy")
        case .paste: return ("粘贴", "Paste")
        case .selectAll: return ("全选", "Select All")
        case .commandPalette: return ("命令面板…", "Command Palette…")
        case .setSyntax: return ("设置语法…", "Set Syntax…")
        case .toggleSidebar: return ("切换侧边栏", "Toggle Sidebar")
        case .toggleMinimap: return ("切换缩略图", "Toggle Minimap")
        case .toggleOutline: return ("切换大纲", "Toggle Outline")
        case .distractionFree: return ("专注模式", "Distraction Free Mode")
        case .toggleSpellCheck: return ("切换拼写检查", "Toggle Spell Check")
        case .toggleWrap: return ("切换自动换行", "Toggle Word Wrap")
        case .toggleTheme: return ("切换主题", "Toggle Theme")
        case .selectColorScheme: return ("选择配色方案…", "Select Color Scheme…")
        case .gotoAnything: return ("转到任意位置…", "Goto Anything…")
        case .gotoSymbol: return ("转到文件符号…", "Goto Symbol…")
        case .gotoProjectSymbol: return ("转到项目符号…", "Goto Symbol in Project…")
        case .gotoLine: return ("转到行…", "Goto Line…")
        case .back: return ("后退", "Back")
        case .forward: return ("前进", "Forward")
        case .find: return ("查找", "Find")
        case .replace: return ("替换", "Replace")
        case .findInFiles: return ("在文件中查找…", "Find in Files…")
        case .replaceInFiles: return ("在文件中替换…", "Replace in Files…")
        case .findResults: return ("查找结果", "Find Results")
        case .build: return ("构建", "Build")
        case .terminal: return ("终端", "Terminal")
        case .formatDocument: return ("格式化文档", "Format Document")
        case .selectBuildSystem: return ("选择构建系统…", "Select Build System…")
        case .importSublimeBuild: return ("导入 Sublime 构建系统…", "Import Sublime Build System…")
        case .toggleBuildOutput: return ("切换构建输出", "Toggle Build Output")
        case .configureLanguageTool: return ("配置语言工具…", "Configure Language Tool…")
        case .importSublimeSettings: return ("导入 Sublime 设置…", "Import Sublime Settings…")
        case .importSublimeKeymap: return ("导入 Sublime 快捷键…", "Import Sublime Keymap…")
        case .importSublimeProject: return ("导入 Sublime 项目…", "Import Sublime Project…")
        case .importSublimeSnippet: return ("导入 Sublime 片段…", "Import Sublime Snippet…")
        case .toggleGit: return ("切换 Git 更改", "Toggle Git Changes")
        case .refreshGit: return ("刷新更改", "Refresh Changes")
        case .openConflicts: return ("打开合并冲突", "Open Merge Conflicts")
        case .checkUpdates: return ("检查更新…", "Check for Updates…")
        case .languageChinese: return ("简体中文", "简体中文")
        case .languageEnglish: return ("English", "English")
        case .switchLanguage: return ("界面语言", "Interface Language")
        case .noFolder: return ("未打开文件夹", "No Folder Opened")
        case .plainText: return ("纯文本", "Plain Text")
        case .line: return ("行", "Ln")
        case .column: return ("列", "Col")
        case .autoSave: return ("自动保存", "Auto Save")
        case .noRecentFiles: return ("没有最近文件", "No recent files are available")
        case .noRecentProjects: return ("没有最近项目", "No recent projects are available")
        case .lineEndingPickerPlaceholder: return ("选择换行符…", "Select line ending…")
        case .encodingActionPickerPlaceholder: return ("选择编码操作…", "Choose an encoding action…")
        case .encodingPickerPlaceholder: return ("选择保存编码…", "Select encoding for save…")
        case .reopenEncodingPickerPlaceholder: return ("以编码重新打开…", "Reopen with encoding…")
        case .current: return ("当前", "Current")
        case .lineEndingChanged: return ("保存换行符：", "Save line endings as ")
        case .encodingChanged: return ("保存编码：", "Save encoding as ")
        case .lineEndingAriaLabel: return ("选择换行符，当前为", "Select line ending, currently ")
        case .encodingAriaLabel: return ("编码操作，当前为", "Encoding actions, currently ")
        case .run: return ("运行", "Run")
        case .stop: return ("停止", "Stop")
        case .gitChanges: return ("Git 更改", "Git Changes")
        case .stage: return ("暂存", "Stage")
        case .unstage: return ("取消暂存", "Unstage")
        case .discard: return ("丢弃", "Discard")
        case .commit: return ("提交", "Commit")
        case .history: return ("历史", "History")
        case .blame: return ("追溯", "Blame")
        case .findPlaceholder: return ("查找", "Find")
        case .replacePlaceholder: return ("替换", "Replace")
        case .includePlaceholder: return ("包含：例如 **/*.ts", "Include: e.g. **/*.ts")
        case .excludePlaceholder: return ("排除：例如 **/node_modules/**", "Exclude: e.g. **/node_modules/**")
        case .findAll: return ("查找全部", "Find All")
        case .replaceAll: return ("全部替换", "Replace All")
        case .formatJson: return ("格式化 JSON", "Format JSON")
        case .compactJson: return ("压缩 JSON", "Compact JSON")
        case .jsonView: return ("JSON 视图", "JSON View")
        case .learnMore: return ("了解更多", "Learn More")
        }
    }
}
