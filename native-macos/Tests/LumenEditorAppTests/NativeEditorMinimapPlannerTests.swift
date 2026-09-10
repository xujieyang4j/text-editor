import AppKit
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class NativeEditorMinimapPlannerTests: XCTestCase {
    func testEmptyAndWhitespaceOnlyDocumentsAreSafe() {
        XCTAssertEqual(NativeMinimapPlanner.plan(text: "").rows, [])
        let whitespace = NativeMinimapPlanner.plan(text: "   \n\t")
        XCTAssertTrue(whitespace.rows.allSatisfy { $0.runs.isEmpty })
    }

    func testRunsPreserveIndentationAndClampLongLines() {
        let plan = NativeMinimapPlanner.plan(text: "  alpha beta\nsecond")
        XCTAssertEqual(plan.rows.first?.runs, [2..<7, 8..<12])
        XCTAssertTrue(plan.rows.flatMap(\.runs).allSatisfy {
            $0.lowerBound >= 0 && $0.upperBound <= NativeMinimapPlanner.maximumColumns
        })
    }

    func testLargeDocumentsHaveABoundedSample() {
        let text = String(repeating: "some source line\n", count: 100_000)
        let plan = NativeMinimapPlanner.plan(text: text, maximumRows: 128)
        XCTAssertLessThanOrEqual(plan.rows.count, 128)
        XCTAssertTrue(plan.wasSampled)
        XCTAssertTrue(zip(plan.rows, plan.rows.dropFirst()).allSatisfy {
            $0.sourceFraction <= $1.sourceFraction
        })
    }

    func testScrollTargetYClampsAcrossMinimapBounds() {
        XCTAssertEqual(
            NativeMinimapPlanner.scrollTargetY(
                pointerY: -24, minimapHeight: 200, documentHeight: 1_000, viewportHeight: 200
            ),
            0
        )
        XCTAssertEqual(
            NativeMinimapPlanner.scrollTargetY(
                pointerY: 100, minimapHeight: 200, documentHeight: 1_000, viewportHeight: 200
            ),
            400
        )
        XCTAssertEqual(
            NativeMinimapPlanner.scrollTargetY(
                pointerY: 260, minimapHeight: 200, documentHeight: 1_000, viewportHeight: 200
            ),
            800
        )
    }

    func testScrollTargetYIsSafeWhenViewportAlreadyCoversDocument() {
        XCTAssertEqual(
            NativeMinimapPlanner.scrollTargetY(
                pointerY: 75, minimapHeight: 150, documentHeight: 120, viewportHeight: 240
            ),
            0
        )
        XCTAssertEqual(
            NativeMinimapPlanner.scrollTargetY(
                pointerY: 75, minimapHeight: 0, documentHeight: 120, viewportHeight: 20
            ),
            0
        )
    }

    func testViewportRectClampsVisibleRegionToMinimapBounds() {
        let rect = try XCTUnwrap(NativeMinimapPlanner.viewportRect(
            minimapBounds: NSRect(x: 0, y: 0, width: 80, height: 200),
            documentHeight: 1_000,
            visibleRect: NSRect(x: 0, y: 900, width: 400, height: 200)
        ))
        XCTAssertEqual(rect.origin.x, 1)
        XCTAssertEqual(rect.width, 78)
        XCTAssertEqual(rect.height, 40)
        XCTAssertEqual(rect.origin.y, 160)
    }

    @MainActor
    func testAccessibilityLabelUpdatesWhenOnlyLocaleChanges() throws {
        let container = NativeEditorContainerView(frame: NSRect(
            x: 0, y: 0, width: 600, height: 400
        ))
        let palette = NativeEditorPalette.make(
            colorScheme: .dark, compatibleWith: .dark,
            increasedContrast: false
        )

        container.configureMinimap(
            shown: true, text: "let value = 1", documentID: "document",
            revision: 7, palette: palette, locale: .enUS
        )
        let minimap = try XCTUnwrap(container.subviews.first {
            $0.accessibilityIdentifier() == "editor.minimap"
        })
        XCTAssertEqual(minimap.accessibilityLabel(), "Document minimap")

        container.configureMinimap(
            shown: true, text: "let value = 1", documentID: "document",
            revision: 7, palette: palette, locale: .zhCN
        )
        XCTAssertEqual(minimap.accessibilityLabel(), "文档缩略图")
        XCTAssertEqual(minimap.accessibilityIdentifier(), "editor.minimap")
    }
}
