@preconcurrency import Foundation

/// A bounded, UTF-16 lexer used by the native TextKit surface.  It is not a
/// parser and never mutates document text; its job is to provide the same
/// useful token classes as CodeMirror's fallback highlighting while a file is
/// visible.  Work is capped independently of the document size.
enum NativeSyntaxHighlighter {
    static let maximumScanUTF16Length = 192 * 1_024
    static let maximumContextUTF16Length = 32 * 1_024
    static let maximumSpans = 20_000
    static let maximumIdentifierUTF16Length = 128

    enum Kind: Equatable, Sendable {
        case keyword
        case string
        case number
        case comment
        case type
        case constant
        case markup
    }

    struct Span: Equatable, Sendable {
        let range: NSRange
        let kind: Kind
    }

    struct Plan: Equatable, Sendable {
        let scannedRange: NSRange
        let spans: [Span]
        let wasTruncated: Bool
    }

    struct ParsedSnapshot: Equatable, Sendable {
        let sourceUTF16Length: Int
        let documentID: String
        let language: String
        let documentRevision: UInt64
        let spans: [Span]
        let wasTruncated: Bool
    }

    static func plan(
        text: String,
        language rawLanguage: String,
        visibleRange requestedRange: NSRange,
        documentID: String? = nil,
        documentRevision: UInt64? = nil,
        parsedSnapshot: ParsedSnapshot? = nil
    ) -> Plan {
        let source = text as NSString
        let requested = clamped(requestedRange, to: source.length)
        guard source.length > 0, requested.length > 0 else {
            return Plan(scannedRange: requested, spans: [], wasTruncated: false)
        }
        if let parsedSnapshot, !parsedSnapshot.wasTruncated,
           parsedSnapshot.sourceUTF16Length == source.length,
           documentID == parsedSnapshot.documentID,
           parsedSnapshot.language == rawLanguage,
           documentRevision == parsedSnapshot.documentRevision {
            return Plan(
                scannedRange: requested,
                spans: parsedSnapshot.spans.compactMap { span in
                    let intersection = NSIntersectionRange(span.range, requested)
                    return intersection.length > 0
                        ? Span(range: intersection, kind: span.kind) : nil
                },
                wasTruncated: false
            )
        }
        let profile = Profile(language: rawLanguage)
        guard profile.kind != .plain else {
            return Plan(scannedRange: requested, spans: [], wasTruncated: false)
        }

        let contextStart = max(0, requested.location - maximumContextUTF16Length)
        let desiredEnd = min(source.length, contextStart + maximumScanUTF16Length)
        let scanRange = NSRange(location: contextStart, length: desiredEnd - contextStart)
        let visible = NSIntersectionRange(requested, scanRange)
        let allSpans: [Span]
        switch profile.kind {
        case .plain:
            allSpans = []
        case .markdown:
            allSpans = lexMarkdown(source, range: scanRange)
        case .markup:
            allSpans = lexMarkup(source, range: scanRange)
        case .code:
            allSpans = lexCode(source, range: scanRange, profile: profile)
        }
        var retained: [Span] = []
        retained.reserveCapacity(min(allSpans.count, maximumSpans))
        var truncated = scanRange != NSRange(location: 0, length: source.length)
            || visible != requested
        for span in allSpans {
            let intersection = NSIntersectionRange(span.range, visible)
            guard intersection.length > 0 else { continue }
            if retained.count == maximumSpans {
                truncated = true
                break
            }
            retained.append(Span(range: intersection, kind: span.kind))
        }
        return Plan(scannedRange: scanRange, spans: retained, wasTruncated: truncated)
    }
}

private extension NativeSyntaxHighlighter {
    struct Profile {
        enum LanguageKind { case plain, code, markup, markdown }
        let kind: LanguageKind
        let lineComments: [[UInt16]]
        let blockComments: [([UInt16], [UInt16])]
        let keywords: Set<String>
        let types: Set<String>
        let constants: Set<String>

