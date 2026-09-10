import Foundation
import LumenEditorCore

/// The frozen JSON envelope returned by `CodeMirrorParserBundle.js`.
struct CodeMirrorParserEnvelope: Decodable, Equatable, Sendable {
    let result: CodeMirrorParserResult
}

/// Untrusted wire data. Decoding only proves that the frozen JSON shape is
/// present; callers must use `validated(text:language:)` before consuming it.
struct CodeMirrorParserResult: Decodable, Equatable, Sendable {
    static let schemaVersion = 2
    static let maximumHighlights = 20_000
    static let maximumSyntaxNodes = 50_000
    static let maximumBracketPairs = 10_000
    static let maximumFolds = 10_000
    static let maximumSymbols = 5_000
    static let maximumIndentationEntries = 100_000
    static let maximumNewlineIndentationEntries = 8
    static let maximumNewlineIndentationTransitions = 48
    static let maximumLanguageUTF16Length = 128
    static let maximumNodeTypeUTF16Length = 128
    static let maximumSymbolLabelUTF16Length = 1_024
    static let maximumSymbolLevel = 256
    static let maximumSyntaxDepth = 256
    static let maximumIndentationColumns = 1_000_000

    enum ParserKind: String, Codable, Equatable, Sendable {
        case lezer
        case stream
        case unsupported
    }

