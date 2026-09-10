# Lumen Editor 原生 macOS 功能对等清单

> 基线日期：2026-09-07；基线为当前未提交工作树，而不是某个已发布 commit。本清单按当前工作树逐文件实查，
> 包含尚未提交的 `native-macos/` 实现；状态变更时必须同时更新本清单与对应验收证据。

## 1. 使用方式与判定规则

本清单的对等基线是现有 Electron 桌面版，而不是 README 中的概括性功能列表。Electron 侧以
`COMMANDS`、原生菜单、`MenuEvent`、IPC 契约和 renderer 实际接线交叉确认。原生侧只有形成
“用户入口 → production controller/model → 可观察 UI 或 revision-checked transaction”的闭环才可标为
“已实现”；仅有类型、route 占位、Core 算法或测试不能据此升级状态。

状态含义：

- **已实现**：原生 App 有可到达入口和对应实现；仍可能因细节差异标为“部分”。
- **部分**：存在用户可用子集，但没有达到本行的 Electron 语义。
- **仅核心**：算法/存储模型及测试存在，但生产 App 未接入。
- **仅持久化**：设置值已有 UI/存储，但其所控制的功能尚未渲染或执行。
- **未实现**：原生生产代码中没有该能力。
- **已接入/待验证**：生产闭环已经存在，但依赖真实 macOS、外部工具、签名 Sandbox、网络或 GUI/VoiceOver
  的验收在本次 Linux 源码审计中不能执行；它不等于“仅核心”，也不宣称实机门禁已通过。
- **已配置/未完成**：仅用于构建发行项，表示入口已声明但缺少本环境或正式产物验证。
- **架构替代**：Electron 特有机制不应逐字移植，但必须通过列出的等价安全验收。

快捷键统一写成 macOS 表示。`面板提示` 表示只见于 `commands.ts` 的 hint 或 CodeMirror
键位、没有 Electron 菜单 accelerator；`role` 表示系统菜单角色而非 Lumen 命令 ID。

阶段沿用原生 README 的路线并细化依赖：

| 阶段 | 目标 | 主要前置依赖 |
| --- | --- | --- |
| P0 | 文件安全与恢复基线稳定化 | Core 编解码、原子写、session、真实 Mac 数据安全回归 |
| P1 | 日常纯文本编辑可用 | `CMD` 命令注册/校验、`TX` NSTextView 可撤销事务、`SET` 设置接入、`L10N` 本地化 |
| P2 | 标签/窗口/分栏、丰富编辑和导航 | P1、`SEL` 多选区模型、`GROUP` 编辑组/窗口状态、`PAL` 可访问面板 |
| P3 | 工作区、搜索、语言视图和预览 | P2、`WS` 多根工作区与授权、`INDEX` 有界索引、`PREVIEW` 安全渲染 |
| P4 | Git、终端、Build、LSP、插件 | P3、`PROC` 外部进程代理、`TRUST` 每会话确认、`EXT` 扩展沙箱 |
| P5 | 发行候选 | 前述阶段、`A11Y` UI/VoiceOver 自动化、`DIST` 签名/公证/升级流水线 |

清单覆盖统计（不含说明/风险表）：

| 领域 | 条目数 | 领域 | 条目数 |
| --- | ---: | --- | ---: |
| 文件 F | 23 | 标签 T | 11 |
| 窗口 WN | 4 | 分栏 SP | 11 |
| 编辑 E | 43 | 选区 S | 19 |
| 搜索 Q | 13 | 导航 N | 20 |
| 预览/视图 V | 30 | 工作区 W | 19 |
| Git G | 15 | Terminal TM | 4 |
| Build B | 8 | LSP L | 13 |
| 插件 P | 10 | 宏 M | 4 |
| 设置 C | 15 | 会话 H | 15 |
| i18n I | 5 | Accessibility A | 10 |
| Security SEC | 13 | Release R | 14 |
| **合计** | **319** |  |  |

命令覆盖审计：Electron `COMMANDS` 有 **167 个声明、167 个唯一 ID**，均至少有一个独立验收行。
`MenuEvent` union 有 **172 个声明分支、171 个唯一 ID**；差值来自 `import-sublime-build` 重复声明。
相对 `COMMANDS` 多出的唯一 ID 是 `command-palette`、`select-build-system`、`encoding-actions`、
`persist-session`。Native public catalog 是 **169 个唯一 ID**（167 + 前两个 public menu command），
`encoding-actions` 与 `persist-session` 分别是 Electron 聚合 UI 事件和关闭握手，不进入 native public catalog。
171 个唯一 `MenuEvent` 均由 Electron `App.run` 的 171 个唯一 case 覆盖，也均由矩阵行覆盖。跨语言 Node 门禁
直接差分上述集合、native catalog、菜单 accelerator、实际 SwiftUI 菜单 surface、`src/shared/i18n.ts` 与 Swift `Localization` 的
**108** 个共享键和双语值、Electron/native 的 **81** 项文件关联扩展名、设置 schema v2 与默认 **200 MiB**
文件上限、两端的多文件打开契约，以及矩阵领域统计；生产 `EditorWindowComposition` 当前为
169/169 public ID 注册 route。静态清单只证明声明/入口集合闭合，production route 测试只证明可路由；两者都不代替逐命令 UI/事务效果验收。系统 role、文件树/面板按钮、拖放、
监听等无 ID 入口仍另列。

### 证据索引

Electron 基线：

