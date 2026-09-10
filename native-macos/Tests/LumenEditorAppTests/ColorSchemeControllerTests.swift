import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class ColorSchemeControllerTests: XCTestCase {
    func testCurrentSchemeIsFirstAndSelectionApplies() {
        var current = EditorColorScheme.dracula
        let controller = ColorSchemeController(
            currentScheme: { current }, apply: { current = $0 }
        )
        XCTAssertTrue(controller.present())
        XCTAssertEqual(controller.items.first?.scheme, .dracula)
        XCTAssertEqual(controller.items.first?.isCurrent, true)
        let light = controller.items.firstIndex { $0.scheme == .light }!
        controller.selectItem(at: light)
        XCTAssertTrue(controller.acceptSelection())
        XCTAssertEqual(current, .light)
        XCTAssertFalse(controller.isPresented)
    }

    func testCommandPresentsPalette() async throws {
        let controller = ColorSchemeController(
            currentScheme: { .dark }, apply: { _ in }
        )
        let router = CommandRouter()
        var presented = 0
        _ = try controller.registerCommand(
            on: router, presentPanel: { presented += 1 }
        )
        let result = await router.execute("select-color-scheme", context: .init())
        XCTAssertTrue(result.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(presented, 1)
    }
}
