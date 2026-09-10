import Combine
import Foundation
import LumenEditorMobileCore
import UIKit

@MainActor
final class MobileWorkspaceModel: ObservableObject {
    @Published private(set) var documents: [MobileDocumentSession] = []
    @Published var activeDocumentID: UUID?
    @Published var isBusy = true
    @Published var alertMessage: String?
    @Published private(set) var recentFiles: [MobileRecentFile] = []

    private let drafts: MobileDraftStore
    private let files: MobileFileAccess
    private let recents: MobileRecentStore
    private var checkpointTasks: [UUID: Task<Void, Never>] = [:]
    private var presenters: [UUID: MobileFilePresenter] = [:]
    private var presenterTokens: [UUID: UUID] = [:]
    private var externalInspectionTasks: [UUID: Task<Void, Never>] = [:]
    private var externalInspectionTokens: [UUID: UUID] = [:]
    private var pendingMovedURLs: [UUID: URL] = [:]
    private var lifecycleCheckpointToken: UUID?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var openingURLs: Set<URL> = []
    private var busyOperationCount = 1
    private var startupTask: Task<Void, Never>?
    private var workspaceAdditionReservations: [UUID: Int] = [:]
    private var foregroundRevalidationPending = false
    private var untitledCounter = 1

    init(
        drafts: MobileDraftStore = .applicationStore(),
        files: MobileFileAccess = MobileFileAccess(),
        recents: MobileRecentStore = .applicationStore()
    ) {
        self.drafts = drafts
        self.files = files
        self.recents = recents
        startupTask = Task { [weak self] in await self?.initializeWorkspace() }
    }

    var activeDocument: MobileDocumentSession? {
        guard let activeDocumentID else { return nil }
        return documents.first { $0.id == activeDocumentID }
    }

    func newDocument() {
        Task { [weak self] in
            guard let self else { return }
            await waitForStartup()
            createNewDocument()
        }
    }

    private func createNewDocument() {
        guard acceptWorkspaceAddition(
            utf16UnitCount: 0, encodingRecoveryByteCount: 0, bookmarkByteCount: 0
        ) else { return }
        let baseName = String(localized: "untitled")
        var name: String
        repeat {
            name = untitledCounter == 1 ? baseName : "\(baseName) \(untitledCounter)"
            untitledCounter += 1
        } while documents.contains(where: { $0.displayName == name })
        let document = MobileDocumentSession(
            displayName: name, content: ""
        )
        documents.append(document)
        activeDocumentID = document.id
        scheduleCheckpoint(document)
    }

    func openPickedURLs(_ urls: [URL]) {
        Task {
            await waitForStartup()
            await openPickedURLsNow(urls)
        }
    }

    func openURL(_ url: URL) {
        openPickedURLs([url])
    }

    private func openPickedURLsNow(_ urls: [URL]) async {
        var references: [MobileFileReference] = []
        for url in urls {
            do {
                references.append(try await files.reference(forPickedURL: url))
            } catch {
                alertMessage = error.localizedDescription
            }
        }
        await openReferences(references)
    }

    func openRecent(_ recent: MobileRecentFile) {
        Task {
            await waitForStartup()
            do {
                let reference = try await files.resolve(recent.bookmarkData)
                await openReferences([reference])
            } catch {
                recentFiles = (try? await recents.remove(id: recent.id)) ?? recentFiles
                alertMessage = error.localizedDescription
            }
        }
    }

    func removeRecent(_ recent: MobileRecentFile) {
        Task { recentFiles = (try? await recents.remove(id: recent.id)) ?? recentFiles }
    }

    func documentDidEdit(_ document: MobileDocumentSession) {
        document.persistence.markEdited()
        scheduleCheckpoint(document)
    }

    func canReplaceDocumentContent(
        _ document: MobileDocumentSession,
        withUTF16UnitCount utf16UnitCount: Int
    ) -> Bool {
        guard documents.contains(where: { $0.id == document.id }), utf16UnitCount >= 0 else {
            return false
        }
        let currentEstimatedByteCount = estimatedPayloadByteCount(for: document)
        let candidateEstimatedByteCount = MobileWorkspaceCapacity.estimatedPayloadByteCount(
            utf16UnitCount: utf16UnitCount,
            encodingRecoveryByteCount: document.encodingRecoveryData?.count ?? 0,
            bookmarkByteCount: document.fileReference?.bookmarkData.count ?? 0
        )
        guard MobileWorkspaceCapacity.replacementRejection(
            otherEstimatedByteCounts: workspaceEstimatedByteCounts(
                excludingDocumentID: document.id
            ),
            currentEstimatedByteCount: currentEstimatedByteCount,
            replacementEstimatedByteCount: candidateEstimatedByteCount
        ) == nil else {
            document.notice = String(localized: "workspace_edit_memory_limit")
            return false
        }
        if document.notice == String(localized: "workspace_edit_memory_limit") {
            document.notice = nil
        }
        return true
    }

