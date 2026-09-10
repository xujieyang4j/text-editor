import Foundation

/// Immutable input captured immediately before an editing command is planned.
/// All positions use UTF-16 offsets, matching AppKit and CodeMirror.
public struct EditingCommandSnapshot: Equatable, Sendable {
    public var text: String
    public var selection: SelectionSet
    public var language: String
    public var tabWidth: Int
    public var indentWidth: Int
    public var insertSpaces: Bool
    public var expectedRevision: UInt64?
    /// Optional parser result for this exact text revision. Invalid or stale
    /// snapshots are ignored and the bounded lexical implementation remains
    /// available as a fallback.
    public var parsedSyntax: ParsedSyntaxSnapshot?

    public init(
        text: String,
        selection: SelectionSet,
        language: String = "Plain Text",
        tabWidth: Int = 4,
        indentWidth: Int? = nil,
        insertSpaces: Bool = true,
        expectedRevision: UInt64? = nil,
        parsedSyntax: ParsedSyntaxSnapshot? = nil
    ) {
        self.text = text
        self.selection = selection
        self.language = language
        self.tabWidth = tabWidth
        self.indentWidth = indentWidth ?? tabWidth
        self.insertSpaces = insertSpaces
        self.expectedRevision = expectedRevision
        self.parsedSyntax = parsedSyntax
    }
}

public typealias EditorCommandSnapshot = EditingCommandSnapshot

public struct EditingCommandLimits: Equatable, Sendable {
    public static let defaultMaximumDocumentUTF16Length = 200_000_000
    public static let defaultMaximumSelections = 10_000
    public static let defaultMaximumEdits = 10_000
    public static let standard = EditingCommandLimits()
    public static var `default`: EditingCommandLimits { standard }
    public static let defaultValue = standard

    public var maximumDocumentUTF16Length: Int
    public var maximumSelections: Int
    public var maximumEdits: Int

    public init(
        maximumDocumentUTF16Length: Int = Self.defaultMaximumDocumentUTF16Length,
        maximumSelections: Int = Self.defaultMaximumSelections,
        maximumEdits: Int = Self.defaultMaximumEdits
    ) {
        precondition(maximumDocumentUTF16Length >= 0)
        precondition(maximumSelections >= 1)
        precondition(maximumEdits >= 1)
        self.maximumDocumentUTF16Length = maximumDocumentUTF16Length
        self.maximumSelections = maximumSelections
        self.maximumEdits = maximumEdits
    }
}

public enum EditingCommandError: Error, Equatable, LocalizedError, Sendable {
    case invalidSelection
    case documentTooLarge(actual: Int, maximum: Int)
    case tooManySelections(actual: Int, maximum: Int)
    case tooManyEdits(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "The editor selection is outside the document."
        case let .documentTooLarge(actual, maximum):
            return "The document has \(actual) UTF-16 units; the maximum is \(maximum)."
        case let .tooManySelections(actual, maximum):
            return "The command produced \(actual) selections; the maximum is \(maximum)."
        case let .tooManyEdits(actual, maximum):
            return "The command produced \(actual) edits; the maximum is \(maximum)."
        }
    }
}

public enum EditingCommandPlan: Equatable, Sendable {
    case transaction(TextTransaction)
    case noChange
    case unsupported

    public var transaction: TextTransaction? {
        guard case let .transaction(transaction) = self else { return nil }
        return transaction
    }
}

public struct EditingCommentSyntax: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public let open: String
        public let close: String

        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    public let line: String?
    public let block: Block?

    public init(line: String? = nil, block: Block? = nil) {
        self.line = line
        self.block = block
    }
}

/// History for selection-only commands. Text commands clear this state so an
/// explicit selection undo can never fall through to document text history.
public struct EditingSelectionHistory: Equatable, Sendable {
    public let capacity: Int
    public private(set) var undoSelections: [SelectionSet]
    public private(set) var redoSelections: [SelectionSet]

    public init(capacity: Int = 100) {
        precondition(capacity >= 1)
        self.capacity = capacity
        self.undoSelections = []
        self.redoSelections = []
    }

    public var canUndo: Bool { !undoSelections.isEmpty }
    public var canRedo: Bool { !redoSelections.isEmpty }

    public mutating func record(from previous: SelectionSet, to next: SelectionSet) {
        guard previous != next else { return }
        if undoSelections.last != previous {
            undoSelections.append(previous)
            if undoSelections.count > capacity { undoSelections.removeFirst() }
        }
        redoSelections.removeAll(keepingCapacity: true)
    }

    public mutating func undo(current: SelectionSet) -> SelectionSet? {
        guard let previous = undoSelections.popLast() else { return nil }
        redoSelections.append(current)
        if redoSelections.count > capacity { redoSelections.removeFirst() }
        return previous
    }

    public mutating func redo(current: SelectionSet) -> SelectionSet? {
        guard let next = redoSelections.popLast() else { return nil }
        undoSelections.append(current)
        if undoSelections.count > capacity { undoSelections.removeFirst() }
        return next
    }

    public mutating func clear() {
        undoSelections.removeAll(keepingCapacity: true)
        redoSelections.removeAll(keepingCapacity: true)
    }
}

/// Stateful command planner. Its only state is selection-only undo/redo; text
/// history remains owned by DocumentBuffer.
public struct EditingCommandPlanner: Equatable, Sendable {
    private struct ExpansionFrame: Equatable, Sendable {
        let before: SelectionSet
        let after: SelectionSet
        let document: String
    }

    public var limits: EditingCommandLimits
    public private(set) var selectionHistory: EditingSelectionHistory
    private var expansionHistory: [ExpansionFrame]
    private var expansionTextUnits: Int

    public init(
        limits: EditingCommandLimits = .standard,
        selectionHistoryCapacity: Int = 100
    ) {
        self.limits = limits
        self.selectionHistory = EditingSelectionHistory(capacity: selectionHistoryCapacity)
        self.expansionHistory = []
        self.expansionTextUnits = 0
    }

    public var canShrinkSelection: Bool { !expansionHistory.isEmpty }

    public mutating func resetSelectionHistory() {
        selectionHistory.clear()
        expansionHistory.removeAll(keepingCapacity: true)
        expansionTextUnits = 0
    }

    public mutating func recordSelectionChange(
        from previous: SelectionSet,
        to next: SelectionSet
    ) {
        guard previous != next else { return }
        selectionHistory.record(from: previous, to: next)
        // Electron clears its Expand Selection stack on every unrelated
        // selection update. Native mouse and keyboard changes enter here.
        expansionHistory.removeAll(keepingCapacity: true)
        expansionTextUnits = 0
    }

    public mutating func plan(
        commandID: String,
        snapshot: EditingCommandSnapshot
    ) throws -> EditingCommandPlan {
        try EditingCommands.validate(snapshot, limits: limits)
        switch commandID {
        case "undo-selection":
            guard let selection = selectionHistory.undo(current: snapshot.selection) else {
                return .noChange
            }
            expansionHistory.removeAll(keepingCapacity: true)
            expansionTextUnits = 0
            return .transaction(try TextTransaction(
                edits: [], selection: selection, expectedRevision: snapshot.expectedRevision
            ))
        case "redo-selection":
            guard let selection = selectionHistory.redo(current: snapshot.selection) else {
                return .noChange
            }
            expansionHistory.removeAll(keepingCapacity: true)
            expansionTextUnits = 0
            return .transaction(try TextTransaction(
                edits: [], selection: selection, expectedRevision: snapshot.expectedRevision
            ))
        case "expand-selection":
            let result = try EditingCommands.plan(
                commandID: commandID, snapshot: snapshot, limits: limits
            )
            guard case let .transaction(transaction) = result,
                  transaction.edits.isEmpty, let next = transaction.selection else {
                return result
            }
            expansionHistory.append(ExpansionFrame(
                before: snapshot.selection, after: next, document: snapshot.text
            ))
            expansionTextUnits += snapshot.text.utf16.count
            if expansionHistory.count > selectionHistory.capacity {
                let removed = expansionHistory.removeFirst()
                expansionTextUnits -= removed.document.utf16.count
            }
            while expansionHistory.count > 1,
                  expansionTextUnits > limits.maximumDocumentUTF16Length {
                let removed = expansionHistory.removeFirst()
                expansionTextUnits -= removed.document.utf16.count
            }
            selectionHistory.record(from: snapshot.selection, to: next)
            return result
        case "shrink-selection":
            guard let frame = expansionHistory.last,
                  frame.after == snapshot.selection,
                  frame.document == snapshot.text else {
                expansionHistory.removeAll(keepingCapacity: true)
                expansionTextUnits = 0
                return .noChange
            }
            let removed = expansionHistory.removeLast()
            expansionTextUnits -= removed.document.utf16.count
            selectionHistory.record(from: snapshot.selection, to: frame.before)
            return .transaction(try TextTransaction(
                edits: [], selection: frame.before, expectedRevision: snapshot.expectedRevision
            ))
        default:
            let result = try EditingCommands.plan(
                commandID: commandID, snapshot: snapshot, limits: limits
            )
            if case let .transaction(transaction) = result {
                if transaction.edits.isEmpty, let next = transaction.selection {
                    selectionHistory.record(from: snapshot.selection, to: next)
                    expansionHistory.removeAll(keepingCapacity: true)
                    expansionTextUnits = 0
                } else if !transaction.edits.isEmpty {
                    selectionHistory.clear()
                    expansionHistory.removeAll(keepingCapacity: true)
                    expansionTextUnits = 0
                }
            }
            return result
        }
    }
}

public typealias EditorCommandPlanner = EditingCommandPlanner
public typealias EditorCommandPlan = EditingCommandPlan

/// Foundation-only planners for editing commands. Structural commands use a
/// bounded UTF-16 lexical model so they remain available without AppKit.
public enum EditingCommands {
    public static let maximumOccurrenceSelections = 10_000

    public static let unsupportedCommandIDs: Set<String> = []

    public static let supportedCommandIDs: Set<String> = [
        "toggle-comment", "toggle-block-comment", "move-line-up",
        "move-line-down", "copy-line-up", "copy-line-down", "delete-line",
        "duplicate-selection", "delete-word-backward", "delete-word-forward",
        "delete-to-line-start", "delete-to-line-end",
        "insert-blank-line-above", "insert-blank-line", "transpose-characters",
        "join-lines", "trim-trailing-whitespace", "indent-selection",
        "outdent-selection", "convert-indent-spaces", "convert-indent-tabs",
        "to-upper-case", "to-lower-case", "to-title-case", "swap-case",
        "sort-lines", "sort-lines-descending", "reverse-lines", "unique-lines",
        "remove-blank-lines", "wrap-paragraph-80", "unwrap-paragraph",
        "ensure-single-final-newline", "add-cursor-above", "add-cursor-below",
        "undo-selection", "redo-selection", "select-next-occurrence",
        "skip-current-occurrence", "remove-last-cursor", "select-all-occurrences",
        "add-cursors-line-starts", "add-cursors-line-ends", "select-line",
        "goto-matching-bracket", "select-matching-bracket", "select-parent-syntax",
        "expand-selection", "shrink-selection", "split-selection-lines",
        "reindent-selection"
    ]

    public static let selectionOnlyCommandIDs: Set<String> = [
        "add-cursor-above", "add-cursor-below", "undo-selection",
        "redo-selection", "select-next-occurrence", "skip-current-occurrence",
        "remove-last-cursor", "select-all-occurrences",
        "add-cursors-line-starts", "add-cursors-line-ends", "select-line",
        "goto-matching-bracket", "select-matching-bracket", "select-parent-syntax",
        "expand-selection", "shrink-selection", "split-selection-lines"
    ]

