@preconcurrency import Foundation

/// Pure UTF-16 analysis used by the TextKit 1 visual-decoration layer.
///
/// Viewport decoration callers supply the character range represented by the
/// glyphs TextKit is currently drawing. Diagnostic mapping necessarily indexes
/// physical lines in its already-bounded snapshot, while the hot drawing path
/// remains limited to the current glyph range.
enum NativeTextEditorVisualPlanner {
    enum DiagnosticSeverity: Int, Equatable, Sendable {
        case information
        case warning
        case error
    }

    struct Diagnostic: Equatable, Sendable {
        let line: Int
        let column: Int
        let endLine: Int?
        let endColumn: Int?
        let severity: DiagnosticSeverity

        init(
            line: Int, column: Int, endLine: Int? = nil, endColumn: Int? = nil,
            severity: DiagnosticSeverity
        ) {
            self.line = line
            self.column = column
            self.endLine = endLine
            self.endColumn = endColumn
            self.severity = severity
        }
    }

    struct DiagnosticMark: Equatable, Sendable {
        let range: NSRange
        let line: Int
        let severity: DiagnosticSeverity
    }

    struct DiagnosticPlan: Equatable, Sendable {
        let marks: [DiagnosticMark]
        let markedLines: [Int: DiagnosticSeverity]
    }

    struct FindHighlight: Equatable, Sendable {
        let range: NSRange
        let isCurrent: Bool
    }

    struct FindHighlightPlan: Equatable, Sendable {
        let highlights: [FindHighlight]
    }

    struct FoldMarker: Equatable, Sendable {
        let id: String
        let startLine: Int
        let endLine: Int
        let fullRange: NSRange
        let hiddenRange: NSRange
        let isFolded: Bool
    }

    struct FoldMarkerPlan: Equatable, Sendable {
        let markers: [FoldMarker]
        let markerByStartLine: [Int: FoldMarker]
    }

    /// A direction-preserving UTF-16 selection snapshot. Keeping this tiny
    /// value in the presentation layer lets the planner remain independent of
    /// AppKit and of mutable editor/document state.
    struct VisualSelection: Equatable {
        let anchor: Int
        let head: Int

        init(anchor: Int, head: Int) {
            self.anchor = anchor
            self.head = head
        }

        var range: NSRange {
            NSRange(location: min(anchor, head), length: abs(head - anchor))
        }

        var isEmpty: Bool { anchor == head }
    }

    /// Selection-derived decorations. Every non-empty returned range is fully
    /// contained in `visibleCharacterRange`; matching never scans beyond that
    /// range (apart from the bounded selected word itself).
    struct DecorationPlan: Equatable {
        let visibleCharacterRange: NSRange
        let currentLineRange: NSRange?
        let selectedWordRange: NSRange?
        let selectedWordMatchRanges: [NSRange]
        let selectionMatchesWereTruncated: Bool
        let matchingBracketRanges: [NSRange]
    }

    static let maximumSelectedWordUTF16Length = 256
    static let maximumSelectionMatches = 512
    static let maximumBracketScanUTF16Length = 20_000
    static let maximumDiagnosticMarks = 1_000
    static let maximumFindHighlights = 10_000
    static let maximumFoldMarkers = 10_000

    /// Filters a controller-produced match snapshot down to exact, drawable
    /// UTF-16 ranges. Search semantics remain owned by FindCore; the visual
    /// planner never re-runs or approximates regex/case/whole-word matching.
    static func findHighlightPlan(
        text: String,
        matches: [NSRange],
        selectedMatchIndex: Int?,
        maximumHighlights requestedMaximum: Int = maximumFindHighlights
    ) -> FindHighlightPlan {
        let length = (text as NSString).length
        let maximum = min(max(0, requestedMaximum), maximumFindHighlights)
        guard maximum > 0 else { return FindHighlightPlan(highlights: []) }
        var highlights: [FindHighlight] = []
        highlights.reserveCapacity(min(matches.count, maximum))
        for (index, range) in matches.enumerated() {
            guard highlights.count < maximum, range.location != NSNotFound,
                  range.location >= 0, range.length >= 0,
                  range.location <= length,
                  range.length <= length - range.location else {
                continue
            }
            highlights.append(FindHighlight(
                range: range, isCurrent: index == selectedMatchIndex
            ))
        }
        return FindHighlightPlan(highlights: highlights)
    }

