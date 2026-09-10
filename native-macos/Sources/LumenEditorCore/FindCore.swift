import Foundation

/// Options shared by the native current-document find bar and its shell routes.
/// All positions produced by this file are UTF-16 offsets, matching AppKit and
/// the Electron/CodeMirror implementation.
public struct FindOptions: Equatable, Sendable {
    public var isCaseSensitive: Bool
    public var isWholeWord: Bool
    public var usesRegularExpression: Bool
    /// CodeMirror unquotes `\n`, `\r`, `\t`, and `\\` in both search and
    /// replacement fields. Set this only for callers that need verbatim input.
    public var isVerbatim: Bool

    public init(
        isCaseSensitive: Bool = false,
        isWholeWord: Bool = false,
        usesRegularExpression: Bool = false,
        isVerbatim: Bool = false
    ) {
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
        self.usesRegularExpression = usesRegularExpression
        self.isVerbatim = isVerbatim
    }
}

public struct FindQuery: Equatable, Sendable {
    public var search: String
    public var replacement: String
    public var options: FindOptions

    public init(
        search: String,
        replacement: String = "",
        options: FindOptions = FindOptions()
    ) {
        self.search = search
        self.replacement = replacement
        self.options = options
    }
}

public enum FindDirection: Equatable, Sendable {
    case next
    case previous
}

public struct FindMatch: Equatable, Sendable {
    public let range: NSRange
    /// Capture zero is the complete regular-expression match. Literal matches
    /// contain only capture zero. Missing optional captures are represented by nil.
    public let captureRanges: [NSRange?]

    public init(range: NSRange, captureRanges: [NSRange?] = []) {
        self.range = range
        self.captureRanges = captureRanges.isEmpty ? [range] : captureRanges
    }

    public var lowerBound: Int { range.location }
    public var upperBound: Int {
        let sum = range.location.addingReportingOverflow(range.length)
        return sum.overflow ? Int.max : sum.partialValue
    }
    public var isEmpty: Bool { range.length == 0 }
}

public struct FindScanResult: Equatable, Sendable {
    public let matches: [FindMatch]
    public let isTruncated: Bool

    public init(matches: [FindMatch], isTruncated: Bool) {
        self.matches = matches
        self.isTruncated = isTruncated
    }
}

public struct FindReplacement: Equatable, Sendable {
    public let match: FindMatch
    public let replacement: String

    public init(match: FindMatch, replacement: String) {
        self.match = match
        self.replacement = replacement
    }
}

public enum FindCoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidRegularExpression(String)
    case invalidResultLimit

    public var errorDescription: String? {
        switch self {
        case let .invalidRegularExpression(message):
            return "Invalid regular expression: \(message)"
        case .invalidResultLimit:
            return "The find result limit must be greater than zero."
        }
    }
}

/// Pure, bounded current-document search and replacement primitives.
public enum FindCore {
    public static let defaultMaximumResults = 10_000

    /// Returns non-overlapping matches in document order. The result is marked
    /// truncated as soon as one match beyond `limit` exists.
    public static func scan(
        _ text: String,
        query: FindQuery,
        limit: Int = defaultMaximumResults
    ) throws -> FindScanResult {
        guard limit > 0 else { throw FindCoreError.invalidResultLimit }
        let effectiveSearch = query.options.usesRegularExpression || query.options.isVerbatim
            ? query.search : unquoted(query.search)
        guard !effectiveSearch.isEmpty else {
            return FindScanResult(matches: [], isTruncated: false)
        }
        let expression = try compiledExpression(for: query)
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var matches: [FindMatch] = []
        matches.reserveCapacity(min(limit, 256))
        var truncated = false

        expression.enumerateMatches(in: text, range: fullRange) { result, _, stop in
            guard let result, result.range.location != NSNotFound,
                  wholeWordAccepts(result.range, in: source, enabled: query.options.isWholeWord)
            else { return }
            if matches.count == limit {
                truncated = true
                stop.pointee = true
                return
            }
            matches.append(makeMatch(result))
        }
        return FindScanResult(matches: matches, isTruncated: truncated)
    }

