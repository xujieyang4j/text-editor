import Foundation
import XCTest
@testable import LumenEditorCore

final class EditingCommandsTests: XCTestCase {
    func testCommentCommandsUseLanguageTokensAndOneTransaction() throws {
        let source = "  one\n    two\n"
        let snapshot = snap(source, selection: .single(anchor: 2, head: 12), language: "Swift")
        let commented = try transaction("toggle-comment", snapshot)

        XCTAssertEqual(commented.edits.count, 2)
        XCTAssertEqual(try commented.applying(to: source), "  // one\n  //   two\n")
        XCTAssertEqual(commented.expectedRevision, 0)

        let uncommentedSource = "  // one\n  //   two\n"
        let uncommented = try transaction(
            "toggle-comment",
            snap(
                uncommentedSource,
                selection: .single(anchor: 0, head: uncommentedSource.utf16.count),
                language: "Swift"
            )
        )
        XCTAssertEqual(try uncommented.applying(to: uncommentedSource), source)

        let block = try transaction(
            "toggle-block-comment",
            snap("value", selection: .single(anchor: 0, head: 5), language: "CSS")
        )
        XCTAssertEqual(try block.applying(to: "value"), "/* value */")
        XCTAssertEqual(
            try EditingCommands.plan(
                commandID: "toggle-comment",
                snapshot: snap("plain", language: "Plain Text")
            ),
            .noChange
        )
    }

    func testMoveCopyDeleteAndDuplicateOperateAtomically() throws {
        let move = try transaction(
            "move-line-down",
            snap("a\nb\nc", selection: .single(anchor: 2))
        )
        XCTAssertEqual(move.edits.count, 1)
        XCTAssertEqual(try move.applying(to: "a\nb\nc"), "a\nc\nb")

        let copy = try transaction(
            "copy-line-down",
            snap("a\nb", selection: .single(anchor: 2))
        )
        XCTAssertEqual(try copy.applying(to: "a\nb"), "a\nb\nb")
        XCTAssertEqual(copy.selection?.main.head, 4)

        let deletion = try transaction(
            "delete-line",
            snap("a\nb\nc", selection: .single(anchor: 2))
        )
        XCTAssertEqual(try deletion.applying(to: "a\nb\nc"), "a\nc")

        let duplicate = try transaction(
            "duplicate-selection",
            snap("A😀B", selection: .single(anchor: 1, head: 3))
        )
        XCTAssertEqual(duplicate.edits.count, 1)
        XCTAssertEqual(try duplicate.applying(to: "A😀B"), "A😀😀B")
        XCTAssertEqual(duplicate.selection?.main, DirectedSelection(anchor: 1, head: 5))
    }

    func testDeleteBoundariesBlankLinesAndTransposeUseUTF16() throws {
        let toStart = try transaction(
            "delete-to-line-start",
            snap("one\ntwo", selection: .cursor(at: 6))
        )
        XCTAssertEqual(try toStart.applying(to: "one\ntwo"), "one\no")

        let toEnd = try transaction(
            "delete-to-line-end",
            snap("one\ntwo", selection: .cursor(at: 3))
        )
        XCTAssertEqual(try toEnd.applying(to: "one\ntwo"), "onetwo")

        let above = try transaction(
            "insert-blank-line-above",
            snap("  one", selection: .cursor(at: 4))
        )
        XCTAssertEqual(try above.applying(to: "  one"), "  \n  one")

        let below = try transaction(
            "insert-blank-line",
            snap("  one", selection: .cursor(at: 4))
        )
        XCTAssertEqual(try below.applying(to: "  one"), "  one\n  ")

        let transpose = try transaction(
            "transpose-characters",
            snap("A😀B", selection: .cursor(at: 3))
        )
        XCTAssertEqual(try transpose.applying(to: "A😀B"), "AB😀")
    }

