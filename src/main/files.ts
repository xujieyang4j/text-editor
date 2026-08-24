import { dialog, ipcMain, BrowserWindow, app, shell, type IpcMainInvokeEvent } from 'electron'
import { promises as fs, watch, type FSWatcher } from 'fs'
import { spawn, execFile, type ChildProcessWithoutNullStreams } from 'child_process'
import { promisify } from 'util'
import { createHash } from 'crypto'
import path from 'path'
import { fileURLToPath, pathToFileURL } from 'url'
import { detectLineEnding, encodeText as encodePreservedText } from '../shared/text.js'
import { isBinaryBuffer, maxEditableBytes } from '../shared/filePolicy.js'
import { extractWorkspaceSymbols } from '../shared/symbolIndex.js'
import {
  IPC,
  DEFAULT_SETTINGS,
  EMPTY_SESSION,
  type OpenedFile,
  type SaveResult,
  type OpenedFolder,
  type DirEntry,
  type BrowserOpenRequest,
  type Settings,
  type Session,
  type TextEncoding,
  type FileWriteOptions,
  type WorkspaceMatch,
  type WorkspaceSearchRequest,
  type WorkspaceReplaceRequest,
  type WorkspaceReplaceResult,
  type WorkspaceReplacePreview,
  type WorkspaceSymbol,
  type BuildRequest,
  type BuildOutput,
  type PluginManifest,
  type LanguageToolRequest,
  type LanguageToolResult,
  type LanguageServerRequest,
  type LanguageServerResult,
  type LanguageServerSyncRequest,
  type LanguageServerDiagnosticEvent,
  type LanguageServerInteractiveRequest,
  type LanguageServerInteractiveResult,
  type LanguageLocation,
  type LanguageRenameEdit,
  type LanguageCompletionItem,
  type PluginInstallRequest
  , type PluginPermission
  , type LayoutKind
  , type MarketplaceItem
  , type MarketplaceInstallRequest
  , type GitStatus
  , type GitDiff
  , type GitHunk
  , type GitHistoryEntry
  , type GitActionRequest
  , type GitConflict
  , type RecentProject
  , type WindowSessionMeta
  , type UpdateInfo
  , type SavedMacro
  , type MacroStep
  , type SublimeProjectImport
  , type SublimeSnippetImport
} from '../shared/ipc.js'

const MAX_SEARCH_FILE_BYTES = 2 * 1024 * 1024
const MAX_SEARCH_RESULTS = 5_000

/** Directory entries that are noisy and rarely useful in an editor workspace. */
const IGNORED_ENTRIES = new Set([
  '.git',
  'node_modules',
  '.DS_Store',
  '.cache',
  'dist',
  'out',
  'release',
  '.npm-cache',
  '.lumen-project.json'
])

/** Prevent concurrent writes from racing through one fixed temporary filename. */
const writeQueues = new Map<string, Promise<void>>()
const workspaceWatchers = new Map<number, Map<string, FSWatcher>>()
const builds = new Map<number, ChildProcessWithoutNullStreams>()
interface PersistentLanguageServer {
  child: ChildProcessWithoutNullStreams
  root: string
  configKey: string
  initialized: boolean
  nextId: number
  documents: Map<string, number>
  pending: Map<number, (message: Record<string, unknown>) => void>
  sender: Electron.WebContents
  ready: Promise<void>
  resolveReady: () => void
}
const languageServers = new Map<string, PersistentLanguageServer>()
const execFileAsync = promisify(execFile)
const windowSessionIds = new Map<number, string>()
const replaceUndoTransactions = new Map<string, { expiresAt: number; files: Map<string, Buffer> }>()
const pendingSublimeImports = new Map<string, { senderId: number; expiresAt: number; sourcePath: string; roots: string[]; project: Session['project'] }>()
const grantedFiles = new Map<number, Set<string>>()
const grantedRoots = new Map<number, Set<string>>()

/** Reject renderer IPC from anything except this app's renderer document. */
function assertTrustedSender(event: IpcMainInvokeEvent): void {
  const win = BrowserWindow.fromWebContents(event.sender)
  const frameUrl = event.senderFrame?.url ?? ''
  const devUrl = process.env['ELECTRON_RENDERER_URL']
  const isExpectedWindow = !!win && win.webContents === event.sender
  const isExpectedOrigin = devUrl
    ? frameUrl.startsWith(devUrl)
    : frameUrl.startsWith('file:') && /\/renderer\//.test(new URL(frameUrl).pathname)

  if (!isExpectedWindow || !isExpectedOrigin) {
    throw new Error('Rejected IPC request from an untrusted renderer.')
  }
}

function assertAbsolutePath(value: unknown, label = 'path'): asserts value is string {
  if (typeof value !== 'string' || value.length === 0 || !path.isAbsolute(value)) {
    throw new Error(`Invalid ${label}.`)
  }
}

function grantFile(senderId: number, file: string): void {
  const files = grantedFiles.get(senderId) ?? new Set<string>()
  files.add(path.resolve(file))
  grantedFiles.set(senderId, files)
}

function grantRoot(senderId: number, root: string): void {
  const roots = grantedRoots.get(senderId) ?? new Set<string>()
  roots.add(path.resolve(root))
  grantedRoots.set(senderId, roots)
}

function isInside(root: string, candidate: string): boolean {
  const relative = path.relative(root, candidate)
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))
}

function assertGrantedFile(event: IpcMainInvokeEvent, candidate: string): void {
  const resolved = path.resolve(candidate)
  const senderId = event.sender.id
  const direct = grantedFiles.get(senderId)?.has(resolved)
  const insideGrantedRoot = [...(grantedRoots.get(senderId) ?? [])].some((root) => isInside(root, resolved))
  if (!direct && !insideGrantedRoot) throw new Error('This path has not been authorised for the current editor window.')
}

function assertGrantedRoot(event: IpcMainInvokeEvent, root: string): void {
  const resolved = path.resolve(root)
  if (![...(grantedRoots.get(event.sender.id) ?? [])].some((granted) => granted === resolved)) {
    throw new Error('This workspace has not been authorised for the current editor window.')
  }
}

function cleanupGrants(senderId: number): void {
  grantedFiles.delete(senderId)
  grantedRoots.delete(senderId)
}

function closeWorkspaceWatchers(senderId: number): void {
  for (const watcher of workspaceWatchers.get(senderId)?.values() ?? []) watcher.close()
  workspaceWatchers.delete(senderId)
}

/** Grant a user-selected OS-level path to a renderer (file associations / CLI opens). */
export function authorizePathForRenderer(senderId: number, target: string): void {
  if (!path.isAbsolute(target)) return
  grantFile(senderId, target)
}

/** Assign a durable session key to a window from the main-process window manager. */
export function setWindowSessionId(senderId: number, sessionId: string): void {
  windowSessionIds.set(senderId, sessionId)
}

export function clearWindowSessionId(senderId: number): void {
  windowSessionIds.delete(senderId)
}

/** Main-process startup helper: returns durable window sessions ordered by recency. */
export async function listWindowSessionIds(): Promise<string[]> {
  const sessions = await readJson<WindowSessionMeta[]>(userDataFile('window-sessions.json'), [])
  return Array.isArray(sessions)
    ? sessions
        .filter((entry) => entry && typeof entry.id === 'string' && /^[a-z0-9-]+$/i.test(entry.id))
        .sort((a, b) => b.updatedAt - a.updatedAt)
        .slice(0, 12)
        .map((entry) => entry.id)
    : []
}

/** Add a base URL so relative assets still work in a temporary HTML snapshot. */
function withPreviewBase(html: string, sourcePath: string | null): string {
  if (!sourcePath || /<base(?:\s|>)/i.test(html)) return html

  const dirUrl = pathToFileURL(`${path.dirname(sourcePath)}${path.sep}`).href
  const safeUrl = dirUrl.replaceAll('&', '&amp;').replaceAll('\"', '&quot;')
  const base = `<base href=\"${safeUrl}\">`

  if (/<head(?:\s[^>]*)?>/i.test(html)) {
    return html.replace(/<head(?:\s[^>]*)?>/i, (head) => `${head}\n${base}`)
  }
  if (/<html(?:\s[^>]*)?>/i.test(html)) {
    return html.replace(/<html(?:\s[^>]*)?>/i, (tag) => `${tag}\n<head>${base}</head>`)
  }
  return `<head>${base}</head>\n${html}`
}

/** Read a directory and return its immediate children, folders first. */
async function readDirectory(dirPath: string): Promise<DirEntry[]> {
  const dirents = await fs.readdir(dirPath, { withFileTypes: true })
  const entries: DirEntry[] = dirents
    .filter((d) => !IGNORED_ENTRIES.has(d.name))
    .map((d) => ({
      name: d.name,
      path: path.join(dirPath, d.name),
      isDirectory: d.isDirectory()
    }))

  entries.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1
    return a.name.localeCompare(b.name)
  })

  return entries
}

/** Recursively list all workspace files, bounded for responsiveness. */
async function listFilesRecursive(root: string): Promise<string[]> {
  const results: string[] = []

  async function walk(dir: string, depth: number): Promise<void> {
    if (results.length >= 20_000 || depth > 20) return
    let dirents: import('fs').Dirent[]
    try {
      dirents = await fs.readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const d of dirents) {
      if (IGNORED_ENTRIES.has(d.name)) continue
      const full = path.join(dir, d.name)
      if (d.isDirectory()) await walk(full, depth + 1)
      else if (d.isFile()) {
        results.push(full)
        if (results.length >= 20_000) return
      }
    }
  }

  await walk(root, 0)
  return results
}

function detectEncoding(buffer: Buffer): TextEncoding {
  if (buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf) return 'utf8bom'
  if (buffer[0] === 0xff && buffer[1] === 0xfe) return 'utf16le'
  if (buffer[0] === 0xfe && buffer[1] === 0xff) return 'utf16be'
  return 'utf8'
}

function decodeText(buffer: Buffer, encoding: TextEncoding): string {
  if (encoding === 'utf8bom') return buffer.subarray(3).toString('utf8')
  if (encoding === 'utf16le') return buffer.subarray(2).toString('utf16le')
  if (encoding === 'utf16be') {
    const copy = Buffer.from(buffer.subarray(2))
    copy.swap16()
    return copy.toString('utf16le')
  }
  return buffer.toString('utf8')
}

function encodeText(content: string, options: FileWriteOptions): Buffer {
  return encodePreservedText(content, options.encoding, options.eol)
}

function looksBinary(buffer: Buffer, encoding: TextEncoding): boolean {
  return isBinaryBuffer(buffer, encoding === 'utf16le' || encoding === 'utf16be')
}

/** Read a file safely, preserving its physical encoding and newline convention. */
async function readFile(filePath: string): Promise<OpenedFile> {
  const stat = await fs.stat(filePath)
  if (!stat.isFile()) throw new Error('The selected path is not a file.')
  const byteLength = stat.size
  const maxBytes = maxEditableBytes((await readSettings()).maxFileSizeMB)
  if (byteLength > maxBytes) {
    return { path: filePath, content: '', encoding: 'utf8', eol: 'LF', byteLength, isBinary: false, isTooLarge: true }
  }
  const buffer = await fs.readFile(filePath)
  const encoding = detectEncoding(buffer)
  if (looksBinary(buffer, encoding)) {
    return { path: filePath, content: '', encoding, eol: 'LF', byteLength, isBinary: true, isTooLarge: false }
  }
  const content = decodeText(buffer, encoding)
  return {
    path: filePath,
    content,
    encoding,
    eol: detectLineEnding(content),
    byteLength,
    isBinary: false,
    isTooLarge: false
  }
}

/** Absolute path to a JSON file living in Electron's userData directory. */
function userDataFile(name: string): string {
  return path.join(app.getPath('userData'), name)
}

function windowSessionFile(senderId: number): string {
  const id = windowSessionIds.get(senderId) ?? String(senderId)
  // Preserve session.json as a migration source for the first legacy window.
  return id === 'legacy' ? userDataFile('session.json') : userDataFile(`session-${id}.json`)
}

/** Settings are read at open time so a changed large-file limit applies immediately. */
async function readSettings(): Promise<Settings> {
  return sanitizeSettings(await readJson<unknown>(userDataFile('settings.json'), DEFAULT_SETTINGS))
}

async function readJson<T>(file: string, fallback: T): Promise<T> {
  try {
    return JSON.parse(await fs.readFile(file, 'utf-8')) as T
  } catch {
    return fallback
  }
}