    public static let recognizedCommandIDs = supportedCommandIDs.union(unsupportedCommandIDs)

    public static var allCommandIDs: Set<String> { recognizedCommandIDs }

    public static func isSupported(commandID: String) -> Bool {
        supportedCommandIDs.contains(commandID)
    }

    public static func plan(
        _ commandID: String,
        snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits = .standard
    ) throws -> EditingCommandPlan {
        try plan(commandID: commandID, snapshot: snapshot, limits: limits)
    }

    public static func commentSyntax(for language: String) -> EditingCommentSyntax? {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "c", "c++", "c#", "objective-c", "objective-c++",
             "java", "javascript", "jsx", "typescript", "tsx",
             "swift", "rust", "go", "dart", "kotlin", "scala",
             "groovy", "glsl", "jsonc":
            return EditingCommentSyntax(
                line: "//", block: .init(open: "/*", close: "*/")
            )
        case "css", "scss", "less":
            return EditingCommentSyntax(block: .init(open: "/*", close: "*/"))
        case "html", "xml", "vue", "markdown":
            return EditingCommentSyntax(block: .init(open: "<!--", close: "-->"))
        case "python", "ruby", "shell", "shell script", "bash",
             "yaml", "toml", "dockerfile", "r", "perl":
            return EditingCommentSyntax(line: "#")
        case "sql":
            return EditingCommentSyntax(
                line: "--", block: .init(open: "/*", close: "*/")
            )
        case "lua":
            return EditingCommentSyntax(
                line: "--", block: .init(open: "--[[", close: "]]--")
            )
        case "haskell":
            return EditingCommentSyntax(
                line: "--", block: .init(open: "{-", close: "-}")
            )
        case "clojure", "common lisp", "scheme":
            return EditingCommentSyntax(line: ";;")
        case "erlang", "elixir", "latex", "stex":
            return EditingCommentSyntax(line: "%")
        case "powershell":
            return EditingCommentSyntax(
                line: "#", block: .init(open: "<#", close: "#>")
            )
        default:
            return nil
        }
    }

    public static func toggleLineComment(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits = .standard
    ) throws -> TextTransaction? {
        try validate(snapshot, limits: limits)
        guard let token = commentSyntax(for: snapshot.language)?.line else { return nil }
        return try toggleLineComment(snapshot, token: token, limits: limits)
    }

    public static func toggleBlockComment(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits = .standard
    ) throws -> TextTransaction? {
        try validate(snapshot, limits: limits)
        guard let syntax = commentSyntax(for: snapshot.language)?.block else { return nil }
        return try toggleBlockComment(
            snapshot,
            syntax: syntax,
            ranges: snapshot.selection.ranges,
            limits: limits
        )
    }

    public static func plan(
        commandID: String,
        snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits = .standard
    ) throws -> EditingCommandPlan {
        try validate(snapshot, limits: limits)
        guard supportedCommandIDs.contains(commandID) else { return .unsupported }
        if commandID == "undo-selection" || commandID == "redo-selection" {
            return .noChange
        }

        let transaction: TextTransaction?
        switch commandID {
        case "toggle-comment":
            transaction = try toggleComment(snapshot, blockOnly: false, limits: limits)
        case "toggle-block-comment":
            transaction = try toggleComment(snapshot, blockOnly: true, limits: limits)
        case "move-line-up":
            transaction = try moveLines(snapshot, down: false, limits: limits)
        case "move-line-down":
            transaction = try moveLines(snapshot, down: true, limits: limits)
        case "copy-line-up":
            transaction = try copyLines(snapshot, down: false, limits: limits)
        case "copy-line-down":
            transaction = try copyLines(snapshot, down: true, limits: limits)
        case "delete-line":
            transaction = try deleteLines(snapshot, limits: limits)
        case "duplicate-selection":
            transaction = try duplicate(snapshot, limits: limits)
        case "delete-word-backward":
            transaction = try deleteWord(snapshot, forward: false, limits: limits)
        case "delete-word-forward":
            transaction = try deleteWord(snapshot, forward: true, limits: limits)
        case "delete-to-line-start":
            transaction = try deleteToLineBoundary(snapshot, end: false, limits: limits)
        case "delete-to-line-end":
            transaction = try deleteToLineBoundary(snapshot, end: true, limits: limits)
        case "insert-blank-line-above":
            transaction = try insertBlankLines(snapshot, below: false, limits: limits)
        case "insert-blank-line":
            transaction = try insertBlankLines(snapshot, below: true, limits: limits)
        case "transpose-characters":
            transaction = try transpose(snapshot, limits: limits)
        case "join-lines":
            transaction = try joinLines(snapshot, limits: limits)
        case "trim-trailing-whitespace":
            transaction = try trimTrailingWhitespace(snapshot, limits: limits)
        case "indent-selection":
            transaction = try indent(snapshot, outdent: false, limits: limits)
        case "outdent-selection":
            transaction = try indent(snapshot, outdent: true, limits: limits)
        case "reindent-selection":
            transaction = try reindent(snapshot, limits: limits)
        case "convert-indent-spaces":
            transaction = try convertIndentation(snapshot, toTabs: false, limits: limits)
        case "convert-indent-tabs":
            transaction = try convertIndentation(snapshot, toTabs: true, limits: limits)
        case "to-upper-case":
            transaction = try transformed(snapshot, caseKind: .upper, limits: limits)
        case "to-lower-case":
            transaction = try transformed(snapshot, caseKind: .lower, limits: limits)
        case "to-title-case":
            transaction = try transformed(snapshot, caseKind: .title, limits: limits)
        case "swap-case":
            transaction = try transformed(snapshot, caseKind: .swap, limits: limits)
        case "sort-lines":
            transaction = try transformed(snapshot, lineMode: .sortAscending, limits: limits)
        case "sort-lines-descending":
            transaction = try transformed(snapshot, lineMode: .sortDescending, limits: limits)
        case "reverse-lines":
            transaction = try transformed(snapshot, lineMode: .reverse, limits: limits)
        case "unique-lines":
            transaction = try transformed(snapshot, lineMode: .unique, limits: limits)
        case "remove-blank-lines":
            transaction = try transformed(snapshot, lineMode: .removeBlank, limits: limits)
        case "wrap-paragraph-80":
            transaction = try transformed(snapshot, paragraphMode: .wrap, limits: limits)
        case "unwrap-paragraph":
            transaction = try transformed(snapshot, paragraphMode: .unwrap, limits: limits)
        case "ensure-single-final-newline":
            transaction = try finalNewline(snapshot, limits: limits)
        case "add-cursor-above":
            transaction = try verticalCursors(snapshot, below: false, limits: limits)
        case "add-cursor-below":
            transaction = try verticalCursors(snapshot, below: true, limits: limits)
        case "select-next-occurrence":
            transaction = try selectNextOccurrence(snapshot, skip: false, limits: limits)
        case "skip-current-occurrence":
            transaction = try selectNextOccurrence(snapshot, skip: true, limits: limits)
        case "remove-last-cursor":
            transaction = try removeMainSelection(snapshot)
        case "select-all-occurrences":
            transaction = try selectAllOccurrences(snapshot, limits: limits)
        case "add-cursors-line-starts":
            transaction = try lineBoundaryCursors(snapshot, atEnd: false, limits: limits)
        case "add-cursors-line-ends":
            transaction = try lineBoundaryCursors(snapshot, atEnd: true, limits: limits)
        case "select-line":
            transaction = try selectLines(snapshot, limits: limits)
        case "goto-matching-bracket":
            transaction = try matchingBrackets(snapshot, extend: false, limits: limits)
        case "select-matching-bracket":
            transaction = try matchingBrackets(snapshot, extend: true, limits: limits)
        case "select-parent-syntax":
            transaction = try selectParentSyntax(snapshot, limits: limits)
        case "expand-selection":
            transaction = try expandSelection(snapshot, limits: limits)
        case "shrink-selection":
            // Exact shrink semantics require planner-owned expansion history.
            transaction = nil
        case "split-selection-lines":
            transaction = try splitSelectionLines(snapshot, limits: limits)
        default:
            return .unsupported
        }
        return transaction.map(EditingCommandPlan.transaction) ?? .noChange
    }

    public static func transaction(
        for commandID: String,
        snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits = .standard
    ) throws -> TextTransaction? {
        try plan(commandID: commandID, snapshot: snapshot, limits: limits).transaction
    }

    fileprivate static func validate(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws {
        let length = snapshot.text.utf16.count
        guard length <= limits.maximumDocumentUTF16Length else {
            throw EditingCommandError.documentTooLarge(
                actual: length, maximum: limits.maximumDocumentUTF16Length
            )
        }
        guard snapshot.selection.ranges.count <= limits.maximumSelections else {
            throw EditingCommandError.tooManySelections(
                actual: snapshot.selection.ranges.count, maximum: limits.maximumSelections
            )
        }
        guard snapshot.selection.isValid(forUTF16Length: length) else {
            throw EditingCommandError.invalidSelection
        }
    }
}

private struct EditingLine {
    let number: Int
    let from: Int
    let to: Int
    let text: String
}

private struct EditingLineBlock {
    var firstLine: Int
    var lastLine: Int
    var rangeIndexes: [Int]
}

/// A conservative structural approximation of CodeMirror's syntax-tree
/// parents. The scanner is deliberately linear and recognizes only balanced
/// delimiters outside strings/comments. It never guesses across malformed
/// constructs, which makes selection expansion predictable for partially
/// written source while retaining a bounded Foundation-only core.
private struct EditingSyntaxStructure {
    struct Pair: Equatable {
        let from: Int
        let to: Int
    }

    struct LexicalContainer: Equatable {
        let innerFrom: Int
        let innerTo: Int
        let outerFrom: Int
        let outerTo: Int

        var inner: DirectedSelection {
            DirectedSelection(anchor: innerFrom, head: innerTo)
        }

        var outer: DirectedSelection {
            DirectedSelection(anchor: outerFrom, head: outerTo)
        }
    }

    private struct Entry {
        let unit: UInt16
        let position: Int
    }

    private enum QuoteStyle {
        case single
        case double
        case backtick
    }

    let pairs: [Pair]
    let lexicalContainers: [LexicalContainer]

