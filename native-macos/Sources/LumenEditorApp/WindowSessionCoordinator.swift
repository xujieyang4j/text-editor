import Foundation
import LumenEditorCore

/// A path-safe, durable value suitable for SwiftUI `WindowGroup(for:)` and
/// `openWindow(value:)`. The raw value is intentionally the same string used
/// by the on-disk registry and session filename.
public struct WindowSessionID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public static let legacy = WindowSessionID(unchecked: "legacy")

    public let rawValue: String
    public var id: String { rawValue }

    public init?(rawValue: String) {
        guard RecentItemsStore.isValidWindowSessionID(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard RecentItemsStore.isValidWindowSessionID(rawValue) else {
            throw RecentItemsStoreError.invalidWindowSessionID(rawValue)
        }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension WindowSessionID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// The value passed to a window scene. Keeping presentation beside the ID lets
/// a `WindowGroup` restore geometry without reading process-wide mutable state.
public struct WindowSessionSceneValue: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: WindowSessionID
    public let presentation: WindowSessionPresentation?

    public init(
        id: WindowSessionID,
        presentation: WindowSessionPresentation? = nil
    ) {
        self.id = id
        self.presentation = presentation
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Split form convenient for a value-based `WindowGroup`: use `primary` as
/// the scene's default value, then call `openWindow(value:)` for `additional`.
public struct WindowSessionStartupPlan: Equatable, Sendable {
    public let primary: WindowSessionSceneValue
    public let additional: [WindowSessionSceneValue]

    public init(
        primary: WindowSessionSceneValue,
        additional: [WindowSessionSceneValue] = []
    ) {
        self.primary = primary
        self.additional = additional
    }

    public var all: [WindowSessionSceneValue] { [primary] + additional }
}

public final class WindowSessionComposition {
    public let sceneValue: WindowSessionSceneValue
    public let sessionStore: SessionStore
    private let registered: () throws -> Void
    private let presentationStaged: (WindowSessionPresentation) -> Void
    private let presentationChanged: (WindowSessionPresentation) throws -> Bool
    private let closed: (WindowSessionCloseDisposition) throws -> Void
    private let stagedTerminationSnapshot: (WindowSession) throws -> Void
    private let stagedWindowCloseSnapshot: (WindowSession) throws -> Void
    private let committedWindowCloseSnapshot: () throws -> Void
    private let abortedWindowCloseSnapshot: () -> Void
    private let lifecycleLock = NSLock()
    private var didClose = false
    private var activePersistCount = 0

    fileprivate init(
        sceneValue: WindowSessionSceneValue,
        sessionStore: SessionStore,
        registered: @escaping () throws -> Void,
        presentationStaged: @escaping (WindowSessionPresentation) -> Void,
        presentationChanged: @escaping (WindowSessionPresentation) throws -> Bool,
        closed: @escaping (WindowSessionCloseDisposition) throws -> Void,
        stagedTerminationSnapshot: @escaping (WindowSession) throws -> Void,
        stagedWindowCloseSnapshot: @escaping (WindowSession) throws -> Void,
        committedWindowCloseSnapshot: @escaping () throws -> Void,
        abortedWindowCloseSnapshot: @escaping () -> Void
    ) {
        self.sceneValue = sceneValue
        self.sessionStore = sessionStore
        self.registered = registered
        self.presentationStaged = presentationStaged
        self.presentationChanged = presentationChanged
        self.closed = closed
        self.stagedTerminationSnapshot = stagedTerminationSnapshot
        self.stagedWindowCloseSnapshot = stagedWindowCloseSnapshot
        self.committedWindowCloseSnapshot = committedWindowCloseSnapshot
        self.abortedWindowCloseSnapshot = abortedWindowCloseSnapshot
    }

    public var id: WindowSessionID { sceneValue.id }
    public var presentation: WindowSessionPresentation? { sceneValue.presentation }

    @MainActor
    public func makeAppModel(
        maximumEditableByteCount: Int64 = TextFileCodec.defaultMaximumByteCount,
        createInitialDocument: Bool = false
    ) -> AppModel {
        AppModel(
            sessionStore: sessionStore,
            maximumEditableByteCount: maximumEditableByteCount,
            createInitialDocument: createInitialDocument,
            sessionWillPersist: { [weak self] in try self?.beginPersistence() },
            sessionPersistenceDidFail: { [weak self] in self?.cancelPersistence() },
            sessionDidPersist: { [weak self] in
                try self?.finishPersistenceAfterSuccessfulSave()
            },
            terminationSnapshotWillPersist: { [weak self] snapshot in
                guard let self else {
                    throw WindowSessionCoordinatorError.closedSession("unknown")
                }
                try self.stageTerminationSnapshot(snapshot)
            },
            applicationCloseSnapshotStager: { [weak self] snapshot in
                guard let self else {
                    throw WindowSessionCoordinatorError.closedSession("unknown")
                }
                try self.stageWindowCloseSnapshot(snapshot)
            },
            applicationCloseSnapshotCommitter: { [weak self] in
                guard let self else {
                    throw WindowSessionCoordinatorError.closedSession("unknown")
                }
                try self.commitWindowCloseSnapshot()
            },
            applicationCloseSnapshotAborter: { [weak self] in
                self?.abortWindowCloseSnapshot()
            }
        )
    }

    /// Use this after AppKit reports a stable frame/state transition. It does
    /// not register an unsaved new window on its own.
    @discardableResult
    public func updatePresentation(_ value: WindowSessionPresentation) throws -> Bool {
        try lifecycleLock.withCriticalSection {
            guard !didClose else { return false }
            return try presentationChanged(value)
        }
    }

    public func stagePresentation(_ value: WindowSessionPresentation) {
        guard value.bounds?.isValid != false else { return }
        lifecycleLock.withCriticalSection {
            guard !didClose else { return }
            presentationStaged(value)
        }
    }

    public func loadSession() -> WindowSession {
        sessionStore.loadWindowSession()
    }

    /// Atomically writes this window's snapshot and only then makes it a
    /// startup-restorable registry entry.
    public func saveSession(_ session: WindowSession) throws {
        try beginPersistence()
        do { try sessionStore.save(session) } catch {
            cancelPersistence()
            throw error
        }
        try finishPersistenceAfterSuccessfulSave()
    }

    private func beginPersistence() throws {
        try lifecycleLock.withCriticalSection {
            guard !didClose else {
                throw WindowSessionCoordinatorError.closedSession(id.rawValue)
            }
            activePersistCount += 1
        }
    }

    func stageTerminationSnapshot(_ snapshot: WindowSession) throws {
        try lifecycleLock.withCriticalSection {
            guard !didClose else {
                throw WindowSessionCoordinatorError.closedSession(id.rawValue)
            }
            guard activePersistCount == 0 else {
                throw WindowSessionCoordinatorError.persistenceInProgress(
                    id.rawValue
                )
            }
            try stagedTerminationSnapshot(snapshot)
        }
    }

    private func stageWindowCloseSnapshot(_ snapshot: WindowSession) throws {
        try lifecycleLock.withCriticalSection {
            guard !didClose else {
                throw WindowSessionCoordinatorError.closedSession(id.rawValue)
            }
            guard activePersistCount == 0 else {
                throw WindowSessionCoordinatorError.persistenceInProgress(id.rawValue)
            }
            try stagedWindowCloseSnapshot(snapshot)
        }
    }

    private func commitWindowCloseSnapshot() throws {
        try lifecycleLock.withCriticalSection {
            guard !didClose else {
                throw WindowSessionCoordinatorError.closedSession(id.rawValue)
            }
            try committedWindowCloseSnapshot()
        }
    }

    private func abortWindowCloseSnapshot() {
        lifecycleLock.withCriticalSection {
            guard !didClose else { return }
            abortedWindowCloseSnapshot()
        }
    }

    private func finishPersistenceAfterSuccessfulSave() throws {
        let shouldRegister = lifecycleLock.withCriticalSection { !didClose }
        defer {
            lifecycleLock.withCriticalSection {
                if activePersistCount > 0 { activePersistCount -= 1 }
            }
        }
        if shouldRegister { try registered() }
    }

    private func cancelPersistence() {
        lifecycleLock.withCriticalSection {
            precondition(activePersistCount > 0)
            activePersistCount -= 1
        }
    }

    /// Flushes an AppModel owned by this composition. The model's injected
    /// callback performs registry registration only after the atomic save.
    @MainActor
    @discardableResult
    public func flush(_ model: AppModel) -> Bool {
        model.flushSession()
    }

    /// Close helper for the common WindowGroup path: flush first, then release
    /// the live ID only if recovery persistence succeeded.
    @MainActor
    @discardableResult
    public func flushAndClose(
        _ model: AppModel,
        disposition: WindowSessionCloseDisposition = .preserve
    ) -> Bool {
        guard model.flushSession() else { return false }
        do {
            try close(disposition)
            return true
        } catch {
            return false
        }
    }

    /// Call only after the window's dirty-document close flow and final session
    /// flush have succeeded. Normal closes remain in the startup registry.
    public func close(_ disposition: WindowSessionCloseDisposition = .preserve) throws {
        try lifecycleLock.withCriticalSection {
            guard !didClose else { return }
            guard activePersistCount == 0 else {
                throw WindowSessionCoordinatorError.persistenceInProgress(id.rawValue)
            }
            try closed(disposition)
            didClose = true
        }
    }

}

public enum WindowSessionCloseDisposition: Equatable, Sendable {
    /// Keep the snapshot registered so this window returns on next launch.
    case preserve
    /// The caller explicitly established that no recoverable state remains.
    case discardEmptySession
}

public enum WindowSessionCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case invalidSceneValue
    case closedSession(String)
    case persistenceInProgress(String)
    case couldNotGenerateUniqueID
    case noTerminationTransaction
    case incompleteTerminationTransaction
    case unexpectedTerminationWindow(String)
    case terminationRecoveryFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSceneValue:
            return "A valid window session could not be created."
        case let .closedSession(id):
            return "Window session \(id) is already closed."
        case let .persistenceInProgress(id):
            return "Window session \(id) is still being saved."
        case .couldNotGenerateUniqueID:
            return "A unique window session ID could not be generated."
        case .noTerminationTransaction:
            return "No application termination transaction is active."
        case .incompleteTerminationTransaction:
            return "Not every application window staged a termination snapshot."
        case let .unexpectedTerminationWindow(id):
            return "Window session \(id) is not part of the termination transaction."
        case .terminationRecoveryFailed:
            return "The committed window-session transaction could not be recovered."
        }
    }
}

