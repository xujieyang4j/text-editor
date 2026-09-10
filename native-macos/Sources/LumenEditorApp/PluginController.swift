import Combine
import Foundation
import LumenEditorCore

struct PluginPresentationIssue: Identifiable, Equatable, Sendable {
    enum Message: Equatable, Sendable {
        case app(AppLocalizedCopy)
        case marketplaceClient(MarketplaceClientError)
        case marketplaceFailures([MarketplaceCatalogFailure.Reason])
        case pluginStore(PluginStoreError)
        case manifestValidation(PluginManifestValidationError)
        case verbatim(String)
    }

    let id = UUID()
    let titleCopy: AppLocalizedCopy
    let content: Message

    /// Stable English text retained for command-routing compatibility. Views
    /// render the structured values with their current runtime locale.
    var title: String { EditorLocale.enUS.localizedApp(titleCopy) }
    var message: String { EditorLocale.enUS.localizedPluginIssue(content) }

    init(title: AppLocalizedCopy, content: Message) {
        titleCopy = title
        self.content = content
    }
}

/// Stable, collision-free ID used by the shell when it merges plugin commands
/// into its command-palette data source. No executable closure is stored here.
struct PluginCommandRoute: Identifiable, Equatable, Sendable {
    let id: String
    let pluginID: String
    let pluginName: String
    let commandID: String
    let title: String
    let insertText: String
    let requirements: CommandRequirements = .document

    init?(
        plugin: InstalledPlugin,
        contribution: PluginCommandContribution,
        index: Int
    ) {
        guard plugin.isEnabled, let insertText = contribution.insertText else { return nil }
        pluginID = plugin.id
        pluginName = plugin.manifest.name
        commandID = contribution.id
        title = contribution.title
        self.insertText = insertText
        // Contribution IDs are bounded but need not be unique. The manifest
        // index keeps SwiftUI and shell routing identities collision-free.
        id = "plugin:\(plugin.id):\(index)"
    }
}

struct PluginSnippetRoute: Identifiable, Equatable, Sendable {
    let id: String
    let pluginID: String
    let pluginName: String
    let label: String
    let text: String
    let trigger: String?
    let scope: String?

    init(plugin: InstalledPlugin, contribution: PluginSnippetContribution, index: Int) {
        pluginID = plugin.id
        pluginName = plugin.manifest.name
        label = contribution.label
        text = contribution.text
        trigger = contribution.trigger
        scope = contribution.scope
        id = "plugin-snippet:\(plugin.id):\(index)"
    }
}

/// Immutable hand-off used by the application shell. A snapshot contains no
/// callbacks, worker handles or filesystem access.
struct PluginShellSnapshot: Equatable, Sendable {
    let commands: [PluginCommandRoute]
    let workerCommands: [PluginWorkerCommandRoute]
    let snippets: [PluginSnippetRoute]
    let workerExecutionSupport: PluginWorkerExecutionSupport

    init(
        commands: [PluginCommandRoute],
        workerCommands: [PluginWorkerCommandRoute] = [],
        snippets: [PluginSnippetRoute],
        workerExecutionSupport: PluginWorkerExecutionSupport
    ) {
        self.commands = commands
        self.workerCommands = workerCommands
        self.snippets = snippets
        self.workerExecutionSupport = workerExecutionSupport
    }
}

struct RoutedPluginCommandSearchResult: Identifiable, Equatable, Sendable {
    let route: PluginCommandRoute
    let fuzzyResult: FuzzyResult
    let status: CommandRouteStatus

    var id: String { route.id }
}

enum PluginCommandRoutingResult: Equatable, Sendable {
    case insertText(String)
    case unavailable(CommandRouteStatus)
    case unknownCommand(String)
}