    init(units: [UInt16], language: String) {
        let syntax = EditingCommands.commentSyntax(for: language)
        let lineComment = syntax?.line.map { Array($0.utf16) }
        let blockCommentOpen = syntax?.block.map { Array($0.open.utf16) }
        let blockCommentClose = syntax?.block.map { Array($0.close.utf16) }
        var stack: [Entry] = []
        var result: [Pair] = []
        var containers: [LexicalContainer] = []
        result.reserveCapacity(min(units.count / 8, 10_000))
        let maximumPairs = min(100_000, max(1, units.count / 2))
        let maximumNestingDepth = 4_096
        var ignoredDepth = 0
        var quote: QuoteStyle?
        var quoteStart: Int?
        var escaped = false
        var inLineComment = false
        var lineCommentStart: Int?
        var lineCommentInnerStart: Int?
        var inBlockComment = false
        var blockCommentStart: Int?
        var blockCommentInnerStart: Int?
        var index = 0

        while index < units.count {
            let unit = units[index]
            if inLineComment {
                if unit == 0x0a || unit == 0x0d {
                    if let start = lineCommentStart, let innerStart = lineCommentInnerStart {
                        containers.append(LexicalContainer(
                            innerFrom: min(index, innerStart),
                            innerTo: index,
                            outerFrom: start,
                            outerTo: index
                        ))
                    }
                    inLineComment = false
                    lineCommentStart = nil
                    lineCommentInnerStart = nil
                }
                index += 1
                continue
            }
            if inBlockComment {
                if let blockCommentClose,
                   Self.matches(blockCommentClose, at: index, in: units) {
                    let closeLength = blockCommentClose.count
                    if let start = blockCommentStart, let innerStart = blockCommentInnerStart {
                        containers.append(LexicalContainer(
                            innerFrom: min(index, innerStart),
                            innerTo: index,
                            outerFrom: start,
                            outerTo: index + closeLength
                        ))
                    }
                    inBlockComment = false
                    blockCommentStart = nil
                    blockCommentInnerStart = nil
                    index += closeLength
                } else {
                    index += 1
                }
                continue
            }
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if unit == 0x5c {
                    escaped = true
                } else if unit == Self.quoteUnit(activeQuote) {
                    if let start = quoteStart {
                        containers.append(LexicalContainer(
                            innerFrom: min(index, start + 1),
                            innerTo: index,
                            outerFrom: start,
                            outerTo: index + 1
                        ))
                    }
                    quote = nil
                    quoteStart = nil
                }
                index += 1
                continue
            }
            if let blockCommentOpen,
               blockCommentClose != nil,
               Self.matches(blockCommentOpen, at: index, in: units) {
                inBlockComment = true
                blockCommentStart = index
                blockCommentInnerStart = index + blockCommentOpen.count
                index += blockCommentOpen.count
                continue
            }
            if let lineComment, Self.matches(lineComment, at: index, in: units) {
                inLineComment = true
                lineCommentStart = index
                lineCommentInnerStart = index + lineComment.count
                index += lineComment.count
                continue
            }
            switch unit {
            case 0x22:
                quote = .double
                quoteStart = index
            case 0x27:
                quote = .single
                quoteStart = index
            case 0x60:
                quote = .backtick
                quoteStart = index
            case 0x28, 0x5b, 0x7b:
                if ignoredDepth > 0 {
                    ignoredDepth += 1
                } else if stack.count < maximumNestingDepth {
                    stack.append(Entry(unit: unit, position: index))
                } else {
                    ignoredDepth = 1
                }
            case 0x29, 0x5d, 0x7d:
                if ignoredDepth > 0 {
                    ignoredDepth -= 1
                } else if let opening = Self.matchingOpening(unit),
                   let last = stack.last, last.unit == opening {
                    stack.removeLast()
                    if result.count < maximumPairs {
                        result.append(Pair(from: last.position, to: index + 1))
                    }
                } else if !stack.isEmpty {
                    // A mismatched closer discards only the innermost pending
                    // branch so valid outer delimiters remain usable.
                    stack.removeLast()
                }
            default:
                break
            }
            index += 1
        }
        if inLineComment, let start = lineCommentStart, let innerStart = lineCommentInnerStart {
            containers.append(LexicalContainer(
                innerFrom: min(units.count, innerStart),
                innerTo: units.count,
                outerFrom: start,
                outerTo: units.count
            ))
        }
        if inBlockComment, let start = blockCommentStart, let innerStart = blockCommentInnerStart {
            containers.append(LexicalContainer(
                innerFrom: min(units.count, innerStart),
                innerTo: units.count,
                outerFrom: start,
                outerTo: units.count
            ))
        }
        if quote != nil, let start = quoteStart {
            containers.append(LexicalContainer(
                innerFrom: min(units.count, start + 1),
                innerTo: units.count,
                outerFrom: start,
                outerTo: units.count
            ))
        }
        pairs = result.sorted { left, right in
            if left.from != right.from { return left.from < right.from }
            return left.to > right.to
        }
        lexicalContainers = containers.sorted { left, right in
            if left.outerFrom != right.outerFrom { return left.outerFrom < right.outerFrom }
            return left.outerTo > right.outerTo
        }
    }

    func parent(of range: DirectedSelection) -> DirectedSelection? {
        var best: DirectedSelection?

        func consider(_ candidate: DirectedSelection) {
            guard candidate.from <= range.from, candidate.to >= range.to,
                  candidate.from < range.from || candidate.to > range.to else { return }
            guard let current = best else {
                best = candidate
                return
            }
            let candidateLength = candidate.to - candidate.from
            let currentLength = current.to - current.from
            if candidateLength < currentLength
                || (candidateLength == currentLength && candidate.from > current.from) {
                best = candidate
            }
        }

        for pair in pairs {
            let innerStart = pair.from + 1
            let innerEnd = max(innerStart, pair.to - 1)
            consider(DirectedSelection(anchor: innerStart, head: innerEnd))
            consider(DirectedSelection(anchor: pair.from, head: pair.to))
        }
        for container in lexicalContainers {
            consider(container.inner)
            consider(container.outer)
        }
        return best
    }

    func lexicalParent(of range: DirectedSelection) -> DirectedSelection? {
        for container in lexicalContainers {
            if range.isEmpty,
               container.inner.from <= range.from, container.inner.to >= range.to,
               container.inner.from < range.from || container.inner.to > range.to {
                return container.inner
            }
            if !range.isEmpty, range == container.inner {
                return container.outer
            }
        }
        return nil
    }

    func pairParent(of range: DirectedSelection, includeInner: Bool) -> DirectedSelection? {
        var best: DirectedSelection?

        func consider(_ candidate: DirectedSelection) {
            guard candidate.from <= range.from, candidate.to >= range.to,
                  candidate.from < range.from || candidate.to > range.to else { return }
            guard let current = best else {
                best = candidate
                return
            }
            let candidateLength = candidate.to - candidate.from
            let currentLength = current.to - current.from
            if candidateLength < currentLength
                || (candidateLength == currentLength && candidate.from > current.from) {
                best = candidate
            }
        }

        for pair in pairs {
            if includeInner {
                let innerStart = pair.from + 1
                let innerEnd = max(innerStart, pair.to - 1)
                consider(DirectedSelection(anchor: innerStart, head: innerEnd))
            }
            consider(DirectedSelection(anchor: pair.from, head: pair.to))
        }
        return best
    }

    func matchingBracket(at position: Int) -> (match: Int, opening: Bool)? {
        for pair in pairs {
            if pair.from == position { return (pair.to - 1, true) }
            if pair.to - 1 == position { return (pair.from, false) }
        }
        return nil
    }

    private static func matchingOpening(_ closing: UInt16) -> UInt16? {
        switch closing {
        case 0x29: 0x28
        case 0x5d: 0x5b
        case 0x7d: 0x7b
        default: nil
        }
    }

    private static func quoteUnit(_ quote: QuoteStyle) -> UInt16 {
        switch quote {
        case .single: 0x27
        case .double: 0x22
        case .backtick: 0x60
        }
    }

    private static func matches(_ token: [UInt16], at index: Int, in units: [UInt16]) -> Bool {
        guard !token.isEmpty, index >= 0, index + token.count <= units.count else { return false }
        return units[index ..< index + token.count].elementsEqual(token)
    }
}

private struct EditingUTF16Document {
    let units: [UInt16]
    let lines: [EditingLine]

    init(_ text: String) {
        let units = Array(text.utf16)
        self.units = units
        var starts = [0]
        for index in units.indices where units[index] == 0x0a {
            starts.append(index + 1)
        }
        lines = starts.enumerated().map { number, from in
            let next = number + 1 < starts.count ? starts[number + 1] : units.count + 1
            let to = number + 1 < starts.count ? next - 1 : units.count
            return EditingLine(
                number: number,
                from: from,
                to: to,
                text: String(decoding: units[from ..< to], as: UTF16.self)
            )
        }
    }

    var length: Int { units.count }

    func lineIndex(at position: Int) -> Int {
        let position = min(length, max(0, position))
        var low = 0
        var high = lines.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lines[middle].from <= position { low = middle } else { high = middle }
        }
        return low
    }

    func string(from: Int, to: Int) -> String {
        String(decoding: units[from ..< to], as: UTF16.self)
    }

    func selectedLineIndexes(for range: DirectedSelection) -> ClosedRange<Int> {
        let first = lineIndex(at: range.from)
        var endpoint = range.to
        if !range.isEmpty, endpoint > 0, lines[lineIndex(at: endpoint)].from == endpoint {
            endpoint -= 1
        }
        return first ... lineIndex(at: endpoint)
    }

    func selectedLineBlocks(
        for selection: SelectionSet,
        mergeAdjacent: Bool = true
    ) -> [EditingLineBlock] {
        var blocks: [EditingLineBlock] = []
        for (rangeIndex, range) in selection.ranges.enumerated() {
            let covered = selectedLineIndexes(for: range)
            let overlapLimit = (blocks.last?.lastLine ?? -2) + (mergeAdjacent ? 1 : 0)
            if let last = blocks.last, covered.lowerBound <= overlapLimit {
                blocks[blocks.count - 1].lastLine = max(last.lastLine, covered.upperBound)
                blocks[blocks.count - 1].rangeIndexes.append(rangeIndex)
            } else {
                blocks.append(EditingLineBlock(
                    firstLine: covered.lowerBound,
                    lastLine: covered.upperBound,
                    rangeIndexes: [rangeIndex]
                ))
            }
        }
        return blocks
    }
}

private extension EditingCommands {
    static func deleteWord(
        _ snapshot: EditingCommandSnapshot,
        forward: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let edits = mergeDeletionEdits(snapshot.selection.ranges.map { range in
            guard range.isEmpty else {
                return TextEdit(from: range.from, to: range.to, insert: "")
            }
            let target = wordDeletionTarget(
                from: range.head,
                forward: forward,
                in: document
            )
            return TextEdit(
                from: min(range.head, target),
                to: max(range.head, target),
                insert: ""
            )
        })
        return try transactionMappingSelection(
            edits: edits, snapshot: snapshot, limits: limits
        )
    }

