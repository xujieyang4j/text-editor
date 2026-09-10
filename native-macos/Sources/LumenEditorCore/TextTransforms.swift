import Foundation
import NaturalLanguage

/// A replacement whose bounds are UTF-16 offsets in the original document.
public struct TextTransformEdit: Equatable, Sendable {
    public let from: Int
    public let to: Int
    public let insert: String

    public init(from: Int, to: Int, insert: String) {
        self.from = from
        self.to = to
        self.insert = insert
    }

    public var range: NSRange {
        NSRange(location: from, length: to - from)
    }
}

/// An atomic text transformation and the selections to install afterwards.
public struct TextTransformPlan: Equatable, Sendable {
    public let changes: [TextTransformEdit]
    public let ranges: [SessionSelection]

    public init(changes: [TextTransformEdit], ranges: [SessionSelection]) {
        self.changes = changes
        self.ranges = ranges
    }
}

public typealias CaseTransformPlan = TextTransformPlan
public typealias LineTransformPlan = TextTransformPlan
public typealias ParagraphTransformPlan = TextTransformPlan
public typealias FinalNewlinePlan = TextTransformPlan

public struct TextStatistics: Equatable, Sendable {
    public let lines: Int
    public let characters: Int
    public let charactersExcludingWhitespace: Int
    public let words: Int

    public init(
        lines: Int,
        characters: Int,
        charactersExcludingWhitespace: Int,
        words: Int
    ) {
        self.lines = lines
        self.characters = characters
        self.charactersExcludingWhitespace = charactersExcludingWhitespace
        self.words = words
    }
}

public enum CaseTransformKind: String, CaseIterable, Codable, Sendable {
    case upper
    case lower
    case title
    case swap
}

public enum LineTransformMode: String, CaseIterable, Codable, Sendable {
    case sortAscending = "sort-ascending"
    case sortDescending = "sort-descending"
    case reverse
    case unique
    case removeBlank = "remove-blank"
}

public enum ParagraphTransformMode: String, CaseIterable, Codable, Sendable {
    case wrap
    case unwrap
}

public enum ParagraphMarker: String, CaseIterable, Codable, Sendable {
    case none = ""
    case hash = "#"
    case slash = "//"
    case tripleSlash = "///"
}

public struct ParagraphTransformOptions: Equatable, Sendable {
    public var column: Double
    public var tabWidth: Double

    public init(column: Double = 80, tabWidth: Double = 8) {
        self.column = column
        self.tabWidth = tabWidth
    }
}

public struct ResolvedParagraphTransformOptions: Equatable, Sendable {
    public let column: Int
    public let tabWidth: Int

    public init(column: Int, tabWidth: Int) {
        self.column = column
        self.tabWidth = tabWidth
    }
}

public struct ParagraphLine: Equatable, Sendable {
    public let lineIndex: Int
    public let from: Int
    public let to: Int
    public let text: String
    public let indent: String
    public let marker: ParagraphMarker
    public let prefix: String
    public let contentFrom: Int
    public let content: String
    public let isBoundary: Bool

    public init(
        lineIndex: Int,
        from: Int,
        to: Int,
        text: String,
        indent: String,
        marker: ParagraphMarker,
        prefix: String,
        contentFrom: Int,
        content: String,
        isBoundary: Bool
    ) {
        self.lineIndex = lineIndex
        self.from = from
        self.to = to
        self.text = text
        self.indent = indent
        self.marker = marker
        self.prefix = prefix
        self.contentFrom = contentFrom
        self.content = content
        self.isBoundary = isBoundary
    }
}

public struct ParagraphBlock: Equatable, Sendable {
    public let from: Int
    public let to: Int
    public let text: String
    public let indent: String
    public let marker: ParagraphMarker
    public let prefix: String
    public let lines: [ParagraphLine]

    public init(
        from: Int,
        to: Int,
        text: String,
        indent: String,
        marker: ParagraphMarker,
        prefix: String,
        lines: [ParagraphLine]
    ) {
        self.from = from
        self.to = to
        self.text = text
        self.indent = indent
        self.marker = marker
        self.prefix = prefix
        self.lines = lines
    }
}

/// Pure text operations shared by editor commands. All document positions are
/// UTF-16 offsets and all editor text accepted by line/paragraph operations is
/// expected to have LF-normalised line endings.
public enum TextTransforms {
    // MARK: - General text helpers

    public static func textStatistics(_ text: String) -> TextStatistics {
        guard !text.isEmpty else {
            return TextStatistics(lines: 0, characters: 0, charactersExcludingWhitespace: 0, words: 0)
        }

        var characters = 0
        var nonWhitespace = 0
        for character in text {
            characters += 1
            if !isECMAScriptWhitespaceCluster(character) { nonWhitespace += 1 }
        }

        let words = wordCount(text)

        let units = utf16(text)
        var lines = 1
        var index = 0
        while index < units.count {
            if units[index] == 0x0d {
                lines += 1
                if index + 1 < units.count, units[index + 1] == 0x0a { index += 1 }
            } else if units[index] == 0x0a {
                lines += 1
            }
            index += 1
        }

        return TextStatistics(
            lines: lines,
            characters: characters,
            charactersExcludingWhitespace: nonWhitespace,
            words: words
        )
    }

    /// Detects physical newline style with the same priority as Electron:
    /// any CRLF wins, followed by any lone CR, otherwise LF.
    public static func detectLineEnding(_ text: String) -> LineEnding {
        TextFileCodec.detectLineEnding(in: text)
    }

    public static func normalizeLineEndings(_ text: String) -> String {
        TextFileCodec.normalizeLineEndings(text)
    }

    public static func applyLineEnding(_ text: String, lineEnding: LineEnding) -> String {
        TextFileCodec.applyLineEnding(text, lineEnding: lineEnding)
    }

