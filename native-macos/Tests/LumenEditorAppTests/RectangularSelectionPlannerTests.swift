import Foundation
import XCTest
@testable import LumenEditorApp

final class RectangularSelectionPlannerTests: XCTestCase {
    func testBasicRectangleCreatesOneRangePerPhysicalLine() {
        let plan = RectangularSelectionPlanner.plan(
            text: "abcdef\nghijkl\nmnopqr",
            anchor: .init(line: 0, visualColumn: 1),
            target: .init(line: 2, visualColumn: 4),
            tabWidth: 4
        )

        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 1, length: 3),
            NSRange(location: 8, length: 3),
            NSRange(location: 15, length: 3)
        ])
        XCTAssertEqual(plan.selection.main.range, NSRange(location: 15, length: 3))
        XCTAssertFalse(plan.wasTruncated)
    }

    func testShortLinesClampToLineEndWithoutVirtualSpaces() {
        let plan = RectangularSelectionPlanner.plan(
            text: "abcdef\nx\n12345",
            anchor: .init(line: 0, visualColumn: 3),
            target: .init(line: 2, visualColumn: 5),
            tabWidth: 4
        )

        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 3, length: 2),
            NSRange(location: 8, length: 0),
            NSRange(location: 12, length: 2)
        ])
    }

    func testHorizontalReverseDragPreservesDirectionOnEveryRow() {
        let plan = RectangularSelectionPlanner.plan(
            text: "abcdef\nghijkl",
            anchor: .init(line: 0, visualColumn: 5),
            target: .init(line: 1, visualColumn: 2),
            tabWidth: 4
        )

        XCTAssertTrue(plan.selection.ranges.allSatisfy(\.isBackward))
        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 2, length: 3), NSRange(location: 9, length: 3)
        ])
    }

    func testVerticalReverseDragKeepsTargetMostLineAsMain() {
        let plan = RectangularSelectionPlanner.plan(
            text: "aa\nbb\ncc",
            anchor: .init(line: 2, visualColumn: 0),
            target: .init(line: 0, visualColumn: 1),
            tabWidth: 4
        )

        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 0, length: 1),
            NSRange(location: 3, length: 1),
            NSRange(location: 6, length: 1)
        ])
        XCTAssertEqual(plan.selection.main.range, NSRange(location: 0, length: 1))
    }

    func testTabsUseVisualStopsAndSnapRectangleEdges() {
        let plan = RectangularSelectionPlanner.plan(
            text: "\tX\n    X",
            anchor: .init(line: 0, visualColumn: 2),
            target: .init(line: 1, visualColumn: 4),
            tabWidth: 4
        )

        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 0, length: 1), NSRange(location: 5, length: 2)
        ])
    }

    func testBothEdgesInsideOneTabSelectTheWholeTab() {
        let plan = RectangularSelectionPlanner.plan(
            text: "\tX", anchor: .init(line: 0, visualColumn: 1),
            target: .init(line: 0, visualColumn: 3), tabWidth: 4
        )
        XCTAssertEqual(plan.selection.main.range, NSRange(location: 0, length: 1))
    }

    func testCRLFAndCRTerminatorsAreExcluded() {
        let text = "abc\r\ndef\rghi"
        let plan = RectangularSelectionPlanner.plan(
            text: text, anchor: .init(line: 0, visualColumn: 1),
            target: .init(line: 2, visualColumn: 3), tabWidth: 4
        )

        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 1, length: 2),
            NSRange(location: 6, length: 2),
            NSRange(location: 10, length: 2)
        ])
    }

    func testUTF16OffsetsAccountForEmojiWithoutEnteringTerminator() {
        let text = "A😀B\n1234"
        XCTAssertEqual(
            RectangularSelectionPlanner.position(
                text: text, utf16Offset: 3, tabWidth: 4
            ),
            .init(line: 0, visualColumn: 2)
        )
        XCTAssertEqual(
            RectangularSelectionPlanner.position(
                text: text, utf16Offset: 2, tabWidth: 4
            ),
            .init(line: 0, visualColumn: 1)
        )
        let plan = RectangularSelectionPlanner.plan(
            text: text, anchor: .init(line: 0, visualColumn: 1),
            target: .init(line: 1, visualColumn: 3), tabWidth: 4
        )
        XCTAssertEqual(plan.selection.ranges.first?.range, NSRange(location: 1, length: 3))
    }

    func testMouseXUsesCodeMirrorStyleRoundedVisualColumn() {
        XCTAssertEqual(
            RectangularSelectionPlanner.position(
                text: "abc", line: 0, x: 14.9, characterWidth: 10
            ),
            .init(line: 0, visualColumn: 1)
        )
        XCTAssertEqual(
            RectangularSelectionPlanner.position(
                text: "abc", line: 0, x: 15.1, characterWidth: 10
            ),
            .init(line: 0, visualColumn: 2)
        )
    }

    func testZeroWidthRectangleProducesOneCursorPerLine() {
        let plan = RectangularSelectionPlanner.plan(
            text: "abc\ndef\nghi", anchor: .init(line: 0, visualColumn: 2),
            target: .init(line: 2, visualColumn: 2), tabWidth: 4
        )
        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 2, length: 0),
            NSRange(location: 6, length: 0),
            NSRange(location: 10, length: 0)
        ])
    }

    func testMaximumLinesTruncatesFromAnchorTowardTarget() {
        let plan = RectangularSelectionPlanner.plan(
            text: "a\nb\nc\nd", anchor: .init(line: 3, visualColumn: 0),
            target: .init(line: 0, visualColumn: 1), tabWidth: 4, maximumLines: 2
        )
        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 4, length: 1), NSRange(location: 6, length: 1)
        ])
        XCTAssertEqual(plan.selection.main.range, NSRange(location: 4, length: 1))
        XCTAssertTrue(plan.wasTruncated)
    }

    func testTrailingNewlineCreatesAnEmptyFinalRow() {
        let plan = RectangularSelectionPlanner.plan(
            text: "abc\n", anchor: .init(line: 0, visualColumn: 1),
            target: .init(line: 1, visualColumn: 3), tabWidth: 4
        )
        XCTAssertEqual(plan.selection.ranges.map(\.range), [
            NSRange(location: 1, length: 2), NSRange(location: 4, length: 0)
        ])
    }

    func testMergingAppendsInitialSelectionsAndDeduplicatesOverlap() {
        let initial = SelectionSet.single(anchor: 0, head: 2)
        let rectangle = RectangularSelectionPlanner.plan(
            text: "ab\ncd\nef", anchor: .init(line: 0, visualColumn: 0),
            target: .init(line: 2, visualColumn: 2), tabWidth: 4
        ).selection
        let merged = RectangularSelectionPlanner.merging(
            rectangle, into: initial, maximumSelections: 3
        )

        XCTAssertEqual(merged.ranges.map(\.range), [
            NSRange(location: 0, length: 2),
            NSRange(location: 3, length: 2),
            NSRange(location: 6, length: 2)
        ])
        XCTAssertEqual(merged.main.range, NSRange(location: 6, length: 2))
    }

    func testMergingKeepsRectangleMainAndBoundsTotalSelections() {
        let initial = SelectionSet(ranges: [
            .init(anchor: 20, head: 20), .init(anchor: 30, head: 30)
        ])
        let rectangle = SelectionSet(ranges: [
            .init(anchor: 0, head: 1), .init(anchor: 3, head: 4)
        ], mainIndex: 1)
        let merged = RectangularSelectionPlanner.merging(
            rectangle, into: initial, maximumSelections: 3
        )

        XCTAssertEqual(merged.ranges.map(\.range), [
            NSRange(location: 0, length: 1),
            NSRange(location: 3, length: 1),
            NSRange(location: 20, length: 0)
        ])
        XCTAssertEqual(merged.main.range, NSRange(location: 3, length: 1))
    }

    func testMergingDropsAnInitialCursorInsideRectangle() {
        let initial = SelectionSet.cursor(at: 1)
        let rectangle = SelectionSet.single(anchor: 0, head: 3)
        let merged = RectangularSelectionPlanner.merging(rectangle, into: initial)

        XCTAssertEqual(merged.ranges, [DirectedSelection(anchor: 0, head: 3)])
        XCTAssertEqual(merged.main, DirectedSelection(anchor: 0, head: 3))
    }
}
