# Lumen Editor

> **English** | [中文](./README.zh-CN.md)

A cross-platform desktop text editor built with **Electron + TypeScript + CodeMirror 6**.
Runs on **Linux, Windows, and macOS** from a single codebase.

## Features

- **Multi-tab editing** with dirty (unsaved) indicators and close buttons
- **Syntax highlighting** for 100+ languages, auto-detected by file extension (via `@codemirror/language-data`)
- **File tree sidebar** — open a folder as a workspace, lazily expand directories
- **Find & replace** (`Ctrl/Cmd+F`, `Ctrl/Cmd+H`) and **Go to Line** (`Ctrl/Cmd+G`)
- **Undo/redo**, **multi-cursor**, rectangular selection, bracket matching, auto-close brackets
- **Autocompletion**, code folding, active-line highlight, selection-match highlight
- **Status bar**: line/column, selection length, language, encoding, line-ending
- **Dark / light theme** toggle, soft **word-wrap** toggle, collapsible sidebar
- **Native application menu** with standard keyboard accelerators on every platform
- **Secure architecture**: `contextIsolation` on, `nodeIntegration` off; the renderer reaches
  the filesystem only through a typed `contextBridge` API

## Architecture

```
src/
  shared/ipc.ts          IPC channel names + shared types (the process contract)
  main/                  Electron main process (Node)
    index.ts             window creation + app lifecycle
    menu.ts              native menu; accelerators -> renderer events
    files.ts             fs IPC handlers (open/save/read-dir), the only fs access
  preload/index.ts       contextBridge: exposes window.editor typed API
  renderer/              UI (browser context, no Node access)
    index.html           app shell markup
    src/
      main.ts            App shell: owns docs, tabs, wires menu events
      editor.ts          CodeMirror 6 wrapper (language/theme/wrap/search)
      documents.ts       Doc model + dirty tracking
      fileTree.ts        lazy collapsible workspace tree
      styles.css         VS Code-like dark UI
```

Menu/accelerator commands are dispatched from the main process to the renderer over a single
`menu:event` channel; the renderer owns all document state. File I/O is the reverse direction:
the renderer calls `window.editor.*`, which invokes handlers in `src/main/files.ts`.

## Prerequisites

- **Node.js** ≥ 18 (developed on v22)
- Internet access to download the Electron binary on first `npm install`.
  In restricted networks set a mirror, e.g.:
  ```bash
  export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
  ```

## Development

```bash
git clone git@github.com:xujieyang4j/text-editor.git
cd text-editor
npm install          # installs deps + Electron binary
npm run dev          # launch the app with hot reload (electron-vite)
```

> ⚠️ **Do NOT run `npm audit fix --force`.** The reported advisories are all in build-time
> tooling and are never bundled into the app; `--force` upgrades the toolchain to mutually
> incompatible major versions and breaks the environment. See the FAQ in
> [`docs/使用说明.md`](./docs/使用说明.md).

> A graphical desktop session is required to run the app. On a headless Linux box you need a
> virtual display, e.g. `xvfb-run -a npm run dev`, plus GPU/Mesa libraries (`libgbm1`,
> `libwayland-server0`). Regular desktop installs of Linux/Windows/macOS need none of this.

## Build & Verify (no GUI needed)

```bash
npm run typecheck    # tsc for both the node and web tsconfigs
npm run build        # bundles main, preload, and renderer into out/
```

## Packaging installers

Produces installers under `release/<version>/`:

```bash
npm run dist         # current OS
npm run dist:win     # Windows: NSIS installer + portable .exe
npm run dist:mac     # macOS: .dmg + .zip
npm run dist:linux   # Linux: AppImage + .deb
```

> electron-builder builds for the host OS by default. Producing macOS artifacts requires macOS;
> Windows/Linux can be cross-built from most hosts (Windows targets may need Wine on Linux).
> Targets are configured in `electron-builder.yml`.

## Keyboard shortcuts

| Action            | Shortcut                    |
| ----------------- | --------------------------- |
| New file          | `Ctrl/Cmd+N`                |
| Open file         | `Ctrl/Cmd+O`                |
| Open folder       | `Ctrl/Cmd+Shift+O`          |
| Save              | `Ctrl/Cmd+S`                |
| Save as           | `Ctrl/Cmd+Shift+S`          |
| Close tab         | `Ctrl/Cmd+W`                |
| Switch tab        | `Ctrl/Cmd+1..9`             |
| Next / prev tab   | `Ctrl/Cmd+Alt+Right/Left`   |
| Find              | `Ctrl/Cmd+F`                |
| Replace           | `Ctrl/Cmd+H`                |
| Go to line        | `Ctrl/Cmd+G`                |
| Toggle sidebar    | `Ctrl/Cmd+B`                |
| Toggle word wrap  | `Alt+Z`                     |
| Toggle theme      | `Ctrl/Cmd+K`                |

## License

MIT
