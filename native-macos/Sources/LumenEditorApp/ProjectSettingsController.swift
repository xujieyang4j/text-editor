import Combine
import Foundation
import LumenEditorCore

struct ProjectSettingsPresentationIssue: Identifiable, Equatable, Sendable {
    enum Title: Equatable, Sendable {
        case load
        case reload
        case save
        case saveLanguageTool
        case authorizeLanguageServerExecutable
        case saveBuildCommand
        case rollbackBuildCommand
        case noWorkspace
    }

    enum Message: Equatable, Sendable {
        case app(ProjectSettingsAppIssue)
        case draft(ProjectSettingsDraftError)
        case buildCommand(ProjectBuildCommandPersistenceError)
        case store(ProjectSettingsStoreError)
        case parse(ProjectSettingsParseError)
        case languageServerAuthorization(LanguageServerExecutableAuthorizationError)
        case securityScope(SecurityScopedAccessError)
        case verbatim(String)
    }

    let id: UUID
    let titleContent: Title
    let content: Message

    /// Stable English compatibility copy for command results and tests. Views
    /// always render `titleContent` and `content` using the current locale.
    var title: String { EditorLocale.enUS.localizedProjectSettingsIssueTitle(titleContent) }
    var message: String { EditorLocale.enUS.localizedProjectSettingsIssue(content) }

    init(id: UUID = UUID(), title: Title, appIssue: ProjectSettingsAppIssue) {
        self.id = id
        self.titleContent = title
        self.content = .app(appIssue)
    }

    init(id: UUID = UUID(), title: Title, error: any Error) {
        self.id = id
        self.titleContent = title
        if let draftError = error as? ProjectSettingsDraftError {
            content = .draft(draftError)
        } else if let persistenceError = error as? ProjectBuildCommandPersistenceError {
            content = .buildCommand(persistenceError)
        } else if let storeError = error as? ProjectSettingsStoreError {
            content = .store(storeError)
        } else if let parseError = error as? ProjectSettingsParseError {
            content = .parse(parseError)
        } else if let authorizationError = error as? LanguageServerExecutableAuthorizationError {
            content = .languageServerAuthorization(authorizationError)
        } else if let scopeError = error as? SecurityScopedAccessError {
            content = .securityScope(scopeError)
        } else {
            content = .verbatim(error.localizedDescription)
        }
    }
}

enum ProjectSettingsAppIssue: Equatable, Sendable {
    case storeWorkspaceMismatch
    case noWorkspace
}

enum ProjectSettingsDraftError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSONObject(String)
    case invalidJSONArray(String)
    case draftTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidJSONObject(section):
            return "\(section) must be a valid JSON object."
        case let .invalidJSONArray(section):
            return "\(section) must be a valid JSON array."
        case let .draftTooLarge(maximum):
            return "Project settings must use at most \(maximum) UTF-8 bytes."
        }
    }
}

enum ProjectBuildCommandPersistenceError: Error, Equatable, LocalizedError, Sendable {
    case workspaceUnavailable(URL)
    case workspaceMismatch(expected: URL, actual: URL)
    case rollbackStateChanged

    var errorDescription: String? {
        switch self {
        case let .workspaceUnavailable(workspace):
            return "Project settings are not ready for \(workspace.path)."
        case let .workspaceMismatch(expected, actual):
            return "Project settings belong to \(actual.path), not the approved build workspace \(expected.path)."
        case .rollbackStateChanged:
            return "Project settings changed before the build-command rollback completed."
        }
    }
}

struct ProjectBuildCommandPersistenceReceipt {
    let workspaceURL: URL
    let previousCommand: String
    let committedCommand: String
    let committedRevision: String
}

