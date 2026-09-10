import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class NativeTextInputPlannerTests: XCTestCase {
    func testOpeningPairWrapsSelectionAndPreservesDirection() throws {
        let source = "hello"
        let selection = SelectionSet.single(anchor: 4, head: 1)
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: selection, replacement: "(",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 3
        ))
        XCTAssertEqual(try transaction.applying(to: source), "h(ell)o")
        XCTAssertEqual(transaction.selection?.main, DirectedSelection(anchor: 5, head: 2))
        XCTAssertEqual(transaction.expectedRevision, 3)
    }

    func testOpeningPairUsesDefaultCloseBeforeGate() throws {
        XCTAssertNil(NativeTextInputPlanner.insertion(
            text: "foobar", selections: .cursor(at: 3), replacement: "(",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))

        let cases: [(source: String, cursor: Int, expected: String)] = [
            ("", 0, "()"),
            (" ", 0, "() "),
            (")", 0, "())"),
            ("]", 0, "()]"),
            ("}", 0, "()}"),
            (":", 0, "():"),
            (";", 0, "();"),
            (">", 0, "()>")
        ]
        for value in cases {
            let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
                text: value.source, selections: .cursor(at: value.cursor), replacement: "(",
                tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
            ))
            XCTAssertEqual(try transaction.applying(to: value.source), value.expected)
            XCTAssertEqual(transaction.selection, .cursor(at: value.cursor + 1))
        }
    }

    func testOpeningPairCloseBeforeGateIsAllOrNothingForMultipleCursors() {
        let selections = SelectionSet(ranges: [
            DirectedSelection(anchor: 0, head: 0),
            DirectedSelection(anchor: 2, head: 2)
        ], mainIndex: 1)

        XCTAssertNil(NativeTextInputPlanner.insertion(
            text: "  a", selections: selections, replacement: "(",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))
    }

    func testTypingHandwrittenCloseDoesNotSkip() {
        XCTAssertNil(NativeTextInputPlanner.insertion(
            text: "()", selections: .cursor(at: 1), replacement: ")",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 8
        ))
    }

    func testTypingAutoInsertedCloseSkipsOnce() throws {
        let opening = try XCTUnwrap(NativeTextInputPlanner.insertionPlan(
            text: "", selections: .cursor(at: 0), replacement: "(",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 7,
            provenance: .empty
        ))
        let source = try opening.transaction.applying(to: "")
        XCTAssertEqual(source, "()")
        XCTAssertTrue(opening.provenance.containsClosing(0x29, at: 1))

        let closing = try XCTUnwrap(NativeTextInputPlanner.insertionPlan(
            text: source, selections: try XCTUnwrap(opening.transaction.selection),
            replacement: ")", tabWidth: 4, insertSpaces: true,
            language: "Swift", revision: 8, provenance: opening.provenance
        ))
        XCTAssertEqual(closing.transaction.edits, [])
        XCTAssertEqual(closing.transaction.selection, .cursor(at: 2))
        XCTAssertFalse(closing.provenance.containsClosing(0x29, at: 1))
        XCTAssertNil(NativeTextInputPlanner.insertionPlan(
            text: source, selections: .cursor(at: 1), replacement: ")",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 8,
            provenance: closing.provenance
        ))
    }

    func testNewlineBetweenBracesCreatesIndentedBlankLine() throws {
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: "  {}", selections: .cursor(at: 3), replacement: "\n",
            tabWidth: 2, insertSpaces: true, language: "JavaScript", revision: 0
        ))
        XCTAssertEqual(try transaction.applying(to: "  {}"), "  {\n    \n  }")
        XCTAssertEqual(transaction.selection, .cursor(at: 8))
    }

    func testNewlineMovesCompleteSpaceAndTabIndentationToNewLine() throws {
        let cases: [(source: String, cursor: Int, expected: String, resultCursor: Int)] = [
            ("    item", 2, "\n    item", 5),
            ("\t \titem", 2, "\n\t \titem", 4)
        ]
        for value in cases {
            let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
                text: value.source, selections: .cursor(at: value.cursor), replacement: "\n",
                tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
            ))
            XCTAssertEqual(try transaction.applying(to: value.source), value.expected)
            XCTAssertEqual(transaction.selection, .cursor(at: value.resultCursor))
        }
    }

    func testNewlineTreatsECMAScriptWhitespaceAsIndentation() throws {
        let source = "  item"
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 1), replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))

        XCTAssertEqual(transaction.edits.first?.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(try transaction.applying(to: source), "\n  item")
        XCTAssertEqual(transaction.selection, .cursor(at: 3))
    }

    func testNewlineMovesWhitespaceOnlyLineIndentation() throws {
        let source = "head\n    \ntail"
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 7), replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))

        XCTAssertEqual(try transaction.applying(to: source), "head\n\n    \ntail")
        XCTAssertEqual(transaction.selection, .cursor(at: 10))
    }

    func testNewlineNormalizesIndentationForMultipleCursors() throws {
        let source = "  one\n\t\ttwo"
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source,
            selections: SelectionSet(ranges: [
                DirectedSelection(anchor: 1, head: 1),
                DirectedSelection(anchor: 7, head: 7)
            ], mainIndex: 1),
            replacement: "\n", tabWidth: 4, insertSpaces: true,
            language: "Swift", revision: 4
        ))

        XCTAssertEqual(try transaction.applying(to: source), "\n  one\n\n\t\ttwo")
        XCTAssertEqual(transaction.selection?.ranges.map(\.head), [3, 10])
        XCTAssertEqual(transaction.selection?.mainIndex, 1)
    }

    func testNewlineOutsideIndentDoesNotExpand() throws {
        let source = "  item"
        let contentTransaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 4), replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))

        XCTAssertEqual(try contentTransaction.applying(to: source), "  it\n  em")
        XCTAssertEqual(contentTransaction.edits.first?.range, NSRange(location: 4, length: 0))
    }

    func testNewlineExpandsSelectionAndConsumesFollowingWhitespace() throws {
        let source = "    item   tail"
        let forward = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .single(anchor: 2, head: 8), replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))
        let backward = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .single(anchor: 8, head: 2), replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))

        XCTAssertEqual(forward.edits.first?.range, NSRange(location: 0, length: 11))
        XCTAssertEqual(backward.edits.first?.range, NSRange(location: 0, length: 11))
        XCTAssertEqual(try forward.applying(to: source), "\n    tail")
        XCTAssertEqual(try backward.applying(to: source), "\n    tail")
        XCTAssertEqual(forward.selection, .cursor(at: 5))
        XCTAssertEqual(backward.selection, .cursor(at: 5))
        XCTAssertEqual(forward.selection?.mainIndex, 0)
        XCTAssertEqual(backward.selection?.mainIndex, 0)
    }

    func testNewlinePrefixExpansionCutoffIsStrictlyLessThanOneHundred() throws {
        for cursor in [99, 100] {
            let source = String(repeating: " ", count: 120) + "item"
            let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
                text: source, selections: .cursor(at: cursor), replacement: "\n",
                tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
            ))

            let expectedRange = cursor == 99
                ? NSRange(location: 0, length: 120)
                : NSRange(location: 100, length: 20)
            let expectedCursor = cursor == 99 ? 121 : 221
            XCTAssertEqual(transaction.edits.first?.range, expectedRange)
            XCTAssertEqual(transaction.selection, .cursor(at: expectedCursor))
        }
    }

    func testNewlineAtPrefixLimitStillConsumesFollowingWhitespace() throws {
        let source = String(repeating: " ", count: 120) + "item"
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 100), replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))

        XCTAssertEqual(
            transaction.edits.first?.range,
            NSRange(location: 100, length: 20)
        )
        XCTAssertEqual(try transaction.applying(to: source),
                       String(repeating: " ", count: 100) + "\n"
                           + String(repeating: " ", count: 120) + "item")
        XCTAssertEqual(transaction.selection, .cursor(at: 221))
    }

    func testNewlineOverlappingExpandedCursorEditsFailAsOnePlan() {
        let selections = SelectionSet(ranges: [
            DirectedSelection(anchor: 1, head: 1),
            DirectedSelection(anchor: 2, head: 2)
        ], mainIndex: 1)

        XCTAssertNil(NativeTextInputPlanner.insertion(
            text: "    item", selections: selections, replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 0
        ))
    }

    func testNewlineSelectionKeepsMainIndexAcrossMultipleLines() throws {
        let source = "  one   tail\n  two   end"
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source,
            selections: SelectionSet(ranges: [
                DirectedSelection(anchor: 1, head: 5),
                DirectedSelection(anchor: 19, head: 14)
            ], mainIndex: 1),
            replacement: "\n", tabWidth: 4, insertSpaces: true,
            language: "Swift", revision: 6
        ))

        XCTAssertEqual(transaction.edits.map(\.range), [
            NSRange(location: 0, length: 8),
            NSRange(location: 13, length: 8)
        ])
        XCTAssertEqual(try transaction.applying(to: source), "\n  tail\n\n  end")
        XCTAssertEqual(transaction.selection?.ranges.map(\.head), [3, 11])
        XCTAssertEqual(transaction.selection?.mainIndex, 1)
    }

    func testTabUsesNextStopAndPairedBackspaceIsOneTransaction() throws {
        let tab = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: " x", selections: .cursor(at: 1), replacement: "\t",
            tabWidth: 4, insertSpaces: true, language: "Plain Text", revision: 0
        ))
        XCTAssertEqual(try tab.applying(to: " x"), "    x")

        let manualDeletion = try XCTUnwrap(NativeTextInputPlanner.pairedBackspace(
            text: "[]", selections: .cursor(at: 1), revision: 4,
            provenance: .empty
        ))
        XCTAssertEqual(try manualDeletion.applying(to: "[]"), "")

        let insertion = try XCTUnwrap(NativeTextInputPlanner.insertionPlan(
            text: "", selections: .cursor(at: 0), replacement: "[",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 3,
            provenance: .empty
        ))
        let deletion = try XCTUnwrap(NativeTextInputPlanner.pairedBackspacePlan(
            text: "[]", selections: .cursor(at: 1), revision: 4,
            provenance: insertion.provenance
        ))
        XCTAssertEqual(try deletion.transaction.applying(to: "[]"), "")
        XCTAssertEqual(deletion.transaction.selection, .cursor(at: 0))
        XCTAssertEqual(deletion.transaction.expectedRevision, 4)
        XCTAssertEqual(deletion.provenance, .empty)
    }

    func testProvenanceMapsThroughUnrelatedEditsAndInvalidatesOnReplacement() throws {
        let provenance = NativeTextInputProvenance(autoClosingUnits: [1: 0x29])
        let insertion = try TextTransaction(edits: [
            TextEdit(from: 0, to: 0, insert: "value")
        ])
        let insertedText = try insertion.applying(to: "()")
        let mapped = provenance.mapped(
            through: insertion, from: "()", to: insertedText
        )
        XCTAssertTrue(mapped.containsClosing(0x29, at: 6))
        XCTAssertFalse(mapped.containsClosing(0x29, at: 1))

        let replacement = try TextTransaction(edits: [
            TextEdit(from: 6, to: 7, insert: ")")
        ])
        let replacedText = try replacement.applying(to: insertedText)
        XCTAssertEqual(
            mapped.mapped(through: replacement, from: insertedText, to: replacedText),
            .empty
        )
    }

    func testManualSameCharacterOverwriteInvalidatesProvenance() throws {
        let source = "()"
        let overwrite = try TextTransaction(edits: [
            TextEdit(from: 1, to: 2, insert: ")")
        ])
        let nextText = try overwrite.applying(to: source)
        let provenance = NativeTextInputProvenance(autoClosingUnits: [1: 0x29])
            .mapped(through: overwrite, from: source, to: nextText)

        XCTAssertEqual(nextText, source)
        XCTAssertEqual(provenance, .empty)
    }

    func testMultiCursorQuoteSkipAndAutopairUpdateProvenanceTogether() throws {
        let source = "\"\" "
        let selections = SelectionSet(ranges: [
            DirectedSelection(anchor: 1, head: 1),
            DirectedSelection(anchor: 3, head: 3)
        ], mainIndex: 1)
        let plan = try XCTUnwrap(NativeTextInputPlanner.insertionPlan(
            text: source, selections: selections, replacement: "\"",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 5,
            provenance: NativeTextInputProvenance(autoClosingUnits: [1: 0x22])
        ))

        XCTAssertEqual(try plan.transaction.applying(to: source), "\"\" \"\"")
        XCTAssertEqual(plan.transaction.selection?.ranges.map(\.head), [2, 4])
        XCTAssertEqual(plan.transaction.selection?.mainIndex, 1)
        XCTAssertFalse(plan.provenance.containsClosing(0x22, at: 1))
        XCTAssertTrue(plan.provenance.containsClosing(0x22, at: 4))
    }

    func testMultiCursorAutopairRecordsEveryGeneratedClosing() throws {
        let selections = SelectionSet(ranges: [
            DirectedSelection(anchor: 0, head: 0),
            DirectedSelection(anchor: 2, head: 2)
        ], mainIndex: 1)
        let plan = try XCTUnwrap(NativeTextInputPlanner.insertionPlan(
            text: "  ", selections: selections, replacement: "(",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 2,
            provenance: .empty
        ))

        XCTAssertEqual(try plan.transaction.applying(to: "  "), "()  ()")
        XCTAssertEqual(plan.transaction.selection?.ranges.map(\.head), [1, 5])
        XCTAssertTrue(plan.provenance.containsClosing(0x29, at: 1))
        XCTAssertTrue(plan.provenance.containsClosing(0x29, at: 5))
    }

    func testPairedBackspaceDoesNotRequireProvenanceAtEveryCursor() throws {
        let selections = SelectionSet(ranges: [
            DirectedSelection(anchor: 1, head: 1),
            DirectedSelection(anchor: 4, head: 4)
        ], mainIndex: 1)
        XCTAssertNotNil(NativeTextInputPlanner.pairedBackspacePlan(
            text: "[] {}", selections: selections, revision: 9,
            provenance: NativeTextInputProvenance(autoClosingUnits: [1: 0x5D])
        ))

        let plan = try XCTUnwrap(NativeTextInputPlanner.pairedBackspacePlan(
            text: "[] {}", selections: selections, revision: 9,
            provenance: NativeTextInputProvenance(
                autoClosingUnits: [1: 0x5D, 4: 0x7D]
            )
        ))
        XCTAssertEqual(try plan.transaction.applying(to: "[] {}"), " ")
        XCTAssertEqual(plan.transaction.selection?.ranges.map(\.head), [0, 1])
        XCTAssertEqual(plan.transaction.selection?.mainIndex, 1)
        XCTAssertEqual(plan.provenance, .empty)
    }

    func testDoesNotAutopairInsideStringsOrComments() throws {
        let stringSource = "let value = \"abc\""
        let stringCursor = (stringSource as NSString).range(of: "bc").location
        let stringTransaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: stringSource, selections: .cursor(at: stringCursor), replacement: "\"",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 1
        ))
        XCTAssertEqual(try stringTransaction.applying(to: stringSource), "let value = \"a\"bc\"")

        let commentSource = "let value = 1 // note"
        let commentCursor = (commentSource as NSString).range(of: "note").location
        let commentTransaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: commentSource, selections: .cursor(at: commentCursor), replacement: "(",
            tabWidth: 4, insertSpaces: true, language: "Swift", revision: 2
        ))
        XCTAssertEqual(try commentTransaction.applying(to: commentSource), "let value = 1 // (note")
    }

    func testPythonAndRubyNewlineIndentFollowBasicBlockRules() throws {
        let pythonSource = "if ready:"
        let pythonTransaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: pythonSource, selections: .cursor(at: pythonSource.utf16.count), replacement: "\n",
            tabWidth: 4, insertSpaces: true, language: "Python", revision: 0
        ))
        XCTAssertEqual(try pythonTransaction.applying(to: pythonSource), "if ready:\n    ")

        let rubySource = "def run\nend"
        let rubyCursor = (rubySource as NSString).range(of: "\n").location
        let rubyTransaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: rubySource, selections: .cursor(at: rubyCursor), replacement: "\n",
            tabWidth: 2, insertSpaces: true, language: "Ruby", revision: 0
        ))
        XCTAssertEqual(try rubyTransaction.applying(to: rubySource), "def run\n  \nend")
        XCTAssertEqual(rubyTransaction.selection, .cursor(at: 10))
    }

    func testNewlineUsesExactParserIndentationAtSafeExistingLineStart() throws {
        let source = "switch (value) {\n  case 1:\n      run()\n}"
        let lineStarts = [0, 17, 27, 39]
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "JavaScript", revision: 7,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [
                .init(lineFrom: lineStarts[0], columns: 0),
                .init(lineFrom: lineStarts[1], columns: 2),
                .init(lineFrom: lineStarts[2], columns: 6),
                .init(lineFrom: lineStarts[3], columns: 0)
            ]
        ))
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: lineStarts[2]), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            language: "JavaScript", revision: 7, parsedIndentation: snapshot
        ))

        XCTAssertEqual(
            try transaction.applying(to: source),
            "switch (value) {\n  case 1:\n\n      run()\n}"
        )
        XCTAssertEqual(transaction.selection, .cursor(at: lineStarts[2] + 7))
    }

    func testNewlineRejectsMismatchedSnapshotAndUnsafeIndentation() throws {
        let source = "{\n  item\n}"
        let parserCorrection = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "JavaScript", revision: 3,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [
                .init(lineFrom: 0, columns: 0),
                .init(lineFrom: 2, columns: 6),
                .init(lineFrom: 9, columns: 0)
            ]
        ))
        XCTAssertEqual(
            parserCorrection.newlineIndentationColumns(atExistingLineStart: 2), 6
        )
        XCTAssertNil(
            parserCorrection.newlineIndentationColumns(atExistingLineStart: 9)
        )
        let exact = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "JavaScript", revision: 3,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [
                .init(lineFrom: 0, columns: 0),
                .init(lineFrom: 2, columns: 2),
                .init(lineFrom: 9, columns: 0)
            ]
        ))
        XCTAssertNil(exact.newlineIndentationColumns(atExistingLineStart: 9))
        let stale = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "JavaScript", revision: 2,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [
                .init(lineFrom: 0, columns: 0),
                .init(lineFrom: 2, columns: 2),
                .init(lineFrom: 9, columns: 0)
            ]
        ))

        let parserBacked = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 2), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            language: "JavaScript", revision: 3,
            parsedIndentation: parserCorrection
        ))
        let staleFallback = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 2), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            language: "JavaScript", revision: 3, parsedIndentation: stale
        ))
        let settingsFallback = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 2), replacement: "\n",
            tabWidth: 4, indentWidth: 4, insertSpaces: true,
            language: "JavaScript", revision: 3, parsedIndentation: exact
        ))
        let indentationPrefixParserBacked = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 3), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            language: "JavaScript", revision: 3, parsedIndentation: parserCorrection
        ))

        XCTAssertEqual(try parserBacked.applying(to: source), "{\n\n      item\n}")
        XCTAssertEqual(try staleFallback.applying(to: source), "{\n\n  item\n}")
        XCTAssertEqual(try settingsFallback.applying(to: source), "{\n\n  item\n}")
        XCTAssertEqual(
            try indentationPrefixParserBacked.applying(to: source),
            "{\n\n      item\n}"
        )
        XCTAssertEqual(parserBacked.selection, .cursor(at: 9))
        XCTAssertEqual(staleFallback.selection, .cursor(at: 5))
    }

    func testParserIndentationKeepsMultiCursorSingleTransaction() throws {
        let source = "first\n    second"
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "JavaScript", revision: 9,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [
                .init(lineFrom: 0, columns: 0),
                .init(lineFrom: 6, columns: 4)
            ]
        ))
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source,
            selections: SelectionSet(ranges: [
                DirectedSelection(anchor: 0, head: 0),
                DirectedSelection(anchor: 6, head: 6)
            ], mainIndex: 1),
            replacement: "\n", tabWidth: 4, indentWidth: 2,
            insertSpaces: true, language: "JavaScript", revision: 9,
            parsedIndentation: snapshot
        ))

        XCTAssertEqual(transaction.edits.count, 2)
        XCTAssertEqual(transaction.expectedRevision, 9)
        XCTAssertEqual(try transaction.applying(to: source), "\nfirst\n\n    second")
        XCTAssertEqual(transaction.selection?.ranges.map(\.head), [1, 12])
    }

    func testParserSnapshotDoesNotRegressDoubleNewlineBetweenBrackets() throws {
        let source = "{}"
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "JavaScript", revision: 1,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [.init(lineFrom: 0, columns: 0)]
        ))
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 1), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            language: "JavaScript", revision: 1, parsedIndentation: snapshot
        ))

        XCTAssertEqual(try transaction.applying(to: source), "{\n  \n}")
        XCTAssertEqual(transaction.selection, .cursor(at: 4))
    }

    func testExactParserControlsHTMLTagPairExplosion() throws {
        let source = "<section></section>"
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "HTML", revision: 4,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [.init(lineFrom: 0, columns: 0)],
            newlineEntries: [.init(
                position: 9, columns: 0, doubleColumns: 2, explode: true
            )]
        ))
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 9), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            language: "HTML", revision: 4, parsedIndentation: snapshot
        ))
        XCTAssertEqual(
            try transaction.applying(to: source),
            "<section>\n  \n</section>"
        )
        XCTAssertEqual(transaction.selection, .cursor(at: 12))
    }

    func testParserColumnsHonorTabAndIndentSettings() throws {
        let source = "\titem"
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "JavaScript", revision: 6,
            tabWidth: 4, indentWidth: 2, insertSpaces: false,
            entries: [.init(lineFrom: 0, columns: 4)]
        ))
        let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: source, selections: .cursor(at: 0), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: false,
            language: "JavaScript", revision: 6, parsedIndentation: snapshot
        ))

        XCTAssertEqual(try transaction.applying(to: source), "\n\titem")
        XCTAssertEqual(transaction.selection, .cursor(at: 2))
    }

    func testExactNewlineFixturesMatchCodeMirrorForMarkupAndContinuations() throws {
        let fixtures: [(language: String, source: String, cursor: Int, columns: Int, expected: String)] = [
            ("JSX", "const view = <div><span>text</span></div>", 18, 2,
             "const view = <div>\n  <span>text</span></div>"),
            ("HTML", "<section><p>text</p></section>", 9, 2,
             "<section>\n  <p>text</p></section>"),
            ("Python", "result = call(value)", 14, 2,
             "result = call(\n  value)"),
            ("SQL", "SELECT id,name FROM users", 10, 2,
             "SELECT id,\n  name FROM users")
        ]
        for fixture in fixtures {
            let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
                text: fixture.source, language: fixture.language, revision: 2,
                tabWidth: 4, indentWidth: 2, insertSpaces: true,
                entries: lineEntries(for: fixture.source),
                newlineEntries: [.init(
                    position: fixture.cursor, columns: fixture.columns
                )]
            ))
            let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
                text: fixture.source, selections: .cursor(at: fixture.cursor),
                replacement: "\n", tabWidth: 4, indentWidth: 2,
                insertSpaces: true, language: fixture.language, revision: 2,
                parsedIndentation: snapshot
            ))
            XCTAssertEqual(
                try transaction.applying(to: fixture.source), fixture.expected,
                fixture.language
            )
        }
    }

    func testSingleCharacterRevisionTransitionPreservesExactEnterAnswer() throws {
        let source = "if ready"
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "Python", revision: 7,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [.init(lineFrom: 0, columns: 0)],
            newlineEntries: [.init(position: source.utf16.count, columns: 0)],
            transitionEntries: [.init(
                position: source.utf16.count, insert: ":", columns: 2
            )]
        ))
        let edit = try TextTransaction(
            edits: [.init(from: 8, to: 8, insert: ":")],
            selection: .cursor(at: 9), expectedRevision: 7
        )
        let nextText = try edit.applying(to: source)
        let mapped = try XCTUnwrap(snapshot.mappedThroughSingleCharacterInsertion(
            edit, from: source, to: nextText, revision: 8
        ))
        let newline = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: nextText, selections: .cursor(at: 9), replacement: "\n",
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            language: "Python", revision: 8, parsedIndentation: mapped
        ))
        XCTAssertEqual(try newline.applying(to: nextText), "if ready:\n  ")
        XCTAssertNil(snapshot.mappedThroughSingleCharacterInsertion(
            edit, from: source, to: nextText, revision: 9
        ))
    }

    func testSingleCharacterTransitionRejectsWrongEditShapeAndText() throws {
        let source = "value"
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "SQL", revision: 3,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [.init(lineFrom: 0, columns: 0)],
            transitionEntries: [.init(
                position: 5, insert: ",", columns: 2
            )]
        ))
        let replacement = try TextTransaction(
            edits: [.init(from: 4, to: 5, insert: ",")],
            selection: .cursor(at: 5), expectedRevision: 3
        )
        XCTAssertNil(snapshot.mappedThroughSingleCharacterInsertion(
            replacement, from: source, to: "valu,", revision: 4
        ))
        let insertion = try TextTransaction(
            edits: [.init(from: 5, to: 5, insert: ",")],
            selection: .cursor(at: 6), expectedRevision: 3
        )
        XCTAssertNil(snapshot.mappedThroughSingleCharacterInsertion(
            insertion, from: "other", to: "other,", revision: 4
        ))
        XCTAssertNil(snapshot.mappedThroughSingleCharacterInsertion(
            insertion, from: source, to: "value,", revision: 5
        ))
        XCTAssertNil(snapshot.mappedThroughSingleCharacterInsertion(
            insertion, from: source, to: "not-the-result", revision: 4
        ))
        let overflowSnapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "SQL", revision: UInt64.max,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [.init(lineFrom: 0, columns: 0)],
            transitionEntries: [.init(
                position: 5, insert: ",", columns: 2
            )]
        ))
        let overflowEdit = try TextTransaction(
            edits: [.init(from: 5, to: 5, insert: ",")],
            selection: .cursor(at: 6), expectedRevision: UInt64.max
        )
        XCTAssertNil(overflowSnapshot.mappedThroughSingleCharacterInsertion(
            overflowEdit, from: source, to: "value,", revision: 0
        ))
    }

    func testMarkdownListContinuationMatchesCodeMirrorBasics() throws {
        let fixtures = [
            ("- first", "- first\n- "),
            ("  * nested", "  * nested\n  * "),
            ("9. ninth", "9. ninth\n10. "),
            ("- [x] done", "- [x] done\n- [ ] ")
        ]
        for (source, expected) in fixtures {
            let transaction = try XCTUnwrap(NativeTextInputPlanner.insertion(
                text: source, selections: .cursor(at: source.utf16.count),
                replacement: "\n", tabWidth: 4, indentWidth: 2,
                insertSpaces: true, language: "Markdown", revision: 0
            ))
            XCTAssertEqual(try transaction.applying(to: source), expected)
        }

        let empty = "- "
        let exit = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: empty, selections: .cursor(at: empty.utf16.count),
            replacement: "\n", tabWidth: 4, insertSpaces: true,
            language: "Markdown", revision: 0
        ))
        XCTAssertEqual(try exit.applying(to: empty), "")

        let fenced = "```\n- code"
        let ordinary = try XCTUnwrap(NativeTextInputPlanner.insertion(
            text: fenced, selections: .cursor(at: fenced.utf16.count),
            replacement: "\n", tabWidth: 4, insertSpaces: true,
            language: "Markdown", revision: 0
        ))
        XCTAssertEqual(try ordinary.applying(to: fenced), "```\n- code\n")
    }

    private func lineEntries(for text: String) -> [CodeMirrorIndentationSnapshot.Entry] {
        var starts = [0]
        for (index, unit) in Array(text.utf16).enumerated() where unit == 0x0A {
            starts.append(index + 1)
        }
        return starts.map { .init(lineFrom: $0, columns: 0) }
    }
}
