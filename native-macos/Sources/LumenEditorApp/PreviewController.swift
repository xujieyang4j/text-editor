import Combine
import Foundation
import LumenEditorCore
#if canImport(AppKit)
import AppKit
#endif

enum DocumentPreviewMode: Equatable, Sendable {
    case hidden
    case markdown
    case json
}

struct DocumentPreviewIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case invalidJSON
        case resourceLimit
        case unexpected
        case transactionCreation
        case transactionRejected
    }

    let kind: Kind
    let content: AppPresentationText

    /// Stable English text retained for controller diagnostics and existing
    /// non-view callers. UI resolves `content` with its current runtime locale.
    var message: String { EditorLocale.enUS.localizedPresentation(content) }
    var id: String { "\(kind.rawValue):\(content)" }

    init(kind: Kind, content: AppPresentationText) {
        self.kind = kind
        self.content = content
    }

    init(kind: Kind, appCopy: AppLocalizedCopy) {
        self.kind = kind
        content = .app(appCopy)
    }

    init(kind: Kind, verbatim message: String) {
        self.kind = kind
        content = .verbatim(message)
    }
}

/// The exact editor state from which a JSON tree was rendered. JSON tree
/// mutations retain this identity and revision until their single transaction
/// is committed, preventing a delayed sheet from editing a newly selected tab.
struct JSONEditorDocumentSnapshot: Equatable, Sendable {
    let documentID: String
    let source: String
    let revision: UInt64
}

struct JSONEditingIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case unavailable
        case invalidValue
        case invalidObjectKey
        case duplicateObjectKey
        case pathUnavailable
        case resourceLimit
        case documentChanged
        case transactionCreation
        case transactionRejected
        case unexpected
    }

    let kind: Kind
    let content: AppPresentationText

    /// Stable English text retained for controller diagnostics and existing
    /// non-view callers. UI resolves `content` with its current runtime locale.
    var message: String { EditorLocale.enUS.localizedPresentation(content) }
    var id: String { "\(kind.rawValue):\(content)" }

    init(kind: Kind, content: AppPresentationText) {
        self.kind = kind
        self.content = content
    }

    init(kind: Kind, appCopy: AppLocalizedCopy) {
        self.kind = kind
        content = .app(appCopy)
    }

    init(kind: Kind, verbatim message: String) {
        self.kind = kind
        content = .verbatim(message)
    }
}

/// Schemes accepted by links in the native Markdown preview.
///
/// Relative URLs, file URLs, application URLs, and URLs without a host are
/// deliberately rejected. The same policy is checked both while rendering and
/// immediately before the injected opener is called.
enum PreviewURLPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Validates the unparsed spelling first so Foundation cannot normalize an
    /// invalid percent escape before policy enforcement.
    static func urlIfAllowed(_ raw: String) -> URL? {
        guard hasValidPercentEscapes(raw),
              !containsControlCharacters(raw),
              let url = URL(string: raw),
              isAllowed(url) else {
            return nil
        }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        let absolute = url.absoluteString
        guard hasValidPercentEscapes(absolute),
              let decoded = absolute.removingPercentEncoding,
              !containsControlCharacters(absolute),
              !containsControlCharacters(decoded),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            return false
        }

        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false
        case "mailto":
            let decodedPayload = String(decoded.dropFirst("mailto:".count))
            guard !decodedPayload.hasPrefix("//") else { return false }
            let recipient = String(decodedPayload.split(
                separator: "?",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0])
            return !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let characters = Array(value.utf8)
        var index = 0
        while index < characters.count {
            guard characters[index] == 0x25 else {
                index += 1
                continue
            }
            guard index + 2 < characters.count,
                  isHexadecimal(characters[index + 1]),
                  isHexadecimal(characters[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isHexadecimal(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x46).contains(byte)
            || (0x61 ... 0x66).contains(byte)
    }
}

struct SafeMarkdownDocument {
    let blocks: [SafeMarkdownBlock]
    let links: [URL]

    static let empty = SafeMarkdownDocument(blocks: [], links: [])

    var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }
}

enum SafeMarkdownTaskState: Equatable, Sendable {
    case checked
    case unchecked
}

struct SafeMarkdownTableCell {
    let content: AttributedString
    let plainText: String
}

struct SafeMarkdownTableRow {
    let cells: [SafeMarkdownTableCell]
}

struct SafeMarkdownTable {
    let header: SafeMarkdownTableRow
    let rows: [SafeMarkdownTableRow]
}

struct SafeMarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case code(language: String?)
        case blockQuote
        case unorderedListItem(depth: Int, task: SafeMarkdownTaskState?)
        case orderedListItem(number: Int, depth: Int, task: SafeMarkdownTaskState?)
        case thematicBreak
        case table
    }

    let id: Int
    let kind: Kind
    let content: AttributedString
    let plainText: String
    let table: SafeMarkdownTable?
}

/// A bounded, intentionally non-HTML Markdown renderer.
///
/// It recognizes the common block and inline forms used by the Electron
/// preview while keeping all rendering native. Images are represented as safe
/// labelled links and are never fetched. Raw HTML-looking lines bypass the
/// inline parser, so an attribute containing Markdown-looking text cannot
/// manufacture a link.
enum SafeMarkdownRenderer {
    static let hardMaximumBlocks = 10_000
    static let defaultMaximumBlocks = hardMaximumBlocks

    struct LimitError: Error, Equatable, LocalizedError {
        let maximumBlocks: Int

        var errorDescription: String? {
            "Markdown preview exceeds the \(maximumBlocks)-block limit."
        }
    }