        init(language raw: String) {
            let language = Self.normalizedLanguage(raw)
            if language.isEmpty || language == "plain text" {
                kind = .plain; lineComments = []; blockComments = []
                keywords = []; types = []; constants = []; return
            }
            if language == "markdown" || language == "stex"
                || language == "latex" || language == "textile" {
                kind = .markdown; lineComments = []; blockComments = []
                keywords = []; types = []; constants = []; return
            }
            if ["html", "xml", "vue", "angular template", "svg", "pug"]
                .contains(language) {
                kind = .markup; lineComments = []; blockComments = []
                keywords = []; types = []; constants = []; return
            }

            kind = .code
            let hashComments = [
                "python", "ruby", "shell", "bash", "yaml", "toml",
                "dockerfile", "r", "perl", "cmake", "makefile", "tcl",
                "gitignore", "properties"
            ].contains(language)
            let dashComments = [
                "sql", "mysql", "mariadb sql", "postgresql",
                "sqlite", "plsql", "haskell", "lua", "ada"
            ].contains(language)
            let semicolonComments = ["clojure", "common lisp", "scheme", "ini"].contains(language)
            let apostropheComments = ["visual basic", "vb", "vb.net"].contains(language)
            lineComments = hashComments ? [units("#")]
                : dashComments ? [units("--")]
                : semicolonComments ? [units(";")]
                : apostropheComments ? [units("'")]
                : [units("//")]
            blockComments = language == "haskell" ? [(units("{-"), units("-}"))]
                : language == "lua" ? [(units("--[["), units("]]"))]
                : language == "powershell" ? [(units("<#"), units("#>"))]
                : hashComments || semicolonComments || apostropheComments ? []
                : [(units("/*"), units("*/"))]
            keywords = Self.keywords(for: language)
            types = Self.types(for: language)
            constants = Self.constants(for: language)
        }

        private static func keywords(for language: String) -> Set<String> {
            var words = commonKeywords
            if ["python", "cython"].contains(language) {
                words.formUnion(["and", "as", "async", "await", "def", "del",
                    "elif", "except", "from", "global", "in", "is",
                    "lambda", "nonlocal", "not", "or", "pass", "raise",
                    "with", "yield"])
            } else if language == "ruby" {
                words.formUnion([
                    "alias", "and", "begin", "case", "class", "def", "defined?",
                    "elsif", "end", "ensure", "module", "next", "redo",
                    "rescue", "retry", "self", "super", "then", "undef",
                    "unless", "until", "when", "yield"
                ])
            } else if ["shell", "bash"].contains(language) {
                words.formUnion([
                    "case", "coproc", "done", "elif", "esac", "eval",
                    "exec", "export", "fi", "function", "local", "readonly",
                    "select", "source", "then", "time", "trap", "typeset",
                    "unset"
                ])
            } else if language == "r" {
                words.formUnion([
                    "break", "else", "for", "function", "if", "in",
                    "next", "repeat", "while"
                ])
            } else if language.contains("sql") || ["mysql", "postgresql", "sqlite", "plsql"].contains(language) {
                words.formUnion(sqlKeywords)
            } else if language == "swift" {
                words.formUnion(["actor", "associatedtype", "defer", "extension",
                    "guard", "inout", "mutating", "nonisolated", "protocol",
                    "some", "where", "willset", "didset"])
            } else if ["javascript", "jsx", "typescript", "tsx"].contains(language) {
                words.formUnion(["async", "await", "debugger", "delete", "export",
                    "extends", "function", "import", "instanceof", "interface",
                    "new", "of", "typeof", "undefined", "void", "yield"])
            }
            return words
        }

        private static func types(for language: String) -> Set<String> {
            var result: Set<String> = ["bool", "boolean", "byte", "char", "double",
                "float", "int", "integer", "long", "number", "object",
                "short", "string", "uint", "void"]
            if language == "swift" {
                result.formUnion(["any", "array", "dictionary", "never",
                    "optional", "self", "self.type"])
            } else if language == "python" {
                result.formUnion([
                    "bool", "bytes", "dict", "float", "frozenset", "int",
                    "list", "object", "set", "str", "tuple"
                ])
            } else if language == "ruby" {
                result.formUnion([
                    "array", "basicobject", "class", "falseclass", "float",
                    "hash", "integer", "module", "nilclass", "object",
                    "proc", "range", "regexp", "string", "symbol", "time", "trueclass"
                ])
            } else if language == "r" {
                result.formUnion([
                    "array", "character", "data.frame", "double", "factor",
                    "function", "integer", "list", "logical", "matrix", "numeric"
                ])
            }
            return result
        }

