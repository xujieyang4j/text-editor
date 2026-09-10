import Foundation

/// Which side of an edit a position at an ambiguous boundary follows.
///
/// This matches CodeMirror's position association: `.before` stays before an
/// insertion at the same UTF-16 offset, while `.after` moves after it.
public enum PositionAssociation: Int, Codable, Sendable {
    case before = -1
    case after = 1
}

public typealias TextPositionAssociation = PositionAssociation

/// A selection whose anchor and moving head are UTF-16 document offsets.
/// A backwards selection has `anchor > head`.
public struct DirectedSelection: Codable, Equatable, Hashable, Sendable {
    public let anchor: Int
    public let head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public init(_ selection: SessionSelection) {
        self.init(anchor: selection.anchor, head: selection.head)
    }

    public var from: Int { min(anchor, head) }
    public var to: Int { max(anchor, head) }
    public var isEmpty: Bool { anchor == head }
    public var isForward: Bool { anchor <= head }
    public var isBackward: Bool { anchor > head }
    public var range: NSRange { NSRange(location: from, length: to - from) }
    public var sessionSelection: SessionSelection {
        SessionSelection(anchor: anchor, head: head)
    }

    public func clamped(toUTF16Length length: Int) -> DirectedSelection {
        precondition(length >= 0, "A document length cannot be negative")
        return DirectedSelection(
            anchor: min(length, max(0, anchor)),
            head: min(length, max(0, head))
        )
    }
}

/// One or more non-overlapping directed selections and the active range.
///
/// Construction uses CodeMirror-style normalization: ranges are sorted by
/// their lower boundary, overlapping ranges and colliding cursors are merged,
/// and `mainIndex` is adjusted to continue to identify the main range. Merely
/// sorting a range never changes its anchor/head direction.
public struct SelectionSet: Codable, Equatable, Sendable {
    public let ranges: [DirectedSelection]
    public let mainIndex: Int

    public init(ranges: [DirectedSelection], mainIndex: Int = 0) {
        precondition(!ranges.isEmpty, "A selection set needs at least one range")
        precondition(ranges.indices.contains(mainIndex), "The main selection index is out of range")
        precondition(
            ranges.allSatisfy { $0.anchor >= 0 && $0.head >= 0 },
            "Selection positions cannot be negative"
        )
        let normalized = Self.normalize(ranges, mainIndex: mainIndex)
        self.ranges = normalized.ranges
        self.mainIndex = normalized.mainIndex
    }

    public init(_ selection: DirectedSelection) {
        self.init(ranges: [selection])
    }

    public static func cursor(at position: Int) -> SelectionSet {
        SelectionSet(DirectedSelection(anchor: position, head: position))
    }

    public static func single(anchor: Int, head: Int? = nil) -> SelectionSet {
        SelectionSet(DirectedSelection(anchor: anchor, head: head ?? anchor))
    }

    public var main: DirectedSelection { ranges[mainIndex] }

    public func isValid(forUTF16Length length: Int) -> Bool {
        length >= 0 && ranges.allSatisfy { $0.anchor <= length && $0.head <= length }
    }

    public func clamped(toUTF16Length length: Int) -> SelectionSet {
        SelectionSet(
            ranges: ranges.map { $0.clamped(toUTF16Length: length) },
            mainIndex: mainIndex
        )
    }

    private enum CodingKeys: String, CodingKey {
        case ranges
        case mainIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRanges = try container.decode([DirectedSelection].self, forKey: .ranges)
        let decodedMainIndex = try container.decode(Int.self, forKey: .mainIndex)
        guard !decodedRanges.isEmpty, decodedRanges.indices.contains(decodedMainIndex),
              decodedRanges.allSatisfy({ $0.anchor >= 0 && $0.head >= 0 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ranges,
                in: container,
                debugDescription: "A selection set must contain a valid main range and non-negative positions."
            )
        }
        let normalized = Self.normalize(decodedRanges, mainIndex: decodedMainIndex)
        ranges = normalized.ranges
        mainIndex = normalized.mainIndex
    }