    func maximumReplacementUTF16UnitCount(for document: MobileDocumentSession) -> Int {
        guard documents.contains(where: { $0.id == document.id }) else { return 0 }
        return MobileWorkspaceCapacity.maximumReplacementUTF16UnitCount(
            otherEstimatedByteCounts: workspaceEstimatedByteCounts(
                excludingDocumentID: document.id
            ),
            currentUTF16UnitCount: document.contentUTF16UnitCount,
            encodingRecoveryByteCount: document.encodingRecoveryData?.count ?? 0,
            bookmarkByteCount: document.fileReference?.bookmarkData.count ?? 0
        )
    }

    func documentSelectionDidChange(
        _ document: MobileDocumentSession,
        status: MobileCursorStatus
    ) {
        document.cursorStatus = status
        scheduleCheckpoint(document)
    }

    func save(_ document: MobileDocumentSession) {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        guard !document.requiresEncodingConfirmation else {
            document.notice = String(localized: "confirm_encoding_before_editing")
            return
        }
        guard document.isDirty else {
            document.notice = String(localized: "saved_verified")
            return
        }
        guard document.externalChange == nil else {
            document.notice = String(localized: "external_change_unresolved")
            return
        }
        guard let reference = document.fileReference, !document.isSaving else { return }
        let content = document.content
        let encoding = document.encoding
        let lineEnding = document.lineEnding
        let expectedRevision = document.persistence.baselineRevision
        let expectedURL = reference.url.standardizedFileURL
        let recoverySnapshot = document.draftSnapshot()
        document.isSaving = true
        Task {
            defer { document.isSaving = false }
            do {
                try await drafts.checkpoint(recoverySnapshot)
                let saved = try await files.encodeAndWriteVerified(
                    content, encoding: encoding, lineEnding: lineEnding,
                    to: reference, expectedRevision: expectedRevision
                )
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                if document.externalChange != nil {
                    document.persistence.acceptVerifiedBaselineWhileDirty(
                        revision: saved.revision
                    )
                    document.notice = String(localized: "external_change_unresolved")
                } else if document.content == content, document.encoding == encoding,
                   document.lineEnding == lineEnding {
                    document.persistence.acceptVerifiedSave(revision: saved.revision)
                    document.externalChange = nil
                    document.notice = String(localized: "saved_verified")
                } else {
                    document.persistence.acceptVerifiedBaselineWhileDirty(revision: saved.revision)
                    document.notice = String(localized: "saved_earlier_revision")
                }
                checkpointNow(document)
            } catch let MobileFileAccessError.verificationFailed(attemptedRevision) {
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.persistence.retainAfterUnverifiedWrite(
                    attemptedRevision: attemptedRevision
                )
                document.notice = String(localized: "save_unverified")
                checkpointNow(document)
            } catch is SavePreflightError {
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.externalChange = .modified
                document.notice = String(localized: "source_changed_conflict")
                checkpointNow(document)
            } catch {
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.notice = error.localizedDescription
                checkpointNow(document)
            }
        }
    }

    func reopen(_ document: MobileDocumentSession, using encoding: MobileTextEncoding) {
        guard !document.isSaving,
              document.encodingRecoveryData != nil || document.fileReference != nil else { return }
        let reference = document.fileReference
        let expectedURL = reference?.url.standardizedFileURL
        document.isSaving = true
        Task {
            defer { document.isSaving = false }
            do {
                let opened: MobileOpenedTextFile
                var sourceState = document.externalChange
                if let recoveryData = document.encodingRecoveryData {
                    opened = try await files.decodeRecoveryData(
                        recoveryData, forcedEncoding: encoding
                    )
                    if let reference {
                        do {
                            let currentData = try await files.read(reference)
                            if MobileTextCodec.revision(of: currentData) != opened.revision {
                                sourceState = .modified
                            } else if sourceState != .deleted {
                                sourceState = nil
                            }
                        } catch {
                            if sourceState != .deleted { sourceState = .unavailable }
                        }
                    }
                } else {
                    guard let reference else {
                        throw WorkspaceMessageError.message(
                            String(localized: "encoding_recovery_unavailable")
                        )
                    }
                    opened = try await files.open(reference, forcedEncoding: encoding)
                }
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                try validateReload(opened, replacing: document)
                document.content = opened.content
                document.encoding = opened.encoding
                document.lineEnding = opened.lineEnding
                document.selection = NSRange(location: 0, length: 0)
                document.cursorStatus = MobileCursorStatus(
                    line: 1, column: 1, utf16Offset: 0, selectionLength: 0
                )
                document.persistence = MobilePersistenceState(
                    baselineRevision: reference == nil ? nil : opened.revision,
                    isDirty: reference == nil || sourceState != nil
                )
                document.requiresEncodingConfirmation = false
                document.encodingRecoveryData = nil
                document.externalChange = sourceState
                switch sourceState {
                case .modified:
                    document.notice = String(localized: "source_changed_conflict")
                case .unavailable:
                    document.notice = String(localized: "source_unavailable")
                case .deleted:
                    document.notice = String(localized: "source_deleted")
                case nil:
                    document.notice = String(localized: "encoding_confirmed")
                }
                checkpointNow(document)
            } catch {
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.notice = error.localizedDescription
            }
        }
    }

