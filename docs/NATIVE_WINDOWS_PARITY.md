# Lumen Editor 原生 Windows 功能对等清单

> 基线日期：2026-09-07。Windows 原生实现位于 `native-windows/`，以 Electron 的命令、IPC、菜单和用户行为为基线，并与原生 macOS 共享同一份文件关联、大小限制、批量打开和命令集合门禁。

## 判定规则

- **已实现**：用户入口、生产 controller、可观察 UI 与测试形成闭环。
- **核心已实现**：非 UI/平台基础模型和测试存在，尚未接入 Windows App。
- **已配置/待 Windows 验证**：MSIX、WinUI、Shell、App SDK 或 GUI 自动化需要真实 Windows runner/设备验收。
- **未实现**：尚无对应生产实现。

当前 `check:native-windows` 自动验证：

- Electron 的 **167** 个 `COMMANDS` 加两个菜单专属命令，必须等于 Windows 的 **169** 个 typed command ID；
- Electron、原生 macOS 与 Windows MSIX 清单的 **81** 个文件关联扩展名一致；
- 三端设置 schema v2、默认 `maxFileSizeMB = 200`、旧默认 20 MB 迁移语义一致；
- Electron 与 Windows 都使用多文件 picker、上限 100、逐文件打开且单项失败不丢弃其他选择；
- Windows 使用 WinUI 3 / Windows App SDK，且 package identity 与 Electron/macOS 原生 preview 隔离。
- WinUI XAML 的所有事件处理器必须存在；非 Windows 环境也会用 stub XAML 编译完整 code-behind。
- MSIX 项目必须真实声明 `WindowsPackageType=MSIX`、自包含 x64/arm64 RID、`runFullTrust`，包脚本会解包核对架构、可执行文件、图标和 81 项关联。
- Windows 与 macOS 复用同一份可复现的 CodeMirror/Lezer parser bundle 和锁定的语言元数据；Windows 目录必须包含 Plain Text + **143** 个 CodeMirror 语言，包必须包含该资源，parser schema v2、输入/输出预算、结构校验和独立 worker 可执行文件入口由静态门禁锁定。
- MSIX 必须只包含一个非空的 `LumenEditor.Windows.Worker.exe`，且 PE Machine 必须与 x64/arm64 目标一致；WinUI 主程序不再承担 parser/plugin worker 入口。
- Windows CI 会创建仅限 job 的测试证书，签名并安装 x64 MSIX，通过 AUMID 启动应用；门禁要求进程拥有可见、启用、非零尺寸的顶层窗口，UI Automation 可识别 `ControlType.Window` 与稳定 `LumenEditorRoot` 工作区，消息循环连续响应并能经 `WM_CLOSE` 正常退出。CI 与 tag release 都上传 structured JSON evidence；这仍不是 SmartScreen、Explorer、IME、Narrator 或完整 GUI 功能验收。

当前 Core 测试基线为 **185 项**；WinUI 生产路由已接入 **169/169** 个命令，Linux 上完整 code-behind stub 与 solution 编译要求 0 warning / 0 error。隔离的 `net8.0` worker 已在 Linux 以 self-contained single-file 真进程完成 parser schema v2 和 plugin 协议 smoke，Windows CI 还会对 `win-x64` worker 重复进程验证。静态门禁要求未实现命令集合为空，并锁定多选区、结构化输入、补全、诊断、折叠、行号、minimap、编辑器装饰、安全富 Markdown、深层 Git、隔离 worker 和 MSIX 资源的关键生产路径。命令路由完整仍不等于 Windows 发行验收完成。

编辑面已从单选区 `TextBox` 升级为原生 `RichEditBox` 适配层：主选区由系统控件持有，最多 10,000 个次选区由有界 UTF-16 模型维护并在可见区绘制；普通输入、删除、粘贴、Tab、带 parser 缩进的 Enter、括号/引号包围与空 pair 退格会作为一次事务复制到全部选区，整组选区可撤销/重做。IME 组合开始时主动收敛到系统主选区，避免复制未完成的组合文本。行号、空白字符、缩进线、竖直标尺、行尾空白、活动行、同词匹配、括号匹配、版本锁定的 LSP diagnostics、磁盘差异和 minimap 均为有界可见区/采样绘制；代码折叠通过 WinUI 文本对象模型的 hidden range 保留原始文本与 offset。补全只使用已由用户启动的 LSP，否则回退到有界工作区词索引，并锁定文档路径、revision 和光标位置防止过期结果写入。上述 GUI 行为仍需 Windows 真机验证。

