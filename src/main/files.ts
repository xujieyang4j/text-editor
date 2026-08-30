import { dialog, ipcMain, BrowserWindow, app, shell, clipboard, type IpcMainInvokeEvent } from 'electron'
import { constants as fsConstants, createReadStream, promises as fs, watch, type FSWatcher } from 'fs'
import { spawn, execFile, type ChildProcessWithoutNullStreams } from 'child_process'
import { promisify, TextDecoder } from 'util'
import { StringDecoder } from 'string_decoder'
import { createHash } from 'crypto'
import path from 'path'
import { fileURLToPath, pathToFileURL } from 'url'
import { applyLineEnding, detectLineEnding, isTextEncoding, jsonStringUtf8ByteLength, normalizeLineEndings } from '../shared/text.js'
import { decodeTextAuto, decodeTextWithEncoding, detectTextEncoding, encodeTextBytes } from './textEncoding.js'
import { isBinaryBuffer, maxEditableBytes } from '../shared/filePolicy.js'
import { extractWorkspaceSymbols } from '../shared/symbolIndex.js'
import { parseGitRemoteLines, parseGitTracking } from '../shared/git.js'
import { createLspMessageReader, encodeLspMessage, LspProtocolError } from '../shared/lspProtocol.js'
import { applyEditorConfigChain, parseEditorConfig } from '../shared/editorConfig.js'
import {
  IPC,
  MAX_SESSION_OPEN_FILES,
  MAX_SESSION_RECOVERY_BYTES,
  DEFAULT_SETTINGS,
  EMPTY_SESSION,
  type OpenedFile,
  type DroppedPaths,
  type SaveResult,
  type OpenedFolder,
  type DirEntry,
  type EditorConfigRequest,
  type ResolvedEditorConfig,
  type BrowserOpenRequest,
  type Settings,
  type Session,
  type TextEncoding,
  type FileWriteOptions,
  type FileReadOptions,
  type WorkspaceMatch,
  type WorkspaceSearchRequest,
  type WorkspaceReplaceRequest,
  type WorkspaceReplaceResult,
  type WorkspaceReplacePreview,
  type WorkspaceSymbol,
  type BuildRequest,
  type BuildOutput,
  type TerminalOutput,
  type BuildSystem,
  type KeyBindingRule,
  type PluginManifest,
  type LanguageToolRequest,
  type LanguageToolResult,
  type LanguageServerRequest,
  type LanguageServerResult,
  type LanguageServerSyncRequest,
  type LanguageServerDiagnosticEvent,
  type LanguageServerInteractiveRequest,
  type LanguageServerInteractiveResult,
  type LanguageServerStatusEvent,
  type LanguageServerLogEvent,
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
  , type RecentFile
  , type WindowSessionMeta
  , type UpdateInfo
  , type SavedMacro
  , type MacroStep
  , type SessionViewState
  , type SublimeProjectImport
  , type SublimeSnippetImport
  , type SublimeBuildImport
  , type SublimeKeymapImport
} from '../shared/ipc.js'

const MAX_SEARCH_FILE_BYTES = 2 * 1024 * 1024
const MAX_SEARCH_RESULTS = 5_000
const MAX_SESSION_SERIALIZED_BYTES = MAX_SESSION_RECOVERY_BYTES + 8 * 1024 * 1024
const MAX_EDITOR_CONFIG_LEVELS = 32
const MAX_EDITOR_CONFIG_FILE_BYTES = 64 * 1024
const MAX_EDITOR_CONFIG_TOTAL_BYTES = 512 * 1024

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
/** Serialises path-changing operations with saves, including directory moves. */
let fileMutationTail: Promise<void> = Promise.resolve()
const workspaceWatchers = new Map<number, Map<string, FSWatcher>>()
const builds = new Map<number, ChildProcessWithoutNullStreams>()
/** The main process owns terminal child processes; the renderer only sees text I/O. */
interface TerminalProcess {
  child: ChildProcessWithoutNullStreams
  sessionId: string
}
const terminals = new Map<number, TerminalProcess>()
const terminalCleanupBound = new Set<number>()
const MAX_TERMINAL_OUTPUT_CHUNK_BYTES = 256 * 1024
interface PersistentLanguageServer {
  child: ChildProcessWithoutNullStreams
  processId: number | undefined
  processGroupId: number | undefined
  root: string
  config: LanguageServerSyncRequest['config']
  configKey: string
  initialized: boolean
  capabilities?: string[]
  nextId: number
  documents: Map<string, LanguageServerDocumentSnapshot>
  pending: Map<number, (message: Record<string, unknown>) => void>
  sender: Electron.WebContents
  ready: Promise<void>
  resolveReady: () => void
  initializeTimer: ReturnType<typeof setTimeout> | null
  processClosed: Promise<void>
  resolveProcessClosed: () => void
  flushStderr: () => void
  writeQueue: Buffer[]
  queuedWriteBytes: number
  writeInProgress: boolean
  writeDrainListener?: () => void
  logBuckets: Map<string, LanguageServerLogBucket>
  logBufferedBytes: number
  logDroppedMessages: number
  logFlushTimer: ReturnType<typeof setTimeout> | null
  logRateStartedAt: number
  logRateBytes: number
  diagnosticRateStartedAt: number
  diagnosticRateBytes: number
  diagnosticRateEvents: number
  diagnosticDroppedEvents: number
  processCloseObserved: boolean
  cleaned: boolean
  stopping: boolean
  restartable: boolean
  stopPromise?: Promise<void>
  terminationPromise?: Promise<void>
}
interface LanguageServerLogBucket {
  stream: LanguageServerLogEvent['stream']
  level: LanguageServerLogEvent['level']
  chunks: string[]
}
interface LanguageServerDocumentSnapshot {
  content: string
  languageId: string
  version: number
}
interface LanguageServerRestartDescriptor {
  sender: Electron.WebContents
  root: string
  config: LanguageServerSyncRequest['config']
  documents: Map<string, LanguageServerDocumentSnapshot>
}
interface LanguageServerRestartOperation {
  descriptor: LanguageServerRestartDescriptor
  source?: PersistentLanguageServer
  replacement?: PersistentLanguageServer
  cancelled: boolean
  promise: Promise<void>
}
interface LanguageServerExplicitStop {
  sender: Electron.WebContents
  root: string
  promise: Promise<void>
}
const languageServers = new Map<string, PersistentLanguageServer>()
const languageServerRestarts = new Map<string, LanguageServerRestartOperation>()
const languageServerTombstones = new Map<string, LanguageServerRestartDescriptor>()
const languageServerExplicitStops = new Map<string, LanguageServerExplicitStop>()
const languageServerTerminations = new Map<PersistentLanguageServer, Promise<void>>()
const languageServerRootReleases = new WeakMap<Electron.WebContents, Set<string>>()
const languageServerSenderCleanupBound = new WeakSet<Electron.WebContents>()
const MAX_LANGUAGE_SERVER_TOMBSTONES_PER_SENDER = 32
const MAX_LANGUAGE_SERVER_TOMBSTONE_DOCUMENTS = 32
const MAX_LANGUAGE_SERVER_TOMBSTONE_CHARS = 1024 * 1024
const MAX_LANGUAGE_SERVER_LOG_CHARS = 64 * 1024
const MAX_LANGUAGE_SERVER_STDIN_QUEUE_BYTES = 16 * 1024 * 1024
const LANGUAGE_SERVER_LOG_FLUSH_MS = 100
const MAX_LANGUAGE_SERVER_LOG_BATCH_BYTES = 64 * 1024
const MAX_LANGUAGE_SERVER_LOG_BYTES_PER_SECOND = 256 * 1024
const MAX_LANGUAGE_SERVER_LOG_CHUNKS_PER_BUCKET = 256
const LANGUAGE_SERVER_LOG_SENTINEL_RESERVE_BYTES = 256
const MAX_LANGUAGE_SERVER_DIAGNOSTICS = 1_000
const MAX_LANGUAGE_SERVER_DIAGNOSTIC_MESSAGE_BYTES = 256 * 1024
const MAX_LANGUAGE_SERVER_DIAGNOSTIC_PATH_CHARS = 32 * 1024
const MAX_LANGUAGE_SERVER_DIAGNOSTIC_EVENTS_PER_SECOND = 20
const MAX_LANGUAGE_SERVER_DIAGNOSTIC_IPC_BYTES_PER_SECOND = 1024 * 1024
const MAX_LANGUAGE_SERVER_CAPABILITY_NAMES = 128
const MAX_LANGUAGE_SERVER_CAPABILITY_CHARS = 32 * 1024
const LANGUAGE_SERVER_INITIALIZE_TIMEOUT_MS = 15_000
const LANGUAGE_SERVER_GRACEFUL_TIMEOUT_MS = 500
const LANGUAGE_SERVER_CLOSE_TIMEOUT_MS = 500
const execFileAsync = promisify(execFile)
const windowSessionIds = new Map<number, string>()
const replaceUndoTransactions = new Map<string, {
  expiresAt: number
  files: Map<string, { content: Buffer; expectedRevision: string }>
}>()
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

async function rememberRecentFile(file: string): Promise<void> {
  const existing = await readJson<RecentFile[]>(userDataFile('recent-files.json'), [])
  const entries = [{ path: file, lastOpened: Date.now() }, ...existing.filter((entry) => entry.path !== file)].slice(0, 50)
  await writeJson(userDataFile('recent-files.json'), entries)
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

function emptyEditorConfig(truncated = false): ResolvedEditorConfig {
  return { sources: [], truncated }
}

function emptyAuthorisedEditorConfig(event: IpcMainInvokeEvent, root: string, truncated = false): ResolvedEditorConfig {
  assertGrantedRoot(event, root)
  return emptyEditorConfig(truncated)
}

async function readBoundedEditorConfig(
  candidate: string,
  byteLimit: number,
  expectedIdentity: { dev: number; ino: number }
): Promise<string | null> {
  const flags = fsConstants.O_RDONLY | (process.platform === 'win32' ? 0 : (fsConstants.O_NOFOLLOW ?? 0))
  const handle = await fs.open(candidate, flags)
  try {
    const stat = await handle.stat()
    if (!stat.isFile() || stat.dev !== expectedIdentity.dev || stat.ino !== expectedIdentity.ino || stat.size > byteLimit) return null
    const bytes = Buffer.allocUnsafe(byteLimit + 1)
    let offset = 0
    while (offset < bytes.length) {
      const { bytesRead } = await handle.read(bytes, offset, bytes.length - offset, offset)
      if (bytesRead === 0) break
      offset += bytesRead
    }
    if (offset > byteLimit) return null
    try {
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, offset))
    } catch {
      return null
    }
  } finally {
    await handle.close()
  }
}

/**
 * Read only project-owned EditorConfig files. The caller establishes the
 * lexical grant first; real paths then prevent symlinks escaping that grant.
 */
