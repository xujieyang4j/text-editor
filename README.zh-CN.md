# Lumen Editor

> [English](./README.md) | **中文** ｜ [图文编辑器使用指南](./docs/编辑器使用指南.md) ｜ [安装与使用说明](./docs/使用说明.md)

一款基于 **Electron + TypeScript + CodeMirror 6** 的跨平台桌面文本编辑器，
单一代码库即可在 **Linux、Windows、macOS** 上运行。

📖 **完整使用指南（中英双语）：** [`docs/USER_GUIDE.md`](./docs/USER_GUIDE.md)

## 功能特性

- **Markdown 实时预览**：并排渲染预览（`Ctrl/Cmd+Shift+V`），经 DOMPurify 消毒，随输入实时更新
- **HTML 在浏览器打开**：`.html` 文件会出现悬浮浏览器图标，点击它（或 *View: Open in Browser*）
  用系统浏览器预览；未保存/未命名的内容使用临时快照，不弹保存窗口、不修改源文件
- **命令面板**（`Ctrl/Cmd+Shift+P`）：模糊搜索全部命令，Sublime 风格
- **Goto Anything**（`Ctrl/Cmd+P`）：模糊查找工作区文件，支持 `:行号[:列号]`、`@当前文件符号`、
  `#项目符号` 子模式与 `文件名:行:列` 精确定位
- **多组布局与窗口**：单组、2/3 列、4 宫格；每组独立标签栏，支持移动/克隆文件到下一组
- **当前文件查找导航**：`F3` / `Shift+F3` 分别跳到当前文件中的下一个 / 上一个匹配，也可从“编辑”菜单或命令面板
  执行；它们不同于使用 `F4` / `Shift+F4` 的工作区结果导航
- **Find Results 与项目符号**：工作区查找结果持久保留并可用 `F4` / `Shift+F4` 跳转；
  支持项目级函数、类和标题查找
- **统一导航历史**：`Alt+←` / `Alt+→` 可在成功的跳转到行、Goto Anything（文件、行、当前文件符号、
  项目符号）、大纲、工作区搜索结果、构建问题、定义/引用、书签、匹配括号和改动跳转之间后退/前进。
  只有成功且确实移动到新位置后才会记录；取消、失败或原地跳转不会污染历史。本次运行中可返回仍打开的
  未命名文档及其原分屏组，关闭的文件可按路径重开；导航历史不会跨重启保留。
- **跳转到符号**（`Ctrl/Cmd+R`）、**跳转到行**（`Ctrl/Cmd+G`）与**跳转到匹配括号**（`Ctrl/Cmd+Shift+\`）
- **多标签编辑**：带未保存（脏）标记、固定标签、关闭按钮与标签顺序恢复
- **语法高亮**：100+ 语言按扩展名自动识别；可通过状态栏语言按钮或**设置语法…**手动指定
- **Minimap 缩略图**、**缩进参考线**、**竖直标尺**、行尾空白高亮
- **行号显示**：通过 *View → Toggle Line Numbers*、命令面板中的 *View: Toggle Line Numbers*，
  或 Settings 中的 `showLineNumbers` 复选框开关；该持久化选项默认开启，只改变边栏显示，并统一作用于
  所有标签和分栏
- **空白字符标记**：通过 *View → Toggle Whitespace Characters*、命令面板中的同名命令或设置项，
  显示空格和 Tab 的视觉标记；该持久化选项默认关闭，不修改文本，也不影响行尾空白高亮
- **行操作**：上/下移动行、复制行、删除行、按词删除、删除至行首/行尾、复制选区、在上方/下方新建空行
  （`Ctrl/Cmd+Shift+Enter` / `Enter`）、转置相邻字符（`Ctrl+T`）、合并行、切换注释（`Ctrl/Cmd+/`），
  以及“编辑”菜单或命令面板中的升序排列行、降序排列行、反转行顺序、删除重复行和删除空白行。对这些
  块操作，每个非空选区都会扩展到完整物理行，不相邻的行块分别处理；所有选区均为空时处理全文。选区和
  光标会随编辑映射到对应位置，剩余内容保留原有的末尾换行状态。删除重复行按整行精确匹配，并稳定保留
  第一次出现；删除空白行仅删除内容长度为零或只含空格、Tab 的物理行，若删掉所有行，结果为空文档
- **确保单个末尾换行**：通过 *Edit → Ensure Single Final Newline* 或命令面板中的
  *Edit: Ensure Single Final Newline* 执行。非空文档末尾没有逻辑 `LF` 时添加一个，存在多个连续末尾 `LF`
  时收敛为一个；已有恰好一个时不变，空文档保持为空。该命令只处理文档末尾的换行符，不会删除末行内容
  中的空格或 Tab；内部的逻辑 `LF` 会在保存时按当前选择写为 `LF`、`CRLF` 或 `CR`。选区和光标会随编辑
  映射，整个改动可一次撤销
- **段落重排 / 取消段落换行**：*Edit: Wrap Paragraph at 80 Columns*（`Alt+Q`）会在每个光标或非空选区
  所在段落内插入物理硬换行，把内容重排到 80 个逻辑字素列附近；*Edit: Unwrap Paragraph* 会移除段落内部的
  硬换行。它不同于 `Alt+Z` 软换行，后者只改变屏幕显示。空行、缩进变化和受支持的重复前缀（`#`、`//`、
  `///`）会作为段落边界；段内空白会被规范化，列宽按 Tab 停靠位计算，超长 token 会保持完整并可超过 80 列，
  富 Markdown 悬挂前缀和块注释悬挂前缀暂不支持，两个命令都可一次撤销