    static func render(
        _ source: String,
        maximumBlocks: Int = SafeMarkdownRenderer.defaultMaximumBlocks
    ) throws -> SafeMarkdownDocument {
        precondition((1 ... hardMaximumBlocks).contains(maximumBlocks))
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(
            separator: "\n",
            maxSplits: maximumBlocks,
            omittingEmptySubsequences: false
        )
        guard lines.count <= maximumBlocks else {
            throw LimitError(maximumBlocks: maximumBlocks)
        }

        var blocks: [SafeMarkdownBlock] = []
        var links: [URL] = []
        var lineIndex = 0

        func append(
            _ kind: SafeMarkdownBlock.Kind,
            text: String,
            parseInline: Bool = true,
            table: SafeMarkdownTable? = nil
        ) throws {
            guard blocks.count < maximumBlocks else {
                throw LimitError(maximumBlocks: maximumBlocks)
            }
            let rendered = parseInline ? renderInline(text) : (AttributedString(text), [])
            blocks.append(SafeMarkdownBlock(
                id: blocks.count,
                kind: kind,
                content: rendered.0,
                plainText: text,
                table: table
            ))
            links.append(contentsOf: rendered.1)
        }

        while lineIndex < lines.count {
            let line = String(lines[lineIndex])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                lineIndex += 1
                continue
            }

            if let fence = fenceOpening(trimmed) {
                lineIndex += 1
                var codeLines: [String] = []
                while lineIndex < lines.count {
                    let candidate = String(lines[lineIndex])
                    if candidate.trimmingCharacters(in: .whitespaces)
                        .hasPrefix(fence.marker) {
                        lineIndex += 1
                        break
                    }
                    codeLines.append(candidate)
                    lineIndex += 1
                }
                try append(
                    .code(language: fence.language),
                    text: codeLines.joined(separator: "\n"),
                    parseInline: false
                )
                continue
            }

            if thematicBreak(trimmed) {
                try append(.thematicBreak, text: "")
                lineIndex += 1
                continue
            }

            if let tableCandidate = table(
                startingAt: lineIndex,
                in: lines
            ) {
                guard blocks.count < maximumBlocks else {
                    throw LimitError(maximumBlocks: maximumBlocks)
                }
                blocks.append(SafeMarkdownBlock(
                    id: blocks.count,
                    kind: .table,
                    content: AttributedString(""),
                    plainText: tableCandidate.plainText,
                    table: tableCandidate.table
                ))
                links.append(contentsOf: tableCandidate.links)
                lineIndex = tableCandidate.nextLineIndex
                continue
            }

            if let heading = headingContent(line) {
                try append(.heading(level: heading.level), text: heading.text)
            } else if let quote = prefixedContent(line, prefix: "> ") {
                try append(.blockQuote, text: quote)
            } else if let item = listItem(line) {
                switch item.kind {
                case .unordered:
                    try append(
                        .unorderedListItem(depth: item.depth, task: item.task),
                        text: item.text
                    )
                case let .ordered(number):
                    try append(
                        .orderedListItem(number: number, depth: item.depth, task: item.task),
                        text: item.text
                    )
                }
            } else if containsRawHTML(line) {
                try append(.paragraph, text: line, parseInline: false)
            } else {
                try append(.paragraph, text: line)
            }
            lineIndex += 1
        }

