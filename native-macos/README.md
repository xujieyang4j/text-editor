# Lumen Editor 原生 macOS 版

`native-macos` 是 Lumen Editor 的 SwiftUI/AppKit 实现。它与 Electron 版共处同一仓库，但拥有独立 bundle ID、独立数据目录和独立发布产物。当前源码已经接通主要编辑器工作流，不再只是单窗口文本编辑 MVP；它仍需真实 macOS 设备上的 GUI、辅助功能、Sandbox 外部进程以及签名/公证验收。

## 已实现能力

- 原生编辑器：SwiftUI 外壳、AppKit `NSTextView`/TextKit 1、多标签与 1/2/3/4 编辑组、组内标签顺序、独立 selection/scroll、撤销/重做、原生查找栏、行号、支持点击与拖动导航的 minimap、空白符、软换行、拼写检查、折叠与增量 diff。Find 高亮绑定精确 document/view/pane/revision，支持 regex、大小写、全词及有界零宽结果；零宽替换会拒绝且不改正文。显式打开的 Find 在专注模式仍可见，Escape 先关闭 Find、再次按下才退出专注模式。production parser 每次请求都在独立 `LumenParserWorker` 中执行，并覆盖全部 143 种 CodeMirror language-data 语言：33 种 Lezer 语言提供完整结构数据，110 种 Stream 语言提供高亮与可用缩进。基础分析立即启动，只有光标相关的换行 probe 使用 120ms 可取消 debounce。
- 文件安全：新建、打开、保存、另存为、全部保存、恢复已关闭标签；UTF-8、UTF-8 BOM、UTF-16 LE/BE（含无 BOM）、GB18030、GBK、Big5、Shift JIS、Windows-1252、ISO-8859-1；LF/CRLF/CR；二进制/大小检查、SHA-256 revision 冲突检测、硬链接拒绝和原子替换。Open/Save/Save As/Save All 的模型失败保留 typed 标题、文件上下文和原因直到菜单/键盘反馈边界；首次打开、按编码重开或外部自动重载遇到不确定/无效字节时，会显示可关闭且随当前界面语言渲染的非阻塞提示。
- 多窗口与 hot exit：`WindowGroup` + `openWindow(value:)`；每窗口稳定合法 ID、独立 `AppModel` 和完整 controller graph、独立 `session-<id>.json`；旧 `session.json` 首次恢复及 V1→V2 迁移；按最近顺序恢复最多 12 个窗口；保存窗口 bounds 与 normal/maximized/fullscreen 状态；自定义 Window 菜单项调用标准 AppKit 窗口 actions（含 Full Screen），File 菜单提供 Open Recent File… / Open Recent Project… 两个 picker 入口；关闭和退出前逐窗口处理 dirty 文档并 flush。进入关闭审查即冻结文本与自动保存，取消后恢复；单窗关闭以 live backup、projected sidecar 和 durable marker 跨越 AppKit 提交边界；全局退出另有参与者清单，损坏或缺失事务工件时 fail closed，避免恢复出混合代。
- 工作区：多根目录、最近文件/项目、递归文件树，以及带 changed/renamed/deleted 分类、丢事件安全回退与 250ms 去抖的 FSEvents 刷新；创建/重命名/移动/废纸篓、Reveal/复制路径、`.editorconfig`、有界 workspace 查找/替换与可撤销的批量替换。批量替换与撤销在 Core 层持有 root-scoped mutation lease，从最终 capability/路径/文件 revision 复验贯穿提交及失败补偿；root 被移除/替换或路径被 symlink 换出授权范围时不会继续写盘。文件提交使用 descriptor-pinned `RENAME_SWAP | RENAME_SECLUDE` 比较交换；已打开、硬链接或映射中的旧目标会在原子交换点 fail closed。交换成功并持久化目录更新后，旧内容才经已验证的文件描述符清零并复用一个隐藏 recovery slot；任何交换后身份不确定都会保留恢复证据并报告 partial state，不按可能被替换的名字删除数据。已提交的项目排除规则以单调 generation 快照同时约束 tree、watcher、workspace search/replace、Goto/project symbols 与工作区词补全；异步旧结果和接受时已过期结果都会拒绝，未保存的设置草稿不改变 live policy。
- 导航和编辑命令：169 个公开 command catalog route 都接入 production router；包含命令面板、Goto Anything、文件/项目符号、行列跳转、前进后退、书签、多光标、文本变换、标签与 pane 操作。File/View/Workspace 菜单也直接暴露自动保存模式、语法选择、浏览器预览、当前改动还原和宏/片段命令；反向选区在同范围重选与 selection-only undo/redo 中保留精确 anchor/head。
- 开发工具：Git 状态/diff/history/blame/stage/commit/分支/冲突，remote URL 在进入 UI 前脱敏；破坏性 mutation 使用不可变确认快照、磁盘/dirty/revision preflight、独立 owner 编辑锁与 mutation 后受保护重读，以及 worktree/ours/theirs/双栏 compare。自由 Build 命令在输入时仅为草稿，批准后、启动前同步提交项目与全局设置；任一持久化失败都会补偿或显式报告 partial persistence，并阻止执行。终端使用经批准的有效登录 shell；隐藏面板保留当前 session，Stop、换 root、关窗或退出才终止并 join。语言服务器支持 hover/definition/references/rename。诊断 panel 可保留有界 unversioned 信息，gutter 只接受 document identity/version/generation 严格匹配的快照；close/stop/stopAll 会清理对应 retained 状态。无法构造适用 LSP request 时，definition/references 分别回退项目符号/工作区全词搜索，已配置 LSP 的空结果或错误不触发该回退；completion 与语言工具 formatting。
- 插件与导入：声明式插件、HTTPS marketplace、完整性与权限检查、独立 `LumenPluginWorker` 进程及逐配置授权；重复发布同一 canonical workspace root 是 no-op，不会因切换标签而重载插件、动态命令或权限。Sublime project/settings/keymap/snippet/build-system 导入采用先预览确认、再应用的流程。
- 预览与结构化编辑：安全 Markdown 预览、浏览器预览，以及带 revision 校验和单事务提交的 JSON tree/格式化/压缩。
- 设置与界面：全局持久化设置（21 行 UI 覆盖 22 个跨平台字段）、深浅色/配色方案、首个菜单/窗口帧前应用的持久 locale、运行时中英文切换（包括仅打开 Settings 的生命周期）、键盘覆盖与 chord、auto-save、distraction-free；没有编辑器窗口时只发布 `new-window`、`open-settings`、`check-for-updates` 和两项语言命令，同时保留标准 App/Window actions，不泄露文档命令。Terminal 已使用 controlling PTY，支持空 Return、foreground Ctrl-C、动态窗口尺寸及有界 session 回收；当前无障碍纯文本显示保持 `TERM=dumb`，不宣称 ANSI/full-screen TUI 仿真。Open/Save 命令、Language Tools、Update、Sublime import、Recent Items、Navigation、Workspace/Workspace Search、Project Settings、全局 Settings 持久化、审批摘要、Git/Build/Terminal/LSP 与 app-owned validation 均在渲染前保留 typed payload，可随 runtime locale 重绘；未知系统/网络错误、外部工具与插件原文保持 verbatim，不会因匹配应用英文模板而误翻译。主 `NSTextView` 有稳定 `lumen` ID 和本地化文档/窗格 label，审批/破坏性 alert 的稳定 action ID 有唯一性单测；主要窗口、菜单、面板和状态继续提供稳定 accessibility identifier，关键异步状态通过原生 VoiceOver announcement 通道播报。文件大小上限只对随后打开的文件生效。
- Sandbox 持久授权：用户选择文件/目录通过 security-scoped bookmark 恢复；记录原子、有界，损坏数据隔离；窗口/文档生命周期管理访问 lease。目录 rename/move 对 exact-file bookmark 使用持久化批量 prepare/commit/abort，失败或进程中断不会遗留只更新一部分的授权；磁盘已提交但 lease 刷新失败时，文档、导航和 session 仍统一跟随实际路径并提示协调错误。

