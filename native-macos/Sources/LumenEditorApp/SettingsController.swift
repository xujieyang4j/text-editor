import Combine
import Foundation
import LumenEditorCore
import SwiftUI

struct SettingsPersistenceIssue: Identifiable, Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        case store(SettingsStoreError)
        case verbatim(String)
    }

    enum Message: Equatable, Sendable {
        case applicationTerminationCommitted
        case saveFailed(Cause)
        case sessionOnly(cause: Cause, destinationPath: String)
    }

    let id: UUID
    let content: Message

    var titleContent: AppLocalizedCopy { .couldNotSaveSettings }
    var title: String { EditorLocale.enUS.localizedApp(.couldNotSaveSettings) }
    var message: String { EditorLocale.enUS.localizedSettingsPersistenceIssue(content) }

    init(id: UUID = UUID(), content: Message) {
        self.id = id
        self.content = content
    }

    init(id: UUID = UUID(), error: any Error, destinationPath: String? = nil) {
        self.id = id
        let cause: Cause = if let storeError = error as? SettingsStoreError {
            .store(storeError)
        } else {
            .verbatim(error.localizedDescription)
        }
        content = if let destinationPath {
            .sessionOnly(cause: cause, destinationPath: destinationPath)
        } else {
            .saveFailed(cause)
        }
    }
}

enum SettingsBuildCommandPersistenceError: Error, LocalizedError {
    case applicationTerminationCommitted

    var errorDescription: String? {
        switch self {
        case .applicationTerminationCommitted:
            return "Settings are locked while the application is terminating."
        }
    }
}

/// Owns the application's single settings snapshot and serialises writes to disk.
///
/// `SettingsStore` deliberately has a synchronous, non-throwing load API. Loading
/// here gives the app its final preferences before the first window and AppModel
/// are created. The settings object is tiny, so saving it on the main actor also
/// keeps updates ordered without introducing an unchecked Sendable store wrapper.
@MainActor
final class SettingsController: ObservableObject {
    @Published private(set) var settings: EditorSettings
    @Published private(set) var hasPendingSave = false
    @Published private(set) var persistenceIssue: SettingsPersistenceIssue?
    @Published private(set) var isApplicationTerminationCommitted = false

    /// Runtime locale shared by menus, windows, panels, and accessibility copy.
    var locale: EditorLocale { settings.locale }

    var preferredColorScheme: ColorScheme {
        settings.colorScheme == .light ? .light : .dark
    }

    private let store: SettingsStore
    private let saveDebounceNanoseconds: UInt64
    private var persistedSettings: EditorSettings
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0

    init(
        store: SettingsStore = SettingsStore(),
        saveDebounceNanoseconds: UInt64 = 350_000_000
    ) {
        self.store = store
        self.saveDebounceNanoseconds = saveDebounceNanoseconds

        let loaded = store.load().sanitized()
        settings = loaded
        persistedSettings = loaded
    }

    func set<Value>(
        _ value: Value,
        for keyPath: WritableKeyPath<EditorSettings, Value>
    ) {
        update { $0[keyPath: keyPath] = value }
    }

    /// Persists presentation state before publishing it. Command routes use
    /// this when a subsequent UI action depends on the setting taking effect.
    @discardableResult
    func persistDistractionFree(_ enabled: Bool) -> Bool {
        guard !isApplicationTerminationCommitted else {
            persistenceIssue = SettingsPersistenceIssue(
                content: .applicationTerminationCommitted
            )
            return false
        }
        guard settings.distractionFree != enabled else { return true }
        saveTask?.cancel()
        saveTask = nil
        saveGeneration &+= 1

        var snapshot = settings
        snapshot.distractionFree = enabled
        snapshot = snapshot.sanitized()
        do {
            try store.save(snapshot)
        } catch {
            hasPendingSave = settings != persistedSettings
            persistenceIssue = SettingsPersistenceIssue(error: error)
            return false
        }
        settings = snapshot
        persistedSettings = snapshot
        hasPendingSave = false
        persistenceIssue = nil
        return true
    }

    /// Synchronously persists an approved build command. State is published
    /// only after the atomic settings write succeeds.
    func persistBuildCommand(_ command: String) throws {
        guard !isApplicationTerminationCommitted else {
            throw SettingsBuildCommandPersistenceError.applicationTerminationCommitted
        }
        saveTask?.cancel()
        saveTask = nil
        saveGeneration &+= 1

        var snapshot = settings
        snapshot.buildCommand = command
        snapshot = snapshot.sanitized()
        do {
            try store.save(snapshot)
        } catch {
            persistenceIssue = SettingsPersistenceIssue(error: error)
            if settings != persistedSettings { scheduleSave() }
            throw error
        }
        settings = snapshot
        persistedSettings = snapshot
        hasPendingSave = false
        persistenceIssue = nil
    }

