import Foundation

/// A declarative snippet row suitable for merging built-in, project, and
/// enabled plug-in sources. No executable callback is carried in the value.
public struct SnippetDefinition: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case builtIn
        case project
        case plugin(id: String, name: String)
    }

    public let id: String
    public let label: String
    public let text: String
    public let trigger: String?
    public let scope: String?
    public let source: Source

    public init(
        id: String,
        label: String,
        text: String,
        trigger: String? = nil,
        scope: String? = nil,
        source: Source
    ) {
        self.id = id
        self.label = label
        self.text = text
        self.trigger = trigger
        self.scope = scope
        self.source = source
    }
}

public struct SnippetPlaceholder: Equatable, Sendable {
    public let index: Int
    public let range: NSRange

    public init(index: Int, range: NSRange) {
        self.index = index
        self.range = range
    }
}

/// Parsed form of Electron's practical `${1:default}`, `${2}`, `$1`, and
/// `${0}` subset. Offsets are UTF-16, matching AppKit and TextTransaction.
public struct ParsedSnippet: Equatable, Sendable {
    public let text: String
    public let placeholders: [SnippetPlaceholder]
    public let finalOffset: Int

    public init(text: String, placeholders: [SnippetPlaceholder], finalOffset: Int) {
        self.text = text
        self.placeholders = placeholders
        self.finalOffset = finalOffset
    }
}

public struct SnippetInsertionPlan: Equatable, Sendable {
    public let transaction: TextTransaction
    public let placeholders: [SnippetPlaceholder]
    public let finalPosition: Int
    public let replacedTriggerRange: NSRange?

    public init(
        transaction: TextTransaction,
        placeholders: [SnippetPlaceholder],
        finalPosition: Int,
        replacedTriggerRange: NSRange? = nil
    ) {
        self.transaction = transaction
        self.placeholders = placeholders
        self.finalPosition = finalPosition
        self.replacedTriggerRange = replacedTriggerRange
    }
}

public struct SnippetLimits: Equatable, Sendable {
    public static let standard = SnippetLimits()

    public var maximumTemplateUTF16Length: Int
    public var maximumPlaceholders: Int
    public var maximumPlaceholderIndex: Int

    public init(
        maximumTemplateUTF16Length: Int = 10_000,
        maximumPlaceholders: Int = 1_000,
        maximumPlaceholderIndex: Int = 100_000
    ) {
        precondition(maximumTemplateUTF16Length >= 0)
        precondition(maximumPlaceholders >= 0)
        precondition(maximumPlaceholderIndex >= 0)
        self.maximumTemplateUTF16Length = maximumTemplateUTF16Length
        self.maximumPlaceholders = maximumPlaceholders
        self.maximumPlaceholderIndex = maximumPlaceholderIndex
    }
}

public enum SnippetError: Error, Equatable, LocalizedError, Sendable {
    case templateTooLarge(actual: Int, maximum: Int)
    case tooManyPlaceholders(actual: Int, maximum: Int)
    case placeholderIndexTooLarge(index: Int, maximum: Int)
    case invalidSelection

    public var errorDescription: String? {
        switch self {
        case let .templateTooLarge(actual, maximum):
            return "Snippet uses \(actual) UTF-16 units; the maximum is \(maximum)."
        case let .tooManyPlaceholders(actual, maximum):
            return "Snippet has \(actual) placeholders; the maximum is \(maximum)."
        case let .placeholderIndexTooLarge(index, maximum):
            return "Snippet placeholder \(index) exceeds the maximum index \(maximum)."
        case .invalidSelection:
            return "The snippet selection is outside the active document."
        }
    }
}

public enum SnippetNavigationDirection: Int, Equatable, Sendable {
    case previous = -1
    case next = 1
}

public enum SnippetNavigationResult: Equatable, Sendable {
    case inactive
    case selection(SelectionSet)
    case final(SelectionSet)
}

