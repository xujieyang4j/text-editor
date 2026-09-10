/// Locale used for command-palette titles. The raw values intentionally match
/// the locale identifiers used by the Electron application.
public enum CommandLocale: String, CaseIterable, Codable, Sendable {
    case english = "en-US"
    case simplifiedChinese = "zh-CN"
}

/// The category prefix used by the existing command palette.
public enum CommandCategory: String, CaseIterable, Codable, Sendable {
    case file = "File"
    case edit = "Edit"
    case selection = "Selection"
    case goto = "Goto"
    case navigate = "Navigate"
    case go = "Go"
    case find = "Find"
    case view = "View"
    case tools = "Tools"
    case json = "JSON"
    case project = "Project"
    case git = "Git"
    case help = "Help"
    case preferences = "Preferences"
    case lsp = "LSP"

    public func title(for locale: CommandLocale) -> String {
        guard locale == .simplifiedChinese else { return rawValue }
        switch self {
        case .file: return "文件"
        case .edit: return "编辑"
        case .selection: return "选择"
        case .goto: return "转到"
        case .navigate: return "导航"
        // `Go` is deliberately not translated by src/shared/i18n.ts.
        case .go: return "Go"
        case .find: return "查找"
        case .view: return "视图"
        case .tools: return "工具"
        case .json: return "JSON"
        case .project: return "项目"
        case .git: return "Git"
        case .help: return "帮助"
        case .preferences: return "偏好设置"
        case .lsp: return "语言服务"
        }
    }
}

/// State that must exist before a command can be routed. Requirements are
/// composable because commands such as project-wide symbol search need more
/// than one piece of state. Dynamic validation (for example, valid JSON) still
/// belongs to the eventual command handler.
public struct CommandRequirements: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let document = Self(rawValue: 1 << 0)
    public static let savedDocument = Self(rawValue: 1 << 1)
    public static let workspace = Self(rawValue: 1 << 2)
    public static let selection = Self(rawValue: 1 << 3)
    public static let findResults = Self(rawValue: 1 << 4)
    public static let navigationHistory = Self(rawValue: 1 << 5)
    public static let closedTab = Self(rawValue: 1 << 6)
    public static let gitRepository = Self(rawValue: 1 << 7)
    public static let languageService = Self(rawValue: 1 << 8)
}

/// Platform-neutral counterpart of NSEvent.ModifierFlags/SwiftUI modifiers.
public struct CommandKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

/// A key that can be routed by the native UI, separately from a display-only
/// shortcut hint. `key` is a lowercase printable character, `f2`...`f12`, or
/// one of: up, down, left, right, backspace, delete, return, and space.
public struct CommandKeyEquivalent: Codable, Hashable, Sendable {
    public let key: String
    public let modifiers: CommandKeyModifiers

    public init(key: String, modifiers: CommandKeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Native-style text suitable for a palette row. This is presentation
    /// metadata; routing should use `key` and `modifiers` instead.
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }

        switch key {
        case "up": result += "↑"
        case "down": result += "↓"
        case "left": result += "←"
        case "right": result += "→"
        case "backspace": result += "⌫"
        case "delete": result += "⌦"
        case "return": result += "↩"
        case "space": result += "Space"
        default: result += key.uppercased()
        }
        return result
    }
}

/// A single key or chord. Chords are supported for imported/user overrides,
/// even though every default Electron menu accelerator is a single key.
public struct CommandKeyBinding: Codable, Hashable, Sendable {
    public let sequence: [CommandKeyEquivalent]

    public init(sequence: [CommandKeyEquivalent]) {
        self.sequence = sequence
    }

    public init(_ keyEquivalent: CommandKeyEquivalent) {
        self.sequence = [keyEquivalent]
    }

    public var singleKeyEquivalent: CommandKeyEquivalent? {
        sequence.count == 1 ? sequence[0] : nil
    }
}

/// Context names accepted by the existing key-binding rule format.
public enum KeyBindingContext: String, CaseIterable, Codable, Sendable {
    case editor
    case findResults = "find-results"
    case git
    case build
}

