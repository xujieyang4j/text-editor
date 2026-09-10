import Foundation
import XCTest

final class LumenEditorIOSUITests: XCTestCase {
    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app = launchedApp {
            // A process crash is itself useful UI evidence. Capture the whole
            // simulator screen even when the application is no longer running.
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Final state - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if app.state != .notRunning { app.terminate() }
        }
        launchedApp = nil
    }

    func testLaunchCreateAndEditDocument() {
        let app = launchApp()
        let editor = createDocument(in: app)

        tap(editor)
        editor.typeText("hello from iOS")
        assertEditor(editor, contains: "hello from iOS")
        XCTAssertTrue(app.buttons["SaveButton"].exists)
        XCTAssertTrue(app.buttons["DocumentSwitcherButton"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["EditorStatusBar"].exists)

        openMoreMenu(in: app)
        waitUntilExists(app.buttons["SaveAsButton"])
        waitUntilExists(app.buttons["ShareButton"])
        tap(app.buttons["FindMenuButton"])

        let findField = app.textFields["FindField"]
        tap(findField)
        findField.typeText("iOS")
    }

    func testReplaceAllThenUndoAndRedo() {
        let app = launchApp()
        let editor = createDocument(in: app)
        tap(editor)
        editor.typeText("alpha alpha")

        openMoreMenu(in: app)
        let find = app.buttons["FindMenuButton"]
        tap(find)
        let findField = app.textFields["FindField"]
        tap(findField)
        findField.typeText("alpha")
        let toggleReplace = app.buttons["ToggleReplaceButton"]
        tap(toggleReplace)
        let replaceField = app.textFields["ReplaceField"]
        tap(replaceField)
        replaceField.typeText("beta")
        let replaceAll = app.buttons["ReplaceAllButton"]
        tap(replaceAll)
        assertEditor(editor, equals: "beta beta")

        let closeFind = app.buttons["CloseFindButton"]
        tap(closeFind)
        openMoreMenu(in: app)
        let undo = app.buttons["UndoMenuButton"]
        tap(undo)
        assertEditor(editor, equals: "alpha alpha")
        openMoreMenu(in: app)
        let redo = app.buttons["RedoMenuButton"]
        tap(redo)
        assertEditor(editor, equals: "beta beta")
    }

    func testCreateAndSwitchBetweenTwoDrafts() {
        let app = launchApp()
        let firstEditor = createDocument(in: app)
        tap(firstEditor)
        firstEditor.typeText("first draft")

        tap(app.buttons["DocumentSwitcherButton"])
        let addDocument = app.buttons["AddDocumentButton"]
        tap(addDocument)
        let newDocument = app.buttons["NewDocumentMenuButton"]
        tap(newDocument)

        waitUntilExists(app.navigationBars["Untitled 2"])
        let secondEditor = app.descendants(matching: .any)["LumenMobileEditor"]
        tap(secondEditor)
        secondEditor.typeText("second draft")
        tap(app.buttons["DocumentSwitcherButton"])
        let firstDocument = app.buttons["DocumentRow-Untitled"]
        tap(firstDocument)
        assertEditor(
            app.descendants(matching: .any)["LumenMobileEditor"],
            equals: "first draft"
        )
    }

    func testChineseLaunchUsesLocalizedGeneratedDocumentName() {
        let app = launchApp(language: "zh-Hans", locale: "zh_CN")
        let newDocument = app.buttons["NewDocumentButton"]
        waitUntilHittable(newDocument)
        XCTAssertEqual(newDocument.label, "新建文档")
        tap(newDocument)
        waitUntilExists(app.navigationBars["未命名"])
    }

    private func launchApp(
        language: String = "en",
        locale: String = "en_US"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale
        ]
        app.launchEnvironment["LUMEN_UI_TEST_SESSION"] = UUID().uuidString
        launchedApp = app
        app.launch()
        return app
    }

    private func createDocument(in app: XCUIApplication) -> XCUIElement {
        let newDocument = app.buttons["NewDocumentButton"]
        tap(newDocument)
        let editor = app.descendants(matching: .any)["LumenMobileEditor"]
        waitUntilHittable(editor)
        return editor
    }

    private func openMoreMenu(in app: XCUIApplication) {
        let more = app.buttons["MoreButton"]
        tap(more)
    }

    private func tap(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        waitUntilHittable(element, timeout: timeout)
        element.tap()
    }

    private func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func waitUntilExists(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
    }

    private func assertEditor(
        _ editor: XCUIElement,
        equals expected: String,
        timeout: TimeInterval = 5
    ) {
        let predicate = NSPredicate(format: "value == %@", expected)
        expectation(for: predicate, evaluatedWith: editor)
        waitForExpectations(timeout: timeout)
    }

    private func assertEditor(
        _ editor: XCUIElement,
        contains expected: String,
        timeout: TimeInterval = 5
    ) {
        let predicate = NSPredicate(format: "value CONTAINS %@", expected)
        expectation(for: predicate, evaluatedWith: editor)
        waitForExpectations(timeout: timeout)
    }
}