    struct Highlight: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case keyword
            case string
            case number
            case comment
            case type
            case constant
            case markup
        }

        let from: Int
        let to: Int
        let kind: Kind
    }

    struct SyntaxNode: Codable, Equatable, Sendable {
        let from: Int
        let to: Int
        let type: String
        let parent: Int
    }

    struct BracketPair: Codable, Equatable, Sendable {
        let open: Int
        let close: Int
    }

    struct Fold: Codable, Equatable, Sendable {
        let fullFrom: Int
        let fullTo: Int
        let from: Int
        let to: Int
        let startLine: Int
        let endLine: Int
    }

    struct Symbol: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case type
            case function
            case method
            case variable
            case heading
        }

        let label: String
        let kind: Kind
        let from: Int
        let to: Int
        let line: Int
        let level: Int
    }

    struct LineIndentation: Codable, Equatable, Sendable {
        let lineFrom: Int
        let columns: Int?
    }

    struct NewlineIndentation: Decodable, Equatable, Sendable {
        let position: Int
        let columns: Int?
        let doubleColumns: Int?
        let explode: Bool?

        init(
            position: Int, columns: Int?, doubleColumns: Int? = nil,
            explode: Bool? = nil
        ) {
            self.position = position
            self.columns = columns
            self.doubleColumns = doubleColumns
            self.explode = explode
        }

        private enum CodingKeys: String, CodingKey {
            case position, columns, doubleColumns, explode
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            position = try container.decode(Int.self, forKey: .position)
            columns = try container.decodeIfPresent(Int.self, forKey: .columns)
            doubleColumns = try container.decodeIfPresent(
                Int.self, forKey: .doubleColumns
            )
            explode = try container.decodeIfPresent(Bool.self, forKey: .explode)
        }
    }

    struct NewlineIndentationTransition: Decodable, Equatable, Sendable {
        let position: Int
        let insert: String
        let columns: Int?
        let doubleColumns: Int?
        let explode: Bool?

        init(
            position: Int, insert: String, columns: Int?,
            doubleColumns: Int? = nil, explode: Bool? = nil
        ) {
            self.position = position
            self.insert = insert
            self.columns = columns
            self.doubleColumns = doubleColumns
            self.explode = explode
        }

        private enum CodingKeys: String, CodingKey {
            case position, insert, columns, doubleColumns, explode
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            position = try container.decode(Int.self, forKey: .position)
            insert = try container.decode(String.self, forKey: .insert)
            columns = try container.decodeIfPresent(Int.self, forKey: .columns)
            doubleColumns = try container.decodeIfPresent(
                Int.self, forKey: .doubleColumns
            )
            explode = try container.decodeIfPresent(Bool.self, forKey: .explode)
        }
    }

    struct Truncated: Codable, Equatable, Sendable {
        let source: Bool
        let highlights: Bool
        let syntaxNodes: Bool
        let bracketPairs: Bool
        let folds: Bool
        let symbols: Bool
        let indentation: Bool
    }

    let schemaVersion: Int
    let supported: Bool
    let parserKind: ParserKind
    let requestedLanguage: String
    let resolvedLanguage: String
    let sourceUTF16Length: Int
    let highlights: [Highlight]
    let syntaxNodes: [SyntaxNode]
    let bracketPairs: [BracketPair]
    let folds: [Fold]
    let symbols: [Symbol]
    let indentation: [LineIndentation]
    let newlineIndentation: [NewlineIndentation]?
    let newlineIndentationTransitions: [NewlineIndentationTransition]?
    let truncated: Truncated

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, supported, parserKind, requestedLanguage
        case resolvedLanguage, sourceUTF16Length, highlights, syntaxNodes
        case bracketPairs, folds, symbols, indentation, newlineIndentation
        case newlineIndentationTransitions, truncated
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        supported = try container.decode(Bool.self, forKey: .supported)
        parserKind = try container.decode(ParserKind.self, forKey: .parserKind)
        requestedLanguage = try container.decode(String.self, forKey: .requestedLanguage)
        resolvedLanguage = try container.decode(String.self, forKey: .resolvedLanguage)
        sourceUTF16Length = try container.decode(Int.self, forKey: .sourceUTF16Length)
        highlights = try container.decode([Highlight].self, forKey: .highlights)
        syntaxNodes = try container.decode([SyntaxNode].self, forKey: .syntaxNodes)
        bracketPairs = try container.decode([BracketPair].self, forKey: .bracketPairs)
        folds = try container.decode([Fold].self, forKey: .folds)
        symbols = try container.decode([Symbol].self, forKey: .symbols)
        indentation = try container.decode([LineIndentation].self, forKey: .indentation)
        newlineIndentation = try container.decodeIfPresent(
            [NewlineIndentation].self, forKey: .newlineIndentation
        )
        newlineIndentationTransitions = try container.decodeIfPresent(
            [NewlineIndentationTransition].self,
            forKey: .newlineIndentationTransitions
        )
        truncated = try container.decode(Truncated.self, forKey: .truncated)
    }

    func validated(text: String, language: String) -> CodeMirrorParserAnalysis? {
        guard schemaVersion == Self.schemaVersion,
              requestedLanguage == language,
              sourceUTF16Length == text.utf16.count,
              Self.isSafeString(
                  requestedLanguage, maximumUTF16Length: Self.maximumLanguageUTF16Length,
                  allowsEmpty: true
              ),
              Self.isSafeString(
                  resolvedLanguage, maximumUTF16Length: Self.maximumLanguageUTF16Length,
                  allowsEmpty: true
              ),
              highlights.count <= Self.maximumHighlights,
              syntaxNodes.count <= Self.maximumSyntaxNodes,
              bracketPairs.count <= Self.maximumBracketPairs,
              folds.count <= Self.maximumFolds,
              symbols.count <= Self.maximumSymbols,
              indentation.count <= Self.maximumIndentationEntries,
              (newlineIndentation?.count ?? 0)
                  <= Self.maximumNewlineIndentationEntries,
              (newlineIndentationTransitions?.count ?? 0)
                  <= Self.maximumNewlineIndentationTransitions else { return nil }

        if supported {
            switch parserKind {
            case .lezer:
                guard !syntaxNodes.isEmpty else { return nil }
            case .stream:
                // A StreamLanguage tree contains styling tokens, not a
                // grammar tree. The bridge deliberately exposes only a
                // sentinel root plus independently scanned bracket pairs, so
                // downstream code cannot treat stream tokens as Lezer syntax.
                guard syntaxNodes.count == 1,
                      syntaxNodes[0] == SyntaxNode(
                          from: 0, to: sourceUTF16Length,
                          type: "Document", parent: -1
                      ),
                      folds.isEmpty, symbols.isEmpty,
                      !truncated.syntaxNodes, !truncated.folds, !truncated.symbols
                else { return nil }
            case .unsupported:
                return nil
            }
        } else {
            guard parserKind == .unsupported, highlights.isEmpty, syntaxNodes.isEmpty,
                  bracketPairs.isEmpty, folds.isEmpty, symbols.isEmpty, indentation.isEmpty,
                  newlineIndentation?.isEmpty != false,
                  newlineIndentationTransitions?.isEmpty != false,
                  !truncated.source, !truncated.highlights, !truncated.syntaxNodes,
                  !truncated.bracketPairs, !truncated.folds, !truncated.symbols,
                  !truncated.indentation
            else { return nil }
        }

        let source = Array(text.utf16)
        guard Self.validHighlights(highlights, sourceLength: source.count),
              Self.validSyntaxNodes(syntaxNodes, sourceLength: source.count),
              Self.validBracketPairs(bracketPairs, source: source),
              Self.validFolds(folds, source: source),
              Self.validSymbols(symbols, source: source),
              Self.validIndentation(indentation, source: source),
              Self.validNewlineIndentation(
                  newlineIndentation ?? [], sourceLength: source.count
              ),
              Self.validNewlineIndentationTransitions(
                  newlineIndentationTransitions ?? [], sourceLength: source.count
              ) else { return nil }
        return CodeMirrorParserAnalysis(
            supported: supported,
            parserKind: parserKind,
            requestedLanguage: requestedLanguage,
            resolvedLanguage: resolvedLanguage,
            sourceUTF16Length: sourceUTF16Length,
            highlights: highlights,
            syntaxNodes: syntaxNodes,
            bracketPairs: bracketPairs,
            folds: folds,
            symbols: symbols,
            indentation: indentation,
            newlineIndentation: newlineIndentation ?? [],
            newlineIndentationTransitions: newlineIndentationTransitions ?? [],
            truncated: truncated
        )
    }

    func validated(
        forText text: String, requestedLanguage language: String
    ) -> CodeMirrorParserAnalysis? {
        validated(text: text, language: language)
    }
}