public enum SnippetSessionError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlaceholderRange
    case editCannotBeMapped
    case mirrorLimitExceeded(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPlaceholderRange:
            return "A snippet placeholder is outside the document."
        case .editCannotBeMapped:
            return "The edit cannot be mapped through the active snippet session."
        case let .mirrorLimitExceeded(actual, maximum):
            return "Snippet mirroring needs \(actual) edits; the maximum is \(maximum)."
        }
    }
}

/// Editor-independent placeholder session. The application owns its lifetime
/// and feeds accepted editor transactions into `mirrorTransaction`.
public struct SnippetSession: Equatable, Sendable {
    public let documentID: String
    public private(set) var placeholders: [SnippetPlaceholder]
    public private(set) var finalPosition: Int
    public private(set) var activeIndex: Int?
    public private(set) var isActive: Bool

    public init(
        documentID: String,
        placeholders: [SnippetPlaceholder],
        finalPosition: Int
    ) {
        precondition(finalPosition >= 0)
        let ordered = placeholders.enumerated().sorted { left, right in
            if left.element.index != right.element.index {
                return left.element.index < right.element.index
            }
            return left.offset < right.offset
        }.map(\.element)
        self.documentID = documentID
        self.placeholders = ordered
        self.finalPosition = finalPosition
        activeIndex = ordered.isEmpty ? nil : 0
        isActive = !ordered.isEmpty
    }

    private init(
        documentID: String,
        placeholders: [SnippetPlaceholder],
        finalPosition: Int,
        activeIndex: Int?,
        isActive: Bool
    ) {
        self.documentID = documentID
        self.placeholders = placeholders
        self.finalPosition = finalPosition
        self.activeIndex = activeIndex
        self.isActive = isActive
    }

    public var activePlaceholder: SnippetPlaceholder? {
        guard isActive, let activeIndex, placeholders.indices.contains(activeIndex) else {
            return nil
        }
        return placeholders[activeIndex]
    }

    public func containsActiveSelection(_ selection: SelectionSet) -> Bool {
        guard let active = activePlaceholder, selection.ranges.count == 1 else {
            return false
        }
        let end = active.range.location + active.range.length
        return selection.main.from >= active.range.location && selection.main.to <= end
    }

    public mutating func cancel() {
        placeholders = []
        activeIndex = nil
        isActive = false
    }

    public mutating func documentDidChange(to documentID: String) {
        if documentID != self.documentID { cancel() }
    }

    public mutating func navigate(
        _ direction: SnippetNavigationDirection
    ) -> SnippetNavigationResult {
        guard isActive, !placeholders.isEmpty, let activeIndex else { return .inactive }
        switch direction {
        case .next where activeIndex >= placeholders.count - 1:
            let selection = SelectionSet.cursor(at: finalPosition)
            cancel()
            return .final(selection)
        case .next:
            self.activeIndex = activeIndex + 1
        case .previous:
            self.activeIndex = (activeIndex - 1 + placeholders.count) % placeholders.count
        }
        let target = placeholders[self.activeIndex!]
        return .selection(.single(
            anchor: target.range.location,
            head: target.range.location + target.range.length
        ))
    }