## 当前分期

| 阶段 | 状态 | Windows 交付物 | 验收重点 |
| --- | --- | --- | --- |
| P0 | **实现完成；待 Windows 真机验收** | 设置/session v3 原子存储、最近文件/项目、100 文件批量打开、200 MiB 保护、传统编码、revision-checked writer、Save/Save As/Save All、三模式 Auto Save、固定标签、热退出、Explorer 激活 | MSIX 安装后的文件关联、多选冷/热启动、真实大文件、自动保存与外部冲突 |
| P1 | **实现完成；待 Windows 真机验收** | 原生 RichEditBox、多光标/多选区事务、parser-backed Enter 缩进、括号/引号配对、每文档 bounded undo/redo、选择历史与范围扩缩、Find/Replace 与持久历史、宏、书签、JSON、段落/缩进/编码/EOL、四套编辑器配色/拼写/软换行、行号/空白符/缩进线/rulers/行尾空白/minimap、代码折叠 | 多光标结构化输入、IME 收敛、组合字符、Narrator、High Contrast 与大文件装饰层性能 |
| P2 | **主要流程已实现；待真机验收** | 最近项、重开关闭、固定/批量关闭、single/2/3/4 pane、pane/session 恢复、Ctrl/Shift 多选文档拆分、导航历史、Goto Anything/符号/大纲、增量差异导航和单 hunk 回滚、项目片段 | 多选标签拆分、克隆文档与每窗格选区/折叠显示需真实 WinUI 验证 |
| P3 | **主要文件工作流与解析级能力已实现；待真机验收** | 最多 12 根、安全懒加载树、session 根恢复、watcher、项目 exclude 贯穿树/搜索/替换/Goto/符号/词索引、新建/重命名/回收站/Reveal；144 项语言目录；禁用原始 HTML、带严格 CSP 的 GFM Markdown WebView2 富预览及文本 fallback；共享 CodeMirror/Lezer schema v2 bundle 在独立 Jint worker 中为最多 128 Ki UTF-16/50,000 行的文档生成最多 20,000 highlights、10,000 folds 和 5,000 symbols；超限、不支持或 worker 失败时回退到最多扫描 2 MiB 的原生词法/折叠/符号分析 | Windows 进程 smoke 已接入 CI；真实 WebView2/主题/折叠叠加、连续输入取消、worker 恢复、watcher 和多根排除仍需 Windows 验收 |
| P4 | **主路径与隔离 worker 已实现；待真机验收** | shell-free 全局 Build Command 与项目构建、Sublime 安全迁移、Git porcelain v2 status/diff/多文件 stage/unstage/discard/commit/conflict/hunk/history/blame/分支、ConPTY、LSP 同步/format/rename/completion/版本锁定 diagnostics、工作区词补全、声明式插件、HTTPS 同源/SRI worker 安装、独立 Jint worker 可执行文件、权限批准、Job Object 回收和更新检查 | Git 复杂 rename/conflict/hunk、terminal 真机 resize/IME、LSP server 兼容矩阵、worker 进程与权限 UI 的 Windows smoke |
| P5 | **真实 MSIX 配置和安装窗口 smoke 已接入；待真机验收** | `WindowsPackageType=MSIX`、x64/arm64 self-contained RID、独立同架构 single-file worker、包内 `runFullTrust`/81 关联/资产/parser hash/依赖/PE 架构校验、每包 SHA-256、job 与正式签名 x64 包的安装/AUMID/可见响应窗口/UIA/正常退出/卸载 smoke 及 JSON artifact | SmartScreen、Explorer 打开方式、安装升级/回退、真实 ARM64 与辅助功能 |

## 首批实施证据