async function resolveEditorConfig(
  event: IpcMainInvokeEvent,
  request: EditorConfigRequest,
  allowMissingTarget = false
): Promise<ResolvedEditorConfig> {
  const root = path.resolve(request.workspaceRoot)
  const target = path.resolve(request.filePath)
  assertGrantedRoot(event, root)
  if (!isInside(root, target)) throw new Error('The EditorConfig target is outside the requested workspace root.')
  const rootGrantIsActive = (): boolean => grantedRoots.get(event.sender.id)?.has(root) === true

  try {
    const realRoot = await fs.realpath(root)
    let realTarget: string
    try {
      realTarget = await fs.realpath(target)
    } catch (error) {
      if (!allowMissingTarget || (error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      realTarget = path.join(await fs.realpath(path.dirname(target)), path.basename(target))
    }
    if (!isInside(realRoot, realTarget)) {
      throw new Error('The EditorConfig target resolves outside the requested workspace root.')
    }

    const configsNearToFar: Array<{ path: string; source: string }> = []
    let directory = path.dirname(target)
    let totalBytes = 0
    let truncated = false

    for (let level = 0; level < MAX_EDITOR_CONFIG_LEVELS; level += 1) {
      if (!rootGrantIsActive()) throw new Error('This workspace has not been authorised for the current editor window.')
      if (!isInside(root, directory)) break
      const candidate = path.join(directory, '.editorconfig')
      try {
        const candidateStat = await fs.lstat(candidate)
        if (candidateStat.isSymbolicLink() || !candidateStat.isFile()) {
          return emptyAuthorisedEditorConfig(event, root)
        }
        if (candidateStat.size > MAX_EDITOR_CONFIG_FILE_BYTES || totalBytes + candidateStat.size > MAX_EDITOR_CONFIG_TOTAL_BYTES) {
          return emptyAuthorisedEditorConfig(event, root, true)
        }
        const realCandidate = await fs.realpath(candidate)
        if (!isInside(realRoot, realCandidate)) {
          return emptyAuthorisedEditorConfig(event, root)
        }
        const remainingBytes = Math.min(MAX_EDITOR_CONFIG_FILE_BYTES, MAX_EDITOR_CONFIG_TOTAL_BYTES - totalBytes)
        const source = await readBoundedEditorConfig(candidate, remainingBytes, {
          dev: candidateStat.dev,
          ino: candidateStat.ino
        })
        if (!rootGrantIsActive()) throw new Error('This workspace has not been authorised for the current editor window.')
        if (source === null) return emptyAuthorisedEditorConfig(event, root, true)
        const bytes = Buffer.byteLength(source, 'utf8')
        if (bytes > MAX_EDITOR_CONFIG_FILE_BYTES || totalBytes + bytes > MAX_EDITOR_CONFIG_TOTAL_BYTES) {
          truncated = true
          break
        }
        totalBytes += bytes
        const config = parseEditorConfig(source)
        if (!config.valid) return emptyAuthorisedEditorConfig(event, root)
        configsNearToFar.push({ path: candidate, source })
        if (config.root) break
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code
        if (code === 'ELOOP') return emptyAuthorisedEditorConfig(event, root)
        if (code !== 'ENOENT') return emptyAuthorisedEditorConfig(event, root)
      }

      if (directory === root) break
      const parent = path.dirname(directory)
      if (parent === directory) break
      directory = parent
      if (level === MAX_EDITOR_CONFIG_LEVELS - 1 && isInside(root, directory)) truncated = true
    }

    // A workspace may be released while filesystem reads are pending. Never
    // return data collected under a grant that is no longer active.
    assertGrantedRoot(event, root)
    if (truncated) return emptyEditorConfig(true)
    const configs = [...configsNearToFar].reverse()
    const values = applyEditorConfigChain(
      configs,
      target,
      process.platform === 'win32' ? 'win32' : 'posix'
    )
    return {
      ...values,
      sources: configs.map((config) => config.path),
      truncated
    }
  } catch (error) {
    // Authorization failures are security decisions; missing/racing project
    // files are ordinary editor conditions and degrade to global preferences.
    if (error instanceof Error && /outside the requested workspace root|not been authorised/.test(error.message)) throw error
    assertGrantedRoot(event, root)
    return emptyEditorConfig()
  }
}

function isLanguageServerRootReleasing(sender: Electron.WebContents, root: string): boolean {
  return languageServerRootReleases.get(sender)?.has(path.resolve(root)) === true
}

function assertLanguageServerRootNotReleasing(sender: Electron.WebContents, root: string): void {
  if (isLanguageServerRootReleasing(sender, root)) {
    throw new Error('This workspace is currently being released.')
  }
}

/** Recheck both parts of LSP authorisation immediately before process use/start. */
function assertLanguageServerRootAvailable(sender: Electron.WebContents, root: string): void {
  const resolvedRoot = path.resolve(root)
  if (!grantedRoots.get(sender.id)?.has(resolvedRoot)) {
    throw new Error('This workspace has not been authorised for the current editor window.')
  }
  assertLanguageServerRootNotReleasing(sender, resolvedRoot)
}

function beginLanguageServerRootRelease(sender: Electron.WebContents, root: string): void {
  const resolvedRoot = path.resolve(root)
  const roots = languageServerRootReleases.get(sender) ?? new Set<string>()
  if (roots.has(resolvedRoot)) throw new Error('This workspace is already being released.')
  roots.add(resolvedRoot)
  languageServerRootReleases.set(sender, roots)
}

function finishLanguageServerRootRelease(sender: Electron.WebContents, root: string): void {
  const roots = languageServerRootReleases.get(sender)
  if (!roots) return
  roots.delete(path.resolve(root))
  if (roots.size === 0) languageServerRootReleases.delete(sender)
}

function cleanupGrants(senderId: number): void {
  grantedFiles.delete(senderId)
  grantedRoots.delete(senderId)
}

function closeWorkspaceWatchers(senderId: number): void {
  for (const watcher of workspaceWatchers.get(senderId)?.values() ?? []) watcher.close()
  workspaceWatchers.delete(senderId)
}

function closeWorkspaceWatcher(senderId: number, root: string): void {
  const watchers = workspaceWatchers.get(senderId)
  if (!watchers) return
  const resolved = path.resolve(root)
  watchers.get(resolved)?.close()
  watchers.delete(resolved)
  if (watchers.size === 0) workspaceWatchers.delete(senderId)
}

/** Drop a recursive workspace grant but preserve direct grants for open tabs. */
async function releaseWorkspaceRoot(event: IpcMainInvokeEvent, root: string, retainFiles: unknown): Promise<void> {
  const resolvedRoot = path.resolve(root)
  const senderId = event.sender.id
  const roots = grantedRoots.get(senderId)
  if (!roots?.has(resolvedRoot)) throw new Error('This workspace has not been authorised for the current editor window.')
  if (!Array.isArray(retainFiles) || retainFiles.length > 100) throw new Error('Invalid retained workspace files.')
  for (const file of retainFiles) {
    if (typeof file !== 'string' || !path.isAbsolute(file) || !isInside(resolvedRoot, path.resolve(file))) {
      throw new Error('A retained file is outside the workspace being removed.')
    }
  }
  beginLanguageServerRootRelease(event.sender, resolvedRoot)
  try {
    // A server is authorised by the workspace grant, not by the renderer's
    // current configuration. Stop every generation before revoking that grant.
    await stopAllLanguageServersForRoot(event.sender, resolvedRoot)
    // A workspace grant may previously have made files in this root accessible
    // through a direct OS dialog or a restored session. Once the root is removed,
    // retain *only* the tabs explicitly named by the renderer.
    const directFiles = grantedFiles.get(senderId)
    if (directFiles) {
      for (const file of directFiles) if (isInside(resolvedRoot, file)) directFiles.delete(file)
      if (directFiles.size === 0) grantedFiles.delete(senderId)
    }
    for (const file of retainFiles) {
      grantFile(senderId, file)
    }
    closeWorkspaceWatcher(senderId, resolvedRoot)
    roots.delete(resolvedRoot)
    if (roots.size === 0) grantedRoots.delete(senderId)
  } finally {
    finishLanguageServerRootRelease(event.sender, resolvedRoot)
  }
}

/**
 * Stop a shell we started, including its POSIX process group where possible.
 * A normal child.kill() can otherwise leave a build started from the shell
 * alive after its owning editor window has gone away.
 */
function stopTerminalProcess(terminal: TerminalProcess | undefined): void {
  if (!terminal || terminal.child.killed) return
  const { child } = terminal
  if (process.platform !== 'win32' && child.pid) {
    try {
      process.kill(-child.pid, 'SIGTERM')
      return
    } catch {
      // The process may have already exited, or group termination may not be
      // available on this platform. Fall back to killing the direct child.
    }
  }
  child.kill()
}

function stopTerminalForSender(senderId: number): void {
  const terminal = terminals.get(senderId)
  terminals.delete(senderId)
  stopTerminalProcess(terminal)
}

function terminalChunk(data: Buffer): string {
  if (data.byteLength <= MAX_TERMINAL_OUTPUT_CHUNK_BYTES) return data.toString()
  return `${data.subarray(0, MAX_TERMINAL_OUTPUT_CHUNK_BYTES).toString()}\n[Terminal output truncated]\n`
}

function assertTerminalSessionId(value: unknown): asserts value is string {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9-]{16,80}$/.test(value)) {
    throw new Error('Invalid terminal session.')
  }
}

/** Grant a user-selected OS-level path to a renderer (file associations / CLI opens). */
export function authorizePathForRenderer(senderId: number, target: string): void {
  if (!path.isAbsolute(target)) return
  grantFile(senderId, target)
}

/** Grant a user-selected (or main-process initiated) workspace root to one renderer. */
export function authorizeWorkspaceForRenderer(senderId: number, root: string): void {
  if (!path.isAbsolute(root)) return
  grantRoot(senderId, root)
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

function encodeText(content: string, options: FileWriteOptions): Buffer {
  const normalized = applyLineEnding(content, options.eol)
  return encodeTextBytes(normalized, options.encoding)
}

function fileRevision(buffer: Uint8Array): string {
  return `sha256:${createHash('sha256').update(buffer).digest('hex')}`
}

/** Hash exact disk bytes without applying the editor's text-size limit. */
async function readRawFileRevision(filePath: string): Promise<string | null> {
  try {
    const hash = createHash('sha256')
    for await (const chunk of createReadStream(filePath)) hash.update(chunk)
    return `sha256:${hash.digest('hex')}`
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
}

function expectedFileRevision(value: unknown): string | null | undefined {
  if (value === undefined) return undefined
  if (value === null) return null
  if (typeof value !== 'string' || !/^sha256:[a-f0-9]{64}$/.test(value)) {
    throw new Error('Invalid file revision.')
  }
  return value
}

function looksBinary(buffer: Buffer, encoding: TextEncoding): boolean {
  return isBinaryBuffer(buffer, encoding.startsWith('utf16'))
}

/** Read a file safely, preserving its physical encoding and newline convention. */
async function readFile(filePath: string, forcedEncoding?: TextEncoding): Promise<OpenedFile> {
  const stat = await fs.stat(filePath)
  if (!stat.isFile()) throw new Error('The selected path is not a file.')
  const byteLength = stat.size
  const maxBytes = maxEditableBytes((await readSettings()).maxFileSizeMB)
  if (byteLength > maxBytes) {
    return { path: filePath, content: '', encoding: 'utf8', eol: 'LF', revision: null, byteLength, isBinary: false, isTooLarge: true }
  }
  const buffer = await fs.readFile(filePath)
  const actualByteLength = buffer.byteLength
  if (actualByteLength > maxBytes) {
    return {
      path: filePath,
      content: '',
      encoding: 'utf8',
      eol: 'LF',
      revision: fileRevision(buffer),
      byteLength: actualByteLength,
      isBinary: false,
      isTooLarge: true
    }
  }
  const detectedEncoding = detectTextEncoding(buffer)
  const binaryEncoding = forcedEncoding ?? detectedEncoding
  if (looksBinary(buffer, binaryEncoding)) {
    return { path: filePath, content: '', encoding: binaryEncoding, eol: 'LF', revision: fileRevision(buffer), byteLength: actualByteLength, isBinary: true, isTooLarge: false }
  }
  const decoded = forcedEncoding
    ? decodeTextWithEncoding(buffer, forcedEncoding)
    : decodeTextAuto(buffer)
  const encoding = decoded.encoding
  return {
    path: filePath,
    // CodeMirror normalises line breaks to LF. Normalise at the process
    // boundary too so document baselines, drafts and watcher snapshots use
    // the same logical representation; `eol` retains the physical format.
    content: normalizeLineEndings(decoded.content),
    encoding,
    eol: detectLineEnding(decoded.content),
    revision: fileRevision(buffer),
    byteLength: actualByteLength,
    isBinary: false,
    isTooLarge: false,
    ...(forcedEncoding ? { encodingLocked: true } : {}),
    ...(decoded.hadDecodingErrors ? { encodingIssue: 'invalid-bytes' as const } : {}),
    ...(!decoded.hadDecodingErrors && decoded.uncertain ? { encodingIssue: 'uncertain' as const } : {})
  }
}

/** Validate a disk revision and write only when the observed bytes still match it. */
async function saveFile(
  filePath: string,
  content: string,
  options?: FileWriteOptions
): Promise<SaveResult> {
  const validated = validWriteOptions(options)
  const expectedRevision = expectedFileRevision(options?.expectedRevision)
  const result = await saveFileBytes(
    filePath,
    encodeText(content, validated),
    expectedRevision,
    validated.expectedEncoding,
    validated.protectedSourcePath
  )
  return result.saved ? { ...result, eol: validated.eol } : result
}

async function saveFileBytes(
  filePath: string,
  bytes: Buffer,
  expectedRevision: string | null | undefined,
  expectedEncoding?: TextEncoding,
  protectedSourcePath?: string
): Promise<SaveResult> {
  return withSerializedFileSave(filePath, async () => {
    const writePath = await fileWriteTarget(filePath)
    if (protectedSourcePath && await pathsShareFileIdentity(writePath, protectedSourcePath)) {
      return { saved: false, path: filePath, reason: 'protected-source' }
    }
    const nextRevision = fileRevision(bytes)
    let checkedRevision: string | null | undefined
    let current: OpenedFile | null = null
    if (expectedRevision !== undefined) {
      const currentRevision = await readRawFileRevision(writePath)
      const revisionMatches = currentRevision === expectedRevision
      if (!revisionMatches) {
        // Concurrent identical saves are idempotent: the desired bytes have
        // already landed, so return their observed revision without rewriting.
        if (currentRevision === nextRevision) {
          return { saved: true, path: filePath, revision: nextRevision }
        }
        if (currentRevision !== null) {
          try { current = await readFile(writePath, expectedEncoding) }
          catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
        }
        return { saved: false, path: filePath, reason: 'conflict', conflict: current }
      }
      checkedRevision = currentRevision
    }

    // Regular files use a durable same-directory temporary file followed by
    // one final revision check and atomic replacement. Refuse hard-linked
    // targets: in-place writes can corrupt every alias on failure, while
    // replacement would silently sever the user's link relationship.
    let links = 1
    let mode: number | undefined
    try {
      const stat = await fs.stat(writePath)
      links = stat.nlink
      mode = stat.mode & 0o777
    } catch { /* Missing targets are created below. */ }
    if (links > 1) {
      return {
        saved: false,
        path: filePath,
        reason: 'hardlink',
        conflict: current ?? await readFile(writePath, expectedEncoding)
      }
    }

    const tempPath = path.join(
      path.dirname(writePath),
      `.${path.basename(writePath)}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`
    )
    let tempCreated = false
    try {
      const handle = await fs.open(tempPath, 'wx', mode ?? 0o666)
      tempCreated = true
      try {
        if (mode !== undefined) await handle.chmod(mode)
        await handle.writeFile(bytes)
        await handle.sync()
      } finally {
        await handle.close()
      }
      if (expectedRevision !== undefined) {
        const latestRevision = await readRawFileRevision(writePath)
        let latest: OpenedFile | null = null
        if (latestRevision !== checkedRevision) {
          if (latestRevision !== null) {
            try { latest = await readFile(writePath, expectedEncoding) }
            catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
          }
          return { saved: false, path: filePath, reason: 'conflict', conflict: latest }
        }
      }
      if (expectedRevision === null) {
        try {
          await fs.link(tempPath, writePath)
          return { saved: true, path: filePath, revision: nextRevision }
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
          let conflict: OpenedFile | null = null
          try { conflict = await readFile(writePath, expectedEncoding) } catch { /* Broken links remain a missing-target conflict. */ }
          return { saved: false, path: filePath, reason: 'conflict', conflict }
        }
      }
      const latestWritePath = await fileWriteTarget(filePath)
      if (path.resolve(latestWritePath) !== path.resolve(writePath)) {
        let conflict: OpenedFile | null = null
        try { conflict = await readFile(filePath, expectedEncoding) } catch { /* The link/path became unavailable. */ }
        return { saved: false, path: filePath, reason: 'conflict', conflict }
      }
      if (protectedSourcePath && await pathsShareFileIdentity(latestWritePath, protectedSourcePath)) {
        return { saved: false, path: filePath, reason: 'protected-source' }
      }
      try {
        if ((await fs.stat(writePath)).nlink > 1) {
          return { saved: false, path: filePath, reason: 'hardlink', conflict: await readFile(writePath, expectedEncoding) }
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
        return { saved: false, path: filePath, reason: 'conflict', conflict: null }
      }
      await fs.rename(tempPath, writePath)
      return { saved: true, path: filePath, revision: nextRevision }
    } finally {
      if (tempCreated) {
        try { await fs.unlink(tempPath) } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'ENOENT') console.warn(`Could not remove save temporary file ${tempPath}:`, error)
        }
      }
    }
  })
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

async function readJson<T>(file: string, fallback: T, maxBytes?: number): Promise<T> {
  try {
    if (maxBytes !== undefined && (await fs.stat(file)).size > maxBytes) return fallback
    return JSON.parse(await fs.readFile(file, 'utf-8')) as T
  } catch {
    return fallback
  }
}

/** Serialise writes per target, use unique temporary paths, and atomically replace the destination. */
async function writeJson(file: string, data: unknown, maxBytes?: number): Promise<void> {
  const previous = writeQueues.get(file) ?? Promise.resolve()
  const next = previous
    .catch(() => undefined)
    .then(async () => {
      await fs.mkdir(path.dirname(file), { recursive: true })
      const tmp = `${file}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`
      const serialized = JSON.stringify(data, null, 2)
      if (maxBytes !== undefined && Buffer.byteLength(serialized, 'utf8') > maxBytes) {
        throw new Error('Session recovery data exceeds the supported 208 MiB serialized limit.')
      }
      let tempCreated = false
      try {
        const handle = await fs.open(tmp, 'wx', 0o600)
        tempCreated = true
        try {
          await handle.writeFile(serialized, 'utf8')
          await handle.sync()
        } finally {
          await handle.close()
        }
        await fs.rename(tmp, file)
      } finally {
        if (tempCreated) {
          try { await fs.unlink(tmp) } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== 'ENOENT') console.warn(`Could not remove JSON temporary file ${tmp}:`, error)
          }
        }
      }
    })
  writeQueues.set(file, next)
  try {
    await next
  } finally {
    if (writeQueues.get(file) === next) writeQueues.delete(file)
  }
}