    /// Folds an edit of the active placeholder and every same-number mirror
    /// replacement into one transaction in the original document coordinates.
    /// Applying the returned value therefore creates exactly one undo unit.
    /// This value mutates a candidate session; callers commit that candidate
    /// only after their transaction callback accepts the result.
    public mutating func incorporatingUserTransaction(
        _ transaction: TextTransaction,
        in originalText: String,
        maximumMirrorEdits: Int = 1_000
    ) throws -> TextTransaction {
        precondition(maximumMirrorEdits >= 1)
        guard isActive, let activeBefore = activePlaceholder else { return transaction }
        let oldLength = originalText.utf16.count
        try transaction.validate(forUTF16Length: oldLength)
        guard placeholders.allSatisfy({ placeholder in
            placeholder.range.location >= 0
                && placeholder.range.location + placeholder.range.length <= oldLength
        }) else { throw SnippetSessionError.invalidPlaceholderRange }

        let activeEdits = transaction.edits.filter { edit in
            Self.isContained(edit, in: activeBefore.range)
        }
        let touchesActive = !activeEdits.isEmpty
        if transaction.edits.contains(where: { edit in
            Self.overlapsAnyPlaceholderBoundary(edit, placeholders: placeholders)
                || (touchesActive && !Self.isContained(edit, in: activeBefore.range))
        }) {
            cancel()
            throw SnippetSessionError.editCannotBeMapped
        }
        guard touchesActive else {
            mapState(through: transaction)
            return transaction
        }
        guard activeEdits.count == transaction.edits.count else {
            cancel()
            throw SnippetSessionError.editCannotBeMapped
        }

        let activeText = (originalText as NSString).substring(
            with: activeBefore.range
        )
        guard let localTransaction = try? TextTransaction(
            edits: activeEdits.map { edit in
                TextEdit(
                    from: edit.from - activeBefore.range.location,
                    to: edit.to - activeBefore.range.location,
                    insert: edit.insert
                )
            }
        ) else { throw SnippetSessionError.editCannotBeMapped }
        let value = try localTransaction.applying(to: activeText)
        let originalPlaceholders = placeholders
        let originalActiveIndex = activeIndex
        var afterUser = SnippetSession(
            documentID: documentID, placeholders: placeholders,
            finalPosition: finalPosition, activeIndex: activeIndex, isActive: isActive
        )
        afterUser.mapState(through: transaction)
        let activeLength = activeBefore.range.length
            + activeEdits.reduce(0) { $0 + $1.lengthDelta }
        guard activeLength >= 0, let originalActiveIndex else {
            throw SnippetSessionError.editCannotBeMapped
        }
        afterUser.placeholders[originalActiveIndex] = SnippetPlaceholder(
            index: activeBefore.index,
            range: NSRange(location: activeBefore.range.location, length: activeLength)
        )
        guard let activeAfter = afterUser.activePlaceholder else { return transaction }
        let mirrorsAfterUser = afterUser.placeholders.enumerated().filter { offset, placeholder in
            offset != originalActiveIndex && placeholder.index == activeAfter.index
        }
        guard mirrorsAfterUser.count <= maximumMirrorEdits else {
            throw SnippetSessionError.mirrorLimitExceeded(
                actual: mirrorsAfterUser.count, maximum: maximumMirrorEdits
            )
        }
        let intermediateSource = NSString(
            string: try transaction.applying(to: originalText)
        )
        let intermediateMirrorEdits = mirrorsAfterUser.compactMap { _, placeholder
            -> TextEdit? in
            guard intermediateSource.substring(with: placeholder.range) != value else { return nil }
            return TextEdit(
                from: placeholder.range.location,
                to: placeholder.range.location + placeholder.range.length,
                insert: value
            )
        }
        let originalSource = originalText as NSString
        let oldMirrorEdits = originalPlaceholders.enumerated().compactMap { offset, placeholder
            -> TextEdit? in
            guard offset != originalActiveIndex,
                  placeholder.index == activeBefore.index,
                  originalSource.substring(with: placeholder.range) != value else { return nil }
            return TextEdit(
                from: placeholder.range.location,
                to: placeholder.range.location + placeholder.range.length,
                insert: value
            )
        }
        guard !oldMirrorEdits.isEmpty else {
            self = afterUser
            return transaction
        }
        let mirrorTransaction = try TextTransaction(edits: intermediateMirrorEdits)
        let combined = try TextTransaction(
            edits: transaction.edits + oldMirrorEdits,
            selection: transaction.selection.map {
                mirrorTransaction.mapSelection($0, cursorAssociation: .after)
            },
            expectedRevision: transaction.expectedRevision
        )
        afterUser.mapState(through: mirrorTransaction)
        self = afterUser
        return combined
    }

    private mutating func mapState(through transaction: TextTransaction) {
        placeholders = placeholders.map { placeholder in
            let contained = transaction.edits.filter {
                Self.isContained($0, in: placeholder.range)
            }
            let start = Self.mappedStart(placeholder.range.location, through: transaction)
            return SnippetPlaceholder(
                index: placeholder.index,
                range: NSRange(
                    location: start,
                    length: max(0, placeholder.range.length
                        + contained.reduce(0) { $0 + $1.lengthDelta })
                )
            )
        }
        finalPosition = Self.mappedStart(finalPosition, through: transaction)
    }