    private static func normalize(
        _ input: [DirectedSelection],
        mainIndex inputMainIndex: Int
    ) -> (ranges: [DirectedSelection], mainIndex: Int) {
        struct IndexedRange {
            let range: DirectedSelection
            let inputIndex: Int
        }

        var indexed = input.enumerated().map {
            IndexedRange(range: $0.element, inputIndex: $0.offset)
        }
        indexed.sort { left, right in
            if left.range.from != right.range.from { return left.range.from < right.range.from }
            return left.inputIndex < right.inputIndex
        }

        var normalized = indexed.map(\.range)
        var mainIndex = indexed.firstIndex { $0.inputIndex == inputMainIndex }!
        var index = 1
        while index < normalized.count {
            let previous = normalized[index - 1]
            let current = normalized[index]
            let shouldMerge = current.isEmpty
                ? current.from <= previous.to
                : current.from < previous.to
            guard shouldMerge else {
                index += 1
                continue
            }

            let mergedFrom = previous.from
            let mergedTo = max(previous.to, current.to)
            let merged = current.isBackward
                ? DirectedSelection(anchor: mergedTo, head: mergedFrom)
                : DirectedSelection(anchor: mergedFrom, head: mergedTo)
            if index <= mainIndex { mainIndex -= 1 }
            normalized.replaceSubrange((index - 1)...index, with: [merged])
            // Keep `index` in place so a newly merged range is compared with
            // the following range as well.
        }
        return (normalized, mainIndex)
    }
}

/// A replacement expressed in UTF-16 offsets in the original document.
public struct TextEdit: Codable, Equatable, Hashable, Sendable {
    public let from: Int
    public let to: Int
    public let insert: String

    public init(from: Int, to: Int, insert: String) {
        self.from = from
        self.to = to
        self.insert = insert
    }

    public init(_ edit: TextTransformEdit) {
        self.init(from: edit.from, to: edit.to, insert: edit.insert)
    }

    public var range: NSRange { NSRange(location: from, length: to - from) }
    public var removedUTF16Length: Int { to - from }
    public var insertedUTF16Length: Int { insert.utf16.count }
    public var lengthDelta: Int { insertedUTF16Length - removedUTF16Length }
    public var isInsertion: Bool { from == to && !insert.isEmpty }
    public var isNoOp: Bool { from == to && insert.isEmpty }
    public var transformEdit: TextTransformEdit {
        TextTransformEdit(from: from, to: to, insert: insert)
    }
}

public enum EditorTransactionError: Error, Equatable, LocalizedError, Sendable {
    case invalidEditRange(TextEdit)
    case overlappingEdits(TextEdit, TextEdit)
    case editOutOfBounds(TextEdit, documentUTF16Length: Int)
    case positionOutOfBounds(position: Int, documentUTF16Length: Int)
    case selectionOutOfBounds(viewID: EditorViewID, documentUTF16Length: Int)
    case unknownView(EditorViewID)
    case staleRevision(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case let .invalidEditRange(edit):
            return "Invalid UTF-16 edit range \(edit.from)..<\(edit.to)."
        case let .overlappingEdits(first, second):
            return "UTF-16 edits \(first.from)..<\(first.to) and \(second.from)..<\(second.to) overlap."
        case let .editOutOfBounds(edit, length):
            return "UTF-16 edit \(edit.from)..<\(edit.to) is outside a document of length \(length)."
        case let .positionOutOfBounds(position, length):
            return "UTF-16 position \(position) is outside a document of length \(length)."
        case let .selectionOutOfBounds(viewID, length):
            return "Selection for view \(viewID.rawValue) is outside a document of UTF-16 length \(length)."
        case let .unknownView(viewID):
            return "Editor view \(viewID.rawValue) is not registered with this buffer."
        case let .staleRevision(expected, actual):
            return "Transaction expected revision \(expected), but the buffer is at revision \(actual)."
        }
    }
}

public typealias TextTransactionError = EditorTransactionError

/// An atomic collection of edits in original-document coordinates.
///
/// Edits are kept in ascending original-coordinate order and are applied in
/// reverse, so every edit sees the document it was authored against. A
/// transaction's optional selection is already in post-edit coordinates.
public struct TextTransaction: Equatable, Sendable {
    public let edits: [TextEdit]
    public let selection: SelectionSet?
    public let expectedRevision: UInt64?

    public var selectionAfter: SelectionSet? { selection }
    public var baseRevision: UInt64? { expectedRevision }
    public var isEmpty: Bool { edits.isEmpty && selection == nil }