/// Process-wide coordinator for independent native window sessions.
///
/// The type is synchronous by design: both underlying stores use bounded,
/// atomic synchronous I/O and AppModel currently flushes sessions on the main
/// actor. An internal lock protects ID reservation and lifecycle bookkeeping
/// when SwiftUI creates or tears down scenes concurrently.
public final class WindowSessionCoordinator: @unchecked Sendable {
    public typealias IDGenerator = @Sendable () -> String
    public typealias Clock = @Sendable () -> Date

    public static let shared = WindowSessionCoordinator()
    private static let terminationMarkerFileName = "termination-commit.json"
    private static let terminationParticipantFilePrefix = "termination-participants-"
    private static let maximumTerminationMarkerBytes = 64 * 1_024
    private static let windowCloseMarkerInfix = ".window-close-marker-"
    private static let windowCloseSidecarInfix = ".window-close-sidecar-"
    private static let windowCloseBackupInfix = ".window-close-backup-"

    private enum TerminationCommitState: String, Codable, Sendable {
        case pending
        case materializing
        case materialized
    }

    private struct TerminationCommitMarker: Codable, Sendable {
        let transactionID: String
        let sessionIDs: [String]
        let state: TerminationCommitState

        init(
            transactionID: String, sessionIDs: [String],
            state: TerminationCommitState = .pending
        ) {
            self.transactionID = transactionID
            self.sessionIDs = sessionIDs
            self.state = state
        }

        private enum CodingKeys: String, CodingKey {
            case transactionID
            case sessionIDs
            case state
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            transactionID = try values.decode(String.self, forKey: .transactionID)
            sessionIDs = try values.decode([String].self, forKey: .sessionIDs)
            state = try values.decodeIfPresent(
                TerminationCommitState.self, forKey: .state
            ) ?? .pending
        }
    }

    private struct TerminationParticipantManifest: Codable, Sendable {
        let transactionID: String
        let sessionIDs: [String]
    }

    /// A standalone window close is not committed until AppKit actually closes
    /// the window. While this marker exists, startup restores `liveRevision`
    /// from the backup even if the projected canonical write had completed.
    private struct WindowCloseCommitMarker: Codable, Sendable {
        let transactionID: String
        let sessionID: String
        let liveRevision: String
        let projectedRevision: String
    }

    private enum WindowCloseArtifactKind {
        case marker
        case sidecar
        case backup
    }

    private struct WindowCloseArtifactGroup {
        let transactionID: String
        var canonicalName: String?
        var marker: URL?
        var sidecar: URL?
        var backup: URL?
    }

    public let recentItemsStore: RecentItemsStore
    public let sessionLimits: SessionStore.Limits

    private let fileManager: FileManager
    private let generateID: IDGenerator
    private let now: Clock
    private let lock = NSLock()

    private final class WeakComposition: @unchecked Sendable {
        weak var value: WindowSessionComposition?

        init(_ value: WindowSessionComposition) { self.value = value }
    }

    private var reservedSessionIDs: Set<WindowSessionID> = []
    private var liveSessionIDs: Set<WindowSessionID> = []
    private var presentations: [WindowSessionID: WindowSessionPresentation] = [:]
    private var compositions: [WindowSessionID: WeakComposition] = [:]
    private var preparedStartupPlan: WindowSessionStartupPlan?
    private var terminationTransactionID: String?
    private var stagedTerminationSessionIDs: Set<WindowSessionID> = []
    private var expectedTerminationSessionIDs: Set<WindowSessionID> = []
    private var windowCloseTransactionIDs: [WindowSessionID: String] = [:]
    private var didResolveCommittedTermination = false
    private var terminationRecoveryFailed = false
    private var applicationTerminationCommitted = false
    private var didResolveWindowCloseTransactions = false

    public convenience init(
        fileManager: FileManager = .default,
        sessionLimits: SessionStore.Limits = .default
    ) {
        self.init(
            recentItemsStore: RecentItemsStore(fileManager: fileManager),
            fileManager: fileManager,
            sessionLimits: sessionLimits
        )
    }

    public init(
        recentItemsStore: RecentItemsStore,
        fileManager: FileManager = .default,
        sessionLimits: SessionStore.Limits = .default,
        idGenerator: @escaping IDGenerator = { UUID().uuidString.lowercased() },
        now: @escaping Clock = { Date() }
    ) {
        self.recentItemsStore = recentItemsStore
        self.fileManager = fileManager
        self.sessionLimits = sessionLimits
        self.generateID = idGenerator
        self.now = now
    }

    /// Values to feed to `openWindow(value:)` at application startup. Registry
    /// order is canonical newest-first and already capped at twelve entries. If
    /// no registry exists yet, an existing pre-multi-window `session.json` is
    /// claimed by the stable `legacy` ID; a clean first launch gets a fresh ID.
    public func startupSceneValues() throws -> [WindowSessionSceneValue] {
        try startupPlan().all
    }

    private func makeStartupSceneValues() -> [WindowSessionSceneValue] {
        let registered = recentItemsStore.windowSessions()
        let isFirstMigration = registered.isEmpty
        let legacyURL = recentItemsStore.directoryURL.appendingPathComponent(
            SessionStore.sessionFileName, isDirectory: false
        )
        var values: [WindowSessionSceneValue] = []
        for metadata in registered {
            guard let id = WindowSessionID(rawValue: metadata.id),
                  let url = try? recentItemsStore.windowSessionURL(
                      for: id.rawValue
                  )
            else { continue }
            guard fileManager.fileExists(atPath: url.path) else {
                _ = try? recentItemsStore.removeWindowSession(id.rawValue)
                continue
            }
            values.append(WindowSessionSceneValue(
                id: id, presentation: metadata.presentation
            ))
        }
        if !values.isEmpty { return values }
        // Only an empty pre-multi-window registry may claim session.json. A
        // stale non-empty registry must not revive an intentionally closed
        // legacy window simply because its old snapshot still exists.
        if isFirstMigration && fileManager.fileExists(atPath: legacyURL.path) {
            return [WindowSessionSceneValue(id: .legacy)]
        }
        if let id = try? generateUniqueID() {
            return [WindowSessionSceneValue(id: id)]
        }
        return [WindowSessionSceneValue(id: .legacy)]
    }

    public func startupRestorationIDs() throws -> [WindowSessionID] {
        try startupSceneValues().map(\.id)
    }

    public func startupPlan() throws -> WindowSessionStartupPlan {
        guard resolveWindowCloseTransactionsIfNeeded() else {
            throw WindowSessionCoordinatorError.terminationRecoveryFailed
        }
        guard resolveCommittedTerminationIfNeeded() else {
            throw WindowSessionCoordinatorError.terminationRecoveryFailed
        }
        if let existing = withStateLock({ preparedStartupPlan }) { return existing }
        let values = makeStartupSceneValues()
        let candidate = WindowSessionStartupPlan(
            primary: values[0],
            additional: Array(values.dropFirst())
        )
        return withStateLock {
            if let preparedStartupPlan { return preparedStartupPlan }
            // `startupSceneValues` always supplies the legacy first-launch route.
            preparedStartupPlan = candidate
            return candidate
        }
    }

    public func retryStartupPlan() throws -> WindowSessionStartupPlan {
        withStateLock {
            didResolveWindowCloseTransactions = false
            didResolveCommittedTermination = false
            terminationRecoveryFailed = false
            preparedStartupPlan = nil
        }
        return try startupPlan()
    }

