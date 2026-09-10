import Foundation
import XCTest
@testable import LumenEditorCore

final class ParsedSyntaxTests: XCTestCase {
    func testValidationRejectsBrokenParentRangesAndUnsortedEntries() {
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 10,
            nodes: [
                .init(from: 0, to: 10, parent: -1, type: "Root"),
                .init(from: 2, to: 8, parent: 1, type: "SelfParent")
            ],
            bracketPairs: [], indentation: [], expectedRevision: 1
        ))
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 10,
            nodes: [
                .init(from: 0, to: 10, parent: -1, type: "Root"),
                .init(from: 0, to: 7, parent: 0, type: "First"),
                .init(from: 5, to: 9, parent: 0, type: "OverlappingSibling")
            ],
            bracketPairs: [], indentation: [], expectedRevision: 1
        ))
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 10, nodes: [],
            bracketPairs: [.init(open: 5, close: 7), .init(open: 2, close: 4)],
            indentation: [], expectedRevision: 1
        ))
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 10, nodes: [],
            bracketPairs: [.init(open: 0, close: 5), .init(open: 2, close: 7)],
            indentation: [], expectedRevision: 1
        ))
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 10,
            nodes: [.init(from: 0, to: 5, parent: -1, type: "Root"),
                    .init(from: 5, to: 10, parent: -1, type: "SecondRoot")],
            bracketPairs: [], indentation: [], expectedRevision: 1
        ))
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 10, nodes: [], bracketPairs: [],
            indentation: [.init(lineFrom: 4, columns: 2), .init(lineFrom: 4, columns: 4)],
            expectedRevision: 1
        ))
    }

    func testSmallestNonRootParentAndBracketLookupUseUTF16Offsets() throws {
        let snapshot = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: 12,
            nodes: [
                .init(from: 0, to: 12, parent: -1, type: "Script"),
                .init(from: 2, to: 12, parent: 0, type: "CallExpression"),
                .init(from: 3, to: 7, parent: 1, type: "Identifier")
            ],
            bracketPairs: [.init(open: 2, close: 11)],
            indentation: [.init(lineFrom: 0, columns: 0)], expectedRevision: 1
        ))

        XCTAssertEqual(
            snapshot.parentRange(containing: .cursor(at: 4)),
            DirectedSelection(anchor: 3, head: 7)
        )
        XCTAssertEqual(snapshot.matchingBracket(atUTF16Offset: 2)?.match, 11)
        XCTAssertEqual(snapshot.matchingBracket(atUTF16Offset: 11)?.opening, false)
    }

    func testRevisionAndCapabilityTruncationArePreserved() throws {
        let snapshot = try XCTUnwrap(ParsedSyntaxSnapshot(
            sourceUTF16Length: 1, nodes: [], bracketPairs: [], indentation: [],
            nodesWereTruncated: true, bracketPairsWereTruncated: true,
            indentationWasTruncated: true, expectedRevision: 42
        ))
        XCTAssertTrue(snapshot.nodesWereTruncated)
        XCTAssertTrue(snapshot.bracketPairsWereTruncated)
        XCTAssertTrue(snapshot.indentationWasTruncated)
        XCTAssertEqual(snapshot.expectedRevision, 42)
    }

    func testZeroWidthRecoveryNodeAtParentEndIsAccepted() throws {
        let snapshot = ParsedSyntaxSnapshot(
            sourceUTF16Length: 1,
            nodes: [
                .init(from: 0, to: 1, parent: -1, type: "Script"),
                .init(from: 0, to: 1, parent: 0, type: "Expression"),
                .init(from: 1, to: 1, parent: 1, type: "Error")
            ],
            bracketPairs: [], indentation: [], expectedRevision: 1
        )
        XCTAssertNotNil(snapshot)
    }

    func testValidationRejectsNodeWhoseParentHasLeftTheActivePreorderPath() {
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 10,
            nodes: [
                .init(from: 0, to: 10, parent: -1, type: "Root"),
                .init(from: 0, to: 4, parent: 0, type: "FirstBranch"),
                .init(from: 0, to: 1, parent: 1, type: "FirstChild"),
                .init(from: 4, to: 10, parent: 0, type: "SecondBranch"),
                // The range is contained by FirstBranch and starts after its
                // previous child. It is invalid solely because preorder has
                // already advanced to SecondBranch.
                .init(from: 1, to: 2, parent: 1, type: "LateFirstChild")
            ],
            bracketPairs: [], indentation: [], expectedRevision: 1
        ))
    }

    func testValidationBoundsParsedIndentationEntriesAndColumns() {
        let tooMany = (0 ... ParsedSyntaxSnapshot.maximumIndentationEntries).map {
            ParsedSyntaxSnapshot.LineIndentation(lineFrom: $0, columns: 0)
        }
        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: ParsedSyntaxSnapshot.maximumIndentationEntries,
            nodes: [], bracketPairs: [], indentation: tooMany, expectedRevision: 1
        ))

        XCTAssertNil(ParsedSyntaxSnapshot(
            sourceUTF16Length: 1, nodes: [], bracketPairs: [],
            indentation: [.init(
                lineFrom: 0,
                columns: ParsedSyntaxSnapshot.maximumIndentationColumns + 1
            )],
            expectedRevision: 1
        ))
    }
}
