/**
 * Shared type definitions used across main, preload and renderer.
 * Keeping the IPC contract in one place avoids drift between processes.
 */

/** IPC channel names. Centralised to avoid typos across process boundaries. */
export const IPC = {
  fileNew: 'file:new',
  fileOpen: 'file:open',
  fileOpenPath: 'file:open-path',
  folderOpen: 'folder:open',
  fileSave: 'file:save',
  fileSaveAs: 'file:save-as',
  dirRead: 'dir:read',
  dirListFiles: 'dir:list-files',
  openInBrowser: 'shell:open-in-browser',
  settingsRead: 'settings:read',
  settingsWrite: 'settings:write',
  settingsImportSublime: 'settings:import-sublime',
  sessionRead: 'session:read',
  sessionWrite: 'session:write',
  sessionFlushed: 'session:flushed',
  recentProjectsRead: 'recent-projects:read',
  recentProjectsAdd: 'recent-projects:add',
  recentProjectOpen: 'recent-project:open',
  recentFilesRead: 'recent-files:read',
  recentFileOpen: 'recent-file:open',
  windowSessionRegister: 'window-session:register',
  windowSessionList: 'window-session:list',
  openExternal: 'shell:open-external',
  workspaceSearch: 'workspace:search',
  workspaceReplace: 'workspace:replace',
  workspaceReplacePreview: 'workspace:replace-preview',
  workspaceReplaceUndo: 'workspace:replace-undo',
  workspaceSymbols: 'workspace:symbols',
  workspaceWords: 'workspace:words',
  fileCreate: 'file:create',
  fileRename: 'file:rename',
  fileMove: 'file:move',
  fileDelete: 'file:delete',
  revealInFolder: 'shell:reveal-in-folder',
  fileWatch: 'file:watch',
  buildRun: 'build:run',
  buildCancel: 'build:cancel',
  buildImportSublime: 'build:import-sublime',
  buildOutput: 'build:output',
  projectRead: 'project:read',
  projectWrite: 'project:write',
  projectImportSublime: 'project:import-sublime',
  projectImportSublimeAccept: 'project:import-sublime-accept',
  projectImportSublimeSnippet: 'project:import-sublime-snippet',
  projectImportSublimeKeymap: 'project:import-sublime-keymap',
  pluginList: 'plugin:list',
  pluginInstall: 'plugin:install',
  pluginRemove: 'plugin:remove',
  pluginExtensionRead: 'plugin:extension-read',
  macroList: 'macro:list',
  macroWrite: 'macro:write',
  languageToolRun: 'language-tool:run',
  languageServerRun: 'language-server:run',
  languageServerSync: 'language-server:sync',
  languageServerStop: 'language-server:stop',
  languageServerDiagnostics: 'language-server:diagnostics',
  languageServerRequest: 'language-server:request',
  marketplaceList: 'marketplace:list',
  marketplaceInstall: 'marketplace:install',
  gitStatus: 'git:status',
  gitDiff: 'git:diff',
  gitHunks: 'git:hunks',
  gitHistory: 'git:history',
  gitBlame: 'git:blame',
  gitAction: 'git:action',
  gitConflicts: 'git:conflicts',
  updateCheck: 'update:check',
  openPathRequested: 'app:open-path-requested',
  appNewWindow: 'app:new-window',
  // main -> renderer notifications (menu / accelerator driven)
  menuEvent: 'menu:event'
} as const

/** A file successfully read from disk. */
export interface OpenedFile {
  /** Absolute path on disk. */
  path: string
  /** UTF-8 text content. */
  content: string
  /** Encoding detected on read and used when the file is saved again. */
  encoding: TextEncoding
  /** Original line-ending convention. CodeMirror internally normalises to LF. */
  eol: LineEnding
  /** Size on disk, in bytes. */
  byteLength: number
  /** True when the file is binary and must not be opened as text. */
  isBinary: boolean
  /** True when the file is intentionally not loaded because it exceeds the safe editor limit. */
  isTooLarge: boolean
}

/** Text encodings the built-in reader/writer can preserve without native add-ons. */
export type TextEncoding = 'utf8' | 'utf8bom' | 'utf16le' | 'utf16be'

/** UI and editor color schemes are independent from language syntax selection. */
export type ColorScheme = 'dark' | 'light' | 'solarized-dark' | 'dracula'

/** Physical newline convention used when a document is saved. */
export type LineEnding = 'LF' | 'CRLF' | 'CR'