/// A user/project override. A nil binding explicitly removes the command's
/// default binding; absence of an override leaves the default untouched.
public struct KeyBindingOverride: Codable, Hashable, Sendable {
    public let commandID: String
    public let binding: CommandKeyBinding?
    public let when: KeyBindingContext?

    public init(
        commandID: String,
        binding: CommandKeyBinding?,
        when: KeyBindingContext? = nil
    ) {
        self.commandID = commandID
        self.binding = binding
        self.when = when
    }

    public static func unbind(
        _ commandID: String,
        when: KeyBindingContext? = nil
    ) -> Self {
        Self(commandID: commandID, binding: nil, when: when)
    }
}

public struct CommandDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let englishName: String
    public let chineseName: String
    public let category: CommandCategory
    public let requirements: CommandRequirements

    /// Human-readable shortcut metadata. It may describe an editor-owned
    /// shortcut even when `defaultKeyEquivalent` is nil.
    public let displayShortcut: String?

    /// Executable default derived strictly from an Electron menu accelerator.
    /// Commands without a menu accelerator intentionally keep this nil.
    public let defaultKeyEquivalent: CommandKeyEquivalent?

    public init(
        id: String,
        englishName: String,
        chineseName: String,
        category: CommandCategory,
        requirements: CommandRequirements = [],
        displayShortcut: String? = nil,
        defaultKeyEquivalent: CommandKeyEquivalent? = nil
    ) {
        self.id = id
        self.englishName = englishName
        self.chineseName = chineseName
        self.category = category
        self.requirements = requirements
        self.displayShortcut = displayShortcut ?? defaultKeyEquivalent?.displayString
        self.defaultKeyEquivalent = defaultKeyEquivalent
    }

    public var requiresDocument: Bool {
        requirements.contains(.document) || requirements.contains(.savedDocument)
    }

    public var requiresWorkspace: Bool {
        requirements.contains(.workspace)
    }

    public func name(for locale: CommandLocale) -> String {
        locale == .simplifiedChinese ? chineseName : englishName
    }

    public func title(for locale: CommandLocale) -> String {
        let separator = locale == .simplifiedChinese ? "：" : ": "
        return category.title(for: locale) + separator + name(for: locale)
    }
}

public struct FuzzyResult: Equatable, Sendable {
    public let score: Double
    /// Character offsets into the searched text, used for highlight rendering.
    public let matches: [Int]

    public init(score: Double, matches: [Int]) {
        self.score = score
        self.matches = matches
    }
}

/// Port of src/renderer/src/fuzzy.ts. It intentionally uses the same greedy
/// subsequence matching and scoring constants.
public enum CommandFuzzyMatcher {
    public static func score(query: String, text: String) -> FuzzyResult? {
        if query.isEmpty { return FuzzyResult(score: 1, matches: []) }
        if query.utf16.count > text.utf16.count { return nil }

        // JavaScript strings and their numeric indices are UTF-16 based. Using
        // code units here preserves both scoring and highlight offsets for
        // supplementary-plane characters.
        let queryCharacters = Array(query.lowercased().utf16)
        let textCharacters = Array(text.lowercased().utf16)
        let originalCharacters = Array(text.utf16)
        var queryIndex = 0
        var textIndex = 0
        var total = 0.0
        var consecutive = 0
        var matches: [Int] = []

        while queryIndex < queryCharacters.count && textIndex < textCharacters.count {
            if queryCharacters[queryIndex] == textCharacters[textIndex] {
                matches.append(textIndex)
                var bonus = 10.0 + Double(consecutive * 5)
                if textIndex == 0 {
                    bonus += 15
                } else if isBoundary(textCharacters[textIndex - 1]) {
                    bonus += 10
                } else if textIndex < originalCharacters.count,
                          isASCIIUppercase(originalCharacters[textIndex]) {
                    bonus += 8
                }
                total += bonus
                consecutive += 1
                queryIndex += 1
            } else {
                total -= 1
                consecutive = 0
            }
            textIndex += 1
        }

        guard queryIndex == queryCharacters.count else { return nil }
        total -= Double(originalCharacters.count) * 0.1
        return FuzzyResult(score: total, matches: matches)
    }

