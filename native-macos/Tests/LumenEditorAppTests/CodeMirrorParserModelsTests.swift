import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class CodeMirrorParserModelsTests: XCTestCase {
    func testValidationRejectsMalformedNewlineIndentationProbes() throws {
        let valid = try decodeEnvelope(
            text: "value",
            newlineIndentation: [[
                "position": 5, "columns": 2, "doubleColumns": 4,
                "explode": false
            ]],
            newlineIndentationTransitions: [[
                "position": 5, "insert": ":", "columns": 2,
                "doubleColumns": 0, "explode": false
            ]]
        )
        XCTAssertNotNil(valid.result.validated(text: "value", language: "Swift"))

        let outOfBounds = try decodeEnvelope(
            text: "value", newlineIndentation: [["position": 6, "columns": 2]]
        )
        XCTAssertNil(outOfBounds.result.validated(text: "value", language: "Swift"))

        let unsafeTransition = try decodeEnvelope(
            text: "value", newlineIndentationTransitions: [[
                "position": 5, "insert": "x", "columns": 2
            ]]
        )
        XCTAssertNil(unsafeTransition.result.validated(
            text: "value", language: "Swift"
        ))
    }

    func testFrozenEnvelopeDecodesValidatesAndBuildsAdapters() throws {
        let text = "func f() {\n  return 1\n}\n"
        let envelope = try decodeEnvelope(
            text: text,
            highlights: [["from": 0, "to": 4, "kind": "keyword"]],
            syntaxNodes: [
                ["from": 0, "to": text.utf16.count, "type": "SourceFile", "parent": -1],
                ["from": 0, "to": 23, "type": "FunctionDeclaration", "parent": 0],
                ["from": 6, "to": 8, "type": "Parameters", "parent": 1]
            ],
            bracketPairs: [["open": 6, "close": 7], ["open": 9, "close": 22]],
            folds: [[
                "fullFrom": 0, "fullTo": 24, "from": 10, "to": 23,
                "startLine": 1, "endLine": 3
            ]],
            symbols: [[
                "label": "f", "kind": "function", "from": 5, "to": 6,
                "line": 1, "level": 0
            ]],
            indentation: [
                ["lineFrom": 0, "columns": 0],
                ["lineFrom": 11, "columns": 2],
                ["lineFrom": 22, "columns": NSNull()],
                ["lineFrom": 24, "columns": 0]
            ]
        )

        let analysis = try XCTUnwrap(envelope.result.validated(text: text, language: "Swift"))
        XCTAssertEqual(analysis.sourceUTF16Length, text.utf16.count)
        XCTAssertEqual(analysis.highlights.first?.kind, .keyword)

        let snapshot = try XCTUnwrap(analysis.parsedSyntaxSnapshot(expectedRevision: 42))
        XCTAssertEqual(snapshot.expectedRevision, 42)
        XCTAssertEqual(snapshot.nodes.map(\.type), ["SourceFile", "FunctionDeclaration", "Parameters"])
        XCTAssertEqual(snapshot.bracketPairs.count, 2)
        XCTAssertEqual(snapshot.indentation.map(\.lineFrom), [0, 11, 24])

        let outline = analysis.outlineDocumentModel(
            limits: .init(
                maximumSourceUTF16Count: text.utf16.count, maximumSymbols: 5,
                maximumFoldRegions: 5, maximumNestingDepth: 5
            )
        )
        XCTAssertEqual(outline.symbols.first?.label, "f")
        XCTAssertEqual(outline.symbols.first?.kind, .function)
        XCTAssertEqual(outline.foldRegions.first?.fullRange, NSRange(location: 0, length: 24))
        XCTAssertEqual(outline.foldRegions.first?.hiddenRange, NSRange(location: 10, length: 13))
        XCTAssertFalse(outline.sourceWasTruncated)
    }

    func testUnsupportedResultRequiresUnsupportedKindAndEmptyArrays() throws {
        let valid = try decodeEnvelope(
            text: "plain", supported: false, parserKind: "unsupported",
            requestedLanguage: "Plain Text",
            resolvedLanguage: "Plain Text"
        )
        XCTAssertNotNil(valid.result.validated(text: "plain", language: "Plain Text"))

        let populated = try decodeEnvelope(
            text: "plain", supported: false, parserKind: "unsupported",
            requestedLanguage: "Plain Text",
            resolvedLanguage: "Plain Text",
            highlights: [["from": 0, "to": 1, "kind": "string"]]
        )
        XCTAssertNil(populated.result.validated(text: "plain", language: "Plain Text"))

        let wrongKind = try decodeEnvelope(
            text: "plain", supported: false, parserKind: "lezer",
            requestedLanguage: "Plain Text",
            resolvedLanguage: "Plain Text"
        )
        XCTAssertNil(wrongKind.result.validated(text: "plain", language: "Plain Text"))

        let falselyTruncated = try decodeEnvelope(
            text: "plain", supported: false, parserKind: "unsupported",
            requestedLanguage: "Plain Text", resolvedLanguage: "Plain Text",
            truncated: [
                "source": false, "highlights": true, "syntaxNodes": false,
                "bracketPairs": false, "folds": false, "symbols": false,
                "indentation": false
            ]
        )
        XCTAssertNil(falselyTruncated.result.validated(
            text: "plain", language: "Plain Text"
        ))
    }

    func testStreamResultAcceptsSentinelTreeBracketsHighlightsAndIndentation() throws {
        let text = "let value = (1)\n  value"
        let valid = try decodeEnvelope(
            text: text, parserKind: "stream",
            highlights: [
                ["from": 0, "to": 3, "kind": "keyword"],
                ["from": 13, "to": 14, "kind": "number"]
            ],
            bracketPairs: [["open": 12, "close": 14]],
            indentation: [
                ["lineFrom": 0, "columns": 0],
                ["lineFrom": 16, "columns": 2]
            ]
        )
        let analysis = try XCTUnwrap(valid.result.validated(
            text: text, language: "Swift"
        ))

        XCTAssertEqual(analysis.parserKind, .stream)
        XCTAssertEqual(analysis.syntaxNodes, [
            .init(from: 0, to: text.utf16.count, type: "Document", parent: -1)
        ])
        XCTAssertEqual(analysis.highlights.map(\.kind), [.keyword, .number])
        XCTAssertEqual(analysis.indentation.map(\.columns), [0, 2])
        XCTAssertEqual(analysis.bracketPairs, [.init(open: 12, close: 14)])

        let wrongRoot = try decodeEnvelope(
            text: text, parserKind: "stream",
            syntaxNodes: [[
                "from": 0, "to": text.utf16.count,
                "type": "Root", "parent": -1
            ]]
        )
        XCTAssertNil(wrongRoot.result.validated(text: text, language: "Swift"))

        let tokenNode = try decodeEnvelope(
            text: text, parserKind: "stream",
            syntaxNodes: [
                ["from": 0, "to": text.utf16.count,
                 "type": "Document", "parent": -1],
                ["from": 0, "to": 3, "type": "Keyword", "parent": 0]
            ]
        )
        XCTAssertNil(tokenNode.result.validated(text: text, language: "Swift"))

        let structuralPayloads: [CodeMirrorParserEnvelope] = [
            try decodeEnvelope(
                text: "a\nb", parserKind: "stream",
                folds: [[
                    "fullFrom": 0, "fullTo": 3, "from": 1, "to": 3,
                    "startLine": 1, "endLine": 2
                ]]
            ),
            try decodeEnvelope(
                text: "value", parserKind: "stream",
                symbols: [[
                    "label": "value", "kind": "variable",
                    "from": 0, "to": 5, "line": 1, "level": 0
                ]]
            )
        ]
        XCTAssertTrue(structuralPayloads.allSatisfy { envelope in
            let payloadText: String
            switch envelope.result.sourceUTF16Length {
            case 3: payloadText = "a\nb"
            default: payloadText = "value"
            }
            return envelope.result.validated(text: payloadText, language: "Swift") == nil
        })
    }

    func testStreamResultRejectsGrammarStructuralTruncationFlags() throws {
        let structuralFlags = [
            "syntaxNodes", "folds", "symbols"
        ]
        for flag in structuralFlags {
            var truncated: [String: Any] = [
                "source": false, "highlights": false, "syntaxNodes": false,
                "bracketPairs": false, "folds": false, "symbols": false,
                "indentation": false
            ]
            truncated[flag] = true
            let envelope = try decodeEnvelope(
                text: "let value = 1", parserKind: "stream",
                truncated: truncated
            )

            XCTAssertNil(
                envelope.result.validated(text: "let value = 1", language: "Swift"),
                "stream result accepted structural truncation flag \(flag)"
            )
        }

        let bracketTruncation: [String: Any] = [
            "source": false, "highlights": false, "syntaxNodes": false,
            "bracketPairs": true, "folds": false, "symbols": false,
            "indentation": false
        ]
        let partial = try decodeEnvelope(
            text: "()[]", parserKind: "stream",
            bracketPairs: [["open": 0, "close": 1]],
            truncated: bracketTruncation
        )
        let analysis = try XCTUnwrap(partial.result.validated(
            text: "()[]", language: "Swift"
        ))
        XCTAssertTrue(analysis.truncated.bracketPairs)
    }

    func testStreamAdaptersRetainBracketsHighlightAndIndentation() throws {
        let text = "let value = (1)\n  value"
        let envelope = try decodeEnvelope(
            text: text, parserKind: "stream",
            highlights: [["from": 0, "to": 3, "kind": "keyword"]],
            bracketPairs: [["open": 12, "close": 14]],
            indentation: [
                ["lineFrom": 0, "columns": 0],
                ["lineFrom": 16, "columns": 2]
            ]
        )
        let analysis = try XCTUnwrap(envelope.result.validated(
            text: text, language: "Swift"
        ))

        let syntax = try XCTUnwrap(analysis.parsedSyntaxSnapshot(expectedRevision: 9))
        XCTAssertEqual(syntax.nodes.map(\.type), ["Document"])
        XCTAssertTrue(syntax.nodesWereTruncated)
        XCTAssertEqual(syntax.bracketPairs, [.init(open: 12, close: 14)])
        XCTAssertFalse(syntax.bracketPairsWereTruncated)
        XCTAssertFalse(syntax.indentationWasTruncated)
        XCTAssertEqual(syntax.indentation.map(\.lineFrom), [0, 16])
        XCTAssertEqual(syntax.indentation.map(\.columns), [0, 2])

        let highlight = try XCTUnwrap(analysis.syntaxHighlightSnapshot(
            documentID: "stream-doc", documentRevision: 9
        ))
        XCTAssertEqual(highlight.documentID, "stream-doc")
        XCTAssertEqual(highlight.documentRevision, 9)
        XCTAssertEqual(highlight.spans, [
            .init(range: NSRange(location: 0, length: 3), kind: .keyword)
        ])
        XCTAssertFalse(highlight.wasTruncated)

        let truncatedIndentation = try decodeEnvelope(
            text: text, parserKind: "stream",
            truncated: [
                "source": false, "highlights": false, "syntaxNodes": false,
                "bracketPairs": false, "folds": false, "symbols": false,
                "indentation": true
            ]
        )
        let truncatedAnalysis = try XCTUnwrap(truncatedIndentation.result.validated(
            text: text, language: "Swift"
        ))
        XCTAssertTrue(try XCTUnwrap(
            truncatedAnalysis.parsedSyntaxSnapshot(expectedRevision: 10)
        ).indentationWasTruncated)

        let partial = try decodeEnvelope(
            text: text, parserKind: "stream",
            bracketPairs: [["open": 12, "close": 14]],
            truncated: [
                "source": false, "highlights": false,
                "syntaxNodes": false, "bracketPairs": true,
                "folds": false, "symbols": false, "indentation": false
            ]
        )
        let partialAnalysis = try XCTUnwrap(partial.result.validated(
            text: text, language: "Swift"
        ))
        let partialSyntax = try XCTUnwrap(
            partialAnalysis.parsedSyntaxSnapshot(expectedRevision: 11)
        )
        XCTAssertTrue(partialSyntax.bracketPairsWereTruncated)
    }

    func testValidationRejectsLanguageLengthAndStringTrustFailures() throws {
        let envelope = try decodeEnvelope(text: "🙂", requestedLanguage: "Swift")
        XCTAssertNotNil(envelope.result.validated(text: "🙂", language: "Swift"))
        XCTAssertNil(envelope.result.validated(text: "🙂", language: "swift"))
        XCTAssertNil(envelope.result.validated(text: "x", language: "Swift"))

        var legacySchema = makeEnvelopeObject(text: "x")
        var legacyResult = try XCTUnwrap(legacySchema["result"] as? [String: Any])
        legacyResult["schemaVersion"] = 1
        legacySchema["result"] = legacyResult
        XCTAssertNil(try decode(legacySchema).result.validated(
            text: "x", language: "Swift"
        ))

        let control = try decodeEnvelope(
            text: "x", resolvedLanguage: "Swift\u{0007}"
        )
        XCTAssertNil(control.result.validated(text: "x", language: "Swift"))
    }

    func testUnknownEnumsAndMissingTruncationFlagFailDecode() throws {
        var object = makeEnvelopeObject(text: "x")
        var result = try XCTUnwrap(object["result"] as? [String: Any])
        result["highlights"] = [["from": 0, "to": 1, "kind": "unknown"]]
        object["result"] = result
        XCTAssertThrowsError(try decode(object))

        object = makeEnvelopeObject(text: "x")
        result = try XCTUnwrap(object["result"] as? [String: Any])
        var truncated = try XCTUnwrap(result["truncated"] as? [String: Any])
        truncated.removeValue(forKey: "folds")
        result["truncated"] = truncated
        object["result"] = result
        XCTAssertThrowsError(try decode(object))
    }

    func testSyntaxTreeRequiresStrictPreorderAndContainingParent() throws {
        let emptyTree = try decodeEnvelope(text: "", syntaxNodes: [])
        XCTAssertNil(emptyTree.result.validated(text: "", language: "Swift"))

        let skippedParent = try decodeEnvelope(
            text: "abcd",
            syntaxNodes: [
                ["from": 0, "to": 4, "type": "Root", "parent": -1],
                ["from": 0, "to": 4, "type": "Outer", "parent": 0],
                ["from": 1, "to": 2, "type": "Leaf", "parent": 0]
            ]
        )
        XCTAssertNil(skippedParent.result.validated(text: "abcd", language: "Swift"))

        let secondRoot = try decodeEnvelope(
            text: "abcd",
            syntaxNodes: [
                ["from": 0, "to": 4, "type": "Root", "parent": -1],
                ["from": 0, "to": 1, "type": "OtherRoot", "parent": -1]
            ]
        )
        XCTAssertNil(secondRoot.result.validated(text: "abcd", language: "Swift"))

        let partialRoot = try decodeEnvelope(
            text: "abcd",
            syntaxNodes: [["from": 1, "to": 4, "type": "Root", "parent": -1]]
        )
        XCTAssertNil(partialRoot.result.validated(text: "abcd", language: "Swift"))

        let overlappingSiblings = try decodeEnvelope(
            text: "abcd",
            syntaxNodes: [
                ["from": 0, "to": 4, "type": "Root", "parent": -1],
                ["from": 0, "to": 3, "type": "First", "parent": 0],
                ["from": 2, "to": 4, "type": "Overlap", "parent": 0]
            ]
        )
        XCTAssertNil(overlappingSiblings.result.validated(
            text: "abcd", language: "Swift"
        ))

        let zeroWidthRecovery = try decodeEnvelope(
            text: "(",
            syntaxNodes: [
                ["from": 0, "to": 1, "type": "Script", "parent": -1],
                ["from": 0, "to": 1, "type": "Expression", "parent": 0],
                ["from": 1, "to": 1, "type": "Error", "parent": 1]
            ]
        )
        XCTAssertNotNil(zeroWidthRecovery.result.validated(
            text: "(", language: "Swift"
        ))
    }

    func testBracketsRequireRealCharactersAndProperNesting() throws {
        let wrongCharacters = try decodeEnvelope(
            text: "ab", bracketPairs: [["open": 0, "close": 1]]
        )
        XCTAssertNil(wrongCharacters.result.validated(text: "ab", language: "Swift"))

        let crossing = try decodeEnvelope(
            text: "([)]",
            bracketPairs: [["open": 0, "close": 2], ["open": 1, "close": 3]]
        )
        XCTAssertNil(crossing.result.validated(text: "([)]", language: "Swift"))
    }

    func testFoldSymbolAndIndentationLineMetadataIsValidated() throws {
        let text = "a\nb\n"
        let badFold = try decodeEnvelope(
            text: text,
            folds: [[
                "fullFrom": 0, "fullTo": 4, "from": 1, "to": 4,
                "startLine": 2, "endLine": 2
            ]]
        )
        XCTAssertNil(badFold.result.validated(text: text, language: "Swift"))

        let badSymbol = try decodeEnvelope(
            text: text,
            symbols: [[
                "label": "b", "kind": "variable", "from": 2, "to": 3,
                "line": 1, "level": 0
            ]]
        )
        XCTAssertNil(badSymbol.result.validated(text: text, language: "Swift"))

        let badIndentation = try decodeEnvelope(
            text: text,
            indentation: [["lineFrom": 1, "columns": 0]]
        )
        XCTAssertNil(badIndentation.result.validated(text: text, language: "Swift"))
    }

    func testOutlineAdapterHonorsLimitsAndAllRelevantTruncationFlags() throws {
        let text = "a\nb\nc\n"
        let envelope = try decodeEnvelope(
            text: text,
            folds: [
                ["fullFrom": 0, "fullTo": 6, "from": 1, "to": 6, "startLine": 1, "endLine": 3],
                ["fullFrom": 2, "fullTo": 6, "from": 3, "to": 6, "startLine": 2, "endLine": 3]
            ],
            symbols: [
                ["label": "a", "kind": "variable", "from": 0, "to": 1, "line": 1, "level": 0],
                ["label": "b", "kind": "variable", "from": 2, "to": 3, "line": 2, "level": 2]
            ],
            truncated: ["source": false, "highlights": false, "syntaxNodes": false,
                        "bracketPairs": false, "folds": true, "symbols": false,
                        "indentation": false]
        )
        let analysis = try XCTUnwrap(envelope.result.validated(text: text, language: "Swift"))
        let model = analysis.outlineDocumentModel(
            limits: .init(
                maximumSourceUTF16Count: 4, maximumSymbols: 1,
                maximumFoldRegions: 1, maximumNestingDepth: 1
            )
        )
        XCTAssertEqual(model.symbols.map(\.label), ["a"])
        XCTAssertTrue(model.symbolsWereTruncated)
        XCTAssertTrue(model.foldRegions.isEmpty)
        XCTAssertTrue(model.foldsWereTruncated)
        XCTAssertTrue(model.sourceWasTruncated)
    }

    func testHighlightAdapterMapsAllKindsAndCarriesRevision() throws {
        let kinds = ["keyword", "string", "number", "comment", "type",
                     "constant", "markup"]
        let text = String(repeating: "x", count: kinds.count)
        let envelope = try decodeEnvelope(
            text: text,
            highlights: kinds.enumerated().map { index, kind in
                ["from": index, "to": index + 1, "kind": kind]
            }
        )
        let analysis = try XCTUnwrap(envelope.result.validated(
            text: text, language: "Swift"
        ))
        let snapshot = try XCTUnwrap(analysis.syntaxHighlightSnapshot(
            documentID: "doc", documentRevision: 12
        ))
        XCTAssertEqual(snapshot.documentID, "doc")
        XCTAssertEqual(snapshot.documentRevision, 12)
        XCTAssertEqual(snapshot.spans.map(\.kind), [
            .keyword, .string, .number, .comment, .type, .constant, .markup
        ])
    }
}

