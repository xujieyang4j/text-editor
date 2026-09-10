import XCTest
@testable import LumenEditorCore

final class PaneLayoutTests: XCTestCase {
    func testEveryLayoutKindCreatesTheExpectedIndependentPanes() {
        let initialSelection = SelectionSet.single(anchor: 7, head: 2)

        for kind in WindowSessionLayoutKind.allCases {
            let layout = PaneLayout(
                kind: kind,
                documentIDs: ["a", "b"],
                activeDocumentID: "b",
                selection: initialSelection
            )

            XCTAssertEqual(layout.kind, kind)
            XCTAssertEqual(layout.panes.count, kind.groupCount)
            XCTAssertEqual(layout.activePaneIndex, 0)
            XCTAssertEqual(layout.panes[0].documentIDs, ["a", "b"])
            XCTAssertEqual(layout.panes[0].activeDocumentID, "b")
            XCTAssertEqual(layout.panes[0].viewID, .default)
            XCTAssertEqual(Set(layout.panes.map(\.viewID)).count, kind.groupCount)

            for pane in layout.panes.dropFirst() {
                XCTAssertEqual(pane.documentIDs, ["b"])
                XCTAssertEqual(pane.activeDocumentID, "b")
                XCTAssertEqual(pane.selection(for: "b"), initialSelection)
            }
        }

        let empty = PaneLayout(kind: .grid4)
        XCTAssertTrue(empty.panes.allSatisfy(\.isEmpty))
        XCTAssertTrue(empty.panes.allSatisfy { $0.activeDocumentID == nil })
    }

    func testPaneNormalizesMembershipAndOwnsSelectionPerDocument() {
        let a = SelectionSet.cursor(at: 1)
        let b = SelectionSet.single(anchor: 8, head: 3)
        let pane = PaneLayout.Pane(
            viewID: "primary",
            documentIDs: ["a", "a", "b"],
            activeDocumentID: "missing",
            selectionsByDocumentID: ["a": a, "b": b, "orphan": .cursor(at: 99)]
        )

        XCTAssertEqual(pane.documentIDs, ["a", "b"])
        XCTAssertEqual(pane.activeDocumentID, "a")
        XCTAssertEqual(pane.selection(for: "a"), a)
        XCTAssertEqual(pane.selection(for: "b"), b)
        XCTAssertNil(pane.selection(for: "orphan"))
        XCTAssertEqual(Set(pane.selectionsByDocumentID.keys), Set(["a", "b"]))
    }

    func testShrinkingMergesTailPanesIntoPaneZeroWithoutLosingReferences() {
        let panes = [
            pane("zero", ["a", "b"], active: "b", positions: ["a": 1, "b": 2]),
            pane("one", ["b", "c"], active: "c", positions: ["b": 10, "c": 11]),
            pane("two", ["d", "a"], active: "d", positions: ["d": 20, "a": 21]),
            pane("three", ["e", "c"], active: "e", positions: ["e": 30, "c": 31])
        ]
        let retiredViewIDs = Set(panes.dropFirst().map(\.viewID))
        var layout = PaneLayout(kind: .grid4, panes: panes, activePaneIndex: 3)
        let documentsBefore = layout.referencedDocumentIDs

        XCTAssertTrue(layout.setLayout(.single))

        XCTAssertEqual(layout.panes.count, 1)
        XCTAssertEqual(layout.panes[0].viewID, "zero")
        XCTAssertEqual(layout.panes[0].documentIDs, ["a", "b", "e", "c", "d"])
        XCTAssertEqual(layout.panes[0].activeDocumentID, "b")
        XCTAssertEqual(layout.panes[0].selection(for: "a"), .cursor(at: 1))
        XCTAssertEqual(layout.panes[0].selection(for: "c"), .cursor(at: 31))
        XCTAssertEqual(layout.panes[0].selection(for: "d"), .cursor(at: 20))
        XCTAssertEqual(layout.referencedDocumentIDs, documentsBefore)
        XCTAssertEqual(layout.activePaneIndex, 0)

        XCTAssertTrue(layout.setLayout(.columns2))
        XCTAssertEqual(layout.panes[1].documentIDs, ["b"])
        XCTAssertEqual(layout.panes[1].selection(for: "b"), .cursor(at: 2))
        XCTAssertFalse(retiredViewIDs.contains(layout.panes[1].viewID))
        XCTAssertEqual(layout.referencedDocumentIDs, documentsBefore)

        let firstReplacementID = layout.panes[1].viewID
        XCTAssertTrue(layout.setLayout(.single))
        XCTAssertTrue(layout.setLayout(.columns2))
        XCTAssertNotEqual(layout.panes[1].viewID, firstReplacementID)
        XCTAssertFalse(retiredViewIDs.contains(layout.panes[1].viewID))
    }