- **文件树侧栏**：默认收起（`Ctrl/Cmd+B` 展开），可把文件夹作为工作区打开并按需加载目录
- **查找替换**、**文本撤销/重做**、**多光标**、矩形选择、整行/匹配括号/外层语法结构选择、按行拆分选区、
  逐级扩展/缩小选区、多选区大小写转换、括号匹配。其中“编辑 → Swap Case”（命令面板：
  `Edit: Swap Case`）会逐个切换有大小写的 Unicode 字符（标题式字符转为小写），无大小写的字符保持不变；所有非空选区独立转换并
  保持各自方向和范围，没有选区时处理全文，整个操作可一次撤销
- **选区与多光标控制**：撤销选区（`Ctrl/Cmd+U`）、重做选区（Windows/Linux 为 `Alt+U`；
  macOS 为 `Cmd+Shift+U`）及在各行行尾添加光标（`Shift+Alt+I`）；可从“选择”菜单或命令面板
  跳过当前匹配、移除最后一个光标，或在各行行首添加光标
- **在文件中查找/替换**：支持正则、大小写/全词、包含与排除 glob 过滤
- **分屏编辑**、每标签独立撤销/选区、书签、宏录制与可复用片段
- **工作区工具**：新建/重命名/回收站删除/系统定位、外部变更刷新、构建输出
- **语言工具**：可选标准 LSP 格式化/诊断，以及标准输入输出格式化器。通过**工具 → 显示语言服务器**
  可查看正在启动、运行中、正在停止、已停止或错误状态、服务器能力、有界的标准错误/服务器通知日志，
  并可重启服务。面板不显示原始协议消息；畸形或超限协议帧会终止异常服务器。
- **本地声明式插件**：项目范围的片段和命令面板插入文本命令
- **配色、Git 与 HTTPS 市场**：独立 UI/代码配色方案；Git 改动/diff、本地操作、上游领先/落后
  状态与脱敏远端详情；受确认的声明式插件市场
- **自动补全**、语言感知的选区自动重新缩进、代码折叠（当前/全部折叠与展开）、当前行高亮、选中词高亮
- **文档统计**：全文或选区的行数、Unicode 字符数、非空白字符数与词/标记数
- **热退出 / 会话恢复**：下次启动自动重开上次的标签与文件夹，并在意外退出后**保留未保存的编辑**
  （含未命名缓冲区）；**重开关闭的标签**（`Ctrl/Cmd+Shift+T`）