    /// Exact UTF-8 byte length of the JSON string representation, including
    /// its quotes. A finite `stopAfter` permits an early over-budget result.
    public static func jsonStringUTF8ByteLength(
        _ value: String,
        stopAfter: Int = .max
    ) -> Int {
        let units = utf16(value)
        var bytes = 2
        var index = 0
        while index < units.count {
            let unit = units[index]
            switch unit {
            case 0x22, 0x5c, 0x08, 0x09, 0x0a, 0x0c, 0x0d:
                bytes += 2
            case 0x00...0x1f:
                bytes += 6
            case 0x20...0x7f:
                bytes += 1
            case 0x80...0x7ff:
                bytes += 2
            case 0xd800...0xdbff:
                if index + 1 < units.count, (0xdc00...0xdfff).contains(units[index + 1]) {
                    bytes += 4
                    index += 1
                } else {
                    bytes += 6
                }
            case 0xdc00...0xdfff:
                bytes += 6
            default:
                bytes += 3
            }
            if bytes > stopAfter { return bytes }
            index += 1
        }
        return bytes
    }

    /// Applies non-overlapping edits expressed in original-document offsets.
    /// Plans produced here are ordered, but applying backwards also makes this
    /// helper safe for callers that retain those original offsets.
    public static func applying(
        _ changes: [TextTransformEdit],
        to text: String
    ) -> String {
        let result = NSMutableString(string: text)
        let ascending = changes.sorted(by: editAscending)
        for (index, change) in ascending.enumerated() {
            precondition(change.from >= 0 && change.to >= change.from && change.to <= result.length)
            if index > 0 { precondition(ascending[index - 1].to <= change.from) }
        }
        for change in ascending.reversed() {
            result.replaceCharacters(in: change.range, with: change.insert)
        }
        return result as String
    }

    // MARK: - Case transformations

    /// Locale-independent case conversion matching JavaScript String casing.
    public static func transformCase(_ source: String, kind: CaseTransformKind) -> String {
        switch kind {
        case .upper:
            return source.uppercased()
        case .lower:
            return source.lowercased()
        case .title:
            return titleCaseLikeElectron(source)
        case .swap:
            var result = ""
            result.reserveCapacity(source.utf8.count)
            for scalar in source.unicodeScalars {
                let piece = String(scalar)
                guard scalar.properties.isCased else {
                    result += piece
                    continue
                }
                result += scalar.properties.isLowercase ? piece.uppercased() : piece.lowercased()
            }
            return result
        }
    }

    /// Builds one multi-selection-safe case transaction. If every range is a
    /// caret, the whole document is transformed and selected.
    public static func planCaseTransform(
        _ text: String,
        ranges: [SessionSelection],
        kind: CaseTransformKind
    ) -> CaseTransformPlan? {
        let textLength = utf16Length(text)
        precondition(ranges.allSatisfy {
            isScalarBoundary($0.anchor, in: text) && isScalarBoundary($0.head, in: text)
        }, "Case transform ranges must use valid UTF-16 scalar boundaries.")
        let hasSelection = ranges.contains { $0.anchor != $0.head }
        if !hasSelection {
            let transformed = transformCase(text, kind: kind)
            guard !exactlyEqual(transformed, text) else { return nil }
            return TextTransformPlan(
                changes: [TextTransformEdit(from: 0, to: textLength, insert: transformed)],
                ranges: [SessionSelection(anchor: 0, head: utf16Length(transformed))]
            )
        }

        let units = utf16(text)
        var candidates: [IndexedCaseChange] = []
        for (rangeIndex, range) in ranges.enumerated() where range.anchor != range.head {
            let from = clamp(min(range.anchor, range.head), lower: 0, upper: units.count)
            let to = clamp(max(range.anchor, range.head), lower: 0, upper: units.count)
            let original = string(units, from: from, to: to)
            let insert = transformCase(original, kind: kind)
            guard !exactlyEqual(insert, original) else { continue }
            candidates.append(IndexedCaseChange(
                rangeIndex: rangeIndex,
                from: from,
                to: to,
                insert: insert,
                finalFrom: 0
            ))
        }
        guard !candidates.isEmpty else { return nil }

        candidates.sort { left, right in
            left.from != right.from ? left.from < right.from : left.to < right.to
        }
        var delta = 0
        for index in candidates.indices {
            candidates[index].finalFrom = candidates[index].from + delta
            delta += utf16Length(candidates[index].insert) - (candidates[index].to - candidates[index].from)
        }

        let changedByRange = Dictionary(uniqueKeysWithValues: candidates.map { ($0.rangeIndex, $0) })
        let mappedRanges = ranges.enumerated().map { rangeIndex, range -> SessionSelection in
            if let change = changedByRange[rangeIndex] {
                let finalTo = change.finalFrom + utf16Length(change.insert)
                return range.anchor <= range.head
                    ? SessionSelection(anchor: change.finalFrom, head: finalTo)
                    : SessionSelection(anchor: finalTo, head: change.finalFrom)
            }
            return SessionSelection(
                anchor: mapPositionThroughCaseChanges(range.anchor, textLength: textLength, changes: candidates),
                head: mapPositionThroughCaseChanges(range.head, textLength: textLength, changes: candidates)
            )
        }
        return TextTransformPlan(
            changes: candidates.map { TextTransformEdit(from: $0.from, to: $0.to, insert: $0.insert) },
            ranges: mappedRanges
        )
    }

    // MARK: - Line transformations

    public static func sortLinesAscending(_ text: String) -> String {
        transformLines(text, mode: .sortAscending)
    }

    public static func sortLinesDescending(_ text: String) -> String {
        transformLines(text, mode: .sortDescending)
    }

    public static func reverseLines(_ text: String) -> String {
        transformLines(text, mode: .reverse)
    }

    public static func uniqueLines(_ text: String) -> String {
        transformLines(text, mode: .unique)
    }

    public static func removeBlankLines(_ text: String) -> String {
        transformLines(text, mode: .removeBlank)
    }

    public static func transformLines(_ text: String, mode: LineTransformMode) -> String {
        transformLineDocument(text, mode: mode).text
    }

    public static func wouldTransformLines(_ text: String, mode: LineTransformMode) -> Bool {
        !exactlyEqual(transformLines(text, mode: mode), text)
    }

    public static func lineTransformEdits(
        _ text: String,
        ranges: [SessionSelection],
        mode: LineTransformMode
    ) -> [TextTransformEdit] {
        planLineTransform(text, ranges: ranges, mode: mode).changes
    }

