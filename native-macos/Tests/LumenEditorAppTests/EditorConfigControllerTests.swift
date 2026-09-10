import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class EditorConfigControllerTests: XCTestCase {
    @MainActor
    func testMostSpecificWorkspaceRootIsPassedToResolver() async throws {
        let outerURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let innerURL = URL(fileURLWithPath: "/workspace/project", isDirectory: true)
        let target = innerURL.appendingPathComponent("Sources/main.swift")
        let roots = [
            WorkspaceRoot(id: .init(), url: outerURL, displayName: "workspace", isPrimary: true),
            WorkspaceRoot(id: .init(), url: innerURL, displayName: "project", isPrimary: false)
        ]
        let recorder = ResolveRecorder(result: ResolvedEditorConfig(
            properties: EditorConfigProperties(
                indentStyle: .space,
                indentSize: .columns(2),
                tabWidth: 8,
                endOfLine: .crlf
            ),
            sources: [innerURL.appendingPathComponent(".editorconfig")]
        ))
        let controller = EditorConfigController(resolver: { target, root, allowMissing in
            XCTAssertFalse(allowMissing)
            recorder.record(target: target, root: root)
            return recorder.result
        })
        let document = makeDocument(url: target, lineEnding: .lf)

        await controller.resolve(for: document, workspaceRoots: roots)

        let call = recorder.lastCall
        XCTAssertEqual(call?.target, target)
        XCTAssertEqual(call?.root, innerURL)
        XCTAssertEqual(document.editorConfig?.indentSize, .columns(2))
        XCTAssertEqual(document.editorConfig?.tabWidth, 8)
        XCTAssertEqual(document.effectiveLineEnding, .crlf)
        XCTAssertFalse(document.isDirty)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testSuggestionDoesNotOverrideExplicitEOLChoiceOrMakeDocumentDirty() async {
        let rootURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let target = rootURL.appendingPathComponent("main.swift")
        let controller = EditorConfigController(resolver: { _, _, _ in
            ResolvedEditorConfig(
                properties: EditorConfigProperties(endOfLine: .crlf),
                sources: [rootURL.appendingPathComponent(".editorconfig")]
            )
        })
        let document = makeDocument(url: target, lineEnding: .lf)

        await controller.resolve(for: document, workspaceRoots: [
            WorkspaceRoot(id: .init(), url: rootURL, displayName: "workspace", isPrimary: true)
        ])

        XCTAssertEqual(document.lineEnding, .lf)
        XCTAssertEqual(document.savedLineEnding, .lf)
        XCTAssertEqual(document.effectiveLineEnding, .crlf)
        XCTAssertFalse(document.isDirty)

        document.chooseLineEndingForSave(.cr)
        XCTAssertEqual(document.effectiveLineEnding, .cr)
        XCTAssertTrue(document.isDirty)
    }

    @MainActor
    func testOutsideWorkspaceClearsSuggestionWithoutCallingResolver() async {
        let recorder = ResolveRecorder(result: ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf)
        ))
        let controller = EditorConfigController(resolver: { target, root, _ in
            recorder.record(target: target, root: root)
            return recorder.result
        })
        let document = makeDocument(
            url: URL(fileURLWithPath: "/elsewhere/main.swift"),
            lineEnding: .lf
        )
        document.setEditorConfig(ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf)
        ))

        await controller.resolve(for: document, workspaceRoots: [
            WorkspaceRoot(
                id: .init(),
                url: URL(fileURLWithPath: "/workspace"),
                displayName: "workspace",
                isPrimary: true
            )
        ])

        XCTAssertNil(document.editorConfig)
        XCTAssertNil(recorder.lastCall)
    }

    @MainActor
    func testResolutionFailureClearsOldSuggestionAndPublishesIssue() async {
        struct Failure: LocalizedError {
            var errorDescription: String? { "resolution failed" }
        }
        let rootURL = URL(fileURLWithPath: "/workspace")
        let document = makeDocument(
            url: rootURL.appendingPathComponent("main.swift"),
            lineEnding: .lf
        )
        document.setEditorConfig(ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf)
        ))
        let controller = EditorConfigController(resolver: { _, _, _ in throw Failure() })

        await controller.resolve(for: document, workspaceRoots: [
            WorkspaceRoot(id: .init(), url: rootURL, displayName: "workspace", isPrimary: true)
        ])

        XCTAssertNil(document.editorConfig)
        XCTAssertEqual(controller.issue?.titleContent, .resolve)
        XCTAssertEqual(controller.issue?.content, .verbatim("resolution failed"))
        XCTAssertEqual(controller.issue?.message, "resolution failed")
        XCTAssertEqual(
            controller.issue.map {
                EditorLocale.zhCN.localizedEditorConfigIssue($0.content)
            },
            "resolution failed"
        )
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    func testResolutionBoundaryErrorStaysTypedForRuntimeLocalization() async {
        let rootURL = URL(fileURLWithPath: "/workspace")
        let target = rootURL.appendingPathComponent("main.swift")
        let failure = EditorConfigResolutionError.targetOutsideWorkspace(target)
        let controller = EditorConfigController(resolver: { _, _, _ in throw failure })
        let document = makeDocument(url: target, lineEnding: .lf)

        await controller.resolve(for: document, workspaceRoots: [
            WorkspaceRoot(
                id: .init(), url: rootURL, displayName: "workspace", isPrimary: true
            )
        ])

        XCTAssertEqual(controller.issue?.content, .resolution(failure))
        XCTAssertEqual(
            controller.issue.map {
                EditorLocale.zhCN.localizedEditorConfigIssue($0.content)
            },
            "EditorConfig 目标位于请求的工作区根目录之外。"
        )
    }

    @MainActor
    func testSaveResolutionUsesMissingDestinationModeAndExplicitOverrideWins() async {
        let rootURL = URL(fileURLWithPath: "/workspace")
        let destination = rootURL.appendingPathComponent("new.swift")
        let recorder = SaveResolveRecorder()
        let controller = EditorConfigController(resolver: { target, root, allowMissing in
            recorder.record(target: target, root: root, allowMissing: allowMissing)
            return ResolvedEditorConfig(
                properties: EditorConfigProperties(endOfLine: .crlf)
            )
        })
        let document = makeDocument(
            url: rootURL.appendingPathComponent("old.swift"),
            lineEnding: .lf
        )
        let roots = [WorkspaceRoot(
            id: .init(), url: rootURL, displayName: "workspace", isPrimary: true
        )]

        let configuredEOL = await controller.lineEndingForSave(
            document: document,
            destination: destination,
            workspaceRoots: roots,
            allowMissingTarget: true
        )
        XCTAssertEqual(configuredEOL, .crlf)
        XCTAssertTrue(recorder.lastCall?.allowMissing == true)
        document.chooseLineEndingForSave(.cr)
        let explicitEOL = await controller.lineEndingForSave(
            document: document,
            destination: destination,
            workspaceRoots: roots,
            allowMissingTarget: true
        )
        XCTAssertEqual(explicitEOL, .cr)
        XCTAssertEqual(recorder.callCount, 1)
    }

    @MainActor
    func testCancelPreventsLateResolutionFromMutatingDocument() async {
        let rootURL = URL(fileURLWithPath: "/workspace")
        let target = rootURL.appendingPathComponent("main.swift")
        let gate = ResolveGate(result: ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf)
        ))
        let controller = EditorConfigController(resolver: { _, _, _ in
            await gate.waitForResult()
        })
        let document = makeDocument(url: target, lineEnding: .lf)
        let roots = [WorkspaceRoot(
            id: .init(), url: rootURL, displayName: "workspace", isPrimary: true
        )]

        let task = Task { await controller.resolve(for: document, workspaceRoots: roots) }
        await gate.waitUntilStarted()
        controller.cancel(for: document.sessionDocumentID)
        await gate.release()
        await task.value

        XCTAssertNil(document.editorConfig)
        XCTAssertEqual(document.effectiveLineEnding, .lf)
    }

    @MainActor
    func testCapabilityConnectedControllerUsesRegisteredRoot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorConfigControllerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        let target = directory.appendingPathComponent("main.swift")
        try Data("print(1)".utf8).write(to: target)
        try Data("[*]\nindent_size=2\nend_of_line=crlf".utf8).write(
            to: directory.appendingPathComponent(".editorconfig")
        )
        let service = WorkspaceService()
        let root = try await service.addRoot(directory)
        let controller = EditorConfigController(resolver: { target, _, allowMissing in
            try await service.resolveEditorConfig(
                for: target,
                in: root.id,
                allowMissingTarget: allowMissing
            )
        })
        let document = makeDocument(url: target, lineEnding: .lf)

        await controller.resolve(for: document, workspaceRoots: [root])

        XCTAssertEqual(document.editorConfig?.indentSize, .columns(2))
        XCTAssertEqual(document.effectiveLineEnding, .crlf)
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    private func makeDocument(url: URL, lineEnding: LineEnding) -> EditorDocument {
        EditorDocument(
            fileURL: url,
            displayName: url.lastPathComponent,
            text: "one\ntwo\n",
            savedText: "one\ntwo\n",
            lineEnding: lineEnding,
            savedLineEnding: lineEnding
        )
    }
}

private actor ResolveGate {
    let result: ResolvedEditorConfig
    private var continuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    init(result: ResolvedEditorConfig) {
        self.result = result
    }

    func waitForResult() async -> ResolvedEditorConfig {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation = $0 }
        return result
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ResolveRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let target: URL
        let root: URL
    }

    let result: ResolvedEditorConfig
    private let lock = NSLock()
    private var call: Call?

    var lastCall: Call? {
        lock.lock()
        defer { lock.unlock() }
        return call
    }

    init(result: ResolvedEditorConfig) {
        self.result = result
    }

    func record(target: URL, root: URL) {
        lock.lock()
        call = Call(target: target, root: root)
        lock.unlock()
    }
}

private final class SaveResolveRecorder: @unchecked Sendable {
    struct Call {
        let target: URL
        let root: URL
        let allowMissing: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var lastCall: Call? {
        lock.lock()
        defer { lock.unlock() }
        return calls.last
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    func record(target: URL, root: URL, allowMissing: Bool) {
        lock.lock()
        calls.append(Call(target: target, root: root, allowMissing: allowMissing))
        lock.unlock()
    }
}
