import { EditorView, Decoration, type DecorationSet, ViewPlugin, type ViewUpdate } from '@codemirror/view'
import { RangeSetBuilder, type Extension } from '@codemirror/state'

/**
 * Highlight trailing whitespace on each line (Sublime's
 * `draw_white_space` / trailing highlight). Purely visual; does not modify text.
 */

const trailingMark = Decoration.mark({ class: 'cm-trailingSpace' })

/** Regex matching one-or-more whitespace chars at end of a line. */
const TRAILING = /[ \t]+$/

const plugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet

    constructor(view: EditorView) {
      this.decorations = this.build(view)
    }

    update(update: ViewUpdate): void {
      if (update.docChanged || update.viewportChanged) {
        this.decorations = this.build(update.view)
      }
    }

    /** Scan visible lines and mark their trailing whitespace runs. */
    private build(view: EditorView): DecorationSet {
      const builder = new RangeSetBuilder<Decoration>()
      for (const { from, to } of view.visibleRanges) {
        let pos = from
        while (pos <= to) {
          const line = view.state.doc.lineAt(pos)
          const match = TRAILING.exec(line.text)
          if (match && match[0].length > 0) {
            const start = line.from + match.index
            builder.add(start, line.to, trailingMark)
          }
          pos = line.to + 1
        }
      }
      return builder.finish()
    }
  },
  {
    decorations: (v) => v.decorations
  }
)

/** The trailing-whitespace highlight extension. */
export function highlightTrailingWhitespace(): Extension {
  return plugin
}