    public static func planLineTransform(
        _ text: String,
        ranges: [SessionSelection],
        mode: LineTransformMode
    ) -> LineTransformPlan {
        let units = utf16(text)
        let selected = ranges.enumerated().filter { $0.element.anchor != $0.element.head }
        var spans: [LineSpan]
        if selected.isEmpty {
            spans = [LineSpan(from: 0, to: units.count, rangeIndexes: [])]
        } else {
            spans = selected.map { rangeIndex, range in
                let from = clamp(min(range.anchor, range.head), lower: 0, upper: units.count)
                let to = clamp(max(range.anchor, range.head), lower: 0, upper: units.count)
                let lineFrom: Int
                if from == 0 {
                    lineFrom = 0
                } else {
                    lineFrom = (lastIndex(of: 0x0a, in: units, before: from) ?? -1) + 1
                }
                let endpoint = to > from && units[to - 1] == 0x0a ? to - 1 : to
                let nextBreak = firstIndex(of: 0x0a, in: units, from: endpoint)
                return LineSpan(
                    from: lineFrom,
                    to: nextBreak.map { $0 + 1 } ?? units.count,
                    rangeIndexes: [rangeIndex]
                )
            }
        }

        spans.sort { left, right in
            left.from != right.from ? left.from < right.from : left.to < right.to
        }
        var merged: [LineSpan] = []
        for span in spans {
            if let last = merged.last, span.from < last.to {
                merged[merged.count - 1].to = max(last.to, span.to)
                merged[merged.count - 1].rangeIndexes.append(contentsOf: span.rangeIndexes)
            } else {
                merged.append(span)
            }
        }

        if mode == .removeBlank {
            return planRemoveBlankLines(text, units: units, ranges: ranges, targets: merged)
        }

        var delta = 0
        var planned: [PlannedLineBlock] = []
        for span in merged {
            let original = string(units, from: span.from, to: span.to)
            let transformed = transformLineDocument(original, mode: mode)
            let changed = !exactlyEqual(transformed.text, original)
            let finalFrom = span.from + delta
            let finalTo = finalFrom + utf16Length(transformed.text)
            planned.append(PlannedLineBlock(
                from: span.from,
                to: span.to,
                insert: transformed.text,
                original: original,
                sourceToOutput: transformed.sourceToOutput,
                finalFrom: finalFrom,
                finalTo: finalTo,
                rangeIndexes: span.rangeIndexes,
                changed: changed
            ))
            if changed { delta += utf16Length(transformed.text) - (span.to - span.from) }
        }

        let changes = planned.filter(\.changed)
        guard !changes.isEmpty else {
            return TextTransformPlan(changes: [], ranges: ranges)
        }

        var targetByRange: [Int: PlannedLineBlock] = [:]
        for block in planned {
            for rangeIndex in block.rangeIndexes { targetByRange[rangeIndex] = block }
        }
        let mappedRanges = ranges.enumerated().map { rangeIndex, range -> SessionSelection in
            if range.anchor != range.head, let block = targetByRange[rangeIndex] {
                return range.anchor <= range.head
                    ? SessionSelection(anchor: block.finalFrom, head: block.finalTo)
                    : SessionSelection(anchor: block.finalTo, head: block.finalFrom)
            }
            return SessionSelection(
                anchor: mapPositionThroughLineChanges(text, changes: changes, position: range.anchor),
                head: mapPositionThroughLineChanges(text, changes: changes, position: range.head)
            )
        }
        return TextTransformPlan(
            changes: changes.map { TextTransformEdit(from: $0.from, to: $0.to, insert: $0.insert) },
            ranges: mappedRanges
        )
    }

    // MARK: - Paragraph transformations

    public static func sanitizeParagraphTransformOptions(
        _ options: ParagraphTransformOptions? = nil
    ) -> ResolvedParagraphTransformOptions {
        ResolvedParagraphTransformOptions(
            column: sanitizePositiveInteger(options?.column, fallback: 80),
            tabWidth: sanitizePositiveInteger(options?.tabWidth, fallback: 8)
        )
    }

    public static func measurePrefixColumns(_ prefix: String, tabWidth: Int = 8) -> Int {
        let safeTabWidth = tabWidth > 0 ? tabWidth : 8
        var column = 0
        for character in prefix {
            if character.unicodeScalars.count == 1, character.unicodeScalars.first?.value == 0x09 {
                column += safeTabWidth - (column % safeTabWidth)
            } else {
                column += 1
            }
        }
        return column
    }

    public static func splitParagraphTokens(_ content: String) -> [String] {
        let units = utf16(content)
        var tokens: [String] = []
        var index = 0
        while index < units.count {
            while index < units.count, isHorizontalWhitespace(units[index]) { index += 1 }
            let start = index
            while index < units.count, !isHorizontalWhitespace(units[index]) { index += 1 }
            if start < index { tokens.append(string(units, from: start, to: index)) }
        }
        return tokens
    }

    public static func classifyParagraphLine(
        _ line: String,
        lineIndex: Int = 0,
        from: Int = 0,
        to: Int? = nil
    ) -> ParagraphLine {
        let units = utf16(line)
        let resolvedTo = to ?? units.count
        var indentLength = 0
        while indentLength < units.count, isHorizontalWhitespace(units[indentLength]) {
            indentLength += 1
        }
        let indent = string(units, from: 0, to: indentLength)
        let markerLength = paragraphMarkerLength(units, from: indentLength)
        let marker: ParagraphMarker
        switch markerLength {
        case 3: marker = .tripleSlash
        case 2: marker = .slash
        case 1: marker = .hash
        default: marker = .none
        }

        let restIsBlank = units[indentLength...].allSatisfy { isHorizontalWhitespace($0) }
        if restIsBlank {
            return ParagraphLine(
                lineIndex: lineIndex, from: from, to: resolvedTo, text: line,
                indent: indent, marker: .none, prefix: indent,
                contentFrom: units.count, content: "", isBoundary: true
            )
        }

        if marker != .none {
            var contentFrom = indentLength + markerLength
            while contentFrom < units.count, isHorizontalWhitespace(units[contentFrom]) { contentFrom += 1 }
            let prefix = indent + marker.rawValue + " "
            let content = string(units, from: contentFrom, to: units.count)
            return ParagraphLine(
                lineIndex: lineIndex, from: from, to: resolvedTo, text: line,
                indent: indent, marker: marker, prefix: prefix,
                contentFrom: contentFrom, content: content, isBoundary: content.isEmpty
            )
        }

        return ParagraphLine(
            lineIndex: lineIndex, from: from, to: resolvedTo, text: line,
            indent: indent, marker: .none, prefix: indent,
            contentFrom: indentLength,
            content: string(units, from: indentLength, to: units.count),
            isBoundary: false
        )
    }

