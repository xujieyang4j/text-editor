import type { MenuEvent, UiLocale } from './ipc.js'

export type TranslationKey = keyof typeof ZH

const ZH = {
  appTitle: 'Lumen 编辑器',
  file: '文件', edit: '编辑', selection: '选择', goto: '转到', view: '视图', tools: '工具', preferences: '偏好设置', project: '项目', git: 'Git', window: '窗口', help: '帮助',
  newFile: '新建文件', newWindow: '新建窗口', openFile: '打开文件…', openFolder: '打开文件夹…', openRecentFile: '打开最近文件…', openRecentProject: '打开最近项目…',
  save: '保存', saveAs: '另存为…', saveAll: '全部保存', pinTab: '固定/取消固定标签页', cycleAutoSave: '切换自动保存模式', closeTab: '关闭标签页', closeOtherTabs: '关闭其他标签页', closeTabsRight: '关闭右侧标签页', closeAllTabs: '关闭全部标签页', reopenTab: '重新打开已关闭标签页',
  undo: '撤销', redo: '重做', cut: '剪切', copy: '复制', paste: '粘贴', selectAll: '全选',
  commandPalette: '命令面板…', setSyntax: '设置语法…', toggleSidebar: '切换侧边栏', toggleMinimap: '切换缩略图', toggleOutline: '切换大纲', distractionFree: '专注模式', toggleSpellCheck: '切换拼写检查', toggleWrap: '切换自动换行', toggleTheme: '切换主题', selectColorScheme: '选择配色方案…',
  gotoAnything: '转到任意位置…', gotoSymbol: '转到文件符号…', gotoProjectSymbol: '转到项目符号…', gotoLine: '转到行…', back: '后退', forward: '前进',
  find: '查找', replace: '替换', findInFiles: '在文件中查找…', replaceInFiles: '在文件中替换…', findResults: '查找结果',
  build: '构建', terminal: '终端', formatDocument: '格式化文档', selectBuildSystem: '选择构建系统…', importSublimeBuild: '导入 Sublime 构建系统…', toggleBuildOutput: '切换构建输出', configureLanguageTool: '配置语言工具…',
  importSublimeSettings: '导入 Sublime 设置…', importSublimeKeymap: '导入 Sublime 快捷键…', importSublimeProject: '导入 Sublime 项目…', importSublimeSnippet: '导入 Sublime 片段…',
  toggleGit: '切换 Git 更改', refreshGit: '刷新更改', openConflicts: '打开合并冲突', checkUpdates: '检查更新…',
  languageChinese: '简体中文', languageEnglish: 'English', switchLanguage: '界面语言',
  noFolder: '未打开文件夹', plainText: '纯文本', line: '行', column: '列', autoSave: '自动保存', noRecentFiles: '没有最近文件', noRecentProjects: '没有最近项目',
  run: '运行', stop: '停止', gitChanges: 'Git 更改', stage: '暂存', unstage: '取消暂存', discard: '丢弃', commit: '提交', history: '历史', blame: '追溯',
  findPlaceholder: '查找', replacePlaceholder: '替换', includePlaceholder: '包含：例如 **/*.ts', excludePlaceholder: '排除：例如 **/node_modules/**', findAll: '查找全部', replaceAll: '全部替换',
  formatJson: '格式化 JSON', compactJson: '压缩 JSON', jsonView: 'JSON 视图',
  learnMore: '了解更多'
} as const

