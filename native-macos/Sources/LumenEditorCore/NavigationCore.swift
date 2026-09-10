import Foundation

public struct NavigationFuzzyMatch: Equatable, Sendable {
    public let score: Double
    /// UTF-16 offsets, matching NSTextView and the Electron implementation.
    public let matches: [Int]

    public init(score: Double, matches: [Int]) {
        self.score = score
        self.matches = matches
    }
}
public enum NavigationFuzzyMatcher {
    /// Subsequence matcher kept byte-for-byte equivalent in scoring policy to
    /// `src/renderer/src/fuzzy.ts`.
    public static func score(query: String, text: String) -> NavigationFuzzyMatch? {
        let original = Array(text.utf16)
        let queryUnits = asciiLowercasedUTF16(query)
        let textUnits = asciiLowercasedUTF16(text)
        if queryUnits.isEmpty { return NavigationFuzzyMatch(score: 1, matches: []) }
        guard queryUnits.count <= original.count else { return nil }

        var queryIndex = 0
        var textIndex = 0
        var total = 0.0
        var consecutive = 0
        var matches: [Int] = []

        while queryIndex < queryUnits.count, textIndex < textUnits.count {
            if queryUnits[queryIndex] == textUnits[textIndex] {
                matches.append(textIndex)
                var bonus = 10.0 + Double(consecutive * 5)
                if textIndex == 0 {
                    bonus += 15
                } else if isBoundary(textUnits[textIndex - 1]) {
                    bonus += 10
                } else if textIndex < original.count, isASCIIUppercase(original[textIndex]) {
                    bonus += 8
                }
                total += bonus
                consecutive += 1
                queryIndex += 1
            } else {
                total -= 1
                consecutive = 0
            }
            textIndex += 1
        }

        guard queryIndex == queryUnits.count else { return nil }
        total -= Double(textUnits.count) * 0.1
        return NavigationFuzzyMatch(score: total, matches: matches)
    }

    public static func filter<Element>(
        query: String,
        items: [Element],
        key: (Element) -> String
    ) -> [(item: Element, result: NavigationFuzzyMatch)] {
        var ranked: [(index: Int, item: Element, result: NavigationFuzzyMatch)] = []
        ranked.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let result = score(query: query, text: key(item)) else { continue }
            ranked.append((index: index, item: item, result: result))
        }
        ranked.sort { left, right in
            left.2.score == right.2.score ? left.0 < right.0 : left.2.score > right.2.score
        }
        return ranked.map { ($0.item, $0.result) }
    }

    private static func isBoundary(_ unit: UInt16) -> Bool {
        unit == 0x2f || unit == 0x5c || unit == 0x5f || unit == 0x2d
            || unit == 0x2e || unit == 0x20
    }

    private static func isASCIIUppercase(_ unit: UInt16) -> Bool {
        (0x41...0x5a).contains(unit)
    }

    private static func asciiLowercasedUTF16(_ value: String) -> [UInt16] {
        Array(value.utf16).map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }
    }
}

public struct DocumentSymbol: Equatable, Sendable {
    public let label: String
    /// UTF-16 offset of the physical line start.
    public let position: Int
    public let line: Int

    public init(label: String, position: Int, line: Int) {
        self.label = label
        self.position = position
        self.line = line
    }
}