    public init(
        edits: [TextEdit],
        selection: SelectionSet? = nil,
        expectedRevision: UInt64? = nil
    ) throws {
        for edit in edits where edit.from < 0 || edit.to < edit.from {
            throw EditorTransactionError.invalidEditRange(edit)
        }
        let effectiveEdits = edits.filter { !$0.isNoOp }
        for leftIndex in effectiveEdits.indices {
            for rightIndex in effectiveEdits.indices where rightIndex > leftIndex {
                let left = effectiveEdits[leftIndex]
                let right = effectiveEdits[rightIndex]
                if Self.overlaps(left, right) {
                    throw EditorTransactionError.overlappingEdits(left, right)
                }
            }
        }

        self.edits = effectiveEdits.enumerated()
            .sorted { left, right in
                if left.element.from != right.element.from {
                    return left.element.from < right.element.from
                }
                // An insertion at a replacement's opening boundary must be
                // applied after that replacement during reverse application.
                if left.element.removedUTF16Length != right.element.removedUTF16Length {
                    if left.element.removedUTF16Length == 0 { return true }
                    if right.element.removedUTF16Length == 0 { return false }
                }
                return left.offset < right.offset
            }
            .map { $0.element }
        self.selection = selection
        self.expectedRevision = expectedRevision
    }

    public init(
        edits: [TextEdit],
        selectionAfter: SelectionSet?,
        expectedRevision: UInt64? = nil
    ) throws {
        try self.init(edits: edits, selection: selectionAfter, expectedRevision: expectedRevision)
    }

    public init(
        edits: [TextEdit],
        selection: SelectionSet? = nil,
        baseRevision: UInt64
    ) throws {
        try self.init(edits: edits, selection: selection, expectedRevision: baseRevision)
    }

    /// Apply all edits backwards to preserve their original UTF-16 offsets.
    public func applying(to text: String) throws -> String {
        let length = text.utf16.count
        try validate(forUTF16Length: length)
        let result = NSMutableString(string: text)
        for edit in edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.insert)
        }
        return result as String
    }

    public func validate(forUTF16Length length: Int) throws {
        guard length >= 0 else {
            throw EditorTransactionError.positionOutOfBounds(
                position: length,
                documentUTF16Length: length
            )
        }
        for edit in edits where edit.to > length {
            throw EditorTransactionError.editOutOfBounds(edit, documentUTF16Length: length)
        }
    }

    /// Map a known-valid UTF-16 position through the edits.
    ///
    /// `.before` leaves a same-point insertion after the position; `.after`
    /// makes the position follow the insertion. Inside replaced text, before
    /// maps to the replacement's start and after to its end. This overload has
    /// no document length to check; use the `originalUTF16Length` overload for
    /// untrusted positions.
    public func mapPosition(
        _ position: Int,
        association: PositionAssociation = .before
    ) -> Int {
        precondition(position >= 0, "A document position cannot be negative")
        return mapValidPosition(position, association: association)
    }

    /// Checked mapping for callers that also know the original document size.
    public func mapPosition(
        _ position: Int,
        association: PositionAssociation = .before,
        originalUTF16Length: Int
    ) throws -> Int {
        try validate(forUTF16Length: originalUTF16Length)
        guard (0...originalUTF16Length).contains(position) else {
            throw EditorTransactionError.positionOutOfBounds(
                position: position,
                documentUTF16Length: originalUTF16Length
            )
        }
        return mapValidPosition(position, association: association)
    }

    /// Map one directed selection using CodeMirror's inward range affinity.
    /// Cursors use the explicitly supplied association (before by default).
    public func mapSelection(
        _ selection: DirectedSelection,
        cursorAssociation: PositionAssociation = .before
    ) -> DirectedSelection {
        if selection.isEmpty {
            let position = mapPosition(selection.head, association: cursorAssociation)
            return DirectedSelection(anchor: position, head: position)
        }

        let firstMappedEdge = mapPosition(selection.from, association: .after)
        let secondMappedEdge = mapPosition(selection.to, association: .before)
        // Both original endpoints may fall inside one replacement, in which
        // case inward association can cross them. Normalize the mapped bounds
        // before restoring the original anchor/head direction.
        let mappedFrom = min(firstMappedEdge, secondMappedEdge)
        let mappedTo = max(firstMappedEdge, secondMappedEdge)
        return selection.isBackward
            ? DirectedSelection(anchor: mappedTo, head: mappedFrom)
            : DirectedSelection(anchor: mappedFrom, head: mappedTo)
    }

    public func mapSelection(
        _ selection: SelectionSet,
        cursorAssociation: PositionAssociation = .before
    ) -> SelectionSet {
        SelectionSet(
            ranges: selection.ranges.map {
                mapSelection($0, cursorAssociation: cursorAssociation)
            },
            mainIndex: selection.mainIndex
        )
    }

    private func mapValidPosition(
        _ position: Int,
        association: PositionAssociation
    ) -> Int {
        var oldPosition = 0
        var newPosition = 0

        for edit in edits {
            let unchangedLength = edit.from - oldPosition
            if unchangedLength > 0 {
                let unchangedEnd = oldPosition + unchangedLength
                if unchangedEnd > position {
                    return newPosition + (position - oldPosition)
                }
                oldPosition = unchangedEnd
                newPosition += unchangedLength
            }

            let removedLength = edit.removedUTF16Length
            let replacedEnd = oldPosition + removedLength
            if replacedEnd > position
                || (replacedEnd == position && association == .before && removedLength == 0) {
                if position == oldPosition || association == .before { return newPosition }
                return newPosition + edit.insertedUTF16Length
            }
            oldPosition = replacedEnd
            newPosition += edit.insertedUTF16Length
        }
        return newPosition + (position - oldPosition)
    }

    private static func overlaps(_ left: TextEdit, _ right: TextEdit) -> Bool {
        if left.from == left.to, right.from == right.to { return false }
        if left.from == left.to {
            return right.from < left.from && left.from < right.to
        }
        if right.from == right.to {
            return left.from < right.from && right.from < left.to
        }
        return max(left.from, right.from) < min(left.to, right.to)
    }

    fileprivate func inverted(in originalText: String) throws -> TextTransaction {
        try validate(forUTF16Length: originalText.utf16.count)
        let source = originalText as NSString
        var delta = 0
        var inverseEdits: [TextEdit] = []
        inverseEdits.reserveCapacity(edits.count)
        for edit in edits {
            let finalFrom = edit.from + delta
            inverseEdits.append(TextEdit(
                from: finalFrom,
                to: finalFrom + edit.insertedUTF16Length,
                insert: source.substring(with: edit.range)
            ))
            delta += edit.lengthDelta
        }
        return try TextTransaction(edits: inverseEdits)
    }
}