## 架构与安全边界

```text
native-macos/
├── Package.swift
├── Sources/
│   ├── LumenEditorCore/       # Foundation 核心、DTO、校验、文件与进程边界
│   ├── LumenEditorApp/        # SwiftUI/AppKit、窗口 composition、controllers
│   │   └── Resources/         # 已锁定、可复现生成的 CodeMirror parser bundle
│   ├── LumenPluginWorker/     # 独立 JavaScriptCore 插件 worker 可执行文件
│   └── LumenParserWorker/     # 每次解析请求独立启动的 JavaScriptCore helper
├── Tests/
│   ├── LumenEditorCoreTests/
│   └── LumenEditorAppTests/
├── Packaging/                 # Info.plist 与主应用/worker entitlements
└── scripts/                   # 验证、本地 bundle、正式签名/公证打包
```

`LumenEditorCore` 不依赖 SwiftUI，保存不可变 DTO、格式校验和资源上限；`LumenEditorApp` 在主 actor 上组合窗口级模型与控制器。设置是进程级共享状态，而文档、workspace、router、build/terminal/LSP、plugin worker、导航和审批 scope 都按窗口隔离。production parser 不在主 App 进程执行 JavaScript；每个请求创建一个 `LumenParserWorker`，结果仍经主进程严格验证后进入 revision cache。cache identity 包含 revision、精确 UTF-16 文本、语言、tab/indent/insert-spaces 设置及 probe 位置；基础分析立即开始，光标相关 probe 延迟 120ms 且可取消。不同 revision 的并行分析有显式上限，过期任务会被取消；共享工作只在最后一个 waiter 离开时取消，parser 专用 runner 也使用比通用工具更小的执行/排队预算。