/** Run one mutation at a time for every resolved file identity it touches. */
async function withSerializedFileMutation<T>(files: readonly string[], operation: () => Promise<T>): Promise<T> {
  void files
  // Queue synchronously before any path-resolution await. This deliberately
  // serialises all editor-originated file mutations: saves are short, while a
  // global ordering also covers directory moves and every path alias.
  const previous = fileMutationTail
  const result = previous.catch(() => undefined).then(operation)
  const tail = result.then(() => undefined, () => undefined)
  fileMutationTail = tail
  return result
}

async function withSerializedFileSave<T>(file: string, operation: () => Promise<T>): Promise<T> {
  return withSerializedFileMutation([file], operation)
}

/** Preserve the logical target of a symlink while still replacing atomically. */
async function fileWriteTarget(file: string): Promise<string> {
  try { return await fs.realpath(file) }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    return path.resolve(file)
  }
}

/** Compare resolved paths and, where present, their underlying file identity. */
async function pathsShareFileIdentity(left: string, right: string): Promise<boolean> {
  const [leftTarget, rightTarget] = await Promise.all([fileWriteTarget(left), fileWriteTarget(right)])
  if (path.resolve(leftTarget) === path.resolve(rightTarget)) return true
  try {
    const [leftStat, rightStat] = await Promise.all([fs.stat(leftTarget), fs.stat(rightTarget)])
    return leftStat.dev === rightStat.dev && leftStat.ino === rightStat.ino
  } catch {
    return false
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
    locale: raw.locale === 'en-US' ? 'en-US' : 'zh-CN',
    fontSize: asFiniteInt(raw.fontSize, DEFAULT_SETTINGS.fontSize, 8, 40),
    tabSize: asFiniteInt(raw.tabSize, DEFAULT_SETTINGS.tabSize, 1, 16),
    insertSpaces: typeof raw.insertSpaces === 'boolean' ? raw.insertSpaces : DEFAULT_SETTINGS.insertSpaces,
    theme: raw.theme === 'light' || raw.theme === 'dark' ? raw.theme : DEFAULT_SETTINGS.theme,
    wordWrap: typeof raw.wordWrap === 'boolean' ? raw.wordWrap : DEFAULT_SETTINGS.wordWrap,
    showLineNumbers: typeof raw.showLineNumbers === 'boolean' ? raw.showLineNumbers : DEFAULT_SETTINGS.showLineNumbers,
    showMinimap: typeof raw.showMinimap === 'boolean' ? raw.showMinimap : DEFAULT_SETTINGS.showMinimap,
    showIndentGuides: typeof raw.showIndentGuides === 'boolean' ? raw.showIndentGuides : DEFAULT_SETTINGS.showIndentGuides,
    showWhitespace: typeof raw.showWhitespace === 'boolean' ? raw.showWhitespace : DEFAULT_SETTINGS.showWhitespace,
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
    showOutline: typeof raw.showOutline === 'boolean' ? raw.showOutline : DEFAULT_SETTINGS.showOutline,
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
    ...(typeof raw.line_numbers === 'boolean' ? { showLineNumbers: raw.line_numbers } : {}),
    ...(typeof raw.draw_white_space === 'string'
      ? { showWhitespace: raw.draw_white_space === 'all' || raw.draw_white_space === 'selection' }
      : {}),
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

function parseSublimeBuild(value: unknown, sourcePath: string): BuildSystem {
  if (!value || typeof value !== 'object') throw new Error('The selected .sublime-build file must be a JSON object.')
  const raw = value as { name?: unknown; cmd?: unknown; shell_cmd?: unknown; working_dir?: unknown; file_regex?: unknown; env?: unknown; variants?: unknown }
  const cmd = Array.isArray(raw.cmd) && raw.cmd.every((part) => typeof part === 'string') ? raw.cmd as string[] : []
  const shell = typeof raw.shell_cmd === 'string' ? raw.shell_cmd : ''
  const command = cmd[0] ?? shell
  if (!command) throw new Error('The Sublime build file requires cmd or shell_cmd.')
  return {
    name: typeof raw.name === 'string' ? raw.name.slice(0, 100) : path.basename(sourcePath, '.sublime-build').slice(0, 100),
    command: command.slice(0, 1_000),
    args: cmd.slice(1, 51),
    ...(shell ? { shell: true } : {}),
    ...(typeof raw.working_dir === 'string' ? { workingDirectory: raw.working_dir.slice(0, 500) } : {}),
    ...(typeof raw.file_regex === 'string' ? { fileRegex: raw.file_regex.slice(0, 1_000) } : {}),
    ...(Object.keys(sanitizeBuildEnv(raw.env)).length > 0 ? { env: sanitizeBuildEnv(raw.env) } : {}),
    variants: Array.isArray(raw.variants)
      ? raw.variants.flatMap((variant) => {
          if (!variant || typeof variant !== 'object') return []
          const item = variant as { name?: unknown; cmd?: unknown; shell_cmd?: unknown; working_dir?: unknown; file_regex?: unknown; env?: unknown }
          const variantCmd = Array.isArray(item.cmd) && item.cmd.every((part) => typeof part === 'string') ? item.cmd as string[] : []
          const variantShell = typeof item.shell_cmd === 'string' ? item.shell_cmd : ''
          const variantCommand = variantCmd[0] ?? variantShell
          if (!variantCommand || typeof item.name !== 'string') return []
          return [{ name: item.name.slice(0, 100), command: variantCommand.slice(0, 1_000), args: variantCmd.slice(1, 51), ...(variantShell ? { shell: true } : {}), ...(typeof item.working_dir === 'string' ? { workingDirectory: item.working_dir.slice(0, 500) } : {}), ...(typeof item.file_regex === 'string' ? { fileRegex: item.file_regex.slice(0, 1_000) } : {}), ...(Object.keys(sanitizeBuildEnv(item.env)).length > 0 ? { env: sanitizeBuildEnv(item.env) } : {}) }]
        }).slice(0, 20)
      : []
  }
}

const SUBLIME_COMMAND_MAP: Record<string, string> = {
  save: 'save', save_as: 'save-as', close_file: 'close-tab', close_all: 'close-all-tabs',
  reopen_last_file: 'reopen-tab', next_view: 'next-tab', prev_view: 'prev-tab',
  goto_line: 'go-to-line',
  toggle_comment: 'toggle-comment', toggle_block_comment: 'toggle-block-comment',
  move_line_up: 'move-line-up', move_line_down: 'move-line-down', duplicate_line: 'duplicate-selection',
  delete_line: 'delete-line', sort_lines: 'sort-lines', upper_case: 'to-upper-case', lower_case: 'to-lower-case',
  join_lines: 'join-lines', indent: 'indent-selection', unindent: 'outdent-selection',
  toggle_setting: 'toggle-word-wrap', build: 'build', toggle_side_bar: 'toggle-sidebar',
  toggle_distraction_free: 'toggle-distraction-free', toggle_bookmark: 'toggle-bookmark',
  next_bookmark: 'next-bookmark', prev_bookmark: 'prev-bookmark', show_scope_name: 'goto-symbol'
}

function sublimeKeyToLumen(key: string): string | null {
  const parts = key.trim().toLowerCase().split('+').map((part) => part.trim()).filter(Boolean)
  if (parts.length === 0) return null
  const mapped = parts.map((part) => part === 'ctrl' || part === 'super' ? 'Mod' : part === 'alt' ? 'Alt' : part === 'shift' ? 'Shift' : part === 'enter' ? 'Enter' : part.length === 1 ? part.toUpperCase() : part)
  return mapped.join('+')
}

function parseSublimeKeymap(value: unknown): { rules: KeyBindingRule[]; skipped: number } {
  if (!Array.isArray(value)) throw new Error('The selected .sublime-keymap file must be a JSON array.')
  const rules: KeyBindingRule[] = []
  let skipped = 0
  for (const item of value.slice(0, 500)) {
    if (!item || typeof item !== 'object') { skipped += 1; continue }
    const source = item as { keys?: unknown; command?: unknown; context?: unknown }
    if (typeof source.command !== 'string' || !SUBLIME_COMMAND_MAP[source.command] || !Array.isArray(source.keys)) { skipped += 1; continue }
    const keys = source.keys.map((key) => typeof key === 'string' ? sublimeKeyToLumen(key) : null).filter((key): key is string => !!key)
    if (keys.length === 0) { skipped += 1; continue }
    rules.push({ keys: keys.length === 1 ? keys[0] : keys, command: SUBLIME_COMMAND_MAP[source.command] })
  }
  return { rules: rules.slice(0, 200), skipped }
}

function sanitizeSession(value: unknown, rejectOversizedText = false): Session {
  const raw = value && typeof value === 'object' ? (value as Partial<Session>) : {}
  if (rejectOversizedText && Array.isArray(raw.openFiles) && raw.openFiles.length > MAX_SESSION_OPEN_FILES) {
    throw new Error(`Session recovery supports at most ${MAX_SESSION_OPEN_FILES} open files.`)
  }
  const recoveryBudget = rejectOversizedText ? MAX_SESSION_RECOVERY_BYTES : MAX_SESSION_SERIALIZED_BYTES
  let recoveryBytes = 0
  const recoveryText = (candidate: unknown): string | undefined => {
    if (typeof candidate !== 'string') return undefined
    const remaining = recoveryBudget - recoveryBytes
    const bytes = jsonStringUtf8ByteLength(candidate, remaining)
    if (bytes > remaining) {
      if (rejectOversizedText) throw new Error('Session recovery text exceeds the supported 200 MiB aggregate limit.')
      return undefined
    }
    recoveryBytes += bytes
    return candidate
  }
  const openFiles = Array.isArray(raw.openFiles)
    ? raw.openFiles
        .filter((item): item is Session['openFiles'][number] => !!item && typeof item === 'object')
        .slice(0, MAX_SESSION_OPEN_FILES)
        .map((file) => {
          const draft = recoveryText(file.draft)
          const recoveryContent = recoveryText(file.recoveryContent)
          const views = sanitizeSessionViewStates(file.views)
          const diskEncoding = isTextEncoding(file.diskEncoding) ? file.diskEncoding : undefined
          return {
            path: typeof file.path === 'string' && path.isAbsolute(file.path) ? file.path : null,
            name: typeof file.name === 'string' ? file.name.slice(0, 255) : 'Untitled',
            ...(file.pinned === true ? { pinned: true } : {}),
            language: typeof file.language === 'string' ? file.language.slice(0, 100) : 'Plain Text',
            languageLocked: file.languageLocked === true,
            ...(draft !== undefined ? { draft } : {}),
            ...(recoveryContent !== undefined ? { recoveryContent } : {}),
            ...(typeof file.formatDirty === 'boolean' ? { formatDirty: file.formatDirty } : {}),
            ...(file.baseRevision === null || (typeof file.baseRevision === 'string' && /^sha256:[a-f0-9]{64}$/.test(file.baseRevision))
              ? { baseRevision: file.baseRevision }
              : {}),
            ...(isTextEncoding(file.encoding) ? { encoding: file.encoding } : {}),
            ...(diskEncoding ? { diskEncoding } : {}),
            ...(file.encodingLocked === true && diskEncoding ? { encodingLocked: true } : {}),
            ...(file.encodingIssue === 'invalid-bytes' || file.encodingIssue === 'uncertain' ? { encodingIssue: file.encodingIssue } : {}),
            ...(file.eol === 'LF' || file.eol === 'CRLF' || file.eol === 'CR' ? { eol: file.eol } : {}),
            ...(file.eolOverride === 'LF' || file.eolOverride === 'CRLF' || file.eolOverride === 'CR' ? { eolOverride: file.eolOverride } : {}),
            ...(Array.isArray(file.bookmarks)
              ? { bookmarks: file.bookmarks.filter((line): line is number => typeof line === 'number' && Number.isInteger(line) && line > 0 && line <= 10_000_000).slice(0, 10_000) }
              : {}),
            ...(views.length > 0 ? { views } : {})
          }
        })
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

async function searchWorkspace(request: WorkspaceSearchRequest, requireCertainEncoding = false): Promise<WorkspaceMatch[]> {
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
        if (opened.isBinary || opened.isTooLarge
          || opened.encodingIssue === 'invalid-bytes'
          || (requireCertainEncoding && opened.encodingIssue !== undefined)) continue
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
  const undoFiles = new Map<string, { content: Buffer; expectedRevision: string }>()

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
        // Never let a bulk write act on bytes whose interpretation was only a
        // heuristic or contained replacements. The user must first confirm an
        // encoding in a normal editor tab.
        if (opened.isBinary || opened.isTooLarge || opened.encodingIssue !== undefined) continue
        let count = 0
        const next = opened.content.replace(re, (...args: unknown[]) => {
          count += 1
          if (request.useRegex) {
            const groups = args.slice(1, -2).map((part) => String(part ?? ''))
            return request.replacement.replace(/\$(\d+|&)/g, (_token, group: string) => group === '&' ? String(args[0]) : (groups[Number(group) - 1] ?? ''))
          }
          return request.replacement
        })
        if (count === 0 || opened.revision === null) continue
        const original = await fs.readFile(file)
        if (fileRevision(original) !== opened.revision) continue
        const nextBytes = encodeText(next, { encoding: opened.encoding, eol: opened.eol })
        const result = await saveFileBytes(file, nextBytes, opened.revision)
        if (!result.saved || !result.revision) continue
        undoFiles.set(file, { content: original, expectedRevision: result.revision })
        changedFiles += 1
        replacements += count
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
  // Keep the preview consistent with the write pass: uncertain decodes are
  // searchable, but they are never eligible for an unattended replacement.
  const matches = await searchWorkspace(request, true)
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
  const total = transaction.files.size
  for (const [file, snapshot] of [...transaction.files]) {
    const result = await saveFileBytes(file, snapshot.content, snapshot.expectedRevision)
    if (!result.saved) {
      throw new Error(`Cannot undo replacement in ${file} because the file changed afterwards.`)
    }
    transaction.files.delete(file)
  }
  replaceUndoTransactions.delete(token)
  return { files: total, replacements: 0 }
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

function sanitizeSessionViewStates(value: unknown): SessionViewState[] {
  if (!Array.isArray(value)) return []
  const views: SessionViewState[] = []
  const seenGroups = new Set<number>()
  for (const item of value) {
    if (!item || typeof item !== 'object') continue
    const source = item as { group?: unknown; selections?: unknown; mainIndex?: unknown; scrollTop?: unknown; scrollLeft?: unknown }
    if (typeof source.group !== 'number' || !Number.isInteger(source.group) || source.group < 0 || source.group > 3 || seenGroups.has(source.group)) continue
    const selections = Array.isArray(source.selections)
      ? source.selections.flatMap((selection) => {
          if (!selection || typeof selection !== 'object') return []
          const range = selection as { anchor?: unknown; head?: unknown }
          if (typeof range.anchor !== 'number' || !Number.isInteger(range.anchor) || range.anchor < 0 || range.anchor > 200_000_000) return []
          if (typeof range.head !== 'number' || !Number.isInteger(range.head) || range.head < 0 || range.head > 200_000_000) return []
          return [{ anchor: range.anchor, head: range.head }]
        }).slice(0, 100)
      : []
    if (selections.length === 0) continue
    views.push({
      group: source.group,
      selections,
      mainIndex: asFiniteInt(source.mainIndex, 0, 0, selections.length - 1),
      scrollTop: asFiniteInt(source.scrollTop, 0, 0, 100_000_000),
      scrollLeft: asFiniteInt(source.scrollLeft, 0, 0, 100_000_000)
    })
    seenGroups.add(source.group)
  }
  return views
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
      if (opened.isBinary || opened.isTooLarge || opened.encodingIssue === 'invalid-bytes') continue
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
      if (opened.isBinary || opened.isTooLarge || opened.encodingIssue === 'invalid-bytes') continue
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
    const [{ stdout: branch }, { stdout: porcelain }, remoteResult] = await Promise.all([
      execFileAsync('git', ['-C', root, 'branch', '--show-current'], { timeout: 10_000, maxBuffer: 64 * 1024 }),
      execFileAsync('git', ['-C', root, 'status', '--porcelain=v1', '-z'], { timeout: 10_000, maxBuffer: 8 * 1024 * 1024 }),
      execFileAsync('git', ['-C', root, 'config', '--get-regexp', '^remote[.].*[.](url|pushurl)$'], { timeout: 10_000, maxBuffer: 512 * 1024 }).catch(() => ({ stdout: '', stderr: '' }))
    ])
    const entries = porcelain.split('\0').filter(Boolean).flatMap((entry) => {
      if (entry.length < 4) return []
      return [{ indexStatus: entry[0], worktreeStatus: entry[1], path: entry.slice(3) }]
    })
    const branchName = branch.trim()
    let tracking = parseGitTracking('', '')
    if (branchName) {
      const [{ stdout: mergeRef }, { stdout: remoteName }, { stdout: upstreamName }] = await Promise.all([
        execFileAsync('git', ['-C', root, 'config', '--get', `branch.${branchName}.merge`], { timeout: 10_000, maxBuffer: 64 * 1024 }).catch(() => ({ stdout: '', stderr: '' })),
        execFileAsync('git', ['-C', root, 'config', '--get', `branch.${branchName}.remote`], { timeout: 10_000, maxBuffer: 64 * 1024 }).catch(() => ({ stdout: '', stderr: '' })),
        execFileAsync('git', ['-C', root, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'], { timeout: 10_000, maxBuffer: 64 * 1024 }).catch(() => ({ stdout: '', stderr: '' }))
      ])
      const upstream = upstreamName.trim()
      const counts = upstream
        ? await execFileAsync('git', ['-C', root, 'rev-list', '--left-right', '--count', 'HEAD...@{upstream}'], { timeout: 10_000, maxBuffer: 64 * 1024 }).catch(() => ({ stdout: '', stderr: '' }))
        : { stdout: '', stderr: '' }
      tracking = parseGitTracking(upstream, counts.stdout, remoteName.trim(), mergeRef.trim())
    }
    return {
      available: true,
      branch: branchName || '(detached)',
      entries,
      tracking,
      remotes: parseGitRemoteLines(remoteResult.stdout)
    }
  } catch (error) {
    const gitError = error as { code?: unknown; stderr?: unknown; message?: unknown }
    const detail = `${typeof gitError.stderr === 'string' ? gitError.stderr : ''} ${typeof gitError.message === 'string' ? gitError.message : ''}`
    if (gitError.code === 128 && /not a git repository|不是一个 git 仓库|非 git 仓库/i.test(detail)) return { available: false, entries: [] }
    throw error
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

function languageServerKey(senderId: number, root: string, config: { command: string; args: string[] }): string {
  const identity = JSON.stringify([senderId, path.resolve(root), config.command, config.args])
  return `lsp-${createHash('sha256').update(identity).digest('hex')}`
}

function boundedLanguageServerText(text: string, limit = MAX_LANGUAGE_SERVER_LOG_CHARS): string {
  if (text.length <= limit) return text
  const suffix = '\n[Language server log truncated]'
  return `${text.slice(0, Math.max(0, limit - suffix.length))}${suffix}`
}

/** Bound UTF-8 text without first allocating a Buffer for the entire input. */
function boundedLanguageServerUtf8Text(text: string, limit: number): string {
  if (limit <= 0) return ''
  if (Buffer.byteLength(text, 'utf8') <= limit) return text
  let low = 0
  let high = Math.min(text.length, limit)
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    if (Buffer.byteLength(text.slice(0, middle), 'utf8') <= limit) low = middle
    else high = middle - 1
  }
  // Do not split a valid surrogate pair at the truncation boundary.
  if (low > 0 && low < text.length &&
      text.charCodeAt(low - 1) >= 0xd800 && text.charCodeAt(low - 1) <= 0xdbff &&
      text.charCodeAt(low) >= 0xdc00 && text.charCodeAt(low) <= 0xdfff) low -= 1
  // Materialise the bounded slice so a short queued log cannot retain an
  // otherwise huge LSP payload string until the next flush.
  return Buffer.from(text.slice(0, low), 'utf8').toString('utf8')
}

function languageServerErrorMessage(error: unknown, fallback: string): string {
  const message = error instanceof Error && error.message ? error.message : fallback
  return boundedLanguageServerText(message, 2_000)
}

function isLanguageServerObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function summarizeLanguageServerCapabilities(capabilities: Record<string, unknown>): string[] {
  const names = Object.keys(capabilities)
    .filter((name) => Boolean(capabilities[name]))
    .sort()
  const summary: string[] = []
  let totalChars = 0
  for (const name of names) {
    if (summary.length >= MAX_LANGUAGE_SERVER_CAPABILITY_NAMES) break
    const addedChars = name.length + (summary.length === 0 ? 0 : 2)
    if (addedChars > MAX_LANGUAGE_SERVER_CAPABILITY_CHARS - totalChars) continue
    summary.push(name)
    totalChars += addedChars
  }
  return summary
}

function cloneLanguageServerDocuments(
  documents: Map<string, LanguageServerDocumentSnapshot>
): Map<string, LanguageServerDocumentSnapshot> {
  return new Map(
    [...documents].map(([uri, document]) => [uri, { ...document }] as const)
  )
}

function rememberLanguageServerTombstone(
  key: string,
  descriptor: LanguageServerRestartDescriptor
): void {
  if (descriptor.sender.isDestroyed()) return
  const previous = languageServerTombstones.get(key)
  const candidates = previous?.sender === descriptor.sender
    ? [...previous.documents, ...descriptor.documents]
    : [...descriptor.documents]
  const documents = new Map<string, LanguageServerDocumentSnapshot>()
  let documentChars = 0
  for (const [uri, document] of candidates.reverse()) {
    if (documents.has(uri)) continue
    const chars = uri.length + document.content.length + document.languageId.length
    if (documents.size >= MAX_LANGUAGE_SERVER_TOMBSTONE_DOCUMENTS ||
        chars > MAX_LANGUAGE_SERVER_TOMBSTONE_CHARS - documentChars) continue
    documents.set(uri, { ...document })
    documentChars += chars
  }
  languageServerTombstones.delete(key)
  languageServerTombstones.set(key, {
    sender: descriptor.sender,
    root: descriptor.root,
    config: { command: descriptor.config.command, args: [...descriptor.config.args] },
    documents
  })

  const ownedKeys = [...languageServerTombstones]
    .filter(([, candidate]) => candidate.sender === descriptor.sender)
    .map(([candidateKey]) => candidateKey)
  for (const staleKey of ownedKeys.slice(0, -MAX_LANGUAGE_SERVER_TOMBSTONES_PER_SENDER)) {
    languageServerTombstones.delete(staleKey)
  }
}

function languageServerDescriptor(server: PersistentLanguageServer): LanguageServerRestartDescriptor {
  return {
    sender: server.sender,
    root: server.root,
    config: { command: server.config.command, args: [...server.config.args] },
    documents: cloneLanguageServerDocuments(server.documents)
  }
}

function sendLanguageServerStatusEvent(
  sender: Electron.WebContents,
  event: LanguageServerStatusEvent
): void {
  if (sender.isDestroyed()) return
  try { sender.send(IPC.languageServerStatus, event) } catch {
    // The renderer may be between its destruction signal and final teardown.
  }
}

function sendLanguageServerStatus(
  server: PersistentLanguageServer,
  state: LanguageServerStatusEvent['state'],
  message?: string
): void {
  const event: LanguageServerStatusEvent = {
    key: server.configKey,
    root: server.root,
    command: server.config.command,
    state,
    ...(server.child.pid === undefined ? {} : { pid: server.child.pid }),
    ...(message ? { message: boundedLanguageServerText(message, 2_000) } : {}),
    ...(state === 'running' && server.capabilities !== undefined
      ? { capabilities: server.capabilities }
      : {})
  }
  sendLanguageServerStatusEvent(server.sender, event)
}

function sendLanguageServerLogEvent(
  sender: Electron.WebContents,
  event: LanguageServerLogEvent
): void {
  if (sender.isDestroyed()) return
  try { sender.send(IPC.languageServerLog, event) } catch {
    // Avoid noisy send-after-destroy warnings during renderer teardown.
  }
}

function resetLanguageServerLogRateWindow(server: PersistentLanguageServer, now: number): void {
  if (now < server.logRateStartedAt || now - server.logRateStartedAt >= 1_000) {
    server.logRateStartedAt = now
    server.logRateBytes = 0
  }
}

function flushLanguageServerLogs(server: PersistentLanguageServer): void {
  if (server.logFlushTimer !== null) {
    clearTimeout(server.logFlushTimer)
    server.logFlushTimer = null
  }
  const buckets = [...server.logBuckets.values()]
  const bufferedBytes = server.logBufferedBytes
  const droppedMessages = server.logDroppedMessages
  server.logBuckets.clear()
  server.logBufferedBytes = 0
  server.logDroppedMessages = 0

  for (const bucket of buckets) {
    const text = bucket.chunks.join('')
    if (!text) continue
    sendLanguageServerLogEvent(server.sender, {
      key: server.configKey,
      root: server.root,
      command: server.config.command,
      stream: bucket.stream,
      level: bucket.level,
      text,
      timestamp: Date.now()
    })
  }

  if (droppedMessages > 0) {
    const now = Date.now()
    resetLanguageServerLogRateWindow(server, now)
    const available = Math.min(
      LANGUAGE_SERVER_LOG_SENTINEL_RESERVE_BYTES,
      MAX_LANGUAGE_SERVER_LOG_BATCH_BYTES - bufferedBytes,
      MAX_LANGUAGE_SERVER_LOG_BYTES_PER_SECOND - server.logRateBytes
    )
    const sentinel = boundedLanguageServerUtf8Text(
      `\n[${droppedMessages} language-server log message${droppedMessages === 1 ? '' : 's'} truncated or dropped]\n`,
      available
    )
    if (sentinel) {
      server.logRateBytes += Buffer.byteLength(sentinel, 'utf8')
      sendLanguageServerLogEvent(server.sender, {
        key: server.configKey,
        root: server.root,
        command: server.config.command,
        stream: 'server',
        level: 'warning',
        text: sentinel,
        timestamp: now
      })
    }
  }
}

function sendLanguageServerLog(
  server: PersistentLanguageServer,
  stream: LanguageServerLogEvent['stream'],
  level: LanguageServerLogEvent['level'],
  text: string
): void {
  if (!text || server.cleaned) return
  const now = Date.now()
  resetLanguageServerLogRateWindow(server, now)
  const available = Math.max(0, Math.min(
    MAX_LANGUAGE_SERVER_LOG_BATCH_BYTES - LANGUAGE_SERVER_LOG_SENTINEL_RESERVE_BYTES - server.logBufferedBytes,
    MAX_LANGUAGE_SERVER_LOG_BYTES_PER_SECOND - LANGUAGE_SERVER_LOG_SENTINEL_RESERVE_BYTES - server.logRateBytes
  ))
  const bounded = boundedLanguageServerUtf8Text(text, available)
  const acceptedBytes = Buffer.byteLength(bounded, 'utf8')
  const key = `${stream}:${level}`
  const bucket = server.logBuckets.get(key)
  if (bounded && (!bucket || bucket.chunks.length < MAX_LANGUAGE_SERVER_LOG_CHUNKS_PER_BUCKET)) {
    const target = bucket ?? { stream, level, chunks: [] }
    target.chunks.push(bounded)
    server.logBuckets.set(key, target)
    server.logBufferedBytes += acceptedBytes
    server.logRateBytes += acceptedBytes
  } else if (bounded) {
    server.logDroppedMessages = Math.min(Number.MAX_SAFE_INTEGER, server.logDroppedMessages + 1)
  }
  if (acceptedBytes < Buffer.byteLength(text, 'utf8')) {
    server.logDroppedMessages = Math.min(Number.MAX_SAFE_INTEGER, server.logDroppedMessages + 1)
  }
  if (server.logFlushTimer === null) {
    server.logFlushTimer = setTimeout(() => flushLanguageServerLogs(server), LANGUAGE_SERVER_LOG_FLUSH_MS)
    server.logFlushTimer.unref?.()
  }
}

function logLanguageServerWindowMessage(
  server: PersistentLanguageServer,
  message: Record<string, unknown>
): void {
  if (message.method !== 'window/logMessage' && message.method !== 'window/showMessage') return
  const params = message.params as { type?: unknown; message?: unknown } | undefined
  if (typeof params?.message !== 'string') return
  const level: LanguageServerLogEvent['level'] = params.type === 1
    ? 'error'
    : params.type === 2
      ? 'warning'
      : 'info'
  sendLanguageServerLog(server, 'server', level, params.message)
}

function terminateLanguageServerProcess(server: PersistentLanguageServer, force = false): void {
  const signal = force ? 'SIGKILL' : 'SIGTERM'
  if (process.platform !== 'win32' && server.processGroupId !== undefined) {
    try {
      process.kill(-server.processGroupId, signal)
      return
    } catch (error) {
      // ESRCH means the complete process group is already gone. Other errors
      // retain a safe direct-child fallback below.
      if ((error as NodeJS.ErrnoException).code === 'ESRCH') return
    }
  }
  // A child close only proves that the group leader exited; it is deliberately
  // checked after the POSIX group signal above.
  if (server.processCloseObserved || server.processId === undefined) return
  if (process.platform === 'win32') {
    execFile(
      'taskkill',
      ['/PID', String(server.processId), '/T', '/F'],
      { windowsHide: true, timeout: LANGUAGE_SERVER_CLOSE_TIMEOUT_MS, maxBuffer: 64 * 1024 },
      (error) => {
        if (!error || server.processCloseObserved) return
        try { server.child.kill() } catch {
          // The direct child may already have exited.
        }
      }
    )
    return
  }
  try { server.child.kill(signal) } catch {
    // The process may already have exited between the state check and kill.
  }
}

function cleanupLanguageServer(
  server: PersistentLanguageServer,
  state: 'stopped' | 'error',
  message?: string
): void {
  if (server.cleaned) return
  server.flushStderr()
  flushLanguageServerLogs(server)
  server.cleaned = true
  if (server.initializeTimer !== null) {
    clearTimeout(server.initializeTimer)
    server.initializeTimer = null
  }
  if (server.logFlushTimer !== null) {
    clearTimeout(server.logFlushTimer)
    server.logFlushTimer = null
  }
  if (server.writeDrainListener) {
    server.child.stdin.off('drain', server.writeDrainListener)
    server.writeDrainListener = undefined
  }
  server.writeQueue.length = 0
  server.queuedWriteBytes = 0
  if (languageServers.get(server.configKey) === server) languageServers.delete(server.configKey)
  if (server.restartable) {
    rememberLanguageServerTombstone(server.configKey, languageServerDescriptor(server))
  }
  server.resolveReady()
  sendLanguageServerStatus(server, state, message)

  const stoppedMessage = { error: { message: message ?? 'Language server stopped.' } }
  const pending = [...server.pending.values()]
  server.pending.clear()
  for (const settle of pending) {
    try { settle(stoppedMessage) } catch {
      // One consumer must not prevent the remaining pending requests settling.
    }
  }
}

function failLanguageServer(
  server: PersistentLanguageServer,
  message: string,
  log = true
): void {
  if (server.cleaned) return
  if (log) sendLanguageServerLog(server, 'server', 'error', message)
  if (server.stopping) cleanupLanguageServer(server, 'stopped')
  else cleanupLanguageServer(server, 'error', message)
  void trackLanguageServerTermination(server).catch(() => undefined)
}

function pumpLanguageServerWriteQueue(server: PersistentLanguageServer): void {
  if (server.cleaned || server.writeInProgress) return
  const frame = server.writeQueue.shift()
  if (!frame) return
  server.writeInProgress = true
  let callbackFinished = false
  let drainFinished = true
  let settled = false
  const settle = (error?: Error | null): void => {
    if (settled || !callbackFinished || !drainFinished) return
    settled = true
    if (server.writeDrainListener) {
      server.child.stdin.off('drain', server.writeDrainListener)
      server.writeDrainListener = undefined
    }
    server.queuedWriteBytes = Math.max(0, server.queuedWriteBytes - frame.byteLength)
    server.writeInProgress = false
    if (error) {
      failLanguageServer(server, languageServerErrorMessage(error, 'Could not write to the language server.'))
      return
    }
    pumpLanguageServerWriteQueue(server)
  }
  try {
    const accepted = server.child.stdin.write(frame, (error?: Error | null) => {
      callbackFinished = true
      if (error) drainFinished = true
      settle(error)
    })
    if (!accepted) {
      drainFinished = false
      const onDrain = (): void => {
        drainFinished = true
        settle()
      }
      server.writeDrainListener = onDrain
      server.child.stdin.once('drain', onDrain)
    }
  } catch (error) {
    callbackFinished = true
    drainFinished = true
    settle(error instanceof Error ? error : new Error('Could not write to the language server.'))
  }
}

/** Encode and enqueue one ordered message, terminating on failure or overflow. */
function writeLanguageServerMessage(
  server: PersistentLanguageServer,
  payload: Record<string, unknown>
): boolean {
  if (server.cleaned || !server.child.stdin.writable || server.child.stdin.destroyed) {
    failLanguageServer(server, 'Language server input is no longer writable.')
    return false
  }
  let frame: Buffer
  try {
    frame = encodeLspMessage(payload)
  } catch (error) {
    failLanguageServer(server, languageServerErrorMessage(error, 'Could not encode an LSP message.'))
    return false
  }
  if (frame.byteLength > MAX_LANGUAGE_SERVER_STDIN_QUEUE_BYTES - server.queuedWriteBytes) {
    failLanguageServer(server, `Language server input exceeded the ${MAX_LANGUAGE_SERVER_STDIN_QUEUE_BYTES}-byte queue limit.`)
    return false
  }
  try {
    server.writeQueue.push(frame)
    server.queuedWriteBytes += frame.byteLength
    pumpLanguageServerWriteQueue(server)
    return true
  } catch (error) {
    failLanguageServer(server, languageServerErrorMessage(error, 'Could not write to the language server.'))
    return false
  }
}

function bindLanguageServerSenderCleanup(sender: Electron.WebContents): void {
  if (languageServerSenderCleanupBound.has(sender)) return
  languageServerSenderCleanupBound.add(sender)
  sender.once('destroyed', () => {
    for (const [key, restart] of languageServerRestarts) {
      if (restart.descriptor.sender !== sender) continue
      restart.cancelled = true
      languageServerTombstones.delete(key)
    }
    for (const [key, descriptor] of languageServerTombstones) {
      if (descriptor.sender === sender) languageServerTombstones.delete(key)
    }
    for (const server of languageServers.values()) {
      if (server.sender !== sender) continue
      server.restartable = false
      server.stopping = true
      cleanupLanguageServer(server, 'stopped')
      void trackLanguageServerTermination(server).catch(() => undefined)
    }
  })
}

function languageServerPosition(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? Math.min(Number.MAX_SAFE_INTEGER - 1, Math.floor(value))
    : 0
}

function lspDiagnostics(
  server: PersistentLanguageServer,
  message: Record<string, unknown>
): { event: LanguageServerDiagnosticEvent; estimatedBytes: number; truncated: boolean } | null {
  if (message.method !== 'textDocument/publishDiagnostics') return null
  const params = message.params as { uri?: unknown; diagnostics?: unknown } | undefined
  if (typeof params?.uri !== 'string' || params.uri.length > MAX_LANGUAGE_SERVER_DIAGNOSTIC_PATH_CHARS ||
      !params.uri.startsWith('file:') || !Array.isArray(params.diagnostics)) return null
  let filePath: string
  try { filePath = fileURLToPath(params.uri) } catch { return null }
  filePath = path.resolve(filePath)
  if (!isInside(server.root, filePath)) return null

  const diagnostics: LanguageServerDiagnosticEvent['diagnostics'] = []
  let messageBytes = 0
  let truncated = params.diagnostics.length > MAX_LANGUAGE_SERVER_DIAGNOSTICS
  const inspected = Math.min(params.diagnostics.length, MAX_LANGUAGE_SERVER_DIAGNOSTICS)
  for (let index = 0; index < inspected; index += 1) {
    const item = params.diagnostics[index] as { range?: unknown; severity?: unknown; message?: unknown } | null
    if (!item || typeof item !== 'object') continue
    const remainingBytes = MAX_LANGUAGE_SERVER_DIAGNOSTIC_MESSAGE_BYTES - messageBytes
    if (remainingBytes <= 0) {
      truncated = true
      break
    }
    const rawMessage = typeof item.message === 'string' ? item.message.slice(0, 2_000) : 'Language server diagnostic'
    const diagnosticMessage = boundedLanguageServerUtf8Text(rawMessage, remainingBytes)
    const bytes = Buffer.byteLength(diagnosticMessage, 'utf8')
    if (!diagnosticMessage) {
      truncated = true
      break
    }
    if (bytes < Buffer.byteLength(rawMessage, 'utf8')) truncated = true
    messageBytes += bytes
    const range = item.range as { start?: { line?: unknown; character?: unknown }; end?: { line?: unknown; character?: unknown } } | undefined
    const startLine = languageServerPosition(range?.start?.line)
    const startCharacter = languageServerPosition(range?.start?.character)
    diagnostics.push({
      line: startLine + 1,
      column: startCharacter + 1,
      endLine: languageServerPosition(range?.end?.line ?? startLine) + 1,
      endColumn: languageServerPosition(range?.end?.character ?? startCharacter) + 1,
      severity: item.severity === 2 ? 'warning' : item.severity === 3 || item.severity === 4 ? 'info' : 'error',
      message: diagnosticMessage
    })
  }
  return {
    event: { filePath, diagnostics },
    estimatedBytes: Buffer.byteLength(filePath, 'utf8') + messageBytes + diagnostics.length * 96,
    truncated
  }
}

function sendLanguageServerDiagnostics(server: PersistentLanguageServer, message: Record<string, unknown>): void {
  const diagnostic = lspDiagnostics(server, message)
  if (!diagnostic || server.sender.isDestroyed()) return
  const now = Date.now()
  if (now < server.diagnosticRateStartedAt || now - server.diagnosticRateStartedAt >= 1_000) {
    if (server.diagnosticDroppedEvents > 0) {
      sendLanguageServerLog(server, 'server', 'warning',
        `[${server.diagnosticDroppedEvents} language-server diagnostic event${server.diagnosticDroppedEvents === 1 ? '' : 's'} dropped by the IPC rate limit]\n`)
    }
    server.diagnosticRateStartedAt = now
    server.diagnosticRateBytes = 0
    server.diagnosticRateEvents = 0
    server.diagnosticDroppedEvents = 0
  }
  if (server.diagnosticRateEvents >= MAX_LANGUAGE_SERVER_DIAGNOSTIC_EVENTS_PER_SECOND ||
      diagnostic.estimatedBytes > MAX_LANGUAGE_SERVER_DIAGNOSTIC_IPC_BYTES_PER_SECOND - server.diagnosticRateBytes) {
    server.diagnosticDroppedEvents = Math.min(Number.MAX_SAFE_INTEGER, server.diagnosticDroppedEvents + 1)
    return
  }
  server.diagnosticRateEvents += 1
  server.diagnosticRateBytes += diagnostic.estimatedBytes
  if (diagnostic.truncated) {
    sendLanguageServerLog(server, 'server', 'warning', '[Language-server diagnostics truncated to the IPC safety limit]\n')
  }
  try { server.sender.send(IPC.languageServerDiagnostics, diagnostic.event) } catch {
    // The renderer may have begun tearing down after the destroyed check.
  }
}

function startPersistentLanguageServer(
  sender: Electron.WebContents,
  root: string,
  config: LanguageServerSyncRequest['config']
): PersistentLanguageServer {
  if (sender.isDestroyed()) throw new Error('The language-server owner is no longer available.')
  const resolvedRoot = path.resolve(root)
  assertLanguageServerRootAvailable(sender, resolvedRoot)
  const savedConfig = { command: config.command, args: [...config.args] }
  const key = languageServerKey(sender.id, resolvedRoot, savedConfig)
  if ([...languageServerTerminations].some(([candidate]) =>
    candidate.sender === sender && candidate.configKey === key)) {
    throw new Error('The previous language-server process is still terminating.')
  }
  const existing = languageServers.get(key)
  if (existing) return existing

  let child: ChildProcessWithoutNullStreams
  try {
    child = spawn(savedConfig.command, savedConfig.args, {
      cwd: resolvedRoot,
      env: process.env,
      detached: process.platform !== 'win32',
      windowsHide: true
    })
  } catch (error) {
    const message = languageServerErrorMessage(error, 'Could not start the language server.')
    const common = { key, root: resolvedRoot, command: savedConfig.command }
    sendLanguageServerStatusEvent(sender, { ...common, state: 'starting' })
    sendLanguageServerLogEvent(sender, {
      ...common, stream: 'server', level: 'error', text: message, timestamp: Date.now()
    })
    sendLanguageServerStatusEvent(sender, { ...common, state: 'error', message })
    throw error
  }
  const spawnedPid = child.pid
  const processId = Number.isSafeInteger(spawnedPid) && (spawnedPid as number) > 1 && spawnedPid !== process.pid
    ? spawnedPid as number
    : undefined
  // detached=true makes the POSIX child the leader of a new process group.
  const processGroupId = process.platform === 'win32' ? undefined : processId
  let resolveReady = (): void => undefined
  const ready = new Promise<void>((resolve) => { resolveReady = resolve })
  let resolveProcessClosed = (): void => undefined
  const processClosed = new Promise<void>((resolve) => { resolveProcessClosed = resolve })
  const stderrDecoder = new StringDecoder('utf8')
  let stderrEnded = false
  const server: PersistentLanguageServer = {
    child,
    processId,
    processGroupId,
    root: resolvedRoot,
    config: savedConfig,
    configKey: key,
    initialized: false,
    nextId: 1,
    documents: new Map(),
    pending: new Map(),
    sender,
    ready,
    resolveReady,
    initializeTimer: null,
    processClosed,
    resolveProcessClosed,
    flushStderr: () => {
      if (stderrEnded) return
      stderrEnded = true
      const finalText = stderrDecoder.end()
      if (finalText) sendLanguageServerLog(server, 'stderr', 'error', finalText)
    },
    writeQueue: [],
    queuedWriteBytes: 0,
    writeInProgress: false,
    logBuckets: new Map(),
    logBufferedBytes: 0,
    logDroppedMessages: 0,
    logFlushTimer: null,
    logRateStartedAt: Date.now(),
    logRateBytes: 0,
    diagnosticRateStartedAt: Date.now(),
    diagnosticRateBytes: 0,
    diagnosticRateEvents: 0,
    diagnosticDroppedEvents: 0,
    processCloseObserved: false,
    cleaned: false,
    stopping: false,
    restartable: true
  }
  languageServers.set(key, server)
  bindLanguageServerSenderCleanup(sender)
  sendLanguageServerStatus(server, 'starting')

  const readMessage = createLspMessageReader((message) => {
    if (server.cleaned) return
    if (typeof message.id === 'number' && message.method === undefined) {
      const pending = server.pending.get(message.id)
      if (pending) {
        server.pending.delete(message.id)
        pending(message)
      }
      return
    }
    if (server.stopping) return
    sendLanguageServerDiagnostics(server, message)
    logLanguageServerWindowMessage(server, message)
  }, (error) => {
    const message = `LSP protocol error: ${error.message}`
    sendLanguageServerLog(server, 'server', 'error', message)
    if (error instanceof LspProtocolError && error.fatal) failLanguageServer(server, message, false)
  })
  child.stdout.on('data', (chunk: Buffer) => readMessage(chunk))
  child.stdout.on('error', (error) => {
    failLanguageServer(server, languageServerErrorMessage(error, 'Could not read from the language server.'))
  })
  child.stderr.on('data', (chunk: Buffer) => {
    const text = stderrDecoder.write(chunk)
    if (text) sendLanguageServerLog(server, 'stderr', 'error', text)
  })
  child.stderr.on('end', server.flushStderr)
  child.stderr.on('error', (error) => {
    sendLanguageServerLog(server, 'stderr', 'error', languageServerErrorMessage(error, 'Could not read language server stderr.'))
  })
  child.stdin.on('error', (error) => {
    failLanguageServer(server, languageServerErrorMessage(error, 'Could not write to the language server.'))
  })
  child.stdin.on('close', () => {
    if (!server.cleaned && !server.stopping &&
        server.child.exitCode === null && server.child.signalCode === null) {
      failLanguageServer(server, 'Language server input closed unexpectedly.')
    }
  })
  child.on('error', (error) => {
    failLanguageServer(server, languageServerErrorMessage(error, 'Could not start the language server.'))
  })
  child.on('close', (code, signal) => {
    server.flushStderr()
    server.processCloseObserved = true
    server.resolveProcessClosed()
    if (server.cleaned) return
    if (server.stopping) {
      cleanupLanguageServer(server, 'stopped')
      // A detached group leader can close while descendants remain alive.
      void trackLanguageServerTermination(server).catch(() => undefined)
      return
    }
    const message = signal
      ? `Language server exited unexpectedly with signal ${signal}.`
      : code === null
        ? 'Language server exited unexpectedly.'
        : `Language server exited unexpectedly with code ${code}.`
    sendLanguageServerLog(server, 'server', 'error', message)
    cleanupLanguageServer(server, 'error', message)
    // A detached process-group leader may exit while descendants remain.
    void trackLanguageServerTermination(server).catch(() => undefined)
  })

  const initializeId = server.nextId++
  server.pending.set(initializeId, (message) => {
    if (server.initializeTimer !== null) {
      clearTimeout(server.initializeTimer)
      server.initializeTimer = null
    }
    if (server.cleaned || server.stopping) return
    if (Object.hasOwn(message, 'error')) {
      if (message.jsonrpc !== '2.0' || Object.hasOwn(message, 'result') ||
          !isLanguageServerObject(message.error) || !Number.isInteger(message.error.code) ||
          typeof message.error.message !== 'string') {
        failLanguageServer(server, 'Language server returned an invalid initialize error response.')
        return
      }
      failLanguageServer(server, boundedLanguageServerText(message.error.message, 2_000))
      return
    }
    if (message.jsonrpc !== '2.0' || !Object.hasOwn(message, 'result') ||
        !isLanguageServerObject(message.result) ||
        !isLanguageServerObject(message.result.capabilities)) {
      failLanguageServer(server, 'Language server returned an invalid initialize response.')
      return
    }
    server.capabilities = summarizeLanguageServerCapabilities(message.result.capabilities)
    server.initialized = true
    server.resolveReady()
    if (!writeLanguageServerMessage(server, { jsonrpc: '2.0', method: 'initialized', params: {} })) return
    sendLanguageServerStatus(server, 'running')
  })
  server.initializeTimer = setTimeout(() => {
    server.initializeTimer = null
    failLanguageServer(server, 'Language server initialization timed out.')
  }, LANGUAGE_SERVER_INITIALIZE_TIMEOUT_MS)
  server.initializeTimer.unref?.()
  writeLanguageServerMessage(server, {
    jsonrpc: '2.0',
    id: initializeId,
    method: 'initialize',
    params: { processId: process.pid, rootUri: pathToFileURL(resolvedRoot).href, capabilities: {} }
  })
  return server
}

async function syncPersistentLanguageServer(
  sender: Electron.WebContents,
  request: LanguageServerSyncRequest
): Promise<PersistentLanguageServer> {
  const resolvedRoot = path.resolve(request.root)
  assertLanguageServerRootAvailable(sender, resolvedRoot)
  const key = languageServerKey(sender.id, resolvedRoot, request.config)
  const explicitStop = languageServerExplicitStops.get(key)
  if (explicitStop?.sender === sender) {
    await explicitStop.promise
    throw new Error('Language server was explicitly stopped.')
  }
  const restart = languageServerRestarts.get(key)
  if (restart?.descriptor.sender === sender) await restart.promise
  if (restart?.cancelled || languageServerExplicitStops.get(key)?.sender === sender) {
    throw new Error('Language server was explicitly stopped.')
  }
  // An explicit stop/restart await above yields to workspace release. Recheck
  // the barrier and grant immediately before the synchronous spawn path.
  assertLanguageServerRootAvailable(sender, resolvedRoot)
  const server = startPersistentLanguageServer(sender, resolvedRoot, request.config)
  const uri = pathToFileURL(request.filePath).href
  await server.ready
  if (!server.initialized || server.cleaned || server.stopping) throw new Error('Language server failed to initialize.')
  const previous = server.documents.get(uri)
  const sent = writeLanguageServerMessage(server, previous === undefined
    ? {
        jsonrpc: '2.0',
        method: 'textDocument/didOpen',
        params: { textDocument: { uri, languageId: request.languageId, version: request.version, text: request.content } }
      }
    : {
        jsonrpc: '2.0',
        method: 'textDocument/didChange',
        params: { textDocument: { uri, version: request.version }, contentChanges: [{ text: request.content }] }
      })
  if (!sent || server.cleaned) throw new Error('Language server stopped before the document could be synchronized.')
  server.documents.set(uri, {
    content: request.content,
    languageId: request.languageId,
    version: request.version
  })
  return server
}

function nextLanguageServerDocumentVersion(
  sender: Electron.WebContents,
  request: LanguageServerRequest
): number {
  const key = languageServerKey(sender.id, request.root, request.config)
  const documents = languageServers.get(key)?.documents ??
    languageServerRestarts.get(key)?.descriptor.documents ??
    languageServerTombstones.get(key)?.documents
  return (documents?.get(pathToFileURL(request.filePath).href)?.version ?? 0) + 1
}

async function formatWithPersistentLanguageServer(
  sender: Electron.WebContents,
  request: LanguageServerRequest
): Promise<LanguageServerResult> {
  const server = await syncPersistentLanguageServer(sender, {
    ...request,
    version: nextLanguageServerDocumentVersion(sender, request)
  })
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
    if (!writeLanguageServerMessage(server, {
      jsonrpc: '2.0', id, method: 'textDocument/formatting',
      params: { textDocument: { uri: pathToFileURL(request.filePath).href }, options: { tabSize: 4, insertSpaces: true } }
    })) {
      clearTimeout(timer)
      server.pending.delete(id)
      reject(new Error('Language server stopped before the formatting request could be sent.'))
    }
  })
}

async function lspRequest(
  sender: Electron.WebContents,
  request: LanguageServerRequest,
  method: string,
  params: Record<string, unknown>
): Promise<Record<string, unknown>> {
  const server = await syncPersistentLanguageServer(sender, {
    ...request,
    version: nextLanguageServerDocumentVersion(sender, request)
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
    if (!writeLanguageServerMessage(server, { jsonrpc: '2.0', id, method, params })) {
      clearTimeout(timer)
      server.pending.delete(id)
      reject(new Error(`Language server stopped before the ${method} request could be sent.`))
    }
  })
}

function waitForLanguageServerClose(
  server: PersistentLanguageServer,
  timeoutMs: number
): Promise<boolean> {
  if (server.processCloseObserved) return Promise.resolve(true)
  return new Promise<boolean>((resolve) => {
    let settled = false
    const finish = (closed: boolean): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(closed)
    }
    const timer = setTimeout(() => finish(false), timeoutMs)
    timer.unref?.()
    void server.processClosed.then(() => finish(true))
  })
}

function waitForLanguageServerTerminationGrace(timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, timeoutMs)
    timer.unref?.()
  })
}