const EN: Record<TranslationKey, string> = {
  appTitle: 'Lumen Editor',
  file: 'File', edit: 'Edit', selection: 'Selection', goto: 'Goto', view: 'View', tools: 'Tools', preferences: 'Preferences', project: 'Project', git: 'Git', window: 'Window', help: 'Help',
  newFile: 'New File', newWindow: 'New Window', openFile: 'Open File…', openFolder: 'Open Folder…', openRecentFile: 'Open Recent File…', openRecentProject: 'Open Recent Project…',
  save: 'Save', saveAs: 'Save As…', saveAll: 'Save All', pinTab: 'Pin / Unpin Tab', cycleAutoSave: 'Cycle Auto Save Mode', closeTab: 'Close Tab', closeOtherTabs: 'Close Other Tabs', closeTabsRight: 'Close Tabs to the Right', closeAllTabs: 'Close All Tabs', reopenTab: 'Reopen Closed Tab',
  undo: 'Undo', redo: 'Redo', cut: 'Cut', copy: 'Copy', paste: 'Paste', selectAll: 'Select All',
  commandPalette: 'Command Palette…', setSyntax: 'Set Syntax…', toggleSidebar: 'Toggle Sidebar', toggleMinimap: 'Toggle Minimap', toggleOutline: 'Toggle Outline', distractionFree: 'Distraction Free Mode', toggleSpellCheck: 'Toggle Spell Check', toggleWrap: 'Toggle Word Wrap', toggleTheme: 'Toggle Theme', selectColorScheme: 'Select Color Scheme…',
  gotoAnything: 'Goto Anything…', gotoSymbol: 'Goto Symbol…', gotoProjectSymbol: 'Goto Symbol in Project…', gotoLine: 'Goto Line…', back: 'Back', forward: 'Forward',
  find: 'Find', replace: 'Replace', findInFiles: 'Find in Files…', replaceInFiles: 'Replace in Files…', findResults: 'Find Results',
  build: 'Build', terminal: 'Terminal', formatDocument: 'Format Document', selectBuildSystem: 'Select Build System…', importSublimeBuild: 'Import Sublime Build System…', toggleBuildOutput: 'Toggle Build Output', configureLanguageTool: 'Configure Language Tool…',
  importSublimeSettings: 'Import Sublime Settings…', importSublimeKeymap: 'Import Sublime Keymap…', importSublimeProject: 'Import Sublime Project…', importSublimeSnippet: 'Import Sublime Snippet…',
  toggleGit: 'Toggle Git Changes', refreshGit: 'Refresh Changes', openConflicts: 'Open Merge Conflicts', checkUpdates: 'Check for Updates…',
  languageChinese: '简体中文', languageEnglish: 'English', switchLanguage: 'Interface Language',
  noFolder: 'No Folder Opened', plainText: 'Plain Text', line: 'Ln', column: 'Col', autoSave: 'Auto Save', noRecentFiles: 'No recent files are available', noRecentProjects: 'No recent projects are available',
  run: 'Run', stop: 'Stop', gitChanges: 'Git Changes', stage: 'Stage', unstage: 'Unstage', discard: 'Discard', commit: 'Commit', history: 'History', blame: 'Blame',
  findPlaceholder: 'Find', replacePlaceholder: 'Replace', includePlaceholder: 'Include: e.g. **/*.ts', excludePlaceholder: 'Exclude: e.g. **/node_modules/**', findAll: 'Find All', replaceAll: 'Replace All',
  formatJson: 'Format JSON', compactJson: 'Compact JSON', jsonView: 'JSON View',
  learnMore: 'Learn More'
}

export function translate(locale: UiLocale, key: TranslationKey): string {
  return (locale === 'en-US' ? EN : ZH)[key]
}

export function makeTranslator(locale: UiLocale): (key: TranslationKey) => string {
  return (key) => translate(locale, key)
}

