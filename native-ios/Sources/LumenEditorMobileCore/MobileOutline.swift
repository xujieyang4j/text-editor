import Foundation

public struct MobileOutlineItem: Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let kind: String
    public let location: Int
    public let line: Int
}

/// Fast bounded fallback outline used before a language parser is available.
public enum MobileOutline {
    public static let maximumCharacters = 1_000_000
    public static let maximumItems = 2_000

    public static func items(in text: String) -> [MobileOutlineItem] {
        let source = text as NSString
        let length = min(source.length, maximumCharacters)
        var items: [MobileOutlineItem] = []
        var lineNumber = 1
        var cursor = 0
        while cursor < length, items.count < maximumItems {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let boundedLength = min(lineRange.length, length - lineRange.location)
            let raw = source.substring(with: NSRange(location: lineRange.location, length: boundedLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parse(raw) {
                items.append(MobileOutlineItem(
                    id: lineRange.location, title: parsed.title, kind: parsed.kind,
                    location: lineRange.location, line: lineNumber
                ))
            }
            cursor = max(cursor + 1, NSMaxRange(lineRange))
            lineNumber += 1
        }
        return items
    }

    private static func parse(_ line: String) -> (title: String, kind: String)? {
        if line.hasPrefix("#") {
            let title = line.drop { $0 == "#" || $0 == " " }
            return title.isEmpty ? nil : (String(title), "heading")
        }
        let prefixes = ["func ", "function ", "class ", "struct ", "enum ", "interface ", "def "]
        for prefix in prefixes where line.hasPrefix(prefix) {
            let remainder = line.dropFirst(prefix.count)
            let name = remainder.prefix { character in
                character.isLetter || character.isNumber || character == "_" || character == "$"
            }
            if !name.isEmpty { return (String(name), prefix.trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }
}