function isLanguageServerProcessGroupAlive(server: PersistentLanguageServer): boolean {
  if (process.platform === 'win32' || server.processGroupId === undefined) {
    return !server.processCloseObserved
  }
  try {
    process.kill(-server.processGroupId, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== 'ESRCH'
  }
}

/** Send SIGTERM and escalate to SIGKILL after a bounded wait. */
function terminateLanguageServerBounded(server: PersistentLanguageServer): Promise<void> {
  if (server.terminationPromise) return server.terminationPromise
  server.terminationPromise = (async () => {
    if (process.platform !== 'win32' && server.processGroupId !== undefined) {
      if (!isLanguageServerProcessGroupAlive(server)) return
      terminateLanguageServerProcess(server)
      // Direct-child close does not imply that its detached descendants exited.
      // Give the whole group a grace period, then always try the group KILL.
      await waitForLanguageServerTerminationGrace(LANGUAGE_SERVER_CLOSE_TIMEOUT_MS)
      if (!isLanguageServerProcessGroupAlive(server)) return
      terminateLanguageServerProcess(server, true)
      await waitForLanguageServerTerminationGrace(LANGUAGE_SERVER_CLOSE_TIMEOUT_MS)
      if (isLanguageServerProcessGroupAlive(server)) {
        throw new Error('Language server process group did not terminate after SIGKILL.')
      }
      return
    }
    terminateLanguageServerProcess(server)
    if (!(await waitForLanguageServerClose(server, LANGUAGE_SERVER_CLOSE_TIMEOUT_MS))) {
      terminateLanguageServerProcess(server, true)
      if (!(await waitForLanguageServerClose(server, LANGUAGE_SERVER_CLOSE_TIMEOUT_MS))) {
        throw new Error('Language server process tree did not terminate after a forced stop.')
      }
    }
  })()
  return server.terminationPromise
}

function trackLanguageServerTermination(server: PersistentLanguageServer): Promise<void> {
  const existing = languageServerTerminations.get(server)
  if (existing) return existing
  const termination = terminateLanguageServerBounded(server)
  languageServerTerminations.set(server, termination)
  // Successful termination no longer needs tracking. A rejected termination
  // deliberately remains registered so restart/root release cannot silently
  // proceed while an unowned process tree may still be alive.
  void termination.then(() => {
    if (languageServerTerminations.get(server) === termination) {
      languageServerTerminations.delete(server)
    }
  }, () => undefined)
  return termination
}

/** Stop one server without allowing an unresponsive peer to hold an IPC call open. */
function stopPersistentLanguageServer(server: PersistentLanguageServer): Promise<void> {
  if (server.stopPromise) return server.stopPromise
  if (server.cleaned) return Promise.resolve()
  server.stopping = true
  sendLanguageServerStatus(server, 'stopping')
  server.stopPromise = (async () => {
    if (server.initialized && !server.cleaned) {
      const shutdownId = server.nextId++
      await new Promise<void>((resolve) => {
        let settled = false
        const finish = (): void => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          server.pending.delete(shutdownId)
          resolve()
        }
        const timer = setTimeout(finish, LANGUAGE_SERVER_GRACEFUL_TIMEOUT_MS)
        timer.unref?.()
        server.pending.set(shutdownId, finish)
        if (!writeLanguageServerMessage(server, {
          jsonrpc: '2.0', id: shutdownId, method: 'shutdown', params: null
        })) finish()
      })
      if (!server.cleaned) {
        writeLanguageServerMessage(server, { jsonrpc: '2.0', method: 'exit', params: null })
      }
      if (await waitForLanguageServerClose(server, LANGUAGE_SERVER_CLOSE_TIMEOUT_MS) &&
          (process.platform === 'win32' || server.processGroupId === undefined)) {
        cleanupLanguageServer(server, 'stopped')
        return
      }
    }

    await trackLanguageServerTermination(server)
    cleanupLanguageServer(server, 'stopped')
  })()
  return server.stopPromise
}