    func hasActiveTerminationRecoveryArtifacts() -> Bool {
        fileManager.fileExists(atPath: terminationMarkerURL.path)
            || hasTerminationBackupArtifacts()
            || hasWindowCloseArtifacts()
    }

    /// Explicit recovery choice: preserve the failed transaction as an
    /// inspectable archive, deactivate its marker, and open copies represented
    /// by the last complete canonical snapshots. Nothing in the committed
    /// transaction is silently consumed or deleted.
    func preserveFailedTerminationAndUseCanonicalSnapshots() throws -> (
        plan: WindowSessionStartupPlan, archiveURL: URL
    ) {
        try Self.withTerminationRecoveryLock {
            let suffix = UUID().uuidString.lowercased()
            let archiveURL = recentItemsStore.directoryURL.appendingPathComponent(
                "termination-recovery-preserved-\(suffix)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: archiveURL, withIntermediateDirectories: false
            )
            let names = try fileManager.contentsOfDirectory(
                atPath: recentItemsStore.directoryURL.path
            )
            let canonicalNames = Set(try recentItemsStore.windowSessionIDs().map {
                try recentItemsStore.windowSessionURL(for: $0).lastPathComponent
            })
            let artifacts = names.filter { name in
                name == Self.terminationMarkerFileName
                    || name.hasPrefix(Self.terminationParticipantFilePrefix)
                    || isTerminationSidecarName(name)
                    || isTerminationBackupName(name)
                    || isWindowCloseArtifactCandidateName(name)
                    || canonicalNames.contains(name)
            }
            do {
                for name in artifacts {
                    try fileManager.copyItem(
                        at: recentItemsStore.directoryURL.appendingPathComponent(name),
                        to: archiveURL.appendingPathComponent(name)
                    )
                }
                let hasGlobalArtifacts = names.contains { name in
                    name == Self.terminationMarkerFileName
                        || name.hasPrefix(Self.terminationParticipantFilePrefix)
                        || isTerminationSidecarName(name)
                        || isTerminationBackupName(name)
                }
                let canonicalIsSafe: Bool
                if let marker = loadTerminationMarker() {
                    switch marker.state {
                    case .pending:
                        canonicalIsSafe = validateCanonicalGeneration(for: marker)
                    case .materializing:
                        canonicalIsSafe = restoreCanonicalBackups(for: marker)
                            && validateCanonicalGeneration(for: marker)
                    case .materialized:
                        canonicalIsSafe = canonicalGenerationMatchesSidecars(for: marker)
                            || (restoreCanonicalBackups(for: marker)
                                && validateCanonicalGeneration(for: marker))
                    }
                } else if hasGlobalArtifacts {
                    // A corrupt marker cannot identify its participants. A
                    // separately committed participant manifest plus a complete
                    // matching backup/sidecar generation can.
                    canonicalIsSafe = restoreUniqueCanonicalBackupGeneration()
                } else {
                    canonicalIsSafe = true
                }
                guard canonicalIsSafe else {
                    throw WindowSessionCoordinatorError.terminationRecoveryFailed
                }
                guard recoverWindowCloseArtifactsForExplicitFallback(names: names) else {
                    throw WindowSessionCoordinatorError.terminationRecoveryFailed
                }
                if fileManager.fileExists(atPath: terminationMarkerURL.path) {
                    try fileManager.moveItem(
                        at: terminationMarkerURL,
                        to: terminationMarkerURL.appendingPathExtension(
                            "preserved-\(suffix)"
                        )
                    )
                }
                removeWindowCloseArtifacts(names: names)
                cleanupTerminationSidecars(except: nil)
                cleanupTerminationParticipantManifests(except: nil)
            } catch {
                try? fileManager.removeItem(at: archiveURL)
                throw error
            }
            withStateLock {
                didResolveCommittedTermination = true
                terminationRecoveryFailed = false
                preparedStartupPlan = nil
            }
            let values = makeStartupSceneValues()
            let plan = WindowSessionStartupPlan(
                primary: values[0], additional: Array(values.dropFirst())
            )
            withStateLock { preparedStartupPlan = plan }
            return (plan, archiveURL)
        }
    }

    /// Produces a fresh value for `openWindow(value:)` without registering it.
    /// Registration follows the first successful session save, preventing a
    /// newly-created but never-materialised scene from returning on relaunch.
    public func newSceneValue() throws -> WindowSessionSceneValue {
        guard withStateLock({ !applicationTerminationCommitted }) else {
            throw WindowSessionCoordinatorError.incompleteTerminationTransaction
        }
        return WindowSessionSceneValue(id: try generateUniqueID())
    }

    public func newWindowID() throws -> WindowSessionID {
        try generateUniqueID()
    }

    /// Builds all session-specific dependencies for a SwiftUI window scene.
    /// The same ID cannot be composed twice concurrently, which prevents two
    /// AppModels from racing writes to one snapshot.
    public func composition(
        for sceneValue: WindowSessionSceneValue
    ) throws -> WindowSessionComposition {
        try composition(for: sceneValue.id, presentation: sceneValue.presentation)
    }

    /// Non-throwing scene-builder adapter. It first attempts the supplied
    /// restoration value, then a fresh ID. Failure means storage configuration
    /// is invalid and the caller can render an explicit recovery view.
    public func makeComposition(
        for sceneValue: WindowSessionSceneValue
    ) -> WindowSessionComposition? {
        if let existing = try? composition(for: sceneValue) { return existing }
        guard let fallback = try? newSceneValue() else { return nil }
        return try? composition(for: fallback)
    }

    public func composition(
        for id: WindowSessionID,
        presentation: WindowSessionPresentation? = nil
    ) throws -> WindowSessionComposition {
        guard withStateLock({ !applicationTerminationCommitted }) else {
            throw WindowSessionCoordinatorError.incompleteTerminationTransaction
        }
        guard resolveWindowCloseTransactionsIfNeeded() else {
            throw WindowSessionCoordinatorError.terminationRecoveryFailed
        }
        guard resolveCommittedTerminationIfNeeded() else {
            throw WindowSessionCoordinatorError.terminationRecoveryFailed
        }
        let sessionURL = try recentItemsStore.windowSessionURL(for: id.rawValue)
        return withStateLock {
            if let existing = compositions[id]?.value { return existing }
            reservedSessionIDs.remove(id)
            liveSessionIDs.insert(id)
            if let presentation { presentations[id] = presentation }
            let store = SessionStore(
                sessionURL: sessionURL,
                fileManager: fileManager,
                limits: sessionLimits
            )
            let composition = WindowSessionComposition(
                sceneValue: WindowSessionSceneValue(
                    id: id,
                    presentation: presentation
                ),
                sessionStore: store,
                registered: { [self] in
                    try self.didPersist(id)
                },
                presentationStaged: { [self] presentation in
                    self.stagePresentation(presentation, for: id)
                },
                presentationChanged: { [self] presentation in
                    return try self.updatePresentation(presentation, for: id)
                },
                closed: { [self] disposition in
                    try self.close(id, disposition: disposition)
                },
                stagedTerminationSnapshot: { [self] snapshot in
                    try self.stageTerminationSnapshot(snapshot, for: id)
                },
                stagedWindowCloseSnapshot: { [self] snapshot in
                    try self.stageWindowCloseSnapshot(snapshot, for: id)
                },
                committedWindowCloseSnapshot: { [self] in
                    try self.commitWindowCloseSnapshot(for: id)
                },
                abortedWindowCloseSnapshot: { [self] in
                    self.abortWindowCloseSnapshot(for: id)
                }
            )
            compositions[id] = WeakComposition(composition)
            return composition
        }
    }

    /// Register only after SessionStore has atomically replaced the snapshot.
    /// This is public for non-AppModel persistence adapters; the normal window
    /// path uses `WindowSessionComposition.saveSession` or `makeAppModel`.
    public func didPersist(
        _ id: WindowSessionID,
        presentation: WindowSessionPresentation? = nil
    ) throws {
        try withStateLock {
            guard liveSessionIDs.contains(id) else { return }
            if let value = presentation ?? presentations[id] {
                try recentItemsStore.registerWindowSession(
                    id.rawValue,
                    presentation: value,
                    at: now()
                )
            } else {
                try recentItemsStore.registerWindowSession(id.rawValue, at: now())
            }
            reservedSessionIDs.remove(id)
        }
    }

    /// Records geometry for an already-persisted window. Before first save it
    /// is retained in memory and attached when `didPersist` registers the ID.
    @discardableResult
    public func updatePresentation(
        _ presentation: WindowSessionPresentation,
        for id: WindowSessionID
    ) throws -> Bool {
        guard presentation.bounds?.isValid != false else {
            throw RecentItemsStoreError.invalidWindowBounds
        }
        return try withStateLock {
            guard liveSessionIDs.contains(id) else { return false }
            presentations[id] = presentation
            return try recentItemsStore.updateWindowSessionPresentation(
                id.rawValue,
                presentation: presentation,
                at: now()
            )
        }
    }