/// Trusted parser output. Construction is limited to the all-or-nothing
/// validator above so downstream editor code never handles partial wire data.
struct CodeMirrorParserAnalysis: Equatable, Sendable {
    typealias ParserKind = CodeMirrorParserResult.ParserKind
    typealias Highlight = CodeMirrorParserResult.Highlight
    typealias SyntaxNode = CodeMirrorParserResult.SyntaxNode
    typealias BracketPair = CodeMirrorParserResult.BracketPair
    typealias Fold = CodeMirrorParserResult.Fold
    typealias Symbol = CodeMirrorParserResult.Symbol
    typealias LineIndentation = CodeMirrorParserResult.LineIndentation
    typealias NewlineIndentation = CodeMirrorParserResult.NewlineIndentation
    typealias NewlineIndentationTransition =
        CodeMirrorParserResult.NewlineIndentationTransition
    typealias Truncated = CodeMirrorParserResult.Truncated

    let supported: Bool
    let parserKind: ParserKind
    let requestedLanguage: String
    let resolvedLanguage: String
    let sourceUTF16Length: Int
    let highlights: [Highlight]
    let syntaxNodes: [SyntaxNode]
    let bracketPairs: [BracketPair]
    let folds: [Fold]
    let symbols: [Symbol]
    let indentation: [LineIndentation]
    var newlineIndentation: [NewlineIndentation] {
        newlineIndentationStorage
    }
    var newlineIndentationTransitions: [NewlineIndentationTransition] {
        newlineIndentationTransitionsStorage
    }
    private let newlineIndentationStorage: [NewlineIndentation]
    private let newlineIndentationTransitionsStorage: [NewlineIndentationTransition]
    let truncated: Truncated

    init(
        supported: Bool, parserKind: ParserKind, requestedLanguage: String,
        resolvedLanguage: String, sourceUTF16Length: Int,
        highlights: [Highlight], syntaxNodes: [SyntaxNode],
        bracketPairs: [BracketPair], folds: [Fold], symbols: [Symbol],
        indentation: [LineIndentation],
        newlineIndentation: [NewlineIndentation] = [],
        newlineIndentationTransitions: [NewlineIndentationTransition] = [],
        truncated: Truncated
    ) {
        self.supported = supported
        self.parserKind = parserKind
        self.requestedLanguage = requestedLanguage
        self.resolvedLanguage = resolvedLanguage
        self.sourceUTF16Length = sourceUTF16Length
        self.highlights = highlights
        self.syntaxNodes = syntaxNodes
        self.bracketPairs = bracketPairs
        self.folds = folds
        self.symbols = symbols
        self.indentation = indentation
        newlineIndentationStorage = newlineIndentation
        newlineIndentationTransitionsStorage = newlineIndentationTransitions
        self.truncated = truncated
    }