    func attachExportedFile(
        _ url: URL,
        data: Data,
        to document: MobileDocumentSession
    ) {
        guard documents.contains(where: { $0.id == document.id }),
              !document.isSaving else { return }
        document.isSaving = true
        checkpointNow(document)
        Task {
            defer { document.isSaving = false }
            do {
                let reference = try await files.verifyExportedData(data, at: url)
                guard documents.contains(where: { $0.id == document.id }) else { return }
                let revision = MobileTextCodec.revision(of: data)
                let current = try? MobileTextCodec.encode(
                    document.content, encoding: document.encoding, lineEnding: document.lineEnding
                )
                let previousBookmark = document.fileReference?.bookmarkData
                cancelExternalInspection(for: document.id)
                stopMonitoring(document)
                document.fileReference = reference
                document.displayName = url.lastPathComponent
                document.externalChange = nil
                if let previousBookmark, previousBookmark != reference.bookmarkData,
                   let staleRecent = recentFiles.first(where: {
                       $0.bookmarkData == previousBookmark
                   }) {
                    recentFiles = (try? await recents.remove(id: staleRecent.id)) ?? recentFiles
                }
                await recordRecent(reference, displayName: document.displayName)
                if current == data {
                    document.persistence.acceptVerifiedSave(revision: revision)
                    document.notice = String(localized: "saved_verified")
                } else {
                    document.persistence.acceptVerifiedBaselineWhileDirty(revision: revision)
                    document.notice = String(localized: "saved_earlier_revision")
                }
                checkpointNow(document)
                startMonitoring(document)
            } catch let MobileFileAccessError.verificationFailed(attemptedRevision) {
                _ = attemptedRevision
                document.persistence.retainAfterUnverifiedCopy()
                document.notice = String(localized: "save_unverified")
                checkpointNow(document)
            } catch {
                document.notice = error.localizedDescription
                checkpointNow(document)
            }
        }
    }

    func exportData(for document: MobileDocumentSession) async throws -> Data {
        try await drafts.checkpoint(document.draftSnapshot())
        try await files.encode(
            document.content, encoding: document.encoding, lineEnding: document.lineEnding
        )
    }

    func shareSnapshot(for document: MobileDocumentSession) async throws -> URL {
        let data = try await exportData(for: document)
        return try await files.makeShareSnapshot(
            data, suggestedName: document.displayName
        )
    }

    func removeShareSnapshot(at url: URL) {
        Task { await files.removeShareSnapshot(at: url) }
    }

    func close(_ document: MobileDocumentSession) {
        guard !document.isSaving else {
            document.notice = String(localized: "operation_in_progress")
            activeDocumentID = document.id
            return
        }
        guard !document.isDirty else {
            document.notice = String(localized: "save_before_close")
            activeDocumentID = document.id
            return
        }
        closeAfterRemovingRecovery(document)
    }

    func discardAndClose(_ document: MobileDocumentSession) {
        guard !document.isSaving else {
            document.notice = String(localized: "operation_in_progress")
            activeDocumentID = document.id
            return
        }
        closeAfterRemovingRecovery(document)
    }

    private func closeAfterRemovingRecovery(_ document: MobileDocumentSession) {
        checkpointTasks.removeValue(forKey: document.id)?.cancel()
        cancelExternalInspection(for: document.id)
        document.isSaving = true
        Task {
            do {
                try await drafts.remove(id: document.id)
                guard documents.contains(where: { $0.id == document.id }) else { return }
                stopMonitoring(document)
                documents.removeAll { $0.id == document.id }
                if activeDocumentID == document.id { activeDocumentID = documents.last?.id }
            } catch {
                document.isSaving = false
                document.notice = String(localized: "recovery_delete_failed")
            }
        }
    }

