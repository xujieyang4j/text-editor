import AppKit
import Darwin
@preconcurrency import Foundation
import LumenEditorCore
import UniformTypeIdentifiers

enum SublimeImportProductionError: Error, Equatable, LocalizedError, Sendable {
    case pickerAlreadyPresented
    case invalidSourceURL(URL)
    case sourceOpenFailed(code: Int32)
    case sourceInspectionFailed(code: Int32)
    case sourceIsNotRegularFile
    case sourceTooLarge(actualBytes: Int64, maximumBytes: Int)
    case sourceReadFailed(code: Int32)
    case sourceChangedDuringRead
    case workspaceRequired(SublimeImportKind)
    case projectSettingsHavePendingChanges
    case projectRootSelectionCancelled(URL)
    case projectRootSelectionMismatch(expected: URL, selected: URL)
    case projectRootAuthorizationFailed(URL)
    case projectRollbackFailed(original: String, rollback: String)
    case settingsPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .pickerAlreadyPresented:
            "Another Sublime import file picker is already open."
        case .invalidSourceURL:
            "A Sublime import source must be an absolute local file URL."
        case let .sourceOpenFailed(code):
            "The selected Sublime file could not be opened (errno \(code))."
        case let .sourceInspectionFailed(code):
            "The selected Sublime file could not be inspected (errno \(code))."
        case .sourceIsNotRegularFile:
            "The selected Sublime source must be a regular file, not a folder or symbolic link."
        case let .sourceTooLarge(actual, maximum):
            "The selected Sublime file uses \(actual) bytes; the maximum is \(maximum) bytes."
        case let .sourceReadFailed(code):
            "The selected Sublime file could not be read (errno \(code))."
        case .sourceChangedDuringRead:
            "The selected Sublime file changed while it was being read. Select it again."
        case let .workspaceRequired(kind):
            "Open a workspace before importing a Sublime \(kind.displayName.lowercased())."
        case .projectSettingsHavePendingChanges:
            "Save or discard the open project-settings draft before importing Sublime data."
        case let .projectRootSelectionCancelled(url):
            "Authorization was cancelled for project folder: \(url.path)"
        case let .projectRootSelectionMismatch(expected, selected):
            "The selected folder (\(selected.path)) does not match the project folder awaiting authorization (\(expected.path))."
        case let .projectRootAuthorizationFailed(url):
            "The project folder could not be authorised: \(url.path)"
        case let .projectRollbackFailed(original, rollback):
            "The import failed (\(original)), and its workspace authorization could not be fully rolled back (\(rollback))."
        case .settingsPersistenceFailed:
            "The imported settings could not be persisted; the previous settings were restored."
        }
    }
}

/// Reads one picker-returned file through a no-follow descriptor. The bound is
/// checked before allocation, enforced again while reading, and the descriptor
/// identity and timestamps are rechecked after EOF.
struct SublimeImportDescriptorReader: Sendable {
    private static let chunkSize = 64 * 1_024

    func read(_ url: URL, maximumByteCount: Int) throws -> Data {
        precondition(maximumByteCount >= 0)
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SublimeImportProductionError.invalidSourceURL(url)
        }
        let descriptor = Darwin.open(
            url.standardizedFileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw SublimeImportProductionError.sourceOpenFailed(code: errno)
        }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw SublimeImportProductionError.sourceInspectionFailed(code: errno)
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            throw SublimeImportProductionError.sourceIsNotRegularFile
        }
        guard before.st_size >= 0, before.st_size <= Int64(maximumByteCount) else {
            throw SublimeImportProductionError.sourceTooLarge(
                actualBytes: max(0, before.st_size), maximumBytes: maximumByteCount
            )
        }

        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            let remainingProbe = maximumByteCount + 1 - result.count
            guard remainingProbe > 0 else {
                throw SublimeImportProductionError.sourceTooLarge(
                    actualBytes: Int64(result.count + 1), maximumBytes: maximumByteCount
                )
            }
            let requested = min(buffer.count, remainingProbe)
            let count: Int = try buffer.withUnsafeMutableBytes { bytes in
                while true {
                    let value = Darwin.read(descriptor, bytes.baseAddress, requested)
                    if value >= 0 { return value }
                    if errno != EINTR {
                        throw SublimeImportProductionError.sourceReadFailed(code: errno)
                    }
                }
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            if result.count > maximumByteCount {
                throw SublimeImportProductionError.sourceTooLarge(
                    actualBytes: Int64(result.count), maximumBytes: maximumByteCount
                )
            }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw SublimeImportProductionError.sourceInspectionFailed(code: errno)
        }
        guard Self.sameSnapshot(before, after), result.count == Int(after.st_size) else {
            throw SublimeImportProductionError.sourceChangedDuringRead
        }
        return result
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

