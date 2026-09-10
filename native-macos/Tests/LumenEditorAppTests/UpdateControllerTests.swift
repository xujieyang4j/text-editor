import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testCheckPublishesResultAndOpensOnlyAfterExplicitConfirmation() async {
        let release = URL(string: "https://github.com/xujieyang4j/text-editor/releases/tag/v2.0.0")!
        var opened: URL?
        let controller = UpdateController(
            currentVersion: "1.0.0",
            checker: { version in
                UpdateInformation(
                    currentVersion: version, latestVersion: "2.0.0",
                    releaseURL: release, isAvailable: true
                )
            },
            openRelease: { opened = $0; return true }
        )
        await controller.presentAndCheck()
        XCTAssertTrue(controller.isPresented)
        XCTAssertFalse(controller.isChecking)
        XCTAssertEqual(controller.result?.latestVersion, "2.0.0")
        controller.requestOpenReleasePage()
        XCTAssertNotNil(controller.pendingReleaseConfirmation)
        XCTAssertNil(opened)
        XCTAssertTrue(controller.confirmOpenReleasePage())
        XCTAssertEqual(opened, release)
        XCTAssertNil(controller.pendingReleaseConfirmation)
        XCTAssertFalse(controller.confirmOpenReleasePage())
        XCTAssertEqual(opened, release)
    }

    func testCancellingReleaseConfirmationDoesNotOpenURL() async {
        let release = URL(string: "https://github.com/xujieyang4j/text-editor/releases/tag/v2.0.0")!
        var openCount = 0
        let controller = UpdateController(
            checker: { version in
                UpdateInformation(
                    currentVersion: version, latestVersion: "2.0.0",
                    releaseURL: release, isAvailable: true
                )
            },
            openRelease: { _ in openCount += 1; return true }
        )
        await controller.presentAndCheck()

        controller.requestOpenReleasePage()
        controller.cancelOpenReleasePage()

        XCTAssertNil(controller.pendingReleaseConfirmation)
        XCTAssertFalse(controller.confirmOpenReleasePage())
        XCTAssertEqual(openCount, 0)
    }

    func testResultChangeInvalidatesPendingConfirmation() async {
        let first = URL(string: "https://github.com/xujieyang4j/text-editor/releases/tag/v2.0.0")!
        let second = URL(string: "https://github.com/xujieyang4j/text-editor/releases/tag/v3.0.0")!
        let sequence = UpdateInformationSequence([
            UpdateInformation(
                currentVersion: "1.0.0", latestVersion: "2.0.0",
                releaseURL: first, isAvailable: true
            ),
            UpdateInformation(
                currentVersion: "1.0.0", latestVersion: "3.0.0",
                releaseURL: second, isAvailable: true
            )
        ])
        var opened: URL?
        let controller = UpdateController(
            checker: { _ in await sequence.next() },
            openRelease: { opened = $0; return true }
        )
        await controller.presentAndCheck()
        controller.requestOpenReleasePage()

        await controller.presentAndCheck()

        XCTAssertNil(controller.pendingReleaseConfirmation)
        XCTAssertFalse(controller.confirmOpenReleasePage())
        XCTAssertNil(opened)
    }

    func testUnsafeReleaseURLIsRejectedAtFinalOpenBoundary() async {
        let unsafe = URL(string: "https://example.com/releases/v2.0.0")!
        var openCount = 0
        let controller = UpdateController(
            checker: { version in
                UpdateInformation(
                    currentVersion: version, latestVersion: "2.0.0",
                    releaseURL: unsafe, isAvailable: true
                )
            },
            openRelease: { _ in openCount += 1; return true }
        )
        await controller.presentAndCheck()
        controller.requestOpenReleasePage()

        XCTAssertFalse(controller.confirmOpenReleasePage())
        XCTAssertEqual(openCount, 0)
        XCTAssertNil(controller.pendingReleaseConfirmation)
    }

    func testCompletedCommandReportsVisiblePanelInsteadOfPlainExecution() async throws {
        let controller = UpdateController(
            currentVersion: "1.0.0",
            checker: { version in
                UpdateInformation(
                    currentVersion: version, latestVersion: "2.0.0",
                    releaseURL: nil, isAvailable: true
                )
            },
            openRelease: { _ in false }
        )
        let router = CommandRouter()
        _ = try controller.registerCommand(on: router)

        let result = await router.execute("check-for-updates", context: .init())

        guard case .visiblePanel(commandID: "check-for-updates") = result else {
            return XCTFail("A completed update check should surface the update panel")
        }
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.result?.latestVersion, "2.0.0")
    }

    func testFailureCanBeDismissedAndCommandIsDisabledWhileChecking() async throws {
        let gate = AsyncGate()
        let controller = UpdateController(
            currentVersion: "1.0.0",
            checker: { _ in
                await gate.wait()
                throw UpdateCheckError.invalidResponse
            },
            openRelease: { _ in false }
        )
        let router = CommandRouter()
        _ = try controller.registerCommand(on: router)
        let task = Task { await router.execute("check-for-updates", context: .init()) }
        await Task.yield()
        XCTAssertTrue(controller.isChecking)
        XCTAssertEqual(
            router.status(for: "check-for-updates", context: .init()),
            .disabled(.handler(reason: "An update check is already running"))
        )
        await gate.open()
        let result = await task.value
        guard case let .failed(commandID, error) = result else {
            return XCTFail("A failed update check must report failure")
        }
        XCTAssertEqual(commandID, "check-for-updates")
        XCTAssertEqual(error.localizedDescription, UpdateCheckError.invalidResponse.localizedDescription)
        XCTAssertEqual(controller.issue?.titleContent, .couldNotCheckForUpdates)
        XCTAssertEqual(controller.issue?.content, .app(.updateInvalidResponse))
        if let signal = error as? CommandHandlerSignal,
           case let .failedPresentation(.app(content)) = signal {
            XCTAssertEqual(
                EditorLocale.zhCN.localizedPresentation(content),
                "更新服务返回了无效响应。"
            )
        } else {
            XCTFail("Update failures must retain typed command presentation")
        }
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
    }

    func testCancellationRemainsANoChangeCommandResult() async throws {
        let controller = UpdateController(
            currentVersion: "1.0.0",
            checker: { _ in throw CancellationError() },
            openRelease: { _ in false }
        )
        let router = CommandRouter()
        _ = try controller.registerCommand(on: router)

        let result = await router.execute("check-for-updates", context: .init())

        guard case let .noChange(commandID) = result else {
            return XCTFail("Cancellation must not be reported as a transport failure")
        }
        XCTAssertEqual(commandID, "check-for-updates")
        XCTAssertNil(controller.issue)
    }

    func testTypedUpdateFailuresRerenderAndExternalFailuresStayVerbatim() {
        let oversized = UpdateController.presentationText(
            for: UpdateCheckError.responseTooLarge(maximumBytes: 262_144)
        )
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentation(oversized),
            "The update response exceeded 262144 bytes."
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(oversized),
            "更新响应超过 262144 字节。"
        )

        struct ExternalFailure: LocalizedError {
            let errorDescription: String? = "The update service returned an invalid response."
        }
        let external = UpdateController.presentationText(for: ExternalFailure())
        XCTAssertEqual(external, .verbatim("The update service returned an invalid response."))
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(external),
            "The update service returned an invalid response."
        )
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor UpdateInformationSequence {
    private var values: [UpdateInformation]

    init(_ values: [UpdateInformation]) {
        self.values = values
    }

    func next() -> UpdateInformation {
        precondition(!values.isEmpty)
        return values.removeFirst()
    }
}