/// Stable identity for one pane/view that displays a shared document buffer.
public struct EditorViewID: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let `default` = EditorViewID(rawValue: "default")
    public var description: String { rawValue }
}

public typealias DocumentViewID = EditorViewID

/// A shared text buffer with per-view selection state and view-scoped history.
///
/// Revision zero is the initial state. Every successful apply, undo, or redo
/// advances the revision; undo never rolls it backwards. Each live view token
/// owns an independent undo/redo branch for the edits it authored, while text
/// changes continue to map selections in every registered view.
@MainActor
public final class DocumentBuffer {
    public private(set) var text: String
    public private(set) var revision: UInt64
    public private(set) var viewSelections: [EditorViewID: SelectionSet]

    private enum HistoryActionKind {
        case undo
        case redo
    }

    private struct HistoryEntry {
        let ownerViewID: EditorViewID
        let ownerToken: UUID
        let transaction: TextTransaction
        let beforeOwnerSelection: SelectionSet
        let afterOwnerSelection: SelectionSet
        let actionKind: HistoryActionKind
        let preservesExactOwnerSelection: Bool
        let exactTargetSelections: [EditorViewID: SelectionSet]?
        let exactTargetTokens: [EditorViewID: UUID]?
    }

    private struct ViewHistory {
        var undo: [HistoryEntry] = []
        var redo: [HistoryEntry] = []
    }

    /// Internal pane-instance identity. A public ID may be reused after a pane
    /// closes, but its registration token never is.
    private var viewRegistrationTokens: [EditorViewID: UUID]
    private var historiesByToken: [UUID: ViewHistory]

    public init(
        text: String = "",
        selection: SelectionSet = .cursor(at: 0),
        revision: UInt64 = 0
    ) {
        precondition(
            selection.isValid(forUTF16Length: text.utf16.count),
            "The initial selection is outside the document"
        )
        self.text = text
        self.revision = revision
        self.viewSelections = [.default: selection]
        self.viewRegistrationTokens = [.default: UUID()]
        self.historiesByToken = Dictionary(
            uniqueKeysWithValues: viewRegistrationTokens.values.map { ($0, ViewHistory()) }
        )
    }

    public init(
        text: String,
        viewSelections: [EditorViewID: SelectionSet],
        revision: UInt64 = 0
    ) throws {
        let length = text.utf16.count
        for (viewID, selection) in viewSelections
        where !selection.isValid(forUTF16Length: length) {
            throw EditorTransactionError.selectionOutOfBounds(
                viewID: viewID,
                documentUTF16Length: length
            )
        }
        self.text = text
        self.revision = revision
        self.viewSelections = viewSelections
        self.viewRegistrationTokens = Dictionary(
            uniqueKeysWithValues: viewSelections.keys.map { ($0, UUID()) }
        )
        if self.viewSelections[.default] == nil {
            self.viewSelections[.default] = .cursor(at: 0)
            self.viewRegistrationTokens[.default] = UUID()
        }
        self.historiesByToken = Dictionary(
            uniqueKeysWithValues: self.viewRegistrationTokens.values.map {
                ($0, ViewHistory())
            }
        )
    }

