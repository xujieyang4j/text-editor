import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class JSONTreeViewTests: XCTestCase {
    func testSnapshotPreservesOrderingPathsKindsAndStatistics() throws {
        let value = try LosslessJSON.parse(
            #"{"10":10,"2":2,"name":"hello","items":[true,null]}"#
        )
        let snapshot = JSONTreeSnapshot(value: value)

        XCTAssertEqual(snapshot.root.label, "$")
        XCTAssertEqual(snapshot.root.kind, .object(count: 4))
        XCTAssertEqual(
            snapshot.root.children.map(\.label),
            [#""2""#, #""10""#, #""name""#, #""items""#]
        )
        XCTAssertEqual(snapshot.statistics, .init(
            keys: 4, objects: 1, arrays: 1, values: 5, maxDepth: 2
        ))
        XCTAssertEqual(snapshot.renderedNodeCount, 7)
        XCTAssertFalse(snapshot.reachedDepthLimit)
        XCTAssertFalse(snapshot.reachedNodeLimit)

        let items = try XCTUnwrap(snapshot.root.children.last)
        XCTAssertEqual(items.path, [.key("items")])
        XCTAssertEqual(items.children[0].path, [.key("items"), .index(0)])
        XCTAssertEqual(items.children[0].kind, .boolean(true))
        XCTAssertEqual(items.children[1].kind, .null)
    }

    func testStatisticsAreBoundedWithTheTreeTraversal() throws {
        let snapshot = JSONTreeSnapshot(
            value: try LosslessJSON.parse(#"[0,1,2,3,4]"#),
            limits: JSONTreeLimits(
                maximumDepth: 10,
                maximumNodes: 3,
                maximumPreviewCharacters: 20
            )
        )

        XCTAssertEqual(snapshot.statistics.arrays, 1)
        XCTAssertEqual(snapshot.statistics.values, 2)
        XCTAssertTrue(snapshot.reachedNodeLimit)
    }

    func testDepthLimitDoesNotDescendPastBoundary() throws {
        let value = try LosslessJSON.parse(#"{"a":{"b":{"c":1}}}"#)
        let snapshot = JSONTreeSnapshot(
            value: value,
            limits: JSONTreeLimits(
                maximumDepth: 1,
                maximumNodes: 100,
                maximumPreviewCharacters: 100
            )
        )

        XCTAssertEqual(snapshot.renderedNodeCount, 2)
        XCTAssertTrue(snapshot.reachedDepthLimit)
        XCTAssertFalse(snapshot.reachedNodeLimit)
        let child = try XCTUnwrap(snapshot.root.children.first)
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(child.children, [])
        XCTAssertEqual(child.omission, .depthLimit(omittedChildren: 1))
    }

    func testNodeLimitStopsTraversalAtExactBudget() throws {
        let value = try LosslessJSON.parse(#"[0,1,2,3,4,5]"#)
        let snapshot = JSONTreeSnapshot(
            value: value,
            limits: JSONTreeLimits(
                maximumDepth: 10,
                maximumNodes: 4,
                maximumPreviewCharacters: 100
            )
        )

        XCTAssertEqual(snapshot.renderedNodeCount, 4)
        XCTAssertTrue(snapshot.reachedNodeLimit)
        XCTAssertFalse(snapshot.reachedDepthLimit)
        XCTAssertEqual(snapshot.root.children.map(\.label), ["[0]", "[1]", "[2]"])
        XCTAssertEqual(snapshot.root.omission, .nodeLimit(omittedChildren: 3))
    }

    func testPrimitivePreviewClipsWithoutChangingLosslessNumberToken() throws {
        let number = "123456789012345678901234567890"
        let value = try LosslessJSON.parse(#"{"n":\#(number),"s":"abcdefghij"}"#)
        let snapshot = JSONTreeSnapshot(
            value: value,
            limits: JSONTreeLimits(
                maximumDepth: 10,
                maximumNodes: 10,
                maximumPreviewCharacters: 5
            )
        )

        XCTAssertEqual(snapshot.root.children[0].displayValue, "12345…")
        XCTAssertEqual(snapshot.root.children[1].displayValue, #""abcde…""#)
        XCTAssertEqual(try LosslessJSON.stringify(value), #"{"n":\#(number),"s":"abcdefghij"}"#)
    }

    func testStringAndKeyDisplayUsesBoundedJSONEscaping() throws {
        let value = try LosslessJSON.parse(
            #"{"line\n\t\"\\\u202e":"value\n\t\"\\\u061c\u200f\u2066\ud800"}"#
        )
        let snapshot = JSONTreeSnapshot(
            value: value,
            limits: JSONTreeLimits(
                maximumDepth: 10,
                maximumNodes: 10,
                maximumPreviewCharacters: 100
            )
        )
        let child = try XCTUnwrap(snapshot.root.children.first)

        XCTAssertEqual(child.label, #""line\n\t\"\\\u202e""#)
        XCTAssertEqual(
            child.displayValue,
            #""value\n\t\"\\\u061c\u200f\u2066\ud800""#
        )
        XCTAssertFalse(child.label.contains("\n"))
        XCTAssertFalse(child.displayValue?.contains("\n") == true)
    }

    func testEscapedStringIsClippedDuringTraversal() throws {
        let value = try LosslessJSON.parse(#""\n\n\n\n""#)
        let snapshot = JSONTreeSnapshot(
            value: value,
            limits: JSONTreeLimits(
                maximumDepth: 10,
                maximumNodes: 10,
                maximumPreviewCharacters: 5
            )
        )

        XCTAssertEqual(snapshot.root.displayValue, #""\n\n…""#)
    }

    func testRootPrimitiveStillUsesOneNode() throws {
        let snapshot = JSONTreeSnapshot(
            value: try LosslessJSON.parse("null"),
            limits: JSONTreeLimits(
                maximumDepth: 0,
                maximumNodes: 1,
                maximumPreviewCharacters: 10
            )
        )

        XCTAssertEqual(snapshot.renderedNodeCount, 1)
        XCTAssertEqual(snapshot.root.kind, .null)
        XCTAssertEqual(snapshot.root.displayValue, "null")
        XCTAssertFalse(snapshot.reachedDepthLimit)
        XCTAssertFalse(snapshot.reachedNodeLimit)
    }

    func testJSONTreeEditingAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(JSONTreeView.Accessibility.tree, "preview.json.tree")
        XCTAssertEqual(JSONTreeView.Accessibility.outline, "preview.json.outline")
        XCTAssertEqual(JSONTreeView.Accessibility.editor, "preview.json.editor")
        XCTAssertEqual(
            JSONTreeView.Accessibility.editorValue, "preview.json.editor.value"
        )
        XCTAssertEqual(
            JSONTreeView.Accessibility.editorSubmit, "preview.json.editor.submit"
        )
        XCTAssertEqual(
            JSONTreeView.Accessibility.editError, "preview.json.edit-error"
        )
        XCTAssertEqual(
            JSONTreeView.Accessibility.edit(17), "preview.json.node.17.edit"
        )
        XCTAssertEqual(
            JSONTreeView.Accessibility.addKey(17), "preview.json.node.17.add-key"
        )
        XCTAssertEqual(
            JSONTreeView.Accessibility.addItem(17), "preview.json.node.17.add-item"
        )
        XCTAssertEqual(
            JSONTreeView.Accessibility.delete(17), "preview.json.node.17.delete"
        )
    }
}