    func parsedSyntaxSnapshot(expectedRevision: UInt64) -> ParsedSyntaxSnapshot? {
        guard supported else { return nil }
        let hasLezerStructure = parserKind == .lezer
        return ParsedSyntaxSnapshot(
            sourceUTF16Length: sourceUTF16Length,
            nodes: syntaxNodes.map {
                .init(from: $0.from, to: $0.to, parent: $0.parent, type: $0.type)
            },
            bracketPairs: bracketPairs.map { .init(open: $0.open, close: $0.close) },
            indentation: indentation.compactMap { entry in
                entry.columns.map { .init(lineFrom: entry.lineFrom, columns: $0) }
            },
            // Core editing commands already use these flags as a fail-closed
            // signal to invoke their lexical parent fallback. A StreamLanguage
            // has no grammar tree, but its token-aware bracket scan is trusted
            // whenever that independently bounded result is complete.
            nodesWereTruncated: !hasLezerStructure || truncated.syntaxNodes,
            bracketPairsWereTruncated: truncated.source || truncated.bracketPairs,
            indentationWasTruncated: truncated.source || truncated.indentation,
            expectedRevision: expectedRevision
        )
    }

    func syntaxHighlightSnapshot(
        documentID: String, documentRevision: UInt64
    ) -> NativeSyntaxHighlighter.ParsedSnapshot? {
        guard supported else { return nil }
        return NativeSyntaxHighlighter.ParsedSnapshot(
            sourceUTF16Length: sourceUTF16Length,
            documentID: documentID,
            language: requestedLanguage,
            documentRevision: documentRevision,
            spans: highlights.map { highlight in
                NativeSyntaxHighlighter.Span(
                    range: NSRange(
                        location: highlight.from, length: highlight.to - highlight.from
                    ),
                    kind: highlight.kind.nativeKind
                )
            },
            wasTruncated: truncated.source || truncated.highlights
        )
    }

    func outlineDocumentModel(limits: OutlineLimits = .default) -> OutlineDocumentModel {
        let sourceWasTruncated = truncated.source
            || sourceUTF16Length > limits.maximumSourceUTF16Count
        let acceptedSymbols = symbols.filter {
            $0.to <= limits.maximumSourceUTF16Count
                && $0.level <= limits.maximumNestingDepth
        }
        let acceptedFolds = folds.filter {
            $0.fullTo <= limits.maximumSourceUTF16Count
        }
        let symbolLimit = min(limits.maximumSymbols, acceptedSymbols.count)
        let foldLimit = min(limits.maximumFoldRegions, acceptedFolds.count)

        return OutlineDocumentModel(
            symbols: acceptedSymbols.prefix(symbolLimit).map { symbol in
                OutlineSymbol(
                    label: symbol.label,
                    kind: symbol.kind.outlineKind,
                    utf16Offset: symbol.from,
                    line: symbol.line,
                    level: symbol.level
                )
            },
            foldRegions: acceptedFolds.prefix(foldLimit).map { fold in
                TextFoldRegion(
                    startLine: fold.startLine,
                    endLine: fold.endLine,
                    fullRange: NSRange(
                        location: fold.fullFrom, length: fold.fullTo - fold.fullFrom
                    ),
                    hiddenRange: NSRange(location: fold.from, length: fold.to - fold.from)
                )
            },
            sourceWasTruncated: sourceWasTruncated,
            symbolsWereTruncated: truncated.symbols
                || acceptedSymbols.count != symbols.count
                || acceptedSymbols.count > symbolLimit,
            foldsWereTruncated: truncated.folds
                || acceptedFolds.count != folds.count
                || acceptedFolds.count > foldLimit
        )
    }
}

/// Exact parser indentation prepared for synchronous native input handling.
///
/// Exact `simulateBreak` answers for the current cursors take precedence. The
/// ordinary line-indentation array is retained as a proven-safe fallback only
/// at an existing non-blank line start where earlier collector overrides were
/// no-ops for the source text. A bounded transition table can carry one answer
/// through the immediately following single-character edit.
struct CodeMirrorIndentationSnapshot: Equatable, Sendable {
    private struct NewlineAnswer: Equatable, Sendable {
        let normal: Int?
        let double: Int?
        let explode: Bool?
    }

    struct Entry: Equatable, Sendable {
        let lineFrom: Int
        let columns: Int?
    }

    struct NewlineEntry: Equatable, Sendable {
        let position: Int
        let columns: Int?
        let doubleColumns: Int?
        let explode: Bool?

        init(
            position: Int, columns: Int?, doubleColumns: Int? = nil,
            explode: Bool? = nil
        ) {
            self.position = position
            self.columns = columns
            self.doubleColumns = doubleColumns
            self.explode = explode
        }
    }

