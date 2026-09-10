import Foundation
import XCTest
@testable import LumenEditorCore

final class HTMLBrowserPreviewTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testRecognizesElectronHTMLFileExtensionsAndManualLanguage() {
        for name in ["index.html", "legacy.HTM", "page.xhtml"] {
            XCTAssertTrue(HTMLBrowserPreview.supports(
                sourceURL: URL(fileURLWithPath: "/tmp/" + name),
                language: "Plain Text"
            ))
        }
        XCTAssertTrue(HTMLBrowserPreview.supports(sourceURL: nil, language: "html"))
        XCTAssertFalse(HTMLBrowserPreview.supports(
            sourceURL: URL(fileURLWithPath: "/tmp/readme.md"), language: "Markdown"
        ))
    }

    func testCleanSavedHTMLUsesOriginalFileWithoutReadingOrWritingIt() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("index.html")
        let original = Data("<p>on disk</p>".utf8)
        try original.write(to: source)
        let store = HTMLBrowserPreviewStore(temporaryRootURL: root)

        let target = try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: source,
            content: "<p>editor text is intentionally irrelevant</p>",
            isDirty: false,
            language: "HTML"
        ))

        XCTAssertEqual(target, HTMLBrowserPreviewTarget(url: source, kind: .savedFile))
        XCTAssertNil(store.temporaryDirectoryURL)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDirtySavedHTMLUsesUTF8SnapshotWithCorrectDirectoryBase() throws {
        let root = try temporaryDirectory()
        let sourceDirectory = root.appendingPathComponent("A & B", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory, withIntermediateDirectories: false
        )
        let source = sourceDirectory.appendingPathComponent("index.html")
        try Data("old".utf8).write(to: source)
        let store = HTMLBrowserPreviewStore(temporaryRootURL: root)

        let target = try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: source,
            content: "<html lang=\"en\"><body><img src=\"asset.png\"></body></html>",
            isDirty: true,
            language: "HTML"
        ))

        XCTAssertEqual(target.kind, .temporarySnapshot)
        XCTAssertNotEqual(target.url, source)
        XCTAssertEqual(target.url.pathExtension, "html")
        let attributes = try FileManager.default.attributesOfItem(atPath: target.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let html = try String(contentsOf: target.url, encoding: .utf8)
        let expectedBase = URL(
            fileURLWithPath: sourceDirectory.path, isDirectory: true
        ).absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        XCTAssertTrue(html.contains("<head><base href=\"\(expectedBase)\"></head>"))
        XCTAssertTrue(html.contains(#"src="asset.png""#))
        XCTAssertEqual(try Data(contentsOf: source), Data("old".utf8))
    }

    func testBaseInsertionUsesHeadAndPreservesExistingBaseCaseInsensitively() throws {
        let source = URL(fileURLWithPath: "/tmp/site/index.html")
        let withHead = try HTMLBrowserPreview.snapshotHTML(
            "<HTML><HEAD data-x=\"1\"><title>x</title></HEAD></HTML>",
            sourceURL: source
        )
        XCTAssertTrue(withHead.contains("<HEAD data-x=\"1\">\n<base href=\"file:///tmp/site/\">"))

        let existing = "<html><head><BASE href=\"https://example.test/\"></head></html>"
        XCTAssertEqual(
            try HTMLBrowserPreview.snapshotHTML(existing, sourceURL: source), existing
        )
    }

    func testUntitledHTMLSnapshotHasNoFabricatedBase() throws {
        let root = try temporaryDirectory()
        let store = HTMLBrowserPreviewStore(temporaryRootURL: root)
        let content = "<html><body>draft</body></html>"

        let target = try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: nil, content: content, isDirty: true, language: "HTML"
        ))

        XCTAssertEqual(target.kind, .temporarySnapshot)
        XCTAssertEqual(try String(contentsOf: target.url, encoding: .utf8), content)
        let browserURL = HTMLBrowserPreview.browserURL(for: target)
        XCTAssertEqual(browserURL.path, target.url.path)
        XCTAssertNotNil(URLComponents(url: browserURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "t" })?.value)
    }

    func testSnapshotLimitCountsInjectedBaseAndLeavesNoFileOnFailure() throws {
        let root = try temporaryDirectory()
        let source = URL(fileURLWithPath: "/tmp/site/index.html")
        let store = HTMLBrowserPreviewStore(
            temporaryRootURL: root, maximumSnapshotByteCount: 20
        )

        XCTAssertThrowsError(try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: source, content: "<p>x</p>", isDirty: true, language: "HTML"
        ))) { error in
            guard case let .snapshotTooLarge(actual, maximum) = error as? HTMLBrowserPreviewError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 20)
        }
        XCTAssertNil(store.temporaryDirectoryURL)
    }

    func testStoreBoundsRetainedSnapshotsAndCleanupRemovesPrivateDirectory() throws {
        let root = try temporaryDirectory()
        let store = HTMLBrowserPreviewStore(
            temporaryRootURL: root, maximumRetainedSnapshots: 2
        )
        for index in 0..<3 {
            _ = try store.prepare(HTMLBrowserPreviewRequest(
                sourceURL: nil,
                content: "<p>\(index)</p>",
                isDirty: true,
                language: "HTML"
            ))
        }
        let directory = try XCTUnwrap(store.temporaryDirectoryURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(store.retainedSnapshotURLs.count, 2)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2
        )

        store.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(store.retainedSnapshotURLs, [])
        store.cleanup()
        _ = try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: nil, content: "<p>after cancelled quit</p>",
            isDirty: true, language: "HTML"
        ))
        store.shutdown()
        XCTAssertThrowsError(try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: nil, content: "<p>late</p>", isDirty: true, language: "HTML"
        ))) { error in
            XCTAssertEqual(error as? HTMLBrowserPreviewError, .storeClosed)
        }
    }

    func testRejectsUnsupportedDocumentsAndNonLocalSourceURLs() throws {
        let root = try temporaryDirectory()
        let store = HTMLBrowserPreviewStore(temporaryRootURL: root)
        XCTAssertThrowsError(try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: URL(fileURLWithPath: "/tmp/readme.txt"),
            content: "text", isDirty: false, language: "Plain Text"
        ))) { error in
            XCTAssertEqual(error as? HTMLBrowserPreviewError, .unsupportedDocument)
        }
        let remote = try XCTUnwrap(URL(string: "https://example.test/index.html"))
        XCTAssertThrowsError(try store.prepare(HTMLBrowserPreviewRequest(
            sourceURL: remote, content: "<p>x</p>", isDirty: false, language: "HTML"
        ))) { error in
            XCTAssertEqual(error as? HTMLBrowserPreviewError, .invalidSourceURL(remote))
        }
    }

    // MARK: — firstMatch fail-closed behavior

    func testFirstMatchInsertionAppliesBaseHRef() throws {
        let source = URL(fileURLWithPath: "/tmp/site/index.html")
        let content = try HTMLBrowserPreview.snapshotHTML(
            "<html><body>test</body></html>",
            sourceURL: source
        )
        XCTAssertTrue(content.contains("<base href="))
    }

    func testBaseTagDetectionIsCaseInsensitive() throws {
        let source = URL(fileURLWithPath: "/tmp/site/index.html")
        for base in ["<BASE>", "<base >", "<Base href=\"/\">", "<BASE href=\"/\">"] {
            let html = "<html><head>\(base)</head></html>"
            let result = try HTMLBrowserPreview.snapshotHTML(html, sourceURL: source)
            XCTAssertEqual(result, html, "\(base) should prevent base insertion")
        }
    }

    func testConsecutiveSnapshotHTMLCallsRemainStable() throws {
        let source = URL(fileURLWithPath: "/tmp/site/index.html")
        for _ in 0..<10 {
            _ = try HTMLBrowserPreview.snapshotHTML(
                "<p>hello</p>", sourceURL: source
            )
        }
        let withHead = try HTMLBrowserPreview.snapshotHTML(
            "<html><head><title>x</title></head></html>",
            sourceURL: source
        )
        XCTAssertTrue(withHead.contains("<base href="))
    }

    func testUnusualBasePositionStillPreservesContent() throws {
        let source = URL(fileURLWithPath: "/tmp/site/index.html")
        let html = "<html><body><base href=\"original\">text</body></html>"
        let result = try HTMLBrowserPreview.snapshotHTML(html, sourceURL: source)
        XCTAssertEqual(result, html)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-preview-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }
}
