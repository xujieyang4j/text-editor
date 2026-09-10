# Lumen Editor 原生 macOS 发行验收记录

本文把 [`NATIVE_MACOS_PARITY.md`](./NATIVE_MACOS_PARITY.md) 中依赖真实 macOS 的剩余门禁变成可重复执行、可留证的检查表。它不替代自动化测试；每个候选版本都必须从空白副本重新执行，不能沿用旧版本结论。

## 1. 候选产物与证据

开始前复制本节并填写；缺少任一必填项即不得将原生版标为正式替代品。不得在记录中粘贴 Apple ID、令牌、私钥、完整用户路径或文档正文。

| 字段 | 必填值 |
| --- | --- |
| 版本 / tag / commit | `v…` / 40 位 commit SHA |
| 产物 | native arm64 DMG+ZIP；native x64 DMG+ZIP |
| SHA-256 | 与 `SHA256SUMS.txt`、`release-manifest.json` 逐项一致 |
| 测试系统 | macOS 完整版本、硬件型号、CPU 架构 |
| 测试环境 | 干净测试账户；之前未授权该版本 |
| 输入法 | Apple 简体拼音版本；ABC |
| 测试人 / 时间 | 姓名或团队账号；ISO-8601 时间 |
| 证据目录 | `native-macos-acceptance/<tag>/<arch>/` 或等价不可变 CI artifact |

每个 case 保存：结果（PASS/FAIL/BLOCKED）、实际行为、屏幕录制或截图、Console/进程日志的脱敏摘录。任何 FAIL 或 BLOCKED 都阻止发布；修复后用新 commit 重新执行受影响项。发布负责人还必须在 GitHub `production-release` environment 中核对这份记录所列 tag、commit 和 artifact SHA 后再批准 deployment；该 environment 应启用 required reviewers 且禁止管理员绕过。仓库 workflow 无法自行证明外部 environment 保护规则，发布记录必须附该配置页截图或审计导出。

自动化会额外留存 `native-release-evidence-macos-<arch>` artifact。其中 ZIP 与 DMG 提取 app 的 `*-window-smoke.json` 必须为 schema v1、`status=passed`、`gracefulExit=true`，并记录 bundle identity、主程序 SHA-256、已连接 editor session、可见 key-capable 内容窗口和至少两次 main-actor round trip。该 smoke 通过 LaunchServices (`open -W -n`) 启动完整 `.app`，不是直接运行 loose Mach-O；它证明普通应用生命周期、窗口创建/可见性/响应和正常退出门禁，但不证明 VoiceOver、IME 或人工 Gatekeeper 首启交互。

## 2. 支持矩阵

| 环境 | 必跑范围 |
| --- | --- |
| Apple Silicon，macOS 14 | A–H 全部；主要发布基线 |
| Apple Silicon，当前发布使用的 macOS | A、E、F、H |
| Intel，当前发布使用的 macOS | A、B、E、F、H；若无真实 Intel，记录具体等价硬件/虚拟化方案和限制 |

显示检查至少覆盖 Retina 主屏和一次外接屏/缩放切换。辅助功能检查在 Full Keyboard Access、Increase Contrast、Reduce Motion 各自开启后执行。

## 3. 可执行验收用例

### A. 安装、签名和启动

- [ ] **A00 自动窗口证据**：下载对应 `native-release-evidence-macos-<arch>`，确认 ZIP 与 DMG 的 structured window smoke 均通过，JSON 中的 executable SHA 与各自提取 app 一致；CI artifact 与候选 tag/run 对应。该项失败或缺证据直接阻断，不以 parser-only smoke 或进程存活替代。
- [ ] **A01 DMG quarantine 首启**：给下载的 DMG 保留或显式设置 `com.apple.quarantine`，挂载后拖入 Applications；Gatekeeper 首次打开不报损坏或未知开发者，About 中版本与 manifest 一致。保存 `xattr -l`、`spctl -a -vv`、`codesign --verify --deep --strict --verbose=2` 和 `stapler validate` 输出。
- [ ] **A02 ZIP quarantine 首启**：对 ZIP 执行同样流程，解压后的 app 可首次启动且签名、公证仍有效。
- [ ] **A03 架构**：在 arm64 与 x86_64 环境分别启动对应产物；主程序、`LumenPluginWorker`、`LumenParserWorker` 的 `lipo -archs` 均只含目标架构。
- [ ] **A04 文件关联**：Finder 的 Open With 可选择 native app 并打开纯文本、源码、JSON 和 Markdown；不会抢占系统默认应用。一次选择多个文件、冷启动与运行中打开均不遗漏文件或重复建 tab。

### B. 文件安全、授权与恢复