    struct TransitionEntry: Equatable, Sendable {
        let position: Int
        let insert: String
        let columns: Int?
        let doubleColumns: Int?
        let explode: Bool?

        init(
            position: Int, insert: String, columns: Int?,
            doubleColumns: Int? = nil, explode: Bool? = nil
        ) {
            self.position = position
            self.insert = insert
            self.columns = columns
            self.doubleColumns = doubleColumns
            self.explode = explode
        }
    }

    let sourceUTF16: [UInt16]
    let languageUTF16: [UInt16]
    let revision: UInt64
    let tabWidth: Int
    let indentWidth: Int
    let insertSpaces: Bool
    let entries: [Entry]
    private let newlineColumnsByPosition: [Int: Int]
    private let exactNewlineColumnsByPosition: [Int: NewlineAnswer]
    private let transitionColumnsByPosition: [Int: [String: NewlineAnswer]]

    init?(
        text: String, language: String, revision: UInt64,
        tabWidth: Int, indentWidth: Int, insertSpaces: Bool,
        entries: [Entry], newlineEntries: [NewlineEntry] = [],
        transitionEntries: [TransitionEntry] = []
    ) {
        guard (1...16).contains(tabWidth), (1...16).contains(indentWidth) else {
            return nil
        }
        let source = Array(text.utf16)
        let lineStarts = Self.lineStarts(in: source)
        guard entries.count == lineStarts.count,
              zip(entries, lineStarts).allSatisfy({ pair in
                  pair.0.lineFrom == pair.1
                      && pair.0.columns.map {
                          (0...CodeMirrorParserResult.maximumIndentationColumns).contains($0)
                      } != false
              }), newlineEntries.count
                  <= CodeMirrorParserResult.maximumNewlineIndentationEntries else { return nil }
        var exactNewlineColumns: [Int: NewlineAnswer] = [:]
        var previousNewlinePosition = -1
        for entry in newlineEntries {
            guard entry.position > previousNewlinePosition, entry.position <= source.count,
                  entry.columns.map({
                      (0...CodeMirrorParserResult.maximumIndentationColumns).contains($0)
                  }) != false,
                  entry.doubleColumns.map({
                      (0...CodeMirrorParserResult.maximumIndentationColumns).contains($0)
                  }) != false else { return nil }
            exactNewlineColumns[entry.position] = NewlineAnswer(
                normal: entry.columns, double: entry.doubleColumns,
                explode: entry.explode
            )
            previousNewlinePosition = entry.position
        }
        guard transitionEntries.count
            <= CodeMirrorParserResult.maximumNewlineIndentationTransitions else { return nil }
        var transitionColumns: [Int: [String: NewlineAnswer]] = [:]
        var previousTransition: (position: Int, rank: Int)?
        for entry in transitionEntries {
            let rank = CodeMirrorParserResult.newlineTransitionRank(entry.insert)
            guard entry.position >= 0, entry.position <= source.count,
                  rank >= 0,
                  entry.columns.map({
                      (0...CodeMirrorParserResult.maximumIndentationColumns).contains($0)
                  }) != false, entry.doubleColumns.map({
                      (0...CodeMirrorParserResult.maximumIndentationColumns).contains($0)
                  }) != false,
                  transitionColumns[entry.position]?.keys.contains(entry.insert) != true,
                  previousTransition.map({ previous in
                      entry.position > previous.position
                          || entry.position == previous.position && rank > previous.rank
                  }) ?? true
            else { return nil }
            transitionColumns[entry.position, default: [:]][entry.insert] = NewlineAnswer(
                normal: entry.columns, double: entry.doubleColumns,
                explode: entry.explode
            )
            previousTransition = (entry.position, rank)
        }

        var earlierOverridesMatchSource = true
        var newlineColumns: [Int: Int] = [:]
        newlineColumns.reserveCapacity(entries.count)
        for index in entries.indices {
            let entry = entries[index]
            let lineEnd = Self.lineEnd(
                at: index, starts: lineStarts, sourceLength: source.count
            )
            let line = source[entry.lineFrom..<lineEnd]
            let hasContent = line.contains(where: {
                !Self.isECMAScriptWhitespace($0)
            })
            let actualColumns = Self.asciiIndentationColumns(
                in: line, tabWidth: tabWidth
            )
            if earlierOverridesMatchSource, let columns = entry.columns,
               hasContent, actualColumns != nil {
                newlineColumns[entry.lineFrom] = columns
            }
            if let columns = entry.columns {
                guard let actualColumns, actualColumns == columns else {
                    earlierOverridesMatchSource = false
                    continue
                }
            }
        }

        sourceUTF16 = source
        languageUTF16 = Array(language.utf16)
        self.revision = revision
        self.tabWidth = tabWidth
        self.indentWidth = indentWidth
        self.insertSpaces = insertSpaces
        self.entries = entries
        newlineColumnsByPosition = newlineColumns
        exactNewlineColumnsByPosition = exactNewlineColumns
        transitionColumnsByPosition = transitionColumns
    }

