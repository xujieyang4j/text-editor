@preconcurrency import Foundation

public struct OutlineLimits: Equatable, Sendable {
    public static let `default` = OutlineLimits(
        maximumSourceUTF16Count: 2 * 1_024 * 1_024,
        maximumSymbols: 5_000,
        maximumFoldRegions: 10_000,
        maximumNestingDepth: 256
    )

    public var maximumSourceUTF16Count: Int
    public var maximumSymbols: Int
    public var maximumFoldRegions: Int
    public var maximumNestingDepth: Int

    public init(
        maximumSourceUTF16Count: Int,
        maximumSymbols: Int,
        maximumFoldRegions: Int,
        maximumNestingDepth: Int
    ) {
        precondition(maximumSourceUTF16Count >= 0)
        precondition(maximumSymbols >= 0)
        precondition(maximumFoldRegions >= 0)
        precondition(maximumNestingDepth >= 0)
        self.maximumSourceUTF16Count = maximumSourceUTF16Count
        self.maximumSymbols = maximumSymbols
        self.maximumFoldRegions = maximumFoldRegions
        self.maximumNestingDepth = maximumNestingDepth
    }
}

public enum OutlineSymbolKind: String, Equatable, Sendable {
    case type
    case function
    case method
    case variable
    case heading
}

public struct OutlineSymbol: Identifiable, Equatable, Sendable {
    public let label: String
    public let kind: OutlineSymbolKind
    public let utf16Offset: Int
    public let line: Int
    public let level: Int

    public var id: String { "\(utf16Offset):\(kind.rawValue):\(label)" }

    public init(
        label: String,
        kind: OutlineSymbolKind,
        utf16Offset: Int,
        line: Int,
        level: Int = 0
    ) {
        self.label = label
        self.kind = kind
        self.utf16Offset = max(0, utf16Offset)
        self.line = max(1, line)
        self.level = max(0, level)
    }
}

/// A fold hides `hiddenRange` while leaving the first line visible. Ranges are
/// UTF-16 offsets so TextKit can consume them without String-index conversion.
public struct TextFoldRegion: Identifiable, Equatable, Hashable, Sendable {
    public let startLine: Int
    public let endLine: Int
    public let fullRange: NSRange
    public let hiddenRange: NSRange

    public var id: String {
        "\(fullRange.location):\(fullRange.length):\(hiddenRange.location):\(hiddenRange.length)"
    }

    public init(
        startLine: Int,
        endLine: Int,
        fullRange: NSRange,
        hiddenRange: NSRange
    ) {
        precondition(fullRange.location != NSNotFound && fullRange.location >= 0)
        precondition(hiddenRange.location != NSNotFound && hiddenRange.location >= 0)
        precondition(fullRange.length >= 0 && hiddenRange.length >= 0)
        precondition(fullRange.length <= Int.max - fullRange.location)
        precondition(hiddenRange.length <= Int.max - hiddenRange.location)
        precondition(hiddenRange.location >= fullRange.location)
        precondition(NSMaxRange(hiddenRange) <= NSMaxRange(fullRange))
        self.startLine = max(1, startLine)
        self.endLine = max(self.startLine, endLine)
        self.fullRange = fullRange
        self.hiddenRange = hiddenRange
    }

    public func contains(_ utf16Offset: Int) -> Bool {
        utf16Offset >= fullRange.location && utf16Offset < NSMaxRange(fullRange)
    }
}

public struct OutlineDocumentModel: Equatable, Sendable {
    public let symbols: [OutlineSymbol]
    public let foldRegions: [TextFoldRegion]
    public let sourceWasTruncated: Bool
    public let symbolsWereTruncated: Bool
    public let foldsWereTruncated: Bool

