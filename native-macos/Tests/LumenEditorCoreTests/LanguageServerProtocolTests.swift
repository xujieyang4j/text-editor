import Foundation
import XCTest
@testable import LumenEditorCore

final class LanguageServerProtocolTests: XCTestCase {
    func testReaderParsesUnicodeOneByteAtATime() throws {
        let message: LSPMessage = [
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "result": .string("你好🙂")
        ]
        let frame = try LSPMessageFraming.encode(message)
        let reader = LSPMessageReader()
        var messages: [LSPMessage] = []
        var errors: [LSPProtocolError] = []

        for byte in frame {
            let output = reader.append(Data([byte]))
            messages.append(contentsOf: output.messages)
            errors.append(contentsOf: output.errors)
        }

        XCTAssertEqual(messages, [message])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(reader.isStopped)
    }

    func testReaderParsesLowercaseHeaderAndConsecutiveFrames() throws {
        let firstPayload = Data(#"{"jsonrpc":"2.0","method":"ready"}"#.utf8)
        var first = Data("content-length: \(firstPayload.count)\r\n".utf8)
        first.append(Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n".utf8))
        first.append(firstPayload)
        let second: LSPMessage = [
            "jsonrpc": .string("2.0"), "id": .integer(2), "result": .null
        ]
        first.append(try LSPMessageFraming.encode(second))

        let output = LSPMessageReader().append(first)
        XCTAssertEqual(output.messages, [
            ["jsonrpc": .string("2.0"), "method": .string("ready")],
            second
        ])
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testFatalFramingErrorsStopReaderPermanently() throws {
        let ignored = try LSPMessageFraming.encode([
            "jsonrpc": LSPJSONValue.string("2.0"),
            "id": LSPJSONValue.string("ignored")
        ])
        let failures: [(Data, String)] = [
            (Data("Content-Length: nope\r\n\r\n".utf8), "Content-Length"),
            (Data("Content-Length: +2\r\n\r\n".utf8), "Content-Length"),
            (Data("Content-Length: 2.0\r\n\r\n".utf8), "Content-Length"),
            (Data("Content-Length: 9007199254740992\r\n\r\n".utf8), "Content-Length"),
            (Data("Content-Type: application/json\r\n\r\n".utf8), "Missing"),
            (Data("Content-Length: 2\r\ncontent-length: 2\r\n\r\n".utf8), "Duplicate"),
            (Data("Not-A-Header\r\n\r\n".utf8), "Malformed"),
            (Data("Content-Length: \(LSPProtocolLimits.maximumPayloadBytes + 1)\r\n\r\n".utf8), "exceeds"),
            (Data(repeating: 120, count: LSPProtocolLimits.maximumHeaderBytes + 1), "header exceeds"),
            (Data("Content-Length: 2\r\nX-Non-Ascii: ".utf8) + Data([0xff]) + Data("\r\n\r\n".utf8), "ASCII")
        ]

        for (malformed, expectedText) in failures {
            let reader = LSPMessageReader()
            var input = malformed
            input.append(ignored)
            let output = reader.append(input)
            let afterStop = reader.append(ignored)

            XCTAssertTrue(reader.isStopped, expectedText)
            XCTAssertTrue(output.messages.isEmpty, expectedText)
            XCTAssertEqual(output.errors.count, 1, expectedText)
            XCTAssertTrue(output.errors[0].fatal, expectedText)
            XCTAssertTrue(output.errors[0].message.localizedCaseInsensitiveContains(expectedText), output.errors[0].message)
            XCTAssertTrue(afterStop.messages.isEmpty)
            XCTAssertTrue(afterStop.errors.isEmpty)
        }
    }

    func testExactlyMaximumHeaderBytesBeforeDelimiterIsAccepted() {
        let payload = Data("{}".utf8)
        let prefix = Data("Content-Length: \(payload.count)\r\nX-Padding: ".utf8)
        var frame = prefix
        frame.append(Data(repeating: 120, count: LSPProtocolLimits.maximumHeaderBytes - prefix.count))
        XCTAssertEqual(frame.count, LSPProtocolLimits.maximumHeaderBytes)
        frame.append(Data("\r\n\r\n".utf8))
        frame.append(payload)

        let output = LSPMessageReader().append(frame)
        XCTAssertEqual(output.messages, [[:]])
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testPayloadErrorsAreRecoverableOnlyAfterDeclaredBoundary() throws {
        let payloads = [
            Data([0xc3, 0x28]),
            Data(#"{"incomplete":"#.utf8),
            Data("null".utf8),
            Data("[1,2,3]".utf8),
            Data(#""string""#.utf8),
            Data()
        ]
        var input = Data()
        for payload in payloads { input.append(frame(payload)) }
        let recovered: LSPMessage = [
            "jsonrpc": .string("2.0"),
            "id": .integer(3),
            "result": .string("recovered")
        ]
        input.append(try LSPMessageFraming.encode(recovered))

        let reader = LSPMessageReader()
        let output = reader.append(input)
        XCTAssertEqual(output.messages, [recovered])
        XCTAssertEqual(output.errors.count, 6)
        XCTAssertFalse(output.errors.contains { $0.fatal })
        XCTAssertTrue(output.errors[0].message.contains("UTF-8"))
        XCTAssertTrue(output.errors[1].message.contains("Invalid JSON"))
        XCTAssertTrue(output.errors[2].message.contains("JSON object"))
        XCTAssertTrue(output.errors[3].message.contains("JSON object"))
        XCTAssertTrue(output.errors[4].message.contains("JSON object"))
        XCTAssertTrue(output.errors[5].message.contains("Invalid JSON"))
        XCTAssertFalse(reader.isStopped)
    }

    func testFramingUsesUTF8ByteLengthAndRejectsOversizedPayload() throws {
        let message: LSPMessage = ["value": .string("你好🙂")]
        let encoded = try LSPMessageFraming.encode(message)
        let separator = try XCTUnwrap(encoded.range(of: Data("\r\n\r\n".utf8)))
        let header = String(decoding: encoded[..<separator.lowerBound], as: UTF8.self)
        let payloadLength = encoded.count - separator.upperBound
        XCTAssertEqual(header, "Content-Length: \(payloadLength)")
        XCTAssertGreaterThan(payloadLength, 10)

        let emptyObjectBytes = try JSONEncoder().encode(["data": ""]).count
        let maximum = [
            "data": String(repeating: "x", count: LSPProtocolLimits.maximumPayloadBytes - emptyObjectBytes)
        ]
        let maximumFrame = try LSPMessageFraming.encode(maximum)
        XCTAssertEqual(framePayloadLength(maximumFrame), LSPProtocolLimits.maximumPayloadBytes)
        XCTAssertThrowsError(try LSPMessageFraming.encode(["data": maximum["data"]! + "x"])) { error in
            XCTAssertEqual(
                error as? LSPMessageEncodingError,
                .payloadTooLarge(limit: LSPProtocolLimits.maximumPayloadBytes)
            )
        }
    }

    func testEncoderRejectsNonObjectAndNonFiniteJSON() {
        for value in [LSPJSONValue.null, .bool(true), .integer(1), .string("message"), .array([])] {
            XCTAssertThrowsError(try LSPMessageFraming.encode(value)) { error in
                XCTAssertEqual(error as? LSPMessageEncodingError, .topLevelMustBeObject)
            }
        }
        XCTAssertThrowsError(try LSPMessageFraming.encode(["number": LSPJSONValue.number(.infinity)])) { error in
            XCTAssertEqual(error as? LSPMessageEncodingError, .notJSONSerializable)
        }
    }

    func testReaderCallbacksReceiveTheSameEvents() throws {
        var messages: [LSPMessage] = []
        var errors: [LSPProtocolError] = []
        let reader = LSPMessageReader(
            onMessage: { messages.append($0) },
            onError: { errors.append($0) }
        )
        let expected: LSPMessage = ["method": .string("ready")]
        reader.receive(try LSPMessageFraming.encode(expected))
        reader.receive(frame(Data("null".utf8)))
        XCTAssertEqual(messages, [expected])
        XCTAssertEqual(errors, [LSPProtocolError("LSP payload must be a JSON object.", fatal: false)])
    }

    func testRequestIDsRoundTripAndNeverWrap() throws {
        var ids = LSPRequestIDGenerator(startingAt: 41)
        XCTAssertEqual(try ids.next(), .integer(41))
        XCTAssertEqual(try ids.next(), .integer(42))

        var last = LSPRequestIDGenerator(startingAt: LSPRequestID.maximumSafeInteger)
        XCTAssertEqual(try last.next(), .integer(LSPRequestID.maximumSafeInteger))
        XCTAssertThrowsError(try last.next()) { error in
            XCTAssertEqual(error as? LSPRequestIDGeneratorError, .exhausted)
        }

        for id in [LSPRequestID.integer(9), .string("client-9")] {
            let data = try JSONEncoder().encode(id)
            XCTAssertEqual(try JSONDecoder().decode(LSPRequestID.self, from: data), id)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(LSPRequestID.self, from: Data("1.5".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(LSPRequestID.self, from: Data("null".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(
            LSPRequestID.self, from: Data("9007199254740992".utf8)
        ))
    }

    func testInitializeAndInitializedMessagesMatchJSONRPCShape() throws {
        let initialize = LSPInitializationMessages.initialize(
            id: .integer(1), processID: 4321, rootURI: "file:///workspace"
        )
        let object = try jsonObject(initialize)
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertEqual(object["method"] as? String, "initialize")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["processId"] as? Int, 4321)
        XCTAssertEqual(params["rootUri"] as? String, "file:///workspace")
        XCTAssertNotNil(params["capabilities"] as? [String: Any])

        let initialized = try jsonObject(LSPInitializationMessages.initialized())
        XCTAssertEqual(initialized["method"] as? String, "initialized")
        XCTAssertEqual((initialized["params"] as? [String: Any])?.count, 0)

        let detached = try jsonObject(LSPInitializationMessages.initialize(
            id: .integer(2), processID: nil, rootURI: nil
        ))
        let detachedParams = try XCTUnwrap(detached["params"] as? [String: Any])
        XCTAssertTrue(detachedParams["processId"] is NSNull)
        XCTAssertTrue(detachedParams["rootUri"] is NSNull)
    }

    func testInitializeResultAndStrictResponseDecode() throws {
        let data = Data(#"""
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "capabilities": {
              "hoverProvider": true,
              "completionProvider": {"triggerCharacters": ["."]},
              "renameProvider": false
            },
            "serverInfo": {"name": "Example", "version": "1.0"}
          }
        }
        """#.utf8)
        let response = try JSONDecoder().decode(LSPResponse.self, from: data)
        XCTAssertEqual(response.id, .integer(1))
        let result = try XCTUnwrap(response.result?.objectValue)
        let initialize = try JSONDecoder().decode(
            LSPInitializeResult.self, from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(initialize.serverInfo, LSPServerInfo(name: "Example", version: "1.0"))
        XCTAssertEqual(initialize.capabilities.summarizedNames(), ["completionProvider", "hoverProvider"])

        let errorData = Data(#"""
        {
          "jsonrpc": "2.0",
          "id": "initialize",
          "error": {"code": -32603, "message": "failed", "data": {"retry": false}}
        }
        """#.utf8)
        let errorResponse = try JSONDecoder().decode(LSPResponse.self, from: errorData)
        XCTAssertEqual(errorResponse.id, .string("initialize"))
        XCTAssertEqual(errorResponse.error, LSPResponseError(
            code: -32603, message: "failed", data: .object(["retry": .bool(false)])
        ))
        XCTAssertNil(errorResponse.result)

        for invalid in [
            #"{"jsonrpc":"1.0","id":1,"result":null}"#,
            #"{"jsonrpc":"2.0","id":1}"#,
            #"{"jsonrpc":"2.0","id":1,"result":null,"error":{"code":-1,"message":"bad"}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(LSPResponse.self, from: Data(invalid.utf8)))
        }
    }

    func testInteractiveRequestDTOsClampPositionsAndMapMethods() throws {
        XCTAssertEqual(LanguageServerMethod.completion.protocolMethod, "textDocument/completion")
        XCTAssertEqual(LanguageServerMethod.hover.protocolMethod, "textDocument/hover")
        XCTAssertEqual(LanguageServerMethod.definition.protocolMethod, "textDocument/definition")
        XCTAssertEqual(LanguageServerMethod.references.protocolMethod, "textDocument/references")
        XCTAssertEqual(LanguageServerMethod.rename.protocolMethod, "textDocument/rename")

        let position = LSPPosition(line: -4, character: -9)
        let params = LSPTextDocumentPositionParams(uri: "file:///tmp/a.swift", position: position)
        let object = try jsonObject(params)
        let encodedPosition = try XCTUnwrap(object["position"] as? [String: Any])
        XCTAssertEqual(encodedPosition["line"] as? Int, 0)
        XCTAssertEqual(encodedPosition["character"] as? Int, 0)

        let references = LSPReferenceParams(
            uri: "file:///tmp/a.swift", position: position
        )
        XCTAssertEqual(
            ((try jsonObject(references)["context"] as? [String: Any])?["includeDeclaration"] as? Bool),
            true
        )
        let rename = LSPRenameParams(
            uri: "file:///tmp/a.swift", position: position, newName: "replacement"
        )
        XCTAssertEqual(try jsonObject(rename)["newName"] as? String, "replacement")
    }

    func testDocumentFormattingParamsUseLSPDefaults() throws {
        let params = LSPDocumentFormattingParams(uri: "file:///tmp/a.swift")
        XCTAssertEqual(params.textDocument.uri, "file:///tmp/a.swift")
        XCTAssertEqual(params.options, LSPFormattingOptions(tabSize: 4, insertSpaces: true))

        let object = try jsonObject(params)
        XCTAssertEqual(
            (object["textDocument"] as? [String: Any])?["uri"] as? String,
            "file:///tmp/a.swift"
        )
        let options = try XCTUnwrap(object["options"] as? [String: Any])
        XCTAssertEqual(options["tabSize"] as? Int, 4)
        XCTAssertEqual(options["insertSpaces"] as? Bool, true)

        XCTAssertEqual(LSPFormattingOptions(tabSize: 0).tabSize, 1)
        XCTAssertEqual(LSPProtocolLimits.maximumFormattingEdits, 1_000)
        XCTAssertEqual(
            LSPProtocolLimits.maximumFormattingTotalTextUTF16CodeUnits,
            4 * 1_024 * 1_024
        )
    }

    func testDiagnosticsLocationsCompletionHoverAndRenameDTOs() throws {
        let range = LSPRange(
            start: LSPPosition(line: 2, character: 3),
            end: LSPPosition(line: 2, character: 8)
        )
        let diagnostic = LSPDiagnostic(range: range, severity: 2, message: "warning")
            .languageServerDiagnostic
        XCTAssertEqual(diagnostic, LanguageServerDiagnostic(
            line: 3, column: 4, endLine: 3, endColumn: 9,
            severity: .warning, message: "warning"
        ))

        let location = LSPLocation(uri: "file:///tmp/hello%20world.swift", range: range)
        XCTAssertEqual(location.languageLocation, LanguageLocation(
            filePath: "/tmp/hello world.swift", line: 2, character: 3
        ))
        XCTAssertNil(LSPLocation(uri: "https://example.com/a.swift", range: range).languageLocation)
        XCTAssertNil(LSPLocation(uri: "file://remote-host/a.swift", range: range).languageLocation)
        let link = LSPLocationLink(
            targetURI: "file:///tmp/target.swift", targetRange: range,
            targetSelectionRange: LSPRange(
                start: LSPPosition(line: 7, character: 4),
                end: LSPPosition(line: 7, character: 9)
            )
        )
        XCTAssertEqual(link.languageLocation, LanguageLocation(
            filePath: "/tmp/target.swift", line: 7, character: 4
        ))

        let completionJSON = Data(#"""
        {
          "isIncomplete": false,
          "items": [{
            "label": "print",
            "detail": "Swift.print",
            "documentation": {"kind": "markdown", "value": "Print a value."},
            "insertText": "print($0)"
          }]
        }
        """#.utf8)
        let completion = try JSONDecoder().decode(LSPCompletionResponse.self, from: completionJSON)
        XCTAssertEqual(completion.items.first?.languageCompletionItem, LanguageCompletionItem(
            label: "print", detail: "Swift.print",
            documentation: "Print a value.", insertText: "print($0)"
        ))

        let hover = LSPHover(contents: .markedStrings([
            .string("let value"), .language(language: "swift", value: "Int")
        ]))
        XCTAssertEqual(hover.languageHover, LanguageHover(text: "let value\nInt"))

        let workspaceEdit = LSPWorkspaceEdit(changes: [
            "file:///tmp/hello%20world.swift": [LSPTextEdit(range: range, newText: "renamed")],
            "https://example.com/ignored.swift": [LSPTextEdit(range: range, newText: "ignored")]
        ])
        XCTAssertEqual(workspaceEdit.languageRenameEdits(), [LanguageRenameEdit(
            filePath: "/tmp/hello world.swift",
            startLine: 2, startCharacter: 3, endLine: 2, endCharacter: 8,
            newText: "renamed"
        )])
    }

    func testCapabilitiesAndLogsStayWithinSafetyBounds() {
        let capabilities = LSPServerCapabilities([
            "zProvider": .bool(true),
            "aProvider": .object([:]),
            "disabled": .bool(false),
            "empty": .string(""),
            "zero": .integer(0)
        ])
        XCTAssertEqual(
            capabilities.summarizedNames(maximumCount: 2, maximumUTF16Units: 100),
            ["aProvider", "zProvider"]
        )
        XCTAssertEqual(
            capabilities.summarizedNames(maximumCount: 2, maximumUTF16Units: 10),
            ["aProvider"]
        )

        let bounded = LSPLogSanitizer.boundedLog(
            String(repeating: "x", count: 100), maximumUTF16Units: 64
        )
        XCTAssertEqual(bounded.utf16.count, 64)
        XCTAssertTrue(bounded.hasSuffix(LSPLogSanitizer.truncationSuffix))
        XCTAssertEqual(LSPLogSanitizer.prefixUTF8("你🙂好", maximumBytes: 7), "你🙂")
        XCTAssertEqual(LSPLogSanitizer.prefixUTF16("a🙂b", maximumUnits: 2), "a")
        XCTAssertEqual(LSPLogSanitizer.prefixUTF16("a🙂b", maximumUnits: 3), "a🙂")

        XCTAssertEqual(LSPProtocolLimits.maximumHeaderBytes, 16 * 1024)
        XCTAssertEqual(LSPProtocolLimits.maximumPayloadBytes, 8 * 1024 * 1024)
        XCTAssertEqual(LSPProtocolLimits.maximumInputQueueBytes, 16 * 1024 * 1024)
        XCTAssertEqual(LSPProtocolLimits.maximumLogBatchBytes, 64 * 1024)
        XCTAssertEqual(LSPProtocolLimits.maximumLogBytesPerSecond, 256 * 1024)
        XCTAssertEqual(LSPProtocolLimits.maximumDiagnostics, 1_000)
    }

    func testApplicationDTOsPreserveElectronJSONFieldNames() throws {
        let config = LanguageServerConfig(command: "sourcekit-lsp", args: ["--flag"])
        let request = LanguageServerInteractiveRequest(
            root: "/workspace", config: config, content: "let value = 1",
            filePath: "/workspace/main.swift", languageId: "swift",
            method: .rename, line: 4, character: 7, newName: "answer"
        )
        let roundTrip = try JSONDecoder().decode(
            LanguageServerInteractiveRequest.self, from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(roundTrip, request)
        let object = try jsonObject(request)
        XCTAssertEqual(object["filePath"] as? String, "/workspace/main.swift")
        XCTAssertEqual(object["languageId"] as? String, "swift")
        XCTAssertEqual(object["newName"] as? String, "answer")
        XCTAssertEqual(object["method"] as? String, "rename")

        let event = LanguageServerDiagnosticEvent(filePath: "/workspace/main.swift", diagnostics: [
            LanguageServerDiagnostic(
                line: 1, column: 2, endLine: 1, endColumn: 3,
                severity: .error, message: "broken"
            )
        ])
        XCTAssertEqual(
            try JSONDecoder().decode(
                LanguageServerDiagnosticEvent.self, from: JSONEncoder().encode(event)
            ),
            event
        )
    }

    private func frame(_ payload: Data) -> Data {
        var result = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        result.append(payload)
        return result
    }

    private func framePayloadLength(_ frame: Data) -> Int {
        guard let separator = frame.range(of: Data("\r\n\r\n".utf8)) else { return -1 }
        return frame.count - separator.upperBound
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
    }
}
