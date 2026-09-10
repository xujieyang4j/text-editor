import Foundation
import LumenEditorCore

/// View-local evidence that a closing delimiter was inserted by the native
/// structural-typing planner. Offsets are UTF-16 character starts in the
/// current committed text.
///
/// Keeping this separate from the document makes the state deliberately
/// ephemeral: edits can map surviving entries, while a view/document reset
/// can discard all of them instead of guessing that an identical character
/// still has automatic-closing provenance.
struct NativeTextInputProvenance: Equatable, Sendable {
    private(set) var autoClosingUnits: [Int: UInt16]

    init(autoClosingUnits: [Int: UInt16] = [:]) {
        self.autoClosingUnits = autoClosingUnits
    }

    static let empty = NativeTextInputProvenance()

    func containsClosing(_ unit: UInt16, at offset: Int) -> Bool {
        autoClosingUnits[offset] == unit
    }

    /// Maps entries whose characters survive `transaction` and drops entries
    /// touched by a replacement. An insertion at an entry's exact offset is
    /// associated before the existing character, so that character and its
    /// provenance move together.
    func mapped(
        through transaction: TextTransaction,
        from oldText: String,
        to newText: String
    ) -> NativeTextInputProvenance {
        let oldSource = oldText as NSString
        let newSource = newText as NSString
        guard (try? transaction.validate(forUTF16Length: oldSource.length)) != nil else {
            return .empty
        }

        var mapped: [Int: UInt16] = [:]
        mapped.reserveCapacity(autoClosingUnits.count)
        for (offset, unit) in autoClosingUnits {
            guard offset >= 0, offset < oldSource.length,
                  oldSource.character(at: offset) == unit,
                  !transaction.edits.contains(where: { edit in
                      edit.from <= offset && offset < edit.to
                  }) else { continue }
            let nextOffset = transaction.mapPosition(offset, association: .after)
            guard nextOffset >= 0, nextOffset < newSource.length,
                  newSource.character(at: nextOffset) == unit else { continue }
            mapped[nextOffset] = unit
        }
        return NativeTextInputProvenance(autoClosingUnits: mapped)
    }

    fileprivate func adding(
        _ additions: [(offset: Int, unit: UInt16)], in text: String
    ) -> NativeTextInputProvenance {
        guard !additions.isEmpty else { return self }
        let source = text as NSString
        var updated = autoClosingUnits
        for addition in additions
        where addition.offset >= 0 && addition.offset < source.length
            && source.character(at: addition.offset) == addition.unit {
            updated[addition.offset] = addition.unit
        }
        return NativeTextInputProvenance(autoClosingUnits: updated)
    }

    fileprivate func removing(_ offsets: Set<Int>) -> NativeTextInputProvenance {
        guard !offsets.isEmpty else { return self }
        return NativeTextInputProvenance(
            autoClosingUnits: autoClosingUnits.filter { !offsets.contains($0.key) }
        )
    }
}

struct NativeTextInputPlan: Equatable, Sendable {
    let transaction: TextTransaction
    let provenance: NativeTextInputProvenance
}

/// Plans CodeMirror-style structural typing without letting NSTextView create
/// a second source of truth. Every accepted plan is one revision-pinned
/// DocumentBuffer transaction, including multi-cursor edits.
enum NativeTextInputPlanner {
    static let pairs: [UInt16: UInt16] = [
        0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D,
        0x22: 0x22, 0x27: 0x27, 0x60: 0x60
    ]
    static let closingUnits: Set<UInt16> = Set(pairs.values)
    static let closeBeforeUnits: Set<UInt16> = [
        0x29, 0x5D, 0x7D, 0x3A, 0x3B, 0x3E
    ]

    static func insertion(
        text: String,
        selections: SelectionSet,
        replacement: String,
        tabWidth requestedTabWidth: Int,
        indentWidth requestedIndentWidth: Int? = nil,
        insertSpaces: Bool,
        language: String,
        revision: UInt64,
        parsedIndentation: CodeMirrorIndentationSnapshot? = nil
    ) -> TextTransaction? {
        insertionPlan(
            text: text, selections: selections, replacement: replacement,
            tabWidth: requestedTabWidth, indentWidth: requestedIndentWidth,
            insertSpaces: insertSpaces, language: language, revision: revision,
            parsedIndentation: parsedIndentation, provenance: .empty
        )?.transaction
    }