/** Serialise writes per target, use unique temporary paths, and atomically replace the destination. */
async function writeJson(file: string, data: unknown): Promise<void> {
  const previous = writeQueues.get(file) ?? Promise.resolve()
  const next = previous
    .catch(() => undefined)
    .then(async () => {
      await fs.mkdir(path.dirname(file), { recursive: true })
      const tmp = `${file}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`
      await fs.writeFile(tmp, JSON.stringify(data, null, 2), 'utf-8')
      await fs.rename(tmp, file)
    })
  writeQueues.set(file, next)
  try {
    await next
  } finally {
    if (writeQueues.get(file) === next) writeQueues.delete(file)
  }
}

function resolveBuildCwd(root: string, workingDirectory?: string): string {
  if (!workingDirectory) return root
  const candidate = path.resolve(root, workingDirectory)
  if (!isInside(path.resolve(root), candidate)) throw new Error('Build working directory must stay inside the workspace.')
  return candidate
}

function sanitizeBuildEnv(value: unknown): Record<string, string> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  return Object.fromEntries(Object.entries(value)
    .filter(([key, item]) => /^[A-Za-z_][A-Za-z0-9_]{0,99}$/.test(key) && typeof item === 'string' && item.length <= 4_000)
    .slice(0, 50))
}

function convertSublimeProject(value: unknown, sourcePath: string): { roots: string[]; project: Session['project'] } {
  const raw = value && typeof value === 'object' ? value as { folders?: unknown; build_systems?: unknown } : {}
  const base = path.dirname(sourcePath)
  const roots = Array.isArray(raw.folders)
    ? raw.folders.flatMap((folder) => {
        if (!folder || typeof folder !== 'object' || typeof (folder as { path?: unknown }).path !== 'string') return []
        const candidate = path.resolve(base, (folder as { path: string }).path)
        return path.isAbsolute(candidate) ? [candidate] : []
      }).slice(0, 20)
    : []
  const first = roots[0] ?? base
  const project = sanitizeSession({
    openFiles: [], activeIndex: 0, folder: first,
    project: {
      exclude: Array.isArray(raw.folders)
        ? raw.folders.flatMap((folder) => {
            if (!folder || typeof folder !== 'object') return []
            const source = folder as { file_exclude_patterns?: unknown; folder_exclude_patterns?: unknown }
            const files = Array.isArray(source.file_exclude_patterns) ? source.file_exclude_patterns : []
            const dirs = Array.isArray(source.folder_exclude_patterns) ? source.folder_exclude_patterns : []
            return [...files, ...dirs].filter((item): item is string => typeof item === 'string').map((item) => item.includes('*') ? item : `**/${item}/**`)
          })
        : [],
      buildCommand: '', keyBindings: {}, plugins: [], pluginPermissions: {}, languageTools: {}, languageServers: {},
      buildSystems: Array.isArray(raw.build_systems)
        ? raw.build_systems.flatMap((system) => {
            if (!system || typeof system !== 'object') return []
            const source = system as { name?: unknown; cmd?: unknown; shell_cmd?: unknown; working_dir?: unknown; file_regex?: unknown; env?: unknown; variants?: unknown }
            const cmd = Array.isArray(source.cmd) && source.cmd.every((part) => typeof part === 'string') ? source.cmd as string[] : []
            const shell = typeof source.shell_cmd === 'string' ? source.shell_cmd : ''
            const command = cmd[0] ?? shell
            if (!command) return []
            return [{
              name: typeof source.name === 'string' ? source.name : command,
              command, args: cmd.slice(1),
              ...(shell ? { shell: true } : {}),
              ...(typeof source.working_dir === 'string' ? { workingDirectory: source.working_dir } : {}),
              ...(typeof source.file_regex === 'string' ? { fileRegex: source.file_regex } : {}),
              ...(Object.keys(sanitizeBuildEnv(source.env)).length > 0 ? { env: sanitizeBuildEnv(source.env) } : {}),
              variants: Array.isArray(source.variants)
                ? source.variants.flatMap((variant) => {
                    if (!variant || typeof variant !== 'object') return []
                    const item = variant as { name?: unknown; cmd?: unknown; shell_cmd?: unknown; working_dir?: unknown; file_regex?: unknown; env?: unknown }
                    const variantCmd = Array.isArray(item.cmd) && item.cmd.every((part) => typeof part === 'string') ? item.cmd as string[] : []
                    const variantShell = typeof item.shell_cmd === 'string' ? item.shell_cmd : ''
                    const variantCommand = variantCmd[0] ?? variantShell
                    if (!variantCommand || typeof item.name !== 'string') return []
                    return [{ name: item.name, command: variantCommand, args: variantCmd.slice(1), ...(variantShell ? { shell: true } : {}), ...(typeof item.working_dir === 'string' ? { workingDirectory: item.working_dir } : {}), ...(typeof item.file_regex === 'string' ? { fileRegex: item.file_regex } : {}), ...(Object.keys(sanitizeBuildEnv(item.env)).length > 0 ? { env: sanitizeBuildEnv(item.env) } : {}) }]
                  }).slice(0, 20)
                : []
            }]
          })
        : [],
      keyBindingRules: [], marketplaceUrls: []
    }
  }).project
  return { roots: [...new Set(roots)], project }
}

function asFiniteInt(value: unknown, fallback: number, min: number, max: number): number {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.max(min, Math.min(max, Math.round(value)))
    : fallback
}

function sanitizeSettings(value: unknown): Settings {
  const raw = value && typeof value === 'object' ? (value as Partial<Settings>) : {}
  return {
    fontSize: asFiniteInt(raw.fontSize, DEFAULT_SETTINGS.fontSize, 8, 40),
    tabSize: asFiniteInt(raw.tabSize, DEFAULT_SETTINGS.tabSize, 1, 16),
    insertSpaces: typeof raw.insertSpaces === 'boolean' ? raw.insertSpaces : DEFAULT_SETTINGS.insertSpaces,
    theme: raw.theme === 'light' || raw.theme === 'dark' ? raw.theme : DEFAULT_SETTINGS.theme,
    wordWrap: typeof raw.wordWrap === 'boolean' ? raw.wordWrap : DEFAULT_SETTINGS.wordWrap,
    showMinimap: typeof raw.showMinimap === 'boolean' ? raw.showMinimap : DEFAULT_SETTINGS.showMinimap,
    showIndentGuides: typeof raw.showIndentGuides === 'boolean' ? raw.showIndentGuides : DEFAULT_SETTINGS.showIndentGuides,
    highlightTrailingWhitespace:
      typeof raw.highlightTrailingWhitespace === 'boolean'
        ? raw.highlightTrailingWhitespace
        : DEFAULT_SETTINGS.highlightTrailingWhitespace,
    rulers: Array.isArray(raw.rulers)
      ? raw.rulers.filter((n): n is number => typeof n === 'number' && Number.isFinite(n) && n > 0 && n <= 500).map(Math.round).slice(0, 10)
      : DEFAULT_SETTINGS.rulers,
    maxFileSizeMB: asFiniteInt(raw.maxFileSizeMB, DEFAULT_SETTINGS.maxFileSizeMB, 1, 200),
    buildCommand: typeof raw.buildCommand === 'string' ? raw.buildCommand.slice(0, 1_000) : '',
    colorScheme: raw.colorScheme === 'light' || raw.colorScheme === 'solarized-dark' || raw.colorScheme === 'dracula'
      ? raw.colorScheme
      : 'dark',
    spellCheck: typeof raw.spellCheck === 'boolean' ? raw.spellCheck : DEFAULT_SETTINGS.spellCheck,
    autoSave: raw.autoSave === 'after_delay' || raw.autoSave === 'on_focus_change' ? raw.autoSave : 'off',
    autoSaveDelayMs: asFiniteInt(raw.autoSaveDelayMs, DEFAULT_SETTINGS.autoSaveDelayMs, 250, 60_000),
    distractionFree: typeof raw.distractionFree === 'boolean' ? raw.distractionFree : DEFAULT_SETTINGS.distractionFree,
    searchHistory: Array.isArray(raw.searchHistory)
      ? raw.searchHistory.filter((item): item is string => typeof item === 'string').map((item) => item.slice(0, 2_000)).slice(0, 50)
      : [],
    replaceHistory: Array.isArray(raw.replaceHistory)
      ? raw.replaceHistory.filter((item): item is string => typeof item === 'string').map((item) => item.slice(0, 2_000)).slice(0, 50)
      : []
  }
}

function stripJsonComments(source: string): string {
  let output = ''
  let quote = false
  let escaped = false
  let lineComment = false
  let blockComment = false
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index]
    const next = source[index + 1]
    if (lineComment) {
      if (char === '\n') { lineComment = false; output += char }
      continue
    }
    if (blockComment) {
      if (char === '*' && next === '/') { blockComment = false; index += 1 }
      continue
    }
    if (quote) {
      output += char
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === '"') quote = false
      continue
    }
    if (char === '"') { quote = true; output += char }
    else if (char === '/' && next === '/') { lineComment = true; index += 1 }
    else if (char === '/' && next === '*') { blockComment = true; index += 1 }
    else output += char
  }
  return output.replace(/,\s*([}\]])/g, '$1')
}

function convertSublimeSettings(value: unknown): Partial<Settings> {
  if (!value || typeof value !== 'object') return {}
  const raw = value as Record<string, unknown>
  const sourceScheme = typeof raw.color_scheme === 'string' ? raw.color_scheme.toLowerCase() : ''
  return {
    ...(typeof raw.font_size === 'number' ? { fontSize: raw.font_size } : {}),
    ...(typeof raw.tab_size === 'number' ? { tabSize: raw.tab_size } : {}),
    ...(typeof raw.translate_tabs_to_spaces === 'boolean' ? { insertSpaces: raw.translate_tabs_to_spaces } : {}),
    ...(typeof raw.word_wrap === 'boolean' ? { wordWrap: raw.word_wrap } : {}),
    ...(typeof raw.draw_white_space === 'string' ? { highlightTrailingWhitespace: raw.draw_white_space === 'all' || raw.draw_white_space === 'selection' } : {}),
    ...(Array.isArray(raw.rulers) ? { rulers: raw.rulers } : {}),
    ...(typeof raw.spell_check === 'boolean' ? { spellCheck: raw.spell_check } : {}),
    ...(raw.auto_save === 'after_delay' || raw.auto_save === 'on_focus_change' ? { autoSave: raw.auto_save } : {}),
    ...(typeof raw.auto_save_delay === 'number' ? { autoSaveDelayMs: raw.auto_save_delay } : {}),
    ...(sourceScheme.includes('solarized') ? { colorScheme: 'solarized-dark' as const } : sourceScheme.includes('dracula') ? { colorScheme: 'dracula' as const } : sourceScheme.includes('light') ? { colorScheme: 'light' as const } : {})
  }
}

function decodeXml(value: string): string {
  return value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&')
}