| 领域 | Windows 入口 | 当前状态 |
| --- | --- | --- |
| 文件关联 | [Package.appxmanifest](../native-windows/src/LumenEditor.Windows.App/Packaging/Package.appxmanifest) | **已配置/待 Windows Explorer 验证**：81 项文本/源码扩展名以 `windows.fileTypeAssociation` 声明，独立 preview identity。 |
| 文件选择 | [MainWindow.xaml.cs](../native-windows/src/LumenEditor.Windows.App/MainWindow.xaml.cs) | **核心已实现/待 WinUI 验证**：`FileOpenPicker.PickMultipleFilesAsync()` → shared batch open。 |
| Shell 激活 | [App.xaml.cs](../native-windows/src/LumenEditor.Windows.App/App.xaml.cs) | **核心已实现/待 Windows 验证**：`IFileActivatedEventArgs` 与 picker 使用相同的 `OpenPathsAsync` 路径。 |
| 文件保护 | [DocumentOpenModels.cs](../native-windows/src/LumenEditor.Windows.Core/Documents/DocumentOpenModels.cs) / [TextFileCodec.cs](../native-windows/src/LumenEditor.Windows.Core/Documents/TextFileCodec.cs) | **核心已实现**：100 文件上限、路径去重、200 MiB 限制、NUL binary 检测、BOM/UTF-16、严格 UTF-8 和行尾归一；单项失败保留其余成功项。 |
| 保存与恢复 | [FileWriteService.cs](../native-windows/src/LumenEditor.Windows.Core/Documents/FileWriteService.cs) / [SessionStore.cs](../native-windows/src/LumenEditor.Windows.Core/Documents/SessionStore.cs) | **核心已实现/WinUI 待验证**：SHA-256 revision preflight、原子替换、session v3 dirty draft/pane/bookmark/pin/root、最近项和 Auto Save。 |
| P1 编辑核心 | [EditorBuffer.cs](../native-windows/src/LumenEditor.Windows.Core/Editing/EditorBuffer.cs) / [EditorInputPlanner.cs](../native-windows/src/LumenEditor.Windows.Core/Editing/EditorInputPlanner.cs) / [MultiSelection.cs](../native-windows/src/LumenEditor.Windows.Core/Editing/MultiSelection.cs) / [CodeFolding.cs](../native-windows/src/LumenEditor.Windows.Core/Editing/CodeFolding.cs) | **已接入 WinUI/待真机验证**：UTF-16-safe 编辑、最多 10,000 个多选区、输入事务复制、parser 优先的 Enter 缩进、括号/引号配对、整组选区历史、正则替换与搜索/替换历史、行/词/段落/括号/缩进转换、宏、书签、四套配色、行号/空白符/缩进线/rulers/行尾空白/minimap、可聚焦 fold gutter 与 hidden-range 折叠。 |
| P2 分栏与导航 | [PaneLayout.cs](../native-windows/src/LumenEditor.Windows.Core/Layout/PaneLayout.cs) / [SymbolIndex.cs](../native-windows/src/LumenEditor.Windows.Core/Navigation/SymbolIndex.cs) | **已接入 WinUI/待真机验证**：single、2/3/4 pane，移动/克隆、Ctrl/Shift 多选文档按列表顺序拆分（最多四栏）、焦点循环、恢复、Goto Anything、当前/项目符号和常驻大纲。 |
| P3 工作区与预览 | [WorkspaceTree.cs](../native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceTree.cs) / [WorkspaceFileWatcher.cs](../native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceFileWatcher.cs) / [WorkspaceReplaceService.cs](../native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceReplaceService.cs) / [PreviewRenderer.cs](../native-windows/src/LumenEditor.Windows.Core/Documents/PreviewRenderer.cs) | **已接入 WinUI/待真机验证**：安全懒加载、多根恢复、watcher、递归搜索、结果定位与 revision-pinned 替换/撤销；有界项目 glob 排除使用同一不可变快照贯穿 tree/watcher/search/replace/Goto/符号/词补全，规则变化会作废替换预览；Markdown 经 Markdig 生成、禁用原始 HTML、施加 CSP 和 document budget。 |
| Parser worker | [CodeMirrorParserModels.cs](../native-windows/src/LumenEditor.Windows.Core/Parsing/CodeMirrorParserModels.cs) / [CodeMirrorParserWorkerProcess.cs](../native-windows/src/LumenEditor.Windows.Core/Parsing/CodeMirrorParserWorkerProcess.cs) / [Worker Program.cs](../native-windows/src/LumenEditor.Windows.Worker/Program.cs) | **已实现/进程 smoke 已接入**：共享冻结 bundle、schema v2 严格 DTO/结构验证、串行严格 UTF-8 JSON-lines、7 秒 deadline、最多四份可见文档 snapshot、512 MiB Job Object 与 parser 不可用时 fallback；Linux self-contained worker 真进程已通过，Windows EXE/Job 行为由 Windows CI 继续验证。 |
| P4 工具与迁移 | [ProjectBuildSettings.cs](../native-windows/src/LumenEditor.Windows.Core/Build/ProjectBuildSettings.cs) / [GitService.cs](../native-windows/src/LumenEditor.Windows.Core/Git/GitService.cs) / [LanguageServerClient.cs](../native-windows/src/LumenEditor.Windows.Core/Language/LanguageServerClient.cs) / [CompletionEngine.cs](../native-windows/src/LumenEditor.Windows.Core/Language/CompletionEngine.cs) / [MarketplaceClient.cs](../native-windows/src/LumenEditor.Windows.Core/Plugins/MarketplaceClient.cs) | **已接入主路径/待真机验证**：shell-free Build、自定义全局命令、Git 多文件与 hunk/history/blame/branch、ConPTY、LSP sync/format/rename/completion/diagnostics、工作区词 fallback、项目设置、Sublime 项目/设置/构建/片段/keymap、安全插件市场和更新检查。 |
| 插件 worker | [PluginWorkerProtocol.cs](../native-windows/src/LumenEditor.Windows.Core/Plugins/PluginWorkerProtocol.cs) / [PluginWorkerProcess.cs](../native-windows/src/LumenEditor.Windows.Core/Plugins/PluginWorkerProcess.cs) / [Worker Program.cs](../native-windows/src/LumenEditor.Windows.Worker/Program.cs) | **已实现/进程 smoke 已接入**：独立纯 `net8.0` 可执行文件、Jint 禁用 CLR/字符串编译、时间/语句/递归/内存预算、16 MiB JSON-lines、首次权限确认、revision-pinned 文档替换、512 MiB Job Object 和 kill-on-close；Linux 真进程协议已通过，Windows CI 继续验证 PE/进程/Job 行为。 |
| 文档生命周期 | [DocumentWorkspace.cs](../native-windows/src/LumenEditor.Windows.Core/Documents/DocumentWorkspace.cs) | **已接入 WinUI/待真机验证**：untitled、去重、dirty、Save All、固定/批量关闭、最近项和重开关闭文件。 |
| 命令目录 | [WindowsCommandCatalog.cs](../native-windows/src/LumenEditor.Windows.Core/WindowsCommandCatalog.cs) | **169/169 项生产 route**：catalog 与 Electron 基线一致；静态门禁要求未实现 ID 集合为空，并检查新增编辑器能力的关键实现锚点。 |
| MSIX 构建 | [LumenEditor.Windows.App.csproj](../native-windows/src/LumenEditor.Windows.App/LumenEditor.Windows.App.csproj) / [package-msix.ps1](../native-windows/scripts/package-msix.ps1) | **已配置/待远端 Windows CI 证据**：真实 MSIX 项、x64/arm64 自包含包、按目标 RID 先发布并注入独立 worker，包内 parser bundle/Jint/Markdig/App/worker/资产/PE 架构验证与 SHA-256 artifact；x64 安装包还需通过可见响应窗口/UIA/正常退出 smoke。 |