    /// The selection for the default single-pane view.
    public var selection: SelectionSet { viewSelections[.default]! }
    public var selections: [EditorViewID: SelectionSet] { viewSelections }
    public var utf16Length: Int { text.utf16.count }
    public var canUndo: Bool { canUndo(for: .default) }
    public var canRedo: Bool { canRedo(for: .default) }
    public var undoDepth: Int { undoDepth(for: .default) }
    public var redoDepth: Int { redoDepth(for: .default) }
    public static let maximumHistoryEntriesPerView = 1_000

    public func selection(for viewID: EditorViewID = .default) -> SelectionSet? {
        viewSelections[viewID]
    }

    public func setSelection(
        _ selection: SelectionSet,
        for viewID: EditorViewID = .default
    ) throws {
        guard selection.isValid(forUTF16Length: utf16Length) else {
            throw EditorTransactionError.selectionOutOfBounds(
                viewID: viewID,
                documentUTF16Length: utf16Length
            )
        }
        viewSelections[viewID] = selection
        if viewRegistrationTokens[viewID] == nil {
            viewRegistrationTokens[viewID] = UUID()
            if let token = viewRegistrationTokens[viewID] {
                historiesByToken[token] = ViewHistory()
            }
        }
    }

    /// Register a pane without coupling its lifetime to document undo/redo.
    public func registerView(
        _ viewID: EditorViewID,
        selection: SelectionSet = .cursor(at: 0)
    ) throws {
        guard selection.isValid(forUTF16Length: utf16Length) else {
            throw EditorTransactionError.selectionOutOfBounds(
                viewID: viewID,
                documentUTF16Length: utf16Length
            )
        }
        if let previousToken = viewRegistrationTokens[viewID] {
            historiesByToken.removeValue(forKey: previousToken)
        }
        viewSelections[viewID] = selection
        viewRegistrationTokens[viewID] = UUID()
        if let token = viewRegistrationTokens[viewID] {
            historiesByToken[token] = ViewHistory()
        }
    }

    public func removeView(_ viewID: EditorViewID) {
        guard viewID != .default else { return }
        if let token = viewRegistrationTokens[viewID] {
            historiesByToken.removeValue(forKey: token)
        }
        viewSelections.removeValue(forKey: viewID)
        viewRegistrationTokens.removeValue(forKey: viewID)
    }

    /// Replace the complete buffer state for disk reload or session restore.
    ///
    /// All selections are validated before any state changes. Existing pane
    /// registrations retain their instance token; newly supplied IDs receive a
    /// new token, and omitted IDs are unregistered. Text undo/redo history is
    /// discarded and the document revision advances exactly once.
    @discardableResult
    public func reset(
        text newText: String,
        viewSelections newViewSelections: [EditorViewID: SelectionSet]
    ) throws -> UInt64 {
        let length = newText.utf16.count
        for (viewID, selection) in newViewSelections
        where !selection.isValid(forUTF16Length: length) {
            throw EditorTransactionError.selectionOutOfBounds(
                viewID: viewID,
                documentUTF16Length: length
            )
        }

        var selections = newViewSelections
        if selections[.default] == nil { selections[.default] = .cursor(at: 0) }
        var tokens: [EditorViewID: UUID] = [:]
        tokens.reserveCapacity(selections.count)
        for viewID in selections.keys {
            tokens[viewID] = viewRegistrationTokens[viewID] ?? UUID()
        }

        text = newText
        viewSelections = selections
        viewRegistrationTokens = tokens
        clearHistory()
        advanceRevision()
        return revision
    }

    /// Reset a single-pane buffer while preserving the default registration.
    @discardableResult
    public func reset(
        text newText: String,
        selection newSelection: SelectionSet = .cursor(at: 0)
    ) throws -> UInt64 {
        try reset(text: newText, viewSelections: [.default: newSelection])
    }