    func testJoinWhitespaceIndentAndConversion() throws {
        let joined = try transaction(
            "join-lines",
            snap("one  \n  two\nthree", selection: .cursor(at: 1))
        )
        XCTAssertEqual(try joined.applying(to: "one  \n  two\nthree"), "one two\nthree")

        let trimmed = try transaction(
            "trim-trailing-whitespace",
            snap("a  \n b\t", selection: .cursor(at: 0))
        )
        XCTAssertEqual(try trimmed.applying(to: "a  \n b\t"), "a\n b")

        let indented = try transaction(
            "indent-selection",
            snap("a\nb", selection: .single(anchor: 0, head: 3), tabWidth: 2)
        )
        XCTAssertEqual(try indented.applying(to: "a\nb"), "  a\n  b")

        let outdented = try transaction(
            "outdent-selection",
            snap("    a", selection: .cursor(at: 4), tabWidth: 4)
        )
        XCTAssertEqual(try outdented.applying(to: "    a"), "a")

        let spaces = try transaction(
            "convert-indent-spaces",
            snap("\t x\nbody\ttext", tabWidth: 4)
        )
        XCTAssertEqual(try spaces.applying(to: "\t x\nbody\ttext"), "     x\nbody\ttext")

        let tabs = try transaction(
            "convert-indent-tabs",
            snap("      x", tabWidth: 4)
        )
        XCTAssertEqual(try tabs.applying(to: "      x"), "\t  x")
    }

    func testExistingTextTransformPlansAreAdaptedWithRevisionAndSelection() throws {
        let cases = try transaction(
            "to-upper-case",
            snap("one two", selection: .single(anchor: 4, head: 7))
        )
        XCTAssertEqual(try cases.applying(to: "one two"), "one TWO")
        XCTAssertEqual(cases.selection?.main, DirectedSelection(anchor: 4, head: 7))

        let lines = try transaction(
            "sort-lines",
            snap("b\na", selection: .cursor(at: 0))
        )
        XCTAssertEqual(try lines.applying(to: "b\na"), "a\nb")

        let final = try transaction(
            "ensure-single-final-newline",
            snap("a\n\n", selection: .cursor(at: 3))
        )
        XCTAssertEqual(try final.applying(to: "a\n\n"), "a\n")
        XCTAssertEqual(final.expectedRevision, 0)
    }

    func testVerticalAndLineBoundaryCursorCommandsPreserveMain() throws {
        let source = "abc\nx\nlong"
        let down = try transaction(
            "add-cursor-below",
            snap(source, selection: .cursor(at: 2))
        )
        XCTAssertEqual(down.selection?.ranges.map(\.head), [2, 5])
        XCTAssertEqual(down.selection?.main.head, 5)

        let starts = try transaction(
            "add-cursors-line-starts",
            snap(source, selection: .single(anchor: 1, head: 6))
        )
        XCTAssertEqual(starts.selection?.ranges.map(\.head), [0, 4])

        let ends = try transaction(
            "add-cursors-line-ends",
            snap(source, selection: .single(anchor: 1, head: 6))
        )
        XCTAssertEqual(ends.selection?.ranges.map(\.head), [3, 5])

        let split = try transaction(
            "split-selection-lines",
            snap(source, selection: .single(anchor: 1, head: 6))
        )
        XCTAssertEqual(split.selection?.ranges.map(\.head), [0, 4])
    }

    func testOccurrenceCommandsAreLiteralOrderedAndBounded() throws {
        let source = "cat scatter cat cat"
        let first = try transaction(
            "select-next-occurrence",
            snap(source, selection: .cursor(at: 1))
        )
        XCTAssertEqual(first.selection?.main, DirectedSelection(anchor: 0, head: 3))

        let next = try transaction(
            "select-next-occurrence",
            snap(source, selection: .single(anchor: 0, head: 3))
        )
        XCTAssertEqual(next.selection?.ranges, [
            DirectedSelection(anchor: 0, head: 3),
            DirectedSelection(anchor: 12, head: 15)
        ])
        XCTAssertEqual(next.selection?.mainIndex, 1)

        let all = try transaction(
            "select-all-occurrences",
            snap(source, selection: .cursor(at: 1))
        )
        XCTAssertEqual(all.selection?.ranges, [
            DirectedSelection(anchor: 0, head: 3),
            DirectedSelection(anchor: 12, head: 15),
            DirectedSelection(anchor: 16, head: 19)
        ])

        let skipped = try transaction(
            "skip-current-occurrence",
            snap(
                source,
                selection: SelectionSet(ranges: [
                    DirectedSelection(anchor: 0, head: 3),
                    DirectedSelection(anchor: 12, head: 15)
                ], mainIndex: 1)
            )
        )
        XCTAssertEqual(skipped.selection?.ranges, [
            DirectedSelection(anchor: 0, head: 3),
            DirectedSelection(anchor: 16, head: 19)
        ])
        XCTAssertEqual(skipped.selection?.mainIndex, 1)
    }