/// Shell-facing contract for native declarative plugins.
///
/// The application shell owns workspace selection, confirmation dialogs and
/// editor mutations. It supplies a `PluginStore` for the authorised workspace,
/// observes `commandRoutes` / `snippetRoutes`, and invokes `insertText(for:)`
/// through its existing one-transaction editor insertion path. Dynamic plugin
/// IDs cannot be registered in the static `CommandCatalog`, so the shell merges
/// these value rows into the palette next to `CommandRouter.search` results.
/// Worker routes are supplied by the isolated worker runtime when connected by
/// the application shell; declarative contributions remain available alone.
@MainActor
final class PluginController: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var commandRoutes: [PluginCommandRoute] = []
    @Published private(set) var workerCommandRoutes: [PluginWorkerCommandRoute] = []
    @Published private(set) var pendingWorkerApproval: PluginWorkerApprovalRequest?
    @Published private(set) var workerIssue: PluginWorkerRuntimeIssue?
    @Published private(set) var isWorkerRunning = false
    @Published private(set) var snippetRoutes: [PluginSnippetRoute] = []
    @Published private(set) var marketplaceItems: [MarketplaceItem] = []
    @Published private(set) var marketplaceFailures: [MarketplaceCatalogFailure] = []
    @Published private(set) var isBusy = false
    @Published private(set) var issue: PluginPresentationIssue?

    var workerExecutionSupport: PluginWorkerExecutionSupport {
        workerRuntime == nil ? .unsupported : .isolatedProcess
    }

    private let marketplaceClient: MarketplaceClient
    let workerRuntime: PluginWorkerRuntimeController?
    private var store: PluginStore?
    private var operationGeneration: UInt = 0
    private var workerSynchronizationGeneration: UInt = 0
    private var workerSynchronizationTask: Task<Void, Never>?

    init(
        marketplaceClient: MarketplaceClient = MarketplaceClient(),
        workerRuntime: PluginWorkerRuntimeController? = nil
    ) {
        self.marketplaceClient = marketplaceClient
        self.workerRuntime = workerRuntime
        if let workerRuntime {
            workerRuntime.$commandRoutes.assign(to: &$workerCommandRoutes)
            workerRuntime.$pendingApproval.assign(to: &$pendingWorkerApproval)
            workerRuntime.$issue.assign(to: &$workerIssue)
            workerRuntime.$isRunning.assign(to: &$isWorkerRunning)
        }
    }

    static func production(
        model: AppModel,
        approvals: ToolApprovalStore,
        scope: ToolApprovalScope,
        notify: @escaping PluginWorkerRuntimeController.Notify = { _ in }
    ) -> PluginController {
        PluginController(
            workerRuntime: PluginWorkerRuntimeController.production(
                model: model, approvals: approvals, scope: scope, notify: notify
            )
        )
    }

    var shellSnapshot: PluginShellSnapshot {
        PluginShellSnapshot(
            commands: commandRoutes,
            workerCommands: workerCommandRoutes,
            snippets: snippetRoutes,
            workerExecutionSupport: workerExecutionSupport
        )
    }

    /// The shell calls this whenever its authorised primary workspace changes.
    func updateWorkspace(_ workspaceURL: URL?, store injectedStore: PluginStore? = nil) {
        let normalizedWorkspace = workspaceURL?.standardizedFileURL
        // The surrounding workspace-context task also tracks the selected
        // file. A tab switch must not tear down and reload the plugin runtime
        // when the authorised project root itself did not change. Tests may
        // still inject a store to request an explicit replacement.
        if injectedStore == nil, normalizedWorkspace == self.workspaceURL { return }
        operationGeneration &+= 1
        self.workspaceURL = normalizedWorkspace
        store = normalizedWorkspace.map { injectedStore ?? PluginStore(workspaceURL: $0) }
        isBusy = false
        plugins = []
        rebuildContributions()
        marketplaceItems = []
        marketplaceFailures = []
        refresh()
    }

    func refresh() {
        guard let store else {
            plugins = []
            rebuildContributions()
            issue = nil
            synchronizeWorkers()
            return
        }
        do {
            plugins = try store.listInstalledPlugins()
            rebuildContributions()
            synchronizeWorkers()
            issue = nil
        } catch {
            present(error, title: .couldNotLoadPlugins)
        }
    }

    func refreshWorkers() {
        synchronizeWorkers()
    }

    @discardableResult
    func installLocalPlugin(from sourceURL: URL) -> Bool {
        guard let store else {
            presentNoWorkspace()
            return false
        }
        do {
            _ = try store.installLocalPlugin(from: sourceURL)
            plugins = try store.listInstalledPlugins()
            rebuildContributions()
            synchronizeWorkers()
            issue = nil
            return true
        } catch {
            present(error, title: .couldNotInstallPlugin)
            return false
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, pluginID: String) -> Bool {
        guard let store else {
            presentNoWorkspace()
            return false
        }
        do {
            try store.setEnabled(enabled, forPluginID: pluginID)
            plugins = try store.listInstalledPlugins()
            rebuildContributions()
            synchronizeWorkers()
            issue = nil
            return true
        } catch {
            present(error, title: .couldNotUpdatePlugin)
            return false
        }
    }

    @discardableResult
    func setPermission(
        _ permission: PluginPermission,
        granted: Bool,
        pluginID: String
    ) -> Bool {
        guard let store, let plugin = plugins.first(where: { $0.id == pluginID }) else {
            presentNoWorkspace()
            return false
        }
        var grants = plugin.grantedPermissions
        if granted {
            if !grants.contains(permission) { grants.append(permission) }
        } else {
            grants.removeAll { $0 == permission }
        }
        do {
            try store.setGrantedPermissions(grants, forPluginID: pluginID)
            plugins = try store.listInstalledPlugins()
            rebuildContributions()
            synchronizeWorkers()
            issue = nil
            return true
        } catch {
            present(error, title: .couldNotUpdatePluginPermissions)
            return false
        }
    }

    @discardableResult
    func uninstallPlugin(id: String) -> Bool {
        guard let store else {
            presentNoWorkspace()
            return false
        }
        do {
            try store.uninstallPlugin(id: id)
            plugins = try store.listInstalledPlugins()
            rebuildContributions()
            synchronizeWorkers()
            issue = nil
            return true
        } catch {
            present(error, title: .couldNotRemovePlugin)
            return false
        }
    }

    @discardableResult
    func setMarketplaceSources(_ sources: [String]) -> Bool {
        guard let store else {
            presentNoWorkspace()
            return false
        }
        do {
            try store.setMarketplaceSources(sources)
            marketplaceItems = []
            marketplaceFailures = []
            issue = nil
            return true
        } catch {
            present(error, title: .couldNotSaveMarketplaceSettings)
            return false
        }
    }

    func refreshMarketplace() async {
        guard let store else {
            presentNoWorkspace()
            return
        }
        let sources: [URL]
        do {
            sources = try store.loadProjectState().marketplaceSources.compactMap(URL.init(string:))
        } catch {
            present(error, title: .couldNotLoadMarketplaceSettings)
            return
        }
        guard !sources.isEmpty else {
            marketplaceItems = []
            marketplaceFailures = []
            issue = PluginPresentationIssue(
                title: .noMarketplaceSources,
                content: .app(.addHTTPSMarketplaceSourceFirst)
            )
            return
        }

        operationGeneration &+= 1
        let generation = operationGeneration
        isBusy = true
        let result = await marketplaceClient.fetchCatalogs(from: sources)
        guard generation == operationGeneration else { return }
        marketplaceItems = result.items
        marketplaceFailures = result.failures
        isBusy = false
        issue = result.items.isEmpty && !result.failures.isEmpty
            ? PluginPresentationIssue(
                title: .couldNotLoadMarketplace,
                content: .marketplaceFailures(result.failures.map(\.reason))
            )
            : nil
    }

    /// Call only after the view/shell has shown the manifest URL and obtained
    /// explicit user confirmation. No install occurs while merely browsing.
    @discardableResult
    func installMarketplaceItem(_ item: MarketplaceItem) async -> Bool {
        guard let store else {
            presentNoWorkspace()
            return false
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        isBusy = true
        do {
            let package = try await marketplaceClient.downloadPlugin(for: item)
            guard generation == operationGeneration else { return false }
            _ = try store.installMarketplacePlugin(package)
            plugins = try store.listInstalledPlugins()
            rebuildContributions()
            synchronizeWorkers()
            isBusy = false
            issue = nil
            return true
        } catch is CancellationError {
            if generation == operationGeneration { isBusy = false }
            return false
        } catch {
            guard generation == operationGeneration else { return false }
            isBusy = false
            present(error, title: .couldNotInstallMarketplacePlugin)
            return false
        }
    }

    func insertText(for routeID: String) -> String? {
        commandRoutes.first(where: { $0.id == routeID })?.insertText
    }

    @discardableResult
    func runWorkerCommand(_ routeID: String) async -> Bool {
        await workerRuntime?.runCommand(routeID: routeID) ?? false
    }

    func confirmPendingWorkerApproval() async {
        await workerRuntime?.confirmPendingApproval()
    }

    func approveWorker(_ request: PluginWorkerApprovalRequest) async {
        await workerRuntime?.approve(request)
    }

    func declinePendingWorkerApproval() {
        workerRuntime?.declinePendingApproval()
    }

    func dismissWorkerIssue() { workerRuntime?.dismissIssue() }

    func deactivateWorkers() async {
        workerSynchronizationGeneration &+= 1
        workerSynchronizationTask?.cancel()
        workerSynchronizationTask = nil
        await workerRuntime?.deactivateAll()
    }

    func snippets(scope: String? = nil, trigger: String? = nil) -> [PluginSnippetRoute] {
        snippetRoutes.filter { snippet in
            (scope == nil || snippet.scope == nil || snippet.scope == scope)
                && (trigger == nil || snippet.trigger == trigger)
        }
    }

    func dismissIssue() { issue = nil }

    private func synchronizeWorkers() {
        guard let workerRuntime else { return }
        workerSynchronizationGeneration &+= 1
        let generation = workerSynchronizationGeneration
        workerSynchronizationTask?.cancel()
        let workspaceURL = workspaceURL
        let plugins = plugins
        let store = store
        workerSynchronizationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  self.workerSynchronizationGeneration == generation else { return }
            await workerRuntime.update(
                workspaceRoot: workspaceURL, plugins: plugins, store: store
            )
            guard self.workerSynchronizationGeneration == generation else { return }
            self.workerSynchronizationTask = nil
        }
    }

    private func rebuildContributions() {
        let enabled = plugins.filter(\.isEnabled)
        commandRoutes = enabled.flatMap { plugin in
            plugin.manifest.commands.enumerated().compactMap { index, contribution in
                PluginCommandRoute(
                    plugin: plugin, contribution: contribution, index: index
                )
            }
        }
        snippetRoutes = enabled.flatMap { plugin in
            plugin.manifest.snippets.enumerated().map { index, contribution in
                PluginSnippetRoute(plugin: plugin, contribution: contribution, index: index)
            }
        }
    }

    private func presentNoWorkspace() {
        issue = PluginPresentationIssue(
            title: .noWorkspaceOpen,
            content: .app(.openWorkspaceBeforeManagingProjectPlugins)
        )
    }

    private func present(_ error: any Error, title: AppLocalizedCopy) {
        issue = PluginPresentationIssue(
            title: title, content: Self.presentationMessage(for: error)
        )
    }

    static func presentationMessage(for error: any Error) -> PluginPresentationIssue.Message {
        if let error = error as? MarketplaceClientError {
            return .marketplaceClient(error)
        }
        if let error = error as? PluginStoreError {
            return .pluginStore(error)
        }
        if let error = error as? PluginManifestValidationError {
            return .manifestValidation(error)
        }
        return .verbatim(error.localizedDescription)
    }
}