    static func insertionPlan(
        text: String,
        selections: SelectionSet,
        replacement: String,
        tabWidth requestedTabWidth: Int,
        indentWidth requestedIndentWidth: Int? = nil,
        insertSpaces: Bool,
        language: String,
        revision: UInt64,
        parsedIndentation: CodeMirrorIndentationSnapshot? = nil,
        provenance: NativeTextInputProvenance
    ) -> NativeTextInputPlan? {
        let source = text as NSString
        guard selections.isValid(forUTF16Length: source.length) else { return nil }
        let tabWidth = min(16, max(1, requestedTabWidth))
        let indentWidth = min(16, max(1, requestedIndentWidth ?? tabWidth))
        let parsedIndentation = parsedIndentation.flatMap { snapshot in
            snapshot.matches(
                text: text, language: language, revision: revision,
                tabWidth: tabWidth, indentWidth: indentWidth,
                insertSpaces: insertSpaces
            ) ? snapshot : nil
        }
        let replacementUnits = Array(replacement.utf16)
        guard replacement == "\n" || replacement == "\r"
                || replacement == "\t" || replacementUnits.count == 1
        else { return nil }

        let operations = selections.ranges.enumerated().map { index, selection in
            operation(
                source: source, selection: selection, replacement: replacement,
                tabWidth: tabWidth, indentWidth: indentWidth,
                insertSpaces: insertSpaces, language: language,
                parsedIndentation: parsedIndentation, provenance: provenance,
                index: index
            )
        }
        guard operations.allSatisfy({ $0 != nil }) else { return nil }
        let accepted = operations.compactMap { $0 }.sorted {
            $0.range.location == $1.range.location
                ? $0.originalIndex < $1.originalIndex
                : $0.range.location < $1.range.location
        }
        let edits = accepted.compactMap(\.edit)
        guard !edits.isEmpty || accepted.contains(where: \.consumesWithoutEdit) else { return nil }
        guard let base = try? TextTransaction(edits: edits, expectedRevision: revision) else {
            return nil
        }

        var resultByIndex: [Int: DirectedSelection] = [:]
        for operation in accepted {
            let location = base.mapPosition(
                operation.range.location, association: .before
            )
            resultByIndex[operation.originalIndex] = DirectedSelection(
                anchor: location + operation.anchorOffset,
                head: location + operation.headOffset
            )
        }
        let finalSelections = selections.ranges.indices.compactMap { resultByIndex[$0] }
        guard finalSelections.count == selections.ranges.count,
              let transaction = try? TextTransaction(
                  edits: edits,
                  selection: SelectionSet(
                      ranges: finalSelections, mainIndex: selections.mainIndex
                  ),
                  expectedRevision: revision
              ),
              let nextText = try? transaction.applying(to: text) else { return nil }
        _ = base // validates the edit set before explicit selection construction.

        let consumedOffsets = Set(accepted.compactMap(\.consumedClosingOffset))
        var nextProvenance = provenance.removing(consumedOffsets).mapped(
            through: transaction, from: text, to: nextText
        )
        let additions: [(offset: Int, unit: UInt16)] = accepted.compactMap { operation in
            guard let generated = operation.generatedClosing else { return nil }
            let location = transaction.mapPosition(
                operation.range.location, association: .before
            )
            return (location + generated.relativeOffset, generated.unit)
        }
        nextProvenance = nextProvenance.adding(additions, in: nextText)
        return NativeTextInputPlan(
            transaction: transaction, provenance: nextProvenance
        )
    }

    static func pairedBackspace(
        text: String, selections: SelectionSet, revision: UInt64,
        provenance: NativeTextInputProvenance = .empty
    ) -> TextTransaction? {
        pairedBackspacePlan(
            text: text, selections: selections, revision: revision,
            provenance: provenance
        )?.transaction
    }