    func testRemoveMainSelectLineAndBracketSelection() throws {
        let removed = try transaction(
            "remove-last-cursor",
            snap(
                "abc",
                selection: SelectionSet(ranges: [
                    DirectedSelection(anchor: 0, head: 0),
                    DirectedSelection(anchor: 2, head: 2)
                ], mainIndex: 1)
            )
        )
        XCTAssertEqual(removed.selection, .cursor(at: 0))

        let line = try transaction(
            "select-line",
            snap("a\nb", selection: .cursor(at: 0))
        )
        XCTAssertEqual(line.selection?.main, DirectedSelection(anchor: 0, head: 2))

        let bracket = try transaction(
            "select-matching-bracket",
            snap("a(b[c]d)e", selection: .cursor(at: 3))
        )
        XCTAssertEqual(bracket.selection?.main, DirectedSelection(anchor: 3, head: 6))
    }

    func testGotoMatchingBracketMovesHeadsAndPreservesMainSelection() throws {
        let source = "😀(a[b]) z{q}"
        let selection = SelectionSet(ranges: [
            DirectedSelection(anchor: 0, head: 2),
            DirectedSelection(anchor: 10, head: 11)
        ], mainIndex: 1)
        let moved = try transaction(
            "goto-matching-bracket",
            snap(source, selection: selection, language: "JavaScript")
        )

        XCTAssertEqual(moved.edits, [])
        XCTAssertEqual(moved.selection?.ranges, [
            DirectedSelection(anchor: 8, head: 8),
            DirectedSelection(anchor: 12, head: 12)
        ])
        XCTAssertEqual(moved.selection?.mainIndex, 1)

        var planner = EditingCommandPlanner()
        let movedByPlanner = try XCTUnwrap(try planner.plan(
            commandID: "goto-matching-bracket",
            snapshot: snap(source, selection: selection, language: "JavaScript")
        ).transaction?.selection)
        XCTAssertEqual(movedByPlanner, moved.selection)
        XCTAssertEqual(try planner.plan(
            commandID: "undo-selection",
            snapshot: snap(source, selection: movedByPlanner, language: "JavaScript")
        ).transaction?.selection, selection)
    }

    func testParentSyntaxUsesUTF16WordsThenBalancedParentsAndSkipsComments() throws {
        let source = "call(😀 + value) // ignored(fake)"
        let word = try transaction(
            "select-parent-syntax",
            snap(source, selection: .cursor(at: 12), language: "JavaScript")
        )
        XCTAssertEqual(word.selection?.main, DirectedSelection(anchor: 10, head: 15))

        let group = try transaction(
            "select-parent-syntax",
            snap(
                source, selection: .single(anchor: 10, head: 15),
                language: "JavaScript"
            )
        )
        XCTAssertEqual(group.selection?.main, DirectedSelection(anchor: 4, head: 16))

        XCTAssertEqual(
            try EditingCommands.plan(
                commandID: "select-parent-syntax",
                snapshot: snap(
                    source, selection: .single(anchor: 28, head: 32),
                    language: "JavaScript"
                )
            ),
            .noChange
        )
        XCTAssertEqual(
            try EditingCommands.plan(
                commandID: "select-parent-syntax",
                snapshot: snap("plain word", selection: .cursor(at: 2))
            ),
            .noChange
        )
    }

    func testParentSyntaxTreatsUnicodeIdentifierAsOneUTF16Range() throws {
        let source = "print(变量名)"
        let selection = try transaction(
            "select-parent-syntax",
            snap(source, selection: .cursor(at: 7), language: "Swift")
        ).selection
        XCTAssertEqual(selection?.main, DirectedSelection(anchor: 6, head: 9))
    }