export interface FileWriteOptions {
  encoding: TextEncoding
  eol: LineEnding
}

/** Result of a save operation. */
export interface SaveResult {
  /** True when the file was written. False when the user cancelled a dialog. */
  saved: boolean
  /** Absolute path the content was written to (present when saved). */
  path?: string
}

/** Request to preview an HTML buffer in the system browser. */
export interface BrowserOpenRequest {
  /** Absolute source path, or null for an untitled buffer. */
  path: string | null
  /** Current editor text, including unsaved changes. */
  content: string
  /** True when content differs from the version on disk. */
  dirty: boolean
}

/** A file match returned by workspace Find in Files. */
export interface WorkspaceMatch {
  path: string
  line: number
  column: number
  lineText: string
  matchText: string
}

export interface WorkspaceSearchRequest {
  /** Primary root, retained for compatibility with one-folder workspaces. */
  root: string
  /** Every selected project root. Searches and replaces are scoped to these roots only. */
  roots?: string[]
  query: string
  caseSensitive: boolean
  wholeWord: boolean
  useRegex: boolean
  include?: string
  exclude?: string
  maxResults?: number
}

export interface WorkspaceReplaceRequest extends WorkspaceSearchRequest {
  replacement: string
}

export interface WorkspaceReplaceResult {
  files: number
  replacements: number
  undoToken?: string
}

export interface WorkspaceReplacePreview {
  files: number
  replacements: number
  matches: WorkspaceMatch[]
}

/** Lightweight project-wide symbol entry, suitable for fast navigation. */
export interface WorkspaceSymbol {
  path: string
  label: string
  line: number
  column: number
}

export interface FileChangeEvent {
  kind: 'changed' | 'renamed' | 'deleted'
  path: string
}

export interface BuildRequest {
  root: string
  command: string
  args?: string[]
  /** Label shown in the output panel. */
  name?: string
  /** Optional working directory relative to the project root. */
  workingDirectory?: string
  /** Optional regex with file/line/column/message capture groups. */
  fileRegex?: string
  /** Build-system commands run directly; free-form command entries may opt into a shell. */
  shell?: boolean
  /** Explicit, bounded environment additions for a configured build. */
  env?: Record<string, string>
}

export interface BuildOutput {
  kind: 'stdout' | 'stderr' | 'exit'
  text: string
  code?: number | null
  systemName?: string
}

export interface BuildSystem {
  name: string
  command: string
  args: string[]
  workingDirectory?: string
  fileRegex?: string
  saveBeforeBuild?: boolean
  shell?: boolean
  env?: Record<string, string>
  variants?: BuildVariant[]
}

export interface BuildVariant {
  name: string
  command?: string
  args?: string[]
  workingDirectory?: string
  fileRegex?: string
  env?: Record<string, string>
  shell?: boolean
}

export interface SublimeBuildImport {
  sourcePath: string
  system: BuildSystem
}

export interface BuildProblem {
  path: string
  line: number
  column: number
  message: string
  severity: 'error' | 'warning' | 'info'
}

export interface GitStatusEntry {
  path: string
  indexStatus: string
  worktreeStatus: string
}

export interface GitStatus {
  available: boolean
  branch?: string
  entries: GitStatusEntry[]
}

export interface GitDiff {
  path: string
  diff: string
}

export interface GitHunk {
  path: string
  header: string
  patch: string
}

export interface GitHistoryEntry {
  id: string
  shortId: string
  author: string
  date: string
  subject: string
}

export type GitAction = 'stage' | 'unstage' | 'discard' | 'stage-hunk' | 'discard-hunk' | 'commit' | 'checkout-branch' | 'create-branch'

export interface GitActionRequest {
  root: string
  action: GitAction
  paths?: string[]
  message?: string
  branch?: string
  patch?: string
}

export interface GitConflict {
  path: string
  ours?: string
  theirs?: string
}

/** A declarative local plugin manifest. Plugins register commands/snippets, not Node access. */
export type PluginPermission = 'document-read' | 'document-edit'

export interface PluginManifest {
  id: string
  name: string
  version: string
  enabled: boolean
  commands: Array<{ id: string; title: string; insertText?: string }>
  snippets: Array<{ label: string; text: string; trigger?: string; scope?: string }>
  extension?: {
    /** Relative worker path after installation; never an executable path. */
    worker: string
    permissions?: PluginPermission[]
    /** HTTPS asset source accepted only for marketplace installs. */
    workerUrl?: string
    /** Required SRI-style SHA-256 digest for a marketplace worker. */
    workerIntegrity?: string
  }
}

