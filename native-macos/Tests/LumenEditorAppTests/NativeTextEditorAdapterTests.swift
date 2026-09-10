import AppKit
import LumenEditorCore
import SwiftUI
import XCTest
@testable import LumenEditorApp

final class NativeTextEditorAdapterTests: XCTestCase {
    @MainActor
    private func makeRulerFixture(text: String) -> (
        scrollView: NSScrollView, textView: NSTextView, ruler: LineNumberRulerView
    ) {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 180)
        )
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 180)
        )
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.string = text
        scrollView.documentView = textView
        let ruler = LineNumberRulerView(
            scrollView: scrollView, orientation: .verticalRuler
        )
        ruler.frame = NSRect(x: 0, y: 0, width: 58, height: 180)
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        return (scrollView, textView, ruler)
    }

    @MainActor
    private func makeLayoutFixture(text: String) -> (
        textStorage: NSTextStorage, layoutManager: NativeTextEditorLayoutManager,
        textContainer: NSTextContainer, textView: NSTextView
    ) {
        let storage = NSTextStorage(string: text)
        let layoutManager = NativeTextEditorLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(width: 600, height: .greatestFiniteMagnitude)
        )
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 100),
            textContainer: container
        )
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        layoutManager.attachTextView(textView)
        layoutManager.ensureLayout(for: container)
        return (storage, layoutManager, container, textView)
    }

    func testFoldGutterAccessibilityCopyIsStableAndLocalized() {
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldGutterIdentifier,
            "lumen.editor.fold.gutter"
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldGutterLabel(locale: .enUS),
            "Code folding gutter"
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldGutterLabel(locale: .zhCN),
            "代码折叠槽"
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldGutterValue(
                markerCount: 3, foldedCount: 1, locale: .enUS
            ),
            "3 foldable regions, 1 folded"
        )
        let marker = NativeTextEditorVisualPlanner.FoldMarker(
            id: "fold", startLine: 2, endLine: 5,
            fullRange: NSRange(location: 4, length: 20),
            hiddenRange: NSRange(location: 10, length: 14), isFolded: false
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldActionAnnouncement(
                marker: marker, willFold: true, locale: .enUS
            ),
            "Folded lines 2 through 5"
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldActionAnnouncement(
                marker: marker, willFold: false, locale: .zhCN
            ),
            "已展开第 2 至 5 行"
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldMarkerIdentifier(marker),
            "lumen.editor.fold.gutter.marker.fold"
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldMarkerLabel(marker, locale: .enUS),
            "Fold lines 2 through 5"
        )
        XCTAssertEqual(
            NativeTextEditorAccessibility.foldMarkerValue(marker, locale: .enUS),
            "Expanded"
        )
    }

    @MainActor
    func testFoldGutterActivationUsesOnlyExactMarkerID() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let ruler = LineNumberRulerView(
            scrollView: scrollView, orientation: .verticalRuler
        )
        let marker = NativeTextEditorVisualPlanner.FoldMarker(
            id: "exact-fold", startLine: 1, endLine: 3,
            fullRange: NSRange(location: 0, length: 12),
            hiddenRange: NSRange(location: 5, length: 7), isFolded: false
        )
        var toggled: [String] = []
        ruler.updateFoldMarkers(
            .init(markers: [marker], markerByStartLine: [1: marker]),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )

        XCTAssertFalse(ruler.activateFoldMarker(id: "diagnostic-or-diff-lane"))
        XCTAssertTrue(ruler.activateFoldMarker(id: "exact-fold"))
        XCTAssertEqual(toggled, ["exact-fold"])
        XCTAssertEqual(ruler.accessibilityIdentifier(), "lumen.editor.fold.gutter")
        XCTAssertEqual(ruler.accessibilityValue() as? String, "1 foldable regions, 1 folded")
    }

    @MainActor
    func testFoldGutterExposesAndActivatesEveryVisibleMarker() throws {
        let fixture = makeRulerFixture(text: "one\ntwo\nthree\nfour")
        let first = NativeTextEditorVisualPlanner.FoldMarker(
            id: "first", startLine: 1, endLine: 2,
            fullRange: NSRange(location: 0, length: 7),
            hiddenRange: NSRange(location: 4, length: 3), isFolded: false
        )
        let second = NativeTextEditorVisualPlanner.FoldMarker(
            id: "second", startLine: 3, endLine: 4,
            fullRange: NSRange(location: 8, length: 10),
            hiddenRange: NSRange(location: 14, length: 4), isFolded: true
        )
        var toggled: [String] = []
        fixture.ruler.updateFoldMarkers(
            .init(markers: [second, first], markerByStartLine: [3: second, 1: first]),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        fixture.ruler.rebuildLineStarts()

        let children = fixture.ruler.foldMarkerAccessibilityElements()
        XCTAssertEqual(children.map { $0.accessibilityIdentifier() }, [
            "lumen.editor.fold.gutter.marker.first",
            "lumen.editor.fold.gutter.marker.second"
        ])
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, [
            "Fold lines 1 through 2", "Unfold lines 3 through 4"
        ])
        XCTAssertEqual(children.map { $0.accessibilityValue() as? String }, [
            "Expanded", "Folded"
        ])
        let hitPoint = NSPoint(
            x: children[1].accessibilityFrameInParentSpace().midX,
            y: children[1].accessibilityFrameInParentSpace().midY
        )
        XCTAssertTrue(
            fixture.ruler.foldMarkerAccessibilityHitTest(inParent: hitPoint) === children[1]
        )
        XCTAssertTrue(
            fixture.ruler.foldMarkerAccessibilityElements()[1] === children[1]
        )
        fixture.ruler.rebuildLineStarts()
        let geometryRefreshedChildren = fixture.ruler.foldMarkerAccessibilityElements()
        XCTAssertTrue(geometryRefreshedChildren[0] === children[0])
        XCTAssertTrue(geometryRefreshedChildren[1] === children[1])
        XCTAssertTrue(fixture.ruler.activateFoldMarker(at: hitPoint))
        let refreshedChildren = fixture.ruler.foldMarkerAccessibilityElements()
        XCTAssertTrue(refreshedChildren[1] === children[1])
        XCTAssertEqual(refreshedChildren[1].accessibilityLabel(), "Fold lines 3 through 4")
        XCTAssertEqual(refreshedChildren[1].accessibilityValue() as? String, "Expanded")
        XCTAssertTrue(refreshedChildren[0].accessibilityPerformPress())
        XCTAssertEqual(toggled, ["second", "first"])
    }

    @MainActor
    func testFoldGutterAccessibilityExcludesInvisibleSameLineMarker() {
        let fixture = makeRulerFixture(text: "head\nbody\nend")
        let hidden = NativeTextEditorVisualPlanner.FoldMarker(
            id: "hidden", startLine: 1, endLine: 2,
            fullRange: NSRange(location: 0, length: 9),
            hiddenRange: NSRange(location: 5, length: 4), isFolded: true
        )
        let visible = NativeTextEditorVisualPlanner.FoldMarker(
            id: "visible", startLine: 1, endLine: 3,
            fullRange: NSRange(location: 0, length: 13),
            hiddenRange: NSRange(location: 5, length: 8), isFolded: true
        )
        var toggled: [String] = []
        fixture.ruler.updateFoldMarkers(
            .init(markers: [hidden, visible], markerByStartLine: [1: visible]),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        fixture.ruler.rebuildLineStarts()

        XCTAssertEqual(
            fixture.ruler.foldMarkerAccessibilityElements().map {
                $0.accessibilityIdentifier()
            },
            ["lumen.editor.fold.gutter.marker.visible"]
        )
        XCTAssertFalse(fixture.ruler.activateFoldMarker(id: "hidden"))
        XCTAssertTrue(fixture.ruler.activateFoldMarker(id: "visible"))
        XCTAssertEqual(toggled, ["visible"])
        XCTAssertEqual(
            fixture.ruler.accessibilityValue() as? String,
            "1 foldable regions, 0 folded"
        )
    }

    @MainActor
    func testFoldGutterDeactivatesStaleAccessibilityElementWhileAncestorHidesIt() {
        let fixture = makeRulerFixture(text: "outer\nchild\nafter\nend")
        let outer = NativeTextEditorVisualPlanner.FoldMarker(
            id: "outer", startLine: 1, endLine: 3,
            fullRange: NSRange(location: 0, length: 17),
            hiddenRange: NSRange(location: 6, length: 11), isFolded: false
        )
        let child = NativeTextEditorVisualPlanner.FoldMarker(
            id: "child", startLine: 2, endLine: 3,
            fullRange: NSRange(location: 6, length: 11),
            hiddenRange: NSRange(location: 12, length: 5), isFolded: false
        )
        var toggled: [String] = []
        fixture.ruler.updateFoldMarkers(
            NativeTextEditorVisualPlanner.foldMarkerPlan(
                text: fixture.textView.string, markers: [outer, child]
            ),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        fixture.ruler.rebuildLineStarts()
        let staleChild = fixture.ruler.foldMarkerAccessibilityElements()[1]

        let foldedOuter = NativeTextEditorVisualPlanner.FoldMarker(
            id: outer.id, startLine: outer.startLine, endLine: outer.endLine,
            fullRange: outer.fullRange, hiddenRange: outer.hiddenRange, isFolded: true
        )
        fixture.ruler.updateFoldMarkers(
            NativeTextEditorVisualPlanner.foldMarkerPlan(
                text: fixture.textView.string, markers: [foldedOuter, child]
            ),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )

        XCTAssertEqual(
            fixture.ruler.foldMarkerAccessibilityElements().map(\.markerID), ["outer"]
        )
        XCTAssertFalse(staleChild.isActive)
        XCTAssertFalse(staleChild.accessibilityPerformPress())
        XCTAssertTrue(toggled.isEmpty)
    }

    @MainActor
    func testFoldGutterTombstonesRemovedAccessibilityElementBeforeIDReuse() throws {
        let fixture = makeRulerFixture(text: "one\ntwo\nthree\nfour")
        let original = NativeTextEditorVisualPlanner.FoldMarker(
            id: "reused", startLine: 1, endLine: 2,
            fullRange: NSRange(location: 0, length: 7),
            hiddenRange: NSRange(location: 4, length: 3), isFolded: false
        )
        var toggled: [String] = []
        fixture.ruler.updateFoldMarkers(
            .init(markers: [original], markerByStartLine: [1: original]),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        fixture.ruler.rebuildLineStarts()
        let staleElement = try XCTUnwrap(
            fixture.ruler.foldMarkerAccessibilityElements().first
        )

        fixture.ruler.updateFoldMarkers(
            .init(markers: [], markerByStartLine: [:]),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        XCTAssertTrue(fixture.ruler.foldMarkerAccessibilityElements().isEmpty)

        let replacement = NativeTextEditorVisualPlanner.FoldMarker(
            id: "reused", startLine: 3, endLine: 4,
            fullRange: NSRange(location: 8, length: 10),
            hiddenRange: NSRange(location: 14, length: 4), isFolded: false
        )
        fixture.ruler.updateFoldMarkers(
            .init(markers: [replacement], markerByStartLine: [3: replacement]),
            locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        let replacementElement = try XCTUnwrap(
            fixture.ruler.foldMarkerAccessibilityElements().first
        )

        XCTAssertFalse(staleElement === replacementElement)
        XCTAssertFalse(staleElement.isActive)
        XCTAssertFalse(staleElement.accessibilityPerformPress())
        XCTAssertTrue(replacementElement.accessibilityPerformPress())
        XCTAssertEqual(toggled, ["reused"])
    }

    @MainActor
    func testFoldGutterResetTombstonesSameGeometryAcrossDocumentIdentity() throws {
        let fixture = makeRulerFixture(text: "head\nbody\nend")
        let marker = NativeTextEditorVisualPlanner.FoldMarker(
            id: "0:13:5:8", startLine: 1, endLine: 3,
            fullRange: NSRange(location: 0, length: 13),
            hiddenRange: NSRange(location: 5, length: 8), isFolded: false
        )
        var firstDocumentToggles = 0
        fixture.ruler.updateFoldMarkers(
            .init(markers: [marker], markerByStartLine: [1: marker]),
            locale: .enUS, onToggle: { _ in
                firstDocumentToggles += 1
                return true
            }
        )
        fixture.ruler.rebuildLineStarts()
        let oldDocumentElement = try XCTUnwrap(
            fixture.ruler.foldMarkerAccessibilityElements().first
        )

        // The coordinator calls this when its document/view identity changes
        // and during dismantle, before the next document publishes markers.
        fixture.ruler.resetFoldMarkerAccessibilityCache()
        var secondDocumentToggles = 0
        fixture.ruler.updateFoldMarkers(
            .init(markers: [marker], markerByStartLine: [1: marker]),
            locale: .enUS, onToggle: { _ in
                secondDocumentToggles += 1
                return true
            }
        )
        let newDocumentElement = try XCTUnwrap(
            fixture.ruler.foldMarkerAccessibilityElements().first
        )

        XCTAssertFalse(oldDocumentElement === newDocumentElement)
        XCTAssertFalse(oldDocumentElement.isActive)
        XCTAssertFalse(oldDocumentElement.accessibilityPerformPress())
        XCTAssertTrue(newDocumentElement.accessibilityPerformPress())
        XCTAssertEqual(firstDocumentToggles, 0)
        XCTAssertEqual(secondDocumentToggles, 1)
    }

    @MainActor
    func testFoldGutterOptimisticToggleRecomputesSameStartMarker() {
        let fixture = makeRulerFixture(text: "head\nbody\nmore\nend")
        let inner = NativeTextEditorVisualPlanner.FoldMarker(
            id: "inner", startLine: 1, endLine: 2,
            fullRange: NSRange(location: 0, length: 10),
            hiddenRange: NSRange(location: 5, length: 5), isFolded: false
        )
        let outer = NativeTextEditorVisualPlanner.FoldMarker(
            id: "outer", startLine: 1, endLine: 4,
            fullRange: NSRange(location: 0, length: 18),
            hiddenRange: NSRange(location: 5, length: 13), isFolded: true
        )
        let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: fixture.textView.string, markers: [inner, outer]
        )
        var toggled: [String] = []
        fixture.ruler.updateFoldMarkers(
            plan, locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        fixture.ruler.rebuildLineStarts()

        XCTAssertTrue(fixture.ruler.activateFoldMarker(id: "outer"))
        XCTAssertFalse(fixture.ruler.activateFoldMarker(id: "outer"))
        XCTAssertTrue(fixture.ruler.activateFoldMarker(id: "inner"))
        XCTAssertEqual(toggled, ["outer", "inner"])
    }

    @MainActor
    func testFoldGutterOptimisticUnfoldRevealsLaterLineDescendant() {
        let fixture = makeRulerFixture(text: "outer\nchild\nafter\nend")
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
        let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: fixture.textView.string, markers: [outer, child]
        )
        var toggled: [String] = []
        fixture.ruler.updateFoldMarkers(
            plan, locale: .enUS, onToggle: { toggled.append($0); return true }
        )
        fixture.ruler.rebuildLineStarts()

        XCTAssertEqual(
            fixture.ruler.foldMarkerAccessibilityElements().map(\.markerID), ["outer"]
        )
        XCTAssertTrue(fixture.ruler.activateFoldMarker(id: "outer"))
        XCTAssertEqual(
            fixture.ruler.foldMarkerAccessibilityElements().map(\.markerID),
            ["outer", "child"]
        )
        XCTAssertTrue(fixture.ruler.activateFoldMarker(id: "child"))
        XCTAssertEqual(toggled, ["outer", "child"])
    }

    @MainActor
    func testTextKitFoldingCollapsesAndRestoresDocumentHeight() {
        let source = "head\none\ntwo\ntail"
        let fixture = makeLayoutFixture(text: source)
        fixture.layoutManager.ensureLayout(for: fixture.textContainer)
        let expandedHeight = fixture.layoutManager.usedRect(
            for: fixture.textContainer
        ).height
        let expandedTailGlyph = fixture.layoutManager.glyphIndexForCharacter(at: 13)
        let expandedTailY = fixture.layoutManager.lineFragmentRect(
            forGlyphAt: expandedTailGlyph, effectiveRange: nil
        ).minY
        let region = TextFoldRegion(
            startLine: 1, endLine: 3,
            fullRange: NSRange(location: 0, length: 13),
            hiddenRange: NSRange(location: 5, length: 8)
        )
        let foldedMarker = TextKitFoldMarker(region: region, isFolded: true)
        fixture.layoutManager.configureFolding(
            TextKitFoldSnapshot(
                documentID: "doc", viewID: "pane", documentRevision: 7,
                hiddenRanges: [region.hiddenRange], markers: [foldedMarker],
                presentationRevision: 1
            ),
            documentID: "doc", viewID: "pane", documentRevision: 7
        )
        fixture.layoutManager.ensureLayout(for: fixture.textContainer)
        let foldedHeight = fixture.layoutManager.usedRect(for: fixture.textContainer).height
        let foldedTailGlyph = fixture.layoutManager.glyphIndexForCharacter(at: 13)
        let foldedTailY = fixture.layoutManager.lineFragmentRect(
            forGlyphAt: foldedTailGlyph, effectiveRange: nil
        ).minY

        XCTAssertEqual(fixture.textStorage.string, source)
        XCTAssertEqual(fixture.textStorage.length, (source as NSString).length)
        XCTAssertLessThan(foldedHeight, expandedHeight)
        XCTAssertLessThan(foldedTailY, expandedTailY)
        XCTAssertFalse(fixture.layoutManager.isFoldedCharacter(at: 4))
        XCTAssertTrue(fixture.layoutManager.isFoldedCharacter(at: 5))
        XCTAssertTrue(fixture.layoutManager.isFoldedCharacter(at: 12))
        XCTAssertFalse(fixture.layoutManager.isFoldedCharacter(at: 13))

        fixture.layoutManager.configureFolding(
            nil, documentID: "doc", viewID: "pane", documentRevision: 7
        )
        fixture.layoutManager.ensureLayout(for: fixture.textContainer)
        let restoredTailGlyph = fixture.layoutManager.glyphIndexForCharacter(at: 13)
        let restoredTailY = fixture.layoutManager.lineFragmentRect(
            forGlyphAt: restoredTailGlyph, effectiveRange: nil
        ).minY
        XCTAssertEqual(
            fixture.layoutManager.usedRect(for: fixture.textContainer).height,
            expandedHeight, accuracy: 0.01
        )
        XCTAssertEqual(restoredTailY, expandedTailY, accuracy: 0.01)
        XCTAssertTrue(fixture.layoutManager.foldedRangesForTesting.isEmpty)
    }

    @MainActor
    func testTextKitFoldingNormalizesOverlappingHiddenRanges() {
        let source = "head\none\ntwo\ntail"
        let fixture = makeLayoutFixture(text: source)
        fixture.layoutManager.configureFolding(
            TextKitFoldSnapshot(
                documentID: "doc", viewID: "pane", documentRevision: 7,
                hiddenRanges: [
                    NSRange(location: 5, length: 4),
                    NSRange(location: 8, length: 5)
                ], presentationRevision: 1
            ),
            documentID: "doc", viewID: "pane", documentRevision: 7
        )

        XCTAssertEqual(
            fixture.layoutManager.foldedRangesForTesting,
            [NSRange(location: 5, length: 8)]
        )
    }

    @MainActor
    func testStaleFoldSnapshotDoesNotChangeLayout() {
        let source = "head\none\ntail"
        let fixture = makeLayoutFixture(text: source)
        fixture.layoutManager.ensureLayout(for: fixture.textContainer)
        let originalHeight = fixture.layoutManager.usedRect(for: fixture.textContainer).height
        let region = TextFoldRegion(
            startLine: 1, endLine: 2,
            fullRange: NSRange(location: 0, length: 9),
            hiddenRange: NSRange(location: 5, length: 4)
        )
        fixture.layoutManager.configureFolding(
            TextKitFoldSnapshot(
                documentID: "other", viewID: "pane", documentRevision: 7,
                hiddenRanges: [region.hiddenRange],
                markers: [TextKitFoldMarker(region: region, isFolded: true)],
                presentationRevision: 1
            ),
            documentID: "doc", viewID: "pane", documentRevision: 7
        )
        fixture.layoutManager.ensureLayout(for: fixture.textContainer)

        XCTAssertEqual(
            fixture.layoutManager.usedRect(for: fixture.textContainer).height,
            originalHeight, accuracy: 0.01
        )
        XCTAssertTrue(fixture.layoutManager.foldedRangesForTesting.isEmpty)
        XCTAssertNil(fixture.layoutManager.foldSnapshotIdentityForTesting)
    }

    @MainActor
    func testZeroLengthFindHighlightGeometryUsesInsertionPointsAndEOF() throws {
        let fixture = makeLayoutFixture(text: "abc")
        let origin = fixture.textView.textContainerOrigin
        let atStart = try XCTUnwrap(
            fixture.layoutManager.zeroLengthFindHighlightRect(at: 0, origin: origin)
        )
        let beforeB = try XCTUnwrap(
            fixture.layoutManager.zeroLengthFindHighlightRect(at: 1, origin: origin)
        )
        let beforeC = try XCTUnwrap(
            fixture.layoutManager.zeroLengthFindHighlightRect(at: 2, origin: origin)
        )
        let atEOF = try XCTUnwrap(
            fixture.layoutManager.zeroLengthFindHighlightRect(at: 3, origin: origin)
        )

        XCTAssertLessThan(atStart.minX, beforeB.minX)
        XCTAssertLessThan(beforeB.minX, beforeC.minX)
        XCTAssertLessThan(beforeC.minX, atEOF.minX)
        XCTAssertEqual(atStart.minY, beforeB.minY, accuracy: 0.01)
        XCTAssertEqual(beforeB.minY, atEOF.minY, accuracy: 0.01)
    }

    @MainActor
    func testZeroLengthFindHighlightGeometryUsesExtraLineAfterNewline() throws {
        let fixture = makeLayoutFixture(text: "abc\n")
        let eof = try XCTUnwrap(fixture.layoutManager.zeroLengthFindHighlightRect(
            at: 4, origin: fixture.textView.textContainerOrigin
        ))
        let beforeNewline = try XCTUnwrap(
            fixture.layoutManager.zeroLengthFindHighlightRect(
                at: 3, origin: fixture.textView.textContainerOrigin
            )
        )
        XCTAssertGreaterThan(eof.minY, beforeNewline.minY)
        XCTAssertLessThan(eof.minX, beforeNewline.minX)
    }

    func testZeroLengthFindHighlightInvalidationIncludesEveryAnchor() {
        let point: (Int, Bool) -> NativeTextEditorVisualPlanner.FindHighlight = {
            location, isCurrent in
            .init(
                range: NSRange(location: location, length: 0),
                isCurrent: isCurrent
            )
        }
        XCTAssertEqual(
            NativeTextEditorAdapter.findHighlightInvalidationRange(
                previous: [], current: [point(1, false)], textLength: 3
            ),
            NSRange(location: 1, length: 1)
        )
        XCTAssertEqual(
            NativeTextEditorAdapter.findHighlightInvalidationRange(
                previous: [point(0, false)], current: [point(0, true)], textLength: 3
            ),
            NSRange(location: 0, length: 1)
        )
        XCTAssertEqual(
            NativeTextEditorAdapter.findHighlightInvalidationRange(
                previous: [point(0, true)], current: [point(2, true)], textLength: 3
            ),
            NSRange(location: 0, length: 3)
        )
        XCTAssertEqual(
            NativeTextEditorAdapter.findHighlightInvalidationRange(
                previous: [], current: [point(3, true)], textLength: 3
            ),
            NSRange(location: 2, length: 1)
        )
        XCTAssertEqual(
            NativeTextEditorAdapter.findHighlightInvalidationRange(
                previous: [point(0, false)], current: [], textLength: 0
            ),
            NSRange(location: 0, length: 0)
        )
    }

    func testZeroLengthFindHighlightsDrawAfterTextKitBackgrounds() throws {
        let order = NativeTextEditorLayoutManager.findHighlightDrawingOrder
        XCTAssertLessThan(
            try XCTUnwrap(order.firstIndex(of: .editorBackgroundDecorations)),
            try XCTUnwrap(order.firstIndex(of: .textKitBackground))
        )
        XCTAssertLessThan(
            try XCTUnwrap(order.firstIndex(of: .textKitBackground)),
            try XCTUnwrap(order.firstIndex(of: .zeroWidthForeground))
        )
    }

    func testFoldedCharacterSweepMatchesReferenceAcrossManyRanges() {
        let ranges = stride(from: 2, to: 20_000, by: 4).map {
            NSRange(location: $0, length: 2)
        }
        let characters = Array(0..<20_000)
        let expected = characters.map { character in
            character % 4 == 2 || character % 4 == 3
        }

        XCTAssertEqual(
            NativeTextEditorAdapter.foldedCharacterMask(
                characterIndexes: characters, foldedRanges: ranges
            ),
            expected
        )
    }

    func testFoldedCharacterSweepHandlesNonmonotonicAndRepeatedIndexes() {
        let ranges = [
            NSRange(location: 2, length: 2),
            NSRange(location: 8, length: 3)
        ]
        XCTAssertEqual(
            NativeTextEditorAdapter.foldedCharacterMask(
                characterIndexes: [0, 2, 3, 3, 9, 10, 7, 2, 11],
                foldedRanges: ranges
            ),
            [false, true, true, true, true, true, false, true, false]
        )
        XCTAssertEqual(
            NativeTextEditorAdapter.foldedCharacterMask(
                characterIndexes: [11, 2], foldedRanges: ranges
            ),
            [false, true]
        )
    }

    @MainActor
    func testZeroLengthForegroundCycleAccumulatesChunksAndDeduplicates() {
        let fixture = makeLayoutFixture(text: "abcdef")
        let first = NativeTextEditorVisualPlanner.FindHighlight(
            range: NSRange(location: 1, length: 0), isCurrent: false
        )
        let second = NativeTextEditorVisualPlanner.FindHighlight(
            range: NSRange(location: 5, length: 0), isCurrent: true
        )
        fixture.layoutManager.configureFindHighlightsForTesting([first, second])

        fixture.layoutManager.beginZeroLengthFindHighlightDrawing()
        fixture.layoutManager.accumulateZeroLengthFindHighlights(
            in: NSRange(location: 0, length: 3)
        )
        fixture.layoutManager.accumulateZeroLengthFindHighlights(
            in: NSRange(location: 3, length: 0)
        )
        fixture.layoutManager.accumulateZeroLengthFindHighlights(
            in: NSRange(location: 0, length: 3)
        )
        fixture.layoutManager.accumulateZeroLengthFindHighlights(
            in: NSRange(location: 3, length: 3)
        )
        XCTAssertEqual(
            fixture.layoutManager.takePendingZeroLengthFindHighlights(), [first, second]
        )
        XCTAssertTrue(fixture.layoutManager.takePendingZeroLengthFindHighlights().isEmpty)

        fixture.layoutManager.accumulateZeroLengthFindHighlights(
            in: NSRange(location: 0, length: 3)
        )
        fixture.layoutManager.beginZeroLengthFindHighlightDrawing()
        XCTAssertTrue(fixture.layoutManager.takePendingZeroLengthFindHighlights().isEmpty)
    }

    @MainActor
    func testTerminationEditabilityGateKeepsTextSelectableButReadOnly() {
        let textView = NSTextView(frame: .zero)
        NativeTextEditorAdapter.applyEditability(false, to: textView)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)

        NativeTextEditorAdapter.applyEditability(true, to: textView)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
    }

    func testAccessibilityMetadataLocalizesLabelButKeepsStablePaneIdentity() {
        let english = NativeTextEditorAccessibility.metadata(
            documentDisplayName: "README.md", paneIndex: 1, viewID: "right-pane",
            locale: .enUS
        )
        let chinese = NativeTextEditorAccessibility.metadata(
            documentDisplayName: "README.md", paneIndex: 1, viewID: "right-pane",
            locale: .zhCN
        )

        XCTAssertEqual(english.identifier, "lumen.editor.pane.right.pane.text")
        XCTAssertEqual(chinese.identifier, english.identifier)
        XCTAssertEqual(english.label, "README.md, editor, pane 2")
        XCTAssertEqual(chinese.label, "README.md，第 2 个窗格编辑器")
    }

    func testAccessibilityIdentifiersDistinguishPanesDisplayingSameDocument() {
        let left = NativeTextEditorAccessibility.metadata(
            documentDisplayName: "shared.swift", paneIndex: 0, viewID: "left",
            locale: .enUS
        )
        let right = NativeTextEditorAccessibility.metadata(
            documentDisplayName: "shared.swift", paneIndex: 1, viewID: "right",
            locale: .enUS
        )

        XCTAssertNotEqual(left.identifier, right.identifier)
    }

    @MainActor
    func testAccessibilityMetadataUpdatesRealTextViewWithoutReplacingTextSemantics() {
        let textView = NSTextView(frame: .zero)
        textView.string = "alpha beta"
        textView.setSelectedRange(NSRange(location: 6, length: 4))

        NativeTextEditorAccessibility.apply(
            NativeTextEditorAccessibility.metadata(
                documentDisplayName: "notes.txt", paneIndex: 0, viewID: "left",
                locale: .enUS
            ),
            to: textView
        )
        XCTAssertEqual(textView.accessibilityIdentifier(), "lumen.editor.pane.left.text")
        XCTAssertEqual(textView.accessibilityLabel(), "notes.txt, editor, pane 1")
        XCTAssertEqual(textView.string, "alpha beta")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 4))

        NativeTextEditorAccessibility.apply(
            NativeTextEditorAccessibility.metadata(
                documentDisplayName: "notes.txt", paneIndex: 1, viewID: "right",
                locale: .zhCN
            ),
            to: textView
        )
        XCTAssertEqual(textView.accessibilityIdentifier(), "lumen.editor.pane.right.text")
        XCTAssertEqual(textView.accessibilityLabel(), "notes.txt，第 2 个窗格编辑器")
        XCTAssertEqual(textView.string, "alpha beta")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 4))
    }

    func testAccessibilityHelpSummarizesDiagnosticsWithoutMessages() {
        let privateMessage = "secret token from compiler output"
        let diagnostics = [
            LanguageServerDiagnostic(
                line: 1, column: 1, severity: .error, message: privateMessage
            ),
            LanguageServerDiagnostic(
                line: 2, column: 3, severity: .warning, message: "another detail"
            ),
            LanguageServerDiagnostic(
                line: 4, column: 2, severity: .info, message: "internal path"
            )
        ]

        let english = NativeTextEditorAccessibility.help(
            diagnostics: diagnostics, locale: .enUS
        )
        let chinese = NativeTextEditorAccessibility.help(
            diagnostics: diagnostics, locale: .zhCN
        )
        XCTAssertEqual(
            english,
            "Current document has 3 diagnostics: 1 errors, 1 warnings, 1 information"
        )
        XCTAssertEqual(chinese, "当前文档有 3 个诊断：1 个错误，1 个警告，1 个信息")
        XCTAssertFalse(english.contains(privateMessage))
        XCTAssertFalse(chinese.contains(privateMessage))
    }

    func testReconcileEditUsesUTF16OffsetsAndDoesNotSplitSurrogatePairs() {
        let edit = NativeTextEditorAdapter.reconcileEdit(
            from: "A😀B",
            to: "A😃B"
        )

        XCTAssertEqual(edit, TextEdit(from: 1, to: 3, insert: "😃"))
        XCTAssertEqual(edit.flatMap { NativeTextEditorAdapter.applying($0, to: "A😀B") }, "A😃B")
    }

    func testReconcileEditFindsOneMiddleReplacement() {
        XCTAssertEqual(
            NativeTextEditorAdapter.reconcileEdit(
                from: "prefix old suffix",
                to: "prefix new suffix"
            ),
            TextEdit(from: 7, to: 10, insert: "new")
        )
        XCTAssertNil(NativeTextEditorAdapter.reconcileEdit(from: "same", to: "same"))
    }

    @MainActor
    func testRejectedUnexpectedEditRestoresRevisionAndAutoClosingProvenance() throws {
        var transactions: [TextTransaction] = []
        var decisions = [true, false, true]
        let editor = NativeTextEditor(
            text: "", documentID: "doc", documentDisplayName: "Draft",
            viewID: "pane", paneIndex: 0, documentRevision: 7,
            selections: .cursor(at: 0), isFocused: Binding.constant(false),
            completionController: CompletionController(
                workspaceCache: WorkspaceCompletionCache()
            ),
            onTextChange: { transaction in
                transactions.append(transaction)
                return decisions.removeFirst()
            },
            onSelectionChange: { _ in true }, onScrollChange: { _ in }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView(frame: .zero)
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertFalse(coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "("
        ))
        XCTAssertEqual(textView.string, "()")

        textView.string = "()x"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.textDidChange(Notification(
            name: NSText.didChangeNotification, object: textView
        ))
        XCTAssertEqual(textView.string, "()")

        XCTAssertFalse(coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 1, length: 0),
            replacementString: ")"
        ))
        XCTAssertEqual(transactions.count, 3)
        let skipTransaction = try XCTUnwrap(transactions.last)
        XCTAssertEqual(skipTransaction.expectedRevision, 8)
        XCTAssertTrue(skipTransaction.edits.isEmpty)
        XCTAssertEqual(skipTransaction.selection, .cursor(at: 2))
    }

    @MainActor
    func testRejectedUnexpectedEditRestoresMappedParserIndentation() throws {
        let source = "value"
        let indentation = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "SQL", revision: 7,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [.init(lineFrom: 0, columns: 0)],
            transitionEntries: [.init(position: 5, insert: ",", columns: 2)]
        ))
        var transactions: [TextTransaction] = []
        var decisions = [true, false, true]
        let editor = NativeTextEditor(
            text: source, documentID: "doc", documentDisplayName: "Query",
            viewID: "pane", paneIndex: 0, documentRevision: 7,
            selections: .cursor(at: 5), isFocused: Binding.constant(false),
            tabWidth: 4, indentWidth: 2, insertSpaces: true, language: "SQL",
            parsedIndentation: indentation,
            completionController: CompletionController(
                workspaceCache: WorkspaceCompletionCache()
            ),
            onTextChange: { transaction in
                transactions.append(transaction)
                return decisions.removeFirst()
            },
            onSelectionChange: { _ in true }, onScrollChange: { _ in }
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView(frame: .zero)
        textView.string = source
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        XCTAssertFalse(coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementString: ","
        ))
        XCTAssertEqual(textView.string, "value,")

        textView.string = "value,x"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        coordinator.textDidChange(Notification(
            name: NSText.didChangeNotification, object: textView
        ))
        XCTAssertEqual(textView.string, "value,")

        XCTAssertFalse(coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 6, length: 0),
            replacementString: "\n"
        ))
        let newlineTransaction = try XCTUnwrap(transactions.last)
        XCTAssertEqual(newlineTransaction.expectedRevision, 8)
        XCTAssertEqual(textView.string, "value,\n  ")
    }

    func testIndentationTransitionRequiresExactNonIMESelectionIdentity() throws {
        let source = "if ready"
        let snapshot = try XCTUnwrap(CodeMirrorIndentationSnapshot(
            text: source, language: "Python", revision: 4,
            tabWidth: 4, indentWidth: 2, insertSpaces: true,
            entries: [.init(lineFrom: 0, columns: 0)],
            transitionEntries: [.init(
                position: 8, insert: ":", columns: 2
            )]
        ))
        let transaction = try TextTransaction(
            edits: [.init(from: 8, to: 8, insert: ":")],
            selection: .cursor(at: 9), expectedRevision: 4
        )
        XCTAssertNotNil(NativeTextEditorAdapter.mappedIndentationAfterAcceptedEdit(
            snapshot, transaction: transaction, oldText: source,
            newText: "if ready:", nextRevision: 5,
            selectionBefore: .cursor(at: 8), selectionAfter: .cursor(at: 9),
            allowsSingleCharacterTransition: true
        ))
        XCTAssertNil(NativeTextEditorAdapter.mappedIndentationAfterAcceptedEdit(
            snapshot, transaction: transaction, oldText: source,
            newText: "if ready:", nextRevision: 5,
            selectionBefore: .cursor(at: 8), selectionAfter: .cursor(at: 9),
            allowsSingleCharacterTransition: false
        ))
        XCTAssertNil(NativeTextEditorAdapter.mappedIndentationAfterAcceptedEdit(
            snapshot, transaction: transaction, oldText: source,
            newText: "if ready:", nextRevision: 5,
            selectionBefore: .cursor(at: 7), selectionAfter: .cursor(at: 9),
            allowsSingleCharacterTransition: true
        ))
    }

    func testPluralEditsStaySeparateAndPreserveInterveningText() throws {
        let edits = try XCTUnwrap(NativeTextEditorAdapter.textEdits(
            in: "0123456789",
            affectedRanges: [
                NSRange(location: 7, length: 1),
                NSRange(location: 2, length: 2)
            ],
            replacementStrings: ["X", "YZ"]
        ))

        XCTAssertEqual(edits, [
            TextEdit(from: 2, to: 4, insert: "YZ"),
            TextEdit(from: 7, to: 8, insert: "X")
        ])
        XCTAssertEqual(
            try TextTransaction(edits: edits).applying(to: "0123456789"),
            "01YZ456X89"
        )
    }

    func testPluralEditsDoNotSwallowAnotherPaneCursorBetweenThem() throws {
        let edits = try XCTUnwrap(NativeTextEditorAdapter.textEdits(
            in: "0123456789",
            affectedRanges: [
                NSRange(location: 2, length: 1),
                NSRange(location: 7, length: 1)
            ],
            replacementStrings: ["AA", "BB"]
        ))
        let transaction = try TextTransaction(edits: edits)

        XCTAssertEqual(
            transaction.mapSelection(.cursor(at: 5), cursorAssociation: .before),
            .cursor(at: 6)
        )
    }

    func testTextEditsRejectOverlapAndOutOfBoundsRanges() {
        XCTAssertNil(NativeTextEditorAdapter.textEdits(
            in: "abcdef",
            affectedRanges: [
                NSRange(location: 1, length: 3),
                NSRange(location: 2, length: 2)
            ],
            replacementStrings: ["x", "y"]
        ))
        XCTAssertNil(NativeTextEditorAdapter.textEdits(
            in: "abc",
            affectedRanges: [NSRange(location: 4, length: 0)],
            replacementStrings: ["x"]
        ))
    }

    func testAppKitSelectionRoundTripPreservesDirectionsAndMainRange() {
        let original = SelectionSet(
            ranges: [
                DirectedSelection(anchor: 2, head: 5),
                DirectedSelection(anchor: 14, head: 10)
            ],
            mainIndex: 1
        )

        XCTAssertEqual(
            NativeTextEditorAdapter.appKitRanges(from: original),
            [NSRange(location: 10, length: 4), NSRange(location: 2, length: 3)]
        )
        let restored = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: original.ranges.map(\.range),
            mainRange: original.main.range,
            preserving: original,
            utf16Length: 20
        )
        XCTAssertEqual(restored, original)
    }

    func testSelectionReadClampsAndKeepsAllRanges() {
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [
                NSRange(location: 2, length: 1),
                NSRange(location: 8, length: 20)
            ],
            mainRange: NSRange(location: 8, length: 20),
            preserving: nil,
            utf16Length: 10
        )

        XCTAssertEqual(selection.ranges.map(\.range), [
            NSRange(location: 2, length: 1),
            NSRange(location: 8, length: 2)
        ])
        XCTAssertEqual(selection.main.range, NSRange(location: 8, length: 2))
    }

    func testShiftLeftUsesCapturedAnchorToCreateBackwardSelection() {
        let previous = SelectionSet.cursor(at: 5)
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [NSRange(location: 4, length: 1)],
            mainRange: NSRange(location: 4, length: 1),
            preserving: previous,
            directionAnchors: NativeTextEditorAdapter.directionAnchors(from: previous),
            utf16Length: 10
        )

        XCTAssertEqual(selection.main, DirectedSelection(anchor: 5, head: 4))
    }

    func testShiftRightUsesCapturedAnchorToCreateForwardSelection() {
        let previous = SelectionSet.cursor(at: 5)
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [NSRange(location: 5, length: 1)],
            mainRange: NSRange(location: 5, length: 1),
            preserving: previous,
            directionAnchors: NativeTextEditorAdapter.directionAnchors(from: previous),
            utf16Length: 10
        )

        XCTAssertEqual(selection.main, DirectedSelection(anchor: 5, head: 6))
    }

    func testReverseMouseDragUsesMouseDownOffsetAsAnchor() {
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [NSRange(location: 2, length: 6)],
            mainRange: NSRange(location: 2, length: 6),
            preserving: .cursor(at: 0), directionAnchors: [8],
            utf16Length: 10
        )

        XCTAssertEqual(selection.main, DirectedSelection(anchor: 8, head: 2))
    }

    func testRedraggingSameRangeFromOppositeEndUpdatesDirection() {
        let range = NSRange(location: 2, length: 6)
        let previous = SelectionSet.single(anchor: 2, head: 8)
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [range], mainRange: range,
            preserving: previous, directionAnchors: [8],
            utf16Length: 10
        )

        XCTAssertEqual(selection.main, DirectedSelection(anchor: 8, head: 2))
    }

    func testUnhintedSameRangeKeepsPreviousDirection() {
        let range = NSRange(location: 2, length: 6)
        let previous = SelectionSet.single(anchor: 8, head: 2)
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [range], mainRange: range,
            preserving: previous, utf16Length: 10
        )

        XCTAssertEqual(selection, previous)
    }

    func testDirectionHintsUseRangeCorrespondenceWhenAdjacentAnchorsAreAmbiguous() {
        let previous = SelectionSet(ranges: [
            DirectedSelection(anchor: 2, head: 2),
            DirectedSelection(anchor: 5, head: 5)
        ], mainIndex: 1)
        let selection = NativeTextEditorAdapter.selectionSet(
            // AppKit may return document order even though hints are active-first.
            fromAppKitRanges: [
                NSRange(location: 2, length: 3),
                NSRange(location: 5, length: 2)
            ],
            mainRange: NSRange(location: 5, length: 2),
            preserving: previous,
            directionAnchors: NativeTextEditorAdapter.directionAnchors(from: previous),
            utf16Length: 10
        )

        XCTAssertEqual(selection, SelectionSet(ranges: [
            DirectedSelection(anchor: 2, head: 5),
            DirectedSelection(anchor: 5, head: 7)
        ], mainIndex: 1))
    }

    func testDuplicateDirectionAnchorValuesRemainPairedByRange() {
        let previous = SelectionSet(ranges: [
            DirectedSelection(anchor: 5, head: 2),
            DirectedSelection(anchor: 5, head: 7)
        ], mainIndex: 1)
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: previous.ranges.map(\.range),
            mainRange: previous.main.range, preserving: previous,
            directionAnchors: NativeTextEditorAdapter.directionAnchors(from: previous),
            utf16Length: 10
        )

        XCTAssertEqual(selection, previous)
    }

    func testChangedMultiSelectionUsesRemainingHintOrderAfterExactMatch() {
        let previous = SelectionSet(ranges: [
            DirectedSelection(anchor: 2, head: 4),
            DirectedSelection(anchor: 8, head: 8)
        ], mainIndex: 1)
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [
                NSRange(location: 2, length: 2),
                NSRange(location: 8, length: 2)
            ],
            mainRange: NSRange(location: 8, length: 2),
            preserving: previous, directionAnchors: [8, 2],
            utf16Length: 12
        )

        XCTAssertEqual(selection.ranges, [
            DirectedSelection(anchor: 2, head: 4),
            DirectedSelection(anchor: 8, head: 10)
        ])
        XCTAssertEqual(selection.main, DirectedSelection(anchor: 8, head: 10))
    }

    func testDirectionHintsPreserveMultipleSelectionsWithoutChangingMainRange() {
        let previous = SelectionSet(ranges: [
            .init(anchor: 2, head: 2),
            .init(anchor: 8, head: 8)
        ], mainIndex: 1)
        let selection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: [
                NSRange(location: 6, length: 2),
                NSRange(location: 2, length: 2)
            ],
            mainRange: NSRange(location: 6, length: 2),
            preserving: previous,
            directionAnchors: NativeTextEditorAdapter.directionAnchors(from: previous),
            utf16Length: 12
        )

        XCTAssertEqual(selection.ranges, [
            DirectedSelection(anchor: 2, head: 4),
            DirectedSelection(anchor: 8, head: 6)
        ])
        XCTAssertEqual(selection.main, DirectedSelection(anchor: 8, head: 6))
    }

    func testSelectionAfterReplacementUsesPostEditUTF16Cursors() {
        let initial = SelectionSet(
            ranges: [
                DirectedSelection(anchor: 1, head: 1),
                DirectedSelection(anchor: 4, head: 4)
            ],
            mainIndex: 1
        )
        let final = NativeTextEditorAdapter.selectionsAfterReplacing(
            initial,
            affectedRanges: [
                NSRange(location: 1, length: 0),
                NSRange(location: 4, length: 0)
            ],
            replacementStrings: ["😀", "x"],
            originalUTF16Length: 6
        )

        XCTAssertEqual(final.ranges.map(\.head), [3, 7])
        XCTAssertEqual(final.main.head, 7)
    }

    func testScrollPositionRoundsAndClampsCoordinates() {
        XCTAssertEqual(
            NativeTextEditorAdapter.scrollPosition(from: NSPoint(x: 12.49, y: 20.6)),
            NativeTextEditorScrollPosition(x: 12, y: 21)
        )
        XCTAssertEqual(
            NativeTextEditorAdapter.scrollPosition(from: NSPoint(x: -4, y: .infinity)),
            .zero
        )
    }

    func testOptionDragThresholdRequiresMeaningfulMovement() {
        XCTAssertFalse(NativeTextEditorAdapter.beginsRectangularSelectionDrag(
            from: NSPoint(x: 10, y: 10),
            to: NSPoint(x: 12, y: 12)
        ))
        XCTAssertTrue(NativeTextEditorAdapter.beginsRectangularSelectionDrag(
            from: NSPoint(x: 10, y: 10),
            to: NSPoint(x: 14, y: 10)
        ))
    }

    func testOptionClickSelectionAppendsRoundedCursorPosition() {
        let selection = NativeTextEditorAdapter.optionClickSelection(
            in: "abc\ndef",
            at: .init(line: 1, visualColumn: 2),
            initialSelection: .cursor(at: 1),
            tabWidth: 4
        )

        XCTAssertEqual(selection.ranges.map(\.range), [
            NSRange(location: 1, length: 0),
            NSRange(location: 6, length: 0)
        ])
        XCTAssertEqual(selection.main.range, NSRange(location: 6, length: 0))
    }

    func testOptionClickSelectionRoundsInsideWideGlyphsUsingNearestBoundary() {
        let tabbed = NativeTextEditorAdapter.optionClickSelection(
            in: "\tX",
            at: .init(line: 0, visualColumn: 1),
            initialSelection: .cursor(at: 1),
            tabWidth: 4
        )
        XCTAssertEqual(tabbed.main.range, NSRange(location: 0, length: 0))

        let emoji = NativeTextEditorAdapter.optionClickSelection(
            in: "A😀B",
            at: .init(line: 0, visualColumn: 2),
            initialSelection: .cursor(at: 0),
            tabWidth: 4
        )
        XCTAssertEqual(emoji.main.range, NSRange(location: 3, length: 0))
    }

    func testOptionClickSelectionDeduplicatesExistingCursorAndHonorsMaximum() {
        let duplicate = NativeTextEditorAdapter.optionClickSelection(
            in: "abc",
            at: .init(line: 0, visualColumn: 1),
            initialSelection: SelectionSet(ranges: [
                .init(anchor: 1, head: 1),
                .init(anchor: 3, head: 3)
            ], mainIndex: 1),
            tabWidth: 4
        )
        XCTAssertEqual(duplicate.ranges.map(\.range), [
            NSRange(location: 1, length: 0),
            NSRange(location: 3, length: 0)
        ])
        XCTAssertEqual(duplicate.main.range, NSRange(location: 1, length: 0))

        let bounded = NativeTextEditorAdapter.optionClickSelection(
            in: "abcdef",
            at: .init(line: 0, visualColumn: 5),
            initialSelection: SelectionSet(ranges: [
                .init(anchor: 0, head: 0),
                .init(anchor: 2, head: 2),
                .init(anchor: 4, head: 4)
            ], mainIndex: 2),
            tabWidth: 4,
            maximumSelections: 2
        )
        XCTAssertEqual(bounded.ranges.map(\.range), [
            NSRange(location: 0, length: 0),
            NSRange(location: 5, length: 0)
        ])
        XCTAssertEqual(bounded.main.range, NSRange(location: 5, length: 0))
    }
}
