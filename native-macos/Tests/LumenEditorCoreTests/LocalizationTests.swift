import XCTest
@testable import LumenEditorCore

final class LocalizationTests: XCTestCase {
    func testTypedKeysExactlyMatchSharedTypeScriptCatalog() {
        let expectedKeys = Set("""
        appTitle file edit selection goto view tools preferences project git window help
        newFile newWindow openFile openFolder openRecentFile openRecentProject
        save saveAs saveAll pinTab cycleAutoSave closeTab closeOtherTabs closeTabsRight closeAllTabs reopenTab
        undo redo cut copy paste selectAll
        commandPalette setSyntax toggleSidebar toggleMinimap toggleOutline distractionFree toggleSpellCheck toggleWrap toggleTheme selectColorScheme
        gotoAnything gotoSymbol gotoProjectSymbol gotoLine back forward
        find replace findInFiles replaceInFiles findResults
        build terminal formatDocument selectBuildSystem importSublimeBuild toggleBuildOutput configureLanguageTool
        importSublimeSettings importSublimeKeymap importSublimeProject importSublimeSnippet
        toggleGit refreshGit openConflicts checkUpdates
        languageChinese languageEnglish switchLanguage
        noFolder plainText line column autoSave noRecentFiles noRecentProjects
        lineEndingPickerPlaceholder encodingActionPickerPlaceholder encodingPickerPlaceholder reopenEncodingPickerPlaceholder current
        lineEndingChanged encodingChanged lineEndingAriaLabel encodingAriaLabel
        run stop gitChanges stage unstage discard commit history blame
        findPlaceholder replacePlaceholder includePlaceholder excludePlaceholder findAll replaceAll
        formatJson compactJson jsonView learnMore
        """.split(whereSeparator: \.isWhitespace).map(String.init))
        let actualKeys = LocalizationKey.allCases.map(\.rawValue)

        XCTAssertEqual(expectedKeys.count, 108, "Update this contract when src/shared/i18n.ts changes")
        XCTAssertEqual(actualKeys.count, expectedKeys.count)
        XCTAssertEqual(Set(actualKeys), expectedKeys)
    }

