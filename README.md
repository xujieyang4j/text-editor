# Lumen Editor

> **English** | [中文](./README.zh-CN.md)

A cross-platform desktop text editor built with **Electron + TypeScript + CodeMirror 6**.
Runs on **Linux, Windows, and macOS** from a single codebase.

📖 **Full user guide (bilingual):** [`docs/USER_GUIDE.md`](./docs/USER_GUIDE.md)

## Features

- **Markdown live preview** — side-by-side rendered preview (`Ctrl/Cmd+Shift+V`), sanitized
  with DOMPurify, updates as you type
- **Open HTML in browser** — a floating browser icon appears for `.html` files; click it (or
  *View: Open in Browser*) to preview in your system browser; unsaved/untitled content opens
  from a temporary snapshot without prompting you to save
- **Command Palette** (`Ctrl/Cmd+Shift+P`) — fuzzy-search every command, Sublime-style
- **Goto Anything** (`Ctrl/Cmd+P`) — fuzzy file finder with `:line` and `@symbol` sub-modes
- **Multi-group layouts & windows** — single, 2/3-column and 4-grid layouts with independent tab groups
- **Find Results & project symbols** — persistent workspace results (`F4` navigation), project-wide symbols and back/forward history
- **Goto Symbol** (`Ctrl/Cmd+R`) and **Goto Line** (`Ctrl/Cmd+G`)
- **Multi-tab editing** with dirty (unsaved) indicators, pinned tabs, close buttons, and restored tab order
- **Syntax highlighting** for 100+ languages, auto-detected by extension; manual override via
  the status-bar language button or **Set Syntax…**
- **Minimap** and **indentation guides**, **vertical rulers**, trailing-whitespace highlight
- **Line operations**: move/copy/delete line, duplicate, toggle comment (`Ctrl/Cmd+/`), sort lines
- **File tree sidebar** — starts collapsed (`Ctrl/Cmd+B` to show), opens a folder as a
  workspace, and lazily expands directories
- **Find & replace**, **text undo/redo**, **multi-cursor**, rectangular selection, bracket matching
- **Selection & multi-cursor control** — undo selection (`Ctrl/Cmd+U`), redo selection
  (Windows/Linux `Alt+U`; macOS `Cmd+Shift+U`), and add cursors to line ends (`Shift+Alt+I`);
  skip the current occurrence, remove the last cursor, or add cursors to line starts from the
  Selection menu or Command Palette
- **Find / Replace in Files** with regex, case/word filters and include/exclude globs
- **Split editing**, per-tab undo/selection preservation, bookmarks, macros and reusable snippets
- **Workspace tools**: file create/rename/trash/reveal, external-change refresh, project build output
- **Language tooling**: optional standard LSP formatting/diagnostics plus stdin/stdout formatters
- **Local declarative plugins**: project-scoped snippets and command-palette text commands
- **Schemes, Git & HTTPS marketplace**: separate UI/editor color schemes, read-only Git changes/diffs, confirmed declarative plugin sources
- **Autocompletion**, code folding, active-line highlight, selection-match highlight
- **Hot exit / session restore** — reopens your tabs + folder on next launch and **preserves
  unsaved edits** (even untitled buffers) across an unexpected quit; **Reopen Closed Tab**
  (`Ctrl/Cmd+Shift+T`)
- **Persistent settings** (JSON in userData): font size, tab size, theme, wrap, minimap, rulers
- **Font zoom** (`Ctrl/Cmd+=` / `-` / `0`), dark/light theme, word-wrap, collapsible sidebar
- **Status bar**: line/column, selection length, language, encoding, line-ending
- **Native application menu** with standard keyboard accelerators on every platform
- **Accessibility foundation** — visible keyboard focus, semantic dialogs and result regions,
  screen-reader status announcements, focus restoration, reduced-motion and forced-color support
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

If macOS reports the development `Electron.app` as malware/damaged or moves it
to the Trash, use the one-command repair + launch flow:

```bash
npm run dev:mac
```

`dev:mac` restores Electron when necessary, repairs the project-local runtime,
verifies it, and starts the editor. It only touches
`node_modules/electron/dist/Electron.app`; it does not disable Gatekeeper or
change system-wide security settings. `npm run fix:mac` remains available when
you want to repair without launching.

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
npm test             # shared tests + typecheck + production bundle
```

## Project configuration

Opening a folder can create a portable `.lumen-project.json` through **Project → Configure Project…**.
It holds workspace excludes, build command, key overrides, enabled plugins, language tools and language servers.
Commands from this file require a one-time approval per app session before Lumen starts them. Local declarative
plugins live in `.lumen-plugins/<id>/plugin.json` and may contribute snippets or insert-text commands only.

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

| Action              | Shortcut                    |
| ------------------- | --------------------------- |
| Command Palette     | `Ctrl/Cmd+Shift+P`          |
| Goto Anything       | `Ctrl/Cmd+P`                |
| Goto Symbol         | `Ctrl/Cmd+R`                |
| Goto Line           | `Ctrl/Cmd+G`                |
| New file            | `Ctrl/Cmd+N`                |
| Open file           | `Ctrl/Cmd+O`                |
| Open folder         | `Ctrl/Cmd+Shift+O`          |
| Save                | `Ctrl/Cmd+S`                |
| Save as             | `Ctrl/Cmd+Shift+S`          |
| Pin / unpin tab      | `Ctrl/Cmd+Alt+P`            |
| Close tab           | `Ctrl/Cmd+W`                |
| Reopen closed tab   | `Ctrl/Cmd+Shift+T`          |
| Switch tab          | `Ctrl/Cmd+1..9`             |
| Next / prev tab     | `Ctrl/Cmd+Alt+Right/Left`   |
| Find                | `Ctrl/Cmd+F`                |
| Replace             | `Ctrl/Cmd+H`                |
| Toggle Markdown preview | `Ctrl/Cmd+Shift+V`      |
| Toggle comment      | `Ctrl/Cmd+/`                |
| Move line up/down   | `Alt+Up/Down`               |
| Copy line up/down   | `Shift+Alt+Up/Down`         |
| Duplicate line/sel  | `Ctrl/Cmd+Shift+D`          |
| Delete line         | `Ctrl/Cmd+Shift+K`          |
| Zoom in/out/reset   | `Ctrl/Cmd+=` / `-` / `0`    |
| Toggle sidebar      | `Ctrl/Cmd+B`                |
| Toggle word wrap    | `Alt+Z`                     |
| Toggle theme        | `Ctrl/Cmd+K`                |

## License

MIT