    func matches(
        text: String, language: String, revision: UInt64,
        tabWidth: Int, indentWidth: Int, insertSpaces: Bool
    ) -> Bool {
        self.revision == revision
            && self.tabWidth == tabWidth
            && self.indentWidth == indentWidth
            && self.insertSpaces == insertSpaces
            && sourceUTF16 == Array(text.utf16)
            && languageUTF16 == Array(language.utf16)
    }

    func newlineIndentationColumns(
        atExistingLineStart position: Int, doubleBreak: Bool = false
    ) -> Int? {
        if let exact = exactNewlineColumnsByPosition[position] {
            return doubleBreak ? exact.double : exact.normal
        }
        return newlineColumnsByPosition[position]
    }

    func shouldExplodeNewline(at position: Int) -> Bool? {
        exactNewlineColumnsByPosition[position]?.explode
    }

    /// Carries one precomputed post-edit answer across the exact character
    /// insertion that produced it. No other stale syntax data is retained.
    func mappedThroughSingleCharacterInsertion(
        _ transaction: TextTransaction, from oldText: String, to newText: String,
        revision nextRevision: UInt64
    ) -> CodeMirrorIndentationSnapshot? {
        guard revision < UInt64.max, sourceUTF16 == Array(oldText.utf16),
              nextRevision == revision + 1,
              transaction.expectedRevision == revision, transaction.edits.count == 1,
              let edit = transaction.edits.first, edit.from == edit.to,
              edit.insert.utf16.count == 1,
              (try? transaction.applying(to: oldText)) == newText else { return nil }
        let nextPosition = edit.from + 1
        guard let value = transitionColumnsByPosition[edit.from]?[edit.insert]
        else { return nil }
        return CodeMirrorIndentationSnapshot(
            text: newText,
            language: String(
                utf16CodeUnits: languageUTF16, count: languageUTF16.count
            ),
            revision: nextRevision, tabWidth: tabWidth, indentWidth: indentWidth,
            insertSpaces: insertSpaces,
            entries: Self.fallbackEntries(for: newText),
            newlineEntries: [.init(
                position: nextPosition, columns: value.normal,
                doubleColumns: value.double, explode: value.explode
            )]
        )
    }

    /// Returns the bounded set of exact cursor positions worth probing.
    static func probePositions(
        for selections: SelectionSet, textUTF16Length: Int
    ) -> [Int] {
        guard selections.ranges.count
            <= CodeMirrorParserService.AnalyzeRequest
                .maximumNewlineIndentationPositions else { return [] }
        let cursors = selections.ranges.compactMap { range in
            range.isEmpty && range.head <= textUTF16Length ? range.head : nil
        }
        guard cursors.count == selections.ranges.count else { return [] }
        return Array(Set(cursors)).sorted()
    }
}

private extension CodeMirrorIndentationSnapshot {
    static func fallbackEntries(for text: String) -> [Entry] {
        lineStarts(in: Array(text.utf16)).map {
            .init(lineFrom: $0, columns: nil)
        }
    }

    static func lineStarts(in source: [UInt16]) -> [Int] {
        var starts = [0]
        // The bundle chooses LF as its separator whenever LF is present. Its
        // supported CRLF representation therefore leaves CR in `line.text`.
        let separator: UInt16? = source.contains(0x0A)
            ? 0x0A : (source.contains(0x0D) ? 0x0D : nil)
        guard let separator else { return starts }
        for index in source.indices where source[index] == separator {
            starts.append(index + 1)
        }
        return starts
    }

    static func lineEnd(at index: Int, starts: [Int], sourceLength: Int) -> Int {
        if index + 1 < starts.count {
            return starts[index + 1] - 1
        }
        return sourceLength
    }