- [ ] **B01 Powerbox 与 bookmark**：从面板打开一个工作区和工作区外单文件，编辑保存；退出并重启后无需再次选择即可恢复授权。
- [ ] **B02 stale bookmark**：移动已授权目录后重选新位置；记录刷新成功，旧位置不再授予访问，关闭最后一个相关 tab/root 后 lease 释放。
- [ ] **B03 外部冲突**：分别验证 clean 文件外改自动刷新；dirty 文件外改、删除、权限变化、由文本变二进制或超限时出现 Compare/Keep Local/Reload/Save As，取消不丢草稿。
- [ ] **B04 原子保存**：在 APFS 上覆盖普通文件时权限保持；symlink 保存仍指向原目标；broken symlink、hard link 和保存期间再次外改均 fail closed，字节级备份不变。
- [ ] **B05 hot exit**：两个窗口各含 dirty/untitled 文档时强制结束进程并重启；逐窗口恢复精确文本、tab/pane/selection/scroll，源文件未被静默写入。损坏和超限 session 被隔离且应用仍能启动。
- [ ] **B06 退出事务故障恢复**：在多窗口 Quit 的 staged commit、部分 canonical materialize、`materialized` marker 留存三个断点分别终止进程；重启只恢复一整代快照。删除或损坏其中一个 canonical 后可从同一事务 sidecar 修复；无法修复时显示可重试的恢复界面，选择安全 fallback 会先保留 marker、sidecar、backup 与 canonical 副本，不循环崩溃或静默丢弃证据。
- [ ] **B07 单窗口关闭与授权移动事务**：在红按钮关闭写入 projected snapshot 后、`windowWillClose` 前终止进程，重启必须恢复 live dirty draft；正常 `windowWillClose` 后不得恢复已确认丢弃内容。移动含多个 exact-file bookmark 的目录时分别模拟目标冲突、磁盘操作失败、rollback 失败和进程中断，验证 bookmark 全有或全无，document/navigation/session 与实际磁盘路径一致。

### C. 文本输入与编辑器

- [ ] **C01 中文 IME**：Apple 简体拼音输入“中文测试”，候选确认前后不出现重复字符；composition 中移动光标、切 tab 再返回、Esc 取消均不破坏正文。
- [ ] **C02 Unicode**：输入 emoji、ZWJ emoji、组合重音 `e` + U+0301；逐字符删除、选择、复制粘贴、撤销/重做不拆坏 UTF-16 边界。
- [ ] **C03 多选区**：创建三个光标后输入、粘贴、Enter、Tab、成对括号及一次 undo/redo；主选区和方向保持，所有改动为一个事务。
- [ ] **C04 查找与矩形选择**：原生 find bar 的 Find/Replace/Next/Previous 可用；literal/regex、大小写和全词选项的高亮范围与结果集合及当前项样式精确一致。切换 tab/pane 或搜索期间编辑后不保留旧高亮；零宽正则查找有界且可见，Replace/Replace All 遇零宽匹配时拒绝并不改正文。专注模式中显式打开 Find 后，第一次 Escape 关闭 Find 并恢复编辑焦点，第二次才退出专注模式。Option 拖动跨 Tab、短行和滚动区域，输入后一次撤销恢复。
- [ ] **C05 parser 消费**：JavaScript 显示 Lezer 高亮、outline、fold 和 bracket navigation；Swift 显示 Stream 高亮/缩进并使用结构 fallback。基础分析立即启动，光标/换行 probe 仅在稳定 120ms 后启动；快速连续光标或 revision 变化会取消冗余 probe，只有精确 settled revision 可进入编辑器。超限输入和病态 parser 输入不冻结 UI，旧 revision 不回写。

### D. 窗口、标签与辅助功能

- [ ] **D01 窗口生命周期**：新建多个窗口，分别调整 pane、tab、bounds、最大化/全屏；关闭和重启后恢复顺序与状态，屏幕移除时 bounds 被安全夹取。
- [ ] **D02 dirty close**：红色关闭按钮、Close Tab、Close Others、Close Right、Close All、Quit 分别覆盖 Save/Discard/Cancel；取消不产生半关闭，保存失败不会退出。
- [ ] **D02a 多窗口 Quit 提交边界**：在第一个窗口的异步进程/服务 teardown 暂停时尝试在其他窗口输入、执行菜单或命令；所有窗口保持关闭 gate，不能产生 marker 之外的新编辑，直到 AppKit 收到最终 terminate reply。
- [ ] **D03 键盘**：Full Keyboard Access 下菜单、tab、banner、picker、设置和所有 panel 可达；Escape 关闭后焦点回到调用处，没有键盘陷阱。
- [ ] **D04 VoiceOver**：验证窗口、pane、tab 的 active/dirty/conflict、主编辑器、状态栏、Find/Build/Git/LSP/Outline 结果、审批与破坏性按钮名称；逐个导航并触发行号 ruler 中的折叠 marker，确认本地化 fold/unfold 状态、准确行范围及操作播报，且不混淆 diff/diagnostic gutter。异步成功/错误只播报一次且不朗读文档或诊断正文。
- [ ] **D05 显示**：深/浅色、Increase Contrast、Reduce Motion、8/40 字号、Retina 与外接显示器下，焦点、选区、gutter、minimap、dirty/冲突状态清晰且信息不只靠颜色；折叠 gutter 在 folded/unfolded 两种状态均能由键盘和 VoiceOver 操作。