    public static func findParagraphBlocks(_ text: String) -> [ParagraphBlock] {
        buildParagraphs(text).paragraphs
    }

    public static func wrapParagraphBlock(
        _ block: ParagraphBlock,
        options: ParagraphTransformOptions? = nil
    ) -> String {
        wrapTokens(
            prefix: block.prefix,
            tokens: paragraphTokens(block),
            options: sanitizeParagraphTransformOptions(options)
        )
    }

    public static func unwrapParagraphBlock(_ block: ParagraphBlock) -> String {
        block.prefix + paragraphTokens(block).joined(separator: " ")
    }

    public static func paragraphTransformEdits(
        _ text: String,
        ranges: [SessionSelection],
        mode: ParagraphTransformMode,
        options: ParagraphTransformOptions? = nil
    ) -> [TextTransformEdit] {
        planParagraphTransform(text, ranges: ranges, mode: mode, options: options).changes
    }

    public static func planParagraphTransform(
        _ text: String,
        ranges: [SessionSelection],
        mode: ParagraphTransformMode,
        options: ParagraphTransformOptions? = nil
    ) -> ParagraphTransformPlan {
        let resolvedOptions = sanitizeParagraphTransformOptions(options)
        let built = buildParagraphs(text)
        let indexesByRange = ranges.map { range in
            paragraphIndexesForRange(
                textLength: utf16Length(text),
                lineStarts: built.lineStarts,
                paragraphByLineIndex: built.paragraphByLineIndex,
                range: range
            )
        }

        var targetedSet: Set<Int> = []
        var targeted: [Int] = []
        for indexes in indexesByRange {
            for index in indexes where targetedSet.insert(index).inserted { targeted.append(index) }
        }
        targeted.sort { built.paragraphs[$0].from < built.paragraphs[$1].from }

        var delta = 0
        var planned: [PlannedParagraph] = []
        for paragraphIndex in targeted {
            let paragraph = built.paragraphs[paragraphIndex]
            let transformed = mode == .wrap
                ? wrapTokens(prefix: paragraph.prefix, tokens: paragraphTokens(paragraph), options: resolvedOptions)
                : unwrapParagraphBlock(paragraph)
            let changed = !exactlyEqual(transformed, paragraph.text)
            let finalFrom = paragraph.from + delta
            planned.append(PlannedParagraph(
                paragraph: paragraph,
                transformed: transformed,
                changed: changed,
                finalFrom: finalFrom,
                sourceLayout: changed ? buildParagraphLayout(paragraph.text) : nil,
                outputLayout: changed ? buildParagraphLayout(transformed) : nil
            ))
            delta += utf16Length(transformed) - utf16Length(paragraph.text)
        }

        let changes = planned.compactMap { block -> TextTransformEdit? in
            guard block.changed else { return nil }
            return TextTransformEdit(
                from: block.paragraph.from,
                to: block.paragraph.to,
                insert: block.transformed
            )
        }
        guard !changes.isEmpty else { return TextTransformPlan(changes: [], ranges: ranges) }

        let mappedRanges = ranges.map { range in
            SessionSelection(
                anchor: mapPositionThroughParagraphs(planned, textLength: utf16Length(text), position: range.anchor),
                head: mapPositionThroughParagraphs(planned, textLength: utf16Length(text), position: range.head)
            )
        }
        return TextTransformPlan(changes: changes, ranges: mappedRanges)
    }

    // MARK: - Final newline

    /// Ensures a non-empty document ends in exactly one LF. Only the trailing
    /// run of LF characters is touched; trailing spaces and tabs are content.
    public static func planSingleFinalNewline(
        _ text: String,
        ranges: [SessionSelection]
    ) -> FinalNewlinePlan? {
        let units = utf16(text)
        guard !units.isEmpty else { return nil }
        guard units.last == 0x0a else {
            return TextTransformPlan(
                changes: [TextTransformEdit(from: units.count, to: units.count, insert: "\n")],
                ranges: ranges
            )
        }

        var firstTrailingNewline = units.count - 1
        while firstTrailingNewline > 0, units[firstTrailingNewline - 1] == 0x0a {
            firstTrailingNewline -= 1
        }
        let keepThrough = firstTrailingNewline + 1
        guard keepThrough != units.count else { return nil }

        return TextTransformPlan(
            changes: [TextTransformEdit(from: keepThrough, to: units.count, insert: "")],
            ranges: ranges.map { range in
                SessionSelection(
                    anchor: min(clamp(range.anchor, lower: 0, upper: units.count), keepThrough),
                    head: min(clamp(range.head, lower: 0, upper: units.count), keepThrough)
                )
            }
        )
    }
}

// MARK: - Shared UTF-16 helpers

private func utf16(_ text: String) -> [UInt16] { Array(text.utf16) }
private func utf16Length(_ text: String) -> Int { text.utf16.count }

private func isScalarBoundary(_ offset: Int, in text: String) -> Bool {
    let units = utf16(text)
    guard offset >= 0, offset <= units.count else { return true }
    guard offset > 0, offset < units.count else { return true }
    return !((0xd800...0xdbff).contains(units[offset - 1])
        && (0xdc00...0xdfff).contains(units[offset]))
}

private func string(_ units: [UInt16], from: Int, to: Int) -> String {
    String(decoding: units[from..<to], as: UTF16.self)
}

private func exactlyEqual(_ left: String, _ right: String) -> Bool {
    utf16(left) == utf16(right)
}