    public init(
        symbols: [OutlineSymbol],
        foldRegions: [TextFoldRegion],
        sourceWasTruncated: Bool,
        symbolsWereTruncated: Bool,
        foldsWereTruncated: Bool
    ) {
        self.symbols = symbols
        self.foldRegions = foldRegions
        self.sourceWasTruncated = sourceWasTruncated
        self.symbolsWereTruncated = symbolsWereTruncated
        self.foldsWereTruncated = foldsWereTruncated
    }

    public static let empty = OutlineDocumentModel(
        symbols: [],
        foldRegions: [],
        sourceWasTruncated: false,
        symbolsWereTruncated: false,
        foldsWereTruncated: false
    )
}

public struct TextFoldingState: Equatable, Sendable {
    public private(set) var regions: [TextFoldRegion]
    public private(set) var foldedRegionIDs: Set<String>

    public init(
        regions: [TextFoldRegion] = [],
        foldedRegionIDs: Set<String> = []
    ) {
        self.regions = regions
        let liveIDs = Set(regions.map(\.id))
        self.foldedRegionIDs = foldedRegionIDs.intersection(liveIDs)
    }

    public var foldedRegions: [TextFoldRegion] {
        regions.filter { foldedRegionIDs.contains($0.id) }
    }

    /// Sorted, non-overlapping UTF-16 ranges suitable for a TextKit layout
    /// manager's not-shown glyph attributes. Nested folds remain in state but
    /// are omitted while an ancestor already hides their complete range.
    public var textKitHiddenRanges: [NSRange] {
        let sorted = foldedRegions.sorted { left, right in
            if left.hiddenRange.location != right.hiddenRange.location {
                return left.hiddenRange.location < right.hiddenRange.location
            }
            return left.hiddenRange.length > right.hiddenRange.length
        }
        var result: [NSRange] = []
        for region in sorted {
            let candidate = region.hiddenRange
            guard candidate.length > 0 else { continue }
            if let last = result.last, candidate.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, candidate)
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    public mutating func update(regions: [TextFoldRegion]) {
        self.regions = regions
        foldedRegionIDs.formIntersection(Set(regions.map(\.id)))
    }

    /// Reconciles folds after a new document revision. Exact UTF-16 IDs are
    /// intentionally revision-local, so preserving them alone would unfold
    /// every region after an insertion before the fold. Match the prior fold
    /// to the best structurally equivalent region using its line span and
    /// relative hidden-range shape; folds whose structure disappeared remain
    /// safely unfolded.
    public mutating func reconcile(regions nextRegions: [TextFoldRegion]) {
        let previousFolded = foldedRegions
        regions = nextRegions
        var available = Set(nextRegions.indices)
        var nextIDs: Set<String> = []

        for previous in previousFolded {
            let candidates = available.filter { index in
                let next = nextRegions[index]
                return next.endLine - next.startLine
                        == previous.endLine - previous.startLine
                    && next.hiddenRange.location - next.fullRange.location
                        == previous.hiddenRange.location - previous.fullRange.location
                    && next.hiddenRange.length == previous.hiddenRange.length
            }
            guard let best = candidates.min(by: { left, right in
                let leftRegion = nextRegions[left]
                let rightRegion = nextRegions[right]
                let leftDistance = abs(leftRegion.startLine - previous.startLine)
                let rightDistance = abs(rightRegion.startLine - previous.startLine)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                return abs(leftRegion.fullRange.location - previous.fullRange.location)
                    < abs(rightRegion.fullRange.location - previous.fullRange.location)
            }) else { continue }
            available.remove(best)
            nextIDs.insert(nextRegions[best].id)
        }
        foldedRegionIDs = nextIDs
    }

    @discardableResult
    public mutating func foldCurrent(atUTF16Offset offset: Int) -> Bool {
        guard let region = OutlineFoldingAnalyzer.foldRegion(
            in: regions, atUTF16Offset: offset
        ) else { return false }
        if let ancestor = smallestFoldedRegion(containing: offset),
           ancestor.fullRange.length > region.fullRange.length {
            foldedRegionIDs.remove(ancestor.id)
        }
        guard !foldedRegionIDs.contains(region.id) else { return false }
        foldedRegionIDs.insert(region.id)
        return true
    }

    @discardableResult
    public mutating func unfoldCurrent(atUTF16Offset offset: Int) -> Bool {
        guard let region = smallestFoldedRegion(containing: offset) else { return false }
        foldedRegionIDs.remove(region.id)
        return true
    }

    @discardableResult
    public mutating func foldAll() -> Bool {
        let next = Set(regions.map(\.id))
        guard next != foldedRegionIDs else { return false }
        foldedRegionIDs = next
        return true
    }

    @discardableResult
    public mutating func unfoldAll() -> Bool {
        guard !foldedRegionIDs.isEmpty else { return false }
        foldedRegionIDs.removeAll(keepingCapacity: true)
        return true
    }

    /// Toggles one exact parser-produced region. Gutter markers carry the
    /// region ID so overlapping/nested regions never depend on a later cursor
    /// lookup choosing the same candidate.
    @discardableResult
    public mutating func toggle(regionID: String) -> Bool {
        guard let region = regions.first(where: { $0.id == regionID }) else {
            return false
        }
        if foldedRegionIDs.remove(regionID) != nil { return true }
        if let ancestor = smallestFoldedRegion(containing: region.fullRange.location),
           ancestor.fullRange.length > region.fullRange.length {
            foldedRegionIDs.remove(ancestor.id)
        }
        foldedRegionIDs.insert(regionID)
        return true
    }

    @discardableResult
    public mutating func reveal(atUTF16Offset offset: Int) -> Bool {
        let ids = foldedRegions.compactMap { region in
            offset >= region.hiddenRange.location
                    && offset < NSMaxRange(region.hiddenRange)
                ? region.id : nil
        }
        guard !ids.isEmpty else { return false }
        foldedRegionIDs.subtract(ids)
        return true
    }

    private func smallestFoldedRegion(containing offset: Int) -> TextFoldRegion? {
        foldedRegions
            .filter { $0.contains(offset) }
            .min { left, right in
                if left.fullRange.length != right.fullRange.length {
                    return left.fullRange.length < right.fullRange.length
                }
                return left.fullRange.location > right.fullRange.location
            }
    }
}

public struct TextKitFoldMarker: Identifiable, Equatable, Sendable {
    public let id: String
    public let startLine: Int
    public let endLine: Int
    public let fullRange: NSRange
    public let hiddenRange: NSRange
    public let isFolded: Bool