        return SafeMarkdownDocument(blocks: blocks, links: links)
    }

    private static func renderInline(_ source: String) -> (AttributedString, [URL]) {
        var result = AttributedString("")
        var links: [URL] = []
        var cursor = source.startIndex
        var literalStart = cursor

        func appendLiteral(upTo end: String.Index) {
            guard literalStart < end else { return }
            result.append(AttributedString(String(source[literalStart ..< end])))
        }

        func appendLink(label: String, url: URL) {
            var attributed = AttributedString(label)
            attributed.link = url
            result.append(attributed)
            links.append(url)
        }

        func appendImageLabel(alt: String, url: URL?) {
            let trimmedAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmedAlt.isEmpty
                ? "Image"
                : "Image: \(trimmedAlt)"
            if let url {
                appendLink(label: label, url: url)
            } else {
                result.append(AttributedString(label))
            }
        }

        while cursor < source.endIndex {
            let character = source[cursor]

            if character == "\\" {
                let escaped = source.index(after: cursor)
                if escaped < source.endIndex, "\\`*{}_[]()<>#+-.!".contains(source[escaped]) {
                    appendLiteral(upTo: cursor)
                    result.append(AttributedString(String(source[escaped])))
                    cursor = source.index(after: escaped)
                    literalStart = cursor
                    continue
                }
            }

            if character == "!",
               let bracket = nextIndex(after: cursor, in: source),
               bracket < source.endIndex,
               source[bracket] == "[" {
                let labelStart = source.index(after: bracket)
                guard let labelEnd = source[labelStart...].firstIndex(of: "]") else {
                    cursor = bracket
                    continue
                }
                let opening = source.index(after: labelEnd)
                guard opening < source.endIndex, source[opening] == "(" else {
                    cursor = opening
                    continue
                }
                let destinationStart = source.index(after: opening)
                guard let closing = source[destinationStart...].firstIndex(of: ")") else {
                    cursor = destinationStart
                    continue
                }
                let destination = String(source[destinationStart ..< closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                appendLiteral(upTo: cursor)
                appendImageLabel(
                    alt: String(source[labelStart ..< labelEnd]),
                    url: PreviewURLPolicy.urlIfAllowed(destination)
                )
                cursor = source.index(after: closing)
                literalStart = cursor
                continue
            }

            if character == "`" {
                let contentStart = source.index(after: cursor)
                guard let closing = source[contentStart...].firstIndex(of: "`") else { break }
                appendLiteral(upTo: cursor)
                result.append(AttributedString(String(source[contentStart ..< closing])))
                cursor = source.index(after: closing)
                literalStart = cursor
                continue
            }

            if character == "[" {
                let previous = cursor > source.startIndex ? source.index(before: cursor) : nil
                if previous.map({ source[$0] == "!" }) == true {
                    cursor = source.index(after: cursor)
                    continue
                }

                let labelStart = source.index(after: cursor)
                guard let labelEnd = source[labelStart...].firstIndex(of: "]") else { break }
                let opening = source.index(after: labelEnd)
                guard opening < source.endIndex, source[opening] == "(" else {
                    cursor = opening
                    continue
                }
                let destinationStart = source.index(after: opening)
                guard let closing = source[destinationStart...].firstIndex(of: ")") else { break }
                let destination = String(source[destinationStart ..< closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = PreviewURLPolicy.urlIfAllowed(destination) {
                    appendLiteral(upTo: cursor)
                    appendLink(
                        label: String(source[labelStart ..< labelEnd]),
                        url: url
                    )
                    cursor = source.index(after: closing)
                    literalStart = cursor
                } else {
                    cursor = source.index(after: closing)
                }
                continue
            }

            if character == "<",
               source[..<cursor].last != "!" {
                let destinationStart = source.index(after: cursor)
                guard let closing = source[destinationStart...].firstIndex(of: ">") else { break }
                let destination = String(source[destinationStart ..< closing])
                if let url = PreviewURLPolicy.urlIfAllowed(destination) {
                    appendLiteral(upTo: cursor)
                    appendLink(label: destination, url: url)
                    cursor = source.index(after: closing)
                    literalStart = cursor
                } else {
                    cursor = source.index(after: closing)
                }
                continue
            }

            if character == "*" || character == "_" {
                let markerLength = matchingMarkerLength(
                    in: source,
                    at: cursor,
                    upperBound: source.endIndex
                )
                let marker = String(repeating: String(character), count: markerLength)
                let contentStart = source.index(cursor, offsetBy: markerLength)
                if let closing = closingMarker(
                    marker,
                    in: source,
                    from: contentStart,
                    upperBound: source.endIndex
                ) {
                    let innerSource = String(source[contentStart ..< closing])
                    appendLiteral(upTo: cursor)
                    let renderedInner = renderInline(innerSource)
                    result.append(
                        styled(
                            renderedInner.0,
                            strongly: markerLength == 2
                        )
                    )
                    links.append(contentsOf: renderedInner.1)
                    cursor = source.index(closing, offsetBy: markerLength)
                    literalStart = cursor
                    continue
                }
            }

            cursor = source.index(after: cursor)
        }

        appendLiteral(upTo: source.endIndex)
        return (result, links)
    }

    private enum ListKind {
        case unordered
        case ordered(number: Int)
    }

    private struct ParsedListItem {
        let kind: ListKind
        let depth: Int
        let task: SafeMarkdownTaskState?
        let text: String
    }

    private struct ParsedTable {
        let table: SafeMarkdownTable
        let nextLineIndex: Int
        let links: [URL]
        let plainText: String
    }

    private static func listItem(_ line: String) -> ParsedListItem? {
        let indentation = leadingIndentationColumns(line)
        let depth = min(32, max(0, indentation / 2))
        if let item = unorderedListContent(line) {
            let task = taskState(in: item)
            return ParsedListItem(
                kind: .unordered,
                depth: depth,
                task: task?.0,
                text: task?.1 ?? item
            )
        }
        if let item = orderedListContent(line) {
            let task = taskState(in: item.text)
            return ParsedListItem(
                kind: .ordered(number: item.number),
                depth: depth,
                task: task?.0,
                text: task?.1 ?? item.text
            )
        }
        return nil
    }

    private static func leadingIndentationColumns(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
        }
        return columns
    }

    private static func taskState(in text: String) -> (SafeMarkdownTaskState, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4, trimmed.first == "[", let closing = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let marker = trimmed[trimmed.index(after: trimmed.startIndex) ..< closing]
        guard marker.count == 1, let value = marker.first else { return nil }
        let remainderStart = trimmed.index(after: closing)
        guard remainderStart == trimmed.endIndex || trimmed[remainderStart] == " " else {
            return nil
        }
        let content = remainderStart < trimmed.endIndex
            ? String(trimmed[trimmed.index(after: remainderStart)...])
            : ""
        switch value {
        case " ":
            return (.unchecked, content)
        case "x", "X":
            return (.checked, content)
        default:
            return nil
        }
    }

    private static func table(
        startingAt lineIndex: Int,
        in lines: [Substring]
    ) -> ParsedTable? {
        guard lineIndex + 1 < lines.count else { return nil }
        let headerLine = String(lines[lineIndex])
        let separatorLine = String(lines[lineIndex + 1])
        guard let headerCells = tableCells(headerLine),
              tableSeparator(separatorLine, expectedCount: headerCells.count) else {
            return nil
        }

        var links: [URL] = []
        func renderRow(_ cells: [String]) -> SafeMarkdownTableRow {
            let renderedCells = cells.map { cell -> SafeMarkdownTableCell in
                let rendered = renderInline(cell)
                links.append(contentsOf: rendered.1)
                return SafeMarkdownTableCell(content: rendered.0, plainText: cell)
            }
            return SafeMarkdownTableRow(cells: renderedCells)
        }

        let header = renderRow(headerCells)
        var rows: [SafeMarkdownTableRow] = []
        var plainLines = [headerCells.joined(separator: "\t")]
        var nextLineIndex = lineIndex + 2
        while nextLineIndex < lines.count {
            let candidate = String(lines[nextLineIndex])
            guard let rowCells = tableCells(candidate),
                  rowCells.count == headerCells.count else {
                break
            }
            rows.append(renderRow(rowCells))
            plainLines.append(rowCells.joined(separator: "\t"))
            nextLineIndex += 1
        }

        return ParsedTable(
            table: SafeMarkdownTable(header: header, rows: rows),
            nextLineIndex: nextLineIndex,
            links: links,
            plainText: plainLines.joined(separator: "\n")
        )
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var characters = Array(line)
        if characters.first == "|" { characters.removeFirst() }
        if characters.last == "|" { characters.removeLast() }
        for character in characters {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.isEmpty ? nil : cells
    }

    private static func tableSeparator(_ line: String, expectedCount: Int) -> Bool {
        guard let cells = tableCells(line), cells.count == expectedCount else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return body.count >= 3 && body.allSatisfy { $0 == "-" }
        }
    }

    private static func thematicBreak(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first else { return false }
        return (first == "-" || first == "*" || first == "_")
            && compact.allSatisfy { $0 == first }
    }

    private static func matchingMarkerLength(
        in source: String,
        at index: String.Index,
        upperBound: String.Index
    ) -> Int {
        let character = source[index]
        guard let next = nextIndex(after: index, in: source),
              next < upperBound,
              source[next] == character else {
            return 1
        }
        return 2
    }

    private static func closingMarker(
        _ marker: String,
        in source: String,
        from start: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        guard !marker.isEmpty else { return nil }
        var cursor = start
        while cursor < upperBound {
            if source[cursor] == "\\" {
                cursor = source.index(after: cursor)
                if cursor < upperBound { cursor = source.index(after: cursor) }
                continue
            }
            if source[cursor...].hasPrefix(marker) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func styled(_ value: AttributedString, strongly: Bool) -> AttributedString {
        var attributed = value
        #if canImport(AppKit)
        var container = AttributeContainer()
        container.inlinePresentationIntent = strongly ? .stronglyEmphasized : .emphasized
        attributed.mergeAttributes(container)
        #endif
        return attributed
    }

    private static func nextIndex(after index: String.Index, in source: String) -> String.Index? {
        let next = source.index(after: index)
        return next < source.endIndex ? next : nil
    }

    private static func fenceOpening(_ trimmed: String) -> (marker: String, language: String?)? {
        let marker: String
        if trimmed.hasPrefix("```") {
            marker = "```"
        } else if trimmed.hasPrefix("~~~") {
            marker = "~~~"
        } else {
            return nil
        }
        let language = trimmed.dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
        return (marker, language.isEmpty ? nil : clipped(language, maximumCharacters: 40))
    }

    private static func headingContent(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let marks = trimmed.prefix(while: { $0 == "#" })
        guard (1 ... 6).contains(marks.count) else { return nil }
        let separator = trimmed.index(trimmed.startIndex, offsetBy: marks.count)
        guard separator < trimmed.endIndex, trimmed[separator] == " " else { return nil }
        return (marks.count, String(trimmed[trimmed.index(after: separator)...]))
    }

    private static func prefixedContent(_ line: String, prefix: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count))
    }

    private static func unorderedListContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if let result = prefixedContent(line, prefix: marker) { return result }
        }
        return nil
    }

    private static func orderedListContent(_ line: String) -> (number: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let dot = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard dot < trimmed.endIndex, trimmed[dot] == "." else { return nil }
        let space = trimmed.index(after: dot)
        guard space < trimmed.endIndex, trimmed[space] == " " else { return nil }
        return (number, String(trimmed[trimmed.index(after: space)...]))
    }

    private static func containsRawHTML(_ line: String) -> Bool {
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let opening = line[searchStart...].firstIndex(of: "<") {
            let afterOpening = line.index(after: opening)
            guard afterOpening < line.endIndex else { return false }
            if line[afterOpening] == "!"
                || line[afterOpening] == "?"
                || line[afterOpening] == "/" {
                return true
            }

            let remainder = line[afterOpening...]
            let name = remainder.prefix(while: {
                $0.isLetter || $0.isNumber || $0 == "-"
            })
            if !name.isEmpty {
                let boundary = remainder.index(remainder.startIndex, offsetBy: name.count)
                if boundary < remainder.endIndex,
                   remainder[boundary].isWhitespace
                    || remainder[boundary] == ">"
                    || remainder[boundary] == "/" {
                    return true
                }
            }
            searchStart = afterOpening
        }
        return false
    }

    private static func clipped(_ value: String, maximumCharacters: Int) -> String {
        let prefix = value.prefix(maximumCharacters + 1)
        guard prefix.count > maximumCharacters else { return String(prefix) }
        return String(prefix.prefix(maximumCharacters)) + "…"
    }
}