private func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
    min(max(value, lower), upper)
}

private func editAscending(_ left: TextTransformEdit, _ right: TextTransformEdit) -> Bool {
    if left.from != right.from { return left.from < right.from }
    return left.to < right.to
}

private func firstIndex(of unit: UInt16, in units: [UInt16], from: Int) -> Int? {
    guard from < units.count else { return nil }
    for index in max(0, from)..<units.count where units[index] == unit { return index }
    return nil
}

private func lastIndex(of unit: UInt16, in units: [UInt16], before: Int) -> Int? {
    guard before > 0, !units.isEmpty else { return nil }
    var index = min(before, units.count) - 1
    while index >= 0 {
        if units[index] == unit { return index }
        if index == 0 { break }
        index -= 1
    }
    return nil
}

private func isHorizontalWhitespace(_ unit: UInt16) -> Bool {
    unit == 0x09 || unit == 0x20
}

private func isBlankLine(_ line: String) -> Bool {
    utf16(line).allSatisfy { isHorizontalWhitespace($0) }
}

private func isECMAScriptWhitespaceCluster(_ character: Character) -> Bool {
    let scalars = character.unicodeScalars
    guard scalars.count == 1, let scalar = scalars.first else { return false }
    switch scalar.value {
    case 0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x0020, 0x00a0, 0x1680,
         0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
        return true
    case 0x2000...0x200a:
        return true
    default:
        return false
    }
}

/// NaturalLanguage is the closest system analogue to `Intl.Segmenter` word
/// segmentation. Keep the Electron fixtures in tests: Apple and V8 may ship
/// different ICU/model versions for uncommon scripts.
private func wordCount(_ text: String) -> Int {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var count = 0
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        if text[range].unicodeScalars.contains(where: { isWordLikeScalar($0) }) { count += 1 }
        return true
    }
    return count
}

private func isWordLikeScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .decimalNumber, .letterNumber, .otherNumber:
        return true
    default:
        return false
    }
}

private func isASCIIWordUnit(_ unit: UInt16) -> Bool {
    (0x30...0x39).contains(unit)
        || (0x41...0x5a).contains(unit)
        || unit == 0x5f
        || (0x61...0x7a).contains(unit)
}

private func isUnicodeLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return false
    }
}

private func titleCaseLikeElectron(_ source: String) -> String {
    let lowered = source.lowercased()
    let units = utf16(lowered)
    var result = ""
    result.reserveCapacity(lowered.utf8.count)
    var offset = 0
    for scalar in lowered.unicodeScalars {
        let currentIsWord = offset < units.count && isASCIIWordUnit(units[offset])
        let previousIsWord = offset > 0 && isASCIIWordUnit(units[offset - 1])
        let atWordBoundary = currentIsWord != previousIsWord
        let piece = String(scalar)
        result += atWordBoundary && isUnicodeLetter(scalar) ? piece.uppercased() : piece
        offset += scalar.value > 0xffff ? 2 : 1
    }
    return result
}

// MARK: - Case planning internals

private struct IndexedCaseChange {
    let rangeIndex: Int
    let from: Int
    let to: Int
    let insert: String
    var finalFrom: Int
}

private func mapPositionThroughCaseChanges(
    _ position: Int,
    textLength: Int,
    changes: [IndexedCaseChange]
) -> Int {
    let position = clamp(position, lower: 0, upper: textLength)
    var delta = 0
    for change in changes {
        if position < change.from { break }
        if position == change.from { return change.from + delta }
        if position < change.to {
            let relative = position - change.from
            return change.finalFrom + min(relative, utf16Length(change.insert))
        }
        delta += utf16Length(change.insert) - (change.to - change.from)
    }
    return position + delta
}

// MARK: - Line transformation internals

private struct LineDocument {
    var lines: [String]
    let trailingNewline: Bool
}

private struct TransformedLineDocument {
    let text: String
    let sourceToOutput: [Int]
}

private struct LineRecord {
    let line: String
    let sourceIndex: Int
}

private struct UTF16Key: Hashable {
    let units: [UInt16]
    init(_ string: String) { units = utf16(string) }
}

private func splitLineDocument(_ text: String) -> LineDocument {
    let units = utf16(text)
    guard !units.isEmpty else { return LineDocument(lines: [], trailingNewline: false) }
    let trailingNewline = units.last == 0x0a
    var lines: [String] = []
    var lineStart = 0
    for index in units.indices where units[index] == 0x0a {
        lines.append(string(units, from: lineStart, to: index))
        lineStart = index + 1
    }
    if !trailingNewline { lines.append(string(units, from: lineStart, to: units.count)) }
    return LineDocument(lines: lines, trailingNewline: trailingNewline)
}

private func joinLineDocument(_ document: LineDocument) -> String {
    document.lines.joined(separator: "\n") + (document.trailingNewline ? "\n" : "")
}

private func compareExact(_ left: String, _ right: String) -> Int {
    let leftUnits = utf16(left)
    let rightUnits = utf16(right)
    if leftUnits == rightUnits { return 0 }
    return leftUnits.lexicographicallyPrecedes(rightUnits) ? -1 : 1
}

private func stableSort(_ records: [LineRecord], descending: Bool) -> [LineRecord] {
    records.sorted { left, right in
        let comparison = compareExact(left.line, right.line)
        if comparison == 0 { return left.sourceIndex < right.sourceIndex }
        return descending ? comparison > 0 : comparison < 0
    }
}