    private func stagePresentation(
        _ presentation: WindowSessionPresentation,
        for id: WindowSessionID
    ) {
        guard presentation.bounds?.isValid != false else { return }
        withStateLock {
            guard liveSessionIDs.contains(id) else { return }
            presentations[id] = presentation
        }
    }

    public func close(
        _ id: WindowSessionID,
        disposition: WindowSessionCloseDisposition = .preserve
    ) throws {
        try withStateLock {
            if disposition == .discardEmptySession {
                _ = try recentItemsStore.removeWindowSession(id.rawValue)
            }
            reservedSessionIDs.remove(id)
            liveSessionIDs.remove(id)
            presentations.removeValue(forKey: id)
            compositions.removeValue(forKey: id)
        }
        finalizeWindowCloseSnapshot(for: id)
    }

    public func isLive(_ id: WindowSessionID) -> Bool {
        withStateLock { liveSessionIDs.contains(id) }
    }

    func isReserved(_ id: WindowSessionID) -> Bool {
        withStateLock { reservedSessionIDs.contains(id) }
    }

    private func generateUniqueID() throws -> WindowSessionID {
        return try withStateLock {
            let registered = Set(recentItemsStore.windowSessionIDs())
            for _ in 0..<128 {
                guard let candidate = WindowSessionID(rawValue: generateID()),
                      candidate != .legacy,
                      !registered.contains(candidate.rawValue),
                      !reservedSessionIDs.contains(candidate),
                      !liveSessionIDs.contains(candidate) else { continue }
                reservedSessionIDs.insert(candidate)
                return candidate
            }
            throw WindowSessionCoordinatorError.couldNotGenerateUniqueID
        }
    }

    public func releaseUnmaterializedScene(_ value: WindowSessionSceneValue) {
        withStateLock {
            guard !liveSessionIDs.contains(value.id) else { return }
            reservedSessionIDs.remove(value.id)
            presentations.removeValue(forKey: value.id)
        }
    }

    /// Starts an application-wide two-phase termination transaction. Each
    /// window stages a snapshot beside its live recovery file, leaving that
    /// live file untouched until every participant has succeeded.
    public func beginTerminationTransaction(
        expectedWindowIDs: Set<WindowSessionID>
    ) -> Bool {
        guard resolveCommittedTerminationIfNeeded() else { return false }
        return withStateLock {
            guard terminationTransactionID == nil,
                  !expectedWindowIDs.isEmpty,
                  expectedWindowIDs.isSubset(of: liveSessionIDs),
                  !fileManager.fileExists(atPath: terminationMarkerURL.path)
            else { return false }
            terminationTransactionID = UUID().uuidString.lowercased()
            stagedTerminationSessionIDs.removeAll()
            expectedTerminationSessionIDs = expectedWindowIDs
            return true
        }
    }