/// Owns preview state without depending on AppModel or NativeTextEditor.
///
/// The composition layer supplies AppModel's pane-aware transaction method and
/// a URL opener. JSON transforms always submit one whole-document `TextEdit` in
/// one revision-pinned `TextTransaction`, so a stale preview cannot overwrite
/// newer editor input.
@MainActor
final class PreviewController: ObservableObject {
    typealias ApplyTransaction = @MainActor (TextTransaction) -> Bool
    typealias OpenURL = @MainActor (URL) -> Bool
    typealias CurrentDocumentSnapshot = @MainActor () -> JSONEditorDocumentSnapshot?

    nonisolated static let defaultMaximumMarkdownUTF16Count = 2 * 1_024 * 1_024
    nonisolated static let defaultMaximumMarkdownBlocks = SafeMarkdownRenderer.defaultMaximumBlocks

    @Published private(set) var mode: DocumentPreviewMode = .hidden
    @Published private(set) var markdownDocument: SafeMarkdownDocument = .empty
    @Published private(set) var jsonSnapshot: JSONTreeSnapshot?
    @Published private(set) var issue: DocumentPreviewIssue?
    @Published private(set) var jsonEditingIssue: JSONEditingIssue?
    @Published private(set) var contentRevision: UInt64 = 0
    @Published private(set) var jsonEditSessionGeneration: UInt64 = 0

