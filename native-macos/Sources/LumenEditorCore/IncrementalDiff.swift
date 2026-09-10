import Foundation

/// Resource bounds for the saved-baseline diff. The implementation uses an
/// LCS table, so the matrix limit is independent from the document/line caps.
public struct IncrementalDiffLimits: Equatable, Sendable {
    public static let standard = IncrementalDiffLimits()
    public static var `default`: IncrementalDiffLimits { standard }

    public var maximumTextUTF16Length: Int
    public var maximumLineCount: Int
    public var maximumMatrixCellCount: Int
    public var maximumHunkCount: Int

    public init(
        maximumTextUTF16Length: Int = 4 * 1_024 * 1_024,
        maximumLineCount: Int = 2_000,
        maximumMatrixCellCount: Int = 4_004_001,
        maximumHunkCount: Int = 2_000
    ) {
        precondition(maximumTextUTF16Length >= 0)
        precondition(maximumLineCount >= 0)
        precondition(maximumMatrixCellCount >= 1)
        precondition(maximumHunkCount >= 1)
        self.maximumTextUTF16Length = maximumTextUTF16Length
        self.maximumLineCount = maximumLineCount
        self.maximumMatrixCellCount = maximumMatrixCellCount
        self.maximumHunkCount = maximumHunkCount
    }
}

public enum IncrementalDiffError: Error, Equatable, LocalizedError, Sendable {
    case textTooLarge(side: IncrementalDiffSide, actual: Int, maximum: Int)
    case tooManyLines(side: IncrementalDiffSide, actual: Int, maximum: Int)
    case matrixTooLarge(actual: Int, maximum: Int)
    case tooManyHunks(actual: Int, maximum: Int)
    case staleHunk
    case invalidSelection

    public var errorDescription: String? {
        switch self {
        case let .textTooLarge(side, actual, maximum):
            return "The \(side.rawValue) text has \(actual) UTF-16 units; the maximum is \(maximum)."
        case let .tooManyLines(side, actual, maximum):
            return "The \(side.rawValue) text has \(actual) lines; the maximum is \(maximum)."
        case let .matrixTooLarge(actual, maximum):
            return "The incremental diff needs \(actual) matrix cells; the maximum is \(maximum)."
        case let .tooManyHunks(actual, maximum):
            return "The incremental diff produced \(actual) hunks; the maximum is \(maximum)."
        case .staleHunk:
            return "The incremental diff hunk no longer matches the current text."
        case .invalidSelection:
            return "The selection is outside the current text."
        }
    }
}

public enum IncrementalDiffSide: String, Equatable, Sendable {
    case baseline
    case current
}

public enum IncrementalDiffChangeKind: String, Codable, Equatable, Sendable {
    case added
    case modified
    case deleted
}

/// One line-oriented change between the saved baseline and the current text.
/// Line numbers are one-based. A pure deletion has zero current lines and its
/// current start is the insertion point, which can be one past the final line.
public struct IncrementalDiffHunk: Equatable, Sendable {
    public let kind: IncrementalDiffChangeKind
    public let baselineStartLine: Int
    public let currentStartLine: Int
    public let baselineLines: [String]
    public let currentLines: [String]

    public init(
        kind: IncrementalDiffChangeKind,
        baselineStartLine: Int,
        currentStartLine: Int,
        baselineLines: [String],
        currentLines: [String]
    ) {
        precondition(baselineStartLine >= 1)
        precondition(currentStartLine >= 1)
        precondition(!baselineLines.isEmpty || !currentLines.isEmpty)
        switch kind {
        case .added:
            precondition(baselineLines.isEmpty && !currentLines.isEmpty)
        case .modified:
            precondition(!baselineLines.isEmpty && !currentLines.isEmpty)
        case .deleted:
            precondition(!baselineLines.isEmpty && currentLines.isEmpty)
        }
        self.kind = kind
        self.baselineStartLine = baselineStartLine
        self.currentStartLine = currentStartLine
        self.baselineLines = baselineLines
        self.currentLines = currentLines
    }

    public var baselineLineCount: Int { baselineLines.count }
    public var currentLineCount: Int { currentLines.count }

    // Electron-compatible spellings used by gutter adapters.
    public var line: Int { currentStartLine }
    public var lineCount: Int { currentLineCount }
    public var baseStart: Int { baselineStartLine - 1 }
    public var baseLines: [String] { baselineLines }