    /// Apply one transaction for a view. Every edit in the transaction is one
    /// undo unit. Other views are mapped through the same edits.
    @discardableResult
    public func apply(
        _ transaction: TextTransaction,
        for viewID: EditorViewID = .default
    ) throws -> UInt64 {
        guard viewSelections[viewID] != nil else {
            throw EditorTransactionError.unknownView(viewID)
        }
        if let expectedRevision = transaction.expectedRevision, expectedRevision != revision {
            throw EditorTransactionError.staleRevision(
                expected: expectedRevision,
                actual: revision
            )
        }

        // A transaction with no effective edits is selection-only view state.
        // It deliberately does not enter or invalidate text undo history.
        if transaction.edits.isEmpty {
            guard let explicitSelection = transaction.selection else { return revision }
            guard explicitSelection.isValid(forUTF16Length: utf16Length) else {
                throw EditorTransactionError.selectionOutOfBounds(
                    viewID: viewID,
                    documentUTF16Length: utf16Length
                )
            }
            viewSelections[viewID] = explicitSelection
            return revision
        }

        let oldLength = utf16Length
        try transaction.validate(forUTF16Length: oldLength)
        let inverseTransaction = try transaction.inverted(in: text)
        let updatedText = try transaction.applying(to: text)
        let updatedLength = updatedText.utf16.count
        let beforeOwnerSelection = viewSelections[viewID] ?? .cursor(at: 0)
        var updatedSelections = viewSelections.mapValues {
            transaction.mapSelection($0)
        }

        if let explicitSelection = transaction.selection {
            guard explicitSelection.isValid(forUTF16Length: updatedLength) else {
                throw EditorTransactionError.selectionOutOfBounds(
                    viewID: viewID,
                    documentUTF16Length: updatedLength
                )
            }
            // Explicit transaction selections are post-change coordinates.
            updatedSelections[viewID] = explicitSelection
        }

        for (candidateViewID, selection) in updatedSelections
        where !selection.isValid(forUTF16Length: updatedLength) {
            throw EditorTransactionError.selectionOutOfBounds(
                viewID: candidateViewID,
                documentUTF16Length: updatedLength
            )
        }

        guard updatedText != text || updatedSelections != viewSelections else {
            return revision
        }

        rebaseHistories(
            through: transaction,
            originalUTF16Length: oldLength,
            clearingRedoFor: viewID
        )
        text = updatedText
        viewSelections = updatedSelections
        appendUndoEntry(HistoryEntry(
            ownerViewID: viewID,
            ownerToken: viewRegistrationTokens[viewID] ?? UUID(),
            transaction: inverseTransaction,
            beforeOwnerSelection: beforeOwnerSelection,
            afterOwnerSelection: updatedSelections[viewID] ?? beforeOwnerSelection,
            actionKind: .undo,
            preservesExactOwnerSelection: true,
            exactTargetSelections: nil,
            exactTargetTokens: nil
        ))
        advanceRevision()
        return revision
    }

    @discardableResult
    public func apply(
        _ transaction: TextTransaction,
        in viewID: EditorViewID
    ) throws -> UInt64 {
        try apply(transaction, for: viewID)
    }

    @discardableResult
    public func undo() -> Bool { undo(for: .default) }

    @discardableResult
    public func undo(for viewID: EditorViewID) -> Bool {
        guard let token = viewRegistrationTokens[viewID] else { return false }
        var history = historiesByToken[token] ?? ViewHistory()
        guard let entry = history.undo.popLast() else { return false }
        let returnSelections = viewSelections
        let returnTokens = viewRegistrationTokens
        let oldText = text
        let oldLength = utf16Length
        let updatedText: String
        let redoTransaction: TextTransaction
        do {
            updatedText = try entry.transaction.applying(to: oldText)
            redoTransaction = try entry.transaction.inverted(in: oldText)
        } catch {
            history.undo.append(entry)
            historiesByToken[token] = history
            return false
        }
        historiesByToken[token] = history
        rebaseHistories(
            through: entry.transaction,
            originalUTF16Length: oldLength,
            clearingRedoFor: nil
        )
        text = updatedText
        viewSelections = remappedSelections(
            afterApplying: entry,
            updatedLength: updatedText.utf16.count
        )
        appendRedoEntry(HistoryEntry(
            ownerViewID: entry.ownerViewID,
            ownerToken: entry.ownerToken,
            transaction: redoTransaction,
            beforeOwnerSelection: entry.beforeOwnerSelection,
            afterOwnerSelection: entry.afterOwnerSelection,
            actionKind: .redo,
            preservesExactOwnerSelection: entry.preservesExactOwnerSelection,
            exactTargetSelections: returnSelections,
            exactTargetTokens: returnTokens
        ))
        advanceRevision()
        return true
    }