    func update(_ mutation: (inout EditorSettings) -> Void) {
        guard !isApplicationTerminationCommitted else { return }
        var updated = settings
        mutation(&updated)
        updated = updated.sanitized()
        guard updated != settings else { return }

        settings = updated
        scheduleSave()
    }

    func toggleLineNumbers() {
        update { $0.showLineNumbers.toggle() }
    }

    func toggleWordWrap() {
        update { $0.wordWrap.toggle() }
    }

    func toggleTheme() {
        update { value in
            let next: EditorColorScheme = value.colorScheme == .light ? .dark : .light
            value.colorScheme = next
            value.theme = next == .light ? .light : .dark
        }
    }

    func zoomFont(by delta: Int) {
        update { $0.fontSize += delta }
    }

    func resetFontZoom() {
        set(EditorSettings.default.fontSize, for: \.fontSize)
    }

    /// Records successful Find/Replace inputs using Electron's newest-first,
    /// duplicate-free, 50-entry policy. The regular settings sanitizer applies
    /// the matching 2,000 UTF-16-unit bound before publishing or persisting.
    func rememberSearchHistory(_ search: String, replacement: String? = nil) {
        let boundedSearch = Self.boundedUTF16Prefix(search, maximum: 2_000)
        guard !boundedSearch.isEmpty else { return }
        update { settings in
            settings.searchHistory = Self.prependingHistory(
                boundedSearch, to: settings.searchHistory, allowEmpty: false
            )
            if let replacement {
                settings.replaceHistory = Self.prependingHistory(
                    replacement, to: settings.replaceHistory, allowEmpty: true
                )
            }
        }
    }

    func dismissPersistenceIssue() {
        persistenceIssue = nil
    }

    @discardableResult
    func retrySave() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        saveGeneration &+= 1
        return persistCurrentSettings()
    }

    /// Cancels the debounce and synchronously saves the latest complete snapshot.
    /// This is used when a settings window or the application is closing.
    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        saveGeneration &+= 1

        guard settings != persistedSettings else {
            hasPendingSave = false
            persistenceIssue = nil
            return true
        }
        return persistCurrentSettings()
    }

    /// Flushes the latest settings and closes the mutation gate immediately
    /// before the application publishes its irreversible termination marker.
    @discardableResult
    func flushAndLockForApplicationTermination() -> Bool {
        guard !isApplicationTerminationCommitted else { return true }
        guard flush() else { return false }
        isApplicationTerminationCommitted = true
        return true
    }

    /// Used only when a later termination commit step fails.
    func unlockAfterFailedApplicationTermination() {
        isApplicationTerminationCommitted = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = nil

        guard settings != persistedSettings else {
            hasPendingSave = false
            persistenceIssue = nil
            return
        }

        hasPendingSave = true
        saveGeneration &+= 1
        let generation = saveGeneration
        let delay = saveDebounceNanoseconds

        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  generation == self.saveGeneration
            else { return }
            self.saveTask = nil
            _ = self.persistCurrentSettings()
        }
    }

    private static func prependingHistory(
        _ raw: String,
        to history: [String],
        allowEmpty: Bool
    ) -> [String] {
        let value = boundedUTF16Prefix(raw, maximum: 2_000)
        guard allowEmpty || !value.isEmpty else { return history }
        return Array(([value] + history.filter { $0 != value }).prefix(50))
    }

    private static func boundedUTF16Prefix(_ value: String, maximum: Int) -> String {
        guard value.utf16.count > maximum else { return value }
        return String(decoding: value.utf16.prefix(maximum), as: UTF16.self)
    }

    @discardableResult
    private func persistCurrentSettings() -> Bool {
        let snapshot = settings.sanitized()
        if snapshot != settings {
            settings = snapshot
        }

        do {
            try store.save(snapshot)
            persistedSettings = snapshot
            hasPendingSave = settings != persistedSettings
            persistenceIssue = nil
            return true
        } catch {
            hasPendingSave = settings != persistedSettings
            persistenceIssue = SettingsPersistenceIssue(
                error: error, destinationPath: store.settingsURL.path
            )
            return false
        }
    }
}
