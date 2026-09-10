import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class UpdateViewTests: XCTestCase {
    func testReleaseConfirmationCopyIsLocalizedAndIncludesReviewedURL() {
        let url = URL(
            string: "https://github.com/xujieyang4j/text-editor/releases/tag/v2.0.0"
        )!
        let confirmation = UpdateReleaseConfirmation(information: UpdateInformation(
            currentVersion: "1.0.0", latestVersion: "2.0.0",
            releaseURL: url, isAvailable: true
        ))

        let english = UpdateReleaseConfirmationPresentation(
            confirmation: confirmation, locale: .enUS
        )
        XCTAssertEqual(english.title, "Open Release Page?")
        XCTAssertEqual(english.confirmAction, "Open Release Page")
        XCTAssertEqual(english.cancelAction, "Cancel")
        XCTAssertTrue(english.message.contains(url.absoluteString))

        let chinese = UpdateReleaseConfirmationPresentation(
            confirmation: confirmation, locale: .zhCN
        )
        XCTAssertEqual(chinese.title, "打开发布页面？")
        XCTAssertEqual(chinese.confirmAction, "打开发布页面")
        XCTAssertEqual(chinese.cancelAction, "取消")
        XCTAssertTrue(chinese.message.contains(url.absoluteString))
    }

    func testReleaseConfirmationAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(
            UpdateView.Accessibility.confirmOpenRelease,
            "panel.update.confirmOpenRelease"
        )
        XCTAssertEqual(
            UpdateView.Accessibility.cancelOpenRelease,
            "panel.update.cancelOpenRelease"
        )
    }
}
