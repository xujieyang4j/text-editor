import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class LanguageServerControllerTests: XCTestCase {
    private let root = URL(
        fileURLWithPath: "/tmp/lumen-language-server-controller-tests",
        isDirectory: true
    )
    private let config = LanguageServerConfig(command: "test-lsp", args: ["--stdio"])

    func testConsumesManagerEventsAndDropsOldGenerationsByKey() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        await controller.waitUntilObservingEvents()
        let key = serverKey()

        await manager.emit(.status(status(
            key: key, state: .running, generation: 2, sequence: 1,
            capabilities: ["hover"]
        )))
        await manager.emit(.log(log(
            key: key, generation: 2, text: "current", sequence: 2
        )))
        await manager.emit(.diagnostics(diagnostics(
            key: key, generation: 2, version: 2, message: "current diagnostic",
            sequence: 3
        )))
        await drainMainActorTasks()

        await manager.emit(.status(status(
            key: key, state: .failed, generation: 1, capabilities: ["stale"]
        )))
        await manager.emit(.log(log(
            key: key, generation: 1, text: "stale"
        )))
        await manager.emit(.diagnostics(diagnostics(
            key: key, generation: 1, version: 99, message: "stale diagnostic"
        )))
        await drainMainActorTasks()

        XCTAssertEqual(controller.status(for: key)?.state, .running)
        XCTAssertEqual(controller.status(for: key)?.capabilities, ["hover"])
        XCTAssertEqual(controller.logs(for: key).map(\.text), ["current"])
        XCTAssertEqual(
            controller.diagnostics(for: key).map { $0.diagnostic.message },
            ["current diagnostic"]
        )
    }

    func testControllerCancelsEventObservationWhenReleased() async {
        let manager = LanguageServerManagerStub()
        weak var releasedController: LanguageServerController?
        do {
            let controller = LanguageServerController(manager: manager)
            await controller.waitUntilObservingEvents()
            releasedController = controller
        }
        await drainMainActorTasks()

        XCTAssertNil(releasedController)
        let didTerminate = await manager.waitUntilEventStreamTerminated()
        XCTAssertTrue(didTerminate)
    }

    func testNewGenerationClearsOldLogsAndDiagnostics() {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()

        controller.receive(.status(status(
            key: key, state: .running, generation: 3, sequence: 1
        )))
        controller.receive(.log(log(
            key: key, generation: 3, text: "old log", sequence: 2
        )))
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 3, version: 1, message: "old diagnostic", sequence: 3
        )))
        XCTAssertFalse(controller.logs(for: key).isEmpty)
        XCTAssertFalse(controller.diagnostics(for: key).isEmpty)

        controller.receive(.status(status(key: key, state: .starting, generation: 4)))

        XCTAssertEqual(controller.status(for: key)?.generation, 4)
        XCTAssertTrue(controller.logs(for: key).isEmpty)
        XCTAssertTrue(controller.diagnostics(for: key).isEmpty)
    }

    func testOutOfOrderSameGenerationStatusCannotRegressLifecycle() {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        let key = serverKey()

        controller.receive(.status(status(
            key: key, state: .starting, generation: 5, sequence: 1
        )))
        controller.receive(.status(status(
            key: key, state: .running, generation: 5, sequence: 3
        )))
        controller.receive(.status(status(
            key: key, state: .starting, generation: 5, sequence: 2
        )))

        XCTAssertEqual(controller.status(for: key)?.state, .running)
    }

    func testEventSequenceDropsLateLogAndDiagnosticAcrossKinds() {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        let key = serverKey()

        controller.receive(.status(status(
            key: key, state: .running, generation: 3, sequence: 4
        )))
        controller.receive(.log(log(
            key: key, generation: 3, text: "late log", sequence: 2
        )))
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 3, version: 1, message: "late diagnostic",
            sequence: 3
        )))

        XCTAssertTrue(controller.logs(for: key).isEmpty)
        XCTAssertTrue(controller.diagnostics(for: key).isEmpty)
    }

    func testOlderDocumentVersionCannotReplaceNewerDiagnostics() {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        let key = serverKey()

        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: 7, message: "newer", sequence: 1
        )))
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: 6, message: "older", sequence: 2
        )))

        XCTAssertEqual(controller.diagnostics.count, 1)
        XCTAssertEqual(controller.diagnostics.first?.diagnostic.message, "newer")
        XCTAssertEqual(controller.diagnostics.first?.documentVersion, 7)
    }

    func testUnversionedBatchCannotDisplaceExactVersionedBatch() {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        let key = serverKey()
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: 7, message: "exact", sequence: 1
        )))
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: nil, message: "ambiguous", sequence: 2
        )))

        XCTAssertEqual(controller.diagnostics.map { $0.diagnostic.message }, ["exact"])
        XCTAssertEqual(controller.diagnostics.first?.documentVersion, 7)
    }

    func testEditorPresentationRequiresCanonicalPathAndExactDocumentRevision() async throws {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        let fileURL = root.appendingPathComponent("folder/../File.swift")
        _ = await controller.synchronize(
            syncRequest(fileURL: fileURL, version: 7),
            documentID: "document-a", documentRevision: 7
        )
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 4, version: 7, message: "exact", sequence: 1
        )))

        let snapshot = try XCTUnwrap(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 7,
            serverKey: key
        ))

        XCTAssertEqual(snapshot.documentID, "document-a")
        XCTAssertEqual(snapshot.filePath, root.appendingPathComponent("File.swift").path)
        XCTAssertEqual(snapshot.documentRevision, 7)
        XCTAssertEqual(snapshot.generation, 4)
        XCTAssertEqual(snapshot.entries.map { $0.diagnostic.message }, ["exact"])
        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 8,
            serverKey: key
        ))
        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-b", fileURL: fileURL, documentRevision: 7,
            serverKey: key
        ))
        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a",
            fileURL: root.appendingPathComponent("Other.swift"),
            documentRevision: 7, serverKey: key
        ))
        let otherServer = LanguageServerInstanceKey(
            root: root, config: LanguageServerConfig(command: "other-lsp", args: [])
        )
        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 7,
            serverKey: otherServer
        ))
    }

    func testUnversionedDiagnosticsRemainInPanelButNeverReachEditor() {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        let key = serverKey()
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: nil, message: "unversioned", sequence: 1
        )))

        XCTAssertEqual(controller.diagnostics.map { $0.diagnostic.message }, ["unversioned"])
        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a",
            fileURL: root.appendingPathComponent("File.swift"),
            documentRevision: 0, serverKey: key
        ))
    }

    func testVersionedDiagnosticsNeedExactSynchronizedDocumentIdentity() {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        let key = serverKey()
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: 0, message: "not synchronized",
            sequence: 1
        )))

        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a",
            fileURL: root.appendingPathComponent("File.swift"),
            documentRevision: 0, serverKey: key
        ))
    }

    func testSynchronizeAdvancesPresentationRevisionForEarlyDiagnosticsRace() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        await controller.waitUntilObservingEvents()
        let key = serverKey()
        let fileURL = root.appendingPathComponent("File.swift")
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: 2, message: "early", sequence: 1
        )))
        let before = controller.diagnosticPresentationRevision

        _ = await controller.synchronize(
            syncRequest(fileURL: fileURL, version: 2),
            documentID: "document-a", documentRevision: 2
        )

        XCTAssertNotEqual(controller.diagnosticPresentationRevision, before)
        XCTAssertNotNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 2,
            serverKey: key
        ))
    }

    func testEditorPresentationUsesOnlyLatestServerGeneration() async throws {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        _ = await controller.synchronize(
            syncRequest(
                fileURL: root.appendingPathComponent("File.swift"), version: 3
            ),
            documentID: "document-a", documentRevision: 3
        )
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 2, version: 3, message: "old", sequence: 1
        )))
        controller.receive(.status(status(
            key: key, state: .running, generation: 3, sequence: 1
        )))
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 3, version: 3, message: "current", sequence: 2
        )))

        let snapshot = try XCTUnwrap(controller.diagnosticPresentationSnapshot(
            documentID: "document-a",
            fileURL: root.appendingPathComponent("File.swift"),
            documentRevision: 3, serverKey: key
        ))
        XCTAssertEqual(snapshot.generation, 3)
        XCTAssertEqual(snapshot.entries.map { $0.diagnostic.message }, ["current"])
    }

    func testRestartGenerationKeepsSynchronizedDocumentIdentity() async throws {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        let fileURL = root.appendingPathComponent("File.swift")
        _ = await controller.synchronize(
            syncRequest(fileURL: fileURL, version: 5),
            documentID: "document-a", documentRevision: 5
        )
        controller.receive(.status(status(
            key: key, state: .running, generation: 8, sequence: 1
        )))
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 8, version: 5, message: "after restart", sequence: 2
        )))

        let snapshot = try XCTUnwrap(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 5,
            serverKey: key
        ))
        XCTAssertEqual(snapshot.generation, 8)
        XCTAssertEqual(snapshot.entries.map { $0.diagnostic.message }, ["after restart"])
    }

    func testEditorPresentationRejectsRevisionBeyondLSPVersionDomain() {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        controller.receive(.diagnostics(diagnostics(
            key: serverKey(), generation: 1, version: Int.max,
            message: "saturated", sequence: 1
        )))

        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a",
            fileURL: root.appendingPathComponent("File.swift"),
            documentRevision: UInt64(Int.max) + 1, serverKey: serverKey()
        ))
    }

    func testClosingDocumentClearsOnlyMatchingServerPathDiagnostics() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        let fileURL = root.appendingPathComponent("File.swift")
        let otherURL = root.appendingPathComponent("Other.swift")
        _ = await controller.synchronize(
            syncRequest(fileURL: fileURL, version: 1),
            documentID: "document-a", documentRevision: 1
        )
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: 1, message: "closed", sequence: 1
        )))
        controller.receive(.diagnostics(LanguageServerDiagnosticsUpdate(
            key: key,
            event: LanguageServerDiagnosticEvent(
                filePath: otherURL.path,
                diagnostics: [.init(
                    line: 1, column: 1, severity: .warning, message: "retained"
                )]
            ),
            documentVersion: 1, generation: 1, sequence: 2
        )))

        let didClose = await controller.closeDocument(
            root: root, config: config, fileURL: fileURL
        )

        XCTAssertTrue(didClose)
        let closedDocumentURLs = await manager.closedDocumentURLs
        XCTAssertEqual(closedDocumentURLs, [fileURL])
        XCTAssertEqual(controller.diagnostics.map { $0.diagnostic.message }, ["retained"])
        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 1,
            serverKey: key
        ))
    }

    func testDocumentLifecycleFindsRemovedOrReconfiguredDocumentsOnly() {
        let first = LanguageServerOpenDocument(
            documentID: "first", fileURL: root.appendingPathComponent("First.swift"),
            root: root, config: config
        )
        let second = LanguageServerOpenDocument(
            documentID: "second", fileURL: root.appendingPathComponent("Second.swift"),
            root: root, config: config
        )
        let reconfigured = LanguageServerOpenDocument(
            documentID: "second", fileURL: second.fileURL, root: root,
            config: LanguageServerConfig(command: "other-lsp", args: [])
        )

        XCTAssertEqual(
            LanguageServerDocumentLifecycle.closedDocuments(
                previous: [first, second], current: [reconfigured]
            ),
            [first, second]
        )
        XCTAssertEqual(LanguageServerDocumentLifecycle.closedDocuments(
            previous: [first], current: [LanguageServerOpenDocument(
                documentID: "replacement-tab", fileURL: first.fileURL,
                root: first.root, config: first.config
            )]
        ), [first])
    }

    func testDocumentLifecycleDoesNotCloseOneOfTwoViewsOfSameDocument() {
        let firstView = LanguageServerOpenDocument(
            documentID: "shared", fileURL: root.appendingPathComponent("Shared.swift"),
            root: root, config: config
        )
        let secondView = LanguageServerOpenDocument(
            documentID: "shared", fileURL: firstView.fileURL,
            root: root, config: config
        )

        XCTAssertTrue(LanguageServerDocumentLifecycle.closedDocuments(
            previous: [firstView, secondView], current: [firstView]
        ).isEmpty)
    }

    func testStatusDiagnosticsAndLogsAreBounded() async {
        let controller = LanguageServerController(manager: LanguageServerManagerStub())
        await controller.waitUntilObservingEvents()
        for index in 0..<(LanguageServerController.maximumServers + 3) {
            let serviceRoot = URL(
                fileURLWithPath: "/tmp/lumen-lsp-\(index)", isDirectory: true
            )
            let serviceConfig = LanguageServerConfig(command: "lsp-\(index)", args: [])
            let key = LanguageServerInstanceKey(root: serviceRoot, config: serviceConfig)
            controller.receive(.status(LanguageServerStatus(
                key: key, root: serviceRoot, config: serviceConfig, state: .running,
                generation: 1, sequence: 1, capabilities: []
            )))
        }
        XCTAssertLessThanOrEqual(
            controller.statuses.count, LanguageServerController.maximumStatuses
        )

        let key = serverKey()
        let oversizedDiagnostics = (0..<(LanguageServerController.maximumDiagnostics + 5)).map {
            LanguageServerDiagnostic(
                line: $0 + 1, column: 1, severity: .warning, message: "warning"
            )
        }
        controller.receive(.diagnostics(LanguageServerDiagnosticsUpdate(
            key: key,
            event: LanguageServerDiagnosticEvent(
                filePath: root.appendingPathComponent("File.swift").path,
                diagnostics: oversizedDiagnostics
            ),
            documentVersion: 1, generation: 1, sequence: 1
        )))
        XCTAssertLessThanOrEqual(
            controller.diagnostics.count, LanguageServerController.maximumDiagnostics
        )

        for index in 0..<(LanguageServerController.maximumLogEntries + 10) {
            controller.receive(.log(log(
                key: key, generation: 1, text: "entry-\(index)",
                sequence: UInt64(index + 2)
            )))
        }
        XCTAssertLessThanOrEqual(
            controller.logEntries.count, LanguageServerController.maximumLogEntries
        )
        XCTAssertLessThanOrEqual(
            controller.logEntries.reduce(0) { $0 + $1.text.utf16.count },
            LanguageServerController.maximumLogCharacters
        )
        XCTAssertTrue(controller.wasLogTruncated)
    }

    func testInteractiveCompletionHoverDefinitionAndReferences() async {
        let manager = LanguageServerManagerStub()
        await manager.enqueueResult(LanguageServerInteractiveResult(completions: [
            LanguageCompletionItem(label: "print", detail: "function")
        ]))
        await manager.enqueueResult(LanguageServerInteractiveResult(
            hover: LanguageHover(text: "String")
        ))
        await manager.enqueueResult(LanguageServerInteractiveResult(locations: [
            LanguageLocation(filePath: "/tmp/definition.swift", line: 3, character: 4)
        ]))
        await manager.enqueueResult(LanguageServerInteractiveResult(locations: [
            LanguageLocation(filePath: "/tmp/reference.swift", line: 5, character: 6)
        ]))
        let controller = LanguageServerController(manager: manager)

        let completions = await controller.completion(request(.completion))
        let hover = await controller.hover(request(.hover))
        let definitions = await controller.definition(request(.definition))
        let references = await controller.references(request(.references))

        XCTAssertEqual(completions?.map(\.label), ["print"])
        XCTAssertEqual(hover?.text, "String")
        XCTAssertEqual(definitions?.first?.filePath, "/tmp/definition.swift")
        XCTAssertEqual(references?.first?.filePath, "/tmp/reference.swift")
        let performedRequests = await manager.performedRequests
        let methods = performedRequests.map(\.method)
        XCTAssertEqual(
            methods,
            [
                LanguageServerMethod.completion, .hover, .definition, .references
            ]
        )
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testTypedInteractiveOutcomesPreserveSuccessfulEmptyAndNonemptyResults() async {
        let manager = LanguageServerManagerStub()
        await manager.enqueueResult(LanguageServerInteractiveResult())
        await manager.enqueueResult(LanguageServerInteractiveResult(locations: []))
        await manager.enqueueResult(LanguageServerInteractiveResult(locations: [
            LanguageLocation(filePath: "/tmp/reference.swift", line: 5, character: 6)
        ]))
        let renameRequest = request(.rename, newName: "Renamed")
        await manager.setRenamePreview(LanguageServerRenamePreview(
            key: serverKey(), fileURL: URL(fileURLWithPath: renameRequest.filePath),
            position: LSPPosition(line: 0, character: 4), newName: "Renamed", edits: []
        ))
        var coordinated: [LanguageServerRenamePreview] = []
        let controller = LanguageServerController(manager: manager) { preview in
            coordinated.append(preview)
        }

        let hover = await controller.hoverOutcome(request(.hover))
        let definitions = await controller.definitionOutcome(request(.definition))
        let references = await controller.referencesOutcome(request(.references))
        let rename = await controller.renameOutcome(renameRequest)

        XCTAssertEqual(hover, .completed(nil))
        XCTAssertEqual(definitions, .completed([]))
        XCTAssertEqual(references, .completed([
            LanguageLocation(filePath: "/tmp/reference.swift", line: 5, character: 6)
        ]))
        XCTAssertEqual(rename, .completed(true))
        XCTAssertEqual(coordinated.count, 1)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testTypedInteractiveOutcomeDistinguishesApprovalAndProtocolFailure() async throws {
        let manager = LanguageServerManagerStub()
        let configuration = try await manager.approvalConfiguration(
            root: root, config: config
        )
        await manager.requireApproval(configuration)
        let controller = LanguageServerController(manager: manager)

        let awaitingApproval = await controller.hoverOutcome(request(.hover))

        XCTAssertEqual(awaitingApproval, .awaitingApproval)
        XCTAssertEqual(controller.pendingApproval?.configuration, configuration)
        XCTAssertNil(controller.issue)

        controller.declinePendingApproval()
        await manager.requireApproval(nil)
        let failure = LanguageServerClientError.responseError(
            code: -32_603, message: "hover unavailable"
        )
        await manager.setPerformError(failure)

        let failed = await controller.hoverOutcome(request(.hover))

        XCTAssertEqual(failed, .failed(failure.errorDescription ?? ""))
        XCTAssertEqual(controller.issue?.title, "Language Server Request Failed")
        XCTAssertEqual(controller.issue?.message, failure.errorDescription)
        XCTAssertNil(controller.pendingApproval)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testStoredTypedFailureRerendersAndUnknownCollisionStaysVerbatim() async {
        let manager = LanguageServerManagerStub()
        let failure = LanguageServerClientError.responseError(
            code: -32_603, message: "hover unavailable"
        )
        await manager.setPerformError(failure)
        let controller = LanguageServerController(manager: manager)

        _ = await controller.hoverOutcome(request(.hover))

        guard let issue = controller.issue else {
            return XCTFail("Expected a retained language-server issue")
        }
        XCTAssertEqual(
            EditorLocale.enUS.localizedLanguageServerIssue(issue.content),
            "Language server error -32603: hover unavailable"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageServerIssue(issue.content),
            "语言服务器错误 -32603：hover unavailable"
        )

        struct ExternalFailure: LocalizedError, Sendable {
            let errorDescription: String? = "The language server is not running."
        }
        await manager.setPerformError(ExternalFailure())
        _ = await controller.hoverOutcome(request(.hover))
        guard let collision = controller.issue else {
            return XCTFail("Expected a retained external issue")
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedLanguageServerIssue(collision.content),
            "The language server is not running."
        )
    }

    func testTypedInteractiveOutcomeTreatsClientCancellationAsCancelled() async {
        let manager = LanguageServerManagerStub()
        await manager.setPerformError(LanguageServerClientError.requestCancelled("hover"))
        let controller = LanguageServerController(manager: manager)

        let outcome = await controller.hoverOutcome(request(.hover))

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(controller.issue)
        XCTAssertNil(controller.pendingApproval)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testControllerForwardsTrustedExecutableSelectionAndDisplaysResolvedIdentity() async throws {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let selected = URL(fileURLWithPath: "/usr/bin/true")

        let authorized = try await controller.authorizeExecutable(selected)
        XCTAssertEqual(authorized, selected)
        let configuration = try await manager.approvalConfiguration(
            root: root, config: config
        )
        let request = LanguageServerApprovalRequest(configuration: configuration)

        XCTAssertTrue(request.identityDescription.contains(
            "Resolved executable: /usr/bin/true"
        ))
    }

    func testTypedInteractiveOutcomeCleansUpWhenCallingTaskIsCancelled() async {
        let manager = LanguageServerManagerStub()
        let gate = LanguageServerResultGate()
        await manager.setPerformGate(gate)
        let controller = LanguageServerController(manager: manager)
        let task = Task { @MainActor in
            await controller.hoverOutcome(request(.hover))
        }
        await gate.waitUntilRequested()

        task.cancel()
        await gate.resume(returning: LanguageServerInteractiveResult(
            hover: LanguageHover(text: "cancelled hover")
        ))
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(controller.interactiveResult)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
        XCTAssertNil(controller.activeInteractiveMethod)
    }

    func testTypedInteractiveOutcomeReportsSupersededRequestAsCancelled() async {
        let manager = LanguageServerManagerStub()
        let gate = LanguageServerResultGate()
        await manager.setPerformGate(gate)
        let controller = LanguageServerController(manager: manager)
        let firstTask = Task { @MainActor in
            await controller.hoverOutcome(request(.hover))
        }
        await gate.waitUntilRequested()

        await manager.setPerformGate(nil)
        await manager.enqueueResult(LanguageServerInteractiveResult(locations: [
            LanguageLocation(filePath: "/tmp/current.swift", line: 1, character: 2)
        ]))
        let current = await controller.definitionOutcome(request(.definition))
        await gate.resume(returning: LanguageServerInteractiveResult(
            hover: LanguageHover(text: "superseded hover")
        ))
        let superseded = await firstTask.value

        XCTAssertEqual(current, .completed([
            LanguageLocation(filePath: "/tmp/current.swift", line: 1, character: 2)
        ]))
        XCTAssertEqual(superseded, .cancelled)
        XCTAssertEqual(controller.interactiveResultMethod, .definition)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testTypedInteractiveOutcomeRejectsMismatchedMethodWithoutCallingManager() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)

        let outcome = await controller.hoverOutcome(request(.definition))

        XCTAssertEqual(
            outcome,
            .failed("Expected hover, received definition.")
        )
        XCTAssertEqual(controller.issue?.title, "Invalid Language Server Request")
        let performedRequests = await manager.performedRequests
        XCTAssertTrue(performedRequests.isEmpty)
    }

    func testTypedRenameOutcomeDistinguishesApprovalCancellationAndFailure() async throws {
        let manager = LanguageServerManagerStub()
        let renameRequest = request(.rename, newName: "Renamed")
        await manager.setRenamePreview(LanguageServerRenamePreview(
            key: serverKey(), fileURL: URL(fileURLWithPath: renameRequest.filePath),
            position: LSPPosition(line: 0, character: 4), newName: "Renamed", edits: []
        ))
        let configuration = try await manager.approvalConfiguration(
            root: root, config: config
        )
        await manager.requireApproval(configuration)
        var coordinatedCount = 0
        let controller = LanguageServerController(manager: manager) { _ in
            coordinatedCount += 1
        }

        let approval = await controller.renameOutcome(renameRequest)
        XCTAssertEqual(approval, .awaitingApproval)
        XCTAssertEqual(controller.pendingApproval?.configuration, configuration)

        await controller.confirmPendingApproval()
        XCTAssertEqual(coordinatedCount, 1)
        XCTAssertNil(controller.pendingApproval)

        await manager.setRenameError(LanguageServerClientError.requestCancelled("rename"))
        let cancelled = await controller.renameOutcome(renameRequest)
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertNil(controller.issue)

        let failure = LanguageServerClientError.invalidResponse("rename")
        await manager.setRenameError(failure)
        let failed = await controller.renameOutcome(renameRequest)
        XCTAssertEqual(failed, .failed(failure.errorDescription ?? ""))
        XCTAssertEqual(controller.issue?.title, "Could Not Preview Rename")
        XCTAssertEqual(controller.issue?.message, failure.errorDescription)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testInteractiveResultRetainsMethodServerIdentityAndRevisionForPanel() async {
        let manager = LanguageServerManagerStub()
        await manager.enqueueResult(LanguageServerInteractiveResult(locations: [
            LanguageLocation(filePath: "/tmp/first.swift", line: 2, character: 3),
            LanguageLocation(filePath: "/tmp/second.swift", line: 5, character: 8)
        ]))
        await manager.enqueueResult(LanguageServerInteractiveResult(
            hover: LanguageHover(text: "A value")
        ))
        let controller = LanguageServerController(manager: manager)

        let definitions = await controller.definition(request(.definition))

        XCTAssertEqual(definitions?.map(\.filePath), [
            "/tmp/first.swift", "/tmp/second.swift"
        ])
        XCTAssertEqual(controller.interactiveResultMethod, .definition)
        XCTAssertEqual(controller.interactiveResultKey, serverKey())
        XCTAssertEqual(controller.interactiveResult?.locations?.count, 2)
        let definitionRevision = controller.interactiveResultRevision

        _ = await controller.hover(request(.hover))

        XCTAssertEqual(controller.interactiveResultMethod, .hover)
        XCTAssertEqual(controller.interactiveResultKey, serverKey())
        XCTAssertEqual(controller.interactiveResult?.hover?.text, "A value")
        XCTAssertTrue(controller.interactiveResultRevision > definitionRevision)
    }

    func testEditorCompletionIsBoundedButDoesNotReplaceInspectorResult() async {
        let manager = LanguageServerManagerStub()
        await manager.enqueueResult(LanguageServerInteractiveResult(
            hover: LanguageHover(text: "Retained hover")
        ))
        await manager.enqueueResult(LanguageServerInteractiveResult(completions: [
            LanguageCompletionItem(label: "print", insertText: "print()")
        ]))
        let controller = LanguageServerController(manager: manager)
        _ = await controller.hover(request(.hover))
        let retainedRevision = controller.interactiveResultRevision

        let completions = await controller.completionForEditor(request(.completion))

        XCTAssertEqual(completions?.map(\.label), ["print"])
        XCTAssertEqual(controller.interactiveResult?.hover?.text, "Retained hover")
        XCTAssertEqual(controller.interactiveResultMethod, .hover)
        XCTAssertEqual(controller.interactiveResultRevision, retainedRevision)
    }

    func testEditorCompletionApprovalReplayCanBeTakenWithoutPublishingPanelResult() async throws {
        let manager = LanguageServerManagerStub()
        let configuration = try await manager.approvalConfiguration(
            root: root, config: config
        )
        await manager.requireApproval(configuration)
        await manager.enqueueResult(LanguageServerInteractiveResult(completions: [
            LanguageCompletionItem(label: "print")
        ]))
        let controller = LanguageServerController(manager: manager)

        let first = await controller.completionForEditor(request(.completion))
        XCTAssertNil(first)
        XCTAssertEqual(controller.pendingApproval?.configuration, configuration)
        await controller.confirmPendingApproval()

        XCTAssertEqual(controller.takeEditorCompletionResult()?.map(\.label), ["print"])
        XCTAssertNil(controller.takeEditorCompletionResult())
        XCTAssertNil(controller.interactiveResult)
    }

    func testInteractiveResultIsBoundedForPanelAndCanBeCleared() async {
        let manager = LanguageServerManagerStub()
        let oversized = String(
            repeating: "x",
            count: LSPProtocolLimits.maximumExternalDetailCharacters + 100
        )
        let completions = (0..<(LanguageServerController.maximumCompletionItems + 10)).map {
            LanguageCompletionItem(
                label: "item-\($0)-" + oversized,
                detail: oversized, documentation: oversized, insertText: oversized
            )
        }
        await manager.enqueueResult(LanguageServerInteractiveResult(
            completions: completions
        ))
        let controller = LanguageServerController(manager: manager)

        _ = await controller.completion(request(.completion))

        let retained = controller.interactiveResult?.completions ?? []
        XCTAssertEqual(retained.count, LanguageServerController.maximumCompletionItems)
        XCTAssertTrue(retained.allSatisfy {
            $0.label.utf16.count <= LSPProtocolLimits.maximumExternalDetailCharacters
                && ($0.detail?.utf16.count ?? 0)
                    <= LSPProtocolLimits.maximumExternalDetailCharacters
                && ($0.documentation?.utf16.count ?? 0)
                    <= LSPProtocolLimits.maximumExternalDetailCharacters
                && ($0.insertText?.utf16.count ?? 0)
                    <= LSPProtocolLimits.maximumExternalDetailCharacters
        })

        controller.clearInteractiveResult()
        XCTAssertNil(controller.interactiveResult)
        XCTAssertNil(controller.interactiveResultMethod)
        XCTAssertNil(controller.interactiveResultKey)
    }

    func testStoppingResultServerClearsRetainedInteractiveResult() async {
        let manager = LanguageServerManagerStub()
        await manager.enqueueResult(LanguageServerInteractiveResult(
            hover: LanguageHover(text: "Current result")
        ))
        let controller = LanguageServerController(manager: manager)
        _ = await controller.hover(request(.hover))
        XCTAssertNotNil(controller.interactiveResult)

        await controller.stop(serverKey())

        XCTAssertNil(controller.interactiveResult)
        XCTAssertNil(controller.interactiveResultMethod)
        XCTAssertNil(controller.interactiveResultKey)
    }

    func testNewServerGenerationClearsRetainedInteractiveResult() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        controller.receive(.status(status(
            key: key, state: .running, generation: 4, sequence: 1
        )))
        await manager.enqueueResult(LanguageServerInteractiveResult(
            hover: LanguageHover(text: "Generation four")
        ))
        _ = await controller.hover(request(.hover))
        XCTAssertNotNil(controller.interactiveResult)

        controller.receive(.status(status(
            key: key, state: .starting, generation: 5, sequence: 1
        )))

        XCTAssertNil(controller.interactiveResult)
        XCTAssertNil(controller.interactiveResultMethod)
        XCTAssertNil(controller.interactiveResultKey)
    }

    func testServerRetentionEvictionClearsItsRetainedInteractiveResult() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let resultKey = serverKey()
        controller.receive(.status(status(
            key: resultKey, state: .running, generation: 1, sequence: 1
        )))
        await manager.enqueueResult(LanguageServerInteractiveResult(
            hover: LanguageHover(text: "Evict me")
        ))
        _ = await controller.hover(request(.hover))

        for index in 0..<LanguageServerController.maximumServers {
            let serviceRoot = URL(
                fileURLWithPath: "/tmp/lumen-lsp-eviction-\(index)",
                isDirectory: true
            )
            let serviceConfig = LanguageServerConfig(
                command: "lsp-eviction-\(index)", args: []
            )
            let key = LanguageServerInstanceKey(root: serviceRoot, config: serviceConfig)
            controller.receive(.status(LanguageServerStatus(
                key: key, root: serviceRoot, config: serviceConfig, state: .running,
                generation: 1, sequence: 1, capabilities: []
            )))
        }

        XCTAssertNil(controller.status(for: resultKey))
        XCTAssertNil(controller.interactiveResult)
        XCTAssertNil(controller.interactiveResultMethod)
        XCTAssertNil(controller.interactiveResultKey)
    }

    func testDocumentFormattingForwardsResultAndApprovalThroughSameManager() async throws {
        let manager = LanguageServerManagerStub()
        let request = LanguageServerRequest(
            root: root.path,
            config: config,
            content: "let value=1",
            filePath: root.appendingPathComponent("File.swift").path,
            languageId: "swift"
        )
        let result = LanguageServerResult(
            edits: [LanguageServerTextEdit(
                startLine: 0, startCharacter: 9,
                endLine: 0, endCharacter: 9,
                newText: " "
            )],
            diagnostics: []
        )
        await manager.enqueueFormattingResult(result)
        let controller = LanguageServerController(manager: manager)

        let formatted = try await controller.formatForDocument(request)
        XCTAssertEqual(formatted, result)
        let formattedRequests = await manager.formattedRequests
        XCTAssertEqual(formattedRequests, [request])

        let approval = try await manager.approvalConfiguration(
            root: root, config: config
        )
        await controller.approveForDocumentFormatting(approval)
        let approvals = await manager.approvedConfigurations
        XCTAssertEqual(approvals, [approval])
    }

    func testDocumentFormattingPropagatesExactApprovalForOwningCoordinator() async throws {
        let manager = LanguageServerManagerStub()
        let request = LanguageServerRequest(
            root: root.path,
            config: config,
            content: "let value=1",
            filePath: root.appendingPathComponent("File.swift").path,
            languageId: "swift"
        )
        let approval = try await manager.approvalConfiguration(
            root: root, config: config
        )
        await manager.requireApproval(approval)
        let controller = LanguageServerController(manager: manager)

        do {
            _ = try await controller.formatForDocument(request)
            XCTFail("Expected exact language-server approval")
        } catch let LanguageServerClientError.approvalRequired(configuration) {
            XCTAssertEqual(configuration, approval)
        }
        XCTAssertNil(
            controller.pendingApproval,
            "The formatter coordinator owns this request and its replay state"
        )
        await controller.approveForDocumentFormatting(approval)
        let result = try await controller.formatForDocument(request)
        XCTAssertEqual(result, LanguageServerResult(edits: [], diagnostics: []))
    }

    func testGenericPerformRoutesRenameOnlyThroughPreviewCoordinator() async {
        let manager = LanguageServerManagerStub()
        let renameRequest = request(.rename, newName: "Renamed")
        let preview = LanguageServerRenamePreview(
            key: serverKey(),
            fileURL: URL(fileURLWithPath: renameRequest.filePath),
            position: LSPPosition(line: renameRequest.line, character: renameRequest.character),
            newName: "Renamed",
            edits: [LanguageRenameEdit(
                filePath: renameRequest.filePath, startLine: 1, startCharacter: 2,
                endLine: 1, endCharacter: 5, newText: "Renamed"
            )]
        )
        await manager.setRenamePreview(preview)
        var coordinated: [LanguageServerRenamePreview] = []
        let controller = LanguageServerController(manager: manager) { received in
            coordinated.append(received)
        }

        let genericResult = await controller.perform(renameRequest)

        XCTAssertNil(genericResult)
        XCTAssertEqual(coordinated, [preview])
        let renameRequests = await manager.renameRequests
        let performedRequests = await manager.performedRequests
        XCTAssertEqual(renameRequests, [renameRequest])
        XCTAssertTrue(performedRequests.isEmpty)
        XCTAssertNil(controller.interactiveResult)
    }

    func testCoordinatorFailureIsPresentedAndPreviewIsNeverAppliedLocally() async {
        struct CoordinatorFailure: Error, LocalizedError {
            var errorDescription: String? { "conflicting dirty document" }
        }
        let manager = LanguageServerManagerStub()
        let renameRequest = request(.rename, newName: "Other")
        await manager.setRenamePreview(LanguageServerRenamePreview(
            key: serverKey(), fileURL: URL(fileURLWithPath: renameRequest.filePath),
            position: LSPPosition(line: 0, character: 0), newName: "Other", edits: []
        ))
        let controller = LanguageServerController(manager: manager) { _ in
            throw CoordinatorFailure()
        }

        let didCoordinate = await controller.rename(renameRequest)
        XCTAssertFalse(didCoordinate)
        XCTAssertEqual(controller.issue?.title, "Could Not Preview Rename")
        XCTAssertEqual(controller.issue?.message, "conflicting dirty document")
        XCTAssertNil(controller.interactiveResult)
    }

    func testCancelDiscardsLateInteractiveResultAndCancelsManagerKey() async {
        let manager = LanguageServerManagerStub()
        let gate = LanguageServerResultGate()
        await manager.setPerformGate(gate)
        let controller = LanguageServerController(manager: manager)
        let interactive = request(.hover)
        let task = Task { @MainActor in await controller.hover(interactive) }
        await gate.waitUntilRequested()

        await controller.cancel()
        await gate.resume(returning: LanguageServerInteractiveResult(
            hover: LanguageHover(text: "late hover")
        ))
        let value = await task.value

        XCTAssertNil(value)
        XCTAssertNil(controller.interactiveResult)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
        let cancelledKeys = await manager.cancelledKeys
        XCTAssertEqual(cancelledKeys, [serverKey()])
    }

    func testTypedInteractiveOutcomeReportsExplicitCancelForLateResult() async {
        let manager = LanguageServerManagerStub()
        let gate = LanguageServerResultGate()
        await manager.setPerformGate(gate)
        let controller = LanguageServerController(manager: manager)
        let task = Task { @MainActor in
            await controller.hoverOutcome(request(.hover))
        }
        await gate.waitUntilRequested()

        await controller.cancel()
        await gate.resume(returning: LanguageServerInteractiveResult(
            hover: LanguageHover(text: "late hover")
        ))

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(controller.interactiveResult)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testStopRestartAndExplicitCancelForwardExactKey() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()

        await controller.stop(key)
        let didRestart = await controller.restart(key)
        XCTAssertTrue(didRestart)
        await controller.cancel(key)

        let stoppedKeys = await manager.stoppedKeys
        let restartedKeys = await manager.restartedKeys
        let cancelledKeys = await manager.cancelledKeys
        XCTAssertEqual(stoppedKeys, [key])
        XCTAssertEqual(restartedKeys, [key])
        XCTAssertEqual(cancelledKeys, [key])
    }

    func testStopAllForwardsWithoutStatusesAndClearsPresentationState() async throws {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        let fileURL = root.appendingPathComponent("File.swift")
        _ = await controller.synchronize(
            syncRequest(fileURL: fileURL, version: 4),
            documentID: "document-a", documentRevision: 4
        )
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 1, version: 4, message: "stale", sequence: 1
        )))
        let configuration = try await manager.approvalConfiguration(
            root: root, config: config
        )
        await manager.requireApproval(configuration)
        _ = await controller.start(root: root, config: config)

        XCTAssertTrue(controller.statuses.isEmpty)
        XCTAssertNotNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 4,
            serverKey: key
        ))
        XCTAssertFalse(controller.diagnostics.isEmpty)
        XCTAssertNotNil(controller.pendingApproval)

        await controller.stopAll()

        let stopAllCallCount = await manager.stopAllCallCount
        let stoppedKeys = await manager.stoppedKeys
        XCTAssertEqual(stopAllCallCount, 1)
        XCTAssertTrue(stoppedKeys.isEmpty)
        XCTAssertTrue(controller.diagnostics.isEmpty)
        XCTAssertNil(controller.diagnosticPresentationSnapshot(
            documentID: "document-a", fileURL: fileURL, documentRevision: 4,
            serverKey: key
        ))
        XCTAssertNil(controller.pendingApproval)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testStopInvalidatesQueuedEventsFromStoppedGeneration() async {
        let manager = LanguageServerManagerStub()
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        controller.receive(.status(status(
            key: key, state: .running, generation: 8, sequence: 1
        )))
        controller.receive(.log(log(
            key: key, generation: 8, text: "retained before stop", sequence: 2
        )))
        controller.receive(.diagnostics(diagnostics(
            key: key, generation: 8, version: 1,
            message: "retained before stop", sequence: 3
        )))

        await controller.stop(key)
        controller.receive(.log(log(
            key: key, generation: 8, text: "queued before stop", sequence: 4
        )))
        controller.receive(.status(status(
            key: key, state: .starting, generation: 9
        )))

        XCTAssertTrue(controller.logs(for: key).isEmpty)
        XCTAssertTrue(controller.diagnostics(for: key).isEmpty)
        XCTAssertEqual(controller.status(for: key)?.generation, 9)
    }

    func testInteractiveResultIsDroppedWhenServerGenerationChanges() async {
        let manager = LanguageServerManagerStub()
        let gate = LanguageServerResultGate()
        await manager.setPerformGate(gate)
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        controller.receive(.status(status(
            key: key, state: .running, generation: 2, sequence: 1
        )))
        let task = Task { @MainActor in await controller.hover(request(.hover)) }
        await gate.waitUntilRequested()

        controller.receive(.status(status(
            key: key, state: .starting, generation: 3, sequence: 1
        )))
        await gate.resume(returning: LanguageServerInteractiveResult(
            hover: LanguageHover(text: "stale hover")
        ))

        let value = await task.value
        XCTAssertNil(value)
        XCTAssertNil(controller.interactiveResult)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testTypedInteractiveOutcomeReportsGenerationStaleResultAsCancelled() async {
        let manager = LanguageServerManagerStub()
        let gate = LanguageServerResultGate()
        await manager.setPerformGate(gate)
        let controller = LanguageServerController(manager: manager)
        let key = serverKey()
        controller.receive(.status(status(
            key: key, state: .running, generation: 2, sequence: 1
        )))
        let task = Task { @MainActor in
            await controller.hoverOutcome(request(.hover))
        }
        await gate.waitUntilRequested()

        controller.receive(.status(status(
            key: key, state: .starting, generation: 3, sequence: 1
        )))
        await gate.resume(returning: LanguageServerInteractiveResult(
            hover: LanguageHover(text: "stale hover")
        ))

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(controller.interactiveResult)
        XCTAssertFalse(controller.isInteractiveRequestRunning)
    }

    func testLifecycleFailuresAreAccessibleAndDismissible() async {
        let manager = LanguageServerManagerStub()
        await manager.setRestartError(LanguageServerClientError.stopped)
        let controller = LanguageServerController(manager: manager)

        let didRestart = await controller.restart(serverKey())
        XCTAssertFalse(didRestart)
        XCTAssertEqual(controller.issue?.title, "Could Not Restart Language Server")
        let expectedMessage = LanguageServerClientError.stopped.errorDescription
        XCTAssertEqual(controller.issue?.message, expectedMessage)
        controller.dismissIssue()
        XCTAssertNil(controller.issue)
    }

    func testExactApprovalIsPresentedAndConfirmationReplaysStart() async throws {
        let manager = LanguageServerManagerStub()
        let configuration = try await manager.approvalConfiguration(
            root: root, config: config
        )
        await manager.requireApproval(configuration)
        let controller = LanguageServerController(manager: manager)

        let first = await controller.start(root: root, config: config)
        XCTAssertNil(first)
        XCTAssertEqual(controller.pendingApproval?.configuration, configuration)
        let startsBeforeApproval = await manager.successfulStartCount
        XCTAssertEqual(startsBeforeApproval, 0)

        await controller.confirmPendingApproval()

        XCTAssertNil(controller.pendingApproval)
        let approved = await manager.approvedConfigurations
        let startsAfterApproval = await manager.successfulStartCount
        XCTAssertEqual(approved, [configuration])
        XCTAssertEqual(startsAfterApproval, 1)
    }

    func testPanelPublishesCompleteAccessibilityContract() {
        XCTAssertEqual(LanguageServerPanelView.Accessibility.panel, "Language Servers")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.summary, "Language Server Summary")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.services, "Language Server Services")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.selectedStatus, "Selected Language Server Status")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.capabilities, "Language Server Capabilities")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.diagnostics, "Language Server Diagnostics")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.log, "Language Server Log")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.statusBar, "Language Server Panel Status")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.restart, "Restart Language Server")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.stop, "Stop Language Server")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.clearLog, "Clear Language Server Log")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.close, "Close Language Server Panel")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.error, "Language Server Error")
        XCTAssertEqual(LanguageServerPanelView.Accessibility.dismissError, "Dismiss Language Server Error")
        XCTAssertEqual(
            LanguageServerPanelView.Accessibility.interactiveResults,
            "Language Server Interactive Results"
        )
        XCTAssertEqual(
            LanguageServerPanelView.Accessibility.hoverResult,
            "Language Server Hover Result"
        )
        XCTAssertEqual(
            LanguageServerPanelView.Accessibility.clearInteractiveResult,
            "Clear Language Server Interactive Result"
        )
        XCTAssertEqual(
            LanguageServerPanelView.Accessibility.approval,
            "Review the exact language server command before allowing it."
        )
    }

    func testLanguageServerNavigationTargetConvertsCoordinatesAndRejectsInvalidPaths() {
        let target = LanguageServerNavigationTarget(LanguageLocation(
            filePath: "/workspace/Sources/File.swift", line: 3, character: 7
        ))
        XCTAssertEqual(target?.url.path, "/workspace/Sources/File.swift")
        XCTAssertEqual(target?.line, 4)
        XCTAssertEqual(target?.column, 8)

        let clamped = LanguageServerNavigationTarget(LanguageLocation(
            filePath: "/workspace/File.swift", line: -4, character: -2
        ))
        XCTAssertEqual(clamped?.line, 1)
        XCTAssertEqual(clamped?.column, 1)

        let saturated = LanguageServerNavigationTarget(LanguageLocation(
            filePath: "/workspace/File.swift", line: Int.max, character: Int.max
        ))
        XCTAssertEqual(saturated?.line, Int.max)
        XCTAssertEqual(saturated?.column, Int.max)
        XCTAssertNil(LanguageServerNavigationTarget(LanguageLocation(
            filePath: "relative/File.swift", line: 0, character: 0
        )))
        XCTAssertNil(LanguageServerNavigationTarget(LanguageLocation(
            filePath: "", line: 0, character: 0
        )))
    }

    func testInteractiveResultPresentationNeverDropsMultipleDefinitions() {
        let none = LanguageServerInteractiveResult(locations: [])
        let one = LanguageServerInteractiveResult(locations: [
            LanguageLocation(filePath: "/workspace/One.swift", line: 0, character: 0)
        ])
        let several = LanguageServerInteractiveResult(locations: [
            LanguageLocation(filePath: "/workspace/One.swift", line: 0, character: 0),
            LanguageLocation(filePath: "/workspace/Two.swift", line: 2, character: 4)
        ])

        XCTAssertTrue(LanguageServerResultPresentation.requiresPanel(
            method: .definition, result: none
        ))
        XCTAssertFalse(LanguageServerResultPresentation.requiresPanel(
            method: .definition, result: one
        ))
        XCTAssertTrue(LanguageServerResultPresentation.requiresPanel(
            method: .definition, result: several
        ))
        XCTAssertTrue(LanguageServerResultPresentation.requiresPanel(
            method: .references, result: several
        ))
        XCTAssertTrue(LanguageServerResultPresentation.requiresPanel(
            method: .hover, result: LanguageServerInteractiveResult()
        ))
        XCTAssertTrue(LanguageServerResultPresentation.requiresPanel(
            method: .completion, result: LanguageServerInteractiveResult()
        ))
        XCTAssertFalse(LanguageServerResultPresentation.requiresPanel(
            method: .rename, result: LanguageServerInteractiveResult()
        ))
    }

    private func serverKey() -> LanguageServerInstanceKey {
        LanguageServerInstanceKey(root: root, config: config)
    }

    private func status(
        key: LanguageServerInstanceKey,
        state: LanguageServerClientState,
        generation: UInt64,
        sequence: UInt64 = 1,
        capabilities: [String] = []
    ) -> LanguageServerStatus {
        LanguageServerStatus(
            key: key, root: root, config: config, state: state,
            generation: generation, sequence: sequence, capabilities: capabilities
        )
    }

    private func log(
        key: LanguageServerInstanceKey, generation: UInt64, text: String,
        sequence: UInt64 = 2
    ) -> LanguageServerLogEntry {
        LanguageServerLogEntry(
            key: key, root: root, stream: .server, level: .info,
            text: text, generation: generation, sequence: sequence
        )
    }

    private func diagnostics(
        key: LanguageServerInstanceKey, generation: UInt64, version: Int?, message: String,
        sequence: UInt64 = 3
    ) -> LanguageServerDiagnosticsUpdate {
        LanguageServerDiagnosticsUpdate(
            key: key,
            event: LanguageServerDiagnosticEvent(
                filePath: root.appendingPathComponent("File.swift").path,
                diagnostics: [LanguageServerDiagnostic(
                    line: 1, column: 2, severity: .error, message: message
                )]
            ),
            documentVersion: version, generation: generation, sequence: sequence
        )
    }

    private func request(
        _ method: LanguageServerMethod, newName: String? = nil
    ) -> LanguageServerInteractiveRequest {
        LanguageServerInteractiveRequest(
            root: root.path, config: config, content: "let value = 1",
            filePath: root.appendingPathComponent("File.swift").path,
            languageId: "swift", method: method, line: 0, character: 4,
            newName: newName
        )
    }

    private func syncRequest(fileURL: URL, version: Int) -> LanguageServerSyncRequest {
        LanguageServerSyncRequest(
            root: root.path, config: config, content: "let value = 1",
            filePath: fileURL.path, languageId: "swift", version: version
        )
    }

    private func drainMainActorTasks() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }
}

