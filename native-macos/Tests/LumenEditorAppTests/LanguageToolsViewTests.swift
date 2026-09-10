import XCTest
@testable import LumenEditorApp

final class LanguageToolsViewTests: XCTestCase {
    func testAccessibilityContractIsStable() {
        XCTAssertEqual(
            LanguageToolsConfigurationView.Accessibility.panel,
            "Language Tool Configuration"
        )
        XCTAssertEqual(
            LanguageToolsConfigurationView.Accessibility.command,
            "Language Tool Command"
        )
        XCTAssertEqual(
            LanguageToolsConfigurationView.Accessibility.save,
            "Save Language Tool"
        )
    }
}