- **持久化设置**（userData 中的 JSON）：字号、Tab 宽度、主题、换行、Minimap、行号、空白字符标记、标尺
- **EditorConfig 互操作**：工作区内文件会读取项目中的 `.editorconfig`，支持 `indent_style`、
  `indent_size`、`tab_width`、`end_of_line`、嵌套配置、`root = true`、常用 section glob 与 `unset`。
  规则只影响后续编辑和保存，单纯打开文件不会改写内容或标脏；状态栏中手动选择的换行格式优先。解析
  严格限制在已授权工作区内，过深、过大或过于复杂的配置会安全回退到正文检测和用户默认设置。
  `indent_style = tab` 始终插入硬 Tab；若数字 `indent_size` 与 `tab_width` 不同，每级硬 Tab 采用
  `tab_width` 的列宽。
- **字号缩放**（`Ctrl/Cmd+=` / `-` / `0`）、明暗主题、软换行、可折叠侧边栏
- **状态栏编码与换行符可点击**：可选 `UTF-8`、`UTF-8 BOM`、`UTF-16 LE`、`UTF-16 BE`，
  以及 `LF`、`CRLF`、`CR`。选择后会把它设为下次保存目标并标记为未保存；保存、全部保存或
  自动保存才会写入磁盘，保存时也会把混合换行统一为所选格式。打开时基于 BOM 区分四种
  Unicode 格式：UTF-8 BOM 对应 UTF-8 BOM，UTF-16 BOM 对应 LE 或 BE，无 BOM 则按
  UTF-8 读取；不会根据内容猜测旧式编码
- **原生应用菜单**，各平台均带标准键盘快捷键
- **无障碍基础支持**：清晰的键盘焦点、语义化对话框与结果区域、屏幕阅读器状态播报、
  焦点恢复，以及系统减少动效和强制色模式适配
- **安全架构**：开启 `contextIsolation`、关闭 `nodeIntegration`；渲染进程只能通过类型化的
  `contextBridge` API 访问文件系统

## 架构

```
src/
  shared/ipc.ts          IPC 通道名 + 共享类型（进程间契约）
  main/                  Electron 主进程（Node 环境）
    index.ts             窗口创建 + 应用生命周期
    menu.ts              原生菜单；快捷键 -> 渲染进程事件
    files.ts             文件系统 IPC 处理（打开/保存/读目录），唯一的 fs 入口
  preload/index.ts       contextBridge：暴露 window.editor 类型化 API
  renderer/              界面（浏览器环境，无 Node 权限）
    index.html           应用外壳标记
    src/
      main.ts            应用外壳：持有文档、标签，接线菜单事件
      editor.ts          CodeMirror 6 封装（语言/主题/换行/查找）
      documents.ts       文档模型 + 脏状态跟踪
      fileTree.ts        懒加载可折叠工作区文件树
      styles.css         VS Code 风格深色界面
```

菜单/快捷键命令由主进程通过单一 `menu:event` 通道派发给渲染进程；渲染进程持有全部文档状态。
文件读写方向相反：渲染进程调用 `window.editor.*`，触发 `src/main/files.ts` 中的处理函数。

## 环境要求

- **Node.js** ≥ 18（开发环境为 v22）
- 首次 `npm install` 需联网下载 Electron 运行时二进制。网络受限时可设镜像：
  ```bash
  export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
  ```

## 开发运行

```bash
git clone git@github.com:xujieyang4j/text-editor.git
cd text-editor
npm install          # 安装依赖 + Electron 二进制
npm run dev          # 启动应用（热重载，electron-vite）
```

如果 macOS 把开发环境的 `Electron.app` 误报为恶意软件/已损坏，或把它移到废纸篓，一条命令
完成修复并启动：

```bash
npm run dev:mac
```

`dev:mac` 会按需恢复 Electron、修复并验证当前项目的运行时，然后直接启动编辑器。它只处理
`node_modules/electron/dist/Electron.app`，不会关闭 Gatekeeper，也不会修改系统级安全设置。
若只想修复、不启动，仍可运行 `npm run fix:mac`。