    let jsonLimits: LosslessJSONLimits
    let jsonTreeLimits: JSONTreeLimits
    let maximumMarkdownUTF16Count: Int
    let maximumMarkdownBlocks: Int

    private let applyTransaction: ApplyTransaction
    private var applyJSONTransaction: ApplyTransaction
    private let urlOpener: OpenURL
    private let currentDocumentSnapshot: CurrentDocumentSnapshot
    private var jsonEditingSnapshot: JSONEditingSnapshot?

    private struct JSONEditingSnapshot {
        let document: JSONEditorDocumentSnapshot?
        let value: LosslessJSONValue
    }

    init(
        jsonLimits: LosslessJSONLimits = .default,
        jsonTreeLimits: JSONTreeLimits = .default,
        maximumMarkdownUTF16Count: Int = PreviewController.defaultMaximumMarkdownUTF16Count,
        maximumMarkdownBlocks: Int = PreviewController.defaultMaximumMarkdownBlocks,
        applyTransaction: @escaping ApplyTransaction,
        openURL: @escaping OpenURL = { _ in false },
        currentDocumentSnapshot: @escaping CurrentDocumentSnapshot = { nil }
    ) {
        precondition(maximumMarkdownUTF16Count >= 0)
        precondition(maximumMarkdownBlocks > 0)
        self.jsonLimits = jsonLimits
        self.jsonTreeLimits = jsonTreeLimits
        self.maximumMarkdownUTF16Count = maximumMarkdownUTF16Count
        self.maximumMarkdownBlocks = maximumMarkdownBlocks
        self.applyTransaction = applyTransaction
        self.applyJSONTransaction = applyTransaction
        self.urlOpener = openURL
        self.currentDocumentSnapshot = currentDocumentSnapshot
    }

    var isVisible: Bool { mode != .hidden }
    var isMarkdownPreviewVisible: Bool { mode == .markdown }
    var isJSONViewVisible: Bool { mode == .json }

    /// Installed by the window after the macro/snippet controller is composed.
    /// This avoids a construction cycle while routing JSON tree mutations
    /// through the same snippet-aware, macro-recording adapter as editor input.
    func setJSONTransactionApplier(_ applier: @escaping ApplyTransaction) {
        applyJSONTransaction = applier
    }

    @discardableResult
    func toggleMarkdownPreview(source: String) -> Bool {
        if mode == .markdown {
            hide()
            return false
        }
        mode = .markdown
        renderMarkdown(source)
        return true
    }

    @discardableResult
    func toggleJSONView(source: String) -> Bool {
        if mode == .json {
            hide()
            return false
        }
        mode = .json
        renderJSON(source)
        return true
    }

    func update(source: String) {
        switch mode {
        case .hidden:
            break
        case .markdown:
            renderMarkdown(source)
        case .json:
            renderJSON(source)
        }
    }

    /// Refreshes a visible preview for the current editor context without
    /// rebuilding an unchanged JSON tree for selection-only AppModel events.
    /// Document identity is checked as well as source text so switching between
    /// two identical JSON tabs still retargets subsequent edits safely.
    func updateForCurrentDocument() {
        switch mode {
        case .hidden:
            break
        case .markdown:
            if let current = currentDocumentSnapshot() {
                renderMarkdown(current.source)
            }
        case .json:
            guard let current = currentDocumentSnapshot() else { return }
            guard current != jsonEditingSnapshot?.document else { return }
            renderJSON(current.source)
        }
    }

    /// Lets the view dismiss a stale editor after a document switch without
    /// discarding the useful error that explains why the commit was refused.
    func isJSONEditRevisionCurrent(
        expectedSessionGeneration: UInt64
    ) -> Bool {
        expectedSessionGeneration == jsonEditSessionGeneration
            && currentDocumentSnapshot() == jsonEditingSnapshot?.document
    }

    func hide() {
        mode = .hidden
        issue = nil
        jsonEditingIssue = nil
        jsonEditingSnapshot = nil
        advanceJSONEditSessionGeneration()
        advanceContentRevision()
    }

    func dismissIssue() {
        issue = nil
    }

    func dismissJSONEditingIssue() {
        jsonEditingIssue = nil
    }