/// Dynamic declarative contributions remain separate from the compile-time
/// `CommandCatalog`, but use the same routing context and fuzzy matcher. The
/// shell merges these rows with `search(_:locale:context:)` and applies the
/// returned insertion through AppModel as one undoable transaction.
extension CommandRouter {
    func searchPluginCommands(
        _ query: String,
        routes: [PluginCommandRoute],
        context: CommandRoutingContext
    ) -> [RoutedPluginCommandSearchResult] {
        CommandFuzzyMatcher.filter(query: query, items: routes) { route in
            route.pluginName + ": " + route.title
        }.map { match in
            let missing = match.item.requirements
                .subtracting(context.availableRequirements)
            return RoutedPluginCommandSearchResult(
                route: match.item,
                fuzzyResult: match.result,
                status: missing.isEmpty
                    ? .enabled
                    : .disabled(.missingRequirements(missing))
            )
        }
    }

    func routePluginCommand(
        _ routeID: String,
        routes: [PluginCommandRoute],
        context: CommandRoutingContext
    ) -> PluginCommandRoutingResult {
        guard let route = routes.first(where: { $0.id == routeID }) else {
            return .unknownCommand(routeID)
        }
        let missing = route.requirements.subtracting(context.availableRequirements)
        guard missing.isEmpty else {
            return .unavailable(.disabled(.missingRequirements(missing)))
        }
        return .insertText(route.insertText)
    }
}
