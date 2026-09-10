import Foundation
import XCTest
@testable import LumenEditorCore

final class LosslessJSONTests: XCTestCase {
    func testCoreFixturePreservesEveryNumberTokenAndPrettyPrints() throws {
        let value = try LosslessJSON.parse(
            #"{"id":7651669476812652838,"small":42,"decimal":1.2300e+10}"#
        )
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["id"]?.numberValue?.raw, "7651669476812652838")
        XCTAssertEqual(object["small"]?.numberValue?.raw, "42")
        XCTAssertEqual(object["decimal"]?.numberValue?.raw, "1.2300e+10")
        XCTAssertEqual(
            try LosslessJSON.stringify(value, indent: 2),
            """
            {
              "id": 7651669476812652838,
              "small": 42,
              "decimal": 1.2300e+10
            }
            """
        )
        XCTAssertEqual(
            try LosslessJSON.stringify(value),
            #"{"id":7651669476812652838,"small":42,"decimal":1.2300e+10}"#
        )
    }

    func testRootPrimitivesArraysAndJSONWhitespace() throws {
        XCTAssertEqual(try LosslessJSON.parse(" \t\r\nnull "), .null)
        XCTAssertEqual(try LosslessJSON.parse("true"), .bool(true))
        XCTAssertEqual(try LosslessJSON.parse("false"), .bool(false))
        XCTAssertEqual(try LosslessJSON.parse(#""hello""#), .string("hello"))
        XCTAssertEqual(try LosslessJSON.parse("-0"), .number(.init("-0")))
        XCTAssertEqual(
            try LosslessJSON.parse(#"[null,false,"x",-12.3400E-05]"#),
            .array([.null, .bool(false), .string("x"), .number(.init("-12.3400E-05"))])
        )

        assertParseError("\u{feff}null", message: "Expected a JSON value.", line: 1, column: 1)
        assertParseError("null\u{00a0}", message: "Unexpected trailing content.", line: 1, column: 5)
    }

    func testNumbersKeepLexicalFormAndRejectInvalidPrefixesLikeElectron() throws {
        let source = "[-0,0,10,0.00,-1.2300e+10,6E-0002,999999999999999999999999999999]"
        XCTAssertEqual(try LosslessJSON.stringify(try LosslessJSON.parse(source)), source)

        assertParseError("-", message: "Invalid JSON number.", line: 1, column: 1)
        assertParseError("01", message: "Unexpected trailing content.", line: 1, column: 2)
        assertParseError("1.", message: "Unexpected trailing content.", line: 1, column: 2)
        assertParseError("1e", message: "Unexpected trailing content.", line: 1, column: 2)
        assertParseError("+1", message: "Expected a JSON value.", line: 1, column: 1)
        assertParseError(".5", message: "Expected a JSON value.", line: 1, column: 1)
    }

    func testStringsDecodeStrictEscapesAndUseJSONStringifyEscaping() throws {
        let source = #"["quote: \", slash: \/","\b\f\n\r\t","\u4e2d\ud83d\ude42"]"#
        let value = try LosslessJSON.parse(source)
        XCTAssertEqual(
            value,
            .array([
                .string("quote: \", slash: /"),
                .string("\u{08}\u{0c}\n\r\t"),
                .string("中🙂")
            ])
        )
        XCTAssertEqual(
            try LosslessJSON.stringify(.string("\"\\\u{08}\u{0c}\n\r\t\u{01}中🙂/")),
            #""\"\\\b\f\n\r\t\u0001中🙂/""#
        )

        assertParseError(#""\x""#, message: "Invalid JSON string.", line: 1, column: 5)
        assertParseError("\"line\nfeed\"", message: "Control character in JSON string.", line: 1, column: 6)
        assertParseError("\"unterminated", message: "Unterminated JSON string.", line: 1, column: 14)
        assertParseError(#""trailing\"#, message: "Unterminated JSON string.", line: 1, column: 12)
    }

    func testSurrogateEscapesAndLoneSurrogatesMatchJavaScriptUTF16Semantics() throws {
        XCTAssertEqual(try LosslessJSON.parse(#""\ud83d\ude42""#), .string("🙂"))

        let loneHigh = try LosslessJSON.parse(#""\ud800""#)
        let loneLow = try LosslessJSON.parse(#""\udc00""#)
        guard case let .string(high) = loneHigh, case let .string(low) = loneLow else {
            return XCTFail("Expected strings")
        }
        XCTAssertEqual(high.utf16, [0xd800])
        XCTAssertEqual(low.utf16, [0xdc00])
        XCTAssertEqual(try LosslessJSON.stringify(loneHigh), #""\ud800""#)
        XCTAssertEqual(try LosslessJSON.stringify(loneLow), #""\udc00""#)

        let keys = try LosslessJSON.parse(
            #"{"\ud800":1,"\ud801":2,"�":3,"\ud800":4}"#
        )
        let object = try XCTUnwrap(keys.objectValue)
        XCTAssertEqual(object.count, 3)
        XCTAssertEqual(object.losslessKeys.map(\.utf16), [[0xd800], [0xd801], [0xfffd]])
        XCTAssertEqual(
            try LosslessJSON.stringify(keys),
            #"{"\ud800":4,"\ud801":2,"�":3}"#
        )
    }

    func testDuplicateKeysOverwriteWithoutMovingAndIndexKeysUseJSOrder() throws {
        let value = try LosslessJSON.parse(
            #"{"b":1,"10":10,"a":2,"2":2,"b":3,"01":1,"4294967294":4,"4294967295":5,"0":0}"#
        )
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(
            object.keys,
            ["0", "2", "10", "4294967294", "b", "a", "01", "4294967295"]
        )
        XCTAssertEqual(object["b"], .number(.init("3")))
        XCTAssertEqual(
            try LosslessJSON.stringify(value),
            #"{"0":0,"2":2,"10":10,"4294967294":4,"b":3,"a":2,"01":1,"4294967295":5}"#
        )

        var editedObject = object
        _ = editedObject.removeValue(forKey: "b")
        editedObject.setValue(.bool(true), forKey: "b")
        XCTAssertEqual(editedObject.keys.last, "b")
    }

    func testCompactPrettyAndEmptyContainerFormatting() throws {
        let value = try LosslessJSON.parse(#"{"a":[1,{"b":true}],"emptyArray":[],"emptyObject":{}}"#)
        XCTAssertEqual(
            try LosslessJSON.stringify(value, indent: 2),
            """
            {
              "a": [
                1,
                {
                  "b": true
                }
              ],
              "emptyArray": [],
              "emptyObject": {}
            }
            """
        )
        XCTAssertEqual(
            try LosslessJSON.stringify(value, indent: -4),
            #"{"a":[1,{"b":true}],"emptyArray":[],"emptyObject":{}}"#
        )
        XCTAssertFalse(try LosslessJSON.stringify(value, indent: 2).hasSuffix("\n"))
    }

    func testParseErrorsUseOneBasedUTF16LineAndColumn() {
        assertParseError(
            "{\n  \"emoji\": \"🙂\",\n  \"bad\" true\n}",
            message: "Expected “:”.",
            line: 3,
            column: 9
        )
        assertParseError("[🙂]", message: "Expected a JSON value.", line: 1, column: 2)
        assertParseError(#""🙂"x"#, message: "Unexpected trailing content.", line: 1, column: 5)
        assertParseError("[1 2]", message: "Expected “,”.", line: 1, column: 4)
        assertParseError("[1,]", message: "Expected a JSON value.", line: 1, column: 4)
        assertParseError("{\"a\":1,}", message: "Expected an object key.", line: 1, column: 8)
        assertParseError("truex", message: "Unexpected trailing content.", line: 1, column: 5)
        assertParseError("tru", message: "Expected true.", line: 1, column: 1)
        assertParseError("", message: "Expected a JSON value.", line: 1, column: 1)
    }

    func testCloneBuildsIndependentContainersAndPreservesNumberTokens() throws {
        let original = try LosslessJSON.parse(#"{"id":99999999999999999999,"items":[1]}"#)
        var clone = try LosslessJSON.clone(original)
        try clone.appendArrayItem(.number(.init("2.00e+3")), at: [.key("items")])
        XCTAssertEqual(
            try LosslessJSON.stringify(original),
            #"{"id":99999999999999999999,"items":[1]}"#
        )
        XCTAssertEqual(
            try LosslessJSON.stringify(clone),
            #"{"id":99999999999999999999,"items":[1,2.00e+3]}"#
        )
    }

    func testStatisticsAndTreeEditingDTO() throws {
        var value = try LosslessJSON.parse(#"{"name":"old","items":[1,{"keep":true}]}"#)
        XCTAssertEqual(
            LosslessJSON.statistics(of: value),
            .init(keys: 3, objects: 2, arrays: 1, values: 3, maxDepth: 3)
        )
        XCTAssertEqual(
            value.value(at: [.key("items"), .index(1), .key("keep")]),
            .bool(true)
        )

        try value.replaceValue(at: [.key("name")], with: .string("new"))
        try value.appendArrayItem(.null, at: [.key("items")])
        try value.addObjectMember(
            key: "2", value: .string("index-key"), at: [.key("items"), .index(1)]
        )
        try value.removeValue(at: [.key("items"), .index(0)])
        XCTAssertEqual(
            try LosslessJSON.stringify(value),
            #"{"name":"new","items":[{"2":"index-key","keep":true},null]}"#
        )

        try value.replaceValue(at: [], with: .bool(false))
        XCTAssertEqual(value, .bool(false))
    }

    func testTreeEditingRejectsInvalidKeysDuplicatesPathsAndRootRemovalAtomically() throws {
        let original = try LosslessJSON.parse(#"{"object":{"a":1},"array":[true]}"#)
        var value = original

        XCTAssertThrowsError(try value.addObjectMember(key: "", value: .null, at: [.key("object")])) { error in
            XCTAssertEqual(error as? LosslessJSONTreeError, .invalidObjectKey(""))
        }
        XCTAssertThrowsError(try value.addObjectMember(key: "__proto__", value: .null, at: [.key("object")])) { error in
            XCTAssertEqual(error as? LosslessJSONTreeError, .invalidObjectKey("__proto__"))
        }
        XCTAssertThrowsError(try value.addObjectMember(key: "a", value: .null, at: [.key("object")])) { error in
            XCTAssertEqual(error as? LosslessJSONTreeError, .duplicateObjectKey("a"))
        }
        XCTAssertThrowsError(try value.appendArrayItem(.null, at: [.key("object")]))
        XCTAssertThrowsError(try value.replaceValue(at: [.key("missing")], with: .null))
        XCTAssertThrowsError(try value.removeValue(at: [])) { error in
            XCTAssertEqual(error as? LosslessJSONTreeError, .cannotRemoveRoot)
        }
        XCTAssertEqual(value, original)
    }

    func testJSONViewMutationSequencePreservesTypesLargeNumbersAndKeyOrder() throws {
        var value = try LosslessJSON.parse(
            #"{"10":10,"2":2,"object":{},"items":[false],"value":null}"#
        )
        try value.replaceValue(
            at: [.key("value")],
            with: try LosslessJSON.parse(#"{"typed":[true,"text"]}"#)
        )
        try value.addObjectMember(
            key: "large",
            value: try LosslessJSON.parse("999999999999999999999999"),
            at: [.key("object")]
        )
        try value.appendArrayItem(
            try LosslessJSON.parse(#"{"ok":true}"#),
            at: [.key("items")]
        )
        try value.removeValue(at: [.key("items"), .index(0)])

        XCTAssertEqual(
            try LosslessJSON.stringify(value, indent: 2) + "\n",
            """
            {
              "2": 2,
              "10": 10,
              "object": {
                "large": 999999999999999999999999
              },
              "items": [
                {
                  "ok": true
                }
              ],
              "value": {
                "typed": [
                  true,
                  "text"
                ]
              }
            }

            """
        )
    }

    func testSourceLengthLimitUsesElectronUTF16CodeUnitsAndIsInclusive() throws {
        let source = #""中""#
        XCTAssertEqual(source.utf8.count, 5)
        XCTAssertEqual(source.utf16.count, 3)
        XCTAssertEqual(
            try LosslessJSON.parse(
                source, limits: .init(maximumDepth: 10, maximumNodes: 10, maximumBytes: 3)
            ),
            .string("中")
        )
        XCTAssertThrowsError(
            try LosslessJSON.parse(
                source, limits: .init(maximumDepth: 10, maximumNodes: 10, maximumBytes: 2)
            )
        ) { error in
            guard let parseError = error as? LosslessJSONParseError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(parseError.kind, .sourceTooLarge(actualLength: 3, maximumLength: 2))
            XCTAssertEqual(parseError.line, 1)
            XCTAssertEqual(parseError.column, 1)
        }
    }

    func testDepthLimitUsesRootDepthZeroAndNodeLimitCountsEveryValue() throws {
        let depthLimits = LosslessJSONLimits(maximumDepth: 2, maximumNodes: 20, maximumBytes: 100)
        XCTAssertNoThrow(try LosslessJSON.parse("[[0]]", limits: depthLimits))
        XCTAssertThrowsError(try LosslessJSON.parse("[[[0]]]", limits: depthLimits)) { error in
            guard let parseError = error as? LosslessJSONParseError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(parseError.kind, .nestingTooDeep(actualDepth: 3, maximumDepth: 2))
        }

        let nodeLimits = LosslessJSONLimits(maximumDepth: 10, maximumNodes: 4, maximumBytes: 100)
        XCTAssertNoThrow(try LosslessJSON.parse("[0,1,2]", limits: nodeLimits))
        XCTAssertThrowsError(try LosslessJSON.parse("[0,1,2,3]", limits: nodeLimits)) { error in
            guard let parseError = error as? LosslessJSONParseError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(parseError.kind, .tooManyNodes(actualNodes: 5, maximumNodes: 4))
        }
    }

    func testBoundedStringifyCloneAndTreeEditsRejectExcessResourcesAtomically() throws {
        let shallow = LosslessJSONLimits(
            maximumDepth: 1, maximumNodes: 20, maximumBytes: 100, maximumIndent: 4
        )
        let tooDeep: LosslessJSONValue = .array([.array([.number(.init("0"))])])
        XCTAssertThrowsError(try LosslessJSON.stringify(tooDeep, limits: shallow)) { error in
            XCTAssertEqual(
                error as? LosslessJSONResourceError,
                .nestingTooDeep(actualDepth: 2, maximumDepth: 1)
            )
        }
        XCTAssertThrowsError(try LosslessJSON.clone(tooDeep, limits: shallow))
        XCTAssertThrowsError(try LosslessJSON.stringify(.null, indent: 5, limits: shallow)) { error in
            XCTAssertEqual(
                error as? LosslessJSONResourceError,
                .indentTooLarge(actualIndent: 5, maximumIndent: 4)
            )
        }
        XCTAssertThrowsError(
            try LosslessJSON.stringify(
                .string("中"),
                limits: .init(maximumDepth: 1, maximumNodes: 1, maximumBytes: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? LosslessJSONResourceError,
                .sourceTooLarge(actualLength: 3, maximumLength: 2)
            )
        }

        var value: LosslessJSONValue = .array([])
        let original = value
        XCTAssertThrowsError(
            try value.appendArrayItem(
                .array([.array([])]),
                at: [],
                limits: shallow
            )
        )
        XCTAssertEqual(value, original)

        let oversizedPath: LosslessJSONPath = [.index(0), .index(0)]
        XCTAssertThrowsError(try value.replaceValue(at: oversizedPath, with: .null, limits: shallow)) { error in
            XCTAssertEqual(
                error as? LosslessJSONResourceError,
                .nestingTooDeep(actualDepth: 2, maximumDepth: 1)
            )
        }
    }

    func testLargeUniqueObjectParsesWithinBoundAndPreservesOrder() throws {
        let entries = (0 ..< 10_000).map { #""k\#($0)":\#($0)"# }.joined(separator: ",")
        let value = try LosslessJSON.parse("{\(entries)}")
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object.count, 10_000)
        XCTAssertEqual(object.keys.first, "k0")
        XCTAssertEqual(object.keys.last, "k9999")
        XCTAssertEqual(object["k7312"]?.numberValue?.raw, "7312")
    }

    private func assertParseError(
        _ source: String,
        message: String,
        line: Int,
        column: Int,
        file: StaticString = #filePath,
        sourceLine: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LosslessJSON.parse(source),
            file: file,
            line: sourceLine
        ) { error in
            guard let parseError = error as? LosslessJSONParseError else {
                return XCTFail("Unexpected error: \(error)", file: file, line: sourceLine)
            }
            XCTAssertEqual(parseError.message, message, file: file, line: sourceLine)
            XCTAssertEqual(parseError.line, line, file: file, line: sourceLine)
            XCTAssertEqual(parseError.column, column, file: file, line: sourceLine)
            XCTAssertEqual(
                parseError.description,
                "\(message) Line \(line), column \(column).",
                file: file,
                line: sourceLine
            )
        }
    }
}