private actor LanguageServerManagerStub: LanguageServerManaging {
    private var continuation: AsyncStream<LanguageServerEvent>.Continuation?
    private var queuedEvents: [LanguageServerEvent] = []
    private var eventStreamTerminated = false

    private(set) var stoppedKeys: [LanguageServerInstanceKey] = []
    private(set) var stopAllCallCount = 0
    private(set) var restartedKeys: [LanguageServerInstanceKey] = []
    private(set) var cancelledKeys: [LanguageServerInstanceKey] = []
    private(set) var closedDocumentURLs: [URL] = []
    private(set) var performedRequests: [LanguageServerInteractiveRequest] = []
    private(set) var renameRequests: [LanguageServerInteractiveRequest] = []
    private(set) var formattedRequests: [LanguageServerRequest] = []

    private var results: [LanguageServerInteractiveResult] = []
    private var formattingResults: [LanguageServerResult] = []
    private var preview: LanguageServerRenamePreview?
    private var restartError: (any Error)?
    private var performError: (any Error)?
    private var renameError: (any Error)?
    private var performGate: LanguageServerResultGate?
    private(set) var approvedConfigurations: [ToolExecutionConfiguration] = []
    private var requiredApproval: ToolExecutionConfiguration?
    private(set) var successfulStartCount = 0

    func approvalConfiguration(
        root: URL, config: LanguageServerConfig
    ) async throws -> ToolExecutionConfiguration {
        try ToolExecutionConfiguration(
            kind: .languageServer, executable: "true", args: config.args, cwd: root,
            authorizedRoot: root, resolver: ToolExecutableResolver(allowedExecutables: [
                "true": URL(fileURLWithPath: "/usr/bin/true")
            ])
        )
    }

    func approve(_ configuration: ToolExecutionConfiguration) async {
        approvedConfigurations.append(configuration)
    }

    func authorizeExecutable(_ url: URL) async throws -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func revokeAllExecutables() async {}

    func requireApproval(_ configuration: ToolExecutionConfiguration?) {
        requiredApproval = configuration
    }

    func events() -> AsyncStream<LanguageServerEvent> {
        let pair = AsyncStream<LanguageServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            guard let manager = self else { return }
            Task { await manager.recordEventStreamTermination() }
        }
        let queued = queuedEvents
        queuedEvents = []
        queued.forEach { pair.continuation.yield($0) }
        return pair.stream
    }

    func emit(_ event: LanguageServerEvent) {
        if let continuation {
            continuation.yield(event)
        } else {
            queuedEvents.append(event)
        }
    }

    func waitUntilEventStreamTerminated() async -> Bool {
        for _ in 0..<100 {
            if eventStreamTerminated { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return eventStreamTerminated
    }

    private func recordEventStreamTermination() { eventStreamTerminated = true }

    func enqueueResult(_ result: LanguageServerInteractiveResult) {
        results.append(result)
    }

    func enqueueFormattingResult(_ result: LanguageServerResult) {
        formattingResults.append(result)
    }

    func setRenamePreview(_ preview: LanguageServerRenamePreview) {
        self.preview = preview
    }

    func setRestartError(_ error: (any Error)?) { restartError = error }
    func setPerformError(_ error: (any Error)?) { performError = error }
    func setRenameError(_ error: (any Error)?) { renameError = error }
    func setPerformGate(_ gate: LanguageServerResultGate?) { performGate = gate }

    func start(
        root: URL, config: LanguageServerConfig
    ) async throws -> LanguageServerInstanceKey {
        if let requiredApproval, !approvedConfigurations.contains(requiredApproval) {
            throw LanguageServerClientError.approvalRequired(requiredApproval)
        }
        successfulStartCount += 1
        return LanguageServerInstanceKey(root: root, config: config)
    }

    func synchronize(
        _ request: LanguageServerSyncRequest
    ) async throws -> LanguageServerInstanceKey {
        LanguageServerInstanceKey(
            root: URL(fileURLWithPath: request.root, isDirectory: true), config: request.config
        )
    }

    func closeDocument(
        root: URL, config: LanguageServerConfig, fileURL: URL
    ) async throws { closedDocumentURLs.append(fileURL) }

    func perform(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerInteractiveResult {
        performedRequests.append(request)
        if let requiredApproval, !approvedConfigurations.contains(requiredApproval) {
            throw LanguageServerClientError.approvalRequired(requiredApproval)
        }
        if let performError { throw performError }
        if let performGate { return try await performGate.wait() }
        guard !results.isEmpty else { return LanguageServerInteractiveResult() }
        return results.removeFirst()
    }

    func format(
        _ request: LanguageServerRequest
    ) async throws -> LanguageServerResult {
        formattedRequests.append(request)
        if let requiredApproval, !approvedConfigurations.contains(requiredApproval) {
            throw LanguageServerClientError.approvalRequired(requiredApproval)
        }
        guard !formattingResults.isEmpty else {
            return LanguageServerResult(edits: [], diagnostics: [])
        }
        return formattingResults.removeFirst()
    }

    func renamePreview(
        _ request: LanguageServerInteractiveRequest
    ) async throws -> LanguageServerRenamePreview {
        renameRequests.append(request)
        if let requiredApproval, !approvedConfigurations.contains(requiredApproval) {
            throw LanguageServerClientError.approvalRequired(requiredApproval)
        }
        if let renameError { throw renameError }
        guard let preview else { throw LanguageServerClientError.invalidResponse("rename") }
        return preview
    }

    func stop(_ key: LanguageServerInstanceKey) async { stoppedKeys.append(key) }

    func stopAll() async { stopAllCallCount += 1 }

    func restart(_ key: LanguageServerInstanceKey) async throws {
        restartedKeys.append(key)
        if let restartError { throw restartError }
    }

    func cancel(_ key: LanguageServerInstanceKey) async { cancelledKeys.append(key) }
}

private actor LanguageServerResultGate: Sendable {
    private var continuation: CheckedContinuation<LanguageServerInteractiveResult, any Error>?
    private var requested = false
    private var requestedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> LanguageServerInteractiveResult {
        requested = true
        let waiters = requestedWaiters
        requestedWaiters = []
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestedWaiters.append($0) }
    }

    func resume(returning value: LanguageServerInteractiveResult) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