    @discardableResult
    public func redo() -> Bool { redo(for: .default) }

    @discardableResult
    public func redo(for viewID: EditorViewID) -> Bool {
        guard let token = viewRegistrationTokens[viewID] else { return false }
        var history = historiesByToken[token] ?? ViewHistory()
        guard let entry = history.redo.popLast() else { return false }
        let returnSelections = viewSelections
        let returnTokens = viewRegistrationTokens
        let oldText = text
        let oldLength = utf16Length
        let updatedText: String
        let undoTransaction: TextTransaction
        do {
            updatedText = try entry.transaction.applying(to: oldText)
            undoTransaction = try entry.transaction.inverted(in: oldText)
        } catch {
            history.redo.append(entry)
            historiesByToken[token] = history
            return false
        }
        historiesByToken[token] = history
        rebaseHistories(
            through: entry.transaction,
            originalUTF16Length: oldLength,
            clearingRedoFor: nil
        )
        text = updatedText
        viewSelections = remappedSelections(
            afterApplying: entry,
            updatedLength: updatedText.utf16.count
        )
        appendUndoEntry(HistoryEntry(
            ownerViewID: entry.ownerViewID,
            ownerToken: entry.ownerToken,
            transaction: undoTransaction,
            beforeOwnerSelection: entry.beforeOwnerSelection,
            afterOwnerSelection: entry.afterOwnerSelection,
            actionKind: .undo,
            preservesExactOwnerSelection: entry.preservesExactOwnerSelection,
            exactTargetSelections: returnSelections,
            exactTargetTokens: returnTokens
        ))
        advanceRevision()
        return true
    }

    public func clearHistory() {
        historiesByToken = Dictionary(
            uniqueKeysWithValues: viewRegistrationTokens.values.map { ($0, ViewHistory()) }
        )
    }

    public func canUndo(for viewID: EditorViewID) -> Bool {
        guard let token = viewRegistrationTokens[viewID] else { return false }
        return !(historiesByToken[token]?.undo.isEmpty ?? true)
    }

    public func canRedo(for viewID: EditorViewID) -> Bool {
        guard let token = viewRegistrationTokens[viewID] else { return false }
        return !(historiesByToken[token]?.redo.isEmpty ?? true)
    }

    public func undoDepth(for viewID: EditorViewID) -> Int {
        guard let token = viewRegistrationTokens[viewID] else { return 0 }
        return historiesByToken[token]?.undo.count ?? 0
    }

    public func redoDepth(for viewID: EditorViewID) -> Int {
        guard let token = viewRegistrationTokens[viewID] else { return 0 }
        return historiesByToken[token]?.redo.count ?? 0
    }

    private func appendUndoEntry(_ entry: HistoryEntry) {
        guard let token = viewRegistrationTokens[entry.ownerViewID],
              token == entry.ownerToken else { return }
        var history = historiesByToken[token] ?? ViewHistory()
        history.undo.append(entry)
        if history.undo.count > Self.maximumHistoryEntriesPerView {
            history.undo.removeFirst(
                history.undo.count - Self.maximumHistoryEntriesPerView
            )
        }
        historiesByToken[token] = history
    }

    private func appendRedoEntry(_ entry: HistoryEntry) {
        guard let token = viewRegistrationTokens[entry.ownerViewID],
              token == entry.ownerToken else { return }
        var history = historiesByToken[token] ?? ViewHistory()
        history.redo.append(entry)
        if history.redo.count > Self.maximumHistoryEntriesPerView {
            history.redo.removeFirst(
                history.redo.count - Self.maximumHistoryEntriesPerView
            )
        }
        historiesByToken[token] = history
    }

    private func remappedSelections(
        afterApplying entry: HistoryEntry,
        updatedLength: Int
    ) -> [EditorViewID: SelectionSet] {
        var mappedSelections = viewSelections.mapValues {
            entry.transaction.mapSelection($0).clamped(toUTF16Length: updatedLength)
        }
        if let exactSelections = entry.exactTargetSelections,
           let exactTokens = entry.exactTargetTokens {
            for (viewID, exactSelection) in exactSelections
            where viewSelections[viewID] != nil
                && viewRegistrationTokens[viewID] == exactTokens[viewID] {
                mappedSelections[viewID] = exactSelection.clamped(
                    toUTF16Length: updatedLength
                )
            }
            return mappedSelections
        }
        if entry.preservesExactOwnerSelection,
           viewRegistrationTokens[entry.ownerViewID] == entry.ownerToken,
           viewSelections[entry.ownerViewID] != nil {
            let exactSelection = (entry.actionKind == .undo
                ? entry.beforeOwnerSelection
                : entry.afterOwnerSelection
            ).clamped(toUTF16Length: updatedLength)
            mappedSelections[entry.ownerViewID] = exactSelection
        }
        return mappedSelections
    }