        private static func constants(for language: String) -> Set<String> {
            var result: Set<String> = ["false", "nil", "null", "true", "undefined"]
            if ["python", "cython"].contains(language) {
                result.formUnion(["none", "true", "false"])
            } else if language == "ruby" {
                result.formUnion(["nil", "true", "false"])
            } else if language == "r" {
                result.formUnion(["na", "nan", "inf", "null", "true", "false", "t", "f"])
            } else if ["shell", "bash"].contains(language) {
                result.formUnion(["true", "false"])
            }
            return result
        }

        private static func normalizedLanguage(_ raw: String) -> String {
            let language = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return switch language {
            case "py": "python"
            case "rb": "ruby"
            case "js": "javascript"
            case "ts": "typescript"
            case "sh", "zsh": "shell"
            case "ps1": "powershell"
            case "md": "markdown"
            case "yml": "yaml"
            case "docker": "dockerfile"
            case "postgres", "postgres sql": "postgresql"
            default: language
            }
        }

        private static let commonKeywords: Set<String> = [
            "break", "case", "catch", "class", "const", "continue",
            "default", "do", "else", "enum", "false", "finally",
            "for", "func", "function", "if", "in", "let", "nil",
            "null", "private", "protected", "public", "return", "static",
            "struct", "switch", "throw", "throws", "true", "try",
            "var", "while"
        ]
        private static let sqlKeywords: Set<String> = [
            "alter", "and", "as", "asc", "begin", "by", "create",
            "delete", "desc", "distinct", "drop", "from", "group",
            "having", "insert", "into", "join", "limit", "not",
            "null", "on", "or", "order", "select", "set", "table",
            "union", "update", "values", "where"
        ]
    }

