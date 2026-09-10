using System.Globalization;

namespace LumenEditor.Windows.Core.Localization;

/// <summary>Small runtime localization table for the native Windows shell and command palette.</summary>
public static class WindowsLocalization
{
    private static readonly IReadOnlyDictionary<string, string> UiChinese = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["New"] = "新建", ["Open"] = "打开", ["Open Encoding"] = "按编码打开", ["Open Recent"] = "最近打开",
        ["Save"] = "保存", ["Save As"] = "另存为", ["Save All"] = "全部保存", ["Auto Save"] = "自动保存",
        ["Undo"] = "撤销", ["Redo"] = "重做", ["Close"] = "关闭", ["Reopen Closed"] = "重新打开已关闭文件",
        ["Encoding"] = "编码", ["Reopen Encoding"] = "按编码重新打开", ["Line Endings"] = "换行符",
        ["Trim Whitespace"] = "删除行尾空白", ["Final Newline"] = "末尾换行", ["Edit Lines"] = "行编辑",
        ["Edit More"] = "更多编辑", ["Macro"] = "宏", ["Find"] = "查找", ["Find in Files"] = "在文件中查找",
        ["Settings"] = "设置", ["Go to Line"] = "转到行", ["Goto Anything"] = "转到任意位置",
        ["Symbols"] = "符号", ["Project Symbols"] = "项目符号", ["Back"] = "后退", ["Forward"] = "前进",
        ["Commands"] = "命令", ["1 Pane"] = "单窗格", ["2 Panes"] = "双窗格", ["3 Panes"] = "三窗格",
        ["4 Panes"] = "四窗格", ["Move Next"] = "移到下一组", ["Clone Next"] = "复制到下一组",
        ["Split Selected"] = "拆分所选标签", ["Focus Next"] = "聚焦下一组", ["Build"] = "构建", ["Git"] = "Git", ["Terminal"] = "终端",
        ["Language"] = "语言工具", ["Plugins"] = "插件", ["Preview"] = "预览", ["Previous"] = "上一个",
        ["Next"] = "下一个", ["Replace"] = "替换", ["Replace All"] = "全部替换", ["Find All"] = "查找全部",
        ["History"] = "历史", ["Search History"] = "搜索历史", ["Use"] = "使用",
        ["History"] = "历史",
        ["Preview Replace"] = "预览替换", ["Apply Preview"] = "应用预览", ["Undo Replace"] = "撤销替换",
        ["Font size"] = "字号", ["Tab size"] = "Tab 宽度", ["Max file MB"] = "文件上限 MB",
        ["Insert spaces"] = "使用空格缩进", ["Word wrap"] = "自动换行", ["Apply"] = "应用",
        ["Line numbers"] = "显示行号",
        ["Whitespace"] = "显示空白字符",
        ["Minimap"] = "显示缩略图",
        ["Auto save"] = "自动保存", ["Off"] = "关闭", ["After delay"] = "延时保存",
        ["On focus change"] = "失焦保存", ["Delay ms"] = "延迟毫秒", ["Open Folder"] = "打开文件夹",
        ["Refresh Workspace"] = "刷新工作区", ["Remove Folder"] = "移除文件夹", ["New File"] = "新建文件",
        ["New Folder"] = "新建文件夹", ["Rename"] = "重命名", ["Recycle"] = "移到回收站", ["Reveal"] = "在资源管理器中显示",
        ["OPEN DOCUMENTS"] = "打开的文档", ["DOCUMENT OUTLINE"] = "文档大纲", ["Close Results"] = "关闭结果",
        ["Stop"] = "停止", ["Stage"] = "暂存", ["Unstage"] = "取消暂存", ["Commit"] = "提交",
        ["Discard"] = "丢弃", ["Stage Hunk"] = "暂存区块", ["Discard Hunk"] = "丢弃区块",
        ["Blame"] = "追溯", ["Branch"] = "切换分支", ["New Branch"] = "新建分支",
        ["Start"] = "启动", ["Clear"] = "清空", ["Hover"] = "悬停信息", ["Definition"] = "定义",
        ["References"] = "引用", ["Apply Rename"] = "应用重命名", ["Undo Rename"] = "撤销重命名",
        ["Stop / Close"] = "停止并关闭", ["Install Local"] = "安装本地插件", ["Insert Snippet"] = "插入片段",
        ["Find text"] = "查找文本", ["Replace text"] = "替换文本", ["Match case"] = "区分大小写",
        ["Whole word"] = "全词匹配", ["Regular expression"] = "正则表达式", ["Find in files text"] = "在文件中查找文本",
        ["Replace in files text"] = "在文件中替换文本", ["Language ID (e.g. typescript)"] = "语言 ID（例如 typescript）",
        ["Server executable"] = "服务器可执行文件", ["One argument per line"] = "每行一个参数",
        ["Type a command and press Enter"] = "输入命令并按 Enter", ["Workspace files"] = "工作区文件",
        ["Open documents"] = "打开的文档", ["Document outline symbols"] = "文档大纲符号",
        ["Editor pane 1"] = "编辑器窗格 1", ["Editor pane 2"] = "编辑器窗格 2",
        ["Editor pane 3"] = "编辑器窗格 3", ["Editor pane 4"] = "编辑器窗格 4",
        ["Document preview"] = "文档预览", ["Markdown preview"] = "Markdown 预览", ["Find in files results"] = "文件查找结果", ["Build output"] = "构建输出",
        ["Indent guides"] = "缩进参考线", ["Trailing whitespace"] = "行尾空白",
        ["Rulers"] = "垂直标尺", ["Vertical ruler columns"] = "垂直标尺列",
        ["Color scheme"] = "编辑器配色", ["Editor color scheme"] = "编辑器配色",
        ["Dark"] = "深色", ["Light"] = "浅色", ["Solarized Dark"] = "Solarized 深色", ["Dracula"] = "Dracula",
        ["Build command"] = "构建命令", ["Executable followed by arguments"] = "可执行文件及参数",
        ["Default build command"] = "默认构建命令",
        ["Git changed files"] = "Git 更改文件", ["Git diff"] = "Git 差异", ["Terminal output"] = "终端输出",
        ["Terminal command input"] = "终端命令输入", ["Language server output"] = "语言服务器输出",
        ["Language server diagnostics"] = "语言服务器诊断", ["Installed declarative plugins"] = "已安装声明式插件",
        ["Auto save mode"] = "自动保存模式", ["Auto save delay in milliseconds"] = "自动保存延迟（毫秒）"
    };

    private static readonly IReadOnlyDictionary<string, string> CommandChinese = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["new-file"]="新建文件", ["new-window"]="新建窗口", ["open-file"]="打开文件", ["open-file-with-encoding"]="按编码打开文件", ["open-folder"]="打开文件夹", ["open-recent-file"]="打开最近文件", ["open-recent-project"]="打开最近项目",
        ["save"]="保存", ["save-as"]="另存为", ["save-all"]="全部保存", ["cycle-auto-save"]="切换自动保存模式", ["close-tab"]="关闭标签页", ["close-other-tabs"]="关闭其他标签页", ["close-tabs-to-right"]="关闭右侧标签页", ["close-all-tabs"]="关闭全部标签页", ["reopen-tab"]="重新打开已关闭标签页", ["toggle-pin-tab"]="固定或取消固定标签页",
        ["find"]="查找", ["replace"]="替换", ["find-next"]="查找下一个", ["find-previous"]="查找上一个", ["find-in-files"]="在文件中查找", ["replace-in-files"]="在文件中替换", ["undo-replace-in-files"]="撤销文件替换", ["find-results-next"]="下一个查找结果", ["find-results-prev"]="上一个查找结果",
        ["goto-anything"]="转到任意位置", ["goto-symbol"]="转到文件符号", ["goto-project-symbol"]="转到项目符号", ["go-to-line"]="转到行", ["goto-matching-bracket"]="转到匹配括号", ["navigate-back"]="后退", ["navigate-forward"]="前进", ["next-change"]="下一个更改", ["prev-change"]="上一个更改", ["revert-current-change"]="还原当前更改",
        ["undo-selection"]="撤销选区更改", ["redo-selection"]="重做选区更改", ["select-line"]="选中整行", ["select-matching-bracket"]="选中至匹配括号", ["select-parent-syntax"]="选中外层语法结构", ["expand-selection"]="扩展选区", ["shrink-selection"]="缩小选区",
        ["toggle-comment"]="切换行注释", ["toggle-block-comment"]="切换块注释", ["move-line-up"]="上移行", ["move-line-down"]="下移行", ["copy-line-up"]="向上复制行", ["copy-line-down"]="向下复制行", ["duplicate-selection"]="复制行或选区", ["delete-line"]="删除行", ["delete-word-backward"]="删除前一个单词", ["delete-word-forward"]="删除后一个单词", ["delete-to-line-start"]="删除至行首", ["delete-to-line-end"]="删除至行尾", ["insert-blank-line-above"]="在上方插入空行", ["insert-blank-line"]="在下方插入空行", ["transpose-characters"]="转置字符",
        ["sort-lines"]="升序排列行", ["sort-lines-descending"]="降序排列行", ["reverse-lines"]="反转行顺序", ["unique-lines"]="删除重复行", ["remove-blank-lines"]="删除空白行", ["to-upper-case"]="转为大写", ["to-lower-case"]="转为小写", ["to-title-case"]="转为标题格式", ["swap-case"]="反转大小写", ["join-lines"]="合并行", ["wrap-paragraph-80"]="按 80 列重排段落", ["unwrap-paragraph"]="取消段落换行", ["indent-selection"]="增加缩进", ["outdent-selection"]="减少缩进", ["reindent-selection"]="重新缩进", ["convert-indent-spaces"]="缩进转空格", ["convert-indent-tabs"]="缩进转制表符", ["trim-trailing-whitespace"]="删除行尾空白", ["ensure-single-final-newline"]="确保末尾单换行",
        ["toggle-bookmark"]="切换书签", ["next-bookmark"]="下一个书签", ["prev-bookmark"]="上一个书签", ["record-macro"]="开始或停止录制宏", ["run-macro"]="运行上次宏", ["save-macro"]="保存宏", ["run-saved-macro"]="运行已保存宏", ["insert-snippet"]="插入片段", ["select-language"]="设置语法", ["select-line-ending"]="选择换行符", ["select-encoding"]="选择保存编码", ["reopen-with-encoding"]="按编码重新打开",
        ["toggle-preview"]="切换预览", ["open-in-browser"]="在浏览器中打开", ["toggle-sidebar"]="切换侧边栏", ["toggle-outline"]="切换大纲", ["reveal-active-file-in-sidebar"]="在侧栏显示活动文件", ["split-editor"]="切换分屏", ["split-selected-tabs"]="将所选标签拆分到分组", ["layout-single"]="单栏布局", ["layout-columns2"]="两栏布局", ["layout-columns3"]="三栏布局", ["layout-grid4"]="四宫格布局", ["move-file-next-group"]="移到下一分组", ["clone-file-next-group"]="复制到下一分组", ["focus-next-group"]="聚焦下一分组", ["focus-prev-group"]="聚焦上一分组",
        ["toggle-distraction-free"]="切换专注模式", ["toggle-spell-check"]="切换拼写检查", ["toggle-word-wrap"]="切换自动换行", ["toggle-theme"]="切换主题", ["select-color-scheme"]="选择配色方案", ["font-zoom-in"]="放大字体", ["font-zoom-out"]="缩小字体", ["font-zoom-reset"]="重置字号", ["format-json"]="格式化 JSON", ["compact-json"]="压缩 JSON", ["toggle-json-view"]="切换 JSON 视图", ["document-statistics"]="文档统计",
        ["build"]="构建", ["select-build-system"]="选择构建系统", ["toggle-problems"]="切换构建输出", ["toggle-terminal"]="切换终端", ["toggle-git"]="切换 Git 更改", ["refresh-git"]="刷新 Git", ["open-git-conflicts"]="打开合并冲突", ["format-document"]="格式化文档", ["language-tools"]="配置语言工具", ["toggle-language-servers"]="显示语言服务器", ["lsp-hover"]="显示悬停信息", ["lsp-definition"]="转到定义", ["lsp-references"]="查找引用", ["lsp-rename"]="重命名符号",
        ["install-plugin"]="安装本地插件", ["manage-plugins"]="管理插件", ["open-marketplace"]="浏览插件市场", ["check-for-updates"]="检查更新", ["project-settings"]="配置项目", ["add-folder-to-project"]="添加文件夹到项目", ["remove-folder-from-project"]="从项目移除文件夹", ["import-sublime-build"]="导入 Sublime 构建系统", ["import-sublime-project"]="导入 Sublime 项目", ["import-sublime-settings"]="导入 Sublime 设置", ["import-sublime-snippet"]="导入 Sublime 片段", ["import-sublime-keymap"]="导入 Sublime 快捷键", ["open-settings"]="打开设置", ["command-palette"]="命令面板", ["set-ui-language-zh"]="切换为简体中文", ["set-ui-language-en"]="切换为英文",
        ["copy-file-path"]="复制文件路径", ["copy-relative-file-path"]="复制相对文件路径", ["next-tab"]="下一个标签页", ["prev-tab"]="上一个标签页", ["convert-eol-lf"]="换行符转 LF", ["convert-eol-crlf"]="换行符转 CRLF", ["convert-eol-cr"]="换行符转 CR"
        ,["add-cursor-above"]="在上方添加光标", ["add-cursor-below"]="在下方添加光标", ["select-next-occurrence"]="选择下一个匹配项", ["skip-current-occurrence"]="跳过当前匹配项", ["remove-last-cursor"]="移除最后一个光标", ["select-all-occurrences"]="选择所有匹配项", ["add-cursors-line-starts"]="在各行行首添加光标", ["add-cursors-line-ends"]="在各行行尾添加光标", ["split-selection-lines"]="将选区拆分为多行光标", ["toggle-line-numbers"]="切换行号显示", ["toggle-minimap"]="切换缩略图", ["toggle-whitespace"]="切换空白字符显示"
        ,["fold-current"]="折叠当前代码块", ["unfold-current"]="展开当前代码块", ["fold-all"]="折叠全部代码块", ["unfold-all"]="展开全部代码块"
    };

    public static string Text(string locale, string current)
    {
        if (locale == "zh-CN") return UiChinese.TryGetValue(current, out var translated) ? translated : current;
        foreach (var pair in UiChinese) if (pair.Value == current) return pair.Key;
        return current;
    }

    public static string CommandTitle(string locale, string commandId)
    {
        if (locale == "zh-CN" && CommandChinese.TryGetValue(commandId, out var translated)) return translated;
        return CultureInfo.InvariantCulture.TextInfo.ToTitleCase(commandId.Replace('-', ' '));
    }
}