> ⚠️ **请勿运行 `npm audit fix --force`。** 报告的漏洞全部位于构建/打包工具链，不会打包进最终
> 应用，`--force` 只会把工具链升级到互不兼容的大版本、破坏环境。详见
> [`docs/使用说明.md`](./docs/使用说明.md) 的 FAQ。

> 运行 GUI 需要图形桌面环境。无显示器的 Linux 服务器需要虚拟显示（如 `xvfb-run -a npm run dev`）
> 以及 GPU/Mesa 库（`libgbm1`、`libwayland-server0`）。普通桌面版 Linux/Windows/macOS 无需这些。

## 构建与校验（无需 GUI）

```bash
npm run typecheck    # 对 node 与 web 两套 tsconfig 做类型检查
npm run build        # 打包 main、preload、renderer 到 out/
npm test             # 共享测试 + 类型检查 + 生产构建
```

## 项目配置

打开文件夹后，可通过 **Project → Configure Project…** 创建可随项目携带的
`.lumen-project.json`。其中保存排除规则、构建命令、快捷键覆盖、启用插件、语言工具和
语言服务器。语言服务器、格式化器及项目配置中的其他外部命令，在每次应用启动后都需要首次确认才会执行。
本地声明式插件位于 `.lumen-plugins/<id>/plugin.json`，只能贡献片段或插入文本命令。

## 打包安装程序

产物输出到 `release/<版本号>/`：

```bash
npm run dist         # 当前操作系统
npm run dist:win     # Windows：NSIS 安装程序 + 便携版 .exe
npm run dist:mac     # macOS：.dmg + .zip
npm run dist:linux   # Linux：AppImage + .deb
```

> electron-builder 默认为宿主操作系统构建。生成 macOS 产物必须在 macOS 上；Windows/Linux 目标在
> 多数宿主上可跨平台构建（在 Linux 上打 Windows 包可能需要 Wine）。目标配置见 `electron-builder.yml`。

## 键盘快捷键

| 操作                | 快捷键                       |
| ------------------- | --------------------------- |
| 命令面板            | `Ctrl/Cmd+Shift+P`          |
| Goto Anything       | `Ctrl/Cmd+P`                |
| 跳转到符号          | `Ctrl/Cmd+R`                |
| 跳转到行            | `Ctrl/Cmd+G`                |
| 跳转历史后退 / 前进 | `Alt+←` / `Alt+→`          |
| 新建文件            | `Ctrl/Cmd+N`                |
| 打开文件            | `Ctrl/Cmd+O`                |
| 打开文件夹          | `Ctrl/Cmd+Shift+O`          |
| 保存                | `Ctrl/Cmd+S`                |
| 另存为              | `Ctrl/Cmd+Shift+S`          |
| 关闭标签            | `Ctrl/Cmd+W`                |
| 重开关闭的标签      | `Ctrl/Cmd+Shift+T`          |
| 切换标签            | `Ctrl/Cmd+1..9`             |
| 下一个 / 上一个标签 | `Ctrl/Cmd+Alt+→/←`         |
| 查找                | `Ctrl/Cmd+F`                |
| 替换                | `Ctrl/Cmd+H`                |
| 当前文件下一个 / 上一个匹配 | `F3` / `Shift+F3`    |
| 工作区下一条 / 上一条结果 | `F4` / `Shift+F4`      |
| 切换 Markdown 预览  | `Ctrl/Cmd+Shift+V`          |
| 切换注释            | `Ctrl/Cmd+/`                |
| 上/下移动行         | `Alt+↑/↓`                  |
| 上/下复制行         | `Shift+Alt+↑/↓`            |
| 复制行/选区         | `Ctrl/Cmd+Shift+D`          |
| 删除行              | `Ctrl/Cmd+Shift+K`          |
| 按 80 列重排段落    | `Alt+Q`                     |
| 放大/缩小/重置字号  | `Ctrl/Cmd+=` / `-` / `0`    |
| 显隐侧边栏          | `Ctrl/Cmd+B`                |
| 切换软换行          | `Alt+Z`                     |
| 切换主题            | `Ctrl/Cmd+K`                |

## 许可证

MIT