    public init(region: TextFoldRegion, isFolded: Bool) {
        id = region.id
        startLine = region.startLine
        endLine = region.endLine
        fullRange = region.fullRange
        hiddenRange = region.hiddenRange
        self.isFolded = isFolded
    }
}

public struct TextKitFoldSnapshot: Equatable, Sendable {
    public let documentID: String
    public let viewID: EditorViewID
    public let documentRevision: UInt64
    public let hiddenRanges: [NSRange]
    public let markers: [TextKitFoldMarker]
    public let presentationRevision: UInt64

    public init(
        documentID: String,
        viewID: EditorViewID,
        documentRevision: UInt64,
        hiddenRanges: [NSRange],
        markers: [TextKitFoldMarker] = [],
        presentationRevision: UInt64
    ) {
        self.documentID = documentID
        self.viewID = viewID
        self.documentRevision = documentRevision
        self.hiddenRanges = hiddenRanges
        self.markers = markers
        self.presentationRevision = presentationRevision
    }
}

public enum OutlineFoldingAnalyzer {
    private static let rubyFoldOpeners: Set<String> = [
        "begin", "case", "class", "def", "do", "for",
        "if", "module", "unless", "until", "while"
    ]
    private struct Line {
        let number: Int
        let start: Int
        let contentEnd: Int
        let end: Int
        let text: String
        let indentation: Int
        let isBlank: Bool
    }

