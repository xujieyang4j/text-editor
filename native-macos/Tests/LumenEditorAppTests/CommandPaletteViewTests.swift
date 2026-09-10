import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class CommandPaletteViewTests: XCTestCase {
    func testStoredAppFeedbackRerendersForRuntimeLocale() {
        let feedback = CommandPaletteFeedback.app(.commandPaletteNoChange)

        XCTAssertEqual(
            feedback.localized(locale: .enUS),
            "The command made no change"
        )
        XCTAssertEqual(
            feedback.localized(locale: .zhCN),
            "命令未产生更改"
        )
    }

    func testExternalCommandFailureRemainsVerbatimAcrossLocales() {
        struct ExternalFailure: LocalizedError {
            let errorDescription: String? = "外部命令原始错误 /tmp/private"
        }
        let feedback = CommandPaletteFeedback.from(error: ExternalFailure())

        XCTAssertEqual(
            feedback.localized(locale: .enUS),
            "外部命令原始错误 /tmp/private"
        )
        XCTAssertEqual(
            feedback.localized(locale: .zhCN),
            "外部命令原始错误 /tmp/private"
        )
    }

    func testTypedCommandFailureRerendersForRuntimeLocale() {
        let feedback = CommandPaletteFeedback.from(
            error: HTMLBrowserPreviewControllerError.systemBrowserRejectedURL
        )

        XCTAssertEqual(
            feedback.localized(locale: .enUS),
            "The system browser did not accept the HTML preview URL."
        )
        XCTAssertEqual(
            feedback.localized(locale: .zhCN),
            "系统浏览器未接受 HTML 预览 URL。"
        )
    }

    func testSubsystemCommandFailuresRerenderForRuntimeLocale() {
        let cases: [(CommandPresentation, String, String)] = [
            (
                .workspace(.workspaceError(.tooManyRoots(maximum: 2), context: nil)),
                "A workspace supports at most 2 roots.",
                "一个工作区最多支持 2 个根目录。"
            ),
            (
                .workspaceSearch(.searchError(.invalidRegularExpression)),
                "The search expression is invalid.",
                "搜索表达式无效。"
            ),
            (
                .plugin(.manifestValidation(.unsuccessfulHTTPStatus(503))),
                "The marketplace resource returned HTTP status 503.",
                "插件市场资源返回了 HTTP 状态 503。"
            ),
            (
                .pluginWorker(.runtime(.permissionDenied(.documentRead))),
                "The plugin was not granted ‘document-read’ permission.",
                "插件未被授予“document-read”权限。"
            ),
        ]

        for (presentation, english, chinese) in cases {
            let feedback = CommandPaletteFeedback.failure(presentation)
            XCTAssertEqual(feedback.localized(locale: .enUS), english)
            XCTAssertEqual(feedback.localized(locale: .zhCN), chinese)
        }
    }

    func testRouteFeedbackUsesLocaleAtRenderTime() {
        let feedback = CommandPaletteFeedback.routeStatus(
            .disabled(.handler(reason: "Requires an HTML document."))
        )

        XCTAssertEqual(
            feedback.localized(locale: .enUS),
            "Requires an HTML document."
        )
        XCTAssertEqual(
            feedback.localized(locale: .zhCN),
            "需要 HTML 文档。"
        )
    }

    func testHandlerReasonsUseRuntimeLocale() {
        let cases: [(reason: String, zhCN: String)] = [
            ("Editor command controller unavailable", "编辑器命令控制器不可用"),
            ("Outline unavailable", "大纲不可用"),
        ]

        for testCase in cases {
            let feedback = CommandPaletteFeedback.routeStatus(
                .disabled(.handler(reason: testCase.reason))
            )

            XCTAssertEqual(feedback.localized(locale: .enUS), testCase.reason)
            XCTAssertEqual(feedback.localized(locale: .zhCN), testCase.zhCN)
        }
    }
}
