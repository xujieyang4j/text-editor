import Combine
import Foundation
import LumenEditorCore

private final class AutoSaveTaskBox {
    var delayTask: Task<Void, Never>?
    var runnerTask: Task<Void, Never>?

    deinit {
        delayTask?.cancel()
        runnerTask?.cancel()
    }
}

struct AutoSaveSettingsSnapshot: Equatable, Sendable {
    let mode: AutoSaveMode
    let delayMilliseconds: Int

    init(mode: AutoSaveMode, delayMilliseconds: Int) {
        self.mode = mode
        self.delayMilliseconds = max(0, delayMilliseconds)
    }

    init(_ settings: EditorSettings) {
        self.init(
            mode: settings.autoSave,
            delayMilliseconds: settings.autoSaveDelayMs
        )
    }
}

struct AutoSaveDocumentSnapshot: Identifiable, Equatable, Sendable {
    let id: EditorDocument.ID
    let fileURL: URL?
    let isDirty: Bool
    let hasExternalConflict: Bool
    let hasEncodingIssue: Bool
    let isSaving: Bool
    let isEditingLocked: Bool
    let revision: UInt64
    let encoding: TextEncoding
    let lineEnding: LineEnding
    let eolOverride: LineEnding?

    init(
        id: EditorDocument.ID,
        fileURL: URL?,
        isDirty: Bool,
        hasExternalConflict: Bool = false,
        hasEncodingIssue: Bool = false,
        isSaving: Bool = false,
        isEditingLocked: Bool = false,
        revision: UInt64 = 0,
        encoding: TextEncoding = .utf8,
        lineEnding: LineEnding = .lf,
        eolOverride: LineEnding? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.isDirty = isDirty
        self.hasExternalConflict = hasExternalConflict
        self.hasEncodingIssue = hasEncodingIssue
        self.isSaving = isSaving
        self.isEditingLocked = isEditingLocked
        self.revision = revision
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.eolOverride = eolOverride
    }

    @MainActor
    init(_ document: EditorDocument) {
        self.init(
            id: document.id,
            fileURL: document.fileURL,
            isDirty: document.isDirty,
            hasExternalConflict: document.externalConflict != nil,
            hasEncodingIssue: document.encodingIssue != nil,
            isSaving: document.isSaving,
            isEditingLocked: document.isEditingLocked,
            revision: document.buffer.revision,
            encoding: document.encoding,
            lineEnding: document.lineEnding,
            eolOverride: document.eolOverride
        )
    }

    var isEligible: Bool {
        fileURL != nil
            && isDirty
            && !hasExternalConflict
            && !hasEncodingIssue
            && !isSaving
            && !isEditingLocked
    }
}

/// Electron-compatible automatic-save scheduling for one application window.
///
/// The controller never chooses a destination and never owns document state.
/// Callers inject bounded value snapshots and the save operation, which keeps
/// untitled-document prompts and all disk lifecycle rules in AppModel.
@MainActor
final class AutoSaveController: ObservableObject {
    typealias SettingsSnapshot = @MainActor () -> AutoSaveSettingsSnapshot
    typealias DocumentSnapshots = @MainActor () -> [AutoSaveDocumentSnapshot]
    typealias SaveDocument = @MainActor (AutoSaveDocumentSnapshot) async -> Bool
    typealias Delay = @MainActor (UInt64) async throws -> Void

    @Published private(set) var hasPendingDelay = false
    @Published private(set) var isRunningSavePass = false
    @Published private(set) var inFlightDocumentIDs: Set<EditorDocument.ID> = []

    private struct SavePassRequest {
        let generation: UInt64
    }

    private let settingsSnapshot: SettingsSnapshot
    private let documentSnapshots: DocumentSnapshots
    private let saveDocument: SaveDocument
    private let delay: Delay
    private let taskBox = AutoSaveTaskBox()

    private var generation: UInt64 = 0
    private var runnerToken: UUID?
    private var requestedPass: SavePassRequest?
    private var subscriptions: Set<AnyCancellable> = []
    private var lastSchedulingSignatures: [SchedulingSignature]?