/// Editable text representation used by the standalone SwiftUI project panel.
/// Complex nested DTOs stay JSON so every Electron field remains representable;
/// `validatedSettings()` sends all sections through the Core sanitizer together.
struct ProjectSettingsDraft: Equatable, Sendable {
    var excludeText: String
    var buildCommand: String
    var keyBindingsJSON: String
    var pluginsText: String
    var pluginPermissionsJSON: String
    var languageToolsJSON: String
    var languageServersJSON: String
    var buildSystemsJSON: String
    var keyBindingRulesJSON: String
    var marketplaceURLsText: String
    var snippetsJSON: String

    init(settings: ProjectSettings = .empty) {
        excludeText = settings.exclude.joined(separator: "\n")
        buildCommand = settings.buildCommand
        keyBindingsJSON = Self.prettyJSON(settings.keyBindings, fallback: "{}")
        pluginsText = settings.plugins.joined(separator: "\n")
        pluginPermissionsJSON = Self.prettyJSON(
            settings.pluginPermissions, fallback: "{}"
        )
        languageToolsJSON = Self.prettyJSON(settings.languageTools, fallback: "{}")
        languageServersJSON = Self.prettyJSON(settings.languageServers, fallback: "{}")
        buildSystemsJSON = Self.prettyJSON(settings.buildSystems, fallback: "[]")
        keyBindingRulesJSON = Self.prettyJSON(
            settings.keyBindingRules, fallback: "[]"
        )
        marketplaceURLsText = settings.marketplaceUrls.joined(separator: "\n")
        snippetsJSON = Self.prettyJSON(settings.snippets, fallback: "[]")
    }