    public static func == (left: Self, right: Self) -> Bool {
        left.kind == right.kind
            && left.baselineStartLine == right.baselineStartLine
            && left.currentStartLine == right.currentStartLine
            && IncrementalDiff.linesExactlyEqual(
                left.baselineLines, right.baselineLines
            )
            && IncrementalDiff.linesExactlyEqual(
                left.currentLines, right.currentLines
            )
    }
}

/// Rendering input independent of AppKit. `lineCount` is always at least one,
/// so a pure deletion can be painted at its clamped insertion point.
public struct IncrementalDiffMarker: Equatable, Sendable {
    public let kind: IncrementalDiffChangeKind
    public let line: Int
    public let lineCount: Int

    public init(kind: IncrementalDiffChangeKind, line: Int, lineCount: Int) {
        precondition(line >= 1)
        precondition(lineCount >= 1)
        self.kind = kind
        self.line = line
        self.lineCount = lineCount
    }
}

public enum IncrementalDiffNavigationDirection: Equatable, Sendable {
    case next
    case previous
}

public struct IncrementalDiffResult: Equatable, Sendable {
    public let hunks: [IncrementalDiffHunk]
    public let baselineLineCount: Int
    public let currentLineCount: Int

    public init(
        hunks: [IncrementalDiffHunk],
        baselineLineCount: Int,
        currentLineCount: Int
    ) {
        self.hunks = hunks
        self.baselineLineCount = baselineLineCount
        self.currentLineCount = currentLineCount
    }

    /// At least one visual line exists even when the string is empty.
    public var displayedCurrentLineCount: Int { max(1, currentLineCount) }

    public var markers: [IncrementalDiffMarker] {
        hunks.map { hunk in
            let line = min(displayedCurrentLineCount, max(1, hunk.currentStartLine))
            let available = displayedCurrentLineCount - line + 1
            return IncrementalDiffMarker(
                kind: hunk.kind,
                line: line,
                lineCount: min(available, max(1, hunk.currentLineCount))
            )
        }
    }

    public func hunk(
        from line: Int,
        direction: IncrementalDiffNavigationDirection
    ) -> IncrementalDiffHunk? {
        guard !hunks.isEmpty else { return nil }
        let current = min(displayedCurrentLineCount, max(1, line))
        switch direction {
        case .next:
            return hunks.first { markerLine(for: $0) > current } ?? hunks[0]
        case .previous:
            return hunks.last { markerLine(for: $0) < current } ?? hunks[hunks.count - 1]
        }
    }

    /// Matches Electron's current-hunk rule (containing hunk, then nearest
    /// preceding hunk), while also making a deletion at EOF reachable.
    public func currentHunk(at line: Int) -> IncrementalDiffHunk? {
        let current = min(displayedCurrentLineCount, max(1, line))
        if let containing = hunks.first(where: { hunk in
            let start = markerLine(for: hunk)
            let count = min(
                displayedCurrentLineCount - start + 1,
                max(1, hunk.currentLineCount)
            )
            return current >= start && current < start + count
        }) {
            return containing
        }
        return hunks.last { markerLine(for: $0) <= current }
    }

    public func markerLine(for hunk: IncrementalDiffHunk) -> Int {
        min(displayedCurrentLineCount, max(1, hunk.currentStartLine))
    }
}

