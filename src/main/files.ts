import { dialog, ipcMain, BrowserWindow, app, shell, type IpcMainInvokeEvent } from 'electron'
import { promises as fs, watch, type FSWatcher } from 'fs'
import { spawn, type ChildProcessWithoutNullStreams } from 'child_process'
import path from 'path'
import { pathToFileURL } from 'url'
import { detectLineEnding, encodeText as encodePreservedText } from '../shared/text.js'
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
  type BuildRequest,
  type BuildOutput,
  type PluginManifest,
  type LanguageToolRequest,
  type LanguageToolResult,
  type LanguageServerRequest,
  type LanguageServerResult,
  type PluginInstallRequest
} from '../shared/ipc.js'

/** Maximum text size we load into CodeMirror. This prevents accidental UI stalls. */
const MAX_EDITABLE_BYTES = 20 * 1024 * 1024
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
  if (encoding === 'utf16le' || encoding === 'utf16be') return false
  const sample = buffer.subarray(0, 8_192)
  return sample.includes(0)
}

/** Read a file safely, preserving its physical encoding and newline convention. */
async function readFile(filePath: string): Promise<OpenedFile> {
  const stat = await fs.stat(filePath)
  if (!stat.isFile()) throw new Error('The selected path is not a file.')
  const byteLength = stat.size
  if (byteLength > MAX_EDITABLE_BYTES) {
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
    buildCommand: typeof raw.buildCommand === 'string' ? raw.buildCommand.slice(0, 1_000) : ''
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
  return {
    openFiles,
    activeIndex: asFiniteInt(raw.activeIndex, 0, 0, Math.max(0, openFiles.length - 1)),
    folder: typeof raw.folder === 'string' && path.isAbsolute(raw.folder) ? raw.folder : null,
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
        : {}
    }
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
      const lines = opened.content.split(/\r\n|\r|\n/)
      for (let index = 0; index < lines.length && results.length < limit; index += 1) {
        const line = lines[index]
        re.lastIndex = 0
        let match: RegExpExecArray | null
        while ((match = re.exec(line)) && results.length < limit) {
          results.push({ path: file, line: index + 1, column: match.index + 1, lineText: line, matchText: match[0] })
          if (match[0].length === 0) re.lastIndex += 1
        }
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
        await fs.writeFile(file, encodeText(next, { encoding: opened.encoding, eol: opened.eol }))
        changedFiles += 1
        replacements += count
      }
    } catch {
      // Preserve a best-effort replace: inaccessible files are skipped, not partially rewritten.
    }
  }
  return { files: changedFiles, replacements }
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