    func testParsedSyntaxOverridesLexicalStructuralCommandsAndRejectsStaleData() throws {
        let source = "let value = call(\"not ) syntax\")"
        let parsed = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count,
            nodes: [
                .init(from: 0, to: source.utf16.count, parent: -1, type: "Script"),
                .init(from: 12, to: source.utf16.count, parent: 0, type: "CallExpression"),
                .init(from: 17, to: 31, parent: 1, type: "String")
            ],
            bracketPairs: [.init(open: 16, close: source.utf16.count - 1)],
            indentation: [.init(lineFrom: 0, columns: 0)], expectedRevision: 4
        ))
        let parent = try transaction(
            "select-parent-syntax",
            EditingCommandSnapshot(
                text: source, selection: .cursor(at: 22), language: "JavaScript",
                expectedRevision: 4, parsedSyntax: parsed
            )
        )
        XCTAssertEqual(parent.selection?.main, DirectedSelection(anchor: 17, head: 31))

        let bracket = try transaction(
            "goto-matching-bracket",
            EditingCommandSnapshot(
                text: source, selection: .cursor(at: 16), language: "JavaScript",
                expectedRevision: 4, parsedSyntax: parsed
            )
        )
        XCTAssertEqual(bracket.selection?.main, .cursor(at: source.utf16.count))

        let stale = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count,
            nodes: [.init(from: 0, to: source.utf16.count, parent: -1, type: "Stale")],
            bracketPairs: [], indentation: [], expectedRevision: 3
        ))
        let lexical = try transaction(
            "select-parent-syntax",
            EditingCommandSnapshot(
                text: source, selection: .cursor(at: 22), language: "JavaScript",
                expectedRevision: 4, parsedSyntax: stale
            )
        )
        XCTAssertNotEqual(lexical.selection?.main, parent.selection?.main)
    }

    func testParsedSyntaxRequiresExplicitMatchingRevisionAndTextLength() throws {
        let source = "()()"
        let matchingLength = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count, nodes: [],
            bracketPairs: [.init(open: 0, close: 3)],
            indentation: [], expectedRevision: 7
        ))
        let withoutCommandRevision = try transaction(
            "goto-matching-bracket",
            EditingCommandSnapshot(
                text: source, selection: .cursor(at: 0), language: "JavaScript",
                expectedRevision: nil, parsedSyntax: matchingLength
            )
        )
        // The parser pair would move to 4. With no command revision it must
        // be ignored, leaving the lexical pair at offsets 0 and 1 in charge.
        XCTAssertEqual(withoutCommandRevision.selection?.main, .cursor(at: 2))

        let wrongLength = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count + 1, nodes: [],
            bracketPairs: [.init(open: 0, close: 3)],
            indentation: [], expectedRevision: 7
        ))
        let mismatchedText = try transaction(
            "goto-matching-bracket",
            EditingCommandSnapshot(
                text: source, selection: .cursor(at: 0), language: "JavaScript",
                expectedRevision: 7, parsedSyntax: wrongLength
            )
        )
        XCTAssertEqual(mismatchedText.selection?.main, .cursor(at: 2))
    }

    func testParsedIndentationDrivesOneAtomicReindentTransaction() throws {
        let source = "if (ready) {\nwork()\n}"
        let parsed = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count, nodes: [], bracketPairs: [],
            indentation: [
                .init(lineFrom: 0, columns: 0),
                .init(lineFrom: 13, columns: 6),
                .init(lineFrom: 20, columns: 0)
            ], expectedRevision: 9
        ))
        let transaction = try self.transaction(
            "reindent-selection",
            EditingCommandSnapshot(
                text: source,
                selection: .single(anchor: 0, head: source.utf16.count),
                language: "JavaScript", tabWidth: 2, indentWidth: 2,
                insertSpaces: true, expectedRevision: 9, parsedSyntax: parsed
            )
        )
        XCTAssertEqual(try transaction.applying(to: source), "if (ready) {\n      work()\n}")
        XCTAssertEqual(transaction.edits.count, 1)
        XCTAssertEqual(transaction.expectedRevision, 9)
    }

    func testParsedIndentationSkipsLinesWithoutLanguageServiceAnswer() throws {
        let source = "if (ready) {\n  first()\n second()\n}"
        let parsed = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count, nodes: [], bracketPairs: [],
            indentation: [
                .init(lineFrom: 0, columns: 0),
                .init(lineFrom: 13, columns: 4),
                // The third line intentionally models getIndentation == nil.
                .init(lineFrom: 33, columns: 0)
            ], expectedRevision: 5
        ))
        let transaction = try self.transaction(
            "reindent-selection",
            EditingCommandSnapshot(
                text: source,
                selection: .single(anchor: 0, head: source.utf16.count),
                language: "JavaScript", tabWidth: 2, indentWidth: 2,
                insertSpaces: true, expectedRevision: 5, parsedSyntax: parsed
            )
        )
        XCTAssertEqual(
            try transaction.applying(to: source),
            "if (ready) {\n    first()\n second()\n}"
        )
    }

    func testCompleteParsedIndentationWithNoAnswersDoesNotFallBackToLexicalRules() throws {
        let source = "if (ready) {\nwork()\n}"
        let parsed = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count, nodes: [], bracketPairs: [],
            indentation: [], indentationWasTruncated: false, expectedRevision: 6
        ))
        XCTAssertEqual(
            try EditingCommands.plan(
                commandID: "reindent-selection",
                snapshot: EditingCommandSnapshot(
                    text: source,
                    selection: .single(anchor: 0, head: source.utf16.count),
                    language: "JavaScript", tabWidth: 2, indentWidth: 2,
                    insertSpaces: true, expectedRevision: 6, parsedSyntax: parsed
                )
            ),
            .noChange
        )
    }

    func testParsedIndentationChecksDocumentLimitBeforeBuildingReplacement() throws {
        let source = "x"
        let parsed = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count, nodes: [], bracketPairs: [],
            indentation: [.init(
                lineFrom: 0, columns: ParsedSyntaxSnapshot.maximumIndentationColumns
            )],
            expectedRevision: 12
        ))
        let limits = EditingCommandLimits(
            maximumDocumentUTF16Length: 8,
            maximumSelections: 1,
            maximumEdits: 1
        )
        XCTAssertThrowsError(try EditingCommands.plan(
            commandID: "reindent-selection",
            snapshot: EditingCommandSnapshot(
                text: source, selection: .cursor(at: 0), language: "JavaScript",
                expectedRevision: 12, parsedSyntax: parsed
            ),
            limits: limits
        )) { error in
            XCTAssertEqual(
                error as? EditingCommandError,
                .documentTooLarge(
                    actual: ParsedSyntaxSnapshot.maximumIndentationColumns
                        + source.utf16.count,
                    maximum: 8
                )
            )
        }
    }

    func testParsedBracketCandidateOrderMatchesCodeMirrorBoundaries() throws {
        let source = "()()"
        let parsed = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: source.utf16.count, nodes: [],
            bracketPairs: [.init(open: 0, close: 1), .init(open: 2, close: 3)],
            indentation: [], expectedRevision: 1
        ))
        func move(_ cursor: Int) throws -> DirectedSelection? {
            try transaction(
                "goto-matching-bracket",
                EditingCommandSnapshot(
                    text: source, selection: .cursor(at: cursor),
                    language: "JavaScript", expectedRevision: 1, parsedSyntax: parsed
                )
            ).selection?.main
        }
        // At the boundary between a closing and opening bracket, CodeMirror
        // gives the closing token immediately before the cursor precedence.
        XCTAssertEqual(try move(2), .cursor(at: 0))
        XCTAssertEqual(try move(0), .cursor(at: 2))
        XCTAssertEqual(try move(4), .cursor(at: 2))
    }

    func testParsedBracketJumpCoversAllFourCursorSides() throws {
        let source = "(x)"
        let parsed = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: 3, nodes: [],
            bracketPairs: [.init(open: 0, close: 2)],
            indentation: [], expectedRevision: 8
        ))
        func move(_ cursor: Int) throws -> DirectedSelection? {
            try transaction(
                "goto-matching-bracket",
                EditingCommandSnapshot(
                    text: source, selection: .cursor(at: cursor),
                    language: "JavaScript", expectedRevision: 8, parsedSyntax: parsed
                )
            ).selection?.main
        }
        XCTAssertEqual(try move(0), .cursor(at: 3)) // at opening
        XCTAssertEqual(try move(1), .cursor(at: 2)) // immediately after opening
        XCTAssertEqual(try move(2), .cursor(at: 1)) // at closing
        XCTAssertEqual(try move(3), .cursor(at: 0)) // immediately after closing
    }

    func testLexicalBracketBoundaryAndClosingSelectionMatchCodeMirror() throws {
        let boundary = try transaction(
            "goto-matching-bracket",
            snap("[]()", selection: .cursor(at: 2), language: "JavaScript")
        )
        // At `](`, CodeMirror tries the closing bracket before the opening
        // bracket at the cursor, even when the bracket types differ.
        XCTAssertEqual(boundary.selection?.main, .cursor(at: 0))

        let closing = try transaction(
            "select-matching-bracket",
            snap("(x)", selection: .cursor(at: 2), language: "JavaScript")
        )
        // Starting directly on the closing token targets the end of the
        // opening token, not the opening token's start.
        XCTAssertEqual(
            closing.selection?.main,
            DirectedSelection(anchor: 2, head: 1)
        )
    }

    func testParentSyntaxAndExpandIncludeLexicalStringCommentAndPairRanges() throws {
        let quoted = "let s = \"two words\""
        let quotedInner = try transaction(
            "select-parent-syntax",
            snap(quoted, selection: .cursor(at: 12), language: "JavaScript")
        ).selection?.main
        XCTAssertEqual(quotedInner, DirectedSelection(anchor: 9, head: 18))
        let quotedOuter = try transaction(
            "expand-selection",
            snap(
                quoted,
                selection: SelectionSet(DirectedSelection(anchor: 9, head: 18)),
                language: "JavaScript"
            )
        ).selection?.main
        XCTAssertEqual(quotedOuter, DirectedSelection(anchor: 8, head: 19))

        let lineComment = "code // note here\nnext"
        let lineInner = try transaction(
            "select-parent-syntax",
            snap(lineComment, selection: .cursor(at: 12), language: "JavaScript")
        ).selection?.main
        XCTAssertEqual(lineInner, DirectedSelection(anchor: 7, head: 17))
        let lineOuter = try transaction(
            "select-parent-syntax",
            snap(
                lineComment,
                selection: SelectionSet(DirectedSelection(anchor: 7, head: 17)),
                language: "JavaScript"
            )
        ).selection?.main
        XCTAssertEqual(lineOuter, DirectedSelection(anchor: 5, head: 17))

        let blockComment = "x /* note here */ y"
        let blockInner = try transaction(
            "expand-selection",
            snap(blockComment, selection: .cursor(at: 9), language: "JavaScript")
        ).selection?.main
        XCTAssertEqual(blockInner, DirectedSelection(anchor: 4, head: 15))
        let blockOuter = try transaction(
            "expand-selection",
            snap(
                blockComment,
                selection: SelectionSet(DirectedSelection(anchor: 4, head: 15)),
                language: "JavaScript"
            )
        ).selection?.main
        XCTAssertEqual(blockOuter, DirectedSelection(anchor: 2, head: 17))

        let pairSource = "call(foo + bar)"
        let pairInner = try transaction(
            "select-parent-syntax",
            snap(pairSource, selection: .cursor(at: 8), language: "JavaScript")
        ).selection?.main
        XCTAssertEqual(pairInner, DirectedSelection(anchor: 5, head: 14))
        let pairOuter = try transaction(
            "select-parent-syntax",
            snap(
                pairSource,
                selection: SelectionSet(DirectedSelection(anchor: 5, head: 14)),
                language: "JavaScript"
            )
        ).selection?.main
        XCTAssertEqual(pairOuter, DirectedSelection(anchor: 4, head: 15))
    }

    func testExpandAndShrinkRestoreExactMultiselectionStack() throws {
        let source = "one two\nthree"
        let initial = SelectionSet(ranges: [
            DirectedSelection(anchor: 1, head: 1),
            DirectedSelection(anchor: 11, head: 11)
        ], mainIndex: 1)
        var planner = EditingCommandPlanner(selectionHistoryCapacity: 3)

        let words = try XCTUnwrap(try planner.plan(
            commandID: "expand-selection",
            snapshot: snap(source, selection: initial)
        ).transaction?.selection)
        XCTAssertEqual(words.ranges, [
            DirectedSelection(anchor: 0, head: 3),
            DirectedSelection(anchor: 8, head: 13)
        ])
        XCTAssertTrue(planner.canShrinkSelection)

        let lines = try XCTUnwrap(try planner.plan(
            commandID: "expand-selection",
            snapshot: snap(source, selection: words)
        ).transaction?.selection)
        // The second range is already its full line, so it advances to the
        // document while the first advances to its line. Normalization merges
        // the overlapping results exactly as CodeMirror does.
        XCTAssertEqual(lines.ranges, [DirectedSelection(anchor: 0, head: 13)])

        let shrunkToWords = try planner.plan(
            commandID: "shrink-selection",
            snapshot: snap(source, selection: lines)
        )
        XCTAssertEqual(shrunkToWords.transaction?.selection, words)
        let shrunkToCursors = try planner.plan(
            commandID: "shrink-selection",
            snapshot: snap(source, selection: words)
        )
        XCTAssertEqual(shrunkToCursors.transaction?.selection, initial)
        XCTAssertFalse(planner.canShrinkSelection)
        XCTAssertEqual(
            try planner.plan(
                commandID: "shrink-selection",
                snapshot: snap(source, selection: initial)
            ),
            .noChange
        )
    }

    func testExpandFallsBackFromWordToLineToDocument() throws {
        let source = "alpha beta\ngamma"
        let word = try transaction(
            "expand-selection", snap(source, selection: .cursor(at: 7))
        ).selection!
        XCTAssertEqual(word.main, DirectedSelection(anchor: 6, head: 10))

        let line = try transaction(
            "expand-selection", snap(source, selection: word)
        ).selection!
        XCTAssertEqual(line.main, DirectedSelection(anchor: 0, head: 11))

        let nextWordAtTheActiveEnd = try transaction(
            "expand-selection", snap(source, selection: line)
        ).selection!
        XCTAssertEqual(nextWordAtTheActiveEnd.main, DirectedSelection(anchor: 11, head: 16))

        let document = try transaction(
            "expand-selection", snap(source, selection: nextWordAtTheActiveEnd)
        ).selection!
        XCTAssertEqual(document.main, DirectedSelection(anchor: 0, head: 16))
        XCTAssertEqual(
            try EditingCommands.plan(
                commandID: "expand-selection",
                snapshot: snap(source, selection: document)
            ),
            .noChange
        )
    }

    func testUnrelatedSelectionChangeInvalidatesShrinkHistory() throws {
        let source = "alpha beta"
        let cursor = SelectionSet.cursor(at: 2)
        var planner = EditingCommandPlanner()
        let expanded = try XCTUnwrap(try planner.plan(
            commandID: "expand-selection",
            snapshot: snap(source, selection: cursor)
        ).transaction?.selection)
        let unrelated = SelectionSet.cursor(at: 8)
        planner.recordSelectionChange(from: expanded, to: unrelated)

        XCTAssertEqual(
            try planner.plan(
                commandID: "shrink-selection",
                snapshot: snap(source, selection: unrelated)
            ),
            .noChange
        )
    }

    func testReindentSelectionUsesLanguageStructureInOneTransaction() throws {
        let source = "func f() {\nlet emoji = \"😀\"\nif ready {\nwork()\n}\n}"
        let reindented = try transaction(
            "reindent-selection",
            snap(
                source,
                selection: .single(anchor: 0, head: source.utf16.count),
                language: "Swift",
                tabWidth: 2
            )
        )
        XCTAssertEqual(reindented.edits.count, 4)
        XCTAssertEqual(try reindented.applying(to: source), """
        func f() {
          let emoji = "😀"
          if ready {
            work()
          }
        }
        """)
        XCTAssertEqual(reindented.expectedRevision, 0)
    }

    func testReindentPythonDedentsElseExceptFinallyAndCase() throws {
        let source = """
        if ready:
        run()
        elif backup:
        retry()
        else:
        stop()
        try:
        work()
        except Error:
        recover()
        finally:
        cleanup()
        match value:
        case 1:
        hit()
        case _:
        miss()
        """
        XCTAssertEqual(
            try transaction(
                "reindent-selection",
                snap(
                    source,
                    selection: .single(anchor: 0, head: source.utf16.count),
                    language: "Python",
                    tabWidth: 4
                )
            ).applying(to: source),
            """
            if ready:
                run()
            elif backup:
                retry()
            else:
                stop()
            try:
                work()
            except Error:
                recover()
            finally:
                cleanup()
            match value:
                case 1:
                    hit()
                case _:
                    miss()
            """
        )
    }

    func testReindentRubyDedentsRescueEnsureAndInBlocks() throws {
        let source = """
        begin
        work
        rescue StandardError
        handle
        ensure
        cleanup
        end
        case value
        in Integer
        handle_integer
        else
        handle_other
        end
        """
        XCTAssertEqual(
            try transaction(
                "reindent-selection",
                snap(
                    source,
                    selection: .single(anchor: 0, head: source.utf16.count),
                    language: "Ruby",
                    tabWidth: 2
                )
            ).applying(to: source),
            """
            begin
              work
            rescue StandardError
              handle
            ensure
              cleanup
            end
            case value
              in Integer
                handle_integer
              else
                handle_other
            end
            """
        )
    }

    func testReindentBracesIgnoreStringsAndBlockComments() throws {
        let source = """
        if (ready) {
        const pattern = "{";
        /* {
        } */
        run();
        }
        """
        XCTAssertEqual(
            try transaction(
                "reindent-selection",
                snap(
                    source,
                    selection: .single(anchor: 0, head: source.utf16.count),
                    language: "JavaScript",
                    tabWidth: 2
                )
            ).applying(to: source),
            """
            if (ready) {
              const pattern = "{";
              /* {
              } */
              run();
            }
            """
        )
    }

    func testMismatchedInnerBracketStillKeepsValidOuterMatch() throws {
        let source = "({])"
        let transaction = try transaction(
            "select-matching-bracket",
            snap(source, selection: .cursor(at: 0), language: "JavaScript")
        )
        XCTAssertEqual(transaction.selection?.main, DirectedSelection(anchor: 0, head: 4))
    }

    func testReindentHonorsTabSettingsAndPlainTextHasNoSyntaxIndent() throws {
        let source = "if (ok) {\nvalue()\n}"
        let tabs = EditingCommandSnapshot(
            text: source,
            selection: .single(anchor: 0, head: source.utf16.count),
            language: "JavaScript",
            tabWidth: 4,
            indentWidth: 4,
            insertSpaces: false,
            expectedRevision: 0
        )
        XCTAssertEqual(
            try transaction("reindent-selection", tabs).applying(to: source),
            "if (ok) {\n\tvalue()\n}"
        )
        XCTAssertEqual(
            try EditingCommands.plan(
                commandID: "reindent-selection",
                snapshot: snap(source, selection: .single(anchor: 0, head: source.utf16.count))
            ),
            .noChange
        )
    }

    func testSelectionUndoRedoNeverProducesTextEdits() throws {
        var planner = EditingCommandPlanner()
        let first = SelectionSet.cursor(at: 0)
        let second = SelectionSet.single(anchor: 0, head: 3)
        planner.recordSelectionChange(from: first, to: second)

        let undo = try planner.plan(
            commandID: "undo-selection",
            snapshot: snap("abc", selection: second)
        )
        XCTAssertEqual(undo.transaction?.edits, [])
        XCTAssertEqual(undo.transaction?.selection, first)

        let redo = try planner.plan(
            commandID: "redo-selection",
            snapshot: snap("abc", selection: first)
        )
        XCTAssertEqual(redo.transaction?.edits, [])
        XCTAssertEqual(redo.transaction?.selection, second)

        XCTAssertEqual(
            try planner.plan(
                commandID: "redo-selection",
                snapshot: snap("abc", selection: second)
            ),
            .noChange
        )
    }

    func testCommandSupportAndResourceLimitsAreExplicit() throws {
        XCTAssertTrue(EditingCommands.unsupportedCommandIDs.isEmpty)
        for commandID in [
            "goto-matching-bracket", "select-parent-syntax", "expand-selection",
            "shrink-selection", "reindent-selection"
        ] {
            XCTAssertTrue(EditingCommands.isSupported(commandID: commandID))
        }
        XCTAssertEqual(
            try EditingCommands.plan(commandID: "unknown", snapshot: snap("x")),
            .unsupported
        )

        let limits = EditingCommandLimits(
            maximumDocumentUTF16Length: 1,
            maximumSelections: 1,
            maximumEdits: 1
        )
        XCTAssertThrowsError(try EditingCommands.plan(
            commandID: "select-line",
            snapshot: snap("😀"),
            limits: limits
        )) { error in
            XCTAssertEqual(
                error as? EditingCommandError,
                .documentTooLarge(actual: 2, maximum: 1)
            )
        }
    }

    @MainActor
    func testOnePlannedCommandIsOneDocumentUndoStep() async throws {
        let source = "a  \nb  "
        let transaction = try self.transaction(
            "trim-trailing-whitespace",
            snap(source, selection: .cursor(at: 0))
        )
        let buffer = DocumentBuffer(text: source)

        try buffer.apply(transaction)
        XCTAssertEqual(buffer.text, "a\nb")
        XCTAssertEqual(buffer.undoDepth, 1)
        XCTAssertTrue(buffer.undo())
        XCTAssertEqual(buffer.text, source)
    }

    private func snap(
        _ text: String,
        selection: SelectionSet = .cursor(at: 0),
        language: String = "Plain Text",
        tabWidth: Int = 4
    ) -> EditingCommandSnapshot {
        EditingCommandSnapshot(
            text: text,
            selection: selection,
            language: language,
            tabWidth: tabWidth,
            expectedRevision: 0
        )
    }

    private func transaction(
        _ commandID: String,
        _ snapshot: EditingCommandSnapshot
    ) throws -> TextTransaction {
        try XCTUnwrap(EditingCommands.transaction(
            for: commandID,
            snapshot: snapshot
        ))
    }
}