private extension CodeMirrorParserModelsTests {
    func decodeEnvelope(
        text: String,
        supported: Bool = true,
        parserKind: String = "lezer",
        requestedLanguage: String = "Swift",
        resolvedLanguage: String = "Swift",
        highlights: [[String: Any]] = [],
        syntaxNodes: [[String: Any]]? = nil,
        bracketPairs: [[String: Any]] = [],
        folds: [[String: Any]] = [],
        symbols: [[String: Any]] = [],
        indentation: [[String: Any]] = [],
        newlineIndentation: [[String: Any]] = [],
        newlineIndentationTransitions: [[String: Any]] = [],
        truncated: [String: Any] = [
            "source": false, "highlights": false, "syntaxNodes": false,
            "bracketPairs": false, "folds": false, "symbols": false,
            "indentation": false
        ]
    ) throws -> CodeMirrorParserEnvelope {
        let effectiveSyntaxNodes: [[String: Any]]
        if supported {
            effectiveSyntaxNodes = syntaxNodes ?? [[
                "from": 0, "to": text.utf16.count,
                "type": parserKind == "stream" ? "Document" : "Root",
                "parent": -1
            ]]
        } else {
            effectiveSyntaxNodes = syntaxNodes ?? []
        }
        try decode(makeEnvelopeObject(
            text: text, supported: supported, parserKind: parserKind,
            requestedLanguage: requestedLanguage, resolvedLanguage: resolvedLanguage,
            highlights: highlights,
            syntaxNodes: effectiveSyntaxNodes,
            bracketPairs: bracketPairs,
            folds: folds, symbols: symbols, indentation: indentation,
            newlineIndentation: newlineIndentation,
            newlineIndentationTransitions: newlineIndentationTransitions,
            truncated: truncated
        ))
    }

