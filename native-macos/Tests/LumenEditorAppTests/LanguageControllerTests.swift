import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class LanguageControllerTests: XCTestCase {
    func testBuiltInCatalogIsBoundedSortedAndDetectsExtensionsAndSpecialNames() {
        let catalog = LanguageCatalog.builtIn

        XCTAssertLessThanOrEqual(catalog.languages.count, LanguageCatalog.maximumLanguageCount)
        XCTAssertEqual(catalog.languages.count, 144)
        XCTAssertGreaterThan(catalog.languages.count, 100)
        XCTAssertEqual(catalog.languages.first?.name, "Plain Text")
        XCTAssertEqual(
            Array(catalog.languages.dropFirst().map(\.name)),
            catalog.languages.dropFirst().map(\.name).sorted { left, right in
                let foldedLeft = left.lowercased()
                let foldedRight = right.lowercased()
                return foldedLeft == foldedRight ? left < right : foldedLeft < foldedRight
            }
        )
        XCTAssertEqual(catalog.detect(fileName: "main.SWIFT").name, "Swift")
        XCTAssertEqual(catalog.detect(fileName: "component.tsx").name, "TSX")
        XCTAssertEqual(catalog.detect(fileName: "README.mdx").name, "Markdown")
        XCTAssertEqual(catalog.detect(fileName: "CMakeLists.txt").name, "CMake")
        XCTAssertEqual(catalog.detect(fileName: "Dockerfile").name, "Dockerfile")
        XCTAssertEqual(catalog.detect(fileName: "foo.BUILD").name, "Plain Text")
        XCTAssertEqual(catalog.detect(fileName: "source.m").name, "Mathematica")
        XCTAssertEqual(catalog.detect(fileName: "module.v").name, "SystemVerilog")
        XCTAssertEqual(catalog.detect(fileName: "key.sig").name, "PGP")
        XCTAssertEqual(catalog.detect(fileName: "unknown.extension").name, "Plain Text")
        XCTAssertEqual(catalog.detect(fileName: nil).name, "Plain Text")
    }

    func testCatalogSanitizesCustomEntriesAndBoundsResults() {
        let oversized = String(repeating: "x", count: 101)
        let catalog = LanguageCatalog(languages: [
            LanguageDefinition(name: "Swift", aliases: ["swift"], extensions: [".swift"]),
            LanguageDefinition(name: "swift", extensions: ["duplicate"]),
            LanguageDefinition(name: oversized, extensions: ["bad"]),
            LanguageDefinition(name: "Python", extensions: ["py"])
        ])

        XCTAssertEqual(catalog.languages.map(\.name), ["Plain Text", "Python", "Swift"])
        XCTAssertEqual(catalog.detect(fileName: "file.swift").name, "Swift")
        XCTAssertEqual(catalog.search("swift").first?.language.name, "Swift")
        XCTAssertEqual(
            catalog.search("", limit: 2).map { $0.language.name },
            ["Plain Text", "Python"]
        )
        XCTAssertTrue(catalog.search("", limit: -1).isEmpty)
        XCTAssertEqual(LanguageCatalog.builtIn.search("js").first?.language.name, "JavaScript")
    }

    func testCatalogBoundsAcceptedLanguagesWithoutInvalidEntriesUsingCapacity() {
        let invalid = (0..<250).map { index in
            LanguageDefinition(
                name: String(repeating: "x", count: 101) + String(index)
            )
        }
        let valid = (0..<250).map { index in
            LanguageDefinition(name: "Language \(index)", extensions: ["l\(index)"])
        }
        let catalog = LanguageCatalog(languages: invalid + valid)

        XCTAssertEqual(catalog.languages.count, LanguageCatalog.maximumLanguageCount)
        XCTAssertNotNil(catalog.language(named: "Language 190"))
        XCTAssertNil(catalog.language(named: "Language 191"))
    }

    func testDocumentDetectionManualLockAndPlainTextUnlock() {
        let document = document(name: "source.swift")
        XCTAssertEqual(document.language, "Swift")
        XCTAssertFalse(document.languageLocked)

        XCTAssertTrue(document.chooseLanguage("Python"))
        XCTAssertEqual(document.language, "Python")
        XCTAssertTrue(document.languageLocked)
        document.relocate(to: URL(fileURLWithPath: "/tmp/source.js"))
        XCTAssertEqual(document.language, "Python")

        XCTAssertTrue(document.chooseLanguage("Plain Text"))
        XCTAssertEqual(document.language, "Plain Text")
        XCTAssertFalse(document.languageLocked)
        XCTAssertTrue(document.refreshAutomaticLanguage())
        XCTAssertEqual(document.language, "JavaScript")
    }

    func testSaveAsRedetectsUnlockedDocumentButPreservesManualLock() {
        let automatic = EditorDocument(
            fileURL: nil, displayName: "Untitled-1", text: "", savedText: ""
        )
        automatic.recordSuccessfulSave(
            to: URL(fileURLWithPath: "/tmp/main.py"), text: "",
            encoding: .utf8, lineEnding: .lf, startedEOLOverride: nil,
            revision: "python-revision"
        )
        XCTAssertEqual(automatic.language, "Python")
        XCTAssertFalse(automatic.languageLocked)

        XCTAssertTrue(automatic.chooseLanguage("Swift"))
        automatic.recordSuccessfulSave(
            to: URL(fileURLWithPath: "/tmp/main.js"), text: "",
            encoding: .utf8, lineEnding: .lf, startedEOLOverride: nil,
            revision: "javascript-revision"
        )
        XCTAssertEqual(automatic.language, "Swift")
        XCTAssertTrue(automatic.languageLocked)
    }

    func testPaletteFiltersMovesAndAppliesOnlyToCapturedDocument() throws {
        let first = document(name: "first.swift")
        let second = document(name: "second.py")
        var active: EditorDocument? = first
        var applications: [(String, String)] = []
        let controller = LanguageController(
            activeDocument: { active },
            applyLanguage: { document, name in
                applications.append((document.sessionDocumentID, name))
                return document.chooseLanguage(name)
            }
        )

        XCTAssertTrue(controller.present(query: "types"))
        XCTAssertEqual(controller.items.first?.name, "TypeScript")
        XCTAssertEqual(controller.selectedIndex, 0)
        controller.query = "script"
        let count = controller.items.count
        XCTAssertGreaterThan(count, 1)
        controller.selectItem(at: 0)
        controller.moveSelection(by: -1)
        XCTAssertEqual(controller.selectedIndex, count - 1)
        controller.moveSelection(by: 1)
        XCTAssertEqual(controller.selectedIndex, 0)

        active = second
        XCTAssertFalse(controller.acceptSelection())
        XCTAssertTrue(applications.isEmpty)
        XCTAssertTrue(controller.isPresented)

        active = first
        controller.query = "swift"
        XCTAssertTrue(controller.acceptSelection())
        XCTAssertEqual(applications.map { $0.1 }, ["Swift"])
        XCTAssertTrue(first.languageLocked)
        XCTAssertFalse(controller.isPresented)
    }

    func testPlainTextSelectionUnlocksAndSessionFlushPersistsTheChange() async throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let model = AppModel(sessionStore: fixture.store)
        let document = try XCTUnwrap(model.selectedDocument)
        let controller = LanguageController(model: model)

        XCTAssertTrue(controller.selectLanguage("Markdown"))
        XCTAssertEqual(document.language, "Markdown")
        XCTAssertTrue(document.languageLocked)
        XCTAssertTrue(model.flushSession())
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.language, "Markdown")
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.languageLocked, true)
        let restoredLocked = AppModel(
            sessionStore: fixture.store, createInitialDocument: false
        )
        await restoredLocked.restoreSession()
        XCTAssertEqual(restoredLocked.selectedDocument?.language, "Markdown")
        XCTAssertEqual(restoredLocked.selectedDocument?.languageLocked, true)

        XCTAssertTrue(controller.selectLanguage("Plain Text"))
        XCTAssertFalse(document.languageLocked)
        XCTAssertTrue(model.flushSession())
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.language, "Plain Text")
        XCTAssertEqual(fixture.store.loadWindowSession().documents.first?.languageLocked, false)
    }

    func testCommandRegistrationPresentsAndTracksAvailability() async throws {
        var current: EditorDocument? = document(name: "main.swift")
        var presentCount = 0
        var prepareCount = 0
        let controller = LanguageController(
            activeDocument: { current },
            applyLanguage: { document, name in document.chooseLanguage(name) }
        )
        let router = CommandRouter()
        let tokens = try controller.registerCommands(
            on: router,
            prepareForCommand: { prepareCount += 1 },
            presentPalette: { presentCount += 1 }
        )
        XCTAssertEqual(tokens.map(\.commandID), LanguageController.commandIDs)

        let available = CommandRoutingContext(hasDocument: true)
        XCTAssertEqual(router.status(for: "select-language", context: available), .enabled)
        let result = await router.execute("select-language", context: available)
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(presentCount, 1)

        controller.dismiss()
        current = nil
        XCTAssertEqual(
            router.status(for: "select-language", context: available),
            .disabled(.handler(reason: "No active document"))
        )
    }

    func testPalettePublishesStableAccessibilityContract() {
        XCTAssertEqual(LanguagePaletteView.Accessibility.palette, "Language Palette")
        XCTAssertEqual(LanguagePaletteView.Accessibility.query, "Language Query")
        XCTAssertEqual(LanguagePaletteView.Accessibility.results, "Language Results")
        XCTAssertEqual(LanguagePaletteView.Accessibility.emptyResults, "No Matching Languages")
        XCTAssertEqual(
            LanguagePaletteView.Accessibility.selectHint,
            "Sets this document's syntax language"
        )
    }

    private func document(name: String) -> EditorDocument {
        EditorDocument(
            fileURL: URL(fileURLWithPath: "/tmp/" + name),
            displayName: name, text: "", savedText: ""
        )
    }
}

private struct SessionFixture {
    let root: URL
    let store: SessionStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("language-controller-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false
        )
        store = SessionStore(sessionURL: root.appendingPathComponent("session.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