    /// Atomically publishes the set of staged snapshots. The marker is the
    /// commit point; startup replays the complete generation into canonical
    /// session files before constructing any window.
    public func commitTerminationTransaction() -> Bool {
        do {
            try withStateLock {
                guard let transactionID = terminationTransactionID else {
                    throw WindowSessionCoordinatorError.noTerminationTransaction
                }
                guard stagedTerminationSessionIDs == expectedTerminationSessionIDs else {
                    throw WindowSessionCoordinatorError.incompleteTerminationTransaction
                }
                let marker = TerminationCommitMarker(
                    transactionID: transactionID,
                    sessionIDs: expectedTerminationSessionIDs.map(\.rawValue).sorted()
                )
                guard expectedTerminationSessionIDs.allSatisfy({ id in
                    guard let url = try? terminationSnapshotURL(
                        for: id, transactionID: transactionID
                    ) else { return false }
                    return validTerminationSnapshot(at: url)
                }) else {
                    throw WindowSessionCoordinatorError.incompleteTerminationTransaction
                }
                let participants = TerminationParticipantManifest(
                    transactionID: transactionID, sessionIDs: marker.sessionIDs
                )
                let data = try JSONEncoder().encode(marker)
                try fileManager.createDirectory(
                    at: recentItemsStore.directoryURL,
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(participants).write(
                    to: terminationParticipantManifestURL(transactionID: transactionID),
                    options: .atomic
                )
                try data.write(to: terminationMarkerURL, options: .atomic)
                applicationTerminationCommitted = true
                didResolveCommittedTermination = true
            }
            return true
        } catch {
            return false
        }
    }

    public func finalizeCommittedTerminationTransaction() {
        // Startup owns materialization. No fallible disk work occurs after the
        // in-memory commit in the terminating process.
        withStateLock {
            terminationTransactionID = nil
            stagedTerminationSessionIDs.removeAll()
            expectedTerminationSessionIDs.removeAll()
        }
    }

    /// Test seam for simulating a crash between staging and commit.
    func terminationTransactionArtifactURLs(
        for id: WindowSessionID
    ) -> (snapshot: URL, backup: URL, marker: URL)? {
        let transactionID = withStateLock { terminationTransactionID }
        guard let transactionID,
              let snapshot = try? terminationSnapshotURL(
                  for: id, transactionID: transactionID
              ) else { return nil }
        let backup = (try? recentItemsStore.windowSessionURL(for: id.rawValue))?
            .appendingPathExtension("termination-backup-\(transactionID)")
        guard let backup else { return nil }
        return (snapshot, backup, terminationMarkerURL)
    }

    func windowCloseTransactionArtifactURLs(
        for id: WindowSessionID
    ) -> (snapshot: URL, backup: URL, marker: URL)? {
        let transactionID = withStateLock { windowCloseTransactionIDs[id] }
        guard let transactionID,
              let canonical = try? recentItemsStore.windowSessionURL(for: id.rawValue)
        else { return nil }
        return (
            windowCloseSidecarURL(for: canonical, transactionID: transactionID),
            windowCloseBackupURL(for: canonical, transactionID: transactionID),
            windowCloseMarkerURL(for: canonical, transactionID: transactionID)
        )
    }

    public func abortTerminationTransaction() {
        let artifacts: ([URL], URL?) = withStateLock {
            guard let transactionID = terminationTransactionID else { return ([], nil) }
            let urls = expectedTerminationSessionIDs.compactMap { id in
                try? terminationSnapshotURL(for: id, transactionID: transactionID)
            }
            terminationTransactionID = nil
            stagedTerminationSessionIDs.removeAll()
            expectedTerminationSessionIDs.removeAll()
            return (urls, terminationParticipantManifestURL(transactionID: transactionID))
        }
        for url in artifacts.0 { try? fileManager.removeItem(at: url) }
        if let manifest = artifacts.1 { try? fileManager.removeItem(at: manifest) }
    }

    /// Prevents any scene created by a late menu, Dock reopen, or system event
    /// from joining after the durable application termination commit point.
    public func markApplicationTerminationCommitted() {
        withStateLock { applicationTerminationCommitted = true }
    }

    private var terminationMarkerURL: URL {
        recentItemsStore.directoryURL.appendingPathComponent(
            Self.terminationMarkerFileName, isDirectory: false
        )
    }

    private func terminationParticipantManifestURL(transactionID: String) -> URL {
        recentItemsStore.directoryURL.appendingPathComponent(
            Self.terminationParticipantFilePrefix + transactionID + ".json",
            isDirectory: false
        )
    }

    private func windowCloseMarkerURL(for canonical: URL, transactionID: String) -> URL {
        canonical.appendingPathExtension(
            "window-close-marker-\(transactionID)"
        )
    }

    private func windowCloseSidecarURL(for canonical: URL, transactionID: String) -> URL {
        canonical.appendingPathExtension(
            "window-close-sidecar-\(transactionID)"
        )
    }

    private func windowCloseBackupURL(for canonical: URL, transactionID: String) -> URL {
        canonical.appendingPathExtension(
            "window-close-backup-\(transactionID)"
        )
    }

    private func stageTerminationSnapshot(
        _ snapshot: WindowSession, for id: WindowSessionID
    ) throws {
        try withStateLock {
            guard let transactionID = terminationTransactionID else {
                throw WindowSessionCoordinatorError.noTerminationTransaction
            }
            guard expectedTerminationSessionIDs.contains(id) else {
                throw WindowSessionCoordinatorError.unexpectedTerminationWindow(
                    id.rawValue
                )
            }
            let url = try terminationSnapshotURL(
                for: id, transactionID: transactionID
            )
            try SessionStore(
                sessionURL: url, fileManager: fileManager, limits: sessionLimits
            ).save(snapshot)
            stagedTerminationSessionIDs.insert(id)
        }
    }

    private func terminationSnapshotURL(
        for id: WindowSessionID, transactionID: String
    ) throws -> URL {
        try recentItemsStore.windowSessionURL(for: id.rawValue)
            .appendingPathExtension("termination-\(transactionID)")
    }

    private func stageWindowCloseSnapshot(
        _ snapshot: WindowSession, for id: WindowSessionID
    ) throws {
        try withStateLock {
            guard liveSessionIDs.contains(id), terminationTransactionID == nil,
                  windowCloseTransactionIDs[id] == nil else {
                throw WindowSessionCoordinatorError.incompleteTerminationTransaction
            }
            let transactionID = UUID().uuidString.lowercased()
            let canonical = try recentItemsStore.windowSessionURL(for: id.rawValue)
            guard fileManager.fileExists(atPath: canonical.path) else {
                throw WindowSessionCoordinatorError.incompleteTerminationTransaction
            }
            let liveData = try strictWindowSessionData(at: canonical)
            let projectedData = try snapshot.encodedData(
                using: canonicalSessionEncoder(), limits: windowSessionLimits
            )
            let backup = windowCloseBackupURL(for: canonical, transactionID: transactionID)
            let sidecar = windowCloseSidecarURL(for: canonical, transactionID: transactionID)
            do {
                try liveData.write(to: backup, options: .atomic)
                try projectedData.write(to: sidecar, options: .atomic)
                windowCloseTransactionIDs[id] = transactionID
            } catch {
                try? fileManager.removeItem(at: backup)
                try? fileManager.removeItem(at: sidecar)
                throw error
            }
        }
    }

    private func commitWindowCloseSnapshot(for id: WindowSessionID) throws {
        try withStateLock {
            guard let transactionID = windowCloseTransactionIDs[id] else {
                throw WindowSessionCoordinatorError.noTerminationTransaction
            }
            let canonical = try recentItemsStore.windowSessionURL(for: id.rawValue)
            let backup = windowCloseBackupURL(for: canonical, transactionID: transactionID)
            let sidecar = windowCloseSidecarURL(for: canonical, transactionID: transactionID)
            let marker = windowCloseMarkerURL(for: canonical, transactionID: transactionID)
            let backupData = try strictWindowSessionData(at: backup)
            let projectedData = try strictWindowSessionData(at: sidecar)
            let record = WindowCloseCommitMarker(
                transactionID: transactionID, sessionID: id.rawValue,
                liveRevision: TextFileCodec.revision(of: backupData),
                projectedRevision: TextFileCodec.revision(of: projectedData)
            )
            try JSONEncoder().encode(record).write(to: marker, options: .atomic)
            do {
                try projectedData.write(to: canonical, options: .atomic)
            } catch {
                try? fileManager.removeItem(at: marker)
                throw error
            }
        }
    }

    private func abortWindowCloseSnapshot(for id: WindowSessionID) {
        let artifacts: (URL, URL, URL)? = withStateLock {
            guard let transactionID = windowCloseTransactionIDs[id],
                  let canonical = try? recentItemsStore.windowSessionURL(for: id.rawValue)
            else { return nil }
            return (
                windowCloseMarkerURL(for: canonical, transactionID: transactionID),
                windowCloseSidecarURL(for: canonical, transactionID: transactionID),
                windowCloseBackupURL(for: canonical, transactionID: transactionID)
            )
        }
        guard let artifacts else { return }
        if fileManager.fileExists(atPath: artifacts.0.path),
           (try? fileManager.removeItem(at: artifacts.0)) == nil {
            // A surviving marker is a durable recovery instruction. Keep both
            // payloads so startup can still restore the live generation.
            return
        }
        withStateLock { windowCloseTransactionIDs.removeValue(forKey: id) }
        try? fileManager.removeItem(at: artifacts.1)
        try? fileManager.removeItem(at: artifacts.2)
    }

    private func finalizeWindowCloseSnapshot(for id: WindowSessionID) {
        let artifacts: (URL, URL, URL)? = withStateLock {
            guard let transactionID = windowCloseTransactionIDs[id],
                  let canonical = try? recentItemsStore.windowSessionURL(for: id.rawValue)
            else { return nil }
            return (
                windowCloseMarkerURL(for: canonical, transactionID: transactionID),
                windowCloseSidecarURL(for: canonical, transactionID: transactionID),
                windowCloseBackupURL(for: canonical, transactionID: transactionID)
            )
        }
        guard let artifacts else { return }
        if fileManager.fileExists(atPath: artifacts.0.path),
           (try? fileManager.removeItem(at: artifacts.0)) == nil {
            // If marker consumption fails, retain the complete recovery set. A
            // future launch conservatively restores the pre-close generation.
            return
        }
        withStateLock { windowCloseTransactionIDs.removeValue(forKey: id) }
        try? fileManager.removeItem(at: artifacts.1)
        try? fileManager.removeItem(at: artifacts.2)
    }

    /// A close marker is removed only from the actual window-close callback. If
    /// it survives process death, AppKit never committed the close, so restore
    /// the exact live generation captured before the projected canonical write.
    private func resolveWindowCloseTransactionsIfNeeded() -> Bool {
        if withStateLock({ didResolveWindowCloseTransactions }) { return true }
        return Self.withTerminationRecoveryLock {
            if withStateLock({ didResolveWindowCloseTransactions }) { return true }
            guard let names = try? fileManager.contentsOfDirectory(
                atPath: recentItemsStore.directoryURL.path
            ) else {
                // A not-yet-created support directory has no recovery work.
                if !fileManager.fileExists(atPath: recentItemsStore.directoryURL.path) {
                    withStateLock { didResolveWindowCloseTransactions = true }
                    return true
                }
                return false
            }
            var groups: [String: WindowCloseArtifactGroup] = [:]
            let artifactNames = names.filter {
                isWindowCloseArtifactCandidateName($0)
            }
            for name in artifactNames {
                let parsed: (String, String, WindowCloseArtifactKind)?
                if let value = parseWindowCloseArtifactName(
                    name, separator: Self.windowCloseMarkerInfix, kind: .marker
                ) {
                    parsed = value
                } else if let value = parseWindowCloseArtifactName(
                    name, separator: Self.windowCloseSidecarInfix, kind: .sidecar
                ) {
                    parsed = value
                } else if let value = parseWindowCloseArtifactName(
                    name, separator: Self.windowCloseBackupInfix, kind: .backup
                ) {
                    parsed = value
                } else {
                    return false
                }
                guard let (canonicalName, transactionID, kind) = parsed else { continue }
                var group = groups[transactionID] ?? WindowCloseArtifactGroup(
                    transactionID: transactionID, canonicalName: nil, marker: nil,
                    sidecar: nil, backup: nil
                )
                guard group.canonicalName == nil || group.canonicalName == canonicalName
                else { return false }
                group.canonicalName = canonicalName
                let url = recentItemsStore.directoryURL.appendingPathComponent(name)
                switch kind {
                case .marker:
                    guard group.marker == nil else { return false }
                    group.marker = url
                case .sidecar:
                    guard group.sidecar == nil else { return false }
                    group.sidecar = url
                case .backup:
                    guard group.backup == nil else { return false }
                    group.backup = url
                }
                groups[transactionID] = group
            }
            if groups.isEmpty {
                withStateLock { didResolveWindowCloseTransactions = true }
                return true
            }
            if groups.values.allSatisfy({ $0.marker == nil }) {
                // Staging without marker is uncommitted: canonical remains live.
                for group in groups.values {
                    if let sidecar = group.sidecar { try? fileManager.removeItem(at: sidecar) }
                    if let backup = group.backup { try? fileManager.removeItem(at: backup) }
                }
                withStateLock { didResolveWindowCloseTransactions = true }
                return true
            }
            let canonicalNames = groups.values.compactMap(\.canonicalName)
            guard Set(canonicalNames).count == groups.count else { return false }
            for group in groups.values.sorted(by: { $0.transactionID < $1.transactionID }) {
                guard let markerURL = group.marker, let backup = group.backup,
                      let sidecar = group.sidecar, let canonicalName = group.canonicalName
                else { return false }
                guard let marker = loadWindowCloseMarker(at: markerURL),
                      let id = WindowSessionID(rawValue: marker.sessionID),
                      let canonical = try? recentItemsStore.windowSessionURL(for: id.rawValue),
                      canonical.lastPathComponent == canonicalName,
                      markerURL == windowCloseMarkerURL(
                          for: canonical, transactionID: marker.transactionID
                      ) else { return false }
                guard snapshotRevision(at: backup) == marker.liveRevision,
                      snapshotRevision(at: sidecar) == marker.projectedRevision else {
                    return false
                }
                do {
                    let liveData = try strictWindowSessionData(at: backup)
                    try liveData.write(to: canonical, options: .atomic)
                    guard snapshotRevision(at: canonical) == marker.liveRevision else {
                        return false
                    }
                    try fileManager.removeItem(at: markerURL)
                    try? fileManager.removeItem(at: sidecar)
                    try? fileManager.removeItem(at: backup)
                } catch {
                    return false
                }
            }
            // An orphan marker-shaped artifact is evidence of an incomplete
            // close transaction; do not silently open a possibly projected file.
            let remaining = (try? fileManager.contentsOfDirectory(
                atPath: recentItemsStore.directoryURL.path
            )) ?? []
            guard !remaining.contains(where: {
                isWindowCloseArtifactCandidateName($0)
            }) else { return false }
            withStateLock { didResolveWindowCloseTransactions = true }
            return true
        }
    }

    private func parseWindowCloseArtifactName(
        _ name: String, separator: String, kind: WindowCloseArtifactKind
    ) -> (String, String, WindowCloseArtifactKind)? {
        guard let range = name.range(of: separator, options: .backwards) else { return nil }
        let canonicalName = String(name[..<range.lowerBound])
        let transactionID = String(name[range.upperBound...])
        guard UUID(uuidString: transactionID) != nil,
              isCanonicalSessionFileName(canonicalName) else { return nil }
        return (canonicalName, transactionID, kind)
    }

    private func isWindowCloseArtifactCandidateName(_ name: String) -> Bool {
        let hasArtifactInfix = name.contains(Self.windowCloseMarkerInfix)
            || name.contains(Self.windowCloseSidecarInfix)
            || name.contains(Self.windowCloseBackupInfix)
        guard hasArtifactInfix else { return false }
        return name.hasPrefix(SessionStore.sessionFileName + ".window-close-")
            || (name.hasPrefix("session-")
                && name.contains(".json.window-close-"))
    }

    private func recoverWindowCloseArtifactsForExplicitFallback(
        names: [String]
    ) -> Bool {
        let candidates = names.filter(isWindowCloseArtifactCandidateName)
        guard !candidates.isEmpty else { return true }
        var groups: [String: WindowCloseArtifactGroup] = [:]
        var malformed = false
        for name in candidates {
            let parsed = parseWindowCloseArtifactName(
                name, separator: Self.windowCloseBackupInfix, kind: .backup
            ) ?? parseWindowCloseArtifactName(
                name, separator: Self.windowCloseSidecarInfix, kind: .sidecar
            ) ?? parseWindowCloseArtifactName(
                name, separator: Self.windowCloseMarkerInfix, kind: .marker
            )
            guard let (canonicalName, transactionID, kind) = parsed else {
                malformed = true
                continue
            }
            var group = groups[transactionID] ?? WindowCloseArtifactGroup(
                transactionID: transactionID, canonicalName: nil, marker: nil,
                sidecar: nil, backup: nil
            )
            if let existing = group.canonicalName, existing != canonicalName {
                malformed = true
                continue
            }
            group.canonicalName = canonicalName
            let url = recentItemsStore.directoryURL.appendingPathComponent(name)
            switch kind {
            case .marker: group.marker = group.marker == nil ? url : group.marker
            case .sidecar: group.sidecar = group.sidecar == nil ? url : group.sidecar
            case .backup: group.backup = group.backup == nil ? url : group.backup
            }
            groups[transactionID] = group
        }
        let canonicalNames = groups.values.compactMap(\.canonicalName)
        let canRestoreAll = !malformed && Set(canonicalNames).count == groups.count
            && groups.values.allSatisfy { group in
                guard let backup = group.backup else { return false }
                return snapshotRevision(at: backup) != nil
            }
        if canRestoreAll {
            do {
                for group in groups.values {
                    guard let canonicalName = group.canonicalName,
                          let backup = group.backup else { return false }
                    let canonical = recentItemsStore.directoryURL
                        .appendingPathComponent(canonicalName)
                    try strictWindowSessionData(at: backup).write(
                        to: canonical, options: .atomic
                    )
                    guard terminationSnapshotsMatch(canonical, backup) else { return false }
                }
                return true
            } catch {
                return false
            }
        }
        // All evidence has already been copied to the archive. If no complete
        // live generation can be proven, the explicit fallback keeps the current
        // canonical files only when every registered snapshot is structurally valid.
        return validateRegisteredCanonicalSnapshots()
    }

    private func loadWindowCloseMarker(at url: URL) -> WindowCloseCommitMarker? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0, size <= Self.maximumTerminationMarkerBytes,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumTerminationMarkerBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set([
                  "transactionID", "sessionID", "liveRevision",
                  "projectedRevision"
              ]),
              dictionary.values.allSatisfy({ $0 is String }),
              let marker = try? JSONDecoder().decode(
                  WindowCloseCommitMarker.self, from: data
              ),
              UUID(uuidString: marker.transactionID) != nil,
              WindowSessionID(rawValue: marker.sessionID) != nil,
              isSHA256Revision(marker.liveRevision),
              isSHA256Revision(marker.projectedRevision) else { return nil }
        return marker
    }