    func testMoveCreatesASecondPaneAndCanLeaveTheSourceEmpty() {
        let movedSelection = SelectionSet.single(anchor: 9, head: 4)
        var layout = PaneLayout(
            documentIDs: ["a"],
            activeDocumentID: "a",
            selection: movedSelection
        )

        XCTAssertTrue(layout.moveActiveToNextPane())

        XCTAssertEqual(layout.kind, .columns2)
        XCTAssertEqual(layout.activePaneIndex, 1)
        XCTAssertTrue(layout.panes[0].isEmpty)
        XCTAssertNil(layout.panes[0].activeDocumentID)
        XCTAssertNil(layout.panes[0].selection(for: "a"))
        XCTAssertEqual(layout.panes[1].documentIDs, ["a"])
        XCTAssertEqual(layout.panes[1].activeDocumentID, "a")
        XCTAssertEqual(layout.panes[1].selection(for: "a"), movedSelection)
        XCTAssertEqual(layout.referencedDocumentIDs, Set(["a"]))
    }

    func testMoveToAnExistingTargetKeepsItsOrderAndViewSelection() {
        let sourceSelection = SelectionSet.cursor(at: 1)
        let targetSelection = SelectionSet.cursor(at: 90)
        var layout = PaneLayout(
            kind: .columns2,
            panes: [
                PaneLayout.Pane(
                    viewID: "left",
                    documentIDs: ["a"],
                    activeDocumentID: "a",
                    selectionsByDocumentID: ["a": sourceSelection]
                ),
                PaneLayout.Pane(
                    viewID: "right",
                    documentIDs: ["a", "b"],
                    activeDocumentID: "b",
                    selectionsByDocumentID: ["a": targetSelection, "b": .cursor(at: 2)]
                )
            ]
        )

        XCTAssertTrue(layout.moveActiveToNextPane())

        XCTAssertTrue(layout.panes[0].isEmpty)
        XCTAssertEqual(layout.panes[1].documentIDs, ["a", "b"])
        XCTAssertEqual(layout.panes[1].activeDocumentID, "a")
        XCTAssertEqual(layout.panes[1].selection(for: "a"), targetSelection)
    }

    func testMovingAnActiveMiddleTabSelectsTheSourcesFirstRemainingTab() {
        var layout = PaneLayout(
            kind: .columns2,
            panes: [
                pane(
                    "left",
                    ["a", "b", "c"],
                    active: "b",
                    positions: ["a": 1, "b": 2, "c": 3]
                ),
                pane("right", ["d"], active: "d", positions: ["d": 4])
            ]
        )

        XCTAssertTrue(layout.moveActiveToNextPane())
        XCTAssertEqual(layout.panes[0].documentIDs, ["a", "c"])
        XCTAssertEqual(layout.panes[0].activeDocumentID, "a")
        XCTAssertEqual(layout.panes[1].documentIDs, ["d", "b"])
        XCTAssertEqual(layout.panes[1].activeDocumentID, "b")
    }

    func testCloneCopiesSelectionValueButPaneSelectionsRemainIndependent() {
        let sourceSelection = SelectionSet.single(anchor: 6, head: 2)
        var layout = PaneLayout(
            kind: .columns2,
            panes: [
                PaneLayout.Pane(
                    viewID: "left",
                    documentIDs: ["a"],
                    activeDocumentID: "a",
                    selectionsByDocumentID: ["a": sourceSelection]
                ),
                pane("right", ["b"], active: "b", positions: ["b": 3])
            ]
        )

        XCTAssertTrue(layout.cloneActiveToNextPane())
        XCTAssertEqual(layout.panes[0].documentIDs, ["a"])
        XCTAssertEqual(layout.panes[1].documentIDs, ["b", "a"])
        XCTAssertEqual(layout.panes[1].activeDocumentID, "a")
        XCTAssertEqual(layout.panes[1].selection(for: "a"), sourceSelection)

        let changedTarget = SelectionSet.cursor(at: 40)
        XCTAssertTrue(layout.setSelection(changedTarget, forDocumentID: "a", inPaneAt: 1))
        XCTAssertEqual(layout.panes[1].selection(for: "a"), changedTarget)
        XCTAssertEqual(layout.panes[0].selection(for: "a"), sourceSelection)
    }