外部文件访问只通过显式授权的文件/根目录能力与 security-scoped bookmark。Git、构建、终端、语言工具、LSP 和插件 worker 经过参数校验、根目录约束、输出/超时上限与用户审批。内置 parser worker 通过 `ToolProcessRunner` 施加输入/输出预算和 1 秒硬超时，超时后终止该请求进程；它与插件 worker 分别使用独立的 sandbox+inherit entitlement。这些边界不能替代真实签名 Sandbox 环境中的行为验证。

### 语法能力边界

原生 App 内打包了由锁定 npm 依赖确定性生成的 CodeMirror parser bundle，覆盖 language-data 登记的全部 **143** 种语言。C/C++、CSS、Go、HTML、Java、JavaScript/JSX、TypeScript/TSX、JSON、Markdown、PHP、Python、Rust、Sass/SCSS、SQL 方言、XML、YAML、WebAssembly、Jinja、Liquid、LESS、Vue 和 Angular Template 等 **33** 种 Lezer 语言会在后台生成有界、revision-checked 的 UTF-16 完整结构快照，供高亮、括号、结构选择、重新缩进、outline 与折叠复用；其余 **110** 种 Stream 语言（包括 Swift）提供 mode 高亮与可用缩进。

Stream mode 不生成与 Lezer 等价的 AST，其结构选择、outline、折叠等继续使用保守的有界 fallback；mode 对某行没有 indentation answer 时，该行也不会被冒进重写。输入 planner 已对齐换行时的缩进前缀空白归一，以及 opener 只在 whitespace/`closeBefore` 标点前自动配对；自动生成的 closing 以 view-local UTF-16 provenance 跟踪，只有有效标记可跳过且只跳过一次，普通编辑会映射或失效标记。parser 自动缩进仍仅在已有非空行的行首安全子集、此前 indentation overrides 与源码一致，且 revision、精确 UTF-16 全文、语言及缩进设置均命中 cache 时使用结果。其他位置以及输入形成新 revision、快照尚未返回时会走有界 planner，因此这项仍是部分对等。混合 CR/LF 文档、超过 128 Ki UTF-16 或 50,000 行预算的文档及解析失败情形同样回退，原生版不宣称整个 language-data 集合具备 AST 等价。parser bundle 不加载项目或网络脚本；其生成产物受 8 MiB 限制。production 请求通过有界 stdin 交给每请求独立的 `LumenParserWorker`，`ToolProcessRunner` 在 1 秒硬超时后终止进程；不同 revision 的并发请求有上限，过期/无等待者的分析会取消，窗口 teardown 会等待 worker 回收。响应回到 Swift 端后仍重新校验范围、树关系、数量及 revision。正式发布前仍需在真实签名 Sandbox 中做病态输入与 helper 回收压力验证。