    /// Returns the full lossless spelling used to seed the native edit sheet.
    /// Tree rows deliberately keep only bounded previews, so they must never be
    /// used as the source of an edit.
    func serializedJSONValue(
        at path: LosslessJSONPath,
        expectedSessionGeneration: UInt64
    ) -> String? {
        guard expectedSessionGeneration == jsonEditSessionGeneration,
              let rendered = jsonEditingSnapshot,
              currentDocumentSnapshot() == rendered.document else {
            jsonEditingIssue = JSONEditingIssue(
                kind: .documentChanged,
                appCopy: .jsonTreeChangedBeforeEditBegan
            )
            return nil
        }
        guard let value = rendered.value.value(at: path) else {
            jsonEditingIssue = JSONEditingIssue(
                kind: .pathUnavailable,
                appCopy: .selectedJSONNodeNoLongerExists
            )
            return nil
        }
        do {
            return try LosslessJSON.stringify(value, limits: jsonLimits)
        } catch let error as LosslessJSONResourceError {
            jsonEditingIssue = JSONEditingIssue(
                kind: .resourceLimit, appCopy: Self.copy(for: error)
            )
        } catch {
            jsonEditingIssue = JSONEditingIssue(
                kind: .unexpected, verbatim: error.localizedDescription
            )
        }
        return nil
    }

    /// Replaces any JSON value, including a root primitive. The entered text is
    /// parsed as JSON rather than coerced as a Swift scalar, matching Electron's
    /// ability to change a string into a number, boolean, null, array, or object.
    @discardableResult
    func replaceJSONValue(
        at path: LosslessJSONPath,
        with source: String,
        expectedSessionGeneration: UInt64
    ) -> Bool {
        mutateJSON(
            expectedSessionGeneration: expectedSessionGeneration,
            invalidInputKind: .invalidValue
        ) { value in
            let replacement = try LosslessJSON.parse(source, limits: jsonLimits)
            try value.replaceValue(at: path, with: replacement, limits: jsonLimits)
        }
    }

    @discardableResult
    func addJSONObjectMember(
        at path: LosslessJSONPath,
        key: String,
        valueSource: String,
        expectedSessionGeneration: UInt64
    ) -> Bool {
        mutateJSON(
            expectedSessionGeneration: expectedSessionGeneration,
            invalidInputKind: .invalidValue
        ) { value in
            let memberValue = try LosslessJSON.parse(valueSource, limits: jsonLimits)
            try value.addObjectMember(
                key: key, value: memberValue, at: path, limits: jsonLimits
            )
        }
    }

    @discardableResult
    func appendJSONArrayItem(
        at path: LosslessJSONPath,
        valueSource: String,
        expectedSessionGeneration: UInt64
    ) -> Bool {
        mutateJSON(
            expectedSessionGeneration: expectedSessionGeneration,
            invalidInputKind: .invalidValue
        ) { value in
            let item = try LosslessJSON.parse(valueSource, limits: jsonLimits)
            try value.appendArrayItem(item, at: path, limits: jsonLimits)
        }
    }

    @discardableResult
    func removeJSONValue(
        at path: LosslessJSONPath,
        expectedSessionGeneration: UInt64
    ) -> Bool {
        mutateJSON(expectedSessionGeneration: expectedSessionGeneration) { value in
            try value.removeValue(at: path, limits: jsonLimits)
        }
    }