    /// Filters and score-sorts while preserving input order for equal scores,
    /// matching modern JavaScript's stable Array.sort behavior.
    public static func filter<Item>(
        query: String,
        items: [Item],
        key: (Item) -> String
    ) -> [(item: Item, result: FuzzyResult)] {
        let scored = items.enumerated().compactMap { offset, item -> (Int, Item, FuzzyResult)? in
            guard let result = score(query: query, text: key(item)) else { return nil }
            return (offset, item, result)
        }
        return scored.sorted { left, right in
            if left.2.score == right.2.score { return left.0 < right.0 }
            return left.2.score > right.2.score
        }.map { (item: $0.1, result: $0.2) }
    }

    private static func isBoundary(_ codeUnit: Unicode.UTF16.CodeUnit) -> Bool {
        codeUnit == 47 || codeUnit == 92 || codeUnit == 95
            || codeUnit == 45 || codeUnit == 46 || codeUnit == 32
    }

    private static func isASCIIUppercase(_ codeUnit: Unicode.UTF16.CodeUnit) -> Bool {
        (65...90).contains(codeUnit)
    }
}

public struct CommandSearchResult: Sendable {
    public let command: CommandDescriptor
    public let result: FuzzyResult

    public init(command: CommandDescriptor, result: FuzzyResult) {
        self.command = command
        self.result = result
    }
}

