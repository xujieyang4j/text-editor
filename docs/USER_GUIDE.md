<!-- Lumen Editor — Detailed User Guide (bilingual) -->
<!-- 详细使用说明（中英双语）。English first, 中文在后。 -->

# Lumen Editor — User Guide / 使用指南

**Language / 语言:** [English](#english) ｜ [中文](#中文)

Related docs: [README (EN)](../README.md) ｜ [README (中文)](../README.zh-CN.md) ｜
[安装与使用（快速版）](./使用说明.md)

---

<a id="english"></a>

# English

Lumen Editor is a cross-platform desktop text editor (Linux / Windows / macOS) built on
Electron + TypeScript + CodeMirror 6, with a feature set aligned to Sublime Text.

## Table of Contents

1. [Install & Launch](#en-install)
2. [Interface Tour](#en-interface)
3. [Files & Tabs](#en-files)
4. [Command Palette & Goto](#en-palette)
5. [Editing & Multi-Cursor](#en-editing)
6. [Search & Replace](#en-search)
7. [Syntax Highlighting](#en-syntax)
8. [View: Minimap, Guides, Rulers, Zoom, Theme](#en-view)
9. [Settings Reference](#en-settings)
10. [Session Restore](#en-session)
11. [Full Keyboard Reference](#en-keys)
12. [Troubleshooting](#en-trouble)

<a id="en-install"></a>

## 1. Install & Launch

**Run from source (developers):**

```bash
git clone git@github.com:xujieyang4j/text-editor.git
cd text-editor
npm install          # installs deps + the Electron runtime binary
npm run dev          # launches with hot reload
```

If the Electron binary download is slow, set a mirror first:

```bash
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
npm install
```

> ⚠️ **Never run `npm audit fix --force`.** The reported advisories all live in build-time
> tooling and are never bundled into the app; `--force` upgrades the toolchain to mutually
> incompatible majors and breaks everything. See [Troubleshooting](#en-trouble).

**Build without a GUI** (typecheck + bundle only — useful on servers/CI):

```bash
npm run typecheck
npm run build
```

**Package installers** → output under `release/<version>/`:

```bash
npm run dist:win     # Windows: NSIS installer + portable .exe
npm run dist:mac     # macOS: .dmg + .zip (must build on macOS)
npm run dist:linux   # Linux: AppImage + .deb
```

<a id="en-interface"></a>

## 2. Interface Tour

```
┌───────────┬─────────────────────────────────┐
│  Sidebar  │  Tab bar                         │
│ (file     ├─────────────────────────────────┤
│  tree)    │                                  │
│           │   Editor (CodeMirror) + Minimap  │
│           │                                  │
│           ├─────────────────────────────────┤
│           │  Status bar: Ln/Col · Lang · EOL │
└───────────┴─────────────────────────────────┘
```

- **Sidebar** — the workspace file tree. Toggle with `Ctrl/Cmd+B`.
- **Tab bar** — one tab per open document. A `●` marks unsaved changes; `×` closes the tab.
- **Editor** — the CodeMirror text area, with an optional minimap on the right.
- **Status bar** — cursor position, selection length, and a **clickable language** field
  (click it to change the syntax).

<a id="en-files"></a>

## 3. Files & Tabs

| Action | How |
| --- | --- |
| New file | `Ctrl/Cmd+N` |
| Open file | `Ctrl/Cmd+O` |
| Open folder (workspace) | `Ctrl/Cmd+Shift+O` — populates the sidebar |
| Save | `Ctrl/Cmd+S` (untitled files prompt for a path) |
| Save As | `Ctrl/Cmd+Shift+S` |
| Close tab | `Ctrl/Cmd+W` (prompts if there are unsaved changes) |
| Reopen closed tab | `Ctrl/Cmd+Shift+T` (LIFO stack of recently closed files) |
| Switch to tab N | `Ctrl/Cmd+1` … `Ctrl/Cmd+9` |
| Next / previous tab | `Ctrl/Cmd+Alt+→` / `Ctrl/Cmd+Alt+←` |

In the file tree, click a folder to expand/collapse it (loaded on demand), and click a file to
open it. Opening a file that's already open just focuses its tab.

<a id="en-palette"></a>

## 4. Command Palette & Goto

**Command Palette — `Ctrl/Cmd+Shift+P`.** Fuzzy-search every command by name and run it.
Matched characters are highlighted; `↑`/`↓` to move, `Enter` to run, `Esc` to dismiss.

**Goto Anything — `Ctrl/Cmd+P`.** A fuzzy file finder over the open workspace folder, with two
sub-modes triggered by a prefix in the same input:

| Type | Mode | Example |
| --- | --- | --- |
| *(text)* | Fuzzy file path | `maints` → `src/renderer/src/main.ts` |
| `:` + number | Go to line in current file | `:120` |
| `@` + name | Go to symbol in current file | `@openFolder` |

**Goto Symbol — `Ctrl/Cmd+R`.** Same as the `@` mode directly. Symbols are extracted with a
fast per-line scan: JS/TS functions, classes, methods and arrow-consts; Python `def`/`class`;
Go `func`; Rust `fn`; and Markdown headings.

> Goto Anything's file list requires an open folder (`Ctrl/Cmd+Shift+O`). With no workspace,
> use `Ctrl/Cmd+P` for `:line`/`@symbol` in the current file, or the sidebar to open files.

<a id="en-editing"></a>

## 5. Editing & Multi-Cursor

**Multi-cursor (Sublime-style):**

| Action | Shortcut |
| --- | --- |
| Add next occurrence of selection to cursors | `Ctrl/Cmd+D` |
| Add cursor above / below | `Ctrl/Cmd+Alt+↑` / `Ctrl/Cmd+Alt+↓` |
| Select all occurrences of selection | `Ctrl/Cmd+Shift+L` |
| Add a cursor at click point | `Alt`+Click |
| Column (rectangular) selection | `Alt`+Drag |
| Collapse back to a single cursor | `Esc` |

**Line operations:**

| Action | Shortcut |
| --- | --- |
| Toggle line/block comment | `Ctrl/Cmd+/` |
| Move line up / down | `Alt+↑` / `Alt+↓` |
| Copy line up / down | `Shift+Alt+↑` / `Shift+Alt+↓` |
| Duplicate line / selection | `Ctrl/Cmd+Shift+D` |
| Delete line | `Ctrl/Cmd+Shift+K` |
| Sort lines (selection, or whole doc) | Command Palette → *Edit: Sort Lines* |
| Select line | `Alt+L` |
| Select enclosing syntax | `Ctrl/Cmd+I` |

Also included: undo/redo (`Ctrl/Cmd+Z` / `Ctrl/Cmd+Y`), auto-close brackets, auto-indent on
input, code folding (fold gutter in the margin), bracket matching, and autocompletion
(`Ctrl/Cmd+Space` to trigger).

<a id="en-search"></a>

## 6. Search & Replace

- **Find** — `Ctrl/Cmd+F` opens the search panel. The panel has regex, case-sensitive and
  whole-word toggles.
- **Find next** — `F3` (or `Enter` while the search field is focused).
- **Replace** — `Ctrl/Cmd+H` opens the panel with the replace row; use its *Replace* /
  *Replace All* buttons.
- **Select all matches** — `Ctrl/Cmd+Shift+L` turns every match of the current selection into a
  cursor for bulk editing.

> Note: `Ctrl/Cmd+G` is bound to **Goto Line** in Lumen (not "find next"), so use `F3` to step
> through matches.

<a id="en-syntax"></a>

## 7. Syntax Highlighting

- **Automatic** — the language is detected from the file extension (100+ languages). The
  resolved name shows at the right of the status bar.
- **Manual** — click the language field in the status bar, or run *View: Set Syntax…* from the
  Command Palette, then pick from the fuzzy list. A manual choice **locks** the language so it
  won't be overwritten by auto-detection when you switch tabs or save.
- **Untitled files** start as *Plain Text* (no extension yet); saving as `foo.py` (or setting
  the syntax manually) enables highlighting.

<a id="en-view"></a>

## 8. View: Minimap, Guides, Rulers, Zoom, Theme

| Feature | How | Setting key |
| --- | --- | --- |
| Minimap (right-edge overview) | *View: Toggle Minimap* | `showMinimap` |
| Indentation guides | always on unless disabled | `showIndentGuides` |
| Trailing-whitespace highlight | always on unless disabled | `highlightTrailingWhitespace` |
| Vertical rulers | set columns in settings | `rulers` |
| Word wrap | `Alt+Z` | `wordWrap` |
| Dark / light theme | `Ctrl/Cmd+K` | `theme` |
| Font zoom in / out / reset | `Ctrl/Cmd+=` / `-` / `0` | `fontSize` |

Toggles you flip at runtime (theme, wrap, minimap, font size) are written straight back to the
settings file, so they persist across restarts.

<a id="en-settings"></a>

## 9. Settings Reference

Settings are stored as JSON in the OS user-data directory and applied live:

- **Windows:** `%APPDATA%\Lumen Editor\settings.json`
- **macOS:** `~/Library/Application Support/Lumen Editor/settings.json`
- **Linux:** `~/.config/Lumen Editor/settings.json`

```jsonc
{
  "fontSize": 14,                       // editor font size in px (8–40)
  "tabSize": 4,                         // columns per tab
  "insertSpaces": true,                 // insert spaces instead of a tab char
  "theme": "dark",                      // "dark" | "light"
  "wordWrap": false,                    // soft wrap long lines
  "showMinimap": true,                  // right-edge minimap
  "showIndentGuides": true,             // indentation guide lines
  "highlightTrailingWhitespace": true,  // mark trailing spaces/tabs
  "rulers": [80, 120]                   // vertical rulers at these columns ([] = none)
}
```

Unknown/missing keys fall back to defaults, so a partial file is fine. `session.json` in the
same folder stores your open tabs + folder and is managed automatically.

<a id="en-session"></a>

## 10. Session Restore

On a clean quit, Lumen records the open files, the active tab and the workspace folder. Next
launch it reopens them. Files deleted or moved in the meantime are skipped silently. Use
`Ctrl/Cmd+Shift+T` to reopen the most recently closed tab.

<a id="en-keys"></a>

## 11. Full Keyboard Reference

| Action | Windows / Linux | macOS |
| --- | --- | --- |
| Command Palette | `Ctrl+Shift+P` | `Cmd+Shift+P` |
| Goto Anything | `Ctrl+P` | `Cmd+P` |
| Goto Symbol | `Ctrl+R` | `Cmd+R` |
| Goto Line | `Ctrl+G` | `Cmd+G` |
| New / Open file | `Ctrl+N` / `Ctrl+O` | `Cmd+N` / `Cmd+O` |
| Open folder | `Ctrl+Shift+O` | `Cmd+Shift+O` |
| Save / Save As | `Ctrl+S` / `Ctrl+Shift+S` | `Cmd+S` / `Cmd+Shift+S` |
| Close / Reopen tab | `Ctrl+W` / `Ctrl+Shift+T` | `Cmd+W` / `Cmd+Shift+T` |
| Tab N / Next / Prev | `Ctrl+1..9` / `Ctrl+Alt+←/→` | `Cmd+1..9` / `Cmd+Alt+←/→` |
| Find / Replace | `Ctrl+F` / `Ctrl+H` | `Cmd+F` / `Cmd+H` |
| Find next | `F3` | `F3` |
| Add next occurrence | `Ctrl+D` | `Cmd+D` |
| Add cursor above / below | `Ctrl+Alt+↑/↓` | `Cmd+Alt+↑/↓` |
| Select all occurrences | `Ctrl+Shift+L` | `Cmd+Shift+L` |
| Toggle comment | `Ctrl+/` | `Cmd+/` |
| Move / Copy line | `Alt+↑↓` / `Shift+Alt+↑↓` | `Alt+↑↓` / `Shift+Alt+↑↓` |
| Duplicate / Delete line | `Ctrl+Shift+D` / `Ctrl+Shift+K` | `Cmd+Shift+D` / `Cmd+Shift+K` |
| Zoom in / out / reset | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | `Cmd+=` / `Cmd+-` / `Cmd+0` |
| Toggle sidebar / wrap / theme | `Ctrl+B` / `Alt+Z` / `Ctrl+K` | `Cmd+B` / `Alt+Z` / `Cmd+K` |

<a id="en-trouble"></a>

## 12. Troubleshooting

**Do not run `npm audit fix --force`.** Advisories are in build tooling only; `--force` breaks
the toolchain (ERESOLVE, `cac` export error). Recover with a fresh `git clone`, or:
`rm -rf node_modules package-lock.json && git checkout package.json package-lock.json && npm install`.

**macOS says "Electron.app is damaged / malware" and trashes it.** This is a false positive for
the unsigned dev runtime. Recover:

```bash
rm -rf node_modules/electron && export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ && npm install
xattr -cr node_modules/electron/dist/Electron.app
codesign --force --deep --sign - node_modules/electron/dist/Electron.app
npm run dev
```

Or approve it under **System Settings → Privacy & Security → Open Anyway**.

**Headless Linux: `libgbm.so.1` missing / core dump.** Electron needs a display + GPU libs.
Install them and use a virtual display, or run on a real desktop:
`sudo apt-get install -y libgbm1 libwayland-server0 xvfb && xvfb-run -a npm run dev`.

**`npm install` says the cache is read-only (`EROFS`).** Point npm at a writable cache:
`npm install --cache /writable/path/.npm-cache`.

---

<a id="中文"></a>

# 中文

Lumen Editor 是一款基于 Electron + TypeScript + CodeMirror 6 的跨平台桌面文本编辑器
（Linux / Windows / macOS），功能对齐 Sublime Text。

## 目录

1. [安装与启动](#zh-install)
2. [界面速览](#zh-interface)
3. [文件与标签](#zh-files)
4. [命令面板与跳转](#zh-palette)
5. [编辑与多光标](#zh-editing)
6. [查找与替换](#zh-search)
7. [语法高亮](#zh-syntax)
8. [视图：Minimap / 参考线 / 标尺 / 缩放 / 主题](#zh-view)
9. [设置项参考](#zh-settings)
10. [会话恢复](#zh-session)
11. [完整快捷键表](#zh-keys)
12. [故障排查](#zh-trouble)

<a id="zh-install"></a>

## 1. 安装与启动

**从源码运行（开发者）：**

```bash
git clone git@github.com:xujieyang4j/text-editor.git
cd text-editor
npm install          # 安装依赖 + Electron 运行时二进制
npm run dev          # 启动（热重载）
```

Electron 二进制下载慢时，先设镜像：

```bash
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
npm install
```

> ⚠️ **切勿运行 `npm audit fix --force`。** 报告的漏洞全部在构建工具链、不会打包进应用；
> `--force` 会把工具链升级到互不兼容的大版本、直接搞崩环境。详见[故障排查](#zh-trouble)。

**无 GUI 校验**（仅类型检查 + 打包，适合服务器/CI）：

```bash
npm run typecheck
npm run build
```

**打包安装程序** → 产物在 `release/<版本号>/`：

```bash
npm run dist:win     # Windows：NSIS 安装程序 + 便携版
npm run dist:mac     # macOS：.dmg + .zip（必须在 macOS 上打）
npm run dist:linux   # Linux：AppImage + .deb
```

<a id="zh-interface"></a>

## 2. 界面速览

```
┌───────────┬─────────────────────────────────┐
│  侧边栏    │  标签栏                          │
│ (文件树)   ├─────────────────────────────────┤
│           │                                  │
│           │   编辑区 (CodeMirror) + Minimap   │
│           │                                  │
│           ├─────────────────────────────────┤
│           │  状态栏：行列 · 语言 · 换行符      │
└───────────┴─────────────────────────────────┘
```

- **侧边栏** —— 工作区文件树，`Ctrl/Cmd+B` 显隐。
- **标签栏** —— 每个打开的文档一个标签；`●` 表示未保存，`×` 关闭。
- **编辑区** —— CodeMirror 文本区，右侧可选 Minimap。
- **状态栏** —— 光标位置、选中长度，以及**可点击的语言字段**（点它可改语法）。

<a id="zh-files"></a>

## 3. 文件与标签

| 操作 | 方式 |
| --- | --- |
| 新建文件 | `Ctrl/Cmd+N` |
| 打开文件 | `Ctrl/Cmd+O` |
| 打开文件夹（工作区） | `Ctrl/Cmd+Shift+O`，载入侧边栏 |
| 保存 | `Ctrl/Cmd+S`（未命名文件会弹保存框） |
| 另存为 | `Ctrl/Cmd+Shift+S` |
| 关闭标签 | `Ctrl/Cmd+W`（有未保存改动会确认） |
| 重开关闭的标签 | `Ctrl/Cmd+Shift+T`（后进先出栈） |
| 切到第 N 个标签 | `Ctrl/Cmd+1` … `Ctrl/Cmd+9` |
| 下一个 / 上一个标签 | `Ctrl/Cmd+Alt+→` / `Ctrl/Cmd+Alt+←` |

文件树中点文件夹展开/折叠（按需加载），点文件打开。打开已开的文件只会聚焦它的标签。

<a id="zh-palette"></a>

## 4. 命令面板与跳转

**命令面板 —— `Ctrl/Cmd+Shift+P`。** 模糊搜索所有命令并执行。匹配字符高亮；`↑`/`↓` 移动、
`Enter` 执行、`Esc` 关闭。

**Goto Anything —— `Ctrl/Cmd+P`。** 对已打开工作区文件夹的模糊查找，输入框里用前缀切换两种子模式：

| 输入 | 模式 | 示例 |
| --- | --- | --- |
| *(文字)* | 模糊匹配文件路径 | `maints` → `src/renderer/src/main.ts` |
| `:` + 数字 | 跳到当前文件的某行 | `:120` |
| `@` + 名称 | 跳到当前文件的符号 | `@openFolder` |

**跳转到符号 —— `Ctrl/Cmd+R`。** 等同直接进入 `@` 模式。符号用快速逐行扫描抽取：JS/TS 的
函数/类/方法/箭头常量、Python 的 `def`/`class`、Go 的 `func`、Rust 的 `fn`，以及 Markdown 标题。

> Goto Anything 的文件列表需要先打开文件夹（`Ctrl/Cmd+Shift+O`）。没有工作区时，`Ctrl/Cmd+P`
> 仍可用 `:行号`/`@符号` 在当前文件内跳转，或用侧边栏打开文件。

<a id="zh-editing"></a>

## 5. 编辑与多光标

**多光标（Sublime 风格）：**

| 操作 | 快捷键 |
| --- | --- |
| 把选区的下一个匹配加入光标 | `Ctrl/Cmd+D` |
| 在上方 / 下方加光标 | `Ctrl/Cmd+Alt+↑` / `Ctrl/Cmd+Alt+↓` |
| 选中选区的所有匹配 | `Ctrl/Cmd+Shift+L` |
| 在点击处加光标 | `Alt`+单击 |
| 列（矩形）选择 | `Alt`+拖拽 |
| 收回为单光标 | `Esc` |

**行操作：**

| 操作 | 快捷键 |
| --- | --- |
| 切换行/块注释 | `Ctrl/Cmd+/` |
| 上移 / 下移行 | `Alt+↑` / `Alt+↓` |
| 向上 / 向下复制行 | `Shift+Alt+↑` / `Shift+Alt+↓` |
| 复制行 / 选区 | `Ctrl/Cmd+Shift+D` |
| 删除行 | `Ctrl/Cmd+Shift+K` |
| 行排序（选区或整篇） | 命令面板 → *Edit: Sort Lines* |
| 选中整行 | `Alt+L` |
| 选中所在语法块 | `Ctrl/Cmd+I` |

另含：撤销/重做（`Ctrl/Cmd+Z` / `Ctrl/Cmd+Y`）、自动闭合括号、输入自动缩进、代码折叠
（左侧折叠槽）、括号匹配、自动补全（`Ctrl/Cmd+Space` 触发）。

<a id="zh-search"></a>

## 6. 查找与替换

- **查找** —— `Ctrl/Cmd+F` 打开查找面板，面板内有正则、区分大小写、全词匹配开关。
- **查找下一个** —— `F3`（或查找框聚焦时按 `Enter`）。
- **替换** —— `Ctrl/Cmd+H` 打开带替换行的面板，用其中的 *Replace* / *Replace All* 按钮。
- **选中所有匹配** —— `Ctrl/Cmd+Shift+L` 把当前选区的每处匹配都变成光标，便于批量编辑。

> 注意：在 Lumen 中 `Ctrl/Cmd+G` 绑定为**跳转到行**（而非“查找下一个”），所以用 `F3` 逐个跳匹配。

<a id="zh-syntax"></a>

## 7. 语法高亮

- **自动** —— 按文件扩展名识别语言（100+ 种），识别结果显示在状态栏右侧。
- **手动** —— 点状态栏语言字段，或在命令面板执行 *View: Set Syntax…*，从模糊列表里选。手动选择
  会**锁定**语言，之后切换标签或保存都不再被自动识别覆盖。
- **未命名文件**初始为 *Plain Text*（还没扩展名）；另存为 `foo.py`（或手动设语法）即可高亮。

<a id="zh-view"></a>

## 8. 视图：Minimap / 参考线 / 标尺 / 缩放 / 主题

| 功能 | 方式 | 设置项 |
| --- | --- | --- |
| Minimap（右侧缩略图） | *View: Toggle Minimap* | `showMinimap` |
| 缩进参考线 | 默认开，可禁用 | `showIndentGuides` |
| 行尾空白高亮 | 默认开，可禁用 | `highlightTrailingWhitespace` |
| 竖直标尺 | 在设置里指定列 | `rulers` |
| 软换行 | `Alt+Z` | `wordWrap` |
| 明 / 暗主题 | `Ctrl/Cmd+K` | `theme` |
| 字号放大 / 缩小 / 复位 | `Ctrl/Cmd+=` / `-` / `0` | `fontSize` |

运行时切换的项（主题、换行、Minimap、字号）会立即写回设置文件，重启后保留。

<a id="zh-settings"></a>

## 9. 设置项参考

设置以 JSON 存于系统 userData 目录，改动即时生效：

- **Windows：** `%APPDATA%\Lumen Editor\settings.json`
- **macOS：** `~/Library/Application Support/Lumen Editor/settings.json`
- **Linux：** `~/.config/Lumen Editor/settings.json`

```jsonc
{
  "fontSize": 14,                       // 编辑器字号(px，8–40)
  "tabSize": 4,                         // 每个 Tab 的列数
  "insertSpaces": true,                 // 用空格代替制表符
  "theme": "dark",                      // "dark" | "light"
  "wordWrap": false,                    // 长行软换行
  "showMinimap": true,                  // 右侧 Minimap
  "showIndentGuides": true,             // 缩进参考线
  "highlightTrailingWhitespace": true,  // 标记行尾空白
  "rulers": [80, 120]                   // 在这些列画竖直标尺([] = 不画)
}
```

缺失/未知键回退到默认值，写一部分也没问题。同目录的 `session.json` 保存打开的标签与文件夹，
由程序自动管理。

<a id="zh-session"></a>

## 10. 会话恢复

正常退出时，Lumen 记录打开的文件、活动标签与工作区文件夹；下次启动自动重开。期间被删除或移动的
文件会被静默跳过。`Ctrl/Cmd+Shift+T` 可重开最近关闭的标签。

<a id="zh-keys"></a>

## 11. 完整快捷键表

| 操作 | Windows / Linux | macOS |
| --- | --- | --- |
| 命令面板 | `Ctrl+Shift+P` | `Cmd+Shift+P` |
| Goto Anything | `Ctrl+P` | `Cmd+P` |
| 跳转到符号 | `Ctrl+R` | `Cmd+R` |
| 跳转到行 | `Ctrl+G` | `Cmd+G` |
| 新建 / 打开文件 | `Ctrl+N` / `Ctrl+O` | `Cmd+N` / `Cmd+O` |
| 打开文件夹 | `Ctrl+Shift+O` | `Cmd+Shift+O` |
| 保存 / 另存为 | `Ctrl+S` / `Ctrl+Shift+S` | `Cmd+S` / `Cmd+Shift+S` |
| 关闭 / 重开标签 | `Ctrl+W` / `Ctrl+Shift+T` | `Cmd+W` / `Cmd+Shift+T` |
| 第 N / 下 / 上标签 | `Ctrl+1..9` / `Ctrl+Alt+←→` | `Cmd+1..9` / `Cmd+Alt+←→` |
| 查找 / 替换 | `Ctrl+F` / `Ctrl+H` | `Cmd+F` / `Cmd+H` |
| 查找下一个 | `F3` | `F3` |
| 加入下一个匹配 | `Ctrl+D` | `Cmd+D` |
| 上方 / 下方加光标 | `Ctrl+Alt+↑/↓` | `Cmd+Alt+↑/↓` |
| 选中所有匹配 | `Ctrl+Shift+L` | `Cmd+Shift+L` |
| 切换注释 | `Ctrl+/` | `Cmd+/` |
| 移动 / 复制行 | `Alt+↑↓` / `Shift+Alt+↑↓` | `Alt+↑↓` / `Shift+Alt+↑↓` |
| 复制 / 删除行 | `Ctrl+Shift+D` / `Ctrl+Shift+K` | `Cmd+Shift+D` / `Cmd+Shift+K` |
| 放大 / 缩小 / 复位字号 | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | `Cmd+=` / `Cmd+-` / `Cmd+0` |
| 显隐侧栏 / 换行 / 主题 | `Ctrl+B` / `Alt+Z` / `Ctrl+K` | `Cmd+B` / `Alt+Z` / `Cmd+K` |

<a id="zh-trouble"></a>

## 12. 故障排查

**切勿运行 `npm audit fix --force`。** 漏洞只在构建工具链；`--force` 会搞崩工具链（ERESOLVE、
`cac` 导出报错）。恢复：重新 `git clone`，或
`rm -rf node_modules package-lock.json && git checkout package.json package-lock.json && npm install`。

**macOS 提示“Electron.app 已损坏/含恶意软件”并移到废纸篓。** 这是未签名开发运行时的误报。恢复：

```bash
rm -rf node_modules/electron && export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ && npm install
xattr -cr node_modules/electron/dist/Electron.app
codesign --force --deep --sign - node_modules/electron/dist/Electron.app
npm run dev
```

或到 **系统设置 → 隐私与安全性 → 仍要打开** 放行。

**无显示器的 Linux：缺 `libgbm.so.1` / core dump。** Electron 需要显示服务与 GPU 库。安装后配
虚拟显示，或直接在有桌面的机器上运行：
`sudo apt-get install -y libgbm1 libwayland-server0 xvfb && xvfb-run -a npm run dev`。

**`npm install` 报缓存只读（`EROFS`）。** 指定可写缓存目录：
`npm install --cache /可写路径/.npm-cache`。