async function replayLanguageServerDocuments(
  server: PersistentLanguageServer,
  documents: Map<string, LanguageServerDocumentSnapshot>
): Promise<void> {
  await server.ready
  if (!server.initialized || server.cleaned || server.stopping) {
    throw new Error('Language server failed to initialize after restart.')
  }
  for (const [uri, document] of documents) {
    if (!writeLanguageServerMessage(server, {
      jsonrpc: '2.0',
      method: 'textDocument/didOpen',
      params: {
        textDocument: {
          uri,
          languageId: document.languageId,
          version: document.version,
          text: document.content
        }
      }
    })) {
      throw new Error('Language server stopped while documents were being restored.')
    }
    server.documents.set(uri, { ...document })
  }
}

async function restartPersistentLanguageServer(
  sender: Electron.WebContents,
  key: string
): Promise<void> {
  const explicitStop = languageServerExplicitStops.get(key)
  if (explicitStop) {
    if (explicitStop.sender !== sender) throw new Error('Language server not found.')
    await explicitStop.promise
    throw new Error('Language server was explicitly stopped.')
  }
  const inProgress = languageServerRestarts.get(key)
  if (inProgress) {
    if (inProgress.descriptor.sender !== sender) throw new Error('Language server not found.')
    await inProgress.promise
    return
  }
  const oldServer = languageServers.get(key)
  const savedDescriptor = languageServerTombstones.get(key)
  const descriptor = oldServer
    ? languageServerDescriptor(oldServer)
    : savedDescriptor && {
        ...savedDescriptor,
        config: { command: savedDescriptor.config.command, args: [...savedDescriptor.config.args] },
        documents: cloneLanguageServerDocuments(savedDescriptor.documents)
      }
  if (!descriptor || descriptor.sender !== sender) throw new Error('Language server not found.')
  const operation: LanguageServerRestartOperation = {
    descriptor,
    source: oldServer,
    cancelled: false,
    promise: Promise.resolve()
  }
  languageServerRestarts.set(key, operation)
  operation.promise = (async () => {
    if (oldServer) await stopPersistentLanguageServer(oldServer)
    if (operation.cancelled || sender.isDestroyed()) return
    const replacement = startPersistentLanguageServer(sender, descriptor.root, descriptor.config)
    operation.replacement = replacement
    if (operation.cancelled) {
      replacement.restartable = false
      await stopPersistentLanguageServer(replacement)
      return
    }
    await replayLanguageServerDocuments(replacement, descriptor.documents)
    if (operation.cancelled) {
      replacement.restartable = false
      await stopPersistentLanguageServer(replacement)
      return
    }
    languageServerTombstones.delete(key)
  })()
  try {
    await operation.promise
  } finally {
    if (languageServerRestarts.get(key) === operation) languageServerRestarts.delete(key)
  }
}

