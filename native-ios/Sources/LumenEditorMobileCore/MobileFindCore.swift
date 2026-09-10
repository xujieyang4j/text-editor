import Foundation

public struct MobileFindOptions: Equatable, Sendable {
    public var isCaseSensitive: Bool
    public var isWholeWord: Bool
    public var usesRegularExpression: Bool

    public init(
        isCaseSensitive: Bool = false,
        isWholeWord: Bool = false,
        usesRegularExpression: Bool = false
    ) {
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
        self.usesRegularExpression = usesRegularExpression
    }
}

public struct MobileFindQuery: Equatable, Sendable {
    public var search: String
    public var replacement: String
    public var options: MobileFindOptions

    public init(
        search: String,
        replacement: String = "",
        options: MobileFindOptions = MobileFindOptions()
    ) {
        self.search = search
        self.replacement = replacement
        self.options = options
    }
}

public enum MobileFindDirection: Equatable, Sendable {
    case next
    case previous
}

public struct MobileFindMatch: Equatable {
    public let range: NSRange
    public let captureRanges: [NSRange?]

    public init(range: NSRange, captureRanges: [NSRange?] = []) {
        self.range = range
        self.captureRanges = captureRanges.isEmpty ? [range] : captureRanges
    }
}

public struct MobileFindScanResult: Equatable {
    public let matches: [MobileFindMatch]
    public let isTruncated: Bool
}

public enum MobileFindError: Error, Equatable, LocalizedError, Sendable {
    case invalidRegularExpression(String)
    case invalidResultLimit
    case zeroWidthReplacement
    case replacementExceedsLimit

    public var errorDescription: String? {
        switch self {
        case let .invalidRegularExpression(message):
            String(
                format: NSLocalizedString("error_invalid_regex", comment: ""), message
            )
        case .invalidResultLimit:
            NSLocalizedString("error_invalid_find_limit", comment: "")
        case .zeroWidthReplacement:
            NSLocalizedString("error_zero_width_replace", comment: "")
        case .replacementExceedsLimit:
            NSLocalizedString("error_replace_output_too_large", comment: "")
        }
    }
}

/// Bounded UTF-16 search primitives shared by the SwiftUI bar and UIKit editor.
public enum MobileFindCore {
    public static let defaultMaximumResults = 10_000

    private enum ReplacementTemplateSegment {
        case literal(NSRange)
        case wholeMatch
        case capture(Int)
    }