private func transformLineDocument(_ text: String, mode: LineTransformMode) -> TransformedLineDocument {
    let document = splitLineDocument(text)
    let records = document.lines.enumerated().map { LineRecord(line: $0.element, sourceIndex: $0.offset) }
    let output: [LineRecord]
    switch mode {
    case .sortAscending:
        output = stableSort(records, descending: false)
    case .sortDescending:
        output = stableSort(records, descending: true)
    case .reverse:
        output = Array(records.reversed())
    case .unique:
        var seen: Set<UTF16Key> = []
        output = records.filter { seen.insert(UTF16Key($0.line)).inserted }
    case .removeBlank:
        output = records.filter { !isBlankLine($0.line) }
    }

    var sourceToOutput = Array(repeating: 0, count: records.count)
    var firstOutputByLine: [UTF16Key: Int] = [:]
    for (outputIndex, record) in output.enumerated() {
        sourceToOutput[record.sourceIndex] = outputIndex
        if firstOutputByLine[UTF16Key(record.line)] == nil {
            firstOutputByLine[UTF16Key(record.line)] = outputIndex
        }
    }
    if mode == .unique {
        for record in records {
            sourceToOutput[record.sourceIndex] = firstOutputByLine[UTF16Key(record.line)] ?? 0
        }
    } else if mode == .removeBlank {
        var retainedBefore = 0
        for record in records {
            sourceToOutput[record.sourceIndex] = retainedBefore
            if !isBlankLine(record.line) { retainedBefore += 1 }
        }
    }

    let outputText: String
    if mode == .removeBlank && output.isEmpty {
        outputText = ""
    } else {
        outputText = joinLineDocument(LineDocument(
            lines: output.map(\.line),
            trailingNewline: document.trailingNewline
        ))
    }
    return TransformedLineDocument(text: outputText, sourceToOutput: sourceToOutput)
}

private func lineStarts(_ text: String) -> [Int] {
    let units = utf16(text)
    var starts = [0]
    for index in units.indices where units[index] == 0x0a { starts.append(index + 1) }
    return starts
}

private func lineIndex(at position: Int, starts: [Int]) -> Int {
    var low = 0
    var high = starts.count
    while low < high {
        let middle = (low + high) >> 1
        if starts[middle] <= position { low = middle + 1 } else { high = middle }
    }
    return max(0, low - 1)
}

private struct LineSpan {
    var from: Int
    var to: Int
    var rangeIndexes: [Int]
}

private struct PlannedLineBlock {
    let from: Int
    let to: Int
    let insert: String
    let original: String
    let sourceToOutput: [Int]
    let finalFrom: Int
    let finalTo: Int
    let rangeIndexes: [Int]
    let changed: Bool
}

private func mapWithinReplacement(_ change: PlannedLineBlock, offset: Int) -> Int {
    let originalLength = utf16Length(change.original)
    let insertLength = utf16Length(change.insert)
    let offset = clamp(offset, lower: 0, upper: originalLength)
    let originalDocument = splitLineDocument(change.original)
    let outputDocument = splitLineDocument(change.insert)
    let originalStarts = lineStarts(change.original)
    let outputStarts = lineStarts(change.insert)
    let originalLineIndex = lineIndex(at: offset, starts: originalStarts)

    if originalDocument.trailingNewline && originalLineIndex >= originalDocument.lines.count {
        return insertLength
    }
    guard originalLineIndex < change.sourceToOutput.count else { return insertLength }
    let outputLineIndex = change.sourceToOutput[originalLineIndex]
    guard outputLineIndex < outputDocument.lines.count else { return insertLength }
    let outputLineStart = outputStarts[outputLineIndex]
    let column = offset - originalStarts[originalLineIndex]
    return outputLineStart + min(column, utf16Length(outputDocument.lines[outputLineIndex]))
}

private func mapPositionThroughLineChanges(
    _ text: String,
    changes: [PlannedLineBlock],
    position: Int
) -> Int {
    let textLength = utf16Length(text)
    let position = clamp(position, lower: 0, upper: textLength)
    var delta = 0
    for change in changes {
        if position < change.from { break }
        let followsFinalLine = position == change.to
            && change.to == textLength
            && utf16(change.original).last != 0x0a
        if position < change.to || followsFinalLine {
            return change.finalFrom + mapWithinReplacement(change, offset: position - change.from)
        }
        delta += utf16Length(change.insert) - (change.to - change.from)
    }
    return position + delta
}

private func planRemoveBlankLines(
    _ text: String,
    units: [UInt16],
    ranges: [SessionSelection],
    targets: [LineSpan]
) -> LineTransformPlan {
    var removals: [TextTransformEdit] = []
    for target in targets {
        var lineStart = target.from
        while lineStart < target.to {
            let nextBreak = firstIndex(of: 0x0a, in: units, from: lineStart)
            let lineEnd = nextBreak == nil || nextBreak! >= target.to ? target.to : nextBreak!
            let line = string(units, from: lineStart, to: lineEnd)
            if isBlankLine(line) {
                let removalTo = lineEnd < target.to && lineEnd < units.count && units[lineEnd] == 0x0a
                    ? lineEnd + 1
                    : lineEnd
                removals.append(TextTransformEdit(from: lineStart, to: removalTo, insert: ""))
            }
            if lineEnd >= target.to { break }
            lineStart = lineEnd + 1
        }
    }

    removals.sort { left, right in
        left.from != right.from ? left.from < right.from : left.to < right.to
    }
    var changes: [TextTransformEdit] = []
    for removal in removals where removal.from != removal.to {
        if let previous = changes.last, removal.from <= previous.to {
            changes[changes.count - 1] = TextTransformEdit(
                from: previous.from, to: max(previous.to, removal.to), insert: ""
            )
        } else {
            changes.append(removal)
        }
    }

    if let terminal = changes.last,
       terminal.to == units.count, units.last != 0x0a,
       terminal.from > 0, units[terminal.from - 1] == 0x0a {
        let adjustedFrom = terminal.from - 1
        changes[changes.count - 1] = TextTransformEdit(from: adjustedFrom, to: terminal.to, insert: "")
        if changes.count >= 2 {
            let previous = changes[changes.count - 2]
            if previous.to >= adjustedFrom {
                changes.removeLast(2)
                changes.append(TextTransformEdit(from: previous.from, to: terminal.to, insert: ""))
            }
        }
    }

    guard !changes.isEmpty else { return TextTransformPlan(changes: [], ranges: ranges) }

    func mapPosition(_ rawPosition: Int) -> Int {
        let position = clamp(rawPosition, lower: 0, upper: units.count)
        var delta = 0
        for change in changes {
            if position < change.from { break }
            if position <= change.to { return change.from + delta }
            delta -= change.to - change.from
        }
        return position + delta
    }

    var targetByRange: [Int: (from: Int, to: Int)] = [:]
    for target in targets {
        let mapped = (from: mapPosition(target.from), to: mapPosition(target.to))
        for index in target.rangeIndexes { targetByRange[index] = mapped }
    }
    let mappedRanges = ranges.enumerated().map { index, range -> SessionSelection in
        if range.anchor != range.head, let target = targetByRange[index] {
            return range.anchor <= range.head
                ? SessionSelection(anchor: target.from, head: target.to)
                : SessionSelection(anchor: target.to, head: target.from)
        }
        return SessionSelection(anchor: mapPosition(range.anchor), head: mapPosition(range.head))
    }
    return TextTransformPlan(changes: changes, ranges: mappedRanges)
}