    func testRemovingOneMembershipReportsRemainingReferencesAndRepairsState() {
        var layout = PaneLayout(
            kind: .columns2,
            panes: [
                pane("left", ["a", "b"], active: "a", positions: ["a": 1, "b": 2]),
                pane("right", ["a", "c"], active: "c", positions: ["a": 10, "c": 11])
            ]
        )
        layout.selectTabs(["a", "b"])

        XCTAssertEqual(layout.referenceCount(for: "a"), 2)
        XCTAssertTrue(layout.removeDocument("a", fromPaneAt: 0))
        XCTAssertEqual(layout.panes[0].documentIDs, ["b"])
        XCTAssertEqual(layout.panes[0].activeDocumentID, "b")
        XCTAssertNil(layout.panes[0].selection(for: "a"))
        XCTAssertEqual(layout.referenceCount(for: "a"), 1)
        XCTAssertTrue(layout.isDocumentReferenced("a"))
        XCTAssertFalse(layout.selectedDocumentIDs.contains("a"))
        XCTAssertTrue(layout.selectedDocumentIDs.contains("b"))
        XCTAssertFalse(layout.removeDocument("missing", fromPaneAt: 0))
        XCTAssertFalse(layout.removeDocument("a", fromPaneAt: 9))
    }

    func testRemovingAnActiveMiddleTabSelectsItsAdjacentSuccessor() {
        var layout = PaneLayout(
            kind: .single,
            panes: [pane(
                "primary",
                ["a", "b", "c"],
                active: "b",
                positions: ["a": 1, "b": 2, "c": 3]
            )]
        )

        XCTAssertTrue(layout.removeDocument(documentID: "b", fromPaneAt: 0))
        XCTAssertEqual(layout.panes[0].documentIDs, ["a", "c"])
        XCTAssertEqual(layout.panes[0].activeDocumentID, "c")
        XCTAssertNil(layout.panes[0].selection(for: "b"))
    }

    func testRemovingAndReaddingToTheSamePaneRestoresItsSelection() {
        let originalSelection = SelectionSet.single(anchor: 12, head: 4)
        var layout = PaneLayout(
            kind: .columns2,
            panes: [
                PaneLayout.Pane(
                    viewID: "left",
                    documentIDs: ["a", "b"],
                    activeDocumentID: "a",
                    selectionsByDocumentID: [
                        "a": originalSelection,
                        "b": .cursor(at: 2)
                    ]
                ),
                pane("right", ["a"], active: "a", positions: ["a": 99])
            ]
        )

        XCTAssertTrue(layout.removeDocument("a", fromPaneAt: 0))
        XCTAssertEqual(layout.referenceCount(for: "a"), 1)
        XCTAssertTrue(layout.addDocument("a", toPaneAt: 0))
        XCTAssertEqual(layout.panes[0].selection(for: "a"), originalSelection)
        XCTAssertEqual(layout.panes[1].selection(for: "a"), .cursor(at: 99))
    }

    func testExplicitSelectionOverridesRetainedSelectionWhenReadding() {
        var layout = PaneLayout(
            kind: .columns2,
            panes: [
                pane("left", ["a", "b"], active: "a", positions: ["a": 7, "b": 2]),
                pane("right", ["a"], active: "a", positions: ["a": 9])
            ]
        )

        XCTAssertTrue(layout.removeDocument("a", fromPaneAt: 0))
        XCTAssertTrue(layout.addDocument(
            "a",
            toPaneAt: 0,
            selection: .cursor(at: 42)
        ))
        XCTAssertEqual(layout.panes[0].selection(for: "a"), .cursor(at: 42))
    }

    func testRemovingDocumentEverywhereAllowsEmptyPanesAndClearsSelection() {
        var layout = PaneLayout(
            kind: .columns2,
            panes: [
                pane("left", ["a"], active: "a", positions: ["a": 1]),
                pane("right", ["b", "a"], active: "a", positions: ["a": 2, "b": 3])
            ],
            activePaneIndex: 1,
            selectedDocumentIDs: ["a"]
        )
        let viewIDs = layout.panes.map(\.viewID)

        XCTAssertTrue(layout.removeDocumentEverywhere("a"))

        XCTAssertTrue(layout.panes[0].isEmpty)
        XCTAssertNil(layout.panes[0].activeDocumentID)
        XCTAssertEqual(layout.panes[1].documentIDs, ["b"])
        XCTAssertEqual(layout.panes[1].activeDocumentID, "b")
        XCTAssertEqual(layout.referenceCount(for: "a"), 0)
        XCTAssertFalse(layout.isDocumentReferenced("a"))
        XCTAssertTrue(layout.selectedDocumentIDs.isEmpty)
        XCTAssertEqual(layout.panes.map(\.viewID), viewIDs)
        XCTAssertFalse(layout.removeDocumentEverywhere("a"))
    }

