import { dialog, ipcMain, BrowserWindow, app, shell, type IpcMainInvokeEvent } from 'electron'
import { promises as fs, watch, type FSWatcher } from 'fs'
import { spawn, execFile, type ChildProcessWithoutNullStreams } from 'child_process'
import { promisify } from 'util'
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
  , type LayoutKind
  , type MarketplaceItem
  , type MarketplaceInstallRequest
  , type GitStatus
  , type GitDiff
  , type RecentProject
  , type WindowSessionMeta
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
const workspaceWatchers = new Map<number, FSWatcher>()
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
    searchHistory: Array.isArray(raw.searchHistory)
      ? raw.searchHistory.filter((item): item is string => typeof item === 'string').map((item) => item.slice(0, 2_000)).slice(0, 50)
      : [],
    replaceHistory: Array.isArray(raw.replaceHistory)
      ? raw.replaceHistory.filter((item): item is string => typeof item === 'string').map((item) => item.slice(0, 2_000)).slice(0, 50)
      : []
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
          ...(file.eol === 'LF' || file.eol === 'CRLF' || file.eol === 'CR' ? { eol: file.eol } : {})
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
              const source = system as { name?: unknown; command?: unknown; args?: unknown; workingDirectory?: unknown; fileRegex?: unknown; saveBeforeBuild?: unknown }
              if (typeof source.name !== 'string' || typeof source.command !== 'string') return []
              return [{
                name: source.name.slice(0, 100),
                command: source.command.slice(0, 1_000),
                args: Array.isArray(source.args) ? source.args.filter((arg): arg is string => typeof arg === 'string').slice(0, 50) : [],
                ...(typeof source.workingDirectory === 'string' ? { workingDirectory: source.workingDirectory.slice(0, 500) } : {}),
                ...(typeof source.fileRegex === 'string' ? { fileRegex: source.fileRegex.slice(0, 1_000) } : {}),
                ...(typeof source.saveBeforeBuild === 'boolean' ? { saveBeforeBuild: source.saveBeforeBuild } : {})
                , variants: Array.isArray((source as { variants?: unknown }).variants)
                  ? (source as { variants: unknown[] }).variants.flatMap((variant) => {
                      if (!variant || typeof variant !== 'object') return []
                      const rawVariant = variant as { name?: unknown; command?: unknown; args?: unknown; workingDirectory?: unknown; fileRegex?: unknown }
                      if (typeof rawVariant.name !== 'string') return []
                      return [{
                        name: rawVariant.name.slice(0, 100),
                        ...(typeof rawVariant.command === 'string' ? { command: rawVariant.command.slice(0, 1_000) } : {}),
                        ...(Array.isArray(rawVariant.args) ? { args: rawVariant.args.filter((arg): arg is string => typeof arg === 'string').slice(0, 50) } : {}),
                        ...(typeof rawVariant.workingDirectory === 'string' ? { workingDirectory: rawVariant.workingDirectory.slice(0, 500) } : {}),
                        ...(typeof rawVariant.fileRegex === 'string' ? { fileRegex: rawVariant.fileRegex.slice(0, 1_000) } : {})
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

async function searchWorkspace(request: WorkspaceSearchRequest): Promise<WorkspaceMatch[]> {
  assertAbsolutePath(request.root, 'workspace root')
  const root = path.resolve(request.root)
  const re = makeSearchRegExp(request)
  const files = await listFilesRecursive(root)
  const limit = Math.max(1, Math.min(request.maxResults ?? MAX_SEARCH_RESULTS, MAX_SEARCH_RESULTS))
  const results: WorkspaceMatch[] = []

  for (const file of files) {
    if (
      results.length >= limit ||
      !matchesGlob(file, root, request.include) ||
      (request.exclude?.trim() ? matchesGlob(file, root, request.exclude) : false)
    ) continue
    let stat
    try {
      stat = await fs.stat(file)
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
  return results
}

async function replaceWorkspace(request: WorkspaceReplaceRequest): Promise<WorkspaceReplaceResult> {
  assertAbsolutePath(request.root, 'workspace root')
  const root = path.resolve(request.root)
  const re = makeSearchRegExp(request)
  const files = await listFilesRecursive(root)
  let changedFiles = 0
  let replacements = 0
  const undoFiles = new Map<string, Buffer>()

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
        .map((snippet) => ({ label: snippet.label.slice(0, 200), text: snippet.text.slice(0, 10_000) }))
        .slice(0, 100)
    : []
  return {
    id: raw.id,
    name: raw.name.slice(0, 200),
    version: typeof raw.version === 'string' ? raw.version.slice(0, 50) : '0.0.0',
    enabled: raw.enabled !== false,
    commands,
    snippets
  }
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
  const manifest = sanitizePlugin(await response.json())
  if (!manifest) throw new Error('Downloaded plugin manifest is invalid.')
  const target = path.join(request.root, '.lumen-plugins', manifest.id)
  await fs.mkdir(target, { recursive: false })
  await fs.writeFile(path.join(target, 'plugin.json'), JSON.stringify(manifest, null, 2), 'utf8')
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
    return searchWorkspace(request)
  })
  ipcMain.handle(IPC.workspaceReplace, async (event, request: WorkspaceReplaceRequest): Promise<WorkspaceReplaceResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    return replaceWorkspace(request)
  })
  ipcMain.handle(IPC.workspaceReplacePreview, async (event, request: WorkspaceReplaceRequest): Promise<WorkspaceReplacePreview> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
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
    workspaceWatchers.get(senderId)?.close()
    try {
      const watcher = watch(root, { recursive: true }, (_event, fileName) => {
        if (!fileName) return
        const changed = path.join(root, fileName.toString())
        event.sender.send(IPC.fileWatch, { kind: 'changed', path: changed })
      })
      workspaceWatchers.set(senderId, watcher)
      event.sender.once('destroyed', () => {
        workspaceWatchers.get(senderId)?.close()
        workspaceWatchers.delete(senderId)
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
    const child = spawn(request.command, args, { cwd, shell: true, env: process.env })
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

  ipcMain.handle(IPC.pluginList, async (event, root: unknown): Promise<PluginManifest[]> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    return listPlugins(root)
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
