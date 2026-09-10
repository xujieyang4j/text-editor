@preconcurrency import Foundation

public enum CompletionSource: String, Codable, Equatable, Sendable {
    case languageServer
    case workspaceWord
}

public struct CompletionSuggestion: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let detail: String?
    public let documentation: String?
    public let insertionText: String
    public let source: CompletionSource

    public init(
        id: String, label: String, detail: String? = nil,
        documentation: String? = nil, insertionText: String? = nil,
        source: CompletionSource
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertionText = insertionText ?? label
        self.source = source
    }
}

public struct CompletionQuery: Equatable, Sendable {
    public let documentID: String
    public let viewID: EditorViewID
    public let revision: UInt64
    public let text: String
    public let cursorUTF16Offset: Int
    public let tokenFrom: Int
    public let tokenTo: Int
    public let token: String

    public var tokenRange: NSRange {
        NSRange(location: tokenFrom, length: tokenTo - tokenFrom)
    }

    public init(
        documentID: String, viewID: EditorViewID, revision: UInt64,
        text: String, cursorUTF16Offset: Int, tokenFrom: Int, tokenTo: Int, token: String
    ) {
        self.documentID = documentID
        self.viewID = viewID
        self.revision = revision
        self.text = text
        self.cursorUTF16Offset = cursorUTF16Offset
        self.tokenFrom = tokenFrom
        self.tokenTo = tokenTo
        self.token = token
    }
}

/// Pure UTF-16 helpers matching Electron's CodeMirror completion source.
public enum CompletionPlanner {
    public static let minimumTokenLength = 2
    public static let maximumWordLength = 81
    public static let maximumCollectedSuggestions = 300
    public static let maximumDisplayedSuggestions = 100
    public static let maximumWorkspaceWords = 20_000
    public static let workspaceCacheTTL: TimeInterval = 60
    public static let maximumWorkspaceFileBytes: Int64 = 2 * 1_024 * 1_024

    public static func query(
        documentID: String, viewID: EditorViewID, revision: UInt64,
        text: String, cursorUTF16Offset requestedOffset: Int
    ) -> CompletionQuery? {
        let units = Array(text.utf16)
        let cursor = min(units.count, max(0, requestedOffset))
        var start = cursor
        while start > 0, isContinuation(units[start - 1]) { start -= 1 }
        while start < cursor, !isStart(units[start]) { start += 1 }
        guard start < cursor else { return nil }
        let length = cursor - start
        guard length >= minimumTokenLength else { return nil }
        let token = String(decoding: units[start..<cursor], as: UTF16.self)
        return CompletionQuery(
            documentID: documentID, viewID: viewID, revision: revision, text: text,
            cursorUTF16Offset: cursor, tokenFrom: start, tokenTo: cursor,
            token: token
        )
    }

    /// Equivalent to JavaScript `/[A-Za-z_$][\w$]{1,80}/g`: ASCII first
    /// character and JavaScript `\w` continuation characters.
    public static func words(
        in text: String, limit: Int = maximumWorkspaceWords
    ) -> [String] {
        let limit = max(0, min(limit, maximumWorkspaceWords))
        guard limit > 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(min(limit, 256))
        var seen = Set<String>()
        scanWords(in: text) { word in
            guard seen.insert(word).inserted else { return true }
            result.append(word)
            return result.count < limit
        }
        return result
    }

    public static func workspaceSuggestions(
        token: String, openBufferTexts: [String], workspaceWords: [String],
        currentText: String
    ) -> [CompletionSuggestion] {
        guard token.utf16.count >= minimumTokenLength else { return [] }
        let foldedToken = token.lowercased()
        var values: [String] = []
        values.reserveCapacity(maximumCollectedSuggestions)
        var seen = Set<String>()

        func add(_ word: String) {
            guard values.count < maximumCollectedSuggestions, word != token,
                  word.lowercased().hasPrefix(foldedToken), seen.insert(word).inserted
            else { return }
            values.append(word)
        }

        for text in openBufferTexts {
            scanWords(in: text) { word in
                add(word)
                return values.count < maximumCollectedSuggestions
            }
            if values.count >= maximumCollectedSuggestions { break }
        }
        if values.count < maximumCollectedSuggestions {
            for word in workspaceWords {
                add(word)
                if values.count >= maximumCollectedSuggestions { break }
            }
        }
        if values.count < maximumCollectedSuggestions {
            scanWords(in: currentText) { word in
                add(word)
                return values.count < maximumCollectedSuggestions
            }
        }

        return values.sorted().prefix(maximumDisplayedSuggestions).enumerated().map {
            CompletionSuggestion(
                id: "workspace:\($0.offset):\($0.element)",
                label: $0.element, source: .workspaceWord
            )
        }
    }

    public static func languageServerSuggestions(
        _ items: [LanguageCompletionItem]
    ) -> [CompletionSuggestion] {
        items.prefix(maximumDisplayedSuggestions).enumerated().map { index, item in
            CompletionSuggestion(
                id: "lsp:\(index):\(item.label)", label: item.label,
                detail: item.detail, documentation: item.documentation,
                insertionText: item.insertText, source: .languageServer
            )
        }
    }

    public static func insertionTransaction(
        suggestion: CompletionSuggestion, query: CompletionQuery
    ) -> TextTransaction? {
        let cursor = query.tokenRange.location + suggestion.insertionText.utf16.count
        return try? TextTransaction(
            edits: [TextEdit(
                from: query.tokenRange.location, to: NSMaxRange(query.tokenRange),
                insert: suggestion.insertionText
            )],
            selection: .cursor(at: cursor),
            expectedRevision: query.revision
        )
    }

    private static func isStart(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 36
    }

    private static func isContinuation(_ unit: UInt16) -> Bool {
        isStart(unit) || (48...57).contains(unit)
    }

    private static func scanWords(
        in text: String, visit: (String) -> Bool
    ) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            guard isStart(units[index]) else { index += 1; continue }
            let start = index
            index += 1
            while index < units.count, isContinuation(units[index]) {
                guard index - start < maximumWordLength else { break }
                index += 1
            }
            let length = index - start
            if length >= minimumTokenLength, length <= maximumWordLength,
               !visit(String(decoding: units[start..<index], as: UTF16.self)) {
                return
            }
        }
    }
}
