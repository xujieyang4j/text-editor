import Foundation
import LumenEditorCore

/// Pure UTF-16 rectangular-selection planning for Option-drag in the native
/// editor. Visual columns account for tab stops; no virtual spaces are added.
enum RectangularSelectionPlanner {
    static let maximumLines = 10_000

    struct Position: Equatable, Sendable {
        let line: Int
        let visualColumn: Int

        init(line: Int, visualColumn: Int) {
            self.line = line
            self.visualColumn = visualColumn
        }
    }

    struct Plan: Equatable, Sendable {
        let selection: SelectionSet
        let wasTruncated: Bool
    }

    static func merging(
        _ rectangle: SelectionSet,
        into existing: SelectionSet,
        maximumSelections: Int = maximumLines
    ) -> SelectionSet {
        let limit = max(1, maximumSelections)
        var ranges = rectangle.ranges
        let target = rectangle.main
        for range in existing.ranges where ranges.count < limit
                && !ranges.contains(where: { overlapsOrTouches($0, range) }) {
            ranges.append(range)
        }
        guard let mainIndex = ranges.firstIndex(of: target) else {
            return SelectionSet(ranges: Array(ranges.prefix(limit)), mainIndex: 0)
        }
        return SelectionSet(ranges: Array(ranges.prefix(limit)), mainIndex: mainIndex)
    }

    static func plan(
        text: String,
        anchor: Position,
        target: Position,
        tabWidth requestedTabWidth: Int,
        maximumLines requestedMaximumLines: Int = maximumLines
    ) -> Plan {
        let source = text as NSString
        let lines = physicalLines(in: source)
        let tabWidth = min(16, max(1, requestedTabWidth))
        let maximumLines = max(1, requestedMaximumLines)
        let anchorLine = min(max(0, anchor.line), lines.count - 1)
        let targetLine = min(max(0, target.line), lines.count - 1)
        let verticalStep = targetLine >= anchorLine ? 1 : -1
        let totalLines = abs(targetLine - anchorLine) + 1
        let retainedCount = min(totalLines, maximumLines)
        let horizontalForward = target.visualColumn >= anchor.visualColumn
        let anchorColumn = max(0, anchor.visualColumn)
        let targetColumn = max(0, target.visualColumn)

        var directed: [DirectedSelection] = []
        directed.reserveCapacity(retainedCount)
        for step in 0..<retainedCount {
            let line = lines[anchorLine + step * verticalStep]
            let anchorOffset = offset(
                atVisualColumn: anchorColumn, in: line, source: source,
                tabWidth: tabWidth, snapRight: !horizontalForward
            )
            let targetOffset = offset(
                atVisualColumn: targetColumn, in: line, source: source,
                tabWidth: tabWidth, snapRight: horizontalForward
            )
            directed.append(DirectedSelection(
                anchor: anchorOffset, head: targetOffset
            ))
        }

        // SelectionSet normalizes into document order while preserving the
        // direction of every row. Track the target-most retained row as main.
        let targetMost = directed[retainedCount - 1]
        let selection = SelectionSet(ranges: directed, mainIndex: retainedCount - 1)
        let mainIndex = selection.ranges.firstIndex(of: targetMost) ?? 0
        return Plan(
            selection: SelectionSet(ranges: selection.ranges, mainIndex: mainIndex),
            wasTruncated: retainedCount < totalLines
        )
    }

    static func position(
        text: String,
        line requestedLine: Int,
        x: Double,
        characterWidth: Double
    ) -> Position {
        let lineCount = physicalLines(in: text as NSString).count
        let line = min(max(0, requestedLine), max(0, lineCount - 1))
        let width = characterWidth.isFinite ? max(1, characterWidth) : 1
        let column = x.isFinite ? max(0, Int((x / width).rounded())) : 0
        return Position(line: line, visualColumn: column)
    }

    static func position(
        text: String, utf16Offset requestedOffset: Int, tabWidth requestedTabWidth: Int
    ) -> Position {
        let source = text as NSString
        let lines = physicalLines(in: source)
        let offset = validCharacterBoundary(
            min(source.length, max(0, requestedOffset)), in: source
        )
        let lineIndex = lineIndex(containing: offset, lines: lines)
        let line = lines[lineIndex]
        let end = min(offset, NSMaxRange(line))
        var column = 0
        let tabWidth = min(16, max(1, requestedTabWidth))
        if line.location < end {
            var location = line.location
            while location < end {
                let range = source.rangeOfComposedCharacterSequence(at: location)
                column = source.character(at: location) == 0x09
                    ? column + tabWidth - column % tabWidth
                    : column + 1
                location = NSMaxRange(range)
            }
        }
        return Position(line: lineIndex, visualColumn: column)
    }
}

private extension RectangularSelectionPlanner {
    static func physicalLines(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var lines: [NSRange] = []
        var location = 0
        while location < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                nil, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            guard lineEnd > location else { break }
            lines.append(NSRange(location: location, length: contentsEnd - location))
            location = lineEnd
        }
        if location == source.length, endsInLineTerminator(source) {
            lines.append(NSRange(location: source.length, length: 0))
        }
        return lines.isEmpty ? [NSRange(location: 0, length: 0)] : lines
    }

    static func offset(
        atVisualColumn requestedColumn: Int,
        in line: NSRange,
        source: NSString,
        tabWidth: Int,
        snapRight: Bool
    ) -> Int {
        let target = max(0, requestedColumn)
        var location = line.location
        var column = 0
        while location < NSMaxRange(line) {
            let unit = source.character(at: location)
            let characterRange = source.rangeOfComposedCharacterSequence(at: location)
            let nextColumn = unit == 0x09
                ? column + tabWidth - column % tabWidth
                : column + 1
            if target < nextColumn {
                return snapRight ? NSMaxRange(characterRange) : location
            }
            if target == nextColumn { return NSMaxRange(characterRange) }
            column = nextColumn
            location = NSMaxRange(characterRange)
        }
        return NSMaxRange(line)
    }

    static func lineIndex(containing offset: Int, lines: [NSRange]) -> Int {
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].location <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }

    static func endsInLineTerminator(_ source: NSString) -> Bool {
        guard source.length > 0 else { return false }
        switch source.character(at: source.length - 1) {
        case 0x0A, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    static func validCharacterBoundary(_ offset: Int, in source: NSString) -> Int {
        guard offset > 0, offset < source.length else { return offset }
        let unit = source.character(at: offset)
        let previous = source.character(at: offset - 1)
        return (0xDC00...0xDFFF).contains(unit)
            && (0xD800...0xDBFF).contains(previous) ? offset - 1 : offset
    }

    static func overlapsOrTouches(
        _ left: DirectedSelection, _ right: DirectedSelection
    ) -> Bool {
        if left.isEmpty && right.isEmpty { return left.from == right.from }
        if left.isEmpty { return left.from >= right.from && left.from <= right.to }
        if right.isEmpty { return right.from >= left.from && right.from <= left.to }
        return left.from < right.to && right.from < left.to
    }
}