/// Pure, bounded line diff used by navigation, hunk reversion, and gutters.
public enum IncrementalDiff {
    public static func compare(
        baseline: String,
        current: String,
        limits: IncrementalDiffLimits = .standard
    ) throws -> IncrementalDiffResult {
        let baselineLength = baseline.utf16.count
        guard baselineLength <= limits.maximumTextUTF16Length else {
            throw IncrementalDiffError.textTooLarge(
                side: .baseline, actual: baselineLength,
                maximum: limits.maximumTextUTF16Length
            )
        }
        let currentLength = current.utf16.count
        guard currentLength <= limits.maximumTextUTF16Length else {
            throw IncrementalDiffError.textTooLarge(
                side: .current, actual: currentLength,
                maximum: limits.maximumTextUTF16Length
            )
        }

        let baselineLineCount = diffLineCount(in: baseline)
        guard baselineLineCount <= limits.maximumLineCount else {
            throw IncrementalDiffError.tooManyLines(
                side: .baseline, actual: baselineLineCount,
                maximum: limits.maximumLineCount
            )
        }
        let currentLineCount = diffLineCount(in: current)
        guard currentLineCount <= limits.maximumLineCount else {
            throw IncrementalDiffError.tooManyLines(
                side: .current, actual: currentLineCount,
                maximum: limits.maximumLineCount
            )
        }

        let rows = baselineLineCount + 1
        let columns = currentLineCount + 1
        let cellProduct = rows.multipliedReportingOverflow(by: columns)
        guard !cellProduct.overflow, cellProduct.partialValue <= limits.maximumMatrixCellCount else {
            throw IncrementalDiffError.matrixTooLarge(
                actual: cellProduct.overflow ? Int.max : cellProduct.partialValue,
                maximum: limits.maximumMatrixCellCount
            )
        }

        let before = splitLines(baseline)
        let after = splitLines(current)
        let (beforeIDs, afterIDs) = internedLineIDs(before, after)
        // The line cap keeps every LCS length representable in UInt32 while
        // halving the table footprint compared with platform-sized Int.
        var table = [UInt32](repeating: 0, count: cellProduct.partialValue)
        if !before.isEmpty, !after.isEmpty {
            for baselineIndex in stride(from: before.count - 1, through: 0, by: -1) {
                for currentIndex in stride(from: after.count - 1, through: 0, by: -1) {
                    let index = baselineIndex * columns + currentIndex
                    if beforeIDs[baselineIndex] == afterIDs[currentIndex] {
                        table[index] = table[(baselineIndex + 1) * columns + currentIndex + 1] + 1
                    } else {
                        table[index] = max(
                            table[(baselineIndex + 1) * columns + currentIndex],
                            table[baselineIndex * columns + currentIndex + 1]
                        )
                    }
                }
            }
        }

        var hunks: [IncrementalDiffHunk] = []
        var baselineIndex = 0
        var currentIndex = 0
        var hunkBaselineStart = 0
        var hunkCurrentStart = 0
        var removed: [String] = []
        var added: [String] = []

        func flush() throws {
            guard !removed.isEmpty || !added.isEmpty else { return }
            let nextCount = hunks.count + 1
            guard nextCount <= limits.maximumHunkCount else {
                throw IncrementalDiffError.tooManyHunks(
                    actual: nextCount, maximum: limits.maximumHunkCount
                )
            }
            let kind: IncrementalDiffChangeKind
            if removed.isEmpty { kind = .added }
            else if added.isEmpty { kind = .deleted }
            else { kind = .modified }
            hunks.append(IncrementalDiffHunk(
                kind: kind,
                baselineStartLine: hunkBaselineStart + 1,
                currentStartLine: hunkCurrentStart + 1,
                baselineLines: removed,
                currentLines: added
            ))
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        while baselineIndex < before.count || currentIndex < after.count {
            if baselineIndex < before.count, currentIndex < after.count,
               beforeIDs[baselineIndex] == afterIDs[currentIndex] {
                try flush()
                baselineIndex += 1
                currentIndex += 1
                hunkBaselineStart = baselineIndex
                hunkCurrentStart = currentIndex
            } else if currentIndex < after.count,
                      baselineIndex == before.count
                        || table[baselineIndex * columns + currentIndex + 1]
                            >= table[(baselineIndex + 1) * columns + currentIndex] {
                added.append(after[currentIndex])
                currentIndex += 1
            } else {
                removed.append(before[baselineIndex])
                baselineIndex += 1
            }
        }
        try flush()
        return IncrementalDiffResult(
            hunks: hunks,
            baselineLineCount: baselineLineCount,
            currentLineCount: currentLineCount
        )
    }

    public static func changes(
        from baseline: String,
        to current: String,
        limits: IncrementalDiffLimits = .standard
    ) throws -> [IncrementalDiffHunk] {
        try compare(baseline: baseline, current: current, limits: limits).hunks
    }

    /// Rebuilds the current string with exactly one hunk restored.
    public static func reverting(
        _ hunk: IncrementalDiffHunk,
        in current: String
    ) throws -> String {
        var lines = splitLines(current)
        let index = hunk.currentStartLine - 1
        guard index >= 0, index <= lines.count,
              hunk.currentLineCount <= lines.count - index,
              linesExactlyEqual(
                Array(lines[index ..< index + hunk.currentLineCount]),
                hunk.currentLines
              )
        else { throw IncrementalDiffError.staleHunk }
        lines.replaceSubrange(
            index ..< index + hunk.currentLineCount,
            with: hunk.baselineLines
        )
        return lines.joined(separator: "\n")
    }

    /// Produces one revision-pinned UTF-16 transaction and explicitly maps the
    /// pane selection. Other pane selections are mapped by DocumentBuffer.
    public static func revertTransaction(
        current: String,
        hunk: IncrementalDiffHunk,
        selection: SelectionSet,
        expectedRevision: UInt64
    ) throws -> TextTransaction {
        guard selection.isValid(forUTF16Length: current.utf16.count) else {
            throw IncrementalDiffError.invalidSelection
        }
        let reverted = try reverting(hunk, in: current)
        guard let edit = minimalUTF16Edit(from: current, to: reverted) else {
            return try TextTransaction(
                edits: [], selection: selection, expectedRevision: expectedRevision
            )
        }
        let mapping = try TextTransaction(edits: [edit])
        return try TextTransaction(
            edits: [edit],
            selection: mapping.mapSelection(selection),
            expectedRevision: expectedRevision
        )
    }

    public static func lineNumber(atUTF16Offset requestedOffset: Int, in text: String) -> Int {
        lineAndColumn(atUTF16Offset: requestedOffset, in: text).line
    }

    /// Columns count UTF-16 code units, matching AppKit and LSP-style editor
    /// coordinates. An offset inside a surrogate pair therefore has column 2.
    public static func lineAndColumn(
        atUTF16Offset requestedOffset: Int, in text: String
    ) -> (line: Int, column: Int) {
        let offset = min(text.utf16.count, max(0, requestedOffset))
        var line = 1
        var column = 1
        var index = 0
        for unit in text.utf16 {
            guard index < offset else { break }
            if unit == 0x0a {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }
        return (line, column)
    }

    public static func utf16Offset(forLine requestedLine: Int, in text: String) -> Int {
        let target = max(1, requestedLine)
        guard target > 1 else { return 0 }
        var line = 1
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0a {
                line += 1
                if line == target { return offset }
            }
        }
        return text.utf16.count
    }

    /// Swift String equality folds canonical Unicode equivalents. Diff and
    /// stale-snapshot checks instead need CodeMirror/AppKit's exact UTF-16 view.
    public static func exactlyEqual(_ left: String, _ right: String) -> Bool {
        left.utf16.elementsEqual(right.utf16)
    }

    fileprivate static func linesExactlyEqual(
        _ left: [String], _ right: [String]
    ) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { pair in
            exactlyEqual(pair.0, pair.1)
        }
    }