const COMMAND_ZH: Partial<Record<MenuEvent, string>> = {
  'new-file': '新建文件', 'new-window': '新建窗口', 'open-file': '打开文件…', 'open-folder': '打开文件夹…', 'open-recent-file': '打开最近文件…', 'open-recent-project': '打开最近项目…', 'copy-file-path': '复制文件路径', 'copy-relative-file-path': '复制相对文件路径',
  save: '保存', 'save-as': '另存为…', 'save-all': '全部保存', 'toggle-pin-tab': '固定/取消固定标签页', 'cycle-auto-save': '切换自动保存模式', 'close-tab': '关闭标签页', 'close-other-tabs': '关闭其他标签页', 'close-tabs-to-right': '关闭右侧标签页', 'close-all-tabs': '关闭全部标签页', 'reopen-tab': '重新打开已关闭标签页',
  find: '查找', replace: '替换', 'find-in-files': '在文件中查找…', 'replace-in-files': '在文件中替换…', 'undo-replace-in-files': '撤销上次文件替换', 'find-results-next': '下一个查找结果', 'find-results-prev': '上一个查找结果',
  'goto-anything': '转到任意位置…', 'goto-symbol': '转到文件符号…', 'goto-project-symbol': '转到项目符号…', 'go-to-line': '转到行…', 'goto-matching-bracket': '转到匹配括号', 'navigate-back': '后退', 'navigate-forward': '前进',
  'toggle-comment': '切换行注释', 'toggle-block-comment': '切换块注释', 'move-line-up': '上移行', 'move-line-down': '下移行', 'copy-line-up': '向上复制行', 'copy-line-down': '向下复制行', 'duplicate-selection': '复制行/选区', 'delete-line': '删除行', 'delete-word-backward': '删除前一个单词', 'delete-word-forward': '删除后一个单词', 'delete-to-line-start': '删除至行首', 'delete-to-line-end': '删除至行尾', 'insert-blank-line-above': '在上方新建空行', 'insert-blank-line': '在下方新建空行', 'transpose-characters': '转置相邻字符', 'sort-lines': '排序行',
  'to-upper-case': '转为大写', 'to-lower-case': '转为小写', 'to-title-case': '转为标题格式', 'join-lines': '合并行', 'trim-trailing-whitespace': '删除行尾空白', 'indent-selection': '增加缩进', 'outdent-selection': '减少缩进', 'reindent-selection': '自动重新缩进选区',
  'add-cursor-above': '在上方添加光标', 'add-cursor-below': '在下方添加光标', 'select-next-occurrence': '选择下一个匹配项', 'select-all-occurrences': '选择全部匹配项', 'select-line': '选中整行', 'select-matching-bracket': '选中至匹配括号', 'select-parent-syntax': '选中外层语法结构', 'expand-selection': '扩展选区', 'shrink-selection': '缩小选区', 'split-selection-lines': '按行拆分选区',
  'next-tab': '下一个标签页', 'prev-tab': '上一个标签页', 'toggle-bookmark': '切换书签', 'next-bookmark': '下一个书签', 'prev-bookmark': '上一个书签', 'next-change': '下一个更改', 'prev-change': '上一个更改', 'revert-current-change': '还原当前更改',
  'toggle-sidebar': '切换侧边栏', 'split-editor': '切换分屏编辑器', 'split-selected-tabs': '将选中标签拆分到分组', 'layout-single': '单栏布局', 'layout-columns2': '两栏布局', 'layout-columns3': '三栏布局', 'layout-grid4': '四宫格布局',
  'move-file-next-group': '将文件移到下一分组', 'clone-file-next-group': '将文件复制到下一分组', 'focus-next-group': '聚焦下一分组', 'focus-prev-group': '聚焦上一分组',
  'toggle-minimap': '切换缩略图', 'toggle-outline': '切换大纲', 'fold-current': '折叠当前代码块', 'unfold-current': '展开当前代码块', 'fold-all': '折叠全部代码块', 'unfold-all': '展开全部代码块', 'toggle-distraction-free': '切换专注模式', 'toggle-spell-check': '切换拼写检查', 'toggle-word-wrap': '切换自动换行', 'toggle-theme': '切换明暗主题', 'select-color-scheme': '选择配色方案…', 'font-zoom-in': '放大字体', 'font-zoom-out': '缩小字体', 'font-zoom-reset': '重置字体大小',
  'toggle-preview': '切换 Markdown 预览', 'open-in-browser': '在浏览器中打开', 'select-language': '设置语法…', 'command-palette': '命令面板…',
  build: '构建', 'toggle-terminal': '切换终端', 'document-statistics': '文档统计', 'select-build-system': '选择构建系统…', 'import-sublime-build': '导入 Sublime 构建系统…', 'format-document': '格式化文档', 'toggle-problems': '切换构建输出', 'language-tools': '配置语言工具…',
  'lsp-hover': '显示悬停信息', 'lsp-definition': '转到定义', 'lsp-references': '查找引用', 'lsp-rename': '重命名符号',
  'toggle-git': '切换 Git 更改', 'refresh-git': '刷新 Git 更改', 'open-git-conflicts': '打开合并冲突', 'check-for-updates': '检查更新…',
  'open-marketplace': '浏览插件市场…', 'install-plugin': '安装本地插件…', 'manage-plugins': '管理插件…', 'insert-snippet': '插入片段…', 'import-sublime-snippet': '导入 Sublime 片段…',
  'record-macro': '开始/停止录制宏', 'run-macro': '运行上次宏', 'save-macro': '保存上次宏…', 'run-saved-macro': '运行已保存宏…',
  'project-settings': '配置项目…', 'add-folder-to-project': '添加文件夹到项目…', 'remove-folder-from-project': '从项目移除文件夹…', 'import-sublime-project': '导入 Sublime 项目…',
  'import-sublime-settings': '导入 Sublime 设置…', 'import-sublime-keymap': '导入 Sublime 快捷键…',
  'set-ui-language-zh': '切换为简体中文', 'set-ui-language-en': '切换为英文', 'open-settings': '打开设置…'
  , 'format-json': '格式化 JSON', 'compact-json': '压缩 JSON', 'toggle-json-view': '切换 JSON 视图'
}

const CATEGORY_ZH: Record<string, string> = {
  File: '文件', Edit: '编辑', Selection: '选择', Goto: '转到', Navigate: '导航', Find: '查找', View: '视图', Tools: '工具', Project: '项目', Git: 'Git', Help: '帮助', LSP: '语言服务', Preferences: '偏好设置'
}

export function commandLabel(locale: UiLocale, event: MenuEvent, fallback: string): string {
  return locale === 'zh-CN' ? (COMMAND_ZH[event] ?? fallback) : fallback
}

export function commandTitle(locale: UiLocale, event: MenuEvent, fallback: string): string {
  if (locale !== 'zh-CN') return fallback
  const [category, ...rest] = fallback.split(': ')
  const label = COMMAND_ZH[event] ?? (rest.join(': ') || fallback)
  return rest.length > 0 ? `${CATEGORY_ZH[category] ?? category}：${label}` : label
}