    /// Normalizes exact parser fold regions for the line-number ruler. Folded
    /// regions take precedence on a shared start line; otherwise the smallest
    /// region is the marker a user can act on.
    static func foldMarkerPlan(
        text: String,
        markers: [FoldMarker],
        maximumMarkers requestedMaximum: Int = maximumFoldMarkers
    ) -> FoldMarkerPlan {
        let length = (text as NSString).length
        let maximum = min(max(0, requestedMaximum), maximumFoldMarkers)
        guard maximum > 0 else {
            return FoldMarkerPlan(markers: [], markerByStartLine: [:])
        }
        var accepted: [FoldMarker] = []
        accepted.reserveCapacity(min(markers.count, maximum))
        for marker in markers {
            guard accepted.count < maximum, marker.startLine > 0,
                  marker.endLine > marker.startLine,
                  valid(marker.fullRange, inUTF16Length: length),
                  valid(marker.hiddenRange, inUTF16Length: length),
                  marker.hiddenRange.location >= marker.fullRange.location,
                  NSMaxRange(marker.hiddenRange) <= NSMaxRange(marker.fullRange),
                  marker.hiddenRange.length > 0 else { continue }
            accepted.append(marker)
        }
        accepted.sort { left, right in
            if left.startLine != right.startLine { return left.startLine < right.startLine }
            if left.fullRange.length != right.fullRange.length {
                return left.fullRange.length < right.fullRange.length
            }
            return left.id < right.id
        }
        return FoldMarkerPlan(
            markers: accepted, markerByStartLine: markerByStartLine(for: accepted)
        )
    }

    /// Selects only actionable marker headers. A folded ancestor suppresses
    /// every descendant whose header lies inside its exact hidden UTF-16 range.
    static func markerByStartLine(for markers: [FoldMarker]) -> [Int: FoldMarker] {
        // Sweep marker headers through the folded-range start/end boundaries.
        // Tracking active ranges by marker ID preserves the self-exclusion
        // rule without comparing every candidate against every folded range.
        let foldedByStart = markers.filter(\.isFolded).sorted { left, right in
            left.hiddenRange.location < right.hiddenRange.location
        }
        let foldedByEnd = foldedByStart.sorted { left, right in
            NSMaxRange(left.hiddenRange) < NSMaxRange(right.hiddenRange)
        }
        let candidates = markers.sorted { left, right in
            left.fullRange.location < right.fullRange.location
        }

        var nextStart = 0
        var nextEnd = 0
        var activeFoldedCount = 0
        var activeFoldedCountByID: [String: Int] = [:]
        var byLine: [Int: FoldMarker] = [:]

        for candidate in candidates {
            let headerLocation = candidate.fullRange.location
            while nextStart < foldedByStart.count,
                  foldedByStart[nextStart].hiddenRange.location <= headerLocation {
                let id = foldedByStart[nextStart].id
                activeFoldedCount += 1
                activeFoldedCountByID[id, default: 0] += 1
                nextStart += 1
            }
            // End boundaries are removed at equality because hidden ranges are
            // half-open. Starts are added first so every interval that could
            // contain this header has an entry before expired ones are removed.
            while nextEnd < foldedByEnd.count,
                  NSMaxRange(foldedByEnd[nextEnd].hiddenRange) <= headerLocation {
                let id = foldedByEnd[nextEnd].id
                activeFoldedCount -= 1
                if activeFoldedCountByID[id] == 1 {
                    activeFoldedCountByID.removeValue(forKey: id)
                } else {
                    activeFoldedCountByID[id, default: 0] -= 1
                }
                nextEnd += 1
            }

            // Only ranges belonging to this candidate's own ID may cover its
            // header. Any other active folded range makes it non-actionable.
            guard activeFoldedCount == activeFoldedCountByID[candidate.id, default: 0]
            else { continue }

            guard let existing = byLine[candidate.startLine] else {
                byLine[candidate.startLine] = candidate
                continue
            }
            // A folded ancestor is the effective visible state when nested
            // regions begin on the same physical line. Otherwise expose the
            // smallest region, consistent with fold-current selection. IDs
            // make equal-length selection independent of input order.
            if candidate.isFolded != existing.isFolded {
                if candidate.isFolded { byLine[candidate.startLine] = candidate }
            } else if candidate.fullRange.length != existing.fullRange.length {
                let preferCandidate = candidate.isFolded
                    ? candidate.fullRange.length > existing.fullRange.length
                    : candidate.fullRange.length < existing.fullRange.length
                if preferCandidate { byLine[candidate.startLine] = candidate }
            } else if candidate.id < existing.id {
                byLine[candidate.startLine] = candidate
            }
        }
        return byLine
    }