    public static func matches(
        in text: String,
        query: FindQuery,
        limit: Int = defaultMaximumResults
    ) throws -> [FindMatch] {
        try scan(text, query: query, limit: limit).matches
    }

    /// Finds relative to a UTF-16 selection and wraps at document boundaries.
    /// The current exact match is skipped, as CodeMirror's Find Next/Previous do.
    public static func match(
        in text: String,
        query: FindQuery,
        selection: NSRange,
        direction: FindDirection
    ) throws -> FindMatch? {
        let effectiveSearch = query.options.usesRegularExpression || query.options.isVerbatim
            ? query.search : unquoted(query.search)
        guard !effectiveSearch.isEmpty else { return nil }
        let sourceLength = (text as NSString).length
        let safeSelection = clamped(selection, to: sourceLength)
        let all = try scan(
            text,
            query: query,
            limit: completeLimit(forUTF16Length: sourceLength)
        ).matches
        guard !all.isEmpty else { return nil }

        switch direction {
        case .next:
            let start = safeSelection.location + safeSelection.length
            if let found = all.first(where: { $0.lowerBound >= start }),
               found.range != safeSelection { return found }
            return all.first(where: { $0.range != safeSelection })
        case .previous:
            if let found = all.last(where: { $0.upperBound <= safeSelection.location }) {
                if found.range != safeSelection { return found }
            }
            return all.last(where: { $0.range != safeSelection })
        }
    }

    public static func nextMatch(
        in text: String,
        query: FindQuery,
        selection: NSRange
    ) throws -> FindMatch? {
        try match(in: text, query: query, selection: selection, direction: .next)
    }

    public static func previousMatch(
        in text: String,
        query: FindQuery,
        selection: NSRange
    ) throws -> FindMatch? {
        try match(in: text, query: query, selection: selection, direction: .previous)
    }

    /// Expands a replacement using CodeMirror's `$&`, `$$`, and `$1...` rules.
    public static func replacementText(
        for match: FindMatch,
        in text: String,
        query: FindQuery
    ) -> String {
        let replacement = query.options.isVerbatim
            ? query.replacement : unquoted(query.replacement)
        guard query.options.usesRegularExpression else { return replacement }
        let source = text as NSString
        let units = Array(replacement.utf16)
        let result = NSMutableString(string: "")
        var literalStart = 0
        var index = 0

        func appendLiteral(_ from: Int, _ to: Int) {
            guard to > from else { return }
            result.append((replacement as NSString).substring(
                with: NSRange(location: from, length: to - from)
            ))
        }

        while index + 1 < units.count {
            guard units[index] == 0x24 else { index += 1; continue } // $
            let marker = units[index + 1]
            if marker == 0x24 || marker == 0x26 { // $ or &
                appendLiteral(literalStart, index)
                if marker == 0x24 {
                    result.append("$")
                } else {
                    result.append(substring(source, range: match.range) ?? "")
                }
                index += 2
                literalStart = index
                continue
            }
            guard (0x30...0x39).contains(marker) else { index += 1; continue }
            var end = index + 1
            while end < units.count, (0x30...0x39).contains(units[end]) { end += 1 }
            let digits = String(decoding: units[(index + 1)..<end], as: UTF16.self)
            var captureLength = digits.utf16.count
            var captureIndex: Int?
            while captureLength > 0 {
                let prefix = String(decoding: digits.utf16.prefix(captureLength), as: UTF16.self)
                if let candidate = Int(prefix), candidate > 0,
                   candidate < match.captureRanges.count {
                    captureIndex = candidate
                    break
                }
                captureLength -= 1
            }
            guard let captureIndex else { index += 1; continue }
            appendLiteral(literalStart, index)
            if let range = match.captureRanges[captureIndex],
               let captured = substring(source, range: range) {
                result.append(captured)
            }
            let suffixStart = index + 1 + captureLength
            appendLiteral(suffixStart, end)
            index = end
            literalStart = end
        }
        appendLiteral(literalStart, units.count)
        return result as String
    }