    static func verticalCursors(
        _ snapshot: EditingCommandSnapshot,
        below: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var ranges = snapshot.selection.ranges
        var existingHeads = Set(ranges.map(\.head))
        var added: [DirectedSelection] = []
        for range in snapshot.selection.ranges {
            let lineIndex = document.lineIndex(at: range.head)
            let targetIndex = below ? lineIndex + 1 : lineIndex - 1
            guard document.lines.indices.contains(targetIndex) else { continue }
            let line = document.lines[lineIndex]
            let target = document.lines[targetIndex]
            let column = max(0, range.head - line.from)
            let position = min(target.to, target.from + column)
            if existingHeads.insert(position).inserted {
                added.append(DirectedSelection(anchor: position, head: position))
            }
        }
        guard !added.isEmpty else { return nil }
        ranges.append(contentsOf: added)
        return try selectionTransaction(
            SelectionSet(ranges: ranges, mainIndex: ranges.count - 1),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func selectNextOccurrence(
        _ snapshot: EditingCommandSnapshot,
        skip: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var selection = snapshot.selection
        if selection.ranges.contains(where: \.isEmpty) {
            var ranges = selection.ranges
            for index in ranges.indices where ranges[index].isEmpty {
                if let word = wordRange(at: ranges[index].head, in: document) {
                    ranges[index] = word
                }
            }
            selection = SelectionSet(ranges: ranges, mainIndex: selection.mainIndex)
            return try selectionTransaction(selection, snapshot: snapshot, limits: limits)
        }

        let current = selection.main
        let selected = document.string(from: current.from, to: current.to)
        guard !selected.isEmpty,
              selection.ranges.allSatisfy({
                  document.string(from: $0.from, to: $0.to) == selected
              }) else { return nil }
        let wholeWord = wordRange(at: current.from, in: document).map {
            $0.from == current.from && $0.to == current.to
        } ?? false
        guard let match = nextOccurrence(
            of: selected,
            after: selection.ranges.last?.to ?? current.to,
            wrappingBefore: max(0, (selection.ranges.last?.from ?? current.from) - 1),
            in: document,
            excluding: selection.ranges,
            wholeWord: wholeWord
        ) else { return nil }

        var ranges = selection.ranges
        let mainIndex: Int
        if skip {
            ranges[selection.mainIndex] = match
            mainIndex = selection.mainIndex
        } else {
            ranges.append(match)
            mainIndex = ranges.count - 1
        }
        return try selectionTransaction(
            SelectionSet(ranges: ranges, mainIndex: mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func removeMainSelection(
        _ snapshot: EditingCommandSnapshot
    ) throws -> TextTransaction? {
        guard snapshot.selection.ranges.count > 1 else { return nil }
        var ranges = snapshot.selection.ranges
        ranges.remove(at: snapshot.selection.mainIndex)
        let mainIndex = snapshot.selection.mainIndex == 0
            ? ranges.count - 1 : snapshot.selection.mainIndex - 1
        return try TextTransaction(
            edits: [],
            selection: SelectionSet(ranges: ranges, mainIndex: mainIndex),
            expectedRevision: snapshot.expectedRevision
        )
    }

    static func selectAllOccurrences(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let main = snapshot.selection.main
        let selectedRange: DirectedSelection
        let wholeWord: Bool
        if main.isEmpty {
            guard let word = wordRange(at: main.head, in: document) else { return nil }
            selectedRange = word
            wholeWord = true
        } else {
            selectedRange = main
            wholeWord = false
        }
        let needle = document.string(from: selectedRange.from, to: selectedRange.to)
        guard !needle.isEmpty else { return nil }
        let needleUnits = Array(needle.utf16)
        var ranges: [DirectedSelection] = []
        var index = 0
        let maximum = min(maximumOccurrenceSelections, limits.maximumSelections)
        while index <= document.length - needleUnits.count, ranges.count < maximum {
            guard let found = firstOccurrence(
                of: needleUnits, in: document.units, from: index, before: document.length
            ) else { break }
            let match = DirectedSelection(anchor: found, head: found + needleUnits.count)
            if !wholeWord || isWholeWord(match, in: document.units) {
                ranges.append(match)
                index = match.to
            } else {
                index = found + 1
            }
        }
        guard !ranges.isEmpty else { return nil }
        return try selectionTransaction(
            SelectionSet(ranges: ranges), snapshot: snapshot, limits: limits
        )
    }

    static func lineBoundaryCursors(
        _ snapshot: EditingCommandSnapshot,
        atEnd: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var positions = Set<Int>()
        var mainPosition: Int?
        for (rangeIndex, range) in snapshot.selection.ranges.enumerated() {
            for index in document.selectedLineIndexes(for: range) {
                let line = document.lines[index]
                positions.insert(atEnd ? line.to : line.from)
            }
            if rangeIndex == snapshot.selection.mainIndex {
                var head = range.head
                let lineIndex = document.lineIndex(at: head)
                if !range.isEmpty, range.head == range.to,
                   document.lines[lineIndex].from == range.head, range.head > 0 {
                    head -= 1
                }
                let line = document.lines[document.lineIndex(at: head)]
                mainPosition = atEnd ? line.to : line.from
            }
        }
        let ordered = positions.sorted()
        guard !ordered.isEmpty else { return nil }
        let ranges = ordered.map { DirectedSelection(anchor: $0, head: $0) }
        let mainIndex = mainPosition.flatMap { ordered.firstIndex(of: $0) } ?? 0
        let selection = SelectionSet(ranges: ranges, mainIndex: mainIndex)
        guard selection != snapshot.selection else { return nil }
        return try selectionTransaction(selection, snapshot: snapshot, limits: limits)
    }

    static func selectLines(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let blocks = document.selectedLineBlocks(for: snapshot.selection)
        let ranges = blocks.map { block -> DirectedSelection in
            let from = document.lines[block.firstLine].from
            let last = document.lines[block.lastLine]
            let to = min(document.length, last.to + (last.to < document.length ? 1 : 0))
            return DirectedSelection(anchor: from, head: to)
        }
        let mainBlock = blocks.firstIndex {
            $0.rangeIndexes.contains(snapshot.selection.mainIndex)
        } ?? 0
        let selection = SelectionSet(ranges: ranges, mainIndex: mainBlock)
        guard selection != snapshot.selection else { return nil }
        return try selectionTransaction(selection, snapshot: snapshot, limits: limits)
    }

    static func splitSelectionLines(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var positions = Set<Int>()
        var mainPosition: Int?
        var found = false
        for (rangeIndex, range) in snapshot.selection.ranges.enumerated() where !range.isEmpty {
            found = true
            for index in document.selectedLineIndexes(for: range) {
                let position = document.lines[index].from
                positions.insert(position)
                if rangeIndex == snapshot.selection.mainIndex, mainPosition == nil {
                    mainPosition = position
                }
            }
        }
        guard found else { return nil }
        let ordered = positions.sorted()
        let ranges = ordered.map { DirectedSelection(anchor: $0, head: $0) }
        let mainIndex = mainPosition.flatMap { ordered.firstIndex(of: $0) } ?? 0
        return try selectionTransaction(
            SelectionSet(ranges: ranges, mainIndex: mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func matchingBrackets(
        _ snapshot: EditingCommandSnapshot,
        extend: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let units = Array(snapshot.text.utf16)
        let parsed = usableParsedSyntax(snapshot).flatMap {
            $0.bracketPairsWereTruncated ? nil : $0
        }
        let structure = parsed == nil
            ? EditingSyntaxStructure(units: units, language: snapshot.language) : nil
        var found = false
        let ranges = snapshot.selection.ranges.map { range -> DirectedSelection in
            for candidate in bracketCandidates(around: range.head, length: units.count) {
                let position = candidate.position
                let bracket = parsed?.matchingBracket(atUTF16Offset: position)
                    ?? structure?.matchingBracket(at: position)
                guard let bracket, bracket.opening == candidate.opening,
                      parsed == nil
                        || parsedBracketIsValid(bracket, at: position, units: units)
                else { continue }
                found = true
                let head = position == range.head ? bracket.match + 1 : bracket.match
                return extend
                    ? DirectedSelection(anchor: range.anchor, head: head)
                    : DirectedSelection(anchor: head, head: head)
            }
            return range
        }
        guard found else { return nil }
        return try selectionTransaction(
            SelectionSet(ranges: ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func selectParentSyntax(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let parsed = usableParsedSyntax(snapshot).flatMap {
            $0.nodesWereTruncated ? nil : $0
        }
        guard parsed != nil || hasSyntaxLanguage(snapshot.language) else { return nil }
        let document = EditingUTF16Document(snapshot.text)
        let structure = parsed == nil ? EditingSyntaxStructure(
            units: document.units, language: snapshot.language
        ) : nil
        var changed = false
        let ranges = snapshot.selection.ranges.map { range -> DirectedSelection in
            let parent = parsed?.parentRange(containing: range)
                ?? structure.flatMap { lexicalSyntaxRange(
                    containing: range, in: document, structure: $0
                ) }
            guard let parent else { return range }
            changed = true
            return parent
        }
        guard changed else { return nil }
        return try selectionTransaction(
            SelectionSet(ranges: ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func lexicalSyntaxRange(
        containing range: DirectedSelection,
        in document: EditingUTF16Document,
        structure: EditingSyntaxStructure
    ) -> DirectedSelection? {
        // When the cursor/selection is inside a string or comment, prefer that
        // lexical container over an identifier fragment inside it. Syntax-tree
        // commands treat literal/comment nodes as the immediate parent.
        if let lexical = structure.lexicalParent(of: range) {
            return lexical
        }
        if range.isEmpty {
            if let word = currentUnicodeWordRange(at: range.head, in: document) {
                return word
            }
        } else if let word = unicodeWordRange(at: range.head, in: document),
                  word.from <= range.from, word.to >= range.to,
                  word.from < range.from || word.to > range.to {
            return word
        }
        return structure.pairParent(of: range, includeInner: range.isEmpty)
    }

    static func expandSelection(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        if let syntax = try selectParentSyntax(snapshot, limits: limits) {
            return syntax
        }

        let document = EditingUTF16Document(snapshot.text)
        let ranges = snapshot.selection.ranges.map { range -> DirectedSelection in
            if let word = unicodeWordRange(at: range.head, in: document),
               word.from < range.from || word.to > range.to {
                return word
            }

            let first = document.lines[document.lineIndex(at: range.from)]
            let lastPosition: Int
            if !range.isEmpty, range.to > 0,
               document.lines[document.lineIndex(at: range.to)].from == range.to {
                lastPosition = range.to - 1
            } else {
                lastPosition = range.to
            }
            let last = document.lines[document.lineIndex(at: lastPosition)]
            let lineTo = min(
                document.length, last.to + (last.to < document.length ? 1 : 0)
            )
            if first.from < range.from || lineTo > range.to {
                return DirectedSelection(anchor: first.from, head: lineTo)
            }
            if range.from > 0 || range.to < document.length {
                return DirectedSelection(anchor: 0, head: document.length)
            }
            return range
        }
        return try selectionTransaction(
            SelectionSet(ranges: ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func selectionTransaction(
        _ selection: SelectionSet,
        snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        guard selection != snapshot.selection else { return nil }
        return try makeTransaction(
            edits: [], selection: selection, snapshot: snapshot, limits: limits
        )
    }

    static func transpose(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let source = snapshot.text as NSString
        var edits: [TextEdit] = []
        for range in snapshot.selection.ranges where range.isEmpty {
            let position = range.head
            guard position > 0, position < document.length else { continue }
            let line = document.lines[document.lineIndex(at: position)]
            let left: NSRange
            let right: NSRange
            if position == line.from {
                left = NSRange(location: position - 1, length: 1)
                right = composedRange(in: source, at: position, forward: true)
            } else if position == line.to {
                left = composedRange(in: source, at: position, forward: false)
                right = NSRange(location: position, length: 1)
            } else {
                left = composedRange(in: source, at: position, forward: false)
                right = composedRange(in: source, at: position, forward: true)
            }
            guard left.location != NSNotFound, right.location != NSNotFound else { continue }
            edits.append(TextEdit(
                from: left.location,
                to: NSMaxRange(right),
                insert: source.substring(with: right) + source.substring(with: left)
            ))
        }
        edits = nonOverlapping(edits)
        guard !edits.isEmpty else { return nil }
        return try transactionMappingSelection(
            edits: edits, snapshot: snapshot, limits: limits
        )
    }

    static func joinLines(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        struct Span { var from: Int; var to: Int }
        let spans: [Span] = snapshot.selection.ranges.compactMap { range in
            let first = document.lines[document.lineIndex(at: range.from)]
            if range.isEmpty {
                guard first.number + 1 < document.lines.count else { return nil }
                return Span(from: first.from, to: document.lines[first.number + 1].to)
            }
            let last = document.lines[document.lineIndex(at: range.to)]
            return Span(from: first.from, to: last.to)
        }.sorted { $0.from < $1.from }
        var merged: [Span] = []
        for span in spans {
            if let last = merged.last, span.from <= last.to {
                merged[merged.count - 1].to = max(last.to, span.to)
            } else {
                merged.append(span)
            }
        }
        let expression = try NSRegularExpression(pattern: #"\s*\n\s*"#)
        let edits = merged.compactMap { span -> TextEdit? in
            let value = document.string(from: span.from, to: span.to)
            let replacement = expression.stringByReplacingMatches(
                in: value,
                options: [],
                range: NSRange(location: 0, length: value.utf16.count),
                withTemplate: " "
            )
            guard replacement != value else { return nil }
            return TextEdit(from: span.from, to: span.to, insert: replacement)
        }
        let base = try TextTransaction(edits: edits)
        let cursors = edits.map { edit -> DirectedSelection in
            let from = base.mapPosition(edit.from, association: .after)
            let position = from + edit.insert.utf16.count
            return DirectedSelection(anchor: position, head: position)
        }
        return try makeTransaction(
            edits: edits,
            selection: cursors.isEmpty ? nil : SelectionSet(ranges: cursors),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func trimTrailingWhitespace(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var edits: [TextEdit] = []
        for line in document.lines {
            let units = Array(line.text.utf16)
            var end = units.count
            while end > 0, units[end - 1] == 0x20 || units[end - 1] == 0x09 {
                end -= 1
            }
            if end < units.count {
                edits.append(TextEdit(
                    from: line.from + end,
                    to: line.from + units.count,
                    insert: ""
                ))
            }
        }
        return try transactionMappingSelection(
            edits: edits, snapshot: snapshot, limits: limits
        )
    }

    static func indent(
        _ snapshot: EditingCommandSnapshot,
        outdent: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var indexes: [Int] = []
        var seen = Set<Int>()
        for range in snapshot.selection.ranges {
            for index in document.selectedLineIndexes(for: range)
            where seen.insert(index).inserted {
                indexes.append(index)
            }
        }
        indexes.sort()
        let edits: [TextEdit] = indexes.compactMap { index in
            let line = document.lines[index]
            if !outdent {
                return TextEdit(
                    from: line.from, to: line.from,
                    insert: indentationUnit(snapshot)
                )
            }
            let prefixLength = leadingASCIISpaceTabLength(line.text)
            guard prefixLength > 0 else { return nil }
            let units = Array(line.text.utf16)
            let columns = indentationColumns(
                Array(units.prefix(prefixLength)),
                tabWidth: safeTabWidth(snapshot.tabWidth)
            )
            let replacement = indentation(
                columns: max(0, columns - safeIndentWidth(snapshot.indentWidth)),
                toTabs: !snapshot.insertSpaces,
                width: safeTabWidth(snapshot.tabWidth)
            )
            return TextEdit(
                from: line.from,
                to: line.from + prefixLength,
                insert: replacement
            )
        }
        return try transactionMappingSelection(
            edits: edits,
            snapshot: snapshot,
            limits: limits,
            cursorAssociation: .after
        )
    }

    static func reindent(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var selected = Set<Int>()
        for range in snapshot.selection.ranges {
            selected.formUnion(document.selectedLineIndexes(for: range))
        }
        guard !selected.isEmpty else { return nil }

        if let parsed = usableParsedSyntax(snapshot),
           !parsed.indentationWasTruncated {
            let edits = try parsedReindentEdits(
                snapshot, document: document, selected: selected, parsed: parsed,
                limits: limits
            )
            return try transactionMappingSelection(
                edits: edits, snapshot: snapshot, limits: limits,
                cursorAssociation: .after
            )
        }
        guard indentationStrategy(for: snapshot.language) != .none else { return nil }

        let width = safeIndentWidth(snapshot.indentWidth)
        let tabWidth = safeTabWidth(snapshot.tabWidth)
        let strategy = indentationStrategy(for: snapshot.language)
        var depth = 0
        var braceState = BraceIndentationState()
        var previousOpenedIndentBlock = false
        var edits: [TextEdit] = []
        edits.reserveCapacity(min(selected.count, limits.maximumEdits))

        for line in document.lines {
            let units = Array(line.text.utf16)
            let prefixLength = leadingASCIISpaceTabLength(line.text)
            let content = Array(units.dropFirst(prefixLength))
            let isBlank = content.allSatisfy(isWhitespace)
            let baseAdjustment: IndentationAdjustment
            switch strategy {
            case .none:
                baseAdjustment = IndentationAdjustment(closesBefore: 0, opensAfter: 0)
            case .indentation:
                baseAdjustment = indentationAdjustment(for: content, language: snapshot.language)
            case .braces:
                baseAdjustment = braceIndentationAdjustment(
                    for: content,
                    language: snapshot.language,
                    state: &braceState
                )
            }
            var closesBefore = baseAdjustment.closesBefore
            if strategy == .indentation, !isBlank {
                let currentColumns = indentationColumns(
                    Array(units.prefix(prefixLength)), tabWidth: tabWidth
                )
                let observedDepth = currentColumns / width
                let sourceDedent: Int
                if previousOpenedIndentBlock,
                   baseAdjustment.closesBefore == 0,
                   baseAdjustment.opensAfter == 0 {
                    sourceDedent = 0
                } else {
                    let allowance = (previousOpenedIndentBlock ? 1 : 0)
                        + indentationBranchAllowance(for: content, language: snapshot.language)
                    sourceDedent = max(0, depth - observedDepth - allowance)
                }
                closesBefore = max(closesBefore, sourceDedent)
                closesBefore = contextualIndentationCloseCount(
                    for: content,
                    language: snapshot.language,
                    depth: depth,
                    base: closesBefore
                )
            }
            let adjustment = IndentationAdjustment(
                closesBefore: closesBefore,
                opensAfter: baseAdjustment.opensAfter
            )
            let lineDepth = max(0, depth - adjustment.closesBefore)
            if selected.contains(line.number), !isBlank || prefixLength > 0 {
                let replacement = isBlank ? "" : indentation(
                    columns: lineDepth * width,
                    toTabs: !snapshot.insertSpaces,
                    width: tabWidth
                )
                let current = String(decoding: units.prefix(prefixLength), as: UTF16.self)
                if replacement != current {
                    edits.append(TextEdit(
                        from: line.from, to: line.from + prefixLength, insert: replacement
                    ))
                    guard edits.count <= limits.maximumEdits else {
                        throw EditingCommandError.tooManyEdits(
                            actual: edits.count, maximum: limits.maximumEdits
                        )
                    }
                }
            }
            depth = max(0, lineDepth + adjustment.opensAfter)
            previousOpenedIndentBlock = strategy == .indentation && !isBlank && adjustment.opensAfter > 0
        }
        return try transactionMappingSelection(
            edits: edits, snapshot: snapshot, limits: limits, cursorAssociation: .after
        )
    }

    static func convertIndentation(
        _ snapshot: EditingCommandSnapshot,
        toTabs: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let width = safeTabWidth(snapshot.tabWidth)
        let edits = document.lines.compactMap { line -> TextEdit? in
            let units = Array(line.text.utf16)
            let prefixLength = leadingASCIISpaceTabLength(line.text)
            guard prefixLength > 0 else { return nil }
            let original = String(
                decoding: Array(units.prefix(prefixLength)),
                as: UTF16.self
            )
            let columns = indentationColumns(
                Array(units.prefix(prefixLength)), tabWidth: width
            )
            let replacement = indentation(columns: columns, toTabs: toTabs, width: width)
            guard replacement != original else { return nil }
            return TextEdit(
                from: line.from,
                to: line.from + prefixLength,
                insert: replacement
            )
        }
        return try transactionMappingSelection(
            edits: edits,
            snapshot: snapshot,
            limits: limits,
            cursorAssociation: .after
        )
    }

    static func moveLines(
        _ snapshot: EditingCommandSnapshot,
        down: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let blocks = document.selectedLineBlocks(for: snapshot.selection)
        var edits: [TextEdit] = []
        var shifts: [Int: Int] = [:]
        for block in blocks {
            guard down ? block.lastLine + 1 < document.lines.count : block.firstLine > 0 else {
                continue
            }
            if down {
                let first = document.lines[block.firstLine]
                let last = document.lines[block.lastLine]
                let next = document.lines[block.lastLine + 1]
                let blockText = document.string(from: first.from, to: last.to)
                let replacement = next.text + "\n" + blockText
                edits.append(TextEdit(from: first.from, to: next.to, insert: replacement))
                let shift = next.text.utf16.count + 1
                for index in block.rangeIndexes { shifts[index] = shift }
            } else {
                let previous = document.lines[block.firstLine - 1]
                let first = document.lines[block.firstLine]
                let last = document.lines[block.lastLine]
                let blockText = document.string(from: first.from, to: last.to)
                let replacement = blockText + "\n" + previous.text
                edits.append(TextEdit(from: previous.from, to: last.to, insert: replacement))
                let shift = -(previous.text.utf16.count + 1)
                for index in block.rangeIndexes { shifts[index] = shift }
            }
        }
        guard !edits.isEmpty else { return nil }
        edits = coalescingConflictingLineMoves(edits)
        let base = try TextTransaction(edits: edits)
        let ranges = snapshot.selection.ranges.enumerated().map { index, range in
            guard let shift = shifts[index] else { return base.mapSelection(range) }
            return DirectedSelection(
                anchor: range.anchor + shift,
                head: range.head + shift
            )
        }
        return try makeTransaction(
            edits: edits,
            selection: SelectionSet(ranges: ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    /// Independently moving two blocks through the same separating line would
    /// create overlapping edits. Keep the operation bounded and deterministic
    /// by retaining the earlier planned replacement in that pathological case.
    static func coalescingConflictingLineMoves(
        _ edits: [TextEdit]
    ) -> [TextEdit] {
        var accepted: [TextEdit] = []
        for edit in edits.sorted(by: { $0.from < $1.from }) {
            if let previous = accepted.last, edit.from < previous.to { continue }
            accepted.append(edit)
        }
        return accepted
    }

    static func copyLines(
        _ snapshot: EditingCommandSnapshot,
        down: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let edits = document.selectedLineBlocks(for: snapshot.selection).map { block in
            let first = document.lines[block.firstLine]
            let last = document.lines[block.lastLine]
            let value = document.string(from: first.from, to: last.to)
            return down
                ? TextEdit(from: first.from, to: first.from, insert: value + "\n")
                : TextEdit(from: last.to, to: last.to, insert: "\n" + value)
        }
        let base = try TextTransaction(edits: edits)
        let ranges = snapshot.selection.ranges.map { range in
            DirectedSelection(
                anchor: base.mapPosition(range.anchor, association: down ? .after : .before),
                head: base.mapPosition(range.head, association: down ? .after : .before)
            )
        }
        return try makeTransaction(
            edits: edits,
            selection: SelectionSet(ranges: ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func deleteLines(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let blocks = document.selectedLineBlocks(for: snapshot.selection)
        var edits: [TextEdit] = []
        for block in blocks {
            let first = document.lines[block.firstLine]
            let last = document.lines[block.lastLine]
            if first.from > 0 {
                edits.append(TextEdit(from: first.from - 1, to: last.to, insert: ""))
            } else if last.to < document.length {
                edits.append(TextEdit(from: first.from, to: last.to + 1, insert: ""))
            } else {
                edits.append(TextEdit(from: first.from, to: last.to, insert: ""))
            }
        }
        let base = try TextTransaction(edits: edits)
        let cursors = blocks.map { block in
            let from = document.lines[block.firstLine].from
            return DirectedSelection(
                anchor: base.mapPosition(from, association: .before),
                head: base.mapPosition(from, association: .before)
            )
        }
        return try makeTransaction(
            edits: edits,
            selection: SelectionSet(ranges: cursors, mainIndex: 0),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func duplicate(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        if snapshot.selection.ranges.allSatisfy(\.isEmpty) {
            return try copyLines(snapshot, down: true, limits: limits)
        }
        let document = EditingUTF16Document(snapshot.text)
        let edits = snapshot.selection.ranges.compactMap { range -> TextEdit? in
            guard !range.isEmpty else { return nil }
            return TextEdit(
                from: range.to,
                to: range.to,
                insert: document.string(from: range.from, to: range.to)
            )
        }
        let base = try TextTransaction(edits: edits)
        let ranges = snapshot.selection.ranges.map { range in
            guard !range.isEmpty else { return base.mapSelection(range, cursorAssociation: .after) }
            return DirectedSelection(
                anchor: base.mapPosition(range.anchor, association: .after),
                head: base.mapPosition(range.head, association: .after)
            )
        }
        return try makeTransaction(
            edits: edits,
            selection: SelectionSet(ranges: ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func deleteToLineBoundary(
        _ snapshot: EditingCommandSnapshot,
        end: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        let candidates = snapshot.selection.ranges.map { range -> TextEdit in
            if !range.isEmpty { return TextEdit(from: range.from, to: range.to, insert: "") }
            let line = document.lines[document.lineIndex(at: range.head)]
            let target: Int
            if end {
                target = range.head < line.to ? line.to : min(document.length, range.head + 1)
            } else {
                target = range.head > line.from ? line.from : max(0, range.head - 1)
            }
            return TextEdit(
                from: min(range.head, target),
                to: max(range.head, target),
                insert: ""
            )
        }
        let edits = mergeDeletionEdits(candidates)
        guard !edits.allSatisfy(\.isNoOp) else { return nil }
        let base = try TextTransaction(edits: edits)
        let ranges = snapshot.selection.ranges.map { range -> DirectedSelection in
            let target: Int
            if !range.isEmpty { target = range.from }
            else if end { target = range.head }
            else {
                let line = document.lines[document.lineIndex(at: range.head)]
                target = range.head > line.from ? line.from : max(0, range.head - 1)
            }
            let mapped = base.mapPosition(target, association: .before)
            return DirectedSelection(anchor: mapped, head: mapped)
        }
        return try makeTransaction(
            edits: edits,
            selection: SelectionSet(ranges: ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func insertBlankLines(
        _ snapshot: EditingCommandSnapshot,
        below: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var indexes: [Int] = []
        var seen = Set<Int>()
        for range in snapshot.selection.ranges {
            let index: Int
            if below, !range.isEmpty {
                index = document.lineIndex(at: range.to)
            } else {
                index = document.lineIndex(at: range.from)
            }
            if seen.insert(index).inserted { indexes.append(index) }
        }
        indexes.sort()
        let records = indexes.map { index -> (position: Int, indent: String) in
            let line = document.lines[index]
            let indentLength = leadingWhitespaceLength(line.text)
            let indent = String(
                decoding: Array(line.text.utf16.prefix(indentLength)),
                as: UTF16.self
            )
            return (below ? line.to : line.from, indent)
        }
        let edits = records.map { record in
            TextEdit(
                from: record.position,
                to: record.position,
                insert: below ? "\n" + record.indent : record.indent + "\n"
            )
        }
        let base = try TextTransaction(edits: edits)
        let cursors = records.map { record -> DirectedSelection in
            let position = base.mapPosition(record.position, association: .before)
                + (below ? 1 + record.indent.utf16.count : record.indent.utf16.count)
            return DirectedSelection(anchor: position, head: position)
        }
        return try makeTransaction(
            edits: edits,
            selection: SelectionSet(ranges: cursors),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func toggleComment(
        _ snapshot: EditingCommandSnapshot,
        blockOnly: Bool,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        guard let syntax = commentSyntax(for: snapshot.language) else { return nil }
        if blockOnly {
            guard let block = syntax.block else { return nil }
            return try toggleBlockComment(
                snapshot, syntax: block, ranges: snapshot.selection.ranges, limits: limits
            )
        }
        if let token = syntax.line {
            return try toggleLineComment(snapshot, token: token, limits: limits)
        }
        guard let block = syntax.block else { return nil }
        let document = EditingUTF16Document(snapshot.text)
        let ranges = document.selectedLineBlocks(for: snapshot.selection).map { block in
            DirectedSelection(
                anchor: document.lines[block.firstLine].from
                    + leadingWhitespaceLength(document.lines[block.firstLine].text),
                head: document.lines[block.lastLine].to
            )
        }
        return try toggleBlockComment(snapshot, syntax: block, ranges: ranges, limits: limits)
    }

    static func toggleLineComment(
        _ snapshot: EditingCommandSnapshot,
        token: String,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let document = EditingUTF16Document(snapshot.text)
        var indexes: [Int] = []
        var seen = Set<Int>()
        for range in snapshot.selection.ranges {
            for index in document.selectedLineIndexes(for: range)
            where seen.insert(index).inserted {
                indexes.append(index)
            }
        }
        indexes.sort()

        let tokenLength = token.utf16.count
        let records = indexes.map { index -> (line: EditingLine, indent: Int, commented: Bool) in
            let line = document.lines[index]
            let indent = leadingWhitespaceLength(line.text)
            let units = Array(line.text.utf16)
            let commented = indent + tokenLength <= units.count
                && String(decoding: units[indent ..< indent + tokenLength], as: UTF16.self) == token
            return (line, indent, commented)
        }
        let nonEmptyIndents = records
            .filter { $0.indent < $0.line.text.utf16.count }
            .map(\.indent)
        let minimumIndent = nonEmptyIndents.min()
        let shouldComment = records.contains { record in
            let isSingle = records.count == 1
            return !record.commented
                && (record.indent < record.line.text.utf16.count || isSingle)
        }

        var edits: [TextEdit] = []
        if shouldComment {
            guard let insertionColumn = minimumIndent ?? records.first?.indent else { return nil }
            for record in records
            where record.indent < record.line.text.utf16.count || records.count == 1 {
                edits.append(TextEdit(
                    from: record.line.from + insertionColumn,
                    to: record.line.from + insertionColumn,
                    insert: token + " "
                ))
            }
            return try transactionMappingSelection(
                edits: edits,
                snapshot: snapshot,
                limits: limits,
                cursorAssociation: .after
            )
        }

        for record in records where record.commented {
            let units = Array(record.line.text.utf16)
            let from = record.line.from + record.indent
            let hasSpace = record.indent + tokenLength < units.count
                && units[record.indent + tokenLength] == 0x20
            edits.append(TextEdit(
                from: from,
                to: from + tokenLength + (hasSpace ? 1 : 0),
                insert: ""
            ))
        }
        return try transactionMappingSelection(
            edits: edits, snapshot: snapshot, limits: limits
        )
    }

    static func toggleBlockComment(
        _ snapshot: EditingCommandSnapshot,
        syntax: EditingCommentSyntax.Block,
        ranges: [DirectedSelection],
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let source = snapshot.text as NSString
        struct Wrapper {
            let range: DirectedSelection
            let openFrom: Int
            let openTo: Int
            let closeFrom: Int
            let closeTo: Int
        }
        let wrappers = ranges.map { range -> Wrapper? in
            let beforeFrom = max(0, range.from - 50)
            let afterTo = min(source.length, range.to + 50)
            let before = source.substring(with: NSRange(
                location: beforeFrom, length: range.from - beforeFrom
            ))
            let after = source.substring(with: NSRange(
                location: range.to, length: afterTo - range.to
            ))
            let beforeWhitespace = trailingWhitespaceLength(before)
            let afterWhitespace = leadingWhitespaceLength(after)
            let openEnd = range.from - beforeWhitespace
            let openStart = openEnd - syntax.open.utf16.count
            let closeStart = range.to + afterWhitespace
            let closeEnd = closeStart + syntax.close.utf16.count
            if openStart >= 0, closeEnd <= source.length,
               source.substring(with: NSRange(
                   location: openStart, length: syntax.open.utf16.count
               )) == syntax.open,
               source.substring(with: NSRange(
                   location: closeStart, length: syntax.close.utf16.count
               )) == syntax.close {
                return Wrapper(
                    range: range,
                    openFrom: openStart,
                    openTo: range.from - max(0, beforeWhitespace - 1),
                    closeFrom: range.to + min(afterWhitespace, 1),
                    closeTo: closeEnd
                )
            }

            let selected = source.substring(with: range.range)
            let startWhitespace = leadingWhitespaceLength(selected)
            let endWhitespace = trailingWhitespaceLength(selected)
            let innerOpen = range.from + startWhitespace
            let innerClose = range.to - endWhitespace - syntax.close.utf16.count
            guard innerOpen + syntax.open.utf16.count <= range.to,
                  innerClose >= innerOpen,
                  source.substring(with: NSRange(
                      location: innerOpen, length: syntax.open.utf16.count
                  )) == syntax.open,
                  source.substring(with: NSRange(
                      location: innerClose, length: syntax.close.utf16.count
                  )) == syntax.close else { return nil }
            let openMarginPosition = innerOpen + syntax.open.utf16.count
            let closeMarginPosition = innerClose - 1
            let openMargin = openMarginPosition < source.length
                && source.character(at: openMarginPosition) == 0x20 ? 1 : 0
            let closeMargin = closeMarginPosition >= 0
                && source.character(at: closeMarginPosition) == 0x20 ? 1 : 0
            return Wrapper(
                range: range,
                openFrom: innerOpen,
                openTo: innerOpen + syntax.open.utf16.count + openMargin,
                closeFrom: innerClose - closeMargin,
                closeTo: innerClose + syntax.close.utf16.count
            )
        }

        let allWrapped = wrappers.allSatisfy { $0 != nil }
        var edits: [TextEdit] = []
        if allWrapped {
            for wrapper in wrappers.compactMap({ $0 }) {
                edits.append(TextEdit(from: wrapper.openFrom, to: wrapper.openTo, insert: ""))
                edits.append(TextEdit(from: wrapper.closeFrom, to: wrapper.closeTo, insert: ""))
            }
        } else {
            for (range, wrapper) in zip(ranges, wrappers) where wrapper == nil {
                edits.append(TextEdit(from: range.from, to: range.from, insert: syntax.open + " "))
                edits.append(TextEdit(from: range.to, to: range.to, insert: " " + syntax.close))
            }
        }
        return try transactionMappingSelection(
            edits: edits,
            snapshot: snapshot,
            limits: limits,
            cursorAssociation: .after
        )
    }

    static func makeTransaction(
        edits: [TextEdit],
        selection: SelectionSet?,
        snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        guard edits.count <= limits.maximumEdits else {
            throw EditingCommandError.tooManyEdits(
                actual: edits.count, maximum: limits.maximumEdits
            )
        }
        if let selection, selection.ranges.count > limits.maximumSelections {
            throw EditingCommandError.tooManySelections(
                actual: selection.ranges.count, maximum: limits.maximumSelections
            )
        }
        let transaction = try TextTransaction(
            edits: edits,
            selection: selection,
            expectedRevision: snapshot.expectedRevision
        )
        try transaction.validate(forUTF16Length: snapshot.text.utf16.count)
        var delta = 0
        for edit in transaction.edits {
            let next = delta.addingReportingOverflow(edit.lengthDelta)
            guard !next.overflow else {
                throw EditingCommandError.documentTooLarge(
                    actual: edit.lengthDelta >= 0 ? Int.max : 0,
                    maximum: limits.maximumDocumentUTF16Length
                )
            }
            delta = next.partialValue
        }
        let final = snapshot.text.utf16.count.addingReportingOverflow(delta)
        guard !final.overflow, final.partialValue >= 0,
              final.partialValue <= limits.maximumDocumentUTF16Length else {
            throw EditingCommandError.documentTooLarge(
                actual: final.overflow ? Int.max : final.partialValue,
                maximum: limits.maximumDocumentUTF16Length
            )
        }
        guard transaction.selection?.isValid(forUTF16Length: final.partialValue) != false else {
            throw EditingCommandError.invalidSelection
        }
        return transaction.isEmpty ? nil : transaction
    }

    static func transactionMappingSelection(
        edits: [TextEdit],
        snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits,
        cursorAssociation: PositionAssociation = .before
    ) throws -> TextTransaction? {
        let base = try TextTransaction(edits: edits)
        guard !base.edits.isEmpty else { return nil }
        return try makeTransaction(
            edits: base.edits,
            selection: base.mapSelection(
                snapshot.selection,
                cursorAssociation: cursorAssociation
            ),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func transformed(
        _ snapshot: EditingCommandSnapshot,
        caseKind: CaseTransformKind,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        guard let plan = TextTransforms.planCaseTransform(
            snapshot.text,
            ranges: sessionRanges(snapshot.selection),
            kind: caseKind
        ) else { return nil }
        return try transaction(from: plan, snapshot: snapshot, limits: limits)
    }

    static func transformed(
        _ snapshot: EditingCommandSnapshot,
        lineMode: LineTransformMode,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let plan = TextTransforms.planLineTransform(
            snapshot.text,
            ranges: sessionRanges(snapshot.selection),
            mode: lineMode
        )
        return try transaction(from: plan, snapshot: snapshot, limits: limits)
    }

    static func transformed(
        _ snapshot: EditingCommandSnapshot,
        paragraphMode: ParagraphTransformMode,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        let plan = TextTransforms.planParagraphTransform(
            snapshot.text,
            ranges: sessionRanges(snapshot.selection),
            mode: paragraphMode,
            options: ParagraphTransformOptions(
                column: 80,
                tabWidth: Double(safeTabWidth(snapshot.tabWidth))
            )
        )
        return try transaction(from: plan, snapshot: snapshot, limits: limits)
    }

    static func finalNewline(
        _ snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        guard let plan = TextTransforms.planSingleFinalNewline(
            snapshot.text,
            ranges: sessionRanges(snapshot.selection)
        ) else { return nil }
        return try transaction(from: plan, snapshot: snapshot, limits: limits)
    }

    static func transaction(
        from plan: TextTransformPlan,
        snapshot: EditingCommandSnapshot,
        limits: EditingCommandLimits
    ) throws -> TextTransaction? {
        guard !plan.changes.isEmpty else { return nil }
        return try makeTransaction(
            edits: plan.changes.map(TextEdit.init),
            selection: selectionSet(plan.ranges, mainIndex: snapshot.selection.mainIndex),
            snapshot: snapshot,
            limits: limits
        )
    }

    static func sessionRanges(_ selection: SelectionSet) -> [SessionSelection] {
        selection.ranges.map {
            SessionSelection(anchor: $0.anchor, head: $0.head)
        }
    }

    static func selectionSet(
        _ ranges: [SessionSelection],
        mainIndex: Int
    ) -> SelectionSet {
        SelectionSet(
            ranges: ranges.map {
                DirectedSelection(anchor: $0.anchor, head: $0.head)
            },
            mainIndex: min(max(0, mainIndex), max(0, ranges.count - 1))
        )
    }

    static func safeTabWidth(_ width: Int) -> Int { min(16, max(1, width)) }
    static func safeIndentWidth(_ width: Int) -> Int { min(16, max(1, width)) }

    static func indentationUnit(_ snapshot: EditingCommandSnapshot) -> String {
        let indent = safeIndentWidth(snapshot.indentWidth)
        let tab = safeTabWidth(snapshot.tabWidth)
        return snapshot.insertSpaces || indent != tab
            ? String(repeating: " ", count: indent) : "\t"
    }

    static func leadingWhitespaceLength(_ text: String) -> Int {
        var count = 0
        for unit in text.utf16 {
            guard isWhitespace(unit) else { break }
            count += 1
        }
        return count
    }

    static func trailingWhitespaceLength(_ text: String) -> Int {
        let units = Array(text.utf16)
        var count = 0
        for unit in units.reversed() {
            guard isWhitespace(unit) else { break }
            count += 1
        }
        return count
    }

    static func leadingASCIISpaceTabLength(_ text: String) -> Int {
        var count = 0
        for unit in text.utf16 {
            guard unit == 0x20 || unit == 0x09 else { break }
            count += 1
        }
        return count
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func indentationColumns(_ prefix: [UInt16], tabWidth: Int) -> Int {
        prefix.reduce(0) { columns, unit in
            columns + (unit == 0x09 ? tabWidth : 1)
        }
    }

    static func usableParsedSyntax(
        _ snapshot: EditingCommandSnapshot
    ) -> ParsedSyntaxSnapshot? {
        guard let expectedRevision = snapshot.expectedRevision,
              let parsed = snapshot.parsedSyntax,
              parsed.sourceUTF16Length == snapshot.text.utf16.count,
              parsed.expectedRevision == expectedRevision else { return nil }
        return parsed
    }

    static func parsedBracketIsValid(
        _ bracket: (match: Int, opening: Bool),
        at position: Int,
        units: [UInt16]
    ) -> Bool {
        guard units.indices.contains(position), units.indices.contains(bracket.match) else {
            return false
        }
        let pairs: [UInt16: UInt16] = [
            0x28: 0x29, 0x5b: 0x5d, 0x7b: 0x7d,
            0x29: 0x28, 0x5d: 0x5b, 0x7d: 0x7b
        ]
        return pairs[units[position]] == units[bracket.match]
            && (bracket.opening ? position < bracket.match : position > bracket.match)
    }

    static func parsedReindentEdits(
        _ snapshot: EditingCommandSnapshot,
        document: EditingUTF16Document,
        selected: Set<Int>,
        parsed: ParsedSyntaxSnapshot,
        limits: EditingCommandLimits
    ) throws -> [TextEdit] {
        let indentationByLineStart = parsed.indentationColumnsByLineStart()
        let tabWidth = safeTabWidth(snapshot.tabWidth)
        var edits: [TextEdit] = []
        var projectedGrowth = 0
        edits.reserveCapacity(selected.count)
        for line in document.lines where selected.contains(line.number) {
            // CodeMirror skips a line when its language service has no
            // indentation answer. Do not turn that local absence into a
            // lexical rewrite of the whole selection.
            guard let parsedColumns = indentationByLineStart[line.from] else { continue }
            let units = Array(line.text.utf16)
            let prefixLength = leadingASCIISpaceTabLength(line.text)
            let isBlank = units.dropFirst(prefixLength).allSatisfy(isWhitespace)
            let columns = isBlank ? 0 : parsedColumns
            let replacementLength = snapshot.insertSpaces
                ? columns : columns / tabWidth + columns % tabWidth
            let delta = replacementLength - prefixLength
            let nextGrowth = projectedGrowth + delta
            guard nextGrowth <= limits.maximumDocumentUTF16Length - document.length else {
                throw EditingCommandError.documentTooLarge(
                    actual: document.length + nextGrowth,
                    maximum: limits.maximumDocumentUTF16Length
                )
            }
            let replacement = isBlank ? "" : indentation(
                columns: columns, toTabs: !snapshot.insertSpaces, width: tabWidth
            )
            let current = String(decoding: units.prefix(prefixLength), as: UTF16.self)
            if replacement != current {
                guard edits.count < limits.maximumEdits else {
                    throw EditingCommandError.tooManyEdits(
                        actual: edits.count + 1, maximum: limits.maximumEdits
                    )
                }
                edits.append(TextEdit(
                    from: line.from, to: line.from + prefixLength, insert: replacement
                ))
                projectedGrowth = nextGrowth
            }
        }
        return edits
    }

    static func indentation(columns: Int, toTabs: Bool, width: Int) -> String {
        guard toTabs else { return String(repeating: " ", count: columns) }
        return String(repeating: "\t", count: columns / width)
            + String(repeating: " ", count: columns % width)
    }

    enum ReindentationStrategy {
        case braces
        case indentation
        case none
    }

    struct IndentationAdjustment {
        let closesBefore: Int
        let opensAfter: Int
    }

    struct BraceIndentationState {
        var quote: UInt16?
        var escaped = false
        var inBlockComment = false
    }

    static func indentationStrategy(for language: String) -> ReindentationStrategy {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if [
            "python", "yaml", "nim", "haskell", "coffee", "sass",
            "stylus", "ruby"
        ].contains(where: { key.contains($0) }) {
            return .indentation
        }
        if key == "plain text" || key == "plaintext" || key == "text"
            || key.contains("markdown") {
            return .none
        }
        return .braces
    }

    static func hasSyntaxLanguage(_ language: String) -> Bool {
        indentationStrategy(for: language) != .none
    }

    static func indentationAdjustment(
        for units: [UInt16],
        language: String
    ) -> IndentationAdjustment {
        switch indentationStrategy(for: language) {
        case .none:
            return IndentationAdjustment(closesBefore: 0, opensAfter: 0)
        case .indentation:
            let significant = trimmedSignificantUnits(units, language: language)
            let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let token = String(decoding: significant, as: UTF16.self).lowercased()
            let closes: Int
            if key.contains("python") {
                closes = pythonLineDedents(token) ? 1 : 0
            } else if key.contains("ruby") {
                closes = rubyLineDedents(token) ? 1 : 0
            } else {
                closes = 0
            }
            let opens = key.contains("ruby")
                ? (rubyLineOpensBlock(token) ? 1 : 0)
                : (significant.last == 0x3a ? 1 : 0)
            return IndentationAdjustment(closesBefore: closes, opensAfter: opens)
        case .braces:
            var state = BraceIndentationState()
            return braceIndentationAdjustment(for: units, language: language, state: &state)
        }
    }

    static func contextualIndentationCloseCount(
        for units: [UInt16],
        language: String,
        depth: Int,
        base: Int
    ) -> Int {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = String(decoding: trimmedSignificantUnits(units, language: language), as: UTF16.self)
            .lowercased()
        let first = firstKeyword(in: token)

        if key.contains("python"), first == "case" {
            return depth >= 2 ? max(base, 1) : 0
        }
        if key.contains("ruby"), first == "in" || first == "when" {
            return depth >= 2 ? max(base, 1) : 0
        }
        return base
    }

    static func indentationBranchAllowance(
        for units: [UInt16],
        language: String
    ) -> Int {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = String(decoding: trimmedSignificantUnits(units, language: language), as: UTF16.self)
            .lowercased()
        let first = firstKeyword(in: token)
        if key.contains("python"), ["elif", "else", "except", "finally", "case"].contains(first) {
            return 1
        }
        if key.contains("ruby"), ["else", "elsif", "when", "rescue", "ensure", "in"].contains(first) {
            return 1
        }
        return 0
    }

    static func isInlineCommentStart(_ unit: UInt16, language: String) -> Bool {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return unit == 0x23 && [
            "python", "yaml", "ruby", "shell", "bash", "toml"
        ].contains(where: { key.contains($0) })
    }

    static func rubyLineOpensBlock(_ token: String) -> Bool {
        let first = firstKeyword(in: token)
        return [
            "class", "module", "def", "if", "unless", "case", "while",
            "until", "for", "begin", "do", "else", "elsif", "when",
            "rescue", "ensure", "in"
        ].contains(first)
    }

    static func braceIndentationAdjustment(
        for units: [UInt16],
        language: String,
        state: inout BraceIndentationState
    ) -> IndentationAdjustment {
        let syntax = commentSyntax(for: language)
        let lineComment = syntax?.line.map { Array($0.utf16) }
        let blockOpen = syntax?.block.map { Array($0.open.utf16) }
        let blockClose = syntax?.block.map { Array($0.close.utf16) }
        var leadingClosers = 0
        var opens = 0
        var closes = 0
        var leading = true
        var index = 0

        while index < units.count {
            if state.inBlockComment {
                if let blockClose, matches(blockClose, at: index, in: units) {
                    state.inBlockComment = false
                    index += blockClose.count
                } else {
                    index += 1
                }
                continue
            }

            let unit = units[index]
            if let activeQuote = state.quote {
                if state.escaped {
                    state.escaped = false
                } else if unit == 0x5c {
                    state.escaped = true
                } else if unit == activeQuote {
                    state.quote = nil
                }
                index += 1
                continue
            }

            if let blockOpen, blockClose != nil,
               matches(blockOpen, at: index, in: units) {
                state.inBlockComment = true
                index += blockOpen.count
                continue
            }
            if let lineComment, matches(lineComment, at: index, in: units) {
                break
            }
            if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                state.quote = unit
                state.escaped = false
                index += 1
                continue
            }

            if leading {
                if isWhitespace(unit) || unit == 0x3b || unit == 0x2c {
                    index += 1
                    continue
                }
                if isClosingBracket(unit) {
                    leadingClosers += 1
                    closes += 1
                    index += 1
                    continue
                }
                leading = false
            }

            if isOpeningBracket(unit) {
                opens += 1
            } else if isClosingBracket(unit) {
                closes += 1
            }
            index += 1
        }

        if state.quote != 0x60 {
            state.quote = nil
        }
        state.escaped = false

        return IndentationAdjustment(
            closesBefore: leadingClosers,
            opensAfter: max(0, opens - max(0, closes - leadingClosers))
        )
    }

    static func trimmedSignificantUnits(
        _ units: [UInt16],
        language: String
    ) -> [UInt16] {
        guard let lineComment = commentSyntax(for: language)?.line.map({ Array($0.utf16) }) else {
            var trimmed = Array(units)
            while trimmed.last.map(isWhitespace) == true { trimmed.removeLast() }
            return trimmed
        }
        var result: [UInt16] = []
        result.reserveCapacity(units.count)
        var quote: UInt16?
        var escaped = false
        var index = 0

        while index < units.count {
            let unit = units[index]
            if let activeQuote = quote {
                result.append(unit)
                if escaped {
                    escaped = false
                } else if unit == 0x5c {
                    escaped = true
                } else if unit == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if matches(lineComment, at: index, in: units) {
                break
            }
            result.append(unit)
            if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                quote = unit
                escaped = false
            }
            index += 1
        }
        while result.last.map(isWhitespace) == true { result.removeLast() }
        return result
    }

    static func pythonLineDedents(_ token: String) -> Bool {
        ["elif", "else", "except", "finally"].contains(firstKeyword(in: token))
    }

    static func rubyLineDedents(_ token: String) -> Bool {
        ["end", "else", "elsif", "rescue", "ensure"]
            .contains(firstKeyword(in: token))
    }

    static func firstKeyword(in token: String) -> String {
        token.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ":")) } ?? ""
    }

    static func composedRange(
        in source: NSString,
        at position: Int,
        forward: Bool
    ) -> NSRange {
        guard source.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        let index = forward ? min(source.length - 1, position) : max(0, position - 1)
        return source.rangeOfComposedCharacterSequence(at: index)
    }

    static func nonOverlapping(_ edits: [TextEdit]) -> [TextEdit] {
        var accepted: [TextEdit] = []
        for edit in edits.sorted(by: {
            $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from
        }) {
            guard accepted.last.map({ $0.to > edit.from }) != true else { continue }
            accepted.append(edit)
        }
        return accepted
    }

    static func mergeDeletionEdits(_ edits: [TextEdit]) -> [TextEdit] {
        var merged: [TextEdit] = []
        for edit in edits
            .filter({ !$0.isNoOp })
            .sorted(by: { $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from }) {
            if let previous = merged.last, edit.from <= previous.to {
                merged[merged.count - 1] = TextEdit(
                    from: previous.from,
                    to: max(previous.to, edit.to),
                    insert: ""
                )
            } else {
                merged.append(edit)
            }
        }
        return merged
    }

    static func wordRange(
        at rawPosition: Int,
        in document: EditingUTF16Document
    ) -> DirectedSelection? {
        guard document.length > 0 else { return nil }
        var position = min(document.length, max(0, rawPosition))
        if position == document.length || !isWordUnit(document.units[position]) {
            if position > 0, isWordUnit(document.units[position - 1]) { position -= 1 }
        }
        guard position < document.length, isWordUnit(document.units[position]) else { return nil }
        var from = position
        var to = position + 1
        while from > 0, isWordUnit(document.units[from - 1]) { from -= 1 }
        while to < document.length, isWordUnit(document.units[to]) { to += 1 }
        return DirectedSelection(anchor: from, head: to)
    }

    static func unicodeWordRange(
        at rawPosition: Int,
        in document: EditingUTF16Document
    ) -> DirectedSelection? {
        guard document.length > 0 else { return nil }
        let source = String(decoding: document.units, as: UTF16.self) as NSString
        let position = min(document.length, max(0, rawPosition))
        let current = position < document.length
            ? source.rangeOfComposedCharacterSequence(at: position) : nil
        let previous = position > 0
            ? source.rangeOfComposedCharacterSequence(at: position - 1) : nil
        guard let seed = [current, previous].compactMap({ $0 }).first(where: {
            isUnicodeWordCluster(source.substring(with: $0))
        }) else { return nil }
        var from = seed.location
        var to = NSMaxRange(seed)
        while from > 0 {
            let candidate = source.rangeOfComposedCharacterSequence(at: from - 1)
            guard isUnicodeWordCluster(source.substring(with: candidate)) else { break }
            from = candidate.location
        }
        while to < document.length {
            let candidate = source.rangeOfComposedCharacterSequence(at: to)
            guard isUnicodeWordCluster(source.substring(with: candidate)) else { break }
            to = NSMaxRange(candidate)
        }
        return DirectedSelection(anchor: from, head: to)
    }

    static func currentUnicodeWordRange(
        at rawPosition: Int,
        in document: EditingUTF16Document
    ) -> DirectedSelection? {
        guard document.length > 0 else { return nil }
        let source = String(decoding: document.units, as: UTF16.self) as NSString
        let position = min(document.length, max(0, rawPosition))
        guard position < document.length else { return nil }
        let current = source.rangeOfComposedCharacterSequence(at: position)
        guard isUnicodeWordCluster(source.substring(with: current)) else { return nil }
        var from = current.location
        var to = NSMaxRange(current)
        while from > 0 {
            let candidate = source.rangeOfComposedCharacterSequence(at: from - 1)
            guard isUnicodeWordCluster(source.substring(with: candidate)) else { break }
            from = candidate.location
        }
        while to < document.length {
            let candidate = source.rangeOfComposedCharacterSequence(at: to)
            guard isUnicodeWordCluster(source.substring(with: candidate)) else { break }
            to = NSMaxRange(candidate)
        }
        return DirectedSelection(anchor: from, head: to)
    }

    static func isUnicodeWordCluster(_ cluster: String) -> Bool {
        var containsBase = false
        for scalar in cluster.unicodeScalars {
            if scalar.value == 0x5f || scalar.value == 0x24
                || CharacterSet.alphanumerics.contains(scalar) {
                containsBase = true
            } else if !CharacterSet.nonBaseCharacters.contains(scalar) {
                return false
            }
        }
        return containsBase
    }

    static func wordDeletionTarget(
        from position: Int,
        forward: Bool,
        in document: EditingUTF16Document
    ) -> Int {
        let line = document.lines[document.lineIndex(at: position)]
        if forward, position == line.to {
            return min(document.length, position + 1)
        }
        if !forward, position == line.from {
            return max(0, position - 1)
        }
        var cursor = position
        var category: Int?
        while forward ? cursor < line.to : cursor > line.from {
            let next = forward ? cursor + 1 : cursor - 1
            let unit = document.units[forward ? cursor : next]
            let nextCategory = wordCategory(unit)
            if let category, nextCategory != category { break }
            if unit != 0x20 || cursor != position { category = nextCategory }
            cursor = next
        }
        return cursor
    }

    static func wordCategory(_ unit: UInt16) -> Int {
        if isWhitespace(unit) { return 0 }
        if isWordUnit(unit) { return 1 }
        return 2
    }

    static func isWordUnit(_ unit: UInt16) -> Bool {
        unit == 0x5f || unit == 0x24
            || (0x30 ... 0x39).contains(unit)
            || (0x41 ... 0x5a).contains(unit)
            || (0x61 ... 0x7a).contains(unit)
    }

    static func nextOccurrence(
        of needle: String,
        after start: Int,
        wrappingBefore end: Int,
        in document: EditingUTF16Document,
        excluding ranges: [DirectedSelection],
        wholeWord: Bool
    ) -> DirectedSelection? {
        let needleUnits = Array(needle.utf16)
        func find(from: Int, before: Int) -> DirectedSelection? {
            var cursor = from
            while cursor <= before - needleUnits.count {
                guard let position = firstOccurrence(
                    of: needleUnits,
                    in: document.units,
                    from: cursor,
                    before: before
                ) else { return nil }
                let match = DirectedSelection(
                    anchor: position,
                    head: position + needleUnits.count
                )
                let overlaps = ranges.contains { match.from < $0.to && match.to > $0.from }
                if !overlaps, !wholeWord || isWholeWord(match, in: document.units) {
                    return match
                }
                cursor = position + max(1, needleUnits.count)
            }
            return nil
        }
        return find(from: start, before: document.length)
            ?? find(from: 0, before: end)
    }

    static func firstOccurrence(
        of needle: [UInt16],
        in haystack: [UInt16],
        from start: Int,
        before end: Int
    ) -> Int? {
        guard !needle.isEmpty, start >= 0, end >= start,
              needle.count <= end - start else { return nil }
        for index in start ... end - needle.count
        where haystack[index ..< index + needle.count].elementsEqual(needle) {
            return index
        }
        return nil
    }

    static func isWholeWord(_ range: DirectedSelection, in units: [UInt16]) -> Bool {
        (range.from == 0 || !isWordUnit(units[range.from - 1]))
            && (range.to == units.count || !isWordUnit(units[range.to]))
    }

    static func bracketCandidates(
        around position: Int, length: Int
    ) -> [(position: Int, opening: Bool)] {
        var result: [(position: Int, opening: Bool)] = []
        // This order mirrors CodeMirror's toMatchingBracket: closing token
        // immediately before the cursor, opening token at the cursor, then the
        // opposite directions at those same two positions.
        if position > 0 { result.append((position - 1, false)) }
        if position < length { result.append((position, true)) }
        if position > 0 { result.append((position - 1, true)) }
        if position < length { result.append((position, false)) }
        return result
    }

    static func isOpeningBracket(_ unit: UInt16) -> Bool {
        unit == 0x28 || unit == 0x5b || unit == 0x7b
    }

    static func isClosingBracket(_ unit: UInt16) -> Bool {
        unit == 0x29 || unit == 0x5d || unit == 0x7d
    }

    static func matches(_ token: [UInt16], at index: Int, in units: [UInt16]) -> Bool {
        guard !token.isEmpty, index >= 0, index + token.count <= units.count else { return false }
        return units[index ..< index + token.count].elementsEqual(token)
    }

    static func matchingBracket(at position: Int, in units: [UInt16]) -> Int? {
        let pairs: [UInt16: UInt16] = [
            0x28: 0x29, 0x5b: 0x5d, 0x7b: 0x7d,
            0x29: 0x28, 0x5d: 0x5b, 0x7d: 0x7b
        ]
        guard units.indices.contains(position), let target = pairs[units[position]] else {
            return nil
        }
        let opening = isOpeningBracket(units[position])
        var depth = 0
        var cursor = position
        while opening ? cursor < units.count : cursor >= 0 {
            let unit = units[cursor]
            if unit == units[position] { depth += 1 }
            else if unit == target {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += opening ? 1 : -1
        }
        return nil
    }
}