    private struct BraceEntry {
        let unit: UInt16
        let lineIndex: Int
    }

    private struct KeywordFoldEntry {
        let lineIndex: Int
    }

    private struct LexicalProfile {
        let lineComments: [[UInt16]]
        let blockComments: [([UInt16], [UInt16])]
    }

    public static func analyze(
        text: String,
        language: String = "Plain Text",
        limits: OutlineLimits = .default
    ) -> OutlineDocumentModel {
        let prefix = boundedPrefix(text, maximumUTF16Count: limits.maximumSourceUTF16Count)
        let sourceWasTruncated = prefix.utf16.count < text.utf16.count
        let lines = makeLines(prefix)

        let extractedSymbols = SymbolExtractor.extract(from: prefix).map { symbol in
            let headingLevel = markdownHeadingLevel(symbol.label)
            return OutlineSymbol(
                label: symbol.label,
                kind: headingLevel == nil ? inferredSymbolKind(symbol.label, line: lines[safe: symbol.line - 1]?.text) : .heading,
                utf16Offset: symbol.position,
                line: symbol.line,
                level: headingLevel.map { max(0, $0 - 1) } ?? indentationLevel(
                    lines[safe: symbol.line - 1]?.indentation ?? 0
                )
            )
        }
        let symbolsWereTruncated = extractedSymbols.count > limits.maximumSymbols
        let symbols = Array(extractedSymbols.prefix(limits.maximumSymbols))

        let candidates: [TextFoldRegion]
        if normalizedLanguage(language).contains("markdown") {
            candidates = markdownFolds(lines, maximumDepth: limits.maximumNestingDepth)
        } else {
            let normalized = normalizedLanguage(language)
            let braces = braceFolds(
                lines,
                language: normalized,
                maximumDepth: limits.maximumNestingDepth
            )
            let indentation = indentationFolds(
                lines,
                language: normalized,
                maximumDepth: limits.maximumNestingDepth
            )
            let keywords = keywordFolds(
                lines,
                language: normalized,
                maximumDepth: limits.maximumNestingDepth
            )
            candidates = normalizedRegions(braces + indentation + keywords)
        }
        let foldsWereTruncated = candidates.count > limits.maximumFoldRegions
        let folds = Array(candidates.prefix(limits.maximumFoldRegions))

        return OutlineDocumentModel(
            symbols: symbols,
            foldRegions: folds,
            sourceWasTruncated: sourceWasTruncated,
            symbolsWereTruncated: symbolsWereTruncated,
            foldsWereTruncated: foldsWereTruncated
        )
    }

    public static func activeSymbol(
        in symbols: [OutlineSymbol],
        atUTF16Offset offset: Int
    ) -> OutlineSymbol? {
        var active: OutlineSymbol?
        for symbol in symbols {
            guard symbol.utf16Offset <= offset else { break }
            active = symbol
        }
        return active
    }

    public static func foldRegion(
        in regions: [TextFoldRegion],
        atUTF16Offset offset: Int
    ) -> TextFoldRegion? {
        regions
            .filter { $0.contains(offset) }
            .min { left, right in
                if left.fullRange.length != right.fullRange.length {
                    return left.fullRange.length < right.fullRange.length
                }
                return left.fullRange.location > right.fullRange.location
            }
    }