public enum SymbolExtractor {
    private static let patterns: [NSRegularExpression] = [
        #"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)"#,
        #"^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)"#,
        #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s*)?\(?[^=]*\)?\s*=>"#,
        #"^\s*(?:public|private|protected|static|\s)*([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^)]*\)\s*\{"#,
        #"^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        #"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        #"^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)"#,
        #"^\s*(?:pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        #"^(#{1,6})\s+(.*)$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func extract(from text: String) -> [DocumentSymbol] {
        let lines = text.components(separatedBy: "\n")
        var result: [DocumentSymbol] = []
        var offset = 0

        for (index, line) in lines.enumerated() {
            let source = line as NSString
            let range = NSRange(location: 0, length: source.length)
            for expression in patterns {
                guard let match = expression.firstMatch(in: line, range: range) else { continue }
                let label: String
                if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                    let hashes = source.substring(with: match.range(at: 1))
                    let heading = source.substring(with: match.range(at: 2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    label = "\(String(repeating: "#", count: hashes.utf16.count)) \(heading)"
                } else {
                    label = source.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                result.append(DocumentSymbol(label: label, position: offset, line: index + 1))
                break
            }
            offset += source.length + 1
        }
        return result
    }
}

public struct GotoLineLocation: Equatable, Sendable {
    public let line: Int
    public let column: Int
}

public enum GotoLineResolver {
    private static let expression = try? NSRegularExpression(
        pattern: #"^([+-])?(\d+)(?::(\d+))?(%)?$"#
    )

    public static func resolve(
        _ input: String,
        currentLine: Int,
        totalLines: Int
    ) -> GotoLineLocation? {
        guard totalLines >= 1, let expression else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed as NSString
        let range = NSRange(location: 0, length: source.length)
        guard let match = expression.firstMatch(in: trimmed, range: range),
              let amount = integerCapture(2, match: match, source: source) else { return nil }
        let column = integerCapture(3, match: match, source: source) ?? 1
        guard column >= 1 else { return nil }

        let sign = stringCapture(1, match: match, source: source)
        let percentage = stringCapture(4, match: match, source: source) != nil
        let target: Int
        if percentage {
            let absolute = Double(totalLines) * Double(amount) / 100
            let signed = sign == "-" ? -absolute : absolute
            let rounded = clampedRoundedInteger(signed)
            target = sign == nil ? rounded : clampedAdd(currentLine, rounded)
        } else {
            let signed = sign == "-" ? -amount : amount
            target = sign == nil ? amount : clampedAdd(currentLine, signed)
        }
        return GotoLineLocation(
            line: min(totalLines, max(1, target)),
            column: column
        )
    }

    private static func stringCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        source: NSString
    ) -> String? {
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : source.substring(with: range)
    }

    private static func integerCapture(
        _ index: Int,
        match: NSTextCheckingResult,
        source: NSString
    ) -> Int? {
        stringCapture(index, match: match, source: source).flatMap(Int.init)
    }

    /// JavaScript's Math.round rounds ties toward positive infinity. Clamp
    /// before converting so an enormous percentage cannot trap Swift's Int.
    private static func clampedRoundedInteger(_ value: Double) -> Int {
        let rounded = floor(value + 0.5)
        if !rounded.isFinite { return rounded.sign == .minus ? Int.min : Int.max }
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    private static func clampedAdd(_ left: Int, _ right: Int) -> Int {
        let result = left.addingReportingOverflow(right)
        guard result.overflow else { return result.partialValue }
        return right >= 0 ? Int.max : Int.min
    }
}

public struct NavigationLocation: Equatable, Sendable {
    public let documentID: String
    public let path: String?
    public let groupID: Int
    public let line: Int
    public let column: Int

    public init(documentID: String, path: String?, groupID: Int, line: Int, column: Int) {
        self.documentID = documentID
        self.path = path
        self.groupID = groupID
        self.line = line
        self.column = column
    }

    public func isSameSemanticPosition(as other: NavigationLocation) -> Bool {
        documentID == other.documentID && groupID == other.groupID
            && line == other.line && column == other.column
    }
}

public enum NavigationDirection: Equatable, Sendable {
    case back
    case forward
}

public struct NavigationTraversal: Equatable, Sendable {
    fileprivate let token: UUID
    public let direction: NavigationDirection
    public let target: NavigationLocation

    public static func == (left: NavigationTraversal, right: NavigationTraversal) -> Bool {
        left.direction == right.direction && left.target == right.target
    }
}

public enum NavigationHistoryError: Error, Equatable {
    case invalidCapacity
}

/// Main-thread coordinator used by command routing.
@MainActor
public final class NavigationIntentEpoch {
    public private(set) var current = 0
    public init() {}
    @discardableResult public func begin() -> Int { current += 1; return current }
    public func isCurrent(_ snapshot: Int) -> Bool { snapshot == current }
}

/// Main-thread history used by a window's navigation controller.
@MainActor
public final class NavigationHistory {
    public static let maximumCapacity = 100

    private struct Prepared {
        let direction: NavigationDirection
        let target: NavigationLocation
        let revision: Int
    }

    public private(set) var backEntries: [NavigationLocation] = []
    public private(set) var forwardEntries: [NavigationLocation] = []
    private var prepared: [UUID: Prepared] = [:]
    private var revision = 0
    private let capacity: Int

    public init() { capacity = Self.maximumCapacity }

    public init(capacity: Int) throws {
        guard (1...Self.maximumCapacity).contains(capacity) else {
            throw NavigationHistoryError.invalidCapacity
        }
        self.capacity = capacity
    }

    public var canGoBack: Bool { !backEntries.isEmpty }
    public var canGoForward: Bool { !forwardEntries.isEmpty }

    public func recordSuccessfulJump(
        source: NavigationLocation?,
        target: NavigationLocation?
    ) {
        guard let source, let target, !source.isSameSemanticPosition(as: target) else { return }
        Self.pushUnique(source, onto: &backEntries, capacity: capacity)
        forwardEntries.removeAll(keepingCapacity: true)
        revision += 1
        prepared.removeAll(keepingCapacity: true)
    }

    public func prepareTraversal(_ direction: NavigationDirection) -> NavigationTraversal? {
        let target = direction == .back ? backEntries.last : forwardEntries.last
        guard let target else { return nil }
        let token = UUID()
        prepared[token] = Prepared(direction: direction, target: target, revision: revision)
        return NavigationTraversal(token: token, direction: direction, target: target)
    }

    @discardableResult
    public func commitTraversal(
        _ traversal: NavigationTraversal,
        current: NavigationLocation?
    ) -> Bool {
        guard let item = prepared.removeValue(forKey: traversal.token),
              item.revision == revision, item.direction == traversal.direction,
              item.target.isSameSemanticPosition(as: traversal.target) else { return false }
        let next = item.direction == .back ? backEntries.last : forwardEntries.last
        guard let next, next.isSameSemanticPosition(as: item.target) else { return false }

        if item.direction == .back {
            backEntries.removeLast()
            if let current, !current.isSameSemanticPosition(as: item.target) {
                Self.pushUnique(current, onto: &forwardEntries, capacity: capacity)
            }
        } else {
            forwardEntries.removeLast()
            if let current, !current.isSameSemanticPosition(as: item.target) {
                Self.pushUnique(current, onto: &backEntries, capacity: capacity)
            }
        }
        revision += 1
        prepared.removeAll(keepingCapacity: true)
        return true
    }

    public func updateDocumentPath(documentID: String, path: String?) {
        rewrite { location in
            location.documentID == documentID
                ? NavigationLocation(
                    documentID: location.documentID, path: path, groupID: location.groupID,
                    line: location.line, column: location.column
                )
                : location
        }
    }

    public func rewritePathPrefix(source: String, target: String) {
        rewrite { location in
            guard let path = location.path, Self.isPath(path, within: source) else { return location }
            let nextPath = path == source
                ? target
                : target + String(path.dropFirst(source.count))
            return NavigationLocation(
                documentID: location.documentID, path: nextPath, groupID: location.groupID,
                line: location.line, column: location.column
            )
        }
    }

    public func removeDocument(documentID: String) {
        filter { $0.documentID != documentID }
    }

    public func removePathPrefix(_ path: String) {
        filter { $0.path.map { !Self.isPath($0, within: path) } ?? true }
    }

    private static func pushUnique(
        _ location: NavigationLocation,
        onto stack: inout [NavigationLocation],
        capacity: Int
    ) {
        if stack.last?.isSameSemanticPosition(as: location) == true { return }
        stack.append(location)
        if stack.count > capacity { stack.removeFirst() }
    }

    private func rewrite(_ transform: (NavigationLocation) -> NavigationLocation) {
        var changed = false
        backEntries = backEntries.map { location in
            let next = transform(location); changed = changed || next != location; return next
        }
        forwardEntries = forwardEntries.map { location in
            let next = transform(location); changed = changed || next != location; return next
        }
        if changed {
            revision += 1
            prepared.removeAll(keepingCapacity: true)
        }
    }

    private func filter(_ keep: (NavigationLocation) -> Bool) {
        let oldBack = backEntries.count
        let oldForward = forwardEntries.count
        backEntries.removeAll { !keep($0) }
        forwardEntries.removeAll { !keep($0) }
        if oldBack != backEntries.count || oldForward != forwardEntries.count {
            revision += 1
            prepared.removeAll(keepingCapacity: true)
        }
    }

    private static func isPath(_ candidate: String, within parent: String) -> Bool {
        if parent == "/" { return candidate.hasPrefix("/") }
        return candidate == parent || candidate.hasPrefix(parent + "/")
            || candidate.hasPrefix(parent + "\\")
    }
}