    @discardableResult
    func formatJSON(source: String, expectedRevision: UInt64) -> Bool {
        transformJSON(
            source: source,
            indent: 2,
            appendFinalNewline: true,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func compactJSON(source: String, expectedRevision: UInt64) -> Bool {
        transformJSON(
            source: source,
            indent: 0,
            appendFinalNewline: false,
            expectedRevision: expectedRevision
        )
    }

    @discardableResult
    func openLink(_ url: URL) -> Bool {
        guard PreviewURLPolicy.isAllowed(url) else { return false }
        return urlOpener(url)
    }

    static func makeWholeDocumentTransaction(
        source: String,
        replacement: String,
        expectedRevision: UInt64
    ) throws -> TextTransaction {
        try TextTransaction(
            edits: [TextEdit(
                from: 0,
                to: source.utf16.count,
                insert: replacement
            )],
            expectedRevision: expectedRevision
        )
    }

    private func transformJSON(
        source: String,
        indent: Int,
        appendFinalNewline: Bool,
        expectedRevision: UInt64
    ) -> Bool {
        do {
            let parsed = try LosslessJSON.parse(source, limits: jsonLimits)
            var replacement = try LosslessJSON.stringify(
                parsed,
                indent: indent,
                limits: jsonLimits
            )
            if appendFinalNewline { replacement.append("\n") }
            guard replacement.utf16.count <= jsonLimits.maximumBytes else {
                issue = DocumentPreviewIssue(
                    kind: .resourceLimit,
                    appCopy: .jsonOutputExceedsLimit(maximum: jsonLimits.maximumBytes)
                )
                return false
            }
            let transaction = try Self.makeWholeDocumentTransaction(
                source: source,
                replacement: replacement,
                expectedRevision: expectedRevision
            )
            guard applyTransaction(transaction) else {
                issue = DocumentPreviewIssue(
                    kind: .transactionRejected,
                    appCopy: .documentChangedBeforeJSONTransformApplied
                )
                return false
            }
            issue = nil
            return true
        } catch let error as LosslessJSONParseError {
            issue = previewIssue(for: error)
            return false
        } catch let error as LosslessJSONResourceError {
            issue = DocumentPreviewIssue(
                kind: .resourceLimit,
                appCopy: Self.copy(for: error)
            )
            return false
        } catch let error as EditorTransactionError {
            issue = DocumentPreviewIssue(
                kind: .transactionCreation,
                appCopy: Self.copy(for: error)
            )
            return false
        } catch {
            issue = DocumentPreviewIssue(
                kind: .unexpected, verbatim: error.localizedDescription
            )
            return false
        }
    }

    private func renderMarkdown(_ source: String) {
        guard source.utf16.count <= maximumMarkdownUTF16Count else {
            markdownDocument = .empty
            issue = DocumentPreviewIssue(
                kind: .resourceLimit,
                appCopy: .markdownExceedsPreviewLimit(
                    maximum: maximumMarkdownUTF16Count
                )
            )
            advanceContentRevision()
            return
        }
        do {
            markdownDocument = try SafeMarkdownRenderer.render(
                source,
                maximumBlocks: maximumMarkdownBlocks
            )
            issue = nil
        } catch let error as SafeMarkdownRenderer.LimitError {
            markdownDocument = .empty
            issue = DocumentPreviewIssue(
                kind: .resourceLimit,
                appCopy: .markdownPreviewExceedsBlockLimit(
                    maximum: error.maximumBlocks
                )
            )
        } catch {
            markdownDocument = .empty
            issue = DocumentPreviewIssue(
                kind: .unexpected, verbatim: error.localizedDescription
            )
        }
        advanceContentRevision()
    }

    private func renderJSON(_ source: String) {
        advanceJSONEditSessionGeneration()
        do {
            let value = try LosslessJSON.parse(source, limits: jsonLimits)
            jsonSnapshot = JSONTreeSnapshot(value: value, limits: jsonTreeLimits)
            let current = currentDocumentSnapshot()
            jsonEditingSnapshot = JSONEditingSnapshot(
                document: current?.source == source ? current : nil,
                value: value
            )
            issue = nil
            jsonEditingIssue = nil
        } catch let error as LosslessJSONParseError {
            jsonSnapshot = nil
            jsonEditingSnapshot = nil
            jsonEditingIssue = nil
            issue = previewIssue(for: error)
        } catch let error as LosslessJSONResourceError {
            jsonSnapshot = nil
            jsonEditingSnapshot = nil
            jsonEditingIssue = nil
            issue = DocumentPreviewIssue(
                kind: .resourceLimit,
                appCopy: Self.copy(for: error)
            )
        } catch {
            jsonSnapshot = nil
            jsonEditingSnapshot = nil
            jsonEditingIssue = nil
            issue = DocumentPreviewIssue(
                kind: .unexpected, verbatim: error.localizedDescription
            )
        }
        advanceContentRevision()
    }

    @discardableResult
    private func mutateJSON(
        expectedSessionGeneration: UInt64,
        invalidInputKind: JSONEditingIssue.Kind = .unexpected,
        _ operation: (inout LosslessJSONValue) throws -> Void
    ) -> Bool {
        guard expectedSessionGeneration == jsonEditSessionGeneration else {
            jsonEditingIssue = JSONEditingIssue(
                kind: .documentChanged,
                appCopy: .jsonTreeChangedBeforeEditApplied
            )
            return false
        }
        guard mode == .json, let rendered = jsonEditingSnapshot else {
            jsonEditingIssue = JSONEditingIssue(
                kind: .unavailable,
                appCopy: .noEditableJSONTree
            )
            return false
        }
        guard let expectedDocument = rendered.document else {
            jsonEditingIssue = JSONEditingIssue(
                kind: .unavailable,
                appCopy: .jsonTreeNotAttachedToEditorRevision
            )
            return false
        }
        guard currentDocumentSnapshot() == expectedDocument else {
            jsonEditingIssue = JSONEditingIssue(
                kind: .documentChanged,
                appCopy: .documentChangedAfterJSONTreeRendered
            )
            return false
        }

        do {
            var next = rendered.value
            try operation(&next)
            var replacement = try LosslessJSON.stringify(
                next, indent: 2, limits: jsonLimits
            )
            replacement.append("\n")
            guard replacement.utf16.count <= jsonLimits.maximumBytes else {
                throw LosslessJSONResourceError.sourceTooLarge(
                    actualLength: replacement.utf16.count,
                    maximumLength: jsonLimits.maximumBytes
                )
            }

            // Treat an exact no-op as success without manufacturing an undo
            // entry. All actual mutations still use one revision-pinned edit.
            if replacement == expectedDocument.source {
                jsonEditingIssue = nil
                return true
            }

            let transaction = try Self.makeWholeDocumentTransaction(
                source: expectedDocument.source,
                replacement: replacement,
                expectedRevision: expectedDocument.revision
            )
            guard applyJSONTransaction(transaction) else {
                jsonEditingIssue = JSONEditingIssue(
                    kind: .transactionRejected,
                    appCopy: .documentChangedBeforeJSONEditApplied
                )
                return false
            }
            jsonEditingIssue = nil
            if let updated = currentDocumentSnapshot(),
               updated.documentID == expectedDocument.documentID {
                renderJSON(updated.source)
            } else {
                // Production supplies a live document snapshot. This fallback
                // keeps injected adapters deterministic without weakening the
                // revision pin used for the transaction itself.
                jsonSnapshot = JSONTreeSnapshot(value: next, limits: jsonTreeLimits)
                jsonEditingSnapshot = nil
                issue = nil
                advanceContentRevision()
            }
            return true
        } catch let error as LosslessJSONParseError {
            jsonEditingIssue = JSONEditingIssue(
                kind: invalidInputKind, content: Self.content(for: error)
            )
        } catch let error as LosslessJSONTreeError {
            let kind: JSONEditingIssue.Kind
            switch error {
            case .invalidObjectKey: kind = .invalidObjectKey
            case .duplicateObjectKey: kind = .duplicateObjectKey
            case .pathNotFound, .typeMismatch, .cannotRemoveRoot:
                kind = .pathUnavailable
            }
            jsonEditingIssue = JSONEditingIssue(
                kind: kind, appCopy: Self.copy(for: error)
            )
        } catch let error as LosslessJSONResourceError {
            jsonEditingIssue = JSONEditingIssue(
                kind: .resourceLimit, appCopy: Self.copy(for: error)
            )
        } catch let error as EditorTransactionError {
            jsonEditingIssue = JSONEditingIssue(
                kind: .transactionCreation, appCopy: Self.copy(for: error)
            )
        } catch {
            jsonEditingIssue = JSONEditingIssue(
                kind: .unexpected, verbatim: error.localizedDescription
            )
        }
        return false
    }

    private func advanceContentRevision() {
        contentRevision &+= 1
    }

    private func advanceJSONEditSessionGeneration() {
        jsonEditSessionGeneration &+= 1
    }

    private func previewIssue(for error: LosslessJSONParseError) -> DocumentPreviewIssue {
        let kind: DocumentPreviewIssue.Kind
        switch error.kind {
        case .syntax:
            kind = .invalidJSON
        case .sourceTooLarge, .nestingTooDeep, .tooManyNodes:
            kind = .resourceLimit
        }
        return DocumentPreviewIssue(kind: kind, content: Self.content(for: error))
    }

    private static func content(for error: LosslessJSONParseError) -> AppPresentationText {
        let location = (line: error.line, column: error.column)
        switch error.kind {
        case let .sourceTooLarge(_, maximum):
            return .app(.jsonInputExceedsLimit(
                maximum: maximum, line: location.line, column: location.column
            ))
        case let .nestingTooDeep(_, maximum):
            return .app(.jsonNestingExceedsLimit(
                maximum: maximum, line: location.line, column: location.column
            ))
        case let .tooManyNodes(_, maximum):
            return .app(.jsonNodeCountExceedsLimit(
                maximum: maximum, line: location.line, column: location.column
            ))
        case .syntax:
            break
        }

        let copy: AppLocalizedCopy? = switch error.message {
        case "Unexpected trailing content.":
            .jsonUnexpectedTrailingContent(line: location.line, column: location.column)
        case "Expected a JSON value.":
            .jsonExpectedValue(line: location.line, column: location.column)
        case "Expected an object key.":
            .jsonExpectedObjectKey(line: location.line, column: location.column)
        case "Invalid JSON string.":
            .jsonInvalidString(line: location.line, column: location.column)
        case "Control character in JSON string.":
            .jsonControlCharacterInString(line: location.line, column: location.column)
        case "Unterminated JSON string.":
            .jsonUnterminatedString(line: location.line, column: location.column)
        case "Invalid JSON number.":
            .jsonInvalidNumber(line: location.line, column: location.column)
        case "Expected true.":
            .jsonExpectedLiteral(value: "true", line: location.line, column: location.column)
        case "Expected false.":
            .jsonExpectedLiteral(value: "false", line: location.line, column: location.column)
        case "Expected null.":
            .jsonExpectedLiteral(value: "null", line: location.line, column: location.column)
        default:
            nil
        }
        if let copy { return .app(copy) }
        if error.message.hasPrefix("Expected “"), error.message.hasSuffix("”.") {
            let value = String(error.message.dropFirst(10).dropLast(2))
            return .app(.jsonExpectedToken(
                value: value, line: location.line, column: location.column
            ))
        }
        return .verbatim(error.description)
    }

    private static func copy(for error: LosslessJSONResourceError) -> AppLocalizedCopy {
        switch error {
        case let .sourceTooLarge(actual, maximum):
            .jsonOutputUsesTooManyCodeUnits(actual: actual, maximum: maximum)
        case let .nestingTooDeep(actual, maximum):
            .jsonDepthExceedsMaximum(actual: actual, maximum: maximum)
        case let .tooManyNodes(actual, maximum):
            .jsonNodeCountExceedsMaximum(actual: actual, maximum: maximum)
        case let .indentTooLarge(actual, maximum):
            .jsonIndentExceedsMaximum(actual: actual, maximum: maximum)
        }
    }

    private static func copy(for error: LosslessJSONTreeError) -> AppLocalizedCopy {
        switch error {
        case .pathNotFound:
            .jsonPathDoesNotExist
        case let .typeMismatch(_, expected):
            .jsonPathWrongContainer(expected: expected.rawValue)
        case .invalidObjectKey:
            .jsonObjectKeyEmptyOrProtected
        case .duplicateObjectKey:
            .jsonObjectKeyAlreadyExists
        case .cannotRemoveRoot:
            .jsonRootCannotBeRemoved
        }
    }

    private static func copy(for error: EditorTransactionError) -> AppLocalizedCopy {
        switch error {
        case let .invalidEditRange(edit):
            .invalidUTF16EditRange(from: edit.from, to: edit.to)
        case let .overlappingEdits(first, second):
            .overlappingUTF16Edits(
                firstFrom: first.from, firstTo: first.to,
                secondFrom: second.from, secondTo: second.to
            )
        case let .editOutOfBounds(edit, length):
            .utf16EditOutsideDocument(from: edit.from, to: edit.to, length: length)
        case let .positionOutOfBounds(position, length):
            .utf16PositionOutsideDocument(position: position, length: length)
        case let .selectionOutOfBounds(viewID, length):
            .selectionOutsideDocument(viewID: viewID.rawValue, length: length)
        case let .unknownView(viewID):
            .unknownEditorView(viewID: viewID.rawValue)
        case let .staleRevision(expected, actual):
            .staleEditorRevision(expected: expected, actual: actual)
        }
    }
}