## 数据与兼容性

- 原生 bundle ID：`com.lumen.editor.native-preview`
- Electron bundle ID：`com.lumen.editor`
- 原生应用：`Lumen Editor Native.app`
- 原生数据目录：`~/Library/Application Support/LumenEditorNativePreview/`
- 全局设置：`settings.json`
- 首次/legacy 窗口：`session.json`
- 新窗口：`session-<id>.json`
- 窗口恢复 registry：`window-sessions.json`（最多 12 项，含可选 bounds/state）
- 最近项目/文件：`recent-projects.json`、`recent-files.json`
- Sandbox 授权：`security-scoped-bookmarks.json`

原生版不会读写 Electron 的用户数据目录。不要在两者间手工复制 session：虽有部分字段和编码标识兼容，两个应用的数据边界仍相互独立。

Native preview 当前不包含应用自有的遥测或崩溃报告上传。为恢复未保存编辑，窗口 session 会在本机 app
container 中保存草稿全文；设置、recent、bookmark、宏和插件状态也只保存在上面列出的原生数据目录。卸载应用
不会由 macOS 自动删除该目录；需要彻底清除本地状态时，应先退出应用并删除
`~/Library/Application Support/LumenEditorNativePreview/`。Git remote URL 在进入 UI/日志前会脱敏，外部工具原始
输出只在当前窗口的有界日志中展示。若未来加入 telemetry 或 crash upload，必须先补充采集字段、用户控制、
保留期和脱敏测试。

## 构建与测试

要求 macOS 14+、Xcode 15.3+、Swift 5.10+。从仓库根目录运行：

```bash
npm ci
npm run check:native-parser
npm run check:native-parity
npm run test:native-packaging
npm run test:release-artifacts
cd native-macos
# 完整验证入口：构建真实 plugin/parser worker、禁止关键 integration test skip，
# 再运行 Swift tests 与 warnings-as-errors Release build。
./scripts/verify.sh

# 生成 ad-hoc 签名的本地 bundle
./scripts/build-app.sh
open "dist/Lumen Editor Native.app"

# 可选：指定配置与输出目录
CONFIGURATION=debug ./scripts/build-app.sh /tmp/lumen-native-build
```

修改 `native-macos/ParserBundle/CodeMirrorParserEntry.js`、`scripts/generate-native-legacy-language-registry.mjs` 或相关 CodeMirror 依赖后，先运行 `npm run build:native-parser` 更新已提交的 legacy registry 与 SwiftPM 资源；Native CI 的 push/PR paths 覆盖这些输入，并从锁文件重新生成到临时目录逐字节核对，运行时不依赖 Node。普通 `swift test` 在 SwiftPM 未把 worker 放到测试 bundle 附近时可跳过 worker executable integration cases，因此不得把它单独视为完整门禁；`verify.sh` 会构建 `LumenPluginWorker` 与 `LumenParserWorker`、设置 `LUMEN_REQUIRE_WORKERS=1` 并把两个真实路径注入测试，缺失 worker 会失败而非跳过，再检查 package、Release build、plist、parser bundle 与 ICNS。`build-app.sh` 每次先清理目标 `.app`，再复制主程序、两个 worker、parser bundle、双语 bundle metadata 和图标，逐字节核对资源，对主 App/两个 helper 的签名 entitlement 做精确 allowlist，并从签名后的 `.app` 运行有界 parser smoke。Native macOS CI 还通过 LaunchServices 打开完整 `.app`，确认 editor scene 已接线、主窗口可见/可成为 key、content view 存在、main actor 连续响应且应用经正常退出事务结束，并上传 schema-v1 JSON evidence；本次 Linux 源码审计不代表远端 workflow 已运行或通过。正式 release 对 ZIP/DMG 提取 app 重复 parser 与窗口生命周期 smoke，并在 quarantine 标记的复制品上复核 Gatekeeper/parser。