    private static func overlapsBoundary(_ edit: TextEdit, range: NSRange) -> Bool {
        let end = range.location + range.length
        if edit.from == edit.to { return false }
        let overlaps = edit.from < end && edit.to > range.location
            || (range.length == 0 && edit.from <= range.location && edit.to >= range.location)
        return overlaps && !isContained(edit, in: range)
    }

    private static func isContained(_ edit: TextEdit, in range: NSRange) -> Bool {
        let end = range.location + range.length
        return edit.from >= range.location && edit.to <= end
    }

    private static func overlapsAnyPlaceholderBoundary(
        _ edit: TextEdit, placeholders: [SnippetPlaceholder]
    ) -> Bool {
        placeholders.contains { overlapsBoundary(edit, range: $0.range) }
    }

    private static func mappedStart(_ position: Int, through transaction: TextTransaction) -> Int {
        position + transaction.edits.reduce(0) { delta, edit in
            edit.from < position ? delta + edit.lengthDelta : delta
        }
    }
}

public enum SnippetEngine {
    /// Electron's trigger grammar is the ASCII `[\w-]+` suffix on the current
    /// line immediately before an empty cursor selection.
    public static func triggerBeforeCursor(in text: String, cursor: Int) -> String? {
        let units = Array(text.utf16)
        guard (0...units.count).contains(cursor) else { return nil }
        var start = cursor
        while start > 0 {
            let unit = units[start - 1]
            guard isTriggerCodeUnit(unit) else { break }
            start -= 1
        }
        guard start < cursor else { return nil }
        return String(decoding: units[start ..< cursor], as: UTF16.self)
    }

    public static func parse(
        _ template: String,
        limits: SnippetLimits = .standard
    ) throws -> ParsedSnippet {
        let templateLength = template.utf16.count
        guard templateLength <= limits.maximumTemplateUTF16Length else {
            throw SnippetError.templateTooLarge(
                actual: templateLength, maximum: limits.maximumTemplateUTF16Length
            )
        }

        let source = template as NSString
        let pattern = #"\$\{(\d+)(?::([^}]*))?\}|\$(\d+)"#
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(
            in: template, range: NSRange(location: 0, length: source.length)
        )
        guard matches.count <= limits.maximumPlaceholders else {
            throw SnippetError.tooManyPlaceholders(
                actual: matches.count, maximum: limits.maximumPlaceholders
            )
        }

        var output = ""
        var outputLength = 0
        var cursor = 0
        var placeholders: [SnippetPlaceholder] = []
        var finalOffset: Int?
        for match in matches {
            let literalRange = NSRange(
                location: cursor, length: match.range.location - cursor
            )
            let literal = source.substring(with: literalRange)
            output += literal
            outputLength += literal.utf16.count

            let firstIndex = match.range(at: 1)
            let compactIndex = match.range(at: 3)
            let indexText = source.substring(with:
                firstIndex.location == NSNotFound ? compactIndex : firstIndex
            )
            let index = Int(indexText) ?? Int.max
            guard index <= limits.maximumPlaceholderIndex else {
                throw SnippetError.placeholderIndexTooLarge(
                    index: index, maximum: limits.maximumPlaceholderIndex
                )
            }

            let defaultRange = match.range(at: 2)
            let value = defaultRange.location == NSNotFound
                ? "" : source.substring(with: defaultRange)
            let start = outputLength
            output += value
            outputLength += value.utf16.count
            if index == 0 {
                // Electron uses the last explicit final marker.
                finalOffset = start
            } else {
                placeholders.append(SnippetPlaceholder(
                    index: index,
                    range: NSRange(location: start, length: value.utf16.count)
                ))
            }
            cursor = match.range.location + match.range.length
        }

        let tail = source.substring(from: cursor)
        output += tail
        outputLength += tail.utf16.count
        placeholders = placeholders.enumerated().sorted { left, right in
            if left.element.index != right.element.index {
                return left.element.index < right.element.index
            }
            if left.element.range.location != right.element.range.location {
                return left.element.range.location < right.element.range.location
            }
            return left.offset < right.offset
        }.map(\.element)
        return ParsedSnippet(
            text: output, placeholders: placeholders,
            finalOffset: finalOffset ?? outputLength
        )
    }