    static func pairedBackspacePlan(
        text: String, selections: SelectionSet, revision: UInt64,
        provenance: NativeTextInputProvenance
    ) -> NativeTextInputPlan? {
        let source = text as NSString
        guard selections.isValid(forUTF16Length: source.length),
              selections.ranges.allSatisfy(\.isEmpty) else { return nil }
        var edits: [TextEdit] = []
        for selection in selections.ranges {
            let cursor = selection.head
            guard cursor > 0, cursor < source.length else { return nil }
            let opening = source.character(at: cursor - 1)
            guard let closing = pairs[opening], source.character(at: cursor) == closing else {
                return nil
            }
            edits.append(TextEdit(from: cursor - 1, to: cursor + 1, insert: ""))
        }
        guard let transaction = try? TextTransaction(edits: edits, expectedRevision: revision)
        else { return nil }
        let result = selections.ranges.map { selection in
            DirectedSelection(
                anchor: transaction.mapPosition(selection.head - 1),
                head: transaction.mapPosition(selection.head - 1)
            )
        }
        guard let finalTransaction = try? TextTransaction(
            edits: edits, selection: SelectionSet(ranges: result, mainIndex: selections.mainIndex),
            expectedRevision: revision
        ), let nextText = try? finalTransaction.applying(to: text) else { return nil }
        return NativeTextInputPlan(
            transaction: finalTransaction,
            provenance: provenance.mapped(
                through: finalTransaction, from: text, to: nextText
            )
        )
    }
}

private extension NativeTextInputPlanner {
    static let maximumLexicalScanUTF16Length = 8 * 1_024

    struct Operation {
        struct GeneratedClosing {
            let relativeOffset: Int
            let unit: UInt16
        }

        let originalIndex: Int
        let range: NSRange
        let edit: TextEdit?
        let anchorOffset: Int
        let headOffset: Int
        let consumesWithoutEdit: Bool
        let generatedClosing: GeneratedClosing?
        let consumedClosingOffset: Int?
    }

    struct LexicalProfile {
        let lineComments: [[UInt16]]
        let blockComments: [([UInt16], [UInt16])]
    }

    struct LexicalState {
        let profile: LexicalProfile
        var quote: UInt16?
        var escaped = false
        var lineCommentMarker: [UInt16]?
        var blockCommentEnd: [UInt16]?
        var consumedCount = 0

        var isInsideLiteralOrComment: Bool {
            quote != nil || lineCommentMarker != nil || blockCommentEnd != nil
        }

        mutating func consume(source: NSString, index: Int, end: Int) -> Bool {
            consumedCount = 0
            if lineCommentMarker != nil {
                consumedCount = 1
                return true
            }
            if let blockCommentEnd {
                if matches(blockCommentEnd, at: index, source: source, end: end) {
                    self.blockCommentEnd = nil
                    consumedCount = blockCommentEnd.count
                } else {
                    consumedCount = 1
                }
                return true
            }
            if let quote {
                if escaped {
                    escaped = false
                } else if source.character(at: index) == 0x5C {
                    escaped = true
                } else if source.character(at: index) == quote {
                    self.quote = nil
                }
                consumedCount = 1
                return true
            }
            if let marker = profile.lineComments.first(where: {
                matches($0, at: index, source: source, end: end)
            }) {
                lineCommentMarker = marker
                consumedCount = marker.count
                return true
            }
            if let pair = profile.blockComments.first(where: {
                matches($0.0, at: index, source: source, end: end)
            }) {
                blockCommentEnd = pair.1
                consumedCount = pair.0.count
                return true
            }
            let unit = source.character(at: index)
            if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                quote = unit
                consumedCount = 1
                return true
            }
            return false
        }