    static func asciiIndentationColumns(
        in line: ArraySlice<UInt16>, tabWidth: Int
    ) -> Int? {
        var columns = 0
        for unit in line {
            if !isECMAScriptWhitespace(unit) { break }
            if unit == 0x20 {
                columns += 1
            } else if unit == 0x09 {
                columns += tabWidth - columns % tabWidth
            } else {
                // CodeMirror counts arbitrary Unicode whitespace by grapheme
                // cluster. Stay fail-closed instead of approximating it here.
                return nil
            }
        }
        return columns
    }

    static func isECMAScriptWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0,
             0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        case 0x2000...0x200A:
            return true
        default:
            return false
        }
    }
}

private extension CodeMirrorParserResult {
    static func validHighlights(_ values: [Highlight], sourceLength: Int) -> Bool {
        var previousTo = -1
        for value in values {
            guard validNonemptyRange(from: value.from, to: value.to, limit: sourceLength),
                  value.from >= previousTo else { return false }
            previousTo = value.to
        }
        return true
    }

    static func validSyntaxNodes(_ values: [SyntaxNode], sourceLength: Int) -> Bool {
        guard !values.isEmpty else { return true }
        guard let root = values.first, root.from == 0, root.to == sourceLength,
              root.parent == -1 else { return false }
        var activePath = [0]
        var lastChildEnd: [Int: Int] = [:]
        for (index, value) in values.enumerated() {
            guard validRange(from: value.from, to: value.to, limit: sourceLength),
                  isSafeString(
                      value.type, maximumUTF16Length: maximumNodeTypeUTF16Length
                  ) else { return false }
            guard index > 0 else { continue }
            // Zero-width recovery nodes may sit exactly at their parent's end.
            // The explicit parent chain plus containment/sibling checks remain
            // strict without rejecting that normal incomplete-code shape.
            while !activePath.isEmpty, activePath.last != value.parent {
                activePath.removeLast()
            }
            guard value.parent >= 0, value.parent < index,
                  activePath.last == value.parent,
                  activePath.count < maximumSyntaxDepth,
                  value.from >= (lastChildEnd[value.parent] ?? values[value.parent].from)
            else { return false }
            let parent = values[value.parent]
            guard parent.from <= value.from, parent.to >= value.to else { return false }
            lastChildEnd[value.parent] = value.to
            activePath.append(index)
        }
        return true
    }

    static func validBracketPairs(_ values: [BracketPair], source: [UInt16]) -> Bool {
        let matching: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
        var previousOpen = -1
        var containingCloses: [Int] = []
        var positions = Set<Int>()
        for value in values {
            while let close = containingCloses.last, value.open > close {
                containingCloses.removeLast()
            }
            guard value.open >= 0, value.open < value.close, value.close < source.count,
                  value.open > previousOpen,
                  matching[source[value.open]] == source[value.close],
                  containingCloses.last.map({ value.close < $0 }) ?? true,
                  positions.insert(value.open).inserted,
                  positions.insert(value.close).inserted else { return false }
            previousOpen = value.open
            containingCloses.append(value.close)
        }
        return true
    }

    static func validFolds(_ values: [Fold], source: [UInt16]) -> Bool {
        let starts = lineStarts(in: source)
        var previousFullFrom = -1
        var containingEnds: [Int] = []
        for value in values {
            while let end = containingEnds.last, value.fullFrom >= end {
                containingEnds.removeLast()
            }
            guard validNonemptyRange(
                      from: value.fullFrom, to: value.fullTo, limit: source.count
                  ),
                  validNonemptyRange(from: value.from, to: value.to, limit: source.count),
                  value.fullFrom <= value.from, value.to <= value.fullTo,
                  value.startLine >= 1, value.startLine < value.endLine,
                  value.endLine <= starts.count,
                  lineNumber(at: value.fullFrom, starts: starts) == value.startLine,
                  lineNumberForRangeEnd(value.fullTo, source: source, starts: starts)
                    == value.endLine,
                  value.fullFrom >= previousFullFrom,
                  containingEnds.last.map({ value.fullTo <= $0 }) ?? true
            else { return false }
            previousFullFrom = value.fullFrom
            containingEnds.append(value.fullTo)
        }
        return true
    }

    static func validSymbols(_ values: [Symbol], source: [UInt16]) -> Bool {
        let starts = lineStarts(in: source)
        var previousFrom = -1
        for value in values {
            guard validNonemptyRange(from: value.from, to: value.to, limit: source.count),
                  isSafeString(
                      value.label, maximumUTF16Length: maximumSymbolLabelUTF16Length
                  ),
                  value.line >= 1, value.line <= starts.count,
                  lineNumber(at: value.from, starts: starts) == value.line,
                  value.level >= 0, value.level <= maximumSymbolLevel,
                  value.from >= previousFrom else { return false }
            previousFrom = value.from
        }
        return true
    }