export interface PluginInstallRequest {
  root: string
  source: string
}

/** A marketplace item remains declarative—only a plugin manifest is installed. */
export interface MarketplaceItem {
  id: string
  name: string
  version: string
  description?: string
  manifestUrl: string
}

export interface MarketplaceInstallRequest {
  root: string
  manifestUrl: string
}

export interface UpdateInfo {
  currentVersion: string
  latestVersion?: string
  releaseUrl?: string
  available: boolean
}

/** A single entry inside a directory listing. */
export interface DirEntry {
  name: string
  path: string
  isDirectory: boolean
}

/** Payload returned when a folder is opened as a workspace. */
export interface OpenedFolder {
  /** Absolute path of the opened root folder. */
  root: string
  /** Top-level entries of the folder. */
  entries: DirEntry[]
}

export interface RecentProject {
  path: string
  lastOpened: number
}

export interface RecentFile {
  path: string
  lastOpened: number
}

export interface WindowSessionMeta {
  id: string
  updatedAt: number
}

export type MacroStep =
  | { kind: 'command'; command: string }
  | { kind: 'edits'; edits: Array<{ from: number; to: number; insert: string }> }

export interface SavedMacro {
  name: string
  commands: string[]
  /** Ordered command/edit stream used by newly recorded macros. */
  steps?: MacroStep[]
  edits?: Array<{ from: number; to: number; insert: string }>
  /** Legacy snapshot format retained for macros saved by older versions. */
  text?: string
}

/**
 * User-configurable settings, persisted as JSON in the app's userData dir.
 * Mirrors the subset of Sublime's Preferences that we support.
 */
export interface Settings {
  fontSize: number
  tabSize: number
  /** Insert spaces instead of a literal tab character. */
  insertSpaces: boolean
  theme: 'dark' | 'light'
  wordWrap: boolean
  showMinimap: boolean
  showIndentGuides: boolean
  highlightTrailingWhitespace: boolean
  /** Column positions to draw vertical rulers at (empty = none). */
  rulers: number[]
  /** Hard cap for editable text files. Larger files remain protected from accidental UI stalls. */
  maxFileSizeMB: number
  /** Optional project-specific command used by Build. */
  buildCommand: string
  colorScheme: ColorScheme
  /** Uses Chromium's native spell checker for prose-oriented files. */
  spellCheck: boolean
  /** Controlled automatic save for already-named buffers only. */
  autoSave: 'off' | 'after_delay' | 'on_focus_change'
  autoSaveDelayMs: number
  /** Hide surrounding chrome and center the editor, like Sublime's Distraction Free Mode. */
  distractionFree: boolean
  searchHistory: string[]
  replaceHistory: string[]
}

/** Built-in defaults, used when no settings file exists yet. */
export const DEFAULT_SETTINGS: Settings = {
  fontSize: 14,
  tabSize: 4,
  insertSpaces: true,
  theme: 'dark',
  wordWrap: false,
  showMinimap: true,
  showIndentGuides: true,
  highlightTrailingWhitespace: true,
  rulers: [],
  maxFileSizeMB: 20,
  buildCommand: '',
  colorScheme: 'dark',
  spellCheck: false,
  autoSave: 'off',
  autoSaveDelayMs: 1_000,
  distractionFree: false,
  searchHistory: [],
  replaceHistory: []
}

/**
 * A single buffer remembered across restarts. This is what powers "hot exit":
 * we persist the actual draft text of modified buffers (including untitled
 * ones), not just their paths, so an unexpected quit never loses work.
 */
export interface SessionFile {
  /** Absolute path on disk, or null for an untitled buffer. */
  path: string | null
  /** Display name (meaningful for untitled buffers, e.g. "Untitled-2"). */
  name: string
  /** Language display name last shown for this buffer. */
  language: string
  /** True when the user manually locked the language (skip auto-detect). */
  languageLocked: boolean
  /**
   * The unsaved draft text. Present ONLY when the buffer had unsaved changes
   * (or is an untitled buffer with content). Clean file-backed buffers omit
   * this and are simply re-read from disk on restore, keeping session.json
   * small in the common case.
   */
  draft?: string
  encoding?: TextEncoding
  eol?: LineEnding
  /** 1-based bookmark lines restored with the session. */
  bookmarks?: number[]
}