    private static func makeLines(_ text: String) -> [Line] {
        let source = text as NSString
        if source.length == 0 {
            return [Line(
                number: 1, start: 0, contentEnd: 0, end: 0, text: "",
                indentation: 0, isBlank: true
            )]
        }
        var result: [Line] = []
        var location = 0
        while location < source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let lineText = source.substring(
                with: NSRange(location: start, length: contentsEnd - start)
            )
            result.append(Line(
                number: result.count + 1,
                start: start,
                contentEnd: contentsEnd,
                end: end,
                text: lineText,
                indentation: indentationWidth(lineText),
                isBlank: lineText.trimmingCharacters(in: .whitespaces).isEmpty
            ))
            guard end > location else { break }
            location = end
        }
        if source.length > 0, result.last?.end == source.length,
           let lastUnit = source.substring(
               with: NSRange(location: source.length - 1, length: 1)
           ).utf16.first, lastUnit == 0x0a || lastUnit == 0x0d {
            result.append(Line(
                number: result.count + 1, start: source.length, contentEnd: source.length,
                end: source.length, text: "", indentation: 0, isBlank: true
            ))
        }
        return result
    }

    private static func braceFolds(
        _ lines: [Line],
        language: String,
        maximumDepth: Int
    ) -> [TextFoldRegion] {
        guard maximumDepth > 0 else { return [] }
        var stack: [BraceEntry] = []
        var ignoredDepth = 0
        var result: [TextFoldRegion] = []
        let profile = lexicalProfile(for: language)
        var state = LexicalState(profile: profile)

        for (lineIndex, line) in lines.enumerated() {
            let units = Array(line.text.utf16)
            var index = 0
            while index < units.count {
                if state.consume(units: units, index: index) {
                    index += max(1, state.consumedCount)
                    continue
                }
                let unit = units[index]
                if unit == 0x7b || unit == 0x5b || unit == 0x28 {
                    if ignoredDepth > 0 {
                        ignoredDepth += 1
                    } else if stack.count < maximumDepth {
                        stack.append(BraceEntry(unit: unit, lineIndex: lineIndex))
                    } else {
                        ignoredDepth = 1
                    }
                } else if let opening = matchingOpening(for: unit) {
                    if ignoredDepth > 0 {
                        ignoredDepth -= 1
                    } else if stack.last?.unit == opening,
                              let entry = stack.popLast() {
                        if lineIndex > entry.lineIndex,
                           let region = region(
                               fromLine: entry.lineIndex, toLine: lineIndex, lines: lines
                           ) {
                            result.append(region)
                        }
                    }
                }
                index += 1
            }
            state.endLine()
        }
        return result
    }

    private static func keywordFolds(
        _ lines: [Line],
        language: String,
        maximumDepth: Int
    ) -> [TextFoldRegion] {
        guard language == "ruby", maximumDepth > 0 else { return [] }

        var result: [TextFoldRegion] = []
        var stack: [KeywordFoldEntry] = []
        var ignoredDepth = 0
        for (lineIndex, line) in lines.enumerated() where !line.isBlank {
            let tokens = codeTokens(in: line.text, language: language)
            guard let first = tokens.first else { continue }
            if first == "end" {
                if ignoredDepth > 0 {
                    ignoredDepth -= 1
                    continue
                }
                guard let entry = stack.popLast() else { continue }
                if lineIndex > entry.lineIndex,
                   let region = region(fromLine: entry.lineIndex, toLine: lineIndex, lines: lines) {
                    result.append(region)
                }
                continue
            }
            if first == "private" || first == "protected" || first == "public" {
                continue
            }
            let opensFold = rubyFoldOpeners.contains(first) || tokens.contains("do")
            guard opensFold else { continue }
            if ignoredDepth > 0 || stack.count >= maximumDepth {
                ignoredDepth += 1
            } else {
                stack.append(KeywordFoldEntry(lineIndex: lineIndex))
            }
        }
        return result
    }