### E. Sandbox 内进程与网络

- [ ] **E01 parser worker**：从已签名 app 打开 JavaScript 与 Swift fixture，确认两类结果进入编辑器；病态输入在硬超时后 UI 仍响应且 worker 无残留。
- [ ] **E02 Build**：自由命令输入期间只修改内存草稿；拒绝审批不持久化。批准后、进程启动前同步提交项目与全局设置；任一写入或补偿失败都显示可重试错误并阻止启动。允许执行后 cwd 为批准的 root，输出/诊断只属于当前 run/root；Stop、换 root、关窗和退出均回收整个进程树。
- [ ] **E02a Terminal**：首次完整命令身份出现审批，实际 shell 为有效的用户登录 shell fallback；允许后 cwd 为 root 且 stdin/stdout/stderr 均连接同一 controlling PTY，`isatty(0/1/2)` 成功。空输入发送真实 Return，Interrupt 经终端行规程到达当前 foreground job，面板尺寸变化更新 `TIOCSWINSZ`/`SIGWINCH`。关闭或 Escape 只隐藏面板，重开仍连接同一 session/output；Stop、换 root、关窗和退出才以 TERM→KILL 终止并 join 已跟踪的 login/foreground process groups，同时关闭 controlling PTY 触发 hangup；多次取消幂等，常规及忽略 TERM 的前台/后台子进程无残留。纯文本面板当前明确保持 `TERM=dumb`，不宣称 ANSI cursor/full-screen TUI 仿真。
- [ ] **E03 formatter/LSP**：真实 formatter 与至少一个 LSP 完成 initialize、同步、completion、hover、definition、references、rename、restart/stop；过期 generation/version 结果不进入当前文档。
- [ ] **E04 plugin worker**：未授权时无文档内容；read/edit 分权；worker 崩溃、超限和关闭窗口均隔离并回收。重复发布同一 canonical workspace root 不重载 descriptor、动态 route、权限或 live runtime；真实换 root 会立即撤下旧动态状态。
- [ ] **E04a plugin worker 本地化边界**：在 worker 返回恰好等于应用英文错误模板的失败文本，以及包含中文、冒号、换行的 stderr 时切换 en-US/zh-CN；只翻译应用拥有的标题/外壳，plugin message 与 stderr 原文逐字保持。
- [ ] **E05 Marketplace**：HTTPS、同源、无重定向且 SHA-256 正确的 fixture 可安装；HTTP、redirect、跨源、hash 错误、超限与认证 URL 全部拒绝且不泄露凭据。

### F. Git 与工作区

- [ ] **F01 Git**：真实仓库覆盖 status、upstream/ahead/behind、diff/hunk、stage/unstage、history、blame、commit、branch；带空格和 `-` 开头路径不被解释为参数，remote 凭据不进入 UI/日志。
- [ ] **F02 destructive Git**：stage/unstage、stage/discard hunk、文件 discard、commit、checkout 与 create branch 都覆盖确认和取消；确认期间改变 status/selection/root 后旧动作不能执行。dirty/saving/外改/busy 文档阻止 discard 或 branch mutation；通过 preflight 的文档从磁盘 mutation 前到 mutation 后重读完成期间不可编辑，只重读精确快照集合，读取失败显示冲突而不把旧内容伪装为 clean。模拟 mutation 已提交但 status refresh 失败/取消，仍必须先协调文档。Git 与 Quit 的独立编辑锁不得互相释放；冲突的 worktree/ours/theirs/双栏 compare 正确。
- [ ] **F03 FSEvents**：创建、修改、rename、delete、事件突发和 root 失效能刷新正确子树；移除 root 后 watcher 停止。
- [ ] **F03a 项目排除 epoch**：在 tree load、watcher debounce、workspace search/replace preview、Goto Anything/project-symbol 和词补全仍在运行时提交排除规则；旧 generation 不得发布或被接受。取消/未提交的设置草稿不改变 live policy；旧 replace confirmation 被关闭/拒绝，已完成替换产生的合法 undo receipt 仍按 revision/capability 生命周期工作。
- [ ] **F03b 批量替换 capability 事务**：分别在 apply/undo 的异步预检后、最终复验前和多文件提交中间尝试移除或原子替换 root；撤销先完成时不得写盘，mutation lease 先取得时 root 变更必须 fail closed，且 lease 覆盖全部提交与补偿。将目标在最终复验前换成内容相同但指向 workspace 外的 symlink，外部文件保持不变；在 `RENAME_SWAP | RENAME_SECLUDE` 前预先持有目标写 FD/映射时必须 fail closed。在交换后分别替换目标、原地改写目标及替换 recovery artifact，必须报告 partial state、保留可恢复数据且不删除外部内容；在交换后的目录同步边界注入失败并做真实 crash/reboot 验证，旧/新完整版本至少保留一份。连续 100 次替换及同目录 40 文件批次只复用有界的空 recovery slot；并发批次不能交错取得彼此写入的 undo ownership。
- [ ] **F04 工作区变更**：添加/移除多 root、创建/rename/move/Trash/Reveal，最具体 root 与授权边界正确，打开文档和导航历史路径同步。
- [ ] **F05 外移目录能力保持**：在工作区目录中创建指向工作区外文件的 symlink，先经 Powerbox 单文件授权并保持文档打开，再将父目录移到另一个已选目录；新路径仍使用迁移后的 exact-file bookmark 读写，不能降级为较弱的目录祖先 lease。容量不足必须在磁盘 move 前失败；retarget symlink 后必须 fail closed；direct-directory Trash 与跨卷 move 继续明确拒绝且保留源。