    private func snapshotRevision(at url: URL) -> String? {
        guard let data = try? strictWindowSessionData(at: url) else { return nil }
        return TextFileCodec.revision(of: data)
    }

    private func isSHA256Revision(_ value: String) -> Bool {
        value.count == 71 && value.hasPrefix("sha256:")
            && value.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private var windowSessionLimits: WindowSession.Limits {
        WindowSession.Limits(
            maximumTabs: sessionLimits.maximumTabs,
            maximumRecoveryBytes: sessionLimits.maximumDraftBytes,
            maximumSnapshotBytes: sessionLimits.maximumSnapshotBytes
        )
    }

    private func canonicalSessionEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func strictWindowSessionData(at url: URL) throws -> Data {
        let data = try boundedTerminationSnapshotData(at: url)
        _ = try WindowSession.decodeValidated(from: data, limits: windowSessionLimits)
        return data
    }

    @discardableResult
    private func resolveCommittedTerminationIfNeeded() -> Bool {
        // A just-written marker belongs to the terminating process. A fresh
        // coordinator has no active transaction and materializes it before
        // any window binds its canonical store.
        guard withStateLock({ terminationTransactionID == nil }) else { return true }
        return Self.withTerminationRecoveryLock {
            resolveCommittedTerminationWhileLocked()
        }
    }

    private func resolveCommittedTerminationWhileLocked() -> Bool {
        let status = withStateLock {
            (didResolveCommittedTermination, terminationRecoveryFailed)
        }
        if status.0 { return !status.1 }
        let markerExists = fileManager.fileExists(atPath: terminationMarkerURL.path)
        let marker = loadTerminationMarker()
        if markerExists, marker == nil {
            // A corrupt marker cannot prove whether canonical files are the live
            // generation or a partially materialized committed generation. Keep
            // every artifact for the explicit archive/recovery choice.
            return false
        }
        if let marker, marker.state == .materialized {
            guard canonicalGenerationMatchesSidecars(for: marker)
                    || repairCanonicalGenerationFromSidecars(marker),
                  canonicalGenerationMatchesSidecars(for: marker),
                  consumeMaterializedMarker(marker) else { return false }
            cleanupTerminationSidecars(except: nil)
            cleanupTerminationParticipantManifests(except: nil)
        } else if let marker {
            if marker.state == .materializing,
               !hasValidTerminationBackups(for: marker) { return false }
            guard hasValidTerminationSidecars(for: marker) else {
                if marker.state == .materializing {
                    guard restoreCanonicalBackups(for: marker) else { return false }
                }
                quarantineInvalidTerminationMarker()
                cleanupTerminationSidecars(except: nil)
                cleanupTerminationParticipantManifests(except: nil)
                withStateLock {
                    didResolveCommittedTermination = true
                }
                return true
            }
            guard materialize(marker) else {
                // Preserve marker and every sidecar. A later launch replays the
                // complete generation, including any already-materialized file.
                withStateLock {
                    didResolveCommittedTermination = true
                    terminationRecoveryFailed = true
                }
                return false
            }
        }
        withStateLock {
            didResolveCommittedTermination = true
            terminationRecoveryFailed = false
        }
        if marker == nil { cleanupTerminationSidecars(except: nil) }
        if marker == nil { cleanupTerminationParticipantManifests(except: nil) }
        return true
    }

    /// Test seam used to stop and retry a committed startup replay between
    /// individual canonical writes.
    func materializeCommittedTerminationForTesting(
        beforeWritingWindowAt shouldContinue: (Int) -> Bool
    ) -> Bool {
        guard let marker = loadTerminationMarker(),
              marker.state != .materialized,
              hasValidTerminationSidecars(for: marker),
              marker.state != .materializing
                || hasValidTerminationBackups(for: marker) else { return false }
        let succeeded = materialize(
            marker, beforeWritingWindowAt: shouldContinue
        )
        if !succeeded {
            withStateLock {
                didResolveCommittedTermination = true
                terminationRecoveryFailed = true
            }
        }
        return succeeded
    }

    func materializeCommittedTerminationWithPostWriteFaultForTesting(
        _ fault: () throws -> Void
    ) -> Bool {
        guard let marker = loadTerminationMarker(),
              marker.state != .materialized,
              hasValidTerminationSidecars(for: marker) else { return false }
        return materialize(
            marker, afterWritingMaterializedMarker: fault
        )
    }

    private func materialize(
        _ marker: TerminationCommitMarker,
        beforeWritingWindowAt shouldContinue: (Int) -> Bool = { _ in true },
        afterWritingMaterializedMarker: () throws -> Void = {}
    ) -> Bool {
        struct Materialization {
            let destination: URL
            let source: URL
            let backup: URL
            let hadPrevious: Bool
        }
        do {
            precondition(marker.state != .materialized)
            let writes = try marker.sessionIDs.map { rawID -> Materialization in
                guard let id = WindowSessionID(rawValue: rawID) else {
                    throw WindowSessionCoordinatorError.incompleteTerminationTransaction
                }
                let source = try terminationSnapshotURL(
                    for: id, transactionID: marker.transactionID
                )
                let destination = try recentItemsStore.windowSessionURL(for: rawID)
                let backup = destination.appendingPathExtension(
                    "termination-backup-\(marker.transactionID)"
                )
                let hadPrevious = fileManager.fileExists(atPath: destination.path)
                if marker.state == .pending, hadPrevious,
                   !fileManager.fileExists(atPath: backup.path) {
                    try boundedTerminationSnapshotData(at: destination).write(
                        to: backup, options: .atomic
                    )
                }
                return Materialization(
                    destination: destination,
                    source: source,
                    backup: backup,
                    hadPrevious: hadPrevious
                )
            }
            func rollbackFromBackups() -> Bool {
                var succeeded = true
                for write in writes.reversed() {
                    do {
                        if fileManager.fileExists(atPath: write.backup.path) {
                            try boundedTerminationSnapshotData(at: write.backup).write(
                                to: write.destination, options: .atomic
                            )
                        } else if !write.hadPrevious,
                                  fileManager.fileExists(
                                      atPath: write.destination.path
                                  ) {
                            try fileManager.removeItem(at: write.destination)
                        } else {
                            succeeded = false
                        }
                    } catch {
                        succeeded = false
                    }
                }
                return succeeded
            }
            // Validate every source before the first canonical write. Read it
            // again one-at-a-time during replacement to cap peak memory.
            for write in writes {
                _ = try boundedTerminationSnapshotData(at: write.source)
            }
            if marker.state == .materializing {
                guard rollbackFromBackups() else {
                    throw WindowSessionCoordinatorError.terminationRecoveryFailed
                }
            }
            let materializing = TerminationCommitMarker(
                transactionID: marker.transactionID,
                sessionIDs: marker.sessionIDs,
                state: .materializing
            )
            try JSONEncoder().encode(materializing).write(
                to: terminationMarkerURL, options: .atomic
            )
            do {
                for (index, write) in writes.enumerated() {
                    guard shouldContinue(index) else {
                        throw WindowSessionCoordinatorError.incompleteTerminationTransaction
                    }
                    try boundedTerminationSnapshotData(at: write.source).write(
                        to: write.destination, options: .atomic
                    )
                }
            } catch {
                guard rollbackFromBackups() else { return false }
                let pending = TerminationCommitMarker(
                    transactionID: marker.transactionID,
                    sessionIDs: marker.sessionIDs,
                    state: .pending
                )
                try? JSONEncoder().encode(pending).write(
                    to: terminationMarkerURL, options: .atomic
                )
                throw error
            }
            let materialized = TerminationCommitMarker(
                transactionID: marker.transactionID,
                sessionIDs: marker.sessionIDs,
                state: .materialized
            )
            try JSONEncoder().encode(materialized).write(
                to: terminationMarkerURL, options: .atomic
            )
            try afterWritingMaterializedMarker()
            guard canonicalGenerationMatchesSidecars(for: materialized) else {
                return false
            }
            guard consumeMaterializedMarker(materialized) else { return false }
            cleanupTerminationSidecars(except: nil)
            cleanupTerminationParticipantManifests(except: nil)
            for write in writes { try? fileManager.removeItem(at: write.backup) }
            return true
        } catch {
            return false
        }
    }

    private func consumeMaterializedMarker(
        _ marker: TerminationCommitMarker
    ) -> Bool {
        let consumed = terminationMarkerURL.appendingPathExtension(
            "consumed-\(marker.transactionID)"
        )
        do {
            if fileManager.fileExists(atPath: consumed.path) {
                try fileManager.removeItem(at: consumed)
            }
            try fileManager.moveItem(at: terminationMarkerURL, to: consumed)
            try? fileManager.removeItem(at: consumed)
            try? fileManager.removeItem(
                at: terminationParticipantManifestURL(
                    transactionID: marker.transactionID
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func loadTerminationMarker() -> TerminationCommitMarker? {
        guard let size = try? terminationMarkerURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize,
              size <= Self.maximumTerminationMarkerBytes,
              let data = try? Data(contentsOf: terminationMarkerURL),
              data.count <= Self.maximumTerminationMarkerBytes,
              let marker = try? JSONDecoder().decode(
                  TerminationCommitMarker.self, from: data
              ),
              UUID(uuidString: marker.transactionID) != nil,
              !marker.sessionIDs.isEmpty,
              Set(marker.sessionIDs).count == marker.sessionIDs.count,
              marker.sessionIDs.allSatisfy({ rawID in
                  WindowSessionID(rawValue: rawID) != nil
              }) else { return nil }
        return marker
    }

    private func hasValidTerminationSidecars(
        for marker: TerminationCommitMarker
    ) -> Bool {
        marker.sessionIDs.allSatisfy { rawID in
            guard let id = WindowSessionID(rawValue: rawID),
                  let url = try? terminationSnapshotURL(
                      for: id, transactionID: marker.transactionID
                  ) else { return false }
            return fileManager.fileExists(atPath: url.path)
                && validTerminationSnapshot(at: url)
        }
    }

    private func validateCanonicalGeneration(
        for marker: TerminationCommitMarker
    ) -> Bool {
        marker.sessionIDs.allSatisfy { rawID in
            guard WindowSessionID(rawValue: rawID) != nil,
                  let canonical = try? recentItemsStore.windowSessionURL(
                      for: rawID
                  ),
                  fileManager.fileExists(atPath: canonical.path) else {
                return false
            }
            return validTerminationSnapshot(at: canonical)
        }
    }

    private func canonicalGenerationMatchesSidecars(
        for marker: TerminationCommitMarker
    ) -> Bool {
        guard hasValidTerminationSidecars(for: marker) else { return false }
        return marker.sessionIDs.allSatisfy { rawID in
            guard let id = WindowSessionID(rawValue: rawID),
                  let sidecar = try? terminationSnapshotURL(
                      for: id, transactionID: marker.transactionID
                  ),
                  let canonical = try? recentItemsStore.windowSessionURL(for: rawID)
            else { return false }
            return terminationSnapshotsMatch(canonical, sidecar)
        }
    }

    private func repairCanonicalGenerationFromSidecars(
        _ marker: TerminationCommitMarker
    ) -> Bool {
        guard hasValidTerminationSidecars(for: marker) else { return false }
        do {
            for rawID in marker.sessionIDs {
                guard let id = WindowSessionID(rawValue: rawID) else {
                    return false
                }
                let sidecar = try terminationSnapshotURL(
                    for: id, transactionID: marker.transactionID
                )
                let canonical = try recentItemsStore.windowSessionURL(for: rawID)
                try boundedTerminationSnapshotData(at: sidecar).write(
                    to: canonical, options: .atomic
                )
            }
            return true
        } catch {
            return false
        }
    }

    private func restoreUniqueCanonicalBackupGeneration() -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: recentItemsStore.directoryURL.path
        ) else { return false }
        let backupMarker = ".termination-backup-"
        let sidecarMarker = ".termination-"
        var backupGroups: [String: [String: URL]] = [:]
        var sidecarGroups: [String: Set<String>] = [:]
        for name in names {
            if let range = name.range(of: backupMarker, options: .backwards) {
                let transactionID = String(name[range.upperBound...])
                let canonicalName = String(name[..<range.lowerBound])
                guard UUID(uuidString: transactionID) != nil,
                      isCanonicalSessionFileName(canonicalName) else { continue }
                backupGroups[transactionID, default: [:]][canonicalName] =
                    recentItemsStore.directoryURL.appendingPathComponent(name)
                continue
            }
            guard let range = name.range(of: sidecarMarker, options: .backwards)
            else { continue }
            let transactionID = String(name[range.upperBound...])
            let canonicalName = String(name[..<range.lowerBound])
            guard UUID(uuidString: transactionID) != nil,
                  isCanonicalSessionFileName(canonicalName) else { continue }
            sidecarGroups[transactionID, default: []].insert(canonicalName)
        }
        let manifestIDs = Set(names.compactMap(terminationParticipantID(from:)))
        let transactionIDs = Set(backupGroups.keys)
            .union(sidecarGroups.keys)
            .union(manifestIDs)
        guard transactionIDs.count == 1, let transactionID = transactionIDs.first,
              let sidecars = sidecarGroups[transactionID],
              let manifest = loadTerminationParticipantManifest(transactionID: transactionID),
              let expectedNames = canonicalNames(for: manifest.sessionIDs),
              sidecars == expectedNames
        else { return false }
        guard let backups = backupGroups[transactionID], !backups.isEmpty,
              Set(backups.keys) == expectedNames,
              backups.values.allSatisfy({ validTerminationSnapshot(at: $0) })
        else { return false }
        let writes = backups.map { canonicalName, backup in
            (backup: backup, canonical: recentItemsStore.directoryURL
                .appendingPathComponent(canonicalName))
        }
        do {
            for write in writes {
                try boundedTerminationSnapshotData(at: write.backup).write(
                    to: write.canonical, options: .atomic
                )
            }
            return writes.allSatisfy {
                terminationSnapshotsMatch($0.canonical, $0.backup)
            }
        } catch {
            return false
        }
    }

    private func terminationParticipantID(from name: String) -> String? {
        guard name.hasPrefix(Self.terminationParticipantFilePrefix),
              name.hasSuffix(".json") else { return nil }
        let value = String(name
            .dropFirst(Self.terminationParticipantFilePrefix.count)
            .dropLast(".json".count))
        return UUID(uuidString: value) == nil ? nil : value
    }

    private func loadTerminationParticipantManifest(
        transactionID: String
    ) -> TerminationParticipantManifest? {
        let url = terminationParticipantManifestURL(transactionID: transactionID)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0, size <= Self.maximumTerminationMarkerBytes,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumTerminationMarkerBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["transactionID", "sessionIDs"]),
              let manifest = try? JSONDecoder().decode(
                  TerminationParticipantManifest.self, from: data
              ), manifest.transactionID == transactionID,
              !manifest.sessionIDs.isEmpty,
              Set(manifest.sessionIDs).count == manifest.sessionIDs.count,
              manifest.sessionIDs.allSatisfy({ WindowSessionID(rawValue: $0) != nil })
        else { return nil }
        return manifest
    }

    private func canonicalNames(for sessionIDs: [String]) -> Set<String>? {
        var result = Set<String>()
        for id in sessionIDs {
            guard let url = try? recentItemsStore.windowSessionURL(for: id),
                  result.insert(url.lastPathComponent).inserted else { return nil }
        }
        return result
    }

    private func isCanonicalSessionFileName(_ name: String) -> Bool {
        name == SessionStore.sessionFileName
            || (name.hasPrefix("session-")
                && name.hasSuffix(".json")
                && RecentItemsStore.isValidWindowSessionID(String(
                    name.dropFirst("session-".count).dropLast(".json".count)
                )))
    }

    private func hasValidTerminationBackups(
        for marker: TerminationCommitMarker
    ) -> Bool {
        marker.sessionIDs.allSatisfy { rawID in
            guard let canonical = try? recentItemsStore.windowSessionURL(
                for: rawID
            ) else { return false }
            let backup = canonical.appendingPathExtension(
                "termination-backup-\(marker.transactionID)"
            )
            return fileManager.fileExists(atPath: backup.path)
                && validTerminationSnapshot(at: backup)
        }
    }

    private func restoreCanonicalBackups(
        for marker: TerminationCommitMarker
    ) -> Bool {
        guard hasValidTerminationBackups(for: marker) else { return false }
        do {
            for rawID in marker.sessionIDs {
                let canonical = try recentItemsStore.windowSessionURL(for: rawID)
                let backup = canonical.appendingPathExtension(
                    "termination-backup-\(marker.transactionID)"
                )
                try boundedTerminationSnapshotData(at: backup).write(
                    to: canonical, options: .atomic
                )
            }
            return true
        } catch {
            return false
        }
    }

    private func hasTerminationBackupArtifacts() -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: recentItemsStore.directoryURL.path
        ) else { return false }
        return names.contains(where: isTerminationBackupName)
    }

