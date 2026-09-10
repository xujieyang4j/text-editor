#if os(macOS)
import Foundation
import XCTest
@testable import LumenEditorCore

/// End-to-end coverage for the JavaScriptCore boundary. SwiftPM builds the
/// executable beside the test products on macOS; non-macOS hosts omit this file.
final class PluginWorkerExecutableTests: XCTestCase {
    func testWorkerEvaluatesJavaScriptAndCompletesLifecycle() async throws {
        let source = Data("""
        self.addEventListener('message', function (event) {
          if (event.data.type === 'activate') {
            postMessage({type: 'register-command', id: 'hello', title: 'Hello'});
          } else if (event.data.type === 'run-command') {
            postMessage({type: 'notify', text: 'worked'});
          }
        });
        """.utf8)
        let responses = try await runWorker(source: source, permissions: [], requests: [
            PluginWorkerRequest(
                type: .load, requestID: "load", source: source,
                sourceSHA256: SHA256Integrity.digest(of: source).rawValue
            ),
            PluginWorkerRequest(
                type: .activate, requestID: "activate",
                context: PluginWorkerContext(permissions: [])
            ),
            PluginWorkerRequest(
                type: .runCommand, requestID: "run", commandID: "hello",
                context: PluginWorkerContext(permissions: [])
            ),
            PluginWorkerRequest(
                type: .deactivate, requestID: "deactivate",
                context: PluginWorkerContext(permissions: [])
            )
        ])

        XCTAssertEqual(
            responses.map { $0.type },
            [
                .completed, .registerCommand, .completed, .notify,
                .completed, .completed
            ]
        )
        XCTAssertEqual(
            responses.compactMap(\.requestID),
            ["load", "activate", "activate", "run", "run", "deactivate"]
        )
        XCTAssertEqual(responses.first(where: { $0.type == .registerCommand })?.id, "hello")
        XCTAssertEqual(responses.first(where: { $0.type == .notify })?.text, "worked")
    }

    func testWorkerRejectsReplacementWithoutEditPermission() async throws {
        let source = Data("""
        self.onmessage = function (event) {
          if (event.data.type === 'run-command') {
            postMessage({type: 'replace-document', text: 'changed'});
          }
        };
        """.utf8)
        let responses = try await runWorker(source: source, permissions: [], requests: [
            PluginWorkerRequest(
                type: .load, requestID: "load", source: source,
                sourceSHA256: SHA256Integrity.digest(of: source).rawValue
            ),
            PluginWorkerRequest(
                type: .runCommand, requestID: "run", commandID: "edit",
                context: PluginWorkerContext(permissions: [])
            )
        ])

        XCTAssertEqual(responses.last?.type, .failed)
        XCTAssertEqual(responses.last?.requestID, "run")
        XCTAssertTrue(responses.last?.text?.contains("document-edit") == true)
    }

    func testWorkerReturnsUTF16BoundedJavaScriptFailure() async throws {
        let source = Data("""
        self.onmessage = function (event) {
          if (event.data.type === 'run-command') {
            throw new Error('😀'.repeat(2500));
          }
        };
        """.utf8)
        let responses = try await runWorker(source: source, permissions: [], requests: [
            PluginWorkerRequest(
                type: .load, requestID: "load", source: source,
                sourceSHA256: SHA256Integrity.digest(of: source).rawValue
            ),
            PluginWorkerRequest(
                type: .runCommand, requestID: "run", commandID: "fail",
                context: PluginWorkerContext(permissions: [])
            )
        ])

        XCTAssertEqual(responses.last?.type, .failed)
        XCTAssertLessThanOrEqual(
            responses.last?.text?.utf16.count ?? .max,
            PluginWorkerProtocol.maximumFailureUTF16Count
        )
    }

    func testWorkerAllowsMaximumPluginMessagesPlusTerminalResponse() async throws {
        let source = Data("""
        self.onmessage = function (event) {
          if (event.data.type === 'activate') {
            for (var i = 0; i < 256; i++) {
              postMessage({type: 'notify', text: 'n'});
            }
          }
        };
        """.utf8)
        let responses = try await runWorker(source: source, permissions: [], requests: [
            PluginWorkerRequest(
                type: .load, requestID: "load", source: source,
                sourceSHA256: SHA256Integrity.digest(of: source).rawValue
            ),
            PluginWorkerRequest(
                type: .activate, requestID: "activate",
                context: PluginWorkerContext(permissions: [])
            )
        ])
        let activation = responses.filter { $0.requestID == "activate" }

        XCTAssertEqual(
            activation.count, PluginWorkerProtocol.maximumWireMessagesPerRequest
        )
        XCTAssertEqual(activation.dropLast().filter { $0.type == .notify }.count, 256)
        XCTAssertEqual(activation.last?.type, .completed)
    }

    func testWorkerRejectsReplacementByUTF8ByteCount() async throws {
        let source = Data("""
        self.onmessage = function (event) {
          if (event.data.type === 'run-command') {
            postMessage({type: 'replace-document', text: '😀'.repeat(2097153)});
          }
        };
        """.utf8)
        let responses = try await runWorker(
            source: source, permissions: [.documentEdit], requests: [
                PluginWorkerRequest(
                    type: .load, requestID: "load", source: source,
                    sourceSHA256: SHA256Integrity.digest(of: source).rawValue
                ),
                PluginWorkerRequest(
                    type: .runCommand, requestID: "run", commandID: "edit",
                    context: PluginWorkerContext(permissions: [.documentEdit])
                )
            ]
        )

        XCTAssertEqual(responses.last?.type, .failed)
        XCTAssertTrue(responses.last?.text?.contains("UTF-8 bytes") == true)
    }

    private func runWorker(
        source: Data,
        permissions: [PluginPermission],
        requests: [PluginWorkerRequest]
    ) async throws -> [PluginWorkerResponse] {
        let executable = try workerExecutableURL()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let stdoutTask = Task.detached {
            output.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            error.fileHandleForReading.readDataToEndOfFile()
        }
        process.executableURL = executable
        process.arguments = [
            "integration-worker", SHA256Integrity.digest(of: source).rawValue
        ] + permissions.map(\.rawValue).sorted()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        var wireInput = Data()
        for request in requests { wireInput.append(try PluginWorkerWireCodec.encode(request)) }
        try input.fileHandleForWriting.write(contentsOf: wireInput)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let (stdoutData, stderrData) = await (stdoutTask.value, stderrTask.value)
        XCTAssertEqual(
            process.terminationStatus, 0,
            String(decoding: stderrData, as: UTF8.self)
        )
        var decoder = PluginWorkerLineDecoder()
        let lines = try decoder.append(stdoutData)
        try decoder.finish()
        return try lines.map(PluginWorkerWireCodec.decodeResponse)
    }

    private func workerExecutableURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["LUMEN_PLUGIN_WORKER_EXECUTABLE"],
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = directory.appendingPathComponent("LumenPluginWorker")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        if ProcessInfo.processInfo.environment["LUMEN_REQUIRE_WORKERS"] == "1" {
            XCTFail("LumenPluginWorker is required but unavailable; run scripts/verify.sh")
            throw CocoaError(.fileNoSuchFile)
        }
        throw XCTSkip("SwiftPM did not place LumenPluginWorker beside the test bundle.")
    }
}
#endif
