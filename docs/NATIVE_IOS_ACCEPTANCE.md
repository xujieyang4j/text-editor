# iOS 原生版发行验收清单

每个正式候选构建必须保留 Xcode 版本、commit、设备型号、iOS 版本、步骤、结果、屏幕录制或截图、
`.xcresult`。仅“代码存在”或 Linux 静态检查通过不算发行验收。

## 自动门禁

- [x] `npm run check:native-ios` 锁定 iOS 17、独立 bundle ID、TextKit 2、IME guard、Document Picker、
  security scope、`NSFileCoordinator`、20 MiB 上限、草稿 Data Protection、冲突检测和写后验证。
- [x] 契约门禁覆盖后台恢复时限、损坏草稿告警、Provider 陈旧回调、并发重复打开、异步可取消查找、
  Save As 基线隔离、原始编码字节恢复、启动与运行时内存预算、替换结果构造前限额、辅助字号重排，
  以及 DEBUG-only UI 测试存储隔离。
- [ ] macOS CI `xcodebuild build` 在 generic iOS Simulator 上以 warnings-as-errors 通过。
- [ ] macOS CI `xcodebuild analyze` 无新增诊断，unsigned Release archive 包含 Privacy Manifest、双语
  `InfoPlist.strings`、编译后的 App Icon 资产、iPhone/iPad 设备族、正确 bundle ID、最低系统版本和非空
  版本号；Release 可执行文件不得包含 `LUMEN_UI_TEST_SESSION` 测试入口。build、analyze、test-build 与
  archive 均须上传独立 `.xcresult`，Simulator 单项测试须设置超时，避免挂起占满整个 job。
- [ ] iPhone simulator 跑完 Mobile Core 编码、查找、草稿、dirty 状态、冲突测试，以及创建/输入、
  查找替换与撤销重做、双草稿切换、中英文生成名 UI 流程；iPad simulator 再跑同组 UI 流程。上传
  两份含最终 Simulator 截图且可由 `xcresulttool` 读取的 `.xcresult`、JSON 摘要与 Xcode/macOS/commit/
  workflow run/设备/运行时清单；每条 UI 测试必须使用独立草稿/最近文件目录，两个 Simulator 执行前
  必须擦除。结果摘要的执行数必须与源码自动统计一致（当前 iPhone 48 Core + 4 UI、iPad 4 UI）；
  iPhone 流程失败时仍必须执行 iPad、archive、结果校验与证据上传。
- [ ] Release archive 的 Privacy Manifest、App Icon、版本、bundle ID 和签名验证通过。

## 真机必测

- [ ] iPhone 小屏与 Max 尺寸、iPad 横竖屏：工具栏不遮正文，查找条随键盘正确布局。
- [ ] 简体中文拼音、双拼、手写，日文、韩文：组合文本不跳光标、不丢字、不重复 undo 步骤。
- [ ] iCloud Drive、本机、至少一个第三方 File Provider：打开、编辑、保存、离线、恢复联网。
- [ ] 文件打开后由另一设备修改：保存必须拒绝覆盖，草稿保持可恢复。
- [ ] 干净文件在另一设备修改：前台自动重载且 selection 被安全限制；脏文件必须显示冲突对话框。
- [ ] 冲突对话框逐项验证：保留本地副本后重载、放弃并重载、另存为、暂不处理；普通保存不得绕过冲突。
- [ ] 打开中的文件被改名/移动：标题、bookmark、最近文件和语法模式更新，旧最近记录被替换，并继续监听新 URL。
- [ ] 打开中的文件被删除：可断开为本地恢复草稿或另存为；内容不能静默丢失。
- [ ] Provider 暂时离线/不可读：显示“暂不可用”而非误报删除，重试成功后恢复安全保存。
- [ ] Provider 报告写入成功但读回失败/不一致：dirty 不清除，显示警告，草稿不删除。
- [ ] “另存为”成功后逐字节验证、切换 source bookmark 并重启可恢复；取消不显示错误。
- [ ] 分享副本保持当前编码和 EOL，不改变 dirty/source/baseline，分享完成后临时文件被清理。
- [ ] 编辑后切后台、系统终止、手动杀进程、低存储：重启后恢复最后检查点。
- [ ] 后台检查点或恢复文件读取失败会明确告警；损坏文件保留，关闭文档前恢复草稿删除事务完成。
- [ ] 同一毫秒内连续检查点以单调代次选择最新内容；超过 30 份或 96 MiB 启动预算的旧草稿保留
  在磁盘，并在关闭部分文档、重启后继续恢复。