    func validatedSettings() throws -> ProjectSettings {
        let object: [String: Any] = [
            "exclude": Self.lines(excludeText),
            "buildCommand": buildCommand,
            "keyBindings": try Self.object(keyBindingsJSON, section: "Key bindings"),
            "plugins": Self.lines(pluginsText, alsoSplitCommas: true),
            "pluginPermissions": try Self.object(
                pluginPermissionsJSON, section: "Plugin permissions"
            ),
            "languageTools": try Self.object(languageToolsJSON, section: "Language tools"),
            "languageServers": try Self.object(
                languageServersJSON, section: "Language servers"
            ),
            "buildSystems": try Self.array(buildSystemsJSON, section: "Build systems"),
            "keyBindingRules": try Self.array(
                keyBindingRulesJSON, section: "Key binding rules"
            ),
            "marketplaceUrls": Self.lines(marketplaceURLsText),
            "snippets": try Self.array(snippetsJSON, section: "Snippets")
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= ProjectSettingsSanitizer.maximumSerializedBytes else {
            throw ProjectSettingsDraftError.draftTooLarge(
                maximumBytes: ProjectSettingsSanitizer.maximumSerializedBytes
            )
        }
        return try ProjectSettingsSanitizer.parse(data)
    }

    private static func lines(_ text: String, alsoSplitCommas: Bool = false) -> [String] {
        text.split { character in
            character.isNewline || (alsoSplitCommas && character == ",")
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func object(_ text: String, section: String) throws -> [String: Any] {
        do {
            guard let value = try parse(text) as? [String: Any] else {
                throw ProjectSettingsDraftError.invalidJSONObject(section)
            }
            return value
        } catch let error as ProjectSettingsDraftError {
            throw error
        } catch {
            throw ProjectSettingsDraftError.invalidJSONObject(section)
        }
    }

    private static func array(_ text: String, section: String) throws -> [Any] {
        do {
            guard let value = try parse(text) as? [Any] else {
                throw ProjectSettingsDraftError.invalidJSONArray(section)
            }
            return value
        } catch let error as ProjectSettingsDraftError {
            throw error
        } catch {
            throw ProjectSettingsDraftError.invalidJSONArray(section)
        }
    }

    private static func parse(_ text: String) throws -> Any {
        guard let data = text.data(using: .utf8),
              data.count <= ProjectSettingsSanitizer.maximumSerializedBytes else {
            throw ProjectSettingsDraftError.draftTooLarge(
                maximumBytes: ProjectSettingsSanitizer.maximumSerializedBytes
            )
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func prettyJSON<T: Encodable>(_ value: T, fallback: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return fallback }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Main-actor owner for one authorised primary workspace's project settings.
/// The shell may register `project-settings`, observe `settings`, and present
/// `ProjectSettingsView` whenever `isPresented` becomes true.
@MainActor
final class ProjectSettingsController: ObservableObject {
    typealias DidCommit = @MainActor (ProjectSettings, URL) -> Void
    typealias ExclusionsDidChange = @MainActor ([String]) -> Void
    typealias ChooseLanguageServerExecutable = @MainActor () async -> URL?
    typealias AuthorizeLanguageServerExecutable = @MainActor (URL) async throws -> URL
    typealias RevokeLanguageServerExecutables = @MainActor () async -> Void

    @Published private(set) var workspaceURL: URL?
    @Published private(set) var settings: ProjectSettings = .empty
    @Published private(set) var draft = ProjectSettingsDraft()
    @Published private(set) var isPresented = false
    @Published private(set) var isSaving = false
    @Published private(set) var issue: ProjectSettingsPresentationIssue?
    @Published private(set) var canReloadAfterConflict = false
    @Published private(set) var isChoosingLanguageServerExecutable = false
    @Published private(set) var authorizedLanguageServerExecutableURLs: [URL] = []

    private var store: ProjectSettingsStore?
    private var revision: String?
    private var loadFailureRevision: String?
    private let chooseLanguageServerExecutableAction: ChooseLanguageServerExecutable
    private let authorizeLanguageServerExecutableAction: AuthorizeLanguageServerExecutable
    private let revokeLanguageServerExecutablesAction: RevokeLanguageServerExecutables
    private let securityScopedAccess: SecurityScopedAccessController
    private var languageServerExecutableLeases: [URL: SecurityScopedResourceLease] = [:]
    private let didCommit: DidCommit
    private let exclusionsDidChange: ExclusionsDidChange

    init(
        chooseLanguageServerExecutable: @escaping ChooseLanguageServerExecutable = { nil },
        authorizeLanguageServerExecutable: @escaping AuthorizeLanguageServerExecutable = { _ in
            throw LanguageServerExecutableAuthorizationError.unavailable
        },
        revokeLanguageServerExecutables: @escaping RevokeLanguageServerExecutables = {},
        securityScopedAccess: SecurityScopedAccessController = .shared,
        exclusionsDidChange: @escaping ExclusionsDidChange = { _ in },
        didCommit: @escaping DidCommit = { _, _ in }
    ) {
        chooseLanguageServerExecutableAction = chooseLanguageServerExecutable
        authorizeLanguageServerExecutableAction = authorizeLanguageServerExecutable
        revokeLanguageServerExecutablesAction = revokeLanguageServerExecutables
        self.securityScopedAccess = securityScopedAccess
        self.exclusionsDidChange = exclusionsDidChange
        self.didCommit = didCommit
    }

    var hasPendingChanges: Bool { draft != ProjectSettingsDraft(settings: settings) }
    var settingsURL: URL? { store?.settingsURL }

    /// Call after a trusted workspace chooser/session restore has authorised the
    /// root. Passing nil clears all project-derived state immediately.
    func updateWorkspace(
        _ workspaceURL: URL?,
        store injectedStore: ProjectSettingsStore? = nil
    ) {
        if injectedStore == nil, store != nil,
           let currentWorkspace = self.workspaceURL,
           let workspaceURL,
           currentWorkspace.standardizedFileURL.resolvingSymlinksInPath()
                == workspaceURL.standardizedFileURL.resolvingSymlinksInPath() {
            return
        }
        isPresented = false
        issue = nil
        canReloadAfterConflict = false
        revision = nil
        loadFailureRevision = nil
        guard let workspaceURL else {
            self.workspaceURL = nil
            store = nil
            settings = .empty
            draft = ProjectSettingsDraft()
            exclusionsDidChange([])
            return
        }

        let standardized = workspaceURL.standardizedFileURL
        self.workspaceURL = standardized
        let nextStore = injectedStore ?? ProjectSettingsStore(workspaceURL: standardized)
        guard nextStore.workspaceURL == standardized else {
            store = nil
            settings = .empty
            draft = ProjectSettingsDraft()
            exclusionsDidChange([])
            issue = ProjectSettingsPresentationIssue(
                title: .load,
                appIssue: .storeWorkspaceMismatch
            )
            return
        }
        store = nextStore
        do {
            let snapshot = try nextStore.load()
            settings = snapshot.settings
            draft = ProjectSettingsDraft(settings: snapshot.settings)
            exclusionsDidChange(snapshot.settings.exclude)
            revision = snapshot.revision
            loadFailureRevision = nil
            didCommit(snapshot.settings, standardized)
        } catch {
            settings = .empty
            draft = ProjectSettingsDraft()
            exclusionsDidChange([])
            if let storeError = error as? ProjectSettingsStoreError,
               case let .invalidContents(_, observedRevision) = storeError {
                loadFailureRevision = observedRevision
            } else {
                loadFailureRevision = nil
            }
            present(error, title: .load)
        }
    }

    func present() {
        guard store != nil else {
            presentNoWorkspace()
            return
        }
        isPresented = true
    }

    func dismiss() {
        discardChanges()
        isPresented = false
    }
    func dismissIssue() {
        issue = nil
        canReloadAfterConflict = false
    }

    func setDraft<Value>(_ value: Value, for keyPath: WritableKeyPath<ProjectSettingsDraft, Value>) {
        var next = draft
        next[keyPath: keyPath] = value
        draft = next
    }

    func discardChanges() { draft = ProjectSettingsDraft(settings: settings) }

    /// Acquires a Powerbox-backed file capability before adding the exact
    /// canonical executable to the LSP manager's in-memory resolver. Editing
    /// or loading project JSON never reaches this trusted UI-only path.
    func chooseLanguageServerExecutable() async {
        guard store != nil else {
            presentNoWorkspace()
            return
        }
        guard !isChoosingLanguageServerExecutable else { return }
        isChoosingLanguageServerExecutable = true
        defer { isChoosingLanguageServerExecutable = false }
        guard let selected = await chooseLanguageServerExecutableAction() else { return }

        var lease: SecurityScopedResourceLease?
        do {
            lease = try securityScopedAccess.accessUserSelectedURL(
                selected, kind: .file
            )
            guard let lease else { return }
            let authorized = try await authorizeLanguageServerExecutableAction(lease.url)
                .standardizedFileURL.resolvingSymlinksInPath()
            languageServerExecutableLeases[authorized]?.invalidate()
            languageServerExecutableLeases[authorized] = lease
            authorizedLanguageServerExecutableURLs = languageServerExecutableLeases.keys
                .sorted { $0.path < $1.path }
            issue = nil
        } catch {
            lease?.invalidate()
            present(error, title: .authorizeLanguageServerExecutable)
        }
    }

    /// Called after language-server shutdown so no process outlives its file
    /// capability. The manager and exact approvals are session-local as well.
    func releaseLanguageServerExecutableAccess() async {
        await revokeLanguageServerExecutablesAction()
        for lease in languageServerExecutableLeases.values { lease.invalidate() }
        languageServerExecutableLeases.removeAll()
        authorizedLanguageServerExecutableURLs = []
    }

    /// Typed mutation path for focused settings panels. It uses the same
    /// revision-pinned store save and whole-project sanitizer as the JSON view.
    /// Merely updating a language-tool declaration never starts that tool.
    @discardableResult
    func saveLanguageTool(
        _ configuration: LanguageToolConfig?,
        for language: String
    ) -> Bool {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty,
              language.utf16.count
                <= ProjectSettingsSanitizer.maximumLanguageNameUTF16CodeUnits,
              !language.utf8.contains(0) else {
            present(
                ProjectSettingsDraftError.invalidJSONObject("Language tools"),
                title: .saveLanguageTool
            )
            return false
        }
        var next = settings
        if let configuration {
            next.languageTools[language] = configuration
        } else {
            next.languageTools.removeValue(forKey: language)
        }
        return saveSettings(next, failureTitle: .saveLanguageTool)
    }

    /// Persists the exact free-form command that passed the external-tool
    /// approval gate without saving an in-progress Project Settings draft.
    func persistBuildCommand(
        _ command: String, approvedWorkspaceRoot: URL
    ) throws -> ProjectBuildCommandPersistenceReceipt {
        let approvedRoot = approvedWorkspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let store, let workspaceURL else {
            let error = ProjectBuildCommandPersistenceError.workspaceUnavailable(approvedRoot)
            present(error, title: .saveBuildCommand)
            throw error
        }
        let currentRoot = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard currentRoot == approvedRoot else {
            let error = ProjectBuildCommandPersistenceError.workspaceMismatch(
                expected: approvedRoot, actual: currentRoot
            )
            present(error, title: .saveBuildCommand)
            throw error
        }
        isSaving = true
        defer { isSaving = false }
        let previousCommand = settings.buildCommand
        var candidate = settings
        candidate.buildCommand = command
        let pendingDraft = draft
        do {
            let validated = candidate.sanitized()
            let result = try store.save(
                validated, expectedRevision: revision ?? loadFailureRevision
            )
            settings = validated
            draft = pendingDraft
            draft.buildCommand = validated.buildCommand
            exclusionsDidChange(validated.exclude)
            revision = result.revision
            loadFailureRevision = nil
            issue = nil
            canReloadAfterConflict = false
            didCommit(validated, workspaceURL)
            return ProjectBuildCommandPersistenceReceipt(
                workspaceURL: currentRoot,
                previousCommand: previousCommand,
                committedCommand: validated.buildCommand,
                committedRevision: result.revision
            )
        } catch {
            present(error, title: .saveBuildCommand)
            throw error
        }
    }

    /// Checked compensation for a command saved immediately before a failed
    /// global settings write. Concurrent project edits prevent rollback.
    func rollbackBuildCommand(
        _ receipt: ProjectBuildCommandPersistenceReceipt
    ) throws {
        guard workspaceURL?.standardizedFileURL.resolvingSymlinksInPath()
                == receipt.workspaceURL,
              revision == receipt.committedRevision,
              settings.buildCommand == receipt.committedCommand else {
            throw ProjectBuildCommandPersistenceError.rollbackStateChanged
        }
        var candidate = settings
        candidate.buildCommand = receipt.previousCommand
        let pendingDraft = draft
        do {
            let validated = candidate.sanitized()
            let result = try store?.save(
                validated, expectedRevision: receipt.committedRevision
            )
            guard let result else {
                throw ProjectBuildCommandPersistenceError.workspaceUnavailable(
                    receipt.workspaceURL
                )
            }
            settings = validated
            draft = pendingDraft
            draft.buildCommand = validated.buildCommand
            exclusionsDidChange(validated.exclude)
            revision = result.revision
            issue = nil
            canReloadAfterConflict = false
            didCommit(validated, receipt.workspaceURL)
        } catch {
            present(error, title: .rollbackBuildCommand)
            throw error
        }
    }

    /// Composition-facing read API for the exact current-language declaration.
    func languageTool(for language: String) -> LanguageToolConfig? {
        settings.languageTools[language]
    }

    @discardableResult
    func reload() -> Bool {
        guard let store, let workspaceURL else {
            presentNoWorkspace()
            return false
        }
        do {
            let snapshot = try store.load()
            settings = snapshot.settings
            draft = ProjectSettingsDraft(settings: snapshot.settings)
            exclusionsDidChange(snapshot.settings.exclude)
            revision = snapshot.revision
            loadFailureRevision = nil
            issue = nil
            canReloadAfterConflict = false
            didCommit(snapshot.settings, workspaceURL)
            return true
        } catch {
            present(error, title: .reload)
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let store, let workspaceURL else {
            presentNoWorkspace()
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let validated = try draft.validatedSettings()
            let result = try store.save(
                validated, expectedRevision: revision ?? loadFailureRevision
            )
            settings = validated
            draft = ProjectSettingsDraft(settings: validated)
            exclusionsDidChange(validated.exclude)
            revision = result.revision
            loadFailureRevision = nil
            issue = nil
            canReloadAfterConflict = false
            didCommit(validated, workspaceURL)
            return true
        } catch {
            present(error, title: .save)
            return false
        }
    }

    @discardableResult
    private func saveSettings(
        _ candidate: ProjectSettings,
        failureTitle: ProjectSettingsPresentationIssue.Title
    ) -> Bool {
        guard let store, let workspaceURL else {
            presentNoWorkspace()
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let validated = candidate.sanitized()
            let result = try store.save(
                validated, expectedRevision: revision ?? loadFailureRevision
            )
            settings = validated
            draft = ProjectSettingsDraft(settings: validated)
            exclusionsDidChange(validated.exclude)
            revision = result.revision
            loadFailureRevision = nil
            issue = nil
            canReloadAfterConflict = false
            didCommit(validated, workspaceURL)
            return true
        } catch {
            present(error, title: failureTitle)
            return false
        }
    }

    @discardableResult
    func saveAndDismiss() -> Bool {
        guard save() else { return false }
        isPresented = false
        return true
    }

    /// Adopts a snapshot that another descriptor-anchored writer just saved.
    /// This avoids a second, fallible read after the atomic rename while still
    /// keeping this controller's optimistic-concurrency revision current.
    func adoptPersistedSettings(
        _ persistedSettings: ProjectSettings,
        revision persistedRevision: String,
        workspaceURL: URL,
        store persistedStore: ProjectSettingsStore
    ) {
        let workspaceURL = workspaceURL.standardizedFileURL
        precondition(persistedStore.workspaceURL == workspaceURL)
        self.workspaceURL = workspaceURL
        store = persistedStore
        settings = persistedSettings.sanitized()
        draft = ProjectSettingsDraft(settings: settings)
        exclusionsDidChange(settings.exclude)
        revision = persistedRevision
        loadFailureRevision = nil
        issue = nil
        canReloadAfterConflict = false
        didCommit(settings, workspaceURL)
    }

    /// Command-router integration kept outside the application shell.
    @discardableResult
    func registerCommand(
        on router: CommandRouter,
        replaceExisting: Bool = false
    ) throws -> CommandHandlerToken {
        try router.register(
            "project-settings",
            replaceExisting: replaceExisting,
            enablement: { [weak self] context in
                guard context.availableRequirements.contains(.workspace),
                      self?.store != nil else {
                    return .disabled(reason: "No workspace")
                }
                return self?.isSaving == true
                    ? .disabled(reason: "Project settings are being saved")
                    : .enabled
            },
            handler: { [weak self] _ in
                guard let self else {
                    throw CommandHandlerSignal.unavailable(
                        reason: "Project settings unavailable"
                    )
                }
                self.present()
            }
        )
    }

    private func presentNoWorkspace() {
        canReloadAfterConflict = false
        issue = ProjectSettingsPresentationIssue(
            title: .noWorkspace,
            appIssue: .noWorkspace
        )
    }

    private func present(
        _ error: any Error, title: ProjectSettingsPresentationIssue.Title
    ) {
        if case .conflict = error as? ProjectSettingsStoreError {
            canReloadAfterConflict = true
        } else {
            canReloadAfterConflict = false
        }
        issue = ProjectSettingsPresentationIssue(title: title, error: error)
    }
}