    private struct SchedulingSignature: Equatable {
        let id: EditorDocument.ID
        let fileURL: URL?
        let isDirty: Bool
        let hasExternalConflict: Bool
        let hasEncodingIssue: Bool
        let isEditingLocked: Bool
        let revision: UInt64
        let encoding: TextEncoding
        let lineEnding: LineEnding
        let eolOverride: LineEnding?

        init(_ snapshot: AutoSaveDocumentSnapshot) {
            id = snapshot.id
            fileURL = snapshot.fileURL
            isDirty = snapshot.isDirty
            hasExternalConflict = snapshot.hasExternalConflict
            hasEncodingIssue = snapshot.hasEncodingIssue
            isEditingLocked = snapshot.isEditingLocked
            revision = snapshot.revision
            encoding = snapshot.encoding
            lineEnding = snapshot.lineEnding
            eolOverride = snapshot.eolOverride
        }
    }

    init(
        settings: @escaping SettingsSnapshot,
        documents: @escaping DocumentSnapshots,
        save: @escaping SaveDocument,
        delay: @escaping Delay = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        settingsSnapshot = settings
        documentSnapshots = documents
        saveDocument = save
        self.delay = delay
    }

    /// Production composition entry point. The returned controller owns only
    /// subscriptions; SettingsController and AppModel retain their normal app
    /// lifetimes and remain the sources of truth.
    static func connected(
        settings: SettingsController,
        model: AppModel
    ) -> AutoSaveController {
        let controller = AutoSaveController(
            settings: { AutoSaveSettingsSnapshot(settings.settings) },
            documents: { model.documents.map { AutoSaveDocumentSnapshot($0) } },
            save: { snapshot in
                guard let document = model.documents.first(where: { $0.id == snapshot.id }),
                      !model.isTextEditingLocked,
                      document.fileURL?.standardizedFileURL
                        == snapshot.fileURL?.standardizedFileURL,
                      AutoSaveDocumentSnapshot(document).isEligible else {
                    return false
                }
                return await model.save(document)
            }
        )

        settings.$settings
            .map(AutoSaveSettingsSnapshot.init)
            .removeDuplicates()
            .sink { [weak controller] snapshot in
                Task { @MainActor [weak controller] in
                    controller?.configurationDidChange(snapshot)
                }
            }
            .store(in: &controller.subscriptions)

        model.objectWillChange
            .sink { [weak controller] _ in
                // EditorDocument and AppModel publish before their mutations.
                // Read the injected value snapshots on the following actor turn.
                Task { @MainActor [weak controller] in
                    await Task.yield()
                    controller?.documentStateDidChange()
                }
            }
            .store(in: &controller.subscriptions)

        return controller
    }

    /// Notify the controller after document content, format, or lifecycle state
    /// changes. In after-delay mode this resets the one global debounce timer.
    func documentStateDidChange() {
        let documents = documentSnapshots()
        let signatures = documents.map(SchedulingSignature.init)
        guard signatures != lastSchedulingSignatures else { return }
        lastSchedulingSignatures = signatures
        configurationDidChange(settingsSnapshot())
    }

    /// Notify the controller after an auto-save mode or delay change.
    func settingsDidChange() {
        configurationDidChange(settingsSnapshot())
    }

    /// The owning editor window resigned key status. `on_focus_change` mirrors
    /// Electron's per-window blur handler; other modes deliberately ignore it.
    /// Application-wide activation notifications must not call this method,
    /// because every window composition owns an independent controller.
    func windowDidResignKey() {
        guard settingsSnapshot().mode == .onFocusChange else { return }
        invalidatePendingDelay()
        requestSavePass(generation: generation)
    }

    /// Cancels pending debounce and save-pass work. Any underlying save action
    /// that does not cooperate with Task cancellation may still finish safely;
    /// its late completion cannot schedule new work for the cancelled generation.
    func cancel() {
        generation &+= 1
        delayTask?.cancel()
        delayTask = nil
        hasPendingDelay = false
        requestedPass = nil

        runnerToken = nil
        runnerTask?.cancel()
        runnerTask = nil
        isRunningSavePass = false
        inFlightDocumentIDs.removeAll()
    }

