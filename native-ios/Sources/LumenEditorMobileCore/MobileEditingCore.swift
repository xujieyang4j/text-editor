import Foundation

public struct MobileEditResult: Equatable {
    public let text: String
    public let selection: NSRange

    public init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
}

public struct MobileCursorStatus: Equatable, Sendable {
    public let line: Int?
    public let column: Int?
    public let utf16Offset: Int
    public let selectionLength: Int

    public init(
        line: Int?, column: Int?, utf16Offset: Int, selectionLength: Int
    ) {
        self.line = line
        self.column = column
        self.utf16Offset = utf16Offset
        self.selectionLength = selectionLength
    }
}

/// Mobile editing transformations operate in UTF-16 offsets because UIKit's
/// selectedRange and the shared find core use the same coordinate system.
public enum MobileEditingCore {
    public static func cursorStatus(
        in text: String,
        selection: NSRange,
        maximumScannedUTF16Length: Int = 50_000,
        knownUTF16Length: Int? = nil
    ) -> MobileCursorStatus {
        let limit = max(0, maximumScannedUTF16Length)
        if let knownUTF16Length, knownUTF16Length > limit {
            return MobileCursorStatus(
                line: nil, column: nil, utf16Offset: max(0, selection.location),
                selectionLength: max(0, selection.length)
            )
        }
        let source = text as NSString
        let range = clamped(selection, to: source.length)
        guard source.length <= limit else {
            return MobileCursorStatus(
                line: nil, column: nil, utf16Offset: range.location,
                selectionLength: range.length
            )
        }
        var line = 1
        var lineStart = 0
        if range.location > 0 {
            for offset in 0..<range.location where source.character(at: offset) == 10 {
                line += 1
                lineStart = offset + 1
            }
        }
        return MobileCursorStatus(
            line: line, column: range.location - lineStart + 1,
            utf16Offset: range.location, selectionLength: range.length
        )
    }

    public static func indent(
        _ text: String, selection: NSRange, unit: String = "    "
    ) -> MobileEditResult {
        guard !unit.isEmpty else { return unchanged(text, selection: selection) }
        let source = text as NSString
        let selection = clamped(selection, to: source.length)
        if selection.length == 0 {
            let output = NSMutableString(string: text)
            output.insert(unit, at: selection.location)
            return MobileEditResult(
                text: output as String,
                selection: NSRange(
                    location: selection.location + (unit as NSString).length, length: 0
                )
            )
        }

        let starts = selectedLineStarts(in: source, selection: selection)
        let unitLength = (unit as NSString).length
        let output = NSMutableString(string: text)
        for start in starts.reversed() { output.insert(unit, at: start) }
        let insertedBeforeStart = starts.filter { $0 < selection.location }.count * unitLength
        return MobileEditResult(
            text: output as String,
            selection: NSRange(
                location: selection.location + insertedBeforeStart,
                length: selection.length + starts.count * unitLength - insertedBeforeStart
            )
        )
    }

    public static func outdent(
        _ text: String, selection: NSRange, tabWidth: Int = 4
    ) -> MobileEditResult {
        let source = text as NSString
        let selection = clamped(selection, to: source.length)
        let starts = selectedLineStarts(in: source, selection: selection)
        var removals: [(location: Int, length: Int)] = []
        for start in starts {
            let available = source.length - start
            guard available > 0 else { continue }
            if source.character(at: start) == 9 {
                removals.append((start, 1))
                continue
            }
            var spaces = 0
            while spaces < min(max(tabWidth, 0), available),
                  source.character(at: start + spaces) == 32 {
                spaces += 1
            }
            if spaces > 0 { removals.append((start, spaces)) }
        }
        guard !removals.isEmpty else { return MobileEditResult(text: text, selection: selection) }

        let output = NSMutableString(string: text)
        for removal in removals.reversed() {
            output.deleteCharacters(in: NSRange(location: removal.location, length: removal.length))
        }
        let removedBeforeStart = removals.reduce(0) { partial, removal in
            partial + removedLength(
                by: removal, before: selection.location
            )
        }
        let selectionEnd = NSMaxRange(selection)
        let removedBeforeEnd = removals.reduce(0) { partial, removal in
            partial + removedLength(by: removal, before: selectionEnd)
        }
        let location = selection.location - removedBeforeStart
        let end = selectionEnd - removedBeforeEnd
        return MobileEditResult(
            text: output as String,
            selection: NSRange(location: location, length: max(0, end - location))
        )
    }

    public static func duplicateLines(_ text: String, selection: NSRange) -> MobileEditResult {
        let source = text as NSString
        let selection = clamped(selection, to: source.length)
        let block = selectedLineBlock(in: source, selection: selection)
        let original = source.substring(with: block)
        let output = NSMutableString(string: text)

        if block.location + block.length < source.length || original.hasSuffix("\n") {
            output.insert(original, at: NSMaxRange(block))
            let relativeLocation = selection.location - block.location
            return MobileEditResult(
                text: output as String,
                selection: NSRange(
                    location: NSMaxRange(block) + relativeLocation, length: selection.length
                )
            )
        }

        let separator = source.length == 0 ? "" : "\n"
        output.append(separator + original)
        let relativeLocation = selection.location - block.location
        return MobileEditResult(
            text: output as String,
            selection: NSRange(
                location: NSMaxRange(block) + (separator as NSString).length + relativeLocation,
                length: selection.length
            )
        )
    }

    private static func selectedLineStarts(in source: NSString, selection: NSRange) -> [Int] {
        let block = selectedLineBlock(in: source, selection: selection)
        var starts = [block.location]
        guard block.length > 0 else { return starts }
        let upperBound = NSMaxRange(block)
        var offset = block.location
        while offset < upperBound {
            if source.character(at: offset) == 10, offset + 1 < upperBound {
                starts.append(offset + 1)
            }
            offset += 1
        }
        return starts
    }

    private static func selectedLineBlock(in source: NSString, selection: NSRange) -> NSRange {
        let range = clamped(selection, to: source.length)
        var start = range.location
        while start > 0, source.character(at: start - 1) != 10 { start -= 1 }

        var probe = NSMaxRange(range)
        if range.length > 0, probe > start, probe <= source.length,
           source.character(at: probe - 1) == 10 {
            probe -= 1
        }
        var end = probe
        while end < source.length, source.character(at: end) != 10 { end += 1 }
        if end < source.length { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func removedLength(
        by removal: (location: Int, length: Int), before offset: Int
    ) -> Int {
        guard removal.location < offset else { return 0 }
        return min(removal.length, offset - removal.location)
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location, length: min(max(0, range.length), length - location)
        )
    }

    private static func unchanged(_ text: String, selection: NSRange) -> MobileEditResult {
        MobileEditResult(
            text: text, selection: clamped(selection, to: (text as NSString).length)
        )
    }
}