    private static func indentationFolds(
        _ lines: [Line],
        language: String,
        maximumDepth: Int
    ) -> [TextFoldRegion] {
        let supportsIndentation = [
            "python", "yaml", "nim", "haskell", "coffee", "sass", "stylus"
        ].contains { language.contains($0) }
        guard supportsIndentation, maximumDepth > 0 else { return [] }

        var result: [TextFoldRegion] = []
        var stack: [(lineIndex: Int, indentation: Int)] = []
        var previousNonBlank: Int?
        for index in lines.indices where !lines[index].isBlank {
            while let top = stack.last, lines[index].indentation <= top.indentation {
                stack.removeLast()
                if let end = previousNonBlank,
                   let region = region(fromLine: top.lineIndex, toLine: end, lines: lines) {
                    result.append(region)
                }
            }
            if let previousNonBlank,
               lines[index].indentation > lines[previousNonBlank].indentation,
               stack.count < maximumDepth {
                stack.append((
                    lineIndex: previousNonBlank,
                    indentation: lines[previousNonBlank].indentation
                ))
            }
            previousNonBlank = index
        }
        if let end = previousNonBlank {
            while let top = stack.popLast() {
                if let region = region(fromLine: top.lineIndex, toLine: end, lines: lines) {
                    result.append(region)
                }
            }
        }
        return normalizedRegions(result)
    }

    private static func markdownFolds(
        _ lines: [Line],
        maximumDepth: Int
    ) -> [TextFoldRegion] {
        guard maximumDepth > 0 else { return [] }
        var headings: [(level: Int, lineIndex: Int)] = []
        for (index, line) in lines.enumerated() {
            if let level = markdownHeadingLevel(line.text) {
                headings.append((min(level, maximumDepth), index))
            }
        }
        var result: [TextFoldRegion] = []
        var stack: [(level: Int, lineIndex: Int)] = []
        for heading in headings {
            while let previous = stack.last, heading.level <= previous.level {
                stack.removeLast()
                var end = heading.lineIndex - 1
                while end > previous.lineIndex, lines[end].isBlank { end -= 1 }
                if let region = region(
                    fromLine: previous.lineIndex, toLine: end, lines: lines
                ) {
                    result.append(region)
                }
            }
            stack.append(heading)
        }
        while let heading = stack.popLast() {
            var end = lines.count - 1
            while end > heading.lineIndex, lines[end].isBlank { end -= 1 }
            if let region = region(
                fromLine: heading.lineIndex, toLine: end, lines: lines
            ) {
                result.append(region)
            }
        }
        return normalizedRegions(result)
    }

    private static func region(
        fromLine startIndex: Int,
        toLine endIndex: Int,
        lines: [Line]
    ) -> TextFoldRegion? {
        guard lines.indices.contains(startIndex), lines.indices.contains(endIndex),
              endIndex > startIndex else { return nil }
        let start = lines[startIndex]
        let end = lines[endIndex]
        let hiddenStart = start.end
        let fullEnd = end.end
        guard hiddenStart < fullEnd else { return nil }
        return TextFoldRegion(
            startLine: start.number,
            endLine: end.number,
            fullRange: NSRange(location: start.start, length: fullEnd - start.start),
            hiddenRange: NSRange(location: hiddenStart, length: fullEnd - hiddenStart)
        )
    }

    private static func normalizedRegions(_ regions: [TextFoldRegion]) -> [TextFoldRegion] {
        var seen = Set<String>()
        return regions.sorted { left, right in
            if left.fullRange.location != right.fullRange.location {
                return left.fullRange.location < right.fullRange.location
            }
            return left.fullRange.length > right.fullRange.length
        }.filter { seen.insert($0.id).inserted }
    }

    private static func boundedPrefix(_ text: String, maximumUTF16Count: Int) -> String {
        guard text.utf16.count > maximumUTF16Count else { return text }
        let units = Array(text.utf16.prefix(maximumUTF16Count))
        var count = units.count
        if count > 0, (0xD800...0xDBFF).contains(units[count - 1]) { count -= 1 }
        return String(decoding: units.prefix(count), as: UTF16.self)
    }

    private static func indentationWidth(_ line: String) -> Int {
        var width = 0
        for unit in line.utf16 {
            if unit == 0x20 { width += 1 }
            else if unit == 0x09 { width += 4 }
            else { break }
        }
        return width
    }

