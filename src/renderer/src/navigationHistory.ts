/** A document position that can be resolved by an open document id or a path. */
export interface NavigationLocation {
  /** Stable id, including for untitled documents whose path is null. */
  readonly docId: string
  /** Current disk path when one exists; null for an untitled document. */
  readonly path: string | null
  /** Editor group that owned the view when the location was captured. */
  readonly groupId: number
  /** One-based line number. */
  readonly line: number
  /** One-based column number. */
  readonly column: number
}

export type NavigationDirection = 'back' | 'forward'

/**
 * A non-mutating traversal prepared by NavigationHistory. Callers should only
 * commit it after its target has been resolved and the jump has succeeded.
 */
export interface NavigationTraversal {
  readonly direction: NavigationDirection
  readonly target: NavigationLocation
}

/** Snapshot the user intent epoch shared by a batch of queued history steps. */
export class NavigationIntentEpoch {
  private revision = 0

  get current(): number { return this.revision }
  begin(): number { this.revision += 1; return this.revision }
  isCurrent(snapshot: number): boolean { return snapshot === this.revision }
}

export const NAVIGATION_HISTORY_LIMIT = 100

interface PreparedTraversal {
  readonly direction: NavigationDirection
  readonly target: NavigationLocation
  readonly revision: number
}

const copyLocation = (location: NavigationLocation): NavigationLocation => ({
  docId: location.docId,
  path: location.path,
  groupId: location.groupId,
  line: location.line,
  column: location.column
})

const frozenLocation = (location: NavigationLocation): NavigationLocation =>
  Object.freeze(copyLocation(location))

/** Compare the semantic document position; path/group are resolver metadata. */
export const sameNavigationLocation = (left: NavigationLocation, right: NavigationLocation): boolean =>
  left.docId === right.docId &&
  left.line === right.line &&
  left.column === right.column

const sameStoredLocation = (left: NavigationLocation, right: NavigationLocation): boolean =>
  sameNavigationLocation(left, right) && left.path === right.path && left.groupId === right.groupId

/** Resolve the Goto Line syntax shared by the menu and Goto Anything. */
export function resolveGotoLine(
  input: string,
  currentLine: number,
  totalLines: number
): { line: number; column: number } | null {
  const match = /^([+-])?(\d+)(?::(\d+))?(%)?$/.exec(input.trim())
  if (!match || !Number.isSafeInteger(currentLine) || !Number.isSafeInteger(totalLines) || totalLines < 1) return null
  const amount = Number(match[2])
  const column = match[3] === undefined ? 1 : Number(match[3])
  if (!Number.isSafeInteger(amount) || !Number.isSafeInteger(column) || column < 1) return null

  let line: number
  if (match[4]) {
    const absolute = totalLines * amount / 100
    line = match[1]
      ? currentLine + Math.round(match[1] === '-' ? -absolute : absolute)
      : Math.round(absolute)
  } else {
    line = match[1]
      ? currentLine + (match[1] === '-' ? -amount : amount)
      : amount
  }
  return { line: Math.max(1, Math.min(totalLines, line)), column }
}

/**
 * Browser-style navigation history with transactional back/forward traversal.
 * Stack entries are ordered oldest-to-newest; the final entry is the next one
 * visited. Preparing a traversal never changes either stack.
 */
export class NavigationHistory {
  private readonly backStack: NavigationLocation[] = []
  private readonly forwardStack: NavigationLocation[] = []
  private readonly preparedTraversals = new WeakMap<NavigationTraversal, PreparedTraversal>()
  private revision = 0

  constructor(private readonly capacity: number = NAVIGATION_HISTORY_LIMIT) {
    if (!Number.isInteger(capacity) || capacity < 1 || capacity > NAVIGATION_HISTORY_LIMIT) {
      throw new RangeError(`Navigation history capacity must be an integer from 1 to ${NAVIGATION_HISTORY_LIMIT}.`)
    }
  }

  get canGoBack(): boolean {
    return this.backStack.length > 0
  }

  get canGoForward(): boolean {
    return this.forwardStack.length > 0
  }

  /** Snapshot for rendering state and tests; mutating it cannot affect history. */
  get backEntries(): readonly NavigationLocation[] {
    return this.backStack.map(copyLocation)
  }

  /** Snapshot for rendering state and tests; mutating it cannot affect history. */
  get forwardEntries(): readonly NavigationLocation[] {
    return this.forwardStack.map(copyLocation)
  }