// MARK: - Paragraph transformation internals

private struct DocumentLine {
    let index: Int
    let start: Int
    let end: Int
    let text: String
    let virtual: Bool
}

private struct BuiltParagraphs {
    let paragraphs: [ParagraphBlock]
    let paragraphByLineIndex: [Int]
    let lineStarts: [Int]
}

private struct ParagraphToken {
    let sourceFrom: Int
    let sourceTo: Int
    let logicalFrom: Int
    let logicalTo: Int
}

private struct ParagraphLayout {
    let text: String
    let tokens: [ParagraphToken]
    let logicalLength: Int
}

private struct PlannedParagraph {
    let paragraph: ParagraphBlock
    let transformed: String
    let changed: Bool
    let finalFrom: Int
    let sourceLayout: ParagraphLayout?
    let outputLayout: ParagraphLayout?
}

private func sanitizePositiveInteger(_ value: Double?, fallback: Int) -> Int {
    guard let value, value.isFinite else { return fallback }
    let rounded = floor(value)
    guard rounded > 0 else { return fallback }
    if rounded >= Double(Int.max) { return Int.max }
    return Int(rounded)
}

private func paragraphMarkerLength(_ units: [UInt16], from start: Int) -> Int {
    func accepted(_ marker: [UInt16]) -> Bool {
        guard start + marker.count <= units.count else { return false }
        guard Array(units[start..<(start + marker.count)]) == marker else { return false }
        let next = start + marker.count
        return next == units.count || isHorizontalWhitespace(units[next])
    }
    if accepted([0x2f, 0x2f, 0x2f]) { return 3 }
    if accepted([0x2f, 0x2f]) { return 2 }
    if accepted([0x23]) { return 1 }
    return 0
}

private func splitDocumentLines(_ text: String) -> [DocumentLine] {
    let units = utf16(text)
    guard !units.isEmpty else {
        return [DocumentLine(index: 0, start: 0, end: 0, text: "", virtual: true)]
    }
    var lines: [DocumentLine] = []
    var lineStart = 0
    var lineIndex = 0
    for index in units.indices where units[index] == 0x0a {
        lines.append(DocumentLine(
            index: lineIndex, start: lineStart, end: index,
            text: string(units, from: lineStart, to: index), virtual: false
        ))
        lineStart = index + 1
        lineIndex += 1
    }
    if units.last != 0x0a {
        lines.append(DocumentLine(
            index: lineIndex, start: lineStart, end: units.count,
            text: string(units, from: lineStart, to: units.count), virtual: false
        ))
    } else {
        lines.append(DocumentLine(
            index: lineIndex, start: units.count, end: units.count, text: "", virtual: true
        ))
    }
    return lines
}

private func buildParagraphs(_ text: String) -> BuiltParagraphs {
    let lines = splitDocumentLines(text)
    var paragraphByLineIndex = Array(repeating: -1, count: lines.count)
    var paragraphs: [ParagraphBlock] = []
    let starts = lines.map(\.start)
    var current: [ParagraphLine] = []
    let textUnits = utf16(text)

    func makeBlock(_ current: [ParagraphLine]) -> ParagraphBlock {
        let first = current[0]
        let last = current[current.count - 1]
        return ParagraphBlock(
            from: first.from, to: last.to,
            text: string(textUnits, from: first.from, to: last.to),
            indent: first.indent, marker: first.marker, prefix: first.prefix, lines: current
        )
    }

    func shouldSplit(_ previous: ParagraphLine, _ next: ParagraphLine) -> Bool {
        !exactlyEqual(previous.indent, next.indent) || previous.marker != next.marker
    }

    for line in lines {
        let classified = TextTransforms.classifyParagraphLine(
            line.text, lineIndex: line.index, from: line.start, to: line.end
        )
        if line.virtual || classified.isBoundary {
            if !current.isEmpty {
                let paragraphIndex = paragraphs.count
                paragraphs.append(makeBlock(current))
                for item in current { paragraphByLineIndex[item.lineIndex] = paragraphIndex }
                current.removeAll(keepingCapacity: true)
            }
            continue
        }
        if let previous = current.last, shouldSplit(previous, classified) {
            let paragraphIndex = paragraphs.count
            paragraphs.append(makeBlock(current))
            for item in current { paragraphByLineIndex[item.lineIndex] = paragraphIndex }
            current.removeAll(keepingCapacity: true)
        }
        current.append(classified)
    }
    if !current.isEmpty {
        let paragraphIndex = paragraphs.count
        paragraphs.append(makeBlock(current))
        for item in current { paragraphByLineIndex[item.lineIndex] = paragraphIndex }
    }
    return BuiltParagraphs(
        paragraphs: paragraphs,
        paragraphByLineIndex: paragraphByLineIndex, lineStarts: starts
    )
}

