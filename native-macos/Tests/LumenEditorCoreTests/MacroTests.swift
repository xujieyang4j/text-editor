import Foundation
import XCTest
@testable import LumenEditorCore

final class MacroTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testMacroStepEncodingMatchesElectronWireFormat() throws {
        let macro = SavedMacro(
            name: "Ordered", commands: [.toggleComment],
            steps: [
                .command(.toggleComment),
                .edits([TextEdit(from: 1, to: 1, insert: "x")])
            ]
        )
        let data = try MacroSanitizer.encodedData([macro])
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let steps = try XCTUnwrap(root.first?["steps"] as? [[String: Any]])

        XCTAssertEqual(steps[0]["kind"] as? String, "command")
        XCTAssertEqual(steps[0]["command"] as? String, "toggle-comment")
        XCTAssertEqual(steps[1]["kind"] as? String, "edits")
        XCTAssertEqual(
            ((steps[1]["edits"] as? [[String: Any]])?.first?["insert"]) as? String,
            "x"
        )
    }

    func testSanitizerDropsUnknownCommandsMalformedEditsAndOverlaps() throws {
        let data = try JSONSerialization.data(withJSONObject: [[
            "name": " Demo ",
            "commands": ["delete-line", "open-file", 42],
            "steps": [
                ["kind": "command", "command": "move-line-up"],
                ["kind": "command", "command": "run-macro"],
                ["kind": "edits", "edits": [
                    ["from": 1, "to": 3, "insert": "x"],
                    ["from": 2, "to": 4, "insert": "y"]
                ]],
                ["kind": "edits", "edits": [
                    ["from": true, "to": 0, "insert": "bad"],
                    ["from": 4, "to": 4, "insert": "!"]
                ]]
            ]
        ]])

        let macro = try XCTUnwrap(MacroSanitizer.parse(data).first)
        XCTAssertEqual(macro.name, "Demo")
        XCTAssertEqual(macro.commands, [.deleteLine])
        XCTAssertEqual(macro.steps, [
            .command(.moveLineUp),
            .edits([TextEdit(from: 4, to: 4, insert: "!")])
        ])
    }

    func testRecordingIsTypedBoundedAndStopsAtTheLimit() throws {
        let limits = MacroLimits(maximumSteps: 2)
        var recording = MacroRecording(limits: limits)
        recording.start()
        try recording.record(command: .deleteLine)
        try recording.record(edits: [TextEdit(from: 0, to: 0, insert: "x")])

        XCTAssertThrowsError(try recording.record(command: .sortLines)) { error in
            XCTAssertEqual(
                error as? MacroRecordingError,
                .recordingLimitReached(maximumSteps: 2)
            )
        }
        XCTAssertFalse(recording.isRecording)
        XCTAssertEqual(recording.steps.count, 2)
    }

    func testRecordingRejectsAnUnsafeEditWithoutAppendingIt() {
        let limits = MacroLimits(maximumPosition: 3)
        var recording = MacroRecording(limits: limits)
        recording.start()

        XCTAssertThrowsError(
            try recording.record(edits: [TextEdit(from: 4, to: 4, insert: "x")])
        ) { error in
            XCTAssertEqual(error as? MacroRecordingError, .editStepRejected)
        }
        XCTAssertTrue(recording.steps.isEmpty)
    }

    func testRecordingRejectsTooManyEditsEvenWhenLaterEditsAreValid() {
        let limits = MacroLimits(maximumEditsPerStep: 1, maximumTotalEdits: 10)
        var recording = MacroRecording(limits: limits)
        recording.start()

        XCTAssertThrowsError(try recording.record(edits: [
            TextEdit(from: 0, to: 0, insert: "a"),
            TextEdit(from: 1, to: 1, insert: "b")
        ])) { error in
            XCTAssertEqual(error as? MacroRecordingError, .editStepRejected)
        }
        XCTAssertTrue(recording.steps.isEmpty)
    }

    func testEncodingSkipsInvalidMacrosBeforeApplyingCollectionLimit() throws {
        let data = try MacroSanitizer.encodedData(
            [SavedMacro(name: "   "), SavedMacro(name: "Good")],
            limits: MacroLimits(maximumMacros: 1)
        )
        XCTAssertEqual(try MacroSanitizer.parse(data).map(\.name), ["Good"])
    }

    func testLegacyReplayPrecedenceMatchesElectron() {
        let commandOnly = SavedMacro(name: "Command", commands: [.deleteLine])
        XCTAssertEqual(commandOnly.replayOperations, [.command(.deleteLine)])

        let snapshot = SavedMacro(
            name: "Snapshot", commands: [.sortLines], text: "old"
        )
        XCTAssertEqual(snapshot.replayOperations, [
            .legacyText("old"), .command(.sortLines)
        ])

        let modern = SavedMacro(
            name: "Modern", commands: [.sortLines],
            steps: [.command(.moveLineDown)], text: "ignored"
        )
        XCTAssertEqual(modern.replayOperations, [.command(.moveLineDown)])
    }

    func testStoreWritesInsideWorkspaceReplacesByNameAndReloads() throws {
        let workspace = try makeWorkspace()
        let store = MacroStore(workspaceURL: workspace)
        try store.save(SavedMacro(
            name: "One", commands: [.deleteLine],
            steps: [.command(.deleteLine)]
        ))
        try store.save(SavedMacro(
            name: "Two", commands: [.sortLines],
            steps: [.command(.sortLines)]
        ))
        try store.save(SavedMacro(
            name: "One", commands: [.moveLineUp],
            steps: [.command(.moveLineUp)]
        ))

        XCTAssertEqual(store.macrosURL.deletingLastPathComponent(), workspace)
        XCTAssertEqual(try store.load().map(\.name), ["One", "Two"])
        XCTAssertEqual(try store.load().first?.steps, [.command(.moveLineUp)])
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: store.macrosURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o077, 0)
    }

    func testStoreRefusesSymlinkDestinationAndDoesNotTouchTarget() throws {
        let workspace = try makeWorkspace()
        let outside = workspace.deletingLastPathComponent().appendingPathComponent(
            "outside-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("[]".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent(MacroStore.fileName),
            withDestinationURL: outside
        )
        let store = MacroStore(workspaceURL: workspace)

        XCTAssertThrowsError(try store.save(SavedMacro(
            name: "Blocked", commands: [.deleteLine]
        ))) { error in
            XCTAssertEqual(error as? MacroStoreError, .symbolicLinkEncountered)
        }
        XCTAssertEqual(try String(contentsOf: outside), "[]")
    }

    func testStoreRejectsOversizedFileBeforeParsing() throws {
        let workspace = try makeWorkspace()
        let limits = MacroLimits(maximumSerializedBytes: 32)
        let store = MacroStore(workspaceURL: workspace, limits: limits)
        try Data(repeating: 0x20, count: 33).write(to: store.macrosURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? MacroStoreError,
                .fileTooLarge(actualBytes: 33, maximumBytes: 32)
            )
        }
    }

    private func makeWorkspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacroTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory.standardizedFileURL
    }
}