    private static func diffLineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return 1 + text.utf16.reduce(into: 0) { count, unit in
            if unit == 0x0a { count += 1 }
        }
    }

    private static func splitLines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// Intern exact UTF-16 line values once so the O(n*m) dynamic-programming
    /// loop compares integers instead of repeatedly scanning long strings.
    private static func internedLineIDs(
        _ baseline: [String], _ current: [String]
    ) -> ([Int], [Int]) {
        var identifiers: [[UInt16]: Int] = [:]
        identifiers.reserveCapacity(baseline.count + current.count)
        var nextIdentifier = 0
        func identifier(for line: String) -> Int {
            let key = Array(line.utf16)
            if let existing = identifiers[key] { return existing }
            let identifier = nextIdentifier
            nextIdentifier += 1
            identifiers[key] = identifier
            return identifier
        }
        return (
            baseline.map { identifier(for: $0) },
            current.map { identifier(for: $0) }
        )
    }

    private static func minimalUTF16Edit(from oldText: String, to newText: String) -> TextEdit? {
        guard !exactlyEqual(oldText, newText) else { return nil }
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        let commonLimit = min(oldUnits.count, newUnits.count)
        var prefix = 0
        while prefix < commonLimit, oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }
        while prefix > 0,
              splitsSurrogatePair(oldUnits, at: prefix)
                || splitsSurrogatePair(newUnits, at: prefix) {
            prefix -= 1
        }

        var suffix = 0
        while suffix < oldUnits.count - prefix, suffix < newUnits.count - prefix,
              oldUnits[oldUnits.count - suffix - 1] == newUnits[newUnits.count - suffix - 1] {
            suffix += 1
        }
        while suffix > 0,
              splitsSurrogatePair(oldUnits, at: oldUnits.count - suffix)
                || splitsSurrogatePair(newUnits, at: newUnits.count - suffix) {
            suffix -= 1
        }

        let newEnd = newUnits.count - suffix
        return TextEdit(
            from: prefix,
            to: oldUnits.count - suffix,
            insert: String(decoding: newUnits[prefix ..< newEnd], as: UTF16.self)
        )
    }

    private static func splitsSurrogatePair(_ units: [UInt16], at boundary: Int) -> Bool {
        guard boundary > 0, boundary < units.count else { return false }
        return (0xD800 ... 0xDBFF).contains(units[boundary - 1])
            && (0xDC00 ... 0xDFFF).contains(units[boundary])
    }
}