    private func rebaseHistories(
        through appliedTransaction: TextTransaction,
        originalUTF16Length: Int,
        clearingRedoFor viewID: EditorViewID?
    ) {
        let clearedToken = viewID.flatMap { viewRegistrationTokens[$0] }
        for token in Array(historiesByToken.keys) {
            var history = historiesByToken[token] ?? ViewHistory()
            history.undo = history.undo.compactMap {
                rebase($0, through: appliedTransaction, originalUTF16Length: originalUTF16Length)
            }
            if token == clearedToken {
                history.redo.removeAll(keepingCapacity: true)
            } else {
                history.redo = history.redo.compactMap {
                    rebase(
                        $0,
                        through: appliedTransaction,
                        originalUTF16Length: originalUTF16Length
                    )
                }
            }
            historiesByToken[token] = history
        }
    }

    private func rebase(
        _ entry: HistoryEntry,
        through appliedTransaction: TextTransaction,
        originalUTF16Length: Int
    ) -> HistoryEntry? {
        guard let rebasedTransaction = rebase(
            entry.transaction,
            through: appliedTransaction,
            originalUTF16Length: originalUTF16Length
        ) else { return nil }
        let mappedBeforeSelection = appliedTransaction.mapSelection(
            entry.beforeOwnerSelection
        )
        let mappedAfterSelection = appliedTransaction.mapSelection(
            entry.afterOwnerSelection
        )
        let mappedExactTargetSelections = entry.exactTargetSelections?.mapValues {
            appliedTransaction.mapSelection($0)
        }
        return HistoryEntry(
            ownerViewID: entry.ownerViewID,
            ownerToken: entry.ownerToken,
            transaction: rebasedTransaction,
            beforeOwnerSelection: mappedBeforeSelection,
            afterOwnerSelection: mappedAfterSelection,
            actionKind: entry.actionKind,
            preservesExactOwnerSelection: entry.preservesExactOwnerSelection,
            exactTargetSelections: mappedExactTargetSelections,
            exactTargetTokens: entry.exactTargetTokens
        )
    }

    private func rebase(
        _ transaction: TextTransaction,
        through appliedTransaction: TextTransaction,
        originalUTF16Length: Int
    ) -> TextTransaction? {
        guard !transaction.edits.isEmpty else { return transaction }
        var rebasedEdits: [TextEdit] = []
        rebasedEdits.reserveCapacity(transaction.edits.count)
        for edit in transaction.edits {
            if edit.from == edit.to {
                guard let mapped = try? appliedTransaction.mapPosition(
                    edit.from,
                    association: .before,
                    originalUTF16Length: originalUTF16Length
                ) else { return nil }
                rebasedEdits.append(TextEdit(from: mapped, to: mapped, insert: edit.insert))
                continue
            }
            for appliedEdit in appliedTransaction.edits
            where Self.editsConflictWhenRebasing(edit, through: appliedEdit) {
                return nil
            }
            guard let mappedFrom = try? appliedTransaction.mapPosition(
                edit.from,
                association: .after,
                originalUTF16Length: originalUTF16Length
            ), let mappedTo = try? appliedTransaction.mapPosition(
                edit.to,
                association: .before,
                originalUTF16Length: originalUTF16Length
            ), mappedFrom <= mappedTo else {
                return nil
            }
            rebasedEdits.append(TextEdit(
                from: mappedFrom,
                to: mappedTo,
                insert: edit.insert
            ))
        }
        return try? TextTransaction(edits: rebasedEdits)
    }

    private static func editsConflictWhenRebasing(
        _ historyEdit: TextEdit,
        through appliedEdit: TextEdit
    ) -> Bool {
        if historyEdit.from == historyEdit.to { return false }
        if appliedEdit.from == appliedEdit.to {
            return historyEdit.from < appliedEdit.from && appliedEdit.from < historyEdit.to
        }
        return max(historyEdit.from, appliedEdit.from) < min(historyEdit.to, appliedEdit.to)
    }

    private func advanceRevision() {
        precondition(revision < UInt64.max, "Document revision exhausted")
        revision += 1
    }
}