    private static func indentationLevel(_ width: Int) -> Int {
        width == 0 ? 0 : min(32, max(1, width / 2))
    }

    private static func markdownHeadingLevel(_ label: String) -> Int? {
        let units = Array(label.utf16)
        var count = 0
        while count < units.count, units[count] == 0x23 { count += 1 }
        return count > 0 && count <= 6 && count < units.count && units[count] == 0x20
            ? count : nil
    }

    private static func inferredSymbolKind(_ label: String, line: String?) -> OutlineSymbolKind {
        guard let line else { return .function }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^(?:export\s+)?(?:abstract\s+)?class\s+"#, options: .regularExpression) != nil
            || trimmed.hasPrefix("struct ") || trimmed.hasPrefix("enum ") {
            return .type
        }
        if trimmed.range(of: #"^(?:const|let|var)\s+"#, options: .regularExpression) != nil {
            return .variable
        }
        if trimmed.hasPrefix("func ") || trimmed.hasPrefix("function ")
            || trimmed.hasPrefix("def ") || trimmed.hasPrefix("fn ") {
            return .function
        }
        return label.isEmpty ? .variable : .method
    }

    private static func normalizedLanguage(_ language: String) -> String {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matchingOpening(for closing: UInt16) -> UInt16? {
        switch closing {
        case 0x7d: 0x7b
        case 0x5d: 0x5b
        case 0x29: 0x28
        default: nil
        }
    }

    private struct LexicalState {
        let profile: LexicalProfile
        var quote: UInt16?
        var escaped = false
        var blockCommentEnd: [UInt16]?
        var lineCommentMarker: [UInt16]?
        var consumedCount = 0

        mutating func consume(units: [UInt16], index: Int) -> Bool {
            consumedCount = 0
            if lineCommentMarker != nil {
                consumedCount = 1
                return true
            }
            if let blockCommentEnd {
                if matches(blockCommentEnd, units: units, index: index) {
                    self.blockCommentEnd = nil
                    consumedCount = blockCommentEnd.count
                } else {
                    consumedCount = 1
                }
                return true
            }
            if let quote {
                if escaped { escaped = false }
                else if units[index] == 0x5c { escaped = true }
                else if units[index] == quote { self.quote = nil }
                consumedCount = 1
                return true
            }
            if let marker = profile.lineComments.first(where: {
                matches($0, units: units, index: index)
            }) {
                lineCommentMarker = marker
                consumedCount = marker.count
                return true
            }
            if let pair = profile.blockComments.first(where: {
                matches($0.0, units: units, index: index)
            }) {
                blockCommentEnd = pair.1
                consumedCount = pair.0.count
                return true
            }
            let unit = units[index]
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

    private static func lexicalProfile(for language: String) -> LexicalProfile {
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

    private static func codeTokens(in line: String, language: String) -> [String] {
        let units = Array(line.utf16)
        let profile = lexicalProfile(for: language)
        var state = LexicalState(profile: profile)
        var tokens: [String] = []
        var index = 0
        while index < units.count {
            if state.consume(units: units, index: index) {
                index += max(1, state.consumedCount)
                continue
            }
            if isIdentifierStart(units[index]) {
                let start = index
                index += 1
                while index < units.count, isIdentifier(units[index]) { index += 1 }
                tokens.append(String(decoding: units[start..<index], as: UTF16.self).lowercased())
            } else {
                index += 1
            }
        }
        return tokens
    }

    private static func matches(_ marker: [UInt16], units: [UInt16], index: Int) -> Bool {
        guard !marker.isEmpty, index >= 0, marker.count <= units.count - index else { return false }
        for offset in marker.indices where units[index + offset] != marker[offset] {
            return false
        }
        return true
    }

    private static func units(_ text: String) -> [UInt16] { Array(text.utf16) }

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        unit == 0x5F || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isIdentifier(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || (0x30...0x39).contains(unit)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