private func paragraphIndexesForRange(
    textLength: Int,
    lineStarts: [Int],
    paragraphByLineIndex: [Int],
    range: SessionSelection
) -> [Int] {
    let minPosition = clamp(min(range.anchor, range.head), lower: 0, upper: textLength)
    let maxPosition = clamp(max(range.anchor, range.head), lower: 0, upper: textLength)
    if range.anchor == range.head {
        let index = lineIndex(at: minPosition, starts: lineStarts)
        let paragraph = paragraphByLineIndex[index]
        return paragraph < 0 ? [] : [paragraph]
    }

    let maxLineIndex = lineIndex(at: maxPosition, starts: lineStarts)
    let atLineStart = lineStarts[maxLineIndex] == maxPosition
    let effectiveEnd = maxPosition > minPosition && atLineStart
        ? max(minPosition, maxPosition - 1)
        : maxPosition
    let startLine = lineIndex(at: minPosition, starts: lineStarts)
    let endLine = lineIndex(at: effectiveEnd, starts: lineStarts)
    var indexes: [Int] = []
    for index in startLine...endLine {
        let paragraph = paragraphByLineIndex[index]
        if paragraph >= 0 && indexes.last != paragraph { indexes.append(paragraph) }
    }
    return indexes
}

private func paragraphTokens(_ block: ParagraphBlock) -> [String] {
    block.lines.flatMap { TextTransforms.splitParagraphTokens($0.content) }
}

private func trimECMAScriptWhitespaceFromEnd(_ text: String) -> String {
    var result = text
    while let last = result.last, isECMAScriptWhitespaceCluster(last) { result.removeLast() }
    return result
}

private func wrapTokens(
    prefix: String,
    tokens: [String],
    options: ResolvedParagraphTransformOptions
) -> String {
    guard !tokens.isEmpty else { return trimECMAScriptWhitespaceFromEnd(prefix) }
    let prefixColumns = TextTransforms.measurePrefixColumns(prefix, tabWidth: options.tabWidth)
    var lines: [String] = []
    var current: [String] = []
    var currentColumns = prefixColumns
    for token in tokens {
        let tokenColumns = token.count
        if current.isEmpty {
            current = [token]
            currentColumns = prefixColumns + tokenColumns
        } else if currentColumns + 1 + tokenColumns <= options.column {
            current.append(token)
            currentColumns += 1 + tokenColumns
        } else {
            lines.append(prefix + current.joined(separator: " "))
            current = [token]
            currentColumns = prefixColumns + tokenColumns
        }
    }
    lines.append(prefix + current.joined(separator: " "))
    return lines.joined(separator: "\n")
}

private func buildParagraphLayout(_ text: String) -> ParagraphLayout {
    let units = utf16(text)
    guard !units.isEmpty else { return ParagraphLayout(text: text, tokens: [], logicalLength: 0) }
    var tokens: [ParagraphToken] = []
    var logicalLength = 0
    var lineStart = 0
    var lineIndex = 0

    while lineStart <= units.count {
        let nextBreak = firstIndex(of: 0x0a, in: units, from: lineStart)
        let lineEnd = nextBreak ?? units.count
        let line = string(units, from: lineStart, to: lineEnd)
        let classified = TextTransforms.classifyParagraphLine(
            line, lineIndex: lineIndex, from: lineStart, to: lineEnd
        )
        var index = classified.contentFrom
        let lineUnits = utf16(line)
        while index < lineUnits.count {
            while index < lineUnits.count, isHorizontalWhitespace(lineUnits[index]) { index += 1 }
            let tokenStart = index
            while index < lineUnits.count, !isHorizontalWhitespace(lineUnits[index]) { index += 1 }
            guard tokenStart < index else { continue }
            let sourceFrom = lineStart + tokenStart
            if !tokens.isEmpty { logicalLength += 1 }
            let logicalFrom = logicalLength
            let tokenLength = index - tokenStart
            tokens.append(ParagraphToken(
                sourceFrom: sourceFrom, sourceTo: sourceFrom + tokenLength,
                logicalFrom: logicalFrom, logicalTo: logicalFrom + tokenLength
            ))
            logicalLength += tokenLength
        }
        guard let nextBreak else { break }
        lineStart = nextBreak + 1
        lineIndex += 1
    }
    return ParagraphLayout(text: text, tokens: tokens, logicalLength: logicalLength)
}

private enum LogicalParagraphOffset {
    case start
    case end
    case offset(Int)
}

private func mapSourceOffsetToLogical(_ layout: ParagraphLayout, offset: Int) -> LogicalParagraphOffset {
    let offset = clamp(offset, lower: 0, upper: utf16Length(layout.text))
    if offset == 0 { return .start }
    if offset == utf16Length(layout.text) { return .end }
    for token in layout.tokens {
        if offset < token.sourceFrom { return .offset(token.logicalFrom) }
        if offset <= token.sourceTo { return .offset(token.logicalFrom + offset - token.sourceFrom) }
    }
    return .end
}

private func mapLogicalToOutput(_ layout: ParagraphLayout, logical: LogicalParagraphOffset) -> Int {
    switch logical {
    case .start: return 0
    case .end: return utf16Length(layout.text)
    case let .offset(rawOffset):
        let offset = clamp(rawOffset, lower: 0, upper: layout.logicalLength)
        for token in layout.tokens {
            if offset < token.logicalFrom { return token.sourceFrom }
            if offset <= token.logicalTo { return token.sourceFrom + offset - token.logicalFrom }
        }
        return utf16Length(layout.text)
    }
}

private func mapOffsetWithinParagraph(_ block: PlannedParagraph, offset: Int) -> Int {
    guard block.changed, let source = block.sourceLayout, let output = block.outputLayout else {
        return clamp(offset, lower: 0, upper: utf16Length(block.transformed))
    }
    if let firstSource = source.tokens.first, let firstOutput = output.tokens.first,
       offset <= firstSource.sourceFrom {
        return min(offset, firstOutput.sourceFrom)
    }
    return mapLogicalToOutput(output, logical: mapSourceOffsetToLogical(source, offset: offset))
}

private func mapPositionThroughParagraphs(
    _ planned: [PlannedParagraph],
    textLength: Int,
    position: Int
) -> Int {
    let position = clamp(position, lower: 0, upper: textLength)
    var delta = 0
    for block in planned {
        if position < block.paragraph.from { break }
        if position <= block.paragraph.to {
            return block.changed
                ? block.finalFrom + mapOffsetWithinParagraph(block, offset: position - block.paragraph.from)
                : block.finalFrom + position - block.paragraph.from
        }
        delta += utf16Length(block.transformed) - utf16Length(block.paragraph.text)
    }
    return position + delta
}
