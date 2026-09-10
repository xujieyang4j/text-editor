import Foundation
import XCTest
@testable import LumenEditorCore

final class PluginWorkerProtocolTests: XCTestCase {
    func testContextExposesDocumentOnlyWithReadPermission() throws {
        let document = try PluginWorkerDocumentContext(
            text: "hello", language: "Plain Text",
            selection: PluginWorkerSelection(from: 1, to: 4)
        )

        XCTAssertNil(PluginWorkerContext(permissions: [], document: document).document)
        XCTAssertNil(
            PluginWorkerContext(permissions: [.documentEdit], document: document).document
        )
        XCTAssertEqual(
            PluginWorkerContext(permissions: [.documentRead], document: document).document,
            document
        )
        let clamped = try PluginWorkerDocumentContext(
            text: "abc", language: "Text",
            selection: PluginWorkerSelection(from: 99, to: 1)
        )
        XCTAssertEqual(clamped.selection, PluginWorkerSelection(from: 1, to: 3))
    }

    func testRequestRoundTripUsesNewlineFramingAndValidatesShape() throws {
        let source = Data("self.onmessage = function () {}".utf8)
        let request = PluginWorkerRequest(
            type: .load, requestID: "load-1", source: source,
            sourceSHA256: SHA256Integrity.digest(of: source).rawValue
        )

        let encoded = try PluginWorkerWireCodec.encode(request)

        XCTAssertEqual(encoded.last, 0x0a)
        XCTAssertEqual(try PluginWorkerWireCodec.decodeRequest(encoded), request)
        XCTAssertThrowsError(try PluginWorkerWireCodec.decodeRequest(try JSONEncoder().encode(
            PluginWorkerRequest(type: .runCommand, requestID: "run")
        ))) { error in
            XCTAssertEqual(error as? PluginWorkerProtocolError, .invalidRequest)
        }
    }

    func testResponseRejectsOversizedReplacement() {
        let response = PluginWorkerResponse(
            type: .replaceDocument, requestID: "run",
            text: String(
                repeating: "x",
                count: PluginWorkerProtocol.maximumReplacementBytes + 1
            )
        )

        XCTAssertThrowsError(try PluginWorkerWireCodec.encode(response)) { error in
            XCTAssertEqual(
                error as? PluginWorkerProtocolError,
                .replacementTooLarge(
                    maximumBytes: PluginWorkerProtocol.maximumReplacementBytes
                )
            )
        }
    }

    func testResponseRejectsMalformedCommandAndOversizedNotification() throws {
        let missingTitle = try JSONEncoder().encode(PluginWorkerResponse(
            type: .registerCommand, requestID: "activate", id: "command"
        ))
        XCTAssertThrowsError(try PluginWorkerWireCodec.decodeResponse(missingTitle)) { error in
            XCTAssertEqual(error as? PluginWorkerProtocolError, .invalidMessage)
        }

        let oversized = try JSONEncoder().encode(PluginWorkerResponse(
            type: .notify, requestID: "activate",
            text: String(repeating: "x", count: 501)
        ))
        XCTAssertThrowsError(try PluginWorkerWireCodec.decodeResponse(oversized)) { error in
            XCTAssertEqual(error as? PluginWorkerProtocolError, .invalidMessage)
        }
    }

    func testResponseShapeAndDynamicCommandBoundsAreStrict() throws {
        let malformed = PluginWorkerResponse(
            type: .completed, requestID: "done", text: "unexpected"
        )
        XCTAssertThrowsError(try PluginWorkerWireCodec.decodeResponse(
            try JSONEncoder().encode(malformed)
        ))

        let oversizedID = PluginWorkerResponse(
            type: .registerCommand, requestID: "register",
            id: String(repeating: "x", count: 101), title: "Command"
        )
        XCTAssertThrowsError(try PluginWorkerWireCodec.decodeResponse(
            try JSONEncoder().encode(oversizedID)
        ))
    }