    /// Converts LSP's one-based UTF-16 line/column pairs into drawable ranges.
    /// Invalid positions are skipped rather than clamped onto unrelated text.
    /// Empty ranges receive one composed character where possible, or the final
    /// UTF-16 code unit on an otherwise empty physical line.
    static func diagnosticPlan(
        text: String, diagnostics: [Diagnostic],
        maximumMarks requestedMaximum: Int = maximumDiagnosticMarks
    ) -> DiagnosticPlan {
        let string = text as NSString
        let maximum = min(max(0, requestedMaximum), maximumDiagnosticMarks)
        guard maximum > 0 else {
            return DiagnosticPlan(marks: [], markedLines: [:])
        }
        let lines = physicalLineRanges(in: string)
        var marks: [DiagnosticMark] = []
        marks.reserveCapacity(min(diagnostics.count, maximum))
        var markedLines: [Int: DiagnosticSeverity] = [:]

        for diagnostic in diagnostics {
            guard marks.count < maximum else { break }
            guard let range = diagnosticRange(
                diagnostic, in: string, physicalLines: lines
            ) else { continue }
            let mark = DiagnosticMark(
                range: range, line: diagnostic.line, severity: diagnostic.severity
            )
            marks.append(mark)
            if let existing = markedLines[diagnostic.line] {
                markedLines[diagnostic.line] = existing.rawValue >= diagnostic.severity.rawValue
                    ? existing : diagnostic.severity
            } else {
                markedLines[diagnostic.line] = diagnostic.severity
            }
        }
        return DiagnosticPlan(marks: marks, markedLines: markedLines)
    }

    enum WhitespaceKind: Equatable {
        case space
        case tab
    }

    struct WhitespaceMarker: Equatable {
        let location: Int
        let kind: WhitespaceKind
    }

    struct Line: Equatable {
        /// Visible line contents without its line terminator.
        let contentsRange: NSRange
        /// The portion of `contentsRange` represented by the visible glyphs.
        let visibleContentsRange: NSRange
        /// Leading indentation measured in display columns.
        let indentationColumns: Int
        /// The visible portion of the trailing ASCII space/tab run.
        let trailingWhitespaceRange: NSRange?
    }

    struct Plan: Equatable {
        let visibleCharacterRange: NSRange
        let lines: [Line]
        let whitespaceMarkers: [WhitespaceMarker]
    }

