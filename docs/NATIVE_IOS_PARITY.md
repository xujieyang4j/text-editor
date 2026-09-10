# iOS 原生版移动适配矩阵

基线：Electron 正式版提供完整桌面能力；iOS 不是对 167 个命令做同形复制，而是按移动场景对齐
“打开、阅读、修改、找回、可靠保存”。状态分为：`已实现`、`需 Apple 环境验证`、`后续`、`不适用`。

| 能力 | iOS 状态 | 移动端行为 | 发行条件 |
|---|---|---|---|
| 系统文件打开 | 已实现 | Document Picker，多选，Open in Place | iCloud Drive 与至少一个第三方 Provider 真机通过 |
| 文档编辑 | 已实现 | TextKit 2 单编辑器，原生 selection/IME/undo；粘贴、输入及整篇替换在提交前执行 96 MiB 工作区预算检查，超限时仍允许删除和缩短内容 | 中文、日文、韩文 IME 与容量拒绝真机矩阵通过 |
| 文档切换与最近文件 | 已实现 | 底部 sheet/抽屉，不显示桌面标签条；最近文件有界持久；启动恢复完成前串行化新建/打开，工作区统一限制 30 份与 96 MiB 估算载荷 | VoiceOver、脏文档关闭保护及容量边界通过 |
| 编码与换行 | 已实现 | 与桌面编码集合一致；无效/歧义编码的原始字节进入受保护恢复草稿，重启或 Provider 离线后仍可严格重解码 | 12 种编码 × LF/CRLF/CR 严格字节往返已有 Core XCTest；仍需 Apple Simulator 留存结果 |
| 安全保存 | 已实现 | 草稿先行，协调写回，revision 冲突，读回验证 | provider 断网/冲突/写回失败矩阵通过 |
| 外部文件变化 | 已实现 | `NSFilePresenter` 监听修改、移动、删除；干净文档只在替换后仍满足工作区预算时自动重载，否则保留当前缓冲区并进入显式处理 | iCloud 与第三方 Provider 跨设备矩阵通过 |
| 另存为与分享 | 已实现 | 系统 File Exporter；分享使用按当前编码/EOL 生成的受保护临时快照且不改变保存基线 | 真机文件 App 与 Share Sheet 验证 |
| 中断恢复 | 已实现 | 单调代次检查点；后台/非活跃申请系统后台时间；损坏或超启动预算的草稿保留并告警 | kill、内存压力、重启恢复真机通过 |
| 当前文件查找替换 | 已实现 | 键盘附近紧凑条，正则/大小写/全词；大文本扫描后台执行、可取消且丢弃陈旧结果；Unicode 安全模板解析统一驱动输出预检与构造，替换结果在构造前核算剩余工作区预算 | 结果上限、取消、零宽、emoji/捕获模板及输出预算规则已有 Core 测试 |
| 快速打开/大纲 | 已实现（P0 fallback） | 全屏可搜索符号列表；Markdown/常见声明启发式 | 后续接共享 parser，当前不得宣称 AST 大纲 |
| 语法高亮 | 已实现（P0 fallback） | 有界 lexical attributes，不改字符，不干扰 marked text | 后续接 parser；超限文本回退纯文本 |
| 外接键盘 | 已实现 | `⌘S`、`⌘F`、`⌘P`、undo/redo 和 accessory | iPad 硬件键盘验证 |
| 高频编辑 | 已实现 | UTF-16 安全的缩进、反缩进、复制行；状态栏显示行、列、选区、编码、EOL、dirty | emoji/组合字符与多行选区 Core 测试通过 |
| 辅助功能 | 已实现基础 | Dynamic Type、44pt 控件、VoiceOver label/状态公告；查找条在辅助字号重排，状态栏可横向浏览 | VoiceOver、加大字体、横竖屏人工通过 |
| 工作区文件树 | 后续 | 手机首发使用系统 Files 和文档抽屉 | iPad 双栏阶段再引入 |
| 多窗格/Minimap | 后续 | iPhone 不占用正文空间 | iPad 大屏需求验证后再做 |
| Build/Terminal | 不适用 | iOS 本地不启动任意 executable | 未来走远程工作区 |
| 本地 LSP/插件 worker | 不适用 | 不执行本地进程或任意插件代码 | 未来走远程受控协议 |
| Git 深层工作流 | 后续 | P0 不在设备上嵌入 Git CLI | 先设计远程/文件提供器语义 |

## 代码入口

- `native-ios/Sources/LumenEditorMobileCore/`：Data 编解码、UTF-16 查找、保存状态、草稿、fallback 大纲。
- `native-ios/Sources/LumenEditorIOSApp/MobileFileAccess.swift`：security scope、bookmark、协调读写与验证。
- `native-ios/Sources/LumenEditorIOSApp/MobileFilePresenter.swift`：Provider 外部修改、移动和删除事件桥。
- `native-ios/Sources/LumenEditorMobileCore/MobileEditingCore.swift`：UTF-16 编辑转换和光标状态。
- `native-ios/Sources/LumenEditorIOSApp/NativeTextEditor.swift`：TextKit 2、IME、系统撤销、外接键盘。
- `native-ios/Sources/LumenEditorIOSApp/RootView.swift`：手机导航、文件入口、生命周期检查点。
- `scripts/check-native-ios.mjs`：跨平台架构与安全契约门禁。

当前 Linux 环境只能运行契约门禁、Swift parse 和可移植 Core 测试；Xcode 编译和模拟器会执行隔离的
英文创建/编辑、查找替换/撤销重做、双草稿切换及中文生成名流程。CI 擦除 iPhone/iPad 后复用一次
`build-for-testing`，即使前序测试失败也继续收集另一设备、archive 和可读 `.xcresult` 摘要；真机验收
仍由人工发行检查完成。