## Windows 真机验收

每次 Windows native preview 候选至少在 Windows 11 x64 的干净用户帐户完成以下检查，并保留 MSIX/MSIXBundle、commit、SHA-256、截图/录屏和 Event Viewer 脱敏输出：

1. Explorer 对 `.txt`、`.md`、`.json`、`.ts`、`.cs`、`.py` 右键“打开方式”可选择本应用；安装不会抢占其他应用默认关联。
2. 从 Explorer 多选文件打开、从运行中的应用 FileOpenPicker 多选、冷启动和二次激活都不会漏文件或重复标签。
3. 199 MiB 文本可打开；201 MiB 文本被拒绝并提示设置路径；二进制、无权限和删除中的文件都不会建假标签。
4. 中文 Microsoft Pinyin、emoji、组合字符、Ctrl/Ctrl+Shift 快捷键、剪贴板、Narrator、High Contrast 和全键盘访问通过。
5. parser-backed Enter/括号配对、多光标补全、LSP diagnostics/diff 装饰、Markdown WebView2、Git 多选/hunk/branch 和 ConPTY 在持续编辑与取消操作下无过期结果或 UI 卡死。
6. MSIX 签名、安装、卸载、升级/回退和 SmartScreen 行为符合发行策略。

在 P0–P5 全部实施并通过 Windows 真机验收前，Windows 原生版保持 preview 身份，与 Electron Windows release 并行。