/// Canonical native catalog. The first 167 entries preserve commands.ts order;
/// the final two are menu-only commands from menu.ts.
public enum CommandCatalog {
    public static let all: [CommandDescriptor] = [
        command("new-file", .file, "New File", "新建文件", key: "n", modifiers: .command),
        command("open-file", .file, "Open File…", "打开文件…", key: "o", modifiers: .command),
        command("open-file-with-encoding", .file, "Open File with Encoding…", "以编码打开文件…"),
        command("open-folder", .file, "Open Folder…", "打开文件夹…", key: "o", modifiers: [.command, .shift]),
        command("copy-file-path", .file, "Copy File Path", "复制文件路径", requires: [.document, .savedDocument]),
        command("copy-relative-file-path", .file, "Copy Relative File Path", "复制相对文件路径", requires: [.document, .savedDocument, .workspace]),
        command("open-recent-file", .file, "Open Recent File…", "打开最近文件…"),
        command("save", .file, "Save", "保存", key: "s", modifiers: .command, requires: .document),
        command("save-as", .file, "Save As…", "另存为…", key: "s", modifiers: [.command, .shift], requires: .document),
        command("save-all", .file, "Save All", "全部保存", key: "s", modifiers: [.command, .option], requires: .document),
        command("select-line-ending", .file, "Select Line Ending…", "选择换行符…", requires: .document),
        command("select-encoding", .file, "Select Encoding for Save…", "选择保存编码…", requires: .document),
        command("reopen-with-encoding", .file, "Reopen with Encoding…", "以编码重新打开…", requires: [.document, .savedDocument]),
        command("toggle-pin-tab", .file, "Pin / Unpin Tab", "固定/取消固定标签页", key: "p", modifiers: [.command, .option], requires: .document),
        command("close-tab", .file, "Close Tab", "关闭标签页", key: "w", modifiers: .command, requires: .document),
        command("close-other-tabs", .file, "Close Other Tabs", "关闭其他标签页", requires: .document),
        command("close-tabs-to-right", .file, "Close Tabs to the Right", "关闭右侧标签页", requires: .document),
        command("close-all-tabs", .file, "Close All Tabs", "关闭全部标签页", requires: .document),
        command("reopen-tab", .file, "Reopen Closed Tab", "重新打开已关闭标签页", key: "t", modifiers: [.command, .shift], requires: .closedTab),

        command("goto-anything", .goto, "Goto Anything…", "转到任意位置…", key: "p", modifiers: .command, requires: .document),
        command("goto-symbol", .goto, "Goto Symbol…", "转到文件符号…", key: "r", modifiers: .command, requires: .document),
        command("goto-project-symbol", .goto, "Goto Symbol in Project…", "转到项目符号…", key: "r", modifiers: [.command, .shift], requires: .workspace),
        command("go-to-line", .goto, "Goto Line…", "转到行…", key: "g", modifiers: .command, requires: .document),
        command("goto-matching-bracket", .goto, "Goto Matching Bracket", "转到匹配括号", key: "\\", modifiers: [.command, .shift], requires: .document),
        command("navigate-back", .goto, "Back", "后退", key: "left", modifiers: .option, requires: .navigationHistory),
        command("navigate-forward", .goto, "Forward", "前进", key: "right", modifiers: .option, requires: .navigationHistory),

        command("find", .find, "Find…", "查找", key: "f", modifiers: .command, requires: .document),
        command("find-next", .find, "Find Next in Current Document", "在当前文档中查找下一个", key: "f3", requires: .document),
        command("find-previous", .find, "Find Previous in Current Document", "在当前文档中查找上一个", key: "f3", modifiers: .shift, requires: .document),
        command("replace", .find, "Replace…", "替换", key: "h", modifiers: .command, requires: .document),
        command("find-in-files", .find, "Find in Files…", "在文件中查找…", key: "f", modifiers: [.command, .shift], requires: .workspace),
        command("replace-in-files", .find, "Replace in Files…", "在文件中替换…", key: "h", modifiers: [.command, .shift], requires: .workspace),
        command("undo-replace-in-files", .find, "Undo Last Replace in Files", "撤销上次文件替换", requires: .workspace),
        command("find-results-next", .find, "Next Result", "下一个查找结果", key: "f4", requires: [.workspace, .findResults]),
        command("find-results-prev", .find, "Previous Result", "上一个查找结果", key: "f4", modifiers: .shift, requires: [.workspace, .findResults]),
        command("next-change", .goto, "Next Change", "下一个更改", key: "down", modifiers: [.command, .option, .shift], requires: [.document, .savedDocument, .workspace, .gitRepository]),
        command("prev-change", .goto, "Previous Change", "上一个更改", key: "up", modifiers: [.command, .option, .shift], requires: [.document, .savedDocument, .workspace, .gitRepository]),
        command("revert-current-change", .edit, "Revert Current Change", "还原当前更改", requires: [.document, .savedDocument, .workspace, .gitRepository]),

        command("toggle-comment", .edit, "Toggle Comment", "切换行注释", key: "/", modifiers: .command, requires: .document),
        command("toggle-block-comment", .edit, "Toggle Block Comment", "切换块注释", key: "/", modifiers: [.command, .shift], requires: .document),
        command("add-cursor-above", .selection, "Add Cursor Above", "在上方添加光标", key: "up", modifiers: [.command, .option], requires: .document),
        command("add-cursor-below", .selection, "Add Cursor Below", "在下方添加光标", key: "down", modifiers: [.command, .option], requires: .document),
        command("undo-selection", .selection, "Undo Selection", "撤销选区更改", key: "u", modifiers: .command, requires: .document),
        command("redo-selection", .selection, "Redo Selection", "重做选区更改", key: "u", modifiers: [.command, .shift], requires: .document),
        command("select-next-occurrence", .selection, "Add Next Occurrence", "选择下一个匹配项", key: "d", modifiers: .command, requires: .document),
        command("skip-current-occurrence", .selection, "Skip Current Occurrence", "跳过当前匹配项", requires: .document),
        command("remove-last-cursor", .selection, "Remove Last Cursor", "移除最后一个光标", requires: .document),
        command("select-all-occurrences", .selection, "Select All Occurrences", "选择全部匹配项", key: "f3", modifiers: .option, requires: .document),
        command("add-cursors-line-starts", .selection, "Add Cursors to Line Starts", "在各行行首添加光标", requires: .document),
        command("add-cursors-line-ends", .selection, "Add Cursors to Line Ends", "在各行行尾添加光标", key: "i", modifiers: [.option, .shift], requires: .document),
        command("select-line", .selection, "Select Line", "选中整行", shortcut: "⌃L", requires: .document),
        command("select-matching-bracket", .selection, "Select to Matching Bracket", "选中至匹配括号", requires: .document),
        command("select-parent-syntax", .selection, "Select Enclosing Syntax", "选中外层语法结构", key: "i", modifiers: .command, requires: .document),
        command("expand-selection", .selection, "Expand Selection", "扩展选区", key: "right", modifiers: [.option, .shift], requires: .document),
        command("shrink-selection", .selection, "Shrink Selection", "缩小选区", key: "left", modifiers: [.option, .shift], requires: .document),
        command("move-line-up", .edit, "Move Line Up", "上移行", key: "up", modifiers: .option, requires: .document),
        command("move-line-down", .edit, "Move Line Down", "下移行", key: "down", modifiers: .option, requires: .document),
        command("copy-line-up", .edit, "Copy Line Up", "向上复制行", key: "up", modifiers: [.option, .shift], requires: .document),
        command("copy-line-down", .edit, "Copy Line Down", "向下复制行", key: "down", modifiers: [.option, .shift], requires: .document),
        command("duplicate-selection", .edit, "Duplicate Line/Selection", "复制行/选区", key: "d", modifiers: [.command, .shift], requires: .document),
        command("delete-line", .edit, "Delete Line", "删除行", key: "k", modifiers: [.command, .shift], requires: .document),
        command("delete-word-backward", .edit, "Delete Previous Word", "删除前一个单词", shortcut: "⌥⌫", requires: .document),
        command("delete-word-forward", .edit, "Delete Next Word", "删除后一个单词", shortcut: "⌥⌦", requires: .document),
        command("delete-to-line-start", .edit, "Delete to Line Start", "删除至行首", key: "backspace", modifiers: [.command, .shift], requires: .document),
        command("delete-to-line-end", .edit, "Delete to Line End", "删除至行尾", key: "delete", modifiers: [.command, .shift], requires: .document),
        command("insert-blank-line-above", .edit, "Insert Blank Line Above", "在上方新建空行", key: "return", modifiers: [.command, .shift], requires: .document),
        command("insert-blank-line", .edit, "Insert Blank Line Below", "在下方新建空行", key: "return", modifiers: .command, requires: .document),
        command("transpose-characters", .edit, "Transpose Characters", "转置相邻字符", key: "t", modifiers: .control, requires: .document),
        command("sort-lines", .edit, "Sort Lines Ascending", "升序排列行", requires: .document),
        command("sort-lines-descending", .edit, "Sort Lines Descending", "降序排列行", requires: .document),
        command("reverse-lines", .edit, "Reverse Lines", "反转行顺序", requires: .document),
        command("unique-lines", .edit, "Unique Lines", "删除重复行", requires: .document),
        command("remove-blank-lines", .edit, "Remove Blank Lines", "删除空白行", requires: .document),
        command("toggle-bookmark", .navigate, "Toggle Bookmark", "切换书签", key: "f2", modifiers: .command, requires: .document),
        command("next-bookmark", .navigate, "Next Bookmark", "下一个书签", key: "f2", requires: .document),
        command("prev-bookmark", .navigate, "Previous Bookmark", "上一个书签", key: "f2", modifiers: .shift, requires: .document),
        command("record-macro", .tools, "Start / Stop Macro Recording", "开始/停止录制宏", requires: .document),
        command("run-macro", .tools, "Run Last Macro", "运行上次宏", requires: .document),
        command("save-macro", .tools, "Save Last Macro…", "保存上次宏…", requires: [.document, .workspace]),
        command("run-saved-macro", .tools, "Run Saved Macro…", "运行已保存宏…", requires: [.document, .workspace]),
        command("insert-snippet", .tools, "Insert Snippet…", "插入片段…", requires: .document),

        command("select-language", .view, "Set Syntax…", "设置语法…", requires: .document),
        command("toggle-preview", .view, "Toggle Markdown Preview", "切换 Markdown 预览", key: "v", modifiers: [.command, .shift], requires: .document),
        command("open-in-browser", .view, "Open in Browser", "在浏览器中打开", requires: .document),
        command("toggle-sidebar", .view, "Toggle Sidebar", "切换侧边栏", key: "b", modifiers: .command),
        command("reveal-active-file-in-sidebar", .view, "Reveal Active File in Sidebar", "在侧栏中显示活动文件", requires: [.document, .savedDocument, .workspace]),
        command("split-editor", .view, "Toggle Split Editor", "切换分屏编辑器", key: "2", modifiers: [.command, .option], requires: .document),
        command("split-selected-tabs", .view, "Split Selected Tabs into Groups", "将选中标签拆分到分组", requires: .document),
        command("toggle-line-numbers", .view, "Toggle Line Numbers", "切换行号显示"),
        command("toggle-minimap", .view, "Toggle Minimap", "切换缩略图"),
        command("toggle-whitespace", .view, "Toggle Whitespace Characters", "切换空白字符显示"),
        command("toggle-outline", .view, "Toggle Outline", "切换大纲", requires: .document),
        command("fold-current", .view, "Fold Current", "折叠当前代码块", shortcut: "⌘⌥[", requires: .document),
        command("unfold-current", .view, "Unfold Current", "展开当前代码块", shortcut: "⌘⌥]", requires: .document),
        command("fold-all", .view, "Fold All", "折叠全部代码块", shortcut: "⌃⌥[", requires: .document),
        command("unfold-all", .view, "Unfold All", "展开全部代码块", shortcut: "⌃⌥]", requires: .document),
        command("toggle-distraction-free", .view, "Toggle Distraction Free Mode", "切换专注模式", key: "f11", modifiers: .shift),
        command("cycle-auto-save", .file, "Cycle Auto Save Mode", "切换自动保存模式"),
        command("toggle-spell-check", .view, "Toggle Spell Check", "切换拼写检查"),
        command("format-json", .json, "Format JSON", "格式化 JSON", requires: .document),
        command("compact-json", .json, "Compact JSON", "压缩 JSON", requires: .document),
        command("toggle-json-view", .json, "Toggle JSON View", "切换 JSON 视图", requires: .document),
        command("toggle-word-wrap", .view, "Toggle Word Wrap", "切换自动换行", key: "z", modifiers: .option),
        command("toggle-theme", .view, "Toggle Theme", "切换明暗主题", key: "k", modifiers: .command),
        command("font-zoom-in", .view, "Zoom In", "放大字体", key: "=", modifiers: .command),
        command("font-zoom-out", .view, "Zoom Out", "缩小字体", key: "-", modifiers: .command),
        command("font-zoom-reset", .view, "Reset Zoom", "重置字体大小", key: "0", modifiers: .command),
        command("build", .tools, "Build", "构建", key: "b", modifiers: [.command, .shift], requires: .workspace),
        command("toggle-terminal", .tools, "Toggle Terminal", "切换终端", key: "t", modifiers: [.command, .option], requires: .workspace),
        command("document-statistics", .tools, "Document Statistics", "文档统计", requires: .document),
        command("import-sublime-build", .tools, "Import Sublime Build System…", "导入 Sublime 构建系统…", requires: .workspace),
        command("format-document", .tools, "Format Document", "格式化文档", requires: .document),
        command("trim-trailing-whitespace", .edit, "Trim Trailing Whitespace", "删除行尾空白", requires: .document),
        command("ensure-single-final-newline", .edit, "Ensure Single Final Newline", "确保文件末尾只有一个换行符", requires: .document),
        command("convert-indent-spaces", .edit, "Convert Indentation to Spaces", "将缩进转换为空格", requires: .document),
        command("convert-indent-tabs", .edit, "Convert Indentation to Tabs", "将缩进转换为制表符", requires: .document),
        command("convert-eol-lf", .edit, "Convert Line Endings to LF", "将换行符转换为 LF", requires: .document),
        command("convert-eol-crlf", .edit, "Convert Line Endings to CRLF", "将换行符转换为 CRLF", requires: .document),
        command("convert-eol-cr", .edit, "Convert Line Endings to CR", "将换行符转换为 CR", requires: .document),
        command("to-upper-case", .edit, "Upper Case", "转为大写", requires: .document),
        command("to-lower-case", .edit, "Lower Case", "转为小写", requires: .document),
        command("to-title-case", .edit, "Title Case", "转为标题格式", requires: .document),
        command("swap-case", .edit, "Swap Case", "反转大小写", requires: .document),
        command("join-lines", .edit, "Join Lines", "合并行", requires: .document),
        command("wrap-paragraph-80", .edit, "Wrap Paragraph at 80 Columns", "按 80 列重排段落", key: "q", modifiers: .option, requires: .document),
        command("unwrap-paragraph", .edit, "Unwrap Paragraph", "取消段落换行", requires: .document),
        command("split-selection-lines", .selection, "Split Selection into Lines", "按行拆分选区", shortcut: "⇧⌘L", requires: [.document, .selection]),
        command("indent-selection", .edit, "Indent Selection", "增加缩进", key: "]", modifiers: .command, requires: .document),
        command("outdent-selection", .edit, "Outdent Selection", "减少缩进", key: "[", modifiers: .command, requires: .document),
        command("reindent-selection", .edit, "Reindent Selection", "自动重新缩进选区", key: "\\", modifiers: [.command, .option], requires: .document),
        command("toggle-problems", .view, "Toggle Build Output", "切换构建输出"),
        command("select-color-scheme", .view, "Select Color Scheme…", "选择配色方案…"),
        command("toggle-git", .view, "Toggle Git Changes", "切换 Git 更改", requires: .workspace),
        command("refresh-git", .git, "Refresh Changes", "刷新 Git 更改", requires: [.workspace, .gitRepository]),
        command("open-git-conflicts", .git, "Open Merge Conflicts", "打开合并冲突", requires: [.workspace, .gitRepository]),
        command("check-for-updates", .help, "Check for Updates…", "检查更新…"),
        command("open-marketplace", .tools, "Browse Plugin Marketplace…", "浏览插件市场…", requires: .workspace),
        command("project-settings", .project, "Configure…", "配置项目…", requires: .workspace),
        command("language-tools", .tools, "Configure Language Tool…", "配置语言工具…", requires: .workspace),
        command("install-plugin", .tools, "Install Local Plugin…", "安装本地插件…", requires: .workspace),
        command("manage-plugins", .tools, "Manage Plugins…", "管理插件…", requires: .workspace),

        command("next-tab", .go, "Next Tab", "下一个标签页", key: "right", modifiers: [.command, .option], requires: .document),
        command("prev-tab", .go, "Previous Tab", "上一个标签页", key: "left", modifiers: [.command, .option], requires: .document),
        command("layout-single", .view, "Layout Single", "单栏布局"),
        command("layout-columns2", .view, "Layout Columns 2", "两栏布局"),
        command("layout-columns3", .view, "Layout Columns 3", "三栏布局"),
        command("layout-grid4", .view, "Layout Grid 4", "四宫格布局"),
        command("move-file-next-group", .view, "Move File to Next Group", "将文件移到下一分组", requires: .document),
        command("clone-file-next-group", .view, "Clone File to Next Group", "将文件复制到下一分组", requires: .document),
        command("focus-next-group", .view, "Focus Next Group", "聚焦下一分组", key: "]", modifiers: [.command, .option]),
        command("focus-prev-group", .view, "Focus Previous Group", "聚焦上一分组", key: "[", modifiers: [.command, .option]),
        command("new-window", .file, "New Window", "新建窗口", key: "n", modifiers: [.command, .shift]),
        command("add-folder-to-project", .project, "Add Folder to Project…", "添加文件夹到项目…"),
        command("remove-folder-from-project", .project, "Remove Folder from Project…", "从项目移除文件夹…", requires: .workspace),
        command("open-recent-project", .project, "Open Recent Project…", "打开最近项目…"),
        command("import-sublime-project", .project, "Import Sublime Project…", "导入 Sublime 项目…"),
        command("import-sublime-settings", .preferences, "Import Sublime Settings…", "导入 Sublime 设置…"),
        command("import-sublime-snippet", .tools, "Import Sublime Snippet…", "导入 Sublime 片段…", requires: .workspace),
        command("import-sublime-keymap", .preferences, "Import Sublime Keymap…", "导入 Sublime 快捷键…", requires: .workspace),
        command("set-ui-language-zh", .preferences, "Switch to Simplified Chinese", "切换为简体中文"),
        command("set-ui-language-en", .preferences, "Switch to English", "切换为英文"),
        command("open-settings", .preferences, "Open Settings…", "打开设置…", key: ",", modifiers: .command),
        command("lsp-hover", .lsp, "Show Hover", "显示悬停信息", key: "space", modifiers: [.command, .shift], requires: [.savedDocument, .workspace, .languageService]),
        command("lsp-definition", .lsp, "Go to Definition", "转到定义", key: "f12", requires: [.savedDocument, .workspace]),
        command("lsp-references", .lsp, "Find References", "查找引用", key: "f12", modifiers: .shift, requires: [.savedDocument, .workspace]),
        command("lsp-rename", .lsp, "Rename Symbol", "重命名符号", key: "f2", requires: [.savedDocument, .workspace, .languageService]),
        command("toggle-language-servers", .lsp, "Show Language Servers", "显示语言服务器", requires: .workspace),

        // Present in menu.ts but intentionally absent from commands.ts.
        command("command-palette", .view, "Command Palette…", "命令面板…", key: "p", modifiers: [.command, .shift]),
        command("select-build-system", .tools, "Select Build System…", "选择构建系统…", requires: .workspace)
    ]

