import Foundation
import XCTest
@testable import LumenEditorApp

final class NativeTextEditorVisualPlannerTests: XCTestCase {
    func testFindHighlightPlanUsesExactRangesAndMarksCurrentMatch() {
        let plan = NativeTextEditorVisualPlanner.findHighlightPlan(
            text: "Cat cat catalog CAT",
            matches: [
                NSRange(location: 4, length: 3),
                NSRange(location: 16, length: 3)
            ],
            selectedMatchIndex: 1
        )

        XCTAssertEqual(plan.highlights, [
            .init(range: NSRange(location: 4, length: 3), isCurrent: false),
            .init(range: NSRange(location: 16, length: 3), isCurrent: true)
        ])
    }

    func testFindHighlightPlanKeepsRegexCaretAndRejectsOutOfBoundsRanges() {
        let plan = NativeTextEditorVisualPlanner.findHighlightPlan(
            text: "abc",
            matches: [
                NSRange(location: 0, length: 0),
                NSRange(location: 3, length: 0),
                NSRange(location: 2, length: 2),
                NSRange(location: 0, length: 3)
            ],
            selectedMatchIndex: 1
        )

        XCTAssertEqual(plan.highlights, [
            .init(range: NSRange(location: 0, length: 0), isCurrent: false),
            .init(range: NSRange(location: 3, length: 0), isCurrent: true),
            .init(range: NSRange(location: 0, length: 3), isCurrent: false)
        ])
    }

    func testFoldMarkerPlanRejectsInvalidRangesAndSelectsNestedVisibleMarker() {
        let source = "head\nbody\nmore\nend"
        let outer = TextFoldRegion(
            startLine: 1, endLine: 4,
            fullRange: NSRange(location: 0, length: 18),
            hiddenRange: NSRange(location: 6, length: 12)
        )
        let inner = TextFoldRegion(
            startLine: 1, endLine: 2,
            fullRange: NSRange(location: 0, length: 10),
            hiddenRange: NSRange(location: 6, length: 4)
        )
        let invalid = NativeTextEditorVisualPlanner.FoldMarker(
            id: "invalid", startLine: 9, endLine: 10,
            fullRange: NSRange(location: 99, length: 2),
            hiddenRange: NSRange(location: 100, length: 1), isFolded: false
        )

        var plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source,
            markers: [
                .init(
                    id: outer.id, startLine: outer.startLine, endLine: outer.endLine,
                    fullRange: outer.fullRange, hiddenRange: outer.hiddenRange,
                    isFolded: false
                ),
                .init(
                    id: inner.id, startLine: inner.startLine, endLine: inner.endLine,
                    fullRange: inner.fullRange, hiddenRange: inner.hiddenRange,
                    isFolded: false
                ),
                invalid
            ]
        )
        XCTAssertEqual(plan.markers.count, 2)
        XCTAssertEqual(plan.markerByStartLine[1]?.id, inner.id)
        XCTAssertEqual(source, "head\nbody\nmore\nend")

        plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source,
            markers: [
                .init(
                    id: outer.id, startLine: outer.startLine, endLine: outer.endLine,
                    fullRange: outer.fullRange, hiddenRange: outer.hiddenRange,
                    isFolded: true
                ),
                .init(
                    id: inner.id, startLine: inner.startLine, endLine: inner.endLine,
                    fullRange: inner.fullRange, hiddenRange: inner.hiddenRange,
                    isFolded: false
                )
            ]
        )
        XCTAssertEqual(plan.markerByStartLine[1]?.id, outer.id)
        XCTAssertTrue(plan.markerByStartLine[1]?.isFolded == true)
    }

    func testFoldMarkerPlanHidesDescendantHeadersInsideFoldedRange() {
        let source = "outer\nchild\nafter\nend\nx"
        let outer = NativeTextEditorVisualPlanner.FoldMarker(
            id: "outer", startLine: 1, endLine: 3,
            fullRange: NSRange(location: 0, length: 17),
            hiddenRange: NSRange(location: 6, length: 11), isFolded: true
        )
        let child = NativeTextEditorVisualPlanner.FoldMarker(
            id: "child", startLine: 2, endLine: 3,
            fullRange: NSRange(location: 6, length: 11),
            hiddenRange: NSRange(location: 12, length: 5), isFolded: false
        )
        let boundary = NativeTextEditorVisualPlanner.FoldMarker(
            id: "boundary", startLine: 4, endLine: 5,
            fullRange: NSRange(location: 17, length: 5),
            hiddenRange: NSRange(location: 21, length: 1), isFolded: false
        )

        var plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source, markers: [outer, child, boundary]
        )
        XCTAssertEqual(plan.markers.count, 3)
        XCTAssertNil(plan.markerByStartLine[2])
        XCTAssertEqual(plan.markerByStartLine[4]?.id, "boundary")

        let unfoldedOuter = NativeTextEditorVisualPlanner.FoldMarker(
            id: outer.id, startLine: outer.startLine, endLine: outer.endLine,
            fullRange: outer.fullRange, hiddenRange: outer.hiddenRange, isFolded: false
        )
        plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source, markers: [unfoldedOuter, child, boundary]
        )
        XCTAssertEqual(plan.markerByStartLine[2]?.id, "child")
    }

    func testFoldMarkerPlanHandlesCrossingRangesAndInvisibleFoldedSuppressors() {
        let source = String(repeating: "x", count: 50)
        let outer = NativeTextEditorVisualPlanner.FoldMarker(
            id: "outer", startLine: 1, endLine: 5,
            fullRange: NSRange(location: 0, length: 40),
            hiddenRange: NSRange(location: 10, length: 20), isFolded: true
        )
        let crossing = NativeTextEditorVisualPlanner.FoldMarker(
            id: "crossing", startLine: 2, endLine: 5,
            fullRange: NSRange(location: 20, length: 20),
            hiddenRange: NSRange(location: 20, length: 20), isFolded: true
        )
        let atStart = NativeTextEditorVisualPlanner.FoldMarker(
            id: "at-start", startLine: 3, endLine: 4,
            fullRange: NSRange(location: 10, length: 2),
            hiddenRange: NSRange(location: 11, length: 1), isFolded: false
        )
        let hiddenOnlyByCrossing = NativeTextEditorVisualPlanner.FoldMarker(
            id: "crossing-child", startLine: 4, endLine: 5,
            fullRange: NSRange(location: 35, length: 2),
            hiddenRange: NSRange(location: 36, length: 1), isFolded: false
        )
        let atEnd = NativeTextEditorVisualPlanner.FoldMarker(
            id: "at-end", startLine: 5, endLine: 6,
            fullRange: NSRange(location: 40, length: 2),
            hiddenRange: NSRange(location: 41, length: 1), isFolded: false
        )

        let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source,
            markers: [hiddenOnlyByCrossing, atEnd, crossing, atStart, outer]
        )

        XCTAssertEqual(plan.markers.count, 5)
        XCTAssertEqual(plan.markerByStartLine[1]?.id, "outer")
        XCTAssertNil(plan.markerByStartLine[2])
        XCTAssertNil(plan.markerByStartLine[3])
        XCTAssertNil(plan.markerByStartLine[4])
        XCTAssertEqual(plan.markerByStartLine[5]?.id, "at-end")
    }

    func testFoldMarkerPlanExcludesSelfAndUsesHalfOpenHiddenRange() {
        let source = String(repeating: "x", count: 24)
        let selfCovering = NativeTextEditorVisualPlanner.FoldMarker(
            id: "self", startLine: 1, endLine: 4,
            fullRange: NSRange(location: 5, length: 10),
            hiddenRange: NSRange(location: 5, length: 10), isFolded: true
        )
        let peerAtStart = NativeTextEditorVisualPlanner.FoldMarker(
            id: "peer-at-start", startLine: 2, endLine: 3,
            fullRange: NSRange(location: 5, length: 2),
            hiddenRange: NSRange(location: 6, length: 1), isFolded: false
        )
        let inside = NativeTextEditorVisualPlanner.FoldMarker(
            id: "inside", startLine: 3, endLine: 4,
            fullRange: NSRange(location: 14, length: 2),
            hiddenRange: NSRange(location: 15, length: 1), isFolded: false
        )
        let sameIDInside = NativeTextEditorVisualPlanner.FoldMarker(
            id: "self", startLine: 5, endLine: 6,
            fullRange: NSRange(location: 14, length: 2),
            hiddenRange: NSRange(location: 15, length: 1), isFolded: false
        )
        let atEnd = NativeTextEditorVisualPlanner.FoldMarker(
            id: "at-end", startLine: 4, endLine: 5,
            fullRange: NSRange(location: 15, length: 2),
            hiddenRange: NSRange(location: 16, length: 1), isFolded: false
        )

        let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source,
            markers: [inside, sameIDInside, atEnd, peerAtStart, selfCovering]
        )

        XCTAssertEqual(plan.markerByStartLine[1]?.id, "self")
        XCTAssertNil(plan.markerByStartLine[2])
        XCTAssertNil(plan.markerByStartLine[3])
        XCTAssertEqual(plan.markerByStartLine[4]?.id, "at-end")
        XCTAssertEqual(plan.markerByStartLine[5]?.id, "self")
    }

    func testFoldMarkerPlanChoosesSameStartMarkersDeterministically() {
        let source = String(repeating: "x", count: 64)
        let markers: [NativeTextEditorVisualPlanner.FoldMarker] = [
            .init(
                id: "u-long", startLine: 1, endLine: 4,
                fullRange: NSRange(location: 0, length: 12),
                hiddenRange: NSRange(location: 1, length: 1), isFolded: false
            ),
            .init(
                id: "z-short", startLine: 1, endLine: 2,
                fullRange: NSRange(location: 0, length: 4),
                hiddenRange: NSRange(location: 1, length: 1), isFolded: false
            ),
            .init(
                id: "a-short", startLine: 1, endLine: 2,
                fullRange: NSRange(location: 0, length: 4),
                hiddenRange: NSRange(location: 1, length: 1), isFolded: false
            ),
            .init(
                id: "fold-small", startLine: 2, endLine: 3,
                fullRange: NSRange(location: 20, length: 8),
                hiddenRange: NSRange(location: 21, length: 1), isFolded: true
            ),
            .init(
                id: "z-fold-large", startLine: 2, endLine: 4,
                fullRange: NSRange(location: 20, length: 12),
                hiddenRange: NSRange(location: 21, length: 1), isFolded: true
            ),
            .init(
                id: "a-fold-large", startLine: 2, endLine: 4,
                fullRange: NSRange(location: 20, length: 12),
                hiddenRange: NSRange(location: 21, length: 1), isFolded: true
            ),
            .init(
                id: "u-tiny", startLine: 2, endLine: 3,
                fullRange: NSRange(location: 20, length: 2),
                hiddenRange: NSRange(location: 21, length: 1), isFolded: false
            )
        ]

        let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source, markers: markers
        )
        let reversedPlan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source, markers: Array(markers.reversed())
        )

        XCTAssertEqual(plan.markerByStartLine[1]?.id, "a-short")
        XCTAssertEqual(plan.markerByStartLine[2]?.id, "a-fold-large")
        XCTAssertEqual(plan.markerByStartLine, reversedPlan.markerByStartLine)
    }

    func testFoldMarkerPlanHandlesMaximumMarkerCount() {
        let markerCount = NativeTextEditorVisualPlanner.maximumFoldMarkers
        let source = String(repeating: "x", count: markerCount * 2 + 1)
        let markers = (0..<markerCount).map { index in
            NativeTextEditorVisualPlanner.FoldMarker(
                id: "marker-\(index)", startLine: index + 1, endLine: index + 2,
                fullRange: NSRange(location: index * 2, length: 2),
                hiddenRange: NSRange(location: index * 2 + 1, length: 1),
                isFolded: false
            )
        }

        let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: source, markers: markers
        )

        XCTAssertEqual(plan.markers.count, markerCount)
        XCTAssertEqual(plan.markerByStartLine.count, markerCount)
        XCTAssertEqual(plan.markerByStartLine[1]?.id, "marker-0")
        XCTAssertEqual(plan.markerByStartLine[markerCount]?.id, "marker-9999")
    }

    func testDiagnosticPlanMapsOneBasedUTF16PositionsWithoutSplittingEmoji() {
        let text = "A😀B\r\n猫 warning"
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: text,
            diagnostics: [
                .init(
                    line: 1, column: 2, endLine: 1, endColumn: 4,
                    severity: .error
                ),
                .init(
                    line: 2, column: 1, endLine: 2, endColumn: 2,
                    severity: .warning
                )
            ]
        )

        XCTAssertEqual(plan.marks.map(\.range), [
            NSRange(location: 1, length: 2),
            NSRange(location: 6, length: 1)
        ])
        XCTAssertEqual(plan.markedLines, [1: .error, 2: .warning])
    }

    func testDiagnosticPlanExpandsMidSurrogateBoundaryToComposedCharacter() {
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: "A😀B",
            diagnostics: [.init(
                line: 1, column: 3, endLine: 1, endColumn: 4,
                severity: .information
            )]
        )

        XCTAssertEqual(plan.marks.map(\.range), [NSRange(location: 1, length: 2)])
    }

    func testDiagnosticPlanSupportsMultilineRangesAndCRLFCoordinates() {
        let text = "one\r\ntwo\nthree"
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: text,
            diagnostics: [.init(
                line: 1, column: 2, endLine: 3, endColumn: 3,
                severity: .warning
            )]
        )

        XCTAssertEqual(plan.marks.map(\.range), [NSRange(location: 1, length: 10)])
    }

    func testDiagnosticPlanRejectsInvalidPositionsAndUsesDrawableCaretFallback() {
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: "abc\n\nlast",
            diagnostics: [
                .init(line: 0, column: 1, severity: .error),
                .init(line: 8, column: 1, severity: .error),
                .init(line: 1, column: 99, severity: .error),
                .init(line: 1, column: 4, severity: .warning),
                .init(line: 2, column: 1, severity: .information)
            ]
        )

        XCTAssertEqual(plan.marks.map(\.range), [
            NSRange(location: 2, length: 1),
            NSRange(location: 4, length: 0)
        ])
        XCTAssertEqual(plan.markedLines, [1: .warning, 2: .information])
    }

    func testDiagnosticPlanKeepsHighestSeverityPerGutterLineAndIsBounded() {
        let diagnostics = [
            NativeTextEditorVisualPlanner.Diagnostic(
                line: 1, column: 1, severity: .information
            ),
            .init(line: 1, column: 2, severity: .warning),
            .init(line: 1, column: 3, severity: .error)
        ]
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: "abc", diagnostics: diagnostics, maximumMarks: 2
        )

        XCTAssertEqual(plan.marks.count, 2)
        XCTAssertEqual(plan.markedLines, [1: .warning])
    }

    func testDiagnosticPlanMapsEmptyDocumentLocationToGutterOnly() {
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: "",
            diagnostics: [.init(line: 1, column: 1, severity: .error)]
        )

        XCTAssertEqual(plan.marks.map(\.range), [NSRange(location: 0, length: 0)])
        XCTAssertEqual(plan.marks.map(\.line), [1])
        XCTAssertEqual(plan.marks.map(\.severity), [.error])
        XCTAssertEqual(plan.markedLines, [1: .error])
    }

    func testDiagnosticPlanAllowsUTF16ColumnInsideCombiningSequenceSafely() {
        let text = "e\u{301}x"
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: text,
            diagnostics: [.init(
                line: 1, column: 2, endLine: 1, endColumn: 3,
                severity: .information
            )]
        )

        XCTAssertEqual(plan.marks.map(\.range), [NSRange(location: 0, length: 2)])
    }

    func testDiagnosticPlanRejectsBackwardAndPartiallySpecifiedRanges() {
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: "first\nsecond",
            diagnostics: [
                .init(
                    line: 2, column: 2, endLine: 1, endColumn: 2,
                    severity: .error
                ),
                .init(line: 1, column: 1, endLine: 2, severity: .warning)
            ]
        )

        XCTAssertTrue(plan.marks.isEmpty)
        XCTAssertTrue(plan.markedLines.isEmpty)
    }

    func testPlanFindsASCIIWhitespaceAndTrailingRunsIndependently() {
        let text = "  alpha \t\n\tbeta\n"
        let plan = NativeTextEditorVisualPlanner.plan(
            text: text,
            visibleCharacterRange: NSRange(location: 0, length: text.utf16.count),
            tabWidth: 4
        )

        XCTAssertEqual(
            plan.whitespaceMarkers,
            [
                .init(location: 0, kind: .space),
                .init(location: 1, kind: .space),
                .init(location: 7, kind: .space),
                .init(location: 8, kind: .tab),
                .init(location: 10, kind: .tab)
            ]
        )
        XCTAssertEqual(
            plan.lines.compactMap(\.trailingWhitespaceRange),
            [NSRange(location: 7, length: 2)]
        )
        XCTAssertEqual(plan.lines.map(\.indentationColumns), [2, 4, 0])
    }

    func testPlanOnlyReturnsPhysicalLinesIntersectingVisibleCharacters() {
        let text = "first  \n second \nthird  "
        let secondLine = (text as NSString).range(of: " second ")
        let plan = NativeTextEditorVisualPlanner.plan(
            text: text,
            visibleCharacterRange: NSRange(
                location: secondLine.location + 1,
                length: secondLine.length - 1
            ),
            tabWidth: 4
        )

        XCTAssertEqual(plan.lines.count, 1)
        XCTAssertEqual(plan.lines[0].contentsRange, NSRange(
            location: secondLine.location + 1,
            length: secondLine.length - 1
        ))
        XCTAssertEqual(plan.lines[0].visibleContentsRange, NSRange(
            location: secondLine.location + 1,
            length: secondLine.length - 1
        ))
        XCTAssertEqual(
            plan.lines[0].trailingWhitespaceRange,
            NSRange(location: NSMaxRange(secondLine) - 1, length: 1)
        )
        XCTAssertTrue(plan.whitespaceMarkers.allSatisfy {
            NSLocationInRange($0.location, plan.visibleCharacterRange)
        })
    }

    func testMixedTabsAdvanceToTabStopsAndTabWidthIsClamped() {
        let text = " \t  value\n\tvalue"

        XCTAssertEqual(
            NativeTextEditorVisualPlanner.plan(
                text: text,
                visibleCharacterRange: NSRange(location: 0, length: text.utf16.count),
                tabWidth: 4
            ).lines.map(\.indentationColumns),
            [6, 4]
        )
        XCTAssertEqual(
            NativeTextEditorVisualPlanner.plan(
                text: "\tvalue",
                visibleCharacterRange: NSRange(location: 0, length: 6),
                tabWidth: 99
            ).lines.first?.indentationColumns,
            16
        )
    }

    func testCRLFAndUnicodeUseUTF16RangesWithoutMarkingLineTerminators() {
        let text = "😀 \t\r\n  z"
        let plan = NativeTextEditorVisualPlanner.plan(
            text: text,
            visibleCharacterRange: NSRange(location: 0, length: text.utf16.count),
            tabWidth: 2
        )

        XCTAssertEqual(plan.lines.map(\.contentsRange), [
            NSRange(location: 0, length: 4),
            NSRange(location: 6, length: 3)
        ])
        XCTAssertEqual(plan.lines.first?.trailingWhitespaceRange, NSRange(location: 2, length: 2))
        XCTAssertEqual(plan.whitespaceMarkers.map(\.location), [2, 3, 6, 7])
    }

    func testDisabledAnalysesAvoidProducingUnusedTokens() {
        let plan = NativeTextEditorVisualPlanner.plan(
            text: "    value  ",
            visibleCharacterRange: NSRange(location: 0, length: 11),
            tabWidth: 4,
            includeWhitespaceMarkers: false,
            includeIndentation: false,
            includeTrailingWhitespace: false
        )

        XCTAssertTrue(plan.whitespaceMarkers.isEmpty)
        XCTAssertEqual(plan.lines.first?.indentationColumns, 0)
        XCTAssertNil(plan.lines.first?.trailingWhitespaceRange)
    }

    func testVeryLargeDocumentPlansOnlyRequestedViewport() {
        let prefix = String(repeating: "offscreen line\n", count: 20_000)
        let visible = "    visible value  "
        let suffix = String(repeating: "\noffscreen line", count: 20_000)
        let text = prefix + visible + suffix
        let visibleRange = NSRange(location: prefix.utf16.count, length: visible.utf16.count)

        let plan = NativeTextEditorVisualPlanner.plan(
            text: text,
            visibleCharacterRange: visibleRange,
            tabWidth: 4
        )

        XCTAssertEqual(plan.visibleCharacterRange, visibleRange)
        XCTAssertEqual(plan.lines.count, 1)
        XCTAssertEqual(plan.lines[0].contentsRange, visibleRange)
        XCTAssertEqual(plan.lines[0].indentationColumns, 4)
        XCTAssertEqual(
            plan.lines[0].trailingWhitespaceRange,
            NSRange(location: NSMaxRange(visibleRange) - 2, length: 2)
        )
    }

    func testDecorationPlanHighlightsOnlyTheVisibleCurrentLine() {
        let text = "first line\nsecond line\nthird line"
        let visible = (text as NSString).range(of: "second line\n")
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: visible,
            selection: .init(anchor: visible.location + 4, head: visible.location + 4)
        )

        XCTAssertEqual(plan.currentLineRange, visible)
        XCTAssertTrue(plan.selectedWordMatchRanges.isEmpty)
        XCTAssertTrue(plan.matchingBracketRanges.isEmpty)
    }

    func testEmptyDocumentHasNoCharacterRangeDecoration() {
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: "", visibleCharacterRange: NSRange(location: 0, length: 0),
            selection: .init(anchor: 0, head: 0)
        )
        XCTAssertNil(plan.currentLineRange)
        XCTAssertTrue(plan.selectedWordMatchRanges.isEmpty)
        XCTAssertTrue(plan.matchingBracketRanges.isEmpty)
    }

    func testDecorationPlanDoesNotScanCurrentLineOutsideViewportSlice() {
        let prefix = String(repeating: "x", count: 50_000)
        let visible = "visible"
        let text = prefix + visible + String(repeating: "y", count: 50_000)
        let visibleRange = NSRange(location: prefix.utf16.count, length: visible.utf16.count)
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: visibleRange,
            selection: .init(anchor: visibleRange.location + 3, head: visibleRange.location + 3)
        )

        XCTAssertEqual(plan.currentLineRange, visibleRange)
    }

    func testSelectedUnicodeWordMatchesWholeWordsInsideViewport() {
        let text = "猫 猫咪 猫 _猫 猫"
        let selected = (text as NSString).range(of: "猫")
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text,
            visibleCharacterRange: NSRange(location: 0, length: (text as NSString).length),
            selection: .init(anchor: selected.location, head: NSMaxRange(selected))
        )

        XCTAssertEqual(plan.selectedWordRange, selected)
        XCTAssertEqual(plan.selectedWordMatchRanges, [
            NSRange(location: 5, length: 1),
            NSRange(location: 10, length: 1)
        ])
    }

    func testSelectedWordMatchesAreViewportBoundedAndExcludeSelection() {
        let text = "word word sword word word"
        let visible = NSRange(location: 5, length: 15)
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: visible,
            selection: .init(anchor: 5, head: 9)
        )

        XCTAssertEqual(plan.selectedWordMatchRanges, [NSRange(location: 16, length: 4)])
        XCTAssertTrue(plan.selectedWordMatchRanges.allSatisfy {
            NSIntersectionRange($0, visible) == $0
        })
    }

    func testSelectedWordMatchLimitIsReportedWithoutUnboundedOutput() {
        let text = "hit hit hit hit hit"
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: NSRange(location: 0, length: text.utf16.count),
            selection: .init(anchor: 0, head: 3), maximumSelectionMatches: 2
        )

        XCTAssertEqual(plan.selectedWordMatchRanges.count, 2)
        XCTAssertTrue(plan.selectionMatchesWereTruncated)
    }

    func testSelectionOutsideViewportCanDriveVisibleMatchesWithoutLineDecoration() {
        let source = "selected offscreen\nvisible selected"
        let visible = (source as NSString).range(of: "visible selected")
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: source, visibleCharacterRange: visible,
            selection: .init(anchor: 0, head: 8)
        )

        XCTAssertNil(plan.currentLineRange)
        XCTAssertEqual(plan.selectedWordRange, NSRange(location: 0, length: 8))
        XCTAssertEqual(plan.selectedWordMatchRanges, [
            NSRange(location: NSMaxRange(visible) - 8, length: 8)
        ])
    }

    func testOverlongSelectedWordIsRejectedBeforeMatching() {
        let word = String(repeating: "a", count:
            NativeTextEditorVisualPlanner.maximumSelectedWordUTF16Length + 1)
        let text = word + " " + word
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: NSRange(location: 0, length: text.utf16.count),
            selection: .init(anchor: 0, head: word.utf16.count)
        )

        XCTAssertNil(plan.selectedWordRange)
        XCTAssertTrue(plan.selectedWordMatchRanges.isEmpty)
    }

    func testPartialOrNonWordSelectionDoesNotProduceMatches() {
        let text = "alpha alpha-beta alpha"
        let visible = NSRange(location: 0, length: text.utf16.count)

        XCTAssertNil(NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: visible,
            selection: .init(anchor: 1, head: 5)
        ).selectedWordRange)
        XCTAssertNil(NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: visible,
            selection: .init(anchor: 6, head: 16)
        ).selectedWordRange)
    }

    func testMatchingBracketUsesCaretCandidatesAndNestedPairs() {
        let text = "call([value])"
        let visible = NSRange(location: 0, length: text.utf16.count)
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: visible,
            selection: .init(anchor: 4, head: 4)
        )

        XCTAssertEqual(plan.matchingBracketRanges, [
            NSRange(location: 4, length: 1),
            NSRange(location: 12, length: 1)
        ])
    }

    func testMatchingBracketFindsOpeningFromCaretAfterCloser() {
        let text = "(value)"
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text,
            visibleCharacterRange: NSRange(location: 0, length: text.utf16.count),
            selection: .init(anchor: text.utf16.count, head: text.utf16.count)
        )

        XCTAssertEqual(plan.matchingBracketRanges, [
            NSRange(location: text.utf16.count - 1, length: 1),
            NSRange(location: 0, length: 1)
        ])
    }

    func testBracketInsideSelectedTextOrQuotedTextIsNotHighlighted() {
        let quoted = #""(value)""#
        let visible = NSRange(location: 0, length: quoted.utf16.count)
        XCTAssertTrue(NativeTextEditorVisualPlanner.decorationPlan(
            text: quoted, visibleCharacterRange: visible,
            selection: .init(anchor: 1, head: 1)
        ).matchingBracketRanges.isEmpty)
        XCTAssertTrue(NativeTextEditorVisualPlanner.decorationPlan(
            text: "(value)",
            visibleCharacterRange: NSRange(location: 0, length: 7),
            selection: .init(anchor: 0, head: 7)
        ).matchingBracketRanges.isEmpty)
    }

    func testMatchingBracketSkipsQuotedAndCommentedBrackets() {
        let text = "{ \"}\" /* } */ value }"
        let visible = NSRange(location: 0, length: text.utf16.count)
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: visible,
            selection: .init(anchor: 0, head: 0)
        )

        XCTAssertEqual(plan.matchingBracketRanges, [
            NSRange(location: 0, length: 1),
            NSRange(location: text.utf16.count - 1, length: 1)
        ])
    }

    func testMismatchedBracketDoesNotPairAcrossInvalidBranch() {
        let text = "([)]"
        let plan = NativeTextEditorVisualPlanner.decorationPlan(
            text: text,
            visibleCharacterRange: NSRange(location: 0, length: text.utf16.count),
            selection: .init(anchor: 0, head: 0)
        )

        XCTAssertTrue(plan.matchingBracketRanges.isEmpty)
    }

    func testMatchingBracketRequiresBothEndsInsideViewportAndScanLimit() {
        let text = "(" + String(repeating: "x", count: 100) + ")"
        let full = NSRange(location: 0, length: text.utf16.count)

        XCTAssertTrue(NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: NSRange(location: 0, length: 20),
            selection: .init(anchor: 0, head: 0)
        ).matchingBracketRanges.isEmpty)
        XCTAssertTrue(NativeTextEditorVisualPlanner.decorationPlan(
            text: text, visibleCharacterRange: full,
            selection: .init(anchor: 0, head: 0),
            maximumBracketScanUTF16Length: 50
        ).matchingBracketRanges.isEmpty)
    }
}