/** Editor state persisted across restarts (open tabs + workspace). */
export interface Session {
  /** Open buffers, in tab order. */
  openFiles: SessionFile[]
  /** Index (into openFiles) of the tab that was active. */
  activeIndex: number
  /** Root of the workspace folder that was open, if any. */
  folder: string | null
  /** All project roots; `folder` remains as the primary-root compatibility field. */
  folders?: string[]
  /** User-created project settings live alongside the workspace session. */
  project?: ProjectSettings
  /** Saved pane arrangement and group-local tab order. */
  layout?: SessionLayout
}

export type LayoutKind = 'single' | 'columns2' | 'columns3' | 'grid4'

export interface SessionLayout {
  kind: LayoutKind
  activeGroup: number
  groups: Array<{ docIndexes: number[]; activeIndex: number }>
}

/** Project settings intentionally kept small and portable in session.json for now. */
export interface ProjectSettings {
  exclude: string[]
  buildCommand: string
  keyBindings: Record<string, string>
  plugins: string[]
  pluginPermissions: Record<string, PluginPermission[]>
  languageTools: Record<string, LanguageToolConfig>
  languageServers: Record<string, LanguageServerConfig>
  buildSystems: BuildSystem[]
  /** Legacy direct map remains supported for simple project key overrides. */
  keyBindingRules: KeyBindingRule[]
  marketplaceUrls: string[]
  /** Project-owned declarative snippets, including imported `.sublime-snippet` files. */
  snippets?: Array<{ label: string; text: string; trigger?: string; scope?: string }>
}

export interface SublimeSnippetImport {
  sourcePath: string
  snippet: { label: string; text: string; trigger?: string; scope?: string }
}

export interface SublimeKeymapImport {
  sourcePath: string
  rules: KeyBindingRule[]
  skipped: number
}

/** Result of a user-confirmed `.sublime-project` import. */
export interface SublimeProjectImport {
  /** Opaque, short-lived main-process token. Roots are not authorised until accepted. */
  token: string
  sourcePath: string
  roots: string[]
  project: ProjectSettings
}

export interface KeyBindingRule {
  keys: string | string[]
  command: string
  /** Restrict the rule to an editor, find-results, Git or build context. */
  when?: 'editor' | 'find-results' | 'git' | 'build'
}

/** Configurable LSP server command, keyed by language name in project settings. */
export interface LanguageServerConfig {
  command: string
  args: string[]
}

/** Configurable stdin/stdout formatter or diagnostics adapter. */
export interface LanguageToolConfig {
  command: string
  args: string[]
}

export interface LanguageToolRequest {
  root: string
  command: string
  content: string
  filePath: string | null
}

export interface LanguageToolResult {
  /** A formatter returns replacement text; diagnostics-only tools omit this. */
  content?: string
  diagnostics: Array<{
    line: number
    column: number
    endLine?: number
    endColumn?: number
    severity: 'error' | 'warning' | 'info'
    message: string
  }>
}

export interface LanguageServerRequest {
  root: string
  config: LanguageServerConfig
  content: string
  filePath: string
  languageId: string
}

/** An incremental document update sent to a persistent LSP process. */
export interface LanguageServerSyncRequest extends LanguageServerRequest {
  version: number
}

export interface LanguageServerDiagnosticEvent {
  filePath: string
  diagnostics: LanguageToolResult['diagnostics']
}

export interface LanguageServerResult {
  edits: Array<{
    startLine: number
    startCharacter: number
    endLine: number
    endCharacter: number
    newText: string
  }>
  diagnostics: LanguageToolResult['diagnostics']
}

export type LanguageServerMethod =
  | 'completion'
  | 'hover'
  | 'definition'
  | 'references'
  | 'rename'

export interface LanguageServerInteractiveRequest extends LanguageServerRequest {
  method: LanguageServerMethod
  line: number
  character: number
  newName?: string
}

export interface LanguageLocation {
  filePath: string
  line: number
  character: number
}

export interface LanguageCompletionItem {
  label: string
  detail?: string
  documentation?: string
  insertText?: string
}

export interface LanguageHover {
  text: string
}

export interface LanguageRenameEdit {
  filePath: string
  startLine: number
  startCharacter: number
  endLine: number
  endCharacter: number
  newText: string
}