    func shutdown() {
        cancel()
        subscriptions.removeAll()
    }

    /// Test/support hook. A pending after-delay timer must be released by an
    /// injected Delay before this method can return.
    func waitForIdle() async {
        while true {
            let pendingDelay = delayTask
            let pendingRunner = runnerTask
            guard pendingDelay != nil || pendingRunner != nil else { return }
            await pendingDelay?.value
            await pendingRunner?.value
            await Task.yield()
        }
    }

    private func configurationDidChange(_ configuration: AutoSaveSettingsSnapshot) {
        switch configuration.mode {
        case .off, .onFocusChange:
            invalidatePendingDelay()
            requestedPass = nil
        case .afterDelay:
            scheduleAfterDelay(configuration.delayMilliseconds)
        }
    }

    private func invalidatePendingDelay() {
        generation &+= 1
        delayTask?.cancel()
        delayTask = nil
        hasPendingDelay = false
    }

    private func scheduleAfterDelay(_ milliseconds: Int) {
        invalidatePendingDelay()
        let expectedGeneration = generation
        let nanoseconds = Self.nanoseconds(forMilliseconds: milliseconds)
        let delay = self.delay
        hasPendingDelay = true
        delayTask = Task { @MainActor [weak self] in
            do {
                try await delay(nanoseconds)
            } catch {
                self?.delayFinished(generation: expectedGeneration)
                return
            }
            guard let self, !Task.isCancelled,
                  self.generation == expectedGeneration,
                  self.settingsSnapshot().mode == .afterDelay else {
                self?.delayFinished(generation: expectedGeneration)
                return
            }
            self.delayTask = nil
            self.hasPendingDelay = false
            self.requestSavePass(generation: expectedGeneration)
        }
    }

    private func delayFinished(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        delayTask = nil
        hasPendingDelay = false
    }

    private func requestSavePass(generation: UInt64) {
        requestedPass = SavePassRequest(generation: generation)
        guard runnerTask == nil else { return }

        let token = UUID()
        runnerToken = token
        isRunningSavePass = true
        runnerTask = Task { @MainActor [weak self] in
            await self?.drainRequestedPasses(token: token)
        }
    }

    private func drainRequestedPasses(token: UUID) async {
        defer { finishRunner(token: token) }
        while runnerToken == token, !Task.isCancelled, let request = requestedPass {
            requestedPass = nil
            await performSavePass(request, runnerToken: token)
        }
    }

    private func finishRunner(token: UUID) {
        guard runnerToken == token else { return }
        runnerToken = nil
        runnerTask = nil
        isRunningSavePass = false
    }

    private func performSavePass(
        _ request: SavePassRequest,
        runnerToken token: UUID
    ) async {
        // A superseded delayed request must never reach the disk. Once a pass
        // begins, it may finish its captured eligible set like Electron does.
        guard request.generation == generation else { return }
        let candidates = documentSnapshots().filter {
            $0.isEligible && !inFlightDocumentIDs.contains($0.id)
        }

        for snapshot in candidates {
            guard runnerToken == token, !Task.isCancelled else { return }
            inFlightDocumentIDs.insert(snapshot.id)
            let saved = await saveDocument(snapshot)
            inFlightDocumentIDs.remove(snapshot.id)

            guard runnerToken == token, !Task.isCancelled else { return }
            if saved,
               let current = documentSnapshots().first(where: { $0.id == snapshot.id }),
               current.isEligible,
               settingsSnapshot().mode == .afterDelay {
                // An edit or format change landed while the saved snapshot was
                // in flight. Queue one trailing debounced pass.
                scheduleAfterDelay(settingsSnapshot().delayMilliseconds)
            }
        }
    }

    private static func nanoseconds(forMilliseconds milliseconds: Int) -> UInt64 {
        let value = UInt64(max(0, milliseconds))
        let result = value.multipliedReportingOverflow(by: 1_000_000)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private var delayTask: Task<Void, Never>? {
        get { taskBox.delayTask }
        set { taskBox.delayTask = newValue }
    }

    private var runnerTask: Task<Void, Never>? {
        get { taskBox.runnerTask }
        set { taskBox.runnerTask = newValue }
    }
}
