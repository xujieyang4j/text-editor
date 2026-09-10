import Foundation
import XCTest
@testable import LumenEditorCore

final class SettingsStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testDefaultsUseTheNativeLargeFileBudget() {
        let settings = EditorSettings.default

        XCTAssertEqual(settings.formatVersion, 2)
        XCTAssertEqual(settings.locale, .zhCN)
        XCTAssertEqual(settings.fontSize, 14)
        XCTAssertEqual(settings.tabSize, 4)
        XCTAssertTrue(settings.insertSpaces)
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertFalse(settings.wordWrap)
        XCTAssertTrue(settings.showLineNumbers)
        XCTAssertTrue(settings.showMinimap)
        XCTAssertTrue(settings.showIndentGuides)
        XCTAssertFalse(settings.showWhitespace)
        XCTAssertTrue(settings.highlightTrailingWhitespace)
        XCTAssertEqual(settings.rulers, [])
        XCTAssertEqual(
            settings.maxFileSizeMB, EditorSettings.defaultMaximumFileSizeMB
        )
        XCTAssertEqual(settings.maxFileSizeMB, 200)
        XCTAssertEqual(settings.buildCommand, "")
        XCTAssertEqual(settings.colorScheme, .dark)
        XCTAssertFalse(settings.spellCheck)
        XCTAssertEqual(settings.autoSave, .off)
        XCTAssertEqual(settings.autoSaveDelayMs, 1_000)
        XCTAssertFalse(settings.distractionFree)
        XCTAssertFalse(settings.showOutline)
        XCTAssertEqual(settings.searchHistory, [])
        XCTAssertEqual(settings.replaceHistory, [])
    }

    func testRoundTripPreservesEverySettingAndWritesVersionedJSON() throws {
        let store = makeStore(nestedPath: true)
        let settings = EditorSettings(
            locale: .enUS,
            fontSize: 19,
            tabSize: 2,
            insertSpaces: false,
            theme: .light,
            wordWrap: true,
            showLineNumbers: false,
            showMinimap: false,
            showIndentGuides: false,
            showWhitespace: true,
            highlightTrailingWhitespace: false,
            rulers: [80, 120],
            maxFileSizeMB: 64,
            buildCommand: "swift build",
            colorScheme: .solarizedDark,
            spellCheck: true,
            autoSave: .afterDelay,
            autoSaveDelayMs: 750,
            distractionFree: true,
            showOutline: true,
            searchHistory: ["needle"],
            replaceHistory: ["replacement"]
        )

        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.settingsURL))
                as? [String: Any]
        )
        XCTAssertEqual(
            object["formatVersion"] as? Int, EditorSettings.currentFormatVersion
        )
        XCTAssertEqual(object["autoSave"] as? String, "after_delay")
        XCTAssertEqual(object["colorScheme"] as? String, "solarized-dark")
    }

    func testLoadsUnversionedElectronObjectWithUnknownAndMissingFields() throws {
        let store = makeStore()
        try write(
            """
            {
              "locale": "en-US",
              "fontSize": 18,
              "wordWrap": true,
              "showMinimap": false,
              "futureSetting": { "nested": [1, true, null] }
            }
            """,
            to: store.settingsURL
        )

        let settings = store.load()

        XCTAssertEqual(settings.formatVersion, EditorSettings.currentFormatVersion)
        XCTAssertEqual(settings.locale, .enUS)
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertTrue(settings.wordWrap)
        XCTAssertFalse(settings.showMinimap)
        XCTAssertEqual(settings.tabSize, EditorSettings.default.tabSize)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.settingsURL.path))
    }

    func testWrongFieldTypesAndUnknownEnumValuesFallBackIndependently() throws {
        let store = makeStore()
        try write(
            """
            {
              "formatVersion": "one",
              "locale": "fr-FR",
              "fontSize": "24",
              "tabSize": null,
              "insertSpaces": 1,
              "theme": "blue",
              "wordWrap": true,
              "showLineNumbers": "false",
              "showMinimap": false,
              "showIndentGuides": {},
              "showWhitespace": true,
              "highlightTrailingWhitespace": [],
              "rulers": "80",
              "maxFileSizeMB": false,
              "buildCommand": 42,
              "colorScheme": "future-scheme",
              "spellCheck": true,
              "autoSave": "always",
              "autoSaveDelayMs": "500",
              "distractionFree": true,
              "showOutline": 0,
              "searchHistory": {},
              "replaceHistory": null
            }
            """,
            to: store.settingsURL
        )

        let settings = store.load()
        let defaults = EditorSettings.default

        XCTAssertEqual(settings.formatVersion, EditorSettings.currentFormatVersion)
        XCTAssertEqual(settings.locale, defaults.locale)
        XCTAssertEqual(settings.fontSize, defaults.fontSize)
        XCTAssertEqual(settings.tabSize, defaults.tabSize)
        XCTAssertEqual(settings.insertSpaces, defaults.insertSpaces)
        XCTAssertEqual(settings.theme, defaults.theme)
        XCTAssertTrue(settings.wordWrap)
        XCTAssertEqual(settings.showLineNumbers, defaults.showLineNumbers)
        XCTAssertFalse(settings.showMinimap)
        XCTAssertEqual(settings.showIndentGuides, defaults.showIndentGuides)
        XCTAssertTrue(settings.showWhitespace)
        XCTAssertEqual(
            settings.highlightTrailingWhitespace,
            defaults.highlightTrailingWhitespace
        )
        XCTAssertEqual(settings.rulers, defaults.rulers)
        XCTAssertEqual(settings.maxFileSizeMB, defaults.maxFileSizeMB)
        XCTAssertEqual(settings.buildCommand, defaults.buildCommand)
        XCTAssertEqual(settings.colorScheme, defaults.colorScheme)
        XCTAssertTrue(settings.spellCheck)
        XCTAssertEqual(settings.autoSave, defaults.autoSave)
        XCTAssertEqual(settings.autoSaveDelayMs, defaults.autoSaveDelayMs)
        XCTAssertTrue(settings.distractionFree)
        XCTAssertEqual(settings.showOutline, defaults.showOutline)
        XCTAssertEqual(settings.searchHistory, [])
        XCTAssertEqual(settings.replaceHistory, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.settingsURL.path))
    }

    func testNumericValuesAreRoundedAndClampedLikeElectron() throws {
        let store = makeStore()
        try write(
            """
            {
              "fontSize": 99.7,
              "tabSize": 2.5,
              "maxFileSizeMB": -10,
              "autoSaveDelayMs": 60000.9,
              "rulers": [-1, 0, 0.4, 80.5, 500, 500.1, "90", null, 100]
            }
            """,
            to: store.settingsURL
        )

        let settings = store.load()

        XCTAssertEqual(settings.fontSize, 40)
        XCTAssertEqual(settings.tabSize, 3)
        XCTAssertEqual(settings.maxFileSizeMB, 1)
        XCTAssertEqual(settings.autoSaveDelayMs, 60_000)
        XCTAssertEqual(settings.rulers, [0, 81, 500, 100])
    }

    func testLegacyDefaultFileLimitMigratesButExplicitModernValuesStayIntact() throws {
        let legacyDefault = makeStore()
        try write(
            "{ \"formatVersion\": 1, \"maxFileSizeMB\": 20 }",
            to: legacyDefault.settingsURL
        )
        let migrated = legacyDefault.load()
        XCTAssertEqual(migrated.formatVersion, EditorSettings.currentFormatVersion)
        XCTAssertEqual(migrated.maxFileSizeMB, EditorSettings.defaultMaximumFileSizeMB)

        let legacyCustom = makeStore()
        try write(
            "{ \"formatVersion\": 1, \"maxFileSizeMB\": 64 }",
            to: legacyCustom.settingsURL
        )
        XCTAssertEqual(legacyCustom.load().maxFileSizeMB, 64)

        let electron = makeStore()
        try write(
            "{ \"maxFileSizeMB\": 20 }", to: electron.settingsURL
        )
        XCTAssertEqual(electron.load().maxFileSizeMB, EditorSettings.defaultMaximumFileSizeMB)

        let modern = makeStore()
        try write(
            "{ \"formatVersion\": 2, \"maxFileSizeMB\": 20 }",
            to: modern.settingsURL
        )
        XCTAssertEqual(modern.load().maxFileSizeMB, 20)
    }

    func testRulersAndHistoriesFilterTruncateAndCapEntries() throws {
        let store = makeStore()
        let rulers: [Any] = (1...12).map { $0 as Any } + ["not-a-number"]
        let longItem = String(repeating: "你", count: 2_001)
        let history: [Any] = [17, NSNull(), longItem]
            + (0..<55).map { String($0) as Any }
        let object: [String: Any] = [
            "rulers": rulers,
            "searchHistory": history,
            "replaceHistory": [false, "kept"]
        ]
        try writeJSONObject(object, to: store.settingsURL)

        let settings = store.load()

        XCTAssertEqual(settings.rulers, Array(1...10))
        XCTAssertEqual(settings.searchHistory.count, 50)
        XCTAssertEqual(settings.searchHistory[0].utf16.count, 2_000)
        XCTAssertEqual(settings.searchHistory[1], "0")
        XCTAssertEqual(settings.searchHistory[49], "48")
        XCTAssertEqual(settings.replaceHistory, ["kept"])
    }

    func testUTF16LimitsSafelyRepairAnEmojiSplitAtTheBoundary() throws {
        let store = makeStore()
        let command = String(repeating: "x", count: 999) + "😀tail"
        let history = String(repeating: "y", count: 1_999) + "😀tail"
        let object: [String: Any] = [
            "buildCommand": command,
            "searchHistory": [history]
        ]
        try writeJSONObject(object, to: store.settingsURL)

        let settings = store.load()

        // JavaScript can retain the unpaired high surrogate produced by slice.
        // Swift Strings are valid Unicode, so the dangling unit becomes U+FFFD.
        XCTAssertEqual(settings.buildCommand.utf16.count, 1_000)
        XCTAssertTrue(settings.buildCommand.hasSuffix("\u{FFFD}"))
        XCTAssertEqual(settings.searchHistory[0].utf16.count, 2_000)
        XCTAssertTrue(settings.searchHistory[0].hasSuffix("\u{FFFD}"))
    }

    func testSaveSanitizesValuesChangedAfterInitialization() throws {
        let store = makeStore()
        var settings = EditorSettings.default
        settings.fontSize = 1_000
        settings.tabSize = -2
        settings.rulers = [0, 80, 501] + Array(1...20)
        settings.autoSaveDelayMs = 1
        settings.buildCommand = String(repeating: "x", count: 1_100)
        settings.searchHistory = (0..<60).map { "query-\($0)" }

        try store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(loaded.fontSize, 40)
        XCTAssertEqual(loaded.tabSize, 1)
        XCTAssertEqual(loaded.rulers, [80] + Array(1...9))
        XCTAssertEqual(loaded.autoSaveDelayMs, 250)
        XCTAssertEqual(loaded.buildCommand.utf16.count, 1_000)
        XCTAssertEqual(loaded.searchHistory.count, 50)
    }

    func testSaveCreatesParentDirectoryAndAtomicallyReplacesExistingSettings() throws {
        let store = makeStore(nestedPath: true)
        try store.save(EditorSettings(fontSize: 12))
        try store.save(EditorSettings(fontSize: 22))

        XCTAssertEqual(store.load().fontSize, 22)
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: store.settingsURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(siblingNames, [SettingsStore.settingsFileName])
    }

    func testMalformedJSONReturnsDefaultsAndIsQuarantined() throws {
        let store = makeStore()
        try write("{ definitely-not-json", to: store.settingsURL)

        XCTAssertEqual(store.load(), .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsURL.path))
        let names = try FileManager.default.contentsOfDirectory(
            atPath: store.settingsURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("\(SettingsStore.settingsFileName).corrupt-"))
    }

    func testUnknownVersionPreservesKnownFieldsButIsRejectedOnSave() throws {
        let store = makeStore()
        try write("{ \"formatVersion\": 3, \"fontSize\": 20 }", to: store.settingsURL)

        let future = store.load()
        XCTAssertEqual(future.formatVersion, 3)
        XCTAssertEqual(future.fontSize, 20)
        XCTAssertFalse(future.wordWrap)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.settingsURL.path))

        XCTAssertThrowsError(try store.save(future)) { error in
            XCTAssertEqual(
                error as? SettingsStoreError,
                .unsupportedFormatVersion(3)
            )
        }
    }

    func testValidNonObjectElectronJSONUsesDefaultsWithoutQuarantine() throws {
        let store = makeStore()
        try write("null", to: store.settingsURL)

        XCTAssertEqual(store.load(), .default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.settingsURL.path))
    }

    func testMissingFileReturnsDefaultsAndDefaultURLUsesApplicationSupport() {
        let store = makeStore()

        XCTAssertEqual(store.load(), .default)
        let defaultURL = SettingsStore.defaultSettingsURL()
        XCTAssertEqual(defaultURL.lastPathComponent, SettingsStore.settingsFileName)
        XCTAssertEqual(
            defaultURL.deletingLastPathComponent().lastPathComponent,
            SettingsStore.applicationSupportDirectoryName
        )
    }

    func testOversizedSettingsFileReturnsDefaultsWithoutReadingItAll() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            repeating: 0x20,
            count: SettingsStore.maximumSerializedBytes + 1
        ).write(to: store.settingsURL)

        XCTAssertEqual(store.load(), .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsURL.path))
        let names = try FileManager.default.contentsOfDirectory(
            atPath: store.settingsURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("\(SettingsStore.settingsFileName).corrupt-"))
    }

    private func makeStore(nestedPath: Bool = false) -> SettingsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SettingsStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryDirectories.append(directory)
        let parent = nestedPath
            ? directory.appendingPathComponent("one/two", isDirectory: true)
            : directory
        return SettingsStore(
            settingsURL: parent.appendingPathComponent(SettingsStore.settingsFileName)
        )
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }

    private func writeJSONObject(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