    func testPaneFocusWrapsAndRejectsInvalidIndexes() {
        var layout = PaneLayout(kind: .grid4)

        XCTAssertTrue(layout.focusPreviousPane())
        XCTAssertEqual(layout.activePaneIndex, 3)
        XCTAssertTrue(layout.focusNextPane())
        XCTAssertEqual(layout.activePaneIndex, 0)
        XCTAssertTrue(layout.focusPane(at: 2))
        XCTAssertEqual(layout.activePaneIndex, 2)
        XCTAssertFalse(layout.focusPane(at: 9))
        XCTAssertEqual(layout.activePaneIndex, 2)

        var single = PaneLayout()
        XCTAssertFalse(single.focusNextPane())
        XCTAssertEqual(single.activePaneIndex, 0)
    }

    func testSplitSelectedTabsUsesSourceOrderCapsAtFourAndKeepsAllDocuments() {
        var selections: [String: SelectionSet] = [:]
        for (position, documentID) in ["a", "b", "c", "d", "e"].enumerated() {
            selections[documentID] = .cursor(at: position + 1)
        }
        var layout = PaneLayout(
            kind: .single,
            panes: [PaneLayout.Pane(
                viewID: "source",
                documentIDs: ["a", "b", "c", "d", "e"],
                activeDocumentID: "e",
                selectionsByDocumentID: selections
            )]
        )

        XCTAssertTrue(layout.splitSelectedTabs(["d", "b", "e", "c", "a"]))

        XCTAssertEqual(layout.kind, .grid4)
        XCTAssertEqual(layout.activePaneIndex, 0)
        XCTAssertEqual(layout.panes.map(\.activeDocumentID), ["a", "b", "c", "d"])
        XCTAssertEqual(layout.panes[0].documentIDs, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(layout.panes[1].documentIDs, ["e", "b"])
        XCTAssertEqual(layout.panes[2].documentIDs, ["e", "c"])
        XCTAssertEqual(layout.panes[3].documentIDs, ["e", "d"])
        XCTAssertEqual(layout.panes[2].selection(for: "c"), .cursor(at: 3))
        XCTAssertEqual(layout.referencedDocumentIDs, Set(["a", "b", "c", "d", "e"]))
        XCTAssertTrue(layout.selectedDocumentIDs.isEmpty)
    }

    func testSplitWithFewerThanTwoSelectedTabsClonesTheActiveTab() {
        var layout = PaneLayout(documentIDs: ["a", "b"], activeDocumentID: "b")

        XCTAssertTrue(layout.splitSelectedTabs(["a"]))

        XCTAssertEqual(layout.kind, .columns2)
        XCTAssertEqual(layout.panes[1].documentIDs, ["b"])
        XCTAssertEqual(layout.panes[1].activeDocumentID, "b")
        XCTAssertEqual(layout.activePaneIndex, 1)
        XCTAssertEqual(layout.selectedDocumentIDs, Set(["a"]))
    }

    func testSplitChoosesTwoThreeAndFourPaneKinds() {
        let documents = ["a", "b", "c", "d"]
        let expected: [(Int, WindowSessionLayoutKind)] = [
            (2, .columns2), (3, .columns3), (4, .grid4)
        ]

        for (count, kind) in expected {
            var layout = PaneLayout(documentIDs: documents, activeDocumentID: "a")
            XCTAssertTrue(layout.splitSelectedTabs(documents.prefix(count)))
            XCTAssertEqual(layout.kind, kind)
        }
    }

    func testTabOrderingMovesSelectedBlockAndPinnedTabsRemainStable() {
        var layout = PaneLayout(documentIDs: ["a", "b", "c", "d"], activeDocumentID: "a")
        layout.selectTabs(["d", "b"])

        XCTAssertTrue(layout.reorderTabs(
            inPaneAt: 0,
            draggedDocumentID: "b",
            relativeTo: "a",
            position: .before
        ))
        XCTAssertEqual(layout.panes[0].documentIDs, ["b", "d", "a", "c"])
        XCTAssertEqual(layout.selectedDocumentIDs, Set(["b", "d"]))

        XCTAssertTrue(layout.reorderTabs(
            inPaneAt: 0,
            draggedDocumentID: "c",
            relativeTo: "b",
            position: .after
        ))
        XCTAssertEqual(layout.panes[0].documentIDs, ["b", "c", "d", "a"])
        XCTAssertEqual(layout.selectedDocumentIDs, Set(["c"]))

        layout.organizePinnedTabs(Set(["d", "b"]))
        XCTAssertEqual(layout.panes[0].documentIDs, ["b", "d", "c", "a"])
        XCTAssertEqual(layout.selectNextTab(), "b")
        XCTAssertEqual(layout.selectPreviousTab(), "a")
    }

    func testWindowSessionConversionPreservesLayoutAndViewState() throws {
        let multiSelection = SelectionSet(
            ranges: [
                DirectedSelection(anchor: 9, head: 2),
                DirectedSelection(anchor: 15, head: 15)
            ],
            mainIndex: 1
        )
        let layout = PaneLayout(
            kind: .columns2,
            panes: [
                pane("left", ["a", "b"], active: "a", positions: ["a": 1, "b": 2]),
                PaneLayout.Pane(
                    viewID: "right",
                    documentIDs: ["b", "c"],
                    activeDocumentID: "b",
                    selectionsByDocumentID: ["b": multiSelection, "c": .cursor(at: 3)]
                )
            ],
            activePaneIndex: 1
        )

        let sessionLayout = layout.toWindowSessionLayout()
        XCTAssertEqual(sessionLayout, WindowSessionLayout(
            kind: .columns2,
            activeGroup: 1,
            groups: [
                WindowSessionGroup(documentIDs: ["a", "b"], activeDocumentID: "a"),
                WindowSessionGroup(documentIDs: ["b", "c"], activeDocumentID: "b")
            ]
        ))

        let view = try XCTUnwrap(layout.windowSessionViewState(
            forDocumentID: "b",
            inPaneAt: 1,
            scrollX: 12,
            scrollY: 34
        ))
        XCTAssertEqual(view.group, 1)
        XCTAssertEqual(view.selections, [
            WindowSessionSelection(anchor: 9, head: 2),
            WindowSessionSelection(anchor: 15, head: 15)
        ])
        XCTAssertEqual(view.mainIndex, 1)
        XCTAssertEqual(view.scrollX, 12)
        XCTAssertEqual(view.scrollY, 34)

        let session = WindowSession(
            documents: [
                WindowSessionDocument(documentID: "a", path: nil, name: "a"),
                WindowSessionDocument(documentID: "b", path: nil, name: "b", views: [view]),
                WindowSessionDocument(documentID: "c", path: nil, name: "c")
            ],
            activeDocumentID: "b",
            layout: sessionLayout
        )
        XCTAssertNoThrow(try session.validate())
    }

    func testRestoringAWindowSessionLayoutUsesStableExplicitViewIDs() {
        let sessionLayout = WindowSessionLayout(
            kind: .columns2,
            activeGroup: 1,
            groups: [
                WindowSessionGroup(documentIDs: ["a", "b"], activeDocumentID: "b"),
                WindowSessionGroup(documentIDs: ["b"], activeDocumentID: "b")
            ]
        )
        let rightSelection = SelectionSet.single(anchor: 8, head: 1)

        let restored = PaneLayout(
            windowSessionLayout: sessionLayout,
            viewIDs: ["left", "right"],
            selectionsByGroup: [1: ["b": rightSelection]]
        )

        XCTAssertEqual(restored.panes.map(\.viewID), ["left", "right"])
        XCTAssertEqual(restored.activePaneIndex, 1)
        XCTAssertEqual(restored.panes[0].selection(for: "a"), .cursor(at: 0))
        XCTAssertEqual(restored.panes[1].selection(for: "b"), rightSelection)
        XCTAssertEqual(restored.windowSessionLayout, sessionLayout)
    }

    private func pane(
        _ viewID: EditorViewID,
        _ documentIDs: [String],
        active: String?,
        positions: [String: Int]
    ) -> PaneLayout.Pane {
        PaneLayout.Pane(
            viewID: viewID,
            documentIDs: documentIDs,
            activeDocumentID: active,
            selectionsByDocumentID: positions.mapValues { SelectionSet.cursor(at: $0) }
        )
    }
}