    private static let commandsByID: [String: CommandDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func command(id: String) -> CommandDescriptor? {
        commandsByID[id]
    }

    public static func commands(in category: CommandCategory) -> [CommandDescriptor] {
        all.filter { $0.category == category }
    }

    public static func search(
        _ query: String,
        locale: CommandLocale = .english
    ) -> [CommandSearchResult] {
        CommandFuzzyMatcher.filter(query: query, items: all) { $0.title(for: locale) }
            .map { CommandSearchResult(command: $0.item, result: $0.result) }
    }

    /// Resolves the last applicable override, falling back to the catalog
    /// default. A matching override whose binding is nil explicitly unbinds.
    public static func keyBinding(
        for commandID: String,
        overrides: [KeyBindingOverride],
        context: KeyBindingContext? = nil
    ) -> CommandKeyBinding? {
        if let override = overrides.last(where: { override in
            override.commandID == commandID
                && (override.when == nil || override.when == context)
        }) {
            return override.binding
        }
        return command(id: commandID)?.defaultKeyEquivalent.map(CommandKeyBinding.init)
    }

    private static func command(
        _ id: String,
        _ category: CommandCategory,
        _ englishName: String,
        _ chineseName: String,
        shortcut: String? = nil,
        key: String? = nil,
        modifiers: CommandKeyModifiers = [],
        requires requirements: CommandRequirements = []
    ) -> CommandDescriptor {
        let keyEquivalent = key.map { CommandKeyEquivalent(key: $0, modifiers: modifiers) }
        return CommandDescriptor(
            id: id,
            englishName: englishName,
            chineseName: chineseName,
            category: category,
            requirements: requirements,
            displayShortcut: shortcut,
            defaultKeyEquivalent: keyEquivalent
        )
    }
}