/** One-shot LSP initialize/open/format handshake, including publishDiagnostics. */
async function runLanguageServer(request: LanguageServerRequest): Promise<LanguageServerResult> {
  assertAbsolutePath(request.root, 'workspace root')
  assertAbsolutePath(request.filePath, 'document path')
  if (!request.config || typeof request.config.command !== 'string' || !request.config.command.trim()) {
    throw new Error('No language server command is configured for this language.')
  }
  return new Promise<LanguageServerResult>((resolve, reject) => {
    const child = spawn(request.config.command, request.config.args ?? [], { cwd: request.root, env: process.env })
    const uri = pathToFileURL(request.filePath).href
    const diagnostics: LanguageServerResult['diagnostics'] = []
    let completed = false
    const fail = (error: Error): void => {
      if (completed) return
      completed = true
      child.kill()
      reject(error)
    }
    const finish = (edits: LanguageServerResult['edits']): void => {
      if (completed) return
      completed = true
      child.kill()
      resolve({ edits, diagnostics })
    }
    const timer = setTimeout(() => fail(new Error('Language server timed out after 15 seconds.')), 15_000)
    child.on('error', (error) => { clearTimeout(timer); fail(error) })
    child.stderr.on('data', () => undefined)
    child.stdout.on('data', createLspReader((message) => {
      if (message.method === 'textDocument/publishDiagnostics') {
        const params = message.params as { uri?: unknown; diagnostics?: unknown } | undefined
        if (params?.uri === uri && Array.isArray(params.diagnostics)) {
          diagnostics.splice(0, diagnostics.length, ...params.diagnostics
            .filter((item): item is { range?: unknown; severity?: unknown; message?: unknown } => !!item && typeof item === 'object')
            .map((item) => {
              const range = item.range as { start?: { line?: number; character?: number }; end?: { line?: number; character?: number } } | undefined
              const severity: LanguageServerResult['diagnostics'][number]['severity'] =
                item.severity === 2 ? 'warning' : item.severity === 3 || item.severity === 4 ? 'info' : 'error'
              return {
                line: (range?.start?.line ?? 0) + 1,
                column: (range?.start?.character ?? 0) + 1,
                endLine: (range?.end?.line ?? range?.start?.line ?? 0) + 1,
                endColumn: (range?.end?.character ?? range?.start?.character ?? 0) + 1,
                severity,
                message: typeof item.message === 'string' ? item.message : 'Language server diagnostic'
              }
            }))
        }
      }
      if (message.id === 1 && message.result) {
        lspMessage(child, { jsonrpc: '2.0', method: 'initialized', params: {} })
        lspMessage(child, {
          jsonrpc: '2.0', method: 'textDocument/didOpen', params: { textDocument: { uri, languageId: request.languageId, version: 1, text: request.content } }
        })
        lspMessage(child, { jsonrpc: '2.0', id: 2, method: 'textDocument/formatting', params: { textDocument: { uri }, options: { tabSize: 4, insertSpaces: true } } })
      }
      if (message.id === 2) {
        clearTimeout(timer)
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
        finish(edits)
      }
    }))
    child.on('close', (code) => {
      if (!completed) { clearTimeout(timer); fail(new Error(`Language server exited with code ${code}.`)) }
    })
    lspMessage(child, {
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { processId: process.pid, rootUri: pathToFileURL(request.root).href, capabilities: {} }
    })
  })
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
    return sanitizeSettings(await readJson<unknown>(userDataFile('settings.json'), DEFAULT_SETTINGS))
  })
  ipcMain.handle(IPC.settingsWrite, async (event, settings: unknown): Promise<void> => {
    assertTrustedSender(event)
    await writeJson(userDataFile('settings.json'), sanitizeSettings(settings))
  })
  ipcMain.handle(IPC.sessionRead, async (event): Promise<Session> => {
    assertTrustedSender(event)
    const session = sanitizeSession(await readJson<unknown>(userDataFile('session.json'), EMPTY_SESSION))
    if (session.folder) grantRoot(event.sender.id, session.folder)
    for (const file of session.openFiles) if (file.path) grantFile(event.sender.id, file.path)
    return session
  })
  ipcMain.handle(IPC.sessionWrite, async (event, session: unknown): Promise<void> => {
    assertTrustedSender(event)
    await writeJson(userDataFile('session.json'), sanitizeSession(session))
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
    const child = spawn(request.command, args, { cwd: request.root, shell: true, env: process.env })
    builds.set(senderId, child)
    const send = (payload: BuildOutput): void => {
      if (!event.sender.isDestroyed()) event.sender.send(IPC.buildOutput, payload)
    }
    child.stdout.on('data', (data: Buffer) => send({ kind: 'stdout', text: data.toString() }))
    child.stderr.on('data', (data: Buffer) => send({ kind: 'stderr', text: data.toString() }))
    child.on('error', (error) => send({ kind: 'stderr', text: `${error.message}\n` }))
    child.on('close', (code) => {
      if (builds.get(senderId) === child) builds.delete(senderId)
      send({ kind: 'exit', text: code === 0 ? 'Build completed successfully.\n' : `Build exited with code ${code}.\n`, code })
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

  ipcMain.handle(IPC.languageToolRun, async (event, request: LanguageToolRequest): Promise<LanguageToolResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    return runLanguageTool(request)
  })

  ipcMain.handle(IPC.languageServerRun, async (event, request: LanguageServerRequest): Promise<LanguageServerResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    assertGrantedFile(event, request.filePath)
    return runLanguageServer(request)
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