    static func validIndentation(_ values: [LineIndentation], source: [UInt16]) -> Bool {
        let starts = Set(lineStarts(in: source))
        var previousLineFrom = -1
        for value in values {
            guard value.lineFrom > previousLineFrom, starts.contains(value.lineFrom),
                  value.columns.map({ $0 >= 0 && $0 <= maximumIndentationColumns }) ?? true
            else { return false }
            previousLineFrom = value.lineFrom
        }
        return true
    }

    static func validNewlineIndentation(
        _ values: [NewlineIndentation], sourceLength: Int
    ) -> Bool {
        var previousPosition = -1
        for value in values {
            guard value.position > previousPosition,
                  value.position <= sourceLength,
                  value.columns.map({
                      $0 >= 0 && $0 <= maximumIndentationColumns
                  }) ?? true, value.doubleColumns.map({
                      $0 >= 0 && $0 <= maximumIndentationColumns
                  }) ?? true else { return false }
            previousPosition = value.position
        }
        return true
    }

    static func validNewlineIndentationTransitions(
        _ values: [NewlineIndentationTransition], sourceLength: Int
    ) -> Bool {
        let allowedInserts: Set<String> = ["(", "[", "{", ":", ",", ">"]
        var previous: (position: Int, rank: Int)?
        for value in values {
            guard value.position >= 0, value.position <= sourceLength,
                  allowedInserts.contains(value.insert),
                  value.insert.utf16.count == 1,
                  value.columns.map({
                      $0 >= 0 && $0 <= maximumIndentationColumns
                  }) ?? true, value.doubleColumns.map({
                      $0 >= 0 && $0 <= maximumIndentationColumns
                  }) ?? true else { return false }
            let rank = Self.newlineTransitionRank(value.insert)
            if let previous,
               value.position < previous.position
                || value.position == previous.position && rank <= previous.rank {
                return false
            }
            previous = (value.position, rank)
        }
        return true
    }

    static func newlineTransitionRank(_ value: String) -> Int {
        ["(", "[", "{", ":", ",", ">"].firstIndex(of: value) ?? -1
    }

    static func validRange(from: Int, to: Int, limit: Int) -> Bool {
        from >= 0 && to >= from && to <= limit
    }

    static func validNonemptyRange(from: Int, to: Int, limit: Int) -> Bool {
        from >= 0 && to > from && to <= limit
    }

    static func isSafeString(
        _ value: String,
        maximumUTF16Length: Int,
        allowsEmpty: Bool = false
    ) -> Bool {
        let count = value.utf16.count
        guard (allowsEmpty || count > 0), count <= maximumUTF16Length else { return false }
        return !value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
        }
    }

    static func lineStarts(in source: [UInt16]) -> [Int] {
        var starts = [0]
        var index = 0
        while index < source.count {
            if source[index] == 0x0D {
                index += 1
                if index < source.count, source[index] == 0x0A { index += 1 }
                starts.append(index)
                continue
            }
            if source[index] == 0x0A { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    static func lineNumber(at offset: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = low + (high - low) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }

    static func lineNumberForRangeEnd(
        _ offset: Int, source: [UInt16], starts: [Int]
    ) -> Int {
        guard offset > 0 else { return 1 }
        var lastIncluded = offset - 1
        if source[lastIncluded] == 0x0A {
            lastIncluded -= 1
            if lastIncluded >= 0, source[lastIncluded] == 0x0D { lastIncluded -= 1 }
        } else if source[lastIncluded] == 0x0D {
            lastIncluded -= 1
        }
        return lineNumber(at: max(0, lastIncluded), starts: starts)
    }
}

private extension CodeMirrorParserResult.Symbol.Kind {
    var outlineKind: OutlineSymbolKind {
        switch self {
        case .type: .type
        case .function: .function
        case .method: .method
        case .variable: .variable
        case .heading: .heading
        }
    }
}

private extension CodeMirrorParserResult.Highlight.Kind {
    var nativeKind: NativeSyntaxHighlighter.Kind {
        switch self {
        case .keyword: .keyword
        case .string: .string
        case .number: .number
        case .comment: .comment
        case .type: .type
        case .constant: .constant
        case .markup: .markup
        }
    }
}