async function explicitlyStopPersistentLanguageServer(
  sender: Electron.WebContents,
  key: string
): Promise<void> {
  const existing = languageServerExplicitStops.get(key)
  if (existing) {
    if (existing.sender === sender) await existing.promise
    return
  }
  const active = languageServers.get(key)
  const restart = languageServerRestarts.get(key)
  const tombstone = languageServerTombstones.get(key)
  const owner = active?.sender ?? restart?.descriptor.sender ?? tombstone?.sender
  if (owner !== sender) return

  const operation: LanguageServerExplicitStop = {
    sender,
    root: path.resolve(active?.root ?? restart?.descriptor.root ?? tombstone?.root ?? ''),
    promise: Promise.resolve()
  }
  languageServerExplicitStops.set(key, operation)
  operation.promise = (async () => {
    if (restart) restart.cancelled = true
    languageServerTombstones.delete(key)
    const candidates = new Set<PersistentLanguageServer>()
    if (active) candidates.add(active)
    if (restart?.source) candidates.add(restart.source)
    if (restart?.replacement) candidates.add(restart.replacement)
    for (const server of candidates) server.restartable = false
    await Promise.all([...candidates].map(stopPersistentLanguageServer))
    await Promise.all(
      [...languageServerTerminations]
        .filter(([server]) => server.sender === sender && server.configKey === key)
        .map(([, termination]) => termination)
    )
    if (restart) {
      try { await restart.promise } catch {
        // Explicit stop supersedes a failed or cancelled restart.
      }
      if (restart.replacement && !restart.replacement.cleaned) {
        restart.replacement.restartable = false
        await stopPersistentLanguageServer(restart.replacement)
      }
    }
    languageServerTombstones.delete(key)
  })()
  try {
    await operation.promise
  } finally {
    if (languageServerExplicitStops.get(key) === operation) languageServerExplicitStops.delete(key)
  }
}