function parseSublimeSnippet(source: string, sourcePath: string): SublimeSnippetImport['snippet'] {
  const field = (name: string): string | undefined => {
    const match = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`, 'i').exec(source)
    return match ? decodeXml(match[1].trim()) : undefined
  }
  const text = field('content')
  if (!text || text.length > 10_000) throw new Error('The Sublime snippet must contain content no longer than 10 KB.')
  const trigger = field('tabTrigger')
  const scope = field('scope')
  return {
    label: path.basename(sourcePath, '.sublime-snippet').slice(0, 200),
    text,
    ...(trigger && /^[\w-]{1,80}$/.test(trigger) ? { trigger } : {}),
    ...(scope ? { scope: scope.slice(0, 100) } : {})
  }
}

function sanitizeSession(value: unknown): Session {
  const raw = value && typeof value === 'object' ? (value as Partial<Session>) : {}
  const openFiles = Array.isArray(raw.openFiles)
    ? raw.openFiles
        .filter((item): item is Session['openFiles'][number] => !!item && typeof item === 'object')
        .slice(0, 100)
        .map((file) => ({
          path: typeof file.path === 'string' && path.isAbsolute(file.path) ? file.path : null,
          name: typeof file.name === 'string' ? file.name.slice(0, 255) : 'Untitled',
          language: typeof file.language === 'string' ? file.language.slice(0, 100) : 'Plain Text',
          languageLocked: file.languageLocked === true,
          ...(typeof file.draft === 'string' && file.draft.length <= 20 * 1024 * 1024 ? { draft: file.draft } : {}),
          ...(file.encoding === 'utf8' || file.encoding === 'utf8bom' || file.encoding === 'utf16le' || file.encoding === 'utf16be' ? { encoding: file.encoding } : {}),
          ...(file.eol === 'LF' || file.eol === 'CRLF' || file.eol === 'CR' ? { eol: file.eol } : {}),
          ...(Array.isArray(file.bookmarks)
            ? { bookmarks: file.bookmarks.filter((line): line is number => typeof line === 'number' && Number.isInteger(line) && line > 0 && line <= 10_000_000).slice(0, 10_000) }
            : {})
        }))
    : []
  const project = raw.project && typeof raw.project === 'object' ? raw.project : EMPTY_SESSION.project!
  const rawLayout = raw.layout && typeof raw.layout === 'object' ? raw.layout : undefined
  const layoutKind: LayoutKind =
    rawLayout?.kind === 'columns2' || rawLayout?.kind === 'columns3' || rawLayout?.kind === 'grid4'
      ? rawLayout.kind
      : 'single'
  const layoutCount = layoutKind === 'single' ? 1 : layoutKind === 'columns2' ? 2 : layoutKind === 'columns3' ? 3 : 4
  const rawGroups = Array.isArray(rawLayout?.groups) ? rawLayout.groups : []
  const layout = {
    kind: layoutKind,
    activeGroup: asFiniteInt(rawLayout?.activeGroup, 0, 0, layoutCount - 1),
    groups: Array.from({ length: layoutCount }, (_value, index) => {
      const group = rawGroups[index] && typeof rawGroups[index] === 'object' ? rawGroups[index] : {}
      const rawIndexes = (group as { docIndexes?: unknown }).docIndexes
      const docIndexes = Array.isArray(rawIndexes)
        ? rawIndexes
            .filter((item): item is number => typeof item === 'number' && Number.isInteger(item) && item >= 0 && item < openFiles.length)
            .slice(0, 200)
        : []
      return {
        docIndexes,
        activeIndex: asFiniteInt((group as { activeIndex?: unknown }).activeIndex, 0, 0, Math.max(0, docIndexes.length - 1))
      }
    })
  }
  return {
    openFiles,
    activeIndex: asFiniteInt(raw.activeIndex, 0, 0, Math.max(0, openFiles.length - 1)),
    folder: typeof raw.folder === 'string' && path.isAbsolute(raw.folder) ? raw.folder : null,
    folders: Array.isArray(raw.folders)
      ? raw.folders.filter((folder): folder is string => typeof folder === 'string' && path.isAbsolute(folder)).slice(0, 20)
      : typeof raw.folder === 'string' && path.isAbsolute(raw.folder) ? [raw.folder] : [],
    project: {
      exclude: Array.isArray(project.exclude)
        ? project.exclude.filter((entry): entry is string => typeof entry === 'string').map((entry) => entry.slice(0, 200)).slice(0, 100)
        : [],
      buildCommand: typeof project.buildCommand === 'string' ? project.buildCommand.slice(0, 1_000) : '',
      keyBindings: project.keyBindings && typeof project.keyBindings === 'object'
        ? Object.fromEntries(
            Object.entries(project.keyBindings)
              .filter(([key, value]) => typeof key === 'string' && key.length <= 100 && typeof value === 'string' && value.length <= 100)
              .slice(0, 100)
          )
        : {},
      plugins: Array.isArray(project.plugins)
        ? project.plugins.filter((entry): entry is string => typeof entry === 'string' && /^[a-z0-9-]+$/i.test(entry)).slice(0, 50)
        : [],
      pluginPermissions: project.pluginPermissions && typeof project.pluginPermissions === 'object'
        ? Object.fromEntries(Object.entries(project.pluginPermissions).flatMap(([id, permissions]) => {
            if (!/^[a-z0-9-]+$/i.test(id) || !Array.isArray(permissions)) return []
            return [[id, permissions.filter((permission): permission is 'document-read' | 'document-edit' => permission === 'document-read' || permission === 'document-edit')]]
          }))
        : {},
      languageServers: project.languageServers && typeof project.languageServers === 'object'
        ? Object.fromEntries(
            Object.entries(project.languageServers)
              .filter(([language, config]) =>
                typeof language === 'string' && language.length <= 100 &&
                !!config && typeof config === 'object' &&
                typeof (config as { command?: unknown }).command === 'string'
              )
              .slice(0, 30)
              .map(([language, config]) => {
                const source = config as { command: string; args?: unknown }
                return [language, {
                  command: source.command.slice(0, 1_000),
                  args: Array.isArray(source.args)
                    ? source.args.filter((arg): arg is string => typeof arg === 'string').slice(0, 50)
                    : []
                }]
              })
          )
        : {},
      languageTools: project.languageTools && typeof project.languageTools === 'object'
        ? Object.fromEntries(
            Object.entries(project.languageTools)
              .filter(([language, config]) =>
                typeof language === 'string' && language.length <= 100 &&
                !!config && typeof config === 'object' &&
                typeof (config as { command?: unknown }).command === 'string'
              )
              .slice(0, 30)
              .map(([language, config]) => {
                const source = config as { command: string; args?: unknown }
                return [language, {
                  command: source.command.slice(0, 1_000),
                  args: Array.isArray(source.args)
                    ? source.args.filter((arg): arg is string => typeof arg === 'string').slice(0, 50)
                    : []
                }]
              })
          )
        : {},
      buildSystems: Array.isArray(project.buildSystems)
        ? project.buildSystems
            .flatMap((system) => {
              if (!system || typeof system !== 'object') return []
              const source = system as { name?: unknown; command?: unknown; args?: unknown; workingDirectory?: unknown; fileRegex?: unknown; saveBeforeBuild?: unknown; shell?: unknown; env?: unknown }
              if (typeof source.name !== 'string' || typeof source.command !== 'string') return []
              return [{
                name: source.name.slice(0, 100),
                command: source.command.slice(0, 1_000),
                args: Array.isArray(source.args) ? source.args.filter((arg): arg is string => typeof arg === 'string').slice(0, 50) : [],
                ...(typeof source.workingDirectory === 'string' ? { workingDirectory: source.workingDirectory.slice(0, 500) } : {}),
                ...(typeof source.fileRegex === 'string' ? { fileRegex: source.fileRegex.slice(0, 1_000) } : {}),
                ...(typeof source.saveBeforeBuild === 'boolean' ? { saveBeforeBuild: source.saveBeforeBuild } : {})
                , ...(typeof source.shell === 'boolean' ? { shell: source.shell } : {})
                , ...(Object.keys(sanitizeBuildEnv(source.env)).length > 0 ? { env: sanitizeBuildEnv(source.env) } : {})
                , variants: Array.isArray((source as { variants?: unknown }).variants)
                  ? (source as { variants: unknown[] }).variants.flatMap((variant) => {
                      if (!variant || typeof variant !== 'object') return []
                      const rawVariant = variant as { name?: unknown; command?: unknown; args?: unknown; workingDirectory?: unknown; fileRegex?: unknown; shell?: unknown; env?: unknown }
                      if (typeof rawVariant.name !== 'string') return []
                      return [{
                        name: rawVariant.name.slice(0, 100),
                        ...(typeof rawVariant.command === 'string' ? { command: rawVariant.command.slice(0, 1_000) } : {}),
                        ...(Array.isArray(rawVariant.args) ? { args: rawVariant.args.filter((arg): arg is string => typeof arg === 'string').slice(0, 50) } : {}),
                        ...(typeof rawVariant.workingDirectory === 'string' ? { workingDirectory: rawVariant.workingDirectory.slice(0, 500) } : {}),
                        ...(typeof rawVariant.fileRegex === 'string' ? { fileRegex: rawVariant.fileRegex.slice(0, 1_000) } : {})
                        , ...(typeof rawVariant.shell === 'boolean' ? { shell: rawVariant.shell } : {})
                        , ...(Object.keys(sanitizeBuildEnv(rawVariant.env)).length > 0 ? { env: sanitizeBuildEnv(rawVariant.env) } : {})
                      }]
                    }).slice(0, 20)
                  : []
              }]
            })
            .slice(0, 30)
        : [],
      keyBindingRules: Array.isArray(project.keyBindingRules)
        ? project.keyBindingRules.flatMap((rule) => {
            if (!rule || typeof rule !== 'object') return []
            const source = rule as { keys?: unknown; command?: unknown; when?: unknown }
            const keys = typeof source.keys === 'string' || (Array.isArray(source.keys) && source.keys.every((key) => typeof key === 'string'))
              ? source.keys
              : null
            if (!keys || typeof source.command !== 'string') return []
            const when: 'editor' | 'find-results' | 'git' | 'build' | undefined = source.when === 'editor' || source.when === 'find-results' || source.when === 'git' || source.when === 'build'
              ? source.when
              : undefined
            return [{
              keys,
              command: source.command.slice(0, 100),
              ...(when ? { when } : {})
            }]
          }).slice(0, 200)
        : [],
      marketplaceUrls: Array.isArray(project.marketplaceUrls)
        ? project.marketplaceUrls.filter((url): url is string => typeof url === 'string' && /^https:\/\//.test(url)).map((url) => url.slice(0, 2_000)).slice(0, 20)
        : []
      , snippets: Array.isArray(project.snippets)
        ? project.snippets.flatMap((snippet) => {
            if (!snippet || typeof snippet !== 'object') return []
            const source = snippet as { label?: unknown; text?: unknown; trigger?: unknown; scope?: unknown }
            if (typeof source.label !== 'string' || typeof source.text !== 'string') return []
            return [{ label: source.label.slice(0, 200), text: source.text.slice(0, 10_000), ...(typeof source.trigger === 'string' && /^[\w-]{1,80}$/.test(source.trigger) ? { trigger: source.trigger } : {}), ...(typeof source.scope === 'string' ? { scope: source.scope.slice(0, 100) } : {}) }]
          }).slice(0, 500)
        : []
    },
    layout
  }
}

function makeSearchRegExp(request: WorkspaceSearchRequest): RegExp {
  const query = request.query.slice(0, 2_000)
  if (!query) throw new Error('Find in Files needs a search term.')
  const escaped = request.useRegex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const source = request.wholeWord ? `\\b(?:${escaped})\\b` : escaped
  try {
    return new RegExp(source, request.caseSensitive ? 'g' : 'gi')
  } catch {
    throw new Error('The search expression is invalid.')
  }
}

function matchesGlob(file: string, root: string, pattern?: string): boolean {
  if (!pattern?.trim()) return true
  const relative = path.relative(root, file).replaceAll(path.sep, '/')
  const globs = pattern.split(',').map((part) => part.trim()).filter(Boolean)
  return globs.some((glob) => globToRegExp(glob).test(relative))
}

/** Convert the small, familiar glob subset used in project search filters. */
function globToRegExp(glob: string): RegExp {
  let source = '^'
  for (let i = 0; i < glob.length; i += 1) {
    const ch = glob[i]
    if (ch === '*' && glob[i + 1] === '*') {
      if (glob[i + 2] === '/') {
        source += '(?:.*/)?'
        i += 2
      } else {
        source += '.*'
        i += 1
      }
    } else if (ch === '*') source += '[^/]*'
    else if (ch === '?') source += '.'
    else source += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp(`${source}$`, 'i')
}

/** Resolve the explicitly-authorised roots for a multi-folder search request. */
function workspaceRoots(request: WorkspaceSearchRequest): string[] {
  assertAbsolutePath(request.root, 'workspace root')
  const candidates = Array.isArray(request.roots) ? [request.root, ...request.roots] : [request.root]
  if (candidates.length > 12) throw new Error('Too many workspace roots.')
  const roots = candidates.map((root) => {
    assertAbsolutePath(root, 'workspace root')
    return path.resolve(root)
  })
  return [...new Set(roots)]
}

async function searchWorkspace(request: WorkspaceSearchRequest): Promise<WorkspaceMatch[]> {
  const re = makeSearchRegExp(request)
  const limit = Math.max(1, Math.min(request.maxResults ?? MAX_SEARCH_RESULTS, MAX_SEARCH_RESULTS))
  const results: WorkspaceMatch[] = []

  for (const root of workspaceRoots(request)) {
    if (results.length >= limit) break
    const files = await listFilesRecursive(root)
    for (const file of files) {
      if (
        results.length >= limit ||
        !matchesGlob(file, root, request.include) ||
        (request.exclude?.trim() ? matchesGlob(file, root, request.exclude) : false)
      ) continue
      try {
        const stat = await fs.stat(file)
        if (stat.size > MAX_SEARCH_FILE_BYTES) continue
        const opened = await readFile(file)
        if (opened.isBinary || opened.isTooLarge) continue
        const content = opened.content
        re.lastIndex = 0
        let match: RegExpExecArray | null
        while ((match = re.exec(content)) && results.length < limit) {
          const before = content.slice(0, match.index)
          const line = before.split('\n').length
          const lineStart = before.lastIndexOf('\n') + 1
          const lineEnd = content.indexOf('\n', match.index)
          const sourceLine = content.slice(lineStart, lineEnd < 0 ? content.length : lineEnd)
          results.push({
            path: file,
            line,
            column: match.index - lineStart + 1,
            lineText: sourceLine,
            matchText: match[0]
          })
          if (match[0].length === 0) re.lastIndex += 1
        }
      } catch {
        // Files can disappear or become unreadable while a workspace search runs.
      }
    }
  }
  return results
}

async function replaceWorkspace(request: WorkspaceReplaceRequest): Promise<WorkspaceReplaceResult> {
  const re = makeSearchRegExp(request)
  let changedFiles = 0
  let replacements = 0
  const undoFiles = new Map<string, Buffer>()

  for (const root of workspaceRoots(request)) {
    const files = await listFilesRecursive(root)
    for (const file of files) {
      if (
        !matchesGlob(file, root, request.include) ||
        (request.exclude?.trim() ? matchesGlob(file, root, request.exclude) : false)
      ) continue
      try {
        const stat = await fs.stat(file)
        if (stat.size > MAX_SEARCH_FILE_BYTES) continue
        const opened = await readFile(file)
        if (opened.isBinary || opened.isTooLarge) continue
        let count = 0
        const next = opened.content.replace(re, (...args: unknown[]) => {
          count += 1
          if (request.useRegex) {
            const groups = args.slice(1, -2).map((part) => String(part ?? ''))
            return request.replacement.replace(/\$(\d+|&)/g, (_token, group: string) => group === '&' ? String(args[0]) : (groups[Number(group) - 1] ?? ''))
          }
          return request.replacement
        })
        if (count > 0) {
          undoFiles.set(file, await fs.readFile(file))
          await fs.writeFile(file, encodeText(next, { encoding: opened.encoding, eol: opened.eol }))
          changedFiles += 1
          replacements += count
        }
      } catch {
        // Preserve a best-effort replace: inaccessible files are skipped, not partially rewritten.
      }
    }
  }
  if (undoFiles.size === 0) return { files: changedFiles, replacements }
  const undoToken = `${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`
  replaceUndoTransactions.set(undoToken, { expiresAt: Date.now() + 10 * 60_000, files: undoFiles })
  return { files: changedFiles, replacements, undoToken }
}

async function previewWorkspaceReplace(request: WorkspaceReplaceRequest): Promise<WorkspaceReplacePreview> {
  const matches = await searchWorkspace(request)
  return {
    files: new Set(matches.map((match) => match.path)).size,
    replacements: matches.length,
    matches
  }
}

async function undoWorkspaceReplace(token: string): Promise<WorkspaceReplaceResult> {
  const transaction = replaceUndoTransactions.get(token)
  if (!transaction || transaction.expiresAt < Date.now()) {
    replaceUndoTransactions.delete(token)
    throw new Error('The workspace replace undo snapshot has expired.')
  }
  for (const [file, content] of transaction.files) await fs.writeFile(file, content)
  replaceUndoTransactions.delete(token)
  return { files: transaction.files.size, replacements: 0 }
}

function sanitizeMacroEdits(value: unknown): Array<{ from: number; to: number; insert: string }> {
  if (!Array.isArray(value)) return []
  const edits: Array<{ from: number; to: number; insert: string }> = []
  for (const edit of value) {
    if (!edit || typeof edit !== 'object') continue
    const source = edit as { from?: unknown; to?: unknown; insert?: unknown }
    if (typeof source.from !== 'number' || !Number.isInteger(source.from) || typeof source.to !== 'number' || !Number.isInteger(source.to) || source.from < 0 || source.to < source.from || typeof source.insert !== 'string' || source.insert.length > 2 * 1024 * 1024) continue
    edits.push({ from: source.from, to: source.to, insert: source.insert })
    if (edits.length >= 1_000) break
  }
  return edits
}

function sanitizeMacroSteps(value: unknown): MacroStep[] {
  if (!Array.isArray(value)) return []
  const steps: MacroStep[] = []
  for (const step of value) {
    if (!step || typeof step !== 'object') continue
    const source = step as { kind?: unknown; command?: unknown; edits?: unknown }
    if (source.kind === 'command' && typeof source.command === 'string' && source.command.length <= 100) {
      steps.push({ kind: 'command', command: source.command })
    } else if (source.kind === 'edits') {
      const edits = sanitizeMacroEdits(source.edits)
      if (edits.length > 0) steps.push({ kind: 'edits', edits })
    }
    if (steps.length >= 1_000) break
  }
  return steps
}

/** Index symbols across a bounded workspace scan for Project Symbol navigation. */
async function indexWorkspaceSymbols(root: string): Promise<WorkspaceSymbol[]> {
  const files = await listFilesRecursive(root)
  const symbols: WorkspaceSymbol[] = []
  for (const file of files) {
    if (symbols.length >= 20_000) break
    try {
      const stat = await fs.stat(file)
      if (stat.size > MAX_SEARCH_FILE_BYTES) continue
      const opened = await readFile(file)
      if (opened.isBinary || opened.isTooLarge) continue
      symbols.push(...extractWorkspaceSymbols(file, opened.content).slice(0, 500))
    } catch {
      // Ignore transient workspace files.
    }
  }
  return symbols.slice(0, 20_000)
}

/** Return a bounded, deduplicated project word list for safe completion fallback. */
async function indexWorkspaceWords(root: string): Promise<string[]> {
  const words = new Set<string>()
  for (const file of await listFilesRecursive(root)) {
    if (words.size >= 20_000) break
    try {
      const stat = await fs.stat(file)
      if (stat.size > MAX_SEARCH_FILE_BYTES) continue
      const opened = await readFile(file)
      if (opened.isBinary || opened.isTooLarge) continue
      for (const word of opened.content.match(/[A-Za-z_$][\w$]{1,80}/g) ?? []) {
        words.add(word)
        if (words.size >= 20_000) break
      }
    } catch {
      // A concurrent file deletion must not fail completion.
    }
  }
  return [...words].sort((a, b) => a.localeCompare(b))
}

/** Load declarative local plugins. They can contribute text commands/snippets, never Node access. */
function sanitizePlugin(value: unknown): PluginManifest | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Partial<PluginManifest>
  if (typeof raw.id !== 'string' || !/^[a-z0-9-]+$/i.test(raw.id) || typeof raw.name !== 'string') return null
  const commands = Array.isArray(raw.commands)
    ? raw.commands
        .filter((command): command is PluginManifest['commands'][number] =>
          !!command && typeof command === 'object' && typeof command.id === 'string' && typeof command.title === 'string'
        )
        .map((command) => ({
          id: command.id.slice(0, 100),
          title: command.title.slice(0, 200),
          ...(typeof command.insertText === 'string' ? { insertText: command.insertText.slice(0, 10_000) } : {})
        }))
        .slice(0, 50)
    : []
  const snippets = Array.isArray(raw.snippets)
    ? raw.snippets
        .filter((snippet): snippet is PluginManifest['snippets'][number] =>
          !!snippet && typeof snippet === 'object' && typeof snippet.label === 'string' && typeof snippet.text === 'string'
        )
        .map((snippet) => ({
          label: snippet.label.slice(0, 200),
          text: snippet.text.slice(0, 10_000),
          ...(typeof snippet.trigger === 'string' && /^[\w-]{1,80}$/.test(snippet.trigger) ? { trigger: snippet.trigger } : {}),
          ...(typeof snippet.scope === 'string' ? { scope: snippet.scope.slice(0, 100) } : {})
        }))
        .slice(0, 100)
    : []
  return {
    id: raw.id,
    name: raw.name.slice(0, 200),
    version: typeof raw.version === 'string' ? raw.version.slice(0, 50) : '0.0.0',
    enabled: raw.enabled !== false,
    commands,
    snippets,
    ...(sanitizePluginExtension(raw.extension) ? { extension: sanitizePluginExtension(raw.extension)! } : {})
  }
}

function sanitizePluginExtension(value: unknown): PluginManifest['extension'] | undefined {
  if (!value || typeof value !== 'object') return undefined
  const raw = value as { worker?: unknown; permissions?: unknown; workerUrl?: unknown; workerIntegrity?: unknown }
  if (typeof raw.worker !== 'string' || !/^[a-zA-Z0-9._/-]+$/.test(raw.worker) || raw.worker.includes('..')) return undefined
  const permissions = Array.isArray(raw.permissions)
    ? raw.permissions.filter((permission): permission is PluginPermission => permission === 'document-read' || permission === 'document-edit')
    : []
  const source = typeof raw.workerUrl === 'string' && /^https:///.test(raw.workerUrl)
    ? { workerUrl: raw.workerUrl }
    : {}
  const integrity = typeof raw.workerIntegrity === 'string' && /^sha256-[A-Za-z0-9+/]{43}=$/.test(raw.workerIntegrity)
    ? { workerIntegrity: raw.workerIntegrity }
    : {}
  return { worker: raw.worker, ...(permissions.length > 0 ? { permissions } : {}), ...source, ...integrity }
}

async function listPlugins(root: string): Promise<PluginManifest[]> {
  const pluginsDir = path.join(root, '.lumen-plugins')
  let names: string[]
  try {
    names = await fs.readdir(pluginsDir)
  } catch {
    return []
  }
  const manifests = await Promise.all(
    names.slice(0, 100).map(async (name) => {
      try {
        return sanitizePlugin(JSON.parse(await fs.readFile(path.join(pluginsDir, name, 'plugin.json'), 'utf8')) as unknown)
      } catch {
        return null
      }
    })
  )
  return manifests.filter((plugin): plugin is PluginManifest => plugin !== null)
}

/** Install a local declarative plugin from a folder containing plugin.json. */
async function installPlugin(request: PluginInstallRequest): Promise<PluginManifest> {
  assertAbsolutePath(request.root, 'workspace root')
  assertAbsolutePath(request.source, 'plugin source')
  const manifestPath = path.join(request.source, 'plugin.json')
  const manifest = sanitizePlugin(JSON.parse(await fs.readFile(manifestPath, 'utf8')) as unknown)
  if (!manifest) throw new Error('plugin.json is invalid.')
  const target = path.join(request.root, '.lumen-plugins', manifest.id)
  try { await fs.access(target); throw new Error(`Plugin “${manifest.id}” is already installed.`) } catch (error) {
    if (error instanceof Error && !('code' in error && (error as NodeJS.ErrnoException).code === 'ENOENT')) throw error
  }
  await fs.mkdir(path.dirname(target), { recursive: true })
  await fs.cp(request.source, target, { recursive: true, errorOnExist: true })
  return manifest
}

function sanitizeMarketplaceItem(value: unknown): MarketplaceItem | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Partial<MarketplaceItem>
  if (typeof raw.id !== 'string' || !/^[a-z0-9-]+$/i.test(raw.id) || typeof raw.name !== 'string' || typeof raw.manifestUrl !== 'string') return null
  if (!/^https:\/\//.test(raw.manifestUrl)) return null
  return {
    id: raw.id,
    name: raw.name.slice(0, 200),
    version: typeof raw.version === 'string' ? raw.version.slice(0, 50) : '0.0.0',
    ...(typeof raw.description === 'string' ? { description: raw.description.slice(0, 500) } : {}),
    manifestUrl: raw.manifestUrl
  }
}

async function listMarketplace(urls: string[]): Promise<MarketplaceItem[]> {
  const all: MarketplaceItem[] = []
  for (const url of urls.slice(0, 20)) {
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(10_000) })
      if (!response.ok) continue
      const payload = await response.json() as unknown
      const entries = Array.isArray(payload) ? payload : (payload as { plugins?: unknown })?.plugins
      if (Array.isArray(entries)) all.push(...entries.map(sanitizeMarketplaceItem).filter((item): item is MarketplaceItem => item !== null))
    } catch {
      // Individual marketplace failure should not hide items from other sources.
    }
  }
  return [...new Map(all.map((item) => [item.id, item])).values()]
}

async function installMarketplacePlugin(request: MarketplaceInstallRequest): Promise<PluginManifest> {
  const response = await fetch(request.manifestUrl, { signal: AbortSignal.timeout(10_000) })
  if (!response.ok) throw new Error(`Could not download plugin manifest (${response.status}).`)
  if (response.url !== request.manifestUrl) throw new Error('Marketplace plugin manifest redirects are not allowed.')
  const manifest = sanitizePlugin(await response.json())
  if (!manifest) throw new Error('Downloaded plugin manifest is invalid.')
  const target = path.join(request.root, '.lumen-plugins', manifest.id)
  await fs.mkdir(target, { recursive: false })
  try {
    if (manifest.extension?.workerUrl || manifest.extension?.workerIntegrity) {
      if (!manifest.extension.workerUrl || !manifest.extension.workerIntegrity) {
        throw new Error('Marketplace extension workers require both an HTTPS URL and a SHA-256 integrity digest.')
      }
      const manifestOrigin = new URL(request.manifestUrl).origin
      const workerUrl = new URL(manifest.extension.workerUrl)
      if (workerUrl.protocol !== 'https:' || workerUrl.origin !== manifestOrigin) {
        throw new Error('Marketplace extension worker must use HTTPS and the same origin as its manifest.')
      }
      const workerResponse = await fetch(workerUrl, { signal: AbortSignal.timeout(10_000) })
      if (!workerResponse.ok) throw new Error(`Could not download extension worker (${workerResponse.status}).`)
      if (workerResponse.url !== workerUrl.href) throw new Error('Marketplace extension worker redirects are not allowed.')
      const worker = Buffer.from(await workerResponse.arrayBuffer())
      if (worker.byteLength === 0 || worker.byteLength > 512 * 1024) throw new Error('Marketplace extension worker must be between 1 byte and 512 KB.')
      const actualIntegrity = `sha256-${createHash('sha256').update(worker).digest('base64')}`
      if (actualIntegrity !== manifest.extension.workerIntegrity) throw new Error('Marketplace extension worker failed its SHA-256 integrity check.')
      const workerPath = path.resolve(target, manifest.extension.worker)
      if (!isInside(target, workerPath)) throw new Error('Marketplace extension worker must stay inside the plugin directory.')
      await fs.mkdir(path.dirname(workerPath), { recursive: true })
      await fs.writeFile(workerPath, worker, { flag: 'wx' })
    }
    const installed: PluginManifest = manifest.extension
      ? { ...manifest, extension: { worker: manifest.extension.worker, ...(manifest.extension.permissions?.length ? { permissions: manifest.extension.permissions } : {}) } }
      : manifest
    await fs.writeFile(path.join(target, 'plugin.json'), JSON.stringify(installed, null, 2), { encoding: 'utf8', flag: 'wx' })
  } catch (error) {
    await fs.rm(target, { recursive: true, force: true })
    throw error
  }
  return manifest
}

async function gitStatus(root: string): Promise<GitStatus> {
  try {
    const [{ stdout: branch }, { stdout: porcelain }] = await Promise.all([
      execFileAsync('git', ['-C', root, 'branch', '--show-current']),
      execFileAsync('git', ['-C', root, 'status', '--porcelain=v1', '-z'])
    ])
    const entries = porcelain.split('\0').filter(Boolean).flatMap((entry) => {
      if (entry.length < 4) return []
      return [{ indexStatus: entry[0], worktreeStatus: entry[1], path: entry.slice(3) }]
    })
    return { available: true, branch: branch.trim() || '(detached)', entries }
  } catch {
    return { available: false, entries: [] }
  }
}

async function gitDiff(root: string, relativePath: string): Promise<GitDiff> {
  if (!relativePath || path.isAbsolute(relativePath) || relativePath.includes('..')) throw new Error('Invalid Git diff path.')
  const { stdout } = await execFileAsync('git', ['-C', root, 'diff', '--no-ext-diff', '--', relativePath], { maxBuffer: 2 * 1024 * 1024 })
  return { path: relativePath, diff: stdout }
}

function parseGitHunks(relativePath: string, diff: string): GitHunk[] {
  const lines = diff.split('\n')
  const prefix: string[] = []
  const hunks: GitHunk[] = []
  let current: string[] | null = null
  let header = ''
  for (const line of lines) {
    if (line.startsWith('@@ ')) {
      if (current) hunks.push({ path: relativePath, header, patch: [...prefix, ...current].join('\n') })
      header = line
      current = [line]
    } else if (current) current.push(line)
    else prefix.push(line)
  }
  if (current) hunks.push({ path: relativePath, header, patch: [...prefix, ...current].join('\n') })
  return hunks.filter((hunk) => hunk.patch.includes('@@ ')).slice(0, 200)
}

async function gitHistory(root: string, relativePath: string): Promise<GitHistoryEntry[]> {
  if (!relativePath || path.isAbsolute(relativePath) || relativePath.includes('..')) throw new Error('Invalid Git history path.')
  const { stdout } = await execFileAsync('git', ['-C', root, 'log', '-n', '100', '--format=%H%x00%h%x00%an%x00%aI%x00%s%x00', '--', relativePath], { maxBuffer: 2 * 1024 * 1024 })
  const values = stdout.split('\0')
  const entries: GitHistoryEntry[] = []
  for (let index = 0; index + 4 < values.length; index += 5) {
    const [id, shortId, author, date, subject] = values.slice(index, index + 5)
    if (id && shortId) entries.push({ id, shortId, author, date, subject })
  }
  return entries
}

async function gitBlame(root: string, relativePath: string): Promise<string> {
  if (!relativePath || path.isAbsolute(relativePath) || relativePath.includes('..')) throw new Error('Invalid Git blame path.')
  const { stdout } = await execFileAsync('git', ['-C', root, 'blame', '--date=short', '--', relativePath], { maxBuffer: 2 * 1024 * 1024 })
  return stdout
}

function validatedGitPaths(paths: unknown): string[] {
  if (!Array.isArray(paths)) return []
  return paths
    .filter((item): item is string => typeof item === 'string' && item.length > 0 && !path.isAbsolute(item) && !item.includes('..'))
    .slice(0, 500)
}

async function gitAction(request: GitActionRequest): Promise<GitStatus> {
  const paths = validatedGitPaths(request.paths)
  if (request.action === 'stage') {
    if (paths.length === 0) throw new Error('Choose at least one file to stage.')
    await execFileAsync('git', ['-C', request.root, 'add', '--', ...paths])
  } else if (request.action === 'unstage') {
    if (paths.length === 0) throw new Error('Choose at least one file to unstage.')
    await execFileAsync('git', ['-C', request.root, 'restore', '--staged', '--', ...paths])
  } else if (request.action === 'discard') {
    if (paths.length === 0) throw new Error('Choose at least one file to discard.')
    await execFileAsync('git', ['-C', request.root, 'restore', '--worktree', '--', ...paths])
  } else if (request.action === 'stage-hunk') {
    if (paths.length !== 1 || typeof request.patch !== 'string' || request.patch.length === 0 || request.patch.length > 2 * 1024 * 1024) throw new Error('Choose one valid hunk to stage.')
    const current = await gitDiff(request.root, paths[0])
    if (!parseGitHunks(paths[0], current.diff).some((hunk) => hunk.patch === request.patch)) throw new Error('The selected hunk is stale or does not belong to this file.')
    await new Promise<void>((resolve, reject) => {
      const child = spawn('git', ['-C', request.root, 'apply', '--cached', '-'], { stdio: ['pipe', 'ignore', 'pipe'] })
      let stderr = ''
      child.stderr.on('data', (data: Buffer) => { stderr += data.toString() })
      child.on('error', reject)
      child.on('close', (code) => code === 0 ? resolve() : reject(new Error(stderr.trim() || 'Git could not stage the selected hunk.')))
      child.stdin.end(request.patch)
    })
  } else if (request.action === 'discard-hunk') {
    if (paths.length !== 1 || typeof request.patch !== 'string' || request.patch.length === 0 || request.patch.length > 2 * 1024 * 1024) throw new Error('Choose one valid hunk to discard.')
    const current = await gitDiff(request.root, paths[0])
    if (!parseGitHunks(paths[0], current.diff).some((hunk) => hunk.patch === request.patch)) throw new Error('The selected hunk is stale or does not belong to this file.')
    await new Promise<void>((resolve, reject) => {
      const child = spawn('git', ['-C', request.root, 'apply', '--reverse', '-'], { stdio: ['pipe', 'ignore', 'pipe'] })
      let stderr = ''
      child.stderr.on('data', (data: Buffer) => { stderr += data.toString() })
      child.on('error', reject)
      child.on('close', (code) => code === 0 ? resolve() : reject(new Error(stderr.trim() || 'Git could not discard the selected hunk.')))
      child.stdin.end(request.patch)
    })
  } else if (request.action === 'commit') {
    if (!request.message?.trim()) throw new Error('Commit message is required.')
    await execFileAsync('git', ['-C', request.root, 'commit', '-m', request.message.trim()])
  } else if (request.action === 'checkout-branch') {
    if (!request.branch || !/^[A-Za-z0-9._/-]+$/.test(request.branch) || request.branch.includes('..')) throw new Error('Invalid branch name.')
    await execFileAsync('git', ['-C', request.root, 'switch', request.branch])
  } else {
    if (!request.branch || !/^[A-Za-z0-9._/-]+$/.test(request.branch) || request.branch.includes('..')) throw new Error('Invalid branch name.')
    await execFileAsync('git', ['-C', request.root, 'switch', '-c', request.branch])
  }
  return gitStatus(request.root)
}

async function gitConflicts(root: string): Promise<GitConflict[]> {
  try {
    const { stdout } = await execFileAsync('git', ['-C', root, 'diff', '--name-only', '--diff-filter=U'])
    return stdout.split(/\r?\n/).filter(Boolean).map((path) => ({ path }))
  } catch {
    return []
  }
}

async function checkForUpdate(): Promise<UpdateInfo> {
  const currentVersion = app.getVersion()
  try {
    const response = await fetch('https://api.github.com/repos/xujieyang4j/text-editor/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' },
      signal: AbortSignal.timeout(10_000)
    })
    if (!response.ok) return { currentVersion, available: false }
    const release = await response.json() as { tag_name?: unknown; html_url?: unknown }
    const latestVersion = typeof release.tag_name === 'string' ? release.tag_name.replace(/^v/, '') : undefined
    const releaseUrl = typeof release.html_url === 'string' ? release.html_url : undefined
    return {
      currentVersion,
      latestVersion,
      releaseUrl,
      available: !!latestVersion && latestVersion.localeCompare(currentVersion, undefined, { numeric: true }) > 0
    }
  } catch {
    return { currentVersion, available: false }
  }
}

/** Run a conservative formatter/diagnostic adapter: stdin text, stdout text or JSON diagnostics. */
async function runLanguageTool(request: LanguageToolRequest): Promise<LanguageToolResult> {
  if (!request || typeof request.command !== 'string' || request.command.trim() === '') {
    throw new Error('Configure a language tool command first.')
  }
  assertAbsolutePath(request.root, 'workspace root')
  if (typeof request.content !== 'string' || (request.filePath !== null && typeof request.filePath !== 'string')) {
    throw new Error('Invalid language tool request.')
  }
  return new Promise<LanguageToolResult>((resolve, reject) => {
    const child = spawn(request.command, [], { cwd: request.root, shell: true, env: process.env })
    let stdout = ''
    let stderr = ''
    const timeout = setTimeout(() => child.kill(), 15_000)
    child.stdout.on('data', (data: Buffer) => { stdout += data.toString() })
    child.stderr.on('data', (data: Buffer) => { stderr += data.toString() })
    child.on('error', (error) => { clearTimeout(timeout); reject(error) })
    child.on('close', (code) => {
      clearTimeout(timeout)
      if (code !== 0) { reject(new Error(stderr.trim() || `Language tool exited with code ${code}.`)); return }
      try {
        const parsed = JSON.parse(stdout) as Partial<LanguageToolResult>
        if (Array.isArray(parsed.diagnostics)) {
          resolve({
            ...(typeof parsed.content === 'string' ? { content: parsed.content } : {}),
            diagnostics: parsed.diagnostics
              .filter((item): item is LanguageToolResult['diagnostics'][number] => !!item && typeof item === 'object' && typeof item.line === 'number' && typeof item.column === 'number' && typeof item.message === 'string')
              .map((item) => ({
                line: Math.max(1, Math.floor(item.line)),
                column: Math.max(1, Math.floor(item.column)),
                ...(typeof item.endLine === 'number' ? { endLine: Math.max(1, Math.floor(item.endLine)) } : {}),
                ...(typeof item.endColumn === 'number' ? { endColumn: Math.max(1, Math.floor(item.endColumn)) } : {}),
                severity: item.severity === 'warning' || item.severity === 'info' ? item.severity : 'error',
                message: item.message.slice(0, 2_000)
              }))
          })
          return
        }
      } catch {
        // Plain stdout is a formatter result.
      }
      resolve({ content: stdout, diagnostics: [] })
    })
    child.stdin.end(request.content)
  })
}

/** Read LSP Content-Length framed JSON-RPC messages from a child process. */
function createLspReader(onMessage: (message: Record<string, unknown>) => void): (chunk: Buffer) => void {
  let buffer = Buffer.alloc(0)
  return (chunk: Buffer): void => {
    buffer = Buffer.concat([buffer, chunk])
    while (true) {
      const headerEnd = buffer.indexOf('\r\n\r\n')
      if (headerEnd < 0) return
      const header = buffer.subarray(0, headerEnd).toString('ascii')
      const length = Number(/^Content-Length:\s*(\d+)/im.exec(header)?.[1])
      if (!Number.isFinite(length) || length < 0) { buffer = Buffer.alloc(0); return }
      const messageStart = headerEnd + 4
      if (buffer.length < messageStart + length) return
      const payload = buffer.subarray(messageStart, messageStart + length).toString('utf8')
      buffer = buffer.subarray(messageStart + length)
      try {
        const parsed = JSON.parse(payload) as unknown
        if (parsed && typeof parsed === 'object') onMessage(parsed as Record<string, unknown>)
      } catch {
        // Ignore malformed server packets and keep processing the stream.
      }
    }
  }
}

function lspMessage(child: ChildProcessWithoutNullStreams, payload: Record<string, unknown>): void {
  const content = JSON.stringify(payload)
  child.stdin.write(`Content-Length: ${Buffer.byteLength(content)}\r\n\r\n${content}`)
}

function languageServerKey(senderId: number, root: string, config: { command: string; args: string[] }): string {
  return `${senderId}\u0000${path.resolve(root)}\u0000${config.command}\u0000${config.args.join('\u0000')}`
}

function lspDiagnostics(message: Record<string, unknown>): LanguageServerDiagnosticEvent | null {
  if (message.method !== 'textDocument/publishDiagnostics') return null
  const params = message.params as { uri?: unknown; diagnostics?: unknown } | undefined
  if (typeof params?.uri !== 'string' || !params.uri.startsWith('file:') || !Array.isArray(params.diagnostics)) return null
  let filePath: string
  try { filePath = fileURLToPath(params.uri) } catch { return null }
  return {
    filePath,
    diagnostics: params.diagnostics
      .filter((item): item is { range?: unknown; severity?: unknown; message?: unknown } => !!item && typeof item === 'object')
      .map((item) => {
        const range = item.range as { start?: { line?: number; character?: number }; end?: { line?: number; character?: number } } | undefined
        return {
          line: (range?.start?.line ?? 0) + 1,
          column: (range?.start?.character ?? 0) + 1,
          endLine: (range?.end?.line ?? range?.start?.line ?? 0) + 1,
          endColumn: (range?.end?.character ?? range?.start?.character ?? 0) + 1,
          severity: item.severity === 2 ? 'warning' : item.severity === 3 || item.severity === 4 ? 'info' : 'error' as const,
          message: typeof item.message === 'string' ? item.message.slice(0, 2_000) : 'Language server diagnostic'
        }
      })
  }
}

function startPersistentLanguageServer(
  sender: Electron.WebContents,
  root: string,
  config: LanguageServerSyncRequest['config']
): PersistentLanguageServer {
  const key = languageServerKey(sender.id, root, config)
  const existing = languageServers.get(key)
  if (existing) return existing
  const child = spawn(config.command, config.args, { cwd: root, env: process.env })
  let resolveReady = (): void => undefined
  const ready = new Promise<void>((resolve) => { resolveReady = resolve })
  const server: PersistentLanguageServer = {
    child,
    root,
    configKey: key,
    initialized: false,
    nextId: 1,
    documents: new Map(),
    pending: new Map(),
    sender,
    ready,
    resolveReady
  }
  languageServers.set(key, server)
  child.stdout.on('data', createLspReader((message) => {
    const diagnostic = lspDiagnostics(message)
    if (diagnostic && !sender.isDestroyed()) sender.send(IPC.languageServerDiagnostics, diagnostic)
    if (typeof message.id === 'number') {
      const pending = server.pending.get(message.id)
      if (pending) {
        server.pending.delete(message.id)
        pending(message)
      }
    }
  }))
  const cleanup = (): void => {
    languageServers.delete(key)
    server.resolveReady()
    for (const resolve of server.pending.values()) resolve({ error: { message: 'Language server stopped.' } })
    server.pending.clear()
  }
  child.on('error', cleanup)
  child.on('close', cleanup)
  sender.once('destroyed', () => {
    child.kill()
    cleanup()
  })
  const initializeId = server.nextId++
  const initializeTimer = setTimeout(() => {
    if (!server.initialized) child.kill()
  }, 15_000)
  server.pending.set(initializeId, () => {
    server.initialized = true
    clearTimeout(initializeTimer)
    server.resolveReady()
    lspMessage(child, { jsonrpc: '2.0', method: 'initialized', params: {} })
  })
  lspMessage(child, {
    jsonrpc: '2.0',
    id: initializeId,
    method: 'initialize',
    params: { processId: process.pid, rootUri: pathToFileURL(root).href, capabilities: {} }
  })
  return server
}

async function syncPersistentLanguageServer(
  sender: Electron.WebContents,
  request: LanguageServerSyncRequest
): Promise<void> {
  const server = startPersistentLanguageServer(sender, request.root, request.config)
  const uri = pathToFileURL(request.filePath).href
  const previousVersion = server.documents.get(uri)
  const sendDocument = (): void => {
    if (previousVersion === undefined) {
      lspMessage(server.child, {
        jsonrpc: '2.0',
        method: 'textDocument/didOpen',
        params: { textDocument: { uri, languageId: request.languageId, version: request.version, text: request.content } }
      })
    } else {
      lspMessage(server.child, {
        jsonrpc: '2.0',
        method: 'textDocument/didChange',
        params: { textDocument: { uri, version: request.version }, contentChanges: [{ text: request.content }] }
      })
    }
    server.documents.set(uri, request.version)
  }
  await server.ready
  if (!server.initialized || server.child.killed) throw new Error('Language server failed to initialize.')
  sendDocument()
}

async function formatWithPersistentLanguageServer(
  sender: Electron.WebContents,
  request: LanguageServerRequest
): Promise<LanguageServerResult> {
  const server = startPersistentLanguageServer(sender, request.root, request.config)
  await syncPersistentLanguageServer(sender, { ...request, version: (server.documents.get(pathToFileURL(request.filePath).href) ?? 0) + 1 })
  return new Promise<LanguageServerResult>((resolve, reject) => {
    const id = server.nextId++
    const timer = setTimeout(() => {
      server.pending.delete(id)
      reject(new Error('Language server formatting request timed out.'))
    }, 15_000)
    server.pending.set(id, (message) => {
      clearTimeout(timer)
      if (message.error) { reject(new Error(String((message.error as { message?: unknown }).message ?? 'Language server error.'))); return }
      const edits = Array.isArray(message.result)
        ? message.result
            .filter((item): item is { range?: unknown; newText?: unknown } => !!item && typeof item === 'object' && typeof item.newText === 'string')
            .map((item) => {
              const range = item.range as { start?: { line?: number; character?: number }; end?: { line?: number; character?: number } } | undefined
              return {
                startLine: range?.start?.line ?? 0, startCharacter: range?.start?.character ?? 0,
                endLine: range?.end?.line ?? 0, endCharacter: range?.end?.character ?? 0, newText: item.newText as string
              }
            })
        : []
      resolve({ edits, diagnostics: [] })
    })
    lspMessage(server.child, {
      jsonrpc: '2.0', id, method: 'textDocument/formatting',
      params: { textDocument: { uri: pathToFileURL(request.filePath).href }, options: { tabSize: 4, insertSpaces: true } }
    })
  })
}

async function lspRequest(
  sender: Electron.WebContents,
  request: LanguageServerRequest,
  method: string,
  params: Record<string, unknown>
): Promise<Record<string, unknown>> {
  const server = startPersistentLanguageServer(sender, request.root, request.config)
  await syncPersistentLanguageServer(sender, {
    ...request,
    version: (server.documents.get(pathToFileURL(request.filePath).href) ?? 0) + 1
  })
  return new Promise<Record<string, unknown>>((resolve, reject) => {
    const id = server.nextId++
    const timer = setTimeout(() => {
      server.pending.delete(id)
      reject(new Error(`Language server ${method} request timed out.`))
    }, 15_000)
    server.pending.set(id, (message) => {
      clearTimeout(timer)
      if (message.error) {
        reject(new Error(String((message.error as { message?: unknown }).message ?? `Language server ${method} error.`)))
      } else resolve(message)
    })
    lspMessage(server.child, { jsonrpc: '2.0', id, method, params })
  })
}

function lspLocations(value: unknown): LanguageLocation[] {
  const locations = Array.isArray(value) ? value : value ? [value] : []
  return locations.flatMap((location) => {
    if (!location || typeof location !== 'object') return []
    const source = location as { uri?: unknown; targetUri?: unknown; range?: unknown; targetSelectionRange?: unknown }
    const uri = typeof source.uri === 'string' ? source.uri : typeof source.targetUri === 'string' ? source.targetUri : null
    const range = (source.range ?? source.targetSelectionRange) as { start?: { line?: number; character?: number } } | undefined
    if (!uri?.startsWith('file:')) return []
    try {
      return [{ filePath: fileURLToPath(uri), line: range?.start?.line ?? 0, character: range?.start?.character ?? 0 }]
    } catch {
      return []
    }
  })
}

function lspText(value: unknown): string {
  if (typeof value === 'string') return value
  if (Array.isArray(value)) return value.map(lspText).filter(Boolean).join('\n')
  if (value && typeof value === 'object') {
    const source = value as { value?: unknown; language?: unknown }
    if (typeof source.value === 'string') return source.value
    if (typeof source.language === 'string') return source.language
  }
  return ''
}

async function interactiveLanguageServerRequest(
  sender: Electron.WebContents,
  request: LanguageServerInteractiveRequest
): Promise<LanguageServerInteractiveResult> {
  const uri = pathToFileURL(request.filePath).href
  const position = { line: Math.max(0, request.line), character: Math.max(0, request.character) }
  let method = ''
  let params: Record<string, unknown> = {}
  if (request.method === 'completion') {
    method = 'textDocument/completion'
    params = { textDocument: { uri }, position }
  } else if (request.method === 'hover') {
    method = 'textDocument/hover'
    params = { textDocument: { uri }, position }
  } else if (request.method === 'definition') {
    method = 'textDocument/definition'
    params = { textDocument: { uri }, position }
  } else if (request.method === 'references') {
    method = 'textDocument/references'
    params = { textDocument: { uri }, position, context: { includeDeclaration: true } }
  } else {
    if (!request.newName?.trim()) throw new Error('A new symbol name is required.')
    method = 'textDocument/rename'
    params = { textDocument: { uri }, position, newName: request.newName.trim() }
  }
  const message = await lspRequest(sender, request, method, params)
  const result = message.result
  if (request.method === 'completion') {
    const rawItems = Array.isArray(result) ? result : Array.isArray((result as { items?: unknown })?.items) ? (result as { items: unknown[] }).items : []
    const completions: LanguageCompletionItem[] = rawItems.flatMap((item) => {
      if (!item || typeof item !== 'object' || typeof (item as { label?: unknown }).label !== 'string') return []
      const source = item as { label: string; detail?: unknown; documentation?: unknown; insertText?: unknown }
      return [{
        label: source.label,
        ...(typeof source.detail === 'string' ? { detail: source.detail } : {}),
        ...(lspText(source.documentation) ? { documentation: lspText(source.documentation) } : {}),
        ...(typeof source.insertText === 'string' ? { insertText: source.insertText } : {})
      }]
    }).slice(0, 200)
    return { completions }
  }
  if (request.method === 'hover') return { hover: result ? { text: lspText((result as { contents?: unknown }).contents) } : undefined }
  if (request.method === 'definition' || request.method === 'references') return { locations: lspLocations(result) }
  const changes = (result as { changes?: Record<string, unknown> } | null)?.changes ?? {}
  const renameEdits: LanguageRenameEdit[] = []
  for (const [editUri, edits] of Object.entries(changes)) {
    if (!editUri.startsWith('file:') || !Array.isArray(edits)) continue
    let filePath: string
    try { filePath = fileURLToPath(editUri) } catch { continue }
    for (const edit of edits) {
      const source = edit as { range?: { start?: { line?: number; character?: number }; end?: { line?: number; character?: number } }; newText?: unknown }
      if (typeof source.newText !== 'string') continue
      renameEdits.push({
        filePath,
        startLine: source.range?.start?.line ?? 0,
        startCharacter: source.range?.start?.character ?? 0,
        endLine: source.range?.end?.line ?? 0,
        endCharacter: source.range?.end?.character ?? 0,
        newText: source.newText
      })
    }
  }
  return { renameEdits }
}

/** Register all file-system IPC handlers. Every handler validates its caller and input. */
export function registerFileHandlers(): void {
  ipcMain.handle(IPC.fileOpen, async (event): Promise<OpenedFile | null> => {
    assertTrustedSender(event)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, { properties: ['openFile'], title: 'Open File' })
    if (result.canceled || result.filePaths.length === 0) return null
    grantFile(event.sender.id, result.filePaths[0])
    return readFile(result.filePaths[0])
  })

  ipcMain.handle(IPC.fileOpenPath, async (event, filePath: unknown): Promise<OpenedFile> => {
    assertTrustedSender(event)
    assertAbsolutePath(filePath)
    assertGrantedFile(event, filePath)
    return readFile(filePath)
  })

  ipcMain.handle(IPC.folderOpen, async (event): Promise<OpenedFolder | null> => {
    assertTrustedSender(event)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, { properties: ['openDirectory'], title: 'Open Folder' })
    if (result.canceled || result.filePaths.length === 0) return null
    const root = result.filePaths[0]
    grantRoot(event.sender.id, root)
    return { root, entries: await readDirectory(root) }
  })

  ipcMain.handle(IPC.dirRead, async (event, dirPath: unknown): Promise<DirEntry[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(dirPath, 'directory path')
    assertGrantedFile(event, dirPath)
    return readDirectory(dirPath)
  })

  ipcMain.handle(IPC.dirListFiles, async (event, root: unknown): Promise<string[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    return listFilesRecursive(root)
  })

  ipcMain.handle(IPC.openInBrowser, async (event, request: BrowserOpenRequest): Promise<boolean> => {
    assertTrustedSender(event)
    if (!request || typeof request.content !== 'string' || typeof request.dirty !== 'boolean') {
      throw new Error('Invalid browser preview request.')
    }
    if (request.path !== null) assertAbsolutePath(request.path)
    if (request.path) assertGrantedFile(event, request.path)
    if (request.path && !request.dirty) {
      await shell.openExternal(pathToFileURL(request.path).href)
      return true
    }

    const previewDir = path.join(app.getPath('temp'), 'lumen-editor-preview')
    const previewPath = path.join(previewDir, `preview-${process.pid}.html`)
    await fs.mkdir(previewDir, { recursive: true })
    await fs.writeFile(previewPath, withPreviewBase(request.content, request.path), 'utf-8')
    const previewUrl = pathToFileURL(previewPath)
    previewUrl.searchParams.set('t', Date.now().toString())
    await shell.openExternal(previewUrl.href)
    return true
  })

  ipcMain.handle(IPC.openExternal, async (event, rawUrl: unknown): Promise<void> => {
    assertTrustedSender(event)
    if (typeof rawUrl !== 'string') throw new Error('Invalid external URL.')
    let url: URL
    try { url = new URL(rawUrl) } catch { throw new Error('Invalid external URL.') }
    if (!['https:', 'http:', 'mailto:'].includes(url.protocol)) throw new Error('Blocked unsafe external URL.')
    await shell.openExternal(url.href)
  })

  ipcMain.handle(
    IPC.fileSave,
    async (event, filePath: unknown, content: unknown, options?: FileWriteOptions): Promise<SaveResult> => {
      assertTrustedSender(event)
      if (typeof content !== 'string') throw new Error('Invalid file contents.')
      if (filePath === null) return saveAs(event.sender, content, undefined, options)
      assertAbsolutePath(filePath)
      assertGrantedFile(event, filePath)
      await fs.writeFile(filePath, encodeText(content, validWriteOptions(options)))
      return { saved: true, path: filePath }
    }
  )

  ipcMain.handle(
    IPC.fileSaveAs,
    async (event, content: unknown, suggestedName?: unknown, options?: FileWriteOptions): Promise<SaveResult> => {
      assertTrustedSender(event)
      if (typeof content !== 'string') throw new Error('Invalid file contents.')
      return saveAs(event.sender, content, typeof suggestedName === 'string' ? suggestedName : undefined, options)
    }
  )

  ipcMain.handle(IPC.settingsRead, async (event): Promise<Settings> => {
    assertTrustedSender(event)
    return readSettings()
  })
  ipcMain.handle(IPC.settingsWrite, async (event, settings: unknown): Promise<void> => {
    assertTrustedSender(event)
    await writeJson(userDataFile('settings.json'), sanitizeSettings(settings))
  })
  ipcMain.handle(IPC.settingsImportSublime, async (event): Promise<Settings | null> => {
    assertTrustedSender(event)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, {
      title: 'Import Sublime Settings',
      properties: ['openFile'],
      filters: [{ name: 'Sublime Settings', extensions: ['sublime-settings'] }]
    })
    if (result.canceled || !result.filePaths[0]) return null
    let raw: unknown
    try { raw = JSON.parse(stripJsonComments(await fs.readFile(result.filePaths[0], 'utf8'))) }
    catch { throw new Error('The selected .sublime-settings file is not valid JSON-with-comments.') }
    return sanitizeSettings({ ...await readSettings(), ...convertSublimeSettings(raw) })
  })
  ipcMain.handle(IPC.sessionRead, async (event): Promise<Session> => {
    assertTrustedSender(event)
    const session = sanitizeSession(await readJson<unknown>(windowSessionFile(event.sender.id), EMPTY_SESSION))
    for (const folder of session.folders ?? []) grantRoot(event.sender.id, folder)
    if (session.folder) grantRoot(event.sender.id, session.folder)
    for (const file of session.openFiles) if (file.path) grantFile(event.sender.id, file.path)
    return session
  })
  ipcMain.handle(IPC.sessionWrite, async (event, session: unknown): Promise<void> => {
    assertTrustedSender(event)
    await writeJson(windowSessionFile(event.sender.id), sanitizeSession(session))
  })

  ipcMain.handle(IPC.recentProjectsRead, async (event): Promise<RecentProject[]> => {
    assertTrustedSender(event)
    const raw = await readJson<unknown>(userDataFile('recent-projects.json'), [])
    return Array.isArray(raw)
      ? raw
          .flatMap((entry) => entry && typeof entry === 'object' && typeof (entry as { path?: unknown }).path === 'string' && path.isAbsolute((entry as { path: string }).path)
            ? [{ path: (entry as { path: string }).path, lastOpened: typeof (entry as { lastOpened?: unknown }).lastOpened === 'number' ? (entry as { lastOpened: number }).lastOpened : 0 }]
            : [])
          .sort((a, b) => b.lastOpened - a.lastOpened)
          .slice(0, 30)
      : []
  })

  ipcMain.handle(IPC.recentProjectsAdd, async (event, root: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    const existing = await readJson<RecentProject[]>(userDataFile('recent-projects.json'), [])
    const entries = [{ path: root, lastOpened: Date.now() }, ...existing.filter((entry) => entry.path !== root)].slice(0, 30)
    await writeJson(userDataFile('recent-projects.json'), entries)
  })

  ipcMain.handle(IPC.recentProjectOpen, async (event, root: unknown): Promise<OpenedFolder> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    const recent = await readJson<RecentProject[]>(userDataFile('recent-projects.json'), [])
    if (!recent.some((entry) => entry.path === root)) throw new Error('This project is not in the recent-projects list.')
    grantRoot(event.sender.id, root)
    return { root, entries: await readDirectory(root) }
  })

  ipcMain.handle(IPC.windowSessionRegister, async (event, id: unknown): Promise<void> => {
    assertTrustedSender(event)
    if (typeof id !== 'string' || !/^[a-z0-9-]+$/i.test(id)) throw new Error('Invalid window session ID.')
    setWindowSessionId(event.sender.id, id)
    const existing = await readJson<WindowSessionMeta[]>(userDataFile('window-sessions.json'), [])
    const next = [{ id, updatedAt: Date.now() }, ...existing.filter((entry) => entry.id !== id)].slice(0, 12)
    await writeJson(userDataFile('window-sessions.json'), next)
  })

  ipcMain.handle(IPC.windowSessionList, async (event): Promise<WindowSessionMeta[]> => {
    assertTrustedSender(event)
    const sessions = await readJson<WindowSessionMeta[]>(userDataFile('window-sessions.json'), [])
    return Array.isArray(sessions)
      ? sessions.filter((entry) => entry && typeof entry.id === 'string' && /^[a-z0-9-]+$/i.test(entry.id) && typeof entry.updatedAt === 'number').slice(0, 12)
      : []
  })

  ipcMain.handle(IPC.workspaceSearch, async (event, request: WorkspaceSearchRequest): Promise<WorkspaceMatch[]> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    for (const root of request.roots ?? []) assertGrantedRoot(event, root)
    return searchWorkspace(request)
  })
  ipcMain.handle(IPC.workspaceReplace, async (event, request: WorkspaceReplaceRequest): Promise<WorkspaceReplaceResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    for (const root of request.roots ?? []) assertGrantedRoot(event, root)
    return replaceWorkspace(request)
  })
  ipcMain.handle(IPC.workspaceReplacePreview, async (event, request: WorkspaceReplaceRequest): Promise<WorkspaceReplacePreview> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    for (const root of request.roots ?? []) assertGrantedRoot(event, root)
    return previewWorkspaceReplace(request)
  })
  ipcMain.handle(IPC.workspaceReplaceUndo, async (event, token: unknown): Promise<WorkspaceReplaceResult> => {
    assertTrustedSender(event)
    if (typeof token !== 'string' || token.length > 200) throw new Error('Invalid workspace replace undo token.')
    return undoWorkspaceReplace(token)
  })
  ipcMain.handle(IPC.workspaceSymbols, async (event, root: unknown): Promise<WorkspaceSymbol[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    return indexWorkspaceSymbols(root)
  })
  ipcMain.handle(IPC.workspaceWords, async (event, root: unknown): Promise<string[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    return indexWorkspaceWords(root)
  })

  ipcMain.handle(IPC.fileCreate, async (event, target: unknown, isDirectory = false): Promise<DirEntry> => {
    assertTrustedSender(event)
    assertAbsolutePath(target, 'new file path')
    assertGrantedFile(event, path.dirname(target))
    if (typeof isDirectory !== 'boolean') throw new Error('Invalid create request.')
    if (isDirectory) await fs.mkdir(target, { recursive: false })
    else {
      await fs.mkdir(path.dirname(target), { recursive: true })
      await fs.writeFile(target, '', { flag: 'wx' })
    }
    return { name: path.basename(target), path: target, isDirectory }
  })

  ipcMain.handle(IPC.fileRename, async (event, source: unknown, target: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(source, 'source path')
    assertAbsolutePath(target, 'destination path')
    assertGrantedFile(event, source)
    assertGrantedFile(event, path.dirname(target))
    if (path.dirname(source) !== path.dirname(target)) throw new Error('Moving files across folders is not supported here.')
    await fs.rename(source, target)
  })

  ipcMain.handle(IPC.fileDelete, async (event, target: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(target, 'delete path')
    assertGrantedFile(event, target)
    await shell.trashItem(target)
  })

  ipcMain.handle(IPC.revealInFolder, async (event, target: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(target, 'reveal path')
    assertGrantedFile(event, target)
    shell.showItemInFolder(target)
  })

  ipcMain.handle(IPC.fileWatch, async (event, root: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    const senderId = event.sender.id
    const resolvedRoot = path.resolve(root)
    const watchers = workspaceWatchers.get(senderId) ?? new Map<string, FSWatcher>()
    watchers.get(resolvedRoot)?.close()
    try {
      const watcher = watch(resolvedRoot, { recursive: true }, (_event, fileName) => {
        if (!fileName) return
        const changed = path.join(resolvedRoot, fileName.toString())
        event.sender.send(IPC.fileWatch, { kind: 'changed', path: changed })
      })
      watchers.set(resolvedRoot, watcher)
      workspaceWatchers.set(senderId, watchers)
      event.sender.once('destroyed', () => {
        closeWorkspaceWatchers(senderId)
        cleanupGrants(senderId)
      })
    } catch {
      // Filesystem watching is platform dependent. The rest of the workspace works without it.
    }
  })

  ipcMain.handle(IPC.buildRun, async (event, request: BuildRequest): Promise<void> => {
    assertTrustedSender(event)
    if (!request || typeof request.command !== 'string' || request.command.trim() === '') {
      throw new Error('Configure a build command before running Build.')
    }
    assertAbsolutePath(request.root, 'workspace root')
    assertGrantedRoot(event, request.root)
    const args = Array.isArray(request.args)
      ? request.args.filter((arg): arg is string => typeof arg === 'string').slice(0, 50)
      : []
    const senderId = event.sender.id
    builds.get(senderId)?.kill()
    const cwd = resolveBuildCwd(request.root, request.workingDirectory)
    const env = { ...process.env, ...sanitizeBuildEnv(request.env) }
    const child = spawn(request.command, args, { cwd, shell: request.shell === true, env })
    builds.set(senderId, child)
    const send = (payload: BuildOutput): void => {
      if (!event.sender.isDestroyed()) event.sender.send(IPC.buildOutput, payload)
    }
    const systemName = typeof request.name === 'string' ? request.name.slice(0, 100) : undefined
    child.stdout.on('data', (data: Buffer) => send({ kind: 'stdout', text: data.toString(), systemName }))
    child.stderr.on('data', (data: Buffer) => send({ kind: 'stderr', text: data.toString(), systemName }))
    child.on('error', (error) => send({ kind: 'stderr', text: `${error.message}\n`, systemName }))
    child.on('close', (code) => {
      if (builds.get(senderId) === child) builds.delete(senderId)
      send({ kind: 'exit', text: code === 0 ? 'Build completed successfully.\n' : `Build exited with code ${code}.\n`, code, systemName })
    })
  })

  ipcMain.handle(IPC.buildCancel, async (event): Promise<void> => {
    assertTrustedSender(event)
    const child = builds.get(event.sender.id)
    child?.kill()
    builds.delete(event.sender.id)
  })

  ipcMain.handle(IPC.projectRead, async (event, root: unknown): Promise<Session['project']> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    const raw = await readJson<unknown>(path.join(root, '.lumen-project.json'), EMPTY_SESSION.project)
    return sanitizeSession({ openFiles: [], activeIndex: 0, folder: root, project: raw }).project
  })

  ipcMain.handle(IPC.projectWrite, async (event, root: unknown, project: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    const clean = sanitizeSession({ openFiles: [], activeIndex: 0, folder: root, project }).project
    await writeJson(path.join(root, '.lumen-project.json'), clean)
  })

  ipcMain.handle(IPC.projectImportSublime, async (event): Promise<SublimeProjectImport | null> => {
    assertTrustedSender(event)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, {
      title: 'Import Sublime Project',
      properties: ['openFile'],
      filters: [{ name: 'Sublime Project', extensions: ['sublime-project'] }]
    })
    if (result.canceled || !result.filePaths[0]) return null
    const sourcePath = result.filePaths[0]
    let parsed: unknown
    try { parsed = JSON.parse(await fs.readFile(sourcePath, 'utf8')) } catch { throw new Error('The selected .sublime-project file is not valid JSON.') }
    const converted = convertSublimeProject(parsed, sourcePath)
    if (converted.roots.length === 0) throw new Error('No folders were declared in the selected .sublime-project.')
    const token = `${event.sender.id}-${Date.now()}-${Math.random().toString(36).slice(2)}`
    pendingSublimeImports.set(token, { senderId: event.sender.id, expiresAt: Date.now() + 60_000, sourcePath, roots: converted.roots, project: converted.project })
    return { token, sourcePath, roots: converted.roots, project: converted.project! }
  })

  ipcMain.handle(IPC.projectImportSublimeAccept, async (event, token: unknown): Promise<OpenedFolder[]> => {
    assertTrustedSender(event)
    if (typeof token !== 'string') throw new Error('Invalid Sublime project import token.')
    const pending = pendingSublimeImports.get(token)
    pendingSublimeImports.delete(token)
    if (!pending || pending.senderId !== event.sender.id || pending.expiresAt < Date.now()) throw new Error('The Sublime project import preview has expired.')
    const folders: OpenedFolder[] = []
    for (const root of pending.roots) {
      try {
        const stat = await fs.stat(root)
        if (!stat.isDirectory()) continue
        grantRoot(event.sender.id, root)
        folders.push({ root, entries: await readDirectory(root) })
      } catch {
        // Missing roots are skipped rather than becoming authorised paths.
      }
    }
    if (folders.length === 0) throw new Error('No existing folders were found in the selected .sublime-project.')
    return folders
  })

  ipcMain.handle(IPC.projectImportSublimeSnippet, async (event): Promise<SublimeSnippetImport | null> => {
    assertTrustedSender(event)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, { title: 'Import Sublime Snippet', properties: ['openFile'], filters: [{ name: 'Sublime Snippet', extensions: ['sublime-snippet'] }] })
    if (result.canceled || !result.filePaths[0]) return null
    const sourcePath = result.filePaths[0]
    return { sourcePath, snippet: parseSublimeSnippet(await fs.readFile(sourcePath, 'utf8'), sourcePath) }
  })

  ipcMain.handle(IPC.pluginList, async (event, root: unknown): Promise<PluginManifest[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    return listPlugins(root)
  })

  ipcMain.handle(IPC.pluginExtensionRead, async (event, root: unknown, pluginId: unknown, worker: unknown): Promise<string> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (typeof pluginId !== 'string' || !/^[a-z0-9-]+$/i.test(pluginId)) throw new Error('Invalid plugin ID.')
    if (typeof worker !== 'string' || !/^[a-z0-9._/-]+$/i.test(worker) || worker.includes('..')) throw new Error('Invalid extension worker path.')
    const pluginRoot = path.join(root, '.lumen-plugins', pluginId)
    const workerPath = path.resolve(pluginRoot, worker)
    if (!isInside(pluginRoot, workerPath)) throw new Error('Extension worker must stay inside the plugin directory.')
    const source = await fs.readFile(workerPath, 'utf8')
    if (Buffer.byteLength(source) > 512 * 1024) throw new Error('Extension worker exceeds 512 KB limit.')
    return source
  })

  ipcMain.handle(IPC.macroList, async (event, root: unknown): Promise<SavedMacro[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    const raw = await readJson<unknown>(path.join(root, '.lumen-macros.json'), [])
    return Array.isArray(raw)
      ? raw.flatMap((macro) => {
          if (!macro || typeof macro !== 'object') return []
          const source = macro as { name?: unknown; commands?: unknown; steps?: unknown; edits?: unknown; text?: unknown }
          if (typeof source.name !== 'string' || !Array.isArray(source.commands)) return []
          const edits = sanitizeMacroEdits(source.edits)
          const steps = sanitizeMacroSteps(source.steps)
          return [{
            name: source.name.slice(0, 100),
            commands: source.commands.filter((command): command is string => typeof command === 'string').slice(0, 200),
            ...(steps.length > 0 ? { steps } : {}),
            ...(edits.length > 0 ? { edits } : {}),
            ...(typeof source.text === 'string' && source.text.length <= 2 * 1024 * 1024 ? { text: source.text } : {})
          }]
        }).slice(0, 100)
      : []
  })

  ipcMain.handle(IPC.macroWrite, async (event, root: unknown, macro: SavedMacro): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (!macro || typeof macro.name !== 'string' || !Array.isArray(macro.commands)) throw new Error('Invalid macro.')
    const next: SavedMacro = {
      name: macro.name.slice(0, 100),
      commands: macro.commands.filter((command): command is string => typeof command === 'string').slice(0, 200),
      ...(sanitizeMacroSteps(macro.steps).length > 0 ? { steps: sanitizeMacroSteps(macro.steps) } : {}),
      ...(sanitizeMacroEdits(macro.edits).length > 0 ? { edits: sanitizeMacroEdits(macro.edits) } : {}),
      ...(typeof macro.text === 'string' && macro.text.length <= 2 * 1024 * 1024 ? { text: macro.text } : {})
    }
    const existing = await readJson<SavedMacro[]>(path.join(root, '.lumen-macros.json'), [])
    await writeJson(path.join(root, '.lumen-macros.json'), [next, ...existing.filter((item) => item.name !== next.name)].slice(0, 100))
  })

  ipcMain.handle(IPC.pluginInstall, async (event, request: PluginInstallRequest): Promise<PluginManifest> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    return installPlugin(request)
  })

  ipcMain.handle(IPC.pluginRemove, async (event, root: unknown, id: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (typeof id !== 'string' || !/^[a-z0-9-]+$/i.test(id)) throw new Error('Invalid plugin ID.')
    await shell.trashItem(path.join(root, '.lumen-plugins', id))
  })

  ipcMain.handle(IPC.marketplaceList, async (event, root: unknown): Promise<MarketplaceItem[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    const project = sanitizeSession({ openFiles: [], activeIndex: 0, folder: root, project: await readJson<unknown>(path.join(root, '.lumen-project.json'), EMPTY_SESSION.project) }).project
    return listMarketplace(project?.marketplaceUrls ?? [])
  })

  ipcMain.handle(IPC.marketplaceInstall, async (event, request: MarketplaceInstallRequest): Promise<PluginManifest> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    if (typeof request.manifestUrl !== 'string' || !/^https:\/\//.test(request.manifestUrl)) throw new Error('Marketplace manifest URL must use HTTPS.')
    return installMarketplacePlugin(request)
  })

  ipcMain.handle(IPC.gitStatus, async (event, root: unknown): Promise<GitStatus> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    return gitStatus(root)
  })

  ipcMain.handle(IPC.gitDiff, async (event, root: unknown, relativePath: unknown): Promise<GitDiff> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (typeof relativePath !== 'string') throw new Error('Invalid Git diff path.')
    return gitDiff(root, relativePath)
  })

  ipcMain.handle(IPC.gitHunks, async (event, root: unknown, relativePath: unknown): Promise<GitHunk[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (typeof relativePath !== 'string') throw new Error('Invalid Git diff path.')
    const diff = await gitDiff(root, relativePath)
    return parseGitHunks(relativePath, diff.diff)
  })

  ipcMain.handle(IPC.gitHistory, async (event, root: unknown, relativePath: unknown): Promise<GitHistoryEntry[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (typeof relativePath !== 'string') throw new Error('Invalid Git history path.')
    return gitHistory(root, relativePath)
  })

  ipcMain.handle(IPC.gitBlame, async (event, root: unknown, relativePath: unknown): Promise<string> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (typeof relativePath !== 'string') throw new Error('Invalid Git blame path.')
    return gitBlame(root, relativePath)
  })

  ipcMain.handle(IPC.gitAction, async (event, request: GitActionRequest): Promise<GitStatus> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    if (!request || !['stage', 'unstage', 'discard', 'stage-hunk', 'discard-hunk', 'commit', 'checkout-branch', 'create-branch'].includes(request.action)) throw new Error('Invalid Git action.')
    return gitAction(request)
  })

  ipcMain.handle(IPC.gitConflicts, async (event, root: unknown): Promise<GitConflict[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    return gitConflicts(root)
  })

  ipcMain.handle(IPC.updateCheck, async (event): Promise<UpdateInfo> => {
    assertTrustedSender(event)
    return checkForUpdate()
  })

  ipcMain.handle(IPC.languageToolRun, async (event, request: LanguageToolRequest): Promise<LanguageToolResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    return runLanguageTool(request)
  })

  ipcMain.handle(IPC.languageServerRun, async (event, request: LanguageServerRequest): Promise<LanguageServerResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    assertGrantedFile(event, request.filePath)
    return formatWithPersistentLanguageServer(event.sender, request)
  })

  ipcMain.handle(IPC.languageServerSync, async (event, request: LanguageServerSyncRequest): Promise<void> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    assertGrantedFile(event, request.filePath)
    await syncPersistentLanguageServer(event.sender, request)
  })

  ipcMain.handle(IPC.languageServerStop, async (event, root: unknown, config: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    if (!config || typeof config !== 'object' || typeof (config as { command?: unknown }).command !== 'string') return
    const source = config as { command: string; args?: unknown }
    const key = languageServerKey(event.sender.id, root, {
      command: source.command,
      args: Array.isArray(source.args) ? source.args.filter((arg): arg is string => typeof arg === 'string') : []
    })
    const server = languageServers.get(key)
    server?.child.kill()
    languageServers.delete(key)
  })

  ipcMain.handle(IPC.languageServerRequest, async (event, request: LanguageServerInteractiveRequest): Promise<LanguageServerInteractiveResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    assertGrantedFile(event, request.filePath)
    return interactiveLanguageServerRequest(event.sender, request)
  })
}

function validWriteOptions(options?: FileWriteOptions): FileWriteOptions {
  return {
    encoding:
      options?.encoding === 'utf8bom' || options?.encoding === 'utf16le' || options?.encoding === 'utf16be'
        ? options.encoding
        : 'utf8',
    eol: options?.eol === 'CRLF' || options?.eol === 'CR' ? options.eol : 'LF'
  }
}

async function saveAs(
  sender: Electron.WebContents,
  content: string,
  suggestedName?: string,
  options?: FileWriteOptions
): Promise<SaveResult> {
  const win = BrowserWindow.fromWebContents(sender)
  const result = await dialog.showSaveDialog(win!, { title: 'Save File', defaultPath: suggestedName })
  if (result.canceled || !result.filePath) return { saved: false }
  grantFile(sender.id, result.filePath)
  await fs.writeFile(result.filePath, encodeText(content, validWriteOptions(options)))
  return { saved: true, path: result.filePath }
}
