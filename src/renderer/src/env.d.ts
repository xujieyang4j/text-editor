import type { EditorApi } from '../../preload/index.js'

declare global {
  interface Window {
    /** Secure API bridge exposed by the preload script. */
    editor: EditorApi
  }
}

export {}