    func makeEnvelopeObject(
        text: String,
        supported: Bool = true,
        parserKind: String = "lezer",
        requestedLanguage: String = "Swift",
        resolvedLanguage: String = "Swift",
        highlights: [[String: Any]] = [],
        syntaxNodes: [[String: Any]] = [],
        bracketPairs: [[String: Any]] = [],
        folds: [[String: Any]] = [],
        symbols: [[String: Any]] = [],
        indentation: [[String: Any]] = [],
        newlineIndentation: [[String: Any]] = [],
        newlineIndentationTransitions: [[String: Any]] = [],
        truncated: [String: Any] = [
            "source": false, "highlights": false, "syntaxNodes": false,
            "bracketPairs": false, "folds": false, "symbols": false,
            "indentation": false
        ]
    ) -> [String: Any] {
        [
            "result": [
                "schemaVersion": 2, "supported": supported, "parserKind": parserKind,
                "requestedLanguage": requestedLanguage,
                "resolvedLanguage": resolvedLanguage,
                "sourceUTF16Length": text.utf16.count,
                "highlights": highlights, "syntaxNodes": syntaxNodes,
                "bracketPairs": bracketPairs, "folds": folds, "symbols": symbols,
                "indentation": indentation,
                "newlineIndentation": newlineIndentation,
                "newlineIndentationTransitions": newlineIndentationTransitions,
                "truncated": truncated
            ]
        ]
    }

    func decode(_ object: [String: Any]) throws -> CodeMirrorParserEnvelope {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(CodeMirrorParserEnvelope.self, from: data)
    }
}