    func applicationWillResignActive() {
        foregroundRevalidationPending = false
        let snapshots = documents.map { document -> MobileDraftSnapshot in
            checkpointTasks.removeValue(forKey: document.id)?.cancel()
            return document.draftSnapshot()
        }
        guard !snapshots.isEmpty else { return }

        let token = UUID()
        lifecycleCheckpointToken = token
        if backgroundTaskIdentifier == .invalid {
            backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
                withName: "LumenRecoveryCheckpoint"
            ) { [weak self] in
                Task { @MainActor [weak self] in self?.endBackgroundCheckpoint() }
            }
        }
        Task { [weak self, drafts] in
            var failedCount = 0
            for snapshot in snapshots {
                do { try await drafts.checkpoint(snapshot) }
                catch { failedCount += 1 }
            }
            guard let self, self.lifecycleCheckpointToken == token else { return }
            if failedCount > 0, self.alertMessage == nil {
                self.alertMessage = String(
                    format: String(localized: "recovery_checkpoint_failed_count"),
                    failedCount
                )
            }
            self.lifecycleCheckpointToken = nil
            self.endBackgroundCheckpoint()
        }
    }

    func applicationDidBecomeActive() {
        foregroundRevalidationPending = true
        Task { [weak self] in
            guard let self else { return }
            await waitForStartup()
            guard foregroundRevalidationPending else { return }
            foregroundRevalidationPending = false
            inspectOpenSourcesAfterActivation()
        }
    }

    private func inspectOpenSourcesAfterActivation() {
        for document in documents where document.fileReference != nil {
            if let movedURL = pendingMovedURLs[document.id],
               let presenterToken = presenterTokens[document.id] {
                completePresentedItemMove(
                    to: movedURL, documentID: document.id, presenterToken: presenterToken
                )
            } else {
                scheduleExternalInspection(document, delay: .zero)
            }
        }
    }

    private func scheduleCheckpoint(_ document: MobileDocumentSession) {
        checkpointTasks[document.id]?.cancel()
        checkpointTasks[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, let document else { return }
            let snapshot = document.draftSnapshot()
            do {
                try await self.drafts.checkpoint(snapshot)
            } catch {
                guard !Task.isCancelled, self.documents.contains(where: { $0.id == document.id })
                else { return }
                document.notice = String(localized: "recovery_checkpoint_failed")
            }
        }
    }

    private func checkpointNow(_ document: MobileDocumentSession) {
        checkpointTasks[document.id]?.cancel()
        let snapshot = document.draftSnapshot()
        checkpointTasks[document.id] = Task { [weak self, weak document, drafts] in
            do {
                try await drafts.checkpoint(snapshot)
            } catch {
                guard !Task.isCancelled, let self, let document,
                      self.documents.contains(where: { $0.id == document.id }) else { return }
                document.notice = String(localized: "recovery_checkpoint_failed")
            }
        }
    }

    private func endBackgroundCheckpoint() {
        guard backgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }

    private func openReferences(_ references: [MobileFileReference]) async {
        beginBusyOperation()
        defer { endBusyOperation() }
        for reference in references {
            let normalizedURL = reference.url.standardizedFileURL
            if let existing = documents.first(where: {
                $0.fileReference?.url.standardizedFileURL == normalizedURL
            }) {
                activeDocumentID = existing.id
                await recordRecent(reference, displayName: existing.displayName)
                continue
            }
            guard openingURLs.insert(normalizedURL).inserted else { continue }
            do {
                defer { openingURLs.remove(normalizedURL) }
                let opened = try await files.open(reference)
                if let existing = documents.first(where: {
                    $0.fileReference?.url.standardizedFileURL == normalizedURL
                }) {
                    activeDocumentID = existing.id
                    await recordRecent(reference, displayName: existing.displayName)
                    continue
                }
                guard !opened.isTooLarge else {
                    throw WorkspaceMessageError.message(String(localized: "file_too_large"))
                }
                guard !opened.isBinary else {
                    throw WorkspaceMessageError.message(String(localized: "binary_file"))
                }
                guard acceptWorkspaceAddition(
                    utf16UnitCount: opened.content.utf16.count,
                    encodingRecoveryByteCount: opened.encodingRecoveryData?.count ?? 0,
                    bookmarkByteCount: reference.bookmarkData.count
                ) else { continue }
                let document = MobileDocumentSession(
                    displayName: reference.url.lastPathComponent,
                    content: opened.content,
                    encoding: opened.encoding,
                    lineEnding: opened.lineEnding,
                    persistence: MobilePersistenceState(
                        baselineRevision: opened.revision, isDirty: false
                    ),
                    fileReference: reference,
                    requiresEncodingConfirmation: opened.encodingIssue != nil,
                    encodingRecoveryData: opened.encodingRecoveryData
                )
                if opened.encodingIssue != nil {
                    document.notice = String(localized: "encoding_warning")
                }
                documents.append(document)
                activeDocumentID = document.id
                await recordRecent(reference, displayName: document.displayName)
                checkpointNow(document)
                startMonitoring(document)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func recordRecent(_ reference: MobileFileReference, displayName: String) async {
        recentFiles = (try? await recents.record(
            displayName: displayName, bookmarkData: reference.bookmarkData
        )) ?? recentFiles
    }

    private func beginBusyOperation() {
        busyOperationCount += 1
        isBusy = true
    }

    private func endBusyOperation() {
        busyOperationCount = max(0, busyOperationCount - 1)
        isBusy = busyOperationCount > 0
    }

    private func restoreWorkspace() async {
        recentFiles = await recents.records()
        let restoreReport: MobileDraftRestoreReport
        do {
            restoreReport = try await drafts.restoreReport()
        } catch {
            if alertMessage == nil { alertMessage = error.localizedDescription }
            return
        }
        var recoveryWarnings: [String] = []
        if restoreReport.unreadableFileCount > 0 {
            recoveryWarnings.append(String(
                format: String(localized: "recovery_drafts_unreadable_count"),
                restoreReport.unreadableFileCount
            ))
        }
        var capacityDeferredCount = 0
        let snapshots = restoreReport.snapshots
        for snapshot in snapshots {
            guard !documents.contains(where: { $0.id == snapshot.id }) else { continue }
            var reference: MobileFileReference?
            if let bookmark = snapshot.bookmarkData {
                reference = try? await files.resolve(bookmark)
            }
            let duplicateSource = reference.map { candidate in documents.contains(where: {
                $0.fileReference?.url.standardizedFileURL == candidate.url.standardizedFileURL
            }) } ?? false
            if duplicateSource, !snapshot.isDirty { continue }
            if duplicateSource { reference = nil }
            var content = snapshot.content
            var encoding = snapshot.encoding
            var lineEnding = snapshot.lineEnding
            var encodingRecoveryData = snapshot.encodingRecoveryData
            var requiresEncodingConfirmation = snapshot.requiresEncodingConfirmation
            var state = MobilePersistenceState(
                baselineRevision: snapshot.sourceRevision, isDirty: snapshot.isDirty
            )
            var recoveryNotice = duplicateSource
                ? String(localized: "recovered_as_local_copy") : nil
            if !duplicateSource, snapshot.isDirty,
               snapshot.bookmarkData != nil, reference == nil {
                recoveryNotice = String(localized: "provider_reopen_failed")
            }
            if !snapshot.isDirty, let reference,
               let opened = try? await files.open(reference),
               !opened.isBinary, !opened.isTooLarge {
                content = opened.content
                encoding = opened.encoding
                lineEnding = opened.lineEnding
                state = MobilePersistenceState(
                    baselineRevision: opened.revision, isDirty: false
                )
                encodingRecoveryData = opened.encodingRecoveryData
                requiresEncodingConfirmation = opened.encodingIssue != nil
            } else if !snapshot.isDirty {
                // A clean cached snapshot is only clean if the provider copy
                // was successfully reopened. Otherwise keep it as recoverable work.
                state = MobilePersistenceState(
                    baselineRevision: snapshot.sourceRevision, isDirty: true
                )
                recoveryNotice = String(localized: "provider_reopen_failed")
            }
            guard workspaceCapacityRejection(
                utf16UnitCount: content.utf16.count,
                encodingRecoveryByteCount: encodingRecoveryData?.count ?? 0,
                bookmarkByteCount: reference?.bookmarkData.count ?? 0
            ) == nil else {
                capacityDeferredCount += 1
                continue
            }
            let document = MobileDocumentSession(
                id: snapshot.id,
                displayName: duplicateSource
                    ? localCopyName(for: snapshot.displayName) : snapshot.displayName,
                content: content,
                encoding: encoding,
                lineEnding: lineEnding,
                persistence: state,
                fileReference: reference,
                requiresEncodingConfirmation: requiresEncodingConfirmation,
                encodingRecoveryData: encodingRecoveryData,
                checkpointGeneration: snapshot.checkpointGeneration ?? 0
            )
            let length = content.utf16.count
            let location = min(snapshot.selectionLocation, length)
            document.selection = NSRange(
                location: location,
                length: min(snapshot.selectionLength, length - location)
            )
            document.cursorStatus = MobileEditingCore.cursorStatus(
                in: content, selection: document.selection, knownUTF16Length: length
            )
            document.notice = recoveryNotice
            documents.append(document)
            startMonitoring(document)
            if state.isDirty, reference != nil {
                // A dirty recovery draft may have missed provider callbacks
                // while the app was terminated. Revalidate before saving.
                scheduleExternalInspection(document, delay: .zero)
            }
        }
        if activeDocumentID == nil { activeDocumentID = documents.first?.id }
        let totalDeferredCount = restoreReport.deferredFileCount + capacityDeferredCount
        if totalDeferredCount > 0 {
            recoveryWarnings.append(String(
                format: String(localized: "recovery_drafts_deferred_count"),
                totalDeferredCount
            ))
        }
        if !recoveryWarnings.isEmpty, alertMessage == nil {
            alertMessage = recoveryWarnings.joined(separator: "\n\n")
        }
    }

    private func initializeWorkspace() async {
        await files.cleanupAbandonedShareSnapshots()
        await restoreWorkspace()
        if foregroundRevalidationPending {
            foregroundRevalidationPending = false
            inspectOpenSourcesAfterActivation()
        }
        startupTask = nil
        endBusyOperation()
    }

    private func waitForStartup() async {
        let task = startupTask
        await task?.value
    }

    func preserveLocalCopyAndReload(_ document: MobileDocumentSession) {
        guard let reference = document.fileReference, !document.isSaving else { return }
        let expectedURL = reference.url.standardizedFileURL
        let localCopy = MobileDocumentSession(
            displayName: localCopyName(for: document.displayName),
            content: document.content,
            encoding: document.encoding,
            lineEnding: document.lineEnding,
            requiresEncodingConfirmation: document.requiresEncodingConfirmation,
            encodingRecoveryData: document.encodingRecoveryData
        )
        guard reserveWorkspaceAddition(
            id: localCopy.id,
            utf16UnitCount: localCopy.content.utf16.count,
            encodingRecoveryByteCount: localCopy.encodingRecoveryData?.count ?? 0,
            bookmarkByteCount: 0
        ) else { return }
        localCopy.selection = document.selection
        localCopy.cursorStatus = document.cursorStatus
        document.isSaving = true
        Task {
            defer {
                document.isSaving = false
                workspaceAdditionReservations.removeValue(forKey: localCopy.id)
            }
            do {
                try await drafts.checkpoint(localCopy.draftSnapshot())
            } catch {
                document.notice = String(localized: "local_copy_checkpoint_failed")
                return
            }
            guard documents.contains(where: { $0.id == document.id }),
                  document.fileReference?.url.standardizedFileURL == expectedURL else { return }
            workspaceAdditionReservations.removeValue(forKey: localCopy.id)
            documents.append(localCopy)
            do {
                let opened = try await files.open(reference)
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                try validateReload(opened, replacing: document)
                applyReload(opened, to: document)
            } catch {
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.notice = error.localizedDescription
            }
        }
    }

    func discardLocalChangesAndReload(_ document: MobileDocumentSession) {
        reloadFromSource(document)
    }

    func keepDeletedSourceAsDraft(_ document: MobileDocumentSession) {
        cancelExternalInspection(for: document.id)
        stopMonitoring(document)
        document.fileReference = nil
        document.persistence = MobilePersistenceState(
            baselineRevision: nil, isDirty: true
        )
        document.externalChange = nil
        document.notice = String(localized: "source_deleted_kept_as_draft")
        checkpointNow(document)
    }

    func dismissExternalChange(_ document: MobileDocumentSession) {
        document.notice = String(localized: "external_change_unresolved")
    }

    func retryExternalInspection(_ document: MobileDocumentSession) {
        document.notice = String(localized: "retrying_source")
        if let movedURL = pendingMovedURLs[document.id],
           let presenterToken = presenterTokens[document.id] {
            completePresentedItemMove(
                to: movedURL, documentID: document.id, presenterToken: presenterToken
            )
            return
        }
        scheduleExternalInspection(document, delay: .zero)
    }

    private func reloadFromSource(_ document: MobileDocumentSession) {
        guard let reference = document.fileReference, !document.isSaving else { return }
        let expectedURL = reference.url.standardizedFileURL
        cancelExternalInspection(for: document.id)
        document.isSaving = true
        Task {
            defer { document.isSaving = false }
            do {
                let opened = try await files.open(reference)
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                try validateReload(opened, replacing: document)
                applyReload(opened, to: document)
            } catch {
                guard documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.notice = error.localizedDescription
            }
        }
    }

    private func startMonitoring(_ document: MobileDocumentSession) {
        guard presenters[document.id] == nil, let url = document.fileReference?.url else { return }
        let documentID = document.id
        let presenterToken = UUID()
        let presenter = MobileFilePresenter(url: url) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePresentedItemEvent(
                    event, documentID: documentID, presenterToken: presenterToken
                )
            }
        }
        presenterTokens[document.id] = presenterToken
        presenters[document.id] = presenter
        presenter.start()
    }

    private func stopMonitoring(_ document: MobileDocumentSession) {
        cancelExternalInspection(for: document.id)
        presenterTokens.removeValue(forKey: document.id)
        pendingMovedURLs.removeValue(forKey: document.id)
        presenters.removeValue(forKey: document.id)?.stop()
    }

    private func handlePresentedItemEvent(
        _ event: MobilePresentedItemEvent,
        documentID: UUID,
        presenterToken: UUID
    ) {
        guard presenterTokens[documentID] == presenterToken else { return }
        guard let document = documents.first(where: { $0.id == documentID }) else { return }
        switch event {
        case .changed:
            guard document.externalChange != .deleted,
                  pendingMovedURLs[documentID] == nil else { return }
            scheduleExternalInspection(document)
        case .deleted:
            document.externalChange = .deleted
            document.persistence.markEdited()
            document.notice = String(localized: "source_deleted")
            checkpointNow(document)
            stopMonitoring(document)
        case let .moved(url):
            cancelExternalInspection(for: document.id)
            pendingMovedURLs[document.id] = url
            completePresentedItemMove(
                to: url, documentID: document.id, presenterToken: presenterToken
            )
        }
    }

    private func completePresentedItemMove(
        to url: URL,
        documentID: UUID,
        presenterToken: UUID
    ) {
        guard let document = documents.first(where: { $0.id == documentID }) else { return }
        let expectedURL = document.fileReference?.url.standardizedFileURL
        let movedURL = url.standardizedFileURL
        let hadContentConflict = document.externalChange == .modified
        let previousBookmark = document.fileReference?.bookmarkData
        Task {
            do {
                let reference = try await files.reference(forPickedURL: url)
                guard presenterTokens[documentID] == presenterToken,
                      documents.contains(where: { $0.id == documentID }),
                      pendingMovedURLs[documentID]?.standardizedFileURL == movedURL,
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                pendingMovedURLs.removeValue(forKey: documentID)
                document.fileReference = reference
                document.displayName = url.lastPathComponent
                if !hadContentConflict { document.externalChange = nil }
                if let previousBookmark,
                   let staleRecent = recentFiles.first(where: {
                       $0.bookmarkData == previousBookmark
                   }) {
                    recentFiles = (try? await recents.remove(id: staleRecent.id)) ?? recentFiles
                }
                await recordRecent(reference, displayName: document.displayName)
                document.notice = hadContentConflict
                    ? String(localized: "source_changed_conflict")
                    : String(localized: "source_moved")
                checkpointNow(document)
                scheduleExternalInspection(document, delay: .zero)
            } catch {
                guard presenterTokens[documentID] == presenterToken,
                      documents.contains(where: { $0.id == documentID }),
                      pendingMovedURLs[documentID]?.standardizedFileURL == movedURL,
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.externalChange = .unavailable
                document.notice = String(localized: "source_unavailable")
                checkpointNow(document)
            }
        }
    }

    private func scheduleExternalInspection(
        _ document: MobileDocumentSession,
        delay: Duration = .milliseconds(180)
    ) {
        cancelExternalInspection(for: document.id)
        let inspectionToken = UUID()
        externalInspectionTokens[document.id] = inspectionToken
        externalInspectionTasks[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let document,
                  self.externalInspectionTokens[document.id] == inspectionToken,
                  document.externalChange != .deleted,
                  let reference = document.fileReference else { return }
            let expectedURL = reference.url.standardizedFileURL
            if document.isSaving {
                self.scheduleExternalInspection(document)
                return
            }
            do {
                let opened = try await self.files.open(reference)
                guard !Task.isCancelled,
                      self.externalInspectionTokens[document.id] == inspectionToken,
                      self.documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                try self.validateReload(opened, replacing: document)
                guard opened.revision != document.persistence.baselineRevision else {
                    if document.externalChange == .unavailable {
                        document.externalChange = nil
                        document.notice = String(localized: "source_available_again")
                        self.checkpointNow(document)
                    }
                    return
                }
                if document.isDirty {
                    document.externalChange = .modified
                    document.notice = String(localized: "source_changed_conflict")
                    self.checkpointNow(document)
                } else {
                    document.content = opened.content
                    document.encoding = opened.encoding
                    document.lineEnding = opened.lineEnding
                    let length = opened.content.utf16.count
                    let location = min(document.selection.location, length)
                    document.selection = NSRange(
                        location: location,
                        length: min(document.selection.length, length - location)
                    )
                    document.cursorStatus = MobileEditingCore.cursorStatus(
                        in: opened.content,
                        selection: document.selection,
                        knownUTF16Length: length
                    )
                    document.persistence = MobilePersistenceState(
                        baselineRevision: opened.revision, isDirty: false
                    )
                    document.requiresEncodingConfirmation = opened.encodingIssue != nil
                    document.encodingRecoveryData = opened.encodingRecoveryData
                    document.externalChange = nil
                    document.notice = String(localized: "source_changed_reloaded")
                    self.checkpointNow(document)
                }
            } catch let error as WorkspaceMessageError {
                guard !Task.isCancelled,
                      self.externalInspectionTokens[document.id] == inspectionToken,
                      self.documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.externalChange = .modified
                document.notice = error.localizedDescription
                self.checkpointNow(document)
            } catch {
                guard !Task.isCancelled,
                      self.externalInspectionTokens[document.id] == inspectionToken,
                      self.documents.contains(where: { $0.id == document.id }),
                      document.fileReference?.url.standardizedFileURL == expectedURL else { return }
                document.externalChange = .unavailable
                document.notice = String(localized: "source_unavailable")
                self.checkpointNow(document)
            }
        }
    }

    private func cancelExternalInspection(for documentID: UUID) {
        externalInspectionTokens.removeValue(forKey: documentID)
        externalInspectionTasks.removeValue(forKey: documentID)?.cancel()
    }

    private func localCopyName(for displayName: String) -> String {
        let path = displayName as NSString
        let fileExtension = path.pathExtension
        let baseName = path.deletingPathExtension
        let suffix = String(localized: "local_copy_suffix")
        guard !fileExtension.isEmpty else { return displayName + suffix }
        return "\(baseName)\(suffix).\(fileExtension)"
    }

    private func validateReload(
        _ opened: MobileOpenedTextFile,
        replacing document: MobileDocumentSession
    ) throws {
        guard !opened.isTooLarge else {
            throw WorkspaceMessageError.message(String(localized: "file_too_large"))
        }
        guard !opened.isBinary else {
            throw WorkspaceMessageError.message(String(localized: "binary_file"))
        }
        guard workspaceCapacityRejection(
            replacing: document,
            utf16UnitCount: opened.content.utf16.count,
            encodingRecoveryByteCount: opened.encodingRecoveryData?.count ?? 0,
            bookmarkByteCount: document.fileReference?.bookmarkData.count ?? 0
        ) == nil else {
            throw WorkspaceMessageError.message(
                String(localized: "workspace_reload_memory_limit")
            )
        }
    }

    private func applyReload(
        _ opened: MobileOpenedTextFile,
        to document: MobileDocumentSession
    ) {
        document.content = opened.content
        document.encoding = opened.encoding
        document.lineEnding = opened.lineEnding
        document.selection = NSRange(location: 0, length: 0)
        document.cursorStatus = MobileCursorStatus(
            line: 1, column: 1, utf16Offset: 0, selectionLength: 0
        )
        document.persistence = MobilePersistenceState(
            baselineRevision: opened.revision, isDirty: false
        )
        document.requiresEncodingConfirmation = opened.encodingIssue != nil
        document.encodingRecoveryData = opened.encodingRecoveryData
        document.externalChange = nil
        document.notice = String(localized: "reloaded_from_source")
        checkpointNow(document)
    }

    private func acceptWorkspaceAddition(
        utf16UnitCount: Int,
        encodingRecoveryByteCount: Int,
        bookmarkByteCount: Int
    ) -> Bool {
        guard let rejection = workspaceCapacityRejection(
            utf16UnitCount: utf16UnitCount,
            encodingRecoveryByteCount: encodingRecoveryByteCount,
            bookmarkByteCount: bookmarkByteCount
        ) else { return true }
        presentWorkspaceCapacityRejection(rejection)
        return false
    }

    private func reserveWorkspaceAddition(
        id: UUID,
        utf16UnitCount: Int,
        encodingRecoveryByteCount: Int,
        bookmarkByteCount: Int
    ) -> Bool {
        let candidateByteCount = MobileWorkspaceCapacity.estimatedPayloadByteCount(
            utf16UnitCount: utf16UnitCount,
            encodingRecoveryByteCount: encodingRecoveryByteCount,
            bookmarkByteCount: bookmarkByteCount
        )
        guard let rejection = workspaceCapacityRejection(
            candidateByteCount: candidateByteCount
        ) else {
            workspaceAdditionReservations[id] = candidateByteCount
            return true
        }
        presentWorkspaceCapacityRejection(rejection)
        return false
    }

    private func workspaceCapacityRejection(
        utf16UnitCount: Int,
        encodingRecoveryByteCount: Int,
        bookmarkByteCount: Int
    ) -> MobileWorkspaceCapacityRejection? {
        workspaceCapacityRejection(candidateByteCount:
            MobileWorkspaceCapacity.estimatedPayloadByteCount(
                utf16UnitCount: utf16UnitCount,
                encodingRecoveryByteCount: encodingRecoveryByteCount,
                bookmarkByteCount: bookmarkByteCount
            )
        )
    }

    private func workspaceCapacityRejection(
        replacing document: MobileDocumentSession,
        utf16UnitCount: Int,
        encodingRecoveryByteCount: Int,
        bookmarkByteCount: Int
    ) -> MobileWorkspaceCapacityRejection? {
        MobileWorkspaceCapacity.replacementRejection(
            otherEstimatedByteCounts: workspaceEstimatedByteCounts(
                excludingDocumentID: document.id
            ),
            currentEstimatedByteCount: estimatedPayloadByteCount(for: document),
            replacementEstimatedByteCount: MobileWorkspaceCapacity.estimatedPayloadByteCount(
                utf16UnitCount: utf16UnitCount,
                encodingRecoveryByteCount: encodingRecoveryByteCount,
                bookmarkByteCount: bookmarkByteCount
            )
        )
    }

    private func workspaceCapacityRejection(
        candidateByteCount: Int,
        excludingDocumentID: UUID? = nil
    ) -> MobileWorkspaceCapacityRejection? {
        return MobileWorkspaceCapacity.rejection(
            existingEstimatedByteCounts: workspaceEstimatedByteCounts(
                excludingDocumentID: excludingDocumentID
            ),
            addingEstimatedByteCount: candidateByteCount
        )
    }

    private func workspaceEstimatedByteCounts(
        excludingDocumentID: UUID? = nil
    ) -> [Int] {
        var byteCounts = documents.compactMap { document -> Int? in
            guard document.id != excludingDocumentID else { return nil }
            return estimatedPayloadByteCount(for: document)
        }
        byteCounts.append(contentsOf: workspaceAdditionReservations.values)
        return byteCounts
    }

    private func estimatedPayloadByteCount(for document: MobileDocumentSession) -> Int {
        MobileWorkspaceCapacity.estimatedPayloadByteCount(
            utf16UnitCount: document.contentUTF16UnitCount,
            encodingRecoveryByteCount: document.encodingRecoveryData?.count ?? 0,
            bookmarkByteCount: document.fileReference?.bookmarkData.count ?? 0
        )
    }

    private func presentWorkspaceCapacityRejection(
        _ rejection: MobileWorkspaceCapacityRejection
    ) {
        switch rejection {
        case .documentCount:
            alertMessage = String(localized: "workspace_document_limit")
        case .estimatedMemory:
            alertMessage = String(localized: "workspace_memory_limit")
        }
    }
}

private enum WorkspaceMessageError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { value } else { nil } }
}
