import XCTest
@testable import LumenEditorApp

final class PluginViewsTests: XCTestCase {
    func testPluginViewsPublishStableAccessibilityContract() {
        XCTAssertEqual(PluginManagerView.Accessibility.panel, "Plugin Manager")
        XCTAssertEqual(PluginManagerView.Accessibility.refresh, "Refresh Plugins")
        XCTAssertEqual(MarketplaceView.Accessibility.panel, "Plugin Marketplace")
        XCTAssertEqual(
            MarketplaceView.Accessibility.search, "Search Plugin Marketplace"
        )
        XCTAssertEqual(
            MarketplaceView.Accessibility.refresh, "Refresh Plugin Marketplace"
        )
    }
}
