import { EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view'
import { Facet, type Extension } from '@codemirror/state'

/**
 * Vertical rulers drawn at fixed character columns (Sublime's `rulers`).
 * Implemented as absolutely-positioned lines inside the scroller so they
 * track horizontal scrolling and the current character width.
 */

/** Columns to draw rulers at. Combined from all providers. */
export const rulerColumns = Facet.define<number[], number[]>({
  combine: (values) => values.flat()
})

const rulerPlugin = ViewPlugin.fromClass(
  class {
    private container: HTMLDivElement

    constructor(private view: EditorView) {
      this.container = document.createElement('div')
      this.container.className = 'cm-rulers'
      this.container.style.position = 'absolute'
      this.container.style.top = '0'
      this.container.style.left = '0'
      this.container.style.height = '100%'
      this.container.style.pointerEvents = 'none'
      view.scrollDOM.appendChild(this.container)
      this.draw()
    }

    update(update: ViewUpdate): void {
      if (
        update.geometryChanged ||
        update.viewportChanged ||
        update.state.facet(rulerColumns) !== update.startState.facet(rulerColumns)
      ) {
        this.draw()
      }
    }

    /** Recreate the ruler lines at the configured columns. */
    private draw(): void {
      const columns = this.view.state.facet(rulerColumns)
      this.container.replaceChildren()
      if (columns.length === 0) return

      // Measure the width of a single character in the current font.
      const charWidth = this.view.defaultCharacterWidth
      const gutterWidth = this.view.contentDOM.getBoundingClientRect().left -
        this.view.scrollDOM.getBoundingClientRect().left

      for (const col of columns) {
        const line = document.createElement('div')
        line.className = 'cm-ruler'
        line.style.position = 'absolute'
        line.style.top = '0'
        line.style.bottom = '0'
        line.style.width = '1px'
        line.style.left = `${gutterWidth + col * charWidth}px`
        this.container.appendChild(line)
      }
    }

    destroy(): void {
      this.container.remove()
    }
  }
)

/** Build the rulers extension for the given columns. */
export function rulers(columns: number[]): Extension {
  return [rulerColumns.of(columns), rulerPlugin]
}