    func testLineDecoderHandlesFragmentedMessagesAndRejectsUnterminatedData() throws {
        let first = try PluginWorkerWireCodec.encode(PluginWorkerResponse(
            type: .notify, requestID: "one", text: "hello"
        ))
        let second = try PluginWorkerWireCodec.encode(PluginWorkerResponse(
            type: .completed, requestID: "one"
        ))
        let combined = first + second
        let split = combined.index(combined.startIndex, offsetBy: combined.count / 2)
        var decoder = PluginWorkerLineDecoder()

        let prefix = try decoder.append(Data(combined[..<split]))
        let suffix = try decoder.append(Data(combined[split...]))
        try decoder.finish()

        XCTAssertEqual(
            try (prefix + suffix).map(PluginWorkerWireCodec.decodeResponse),
            [
                PluginWorkerResponse(type: .notify, requestID: "one", text: "hello"),
                PluginWorkerResponse(type: .completed, requestID: "one")
            ]
        )

        var incomplete = PluginWorkerLineDecoder()
        _ = try incomplete.append(Data("{}".utf8))
        XCTAssertThrowsError(try incomplete.finish()) { error in
            XCTAssertEqual(error as? PluginWorkerProtocolError, .invalidMessage)
        }
    }

    func testLineDecoderAcceptsSeveralBoundedLinesInOneChunk() throws {
        let line = try PluginWorkerWireCodec.encode(PluginWorkerResponse(
            type: .completed, requestID: "request"
        ))
        let count = 4
        var decoder = PluginWorkerLineDecoder()

        let messages = try decoder.append(
            (0..<count).reduce(into: Data()) { data, _ in data.append(line) }
        )
        try decoder.finish()

        XCTAssertEqual(messages.count, count)
    }

    func testWireBudgetIncludesTerminalResponseBeyondPluginMessageLimit() throws {
        let notify = try PluginWorkerWireCodec.encode(PluginWorkerResponse(
            type: .notify, requestID: "request", text: "x"
        ))
        let completed = try PluginWorkerWireCodec.encode(PluginWorkerResponse(
            type: .completed, requestID: "request"
        ))
        var payload = Data()
        for _ in 0..<PluginWorkerProtocol.maximumMessagesPerRequest {
            payload.append(notify)
        }
        payload.append(completed)
        var decoder = PluginWorkerLineDecoder()

        let messages = try decoder.append(payload)
        try decoder.finish()

        XCTAssertEqual(messages.count, PluginWorkerProtocol.maximumWireMessagesPerRequest)
        XCTAssertEqual(
            try PluginWorkerWireCodec.decodeResponse(try XCTUnwrap(messages.last)).type,
            .completed
        )
    }

    func testDocumentAndMessageBoundsAreEnforced() {
        XCTAssertThrowsError(try PluginWorkerDocumentContext(
            text: String(
                repeating: "x", count: PluginWorkerProtocol.maximumDocumentBytes + 1
            ),
            language: "Text", selection: PluginWorkerSelection(from: 0, to: 0)
        )) { error in
            XCTAssertEqual(
                error as? PluginWorkerProtocolError,
                .documentTooLarge(maximumBytes: PluginWorkerProtocol.maximumDocumentBytes)
            )
        }

        var decoder = PluginWorkerLineDecoder()
        XCTAssertThrowsError(try decoder.append(Data(
            repeating: 0x20, count: PluginWorkerProtocol.maximumMessageBytes + 1
        ))) { error in
            XCTAssertEqual(
                error as? PluginWorkerProtocolError,
                .messageTooLarge(maximumBytes: PluginWorkerProtocol.maximumMessageBytes)
            )
        }
    }

    func testProtocolSeparatesPerRequestProcessAndRetainedOutputBudgets() {
        XCTAssertGreaterThan(
            PluginWorkerProtocol.maximumProcessOutputBytes,
            PluginWorkerProtocol.maximumResponseBytes
        )
        XCTAssertLessThan(
            PluginWorkerProtocol.maximumRetainedProcessOutputBytes,
            PluginWorkerProtocol.maximumResponseBytes
        )
    }
}