- [ ] 冷启动恢复期间由 Files/URL 激活或用户新建/打开文档不会丢失、重复或被恢复结果覆盖；达到 30 份
  或 96 MiB 工作区预算后，新建、打开和“保留本地副本”均明确拒绝且不分配第二份文档内容。
- [ ] 接近 96 MiB 工作区边界时，软键盘、IME 提交、硬件键盘、粘贴、查找替换和复制行的增长操作
  在修改 TextKit 缓冲区前被明确拒绝；删除、反缩进和其他不增长操作仍可执行，以便用户释放预算。
- [ ] 干净文档的外部变化或手动重新载入若会突破工作区预算，现有缓冲区保持不变且进入显式处理；
  关闭其他文档后重试可安全载入，重选编码也遵守相同边界。
- [x] Core XCTest 已覆盖 UTF-8/BOM、UTF-16 LE/BE（含无 BOM）、GB18030、GBK、Big5、Shift JIS、
  Windows-1252、Latin-1 与 LF/CRLF/CR 的 36 组严格字节往返；Apple Simulator 仍须执行并留存
  `.xcresult`。GBK、GB18030 四字节、Big5、Shift JIS、Windows-1252 与 Latin-1 另有已知标准字节 fixture，
  不可表示字符必须阻止保存。
- [ ] 无效或歧义编码文件在切后台、终止、Provider 离线/删除后，仍能用受保护的原始字节重新选择
  编码；若原文件 revision 已变化，必须保持 dirty 并进入冲突状态。
- [ ] VoiceOver 完成打开文件、切换文档、编辑、查找、保存；最大辅助字号下主要操作仍可达。
- [ ] VoiceOver 可听到保存、冲突与恢复失败公告；最大辅助字号下查找/替换条和状态栏无不可达操作。
- [ ] 外接键盘 `⌘S`、`⌘F`、`⌘P`、`⌘Z`、`⇧⌘Z` 与软键盘 accessory 均工作。
- [ ] 软键盘 accessory 和菜单完成多行缩进/反缩进/复制行；`⌘]`、`⌘[`、`⇧⌘D` 可用且一次撤销恢复。
- [ ] 状态栏的行、列、UTF-16 选择长度、编码、EOL 和未保存状态随光标/编辑实时更新；超大偏移处退化为位置显示且不阻塞主线程。
- [ ] 20 MiB 边界、长行、emoji/组合字符、10,000 个匹配在内存压力下不崩溃。
- [ ] 20 MiB 文档连续修改搜索词、切换选区和关闭查找条时，后台扫描可取消且陈旧结果不会回写 UI。
- [ ] 大量匹配配合长替换文本时，替换结果在构造前按剩余工作区预算拒绝，不出现先分配巨型字符串后再拦截的峰值；
  emoji、`$$`、`$&`、有效和无效 `$digits` 模板的预检长度与最终输出一致。

## 当前发布判断

当前为 **发行候选代码阶段**：安全编辑闭环、外部变化处理、另存为/分享、高频移动编辑和自动化入口
已经具备，但上述 Xcode、Provider、IME、VoiceOver 和真机中断矩阵尚未产生证据前，不得标记为 App Store
正式版，也不得替代 Electron 桌面正式版。