## 发布链

以下是已配置的发布流程，不是已经成功签名、公证或通过实机验收的证据。tag release 会在 Intel 与 Apple Silicon runner 上分别构建 Electron 和原生版本。macOS job 显式创建临时 keychain、导入一次 Developer ID Application 证书，并让 Electron/native 打包共用同一 identity；Electron 仅通过 keychain 搜索列表读取证书，不取得该 keychain 的清理权，清理 step 使用 `always()` 恢复 keychain 列表并删除临时证书/keychain。原生 bundle 的短版本必须与 `package.json` 一致，`CFBundleVersion` 则在 staging 中使用 GitHub run number，保持发布构建号单调递增。当前配置生成独立的 thin `arm64` 与 `x86_64` 产物，没有实现或声称 universal binary。

原生正式打包流程为：

1. 按 `x86_64` 或 `arm64` 构建主程序、`LumenPluginWorker` 与 `LumenParserWorker`，并验证三个 Mach-O 都只有期望架构。
2. 先分别签两个 worker，再签外层 app；显式检查 identity、Hardened Runtime，并对主 App 与两个 worker 的 entitlement 做精确 allowlist 校验。
3. 从签名 app 实际运行 Lezer/Stream parser smoke；随后公证用于提交的 app ZIP，staple app，再由已 staple app 生成 DMG 与最终发布 ZIP。
4. 公证并 staple DMG；对 app/DMG 做 Gatekeeper、codesign 与 stapler 检查，对 ZIP/DMG 提取 app 通过 LaunchServices 执行可见响应窗口与正常退出 smoke 并上传 JSON evidence，再对带 quarantine 的复制品重跑 Gatekeeper/parser smoke。
5. 生成下列架构一致的产物并汇入统一 SHA-256 清单与 JSON manifest：
   - `text-editor-xujieyang-<version>-native-macos-arm64.{dmg,zip}`
   - `text-editor-xujieyang-<version>-native-macos-x64.{dmg,zip}`

`UpdateService` 只读取受限大小、拒绝重定向的 GitHub Releases 元数据，并要求当前架构对应的 native DMG 和 ZIP 名称同时存在。当前更新入口只打开受批准的 GitHub release 页面，不自动下载、验证或安装二进制；打开前会显示包含精确 URL 的本地化一次性确认，确认边界再次核对结果快照及固定 GitHub HTTPS allowlist，取消、结果变化或不安全 URL 都不会打开。`SHA256SUMS.txt` 供用户/发布审计校验，并不是独立签名信任根。

## 仍需真实 macOS 验证

CI 和单元测试不能替代以下实机验收。逐项操作、fixture、系统/架构矩阵、通过条件与证据格式见
[`docs/NATIVE_MACOS_ACCEPTANCE.md`](../docs/NATIVE_MACOS_ACCEPTANCE.md)；每个 release candidate 都必须针对其
commit 和产物 SHA 重新执行，任一 FAIL/BLOCKED 都阻止把原生版标为正式替代品。

验收范围包括：

- Apple Silicon 与 Intel 上的首次启动、多个窗口创建/关闭/重启顺序、屏幕增减后的 bounds 恢复，以及每窗口草稿隔离。
- 中文输入法、组合字符、emoji、UTF-16 多选区、Retina、深浅色、键盘导航、全键盘访问和 VoiceOver。
- App Sandbox 下 security-scoped bookmark 的首次授权、重启恢复、stale bookmark 刷新与 lease 释放。
- 真实 Git/构建/终端/formatter/LSP/plugin/parser worker 子进程在签名 Sandbox 内的启动、取消、超时、权限与进程清理。
- Developer ID 签名、Hardened Runtime、notarytool、stapling、Gatekeeper，以及带 quarantine 属性的 DMG/ZIP 安装路径。
- 保存冲突、只读目录、文件删除/替换、异常退出后的 hot-exit 恢复，以及重要文件的字节级备份对照。

在上述实机矩阵完成前，原生版仍应视为预览版本；不要把它用于没有其他副本的重要文件。
