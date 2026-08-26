import type { PluginManifest, PluginPermission } from '../../shared/ipc.js'

export interface ExtensionHostContext {
  getDocument: () => { text: string; language: string; selection: { from: number; to: number } }
  replaceDocument: (text: string) => void
  registerCommand: (plugin: PluginManifest, id: string, title: string, run: () => void) => void
  notify: (message: string) => void
}

interface HostMessage {
  type: 'register-command' | 'replace-document' | 'notify'
  id?: unknown
  title?: unknown
  text?: unknown
}

/**
 * Runs opt-in declarative plugin workers in a Web Worker. Worker code receives
 * only an explicit context message—no Electron APIs, DOM, Node or filesystem.
 */
export class ExtensionHost {
  private workers = new Map<string, Worker>()

  async load(
    root: string,
    plugin: PluginManifest,
    permissions: PluginPermission[],
    context: ExtensionHostContext
  ): Promise<void> {
    if (!plugin.extension?.worker || this.workers.has(plugin.id)) return
    const source = await window.editor.readPluginExtension(root, plugin.id, plugin.extension.worker)
    const blob = new Blob([source], { type: 'text/javascript' })
    const worker = new Worker(URL.createObjectURL(blob), { name: `lumen-plugin-${plugin.id}` })
    this.workers.set(plugin.id, worker)

    worker.addEventListener('message', (event: MessageEvent<HostMessage>) => {
      const message = event.data
      if (!message || typeof message.type !== 'string') return
      if (message.type === 'register-command' && typeof message.id === 'string' && typeof message.title === 'string') {
        context.registerCommand(plugin, message.id.slice(0, 100), message.title.slice(0, 200), () => {
          worker.postMessage({ type: 'run-command', id: message.id, context: this.safeContext(permissions, context) })
        })
      } else if (message.type === 'replace-document' && permissions.includes('document-edit') && typeof message.text === 'string') {
        context.replaceDocument(message.text)
      } else if (message.type === 'notify' && typeof message.text === 'string') {
        context.notify(`${plugin.name}: ${message.text.slice(0, 500)}`)
      }
    })
    worker.addEventListener('error', (event) => context.notify(`${plugin.name}: extension error — ${event.message}`))
    worker.postMessage({ type: 'activate', context: this.safeContext(permissions, context) })
  }

  dispose(): void {
    for (const worker of this.workers.values()) worker.terminate()
    this.workers.clear()
  }

  private safeContext(permissions: PluginPermission[], context: ExtensionHostContext): Record<string, unknown> {
    const base: Record<string, unknown> = { permissions }
    if (permissions.includes('document-read')) base.document = context.getDocument()
    return base
  }
}