### G. 本地化与隐私

- [ ] **G01 runtime locale**：从 en-US 和 zh-CN 各冷启动一次；在仅 Settings 窗口与编辑窗口中切换语言，菜单、panel、dialog、状态与辅助名称立即一致。Settings-only 场景只出现 `new-window`、`open-settings`、`check-for-updates`、`set-ui-language-zh`、`set-ui-language-en` 五个应用命令及标准 About/Services/Hide/Hide Others/Show All/Quit、miniaturize/zoom/full-screen/front actions，不出现文档/workspace 命令。覆盖已存在的 Save/Save As/Save All/Open、Language Tools、Navigation、Completion/LSP、Update/Sublime import/Recent Items/Workspace/Workspace Search/Project Settings/全局 Settings/Build/Marketplace/Plugin/Plugin Worker/Find/command-palette typed 错误、动态路径/字节数/errno 以及单数/复数 VoiceOver 播报；系统文案和未知网络错误、外部工具、插件、stderr 原文可保留系统/来源语言且不得因恰好匹配应用英文模板而被反向误翻译。
- [ ] **G02 数据检查**：确认 Application Support 只含声明的设置、窗口 session、recent、bookmark、macro/plugin 数据；卸载/清除步骤可删除这些数据。日志不得含 token、完整文档正文或未经脱敏的 remote URL。
- [ ] **G03 崩溃报告**：确认当前构建不上传应用自有 telemetry/crash report；若以后启用，必须先记录采集字段、保留期、用户控制与脱敏测试。

### H. 升级与回退

- [ ] **H01 升级**：从上一正式版安装当前版，设置/session/recent/bookmark 可恢复，schema 迁移后仍可编辑和保存。
- [ ] **H02 回退**：保留备份后回到上一版；未来 schema 被安全拒绝或隔离，不循环崩溃、不覆盖未知字段。记录明确的数据兼容限制。
- [ ] **H03 并行安装**：Electron 与 Native 同时安装和运行，bundle ID、数据目录、窗口/session 和更新资产互不覆盖。
- [ ] **H04 更新页面确认**：Open Release Page 的本地化确认显示精确 GitHub release URL；Cancel 不打开任何页面。对话框存在时替换 update result 会使旧确认失效，最终打开边界再次拒绝非固定 GitHub HTTPS allowlist 的 URL。

## 4. 发布判定

只有满足以下全部条件，才能把 native preview 改称正式替代品：

1. `native-macos/scripts/verify.sh`、Native macOS CI 和 tag release 的全部自动门禁通过；两个目标架构均留存并通过 packaged-window structured evidence。
2. A–H 用例在支持矩阵中完成，记录对应 commit 与产物 SHA，且不存在 FAIL/BLOCKED。
3. 两个架构的 DMG/ZIP 与 `release-manifest.json` 完整匹配；签名、公证、staple、Gatekeeper 和 quarantine 首启证据齐全。
4. [`NATIVE_MACOS_PARITY.md`](./NATIVE_MACOS_PARITY.md) 中所有 P0–P5 项已实现/验收，或有经产品批准并记录迁移影响的不适用决定。

在这些条件满足前，原生应用保持 `com.lumen.editor.native-preview` 身份并与 Electron release 并行。
