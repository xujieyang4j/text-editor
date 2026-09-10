# Lumen Editor iOS

Lumen Editor iOS 是独立的 iPhone/iPad 原生预览轨道，最低支持 iOS 17。它保留 Electron、macOS
和 Windows 版本，不共享数据目录，也不把桌面三栏界面缩放到手机。当前产品目标是“快速查看与安全编辑”：
单文档编辑面、系统文件入口、文档切换抽屉、键盘上方工具条、底部查找替换和快速大纲。

## 已实现的移动端核心

- SwiftUI 导航外壳与 UIKit `UITextView(usingTextLayoutManager: true)` TextKit 2 编辑面。
- 系统 Document Picker、Open in Place、security-scoped bookmark 与 `NSFileCoordinator`。
- UTF-8、UTF-8 BOM、UTF-16 LE/BE（含无 BOM）、GB18030、GBK、Big5、Shift JIS、
  Windows-1252、ISO-8859-1；保存时保持 LF/CRLF/CR。不能无损表示的字符会拒绝保存。
- 20 MiB 手机编辑上限、二进制检测、精确 SHA-256 revision 和外部修改冲突拦截。
- `NSFilePresenter` 持续监听 Provider 修改、移动和删除；干净缓冲区自动安全重载，脏缓冲区提供保留
  本地副本、放弃重载、另存为和延后处理，Provider 暂不可用时可重试。
- 双层保存：应用私有、原子、Data Protection 草稿检查点，加 File Provider 原文件写回与逐字节读回验证。
  写回无法验证时文档继续保持 dirty，并保留草稿。
- 编码无效或无 BOM UTF-16 推断不确定时先只读展示；原始字节会进入受保护恢复草稿，重启或
  Provider 暂不可用后仍可选择编码并严格重解码，且 revision 变化不会被误标为已保存。
- 当前文件查找/替换、大小写/全词/正则、UTF-16 selection、结果上限与零宽替换保护；正则替换模板
  对 emoji、`$$`、`$&` 和捕获组采用同一套 Unicode 安全解析，替换结果在构造字符串前按当前工作区
  剩余预算限制。
- 大文本查找、导航和替换计算在后台执行，带防抖、协作取消与陈旧结果隔离；辅助字号下自动重排。
- 多文档恢复、最近文件与切换，系统撤销/重做、键盘 accessory、`⌘S`/`⌘F`/`⌘P`、动态字体与基础 VoiceOver 标签。
- 启动恢复完成前串行化新建、Files 激活与最近文件打开；恢复、运行时新增、TextKit 输入/粘贴、整篇替换
  和原文件重载统一执行 30 文档/96 MiB 估算载荷上限。增长操作在修改缓冲区前拒绝，但始终允许删除或缩短
  内容以释放预算。
- 切后台时申请系统后台时间完成全部恢复检查点；单调代次阻止旧异步写覆盖新内容；恢复启动按最近
  30 份和 96 MiB 估算内存预算加载，损坏或延后草稿不会静默删除；关闭文档也会等待草稿删除成功。
- 系统“另存为”和分享副本；分享使用受保护的应用私有临时快照，不改变 source、dirty 或保存 revision。
- UTF-16 安全的多行缩进/反缩进/复制行，`⌘]`、`⌘[`、`⇧⌘D`，以及行列/选区/编码/EOL 状态栏。
- 有界轻量语法着色和快速大纲；IME marked text 阶段不回写 SwiftUI，也不重做 attributes。
- 中文和英文运行时本地化、Privacy Manifest、iPhone/iPad 通用 App 图标，以及创建/输入 UI smoke target。

## 本地构建

需要 macOS、Xcode 16 或兼容 iOS 17 SDK 的较新 Xcode：

```bash
open native-ios/LumenEditorIOS.xcodeproj
```

选择共享的 `LumenEditorIOS` scheme 和任意 iOS 17+ iPhone/iPad 模拟器。命令行验证：

```bash
npm run check:native-ios
xcodebuild build \
  -project native-ios/LumenEditorIOS.xcodeproj \
  -scheme LumenEditorIOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test \
  -project native-ios/LumenEditorIOS.xcodeproj \
  -scheme LumenEditorIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

共享 scheme 的 UI 测试会为每个启动传入一次性 UUID，只在 Debug 构建中切换到独立临时草稿和最近文件
目录；Release 构建忽略该环境变量。CI 会在 iPhone 和 iPad 各执行一遍隔离 UI 流程，模拟器测试不会读取
或污染日常应用恢复状态。CI 在测试前擦除两个 Simulator，复用一次显式测试构建，并在 app 崩溃时仍
保留最终 Simulator 截图；任一设备失败不会阻止另一设备、Release archive 和 `.xcresult` 证据检查。
build、analyze、test-build 和 archive 会各自保留结构化结果；archive 门禁还会扫描最终可执行文件，确认
Debug-only 的 UI 测试环境键没有进入 Release 产物。

真机运行需要在 Xcode 中为 bundle ID `com.lumen.editor.native-preview.ios` 选择开发团队。预览版 bundle ID
和恢复目录故意与桌面版隔离。

## 当前边界

这是进入发行候选验收的原生实现，不宣称已经达到 App Store 正式发行状态。发布前仍需按
[验收清单](../docs/NATIVE_IOS_ACCEPTANCE.md)完成真机 IME、iCloud/第三方 File Provider、VoiceOver、
内存压力、后台终止与签名归档验证。Build、Terminal、本地 LSP executable 和桌面插件 worker 不属于
iOS 本地能力；未来应通过显式授权的远程工作区提供。