    static func lexCode(_ source: NSString, range: NSRange, profile: Profile) -> [Span] {
        let end = NSMaxRange(range)
        var index = range.location
        var spans: [Span] = []
        while index < end, spans.count < maximumSpans {
            if let pair = profile.blockComments.first(where: { matches($0.0, at: index, in: source, end: end) }) {
                let stop = consume(until: pair.1, from: index + pair.0.count, in: source, end: end)
                spans.append(Span(range: NSRange(location: index, length: stop - index), kind: .comment))
                index = stop; continue
            }
            if let marker = profile.lineComments.first(where: { matches($0, at: index, in: source, end: end) }) {
                let stop = lineEnd(from: index + marker.count, in: source, end: end)
                spans.append(Span(range: NSRange(location: index, length: stop - index), kind: .comment))
                index = stop; continue
            }
            let unit = source.character(at: index)
            if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                let stop = quotedEnd(quote: unit, from: index + 1, in: source, end: end)
                spans.append(Span(range: NSRange(location: index, length: stop - index), kind: .string))
                index = stop; continue
            }
            if isDigit(unit), index == range.location || !isIdentifier(source.character(at: index - 1)) {
                var stop = index + 1
                while stop < end, isNumberPart(source.character(at: stop)) { stop += 1 }
                spans.append(Span(range: NSRange(location: index, length: stop - index), kind: .number))
                index = stop; continue
            }
            if isIdentifierStart(unit) {
                var stop = index + 1
                while stop < end, isIdentifier(source.character(at: stop)),
                      stop - index <= maximumIdentifierUTF16Length { stop += 1 }
                let token = source.substring(with: NSRange(location: index, length: stop - index))
                    .lowercased()
                let kind: Kind? = profile.constants.contains(token) ? .constant
                    : profile.keywords.contains(token) ? .keyword
                    : profile.types.contains(token) ? .type : nil
                if let kind { spans.append(Span(range: NSRange(location: index, length: stop - index), kind: kind)) }
                index = stop; continue
            }
            index += 1
        }
        return spans
    }

    static func lexMarkup(_ source: NSString, range: NSRange) -> [Span] {
        let end = NSMaxRange(range)
        var index = range.location
        var spans: [Span] = []
        while index < end, spans.count < maximumSpans {
            if matches(units("<!--"), at: index, in: source, end: end) {
                let stop = consume(until: units("-->"), from: index + 4, in: source, end: end)
                spans.append(Span(range: NSRange(location: index, length: stop - index), kind: .comment))
                index = stop; continue
            }
            if source.character(at: index) == 0x3C {
                let stop = min(end, first(0x3E, from: index + 1, in: source, end: end).map { $0 + 1 } ?? end)
                spans.append(Span(range: NSRange(location: index, length: stop - index), kind: .markup))
                var quote = index + 1
                while quote < stop {
                    let unit = source.character(at: quote)
                    if unit == 0x22 || unit == 0x27 {
                        let quoted = quotedEnd(quote: unit, from: quote + 1, in: source, end: stop)
                        spans.append(Span(range: NSRange(location: quote, length: quoted - quote), kind: .string))
                        quote = quoted
                    } else { quote += 1 }
                }
                index = stop; continue
            }
            index += 1
        }
        return spans
    }

    static func lexMarkdown(_ source: NSString, range: NSRange) -> [Span] {
        let end = NSMaxRange(range)
        var index = range.location
        var spans: [Span] = []
        while index < end, spans.count < maximumSpans {
            let lineStart = index
            let stop = lineEnd(from: index, in: source, end: end)
            var firstNonspace = lineStart
            while firstNonspace < stop, source.character(at: firstNonspace) == 0x20 { firstNonspace += 1 }
            let unit = firstNonspace < stop ? source.character(at: firstNonspace) : 0
            if unit == 0x23 || unit == 0x3E || unit == 0x2D || unit == 0x2A {
                spans.append(Span(range: NSRange(location: firstNonspace, length: stop - firstNonspace), kind: .markup))
            }
            var cursor = lineStart
            while cursor < stop, spans.count < maximumSpans {
                let character = source.character(at: cursor)
                if character == 0x60 {
                    let closing = first(0x60, from: cursor + 1, in: source, end: stop)
                    let tokenEnd = closing.map { $0 + 1 } ?? stop
                    spans.append(Span(range: NSRange(location: cursor, length: tokenEnd - cursor), kind: .string))
                    cursor = tokenEnd
                } else if character == 0x5B || character == 0x2A || character == 0x5F {
                    let closingUnit: UInt16 = character == 0x5B ? 0x5D : character
                    if let closing = first(closingUnit, from: cursor + 1, in: source, end: stop) {
                        spans.append(Span(range: NSRange(location: cursor, length: closing + 1 - cursor), kind: .markup))
                        cursor = closing + 1
                    } else { cursor += 1 }
                } else { cursor += 1 }
            }
            index = stop < end ? stop + 1 : end
        }
        return spans
    }

    static func quotedEnd(quote: UInt16, from start: Int, in source: NSString, end: Int) -> Int {
        var index = start
        var escaped = false
        while index < end {
            let unit = source.character(at: index)
            if escaped { escaped = false }
            else if unit == 0x5C { escaped = true }
            else if unit == quote { return index + 1 }
            else if unit == 0x0A || unit == 0x0D { return index }
            index += 1
        }
        return end
    }

    static func consume(until marker: [UInt16], from start: Int, in source: NSString, end: Int) -> Int {
        var index = start
        while index < end {
            if matches(marker, at: index, in: source, end: end) {
                return min(end, index + marker.count)
            }
            index += 1
        }
        return end
    }

    static func lineEnd(from start: Int, in source: NSString, end: Int) -> Int {
        var index = start
        while index < end {
            let unit = source.character(at: index)
            if unit == 0x0A || unit == 0x0D { return index }
            index += 1
        }
        return end
    }

    static func first(_ unit: UInt16, from start: Int, in source: NSString, end: Int) -> Int? {
        var index = start
        while index < end {
            if source.character(at: index) == unit { return index }
            index += 1
        }
        return nil
    }

    static func matches(_ marker: [UInt16], at index: Int, in source: NSString, end: Int) -> Bool {
        guard !marker.isEmpty, index >= 0, marker.count <= end - index else { return false }
        for offset in marker.indices where source.character(at: index + offset) != marker[offset] {
            return false
        }
        return true
    }

    static func units(_ value: String) -> [UInt16] { Array(value.utf16) }
    static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        unit == 0x5F || unit == 0x24 || (0x41...0x5A).contains(unit)
            || (0x61...0x7A).contains(unit)
    }
    static func isIdentifier(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }
    static func isNumberPart(_ unit: UInt16) -> Bool {
        isDigit(unit) || unit == 0x2E || unit == 0x5F
            || (0x41...0x46).contains(unit) || (0x61...0x66).contains(unit)
            || unit == 0x58 || unit == 0x78
    }
    static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: length, length: 0) }
        let start = min(length, max(0, range.location))
        return NSRange(location: start, length: min(max(0, range.length), length - start))
    }
}