    func testTypedKeysAndSupportedLocaleIdentifiersAreUnique() {
        let keys = LocalizationKey.allCases.map(\.rawValue)
        let localeIdentifiers = Localization.supportedLocales.map(\.rawValue)

        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(localeIdentifiers).count, localeIdentifiers.count)
        XCTAssertEqual(Set(localeIdentifiers), ["zh-CN", "en-US"])
    }

    func testBothCatalogsAreCompleteAndNonempty() {
        let expectedKeys = Set(LocalizationKey.allCases)

        XCTAssertEqual(Set(Localization.catalogs.keys), Set(Localization.supportedLocales))
        for locale in Localization.supportedLocales {
            let catalog = Localization.catalog(for: locale)
            XCTAssertEqual(Set(catalog.keys), expectedKeys, "Incomplete catalog for \(locale.rawValue)")
            XCTAssertEqual(catalog.count, expectedKeys.count)
            for key in LocalizationKey.allCases {
                XCTAssertFalse(
                    catalog[key, default: ""].isEmpty,
                    "Empty \(locale.rawValue) translation for \(key.rawValue)"
                )
            }
        }
    }

    func testRepresentativeStringsMatchSharedTypeScriptCatalogExactly() {
        XCTAssertEqual(Localization.string(.appTitle, locale: .zhCN), "文本编辑器(徐洁阳)")
        XCTAssertEqual(Localization.string(.appTitle, locale: .enUS), "文本编辑器(徐洁阳)")
        XCTAssertEqual(Localization.string(.openFile, locale: .zhCN), "打开文件…")
        XCTAssertEqual(Localization.string(.openFile, locale: .enUS), "Open File…")
        XCTAssertEqual(Localization.string(.languageChinese, locale: .enUS), "简体中文")
        XCTAssertEqual(Localization.string(.languageEnglish, locale: .zhCN), "English")
        XCTAssertEqual(Localization.string(.includePlaceholder, locale: .zhCN), "包含：例如 **/*.ts")
        XCTAssertEqual(Localization.string(.excludePlaceholder, locale: .enUS), "Exclude: e.g. **/node_modules/**")
        XCTAssertEqual(Localization.translate(.learnMore, locale: .zhCN), "了解更多")
    }

    func testUnknownAndPartialLocaleIdentifiersFallBackToSimplifiedChinese() {
        XCTAssertEqual(Localization.fallbackLocale, .zhCN)
        XCTAssertEqual(Localization.resolveLocale("en-US"), .enUS)
        XCTAssertEqual(Localization.resolveLocale("zh-CN"), .zhCN)
        XCTAssertEqual(Localization.resolveLocale(nil), .zhCN)
        XCTAssertEqual(Localization.resolveLocale("en"), .zhCN)
        XCTAssertEqual(Localization.resolveLocale("zh-Hans"), .zhCN)
        XCTAssertEqual(Localization.resolveLocale("EN-US"), .zhCN)
        XCTAssertEqual(Localization.resolveLocale("fr-FR"), .zhCN)

        let fallbackCatalog = Localization.catalog(forLocaleIdentifier: "fr-FR")
        XCTAssertEqual(fallbackCatalog, Localization.catalog(for: .zhCN))
        XCTAssertEqual(
            Localization.string(.openFolder, localeIdentifier: "fr-FR"),
            "打开文件夹…"
        )
        XCTAssertEqual(
            Localization.string(.openFolder, localeIdentifier: "en-US"),
            "Open Folder…"
        )
    }

    func testTranslatorCapturesItsLocale() {
        let chinese = Localization.makeTranslator(locale: .zhCN)
        let english = Localization.makeTranslator(locale: .enUS)

        XCTAssertEqual(chinese(.saveAs), "另存为…")
        XCTAssertEqual(english(.saveAs), "Save As…")
    }

    func testDynamicPrefixInterpolationPreservesTypeScriptValues() {
        XCTAssertEqual(Localization.string(.lineEndingChanged, locale: .zhCN), "保存换行符：")
        XCTAssertEqual(Localization.string(.lineEndingChanged, locale: .enUS), "Save line endings as ")
        XCTAssertEqual(
            Localization.string(.lineEndingChanged, locale: .zhCN, arguments: ["value": "CRLF"]),
            "保存换行符：CRLF"
        )
        XCTAssertEqual(
            Localization.string(.encodingChanged, locale: .enUS, arguments: ["value": "UTF-8"]),
            "Save encoding as UTF-8"
        )
        XCTAssertEqual(
            Localization.string(.lineEndingAriaLabel, locale: .enUS, arguments: ["value": "LF"]),
            "Select line ending, currently LF"
        )
        XCTAssertEqual(
            Localization.string(.encodingAriaLabel, locale: .zhCN, arguments: ["value": "UTF-16 LE"]),
            "编码操作，当前为UTF-16 LE"
        )

        // Arguments that a key does not declare cannot accidentally alter it.
        XCTAssertEqual(
            Localization.string(.save, locale: .enUS, arguments: ["value": "ignored"]),
            "Save"
        )
    }

    func testEveryCatalogCommandHasCompleteBilingualLabelsAndUniqueID() {
        let commandIDs = CommandCatalog.all.map(\.id)
        XCTAssertEqual(Set(commandIDs).count, commandIDs.count)

        for command in CommandCatalog.all {
            XCTAssertFalse(command.englishName.isEmpty, "Missing English command label for \(command.id)")
            XCTAssertFalse(command.chineseName.isEmpty, "Missing Chinese command label for \(command.id)")
            let englishTitle = command.title(for: .english)
            XCTAssertEqual(
                Localization.commandLabel(
                    for: command.id,
                    locale: .enUS,
                    fallback: command.englishName
                ),
                command.englishName
            )
            XCTAssertEqual(
                Localization.commandLabel(
                    for: command.id,
                    locale: .zhCN,
                    fallback: command.englishName
                ),
                command.chineseName
            )
            XCTAssertEqual(
                Localization.commandTitle(
                    for: command.id,
                    locale: .enUS,
                    fallback: englishTitle
                ),
                englishTitle
            )
            XCTAssertEqual(
                Localization.commandTitle(
                    for: command.id,
                    locale: .zhCN,
                    fallback: englishTitle
                ),
                command.title(for: .simplifiedChinese)
            )
        }
    }

    func testCommandLabelAndTitleMatchSharedFallbackRules() {
        XCTAssertEqual(
            Localization.commandLabel(for: "save-as", locale: .zhCN, fallback: "Save As…"),
            "另存为…"
        )
        XCTAssertEqual(
            Localization.commandLabel(for: "save-as", locale: .enUS, fallback: "Save As…"),
            "Save As…"
        )
        XCTAssertEqual(
            Localization.commandLabel(for: "unknown", locale: .zhCN, fallback: "Plug-in Command"),
            "Plug-in Command"
        )
        XCTAssertEqual(
            Localization.commandTitle(for: "save-as", locale: .zhCN, fallback: "File: Save As…"),
            "文件：另存为…"
        )
        XCTAssertEqual(
            Localization.commandTitle(for: "save-as", locale: .enUS, fallback: "File: Save As…"),
            "File: Save As…"
        )
        XCTAssertEqual(
            Localization.commandTitle(for: "unknown", locale: .zhCN, fallback: "Tools: Plug-in: Run"),
            "工具：Plug-in: Run"
        )
        XCTAssertEqual(
            Localization.commandTitle(for: "unknown", locale: .zhCN, fallback: "Plug-in Command"),
            "Plug-in Command"
        )
        XCTAssertEqual(
            Localization.commandTitle(
                for: "save-as",
                localeIdentifier: "unsupported",
                fallback: "File: Save As…"
            ),
            "文件：另存为…"
        )
    }
}
