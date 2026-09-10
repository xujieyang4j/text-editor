# Lumen Editor 原生 Windows 发行验收记录

这是 [Windows 对等清单](./NATIVE_WINDOWS_PARITY.md) 的可留证执行模板。每个候选版本从干净用户档案重新执行；任何 FAIL/BLOCKED 都阻止 Windows native preview 升级为正式替代品。

| 字段 | 必填 |
| --- | --- |
| 版本 / commit | `v…` / 40 位 SHA |
| 产物 | 已签名 x64 MSIX、已签名 arm64 MSIX |
| SHA-256 | 对应 release manifest |
| 系统 | Windows 10/11 build、CPU 架构、Windows App SDK runtime |
| 帐户 | 干净本地测试帐户 |
| 测试人 / 时间 | 团队帐号 / ISO-8601 |
| 证据目录 | 不可变 CI artifact 或 release evidence 目录 |

tag release 会留存 `native-release-evidence-windows-x64/window-smoke-x64.json`。该 schema-v1 记录必须证明：正式签名 x64 MSIX 已安装并由 AUMID 启动；新进程拥有非零、可见、启用的顶层窗口；UI Automation 把它识别为 `ControlType.Window` 且能找到 `LumenEditorRoot` 工作区；消息循环连续响应三次；`WM_CLOSE` 后应用正常退出。它比“进程存活 3 秒”更强，但仍不能替代 IME、Narrator、High Contrast、Explorer 和 SmartScreen 人工验收。

## P0 启动门禁

- [ ] `package-msix.ps1` 生成两个非空包；`verify-msix.ps1` 确认包内 architecture、版本、App EXE、唯一且非空的同架构 worker EXE、Jint、Markdig、CodeMirror parser bundle hash、四张尺寸正确的图标、`runFullTrust` 与 81 个文件关联。
- [ ] `smoke-installed-msix.ps1` 在 Windows CI 使用 job 证书安装 x64 包，通过 AUMID 启动，验证 Win32 可见/启用顶层窗口、UI Automation 的 `ControlType.Window` 与 `LumenEditorRoot`、三次消息循环响应，再发送 `WM_CLOSE` 并等待正常退出，最后卸载并清理证书；下载并核对 structured JSON evidence。
- [ ] `signtool verify /pa /all /v` 对 x64、arm64 MSIX 均成功，签名证书 Subject 与包内 Publisher 一致并含可信时间戳。
- [ ] tag release 对正式签名 x64 MSIX 重复同一 installed-window smoke，上传的 `native-release-evidence-windows-x64` 与候选 run、MSIX SHA-256 一致；arm64 因 runner 架构不匹配仍必须在真实 ARM64 设备按本节完整验收。

- [ ] MSIX 安装后，`.txt`、`.md`、`.json`、`.ts`、`.cs`、`.py` 的 Explorer “打开方式”可选择 Windows native preview，且不覆盖既有默认应用。
- [ ] 在 FileOpenPicker 中 Ctrl/Shift 多选至少三个文件；其中一个无权限或超过上限时，其他可用文件仍全部打开。
- [ ] Explorer 多选、双击冷启动、运行中二次打开分别验证；没有遗漏、重复 tab 或窗口路由错误。
- [ ] 199 MiB UTF-8 文本可打开；201 MiB 被拒绝；二进制、UTF-16、损坏 UTF-8、删除中路径分别有安全结果。
- [ ] New/close/dirty edit/Save/Save As/session recovery 的数据安全回归完成后，才能关闭 P0。

## P1–P5 发布门禁

- [ ] IME、Unicode、复制粘贴、Undo/Redo、Find、键盘快捷键和 High Contrast/Narrator。
- [ ] `verify-core.sh` 在 Linux 重复运行均通过：185/185 Core tests、独立 self-contained worker 的 parser/plugin 真进程协议 smoke，以及 Worker/WinUI stub 0 warning / 0 error；不能依赖上次运行残留的 artifacts。
- [ ] 多光标：上下添加、下一匹配/跳过/全选匹配、移除最后光标、行首/行尾和按行拆分均可见；输入、退格、删除、粘贴、Tab、parser-backed Enter 和括号/引号配对在所有选区中形成一个可撤销事务；开始 IME 组合时安全收敛到主选区。
- [ ] 四窗格分别验证行号随滚动对齐、空格/Tab 标记不修改文本、缩进线、竖直标尺、行尾空白、活动行、同词/括号匹配、diagnostics/diff gutter、minimap 点击导航，以及当前/全部折叠与展开；切换四套配色、字号、自动换行和 199 MiB 文件时无失真、卡死或无界 UI 元素增长。
- [ ] 查找、替换与工作区搜索会记录去重且有界的历史；重启后可选回历史项，空值/超长设置不会污染配置。
- [ ] `test-parser-worker.ps1` 与 `test-plugin-worker.ps1` 均通过；语言选择器包含 Plain Text + 143 个锁定语言，扩展名、特殊 filename 与 alias 可检测；JavaScript/TypeScript/JSON/HTML/Markdown 文档显示 parser 级 token，Lezer 折叠、大纲和 Enter 缩进与源码结构一致；C# 等 stream parser 保留 token 着色但不冒充语法树；超过 128 Ki UTF-16、超过 50,000 行、不支持语言和 worker 故障都无崩溃地回退。
- [ ] Markdown WebView2 显示 GFM 富预览，原始 `<script>`/HTML 不执行；devtools、脚本、上下文菜单、下载和弹窗关闭，外部 HTTP/HTTPS/mailto 链接取消内部导航后交给系统；WebView2 不可用时显示安全文本 fallback，超预算文档有明确失败。
- [ ] 已启动 LSP 时补全、format、rename、diagnostics 均可工作；未启动时补全只读有界工作区词索引，不静默执行服务器。快速输入、切换文档、关闭文档和取消请求后，旧 path/revision/version/caret 的补全或 diagnostics 不得显示。
- [ ] 在“打开的文档”列表中用 Ctrl/Shift 选择 2、3、4 和 5 个文档并执行 Split Selected；分别形成 2/3/4/4 个窗格，按列表顺序显示前四项，未拆分文档不丢失；少于两个选择时复制活动文档到下一窗格。
- [ ] 在 `.lumen-project.json` 配置 `exclude`（如 `generated/**`、`**/*.tmp`）；被排除项不出现在树、Goto、项目符号和搜索/替换中，外部文件变化不触发重载；修改规则后旧替换预览必须拒绝应用。
- [ ] 工作区 watcher、搜索替换、文件变更/冲突、JSON/Markdown/语法展示。
- [ ] Git porcelain v2 status、remote 脱敏、diff、文件多选 stage/unstage/discard、commit、conflict、单 hunk stage/discard、history、blame、切换/新建分支均在含空格/Unicode/rename 路径上通过；过期 hunk 必须拒绝应用。
- [ ] 项目 Build 与全局 `buildCommand` 均通过 argv 直接启动而不经 shell；包含引号和空格的命令可解析，恶意 shell metacharacter 不被解释。
- [ ] ConPTY terminal、LSP、parser/plugin worker 的取消、窗口关闭与 Job Object 回收，以及外部工具/插件首次确认均通过。
- [ ] MSIX 签名、证书信任、SmartScreen、升级/回退和 Electron 并行安装。