/// Main-actor AppKit adapter. Security-scoped access, when supplied by the
/// sandbox, exists only around the bounded descriptor read; the controller is
/// handed immutable bytes and never retains filesystem authority.
@MainActor
final class SublimeImportSourcePicker {
    typealias ChooseURL = @MainActor (SublimeImportKind) async -> URL?
    typealias CurrentLocale = @MainActor () -> EditorLocale
    typealias ReadBytes = @Sendable (URL, Int) throws -> Data
    typealias StartSecurityScope = @MainActor (URL) -> Bool
    typealias StopSecurityScope = @MainActor (URL) -> Void

    private(set) var isPresenting = false
    private let chooseURL: ChooseURL
    private let readBytes: ReadBytes
    private let startSecurityScope: StartSecurityScope
    private let stopSecurityScope: StopSecurityScope

    init(
        chooseURL: @escaping ChooseURL,
        readBytes: @escaping ReadBytes = { url, maximum in
            try SublimeImportDescriptorReader().read(url, maximumByteCount: maximum)
        },
        startSecurityScope: @escaping StartSecurityScope = {
            $0.startAccessingSecurityScopedResource()
        },
        stopSecurityScope: @escaping StopSecurityScope = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.chooseURL = chooseURL
        self.readBytes = readBytes
        self.startSecurityScope = startSecurityScope
        self.stopSecurityScope = stopSecurityScope
    }

    convenience init(currentLocale: @escaping CurrentLocale = { .zhCN }) {
        self.init(chooseURL: { kind in
            await Self.chooseWithSystemPanel(kind, locale: currentLocale())
        })
    }

    func requestSource(for kind: SublimeImportKind) async throws -> SublimeImportSource? {
        guard !isPresenting else {
            throw SublimeImportProductionError.pickerAlreadyPresented
        }
        isPresenting = true
        defer { isPresenting = false }
        guard let selectedURL = await chooseURL(kind) else { return nil }
        let url = selectedURL.standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SublimeImportProductionError.invalidSourceURL(url)
        }