  /**
   * Record an ordinary (non-history) jump after it has succeeded. A real jump
   * puts its source on the back stack and starts a new forward branch.
   */
  recordSuccessfulJump(
    source: NavigationLocation | null,
    target: NavigationLocation | null
  ): void {
    if (!source || !target || sameNavigationLocation(source, target)) return

    this.pushUnique(this.backStack, source)
    this.forwardStack.length = 0

    // Invalidate traversals prepared before this jump even when the source was
    // already the top back entry and the forward stack was already empty.
    this.revision += 1
  }

  /** Return the next target without removing it from its source stack. */
  prepareTraversal(direction: NavigationDirection): NavigationTraversal | null {
    const source = this.stackFor(direction)
    const next = source[source.length - 1]
    if (!next) return null

    const target = frozenLocation(next)
    const traversal: NavigationTraversal = Object.freeze({ direction, target })
    this.preparedTraversals.set(traversal, {
      direction,
      target,
      revision: this.revision
    })
    return traversal
  }

  /**
   * Commit a prepared traversal after the caller successfully jumped to its
   * target. Stale, foreign, or already-used transactions are rejected without
   * changing either stack. Omitting commit after a failed jump is a no-op.
   */
  commitTraversal(
    traversal: NavigationTraversal,
    current: NavigationLocation | null
  ): boolean {
    const prepared = this.preparedTraversals.get(traversal)
    if (!prepared) return false
    this.preparedTraversals.delete(traversal)

    if (prepared.revision !== this.revision) return false

    const source = this.stackFor(prepared.direction)
    const next = source[source.length - 1]
    if (!next || !sameNavigationLocation(next, prepared.target)) return false

    source.pop()
    if (current && !sameNavigationLocation(current, prepared.target)) {
      const destination = prepared.direction === 'back' ? this.forwardStack : this.backStack
      this.pushUnique(destination, current)
    }
    this.revision += 1
    return true
  }

  /** Keep fallback paths usable when an open document is saved under a new path. */
  updateDocumentPath(docId: string, nextPath: string | null): void {
    this.rewriteLocations((location) => location.docId === docId ? { ...location, path: nextPath } : location)
  }

  /** Rewrite file and directory descendants after an in-app rename or move. */
  rewritePathPrefix(source: string, target: string): void {
    this.rewriteLocations((location) => {
      if (!location.path || !this.isPathWithin(location.path, source)) return location
      return { ...location, path: location.path === source ? target : `${target}${location.path.slice(source.length)}` }
    })
  }

  /** Remove locations made permanently unreachable by closing an untitled doc. */
  removeDocument(docId: string): void {
    this.filterLocations((location) => location.docId !== docId)
  }

  /** Remove a deleted file or directory and all of its descendants. */
  removePathPrefix(target: string): void {
    this.filterLocations((location) => !location.path || !this.isPathWithin(location.path, target))
  }

  private stackFor(direction: NavigationDirection): NavigationLocation[] {
    return direction === 'back' ? this.backStack : this.forwardStack
  }

  private pushUnique(stack: NavigationLocation[], location: NavigationLocation): void {
    const previous = stack[stack.length - 1]
    if (previous && sameNavigationLocation(previous, location)) return

    stack.push(copyLocation(location))
    if (stack.length > this.capacity) stack.shift()
  }

  private rewriteLocations(mapper: (location: NavigationLocation) => NavigationLocation): void {
    let changed = false
    for (const stack of [this.backStack, this.forwardStack]) {
      for (let index = 0; index < stack.length; index += 1) {
        const next = mapper(stack[index])
        if (!sameStoredLocation(next, stack[index])) {
          stack[index] = copyLocation(next)
          changed = true
        }
      }
    }
    if (changed) this.revision += 1
  }

  private filterLocations(keep: (location: NavigationLocation) => boolean): void {
    let changed = false
    for (const stack of [this.backStack, this.forwardStack]) {
      for (let index = stack.length - 1; index >= 0; index -= 1) {
        if (keep(stack[index])) continue
        stack.splice(index, 1)
        changed = true
      }
    }
    if (changed) this.revision += 1
  }

  private isPathWithin(candidate: string, parent: string): boolean {
    return candidate === parent || candidate.startsWith(`${parent}/`) || candidate.startsWith(`${parent}\\`)
  }
}
