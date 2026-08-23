# Lumen Editor

> [English](./README.md) | **中文** ｜ 详细使用说明见 [`docs/使用说明.md`](./docs/使用说明.md)

一款基于 **Electron + TypeScript + CodeMirror 6** 的跨平台桌面文本编辑器，
单一代码库即可在 **Linux、Windows、macOS** 上运行。

📖 **完整使用指南（中英双语）：** [`docs/USER_GUIDE.md`](./docs/USER_GUIDE.md)

## 功能特性

- **命令面板**（`Ctrl/Cmd+Shift+P`）：模糊搜索全部命令，Sublime 风格
- **Goto Anything**（`Ctrl/Cmd+P`）：模糊查找工作区文件，支持 `:行号` 与 `@符号` 子模式
- **跳转到符号**（`Ctrl/Cmd+R`）与**跳转到行**（`Ctrl/Cmd+G`）
- **多标签编辑**：带未保存（脏）标记与关闭按钮
- **语法高亮**：100+ 语言按扩展名自动识别；可通过状态栏语言按钮或**设置语法…**手动指定
- **Minimap 缩略图**、**缩进参考线**、**竖直标尺**、行尾空白高亮
- **行操作**：上/下移动行、复制行、删除行、复制选区、切换注释（`Ctrl/Cmd+/`）、行排序
- **文件树侧栏**：把文件夹作为工作区打开，按需懒加载展开
- **查找替换**、**撤销/重做**、**多光标**、矩形选择、括号匹配
- **自动补全**、代码折叠、当前行高亮、选中词高亮
- **热退出 / 会话恢复**：下次启动自动重开上次的标签与文件夹，并在意外退出后**保留未保存的编辑**
  （含未命名缓冲区）；**重开关闭的标签**（`Ctrl/Cmd+Shift+T`）
- **持久化设置**（userData 中的 JSON）：字号、Tab 宽度、主题、换行、Minimap、标尺
- **字号缩放**（`Ctrl/Cmd+=` / `-` / `0`）、明暗主题、软换行、可折叠侧边栏
- **状态栏**：行/列、选中字符数、语言、编码、换行符
- **原生应用菜单**，各平台均带标准键盘快捷键
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

> ⚠️ **请勿运行 `npm audit fix --force`。** 报告的漏洞全部位于构建/打包工具链，不会打包进最终
> 应用，`--force` 只会把工具链升级到互不兼容的大版本、破坏环境。详见
> [`docs/使用说明.md`](./docs/使用说明.md) 的 FAQ。

> 运行 GUI 需要图形桌面环境。无显示器的 Linux 服务器需要虚拟显示（如 `xvfb-run -a npm run dev`）
> 以及 GPU/Mesa 库（`libgbm1`、`libwayland-server0`）。普通桌面版 Linux/Windows/macOS 无需这些。

## 构建与校验（无需 GUI）

```bash
npm run typecheck    # 对 node 与 web 两套 tsconfig 做类型检查
npm run build        # 打包 main、preload、renderer 到 out/
```

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
| 切换注释            | `Ctrl/Cmd+/`                |
| 上/下移动行         | `Alt+↑/↓`                  |
| 上/下复制行         | `Shift+Alt+↑/↓`            |
| 复制行/选区         | `Ctrl/Cmd+Shift+D`          |
| 删除行              | `Ctrl/Cmd+Shift+K`          |
| 放大/缩小/重置字号  | `Ctrl/Cmd+=` / `-` / `0`    |
| 显隐侧边栏          | `Ctrl/Cmd+B`                |
| 切换软换行          | `Alt+Z`                     |
| 切换主题            | `Ctrl/Cmd+K`                |

## 许可证

MIT