/** Stop all configurations and restart generations authorised by one root. */
async function stopAllLanguageServersForRoot(
  sender: Electron.WebContents,
  root: string
): Promise<void> {
  const resolvedRoot = path.resolve(root)
  const matches = (owner: Electron.WebContents, candidateRoot: string): boolean =>
    owner === sender && path.resolve(candidateRoot) === resolvedRoot

  while (true) {
    const keys = new Set<string>()
    for (const [key, server] of languageServers) {
      if (matches(server.sender, server.root)) keys.add(key)
    }
    for (const [key, restart] of languageServerRestarts) {
      if (matches(restart.descriptor.sender, restart.descriptor.root)) keys.add(key)
    }
    for (const [key, tombstone] of languageServerTombstones) {
      if (matches(tombstone.sender, tombstone.root)) keys.add(key)
    }
    const operations = [...languageServerExplicitStops.values()]
      .filter((operation) => matches(operation.sender, operation.root))
    const terminations = [...languageServerTerminations]
      .filter(([server]) => matches(server.sender, server.root))
      .map(([, termination]) => termination)
    if (keys.size === 0 && operations.length === 0 && terminations.length === 0) return
    await Promise.all([
      ...[...keys].map((key) => explicitlyStopPersistentLanguageServer(sender, key)),
      ...operations.map((operation) => operation.promise),
      ...terminations
    ])
  }
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
  ipcMain.handle(IPC.fileOpen, async (event, options?: unknown): Promise<OpenedFile | null> => {
    assertTrustedSender(event)
    if (options !== undefined && (!options || typeof options !== 'object' || Array.isArray(options))) {
      throw new Error('Invalid file read options.')
    }
    const requestedEncoding = (options as Partial<FileReadOptions> | null)?.encoding
    if (requestedEncoding !== undefined && !isTextEncoding(requestedEncoding)) throw new Error('Unsupported text encoding.')
    if (requestedEncoding === undefined && options !== undefined) throw new Error('Invalid file read options.')
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, { properties: ['openFile'], title: 'Open File' })
    if (result.canceled || result.filePaths.length === 0) return null
    grantFile(event.sender.id, result.filePaths[0])
    await rememberRecentFile(result.filePaths[0])
    return readFile(result.filePaths[0], requestedEncoding)
  })

  ipcMain.handle(IPC.fileOpenPath, async (event, filePath: unknown, options?: unknown): Promise<OpenedFile> => {
    assertTrustedSender(event)
    assertAbsolutePath(filePath)
    assertGrantedFile(event, filePath)
    await rememberRecentFile(filePath)
    if (options !== undefined && (!options || typeof options !== 'object' || Array.isArray(options))) {
      throw new Error('Invalid file read options.')
    }
    const requestedEncoding = (options as Partial<FileReadOptions> | null)?.encoding
    if (requestedEncoding !== undefined && !isTextEncoding(requestedEncoding)) throw new Error('Unsupported text encoding.')
    if (requestedEncoding === undefined && options !== undefined) throw new Error('Invalid file read options.')
    return readFile(filePath, requestedEncoding)
  })

  ipcMain.handle(IPC.fileReopenWithEncoding, async (event, filePath: unknown, options: unknown): Promise<OpenedFile> => {
    assertTrustedSender(event)
    assertAbsolutePath(filePath)
    assertGrantedFile(event, filePath)
    if (!options || typeof options !== 'object' || Array.isArray(options)) throw new Error('Invalid file read options.')
    const encoding = (options as Partial<FileReadOptions>).encoding
    if (!isTextEncoding(encoding)) throw new Error('Unsupported text encoding.')
    return readFile(filePath, encoding)
  })

  ipcMain.handle(IPC.dropOpen, async (event, candidates: unknown): Promise<DroppedPaths> => {
    assertTrustedSender(event)
    if (!Array.isArray(candidates) || candidates.length === 0 || candidates.length > 32) {
      throw new Error('Drop up to 32 local files or folders at a time.')
    }
    const unique = [...new Set(candidates)]
    if (unique.some((candidate) => typeof candidate !== 'string' || !path.isAbsolute(candidate))) {
      throw new Error('Invalid dropped path.')
    }
    const files: OpenedFile[] = []
    const folders: OpenedFolder[] = []
    let rejected = 0
    for (const candidate of unique) {
      try {
        const stat = await fs.stat(candidate)
        if (stat.isFile()) {
          grantFile(event.sender.id, candidate)
          await rememberRecentFile(candidate)
          files.push(await readFile(candidate))
        } else if (stat.isDirectory()) {
          grantRoot(event.sender.id, candidate)
          folders.push({ root: candidate, entries: await readDirectory(candidate) })
        } else {
          rejected += 1
        }
      } catch {
        // Drag operations can race with an external move/delete. Skip only the
        // failed entry so valid items in the same drop still open.
        rejected += 1
      }
    }
    return { files, folders, rejected }
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

  ipcMain.handle(IPC.editorConfigResolve, async (event, rawRequest: unknown): Promise<ResolvedEditorConfig> => {
    assertTrustedSender(event)
    if (!rawRequest || typeof rawRequest !== 'object') throw new Error('Invalid EditorConfig request.')
    const request = rawRequest as Partial<EditorConfigRequest>
    assertAbsolutePath(request.filePath, 'EditorConfig target')
    assertAbsolutePath(request.workspaceRoot, 'workspace root')
    return resolveEditorConfig(event, { filePath: request.filePath, workspaceRoot: request.workspaceRoot })
  })

  ipcMain.handle(IPC.workspaceRelease, async (event, root: unknown, retainFiles: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    await releaseWorkspaceRoot(event, root, retainFiles)
  })

  ipcMain.handle(IPC.clipboardWritePath, async (event, target: unknown, relativeRoot?: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(target, 'clipboard path')
    assertGrantedFile(event, target)
    if (relativeRoot === undefined || relativeRoot === null) {
      clipboard.writeText(target)
      return
    }
    assertAbsolutePath(relativeRoot, 'workspace root')
    assertGrantedRoot(event, relativeRoot)
    const root = path.resolve(relativeRoot)
    const resolvedTarget = path.resolve(target)
    if (!isInside(root, resolvedTarget)) throw new Error('The copied path is outside the requested workspace root.')
    const relative = path.relative(root, resolvedTarget) || path.basename(resolvedTarget)
    clipboard.writeText(relative.split(path.sep).join('/'))
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
      if (filePath === null) return saveAs(event, content, undefined, options)
      assertAbsolutePath(filePath)
      assertGrantedFile(event, filePath)
      if (options?.protectedSourcePath !== undefined) {
        throw new Error('Protected source paths are valid only for Save As.')
      }
      const configured = await editorConfigWriteOptions(event, filePath, options)
      return saveFile(filePath, content, { ...configured, expectedRevision: options?.expectedRevision })
    }
  )

  ipcMain.handle(
    IPC.fileSaveAs,
    async (event, content: unknown, suggestedName?: unknown, options?: FileWriteOptions): Promise<SaveResult> => {
      assertTrustedSender(event)
      if (typeof content !== 'string') throw new Error('Invalid file contents.')
      return saveAs(event, content, typeof suggestedName === 'string' ? suggestedName : undefined, options)
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
    const session = sanitizeSession(await readJson<unknown>(
      windowSessionFile(event.sender.id),
      EMPTY_SESSION,
      MAX_SESSION_SERIALIZED_BYTES
    ))
    for (const folder of session.folders ?? []) grantRoot(event.sender.id, folder)
    if (session.folder) grantRoot(event.sender.id, session.folder)
    for (const file of session.openFiles) if (file.path) grantFile(event.sender.id, file.path)
    return session
  })
  ipcMain.handle(IPC.sessionWrite, async (event, session: unknown): Promise<void> => {
    assertTrustedSender(event)
    await writeJson(
      windowSessionFile(event.sender.id),
      sanitizeSession(session, true),
      MAX_SESSION_SERIALIZED_BYTES
    )
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

  ipcMain.handle(IPC.recentFilesRead, async (event): Promise<RecentFile[]> => {
    assertTrustedSender(event)
    const raw = await readJson<unknown>(userDataFile('recent-files.json'), [])
    return Array.isArray(raw)
      ? raw.flatMap((entry) => entry && typeof entry === 'object' && typeof (entry as { path?: unknown }).path === 'string' && path.isAbsolute((entry as { path: string }).path)
        ? [{ path: (entry as { path: string }).path, lastOpened: typeof (entry as { lastOpened?: unknown }).lastOpened === 'number' ? (entry as { lastOpened: number }).lastOpened : 0 }]
        : []).sort((a, b) => b.lastOpened - a.lastOpened).slice(0, 50)
      : []
  })

  ipcMain.handle(IPC.recentFileOpen, async (event, file: unknown): Promise<OpenedFile> => {
    assertTrustedSender(event)
    assertAbsolutePath(file, 'recent file')
    const recent = await readJson<RecentFile[]>(userDataFile('recent-files.json'), [])
    if (!recent.some((entry) => entry.path === file)) throw new Error('This file is not in the recent-files list.')
    grantFile(event.sender.id, file)
    await rememberRecentFile(file)
    return readFile(file)
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
    await withSerializedFileMutation([target], async () => {
      if (isDirectory) await fs.mkdir(target, { recursive: false })
      else {
        await fs.mkdir(path.dirname(target), { recursive: true })
        await fs.writeFile(target, '', { flag: 'wx' })
      }
    })
    return { name: path.basename(target), path: target, isDirectory }
  })

  ipcMain.handle(IPC.fileRename, async (event, source: unknown, target: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(source, 'source path')
    assertAbsolutePath(target, 'destination path')
    assertGrantedFile(event, source)
    assertGrantedFile(event, path.dirname(target))
    if (path.dirname(source) !== path.dirname(target)) throw new Error('Moving files across folders is not supported here.')
    await withSerializedFileMutation([source, target], () => fs.rename(source, target))
  })

  ipcMain.handle(IPC.fileMove, async (event, source: unknown): Promise<string | null> => {
    assertTrustedSender(event)
    assertAbsolutePath(source, 'source path')
    assertGrantedFile(event, source)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, { title: 'Move To', properties: ['openDirectory', 'createDirectory'] })
    if (result.canceled || !result.filePaths[0]) return null
    const target = path.join(result.filePaths[0], path.basename(source))
    if (path.resolve(target) === path.resolve(source)) return source
    await withSerializedFileMutation([source, target], async () => {
      try { await fs.access(target); throw new Error(`A file named “${path.basename(source)}” already exists in the destination.`) }
      catch (error) { if (!(error instanceof Error && 'code' in error && (error as NodeJS.ErrnoException).code === 'ENOENT')) throw error }
      await fs.rename(source, target)
    })
    grantFile(event.sender.id, target)
    return target
  })

  ipcMain.handle(IPC.fileDelete, async (event, target: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(target, 'delete path')
    assertGrantedFile(event, target)
    await withSerializedFileMutation([target], () => shell.trashItem(target))
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

  ipcMain.handle(IPC.terminalStart, async (event, root: unknown, sessionId: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertAbsolutePath(root, 'workspace root')
    assertGrantedRoot(event, root)
    assertTerminalSessionId(sessionId)
    const senderId = event.sender.id
    stopTerminalForSender(senderId)
    const shell = process.platform === 'win32' ? (process.env.COMSPEC || 'cmd.exe') : (process.env.SHELL || '/bin/sh')
    const args = process.platform === 'win32' ? [] : ['-i']
    const child = spawn(shell, args, {
      cwd: root,
      env: { ...process.env, TERM: 'dumb' },
      stdio: 'pipe',
      // On POSIX this lets the stop handler terminate commands launched by
      // the shell as one known process group.
      detached: process.platform !== 'win32'
    })
    const terminal: TerminalProcess = { child, sessionId }
    terminals.set(senderId, terminal)
    const send = (payload: Omit<TerminalOutput, 'sessionId'>): void => {
      // A new terminal replaces the old one. Ignore late output from the old
      // shell so an exit event cannot make the new panel look stopped.
      if (terminals.get(senderId) === terminal && !event.sender.isDestroyed()) {
        event.sender.send(IPC.terminalOutput, { ...payload, sessionId: terminal.sessionId })
      }
    }
    child.stdout.on('data', (data: Buffer) => send({ kind: 'stdout', text: terminalChunk(data) }))
    child.stderr.on('data', (data: Buffer) => send({ kind: 'stderr', text: terminalChunk(data) }))
    child.on('error', (error) => send({ kind: 'stderr', text: `${error.message}\n` }))
    child.on('close', (code) => {
      if (terminals.get(senderId) !== terminal) return
      send({ kind: 'exit', text: code === 0 ? 'Terminal exited.\n' : `Terminal exited with code ${code}.\n`, code })
      terminals.delete(senderId)
    })
    if (!terminalCleanupBound.has(senderId)) {
      terminalCleanupBound.add(senderId)
      event.sender.once('destroyed', () => {
        stopTerminalForSender(senderId)
        terminalCleanupBound.delete(senderId)
      })
    }
  })

  ipcMain.handle(IPC.terminalWrite, async (event, sessionId: unknown, text: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertTerminalSessionId(sessionId)
    if (typeof text !== 'string' || text.length === 0 || text.length > 64 * 1024) throw new Error('Invalid terminal input.')
    const terminal = terminals.get(event.sender.id)?.child
    if (!terminal || terminals.get(event.sender.id)?.sessionId !== sessionId || terminal.killed || !terminal.stdin.writable) {
      throw new Error('No active terminal session.')
    }
    terminal.stdin.write(text)
  })

  ipcMain.handle(IPC.terminalStop, async (event, sessionId: unknown): Promise<void> => {
    assertTrustedSender(event)
    assertTerminalSessionId(sessionId)
    const terminal = terminals.get(event.sender.id)
    if (terminal?.sessionId === sessionId) stopTerminalForSender(event.sender.id)
  })

  ipcMain.handle(IPC.buildImportSublime, async (event): Promise<SublimeBuildImport | null> => {
    assertTrustedSender(event)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, { title: 'Import Sublime Build System', properties: ['openFile'], filters: [{ name: 'Sublime Build System', extensions: ['sublime-build'] }] })
    if (result.canceled || !result.filePaths[0]) return null
    const sourcePath = result.filePaths[0]
    let raw: unknown
    try { raw = JSON.parse(stripJsonComments(await fs.readFile(sourcePath, 'utf8'))) }
    catch { throw new Error('The selected .sublime-build file is not valid JSON-with-comments.') }
    return { sourcePath, system: parseSublimeBuild(raw, sourcePath) }
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

  ipcMain.handle(IPC.projectImportSublimeKeymap, async (event): Promise<SublimeKeymapImport | null> => {
    assertTrustedSender(event)
    const win = BrowserWindow.fromWebContents(event.sender)
    const result = await dialog.showOpenDialog(win!, { title: 'Import Sublime Keymap', properties: ['openFile'], filters: [{ name: 'Sublime Keymap', extensions: ['sublime-keymap'] }] })
    if (result.canceled || !result.filePaths[0]) return null
    const sourcePath = result.filePaths[0]
    let raw: unknown
    try { raw = JSON.parse(stripJsonComments(await fs.readFile(sourcePath, 'utf8'))) }
    catch { throw new Error('The selected .sublime-keymap file is not valid JSON-with-comments.') }
    return { sourcePath, ...parseSublimeKeymap(raw) }
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
    if (!request || typeof request !== 'object' || typeof request.root !== 'string' || !['stage', 'unstage', 'discard', 'stage-hunk', 'discard-hunk', 'commit', 'checkout-branch', 'create-branch'].includes(request.action)) throw new Error('Invalid Git action.')
    assertGrantedRoot(event, request.root)
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
    await explicitlyStopPersistentLanguageServer(event.sender, key)
  })

  ipcMain.handle(IPC.languageServerRestart, async (event, key: unknown): Promise<void> => {
    assertTrustedSender(event)
    if (typeof key !== 'string' || !/^lsp-[a-f0-9]{64}$/.test(key)) {
      throw new Error('Invalid language server key.')
    }
    await restartPersistentLanguageServer(event.sender, key)
  })

  ipcMain.handle(IPC.languageServerRequest, async (event, request: LanguageServerInteractiveRequest): Promise<LanguageServerInteractiveResult> => {
    assertTrustedSender(event)
    assertGrantedRoot(event, request.root)
    assertGrantedFile(event, request.filePath)
    return interactiveLanguageServerRequest(event.sender, request)
  })
}

function validWriteOptions(options?: FileWriteOptions): FileWriteOptions {
  if (options !== undefined) {
    if (!options || typeof options !== 'object' || Array.isArray(options)) throw new Error('Invalid file write options.')
    if (!isTextEncoding(options.encoding)) throw new Error('Unsupported text encoding.')
    if (options.eol !== 'LF' && options.eol !== 'CRLF' && options.eol !== 'CR') throw new Error('Unsupported line ending.')
    if (options.expectedEncoding !== undefined && !isTextEncoding(options.expectedEncoding)) {
      throw new Error('Unsupported expected text encoding.')
    }
    if (options.protectedSourcePath !== undefined && (typeof options.protectedSourcePath !== 'string' || !path.isAbsolute(options.protectedSourcePath))) {
      throw new Error('Invalid protected source path.')
    }
  }
  return {
    encoding: isTextEncoding(options?.encoding) ? options.encoding : 'utf8',
    eol: options?.eol === 'CRLF' || options?.eol === 'CR' ? options.eol : 'LF',
    ...(isTextEncoding(options?.expectedEncoding) ? { expectedEncoding: options.expectedEncoding } : {}),
    ...(options?.protectedSourcePath ? { protectedSourcePath: options.protectedSourcePath } : {})
  }
}

async function editorConfigWriteOptions(
  event: IpcMainInvokeEvent,
  target: string,
  options?: FileWriteOptions,
  allowMissingTarget = false
): Promise<FileWriteOptions> {
  const validated = validWriteOptions(options)
  if (options?.respectEditorConfigEol !== true) return validated
  const root = [...(grantedRoots.get(event.sender.id) ?? [])]
    .filter((candidate) => isInside(candidate, target))
    .sort((left, right) => right.length - left.length)[0]
  if (!root) return validated
  try {
    const config = await resolveEditorConfig(event, { filePath: target, workspaceRoot: root }, allowMissingTarget)
    if (config.endOfLine) validated.eol = config.endOfLine
  } catch {
    // Saving an explicitly authorised file remains available if its project
    // config disappears, races, or the workspace grant is removed.
  }
  return validated
}

async function saveAs(
  event: IpcMainInvokeEvent,
  content: string,
  suggestedName?: string,
  options?: FileWriteOptions
): Promise<SaveResult> {
  const sender = event.sender
  const win = BrowserWindow.fromWebContents(sender)
  const result = await dialog.showSaveDialog(win!, { title: 'Save File', defaultPath: suggestedName })
  if (result.canceled || !result.filePath) return { saved: false, reason: 'cancelled' }
  grantFile(sender.id, result.filePath)
  // Freeze the overwrite baseline immediately after the user confirms the
  // native dialog. Config lookup must not widen this optimistic-save window.
  const expectedRevision = await readRawFileRevision(result.filePath)
  const validated = await editorConfigWriteOptions(event, result.filePath, options, true)
  if (validated.protectedSourcePath) {
    assertGrantedFile(event, validated.protectedSourcePath)
    if (await pathsShareFileIdentity(result.filePath, validated.protectedSourcePath)) {
      return { saved: false, path: result.filePath, reason: 'protected-source' }
    }
  }
  // Capture the selected target after the dialog returns, then use the same
  // optimistic checks as a normal save. A change after the user's overwrite
  // confirmation must not be silently replaced.
  return saveFile(result.filePath, content, {
    encoding: validated.encoding,
    eol: validated.eol,
    expectedRevision,
    ...(validated.protectedSourcePath ? { protectedSourcePath: validated.protectedSourcePath } : {})
  })
}