        mutating func endLine() {
            lineCommentMarker = nil
            escaped = false
            if quote != 0x60 { quote = nil }
        }
    }

    struct LineContext {
        let codeBeforeCursor: String
        let codeAfterCursor: String
        let insideLiteralOrComment: Bool
    }

    static func operation(
        source: NSString, selection: DirectedSelection, replacement: String,
        tabWidth: Int, indentWidth: Int, insertSpaces: Bool, language: String,
        parsedIndentation: CodeMirrorIndentationSnapshot?,
        provenance: NativeTextInputProvenance, index: Int
    ) -> Operation? {
        let range = selection.range
        let languageKey = normalizedLanguage(language)
        let lineContext = context(at: range.location, source: source, language: languageKey)
        if replacement == "\t" {
            guard selection.isEmpty else { return nil }
            let indent: String
            if insertSpaces {
                let column = displayColumn(at: range.location, source: source, tabWidth: tabWidth)
                indent = String(repeating: " ", count: tabWidth - column % tabWidth)
            } else {
                indent = "\t"
            }
            return replacementOperation(index: index, range: range, inserted: indent)
        }
        if replacement == "\n" || replacement == "\r" {
            if languageKey == "markdown", selection.isEmpty,
               let markdown = markdownContinuation(
                   at: range.location, source: source, lineContext: lineContext
               ) {
                return replacementOperation(
                    index: index, range: markdown.range,
                    inserted: markdown.inserted, cursorOffset: markdown.cursorOffset
                )
            }
            let whitespaceTrimmedRange = consumingFollowingWhitespace(
                in: range, source: source
            )
            let lineStart = lineStart(before: range.location, source: source)
            let expandsToLineStart = range.location < lineStart + 100
                && isWhitespaceOnly(
                    from: lineStart, to: range.location, source: source
                )
            let replacementRange = NSRange(
                location: expandsToLineStart ? lineStart : range.location,
                length: NSMaxRange(whitespaceTrimmedRange)
                    - (expandsToLineStart ? lineStart : range.location)
            )
            let base = leadingIndent(at: lineStart, source: source)
            let previous = previousNonspace(in: lineContext.codeBeforeCursor)
            let next = range.location < source.length ? source.character(at: range.location) : nil
            let shouldIndent = !lineContext.insideLiteralOrComment && (
                previous.map { [0x7B, 0x5B, 0x28].contains($0) } == true
                    || (languageKey == "python" && pythonLineStartsBlock(lineContext.codeBeforeCursor))
                    || (languageKey == "ruby" && rubyLineStartsBlock(lineContext.codeBeforeCursor))
            )
            let bracketPairAtCursor = previous.flatMap { pairs[$0] }
                .map { $0 == next } == true
            let unit = insertSpaces ? String(repeating: " ", count: indentWidth) : "\t"
            let lexicalInner = base + (shouldIndent ? unit : "")
            let nextCodeToken = firstCodeToken(in: lineContext.codeAfterCursor)
            let rubyKeywordClose = languageKey == "ruby"
                && shouldIndent && nextCodeToken == "end"
            let parserExplode = parsedIndentation?.shouldExplodeNewline(
                at: expandsToLineStart ? lineStart : range.location
            )
            let explode = selection.isEmpty
                && (parserExplode ?? (bracketPairAtCursor || rubyKeywordClose))
            // Bundle indentation normally targets existing lines. The snapshot
            // exposes only the subset proven equivalent to CodeMirror's Enter
            // `simulateBreak` query; all other positions retain lexical behavior.
            let parsedColumns = parsedIndentation
                .flatMap { $0.newlineIndentationColumns(
                    atExistingLineStart: expandsToLineStart
                        ? lineStart : range.location,
                    doubleBreak: explode
                ) }
            let inner = parsedColumns.map { indentation(
                    columns: $0, tabWidth: tabWidth, insertSpaces: insertSpaces
                ) } ?? lexicalInner
            let outer = parsedIndentation.flatMap { snapshot in
                parserExplode == true || bracketPairAtCursor
                    ? snapshot.newlineIndentationColumns(
                        atExistingLineStart: expandsToLineStart
                            ? lineStart : range.location
                    ).map { indentation(
                        columns: $0, tabWidth: tabWidth,
                        insertSpaces: insertSpaces
                    ) }
                    : nil
            } ?? base
            let inserted: String
            let cursor: Int
            if explode {
                inserted = "\n" + inner + "\n" + outer
                cursor = 1 + inner.utf16.count
            } else {
                inserted = "\n" + inner
                cursor = inserted.utf16.count
            }
            if explode {
                return replacementOperation(
                    index: index, range: range, inserted: inserted,
                    cursorOffset: cursor
                )
            }
            return replacementOperation(
                index: index, range: replacementRange, inserted: inserted,
                cursorOffset: cursor
            )
        }

        let unit = Array(replacement.utf16)[0]
        if selection.isEmpty, closingUnits.contains(unit),
           range.location < source.length, source.character(at: range.location) == unit,
           provenance.containsClosing(unit, at: range.location) {
            return Operation(
                originalIndex: index, range: range, edit: nil,
                anchorOffset: 1, headOffset: 1, consumesWithoutEdit: true,
                generatedClosing: nil, consumedClosingOffset: range.location
            )
        }
        if selection.isEmpty, lineContext.insideLiteralOrComment, pairs[unit] != nil {
            return replacementOperation(index: index, range: range, inserted: replacement)
        }
        guard let closing = pairs[unit] else { return nil }
        if selection.isEmpty, range.location < source.length {
            let next = source.character(at: range.location)
            guard isECMAScriptWhitespace(next) || closeBeforeUnits.contains(next) else {
                return nil
            }
        }
        let selected = source.substring(with: range)
        let inserted = replacement + selected + String(utf16CodeUnits: [closing], count: 1)
        if selection.isEmpty {
            return replacementOperation(
                index: index, range: range, inserted: inserted,
                cursorOffset: replacement.utf16.count,
                generatedClosing: Operation.GeneratedClosing(
                    relativeOffset: replacement.utf16.count, unit: closing
                )
            )
        }
        let openingLength = replacement.utf16.count
        return Operation(
            originalIndex: index, range: range,
            edit: TextEdit(from: range.location, to: NSMaxRange(range), insert: inserted),
            anchorOffset: selection.isBackward ? openingLength + selected.utf16.count : openingLength,
            headOffset: selection.isBackward ? openingLength : openingLength + selected.utf16.count,
            consumesWithoutEdit: false,
            generatedClosing: Operation.GeneratedClosing(
                relativeOffset: openingLength + selected.utf16.count, unit: closing
            ),
            consumedClosingOffset: nil
        )
    }

    static func replacementOperation(
        index: Int, range: NSRange, inserted: String, cursorOffset: Int? = nil,
        generatedClosing: Operation.GeneratedClosing? = nil
    ) -> Operation {
        let cursor = cursorOffset ?? inserted.utf16.count
        return Operation(
            originalIndex: index, range: range,
            edit: TextEdit(from: range.location, to: NSMaxRange(range), insert: inserted),
            anchorOffset: cursor, headOffset: cursor, consumesWithoutEdit: false,
            generatedClosing: generatedClosing, consumedClosingOffset: nil
        )
    }

    static func markdownContinuation(
        at position: Int, source: NSString, lineContext: LineContext
    ) -> (range: NSRange, inserted: String, cursorOffset: Int)? {
        guard !lineContext.insideLiteralOrComment else { return nil }
        let start = lineStart(before: position, source: source)
        let before = source.substring(with: NSRange(
            location: start, length: position - start
        ))
        // Fenced code must keep the ordinary language indentation behavior.
        guard !isInsideOrBeyondMarkdownFence(
            at: start, source: source
        ) else { return nil }
        let pattern = #"^([ \t]*)([-+*]|([0-9]+)([.)]))[ \t]+((?:\[[ xX]\][ \t]+)?)(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: before, range: NSRange(location: 0, length: before.utf16.count)
              ), match.range.location != NSNotFound else { return nil }
        let indent = (before as NSString).substring(with: match.range(at: 1))
        let body = (before as NSString).substring(with: match.range(at: 6))
        let marker: String
        if match.range(at: 3).location != NSNotFound,
           let value = Int((before as NSString).substring(with: match.range(at: 3))),
           value < Int.max {
            marker = "\(value + 1)"
                + (before as NSString).substring(with: match.range(at: 4))
        } else if match.range(at: 3).location != NSNotFound {
            return nil
        } else {
            marker = (before as NSString).substring(with: match.range(at: 2))
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (
                NSRange(location: start, length: position - start),
                "", 0
            )
        }
        let taskPrefix = match.range(at: 5).location == NSNotFound ? "" : "[ ] "
        let continuation = indent + marker + " " + taskPrefix
        let inserted = "\n" + continuation
        return (NSRange(location: position, length: 0), inserted, inserted.utf16.count)
    }

    static func isInsideOrBeyondMarkdownFence(
        at position: Int, source: NSString
    ) -> Bool {
        let rawStart = max(0, position - maximumLexicalScanUTF16Length)
        // Without the earlier document prefix the fence state is unknowable.
        // Fail closed instead of continuing markup inside a possible code fence.
        guard rawStart == 0 else { return true }
        let prefix = source.substring(with: NSRange(location: 0, length: position))
        var fence: (unit: Character, length: Int)?
        for line in prefix.split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first, first == "`" || first == "~" else {
                continue
            }
            let count = trimmed.prefix(while: { $0 == first }).count
            guard count >= 3 else { continue }
            if let active = fence {
                if active.unit == first, count >= active.length { fence = nil }
            } else {
                fence = (first, count)
            }
        }
        return fence != nil
    }

    static func indentation(
        columns: Int, tabWidth: Int, insertSpaces: Bool
    ) -> String {
        guard !insertSpaces else { return String(repeating: " ", count: columns) }
        return String(repeating: "\t", count: columns / tabWidth)
            + String(repeating: " ", count: columns % tabWidth)
    }

    static func consumingFollowingWhitespace(
        in range: NSRange, source: NSString
    ) -> NSRange {
        let lineEnd = lineEnd(after: range.location, source: source)
        var end = NSMaxRange(range)
        while end < lineEnd {
            let unit = source.character(at: end)
            guard isECMAScriptWhitespace(unit) else { break }
            end += 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    static func isWhitespaceOnly(
        from start: Int, to end: Int, source: NSString
    ) -> Bool {
        for index in start..<end {
            let unit = source.character(at: index)
            guard isECMAScriptWhitespace(unit) else { return false }
        }
        return true
    }

    static func isECMAScriptWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0,
             0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        case 0x2000...0x200A:
            return true
        default:
            return false
        }
    }

    static func leadingIndent(at lineStart: Int, source: NSString) -> String {
        let start = min(max(0, lineStart), source.length)
        var end = start
        let lineEnd = lineEnd(after: start, source: source)
        while end < lineEnd {
            let unit = source.character(at: end)
            guard isECMAScriptWhitespace(unit) else { break }
            end += 1
        }
        return source.substring(with: NSRange(location: start, length: end - start))
    }

    static func previousNonspace(before position: Int, source: NSString) -> UInt16? {
        var index = min(position, source.length)
        while index > 0 {
            let unit = source.character(at: index - 1)
            if unit == 0x0A || unit == 0x0D { return nil }
            if unit != 0x20 && unit != 0x09 { return unit }
            index -= 1
        }
        return nil
    }

    static func previousNonspace(in text: String) -> UInt16? {
        Array(text.utf16.reversed()).first { $0 != 0x20 && $0 != 0x09 }
    }

    static func displayColumn(at position: Int, source: NSString, tabWidth: Int) -> Int {
        var start = min(position, source.length)
        while start > 0 {
            let unit = source.character(at: start - 1)
            if unit == 0x0A || unit == 0x0D { break }
            start -= 1
        }
        var column = 0
        for index in start..<min(position, source.length) {
            column += source.character(at: index) == 0x09
                ? tabWidth - column % tabWidth : 1
        }
        return column
    }

    static func normalizedLanguage(_ language: String) -> String {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func lexicalProfile(for language: String) -> LexicalProfile {
        let hashComments = [
            "python", "ruby", "shell", "bash", "yaml", "toml",
            "dockerfile", "r", "perl", "cmake", "makefile", "tcl"
        ].contains(language)
        let dashComments = [
            "sql", "mysql", "mariadb sql", "postgresql",
            "sqlite", "plsql", "haskell", "lua"
        ].contains(language)
        let semicolonComments = ["clojure", "common lisp", "scheme", "ini"].contains(language)
        let slashComments = !hashComments && !dashComments && !semicolonComments

        var lineComments: [[UInt16]] = []
        if slashComments { lineComments.append(units("//")) }
        if hashComments { lineComments.append(units("#")) }
        if dashComments { lineComments.append(units("--")) }
        if semicolonComments { lineComments.append(units(";")) }

        let blockComments: [([UInt16], [UInt16])]
        if language == "haskell" {
            blockComments = [(units("{-"), units("-}"))]
        } else if language == "lua" {
            blockComments = [(units("--[["), units("]]"))]
        } else if language == "powershell" {
            blockComments = [(units("<#"), units("#>"))]
        } else if hashComments || semicolonComments {
            blockComments = []
        } else {
            blockComments = [(units("/*"), units("*/"))]
        }
        return LexicalProfile(lineComments: lineComments, blockComments: blockComments)
    }

    static func context(at position: Int, source: NSString, language: String) -> LineContext {
        let lineStart = lineStart(before: position, source: source)
        let lineEnd = lineEnd(after: position, source: source)
        var state = lexicalState(at: lineStart, source: source, language: language)
        let boundedPosition = min(max(position, lineStart), lineEnd)
        var insideAtCursor = state.isInsideLiteralOrComment
        var before: [UInt16] = []
        var after: [UInt16] = []
        var index = lineStart
        while index < lineEnd {
            if index == boundedPosition {
                insideAtCursor = state.isInsideLiteralOrComment
            }
            if state.consume(source: source, index: index, end: lineEnd) {
                index += max(1, state.consumedCount)
                continue
            }
            let unit = source.character(at: index)
            if index < boundedPosition {
                before.append(unit)
            } else {
                after.append(unit)
            }
            index += 1
        }
        if boundedPosition == lineEnd {
            insideAtCursor = state.isInsideLiteralOrComment
        }
        return LineContext(
            codeBeforeCursor: String(decoding: before, as: UTF16.self),
            codeAfterCursor: String(decoding: after, as: UTF16.self),
            insideLiteralOrComment: insideAtCursor
        )
    }

    static func lexicalState(at position: Int, source: NSString, language: String) -> LexicalState {
        let profile = lexicalProfile(for: language)
        var state = LexicalState(profile: profile)
        let start = max(0, position - maximumLexicalScanUTF16Length)
        var index = start
        while index < position {
            let lineEnd = lineEnd(after: index, source: source)
            let segmentEnd = min(lineEnd, position)
            while index < segmentEnd {
                if state.consume(source: source, index: index, end: segmentEnd) {
                    index += max(1, state.consumedCount)
                } else {
                    index += 1
                }
            }
            if segmentEnd == lineEnd, segmentEnd < position {
                state.endLine()
                index = min(position, lineEnd + newlineLength(at: lineEnd, source: source))
            }
        }
        return state
    }

    static func lineStart(before position: Int, source: NSString) -> Int {
        var start = min(max(0, position), source.length)
        while start > 0 {
            let unit = source.character(at: start - 1)
            if unit == 0x0A || unit == 0x0D { break }
            start -= 1
        }
        return start
    }

    static func lineEnd(after position: Int, source: NSString) -> Int {
        var end = min(max(0, position), source.length)
        while end < source.length {
            let unit = source.character(at: end)
            if unit == 0x0A || unit == 0x0D { break }
            end += 1
        }
        return end
    }

    static func newlineLength(at lineEnd: Int, source: NSString) -> Int {
        guard lineEnd < source.length else { return 0 }
        let unit = source.character(at: lineEnd)
        if unit == 0x0D, lineEnd + 1 < source.length, source.character(at: lineEnd + 1) == 0x0A {
            return 2
        }
        return (unit == 0x0A || unit == 0x0D) ? 1 : 0
    }

    static func firstCodeToken(in text: String) -> String? {
        let scalars = Array(text.lowercased().utf16)
        var start: Int?
        var index = 0
        while index < scalars.count {
            let unit = scalars[index]
            if start == nil {
                if isIdentifierStart(unit) { start = index }
            } else if !isIdentifier(unit), let start {
                let token = String(decoding: scalars[start..<index], as: UTF16.self)
                return token
            }
            index += 1
        }
        if let start {
            return String(decoding: scalars[start..<scalars.count], as: UTF16.self)
        }
        return nil
    }

    static func pythonLineStartsBlock(_ code: String) -> Bool {
        code.trimmingCharacters(in: .whitespaces).hasSuffix(":")
    }

    static func rubyLineStartsBlock(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        if lowered.range(
            of: #"\bdo\b(?:\s*\|[^|]*\|)?\s*$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        let first = firstCodeToken(in: lowered)
        return [
            "class", "module", "def", "if", "unless",
            "case", "begin", "while", "until", "for"
        ].contains(first)
    }

    static func matches(_ marker: [UInt16], at index: Int, source: NSString, end: Int) -> Bool {
        guard !marker.isEmpty, index >= 0, marker.count <= end - index else { return false }
        for offset in marker.indices where source.character(at: index + offset) != marker[offset] {
            return false
        }
        return true
    }

    static func units(_ text: String) -> [UInt16] { Array(text.utf16) }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        unit == 0x5F || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    static func isIdentifier(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || (0x30...0x39).contains(unit)
    }
}
