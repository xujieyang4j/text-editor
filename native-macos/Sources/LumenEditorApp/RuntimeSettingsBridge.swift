import Combine
import Foundation
import LumenEditorCore

@MainActor
enum BuildCommandPersistenceTransaction {
    static func commit<Receipt>(
        persistProject: () throws -> Receipt,
        persistGlobal: () throws -> Void,
        rollbackProject: (Receipt) throws -> Void
    ) throws {
        let receipt: Receipt
        do {
            receipt = try persistProject()
        } catch {
            throw BuildCommandPersistenceError.projectWriteFailed(
                error.localizedDescription
            )
        }

        do {
            try persistGlobal()
        } catch {
            let globalFailure = error.localizedDescription
            do {
                try rollbackProject(receipt)
            } catch {
                throw BuildCommandPersistenceError.partialPersistence(
                    globalFailure: globalFailure,
                    projectRollbackFailure: error.localizedDescription
                )
            }
            throw BuildCommandPersistenceError.globalWriteFailed(globalFailure)
        }
    }
}

/// Connects the shared persisted settings snapshot to window-scoped runtime
/// controllers. The bridge owns its subscriptions for the lifetime of one
/// window composition; callbacks use weak references to avoid retain cycles.
@MainActor
final class RuntimeSettingsBridge {
    private var subscriptions: Set<AnyCancellable> = []
    private weak var settings: SettingsController?

    init(
        settings: SettingsController,
        build: BuildController,
        find: FindBarController,
        workspaceSearch: WorkspaceSearchController,
        projectSettings: ProjectSettingsController
    ) {
        self.settings = settings
        build.bindFreeFormCommand(initialValue: settings.settings.buildCommand) {
            [weak settings, weak projectSettings] configuration in
            guard let settings, let projectSettings else {
                throw BuildCommandPersistenceError.projectWriteFailed(
                    "The settings bridge is no longer available."
                )
            }
            try BuildCommandPersistenceTransaction.commit(
                persistProject: {
                    try projectSettings.persistBuildCommand(
                        configuration.executable,
                        approvedWorkspaceRoot: configuration.root
                    )
                },
                persistGlobal: {
                    try settings.persistBuildCommand(configuration.executable)
                },
                rollbackProject: { receipt in
                    try projectSettings.rollbackBuildCommand(receipt)
                }
            )
        }
        build.synchronizeProjectBuildCommand(projectSettings.settings.buildCommand)
        find.setHistoryIntegration(
            search: { [weak settings] in settings?.settings.searchHistory ?? [] },
            replace: { [weak settings] in settings?.settings.replaceHistory ?? [] },
            record: { [weak settings] search, replacement in
                settings?.rememberSearchHistory(search, replacement: replacement)
            }
        )
        workspaceSearch.setHistoryIntegration(
            search: { [weak settings] in settings?.settings.searchHistory ?? [] },
            replace: { [weak settings] in settings?.settings.replaceHistory ?? [] },
            record: { [weak settings] search, replacement in
                settings?.rememberSearchHistory(search, replacement: replacement)
            }
        )

        settings.$settings
            .removeDuplicates()
            .sink { [weak build, weak find, weak workspaceSearch] snapshot in
                build?.synchronizePersistedFreeFormCommand(snapshot.buildCommand)
                find?.synchronizeHistory(
                    search: snapshot.searchHistory, replace: snapshot.replaceHistory
                )
                workspaceSearch?.synchronizeHistory(
                    search: snapshot.searchHistory, replace: snapshot.replaceHistory
                )
            }
            .store(in: &subscriptions)

        projectSettings.$settings
            .map(\.buildCommand)
            .removeDuplicates()
            .sink { [weak build] command in
                build?.synchronizeProjectBuildCommand(command)
            }
            .store(in: &subscriptions)
    }

    /// Reveal Active File must make persistent chrome visible before the
    /// workspace begins expanding the tree. Failure leaves runtime state intact.
    func prepareSidebarReveal() -> Bool {
        guard let settings else { return false }
        return settings.persistDistractionFree(false)
    }
}