        let hasSecurityScope = startSecurityScope(url)
        let sandboxed = ProcessInfo.processInfo.environment[
            "APP_SANDBOX_CONTAINER_ID"
        ] != nil
        guard hasSecurityScope || !sandboxed else {
            throw SecurityScopedAccessError.accessDenied(url.path)
        }
        defer { if hasSecurityScope { stopSecurityScope(url) } }
        let maximum = kind.maximumSourceBytes
        let readBytes = readBytes
        let data = try await Task.detached(priority: .userInitiated) {
            try readBytes(url, maximum)
        }.value
        return SublimeImportSource(sourceURL: url, data: data)
    }

    private static func chooseWithSystemPanel(
        _ kind: SublimeImportKind, locale: EditorLocale
    ) async -> URL? {
        let panel = NSOpenPanel()
        let copy = SublimeImportPanelCopy.source(kind: kind, locale: locale)
        panel.title = copy.title
        panel.message = copy.message
        panel.prompt = copy.prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let type = UTType(filenameExtension: kind.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let response = await withCheckedContinuation { continuation in
            if let window = NSApplication.shared.keyWindow, window.attachedSheet == nil {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }
}

struct SublimeImportPanelCopy: Equatable {
    let title: String
    let message: String
    let prompt: String

    static func source(
        kind: SublimeImportKind, locale: EditorLocale
    ) -> SublimeImportPanelCopy {
        SublimeImportPanelCopy(
            title: locale.localizedApp(
                .importSublime(kindName: localizedKindName(kind, locale: locale))
            ),
            message: locale.localizedApp(
                .chooseSublimeSource(fileExtension: kind.fileExtension)
            ),
            prompt: locale.localizedApp(.preview)
        )
    }

    static func projectAuthorization(
        expected: URL, locale: EditorLocale
    ) -> SublimeImportPanelCopy {
        SublimeImportPanelCopy(
            title: locale.localizedApp(.authorizeSublimeProjectFolder),
            message: locale.localizedApp(
                .confirmSublimeProjectFolder(path: expected.path)
            ),
            prompt: locale.localizedApp(.authorize)
        )
    }

    private static func localizedKindName(
        _ kind: SublimeImportKind, locale: EditorLocale
    ) -> String {
        guard locale.isSimplifiedChinese else { return kind.displayName }
        switch kind {
        case .project: "项目"
        case .settings: "设置"
        case .keymap: "快捷键映射"
        case .snippet: "代码片段"
        case .build: "构建系统"
        }
    }
}

private extension SublimeImportKind {
    var fileExtension: String {
        switch self {
        case .project: "sublime-project"
        case .settings: "sublime-settings"
        case .keymap: "sublime-keymap"
        case .snippet: "sublime-snippet"
        case .build: "sublime-build"
        }
    }

    var maximumSourceBytes: Int {
        switch self {
        case .snippet: SublimeImportLimits.default.maximumSnippetBytes
        default: SublimeImportLimits.default.maximumJSONBytes
        }
    }
}

private extension EditorSettings {
    mutating func applySublimeChanges(
        from imported: EditorSettings, changes: [SublimeSettingChange]
    ) {
        for change in changes {
            switch change.key {
            case .fontSize: fontSize = imported.fontSize
            case .tabSize: tabSize = imported.tabSize
            case .insertSpaces: insertSpaces = imported.insertSpaces
            case .wordWrap: wordWrap = imported.wordWrap
            case .showLineNumbers: showLineNumbers = imported.showLineNumbers
            case .showWhitespace: showWhitespace = imported.showWhitespace
            case .rulers: rulers = imported.rulers
            case .spellCheck: spellCheck = imported.spellCheck
            case .autoSave: autoSave = imported.autoSave
            case .autoSaveDelayMs: autoSaveDelayMs = imported.autoSaveDelayMs
            case .colorScheme: colorScheme = imported.colorScheme
            }
        }
    }
}

/// Compensating transaction for project-root capabilities. Existing grants are
/// never revoked. Every grant added by this attempt is revoked in reverse order
/// if a later grant or the atomic ProjectSettings write fails.
@MainActor
final class SublimeProjectImportTransaction {
    struct RootSnapshot: Equatable, Sendable {
        let urls: [URL]
        let primaryURL: URL?

        init(urls: [URL], primaryURL: URL?) {
            self.urls = urls
            self.primaryURL = primaryURL
        }
    }

    typealias ExistingRoots = @MainActor () async -> RootSnapshot
    typealias AuthorizeRoot = @MainActor (URL, Bool) async throws -> URL
    typealias RevokeRoot = @MainActor (URL) async throws -> Void
    typealias SetPrimaryRoot = @MainActor (URL) async throws -> Void
    typealias RestorePrimaryRoot = @MainActor (URL?) async throws -> Void
    typealias PersistProject = @MainActor (URL, SublimeProjectImport) throws -> Void

    private let existingRoots: ExistingRoots
    private let authorizeRoot: AuthorizeRoot
    private let revokeRoot: RevokeRoot
    private let setPrimaryRoot: SetPrimaryRoot
    private let restorePrimaryRoot: RestorePrimaryRoot
    private let persistProject: PersistProject

    init(
        existingRoots: @escaping ExistingRoots,
        authorizeRoot: @escaping AuthorizeRoot,
        revokeRoot: @escaping RevokeRoot,
        setPrimaryRoot: @escaping SetPrimaryRoot = { _ in },
        restorePrimaryRoot: @escaping RestorePrimaryRoot = { _ in },
        persistProject: @escaping PersistProject
    ) {
        self.existingRoots = existingRoots
        self.authorizeRoot = authorizeRoot
        self.revokeRoot = revokeRoot
        self.setPrimaryRoot = setPrimaryRoot
        self.restorePrimaryRoot = restorePrimaryRoot
        self.persistProject = persistProject
    }

    func apply(_ imported: SublimeProjectImport) async throws -> [URL] {
        let originalRoots = await existingRoots()
        let existingByIdentity = Dictionary(
            originalRoots.urls.map { (Self.identity($0), $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        )
        var accepted: [URL] = []
        var acceptedIdentities = Set<String>()
        var newlyAuthorized: [URL] = []
        do {
            for candidate in imported.roots {
                let candidateIdentity = Self.identity(candidate)
                guard !acceptedIdentities.contains(candidateIdentity) else { continue }
                if let existingURL = existingByIdentity[candidateIdentity] {
                    acceptedIdentities.insert(candidateIdentity)
                    accepted.append(existingURL)
                    continue
                }
                let authorized = try await authorizeRoot(
                    candidate.standardizedFileURL, accepted.isEmpty
                ).standardizedFileURL
                let authorizedIdentity = Self.identity(authorized)
                guard acceptedIdentities.insert(authorizedIdentity).inserted else {
                    try await revokeRoot(authorized)
                    continue
                }
                accepted.append(authorized)
                newlyAuthorized.append(authorized)
            }
            guard let settingsRoot = accepted.first else {
                throw SublimeImportProductionError.projectRootAuthorizationFailed(
                    imported.sourceURL
                )
            }
            try await setPrimaryRoot(settingsRoot)
            try persistProject(settingsRoot, imported)
            return accepted
        } catch {
            let originalError = error
            var rollbackFailures: [String] = []
            for root in newlyAuthorized.reversed() {
                do {
                    try await revokeRoot(root)
                } catch {
                    rollbackFailures.append("\(root.path): \(error.localizedDescription)")
                }
            }
            do {
                try await restorePrimaryRoot(originalRoots.primaryURL)
            } catch {
                rollbackFailures.append("restore primary root: \(error.localizedDescription)")
            }
            if rollbackFailures.isEmpty { throw originalError }
            throw SublimeImportProductionError.projectRollbackFailed(
                original: originalError.localizedDescription,
                rollback: rollbackFailures.joined(separator: "; ")
            )
        }
    }

    private static func identity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum SublimeImportProjectSettingsMerge {
    static func project(
        _ imported: SublimeProjectImport, into current: ProjectSettings
    ) -> ProjectSettings {
        var next = current
        next.exclude = imported.exclusions
        next.buildSystems = mergeBuildSystems(
            imported.buildSystems.map(projectBuildSystem), into: current.buildSystems
        )
        return next.sanitized()
    }

    static func keymap(
        _ imported: SublimeKeymapImport, into current: ProjectSettings
    ) -> ProjectSettings {
        var next = current
        let incoming = imported.overrides.map(projectKeyBindingRule)
        let identities = Set(incoming.map(RuleIdentity.init))
        next.keyBindingRules = Array(
            (current.keyBindingRules.filter { !identities.contains(RuleIdentity($0)) }
                + incoming).suffix(ProjectSettingsSanitizer.maximumKeyBindingRules)
        )
        return next.sanitized()
    }

    static func snippet(
        _ imported: SublimeSnippetImport, into current: ProjectSettings
    ) -> ProjectSettings {
        var next = current
        let snippet = ProjectSnippet(
            label: imported.label, text: imported.text,
            trigger: imported.trigger, scope: imported.scope
        )
        next.snippets = Array(
            ([snippet] + current.snippets.filter { $0.label != snippet.label })
                .prefix(ProjectSettingsSanitizer.maximumSnippets)
        )
        return next.sanitized()
    }

    static func build(
        _ imported: SublimeBuildImport, into current: ProjectSettings
    ) -> ProjectSettings {
        var next = current
        let system = projectBuildSystem(imported.system)
        next.buildSystems = mergeBuildSystems([system], into: current.buildSystems)
        return next.sanitized()
    }

    static func keyBindingOverrides(
        from rules: [ProjectKeyBindingRule]
    ) -> [KeyBindingOverride] {
        rules.compactMap { rule in
            let sequence = rule.keys.compactMap(parseProjectKey)
            guard sequence.count == rule.keys.count, !sequence.isEmpty else { return nil }
            return KeyBindingOverride(
                commandID: rule.command,
                binding: CommandKeyBinding(sequence: sequence),
                when: rule.when
            )
        }
    }

    private struct RuleIdentity: Hashable {
        let command: String
        let context: KeyBindingContext?

        init(_ value: ProjectKeyBindingRule) {
            command = value.command
            context = value.when
        }
    }

    private static func mergeBuildSystems(
        _ incoming: [ProjectBuildSystem], into existing: [ProjectBuildSystem]
    ) -> [ProjectBuildSystem] {
        let names = Set(incoming.map(\.name))
        return Array(
            (incoming + existing.filter { !names.contains($0.name) })
                .prefix(ProjectSettingsSanitizer.maximumBuildSystems)
        )
    }

    private static func projectBuildSystem(
        _ value: SublimeBuildSystemImport
    ) -> ProjectBuildSystem {
        ProjectBuildSystem(
            name: value.name, command: value.command, args: value.arguments,
            workingDirectory: value.workingDirectory, fileRegex: value.fileRegex,
            shell: value.usesShell, env: value.environment,
            variants: value.variants.map { variant in
                ProjectBuildVariant(
                    name: variant.name, command: variant.command,
                    args: variant.arguments, workingDirectory: variant.workingDirectory,
                    fileRegex: variant.fileRegex, env: variant.environment,
                    shell: variant.usesShell
                )
            }
        )
    }

    private static func projectKeyBindingRule(
        _ value: KeyBindingOverride
    ) -> ProjectKeyBindingRule {
        ProjectKeyBindingRule(
            keys: value.binding?.sequence.map(projectKey) ?? [],
            command: value.commandID, when: value.when
        )
    }

    private static func projectKey(_ value: CommandKeyEquivalent) -> String {
        var components: [String] = []
        if value.modifiers.contains(.command) { components.append("Mod") }
        if value.modifiers.contains(.control) { components.append("Ctrl") }
        if value.modifiers.contains(.option) { components.append("Alt") }
        if value.modifiers.contains(.shift) { components.append("Shift") }
        switch value.key {
        case "return": components.append("Enter")
        case "space": components.append("Space")
        default: components.append(value.key.count == 1 ? value.key.uppercased() : value.key)
        }
        return components.joined(separator: "+")
    }

    private static func parseProjectKey(_ source: String) -> CommandKeyEquivalent? {
        let parts = source.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let rawKey = parts.last else { return nil }
        var modifiers: CommandKeyModifiers = []
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "mod", "cmd", "command", "super": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let key: String
        switch rawKey.lowercased() {
        case "enter", "return": key = "return"
        case "space": key = "space"
        default: key = rawKey.lowercased()
        }
        return CommandKeyEquivalent(key: key, modifiers: modifiers)
    }
}

/// Owns the production adapters retained by controller closures and presents a
/// single, explicit API for composition-root construction and command wiring.
@MainActor
final class SublimeImportComposition {
    typealias CurrentKeyBindings = @MainActor () -> [KeyBindingOverride]
    typealias ApplyKeyBindings = @MainActor ([KeyBindingOverride]) -> Void
    typealias Present = @MainActor () -> Void
    typealias SynchronizeWorkspaceSession = @MainActor () -> Void
    typealias AuthorizeProjectRoot = @MainActor (URL) async throws -> URL

    let controller: SublimeImportController
    let sourcePicker: SublimeImportSourcePicker
    private let projectTransaction: SublimeProjectImportTransaction

    private init(
        controller: SublimeImportController,
        sourcePicker: SublimeImportSourcePicker,
        projectTransaction: SublimeProjectImportTransaction
    ) {
        self.controller = controller
        self.sourcePicker = sourcePicker
        self.projectTransaction = projectTransaction
    }

    static func production(
        settings: SettingsController,
        workspace: WorkspaceController,
        projectSettings: ProjectSettingsController,
        currentKeyBindings: @escaping CurrentKeyBindings,
        applyKeyBindings: @escaping ApplyKeyBindings,
        synchronizeWorkspaceSession: @escaping SynchronizeWorkspaceSession = {},
        authorizeProjectRoot: AuthorizeProjectRoot? = nil,
        sourcePicker: SublimeImportSourcePicker? = nil
    ) -> SublimeImportComposition {
        func requireProjectRoot(_ kind: SublimeImportKind) throws -> URL {
            guard let root = workspace.roots.first(where: \.isPrimary)?.url
                    ?? workspace.roots.first?.url else {
                throw SublimeImportProductionError.workspaceRequired(kind)
            }
            return root.standardizedFileURL
        }

        func persistProjectSettings(
            at root: URL, mutation: (ProjectSettings) -> ProjectSettings
        ) throws -> ProjectSettings {
            guard !projectSettings.hasPendingChanges, !projectSettings.isSaving else {
                throw SublimeImportProductionError.projectSettingsHavePendingChanges
            }
            let store = ProjectSettingsStore(workspaceURL: root)
            let snapshot = try store.load()
            let next = mutation(snapshot.settings).sanitized()
            let result = try store.save(next, expectedRevision: snapshot.revision)
            projectSettings.adoptPersistedSettings(
                next, revision: result.revision, workspaceURL: root, store: store
            )
            return next
        }

        let sourcePicker = sourcePicker ?? SublimeImportSourcePicker(
            currentLocale: { settings.locale }
        )
        let authorizeProjectRoot = authorizeProjectRoot ?? { expected in
            try await chooseProjectRoot(expected, locale: settings.locale)
        }
        let projectTransaction = SublimeProjectImportTransaction(
            existingRoots: {
                SublimeProjectImportTransaction.RootSnapshot(
                    urls: workspace.roots.map(\.url),
                    primaryURL: workspace.roots.first(where: \.isPrimary)?.url
                )
            },
            authorizeRoot: { url, makePrimary in
                let selected = try await authorizeProjectRoot(url)
                let expectedIdentity = url.standardizedFileURL
                    .resolvingSymlinksInPath().path
                let selectedIdentity = selected.standardizedFileURL
                    .resolvingSymlinksInPath().path
                guard expectedIdentity == selectedIdentity else {
                    throw SublimeImportProductionError.projectRootSelectionMismatch(
                        expected: url, selected: selected
                    )
                }
                guard await workspace.addRoot(
                    selected, makePrimary: makePrimary, accessSource: .userSelected
                ),
                      let root = workspace.roots.first(where: {
                          $0.url.standardizedFileURL.resolvingSymlinksInPath().path
                              == selected.standardizedFileURL.resolvingSymlinksInPath().path
                      }) else {
                    throw SublimeImportProductionError.projectRootAuthorizationFailed(selected)
                }
                return root.url
            },
            revokeRoot: { url in
                guard let root = workspace.roots.first(where: {
                    $0.url.standardizedFileURL.resolvingSymlinksInPath().path
                        == url.standardizedFileURL.resolvingSymlinksInPath().path
                }), await workspace.removeRoot(root) else {
                    throw SublimeImportProductionError.projectRootAuthorizationFailed(url)
                }
            },
            setPrimaryRoot: { url in
                guard let root = workspace.roots.first(where: {
                    $0.url.standardizedFileURL.resolvingSymlinksInPath().path
                        == url.standardizedFileURL.resolvingSymlinksInPath().path
                }) else {
                    throw SublimeImportProductionError.projectRootAuthorizationFailed(url)
                }
                try await workspace.setPrimaryRoot(root)
            },
            restorePrimaryRoot: { originalPrimary in
                guard let originalPrimary else { return }
                guard let root = workspace.roots.first(where: {
                    $0.url.standardizedFileURL.resolvingSymlinksInPath().path
                        == originalPrimary.standardizedFileURL
                            .resolvingSymlinksInPath().path
                }) else {
                    throw SublimeImportProductionError
                        .projectRootAuthorizationFailed(originalPrimary)
                }
                try await workspace.setPrimaryRoot(root)
            },
            persistProject: { root, imported in
                _ = try persistProjectSettings(at: root) {
                    SublimeImportProjectSettingsMerge.project(imported, into: $0)
                }
            }
        )

        let controller = SublimeImportController(
            requestSource: { kind in
                try await sourcePicker.requestSource(for: kind)
            },
            currentSettings: { settings.settings },
            hasWorkspace: { !workspace.roots.isEmpty },
            applyProject: { imported in
                let roots = try await projectTransaction.apply(imported)
                synchronizeWorkspaceSession()
                return roots
            },
            applySettings: { imported in
                let previous = settings.settings
                settings.update { current in
                    current.applySublimeChanges(from: imported.settings, changes: imported.changes)
                }
                guard settings.flush() else {
                    settings.update { $0 = previous }
                    _ = settings.flush()
                    throw SublimeImportProductionError.settingsPersistenceFailed
                }
            },
            applyKeymap: { imported in
                let root = try requireProjectRoot(.keymap)
                let persisted = try persistProjectSettings(at: root) {
                    SublimeImportProjectSettingsMerge.keymap(imported, into: $0)
                }
                let mergedRuntime = imported.merging(into: currentKeyBindings())
                _ = persisted
                applyKeyBindings(mergedRuntime)
            },
            applySnippet: { imported in
                let root = try requireProjectRoot(.snippet)
                _ = try persistProjectSettings(at: root) {
                    SublimeImportProjectSettingsMerge.snippet(imported, into: $0)
                }
            },
            applyBuild: { imported in
                let root = try requireProjectRoot(.build)
                _ = try persistProjectSettings(at: root) {
                    SublimeImportProjectSettingsMerge.build(imported, into: $0)
                }
            }
        )
        return SublimeImportComposition(
            controller: controller, sourcePicker: sourcePicker,
            projectTransaction: projectTransaction
        )
    }

    private static func chooseProjectRoot(
        _ expected: URL, locale: EditorLocale
    ) async throws -> URL {
        let panel = NSOpenPanel()
        let copy = SublimeImportPanelCopy.projectAuthorization(
            expected: expected, locale: locale
        )
        panel.title = copy.title
        panel.message = copy.message
        panel.prompt = copy.prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.directoryURL = expected
        let response = await withCheckedContinuation { continuation in
            if let window = NSApplication.shared.keyWindow, window.attachedSheet == nil {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let selected = panel.url?.standardizedFileURL else {
            throw SublimeImportProductionError.projectRootSelectionCancelled(expected)
        }
        let expectedIdentity = expected.standardizedFileURL.resolvingSymlinksInPath().path
        let selectedIdentity = selected.resolvingSymlinksInPath().path
        guard expectedIdentity == selectedIdentity else {
            throw SublimeImportProductionError.projectRootSelectionMismatch(
                expected: expected, selected: selected
            )
        }
        return selected
    }

    /// Registers all five routes transactionally. `present` is called only
    /// when a preview or readable issue exists, so picker cancellation leaves
    /// the current UI untouched. The returned tokens remain caller-owned.
    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping SublimeImportController.PrepareForCommand = {},
        present: @escaping Present
    ) throws -> [CommandHandlerToken] {
        try controller.registerCommands(
            on: router, replaceExisting: replaceExisting,
            prepareForCommand: prepareForCommand,
            didFinishRequest: { [weak controller] in
                guard let controller,
                      controller.presentation != nil || controller.issue != nil else { return }
                present()
            }
        )
    }
}
