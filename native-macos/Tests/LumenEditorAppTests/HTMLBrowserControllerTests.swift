import AppKit
import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class HTMLBrowserControllerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    @MainActor
    func testCleanSavedHTMLOpensOriginalFileURL() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("index.html")
        try Data("<p>saved</p>".utf8).write(to: source)
        let document = EditorDocument(
            fileURL: source, displayName: "index.html",
            text: "<p>saved</p>", savedText: "<p>saved</p>", language: "HTML"
        )
        var opened: [URL] = []
        let controller = HTMLBrowserController(
            store: HTMLBrowserPreviewStore(temporaryRootURL: root),
            openURL: { opened.append($0); return true }
        )

        let didOpen = await controller.open(HTMLBrowserDocumentSnapshot(document: document))
        XCTAssertTrue(didOpen)
        XCTAssertEqual(opened, [source])
        XCTAssertEqual(controller.lastOpenedTarget?.kind, .savedFile)
        XCTAssertEqual(controller.retainedTemporarySnapshotURLs, [])
    }

    @MainActor
    func testDirtyDocumentOpensSnapshotWithoutSavingSource() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("index.html")
        try Data("disk".utf8).write(to: source)
        let document = EditorDocument(
            fileURL: source, displayName: "index.html",
            text: "<img src=\"asset.png\">", savedText: "disk", language: "HTML"
        )
        var openedURL: URL?
        let controller = HTMLBrowserController(
            store: HTMLBrowserPreviewStore(temporaryRootURL: root),
            openURL: { openedURL = $0; return true }
        )

        let didOpen = await controller.open(HTMLBrowserDocumentSnapshot(document: document))
        XCTAssertTrue(didOpen)
        let snapshot = try XCTUnwrap(openedURL)
        XCTAssertNotEqual(snapshot, source)
        XCTAssertEqual(controller.lastOpenedTarget?.kind, .temporarySnapshot)
        XCTAssertEqual(try String(contentsOf: source), "disk")
        XCTAssertTrue(try String(contentsOf: snapshot).contains("<base href="))
    }

    @MainActor
    func testRejectedBrowserLaunchDeletesNewSnapshot() async throws {
        let root = try temporaryDirectory()
        let store = HTMLBrowserPreviewStore(temporaryRootURL: root)
        let document = EditorDocument(
            fileURL: nil, displayName: "Untitled-1",
            text: "<p>draft</p>", savedText: "", language: "HTML"
        )
        var rejectedURL: URL?
        let controller = HTMLBrowserController(store: store, openURL: {
            rejectedURL = $0
            return false
        })

        let didOpen = await controller.open(HTMLBrowserDocumentSnapshot(document: document))
        XCTAssertFalse(didOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(rejectedURL).path))
        XCTAssertEqual(controller.retainedTemporarySnapshotURLs, [])
        XCTAssertEqual(controller.issue?.title, "Could Not Open Browser Preview")
        let issue = try XCTUnwrap(controller.issue)
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(issue.titleContent),
            "无法打开浏览器预览"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(issue.content),
            "系统浏览器未接受 HTML 预览 URL。"
        )
    }

    @MainActor
    func testKnownBrowserErrorsAreTypedAndUnknownErrorsRemainVerbatim() {
        let known = HTMLBrowserController.presentationText(
            for: HTMLBrowserPreviewError.snapshotTooLarge(actual: 12, maximum: 10)
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(known),
            "HTML 预览为 12 字节；上限为 10 字节。"
        )

        struct ExternalFailure: LocalizedError {
            let errorDescription: String? = "外部浏览器原始错误 /tmp/private"
        }
        let external = HTMLBrowserController.presentationText(for: ExternalFailure())
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentation(external),
            "外部浏览器原始错误 /tmp/private"
        )
        XCTAssertEqual(
            EditorLocale.zhCN.localizedPresentation(external),
            "外部浏览器原始错误 /tmp/private"
        )
    }

    @MainActor
    func testTerminationNotificationCleansTemporarySnapshots() async throws {
        let root = try temporaryDirectory()
        let center = NotificationCenter()
        let controller = HTMLBrowserController(
            store: HTMLBrowserPreviewStore(temporaryRootURL: root),
            notificationCenter: center,
            openURL: { _ in true }
        )
        let document = EditorDocument(
            fileURL: nil, displayName: "Untitled-1",
            text: "<p>draft</p>", savedText: "", language: "HTML"
        )
        let didOpen = await controller.open(HTMLBrowserDocumentSnapshot(document: document))
        XCTAssertTrue(didOpen)
        let directory = try XCTUnwrap(controller.retainedTemporarySnapshotURLs.first)
            .deletingLastPathComponent()

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(controller.retainedTemporarySnapshotURLs, [])
    }

    @MainActor
    func testCommandRegistrationChecksHTMLAndReturnsFailuresThroughRouter() async throws {
        let root = try temporaryDirectory()
        let document = EditorDocument(
            fileURL: nil, displayName: "Untitled-1",
            text: "<p>draft</p>", savedText: "", language: "HTML"
        )
        var current: EditorDocument? = document
        var openedCount = 0
        var prepareCount = 0
        let controller = HTMLBrowserController(
            store: HTMLBrowserPreviewStore(temporaryRootURL: root),
            openURL: { _ in openedCount += 1; return true }
        )
        let router = CommandRouter()
        let api = controller.commandHandlerAPI(
            snapshot: { current.map(HTMLBrowserDocumentSnapshot.init(document:)) },
            prepareForCommand: { prepareCount += 1 }
        )
        let context = CommandRoutingContext(hasDocument: true)
        XCTAssertEqual(api.enablement(context), .enabled)
        _ = try controller.registerCommandHandler(
            on: router,
            snapshot: { current.map(HTMLBrowserDocumentSnapshot.init(document:)) },
            prepareForCommand: { prepareCount += 1 }
        )
        XCTAssertEqual(router.status(for: "open-in-browser", context: context), .enabled)
        let executed = await router.execute("open-in-browser", context: context)
        XCTAssertTrue(executed.didExecuteSuccessfully)
        XCTAssertEqual(openedCount, 1)
        XCTAssertEqual(prepareCount, 1)

        current = EditorDocument(
            fileURL: nil, displayName: "Untitled-2",
            text: "plain", savedText: "", language: "Plain Text"
        )
        XCTAssertEqual(
            router.status(for: "open-in-browser", context: context),
            .disabled(.handler(reason: "Requires an HTML document."))
        )
        let unavailable = await router.execute("open-in-browser", context: context)
        XCTAssertFalse(unavailable.didExecuteSuccessfully)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-controller-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }
}