    /// Builds one undoable replacement transaction and absolute placeholder
    /// ranges. The first numbered placeholder is selected immediately.
    public static func insertionPlan(
        template: String,
        documentUTF16Length: Int,
        selection: SelectionSet,
        expectedRevision: UInt64? = nil,
        limits: SnippetLimits = .standard
    ) throws -> SnippetInsertionPlan {
        guard selection.isValid(forUTF16Length: documentUTF16Length) else {
            throw SnippetError.invalidSelection
        }
        let parsed = try parse(template, limits: limits)
        let insertionStart = selection.main.from
        let absolutePlaceholders = parsed.placeholders.map { placeholder in
            SnippetPlaceholder(
                index: placeholder.index,
                range: NSRange(
                    location: insertionStart + placeholder.range.location,
                    length: placeholder.range.length
                )
            )
        }
        let finalPosition = insertionStart + parsed.finalOffset
        let selectionAfter = absolutePlaceholders.first.map { placeholder in
            SelectionSet.single(
                anchor: placeholder.range.location,
                head: placeholder.range.location + placeholder.range.length
            )
        } ?? .cursor(at: finalPosition)
        let transaction = try TextTransaction(
            edits: [TextEdit(
                from: selection.main.from,
                to: selection.main.to,
                insert: parsed.text
            )],
            selection: selectionAfter,
            expectedRevision: expectedRevision
        )
        try transaction.validate(forUTF16Length: documentUTF16Length)
        return SnippetInsertionPlan(
            transaction: transaction,
            placeholders: absolutePlaceholders,
            finalPosition: finalPosition
        )
    }

    /// Atomically removes an immediately preceding trigger and inserts the
    /// expanded snippet. Electron emits two changes, but one native
    /// transaction intentionally gives users a single undo step.
    public static func triggerExpansionPlan(
        trigger: String,
        template: String,
        documentUTF16Length: Int,
        cursor: Int,
        expectedRevision: UInt64? = nil,
        limits: SnippetLimits = .standard
    ) throws -> SnippetInsertionPlan {
        let triggerLength = trigger.utf16.count
        guard !trigger.isEmpty, cursor >= triggerLength,
              cursor <= documentUTF16Length else {
            throw SnippetError.invalidSelection
        }
        let replacedRange = NSRange(
            location: cursor - triggerLength, length: triggerLength
        )
        let base = try insertionPlan(
            template: template, documentUTF16Length: documentUTF16Length,
            selection: .single(
                anchor: replacedRange.location, head: cursor
            ),
            expectedRevision: expectedRevision, limits: limits
        )
        return SnippetInsertionPlan(
            transaction: base.transaction, placeholders: base.placeholders,
            finalPosition: base.finalPosition, replacedTriggerRange: replacedRange
        )
    }

    public static func triggerExpansionPlan(
        trigger: String,
        template: String,
        documentText: String,
        cursor: Int,
        expectedRevision: UInt64? = nil,
        limits: SnippetLimits = .standard
    ) throws -> SnippetInsertionPlan {
        guard triggerBeforeCursor(in: documentText, cursor: cursor) == trigger else {
            throw SnippetError.invalidSelection
        }
        return try triggerExpansionPlan(
            trigger: trigger, template: template,
            documentUTF16Length: documentText.utf16.count, cursor: cursor,
            expectedRevision: expectedRevision, limits: limits
        )
    }

    private static func isTriggerCodeUnit(_ unit: UInt16) -> Bool {
        unit == 45 || unit == 95
            || (48...57).contains(unit)
            || (65...90).contains(unit)
            || (97...122).contains(unit)
    }
}