    public static func scan(
        _ text: String,
        query: MobileFindQuery,
        limit: Int = defaultMaximumResults,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> MobileFindScanResult {
        guard limit > 0 else { throw MobileFindError.invalidResultLimit }
        guard !query.search.isEmpty else {
            return MobileFindScanResult(matches: [], isTruncated: false)
        }
        let expression = try compiledExpression(for: query)
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var matches: [MobileFindMatch] = []
        var truncated = false
        expression.enumerateMatches(in: text, range: fullRange) { result, _, stop in
            guard !shouldCancel() else {
                stop.pointee = true
                return
            }
            guard let result, result.range.location != NSNotFound,
                  wholeWordAccepts(
                    result.range, in: source, enabled: query.options.isWholeWord
                  ) else { return }
            guard matches.count < limit else {
                truncated = true
                stop.pointee = true
                return
            }
            matches.append(makeMatch(result))
        }
        if shouldCancel() { throw CancellationError() }
        return MobileFindScanResult(matches: matches, isTruncated: truncated)
    }

    public static func match(
        in text: String,
        query: MobileFindQuery,
        selection: NSRange,
        direction: MobileFindDirection,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> MobileFindMatch? {
        let length = (text as NSString).length
        let selection = clamped(selection, to: length)
        let scan = try scan(
            text, query: query, limit: defaultMaximumResults, shouldCancel: shouldCancel
        )
        guard !scan.matches.isEmpty else { return nil }
        switch direction {
        case .next:
            let start = selection.location + selection.length
            return scan.matches.first { $0.range.location >= start && $0.range != selection }
                ?? scan.matches.first { $0.range != selection }
        case .previous:
            return scan.matches.last {
                $0.range.location + $0.range.length <= selection.location && $0.range != selection
            } ?? scan.matches.last { $0.range != selection }
        }
    }

    public static func replacing(
        _ match: MobileFindMatch,
        in text: String,
        query: MobileFindQuery,
        maximumOutputUTF16Length: Int = Int.max
    ) throws -> (text: String, selection: NSRange) {
        guard match.range.length > 0 else { throw MobileFindError.zeroWidthReplacement }
        let source = text as NSString
        guard match.range.location >= 0, match.range.location <= source.length,
              match.range.length <= source.length - match.range.location else {
            return (text, match.range)
        }
        let segments = replacementSegments(
            for: query, captureCount: match.captureRanges.count
        )
        guard let replacementLength = replacementUTF16Length(
                  for: segments, match: match, sourceLength: source.length
              ) else {
            throw MobileFindError.replacementExceedsLimit
        }
        guard let outputLength = MobileWorkspaceCapacity.utf16UnitCount(
                  current: source.length, replacing: match.range.length,
            with: replacementLength
              ),
              outputLength <= max(0, maximumOutputUTF16Length) else {
            throw MobileFindError.replacementExceedsLimit
        }
        let replacement = replacementText(
            from: segments, match: match, source: source,
            template: query.replacement as NSString, capacity: replacementLength
        )
        let result = source.replacingCharacters(in: match.range, with: replacement)
        return (result, NSRange(location: match.range.location, length: replacement.utf16.count))
    }

    public static func replacingAll(
        in text: String,
        query: MobileFindQuery,
        limit: Int = defaultMaximumResults,
        maximumOutputUTF16Length: Int = Int.max,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> (text: String, count: Int) {
        let matches = try scan(
            text, query: query, limit: limit, shouldCancel: shouldCancel
        )
        guard !matches.isTruncated else { throw MobileFindError.invalidResultLimit }
        guard matches.matches.allSatisfy({ $0.range.length > 0 }) else {
            throw MobileFindError.zeroWidthReplacement
        }
        guard !matches.matches.isEmpty else { return (text, 0) }
        let source = text as NSString
        let template = query.replacement as NSString
        let segments = replacementSegments(
            for: query, captureCount: matches.matches[0].captureRanges.count
        )
        var outputLength = source.length
        for match in matches.matches {
            guard match.range.length <= outputLength else {
                throw MobileFindError.replacementExceedsLimit
            }
            outputLength -= match.range.length
        }
        let boundedMaximumOutputUTF16Length = max(0, maximumOutputUTF16Length)
        for match in matches.matches {
            if shouldCancel() { throw CancellationError() }
            guard let replacementLength = replacementUTF16Length(
                      for: segments, match: match, sourceLength: source.length
                  ) else {
                throw MobileFindError.replacementExceedsLimit
            }
            let (nextLength, overflow) = outputLength.addingReportingOverflow(
                replacementLength
            )
            guard !overflow else {
                throw MobileFindError.replacementExceedsLimit
            }
            outputLength = nextLength
            guard outputLength <= boundedMaximumOutputUTF16Length else {
                throw MobileFindError.replacementExceedsLimit
            }
        }
        let output = NSMutableString(capacity: outputLength)
        var cursor = 0
        for match in matches.matches {
            if shouldCancel() { throw CancellationError() }
            output.append(source.substring(with: NSRange(
                location: cursor, length: match.range.location - cursor
            )))
            appendReplacement(
                from: segments, match: match, source: source,
                template: template, to: output
            )
            cursor = NSMaxRange(match.range)
        }
        output.append(source.substring(from: cursor))
        return (output as String, matches.matches.count)
    }

    public static func replacementText(
        for match: MobileFindMatch,
        in text: String,
        query: MobileFindQuery
    ) -> String {
        guard query.options.usesRegularExpression else { return query.replacement }
        let source = text as NSString
        let template = query.replacement as NSString
        let segments = replacementSegments(
            for: query, captureCount: match.captureRanges.count
        )
        let capacity = replacementUTF16Length(
            for: segments, match: match, sourceLength: source.length
        ) ?? 0
        return replacementText(
            from: segments, match: match, source: source, template: template,
            capacity: capacity
        )
    }

    private static func replacementSegments(
        for query: MobileFindQuery,
        captureCount: Int
    ) -> [ReplacementTemplateSegment] {
        let template = query.replacement as NSString
        guard query.options.usesRegularExpression else {
            return template.length == 0
                ? [] : [.literal(NSRange(location: 0, length: template.length))]
        }
        var segments: [ReplacementTemplateSegment] = []
        var literalStart = 0
        var index = 0
        while index < template.length {
            guard template.character(at: index) == 0x24,
                  index + 1 < template.length else {
                index += 1
                continue
            }
            let next = template.character(at: index + 1)
            if next == 0x24 {
                appendLiteral(
                    from: literalStart, to: index, to: &segments
                )
                segments.append(.literal(NSRange(location: index, length: 1)))
                index += 2
                literalStart = index
                continue
            }
            if next == 0x26 {
                appendLiteral(
                    from: literalStart, to: index, to: &segments
                )
                segments.append(.wholeMatch)
                index += 2
                literalStart = index
                continue
            }
            guard next >= 0x30, next <= 0x39 else {
                index += 1
                continue
            }
            var end = index + 1
            var captureValue: Int? = 0
            var captureIndex: Int?
            var acceptedLength = 0
            while end < template.length {
                let digit = template.character(at: end)
                guard digit >= 0x30, digit <= 0x39 else { break }
                if let value = captureValue {
                    let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(
                        by: 10
                    )
                    let (candidate, addOverflow) = multiplied.addingReportingOverflow(
                        Int(digit - 0x30)
                    )
                    if multiplyOverflow || addOverflow {
                        captureValue = nil
                    } else {
                        captureValue = candidate
                        if candidate >= 0, candidate < captureCount {
                            captureIndex = candidate
                            acceptedLength = end - index
                        }
                    }
                }
                end += 1
            }
            guard let captureIndex else {
                index += 1
                continue
            }
            appendLiteral(from: literalStart, to: index, to: &segments)
            segments.append(.capture(captureIndex))
            index += 1 + acceptedLength
            literalStart = index
        }
        appendLiteral(from: literalStart, to: template.length, to: &segments)
        return segments
    }

    private static func appendLiteral(
        from start: Int,
        to end: Int,
        to segments: inout [ReplacementTemplateSegment]
    ) {
        guard end > start else { return }
        segments.append(.literal(NSRange(location: start, length: end - start)))
    }

    private static func replacementUTF16Length(
        for segments: [ReplacementTemplateSegment],
        match: MobileFindMatch,
        sourceLength: Int
    ) -> Int? {
        var length = 0
        for segment in segments {
            switch segment {
            case let .literal(range):
                guard addWithoutOverflow(range.length, to: &length) else { return nil }
            case .wholeMatch:
                if let range = validRange(match.range, within: sourceLength),
                   !addWithoutOverflow(range.length, to: &length) {
                    return nil
                }
            case let .capture(index):
                if let range = captureRange(
                    at: index, in: match, sourceLength: sourceLength
                ), !addWithoutOverflow(range.length, to: &length) {
                    return nil
                }
            }
        }
        return length
    }

    private static func replacementText(
        from segments: [ReplacementTemplateSegment],
        match: MobileFindMatch,
        source: NSString,
        template: NSString,
        capacity: Int
    ) -> String {
        let output = NSMutableString(capacity: max(0, capacity))
        appendReplacement(
            from: segments, match: match, source: source,
            template: template, to: output
        )
        return output as String
    }

    private static func appendReplacement(
        from segments: [ReplacementTemplateSegment],
        match: MobileFindMatch,
        source: NSString,
        template: NSString,
        to output: NSMutableString
    ) {
        for segment in segments {
            switch segment {
            case let .literal(range):
                output.append(template.substring(with: range))
            case .wholeMatch:
                if let range = validRange(match.range, within: source.length) {
                    output.append(source.substring(with: range))
                }
            case let .capture(index):
                if let range = captureRange(
                    at: index, in: match, sourceLength: source.length
                ) {
                    output.append(source.substring(with: range))
                }
            }
        }
    }

    private static func addWithoutOverflow(_ value: Int, to total: inout Int) -> Bool {
        let (result, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { return false }
        total = result
        return true
    }

    private static func compiledExpression(
        for query: MobileFindQuery
    ) throws -> NSRegularExpression {
        let pattern = query.options.usesRegularExpression
            ? query.search : NSRegularExpression.escapedPattern(for: query.search)
        var options: NSRegularExpression.Options = []
        if !query.options.isCaseSensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw MobileFindError.invalidRegularExpression(error.localizedDescription)
        }
    }

    private static func makeMatch(_ result: NSTextCheckingResult) -> MobileFindMatch {
        let captures = (0..<result.numberOfRanges).map { index -> NSRange? in
            let range = result.range(at: index)
            return range.location == NSNotFound ? nil : range
        }
        return MobileFindMatch(range: result.range, captureRanges: captures)
    }

    private static func wholeWordAccepts(
        _ range: NSRange,
        in source: NSString,
        enabled: Bool
    ) -> Bool {
        guard enabled else { return true }
        guard range.length > 0 else { return true }
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

    private static func validRange(_ range: NSRange, within length: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= length,
              range.length <= length - range.location else { return nil }
        return range
    }

    private static func captureRange(
        at index: Int,
        in match: MobileFindMatch,
        sourceLength: Int
    ) -> NSRange? {
        guard match.captureRanges.indices.contains(index),
              let range = match.captureRanges[index] else { return nil }
        return validRange(range, within: sourceLength)
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let available = length - location
        return NSRange(location: location, length: min(max(0, range.length), available))
    }
}