    private func hasWindowCloseArtifacts() -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: recentItemsStore.directoryURL.path
        ) else { return false }
        return names.contains(where: isWindowCloseArtifactCandidateName)
    }

    private func validateRegisteredCanonicalSnapshots() -> Bool {
        recentItemsStore.windowSessionIDs().allSatisfy { rawID in
            guard let url = try? recentItemsStore.windowSessionURL(for: rawID),
                  fileManager.fileExists(atPath: url.path) else { return false }
            return validTerminationSnapshot(at: url)
        }
    }

    private func removeWindowCloseArtifacts(names: [String]) {
        for name in names where isWindowCloseArtifactCandidateName(name) {
            try? fileManager.removeItem(
                at: recentItemsStore.directoryURL.appendingPathComponent(name)
            )
        }
    }

    private func cleanupTerminationParticipantManifests(except transactionID: String?) {
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: recentItemsStore.directoryURL.path
        ) else { return }
        for name in names {
            guard let candidate = terminationParticipantID(from: name),
                  candidate != transactionID else { continue }
            try? fileManager.removeItem(
                at: recentItemsStore.directoryURL.appendingPathComponent(name)
            )
        }
    }

    private func cleanupTerminationSidecars(except transactionID: String?) {
        let retainedSuffix = transactionID.map { ".termination-\($0)" }
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: recentItemsStore.directoryURL.path
        ) else { return }
        for name in names where isTerminationSidecarName(name) {
            if retainedSuffix.map({ name.hasSuffix($0) }) == true { continue }
            try? fileManager.removeItem(
                at: recentItemsStore.directoryURL.appendingPathComponent(name)
            )
        }
        for name in names where isTerminationBackupName(name) {
            if let transactionID, name.hasSuffix(
                ".termination-backup-\(transactionID)"
            ) { continue }
            try? fileManager.removeItem(
                at: recentItemsStore.directoryURL.appendingPathComponent(name)
            )
        }
    }

    private func quarantineInvalidTerminationMarker() {
        let quarantineURL = terminationMarkerURL.appendingPathExtension(
            "corrupt-\(UUID().uuidString.lowercased())"
        )
        if (try? fileManager.moveItem(
            at: terminationMarkerURL, to: quarantineURL
        )) == nil {
            try? fileManager.removeItem(at: terminationMarkerURL)
        }
    }

    private func isTerminationSidecarName(_ name: String) -> Bool {
        guard let range = name.range(
            of: ".json.termination-", options: .backwards
        ) else { return false }
        let transaction = String(name[range.upperBound...])
        guard UUID(uuidString: transaction) != nil else { return false }
        let prefix = String(name[..<range.lowerBound])
        return prefix == "session"
            || (prefix.hasPrefix("session-")
                && RecentItemsStore.isValidWindowSessionID(
                    String(prefix.dropFirst("session-".count))
                ))
    }

    private func isTerminationBackupName(_ name: String) -> Bool {
        guard let range = name.range(
            of: ".json.termination-backup-", options: .backwards
        ) else { return false }
        let transaction = String(name[range.upperBound...])
        guard UUID(uuidString: transaction) != nil else { return false }
        let prefix = String(name[..<range.lowerBound])
        return prefix == "session"
            || (prefix.hasPrefix("session-")
                && RecentItemsStore.isValidWindowSessionID(
                    String(prefix.dropFirst("session-".count))
                ))
    }

    private func validTerminationSnapshot(at url: URL) -> Bool {
        guard let data = try? boundedTerminationSnapshotData(at: url),
              let session = try? WindowSession.decodeValidated(
                  from: data,
                  limits: windowSessionLimits
              ) else { return false }
        return session.formatVersion == WindowSession.currentFormatVersion
    }

    private func boundedTerminationSnapshotData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 0, size <= sessionLimits.maximumSnapshotBytes else {
            throw WindowSessionCoordinatorError.incompleteTerminationTransaction
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= sessionLimits.maximumSnapshotBytes else {
            throw WindowSessionCoordinatorError.incompleteTerminationTransaction
        }
        return data
    }

    private func terminationSnapshotsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard validTerminationSnapshot(at: lhs), validTerminationSnapshot(at: rhs),
              let leftSize = try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let rightSize = try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              leftSize == rightSize, leftSize <= sessionLimits.maximumSnapshotBytes,
              let left = try? FileHandle(forReadingFrom: lhs),
              let right = try? FileHandle(forReadingFrom: rhs)
        else { return false }
        defer {
            try? left.close()
            try? right.close()
        }
        do {
            while true {
                let leftChunk = try left.read(upToCount: 64 * 1_024) ?? Data()
                let rightChunk = try right.read(upToCount: 64 * 1_024) ?? Data()
                guard leftChunk == rightChunk else { return false }
                if leftChunk.isEmpty { return true }
            }
        } catch {
            return false
        }
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func withTerminationRecoveryLock<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        WindowSessionTerminationRecoveryLock.shared.lock()
        defer { WindowSessionTerminationRecoveryLock.shared.unlock() }
        return try body()
    }
}

private enum WindowSessionTerminationRecoveryLock {
    static let shared = NSLock()
}

private extension NSLock {
    func withCriticalSection<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
