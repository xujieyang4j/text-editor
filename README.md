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
- **Goto Anything** (`Ctrl/Cmd+P`) — fuzzy workspace file finder with `:line[:column]`,
  `@current-symbol`, and `#project-symbol` modes
- **Multi-group layouts & windows** — single, 2/3-column and 4-grid layouts with independent tab groups
- **Current-file find navigation** — run *Find Next* (`F3`) or *Find Previous* (`Shift+F3`)
  from the Edit menu or Command Palette; these are separate from workspace-result navigation
  with `F4` / `Shift+F4`
- **Find Results & project symbols** — persistent workspace results (`F4` / `Shift+F4` navigation)
  and project-wide function, class, and heading lookup
- **Unified navigation history** — `Alt+Left` / `Alt+Right` goes back/forward across successful
  Goto Line and Goto Anything jumps (file, line, current/project symbol), outline selections,
  workspace-search results, build problems, definitions/references, bookmarks, matching brackets,
  and change navigation. A jump is recorded only after it succeeds and actually moves; canceled,
  failed, and no-op attempts leave history unchanged. During the current app run, history supports
  still-open untitled documents and their original split groups, and can reopen a closed file from
  its path. Navigation history is not restored after restart.
- **Goto Symbol** (`Ctrl/Cmd+R`) and **Goto Line** (`Ctrl/Cmd+G`)
- **Multi-tab editing** with dirty (unsaved) indicators, pinned tabs, close buttons, and restored tab order
- **Syntax highlighting** for 100+ languages, auto-detected by extension; manual override via
  the status-bar language button or **Set Syntax…**
- **Minimap** and **indentation guides**, **vertical rulers**, trailing-whitespace highlight
- **Whitespace character markers** — choose *View → Toggle Whitespace Characters*, run the same
  command from the Command Palette, or enable it in Settings to reveal spaces and tabs without
  changing document text; this persistent option is off by default and is independent of
  trailing-whitespace highlighting
- **Line operations**: move/copy/delete line, duplicate, toggle comment (`Ctrl/Cmd+/`), plus
  *Sort Lines Ascending*, *Sort Lines Descending*, *Reverse Lines*, *Unique Lines*, and *Remove Blank
  Lines* from the Edit menu or Command Palette. For these block operations, every non-empty selection
  expands to complete physical lines and disjoint blocks are processed independently; if every selection
  is empty, they process the whole file. Selections and cursors remain mapped through the edit, and the
  remaining content keeps its final-newline state. *Unique Lines* matches complete lines exactly and
  stably keeps the first occurrence. *Remove Blank Lines* deletes physical lines that are empty or contain
  only spaces or tabs; if it removes every line, the document becomes empty
- **File tree sidebar** — starts collapsed (`Ctrl/Cmd+B` to show), opens a folder as a
  workspace, and lazily expands directories
- **Find & replace**, **text undo/redo**, **multi-cursor**, rectangular selection, bracket matching,
  and multi-selection case conversion. *Edit → Swap Case* (Command Palette: *Edit: Swap Case*)
  toggles each Unicode character that has case (titlecase becomes lowercase), leaves uncased characters unchanged, processes every
  non-empty selection independently while preserving its range and direction, or processes the whole
  document when there is no selection. The operation is undoable in one step
- **Selection & multi-cursor control** — undo selection (`Ctrl/Cmd+U`), redo selection
  (Windows/Linux `Alt+U`; macOS `Cmd+Shift+U`), and add cursors to line ends (`Shift+Alt+I`);
  skip the current occurrence, remove the last cursor, or add cursors to line starts from the
  Selection menu or Command Palette
- **Find / Replace in Files** with regex, case/word filters and include/exclude globs
- **Split editing**, per-tab undo/selection preservation, bookmarks, macros and reusable snippets
- **Workspace tools**: file create/rename/trash/reveal, external-change refresh, project build output
- **Language tooling**: optional standard LSP formatting/diagnostics plus stdin/stdout formatters.
  **Tools → Show Language Servers** shows starting/running/stopping/stopped/error states, advertised
  capabilities, bounded stderr/server-notification logs, and a restart action. Raw protocol messages
  are omitted; malformed or oversized framing terminates the faulty server.
- **Local declarative plugins**: project-scoped snippets and command-palette text commands
- **Schemes, Git & HTTPS marketplace**: separate UI/editor color schemes; Git changes, diffs,
  local actions, upstream/ahead/behind and credential-redacted remote details; confirmed declarative plugin sources
- **Autocompletion**, code folding, active-line highlight, selection-match highlight
- **Hot exit / session restore** — reopens your tabs + folder on next launch and **preserves
  unsaved edits** (even untitled buffers) across an unexpected quit; **Reopen Closed Tab**
  (`Ctrl/Cmd+Shift+T`)
- **Persistent settings** (JSON in userData): font size, tab size, theme, wrap, minimap, whitespace
  character markers, rulers
- **Font zoom** (`Ctrl/Cmd+=` / `-` / `0`), dark/light theme, word-wrap, collapsible sidebar
- **Clickable encoding & line endings** in the status bar: choose `UTF-8`, `UTF-8 BOM`,
  `UTF-16 LE`, or `UTF-16 BE`, and `LF`, `CRLF`, or `CR`. A choice sets the target for
  the next Save, Save All, or Auto Save and marks the document unsaved; saving also
  normalizes mixed line endings to the selected style. On open, BOM detection distinguishes the
  four Unicode formats: a UTF-8 BOM selects UTF-8 BOM, UTF-16 BOMs select LE or BE, and no
  BOM falls back to UTF-8; the editor does not guess legacy encodings from content
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
Language servers, formatters, and other external commands from this file require a one-time approval per app
session before Lumen starts them. Local declarative plugins live in `.lumen-plugins/<id>/plugin.json` and may
contribute snippets or insert-text commands only.

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
| Navigation back / forward | `Alt+Left` / `Alt+Right` |
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
| Find next / previous in current file | `F3` / `Shift+F3` |
| Next / previous workspace result | `F4` / `Shift+F4` |
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