    /// Plans visual-only editor affordances from immutable UTF-16 coordinates.
    /// The document is never copied into a UTF-16 array and occurrence/bracket
    /// scans are constrained to the supplied viewport.
    static func decorationPlan(
        text: String,
        visibleCharacterRange requestedRange: NSRange,
        selection requestedSelection: VisualSelection?,
        maximumSelectionMatches requestedMaximumMatches: Int = maximumSelectionMatches,
        maximumBracketScanUTF16Length requestedBracketLimit: Int = maximumBracketScanUTF16Length
    ) -> DecorationPlan {
        let string = text as NSString
        let visibleRange = clamped(requestedRange, to: string.length)
        let selection = requestedSelection.map { clamped($0, to: string.length) }
        guard visibleRange.length > 0 else {
            return DecorationPlan(
                visibleCharacterRange: visibleRange, currentLineRange: nil,
                selectedWordRange: nil, selectedWordMatchRanges: [],
                selectionMatchesWereTruncated: false, matchingBracketRanges: []
            )
        }

        let currentLineRange = selection.flatMap { selection in
            visibleCurrentLineRange(
                in: string, at: selection.head, visibleRange: visibleRange
            )
        }
        let selectedWord: NSRange? = selection.flatMap { selection in
            Self.selectedWordRange(
                in: string, selection: selection
            )
        }
        let matches = selectedWord.map { selectedWordRange in
            visibleSelectionMatches(
                in: string, selectedWordRange: selectedWordRange,
                visibleRange: visibleRange,
                maximumMatches: max(0, requestedMaximumMatches)
            )
        } ?? (ranges: [], wasTruncated: false)
        let brackets = selection.flatMap { selection in
            visibleMatchingBracketRanges(
                in: string, selection: selection, visibleRange: visibleRange,
                maximumScanLength: max(0, requestedBracketLimit)
            )
        } ?? []

        return DecorationPlan(
            visibleCharacterRange: visibleRange,
            currentLineRange: currentLineRange,
            selectedWordRange: selectedWord,
            selectedWordMatchRanges: matches.ranges,
            selectionMatchesWereTruncated: matches.wasTruncated,
            matchingBracketRanges: brackets
        )
    }

    static func plan(
        text: String,
        visibleCharacterRange requestedRange: NSRange,
        tabWidth requestedTabWidth: Int,
        includeWhitespaceMarkers: Bool = true,
        includeIndentation: Bool = true,
        includeTrailingWhitespace: Bool = true
    ) -> Plan {
        let string = text as NSString
        let visibleRange = clamped(requestedRange, to: string.length)
        guard string.length > 0, visibleRange.length > 0 else {
            return Plan(
                visibleCharacterRange: visibleRange,
                lines: [],
                whitespaceMarkers: []
            )
        }

        let tabWidth = min(16, max(1, requestedTabWidth))
        let visibleEnd = NSMaxRange(visibleRange)

        var lines: [Line] = []
        var markers: [WhitespaceMarker] = []
        // TextKit normally starts a glyph draw range on a fragment boundary.
        // Starting at the requested location keeps work strictly bounded even
        // for a pathological multi-megabyte physical line.
        var lineStart = visibleRange.location

        while lineStart < string.length, lineStart < visibleEnd {
            var discoveredStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(
                &discoveredStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )
            guard lineEnd > lineStart else { break }

            let fullContentsRange = NSRange(
                location: discoveredStart,
                length: contentsEnd - discoveredStart
            )
            let visibleContentsRange = NSIntersectionRange(fullContentsRange, visibleRange)
            // Do not walk horizontally offscreen prefixes/suffixes. If a
            // physical edge is not represented by the visible glyph range,
            // its decoration cannot be visible either.
            let includesLineStart = visibleContentsRange.location == fullContentsRange.location
            let includesLineEnd = NSMaxRange(visibleContentsRange) == NSMaxRange(fullContentsRange)
            let indentationColumns = includeIndentation && includesLineStart
                ? leadingIndentationColumns(
                    in: string,
                    contentsRange: visibleContentsRange,
                    tabWidth: tabWidth
                )
                : 0
            let trailingRange = includeTrailingWhitespace && includesLineEnd
                ? visibleTrailingWhitespaceRange(
                    in: string,
                    contentsRange: visibleContentsRange,
                    visibleContentsRange: visibleContentsRange
                )
                : nil

            if includeWhitespaceMarkers, visibleContentsRange.length > 0 {
                let markerEnd = NSMaxRange(visibleContentsRange)
                for location in visibleContentsRange.location..<markerEnd {
                    switch string.character(at: location) {
                    case 0x20:
                        markers.append(WhitespaceMarker(location: location, kind: .space))
                    case 0x09:
                        markers.append(WhitespaceMarker(location: location, kind: .tab))
                    default:
                        break
                    }
                }
            }

            lines.append(Line(
                contentsRange: visibleContentsRange,
                visibleContentsRange: visibleContentsRange,
                indentationColumns: indentationColumns,
                trailingWhitespaceRange: trailingRange
            ))
            lineStart = lineEnd
        }

        if visibleEnd == string.length, endsInLineTerminator(string) {
            lines.append(Line(
                contentsRange: NSRange(location: string.length, length: 0),
                visibleContentsRange: NSRange(location: string.length, length: 0),
                indentationColumns: 0,
                trailingWhitespaceRange: nil
            ))
        }

        return Plan(
            visibleCharacterRange: visibleRange,
            lines: lines,
            whitespaceMarkers: markers
        )
    }

