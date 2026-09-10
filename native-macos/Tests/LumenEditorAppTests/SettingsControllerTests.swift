import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class SettingsControllerTests: XCTestCase {
    @MainActor
    func testApprovedBuildCommandPersistsSynchronouslyWithoutPublishingOnFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store, saveDebounceNanoseconds: 60_000_000_000
        )

        try controller.persistBuildCommand("npm test")

        XCTAssertEqual(controller.settings.buildCommand, "npm test")
        XCTAssertEqual(fixture.store.load().buildCommand, "npm test")
        XCTAssertFalse(controller.hasPendingSave)

        let blockedParent = fixture.directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let failing = SettingsController(store: SettingsStore(
            settingsURL: blockedParent.appendingPathComponent("settings.json")
        ))
        XCTAssertThrowsError(try failing.persistBuildCommand("must not publish"))
        XCTAssertEqual(failing.settings.buildCommand, "")
        guard let issue = failing.persistenceIssue,
              case .saveFailed(.verbatim(_)) = issue.content else {
            return XCTFail("Expected a typed verbatim settings persistence issue")
        }
        XCTAssertEqual(
            EditorLocale.zhCN.localizedSettingsPersistenceIssue(issue.content),
            issue.message
        )
    }

    @MainActor
    func testTerminationCommitFlushesAndLocksFurtherSettingsMutations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store, saveDebounceNanoseconds: 60_000_000_000
        )
        controller.set(19, for: \.fontSize)

        XCTAssertTrue(controller.flushAndLockForApplicationTermination())
        XCTAssertTrue(controller.isApplicationTerminationCommitted)
        XCTAssertEqual(fixture.store.load().fontSize, 19)

        controller.set(31, for: \.fontSize)
        XCTAssertEqual(controller.settings.fontSize, 19)
        controller.unlockAfterFailedApplicationTermination()
        controller.set(21, for: \.fontSize)
        XCTAssertEqual(controller.settings.fontSize, 21)
    }

    @MainActor
    func testDistractionFreeTransactionPublishesOnlyAfterPersistence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.save(EditorSettings(distractionFree: true))
        let controller = SettingsController(store: fixture.store)

        XCTAssertTrue(controller.persistDistractionFree(false))
        XCTAssertFalse(controller.settings.distractionFree)
        XCTAssertFalse(fixture.store.load().distractionFree)
        XCTAssertNil(controller.persistenceIssue)

        let blockedParent = fixture.directory.appendingPathComponent("blocked-state")
        try Data("not a directory".utf8).write(to: blockedParent)
        let blockedURL = blockedParent.appendingPathComponent("settings.json")
        let failing = SettingsController(store: SettingsStore(settingsURL: blockedURL))
        failing.set(true, for: .distractionFree)
        XCTAssertTrue(failing.settings.distractionFree)

        XCTAssertFalse(failing.persistDistractionFree(false))
        XCTAssertTrue(failing.settings.distractionFree)
        XCTAssertNotNil(failing.persistenceIssue)
        failing.dismissPersistenceIssue()
        XCTAssertTrue(failing.flushAndLockForApplicationTermination())
        XCTAssertFalse(failing.persistDistractionFree(false))
        XCTAssertTrue(failing.settings.distractionFree)
    }

    func testSearchHistoryIsNewestFirstDeduplicatedBoundedAndPersisted() async throws {
        try await MainActor.run {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store, saveDebounceNanoseconds: 0
        )

        for index in 0 ..< 55 {
            controller.rememberSearchHistory("query-\(index)")
        }
        controller.rememberSearchHistory("query-50")
        controller.rememberSearchHistory(
            String(repeating: "a", count: 1_999) + "😀tail"
        )
        XCTAssertTrue(controller.flush())

        XCTAssertEqual(controller.settings.searchHistory.count, 50)
        XCTAssertEqual(controller.settings.searchHistory[1], "query-50")
        XCTAssertEqual(Set(controller.settings.searchHistory).count, 50)
        XCTAssertEqual(controller.settings.searchHistory[0].utf16.count, 2_000)
        XCTAssertTrue(controller.settings.searchHistory[0].hasSuffix("�"))
        XCTAssertEqual(fixture.store.load().searchHistory, controller.settings.searchHistory)
        }
    }

    func testReplacementHistoryKeepsEmptyReplacementAndIgnoresEmptySearch() async throws {
        try await MainActor.run {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = SettingsController(
            store: fixture.store, saveDebounceNanoseconds: 0
        )

        controller.rememberSearchHistory("", replacement: "ignored")
        XCTAssertEqual(controller.settings.searchHistory, [])
        XCTAssertEqual(controller.settings.replaceHistory, [])

        controller.rememberSearchHistory("needle", replacement: "")
        controller.rememberSearchHistory("needle", replacement: "replacement")
        controller.rememberSearchHistory("needle", replacement: "")
        XCTAssertTrue(controller.flush())

        XCTAssertEqual(controller.settings.searchHistory, ["needle"])
        XCTAssertEqual(controller.settings.replaceHistory, ["", "replacement"])
        XCTAssertEqual(fixture.store.load().replaceHistory, ["", "replacement"])
        }
    }

    private struct Fixture {
        let directory: URL
        let store: SettingsStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SettingsControllerTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            store = SettingsStore(
                settingsURL: directory.appendingPathComponent("settings.json")
            )
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