export interface LanguageServerInteractiveResult {
  completions?: LanguageCompletionItem[]
  hover?: LanguageHover
  locations?: LanguageLocation[]
  renameEdits?: LanguageRenameEdit[]
}

/** Empty session used on first launch. */
export const EMPTY_SESSION: Session = {
  openFiles: [],
  activeIndex: 0,
  folder: null,
  folders: [],
  project: { exclude: [], buildCommand: '', keyBindings: {}, plugins: [], pluginPermissions: {}, languageTools: {}, languageServers: {}, buildSystems: [], keyBindingRules: [], marketplaceUrls: [] },
  layout: { kind: 'single', activeGroup: 0, groups: [{ docIndexes: [], activeIndex: 0 }] }
}

/**
 * Menu / accelerator events forwarded from the main process to the renderer.
 * The renderer owns editor state, so structural commands are dispatched here.
 */
export type MenuEvent =
  | 'new-file'
  | 'open-file'
  | 'open-folder'
  | 'save'
  | 'save-as'
  | 'save-all'
  | 'close-tab'
  | 'close-other-tabs'
  | 'close-tabs-to-right'
  | 'close-all-tabs'
  | 'reopen-tab'
  | 'next-tab'
  | 'prev-tab'
  | 'find'
  | 'replace'
  | 'toggle-sidebar'
  | 'toggle-word-wrap'
  | 'toggle-theme'
  | 'toggle-minimap'
  | 'toggle-distraction-free'
  | 'cycle-auto-save'
  | 'toggle-spell-check'
  | 'command-palette'
  | 'goto-anything'
  | 'goto-symbol'
  | 'go-to-line'
  | 'select-language'
  | 'toggle-comment'
  | 'toggle-block-comment'
  | 'add-cursor-above'
  | 'add-cursor-below'
  | 'select-next-occurrence'
  | 'select-all-occurrences'
  | 'move-line-up'
  | 'move-line-down'
  | 'copy-line-up'
  | 'copy-line-down'
  | 'delete-line'
  | 'duplicate-selection'
  | 'sort-lines'
  | 'font-zoom-in'
  | 'font-zoom-out'
  | 'font-zoom-reset'
  | 'toggle-preview'
  | 'open-in-browser'
  | 'find-in-files'
  | 'replace-in-files'
  | 'undo-replace-in-files'
  | 'find-results-next'
  | 'find-results-prev'
  | 'next-change'
  | 'prev-change'
  | 'revert-current-change'
  | 'goto-project-symbol'
  | 'navigate-back'
  | 'navigate-forward'
  | 'layout-single'
  | 'layout-columns2'
  | 'layout-columns3'
  | 'layout-grid4'
  | 'move-file-next-group'
  | 'clone-file-next-group'
  | 'focus-next-group'
  | 'focus-prev-group'
  | 'new-window'
  | 'add-folder-to-project'
  | 'open-recent-project'
  | 'open-recent-file'
  | 'import-sublime-project'
  | 'import-sublime-settings'
  | 'import-sublime-snippet'
  | 'import-sublime-keymap'
  | 'import-sublime-build'
  | 'lsp-hover'
  | 'lsp-definition'
  | 'lsp-references'
  | 'lsp-rename'
  | 'select-color-scheme'
  | 'open-marketplace'
  | 'toggle-git'
  | 'refresh-git'
  | 'open-git-conflicts'
  | 'check-for-updates'
  | 'split-editor'
  | 'split-selected-tabs'
  | 'toggle-bookmark'
  | 'next-bookmark'
  | 'prev-bookmark'
  | 'record-macro'
  | 'run-macro'
  | 'save-macro'
  | 'run-saved-macro'
  | 'insert-snippet'
  | 'build'
  | 'select-build-system'
  | 'import-sublime-build'
  | 'trim-trailing-whitespace'
  | 'convert-indent-spaces'
  | 'convert-indent-tabs'
  | 'convert-eol-lf'
  | 'convert-eol-crlf'
  | 'convert-eol-cr'
  | 'to-upper-case'
  | 'to-lower-case'
  | 'to-title-case'
  | 'join-lines'
  | 'split-selection-lines'
  | 'indent-selection'
  | 'outdent-selection'
  | 'format-document'
  | 'toggle-problems'
  | 'project-settings'
  | 'language-tools'
  | 'install-plugin'
  | 'manage-plugins'
  | 'persist-session'