    private static func physicalLineRanges(in string: NSString) -> [NSRange] {
        guard string.length > 0 else {
            return [NSRange(location: 0, length: 0)]
        }
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(
                &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            guard lineEnd > location else { break }
            ranges.append(NSRange(location: lineStart, length: contentsEnd - lineStart))
            location = lineEnd
        }
        if diagnosticEndsInLineTerminator(string) {
            ranges.append(NSRange(location: string.length, length: 0))
        }
        return ranges
    }

    private static func diagnosticEndsInLineTerminator(_ string: NSString) -> Bool {
        guard string.length > 0 else { return false }
        switch string.character(at: string.length - 1) {
        case 0x0A, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private static func diagnosticRange(
        _ diagnostic: Diagnostic, in string: NSString, physicalLines: [NSRange]
    ) -> NSRange? {
        guard diagnostic.line > 0, diagnostic.column > 0,
              physicalLines.indices.contains(diagnostic.line - 1) else { return nil }
        let startLine = physicalLines[diagnostic.line - 1]
        let startColumn = diagnostic.column - 1
        guard startColumn <= startLine.length else { return nil }
        let start = startLine.location + startColumn
        guard (diagnostic.endLine == nil) == (diagnostic.endColumn == nil) else {
            return nil
        }

        let requestedEnd: Int
        if let endLine = diagnostic.endLine, let endColumn = diagnostic.endColumn {
            guard endLine > 0, endColumn > 0, endLine >= diagnostic.line,
                  physicalLines.indices.contains(endLine - 1) else { return nil }
            let targetLine = physicalLines[endLine - 1]
            let targetColumn = endColumn - 1
            guard targetColumn <= targetLine.length else { return nil }
            requestedEnd = targetLine.location + targetColumn
            guard requestedEnd >= start else { return nil }
        } else {
            requestedEnd = start
        }

        if requestedEnd > start {
            let requested = NSRange(location: start, length: requestedEnd - start)
            let composed = string.rangeOfComposedCharacterSequences(for: requested)
            guard composed.location >= 0, NSMaxRange(composed) <= string.length else {
                return nil
            }
            return composed
        }
        if start < NSMaxRange(startLine) {
            return string.rangeOfComposedCharacterSequence(at: start)
        }
        // A zero-length diagnostic at end-of-line has no glyph of its own.
        // Underline the closest drawable composed character on that line.
        if startLine.length > 0 {
            return string.rangeOfComposedCharacterSequence(at: NSMaxRange(startLine) - 1)
        }
        return NSRange(location: start, length: 0)
    }

    private static func leadingIndentationColumns(
        in string: NSString,
        contentsRange: NSRange,
        tabWidth: Int
    ) -> Int {
        var columns = 0
        var location = contentsRange.location
        let end = NSMaxRange(contentsRange)
        while location < end {
            switch string.character(at: location) {
            case 0x20:
                columns += 1
            case 0x09:
                columns += tabWidth - columns % tabWidth
            default:
                return columns
            }
            location += 1
        }
        return columns
    }

    private static func visibleTrailingWhitespaceRange(
        in string: NSString,
        contentsRange: NSRange,
        visibleContentsRange: NSRange
    ) -> NSRange? {
        guard contentsRange.length > 0, visibleContentsRange.length > 0 else { return nil }
        var start = NSMaxRange(contentsRange)
        while start > contentsRange.location {
            let unit = string.character(at: start - 1)
            guard unit == 0x20 || unit == 0x09 else { break }
            start -= 1
        }
        guard start < NSMaxRange(contentsRange) else { return nil }

        let visibleTrailingRange = NSIntersectionRange(
            NSRange(location: start, length: NSMaxRange(contentsRange) - start),
            visibleContentsRange
        )
        return visibleTrailingRange.length > 0 ? visibleTrailingRange : nil
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(length, max(0, range.location))
        let rangeLength = min(max(0, range.length), length - location)
        return NSRange(location: location, length: rangeLength)
    }

    private static func valid(_ range: NSRange, inUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private static func clamped(
        _ selection: VisualSelection, to length: Int
    ) -> VisualSelection {
        VisualSelection(
            anchor: min(length, max(0, selection.anchor)),
            head: min(length, max(0, selection.head))
        )
    }

    private static func visibleCurrentLineRange(
        in string: NSString,
        at requestedPosition: Int,
        visibleRange: NSRange
    ) -> NSRange? {
        guard isVisible(requestedPosition, in: visibleRange, documentLength: string.length)
        else { return nil }

        // Never walk outside the visible slice. A clipped range is sufficient
        // for TextKit to recover and paint the visible line fragments.
        let visibleEnd = NSMaxRange(visibleRange)
        var start = min(max(visibleRange.location, requestedPosition), visibleEnd)
        while start > visibleRange.location,
              !isLineTerminator(string.character(at: start - 1)) {
            start -= 1
        }
        var end = min(max(start, requestedPosition), visibleEnd)
        while end < visibleEnd, !isLineTerminator(string.character(at: end)) {
            end += 1
        }
        if end < visibleEnd { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func selectedWordRange(
        in string: NSString,
        selection: VisualSelection
    ) -> NSRange? {
        let range = selection.range
        guard range.length > 0, range.length <= maximumSelectedWordUTF16Length,
              NSMaxRange(range) <= string.length,
              NSEqualRanges(
                  string.rangeOfComposedCharacterSequences(for: range), range
              ) else { return nil }

        let selected = string.substring(with: range)
        guard !selected.isEmpty, selected.unicodeScalars.allSatisfy(isWordScalar) else {
            return nil
        }
        guard !wordClusterBefore(range.location, in: string),
              !wordCluster(at: NSMaxRange(range), in: string) else { return nil }
        return range
    }

    private static func visibleSelectionMatches(
        in string: NSString,
        selectedWordRange: NSRange,
        visibleRange: NSRange,
        maximumMatches: Int
    ) -> (ranges: [NSRange], wasTruncated: Bool) {
        guard visibleRange.length > 0 else { return ([], false) }
        let needle = string.substring(with: selectedWordRange)
        var ranges: [NSRange] = []
        ranges.reserveCapacity(min(16, maximumMatches))
        var cursor = visibleRange.location
        let visibleEnd = NSMaxRange(visibleRange)

        while cursor < visibleEnd {
            let searchRange = NSRange(location: cursor, length: visibleEnd - cursor)
            let match = string.range(of: needle, options: [.literal], range: searchRange)
            guard match.location != NSNotFound, match.length > 0 else { break }
            cursor = NSMaxRange(match)
            guard !NSEqualRanges(match, selectedWordRange),
                  !wordClusterBefore(match.location, in: string),
                  !wordCluster(at: NSMaxRange(match), in: string) else { continue }
            guard ranges.count < maximumMatches else { return (ranges, true) }
            ranges.append(match)
        }
        return (ranges, false)
    }

    private static func visibleMatchingBracketRanges(
        in string: NSString,
        selection: VisualSelection,
        visibleRange: NSRange,
        maximumScanLength: Int
    ) -> [NSRange] {
        guard selection.isEmpty, visibleRange.length > 0, maximumScanLength > 0 else {
            return []
        }
        var seen = Set<Int>()
        for candidate in [selection.head, selection.head - 1, selection.head + 1]
        where candidate >= visibleRange.location
                && candidate < NSMaxRange(visibleRange)
                && candidate >= 0
                && candidate < string.length
                && seen.insert(candidate).inserted {
            guard let match = matchingBracket(
                in: string, at: candidate, visibleRange: visibleRange,
                maximumScanLength: maximumScanLength
            ) else { continue }
            return [
                NSRange(location: candidate, length: 1),
                NSRange(location: match, length: 1)
            ]
        }
        return []
    }

    private static func matchingBracket(
        in string: NSString,
        at position: Int,
        visibleRange: NSRange,
        maximumScanLength: Int
    ) -> Int? {
        let unit = string.character(at: position)
        let opening = matchingClosing(for: unit) != nil
        guard opening || matchingOpening(for: unit) != nil,
              isCodePosition(in: string, at: position, lowerBound: visibleRange.location)
        else { return nil }

        if opening {
            let upper = min(
                NSMaxRange(visibleRange),
                position + 1 + maximumScanLength
            )
            guard position + 1 < upper else { return nil }
            var quote: UInt16?
            var escaped = false
            var lineComment = false
            var blockComment = false
            var stack: [(unit: UInt16, position: Int)] = [(unit, position)]
            for index in (position + 1)..<upper {
                let candidate = string.character(at: index)
                let next = index + 1 < upper ? string.character(at: index + 1) : 0
                if lineComment {
                    if isLineTerminator(candidate) { lineComment = false }
                    continue
                }
                if blockComment {
                    if candidate == 0x2A, next == 0x2F { blockComment = false }
                    continue
                }
                if let activeQuote = quote {
                    if escaped { escaped = false; continue }
                    if candidate == 0x5C { escaped = true; continue }
                    if candidate == activeQuote { quote = nil }
                    continue
                }
                if candidate == 0x2F, next == 0x2F { lineComment = true; continue }
                if candidate == 0x2F, next == 0x2A { blockComment = true; continue }
                if candidate == 0x22 || candidate == 0x27 || candidate == 0x60 {
                    quote = candidate
                    continue
                }
                if matchingClosing(for: candidate) != nil {
                    stack.append((candidate, index))
                } else if let expected = matchingOpening(for: candidate) {
                    guard stack.last?.unit == expected else {
                        stack.removeAll(keepingCapacity: true)
                        continue
                    }
                    stack.removeLast()
                    if stack.isEmpty { return index }
                }
            }
        } else {
            let lower = max(visibleRange.location, position - maximumScanLength)
            guard position > lower else { return nil }
            // Forward-scan the bounded slice so string/comment skipping has the
            // same deterministic state machine as opening-bracket matching.
            var pairs: [(unit: UInt16, position: Int)] = []
            var quote: UInt16?
            var escaped = false
            var lineComment = false
            var blockComment = false
            for index in lower...position {
                let candidate = string.character(at: index)
                let next = index + 1 <= position ? string.character(at: index + 1) : 0
                if lineComment {
                    if isLineTerminator(candidate) { lineComment = false }
                    continue
                }
                if blockComment {
                    if candidate == 0x2A, next == 0x2F { blockComment = false }
                    continue
                }
                if let activeQuote = quote {
                    if escaped { escaped = false; continue }
                    if candidate == 0x5C { escaped = true; continue }
                    if candidate == activeQuote { quote = nil }
                    continue
                }
                if candidate == 0x2F, next == 0x2F { lineComment = true; continue }
                if candidate == 0x2F, next == 0x2A { blockComment = true; continue }
                if candidate == 0x22 || candidate == 0x27 || candidate == 0x60 {
                    quote = candidate
                    continue
                }
                if matchingClosing(for: candidate) != nil {
                    pairs.append((candidate, index))
                } else if let expected = matchingOpening(for: candidate),
                          pairs.last?.unit == expected {
                    let openingPosition = pairs.removeLast().position
                    if index == position { return openingPosition }
                } else if matchingOpening(for: candidate) != nil {
                    pairs.removeAll(keepingCapacity: true)
                }
            }
        }
        return nil
    }

    private static func matchingClosing(for opening: UInt16) -> UInt16? {
        switch opening {
        case 0x28: return 0x29
        case 0x5B: return 0x5D
        case 0x7B: return 0x7D
        default: return nil
        }
    }

    private static func matchingOpening(for closing: UInt16) -> UInt16? {
        switch closing {
        case 0x29: return 0x28
        case 0x5D: return 0x5B
        case 0x7D: return 0x7B
        default: return nil
        }
    }

    private static func isCodePosition(
        in string: NSString, at position: Int, lowerBound: Int
    ) -> Bool {
        guard position >= lowerBound else { return false }
        var quote: UInt16?
        var escaped = false
        var lineComment = false
        var blockComment = false
        var index = lowerBound
        while index < position {
            let unit = string.character(at: index)
            let next = index + 1 <= position ? string.character(at: index + 1) : 0
            if lineComment {
                if isLineTerminator(unit) { lineComment = false }
                index += 1
                continue
            }
            if blockComment {
                if unit == 0x2A, next == 0x2F {
                    blockComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if unit == 0x5C { escaped = true }
                else if unit == activeQuote { quote = nil }
                index += 1
                continue
            }
            if unit == 0x2F, next == 0x2F {
                lineComment = true
                index += 2
            } else if unit == 0x2F, next == 0x2A {
                blockComment = true
                index += 2
            } else if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                quote = unit
                index += 1
            } else {
                index += 1
            }
        }
        return quote == nil && !lineComment && !blockComment
    }

    private static func wordClusterBefore(_ location: Int, in string: NSString) -> Bool {
        guard location > 0 else { return false }
        let range = string.rangeOfComposedCharacterSequence(at: location - 1)
        return isWordCluster(string.substring(with: range))
    }

    private static func wordCluster(at location: Int, in string: NSString) -> Bool {
        guard location >= 0, location < string.length else { return false }
        let range = string.rangeOfComposedCharacterSequence(at: location)
        return isWordCluster(string.substring(with: range))
    }

    private static func isWordCluster(_ cluster: String) -> Bool {
        var hasBase = false
        for scalar in cluster.unicodeScalars {
            if isWordScalar(scalar) {
                if !CharacterSet.nonBaseCharacters.contains(scalar) { hasBase = true }
            } else {
                return false
            }
        }
        return hasBase
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x5F || scalar.value == 0x24
            || CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    private static func isVisible(
        _ position: Int,
        in visibleRange: NSRange,
        documentLength: Int
    ) -> Bool {
        guard position >= 0, position <= documentLength else { return false }
        if NSLocationInRange(position, visibleRange) { return true }
        // Only the document-end caret can be represented without a following
        // character; any other range-end position belongs to the next slice.
        return position == NSMaxRange(visibleRange)
            && position == documentLength
    }

    private static func isLineTerminator(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func endsInLineTerminator(_ string: NSString) -> Bool {
        guard string.length > 0 else { return false }
        switch string.character(at: string.length - 1) {
        case 0x0A, 0x0D, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}
