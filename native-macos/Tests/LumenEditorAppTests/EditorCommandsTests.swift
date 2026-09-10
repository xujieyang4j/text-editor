import AppKit
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class EditorCommandsTests: XCTestCase {
    @MainActor
    func testSettingsOnlyMenuPublishesOnlyApplicationScopedCommands() throws {
        XCTAssertEqual(
            SettingsOnlyCommands.commandIDs,
            [
                "new-window", "open-settings", "check-for-updates",
                "set-ui-language-zh", "set-ui-language-en"
            ]
        )
        XCTAssertEqual(Set(SettingsOnlyCommands.commandIDs).count, 5)
        XCTAssertTrue(SettingsOnlyCommands.preservesSystemServices)
        XCTAssertTrue(SettingsOnlyCommands.replacesSettingsPlacement)

        let commands = try SettingsOnlyCommands.commandIDs.map { commandID in
            try XCTUnwrap(CommandCatalog.command(id: commandID))
        }
        let editorRequirements: CommandRequirements = [
            .document, .savedDocument, .workspace, .selection, .findResults,
            .navigationHistory, .closedTab, .gitRepository, .languageService
        ]
        XCTAssertTrue(commands.allSatisfy {
            $0.requirements.intersection(editorRequirements).isEmpty
        })
        XCTAssertFalse(SettingsOnlyCommands.commandIDs.contains("new-file"))
        XCTAssertFalse(SettingsOnlyCommands.commandIDs.contains("open-file"))
        XCTAssertFalse(SettingsOnlyCommands.commandIDs.contains("save"))
        XCTAssertFalse(SettingsOnlyCommands.commandIDs.contains("close-tab"))
    }

    @MainActor
    func testSettingsOnlyMenuTitlesFollowRuntimeLocale() {
        XCTAssertEqual(
            SettingsOnlyCommands.commandTitle("new-window", locale: .enUS),
            "New Window"
        )
        XCTAssertEqual(
            SettingsOnlyCommands.commandTitle("new-window", locale: .zhCN),
            "新建窗口"
        )
        XCTAssertEqual(
            SettingsOnlyCommands.commandTitle("open-settings", locale: .enUS),
            "Open Settings…"
        )
        XCTAssertEqual(
            SettingsOnlyCommands.commandTitle("open-settings", locale: .zhCN),
            "打开设置…"
        )
        XCTAssertEqual(
            SettingsOnlyCommands.commandTitle("check-for-updates", locale: .zhCN),
            "检查更新…"
        )
        XCTAssertEqual(
            SettingsOnlyCommands.commandTitle("set-ui-language-en", locale: .zhCN),
            "切换为英文"
        )
    }

    @MainActor
    func testSettingsOnlyMenuUsesStandardApplicationActions() {
        XCTAssertEqual(
            SettingsOnlyCommands.standardApplicationActions,
            [
                #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                #selector(NSApplication.hide(_:)),
                #selector(NSApplication.hideOtherApplications(_:)),
                #selector(NSApplication.unhideAllApplications(_:)),
                #selector(NSApplication.terminate(_:))
            ]
        )
        XCTAssertEqual(
            SettingsOnlyCommands.standardWindowActions,
            [
                #selector(NSWindow.performMiniaturize(_:)),
                #selector(NSWindow.performZoom(_:)),
                #selector(NSWindow.toggleFullScreen(_:)),
                #selector(NSApplication.arrangeInFront(_:))
            ]
        )
    }

    @MainActor
    func testFileMenuPublishesBothRecentItemCatalogCommands() throws {
        XCTAssertEqual(
            EditorCommands.fileRecentCommandIDs,
            ["open-recent-file", "open-recent-project"]
        )
        XCTAssertEqual(
            EditorCommands.fileRecentCommandIDs,
            RecentItemsController.commandIDs
        )

        let commands = try EditorCommands.fileRecentCommandIDs.map { commandID in
            try XCTUnwrap(CommandCatalog.command(id: commandID))
        }
        XCTAssertEqual(
            commands.map { $0.name(for: .english) },
            ["Open Recent File…", "Open Recent Project…"]
        )
        XCTAssertEqual(
            commands.map { $0.name(for: .simplifiedChinese) },
            ["打开最近文件…", "打开最近项目…"]
        )
    }

    @MainActor
    func testFullScreenMenuUsesTheStandardSelectorAndShortcut() {
        XCTAssertEqual(
            EditorCommands.toggleFullScreenAction,
            #selector(NSWindow.toggleFullScreen(_:))
        )
        XCTAssertEqual(EditorCommands.toggleFullScreenShortcut.key.character, "f")
        XCTAssertEqual(
            EditorCommands.toggleFullScreenShortcut.modifiers,
            [.control, .command]
        )
    }

    @MainActor
    func testSystemActionEnablementUsesAppKitMenuValidation() {
        let action = EditorCommands.toggleFullScreenAction
        XCTAssertFalse(EditorCommands.systemActionIsEnabled(action, target: nil))

        let disabled = MenuItemValidator(enabled: false)
        XCTAssertFalse(EditorCommands.systemActionIsEnabled(action, target: disabled))
        XCTAssertEqual(disabled.validatedAction, action)

        let enabled = MenuItemValidator(enabled: true)
        XCTAssertTrue(EditorCommands.systemActionIsEnabled(action, target: enabled))
        XCTAssertEqual(enabled.validatedAction, action)

        let interfaceValidator = UserInterfaceValidator(enabled: false)
        XCTAssertFalse(
            EditorCommands.systemActionIsEnabled(action, target: interfaceValidator)
        )
        XCTAssertEqual(interfaceValidator.validatedAction, action)

        XCTAssertTrue(EditorCommands.systemActionIsEnabled(action, target: NSObject()))
    }
}

@MainActor
private final class MenuItemValidator: NSObject, NSMenuItemValidation {
    let enabled: Bool
    private(set) var validatedAction: Selector?

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validatedAction = menuItem.action
        return enabled
    }
}

@MainActor
private final class UserInterfaceValidator: NSObject, NSUserInterfaceValidations {
    let enabled: Bool
    private(set) var validatedAction: Selector?

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        validatedAction = item.action
        return enabled
    }
}