- `E-CMD`：[命令面板清单](../src/renderer/src/commands.ts#L22)；`E-MENU`：[原生菜单](../src/main/menu.ts#L42)；
  `E-EVENT`：[MenuEvent 全集](../src/shared/ipc.ts#L858)；`E-DISPATCH`：[统一执行器](../src/renderer/src/main.ts#L689)。
- `E-IPC`：[IPC 契约](../src/shared/ipc.ts#L7)；`E-BRIDGE`：[类型化 preload](../src/preload/index.ts#L59)；
  `E-FS`：[主进程文件/进程 handlers](../src/main/files.ts#L3497)。
- `E-EDIT`：[CodeMirror 封装](../src/renderer/src/editor.ts#L260)；`E-TREE`：[文件树](../src/renderer/src/fileTree.ts#L29)；
  `E-SEARCH`：[工作区搜索](../src/renderer/src/workspaceSearch.ts#L32)；`E-NAV`：[导航历史](../src/renderer/src/navigationHistory.ts#L35)。
- `E-PREVIEW`：[Markdown 预览](../src/renderer/src/preview.ts#L8)；`E-JSON`：[JSON 视图](../src/renderer/src/jsonView.ts#L1)；
  `E-GIT`：[Git 面板](../src/renderer/src/gitPanel.ts#L26)；`E-BUILD`：[Build 面板](../src/renderer/src/buildPanel.ts#L15)；
  `E-TERM`：[Terminal 面板](../src/renderer/src/terminalPanel.ts#L14)；`E-LSP`：[LSP 面板](../src/renderer/src/languageServerPanel.ts#L64)。
- `E-SET`：[Settings 类型/默认值](../src/shared/ipc.ts#L498)；`E-SETUI`：[设置面板](../src/renderer/src/settingsPanel.ts#L14)；
  `E-SHELL`：[窗口与安全策略](../src/main/index.ts#L127)；`E-PACK`：[打包配置](../electron-builder.yml#L1)；
  `E-RELEASE`：[正式发布流水线](../.github/workflows/release.yml#L18)。
- 用户可见语义：[中文 README](../README.zh-CN.md#功能特性) 与 [双语用户指南](./USER_GUIDE.md)。

原生现状：

- `N-APP`：[应用/多窗口组合入口](../native-macos/Sources/LumenEditorApp/LumenEditorApplication.swift#L3)；
  `N-CMD`：[原生菜单](../native-macos/Sources/LumenEditorApp/EditorCommands.swift#L4)；
  `N-ROUTER`：[统一 command router](../native-macos/Sources/LumenEditorApp/CommandRouter.swift#L158)；
  `N-COVER`：[169/169 production route 覆盖测试](../native-macos/Tests/LumenEditorAppTests/ProductionCommandCoverageTests.swift#L8)；
  `N-ACT`：[文件面板与交互编排](../native-macos/Sources/LumenEditorApp/EditorActionController.swift#L19)。
- `N-MODEL`：[文档生命周期](../native-macos/Sources/LumenEditorApp/AppModel.swift#L34)；
  `N-DOC`：[标签/脏状态模型](../native-macos/Sources/LumenEditorApp/EditorDocument.swift#L45)；
  `N-VIEW`：[窗口与 panel 组合](../native-macos/Sources/LumenEditorApp/EditorWindowView.swift#L5)；
  `N-PANE`：[1/2/3/4 pane、tab 与 editor 接线](../native-macos/Sources/LumenEditorApp/EditorPaneView.swift#L4)；
  `N-TEXT`：[NSTextView/TextKit 1、多选区和事务适配](../native-macos/Sources/LumenEditorApp/NativeTextEditor.swift#L4)。
- `N-CODEC`：[编码与文件策略](../native-macos/Sources/LumenEditorCore/TextFileCodec.swift#L30)；
  `N-WRITE`：[revision/原子写](../native-macos/Sources/LumenEditorCore/AtomicFileWriter.swift#L31)；
  `N-SESSION`：[热退出存储](../native-macos/Sources/LumenEditorCore/SessionStore.swift#L15)；
  `N-RECENT`：[最近文件/项目及窗口 registry](../native-macos/Sources/LumenEditorCore/RecentItemsStore.swift#L3)。
- `N-NAV`：[导航 controller 与 production adapters](../native-macos/Sources/LumenEditorApp/NavigationController.swift#L304)；
  `N-FIND`：[文档查找 controller](../native-macos/Sources/LumenEditorApp/FindBarController.swift#L118)；
  `N-SET`：[设置模型](../native-macos/Sources/LumenEditorCore/EditorSettings.swift#L26)；
  `N-SETSTORE`：[已接 App 的设置存储](../native-macos/Sources/LumenEditorCore/SettingsStore.swift#L14)；
  `N-SETAPP`：[设置控制器](../native-macos/Sources/LumenEditorApp/SettingsController.swift#L12) 与
  [设置界面](../native-macos/Sources/LumenEditorApp/SettingsView.swift#L4)。
- `N-CATALOG`：[169 项 public 命令目录、快捷键与上下文模型](../native-macos/Sources/LumenEditorCore/CommandCatalog.swift#L317)，
  [catalog 测试](../native-macos/Tests/LumenEditorCoreTests/CommandCatalogTests.swift#L5)；
  `N-EDITCMD`：[编辑/选区 planner 与 production transaction controller](../native-macos/Sources/LumenEditorApp/EditorCommandController.swift#L27)；
  `N-TRANSFORM`：[文本变换 Core](../native-macos/Sources/LumenEditorCore/TextTransforms.swift#L168)。
- `N-WS`：[多根工作区服务](../native-macos/Sources/LumenEditorCore/WorkspaceService.swift#L227)、
  [production controller](../native-macos/Sources/LumenEditorApp/WorkspaceController.swift#L18) 与
  [侧栏 UI](../native-macos/Sources/LumenEditorApp/WorkspaceSidebarView.swift#L54)；
  `N-WATCH`：[递归 FSEvents watcher](../native-macos/Sources/LumenEditorApp/WorkspaceFileWatcher.swift#L36)；
  `N-WSEARCH`：[工作区查找/替换 controller](../native-macos/Sources/LumenEditorApp/WorkspaceSearchController.swift#L13)。
- `N-WSESSION`：[v2 窗口/布局 session schema、v1 迁移与多窗口协调](../native-macos/Sources/LumenEditorCore/WindowSession.swift#L454)，
  [window-session 测试](../native-macos/Tests/LumenEditorCoreTests/WindowSessionTests.swift#L5)。
- `N-PARSER`：[CodeMirror parser bundle 入口](../native-macos/ParserBundle/CodeMirrorParserEntry.js)、
  [每请求独立 parser worker](../native-macos/Sources/LumenParserWorker/main.swift)、
  [typed bridge 与验证](../native-macos/Sources/LumenEditorApp/CodeMirrorParserModels.swift)及
  [revision cache](../native-macos/Sources/LumenEditorApp/CodeMirrorParserCoordinator.swift)；cache identity 包含 revision、
  精确 UTF-16 文本、语言、tab/indent/insert-spaces 设置与 newline-probe 位置。基础分析立即启动，只有光标相关 probe
  使用 120ms 可取消 debounce；取消 waiter 仅在其为最后一个 waiter 时取消共享工作。production 请求通过
  `ToolProcessRunner` 施加 1 秒硬超时并回收 worker，进程内 JavaScriptCore 仅保留为测试 seam。
  `N-TX`：[已接 production editor 的 UTF-16 多选区/原子事务/多视图 undo](../native-macos/Sources/LumenEditorCore/EditorTransaction.swift#L14)，
  [事务测试](../native-macos/Tests/LumenEditorCoreTests/EditorTransactionTests.swift#L4)；
  `N-SYNTAX`：[有界 lexical highlighter](../native-macos/Sources/LumenEditorApp/NativeSyntaxHighlighter.swift#L3)；
  `N-RECT`：[矩形选择 visual-column planner](../native-macos/Sources/LumenEditorApp/RectangularSelectionPlanner.swift#L3)。
- `N-PREVIEW`：[原生预览控制器及生产事务适配](../native-macos/Sources/LumenEditorApp/PreviewController.swift#L453)；
  `N-JSON`：[可编辑 JSON 树](../native-macos/Sources/LumenEditorApp/JSONTreeView.swift#L405) 与
  [控制器测试](../native-macos/Tests/LumenEditorAppTests/PreviewControllerTests.swift#L158)。
- `N-TOOLS`：[Git](../native-macos/Sources/LumenEditorApp/GitController.swift#L86)、
  [Build](../native-macos/Sources/LumenEditorApp/BuildController.swift#L388)、
  [Terminal](../native-macos/Sources/LumenEditorApp/TerminalController.swift#L17) 与
  [LSP](../native-macos/Sources/LumenEditorApp/LanguageServerController.swift#L64) production controllers；
  `N-PROC`：[外部进程校验、配额与回收](../native-macos/Sources/LumenEditorCore/ToolProcessRunner.swift#L104)；
  `N-PLUGIN`：[插件 production controller](../native-macos/Sources/LumenEditorApp/PluginController.swift#L29) 与
  [独立 worker runtime](../native-macos/Sources/LumenEditorApp/PluginWorkerRuntimeController.swift#L12)。
- `N-L10N`：[runtime locale environment](../native-macos/Sources/LumenEditorApp/AppLocalization.swift#L8) 与
  [双语 typed catalog](../native-macos/Sources/LumenEditorCore/Localization.swift#L3)；
  `N-A11Y`：[共享辅助功能支持](../native-macos/Sources/LumenEditorApp/AccessibilitySupport.swift#L3)。
- `N-PKG`：[Swift Package](../native-macos/Package.swift#L1)；`N-PLIST`：[bundle 元数据](../native-macos/Packaging/Info.plist#L1)；
  `N-CI`：[独立 CI](../.github/workflows/native-macos.yml#L1)；`N-BUNDLE`：[本地 app 组装](../native-macos/scripts/build-app.sh#L1)；
  `N-DIST`：[Developer ID、公证、DMG/ZIP 脚本](../native-macos/scripts/package-release.sh#L1) 与
  [tag release wiring](../.github/workflows/release.yml#L108)。
- `N-ACCEPT`：[版本化真机验收用例与证据格式](./NATIVE_MACOS_ACCEPTANCE.md)，覆盖安装/quarantine、
  APFS 与 bookmark、IME/Unicode、多窗口、VoiceOver、Sandbox 进程、Git、升级和回退。

本轮在 Linux 上完成的是源码接线与测试证据审计，不能运行 AppKit/SwiftUI、FSEvents、VoiceOver、App Sandbox、
Developer ID 或 notarytool 实机流程。矩阵中相应能力即使已有 production 闭环，也明确保留“待真实 macOS/签名
Sandbox/GUI 验证”。`N-PARSER` 当前覆盖 language-data 的全部 **143** 种语言：**33** 种 Lezer 语言提供完整
结构快照，**110** 种 Stream 语言提供高亮和可用缩进；后者的结构选择、outline、折叠等仍使用保守 fallback，
因此不宣称整个 language-data 集合都具备 AST 等价。production parser 已隔离到每请求新建的
`LumenParserWorker`，由专用的有界 `ToolProcessRunner` 在 1 秒硬超时后终止；不同 revision 的并发分析受限，
过期/无人等待的任务会取消，窗口 teardown 会等待 worker 回收。helper 的 Sandbox/inherit entitlement、打包、
签名检查及签名后 parser smoke 已接入，但仍保留真实用户交互和压力验证门禁。

## 2. 文件生命周期与磁盘格式

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| F01 新建递增命名的未命名文档 | `new-file` / `⌘N` | E-CMD 23；E-DISPATCH 705 | **已实现**：`AppModel.newDocument` 与 `EditorCommands`，N-MODEL 83、N-CMD 9 | 连续新建名称不冲突；新标签被选中；空草稿可安全关闭 | P0 / — |
| F02 文件选择器打开一个或多个文件并去重 | `open-file` / `⌘O` | E-CMD 24；E-FS 3497 | **已实现**：`NSOpenPanel` 明确允许多选、规范路径去重，并逐项安全授权/读取；Finder/LaunchServices 传入的多 URL 也完整保留；模型打开错误以 typed `AppModelIssue` 跨命令路由传递，N-ACT、N-APP | 多选均打开；重复路径（含 symlink 别名）只聚焦已有标签；取消无副作用；app-owned 打开错误可随 locale 重绘 | P0 / — |
| F03 按指定编码打开文件 | `open-file-with-encoding` / — | E-CMD 25；E-DISPATCH 760 | **已实现**：Open Using Encoding 菜单，N-CMD 22、N-ACT 105 | 每种支持编码可在首次读取前选择；取消不建立标签 | P0 / — |
| F04 Finder/argv 打开关联文件 | 无独立 ID / Finder Open With | E-SHELL 73、1979；E-PACK 13 | **已实现**：delegate 与 `.onOpenURL` 去重串行，N-APP 27、N-ACT 91 | 冷启动/运行中双击文件均打开；重复回调不重复建 tab；关联类型正确 | P0 / DIST |
| F05 拖放文件/文件夹 | 无独立 ID / 拖放 | E-BRIDGE 75；E-DISPATCH 660 | **已实现**：window drop modifier → `handleDroppedURLs` → 文件打开/首目录替换与后续目录追加，N-APP 554、`WorkspaceDropModifier.swift` | 拖入文件打开；首个目录替换 workspace、后续目录添加 root；拒绝/上限有反馈 | P3 / WS |
| F06 保存 | `save` / `⌘S` | E-CMD 30；E-FS 3658 | **已实现**：命名文件保存，未命名文件转 Save As；`AppModelIssue` 的 typed 标题、文件上下文及写入错误保持到菜单/键盘反馈边界，N-CMD 32、N-ACT 125 | 命名/未命名均正确；写入期间再次编辑仍保持 dirty；失败不改保存基线；运行时切换语言可重绘错误 | P0 / — |
| F07 另存为 | `save-as` / `⇧⌘S` | E-CMD 31；E-FS 3674 | **已实现**：与 F06 共用 typed command outcome，N-CMD 39、N-ACT 146 | 取消无副作用；成功后路径/名称/revision 更新；冲突或不可表示编码不覆盖目标 | P0 / — |
| F08 全部保存 | `save-all` / `⌥⌘S` | E-CMD 32；E-DISPATCH 4060 | **已实现**：逐个处理未命名目标，首个 typed AppModel/耐久性失败原样返回命令路由，N-CMD 45、N-ACT 159 | 仅 dirty 文档写盘；逐个询问未命名路径；任一步取消/失败停止且不丢其他草稿 | P0 / — |
| F09 选择下次保存编码 | `select-encoding` / — | E-CMD 34；E-DISPATCH 4527 | **已实现**：状态栏与 Document 菜单，N-VIEW 469、N-CMD 69 | 选择只改元数据并标脏，不立即重编码；保存后严格往返 | P0 / — |
| F10 按编码重新打开原始字节 | `reopen-with-encoding` / — | E-CMD 35；E-IPC 12 | **已实现**：有破坏性确认；成功或无效字节结果通过可关闭、按当前 locale 渲染的非阻塞 notice 反馈，N-ACT、N-MODEL、N-VIEW | dirty 时明确确认；从原始字节重读；取消保留文本/选区/dirty；无效字节时明确说明覆盖保存已禁用 | P0 / — |
| F11 选择下次保存行尾 | `select-line-ending` / — | E-CMD 33；E-DISPATCH 4487 | **已实现**：状态栏与 Document 菜单，N-VIEW 526、N-CMD 88 | LF/CRLF/CR 只改保存格式；保存后字节及状态正确 | P0 / — |
| F12 显式转换行尾 | `convert-eol-lf` / — | E-CMD 143；E-DISPATCH 932 | **已实现**：public catalog route 直达文档格式 controller/model，N-APP 939 | 命令可发现且只设 LF；一次撤销/脏状态与 Electron 一致 | P1 / CMD、TX |
| F13 显式转换行尾 | `convert-eol-crlf` / — | E-CMD 144；E-DISPATCH 935 | **已实现**：同 F12 | 同 F12，并验证混合行尾保存为 CRLF | P1 / CMD、TX |
| F14 显式转换行尾 | `convert-eol-cr` / — | E-CMD 145；E-DISPATCH 938 | **已实现**：同 F12 | 同 F12，并验证保存为单 CR | P1 / CMD、TX |
| F15 完整编码集合与无损写入拒绝 | 无独立 ID | E-IPC 127；E-FS 758 | **已实现**：12 个编码、严格 round-trip，N-CODEC 3、239 | UTF-8/BOM、UTF-16 LE/BE 含无 BOM、GB18030/GBK/Big5/Shift-JIS/1252/Latin-1 逐项读写；不可表示字符拒写 | P0 / 真实 Mac 编码回归 |
| F16 二进制和超大文件保护 | 无独立 ID | E-IPC 106；E-FS 87、758 | **已实现**：N-CODEC 31、325；原生新安装及未改动的 v1 preview 设置默认 200 MiB，仍可在 1–200 MiB 内明确配置 | 常规/二进制/边界前后文件均给出确定结果；拒绝项不分配大文本且不建可编辑 tab | P0 / — |
| F17 外部修改/删除/权限/类型冲突 | 无独立 ID | E-DISPATCH 2277、3737 | **已接入，待真实 macOS 文件系统验证**：2 秒活动态轮询 + FSEvents root invalidation 驱动冲突 banner/model；活动 clean 文档自动重载出无效字节时发布非阻塞双语警告，N-ACT、N-WATCH、N-VIEW | clean 自动刷新且无损解码失败有可见反馈；dirty 提供 Compare/Keep Local/Reload/Save As；删除、不可读、二进制、超大均保草稿 | P0 / 真实文件系统回归 |
| F18 乐观 revision、symlink/hard-link 与原子替换 | 无独立 ID | E-FS 733、974 | **已接入，待真实 APFS 验证**：双 revision 检查、symlink 目标复查、hard-link 拒绝与原子写，N-WRITE | 并发保存只有合法结果；不静默覆盖外改；断链/换链/硬链接安全失败；权限尽量保留 | P0 / 真实 APFS 回归 |
| F19 复制完整路径 | `copy-file-path` / — | E-CMD 26；E-IPC 22 | **已实现**：route 只写通用剪贴板，N-APP 949 | 标签/文件树入口仅写剪贴板；不得获得剪贴板读取权；无路径时有反馈 | P1 / CMD |
| F20 复制项目相对路径 | `copy-relative-file-path` / — | E-CMD 27；E-TREE 201 | **已实现**：route 校验 workspace，controller 选择最具体 root，N-APP 959、N-WS | 选最具体 workspace root；外部/未命名文件禁用或提示 | P3 / WS、CMD |
| F21 最近文件 | `open-recent-file` / — | E-CMD 28；E-IPC 40 | **已实现**：有界 recent store、恢复授权、picker、route 与 File 菜单的 Open Recent File… 入口已接 production，`RecentItemsController.swift`、N-CMD、N-VIEW | 菜单入口打开有界、去重、按最近时间排序的 picker；失效路径可移除；打开遵守编码/大小保护 | P1 / SET、CMD |
| F22 自动保存模式 | `cycle-auto-save` / — | E-CMD 124；E-SET 521 | **已实现**：`AutoSaveController.connected` 监听三态、延时/失焦并走安全保存路径；File 菜单与 route 均可达，N-APP、N-CMD、`AutoSaveController.swift` | off/延时/失焦三态；只保存有路径且无编码警告/外部冲突的 dirty 文档；错误可见 | P1 / 自动保存调度、CMD |
| F23 EditorConfig 解析与优先级 | 无独立 ID | E-IPC 15；E-FS 370 | **已实现**：workspace 授权内有界解析，打开/路径变化/FSEvents 均驱动 runtime 配置；Core 边界错误与 workspace capability 错误保留 typed payload，未知 resolver/POSIX 错误原文显示，`EditorConfigController.swift`、N-ACT、N-WATCH | 授权 root 内逐层解析 `root/unset/glob/indent_style/indent_size/tab_width/end_of_line`；有深度/字节预算；不因读取而标脏；运行中切换 locale 可重绘 app-owned 错误且不误翻译外部错误 | P3 / WS、SET |

## 3. 标签、窗口与分栏

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| T01 标签栏、活动标签、脏/冲突标识、单标签关闭 | `close-tab` / `⌘W` | E-CMD 37；E-DISPATCH 784 | **已实现**：横向标签栏、dirty 点、关闭确认，N-VIEW 186、N-MODEL 198 | 鼠标/键盘选择稳定；dirty 关闭 Save/Don’t Save/Cancel；冲突状态可辨识 | P0 / — |
| T02 固定/取消固定标签 | `toggle-pin-tab` / `⌥⌘P` | E-CMD 36；E-DISPATCH 4255 | **已实现**：tab UI/model/session 与 route 闭环，N-APP 915、N-PANE | 固定标签置前、跨重启保留、批量关闭跳过、单独关闭仍可用 | P2 / CMD、GROUP、session 扩展 |
| T03 关闭其他标签 | `close-other-tabs` / — | E-CMD 38；E-DISPATCH 4159 | **已接入，待 macOS GUI 验证**：安全批量关闭 flow 与 route；controller 测试覆盖多 dirty tab 在全部确认后才提交，N-APP 918、N-ACT | 逐个处理 dirty；固定标签保留；取消不产生半完成的破坏性批量操作 | P2 / CMD、T02 |
| T04 关闭右侧标签 | `close-tabs-to-right` / — | E-CMD 39；E-DISPATCH 4159 | **已接入，待 macOS GUI 验证**：同 T03，N-APP 921 | 以当前组顺序为准；固定标签保留；dirty 确认可取消 | P2 / CMD、T02 |
| T05 关闭全部标签 | `close-all-tabs` / — | E-CMD 40；E-DISPATCH 4159 | **已接入，待 macOS GUI 验证**：同 T03；controller 测试覆盖取消不部分关闭且固定标签保留，N-APP 924 | 固定标签保留；其他标签安全关闭；至少保留一个空文档的产品规则一致 | P2 / CMD、T02 |
| T06 重开最近关闭标签 | `reopen-tab` / `⇧⌘T` | E-CMD 41；E-DISPATCH 4241 | **已实现**：有界 LIFO、route 与授权重开 flow，N-APP 927、N-ACT | 按 Electron 基线以 LIFO 恢复路径，并在当前活动组打开；不可读文件有明确反馈；不恢复已明确丢弃的未命名秘密草稿 | P2 / CMD、recent-tab 模型 |
| T07 下一标签 | `next-tab` / `⌥⌘→` | E-CMD 169；E-MENU 200 | **已实现**：当前 pane 循环并由 UI 观察，N-APP 1022、N-MODEL | 当前编辑组内循环、聚焦编辑器、状态栏同步 | P1 / CMD |
| T08 上一标签 | `prev-tab` / `⌥⌘←` | E-CMD 170；E-MENU 201 | **已实现**：同 T07，N-APP 1025 | 与 T07 反向且循环边界一致 | P1 / CMD |
| T09 第 1…9 个标签 | 无命令 ID / `⌘1…⌘9` | E-DISPATCH 1320 | **已实现**：keyboard controller 发编号通知，窗口按当前 pane 选择，N-ROUTER 595、N-VIEW 86 | 仅切当前组对应标签；越界不动作；不与系统菜单冲突 | P1 / CMD |
| T10 标签拖拽排序 | 无命令 ID / 拖放 | E-DISPATCH 1477、5707 | **已实现**：tab drag/drop → `AppModel.reorderTabs` → session，N-PANE 420、N-MODEL 793 | 单标签排序跨重启保留；拖放取消不改顺序 | P2 / GROUP、session 扩展 |
| T11 多选标签块排序 | 无命令 ID / `⌘`+点击后拖放 | E-DISPATCH 1528、5707 | **已实现**：command-click selection 与稳定 block reorder，N-PANE 218、`PaneLayout.swift` 703 | 多选集合按原相对顺序作为块移动；选择态和活动 tab 可预测 | P2 / GROUP、SEL |
| WN01 新窗口 | `new-window` / `⇧⌘N`（菜单；面板无 hint） | E-CMD 179；E-IPC 96 | **已实现**：value-based `WindowGroup`、每窗口 composition/session 及 `openWindow(value:)`，N-APP、`WindowSessionCoordinator.swift` | 可建立独立窗口/session；无共享 mutable UI 状态竞态；关闭一窗不丢其他窗草稿 | P2 / GROUP、session 多窗口化 |
| WN02 标准窗口操作 | 无 ID，macOS `role` | E-MENU 313 | **已接入，待 AppKit GUI 验证**：自定义 Window 菜单项调用标准 AppKit Minimize/Zoom/Bring All to Front actions；Full Screen 使用 `NSWindow.toggleFullScreen(_:)`、`⌃⌘F` 与 AppKit menu validation；Linux 未验证最终菜单布局和行为 | 菜单含 Minimize/Zoom/Bring All to Front/Full Screen，标准快捷键和 enablement 正确 | P1 / CMD、GUI 测试 |
| WN03 About/Services/Hide/Quit 菜单 | 无 ID，macOS `role` | E-MENU 53 | **部分，待打包实机验证**：系统 About/Services/Hide/Quit 存在，Quit 已过 dirty review；runtime i18n/metadata 仍有混合语言边界 | About 版本准确；Services/Hide/Hide Others/Quit 正常；Quit 必经所有 dirty tab 审查 | P1 / L10N、DIST |
| WN04 窗口关闭与应用退出安全流 | 内部 `persist-session` / — | E-SHELL 94、2025 | **已实现，待 AppKit GUI 验证**：红按钮与退出均异步逐标签审查；进入审查即冻结文本与自动保存，取消时恢复；单窗关闭以 live backup + projected sidecar + marker 跨越 AppKit close 边界，只有 `windowWillClose` 才消费工件，提前崩溃会恢复 dirty live generation；应用退出使用全窗口 prepare/validate/commit 与独立 participant manifest，Discard 在所有窗口确认前只记录 document ID+revision，损坏 marker 或参与者缺失均 fail closed，N-ACT、N-APP delegate | 多 dirty tab 的 Save/Discard/Cancel 无数据丢失；保存途中编辑不可被关闭；单窗与全局退出的断点崩溃均只恢复完整一代 | P0 / GUI/真实 Mac 回归 |
| SP01 单编辑组布局 | `layout-single` / — | E-CMD 171；E-DISPATCH 1392 | **已实现**：四布局 model/UI 可收敛并持久，N-APP 990、N-PANE | 有布局命令；从多组切回时不丢标签/视图；session 恢复 | P2 / GROUP |
| SP02 两列布局 | `layout-columns2` / — | E-CMD 172；E-DISPATCH 1392 | **已实现**：独立 pane/viewID，N-APP 993、N-PANE | 两个独立可聚焦编辑组，可同时显示同/不同文档 | P2 / GROUP |
| SP03 三列布局 | `layout-columns3` / — | E-CMD 173；E-DISPATCH 1392 | **已实现**：N-APP 996、N-PANE | 三列尺寸/焦点/标签归属及恢复正确 | P2 / GROUP |
| SP04 四宫格布局 | `layout-grid4` / — | E-CMD 174；E-DISPATCH 1392 | **已实现**：N-APP 999、N-PANE | 2×2 布局、窗口缩放、焦点和恢复正确 | P2 / GROUP |
| SP05 切换单组/两列 | `split-editor` / `⌥⌘2` | E-CMD 113；E-DISPATCH 4317 | **已实现**：N-APP 1002、N-MODEL | 在 single/columns2 间稳定切换；活动文档和状态不丢失 | P2 / GROUP、CMD |
| SP06 将所选标签拆为组 | `split-selected-tabs` / — | E-CMD 114；E-DISPATCH 1533 | **已实现**：多选 tab 拆分，不足时 clone，N-APP 1005 | 2–4 个选中标签分别进入组；不足两个时遵循克隆规则 | P2 / GROUP、T11 |
| SP07 当前文件移动到下一组 | `move-file-next-group` / — | E-CMD 175；E-DISPATCH 1501 | **已实现**：N-APP 1010、N-MODEL | 源组移除、目标组选中；内容/undo/selection/scroll 不丢 | P2 / GROUP |
| SP08 当前文件克隆到下一组 | `clone-file-next-group` / — | E-CMD 176；E-DISPATCH 1501 | **已实现**：共享 document、独立 view state，N-APP 1013、N-MODEL | 两组共享文档内容但保留独立 selection/scroll/fold/undo 视图 | P2 / GROUP |
| SP09 聚焦下一组 | `focus-next-group` / `⌥⌘]` | E-CMD 177；E-MENU 231 | **已实现**：N-APP 1016、N-PANE | 循环聚焦并恢复该组活动 tab/编辑器焦点 | P2 / GROUP、CMD |
| SP10 聚焦上一组 | `focus-prev-group` / `⌥⌘[` | E-CMD 178；E-MENU 232 | **已实现**：N-APP 1019、N-PANE | 与 SP09 反向，单组时无副作用 | P2 / GROUP、CMD |
| SP11 每组独立视图状态 | 无独立 ID | E-EDIT 421；E-IPC 602 | **已实现**：viewID-scoped SelectionSet/scroll/fold 进入 v2 session，N-PANE 599、N-WSESSION | 每组多选区、主选区、横纵滚动及 fold 在本次运行保留；session 恢复 Electron 已承诺的 selection/scroll | P2 / GROUP、SEL、session 扩展 |

## 4. 基础编辑与文本变换

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| E01 纯文本输入、IME、Unicode、撤销管理 | 无 Lumen ID；系统 `⌘Z/⇧⌘Z` | E-EDIT 260 | **已接入，待真实 macOS IME/GUI 验证**：AppKit 输入变为 revision-checked `TextTransaction`，document buffer 统一 undo，N-TEXT 948、N-TX、N-MODEL | 中英文 IME、组合字符、emoji、长行输入稳定；每标签 undo 隔离；切 tab 不清历史 | P1 / TX 接线、真实 Mac GUI |
| E02 撤销 | 无 ID，Electron `undo` role / `⌘Z` | E-MENU 108 | **已实现**：显式菜单状态 → document buffer undo，N-CMD 71、N-MODEL | 菜单状态、键盘与编辑器 responder 一致；程序化变换每次只占一个 undo step | P1 / TX、CMD |
| E03 重做 | 无 ID，Electron `redo` role / `⇧⌘Z` | E-MENU 109 | **已实现**：同 E02 | 与 E02 成对；tab 切换后仍作用于正确文档 | P1 / TX、CMD |
| E04 剪切 | 无 ID，Electron `cut` role / `⌘X` | E-MENU 111 | **已接入，待 macOS GUI 验证**：AppKit responder + 多范围 transaction adapter，N-TEXT | 单/多选区语义、菜单 enablement、富文本不渗入纯文本 | P1 / SEL |
| E05 复制 | 无 ID，Electron `copy` role / `⌘C` | E-MENU 112 | **已接入，待 macOS GUI 验证**：AppKit responder + production `selectedRanges`，N-TEXT | 复制精确 Unicode 文本；无选区行为符合 macOS 约定 | P1 / SEL |
| E06 粘贴 | 无 ID，Electron `paste` role / `⌘V` | E-MENU 113 | **已接入，待 macOS GUI 验证**：纯文本、多范围 edit 合并为单 transaction，N-TEXT 948 | 只粘纯文本；多光标分发及一次撤销在 SEL 完成后验收 | P1 / TX；P2 / SEL |
| E07 全选 | 无 ID，Electron `selectAll` role / `⌘A` | E-MENU 114 | **已接入，待 macOS GUI 验证**：AppKit responder 与 SelectionSet 双向同步，N-TEXT | 全文选择、状态栏长度和后续编辑正确 | P1 / — |
| E08 切换行注释 | `toggle-comment` / `⌘/` | E-CMD 64；E-EDIT 621 | **已实现**：language-aware planner → 单 transaction，N-EDITCMD、N-TX | 按语言注释符处理单/多选区；一次撤销；未知语言有明确行为 | P2 / TX、SEL、语言层 |
| E09 切换块注释 | `toggle-block-comment` / `⇧⌘/` | E-CMD 65；E-EDIT 624 | **已实现**：同 E08 | 语言支持时成对包裹/解除；多选区、嵌套和无语法时安全 | P2 / TX、SEL、语言层 |
| E10 上移行 | `move-line-up` / `⌥↑` | E-CMD 81；E-EDIT 574 | **已实现**：N-EDITCMD、N-TX | 选区覆盖行整体上移，多光标去重，首行 no-op，可一次撤销 | P1 / TX、SEL |
| E11 下移行 | `move-line-down` / `⌥↓` | E-CMD 82；E-EDIT 577 | **已实现**：N-EDITCMD、N-TX | 与 E10 对称，末行 no-op，末尾换行保持 | P1 / TX、SEL |
| E12 向上复制行 | `copy-line-up` / `⇧⌥↑` | E-CMD 83；E-EDIT 580 | **已实现**：N-EDITCMD、N-TX | 多行/多选区复制位置、选择映射和一次撤销对等 | P1 / TX、SEL |
| E13 向下复制行 | `copy-line-down` / `⇧⌥↓` | E-CMD 84；E-EDIT 583 | **已实现**：N-EDITCMD、N-TX | 与 E12 对称，EOF/末尾换行边界覆盖 | P1 / TX、SEL |
| E14 复制行或选区 | `duplicate-selection` / `⇧⌘D` | E-CMD 85；E-EDIT 789 | **已实现**：N-EDITCMD、N-TX | 空选区复制整行；非空选区各自复制；保留方向/主选区 | P1 / TX、SEL |
| E15 删除行 | `delete-line` / `⇧⌘K` | E-CMD 86；E-EDIT 586 | **已实现**：N-EDITCMD、N-TX | 多选区覆盖行只删一次；首尾/空文档行为一致；一次撤销 | P1 / TX、SEL |
| E16 删除前一个词 | `delete-word-backward` / `⌥⌫`（面板提示） | E-CMD 87；E-EDIT 589 | **已实现**：public route 与 Unicode/多选 planner，N-EDITCMD | 文本选择优先；多光标按编辑器词组边界；菜单/命令面板可调用 | P1 / CMD、SEL |
| E17 删除后一个词 | `delete-word-forward` / `⌥⌦`（面板提示） | E-CMD 88；E-EDIT 590 | **已实现**：同 E16 | 与 E16 对称，标点/Unicode/行边界一致 | P1 / CMD、SEL |
| E18 删除至行首 | `delete-to-line-start` / `⇧⌘⌫` | E-CMD 89；E-EDIT 591 | **已实现**：N-EDITCMD、N-TX | 有选区先删选区；在行首删除前一换行；多光标一次撤销 | P1 / TX、CMD、SEL |
| E19 删除至行尾 | `delete-to-line-end` / `⇧⌘⌦` | E-CMD 90；E-EDIT 592 | **已实现**：N-EDITCMD、N-TX | 有选区先删选区；在行尾删除后一换行；多光标一次撤销 | P1 / TX、CMD、SEL |
| E20 上方插入空行 | `insert-blank-line-above` / `⇧⌘↩` | E-CMD 91；E-EDIT 594 | **已实现**：N-EDITCMD、N-TX | 不拆当前行；复制前导缩进；同一行多光标只插一次；一次撤销 | P1 / TX、SEL |
| E21 下方插入空行 | `insert-blank-line` / `⌘↩` | E-CMD 92；E-EDIT 615 | **已实现**：language profile + 多选 planner，N-EDITCMD、N-TX | 使用语言缩进规则；每个光标生效；不拆当前行；一次撤销 | P1 / TX、SEL、语言层 |
| E22 转置相邻字符 | `transpose-characters` / `⌃T` | E-CMD 93；E-EDIT 618 | **已实现**：Unicode 字素 planner + public route，N-EDITCMD | 按 Unicode 字素交换；行首等无效位置 no-op；命令面板/菜单一致；一次撤销 | P1 / CMD、TX |
| E23 升序排列行 | `sort-lines` / — | E-CMD 94；`lineTransforms.ts` 119 | **已实现**：Core plan 经 production controller 单事务提交，N-TRANSFORM、N-EDITCMD | 每个非空选区扩展到物理行；无选区处理全文；稳定排序、选择映射、尾 LF 保持 | P2 / TX、SEL |
| E24 降序排列行 | `sort-lines-descending` / — | E-CMD 95；`lineTransforms.ts` 123 | **已实现**：同 E23 | 与 E23 相同但反序；相等行保持稳定 | P2 / TX、SEL |
| E25 反转行 | `reverse-lines` / — | E-CMD 96；`lineTransforms.ts` 127 | **已实现**：同 E23 | 不相邻块独立反转；重叠块去重；选区方向/末尾 LF 保持 | P2 / TX、SEL |
| E26 删除重复行 | `unique-lines` / — | E-CMD 97；`lineTransforms.ts` 132 | **已实现**：同 E23 | 按完整行精确匹配、稳定保留第一次；被删行位置映射到保留行 | P2 / TX、SEL |
| E27 删除空白行 | `remove-blank-lines` / — | E-CMD 98；`lineTransforms.ts` 137 | **已实现**：同 E23 | 只删空或空格/Tab 行；全删得到空文档；保持其余尾 LF | P2 / TX、SEL |
| E28 大写转换 | `to-upper-case` / — | E-CMD 146；E-EDIT 1045 | **已实现**：case plan 经 production controller 单事务提交，N-TRANSFORM、N-EDITCMD | 每个非空选区独立；无选区处理全文；Unicode、方向/范围、一次撤销正确 | P1 / TX、SEL |
| E29 小写转换 | `to-lower-case` / — | E-CMD 147；E-EDIT 1045 | **已实现**：同 E28 | 同 E28，覆盖 Unicode 扩展/收缩映射 | P1 / TX、SEL |
| E30 标题式转换 | `to-title-case` / — | E-CMD 148；`caseTransforms.ts` 9 | **已实现**：同 E28 | Electron 的按词标题式语义、Unicode 与多选区映射一致 | P1 / TX、SEL |
| E31 交换大小写 | `swap-case` / — | E-CMD 149；`caseTransforms.ts` 9 | **已实现**：同 E28 | 逐 Unicode 字符切换；titlecase→lower；无大小写字符不变 | P1 / TX、SEL |
| E32 合并行 | `join-lines` / — | E-CMD 150；E-EDIT 1061 | **已实现**：N-EDITCMD、N-TX | 去掉换行及两侧空白；多块独立、重叠去重；无下一行时提示 | P2 / TX、SEL |
| E33 80 列硬换行重排段落 | `wrap-paragraph-80` / `⌥Q` | E-CMD 151；`paragraphTransforms.ts` 1 | **已实现**：paragraph plan 经 production controller 单事务提交，N-TRANSFORM、N-EDITCMD | Unicode 字素+Tab stop 计宽；保留缩进及 `#`/`//`/`///`；长 token 不拆；多区映射 | P2 / TX、SEL |
| E34 取消段落硬换行 | `unwrap-paragraph` / — | E-CMD 152；E-EDIT 859 | **已实现**：同 E33 | 与 E33 使用相同段落边界；规范段内空白；一次撤销 | P2 / TX、SEL |
| E35 清理行尾空白 | `trim-trailing-whitespace` / — | E-CMD 139；E-EDIT 1030 | **已实现**：N-EDITCMD、N-TX | 只删每行末尾空格/Tab；选择映射且一次撤销；EOL 保存规则不变 | P1 / TX |
| E36 保证单个末尾换行 | `ensure-single-final-newline` / — | E-CMD 140；`finalNewline.ts` 16 | **已实现**：Core plan 经 production controller 单事务提交，N-TRANSFORM、N-EDITCMD | 空文档不变；0 个补 1 个、多个收敛为 1 个；不删末行空白；UTF-16 选择映射；一次撤销 | P1 / TX、SEL |
| E37 转换缩进为空格 | `convert-indent-spaces` / — | E-CMD 141；E-EDIT 1034 | **已实现**：N-EDITCMD、runtime tab width、N-TX | 只转换行首；按 tab width 保持视觉列；一次撤销 | P1 / TX、SET |
| E38 转换缩进为 Tab | `convert-indent-tabs` / — | E-CMD 142；E-EDIT 1034 | **已实现**：同 E37 | 完整 tab stop 转 Tab、余数保留空格；正文中间空白不变 | P1 / TX、SET |
| E39 手工增加缩进 | `indent-selection` / `⌘]`（菜单；面板无 hint） | E-CMD 153；E-MENU 146 | **已实现**：统一 route 使用 runtime tab/space 设置与多选事务，N-EDITCMD | 依据 tabSize/insertSpaces 对所有选中行缩进；命令面板、菜单、快捷键一致 | P1 / CMD、SET、SEL |
| E40 手工减少缩进 | `outdent-selection` / `⌘[`（菜单；面板无 hint） | E-CMD 154；E-MENU 147 | **已实现**：同 E39 | 与 E39 对称；不足一级安全移除；多选区不重复 | P1 / CMD、SET、SEL |
| E41 按本地语法重新缩进 | `reindent-selection` / `⌥⌘\` | E-CMD 155；E-EDIT 1173 | **已实现（143 种语言均已登记）**：命令异步预热 exact-revision cache；33 种 Lezer 语言使用语法 indentation service，110 种 Stream 语言使用 mode 提供的 indentation answer，逐行生成单事务；没有 answer 的行保持不变，超预算/解析失败时使用有界 lexical fallback，N-PARSER、N-EDITCMD | 使用当前语言可用的本地缩进规则，不启动外部进程；无规则时 no-op+提示；不宣称每种语言的每一行都有 mode answer | P3 / 语言层、TX、SEL |
| E42 基于保存基线还原当前改动 | `revert-current-change` / — | E-CMD 62；E-DISPATCH 2249 | **已实现**：增量 diff controller → revision-checked transaction → gutter/UI，且菜单入口与 route 共用同一执行路径，`IncrementalDiffController.swift`、N-CMD、N-PANE | gutter 当前 hunk 精确还原；选择映射；外部冲突时不错误套用旧基线；菜单可达 | P2 / diff core、TX |
| E43 文档统计 | `document-statistics` / — | E-CMD 136；E-DISPATCH 2520 | **已实现**：route 计算全文/主选区并呈现结果，N-APP 1211、N-TRANSFORM | 全文/主选区分别给出行、字素、非空白、词/标记；CJK/组合字符/emoji 与 Electron 分词一致且只读 | P1 / CMD |

## 5. 选区与多光标

> 当前 production editor 使用 `SelectionSet` 与 AppKit `selectedRanges` 双向同步，保留 main index 与逐范围方向；
> 矩形手势生成 `SelectionSet`，普通输入和编辑命令再提交 revision-checked `TextTransaction`。33 种 Lezer 语言
> 使用 exact-revision 完整结构快照；110 种 Stream 语言保留高亮与 mode 缩进，但结构选择、括号、outline、
> 折叠等使用保守的有界 fallback；超预算或解析失败也 fail closed 到 fallback。

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| S01 单选区/光标双向同步和恢复 | 无独立 ID | E-IPC 602；E-EDIT 392 | **已实现**：directed `SelectionSet` ↔ `selectedRanges`、revision mapping 与 pane/session 恢复；键盘扩选、鼠标反向拖选及从相反端重建相同范围均保留或更新 anchor，多选区共享端点按 range 身份稳定配对，N-TEXT、N-PANE | 正/反向选区均保方向；程序化文本变化后 clamp/mapping；切 tab 和重启恢复 | P1 / SEL、TX 接线 |
| S02 Alt-click 多光标 | 无独立 ID / `⌥`+点击 | E-EDIT 285 | **已实现**：AppKit 多范围与 main/direction adapter 已接 production，N-TEXT | 添加而非替换光标；主选区稳定；与 IME/undo/拖选兼容 | P2 / SEL 接线 |
| S03 矩形选择 | 无独立 ID / `⌥`+拖动 | E-EDIT 285 | **已接入，待 macOS GUI 验证**：Option-drag → visual-column planner → SelectionSet；Tab、短行、方向与 10,000 行上限已有测试，真实拖动/autoscroll/后续输入 undo 未在 Linux 验证，N-TEXT 1849、N-RECT | 等宽/Tab/短行/滚动下矩形范围正确，后续输入一次撤销 | P2 / SEL 接线、列算法 |
| S04 向上添加光标 | `add-cursor-above` / `⌥⌘↑` | E-CMD 66；E-EDIT 627 | **已实现**：N-EDITCMD、N-TX | 维持目标视觉列，短行 clamp，重复位置去重 | P2 / SEL、CMD |
| S05 向下添加光标 | `add-cursor-below` / `⌥⌘↓` | E-CMD 67；E-EDIT 630 | **已实现**：N-EDITCMD、N-TX | 与 S04 对称 | P2 / SEL、CMD |
| S06 撤销选区变化 | `undo-selection` / `⌘U` | E-CMD 68；`selectionCommands.ts` 25 | **已实现**：手动鼠标/键盘 selection 进入按 document+view 隔离、revision-checked 的独立 history，N-EDITCMD、N-TEXT | 只回退当前视图 selection history，不误触文本 undo；无历史时提示 | P2 / SEL、CMD |
| S07 重做选区变化 | `redo-selection` / `⇧⌘U` | E-CMD 69；`selectionCommands.ts` 26 | **已实现**：同 S06；文本编辑使旧 revision history 失效，程序化 selection 不重复入栈 | 与 S06 成对；文本/手动移动后分支规则一致 | P2 / SEL、CMD |
| S08 加入下一处匹配 | `select-next-occurrence` / `⌘D` | E-CMD 70；E-EDIT 639 | **已实现**：N-EDITCMD | 空光标先选词；之后加入下一匹配；主选区顺序与回绕一致 | P2 / SEL、CMD |
| S09 跳过当前匹配 | `skip-current-occurrence` / — | E-CMD 71；E-EDIT 644 | **已实现**：N-EDITCMD | 用下一未选匹配替换最后选择；无更多匹配 no-op+提示 | P2 / SEL、CMD |
| S10 移除最后一个光标 | `remove-last-cursor` / — | E-CMD 72；E-EDIT 658 | **已实现**：N-EDITCMD | 删除主/最后附加范围而不改文本；仅一个时 no-op+提示 | P2 / SEL、CMD |
| S11 选中所有匹配 | `select-all-occurrences` / `⌥F3` | E-CMD 73；E-EDIT 670 | **已实现**：有界匹配转 production SelectionSet，N-EDITCMD | 空光标按词边界，非空按精确文本；结果有上限；全部可一次编辑 | P2 / SEL、CMD |
| S12 各行行首加光标 | `add-cursors-line-starts` / — | E-CMD 74；E-EDIT 1125 | **已实现**：N-EDITCMD | 覆盖物理行去重；结束在下一行首时不多加；主光标保持 | P2 / SEL、CMD |
| S13 各行行尾加光标 | `add-cursors-line-ends` / `⇧⌥I` | E-CMD 75；E-EDIT 1130 | **已实现**：N-EDITCMD | 同 S12，位置取无换行符的行尾 | P2 / SEL、CMD |
| S14 选中整行 | `select-line` / macOS `⌃L`（面板提示） | E-CMD 76；E-EDIT 702 | **已实现**：统一 public route，N-EDITCMD | 每个范围扩为完整物理行；末行及末尾 LF 边界一致 | P1 / CMD、SEL |
| S15 选至匹配括号 | `select-matching-bracket` / — | E-CMD 77；E-EDIT 705 | **已实现（现代 Lezer 语言）/部分（legacy）**：parser token 括号对优先，revision/截断校验失败才走 lexical fallback，N-PARSER、N-EDITCMD | 从活动端扩至 `()[]{}` 配对；找不到时不改变选区 | P2 / SEL、语言层 |
| S16 选中外层语法结构 | `select-parent-syntax` / `⌘I` | E-CMD 78；E-EDIT 708 | **已实现（现代 Lezer 语言）/部分（legacy）**：production route 使用 validated preorder syntax nodes；其他语言保留 conservative fallback，N-PARSER、N-EDITCMD | 选取下一外层 syntax node；纯文本/损坏语法/最外层 no-op+提示 | P3 / 语法树、SEL |
| S17 扩展选区 | `expand-selection` / `⇧⌥→` | E-CMD 79；E-EDIT 721 | **已实现（现代 Lezer 语言）/部分（legacy）**：语法树优先、词→行→全文回退并记录精确路径，N-PARSER、N-EDITCMD | 语法树优先，回退词→行→全文；每个范围独立；记录精确路径 | P3 / 语法树、SEL |
| S18 缩小选区 | `shrink-selection` / `⇧⌥←` | E-CMD 80；E-EDIT 746 | **已实现（现代 Lezer 语言）/部分（legacy）**：精确回退 parser-aware S17 历史；legacy 上游仍是 lexical path，N-PARSER、N-EDITCMD | 严格恢复 S17 的前一组范围；普通移动/编辑后历史失效 | P3 / S17 |
| S19 按行拆分选区 | `split-selection-lines` / `⇧⌘L`（面板提示） | E-CMD 153；E-EDIT 1095 | **已实现**：N-EDITCMD | 每个覆盖行生成行首光标；重叠去重；空选区 no-op+提示 | P2 / SEL、CMD |

## 6. 查找、替换与结果

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| Q01 打开当前文档查找 | `find` / `⌘F` | E-CMD 51；E-EDIT 878 | **已实现**：custom `FindBarController`、route 与 `FindBarView`，N-FIND、N-VIEW | `⌘F` 打开且聚焦；显式 Find 在专注模式仍可见，Esc 先关闭 Find 并恢复编辑焦点、再次按下才退出专注；切 tab 不串状态 | P1 / CMD、GUI 测试 |
| Q02 当前文档下一匹配 | `find-next` / `F3` | E-CMD 52；E-MENU 151 | **已实现**：route、回绕，以及严格绑定 document/view/pane/revision 的 highlight snapshot，N-FIND、N-TEXT | F3 与菜单/面板统一；可回绕；只操作当前文档；dismiss、切换 context 或 revision 后不保留旧高亮 | P1 / CMD |
| Q03 当前文档上一匹配 | `find-previous` / `⇧F3` | E-CMD 53；E-MENU 152 | **已实现**：同 Q02 | 与 Q02 反向；无结果时可访问地播报；当前匹配样式与结果索引一致 | P1 / CMD、A11Y |
| Q04 当前文档替换 | `replace` / `⌘H` | E-CMD 54；E-EDIT 890 | **已实现**：custom controller 以单 transaction 提交 replace/replace-all，N-FIND、`NativeFeatureCoordinator.swift` 51 | 单次/全部替换正确且可撤销；不跨文档；菜单与快捷键可达 | P1 / CMD、TX |
| Q05 正则/大小写/全词查找选项 | 查找面板内控件 | E-EDIT 892；用户指南 `Search & Replace` | **已实现**：三选项组合及精确结果绘制；非法正则与零宽预算在 custom find core/controller 中闭合，N-FIND、N-TEXT | regex/case/whole-word 高亮与结果集合完全一致；Unicode 与零宽查找有界且可见；非法正则和零宽替换不选择、不改正文 | P2 / 自定义 find controller |
| Q06 工作区查找 | `find-in-files` / `⇧⌘F` | E-CMD 55；E-IPC 39 | **已实现**：多根有界 service → controller → results panel，N-WSEARCH、N-VIEW | 多根 root、include/exclude glob、正则/大小写/全词；跳过二进制和超限文件；最多 5000 结果 | P3 / WS、INDEX、PAL |
| Q07 工作区替换预览 | `replace-in-files` / `⇧⌘H` | E-CMD 56；E-IPC 41 | **已实现**：preview receipt 在确认前不写盘，N-WSEARCH | 执行前展示命中、文件数、替换数；非法表达式/权限失败不会部分写入 | P3 / Q06、TX |
| Q08 确认执行工作区替换 | `replace-in-files` / `⇧⌘H` | E-SEARCH 251；E-IPC 40 | **已实现/待 APFS 实机验证**：revision/receipt 校验、Core root-scoped mutation lease、descriptor-pinned `RENAME_SWAP` + `RENAME_SECLUDE` compare/exchange、最终 capability/路径/bytes 复验、失败补偿与 opened-document 协调；已打开/硬链接/映射中的旧目标在交换点 fail closed，目录同步成功后才清零并复用隐藏 recovery slot，交换后身份不确定则保留证据并报告 partial state，N-WS、N-WSEARCH | 只改预览集合；root 移除/替换不能越过 lease；symlink 换出授权范围或外部并发保存不能被静默覆盖；串行/原子文件写；打开文档与磁盘状态协调；最终摘要准确 | P3 / Q07、WS 安全写、真实 APFS crash/open-FD 回归 |
| Q09 撤销最近工作区替换 | `undo-replace-in-files` / — | E-CMD 57；E-IPC 42 | **已实现**：一次性 undo receipt、revision 拒绝、与 Q08 共用贯穿最终复验/提交/补偿的 capability lease，以及 UI/tree 刷新，N-APP 1043、N-WS、N-WSEARCH | 一次性 token 只还原对应批次；外部再修改、root 撤销或路径越界时拒绝覆盖；刷新树与干净 tab | P3 / Q08、revision |
| Q10 持久 Find Results | 无单独打开 ID | `findResults.ts` 18 | **已实现**：分组 results panel、selection 与 navigation adapter，N-WSEARCH、N-VIEW | 按文件分组并保持结果；点击、Enter、Space 均能定位；关闭/重开焦点正确 | P3 / Q06、PAL、NAV |
| Q11 下一条工作区结果 | `find-results-next` / `F4` | E-CMD 58；E-MENU 157 | **已实现**：N-APP 1051、N-WSEARCH、N-NAV | F4 在结果中循环；成功跳转写入统一导航历史 | P3 / Q10、NAV |
| Q12 上一条工作区结果 | `find-results-prev` / `⇧F4` | E-CMD 59；E-MENU 158 | **已实现**：同 Q11 | 与 Q11 反向；空/失效结果安全跳过 | P3 / Q10、NAV |
| Q13 搜索/替换历史 | 无独立 ID | E-SET 528；E-DISPATCH 2833 | **已实现**：find/workspace controllers 经 runtime settings bridge 双向持久，`RuntimeSettingsBridge.swift` 23 | 各最多 50 项、单项 UTF-16 2000；输入可重用；跨重启恢复且不泄漏到别的 profile | P3 / SET、Q01、Q06 |

## 7. 命令面板、跳转与导航

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| N01 命令面板 | `command-palette` / `⇧⌘P`（菜单有，`COMMANDS` 无） | E-MENU 214；`palette.ts` 51 | **已接入，待 VoiceOver/GUI 验证**：catalog、plugin/worker routes、fuzzy、键盘与 execution 均在 production UI，`CommandPaletteView.swift`、N-ROUTER | 汇集全部可调用原生命令及插件命令；模糊排序/高亮；上下键、Enter、Esc；焦点恢复与 VoiceOver 完整 | P1 / CMD 接线、PAL、L10N、A11Y |
| N01a 命令 ID/快捷键元数据完整性 | 167 个面板 ID + `command-palette` + `select-build-system` | E-CMD；E-MENU；E-EVENT | **已实现（自动集合闭合）**：跨语言门禁直接解析 Electron `COMMANDS`、`MenuEvent`、菜单 item/accelerator、native `CommandCatalog.all`、`EditorCommands.body`（含实际消费的命令数组）与本矩阵，校验 169 个唯一 public ID、78 个 executable shortcut、显式非菜单例外和 319 行领域统计；注释/字符串不会被误计为菜单入口；production composition 再验证 169/169 route，`scripts/check-native-command-parity.mjs`、N-CATALOG、N-COVER。仍不以 route 覆盖代替逐 ID UI effect E2E | 权威清单差分：ID 不缺不重；默认快捷键精确；每项有矩阵行和 enablement；Catalog 实际驱动菜单、面板和路由 | P1 / CMD 接线 |
| N02 Goto Anything：模糊文件 | `goto-anything` / `⌘P` | E-CMD 43；E-DISPATCH 5289 | **已实现**：多根 workspace listing → root/exclusion-generation-bound fuzzy palette → accept-time revalidation → open/select，N-NAV、`NavigationPaletteView.swift` | 多根工作区有界列文件；相对路径排序/高亮与 Electron 一致；root/exclusion 改变后旧结果不可显示或接受 | P3 / WS、INDEX、PAL |
| N03 Goto Anything：`:行[:列]` | `goto-anything` / `⌘P` | E-DISPATCH 5361 | **已实现**：parser、palette、selection 与成功提交 history 已接，N-NAV | 支持绝对、相对、百分比及列；非法输入不跳；成功才写历史 | P2 / PAL、NAV 接线 |
| N04 Goto Anything：`@当前文件符号` | `goto-anything` / `⌘P` | E-DISPATCH 5367；`symbols.ts` 9 | **已实现**：当前文档符号抽取与 picker/navigation 闭环，N-NAV | JS/TS/Python/Go/Rust/Markdown 规则与 UTF-16 位置对等；筛选与跳转可用 | P2 / PAL、NAV 接线 |
| N05 Goto Anything：`#项目符号` | `goto-anything` / `⌘P` | E-DISPATCH 5371；E-IPC 43 | **已实现，待 macOS GUI 验证**：授权多根即时枚举、root+exclusion generation guard、200 条上限与 picker 已接，`NativeFeatureCoordinator.swift`、N-NAV | 多 root 有界索引、排除规则、最多 200 展示；root/exclusion 变化取消旧 provider，accept 时再次同步拒绝陈旧结果 | P3 / WS、INDEX、PAL |
| N06 Goto Anything：`文件:行:列` | `goto-anything` / `⌘P` | E-DISPATCH 5382 | **已实现**：文件与 line/column mode 在同一 revision-aware navigation controller 中闭合，N-NAV | 路径含冒号/同名文件/越界列可预测；打开失败不污染历史 | P3 / N02、N03 |
| N07 独立跳转当前文件符号 | `goto-symbol` / `⌘R` | E-CMD 44；E-DISPATCH 5410 | **已实现**：public route 直开 symbol mode，N-APP、N-NAV | 直接打开当前符号 picker；无符号时说明；选择跳至精确 UTF-16 位置 | P2 / N04、CMD、PAL |
| N08 独立跳转项目符号 | `goto-project-symbol` / `⇧⌘R` | E-CMD 45；E-IPC 43 | **已实现**：public route + root/exclusion snapshot-bound multi-root project symbol picker，N-APP、N-NAV | 直接进入项目符号模式；跨 root、排除、失效文件处理正确；旧 generation 不可接受 | P3 / N05、CMD |
| N09 跳转到行 | `go-to-line` / `⌘G` | E-CMD 46；E-NAV 65 | **已实现**：line parser → picker → pane selection/scroll，N-NAV | 支持 `42:8`、`+10`、`-5`、`50%` 并 clamp；接受后聚焦并滚入视图 | P1 / CMD、PAL、NAV 接线 |
| N10 跳转到匹配括号 | `goto-matching-bracket` / `⇧⌘\\` | E-CMD 47；E-EDIT 695 | **已实现（现代 Lezer 语言）/部分（legacy）**：parser token 配对、CodeMirror 候选优先级、selection/history 均接入；其余路径有界回退，N-PARSER、N-EDITCMD、N-APP | 光标位于或紧邻 `()[]{}` 时跳另一端；失败原地且不写历史 | P2 / CMD、语法/括号匹配 |
| N11 导航后退 | `navigate-back` / `⌥←` | E-CMD 48；E-NAV 95 | **已实现**：transactional traversal 只在成功选择/open 后 commit，N-NAV、N-APP | 仅成功且实际移动后记录；可返回未命名文档/原组；失效目标不破坏栈 | P2 / NAV 接线、GROUP |
| N12 导航前进 | `navigate-forward` / `⌥→` | E-CMD 49；E-NAV 144 | **已实现**：同 N11 | 与 N11 成对；新跳转清空 forward；失败 traversal 可取消 | P2 / N11 |
| N13 切换书签 | `toggle-bookmark` / `⌘F2` | E-CMD 99；E-DISPATCH 4322 | **已实现**：`BookmarkController` route → document/session model，`BookmarkController.swift`、N-APP | 以 1-based 行记录；重复切换移除；编辑后的映射规则明确；session 保存 | P2 / CMD、session 扩展 |
| N14 下一书签 | `next-bookmark` / `F2` | E-CMD 100；E-MENU 204 | **已实现**：回绕与 NAV 写入；默认 F2 冲突由 context-aware keyboard resolver 处理，N-ROUTER | 向后并回绕；跳转写入历史；解决与 LSP Rename 的 F2 冲突 | P2 / N13、CMD |
| N15 上一书签 | `prev-bookmark` / `⇧F2` | E-CMD 101；E-MENU 205 | **已实现**：同 N14 | 向前并回绕；空集合 no-op | P2 / N13、CMD |
| N16 保存基线增量标记 | 无独立 ID | `incrementalDiff.ts` 1；E-EDIT 385 | **已实现**：controller 从保存基线生成有界 gutter markers 并注入 editor，`IncrementalDiffController.swift`、N-PANE | gutter 区分新增/修改/删除；保存/重载/冲突后基线正确；大文档有界 | P2 / diff core |
| N17 下一改动 | `next-change` / `⌥⇧⌘↓` | E-CMD 60；E-DISPATCH 835 | **已实现**：diff controller route → pane selection/scroll + NAV，N-APP | 循环跳转下一个 hunk 并记录导航；无改动不移动 | P2 / N16、NAV、CMD |
| N18 上一改动 | `prev-change` / `⌥⇧⌘↑` | E-CMD 61；E-DISPATCH 838 | **已实现**：同 N17 | 与 N17 对称 | P2 / N16、NAV、CMD |
| N19 当前文件大纲 | `toggle-outline` / — | E-CMD 118；`outlinePanel.ts` 13 | **已实现，待 macOS GUI 验证**：现代语言使用 Lezer symbol/fold snapshot，其他语言保持与 Electron regex 基线同级；production 点击使用统一 navigation history，并校验 pane/document/revision，N-PARSER、`OutlineController.swift`、`OutlinePanelView.swift` | 侧栏可筛选、跟随光标、键盘激活；点击跳转写历史；不启动 LSP | P3 / WS 侧栏、N04、A11Y |

## 8. 语言编辑、预览与视图

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| V01 按扩展名自动语法高亮 | 无独立 ID | E-EDIT 458、1216；`@codemirror/language-data` | **已实现（143/143）**：后台 bundle 为 33 种 Lezer 语言生成完整结构化 spans，为 110 种 Stream 语言生成 mode 高亮；TextKit 只消费 exact-revision cache，失配/截断/失败走有界 lexical fallback，N-PARSER、N-SYNTAX、N-TEXT | 支持 Electron 当前 143 种 language-data 语言；异步切 tab 不串色；无扩展名为 Plain Text；Stream 语言不冒充 AST | P3 / 语言层 |
| V02 手动选择并锁定语法 | `select-language` / — | E-CMD 107；E-DISPATCH 5458 | **已实现**：View 菜单/route → language picker/controller → document/session → editor/status，`LanguageController.swift`、N-CMD、N-PANE | 菜单与命令面板均可达；模糊选择语言；锁定随 tab/session；Save As 不覆盖手工选择；状态栏可见 | P3 / V01、PAL、session 扩展 |
| V03 自动缩进、括号自动闭合/匹配 | 无独立 ID | E-EDIT 273、275、276 | **已接入，待真实 macOS IME/GUI 验证**：后台 CodeMirror 对最多 8 个光标生成真实 `IndentContext(simulateBreak:)` normal/double-break probe，并预计算 `(`、`[`、`{`、`:`、`,`、`>` 单字符 transition；主线程只消费 exact document/revision/text/selection/settings snapshot，非 IME 单光标精确插入才推进 transition，IME 或意外编辑立即失效且不在 MainActor 跑 JavaScript。newline planner 还覆盖 HTML 成对标签、Markdown bullet/ordered/task list continuation 与空 marker 退出；paired insert/backspace、closing 单次跳过和 bracket visuals 使用 view-local UTF-16 provenance；模型拒绝意外 AppKit edit 时会恢复原 revision/provenance/indentation，N-PARSER、`NativeTextInputPlanner.swift`、N-TEXT | CodeMirror 语言感知 Enter 与 Electron 一致；旧 revision/parser 结果绝不套到新文本；多光标、IME、HTML/JSX/Python/SQL/Markdown、行首空白与 parser 超时均 fail closed；括号输入/退格/匹配不改错文本 | P3 / 语言层、TX、真实 IME |
| V04 自动补全基础/工作区词 | 无独立 ID / `⌃Space` 或 `⌘Space` | E-EDIT 277；E-DISPATCH 1645 | **已实现**：本地/工作区/LSP 候选经 versioned `CompletionController` 到 editor popup/transaction，`CompletionController.swift`、N-PANE | 本地/工作区候选有界、异步结果不过期；键盘选择与 IME 不冲突 | P3 / INDEX、PAL、语言层 |
| V05 Markdown 实时旁栏预览 | `toggle-preview` / `⇧⌘V` | E-CMD 108；E-PREVIEW 47 | **已实现**：route → safe native Markdown document → 实时旁栏 view，N-APP 1175、N-PREVIEW、`DocumentPreviewView.swift` | 扩展名或手工语法可启用；与编辑并排实时更新；切 tab/布局状态正确 | P3 / PREVIEW、V02、GROUP |
| V06 Markdown 消毒与安全链接 | 同 `toggle-preview` | E-PREVIEW 28、73 | **已实现**：不渲染 HTML/JS；只构造 `AttributedString`，链接严格 allowlist http/https/mailto，N-PREVIEW 55、159 | script、事件属性、`javascript:` 等不可执行；链接经白名单交系统浏览器，不在 app 内载入 | P3 / PREVIEW、SEC 外链策略 |
| V07 当前 HTML 在系统浏览器打开 | `open-in-browser` / — | E-CMD 109；E-IPC 23 | **已实现**：菜单/route 将 clean file 或有界原子临时快照只交系统浏览器，退出清理，无 WKWebView，N-CMD、`HTMLBrowserController.swift`、`HTMLBrowserPreview.swift` | 菜单与命令面板均可达；clean 文件直接打开；dirty/untitled 用临时快照且不触发 Save；相对资源基准正确；退出清理临时文件 | P3 / PREVIEW、文件授权 |
| V08 JSON 格式化 | `format-json` / — | E-CMD 126；E-DISPATCH 1108 | **已实现**：lossless JSON format → revision-checked 全文单 transaction，N-APP 1198、N-PREVIEW | 合法 JSON 格式化且一次撤销；无损大整数/重复键策略与 Electron 明确一致；错误不改文本 | P2 / TX、JSON core |
| V09 JSON 压缩 | `compact-json` / — | E-CMD 127；E-DISPATCH 1111 | **已实现**：同 V08 的 compact path，N-APP 1204、N-PREVIEW | 与 V08 共享无损解析策略；输出紧凑、一次撤销 | P2 / TX、JSON core |
| V10 JSON 树视图和节点编辑 | `toggle-json-view` / — | E-CMD 128；E-JSON 1 | **已接入，待 macOS GUI/VoiceOver 验证**：JSON tree、无损编辑与 revision-checked single transaction 已进 production，N-JSON、N-PREVIEW | 展开/收起、编辑任意 JSON 值、增键/数组项、确认删除；无损大整数与键顺序；文档 ID/版本及 UI generation 防过期；UTF-16 全文单事务并进入 undo/宏链；中英文、键盘与稳定 a11y ID | P3 / macOS GUI、VoiceOver |
| V11 侧栏显示/隐藏 | `toggle-sidebar` / `⌘B` | E-CMD 110；E-DISPATCH 4289 | **已实现**：route 驱动 workspace sidebar 的可见/焦点/布局状态，N-APP 983、N-VIEW | 显隐不改工作区；隐藏后不可聚焦；设置持久化；分栏布局重排正确 | P3 / WS、SET、A11Y |
| V12 在侧栏显示活动文件 | `reveal-active-file-in-sidebar` / — | E-CMD 111；E-TREE 174 | **已实现**：route → generation-guarded parent expansion/highlight，N-APP 986、N-WS | 显示侧栏、退出专注模式、展开父目录、高亮而不抢焦点；外部/未命名文件仅提示 | P3 / WS、V11 |
| V13 行号显示/隐藏 | `toggle-line-numbers` / — | E-CMD 115；E-EDIT 368 | **已实现**：设置页和菜单 toggle 即时驱动 ruler 并持久，N-SETAPP 101、N-CMD 133、N-TEXT 138 | 开关即时作用全部 tab/组、只改显示且持久；长文件/软换行行号准确 | P1 / GUI 测试 |
| V14 Minimap | `toggle-minimap` / — | E-CMD 116；E-EDIT 196 | **已接入，待 macOS GUI/VoiceOver 验证**：有界 minimap render、点击与连续拖动导航、边界 clamp、取消状态及设置同步已接；VoiceOver 降噪仍需实测，`NativeEditorMinimap.swift`、N-TEXT | 可开关并持久；点击/拖动导航；大文档性能和 VoiceOver 降噪合格 | P3 / 自定义渲染、SET |
| V15 空白字符标记 | `toggle-whitespace` / — | E-CMD 117；E-EDIT 379 | **已实现**：设置即时驱动可见 glyph whitespace 绘制，N-PANE 765、N-TEXT 1631 | 空格/Tab 可见且不改文本；与行尾空白独立；全部组同步 | P2 / TextKit attributes、CMD |
| V16 缩进参考线 | 无独立 ID；设置 `showIndentGuides` | E-EDIT 378；E-SET 508 | **已实现**：有界 indentation guide decoration，N-PANE 766、N-TEXT 1578 | 多级缩进与 tab width 对齐；可关闭；不影响 selection/打印文本 | P2 / TextKit decorations |
| V17 行尾空白高亮 | 无独立 ID；设置 `highlightTrailingWhitespace` | E-EDIT 380；E-SET 511 | **已实现**：可见区 trailing-whitespace decoration，N-PANE 767、N-TEXT 1601 | 只标行尾空格/Tab；与 V15 独立；编辑后增量更新 | P2 / TextKit decorations |
| V18 竖直标尺 | 无独立 ID；设置 `rulers` | E-EDIT 381；E-SET 512 | **已实现**：1–500/最多 10 的固定列 ruler 绘制，N-PANE 768、N-TEXT 1828 | 1–500 列、最多 10 个，按字体/Tab 列对齐；空数组隐藏 | P2 / TextKit decorations |
| V19 当前块折叠 | `fold-current` / `⌘⌥[`（面板提示） | E-CMD 119；E-EDIT 711 | **已实现（现代 Lezer 语言）/部分（legacy）**：CodeMirror fold service 经 parser coordinator 接 production；失败/不支持时回退 lexical analyzer；revision 更新按结构等价 region 协调既有 fold；line-number ruler 有独立 fold lane 与精确 marker ID，N-PARSER、`OutlineController.swift`、N-TEXT | 语法块折叠；鼠标或 VoiceOver 逐 marker 激活且不误触 diff/diagnostic lane；普通编辑及切 tab/组保留有效状态 | P3 / 语法树、CMD、A11Y |
| V20 当前块展开 | `unfold-current` / `⌘⌥]`（面板提示） | E-CMD 120；E-EDIT 712 | **已实现（现代 Lezer 语言）/部分（legacy）**：与 V19 共用 parser-aware region，N-PARSER、`OutlineController.swift`、N-TEXT | 只展开光标处；没有折叠时 no-op+提示 | P3 / V19 |
| V21 全部折叠 | `fold-all` / `⌃⌥[`（面板提示） | E-CMD 121；E-EDIT 713 | **已实现（现代 Lezer 语言）/部分（legacy）**：与 V19 共用 parser-aware region，N-PARSER、`OutlineController.swift`、N-TEXT | 折叠全部可折叠块且 UI 保持响应 | P3 / V19 |
| V22 全部展开 | `unfold-all` / `⌃⌥]`（面板提示） | E-CMD 122；E-EDIT 714 | **已实现**：production unfold-all 清空 fold state，`OutlineController.swift`、N-TEXT | 清除全部 fold；文本/selection 不变 | P3 / V19 |
| V23 专注模式 | `toggle-distraction-free` / `⇧F11` | E-CMD 123；E-DISPATCH 4306 | **已实现**：设置/route 即时隐藏 sidebar/tab/status/panels 并限制内容宽度；显式 Find 仍显示，Escape 优先关闭 Find，再退出专注模式，N-APP 1146、N-VIEW | 隐藏侧栏/tab/status chrome、编辑器居中；Find 可达且两级 Esc 顺序正确；状态持久且不隐藏系统退出路径 | P2 / GROUP、CMD |
| V24 拼写检查 | `toggle-spell-check` / — | E-CMD 125；E-EDIT 521 | **已实现**：runtime setting 驱动 NSTextView spell checking 并按 language scope，N-TEXT、N-PANE | 只在 Plain Text/Markdown 启用；开关持久；不启用自动纠正；全部 editor 同步 | P1 / 文档类型 scope、GUI 测试 |
| V25 软换行 | `toggle-word-wrap` / `⌥Z` | E-CMD 129；E-EDIT 545 | **已实现**：设置页和 `⌥Z` 菜单即时驱动 TextKit 并持久，N-SETAPP 87、N-CMD 138、N-TEXT 185 | 快捷键/菜单切换；不改文档；横向滚动状态正确；持久化 | P1 / GUI 测试 |
| V26 明暗主题切换 | `toggle-theme` / `⌘K` | E-CMD 130；E-DISPATCH 1073 | **已实现**：设置页、菜单、SwiftUI scene 与 NSTextView 同步主题并持久，N-SETAPP 43、N-CMD 141、N-TEXT 166 | 手工 dark/light 切换并持久；所有面板、selection、ruler 对比度合格 | P1 / GUI/A11Y 测试 |
| V27 选择配色方案 | `select-color-scheme` / — | E-CMD 159；E-SET 147 | **已实现**：picker/controller 持久设置并即时驱动 editor syntax palette，`ColorSchemeController.swift`、N-PANE 771 | 四种方案即时应用编辑器并持久；语法色与 UI theme 边界明确 | P3 / V01、配色渲染、PAL |
| V28 字号放大 | `font-zoom-in` / `⌘=` | E-CMD 131；E-DISPATCH 1278 | **已实现**：设置页和菜单即时驱动 NSTextView，N-SETAPP 70、N-CMD 148 | 每次 +1，最大 40；全部组同步、布局稳定并持久 | P1 / GUI 测试 |
| V29 字号缩小 | `font-zoom-out` / `⌘-` | E-CMD 132；E-DISPATCH 1282 | **已实现**，N-CMD 154 | 每次 -1，最小 8；同 V28 | P1 / GUI 测试 |
| V30 字号重置 | `font-zoom-reset` / `⌘0` | E-CMD 133；E-DISPATCH 1286 | **已实现**，N-CMD 160 | 回到 14；重复调用幂等并持久 | P1 / GUI 测试 |

## 9. 工作区、项目与文件树

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| W01 打开文件夹为工作区 | `open-folder` / `⇧⌘O` | E-CMD 26；E-IPC 14 | **已接入，待真实 Sandbox/GUI 验证**：directory panel → bookmark/root service → sidebar/session，N-APP 866、N-WS | 选择目录后建立 primary root、授权并显示树；取消保留原工作区 | P3 / WS 接线、CMD |
| W02 懒加载文件树 | 无独立 ID | E-TREE 29、249；E-IPC 15 | **已实现**：有界 lazy children controller 与 expandable tree UI，N-WS、`WorkspaceSidebarView.swift` | 文件/目录排序与过滤正确；首次展开才读子目录；刷新保留展开态；错误局部呈现 | P3 / WS 接线、A11Y |
| W03 添加文件夹到项目 | `add-folder-to-project` / — | E-CMD 180；E-DISPATCH 3147 | **已接入，待真实 Sandbox/GUI 验证**：add-root route/panel → independent grant/watcher/session，N-APP 869、N-WS | 可添加多 root、去重；每 root 独立授权/监听；最具体 root 决定相对路径 | P3 / WS 接线 |
| W04 从项目移除文件夹 | `remove-folder-from-project` / — | E-CMD 181；E-IPC 17 | **已接入，待真实 Sandbox/GUI 验证**：确认/选择 → resource teardown/root removal/session sync，N-APP 877、N-WS | 保留已开 tab，但撤销树/搜索/符号/Build/Git/terminal/LSP 权限与资源；需确认 | P3 / W03、资源生命周期 |
| W05 最近项目 | `open-recent-project` / — | E-CMD 182；E-IPC 34 | **已实现**：recent project store/controller/picker、File 菜单的 Open Recent Project… 入口与授权恢复，`RecentItemsController.swift`、N-CMD、N-VIEW | 菜单入口打开有界、去重、按最近时间排序的 picker；失效项处理；打开恢复多根项目语义 | P3 / WS、SET、PAL |
| W06 创建文件 | 文件树上下文菜单 / — | E-TREE 13、215；E-IPC 44 | **已实现**：sidebar context action → root-fd `openat(O_NOFOLLOW + O_EXCL)` → refresh/open；root/parent identity 重验抵御 symlink swap，N-WS、`WorkspaceSidebarView.swift` | 仅在授权 root 内创建；重名/非法名/权限错误可见；树刷新并可打开 | P3 / WS 接线、安全路径解析 |
| W07 创建文件夹 | 文件树上下文菜单 / — | E-TREE 13、215；E-IPC 44 | **已实现**：同 W06，使用 root-fd `mkdirat` 并重验 capability identity，N-WS、`WorkspaceSidebarView.swift` | 同 W06，且新目录可展开、可作为后续创建父目录 | P3 / W06 |
| W08 重命名路径 | 文件树上下文菜单 / — | E-TREE 16、219；E-IPC 46 | **已实现**：sidebar rename → descriptor-anchored `renameatx_np(RENAME_EXCL)` → open tabs/navigation/session path rewrite；源 inode、root 与 parent capability 均重验，N-WS | 目标仍在 root；打开 tab、导航、树和 session 路径原子更新；冲突拒绝 | P3 / WS 接线、NAV、session |
| W09 移动路径 | 文件树上下文菜单 / — | E-TREE 17、220；E-IPC 47 | **已接入，待真实 macOS panel/FS 验证**：destination panel、授权 move 与 model path coordination；exact-file bookmark 批量 prepare/commit/abort 并持久化 pending before-image，目录后代 grants 全有或全无；rollback 失败按 committed/indeterminate 分类并同步或保守刷新，N-WS | 通过系统目标选择；不越权；打开后代路径、lease、历史与 session 统一重写；失败及进程中断可恢复且不留下 ghost grant | P3 / W08 |
| W10 移到系统废纸篓 | 文件树上下文菜单 / — | E-TREE 18、221；E-FS 3878 | **已接入，待真实 macOS Trash 验证**：destructive confirmation → `trashItem` → model/tree refresh，N-WS | 明确确认；调用 Trash 而非永久删除；dirty/open 文件语义清楚；失败不从树伪删除 | P3 / WS 接线、TRUST |
| W11 在 Finder 中显示 | 文件树上下文菜单 / — | E-TREE 19、222；E-IPC 49 | **已接入，待真实 macOS Finder 验证**：authorized path → `NSWorkspace.activateFileViewerSelecting`，N-WS | 仅已授权存在路径可调用；Finder 定位正确；无越权路径注入 | P3 / WS |
| W12 文件树复制完整/相对路径入口 | 复用 `copy-file-path` / `copy-relative-file-path` | E-TREE 20、223 | **已实现**：tree context menu 共用 validated full/relative clipboard paths，`WorkspaceSidebarView.swift`、N-WS | 与 F19/F20 共用实现，树 item 与 tab 结果一致 | P3 / F19、F20、W02 |
| W13 显示活动文件并高亮 | `reveal-active-file-in-sidebar` / — | E-CMD 111；E-TREE 170 | **已实现**：generation-guarded expand/highlight active file，N-WS | 见 V12；异步旧请求不得覆盖更新的活动路径 | P3 / W02、并发令牌 |
| W14 文件系统监听与树刷新 | 无独立 ID；IPC `file:watch` | E-BRIDGE 186；E-FS 3892 | **已接入，待真实 macOS 验证**：每 root 建立有上限、带 `FileEvents`/`UseCFTypes` 的递归 FSEventStream；保留 changed/renamed/deleted 路径分类，丢事件/root change 安全降级为 root invalidation；root 增删同步启停，250ms 去抖后精确刷新，旧 root/exclusion generation 的已排队 callback 和 batch 会丢弃，N-WATCH、N-WS | 每 root 监听，rename/delete/change 分类；事件突发去抖；root/exclusion 改变后旧 callback 不回写；移除 root 后停止；轮询可兜底 | P3 / macOS GUI/文件系统回归 |
| W15 项目排除规则 | 无独立 ID；`exclude` | E-SET 636；E-DISPATCH 5344 | **已实现**：只有成功提交的 normalized exclusions 才以单调 snapshot generation 进入 tree/watcher/search/replace/Goto/project-symbol/word enumeration；各异步结果与 accept 均拒绝旧 generation，N-WS、N-WSEARCH、N-NAV | 未保存/取消的草稿不改变 live policy；旧 preview/结果失效且不可接受，已完成 replace 的 undo receipt 仍按 capability/revision 工作；glob/目录/多根语义一致 | P3 / WS 接线、INDEX |
| W16 配置项目 | `project-settings` / — | E-CMD 164；E-IPC 636 | **已实现**：route → validated `ProjectSettingsController` → project/session/runtime consumers；draft/store/build-command/security-scope/LSP authorization 失败保留 typed payload，未知 picker/system 错误保持 verbatim，N-APP 1255、`ProjectSettingsView.swift` | 编辑并校验 exclude/build/key bindings/plugins/permissions/language tools/LSP/build systems/marketplace/snippets；非法字段不执行；既有错误可随 locale 重绘且不误翻译外部错误 | P3 / WS、SET、TRUST |
| W17 导入 Sublime Project | `import-sublime-project` / — | E-CMD 183；E-IPC 663 | **已实现**：picker → bounded parse/preview → confirm/apply composition，`SublimeImportProduction.swift`、N-APP 419 | 预览并确认 roots、排除和 build systems；短期 token 接受前不得授权；绝不执行 Python 插件 | P3 / WS、导入解析器、TRUST |
| W18 EditorConfig | 无独立 ID | E-FS 3595；`editorConfig.ts` | **已实现**：见 F23；FSEvents 变化触发重检，N-WATCH、N-ACT | 见 F23；变更文件时刷新受影响文档，用户显式 EOL 选择优先 | P3 / F23、W14 |
| W19 工作区词索引 | 无独立 ID；IPC `workspace:words` | E-BRIDGE 171；E-DISPATCH 1666 | **已实现**：有界 workspace word provider 接 completion controller，N-WS、`CompletionController.swift` | 多根、排除和 2 MiB/file 等预算；最多缓存 60 秒；用于补全但不执行内容 | P3 / WS、INDEX |

## 10. Git

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| G01 显示/隐藏 Git Changes 面板 | `toggle-git` / — | E-CMD 160；E-DISPATCH 1027 | **已接入，待真实 Git/GUI 验证**：route 切 panel 并 refresh，N-APP 1062、`GitPanelView.swift`、N-TOOLS | 仅在 workspace root 内工作；打开即刷新；关闭恢复焦点且不终止无关工具 | P4 / WS、PROC、PAL |
| G02 刷新仓库状态 | `refresh-git` / — | E-CMD 161；E-IPC 85 | **已接入，待真实 Git 验证**：root-scoped service → published status/UI，`GitController.swift` 192、`GitService.swift` | 显示非仓库状态、分支、index/worktree 双状态；命令超时/缺 git 可见 | P4 / G01、PROC |
| G03 upstream 与 ahead/behind | 面板内 / — | E-IPC 342；E-GIT 202 | **已接入，待真实 Git 验证**：本地 tracking refs 与 ahead/behind parser 已进 status model，`GitService.swift` 1321 | 只读本地 refs/config，不 fetch；无 upstream/无法比较状态区分；计数准确 | P4 / G02 |
| G04 远端详情与凭据脱敏 | 面板内 / — | E-IPC 334；E-GIT 238 | **已接入，待真实 Git 验证**：fetch/push remote URL 在进入 observable state 前脱敏，面板只渲染 sanitized display URL，不持有可回显的原始凭据 URL，`GitService.swift` 689、`GitController.swift` 517、`GitPanelView.swift` | fetch/push URL 到 UI 前剥离 userinfo/token；错误/fallback 文案也不得回显原 URL；刷新不联网；SSH/HTTPS 均测试 | P4 / G02、SEC |
| G05 打开变更文件与多选 | 面板列表 / 键盘、`⌘`+点击 | E-GIT 159 | **已接入，待 macOS GUI 验证**：changed-file list、多选与 navigation callbacks 已接 panel，`GitPanelView.swift`、N-NAV | index/worktree 状态可读；Enter 打开、Space/⌘click 多选；完整键盘导航 | P4 / G01、A11Y |
| G06 文件 diff | 面板双击 / — | E-IPC 86；E-GIT 339 | **已接入，待真实 Git 验证**：有界 diff request/generation guard → preview，`GitController.swift` 207、`GitPanelView.swift` | 有界文本 diff；binary/rename/未跟踪文件状态明确；异步旧结果不覆盖新选择 | P4 / PROC、G05 |
| G07 hunk 列表与预览 | 面板选择器 / — | E-IPC 365；E-GIT 288 | **已接入，待真实 Git 验证**：有界 hunk parser/selection/preview，`GitController.swift` 228、`GitService.swift` 800 | 正确解析每个 hunk header/patch；选择与文件切换一致；大 diff 截断说明 | P4 / G06 |
| G08 暂存/取消暂存文件 | 面板按钮 / — | E-IPC 379；E-GIT 100 | **已接入，待真实 Git 验证**：root/status-bound immutable mutation snapshot → explicit confirm → validated argv/path mutation → refresh，`GitController.swift`、`GitService.swift` | 多选路径经 root 校验；确认时输入不漂移；取消/旧确认不执行；部分失败有明确结果并刷新 | P4 / G05、TRUST |
| G09 丢弃工作区文件改动 | 面板按钮 / — | E-IPC 379；E-GIT 102 | **已接入，待真实 Git/GUI 验证**：destructive confirm 后检查磁盘外变、dirty/saving/conflict，捕获 buffer+disk revision 并以独立 owner 锁住；mutation committed 或已启动但结果不确定时均在解锁前 guarded reopen，`GitController.swift`、`LumenEditorApplication.swift`、`GitPanelView.swift` | 强确认；编辑/保存/外部 revision 不与 restore 竞态；root switch/shutdown 等待协调；status refresh 失败不留下 stale clean buffer | P4 / G05、TRUST、revision |
| G10 暂存/丢弃单个 hunk | 面板按钮 / — | E-IPC 365、379；E-GIT 103 | **已接入，待真实 Git/GUI 验证**：stage/discard 均冻结并确认精确 patch、执行前 fresh diff 重验；discard-hunk 与整文件 discard 共用 external-change preflight、owner lock 和 post-mutation reopen，`GitController.swift`、`GitService.swift` | patch 仅作用于确认的 path/hunk；陈旧 patch 拒绝；取消不执行；失败或取消后磁盘状态不确定时仍协调打开文档 | P4 / G07、TRUST、revision |
| G11 文件提交历史 | 面板 `History` / — | E-IPC 371；E-GIT 362 | **已接入，待真实 Git 验证**：`git log -- ...` 有界 100 条并显示 panel，`GitService.swift` 478、N-TOOLS | 最多 100 条，包含 hash/author/date/subject；路径与参数不被解释成 option | P4 / PROC、G05 |
| G12 文件 blame | 面板 `Blame` / — | E-IPC 89；E-GIT 377 | **已接入，待真实 Git 验证**：有界 blame argv/output 与 panel，`GitService.swift` 490、N-TOOLS | 输出有界、可选择复制；二进制/未提交文件错误清楚 | P4 / PROC、G05 |
| G13 Commit | 面板 `Commit` / — | E-IPC 379；E-DISPATCH 3605 | **已接入，待真实 Git/GUI 验证**：非空 message 与 staged/status/root immutable snapshot 经确认后执行；取消、刷新或 root 变化使旧确认失效，`GitController.swift`、`GitPanelView.swift` | 二次确认且只提交 reviewed staged 内容；旧确认不 mutate；失败 stderr 有界显示 | P4 / PROC、TRUST |
| G14 切换/创建分支 | 面板按钮 / — | E-IPC 379；E-DISPATCH 3616 | **已接入，待真实 Git/GUI 验证**：checkout/create 都需冻结确认；当前 worktree 的 open docs 先检查 saving/dirty/external conflict/busy，再以独立 owner lock 覆盖 mutation 与 post-switch reopen。Git 区分 not-started、committed 和 launched-indeterminate，后两者即使 status refresh/root switch/shutdown 失败也先协调精确 token 文档，`GitController.swift`、`GitService.swift`、N-MODEL | 分支名/确认正确；阻塞原因 typed/localized；Git 与 Quit locks 可叠加且互不释放；read failure 显式 conflict，不把旧 branch 内容标为 clean | P4 / PROC、TRUST、revision |
| G15 打开合并冲突 | `open-git-conflicts` / — | E-CMD 162；E-IPC 92 | **已接入，待真实 Git/GUI 验证**：route 枚举 unmerged paths；面板可打开 worktree、ours、theirs，或将两个有界 Git blob 快照置于左右 pane 比较，`GitController.swift`、`GitPanelView.swift`、`GitService.swift`、N-APP | 枚举 unmerged 路径并以两列打开 ours/theirs/工作树策略；无冲突有反馈 | P4 / Git、GROUP、WS |

## 11. Terminal 与 Build

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| TM01 显示并首次启动项目终端 | `toggle-terminal` / `⌥⌘T` | E-CMD 135；E-DISPATCH 4897 | **已接入，待真实签名 Sandbox/进程验证**：route/panel → 完整 identity approval → 有效用户登录 shell fallback → terminal start，N-APP 1114、`TerminalController.swift` | 无 workspace 时拒绝；首次明确告知 shell 可读写/删除/联网并确认；隐藏/Escape 保留 live session 和输出，重开继续使用 | P4 / WS、PROC、TRUST |
| TM02 终端输入/输出/退出 | 面板内 / Enter、Interrupt | E-IPC 285；E-TERM 14 | **已接入，待真实签名 Sandbox/进程验证**：独立 `forkpty` broker 提供 controlling PTY、串行有界输入/合流输出/退出、动态 `TIOCSWINSZ` 和 session identity；空行发送 Return，Interrupt 写入 VINTR，由终端行规程投递到 foreground process group；TERM→KILL 覆盖已跟踪 login/foreground process groups，关闭 PTY 触发 hangup。纯文本可访问显示保持 `TERM=dumb`，不伪装 ANSI/full-screen TUI，`PseudoTerminalProcessRunner.swift`、`LumenPTYSupport.c`、`TerminalController.swift`、`TerminalPanelView.swift` | cwd 为项目 root；PTY 中 stdout/stderr 按真实终端语义合流；输入串行；Interrupt 到达前台作业；窗口尺寸同步；旧 session output 由 opaque ID 丢弃 | P4 / TM01 |
| TM03 停止终端 | 面板 Stop / — | E-IPC 54；E-DISPATCH 4975 | **已接入，待真实签名 Sandbox/进程验证**：仅 Stop、root change、window/app shutdown 关闭并 join 进程；面板关闭只隐藏，N-APP 343、N-TOOLS | 优雅停止后强制回收；窗口/root 移除/退出时无孤儿进程；隐藏不终止，UI 状态同步 | P4 / TM01、PROC 生命周期 |
| TM04 终端日志边界和可访问性 | 面板内 / — | E-TERM 15、191 | **已接入，待 VoiceOver/真实进程验证**：有界日志、截断状态与稳定 a11y identifiers，`TerminalPanelView.swift`、N-TOOLS | 可见日志最多 1,000,000 字符、单 chunk 有上限并说明截断；日志不设打扰性 live region | P4 / TM02、A11Y |
| B01 运行自由构建命令 | `build` / `⇧⌘B` | E-CMD 134；E-IPC 55 | **已接入，待真实签名 Sandbox/进程验证**：输入仅更新草稿；完整 workspace identity approval 后、启动前同步提交项目+全局命令，失败补偿或报告 partial persistence 并阻止 runner，N-APP 1082、`BuildController.swift`、`RuntimeSettingsBridge.swift` | 拒绝审批不持久；批准后持久化先于启动；workspace root cwd；stdout/stderr/exit 只属于当前 run/root；重复启动策略明确 | P4 / WS、PROC、TRUST |
| B02 取消构建 | Build 面板 Stop / — | E-IPC 56；`buildPanel.ts` 70 | **已接入，待真实进程验证**：idempotent cancel/termination lifecycle，`BuildController.swift`、`BuildPanelView.swift` | 终止进程树并最终产生 exit；多次 cancel 幂等；退出无孤儿 | P4 / B01 |
| B03 Build Output 面板 | `toggle-problems` / — | E-CMD 156；E-BUILD 15 | **已接入，待 macOS GUI/真实进程验证**：toggle、clear、stop、bounded output/status，N-APP 1109、`BuildPanelView.swift` | 显示/隐藏、清空、停止；输出最多 1,000,000 字符；焦点关闭后恢复 | P4 / B01、A11Y |
| B04 选择 Build System | `select-build-system` / —（菜单有，`COMMANDS` 无） | E-MENU 266；E-DISPATCH 4749 | **已实现**：第 169 个 public catalog route 打开 fuzzy build-system/variant palette，N-APP 1092、`BuildSystemPaletteView.swift` | 模糊选择系统/variant；当前选择有状态；无配置时说明；应进入统一命令注册表 | P4 / W16、PAL、CMD |
| B05 结构化 Build System 与 variants | 无独立 ID | E-IPC 293；E-DISPATCH 4809 | **已实现**：project settings → validated command/args/cwd/env/shell/variant model，`BuildController.swift`、`ProjectSettingsController.swift` | command/args/cwd/env/shell/saveBeforeBuild/variant 逐项校验；变量替换可预测 | P4 / B04、PROC |
| B06 Build 前保存 | `build` 的配置行为 | E-IPC 299；E-DISPATCH 4809 | **已接入，待 GUI/真实进程验证**：`saveBeforeBuild` 通过 `saveAllDocuments` preflight，N-APP 121、`BuildController.swift` | `saveBeforeBuild` 时处理所有相关 dirty/untitled/冲突；取消即不执行命令 | P4 / B05、F08 |
| B07 解析并跳转构建问题 | 面板结果 / Enter/点击 | E-IPC 320；E-DISPATCH 5006 | **已实现**：可取消的 detached 增量逐行 parser → panel row → navigation controller；自定义 regex 拒绝嵌套量词/回溯引用/lookaround，并受行长、输入量、尝试次数与累计匹配时间预算约束，`BuildController.swift`、`BuildPanelView.swift`、N-NAV | 默认及自定义 `fileRegex`；最多 500 条；相对路径限于 root；跳转写 NAV | P4 / B03、NAV、A11Y |
| B08 导入 Sublime Build System | `import-sublime-build` / — | E-CMD 137；E-IPC 58 | **已实现**：bounded declarative import → preview/confirm → project settings；执行仍另行审批，`SublimeImportProduction.swift` | 只导入声明字段；最多 30 个；导入确认与执行确认分开；不执行导入文件代码 | P4 / W16、B05、TRUST |

## 12. LSP、格式化与诊断

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| L01 配置 stdin/stdout language tool | `language-tools` / — | E-CMD 165；E-IPC 685 | **已实现**：validated project language-tool editor 持久配置；配置不启动进程；draft、LSP、执行策略、进程、security scope 与 Project Settings 失败保留 typed payload，并跨菜单/快捷键/命令面板路由，不再降级为英文字符串；未知 picker/formatter/system 错误保持 verbatim，`LanguageToolsController.swift`、`LanguageToolsView.swift` | 按语言保存 command/args；严格 JSON 校验；配置本身不启动进程；运行中切换 locale 可重绘 app-owned 错误且 stderr/外部错误不被反向匹配翻译 | P4 / W16、PROC、TRUST |
| L02 Format Document | `format-document` / — | E-CMD 138；E-DISPATCH 5049 | **已接入，待真实 formatter/LSP 验证**：LSP → language tool → built-in fallback，revision-checked 单 transaction，`LanguageToolsController.swift` | 优先 LSP、其次 language tool、最后内建格式；替换一次可撤销；保存/冲突策略正确 | P4 / L01、L03、TX |
| L03 配置并持久运行 LSP | 无独立 ID；`languageServers` | E-IPC 679；E-FS 4261 | **已接入，待真实签名 Sandbox/LSP 验证**：root+config manager、用户选择的绝对 executable 以 security-scoped bookmark/lease 形成窗口会话 allowlist，之后仍按完整 identity 首次审批；项目 JSON 单独不能授权或启动，start/stop/restart lifecycle 已接，N-TOOLS | 每 root+server 独立进程；initialize/同步/stop 生命周期正确；每会话首次启动确认 | P4 / WS、PROC、TRUST |
| L04 文档同步与诊断 gutter | 无独立 ID | E-DISPATCH 1555、1929；E-EDIT 1175 | **已接入，待真实 LSP/GUI 验证**：panel 可保留有界、未携 version 的诊断供检查，但 gutter 只接受 canonical path/document identity、document version 与最新 server generation 全部精确匹配的快照；close、stop 与 stopAll 分别转发 manager 生命周期并清理对应或全部 status/diagnostic/log/identity，旧 generation 结果被拒绝，`LanguageServerController.swift`、N-PANE | 已保存 workspace 文档防抖版本同步；未版本化诊断不得进入 gutter；旧文档、旧版本或旧 generation 均不能污染当前编辑器；停止生命周期及时清 retained state；最多 1000 条且路径授权 | P4 / L03、语言层 |
| L05 自动补全 | LSP method `completion` / 编辑器补全键 | E-IPC 797；E-DISPATCH 1628 | **已接入，待真实 LSP/GUI 验证**：versioned/cancellable LSP completion 优先、workspace fallback 与 transaction insertion，`CompletionController.swift` | server 候选优先、空结果回退 workspace words；取消/版本化异步请求；插入文本正确 | P4 / L03、V04 |
| L06 Hover | `lsp-hover` / `⇧⌘Space` | E-CMD 190；E-DISPATCH 1709 | **已接入，待真实 LSP/GUI 验证**：route → bounded hover result → panel，N-APP 1274、N-TOOLS | 展示有界纯文本/Markdown 安全内容；无结果/错误不改文档；焦点可返回 | P4 / L03、PAL、A11Y |
| L07 Go to Definition | `lsp-definition` / `F12` | E-CMD 191；E-DISPATCH 1719 | **已接入，待真实 LSP 验证**：LSP 单结果直达 NAV、多结果进入 panel；未配置或无法构造适用 LSP request 时回退项目符号，并有 production fallback 测试；已配置 LSP 的空结果只提示、错误进入 LSP panel，不再回退，N-APP 1281、N-TOOLS | 单结果直跳，多结果进 Find Results；无适用 LSP 时回退项目符号；成功写 NAV | P4 / L03、Q10、NAV |
| L08 Find References | `lsp-references` / `⇧F12` | E-CMD 192；E-DISPATCH 1719 | **已接入，待真实 LSP 验证**：LSP references 进入 results panel/navigation；未配置或无法构造适用 LSP request 时回退工作区全词搜索，并有 production fallback 测试；已配置 LSP 的空结果只提示、错误进入 LSP panel，不再回退，N-APP 1295、N-TOOLS | 多结果进 Find Results；无适用 LSP 时回退工作区全词搜索；失效位置安全跳过 | P4 / L03、Q06、Q10 |
| L09 Rename Symbol | `lsp-rename` / `F2` | E-CMD 193；E-MENU 264 | **已接入，待真实 LSP/GUI 验证**：prompt → rename preview → validated cross-file atomic apply/rollback，N-APP 1302、`NativeFeatureCoordinator.swift` | 多文件 workspace edit 预览/确认；UTF-16 位置、重叠 edit、dirty/外改冲突安全；解决 F2 冲突 | P4 / L03、WS、TX、CMD |
| L10 Language Servers 面板 | `toggle-language-servers` / — | E-CMD 194；E-LSP 64 | **已接入，待真实 LSP/VoiceOver 验证**：route/panel 显示实例、能力、诊断、日志与状态，N-APP 1247、`LanguageServerPanelView.swift` | 显示 root/command/PID、starting/running/stopping/stopped/error、能力、原因和 restart | P4 / L03、A11Y、L10N |
| L11 重启服务器 | 面板 Restart / — | E-BRIDGE 288；E-LSP 559 | **已接入，待真实 LSP 验证**：选定 generation 的 restart/busy/error state，`LanguageServerController.swift` 340 | 仅重启所选实例；按钮 busy；错误可重试；旧事件不覆盖新实例状态 | P4 / L10 |
| L12 有界 LSP 日志 | 面板 log / — | E-IPC 775；E-FS 203 | **已实现**：日志按条目/字符/速率有界，panel 只保留清洗摘要，`LanguageServerProtocol.swift`、N-TOOLS | 只展示 bounded stderr/server notification 摘要，不展示原始协议；速率/字节/条数截断有提示 | P4 / L03、SEC、A11Y |
| L13 协议与进程防护 | 无用户 ID | `lspProtocol.ts`；E-FS 220 | **已接入，待真实异常进程验证**：header/payload/stdin queue/timeout/generation/cleanup 防护均在 production client，`LanguageServerProtocol.swift`、`LanguageServerClient.swift` | 15s initialize timeout；畸形/超限 frame、stdin queue 溢出或异常退出终止 server；资源全部回收 | P4 / PROC、SEC |

## 13. 插件、市场、片段与宏

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| P01 安装本地声明式插件 | `install-plugin` / — | E-CMD 166；E-IPC 66 | **已实现**：local panel → bounded manifest/worker parse → descriptor-anchored copy/publish → project enable；目录发布后若 project state 落盘失败会同步回滚并 fsync，N-PLUGIN、`PluginManagerView.swift` | 仅接受合法 manifest/ID 和 workspace 范围目标；复制而非执行任意安装脚本；目录与启用状态要么同时提交、要么恢复到安装前 | P4 / WS、EXT、TRUST |
| P02 管理/移除插件 | `manage-plugins` / — | E-CMD 167；E-IPC 69 | **已实现**：manager UI 列表/enable/remove，确认后先原子 detach，再提交 project state，最后移系统废纸篓；状态写或 Trash 失败均恢复目录/状态；worker/routes 在确认流程中停用，N-PLUGIN | 列出 enabled 插件；移除成功后停止 worker、清理动态命令/权限；任一持久化/Trash 失败不留下半卸载状态 | P4 / P01、EXT |
| P03 声明式插入文本命令 | 命令面板中的插件动态 ID | E-IPC 399；E-DISPATCH 5195 | **已实现**：dynamic declarative route → SelectionSet text transaction；禁用即重建 routes，N-PLUGIN、N-VIEW 624 | 命令只插 manifest 声明文本；项目禁用后立即消失；与多选区/undo 一致 | P4 / P01、PAL、SEL |
| P04 项目/插件 snippets 列表 | `insert-snippet` / — | E-CMD 106；E-DISPATCH 4467 | **已实现**：菜单/route 将 project + enabled plugin snippets 合并/筛选 picker → transaction，N-CMD、`MacroSnippetController.swift` | 菜单与命令面板均可达；汇总项目和启用插件片段；scope/trigger 过滤；模糊选择；插入一次撤销 | P4 / W16、PAL、TX |
| P05 Snippet 占位符与镜像 | `insert-snippet` 后 Tab/⇧Tab | E-EDIT 963 | **已实现**：numbered/default/mirror/final placeholder session 接 NativeTextEditor Tab/Shift-Tab，`Snippet.swift`、`MacroSnippetController.swift` | 支持 numbered default、重复编号镜像、最终停靠位；编辑映射与 Esc/文档切换退出正确 | P4 / P04、TX、SEL |
| P06 导入 Sublime Snippet | `import-sublime-snippet` / — | E-CMD 185；E-IPC 60 | **已实现**：bounded XML parse → preview/confirm → project snippet，`SublimeImportProduction.swift` | 解析 XML/字段、预览后写项目声明；不执行脚本；非法/超大输入拒绝 | P4 / P04、导入解析器 |
| P07 插件 Web Worker 扩展 | 动态命令，无固定 ID | `extensionHost.ts` 17；E-IPC 406 | **已接入，待真实签名 Sandbox 验证**：独立 `LumenPluginWorker`/JavaScriptCore 进程、bounded JSON protocol 与回收，`PluginWorkerRuntimeController.swift` | worker 无 DOM/Node/Electron/fs/network 直接权限；消息 schema/长度有界；崩溃隔离 | P4 / EXT、SEC |
| P08 插件文档读/写权限 | 首次权限确认 | E-IPC 396；`extensionHost.ts` 68 | **已接入，待真实签名 Sandbox 验证**：read/edit 分权、每配置审批、permission-filtered context 与 revision transaction，`PluginWorkerRuntimeController.swift` | `document-read`/`document-edit` 分离、按插件/项目持久；未授予时上下文不含文档且 replace 被拒绝 | P4 / P07、TRUST |
| P09 浏览 HTTPS Marketplace | `open-marketplace` / — | E-CMD 163；`marketplace.ts` 5 | **已接入，待真实网络验证**：project HTTPS sources → bounded catalog → marketplace UI，`MarketplaceClient.swift`、`MarketplaceView.swift` | 仅项目配置 HTTPS 源；列表有界并展示 id/name/version/description；网络错误不影响编辑 | P4 / WS、EXT、SEC |
| P10 安装 Marketplace 插件 | 市场确认按钮 / — | E-IPC 431；E-FS 1921 | **已接入，待真实网络/签名 Sandbox 验证**：HTTPS/no-redirect/same-origin/SHA-256 校验后安装，`MarketplaceClient.swift` | manifest HTTPS；worker 必须同源 HTTPS 且 SHA-256 integrity 匹配；确认后安装，无重定向降级 | P4 / P09、SEC |

插件 workspace lifecycle 以 canonical root 为 identity：没有 replacement store 时重复发布同一 root 是 no-op，保留 descriptor、动态 command/snippet、权限与 live runtime；真实 root 变化会立即撤下旧 workspace 的动态状态。
| M01 开始/停止宏录制 | `record-macro` / — | E-CMD 102；E-DISPATCH 4348 | **已实现**：菜单/route → router execution observer + raw transaction recorder，排除自身/失败并限制 1,000 步，N-CMD、`MacroSnippetController.swift` | 菜单与命令面板均可达；记录受支持命令及低层编辑，不记录自身/危险 UI；最多 1000 步；状态可见 | P2 / CMD、TX |
| M02 运行最近宏 | `run-macro` / — | E-CMD 103；E-DISPATCH 4361 | **已实现**：菜单/route → strict async replay、防递归、首失败停止，N-CMD、`MacroSnippetController.swift` | 菜单与命令面板均可达；严格顺序重放；防递归录制；文档/选择前置条件失败时停止并反馈 | P2 / M01 |
| M03 保存宏 | `save-macro` / — | E-CMD 104；E-IPC 71 | **已实现**：菜单/route → workspace-scoped bounded atomic macro store 与命名 UI，N-CMD、`MacroSnippetController.swift`、`MacroStore.swift` | 菜单与命令面板均可达；仅 workspace 内声明文件；名称/步骤/编辑严格清洗和大小限制；不存任意代码 | P4 / WS、M01 |
| M04 运行已保存宏 | `run-saved-macro` / — | E-CMD 105；E-IPC 70 | **已实现**：菜单/route → saved-macro fuzzy picker 与兼容格式 replay，N-CMD、`MacroSnippetController.swift` | 菜单与命令面板均可达；模糊选择；兼容命令/step/旧 snapshot 格式；未知命令安全跳过或报错 | P4 / M03、PAL |

## 14. 设置、快捷键、会话与 i18n

### 14.1 设置与导入

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| C01 图形设置面板 | `open-settings` / `⌘,`（菜单有；面板无 hint） | E-MENU 289；E-SETUI 14 | **已接入，待 macOS GUI/A11Y 验证**：SwiftUI Settings scene 覆盖 21 行/22 字段，runtime consumers、350ms 原子保存与失败重试，N-SETAPP、N-APP | 原生表单可键盘访问；变更即时应用或明确标 stored-only、校验并原子保存；关闭/退出 flush；失败可见可重试 | P1 / GUI、A11Y 测试 |
| C02 界面语言设置 | 设置 `locale` | E-SET 499；E-SETUI 55 | **已接入，待真实 macOS GUI/系统 role 验证**：持久 locale 在首个菜单/窗口帧前注入，runtime 切换即时驱动窗口、菜单和主要 panels；没有 editor window、仅打开 Settings 的启动/切换路径也已接通。Update、Sublime import、Recent Items、Navigation 以及 Workspace/Plugin/Git/Build/Terminal/LSP 等 app-owned 状态均保留 typed payload 到渲染边界；未知系统、网络、插件和工具原文保持 verbatim，N-L10N、N-APP 1158 | 启动首帧读取；Settings-only 与编辑窗口路径均可切换并持久；窗口、菜单、对话框、状态及辅助标签同步，无需重启；外部原文不被英文反向匹配误翻译 | P1 / L10N、真实 GUI |
| C03 字号设置 | `fontSize`，8–40 | E-SET 500；E-SETUI 67 | **已实现**：设置页 + 缩放命令即时应用/持久，N-SETAPP 70、N-TEXT 153 | 数值 clamp/取整与 Electron 一致；立即应用全部视图并持久 | P1 / GUI 测试 |
| C04 Tab 宽度与插入空格 | `tabSize` / `insertSpaces` | E-SET 501；E-SETUI 68、85 | **已实现**：设置即时驱动 editor tab stops、Tab insertion 与 indent commands，N-PANE、N-TEXT | 1–16；Tab 输入/缩进显示一致；已有正文不被设置变化重写 | P1 / TX 接线 |
| C05 主题和配色 | `theme` / `colorScheme` | E-SET 504、518 | **已实现**：theme 与四种 editor palette 均即时渲染并持久，`ColorSchemeController.swift`、N-PANE | dark/light UI 与四编辑配色分别持久；组合迁移规则明确 | P1/P3 / 语言层 |
| C06 视图布尔项 | `wordWrap/showLineNumbers/showMinimap/showIndentGuides/showWhitespace/highlightTrailingWhitespace` | E-SET 505 | **已实现**：六个视图项均传入 production editor 并即时绘制，N-PANE 765、N-TEXT | 每项独立、即时、全 tab/group、生效不改正文；未知/非法值回默认 | P1–P3 / 各视图能力 |
| C07 rulers | `rulers` | E-SET 512；E-FS 1147 | **已实现**：清洗后的 rulers 即时绘制，N-PANE 768、N-TEXT 1828 | 与 Electron 一致：原始值 `0<n<=500` 后取整、最多 10，不擅自排序/去重 | P2 / V18 |
| C08 文件大小上限 | `maxFileSizeMB`，1–200 | E-SET 514；E-FS 1150 | **已实现（下次启动生效）**：启动时换算并注入 AppModel；跨平台/原生新安装默认 200 MiB，无版本或 v1 的旧默认 20 MiB 配置自动迁移为 200 MiB，v2 显式值保持不变；设置页明确已开文档不受影响 | 启动读取驱动所有后续打开；边界按字节；当前超限 tab 不被静默丢弃；生效时机有说明 | P1 / 启动集成测试 |
| C09 Build 命令设置 | `buildCommand` | E-SET 516 | **已接入，待 macOS GUI/真实进程验证**：panel 从共享/项目设置 hydrate，但自由输入只保留内存草稿；审批后、启动前执行 revision-pinned 项目写入与同步全局写入，失败 checked rollback，N-TOOLS | 最长 1000 UTF-16 units；拒绝不持久；写入/补偿失败有 typed issue 且不启动；项目命令优先 | P4 / B01、GUI |
| C10 拼写、自动保存、专注、大纲 | `spellCheck/autoSave/autoSaveDelayMs/distractionFree/showOutline` | E-SET 519 | **已实现**：spell check、auto-save、distraction-free 与 outline 均有 runtime consumers，N-APP、N-VIEW | 各值 bounds/default 与 Electron 一致，并分别通过 V23/V24/F22/N19 验收 | P1–P3 / 各功能接线 |
| C11 搜索/替换历史设置 | `searchHistory/replaceHistory` | E-SET 528 | **已实现**：Find/Find in Files 成功操作写共享有界 history，两个 panel 提供重用菜单，N-FIND、N-WSEARCH | 每组最多 50、每项 2000 UTF-16；最新优先、去重；空替换可重用；跨重启恢复 | P3 / GUI、A11Y |
| C12 设置存储韧性 | 无命令 ID | E-FS 956、1130 | **已实现**：字段清洗、默认、有界读取、损坏隔离和 atomic write 已接 SettingsController 并有测试，N-SETSTORE 53、N-SETAPP 38 | 缺失/不可读用默认；合法非 object 用默认；损坏文件隔离；未来版本可读已知字段但拒绝覆盖；部分坏字段不吞好字段 | P1 / GUI/失败路径测试 |
| C13 导入 Sublime Settings | `import-sublime-settings` / — | E-CMD 184；E-IPC 28 | **已实现**：bounded settings import preview/confirm → `SettingsController`，`SublimeImportProduction.swift` | 仅映射支持字段；`draw_white_space`/`line_numbers` 语义准确；预览/确认；其他设置不被重置 | P2 / C01、导入解析器 |
| C14 导入 Sublime Keymap | `import-sublime-keymap` / — | E-CMD 186；E-IPC 61 | **已实现**：known-command/context import、skipped report、project persistence 与 live keyboard relay，`SublimeImportProduction.swift`、N-ROUTER | 只映射已知命令与支持上下文；报告 skipped；导入后不触发命令 | P2 / CMD、W16、导入解析器 |
| C15 项目快捷键覆盖与 key sequence | `keyBindings/keyBindingRules` | E-SET 639、672；E-DISPATCH 1335 | **已实现**：validated project rules、context matching、1.5s chords、冲突处理与 live router/keyboard overrides，N-ROUTER、`ProjectSettingsController.swift` | 支持单键/序列、1.5s 超时、editor/find-results/git/build context；冲突检测；系统保留键安全 | P2 / CMD、W16 |

### 14.2 会话与恢复

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| H01 打开标签与活动标签恢复 | 内部 `persist-session` / — | E-EVENT 1030；E-IPC 611 | **已实现**：版本化 tab snapshot，N-SESSION 77、N-MODEL 370 | 重启保持顺序/活动 tab；clean 文件从磁盘重读；最多 100 tab；无 session 时建一个 untitled | P0 / — |
| H02 dirty 文件草稿热退出 | 内部 `persist-session` | E-IPC 563；E-DISPATCH 5499 | **已实现**：当前/保存基线均存、350ms 防抖，N-MODEL 479、718 | 强退后恢复精确文本和 dirty；不偷偷写源文件；磁盘同时改变则恢复显式 conflict | P0 / 崩溃/断电演练 |
| H03 未命名草稿恢复 | 内部 `persist-session` | E-IPC 563 | **已实现**，N-MODEL 446 | 有内容/格式变化草稿恢复为 untitled；名称不碰撞；保存仍询问路径 | P0 / — |
| H04 文件丢失/二进制/超大时恢复草稿 | 内部 `persist-session` | E-DISPATCH 563 | **已实现**：转 recovered untitled，N-MODEL 383、683 | 只要存在可恢复变化就保留；路径解绑、requiresSave=true、原始名称可辨识 | P0 / — |
| H05 编码/EOL metadata-only dirty 恢复 | 内部 `persist-session` | E-IPC 582 | **已实现**，N-SESSION 24、N-MODEL 386 | clean text + pending encoding/EOL 仍为 dirty；保存使用新格式；磁盘改变产生冲突 | P0 / — |
| H06 选择恢复 | 内部 `persist-session` | E-IPC 598 | **已实现**：v2 production session 保存/恢复 directed multi-selection/main index 并 clamp，N-MODEL 1875、1958 | UTF-16 范围 clamp；方向保留；完成 SEL 后恢复多选区和 main index | P0/P2 / SEL、v2 接线 |
| H07 分栏布局、组内顺序和滚动恢复 | 内部 `persist-session` | E-IPC 602、623 | **已实现**：layout/group order/viewID selections/scroll 均进 production v2 snapshot/restore，N-MODEL 1891、1935 | layout kind/active group/group tab order/selection/scroll 恢复；undo/fold 明确不跨重启 | P2 / GROUP、v2 接线 |
| H08 workspace/project session 恢复 | `open-folder` 等 | E-IPC 617 | **已接入，待真实 Sandbox 恢复验证**：folders/primary/project 由 session 恢复到 workspace/bookmark controller，N-MODEL、N-APP | 多根、primary root、项目配置与最近状态恢复；不存在 root 不阻塞草稿恢复 | P3 / WS、v2 接线 |
| H09 固定标签与书签恢复 | `toggle-pin-tab` / `toggle-bookmark` | E-IPC 568、596 | **已实现**：pinned/bookmarks 从 production document snapshot 双向恢复，N-MODEL 1496、1951 | pinned 顺序/批量保护、1-based bookmark 行跨重启；文件内容变化时安全 clamp | P2 / T02、N13、v2 接线 |
| H10 会话大小/数量预算 | 无用户 ID | E-IPC 103；E-FS 1307 | **已实现**：100 tab、200 MiB draft、208 MiB snapshot，N-SESSION 127 | 写前和读前均限制；整数溢出安全；超限拒绝且旧快照保留 | P0 / — |
| H11 原子写、损坏隔离与版本迁移 | 无用户 ID | E-FS 965、1307 | **已实现**：原子 Data.write、非法/未来版隔离，N-SESSION 200、237 | 半写不替换旧 snapshot；损坏文件唯一重命名；unsupported version 不误解码；启动可继续 | P0 / — |
| H12 窗口关闭 flush handshake | 内部 `persist-session` / — | E-SHELL 94 | **架构替代已接入，待 macOS GUI 验证**：同步 flush + async quit/close dirty review；单窗 projected snapshot 在 AppKit 真正 close 前由 durable marker/live backup 保护，启动时恢复未完成 close；全局 Quit 以 participant manifest 防止损坏 marker 误恢复混合代，N-MODEL、`WindowCloseGuard.swift` | 正常关窗/退出在允许关闭前完成最新 snapshot；任一写失败或缺失工件 fail closed；close 前崩溃不丢 reviewed dirty draft | P0 / GUI 测试 |
| H13 多窗口独立 session | `new-window` / `⇧⌘N` | E-IPC 37；E-SHELL 2011 | **已实现**：合法稳定 ID、`session-<id>.json`、legacy 接管、最近 12 个持久 session/几何恢复及并发 registry，`WindowSessionCoordinator.swift`、N-RECENT | 每窗口稳定 ID/独立 session；按 Electron 基线重启恢复最近 12 个已持久窗口；并发落盘不互相覆盖 | P2 / WN01、session v2 |
| H14 最近关闭标签栈 | `reopen-tab` / `⇧⌘T` | E-CMD 41 | **已实现**：运行期有界 recently-closed LIFO；按 Electron 语义不跨重启，N-MODEL、N-ACT | 见 T06；明确是否持久化（Electron 只承诺运行期 LIFO） | P2 / T06 |
| H15 导航历史不跨重启 | `navigate-back/forward` | E-NAV 95；用户指南 Session Restore | **已实现（有意不持久）**：runtime navigation controller 已接，session schema 不序列化 history，N-NAV | 重启后 back/forward 为空；session schema 不序列化 NAV；本次运行照 N11/N12 | P2 / NAV 接线 |

### 14.3 国际化

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| I01 切换简体中文 | `set-ui-language-zh` / — | E-CMD 187；E-MENU 294 | **已接入，待真实菜单/VoiceOver 验证**：启动首帧注入持久 zh-CN，route/settings 可即时切换并持久；Settings-only 生命周期也建立 locale/menu 环境。已产生的 Update、Sublime import、Recent Items、Navigation、Workspace、Marketplace/Plugin、Find 与 command palette typed 状态在渲染时按新 locale 重绘，N-APP 1158、N-L10N | 当前窗口与 Settings-only 场景立即改中文并持久；聚焦窗口驱动菜单；屏幕状态与 VoiceOver 使用同一当前 locale | P1 / L10N、SET、真实 A11Y |
| I02 切换英文 | `set-ui-language-en` / — | E-CMD 188；E-MENU 295 | **已接入，待真实菜单/VoiceOver 验证**：与 I01 对称；持久 en-US 在首个菜单/窗口帧前生效，Settings-only 场景不依赖已有 editor window；typed issue 不固化创建时语言，N-L10N | 与 I01 对称；启动读 en-US 时菜单、Settings 与编辑窗口首帧不闪中文；既有错误随切换重绘 | P1 / I01、真实 A11Y |
| I03 菜单、命令标题与 role 本地化 | 无独立 ID | `i18n.ts`；E-MENU 7 | **已接入，待打包 AppKit 菜单验证**：typed catalog/169 命令标题与自定义菜单可在首帧按持久 locale 构建，并支持仅 Settings 窗口时更新；系统 role 由 AppKit 参与呈现，应用自有参数保留结构化值，N-CMD、N-L10N | 所有 Lumen 命令和 About/Services/Hide/Quit/Window 标签覆盖中英；首帧与 Settings-only 菜单一致；系统 role 在打包应用中跟随语言且 shortcut/selector 不变 | P1 / L10N、CMD、真实 GUI |
| I04 面板、状态、错误与辅助名称本地化 | 无独立 ID | E-DISPATCH 5226；各 renderer 组件 | **已接入，待真实 VoiceOver 审计**：主要 View 均接 runtime locale；Update、Sublime import、Recent Items、Navigation、Workspace/Workspace Search、Project Settings、全局 Settings 持久化、AppModel 文件/保存/session、EditorConfig、Language Tools/格式化、Marketplace/Plugin、Find、Git（含标题、discard/branch preflight 与命令失败传递）、Build、terminal、审批与 app-owned validation 使用 typed payload，动态上限、ID、URL、path、errno、诊断等参数原样嵌入；Find 屏幕与 VoiceOver 共用 formatter。未知系统/网络错误、插件/工具 stderr 明确保持 verbatim，不靠英文字符串反向匹配、不伪翻译，N-L10N | 应用自有 UI 字符串按当前 locale 渲染；运行中切换不保留旧语言；外部原文边界明确；VoiceOver 与屏幕文案一致且不泄漏/改写参数 | P1–P4 / L10N、A11Y、真实 VoiceOver |
| I05 产品名、bundle development region 与 locale 回退 | 无独立 ID | E-PACK 1；N-PLIST 5 | **部分**：bundle 名/region 与 zh-CN fallback 已实现；About/Finder/system role 的打包实机一致性未验证，N-PLIST、N-L10N | 系统 About/Finder/菜单名称一致；未知 locale 安全回落 zh-CN；不把 plist region 当完整 i18n | P1/P5 / L10N、DIST |

Settings-only 生命周期不注册 editor composition：此时 catalog 仅暴露 `new-window`、`open-settings`、`check-for-updates`、`set-ui-language-zh`、`set-ui-language-en` 五个应用命令，并保留标准 About/Services/Hide/Hide Others/Show All/Quit 与 window miniaturize/zoom/full-screen/front actions；文档/workspace 命令不会泄露。

## 15. Accessibility

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| A01 编辑器、标签和状态栏语义 | 无独立 ID | `index.html` 13；E-DISPATCH 5756 | **已接入，待 VoiceOver 实机验证**：主 `NSTextView` 有稳定 `lumen.editor.pane.<view>.text` identifier 与本地化 label；fold gutter 使用稳定 `lumen.editor.fold.gutter`，并为每个可见 marker 暴露独立 label/value/frame/action 与精确 region ID，N-A11Y、N-TEXT、N-PANE、N-VIEW | VoiceOver 能识别窗口、tab、编辑器与状态；逐 marker fold/unfold 及行范围可感知且不混淆 diff/diagnostic lane；同文档多窗格 ID 可区分 | P1/P3 / A11Y、GUI 测试 |
| A02 命令/Goto picker 语义 | `command-palette` 等 | `palette.ts` 51 | **已接入，待 VoiceOver 实机验证**：command/navigation pickers 有键盘流程、labels、selected/status identifiers，`CommandPaletteView.swift`、`NavigationPaletteView.swift` | dialog+combobox/listbox；expanded/busy/activedescendant/selected 正确；键盘全流程和关闭焦点恢复 | P1/P2 / PAL、A11Y |
| A03 设置/搜索等侧板、审批与破坏性对话框语义 | 各 panel 命令 | E-SETUI 35；E-SEARCH 60 | **已接入，待 VoiceOver 实机验证**：settings/search/tool panels 均有稳定 a11y IDs、关闭控制与焦点恢复路径；language tool/LSP/plugin worker 审批及通用 OK/Cancel/Don’t Save/Save/Reopen/Reload 共 12 个 action ID 已集中定义并由单测保证唯一稳定，N-A11Y、`EditorWindowView.swift`、各 View | 每板有名称/heading/region 或 dialog；关键审批/破坏性按钮可稳定定位；隐藏时不进焦点；Escape/关闭回到调用点 | P1–P4 / 各面板、A11Y |
| A04 结果列表键盘操作 | Find/Build/Git/LSP/Outline 结果 | `findResults.ts` 109；E-BUILD 152；E-GIT 392；E-LSP 373 | **已接入，待 VoiceOver 实机验证**：Find/Build/Git/LSP/Outline lists 有键盘选择/激活及状态 labels，N-A11Y、各 panel View | 上下/Home/End/Enter/Space 与 roving tabindex；选择、当前位置、错误均可感知 | P3/P4 / 各面板、A11Y |
| A05 状态与错误播报 | 无独立 ID | `index.html` 13；E-DISPATCH 5816 | **已接入，待 VoiceOver 实机验证**：alerts/status labels、稳定 IDs 与原生 `announcementRequested` 通道已覆盖 Find、workspace search、Build、terminal、LSP 的主要动态状态；仍需验证播报时机与去重，N-A11Y | 非阻塞状态 polite、错误 assertive 且不重复；保存/搜索/LSP/Build 动态状态可读 | P1 / A11Y、L10N |
| A06 键盘焦点可见与完整键盘访问 | 所有命令 | `styles.css` 88 | **已接入，待 Full Keyboard Access 实机验证**：原生 controls + custom picker/editor key paths，N-A11Y | Full Keyboard Access 下所有按钮/menu/tab/banner 可达；焦点清晰，不陷阱、不丢失 | P1–P5 / GUI 自动化 |
| A07 减少动态效果 | 无独立 ID | `styles.css` 1783 | **已实现（源码）/待实机验证**：主要动画读取 `accessibilityReduceMotion` 或共享 nil-animation helper，N-A11Y | Reduce Motion 下禁用/简化非必要动画；状态变化不依赖动画理解 | P1 / A11Y |
| A08 高对比/强制色/系统外观 | 无独立 ID | `styles.css` 1768 | **已接入，待高对比实机审计**：系统颜色、contrast-aware strokes 与非纯色状态标识已用；自绘 editor 仍需实机，N-A11Y、N-TEXT | Increase Contrast/深浅色/色彩滤镜下焦点、选区、dirty、冲突、ruler 达 WCAG；信息不只靠颜色 | P1 / A11Y、设计 tokens |
| A09 字号缩放与 Retina | `font-zoom-*` | E-CMD 131 | **已接入，待 Retina/多显示器实机验证**：8–40 runtime zoom 已闭环，N-SETAPP、N-TEXT | 8–40 缩放时编辑、行号、状态、弹窗不截断；Retina/多显示器清晰 | P1 / 真实 Mac |
| A10 VoiceOver 与 GUI 自动化门禁 | 无独立 ID | Electron CI smoke：`index.ts` 398 | **未完成（源码/单测证据增强）**：主 NSTextView 的稳定 ID/本地化文档与窗格 label、诊断 help，以及 12 个审批/破坏性 alert action ID 均有单测；但尚无真实 Apple Silicon VoiceOver/XCUI 门禁，Linux 也不能执行该验收 | 对 P0–P4 关键流程建 XCUI/Accessibility regression；至少真实 Apple Silicon + macOS 14 验收 | P5 / A11Y、CI |

## 16. Security 与信任边界

| 项 | Electron 命令 ID / 默认快捷键 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| SEC01 renderer 进程隔离的原生替代 | 无用户 ID | E-SHELL 145；E-BRIDGE 59 | **架构替代已实现**：原生 UI 无 web renderer/Node；插件 JavaScript 与 production parser JavaScript 分别运行于独立 `LumenPluginWorker`、每请求独立 `LumenParserWorker`，网络/外部命令使用受限服务，N-PARSER、N-TOOLS、N-PLUGIN | 威胁模型明确：UI 不等于不可信 web renderer；文档内容不能变主进程代码；parser 卡死由硬超时终止 helper | P0 持续 / 安全设计评审 |
| SEC02 文件/工作区授权边界 | 无用户 ID | E-FS 304、628；E-BRIDGE 94 | **已接入，待真实 Sandbox 验证**：文件/工作区 Powerbox URL 建立独立有界 app-scoped bookmark；session/recent 恢复、stale 刷新、目录 descendant、引用计数 lease 与关闭/移除释放已接生产路径；目录移动对 exact-file bookmark 使用持久化批量事务，重启按磁盘事实恢复，lease 获取失败仍让 document/navigation/session 跟随已提交路径；N-WS 继续校验 resolved-path/symlink 越界 | 打开/最近/session/workspace 全部使用可验证授权；重启权限有 security-scoped bookmark；canonicalization 防 symlink 越界；移动失败不遗留新路径 ghost capability | P5 / macOS 14 签名 Sandbox GUI 回归 |
| SEC03 安全读文件 | 无用户 ID | E-FS 757 | **已实现**：regular file、size、binary、编码 issue，N-CODEC 38 | TOCTOU 风险记录；有界读取；特殊文件拒绝；无效字节可查看但禁止危险覆盖 | P0 / 真实文件系统回归 |
| SEC04 revision 冲突与原子保存 | 无用户 ID | E-IPC 187；E-FS 733 | **已实现**，N-WRITE 31 | 见 F17/F18；任何冲突路径无 silent overwrite；同进程写串行 | P0 / — |
| SEC05 会话/设置输入验证与资源预算 | 无用户 ID | E-FS 1130、1307 | **已实现**：session/settings/project/recent/bookmark stores 均有 schema 清洗、预算、原子写与损坏隔离并接 production，N-SESSION、N-SETSTORE | 恶意/超大 JSON 不造成无界分配或启动循环；权限/数据保护策略审计；错误可恢复 | P0/P1 / SET 接线 |
| SEC06 外部 URL allowlist | `open-in-browser`、update、preview links | E-FS 3649 | **已实现**：Markdown 仅 http/https/mailto；update 仅固定 GitHub HTTPS；HTML 只开受控 file URL，N-PREVIEW、`UpdateService.swift`、`HTMLBrowserController.swift` | 只允许 http/https/mailto（按用途可更窄）；使用 `NSWorkspace.open` 前解析 URL；拒绝 file/custom schemes | P3 / PREVIEW；P5 / update |
| SEC07 Markdown/HTML 内容隔离 | `toggle-preview` / `open-in-browser` | E-PREVIEW 73；E-SHELL 127 | **已实现**：Markdown 是无 HTML/JS 的 native renderer；HTML 永不嵌入 WebView，临时快照有界/原子/清理，N-PREVIEW、`HTMLBrowserPreview.swift` | Markdown sanitizer 默认拒绝脚本/事件/危险 URL；HTML 永不嵌入高权限 app WebView；临时快照权限和生命周期受限 | P3 / PREVIEW、SEC06 |
| SEC08 外部命令首次确认 | Build/terminal/LSP/language tool | E-DISPATCH 5150 | **已接入，待真实签名 Sandbox 验证**：window/session-scoped approval 按 root+kind+resolved executable+argv+cwd+env+shell 完整 identity；formatter/LSP 的非系统 executable 还需先经用户 picker 与 security-scoped lease 加入会话 allowlist，项目设置无法静默授予，`ToolExecution.swift`、N-TOOLS | 每 app session、按 root+命令+args+cwd+env+shell+用途身份确认；项目文件不能静默执行 | P4 / PROC、TRUST |
| SEC09 外部进程资源限制与回收 | Build/terminal/LSP/parser worker | E-FS 203、3917 | **已接入，待真实签名 Sandbox/进程验证**：Build/LSP/workers 由 `posix_spawn` 在 exec 前原子建立独立 process group，并以 fd-safe pipe、sanitized env、cwd/argv/env 上限和无 shell argv 启动；Terminal 使用独立 `forkpty` C shim 建立 controlling terminal，fork 后先关闭应用继承 fd，再 `chdir`/`execve`，以同一验证/资源边界对已跟踪 login/foreground process groups 执行 TERM→KILL，并关闭 PTY 触发 hangup。两类 broker 均由 state queue、`DispatchSourceProcess` 与 `waitpid` 在发布终止前 reap，避免 PID reuse；Git 连续 root 切换/退出会等待所有前代 service 回收；Build 与 Terminal 均保留跨 chunk UTF-8 残尾，日志不损坏非 ASCII；parser helper 有低并发与 1 秒硬超时，N-PROC、N-PARSER | stdout/stderr、队列、frame、日志、诊断限额；100 次短命进程、PTY foreground job、leader 先退后代、连续 Git root 切换、超时/取消/窗口退出均确认进程/session 回收；分块中文/emoji 日志无损；无 shell 注入 | P4 / PROC、真实 macOS process/Sandbox |
| SEC10 Git 参数和凭据安全 | Git 面板 | E-FS 1962、2044 | **已接入，待真实 Git 验证**：argv `--`、root-relative path、bounded output 与 credential sanitization，`GitService.swift` | 用 argv 而非拼 shell；`--` 分隔路径；所有路径 root 限定；remote 凭据到 UI 前清除 | P4 / Git、PROC |
| SEC11 插件最小权限与供应链 | 插件/Marketplace | E-FS 1799、1921；`extensionHost.ts` 17 | **已接入，待真实网络/签名 Sandbox 验证**：schema/HTTPS/same-origin/integrity/permission 与 isolated worker 均在 production，N-PLUGIN、`MarketplaceClient.swift` | 见 P01–P10；manifest schema、HTTPS/同源/integrity、显式权限、隔离执行和可撤销安装完整 | P4 / EXT、TRUST |
| SEC12 应用沙箱、Hardened Runtime 与 entitlement | 无用户 ID | E-PACK 49；`entitlements.mac.plist` | **已配置，待真实签名 Sandbox 验证**：主 App、`LumenPluginWorker` 与 `LumenParserWorker` 使用分离最小 entitlements；两个 helper 均校验 app-sandbox/inherit，Developer ID runtime signing 与 CI verification 已写入；Linux 未执行真实签名/公证，N-DIST | 决定并记录 App Sandbox 策略；主程序与两个 helper 使用最小 entitlement；Developer ID hardened runtime；不为便利扩大权限 | P5 / 真实 macOS、DIST、PROC helper 决策 |
| SEC13 敏感数据与日志 | 无用户 ID | E-LSP、E-GIT、E-TERM | **部分（政策与验收已定义）**：Git/terminal/Build/LSP/plugin 已有 bounded/sanitized observable logs；session 为恢复未保存编辑而在本机保存全文草稿。Native preview 不上传应用自有 telemetry/crash report；用户删除 Application Support 下的 native preview 目录即可清除本地状态。发布前按 N-ACCEPT G02/G03 复核实际产物、日志与未来采集变更 | session/settings/临时预览只留在 app container；日志不含 token、完整正文或未脱敏 remote URL；任何未来 telemetry/crash upload 必须先记录字段、保留期、用户控制并补脱敏测试 | P5 / 安全与隐私评审 |

## 17. 构建、测试与 Release

> 本节的“Build”指构建和发布原生应用本身；第 11 节的 Build 是编辑器内部运行项目任务，两者不能混同。

| 项 | Electron 基线 / 入口 | Electron 关键源 | 原生状态（实查） | 对等验收标准 | 阶段 / 依赖 |
| --- | --- | --- | --- | --- | --- |
| R01 Swift Package 描述与最低系统 | `swift package describe`；macOS 14+ | N-PKG | **已配置/待 macOS 执行验证**：Swift tools 5.10、Core、App、plugin worker、parser worker 与两 test targets、macOS 14 minimum；Linux 不能解析 AppKit target，N-PKG | 在 Xcode 15.3+ 可解析；最低系统与 plist/文档一致；依赖锁定策略明确 | P0 / macOS runner |
| R02 单元测试 | `swift test` | Electron：`npm test`；原生 Tests | **已配置/测试资产存在**：command-parity gate 仅核对 Swift 测试文件与方法声明库存，不冒充 XCTest discovery/execution；parser bundle、Electron↔native command parity、packaging 与 release artifact contract 另有 Node/static gates；`verify.sh` 设置 `LUMEN_REQUIRE_WORKERS=1`，确保两个真实 worker integration tests 不会以 skip 伪绿；完整 AppKit/SwiftUI suite 由 macOS CI 实际执行 | macOS CI 全绿；覆盖边界、损坏、并发、迁移；失败阻断合并 | P0 持续 / N-CI |
| R03 Debug/Release build | `swift build` / `swift build -c release` | Electron `npm run build` | **已配置/待 macOS 执行验证**：CI 先构建 Debug helper、运行完整测试，再以 warnings-as-errors 构建全部 Release products；本次 Linux 不能验证 AppKit executable | clean checkout 两配置成功；warnings 策略明确；产物可启动；Apple Silicon/Intel 策略明确 | P0/P5 / macOS 14、Xcode 15.3+ |
| R04 本地 .app 组装 | `native-macos/scripts/build-app.sh` | Electron `dist:mac:local` | **已配置/待 macOS 执行验证（开发用途）**：脚本组装主程序、`LumenPluginWorker`、`LumenParserWorker`、plist/parser bundle/icon，逐字节核对资源，按最小 entitlement 签名并对主 App/两个 helper 做精确 allowlist；签名后从 `.app` 实际运行 parser smoke；CI 另通过 LaunchServices 启动完整 `.app`，确认 editor scene、可见 key-capable 内容窗口、main-actor 响应与正常退出并留 JSON evidence；Linux packaging contract 测试覆盖脚本、探针契约与资源复制，N-BUNDLE | 三个 Mach-O 与资源结构完整；签名/entitlement 严格校验；packaged parser 与普通窗口生命周期可运行；Finder 关联和图标仍需人工验收；明确不可分发 | P0 / macOS、codesign |
| R05 原生 CI | Native macOS CI | Electron CI：`.github/workflows/ci.yml` | **已配置**：macOS 14 workflow 校验工具链、Core/App tests、当前与另一架构 Release compile、含两个 worker 的 ad-hoc bundle/精确 entitlements/packaged parser smoke，并以 LaunchServices 执行 packaged-window smoke、上传 structured runtime evidence；push/PR paths 覆盖 Electron 命令源、矩阵、parser 与 packaging 输入，并运行 parser freshness、command parity、packaging/release artifact gates；本轮未触发远端 CI，N-CI | workflow 从已提交原生、parser、命令基线或 packaging 文件变更触发；测试/双架构编译/plist/helper/entitlement/resource/parser/window smoke/freshness 任一失败阻断；固定 action commit | P0 / 提交 workflow 与 native 目录 |
| R06 bundle 身份和数据隔离 | bundle ID `com.lumen.editor.native-preview` | E-PACK 1 | **已实现**：独立 ID、display name 和 Application Support 目录，N-PLIST 5、N-SESSION 158 | 与 Electron 同装同跑不覆盖设置/session/最近状态；显式迁移前禁止手拷 session | P0 / — |
| R07 文档类型关联 | Finder Open With | E-PACK 13；N-PLIST 33 | **已配置/待 Finder 实机验证**：Info.plist 注册 public text/source/json/Markdown，加上 `com.lumen.editor.native.text-document` 的常用源码扩展名声明；保留 `Alternate` handler、不抢默认应用；openURL 多文件路径已接，N-PLIST、N-APP | 安装后 Finder 关联及 openURLs 工作；不抢默认应用；声明的 UTI 均可安全打开 | P1/P5 / R04、GUI |
| R08 Developer ID 与 Hardened Runtime | 正式签名 | E-PACK 49；E-RELEASE 107 | **已配置/待真实凭据执行**：双架构脚本以 Developer ID、timestamp、Hardened Runtime 和分离 entitlements 依次签 `LumenPluginWorker`、`LumenParserWorker` 与主 App，并对最终签入 entitlement 做精确 key allowlist 校验，N-DIST | arm64/x64 的主程序与两个 helper 均具正确 Developer ID、架构、hardened runtime 和最小 entitlements；`codesign --strict` 通过且无意外扩权 | P5 / Apple 凭据、SEC12 |
| R09 Apple 公证与 stapling | 正式发布 | E-RELEASE 123、134 | **已配置/待真实凭据执行**：notarytool 提交 app ZIP/DMG、staple 与 Gatekeeper/stapler 验证均在脚本/workflow，N-DIST | app/DMG/ZIP 走 notarytool；stapler validate 与 Gatekeeper 在线/离线检查通过 | P5 / R08 |
| R10 DMG/ZIP 安装介质 | `dist:mac` | E-PACK 42 | **已配置/待真实凭据执行**：分别生成 thin x64/arm64 native DMG+ZIP；workflow 解压/挂载最终介质，复核三二进制架构、唯一 app、资源、签名与 parser smoke，并对 ZIP/DMG 内 app 各执行 LaunchServices window lifecycle smoke、保留 JSON evidence；复制品施加 quarantine 后继续复核 Gatekeeper/parser。未实现或声称 universal binary，N-DIST | arm64 与 Intel DMG/ZIP 命名一致；主程序和两个 helper 各自只有目标架构；挂载/解压后唯一 top-level app，签名、parser 与可见响应窗口 smoke 均通过；quarantine 人工首启仍须验收 | P5 / R08、R09 |
| R11 正式 release workflow 与不可变发布 | tag `v*` | E-RELEASE 1、286 | **已配置/待真实 tag 执行**：根 tag workflow 已构建并汇聚 Electron+native，校验 main/tag 后 draft→publish 且拒绝覆盖已发布 tag，E-RELEASE | tag 匹配版本且来自 main；先 draft、完整校验后发布；不得覆盖已发布 tag | P5 / R08–R10、GitHub environment |
| R12 校验和与 manifest | `SHA256SUMS.txt` / `release-manifest.json` | E-RELEASE 311 | **已实现（逻辑与合成资产测试）/待真实 release 执行**：完整 asset 集合校验并生成可复算 SHA256SUMS/manifest（含 tag/commit/bytes）；测试覆盖成功及 tag、缺失、多余、空文件、目录、symlink 拒绝，`scripts/release-artifacts.mjs`、`scripts/test-release-artifacts.mjs` | 每个 native asset 的文件名、字节、SHA-256、tag、commit 可复算且集合完整 | P5 / R11 |
| R13 应用内检查更新 | `check-for-updates` / — | E-CMD 162；E-IPC 94 | **已实现**：route → bounded redirect-free GitHub release check → architecture-specific native asset gate → 显示精确 URL 的本地化一次性确认；最终 open 边界重验结果快照与固定 GitHub HTTPS allowlist，`UpdateController.swift`、`UpdateService.swift`、`UpdateView.swift` | 只查 HTTPS 正式 release；版本比较正确；取消、结果变化或 unsafe URL 均不打开；不静默安装；错误不影响编辑 | P5 / SEC06、正式 release |
| R14 真机发行矩阵 | 手工验证 | N-ACCEPT | **未完成（验收计划已定义）**：A–H case、fixture、支持矩阵、证据字段及 PASS/FAIL/BLOCKED 发布判定已版本化；尚未在 Apple Silicon/Intel 产物上执行并留证 | Apple Silicon macOS 14 必测；若声称 Intel 支持则按 N-ACCEPT 记录真机/等价硬件覆盖；编码、IME、VoiceOver、Sandbox、Gatekeeper、升级/回退全过 | P5 / R08–R13 |

## 18. 命令与入口一致性债务

这些是 Electron 基线自身的可观察差异。原生版应以一个 typed command registry 生成菜单、命令面板、
快捷键和可用状态，而不是复制这些漂移；但默认行为变更必须作为产品决定记录。

| 差异 | Electron 证据 | 原生验收决定 |
| --- | --- | --- |
| `COMMANDS` 有 167 个唯一 ID；`command-palette` 与 `select-build-system` 只在 MenuEvent/菜单，不在面板清单 | E-CMD；E-MENU 214、266；E-DISPATCH 1387 | N-CATALOG 以 167+2 收录 169 个唯一 public ID，并实际驱动 menu/palette/keyboard/router；N-COVER 对真实 composition 断言 169/169 均有 route，静态门禁还直接解析 `EditorCommands.body`，核对实际 SwiftUI 菜单集合而非自报清单 |
| `MenuEvent` 有 172 个 union 分支、171 个唯一 ID；`import-sublime-build` 重复，`encoding-actions`/`persist-session` 仅为内部事件 | E-EVENT 858–1030；E-DISPATCH 1135、1296 | native catalog 不复制重复声明，也不把内部聚合/关闭握手暴露给宏或插件；169 public 与两项 internal concern 分层 |
| `file:new` IPC 定义但无 preload/handler；`new-file` 实际 renderer-only | E-IPC 9；E-DISPATCH 705 | 原生无需复制死通道；由 command service 直接创建模型对象 |
| 面板有、菜单无：`convert-indent-spaces/tabs`、三个 `convert-eol-*` | E-CMD 141–145；E-MENU | 原生 registry 保留这些 public ID；命令面板/快捷键 route 已可执行，菜单 surface 由 `EditorCommands` 显式选择 |
| 菜单 accelerator 有但面板 hint 缺：`new-window`、`open-settings`、`indent-selection`、`outdent-selection` | E-MENU 76、146、289；E-CMD 153、179、189 | 同一 Shortcut 定义生成两侧展示，自动测试完全一致 |
| 面板 hint 有但菜单 accelerator 缺：词删除、`select-line`、`split-selection-lines`、四个 fold 命令 | E-CMD 87、76、119、153；E-MENU | 区分 TextKit 内建 key equivalent 与 app accelerator，并用实际 key event 测试 |
| `next-bookmark` 与 `lsp-rename` 都声明 `F2` | E-MENU 204、264 | native keyboard resolver 按 context/enablement 优先 LSP Rename，再回退书签；显式 override 时遵循 override，N-ROUTER 637 |
| 用户指南中文搜索段把“选中所有匹配”写成 `⇧⌘L`，但实际 `⌥F3`；`⇧⌘L` 是拆分选区 | `USER_GUIDE.md` 933；E-CMD 73、153 | 原生以 registry 为准并生成快捷键文档；迁移说明标出变化 |
| 原生保留标准 macOS Edit roles，同时大量 Lumen actions 需要稳定 ID | N-CMD；N-CATALOG | 当前菜单已用 shared router/catalog 覆盖 File/Edit/Selection/Find/Goto/Tools/View，系统 cut/copy/paste roles 与应用级 transaction undo/redo 分工明确 |

## 19. 对等完成门禁

“功能对等”不能仅以源码中出现类型或按钮判定。准备把原生版称为 Electron 版替代品前，必须同时满足：

1. **清单闭合**：本文件所有 P0–P5 项均为已实现，或有经产品批准、写明理由和迁移影响的“不适用”。
2. **命令闭合**：Electron 的 167 个 `COMMANDS`、菜单专属命令、系统 role 和无 ID 交互都在原生 typed registry/测试中有映射；不能用“大体支持编辑”替代逐命令验收。
3. **数据安全**：编码矩阵、换行、外部冲突、symlink/hard link、原子保存、hot exit、损坏/超限 session 在单测和真实 APFS 上通过；任何失败都不静默丢失或覆盖用户数据。
4. **跨能力语义**：多选区、分栏、workspace、导航历史、外部变化、LSP workspace edit 等组合路径有集成测试，而非仅测各模块。
5. **安全边界**：外部内容、URL、Git、terminal、Build、LSP、插件都经过路径/协议/schema/资源限制及信任确认；原生架构的差异有威胁模型评审。
6. **可访问性与国际化**：简中/英文动态切换、Full Keyboard Access、VoiceOver、减少动态效果、高对比、IME 和 Retina 在打包后的 app 上验收。
7. **发行**：CI、Developer ID、Hardened Runtime、公证、stapling、DMG/ZIP、checksum/manifest、升级/回退和 arm64/x64 支持声明均由实际产物证明。

### 当前结论

截至 2026-09-07 的未提交工作树，原生版已不是“基础文本 MVP”：多窗口/v2 session、四种 pane、tab/多选区、
169 public command routes、含 Full Screen 及 Open Recent File…/Project… picker 入口的原生菜单、workspace/tree/search、导航、
预览、Git、terminal、Build、LSP、插件/worker、Sublime 导入、runtime settings 与更新检查都已形成 production
入口到 controller/model 再到 UI/transaction 的闭环。

仍真实未完成或仅部分对等的项目集中在以下边界：

- **parser 语义**：V01 已覆盖全部 143 种 language-data 语言；33 种 Lezer 语言提供 typed、exact-revision
  完整结构快照，110 种 Stream 语言提供 mode 高亮与可用缩进，但结构选择、outline、折叠等使用保守 fallback。
  V03 只有已有非空行的行首安全子集，且 revision、精确全文、语言和缩进设置均命中 cache 时使用 parser 缩进；
  planner 已对齐行首空白归一与 opener `closeBefore` 门禁，但新 revision 等待快照时仍走有界 fallback。因此全
  language-data 集合仍不宣称 AST 等价，V03 也保持“部分”。production JavaScript 每请求运行于独立
  `LumenParserWorker`，由 `ToolProcessRunner` 施加 1 秒硬超时和终止。基础分析立即启动，只有 cursor/newline probe
  使用 120ms 可取消 debounce；签名 Sandbox 实机行为仍待验证。
- **近期一致性闭环**：Git mutation 使用冻结确认、disk/revision preflight、owner 编辑锁与提交后文档协调；workspace replace/undo 以 Core mutation lease 把最终 root/path/revision 复验、整批提交与失败补偿置于同一 capability 生命周期；Build 自由命令仅在审批后、启动前事务持久化；Terminal 隐藏不终止 session；project exclusions 以 generation 覆盖 tree/watcher/search/replace/Goto；Find 精确绘制匹配并拒绝零宽替换，折叠 marker 以 O(n log n) 规划并保持当前文档内的稳定 VoiceOver identity。上述源码/测试接线不替代真实 Git、进程、GUI 与 VoiceOver 验收。
- **LSP 降级与诊断**：L04 的 panel 可保留有界 unversioned 诊断，gutter 则以 document identity、version、
  generation 三重匹配严格拒绝过期结果；close/stop/stopAll 已清对应 retained lifecycle state。L07/L08 已有
  无适用 LSP request 的项目符号/工作区全词搜索 fallback 及测试。真实 server 与 GUI 行为仍保留实机门禁。
- **runtime i18n**：持久 locale 已在菜单/窗口首帧前生效，Settings-only 生命周期可用；Save/Save As/Save All/Open、Language Tools、Navigation 与 Completion/LSP 的跨控制器失败现保留 typed 标题和消息，Update、Sublime
  import、Recent Items、Workspace/Workspace Search、Project Settings、全局 Settings 持久化、审批摘要、Git/Build/Terminal/LSP 与 app-owned validation
  均保留 typed payload 到渲染边界，运行中切换语言可重绘既有状态。未知系统/网络错误、外部工具与插件原文保持
  verbatim，不再因恰好匹配应用英文模板而被误翻译。C02/I01–I04 的源码契约已接入，真实 GUI/VoiceOver 仍是门禁；
  I05 继续因 About/Finder/system role 的打包实机一致性保持“部分”。
- **真实 macOS 验证**：本轮 Linux 审计不能运行 AppKit/SwiftUI、FSEvents、IME、Retina、Full Keyboard
  Access、VoiceOver，也不能证明 security-scoped bookmark、Git/终端/Build/LSP/plugin/parser worker 在真实签名 App
  Sandbox 内的行为；对应行保持“已接入/待验证”，A10 与 R14 仍未完成。
- **发行执行**：Developer ID、Hardened Runtime、notarytool、stapling、双架构 DMG/ZIP、checksum/manifest
  和不可变 tag workflow 已配置；尚需真实 Apple/GitHub 凭据跑出并验收产物，R08–R12 不记为已执行。

因此当前源码已覆盖 Electron 的主要功能面，但在上述 parser 等价、零混合语言、VoiceOver/Sandbox/真实外部
进程与正式签名公证实机门禁完成前，仍应以 native preview 身份与 Electron release 并行。
