<!-- Lumen Editor — Detailed User Guide (bilingual) -->
<!-- 详细使用说明（中英双语）。English first, 中文在后。 -->

# Lumen Editor — User Guide / 使用指南

**Language / 语言:** [English](#english) ｜ [中文](#中文)

Related docs: [README (EN)](../README.md) ｜ [README (中文)](../README.zh-CN.md) ｜
[安装与使用（快速版）](./使用说明.md)

---

<a id="english"></a>

# English

Lumen Editor is a cross-platform desktop text editor (Linux / Windows / macOS) built on
Electron + TypeScript + CodeMirror 6, with a feature set aligned to Sublime Text.

## Table of Contents

1. [Install & Launch](#en-install)
2. [Interface Tour](#en-interface)
3. [Files & Tabs](#en-files)
4. [Command Palette & Goto](#en-palette)
5. [Editing & Multi-Cursor](#en-editing)
6. [Search & Replace](#en-search)
7. [Syntax Highlighting](#en-syntax)
8. [View: Minimap, Guides, Rulers, Zoom, Theme](#en-view)
9. [Settings Reference](#en-settings)
10. [Session Restore](#en-session)
11. [Full Keyboard Reference](#en-keys)
12. [Troubleshooting](#en-trouble)

<a id="en-install"></a>

## 1. Install & Launch

**Run from source (developers):**

```bash
git clone git@github.com:xujieyang4j/text-editor.git
cd text-editor
npm install          # installs deps + the Electron runtime binary
npm run dev          # launches with hot reload
```

If the Electron binary download is slow, set a mirror first:

```bash
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
npm install
```

> ⚠️ **Never run `npm audit fix --force`.** The reported advisories all live in build-time
> tooling and are never bundled into the app; `--force` upgrades the toolchain to mutually
> incompatible majors and breaks everything. See [Troubleshooting](#en-trouble).

**Build without a GUI** (typecheck + bundle only — useful on servers/CI):

```bash
npm run typecheck
npm run build
```

**Package installers** → output under `release/<version>/`:

```bash
npm run dist:win     # Windows: NSIS installer + portable .exe
npm run dist:mac     # macOS: .dmg + .zip (must build on macOS)
npm run dist:linux   # Linux: AppImage + .deb
```

<a id="en-interface"></a>

## 2. Interface Tour

```
┌───────────┬─────────────────────────────────┐
│  Sidebar  │  Tab bar                         │
│ (file     ├─────────────────────────────────┤
│  tree)    │                                  │
│           │   Editor (CodeMirror) + Minimap  │
│           │                                  │
│           ├─────────────────────────────────┤
│           │ Status: Ln/Col · Lang · Enc · EOL │
└───────────┴─────────────────────────────────┘
```

- **Sidebar** — the workspace file tree. It starts collapsed; toggle with `Ctrl/Cmd+B`.
- **Tab bar** — one tab per open document. A `●` marks unsaved changes; `×` closes the tab; pinned tabs receive an accent marker.
- **Editor** — the CodeMirror text area, with an optional minimap on the right.
- **Status bar** — cursor position and selection length, plus clickable language, encoding, and
  line-ending fields. Click the encoding or line-ending field to choose the next-save format.
- **Keyboard and assistive technology** — interactive panels expose named regions and keyboard-operable
  results, restore focus when closed, and honour reduced-motion and forced-color system settings.

<a id="en-files"></a>

## 3. Files & Tabs

| Action | How |
| --- | --- |
| New file | `Ctrl/Cmd+N` |
| Open file | `Ctrl/Cmd+O` |
| Open folder (workspace) | `Ctrl/Cmd+Shift+O` — populates the sidebar |
| Drag files/folders into the window | files open as tabs; the first folder replaces the workspace and later folders are added as roots |
| Remove a workspace root | *Project: Remove Folder from Project…* — keeps its open tabs but revokes the folder's workspace access |
| Save | `Ctrl/Cmd+S` (untitled files prompt for a path) |
| Save As | `Ctrl/Cmd+Shift+S` |
| Save All | `Ctrl/Cmd+Alt+S` |
| Pin / unpin tab | `Ctrl/Cmd+Alt+P`, double-click the tab, or use its context menu |
| Close tab | `Ctrl/Cmd+W` (prompts if there are unsaved changes) |
| Reopen closed tab | `Ctrl/Cmd+Shift+T` (LIFO stack of recently closed files) |
| Switch to tab N | `Ctrl/Cmd+1` … `Ctrl/Cmd+9` |
| Next / previous tab | `Ctrl/Cmd+Alt+→` / `Ctrl/Cmd+Alt+←` |

The status bar's encoding menu offers **UTF-8**, **UTF-8 BOM**, **UTF-16 LE**, and
**UTF-16 BE**; its line-ending menu offers **LF**, **CRLF**, and **CR**. Selecting either
value sets the target for the next save and marks the document unsaved—it does not rewrite the
file immediately. The target is written by **Save**, **Save All**, or a configured **Auto Save**.
When a file containing mixed line endings is saved, all line endings are normalized to the selected
style.

On open, BOM detection distinguishes these four Unicode formats: a UTF-8 BOM selects **UTF-8
BOM**, UTF-16 BOMs select **UTF-16 LE** or **UTF-16 BE**, and no BOM falls back to
**UTF-8**. The editor does not guess legacy or other encodings from the file contents.

In the file tree, click a folder to expand/collapse it (loaded on demand), and click a file to
open it. Opening a file that's already open just focuses its tab.

Drag a tab within its editor group to reorder it. Ctrl/Cmd-selected tabs move together as one block,
and the order is restored in the next session. Pin a frequently used tab with `Ctrl/Cmd+Alt+P`,
double-click, the pin button, or the tab context menu. Pinned tabs stay at the front of every
editor group, survive restart, and are excluded from **Close Other Tabs**, **Close Tabs to the Right**,
and **Close All Tabs**; closing an individual pinned tab still works normally.

Right-click a file/tree entry or an open tab to copy its full path or project-relative path. The
copy action writes only an already authorised path and does not grant clipboard-read access.

<a id="en-palette"></a>

## 4. Command Palette & Goto

**Command Palette — `Ctrl/Cmd+Shift+P`.** Fuzzy-search every command by name and run it.
Matched characters are highlighted; `↑`/`↓` to move, `Enter` to run, `Esc` to dismiss.

**Goto Anything — `Ctrl/Cmd+P`.** A fuzzy file finder over the open workspace folder, with
prefix modes in the same input:

| Type | Mode | Example |
| --- | --- | --- |
| *(text)* | Fuzzy file path | `maints` → `src/renderer/src/main.ts` |
| `:` + `line[:column]` | Go to a location in the current file | `:120:8` |
| `@` + name | Go to symbol in current file | `@openFolder` |
| `#` + name | Go to a symbol in the workspace | `#parseConfig` |

You can also type `file:line:column` (for example, `main.ts:120:8`) to open a matched workspace
file at an exact location.

**Goto Symbol — `Ctrl/Cmd+R`.** Same as the `@` mode directly. Symbols are extracted with a
fast per-line scan: JS/TS functions, classes, methods and arrow-consts; Python `def`/`class`;
Go `func`; Rust `fn`; and Markdown headings.

**Goto Line — `Ctrl/Cmd+G`.** Enter an absolute `line[:column]`, a relative line such as `+10`
or `-5`, or a percentage such as `50%`. Goto Anything's `:` mode uses the same location syntax.
**Goto Symbol in Project — `Ctrl/Cmd+Shift+R`** opens the workspace-symbol mode directly.

**Goto Matching Bracket — `Ctrl/Cmd+Shift+\`.** With the cursor on, or directly beside, a
matching `()`, `[]` or `{}` pair, jumps to the other end. When no pair is available, the cursor
stays in place. The command is also available through *Goto: Goto Matching Bracket*.

**Back / Forward — `Alt+Left` / `Alt+Right`.** One navigation history is shared by successful
Goto Line and Goto Anything jumps (file, line, current-file symbol, and project symbol), outline
selections, workspace-search results, build problems, definitions/references, bookmarks, matching
brackets, and next/previous-change jumps. An entry is added only after the operation succeeds and
actually moves to another location; cancellation, failure, or an already-current target does not
change either history stack. A still-open untitled document remains addressable, an open target
returns to the split group in which its location was captured, and a closed file can be reopened
from its stored path when that path is still available. This history exists only for the current
app run and is not restored after restart.

> Goto Anything's file list requires an open folder (`Ctrl/Cmd+Shift+O`). With no workspace,
> use `Ctrl/Cmd+P` for `:line[:column]`/`@symbol` in the current file, or the sidebar to open files.

<a id="en-editing"></a>

## 5. Editing & Multi-Cursor

**Multi-cursor (Sublime-style):**

| Action | Shortcut |
| --- | --- |
| Add next occurrence of selection to cursors | `Ctrl/Cmd+D` |
| Undo the last selection change | `Ctrl/Cmd+U` |
| Redo the last selection change | Windows/Linux: `Alt+U`; macOS: `Cmd+Shift+U` |
| Skip current occurrence | Selection menu / Command Palette |
| Remove last cursor | Selection menu / Command Palette |
| Add cursor above / below | `Ctrl/Cmd+Alt+↑` / `Ctrl/Cmd+Alt+↓` |
| Select all occurrences of selection | `Alt+F3` |
| Add cursors to line starts | Selection menu / Command Palette |
| Add cursors to line ends | `Shift+Alt+I` |
| Add a cursor at click point | `Alt`+Click |
| Column (rectangular) selection | `Alt`+Drag |
| Collapse back to a single cursor | `Esc` |

*Undo/Redo Selection* traverses available cursor and selection history without falling through to text undo. When adding
occurrences, *Skip Current Occurrence* replaces the last selected occurrence with the next available
match, while *Remove Last Cursor* removes the last cursor or selection. *Add Cursors to Line
Starts/Ends* places one cursor at the corresponding boundary of each covered physical line. All of
these commands are available from the Selection menu and Command Palette.

**Expand / shrink selection.** Use `Shift+Alt+→` to grow the current selection and
`Shift+Alt+←` to walk back through the exact expansion path. In a recognised language, Lumen
prefers the next enclosing syntax-tree construct (for example, an identifier, expression, argument
list, or block). In plain text, incomplete code, or once syntax expansion is exhausted, it falls back
to **word → current line → whole document**. Moving the cursor, making a manual selection, or
changing text starts a new expansion path. The commands are also available as *Selection: Expand
Selection* and *Selection: Shrink Selection* in the Command Palette.

**Quick line and bracket selections.** *Selection: Select Line* selects the full physical line(s)
touched by the cursor or selection. Its default key is `Alt+L` on Windows/Linux and `Ctrl+L` on
macOS. *Selection: Select to Matching Bracket* extends the active end of the selection to its
matching `()`, `[]`, or `{}` bracket. It leaves the selection untouched when no matching bracket is
available. Both commands are available in the Selection menu and Command Palette.

**Select enclosing syntax.** *Selection: Select Enclosing Syntax* (`Ctrl/Cmd+I`) uses the active
language's syntax tree to select the next outer structure around the cursor or selection—such as
an expression, argument, call, condition, or block. It is useful before copying, deleting, wrapping,
or refactoring a precise code unit. Plain text, incomplete syntax, or an already outermost structure
leave the selection unchanged and show a status message; use Expand Selection to continue growing
where applicable.

**Split selection into lines.** *Selection: Split Selection into Lines* turns every line covered by
all non-empty selections into a cursor at that line's start. Overlapping selected lines are deduped,
and a selection ending exactly at the next line's start doesn't add an extra cursor. The main
selection's resulting cursor remains the main cursor. With no selection, nothing changes and Lumen
shows a status message.

**Transpose characters.** Put the cursor directly after two adjacent characters in the wrong order
(for example, `teh`) and press `Ctrl+T` to swap them. The command is also available as *Edit:
Transpose Characters*. It respects Unicode character boundaries, does nothing when there is no
swappable pair (such as at the start of a line), and is undoable like normal typing.

**Insert blank line below.** *Edit: Insert Blank Line Below* (`Ctrl/Cmd+Enter`) creates a new
indented line below the current line without splitting that line at the cursor. This is useful when
you want to start the next line before finishing the current one. It uses the active language's
normal indentation rules, applies at every cursor, and is undoable like regular typing.

**Insert blank line above.** *Edit: Insert Blank Line Above* (`Ctrl/Cmd+Shift+Enter`) is the
matching operation above the current line. It creates one blank line before each cursor's line,
preserving that line's existing leading indentation without splitting or moving its contents.
Multiple cursors on the same line create one blank line; cursors on different lines create their own
lines. The operation is undoable in one step.

**Delete to line start / end.** *Edit: Delete to Line Start* and *Delete to Line End* use
`Ctrl/Cmd+Shift+Backspace` and `Ctrl/Cmd+Shift+Delete`. With a selection, they delete that
selection. With cursors, they delete from each cursor to the corresponding line boundary. At a line
boundary they remove the preceding or following line break, joining lines. Both operations work at
multiple cursors and are undoable in one step.

**Delete previous / next word.** *Edit: Delete Previous Word* and *Delete Next Word* use
`Ctrl+Backspace` / `Ctrl+Delete` on Windows/Linux and `Alt+Backspace` / `Alt+Delete` on macOS.
They delete a selection directly, or otherwise delete one editor-recognised word group at each
cursor. This makes repeated cleanup of identifiers, parameters, prose, and nearby punctuation fast
and consistent across multiple cursors.

**Case conversion with multiple selections.** *Edit: Upper Case*, *Lower Case*, *Title Case*, and
*Swap Case* apply independently to every non-empty selection. *Swap Case* is available from
*Edit → Swap Case* or as *Edit: Swap Case* in the Command Palette. It processes Unicode characters
one by one: lowercase becomes uppercase, uppercase and titlecase become lowercase, and characters
without case remain unchanged. Each converted selection keeps its range and direction; when there is no selection,
the command converts the entire document. The whole operation is undoable in one step.

**Join lines.** *Edit: Join Lines* removes the line break and surrounding whitespace between lines.
For a selection, it joins all lines the selection covers; multiple independent selections are handled
separately, and overlapping spans are joined only once. With no selection, it joins the cursor's
current line to the next line. It leaves the document untouched and shows a status message when
there is no following line or no line break to join. The resulting line blocks keep a cursor and the
whole action is undoable in one step.

**Sort, reverse, unique, and remove blank lines.** Run *Edit: Sort Lines Ascending*, *Sort Lines
Descending*, *Reverse Lines*, *Unique Lines*, or *Remove Blank Lines* from the Edit menu or Command
Palette. Every non-empty selection expands to the complete physical lines it touches. Disjoint line blocks
are transformed independently, overlapping blocks are handled once, and selection direction and cursor
positions remain mapped through the edit (positions inside a duplicate removed by *Unique Lines* follow
its retained first occurrence). If every selection is empty, the command applies to the whole document.
Sorting compares complete line contents, reversing only changes line order, and *Unique Lines* uses exact
line matching while stably retaining the first occurrence. *Remove Blank Lines* deletes physical lines
whose content has zero length or consists only of spaces and tabs. All five operations preserve the
remaining content's final-newline state; if *Remove Blank Lines* removes every line, the result is an empty
document.

**Ensure a single final newline.** Choose *Edit → Ensure Single Final Newline* or run *Edit: Ensure
Single Final Newline* from the Command Palette. In a non-empty document, the command appends one
logical `LF` when none is present and collapses multiple consecutive final `LF`s to one. A document
that already ends in exactly one `LF` is unchanged, and an empty document stays empty. It changes only
line breaks at the end of the document, without removing spaces or tabs from the final content line.
The logical `LF` is written using the currently selected `LF`, `CRLF`, or `CR` style when the document
is saved. Selections and cursors remain mapped through any edit, and the change is undoable in one step.

**Wrap and unwrap paragraphs.** *Edit: Wrap Paragraph at 80 Columns* (`Alt+Q`) inserts physical hard
newlines into the targeted paragraph, while *Edit: Unwrap Paragraph* removes paragraph-internal hard
newlines and joins the paragraph back into one logical line. These commands are different from `Alt+Z`
word wrap: `Alt+Z` is only a soft on-screen view option and never changes file contents. Paragraph wrap
targets the paragraph containing each cursor, or each non-empty selection independently when selections
exist; multiple cursors and disjoint selections are handled separately. Blank lines end a paragraph, and
so do changes in indentation or in a repeated supported prefix. The supported prefixes are `#`, `//`,
and `///`; the command preserves a repeated prefix on each output line, but richer Markdown hanging
prefixes, list indentation schemes, and block-comment hanging prefixes are not supported. Inside a
wrapped paragraph, runs of internal spaces, tabs, and physical newlines are normalized to single
separators, while the paragraph's leading indentation and repeated prefix are preserved. Width is
measured as 80 logical grapheme columns with tab stops, so combining characters and emoji count by
user-visible graphemes rather than raw code units. Long tokens are never split just to satisfy the
target width, so an individual token may still exceed 80 columns. Each wrap or unwrap action is
undoable in one step.

**Reindent selection.** *Edit: Reindent Selection* (`Ctrl/Cmd+Alt+\`) uses the active language's
local syntax indentation service to recalculate the leading whitespace of selected lines. Unlike
manual indent/outdent, it is useful after pasting a malformed block or changing braces, Python
blocks, lists, or branches. It does not start an LSP, terminal, or external formatter. When the
language has no applicable indentation information, the text is left unchanged and Lumen shows a
status message.

**Line operations:**

| Action | Shortcut |
| --- | --- |
| Toggle line/block comment | `Ctrl/Cmd+/` |
| Move line up / down | `Alt+↑` / `Alt+↓` |
| Copy line up / down | `Shift+Alt+↑` / `Shift+Alt+↓` |
| Duplicate line / selection | `Ctrl/Cmd+Shift+D` |
| Delete line | `Ctrl/Cmd+Shift+K` |
| Transpose adjacent characters | `Ctrl+T` |
| Sort lines ascending | Edit menu or Command Palette → *Edit: Sort Lines Ascending* |
| Sort lines descending | Edit menu or Command Palette → *Edit: Sort Lines Descending* |
| Reverse lines | Edit menu or Command Palette → *Edit: Reverse Lines* |
| Unique lines | Edit menu or Command Palette → *Edit: Unique Lines* |
| Remove blank lines | Edit menu or Command Palette → *Edit: Remove Blank Lines* |
| Ensure single final newline | Edit menu or Command Palette → *Edit: Ensure Single Final Newline* |
| Wrap paragraph at 80 columns | `Alt+Q` |
| Unwrap paragraph | Edit menu or Command Palette → *Edit: Unwrap Paragraph* |
| Select line | `Alt+L` |
| Select enclosing syntax | `Ctrl/Cmd+I` |

Also included: undo/redo (`Ctrl/Cmd+Z` / `Ctrl/Cmd+Y`), auto-close brackets, auto-indent on
input, code folding (fold gutter in the margin), bracket matching, and autocompletion
(`Ctrl/Cmd+Space` to trigger).

**Code folding.** Use the fold gutter, or run *View: Fold Current*, *Unfold Current*, *Fold All*,
and *Unfold All* from the Command Palette or View menu. Current-block folding uses
`Ctrl+Shift+[` / `]` on Windows/Linux and `Cmd+Alt+[` / `]` on macOS. Folding or unfolding every
available block uses `Ctrl+Alt+[` / `]`. When the cursor is not in a foldable block (or nothing is
folded), the document is left unchanged and Lumen shows a status message. Fold state stays with the
tab and editor group during the session.

**Document statistics.** Run *Tools: Document Statistics* from the Command Palette or Tools menu
to see the active buffer's lines, user-visible characters, non-whitespace characters, and words /
tokens. When the main selection is non-empty, the same counts are shown for the selection too. The
tool reads only the in-memory buffer: it does not require a saved file or a workspace and never
modifies text. Counts use Unicode graphemes and word segments, so CJK runs, combining characters,
and emoji are handled without relying on an ASCII whitespace split.

**Language servers and logs.** When a project configures an LSP server, choose *Tools → Show
Language Servers* or run *LSP: Show Language Servers* from the Command Palette. The panel shows
each server's workspace and PID, Starting, Running, Stopping, Stopped, or Error state, advertised
capabilities, and a restart action. It keeps bounded in-memory logs of stderr and server
notifications, not raw protocol messages. Malformed or oversized LSP framing terminates the faulty
server. Opening the panel does not run a command; language servers and formatters remain external
processes and require first-run approval in each app session. Approve only commands from projects
you trust.

<a id="en-search"></a>

## 6. Search & Replace

- **Find** — `Ctrl/Cmd+F` opens the search panel. The panel has regex, case-sensitive and
  whole-word toggles.
- **Find next / previous** — `F3` / `Shift+F3` steps through matches in the current file. Both
  commands are available from the Edit menu and Command Palette; `Enter` also finds the next match
  while the search field is focused.
- **Replace** — `Ctrl/Cmd+H` opens the panel with the replace row; use its *Replace* /
  *Replace All* buttons.
- **Select all matches** — `Alt+F3` turns every match of the current selection into a
  cursor for bulk editing.

> *Find Next* and *Find Previous* search the current file. They are distinct from `F4` /
> `Shift+F4`, which navigate persistent workspace Find Results. `Ctrl/Cmd+G` is bound to
> **Goto Line** in Lumen (not "find next").

<a id="en-syntax"></a>

## 7. Syntax Highlighting

- **Automatic** — the language is detected from the file extension (100+ languages). The
  resolved name shows at the right of the status bar.
- **Manual** — click the language field in the status bar, or run *View: Set Syntax…* from the
  Command Palette, then pick from the fuzzy list. A manual choice **locks** the language so it
  won't be overwritten by auto-detection when you switch tabs or save.
- **Untitled files** start as *Plain Text* (no extension yet); saving as `foo.py` (or setting
  the syntax manually) enables highlighting.

<a id="en-view"></a>

## 8. View: Minimap, Line Numbers, Guides, Rulers, Zoom, Theme

### Markdown preview & Open in browser

- **Markdown preview** — with a Markdown file active, press `Ctrl/Cmd+Shift+V` (or click the
  floating preview icon at the editor's top-right, or run *View: Toggle Markdown Preview*) to
  open a rendered preview beside the editor. It updates live as you type. A file counts as
  Markdown if its name ends in `.md`/`.markdown`/etc. **or** you set the syntax to Markdown from
  the status bar — so an unsaved buffer can be previewed too. The rendered HTML is sanitized
  with DOMPurify, so embedded `<script>` / `onerror=` / `javascript:` payloads can't execute.
- **Open HTML in browser** — with an `.html`/`.htm` file active, a **floating browser icon**
  appears at the top-right of the editor. Click it (or run *View: Open in Browser*) to open the
  current content in your system's default browser. A clean saved file opens at its real path;
  unsaved changes and untitled HTML open from a temporary snapshot, without a Save dialog and
  without modifying the source file. For a dirty saved file, the snapshot keeps relative CSS,
  JavaScript and image paths rooted at the source file's directory.

### Toggles

| Feature | How | Setting key |
| --- | --- | --- |
| Minimap (right-edge overview) | *View: Toggle Minimap* | `showMinimap` |
| Line numbers | *View → Toggle Line Numbers* or Command Palette: *View: Toggle Line Numbers* | `showLineNumbers` |
| Indentation guides | always on unless disabled | `showIndentGuides` |
| Spaces and tab markers | *View → Toggle Whitespace Characters* or Command Palette: *View: Toggle Whitespace Characters* | `showWhitespace` |
| Trailing-whitespace highlight | always on unless disabled | `highlightTrailingWhitespace` |
| Vertical rulers | set columns in settings | `rulers` |
| Word wrap | `Alt+Z` | `wordWrap` |
| Wrap paragraph at 80 columns | `Alt+Q` | none (content-editing command) |
| Dark / light theme | `Ctrl/Cmd+K` | `theme` |
| Font zoom in / out / reset | `Ctrl/Cmd+=` / `-` / `0` | `fontSize` |

*Toggle Whitespace Characters* controls an option that is off by default. Enable it from the View menu, the Command Palette,
or its Settings checkbox to draw visual markers for spaces and tabs without changing document text.
It is independent of trailing-whitespace highlighting, so either display aid can be enabled on its own.

*Toggle Line Numbers* controls the `showLineNumbers` checkbox in Settings. It is on by default and
persisted across restarts. The option changes only the line-number gutter display, never document text,
and applies to every tab and split editor group.

Toggles you flip at runtime (theme, wrap, minimap, line numbers, whitespace markers, font size) are written straight
back to the settings file, so they persist across restarts.

Use **Preferences: Open Settings…** (`Ctrl/Cmd+,`) for a graphical editor of these preferences;
changes apply immediately and are saved to the same settings file.

The **View: Toggle Outline** command adds a filtered outline of functions, classes, and Markdown
headings for the active document to the sidebar. It is local to the open buffer and does not start
a language server.

The Git panel shows the current branch, configured upstream, and locally cached ahead/behind counts.
Its expandable remote details are read only from local Git configuration, so refreshing the panel does
not contact the network. User names, passwords, and tokens embedded in remote URLs are removed before
the values reach the renderer.

<a id="en-settings"></a>

## 9. Settings Reference

Settings are stored as JSON in the OS user-data directory and applied live:

- **Windows:** `%APPDATA%\Lumen Editor\settings.json`
- **macOS:** `~/Library/Application Support/Lumen Editor/settings.json`
- **Linux:** `~/.config/Lumen Editor/settings.json`

```jsonc
{
  "fontSize": 14,                       // editor font size in px (8–40)
  "tabSize": 4,                         // columns per tab
  "insertSpaces": true,                 // insert spaces instead of a tab char
  "theme": "dark",                      // "dark" | "light"
  "wordWrap": false,                    // soft wrap long lines
  "showMinimap": true,                  // right-edge minimap
  "showLineNumbers": true,              // show line numbers in every editor
  "showOutline": false,                 // active-file structure outline in sidebar
  "showIndentGuides": true,             // indentation guide lines
  "showWhitespace": false,               // show visual markers for spaces/tabs
  "highlightTrailingWhitespace": true,  // mark trailing spaces/tabs
  "rulers": [80, 120]                   // vertical rulers at these columns ([] = none)
}
```

Unknown/missing keys fall back to defaults, so a partial file is fine. The app manages
`session.json` for the legacy window and `session-<id>.json` for additional windows in the same
folder.

For files inside an open workspace, Lumen reads nested `.editorconfig` files from the workspace root
to the file. It supports `root = true`, `unset`, common section globs, and `indent_style`,
`indent_size` (`1`–`16` or `tab`), `tab_width` (`1`–`16`), and `end_of_line` (`lf`, `crlf`, or `cr`).
Rules override content-based indentation detection one property at a time; detection then falls back
to these user settings. Merely loading or changing a config never rewrites the buffer or marks it
dirty. Its EOL is used on the next content/manual save, while an explicit status-bar choice wins.
`charset`, `trim_trailing_whitespace`, and `insert_final_newline` are not yet applied.
Resolution stays inside the authorised workspace and is resource-bounded; an excessively deep, large,
or complex configuration safely falls back to content detection and user defaults.
`indent_style = tab` always inserts hard tabs. If its numeric `indent_size` differs from `tab_width`,
the configured `tab_width` is used for each fixed hard-tab indentation level.

When importing Sublime Text settings, `draw_white_space` values `all` and `selection` map to
`showWhitespace: true`; `none` maps to `false`. This mapping changes only `showWhitespace`;
`highlightTrailingWhitespace` keeps its current value. A boolean `line_numbers` value maps to
`showLineNumbers` and does not change any other visual setting.

<a id="en-session"></a>

## 10. Session Restore & Hot Exit

Lumen remembers your workspace **and your unsaved work** across restarts — including after an
unexpected quit or a machine crash (Sublime's "hot exit").

- **Open tabs, active tab, pinned state and workspace folder** are restored on the next launch.
- **Unsaved edits are preserved.** Modified buffers are restored *dirty* (marked with `●`) with
  your exact unsaved text — nothing is silently written to disk.
- **Untitled buffers with content are preserved too**, as untitled drafts.
- The session is written **as you type** (debounced), not just on quit, so a hard crash or power
  loss can't lose more than the last fraction of a second.
- The session file uses a temporary file plus atomic replacement, preventing a partial write from
  replacing the last complete recovery snapshot.
- On restore, clean file-backed buffers are re-read from disk (so external changes show up),
  while dirty buffers keep your draft layered on top. If a file was deleted/moved but you had
  unsaved edits, the draft is kept as an untitled buffer rather than lost.
- Each editor group restores its active document's selections (including multi-cursor) and scroll
  position. Undo history and folded ranges remain session-local rather than being serialised.
- Back/forward navigation history is also session-local and is not restored after restart.

Use `Ctrl/Cmd+Shift+T` to reopen the most recently closed tab. Session data lives next to your
settings as `session.json` for the legacy window or `session-<id>.json` per window (see
[Settings Reference](#en-settings)).

<a id="en-keys"></a>

## 11. Full Keyboard Reference

| Action | Windows / Linux | macOS |
| --- | --- | --- |
| Command Palette | `Ctrl+Shift+P` | `Cmd+Shift+P` |
| Goto Anything | `Ctrl+P` | `Cmd+P` |
| Goto Symbol | `Ctrl+R` | `Cmd+R` |
| Goto Line | `Ctrl+G` | `Cmd+G` |
| Goto Matching Bracket | `Ctrl+Shift+\` | `Cmd+Shift+\` |
| Navigation back / forward | `Alt+←` / `Alt+→` | `Alt+←` / `Alt+→` |
| New / Open file | `Ctrl+N` / `Ctrl+O` | `Cmd+N` / `Cmd+O` |
| Open folder | `Ctrl+Shift+O` | `Cmd+Shift+O` |
| Save / Save As / Save All | `Ctrl+S` / `Ctrl+Shift+S` / `Ctrl+Alt+S` | `Cmd+S` / `Cmd+Shift+S` / `Cmd+Alt+S` |
| Close / Reopen tab | `Ctrl+W` / `Ctrl+Shift+T` | `Cmd+W` / `Cmd+Shift+T` |
| Tab N / Next / Prev | `Ctrl+1..9` / `Ctrl+Alt+←/→` | `Cmd+1..9` / `Cmd+Alt+←/→` |
| Find / Replace | `Ctrl+F` / `Ctrl+H` | `Cmd+F` / `Cmd+H` |
| Find next / previous in current file | `F3` / `Shift+F3` | `F3` / `Shift+F3` |
| Next / previous workspace result | `F4` / `Shift+F4` | `F4` / `Shift+F4` |
| Toggle Markdown preview | `Ctrl+Shift+V` | `Cmd+Shift+V` |
| Add next occurrence | `Ctrl+D` | `Cmd+D` |
| Undo / redo selection | `Ctrl+U` / `Alt+U` | `Cmd+U` / `Cmd+Shift+U` |
| Add cursor above / below | `Ctrl+Alt+↑/↓` | `Cmd+Alt+↑/↓` |
| Select all occurrences | `Alt+F3` | `Alt+F3` |
| Add cursors to line ends | `Shift+Alt+I` | `Shift+Alt+I` |
| Expand / shrink selection | `Shift+Alt+→/←` | `Shift+Alt+→/←` |
| Toggle comment | `Ctrl+/` | `Cmd+/` |
| Move / Copy line | `Alt+↑↓` / `Shift+Alt+↑↓` | `Alt+↑↓` / `Shift+Alt+↑↓` |
| Duplicate / Delete line | `Ctrl+Shift+D` / `Ctrl+Shift+K` | `Cmd+Shift+D` / `Cmd+Shift+K` |
| Wrap paragraph at 80 columns / Unwrap paragraph | `Alt+Q` / Command Palette | `Alt+Q` / Command Palette |
| Zoom in / out / reset | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | `Cmd+=` / `Cmd+-` / `Cmd+0` |
| Toggle sidebar / wrap / theme | `Ctrl+B` / `Alt+Z` / `Ctrl+K` | `Cmd+B` / `Alt+Z` / `Cmd+K` |

<a id="en-trouble"></a>

## 12. Troubleshooting

**Do not run `npm audit fix --force`.** Advisories are in build tooling only; `--force` breaks
the toolchain (ERESOLVE, `cac` export error). Recover with a fresh `git clone`, or:
`rm -rf node_modules package-lock.json && git checkout package.json package-lock.json && npm install`.

**macOS says "Electron.app is damaged / malware" and trashes it.** This is a false positive for
the development runtime. Repair and launch with one command:

```bash
npm run dev:mac
```

`dev:mac` runs the built-in repair and then starts the editor. The repair restores Electron if
macOS moved it to the Trash, removes the quarantine attribute only from this project's
`Electron.app`, ad-hoc signs it, then verifies the resulting bundle. It does not disable Gatekeeper
or change system-wide security settings. If downloading Electron is slow, set
`ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/` before running it. Use `npm run fix:mac`
when you want to repair without launching. This command is for local development; distributable
macOS builds should use Developer ID signing + notarization.

Or approve it under **System Settings → Privacy & Security → Open Anyway**.

**Headless Linux: `libgbm.so.1` missing / core dump.** Electron needs a display + GPU libs.
Install them and use a virtual display, or run on a real desktop:
`sudo apt-get install -y libgbm1 libwayland-server0 xvfb && xvfb-run -a npm run dev`.

**`npm install` says the cache is read-only (`EROFS`).** Point npm at a writable cache:
`npm install --cache /writable/path/.npm-cache`.

---

<a id="中文"></a>

# 中文

Lumen Editor 是一款基于 Electron + TypeScript + CodeMirror 6 的跨平台桌面文本编辑器
（Linux / Windows / macOS），功能对齐 Sublime Text。

## 目录

1. [安装与启动](#zh-install)
2. [界面速览](#zh-interface)
3. [文件与标签](#zh-files)
4. [命令面板与跳转](#zh-palette)
5. [编辑与多光标](#zh-editing)
6. [查找与替换](#zh-search)
7. [语法高亮](#zh-syntax)
8. [视图：Minimap / 参考线 / 标尺 / 缩放 / 主题](#zh-view)
9. [设置项参考](#zh-settings)
10. [会话恢复](#zh-session)
11. [完整快捷键表](#zh-keys)
12. [故障排查](#zh-trouble)

<a id="zh-install"></a>

## 1. 安装与启动

**从源码运行（开发者）：**

```bash
git clone git@github.com:xujieyang4j/text-editor.git
cd text-editor
npm install          # 安装依赖 + Electron 运行时二进制
npm run dev          # 启动（热重载）
```

Electron 二进制下载慢时，先设镜像：

```bash
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
npm install
```

> ⚠️ **切勿运行 `npm audit fix --force`。** 报告的漏洞全部在构建工具链、不会打包进应用；
> `--force` 会把工具链升级到互不兼容的大版本、直接搞崩环境。详见[故障排查](#zh-trouble)。

**无 GUI 校验**（仅类型检查 + 打包，适合服务器/CI）：

```bash
npm run typecheck
npm run build
```

**打包安装程序** → 产物在 `release/<版本号>/`：

```bash
npm run dist:win     # Windows：NSIS 安装程序 + 便携版
npm run dist:mac     # macOS：.dmg + .zip（必须在 macOS 上打）
npm run dist:linux   # Linux：AppImage + .deb
```

<a id="zh-interface"></a>

## 2. 界面速览

```
┌───────────┬─────────────────────────────────┐
│  侧边栏    │  标签栏                          │
│ (文件树)   ├─────────────────────────────────┤
│           │                                  │
│           │   编辑区 (CodeMirror) + Minimap   │
│           │                                  │
│           ├─────────────────────────────────┤
│           │ 状态：行列 · 语言 · 编码 · 换行符   │
└───────────┴─────────────────────────────────┘
```

- **侧边栏** —— 工作区文件树，默认收起，按 `Ctrl/Cmd+B` 显隐。
- **标签栏** —— 每个打开的文档一个标签；`●` 表示未保存，`×` 关闭；固定标签带强调色。
- **编辑区** —— CodeMirror 文本区，右侧可选 Minimap。
- **状态栏** —— 光标位置、选中长度，以及可点击的语言、编码和换行符字段。点击编码或
  换行符字段，可以选择下次保存使用的格式。
- **键盘与辅助技术** —— 面板和结果区域具有明确语义，结果可用键盘操作；关闭面板后恢复焦点，
  并遵循系统的减少动效和强制色设置。

<a id="zh-files"></a>

## 3. 文件与标签

| 操作 | 方式 |
| --- | --- |
| 新建文件 | `Ctrl/Cmd+N` |
| 打开文件 | `Ctrl/Cmd+O` |
| 打开文件夹（工作区） | `Ctrl/Cmd+Shift+O`，载入侧边栏 |
| 保存 | `Ctrl/Cmd+S`（未命名文件会弹保存框） |
| 另存为 | `Ctrl/Cmd+Shift+S` |
| 全部保存 | `Ctrl/Cmd+Alt+S` |
| 固定 / 取消固定标签 | `Ctrl/Cmd+Alt+P`、双击标签或标签右键菜单 |
| 关闭标签 | `Ctrl/Cmd+W`（有未保存改动会确认） |
| 重开关闭的标签 | `Ctrl/Cmd+Shift+T`（后进先出栈） |
| 切到第 N 个标签 | `Ctrl/Cmd+1` … `Ctrl/Cmd+9` |
| 下一个 / 上一个标签 | `Ctrl/Cmd+Alt+→` / `Ctrl/Cmd+Alt+←` |

状态栏编码菜单可选 **UTF-8**、**UTF-8 BOM**、**UTF-16 LE** 和 **UTF-16 BE**，换行符
菜单可选 **LF**、**CRLF** 和 **CR**。选择任一项只会设置下次保存的目标格式，并将文档标记为
未保存，不会立即重写文件；执行**保存**、**全部保存**或已配置的**自动保存**时才会写入磁盘。
如果文件中混用了多种换行符，保存时会将它们统一为所选格式。

打开文件时，编辑器基于 BOM 区分这四种 Unicode 格式：UTF-8 BOM 选择 **UTF-8 BOM**，
UTF-16 BOM 选择 **UTF-16 LE** 或 **UTF-16 BE**，没有 BOM 则按 **UTF-8** 读取。
编辑器不会根据文件内容猜测旧式编码或其他编码。

文件树中点文件夹展开/折叠（按需加载），点文件打开。打开已开的文件只会聚焦它的标签。

常用的入口文件、配置或文档可固定为标签：使用 `Ctrl/Cmd+Alt+P`、双击标签、点击标签上的固定按钮，或在标签右键菜单中选择固定。固定标签始终位于每个编辑组标签栏前侧，重启后仍会保留；“关闭其他标签”“关闭右侧标签”“关闭全部标签”会自动跳过固定标签。单独关闭固定标签仍按正常规则工作。

<a id="zh-palette"></a>

## 4. 命令面板与跳转

**命令面板 —— `Ctrl/Cmd+Shift+P`。** 模糊搜索所有命令并执行。匹配字符高亮；`↑`/`↓` 移动、
`Enter` 执行、`Esc` 关闭。

**Goto Anything —— `Ctrl/Cmd+P`。** 对已打开工作区文件夹的模糊查找，输入框里用前缀切换模式：

| 输入 | 模式 | 示例 |
| --- | --- | --- |
| *(文字)* | 模糊匹配文件路径 | `maints` → `src/renderer/src/main.ts` |
| `:` + `行[:列]` | 跳到当前文件的位置 | `:120:8` |
| `@` + 名称 | 跳到当前文件的符号 | `@openFolder` |
| `#` + 名称 | 跳到工作区符号 | `#parseConfig` |

也可输入 `文件名:行号:列号`（例如 `main.ts:120:8`），直接打开匹配的工作区文件并精确定位。

**跳转到符号 —— `Ctrl/Cmd+R`。** 等同直接进入 `@` 模式。符号用快速逐行扫描抽取：JS/TS 的
函数/类/方法/箭头常量、Python 的 `def`/`class`、Go 的 `func`、Rust 的 `fn`，以及 Markdown 标题。

**跳转到行 —— `Ctrl/Cmd+G`。** 可输入绝对 `行[:列]`、`+10` / `-5` 等相对行，或 `50%` 等
百分比位置；Goto Anything 的 `:` 模式使用相同格式。**跳转到项目符号 —— `Ctrl/Cmd+Shift+R`**
可直接打开工作区符号模式。

**转到匹配括号 —— `Ctrl/Cmd+Shift+\`。** 光标位于或紧邻 `()`、`[]`、`{}` 等成对括号时，会跳到
另一端；没有可匹配括号时光标保持不动。命令面板中也可执行 *Goto: Goto Matching Bracket*。

**后退 / 前进 —— `Alt+←` / `Alt+→`。** 跳转到行、Goto Anything（文件、行、当前文件符号、
项目符号）、大纲、工作区搜索结果、构建问题、定义/引用、书签、匹配括号和改动跳转共用一份导航历史。
只有操作成功且确实移动到另一位置后才会入栈；取消、失败或目标就是当前位置时，两侧历史都不会改变。
仍打开的未命名文档可按文档身份返回，已打开的目标会回到记录位置时所在的分屏组；关闭的文件在路径仍
可用时可按该路径重开。导航历史只存在于本次应用运行中，重启后不会恢复。

> Goto Anything 的文件列表需要先打开文件夹（`Ctrl/Cmd+Shift+O`）。没有工作区时，`Ctrl/Cmd+P`
> 仍可用 `:行号[:列号]`/`@符号` 在当前文件内跳转，或用侧边栏打开文件。

<a id="zh-editing"></a>

## 5. 编辑与多光标

**多光标（Sublime 风格）：**

| 操作 | 快捷键 |
| --- | --- |
| 把选区的下一个匹配加入光标 | `Ctrl/Cmd+D` |
| 撤销上次选区更改 | `Ctrl/Cmd+U` |
| 重做上次选区更改 | Windows/Linux：`Alt+U`；macOS：`Cmd+Shift+U` |
| 跳过当前匹配项 | “选择”菜单 / 命令面板 |
| 移除最后一个光标 | “选择”菜单 / 命令面板 |
| 在上方 / 下方加光标 | `Ctrl/Cmd+Alt+↑` / `Ctrl/Cmd+Alt+↓` |
| 选中选区的所有匹配 | `Alt+F3` |
| 在各行行首添加光标 | “选择”菜单 / 命令面板 |
| 在各行行尾添加光标 | `Shift+Alt+I` |
| 在点击处加光标 | `Alt`+单击 |
| 列（矩形）选择 | `Alt`+拖拽 |
| 收回为单光标 | `Esc` |

*Undo/Redo Selection* 只回退或恢复可用的光标与选区历史，不会继续回退正文编辑。逐个添加匹配时，
*Skip Current Occurrence* 会用下一个尚未选择的匹配替换最后一个匹配选区，*Remove Last Cursor*
则移除最后一处光标或选区。*Add Cursors to Line Starts/Ends* 会在当前选区覆盖的每个物理行
对应边界各放置一个光标。这些命令也都可从“选择”菜单或命令面板执行。

**逐级扩展 / 缩小选区。** `Shift+Alt+→` 会逐级扩大当前选区，`Shift+Alt+←` 会沿本次路径逐级缩小。
对于已识别语言，会优先选择外层语法结构，例如标识符、表达式、参数列表或代码块；纯文本、未完成代码或
语法结构已到顶时，则按**单词 → 当前行 → 全文**回退。移动光标、手动选择文本或修改内容会开启新的扩展
路径。也可以在命令面板执行 *Selection: Expand Selection* / *Selection: Shrink Selection*。

**快速选择行和括号范围。** *Selection: Select Line* 会选择光标或选区触及的完整物理行；Windows/Linux
默认 `Alt+L`，macOS 默认 `Ctrl+L`。*Selection: Select to Matching Bracket* 会把选区活动端扩展到
对应的 `()`、`[]`、`{}` 另一端；没有匹配括号时保持原选区。两项操作均可从选择菜单和命令面板执行。

**选中外层语法结构。** *Selection: Select Enclosing Syntax*（`Ctrl/Cmd+I`）利用当前语言语法树选择
光标或选区所在的下一层外部结构，例如表达式、参数、调用、条件或代码块。它适合在精确代码单元上进行
复制、删除、包裹或重构。纯文本、未解析语法或已经位于最大结构时保持原选区并显示提示；需要继续扩大时
可使用 Expand Selection。

**按行拆分选区。** *Selection: Split Selection into Lines* 会把全部非空选区覆盖的每行转为行首光标。
重叠行会去重；选区恰好结束在下一行开头时不会多生成光标。主选区生成的光标仍是主光标。没有选区时不
改变内容或光标，并显示状态提示。

**转置字符。** 当两个相邻字符的顺序写反，例如 `teh`，把光标放在它们之后并按 `Ctrl+T`，即可交换。
也可从 *Edit: Transpose Characters* 调用。该操作遵循 Unicode 字符边界；行首等没有可交换字符的位置
不会修改文本，并可像普通输入一样撤销。

**在下方新建空行。** *Edit: Insert Blank Line Below*（`Ctrl/Cmd+Enter`）会在当前行下方创建一个
自动缩进的新行，不会从光标处拆开当前行。适合当前行未写完时直接开始编辑下一行。它使用当前语言的常规
缩进规则，对每个光标分别生效，并可像普通输入一样撤销。

**在上方新建空行。** *Edit: Insert Blank Line Above*（`Ctrl/Cmd+Shift+Enter`）是在当前行上方的
对称操作：它会在每个光标所在行前创建一个空行，保留该行已有的前导缩进，不拆分或移动当前行内容。
多个光标位于同一行时只创建一行，位于不同的行时分别创建；整个操作可一次撤销。

**删除至行首 / 行尾。** *Edit: Delete to Line Start*、*Delete to Line End* 对应
`Ctrl/Cmd+Shift+Backspace`、`Ctrl/Cmd+Shift+Delete`。有选区时直接删除选区；单光标时分别删除至
当前行首或行尾；光标已在边界时会删除相邻换行、连接两行。它们支持多光标，并可一次撤销。

**删除前一个 / 后一个单词。** *Edit: Delete Previous Word*、*Delete Next Word* 在 Windows/Linux
使用 `Ctrl+Backspace` / `Ctrl+Delete`，macOS 使用 `Alt+Backspace` / `Alt+Delete`。有选区时直接
删除选区；没有选区时，每个光标会删除一个编辑器识别的词组边界，适合连续清理标识符、参数、普通文字
和相邻标点，并支持多光标。

**多选区大小写转换。** *Edit: Upper Case*、*Lower Case*、*Title Case* 和 *Swap Case* 会分别作用于
每个非空选区。*Swap Case* 可从“编辑 → Swap Case”或命令面板中的 *Edit: Swap Case* 执行；它逐个处理
Unicode 字符，将小写转为大写、大写和标题式字符转为小写，无大小写的字符保持不变。转换后的每个选区保持原有方向和
范围；没有选区时转换整个文档，整个操作可一次撤销。

**合并行。** *Edit: Join Lines* 会移除行间换行和两侧多余空白。存在选区时，它合并选区覆盖的所有行；
多个独立选区分别处理，重叠范围只合并一次。没有选区时，合并光标所在行与下一行。最后一行等没有可合并
换行的位置会保持文本不变并显示状态提示。每个合并后的行块保留一个光标，整个操作可一次撤销。

**排序、反转、删除重复行与删除空白行。** 从“编辑”菜单或命令面板执行 *Edit: Sort Lines Ascending*、
*Sort Lines Descending*、*Reverse Lines*、*Unique Lines* 或 *Remove Blank Lines*。每个非空选区都会扩展到
其触及的完整物理行；不相邻的行块分别处理，重叠行块只处理一次，选区方向和光标位置会随编辑正确映射
（位于被 *Unique Lines* 删除的重复行内的位置会跟随保留下来的首次出现行）。所有选区均为空时处理整个
文档。排序按完整行内容比较，反转只改变行的先后顺序；*Unique Lines* 按整行内容精确匹配，并按原顺序
稳定保留第一次出现。*Remove Blank Lines* 删除内容长度为零或仅由空格和 Tab 组成的物理行。五项操作都会
保留剩余内容原有的末尾换行状态；若 *Remove Blank Lines* 删除所有行，结果为空文档。

**确保单个末尾换行。** 从 *Edit → Ensure Single Final Newline* 或命令面板中的 *Edit: Ensure Single
Final Newline* 执行。非空文档末尾没有逻辑 `LF` 时添加一个，有多个连续末尾 `LF` 时收敛为一个；已有
恰好一个 `LF` 时不变，空文档保持为空。该命令只处理文档末尾的换行符，不会删除末行内容中的空格或
Tab。内部的逻辑 `LF` 会在保存时按当前选择写为 `LF`、`CRLF` 或 `CR`。选区和光标会随编辑映射，整个
改动可一次撤销。

**段落重排与取消段落换行。** *Edit: Wrap Paragraph at 80 Columns*（`Alt+Q`）会在目标段落内插入物理
硬换行，*Edit: Unwrap Paragraph* 会移除段落内部的硬换行并把段落重新并成一条逻辑行。它们不同于
`Alt+Z` 软换行：`Alt+Z` 只影响屏幕显示，不会修改文件内容。存在选区时，每个非空选区会独立作用于其
命中的段落；没有选区时，则按每个光标所在段落处理，多光标和不相邻选区互不影响。空行会结束段落，缩进
变化或重复前缀变化也会结束段落。当前支持的重复前缀只有 `#`、`//` 和 `///`；重排后会在每一输出行保留
该重复前缀，但更丰富的 Markdown 悬挂前缀、列表缩进方案和块注释悬挂前缀暂不支持。重排时，段落内部
连续的空格、Tab 与物理换行会被规范化为单个分隔；段落已有的前导缩进和重复前缀会被保留。宽度按 80 个
逻辑字素列并结合 Tab 停靠位计算，因此组合字符、emoji 等按用户可见字素计数，而不是按原始代码单元。
超长 token 不会被强行拆开来满足宽度目标，所以单个 token 仍可能超过 80 列。每次重排或取消换行都可
一次撤销。

**自动重新缩进选区。** *Edit: Reindent Selection*（`Ctrl/Cmd+Alt+\`）利用当前语言的本地语法缩进
服务重新计算选中行前导空白。它区别于手工增加/减少一级缩进，适合粘贴错位代码或修改括号、Python 块、
列表、分支后恢复结构。它不会启动 LSP、终端或外部格式化器；语言没有可用缩进信息时，文本保持不变并
显示状态提示。

**行操作：**

| 操作 | 快捷键 |
| --- | --- |
| 切换行/块注释 | `Ctrl/Cmd+/` |
| 上移 / 下移行 | `Alt+↑` / `Alt+↓` |
| 向上 / 向下复制行 | `Shift+Alt+↑` / `Shift+Alt+↓` |
| 复制行 / 选区 | `Ctrl/Cmd+Shift+D` |
| 删除行 | `Ctrl/Cmd+Shift+K` |
| 转置相邻字符 | `Ctrl+T` |
| 升序排列行 | “编辑”菜单或命令面板 |
| 降序排列行 | “编辑”菜单或命令面板 |
| 反转行顺序 | “编辑”菜单或命令面板 |
| 删除重复行 | “编辑”菜单或命令面板 |
| 删除空白行 | “编辑”菜单或命令面板 |
| 确保单个末尾换行 | “编辑”菜单或命令面板：*Edit: Ensure Single Final Newline* |
| 按 80 列重排段落 | `Alt+Q` |
| 取消段落换行 | “编辑”菜单或命令面板：*Edit: Unwrap Paragraph* |
| 选中整行 | `Alt+L` |
| 选中所在语法块 | `Ctrl/Cmd+I` |

另含：撤销/重做（`Ctrl/Cmd+Z` / `Ctrl/Cmd+Y`）、自动闭合括号、输入自动缩进、代码折叠
（左侧折叠槽）、括号匹配、自动补全（`Ctrl/Cmd+Space` 触发）。

**代码折叠。** 可使用左侧折叠槽，也可从命令面板或“视图”执行 *Fold Current*、*Unfold Current*、
*Fold All*、*Unfold All*。当前块在 Windows/Linux 使用 `Ctrl+Shift+[` / `]`，在 macOS 使用
`Cmd+Alt+[` / `]`；全部折叠/展开使用 `Ctrl+Alt+[` / `]`。光标处无可折叠块或没有已折叠内容时，
文档保持不变并显示状态提示。折叠状态会在本次会话中随标签和编辑组保留。

**文档统计。** 从命令面板或“工具”执行 *Tools: Document Statistics*，可查看当前缓冲区的行数、
用户可见字符数、非空白字符数与词/标记数；主选区非空时，也会显示选区的同类统计。该工具只读取
内存缓冲区，不需要保存文件或打开工作区，也不会修改文本。统计采用 Unicode 字素和词段，可正确处理
中文连续文本、组合字符和 emoji，而不是依赖 ASCII 空白分词。

**语言服务器与日志。** 项目配置 LSP 后，可选择“工具 → 显示语言服务器”，或在命令面板执行
*LSP: Show Language Servers*。面板会显示各服务器的工作区与 PID、正在启动、运行中、正在停止、已停止
或错误状态、声明的能力及重启操作。它只在内存中保留有界的标准错误和服务器通知日志，不显示原始协议
消息；畸形或超限的 LSP 协议帧会终止异常服务器。打开面板本身不会运行命令；语言服务器和格式化器仍是
外部进程，每个应用会话首次运行相应命令前均须确认，且只应批准可信项目中的命令。

<a id="zh-search"></a>

## 6. 查找与替换

- **查找** —— `Ctrl/Cmd+F` 打开查找面板，面板内有正则、区分大小写、全词匹配开关。
- **查找下一个 / 上一个** —— `F3` / `Shift+F3` 在当前文件的匹配间前后跳转。两项命令均可从
  “编辑”菜单或命令面板执行；查找框聚焦时按 `Enter` 也会查找下一个。
- **替换** —— `Ctrl/Cmd+H` 打开带替换行的面板，用其中的 *Replace* / *Replace All* 按钮。
- **选中所有匹配** —— `Ctrl/Cmd+Shift+L` 把当前选区的每处匹配都变成光标，便于批量编辑。

> *Find Next* 和 *Find Previous* 只查找当前文件，区别于使用 `F4` / `Shift+F4` 导航的工作区
> Find Results。在 Lumen 中 `Ctrl/Cmd+G` 绑定为**跳转到行**（而非“查找下一个”）。

<a id="zh-syntax"></a>

## 7. 语法高亮

- **自动** —— 按文件扩展名识别语言（100+ 种），识别结果显示在状态栏右侧。
- **手动** —— 点状态栏语言字段，或在命令面板执行 *View: Set Syntax…*，从模糊列表里选。手动选择
  会**锁定**语言，之后切换标签或保存都不再被自动识别覆盖。
- **未命名文件**初始为 *Plain Text*（还没扩展名）；另存为 `foo.py`（或手动设语法）即可高亮。

<a id="zh-view"></a>

## 8. 视图：Minimap / 行号 / 参考线 / 标尺 / 缩放 / 主题

### Markdown 预览 & 在浏览器打开

- **Markdown 预览** —— 当前是 Markdown 文件时，按 `Ctrl/Cmd+Shift+V`（或点击编辑器右上角的悬浮
  预览图标，或执行 *View: Toggle Markdown Preview*）在编辑器旁打开渲染预览，随输入实时更新。判定为
  Markdown 的条件是：文件名以 `.md`/`.markdown` 等结尾，**或**你在状态栏把语法设为 Markdown——因此
  未保存的缓冲区也能预览。渲染出的 HTML 经 DOMPurify 消毒，内嵌的 `<script>` / `onerror=` /
  `javascript:` 等负载无法执行。
- **HTML 在浏览器打开** —— 当前是 `.html`/`.htm` 文件时，编辑器右上角会出现**悬浮浏览器图标**。
  点击它（或执行 *View: Open in Browser*）用系统默认浏览器打开当前内容。已保存且没有改动时直接打开
  原文件；有未保存改动或未命名的 HTML 会使用临时快照，不弹保存窗口，也不修改源文件。对于有路径的
  脏文件，快照会保持 CSS、JavaScript、图片等相对路径以原文件目录为基准。

### 开关项

| 功能 | 方式 | 设置项 |
| --- | --- | --- |
| Minimap（右侧缩略图） | *View: Toggle Minimap* | `showMinimap` |
| 行号 | *View → Toggle Line Numbers*，或命令面板：*View: Toggle Line Numbers* | `showLineNumbers` |
| 缩进参考线 | 默认开，可禁用 | `showIndentGuides` |
| 空格和 Tab 标记 | *View → Toggle Whitespace Characters*，或命令面板：*View: Toggle Whitespace Characters* | `showWhitespace` |
| 行尾空白高亮 | 默认开，可禁用 | `highlightTrailingWhitespace` |
| 竖直标尺 | 在设置里指定列 | `rulers` |
| 软换行 | `Alt+Z` | `wordWrap` |
| 按 80 列重排段落 | `Alt+Q` | 无（内容编辑命令） |
| 明 / 暗主题 | `Ctrl/Cmd+K` | `theme` |
| 字号放大 / 缩小 / 复位 | `Ctrl/Cmd+=` / `-` / `0` | `fontSize` |

Git 面板会显示当前分支、已配置的上游以及本地缓存的领先/落后提交数。可展开的远端详情仅从
本地 Git 配置读取，刷新面板不会访问网络；远端 URL 中的用户名、密码或令牌会在进入渲染界面前移除。

*Toggle Whitespace Characters* 控制的选项默认关闭，可从“视图”菜单、命令面板或设置中的复选框启用；
它只为空格和 Tab 绘制视觉标记，不会改动文档文本。此功能与行尾空白高亮互不影响，可以分别开关。

*Toggle Line Numbers* 控制设置中的 `showLineNumbers` 复选框。该选项默认开启并持久保存，只改变
行号边栏显示，不会修改文档文本，并统一作用于所有标签和分栏编辑组。

运行时切换的项（主题、换行、Minimap、行号、空白字符标记、字号）会立即写回设置文件，重启后保留。

<a id="zh-settings"></a>

## 9. 设置项参考

设置以 JSON 存于系统 userData 目录，改动即时生效：

- **Windows：** `%APPDATA%\Lumen Editor\settings.json`
- **macOS：** `~/Library/Application Support/Lumen Editor/settings.json`
- **Linux：** `~/.config/Lumen Editor/settings.json`

```jsonc
{
  "fontSize": 14,                       // 编辑器字号(px，8–40)
  "tabSize": 4,                         // 每个 Tab 的列数
  "insertSpaces": true,                 // 用空格代替制表符
  "theme": "dark",                      // "dark" | "light"
  "wordWrap": false,                    // 长行软换行
  "showMinimap": true,                  // 右侧 Minimap
  "showLineNumbers": true,              // 在所有编辑器中显示行号
  "showIndentGuides": true,             // 缩进参考线
  "showWhitespace": false,               // 显示空格和 Tab 的视觉标记
  "highlightTrailingWhitespace": true,  // 标记行尾空白
  "rulers": [80, 120]                   // 在这些列画竖直标尺([] = 不画)
}
```

缺失/未知键回退到默认值，写一部分也没问题。旧窗口使用同目录的 `session.json`，多窗口使用
`session-<id>.json` 保存打开的标签与文件夹，均由程序自动管理。

对于已打开工作区内的文件，Lumen 会从工作区根目录到文件所在目录逐层读取 `.editorconfig`。当前支持
`root = true`、`unset`、常用 section glob，以及 `indent_style`、`indent_size`（`1`–`16` 或 `tab`）、
`tab_width`（`1`–`16`）和 `end_of_line`（`lf`、`crlf`、`cr`）。各属性按 EditorConfig、正文缩进
检测、用户默认设置的顺序独立决议。加载或修改配置本身不会改写正文或把文档标为未保存；配置的换行
格式在下一次正文/手动保存时采用，状态栏中的手动选择优先。当前不会应用 `charset`、
`trim_trailing_whitespace` 或 `insert_final_newline`。
解析严格限制在已授权工作区内；过深、过大或过于复杂的配置会安全回退到正文检测和用户默认设置。
`indent_style = tab` 始终插入硬 Tab；若数字 `indent_size` 与 `tab_width` 不同，每级硬 Tab 使用
`tab_width` 的列宽。

导入 Sublime Text 设置时，`draw_white_space` 的 `all` / `selection` 均映射为
`showWhitespace: true`，`none` 映射为 `false`。此映射只更改 `showWhitespace`，
`highlightTrailingWhitespace` 保持当前值不变。布尔类型的 `line_numbers` 会映射为
`showLineNumbers`，且不会更改其他视觉设置。

<a id="zh-session"></a>

## 10. 会话恢复与热退出（Hot Exit）

Lumen 会跨重启记住你的工作区**以及未保存的编辑**——即使是意外退出或机器崩溃之后（对齐
Sublime 的 “hot exit”）。

- **打开的标签、活动标签、固定状态、工作区文件夹**会在下次启动时恢复。
- **未保存的编辑会被保留。** 有改动的缓冲区恢复为**脏状态**（标签上带 `●`），内容是你当时未保存
  的原样文本——不会偷偷写回磁盘。
- **有内容的未命名缓冲区同样保留**，恢复为未命名草稿。
- 会话**在你打字时就（防抖）写盘**，不只在退出时写，所以硬崩溃/断电最多只丢失最后零点几秒。
- 会话文件使用临时文件加原子替换，未完成的写入不会覆盖上一份完整恢复快照。
- 恢复时，未改动的文件会重新从磁盘读取（因此外部改动会体现出来），有改动的则把你的草稿叠加在
  磁盘内容之上；若文件被删除/移动但你有未保存编辑，草稿会作为未命名缓冲区保留，而非丢弃。
- 后退/前进导航历史也仅在本次运行中有效，不会随会话在重启后恢复。

`Ctrl/Cmd+Shift+T` 可重开最近关闭的标签。旧窗口会话使用 `session.json`，多窗口分别使用
`session-<id>.json`，都存于设置同目录（见[设置项参考](#zh-settings)）。

<a id="zh-keys"></a>

## 11. 完整快捷键表

| 操作 | Windows / Linux | macOS |
| --- | --- | --- |
| 命令面板 | `Ctrl+Shift+P` | `Cmd+Shift+P` |
| Goto Anything | `Ctrl+P` | `Cmd+P` |
| 跳转到符号 | `Ctrl+R` | `Cmd+R` |
| 跳转到行 | `Ctrl+G` | `Cmd+G` |
| 跳转到匹配括号 | `Ctrl+Shift+\` | `Cmd+Shift+\` |
| 跳转历史后退 / 前进 | `Alt+←` / `Alt+→` | `Alt+←` / `Alt+→` |
| 新建 / 打开文件 | `Ctrl+N` / `Ctrl+O` | `Cmd+N` / `Cmd+O` |
| 打开文件夹 | `Ctrl+Shift+O` | `Cmd+Shift+O` |
| 保存 / 另存为 / 全部保存 | `Ctrl+S` / `Ctrl+Shift+S` / `Ctrl+Alt+S` | `Cmd+S` / `Cmd+Shift+S` / `Cmd+Alt+S` |
| 关闭 / 重开标签 | `Ctrl+W` / `Ctrl+Shift+T` | `Cmd+W` / `Cmd+Shift+T` |
| 第 N / 下 / 上标签 | `Ctrl+1..9` / `Ctrl+Alt+←→` | `Cmd+1..9` / `Cmd+Alt+←→` |
| 查找 / 替换 | `Ctrl+F` / `Ctrl+H` | `Cmd+F` / `Cmd+H` |
| 当前文件查找下一个 / 上一个 | `F3` / `Shift+F3` | `F3` / `Shift+F3` |
| 工作区下一条 / 上一条查找结果 | `F4` / `Shift+F4` | `F4` / `Shift+F4` |
| 切换 Markdown 预览 | `Ctrl+Shift+V` | `Cmd+Shift+V` |
| 加入下一个匹配 | `Ctrl+D` | `Cmd+D` |
| 撤销 / 重做选区 | `Ctrl+U` / `Alt+U` | `Cmd+U` / `Cmd+Shift+U` |
| 上方 / 下方加光标 | `Ctrl+Alt+↑/↓` | `Cmd+Alt+↑/↓` |
| 选中所有匹配 | `Ctrl+Shift+L` | `Cmd+Shift+L` |
| 在各行行尾添加光标 | `Shift+Alt+I` | `Shift+Alt+I` |
| 切换注释 | `Ctrl+/` | `Cmd+/` |
| 移动 / 复制行 | `Alt+↑↓` / `Shift+Alt+↑↓` | `Alt+↑↓` / `Shift+Alt+↑↓` |
| 复制 / 删除行 | `Ctrl+Shift+D` / `Ctrl+Shift+K` | `Cmd+Shift+D` / `Cmd+Shift+K` |
| 按 80 列重排段落 / 取消段落换行 | `Alt+Q` / 命令面板 | `Alt+Q` / 命令面板 |
| 放大 / 缩小 / 复位字号 | `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | `Cmd+=` / `Cmd+-` / `Cmd+0` |
| 显隐侧栏 / 换行 / 主题 | `Ctrl+B` / `Alt+Z` / `Ctrl+K` | `Cmd+B` / `Alt+Z` / `Cmd+K` |

<a id="zh-trouble"></a>

## 12. 故障排查

**切勿运行 `npm audit fix --force`。** 漏洞只在构建工具链；`--force` 会搞崩工具链（ERESOLVE、
`cac` 导出报错）。恢复：重新 `git clone`，或
`rm -rf node_modules package-lock.json && git checkout package.json package-lock.json && npm install`。

**macOS 提示“Electron.app 已损坏/含恶意软件”并移到废纸篓。** 这是未签名开发运行时的误报。恢复：

```bash
npm run dev:mac
```

`dev:mac` 会自动执行内置修复，然后直接启动编辑器。Electron 被移到废纸篓时会自动恢复；只对当前
项目的 `Electron.app` 清除隔离属性、执行临时签名并验证签名，不会关闭 Gatekeeper 或修改系统级
安全设置。Electron 下载慢时，可先设置 `ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/`。
只修复、不启动时可用 `npm run fix:mac`。此命令只用于本地开发；正式分发的 macOS 安装包应使用
Developer ID 签名与 Apple 公证。

或到 **系统设置 → 隐私与安全性 → 仍要打开** 放行。

**无显示器的 Linux：缺 `libgbm.so.1` / core dump。** Electron 需要显示服务与 GPU 库。安装后配
虚拟显示，或直接在有桌面的机器上运行：
`sudo apt-get install -y libgbm1 libwayland-server0 xvfb && xvfb-run -a npm run dev`。

**`npm install` 报缓存只读（`EROFS`）。** 指定可写缓存目录：
`npm install --cache /可写路径/.npm-cache`。