    public static func replacement(
        for match: FindMatch,
        in text: String,
        query: FindQuery
    ) -> FindReplacement {
        FindReplacement(
            match: match,
            replacement: replacementText(for: match, in: text, query: query)
        )
    }

    public static func replacements(
        in text: String,
        query: FindQuery,
        limit: Int = defaultMaximumResults
    ) throws -> [FindReplacement] {
        try scan(text, query: query, limit: limit).matches.map {
            replacement(for: $0, in: text, query: query)
        }
    }

    private static func compiledExpression(for query: FindQuery) throws -> NSRegularExpression {
        let pattern: String
        if query.options.usesRegularExpression {
            pattern = query.search
        } else {
            let literal = query.options.isVerbatim ? query.search : unquoted(query.search)
            pattern = NSRegularExpression.escapedPattern(for: literal)
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.options.isCaseSensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw FindCoreError.invalidRegularExpression(error.localizedDescription)
        }
    }

    private static func makeMatch(_ result: NSTextCheckingResult) -> FindMatch {
        let captures = (0..<result.numberOfRanges).map { index -> NSRange? in
            let range = result.range(at: index)
            return range.location == NSNotFound ? nil : range
        }
        return FindMatch(range: result.range, captureRanges: captures)
    }

    private static func unquoted(_ value: String) -> String {
        let source = value as NSString
        let units = Array(value.utf16)
        let result = NSMutableString(string: "")
        var literalStart = 0
        var index = 0
        while index + 1 < units.count {
            guard units[index] == 0x5c else { index += 1; continue } // backslash
            let replacement: String?
            switch units[index + 1] {
            case 0x6e: replacement = "\n"
            case 0x72: replacement = "\r"
            case 0x74: replacement = "\t"
            case 0x5c: replacement = "\\"
            default: replacement = nil
            }
            guard let replacement else { index += 1; continue }
            if index > literalStart {
                result.append(source.substring(with: NSRange(
                    location: literalStart, length: index - literalStart
                )))
            }
            result.append(replacement)
            index += 2
            literalStart = index
        }
        if literalStart < units.count {
            result.append(source.substring(with: NSRange(
                location: literalStart, length: units.count - literalStart
            )))
        }
        return result as String
    }

    private static func wholeWordAccepts(
        _ range: NSRange,
        in source: NSString,
        enabled: Bool
    ) -> Bool {
        guard enabled, range.length > 0 else { return true }
        // CodeMirror only requires a boundary on a side when the matched
        // character on that side is itself a word character. This means a
        // punctuation-only query can still match next to an identifier.
        let startsWithWord = wordCharacter(at: range.location, in: source)
        let endsWithWord = wordCharacter(before: NSMaxRange(range), in: source)
        return !(startsWithWord && wordCharacter(before: range.location, in: source))
            && !(endsWithWord && wordCharacter(at: NSMaxRange(range), in: source))
    }

    private static func wordCharacter(before offset: Int, in source: NSString) -> Bool {
        guard offset > 0 else { return false }
        let range = source.rangeOfComposedCharacterSequence(at: offset - 1)
        return containsWordCharacter(source.substring(with: range))
    }

    private static func wordCharacter(at offset: Int, in source: NSString) -> Bool {
        guard offset < source.length else { return false }
        let range = source.rangeOfComposedCharacterSequence(at: offset)
        return containsWordCharacter(source.substring(with: range))
    }

    private static func containsWordCharacter(_ value: String) -> Bool {
        value == "_" || value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter, .decimalNumber,
                 .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }
    }

    private static func substring(_ source: NSString, range: NSRange) -> String? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= source.length, range.length <= source.length - range.location
        else { return nil }
        return source.substring(with: range)
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let start = min(length, max(0, range.location))
        let rawEnd = range.length > Int.max - max(0, range.location)
            ? Int.max : max(0, range.location) + max(0, range.length)
        let end = min(length, max(start, rawEnd))
        return NSRange(location: start, length: end - start)
    }

    private static func completeLimit(forUTF16Length length: Int) -> Int {
        length == Int.max ? Int.max : max(defaultMaximumResults, length + 1)
    }
}
