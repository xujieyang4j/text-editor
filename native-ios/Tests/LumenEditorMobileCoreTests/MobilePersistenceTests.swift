import XCTest
@testable import LumenEditorMobileCore

final class MobilePersistenceTests: XCTestCase {
    func testDirtyStateOnlyClearsAfterVerifiedSave() {
        var state = MobilePersistenceState(baselineRevision: "sha256:old")
        state.markEdited()
        XCTAssertTrue(state.isDirty)
        state.retainAfterUnverifiedWrite(attemptedRevision: "sha256:attempted")
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.warning, .verificationFailed)
        XCTAssertEqual(state.baselineRevision, "sha256:attempted")
        state.acceptVerifiedSave(revision: "sha256:new")
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.warning)
        XCTAssertEqual(state.baselineRevision, "sha256:new")
    }

    func testVerifiedOlderSnapshotAdvancesBaselineButStaysDirty() {
        var state = MobilePersistenceState(baselineRevision: "sha256:old", isDirty: true)
        state.acceptVerifiedBaselineWhileDirty(revision: "sha256:installed")
        XCTAssertEqual(state.baselineRevision, "sha256:installed")
        XCTAssertTrue(state.isDirty)
        XCTAssertNil(state.warning)
    }

    func testUnverifiedSaveAsCopyDoesNotReplaceSourceBaseline() {
        var state = MobilePersistenceState(baselineRevision: "sha256:source")
        state.retainAfterUnverifiedCopy()
        XCTAssertEqual(state.baselineRevision, "sha256:source")
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.warning, .verificationFailed)
    }

    func testWorkspaceCapacityBoundsOpenDocumentCount() {
        let existing = Array(
            repeating: MobileWorkspaceCapacity.perDocumentOverheadByteCount,
            count: MobileWorkspaceCapacity.maximumDocumentCount
        )
        XCTAssertEqual(
            MobileWorkspaceCapacity.rejection(
                existingEstimatedByteCounts: existing,
                addingEstimatedByteCount: MobileWorkspaceCapacity.perDocumentOverheadByteCount
            ),
            .documentCount
        )
    }

    func testWorkspaceCapacityIncludesUTF16AndRecoveryBytes() {
        let estimated = MobileWorkspaceCapacity.estimatedPayloadByteCount(
            utf16UnitCount: 12, encodingRecoveryByteCount: 7, bookmarkByteCount: 5
        )
        XCTAssertEqual(
            estimated,
            24 + 7 + 5 + MobileWorkspaceCapacity.perDocumentOverheadByteCount
        )
        XCTAssertEqual(
            MobileWorkspaceCapacity.rejection(
                existingEstimatedByteCounts: [
                    MobileWorkspaceCapacity.maximumEstimatedPayloadByteCount
                ],
                addingEstimatedByteCount: estimated
            ),
            .estimatedMemory
        )
    }

    func testWorkspaceCapacityArithmeticCannotOverflowOpen() {
        XCTAssertEqual(
            MobileWorkspaceCapacity.rejection(
                existingEstimatedByteCounts: [Int.max],
                addingEstimatedByteCount: Int.max
            ),
            .estimatedMemory
        )
        XCTAssertEqual(
            MobileWorkspaceCapacity.estimatedPayloadByteCount(
                utf16UnitCount: Int.max, encodingRecoveryByteCount: Int.max
            ),
            Int.max
        )
    }

    func testWorkspaceCapacityComputesProspectiveUTF16LengthSafely() {
        XCTAssertEqual(
            MobileWorkspaceCapacity.utf16UnitCount(
                current: 12, replacing: 5, with: 9
            ),
            16
        )
        XCTAssertNil(MobileWorkspaceCapacity.utf16UnitCount(
            current: 4, replacing: 5, with: 0
        ))
        XCTAssertNil(MobileWorkspaceCapacity.utf16UnitCount(
            current: Int.max, replacing: 0, with: 1
        ))
    }

    func testWorkspaceCapacityAllowsShrinkingAnOverBudgetDocument() {
        XCTAssertNil(MobileWorkspaceCapacity.replacementRejection(
            otherEstimatedByteCounts: [
                MobileWorkspaceCapacity.maximumEstimatedPayloadByteCount
            ],
            currentEstimatedByteCount: 10_000,
            replacementEstimatedByteCount: 9_999
        ))
        XCTAssertEqual(MobileWorkspaceCapacity.replacementRejection(
            otherEstimatedByteCounts: [
                MobileWorkspaceCapacity.maximumEstimatedPayloadByteCount
            ],
            currentEstimatedByteCount: 10_000,
            replacementEstimatedByteCount: 10_001
        ), .estimatedMemory)
        XCTAssertEqual(
            MobileWorkspaceCapacity.maximumReplacementUTF16UnitCount(
                otherEstimatedByteCounts: [
                    MobileWorkspaceCapacity.maximumEstimatedPayloadByteCount
                ],
                currentUTF16UnitCount: 5_000
            ),
            5_000
        )
        XCTAssertEqual(
            MobileWorkspaceCapacity.maximumReplacementUTF16UnitCount(
                otherEstimatedByteCounts: [10_000],
                currentUTF16UnitCount: 20,
                encodingRecoveryByteCount: 1_000,
                bookmarkByteCount: 2_000
            ),
            (MobileWorkspaceCapacity.maximumEstimatedPayloadByteCount
                - 10_000 - 1_000 - 2_000
                - MobileWorkspaceCapacity.perDocumentOverheadByteCount) / 2
        )
        XCTAssertEqual(
            MobileWorkspaceCapacity.maximumReplacementUTF16UnitCount(
                otherEstimatedByteCounts: Array(
                    repeating: MobileWorkspaceCapacity.perDocumentOverheadByteCount,
                    count: MobileWorkspaceCapacity.maximumDocumentCount
                ),
                currentUTF16UnitCount: 123
            ),
            123
        )
    }

    func testExternalModificationFailsPreflight() {
        XCTAssertThrowsError(try MobileSavePreflight.validate(
            expectedRevision: "sha256:expected", currentRevision: "sha256:other"
        ))
    }

    func testDraftCheckpointAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileDraftStore(directory: root)
        let id = UUID()
        let snapshot = MobileDraftSnapshot(
            id: id, displayName: "恢复.swift", content: "let 😀 = 1",
            encoding: .utf8, lineEnding: .lf, bookmarkData: Data([1, 2]),
            sourceRevision: "sha256:base", isDirty: true,
            requiresEncodingConfirmation: false,
            selectionLocation: 4, selectionLength: 2, checkpointedAt: Date(timeIntervalSince1970: 12)
        )
        try await store.checkpoint(snapshot)
        let restored = try await store.restoreAll()
        XCTAssertEqual(restored, [snapshot])
        try await store.remove(id: id)
        let afterRemoval = try await store.restoreAll()
        XCTAssertEqual(afterRemoval, [])
    }

    func testDraftRestoreReportsCorruptionWithoutDeletingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let damaged = root.appendingPathComponent("damaged.json")
        try Data("{truncated".utf8).write(to: damaged)

        let store = MobileDraftStore(directory: root)
        let report = try await store.restoreReport()

        XCTAssertEqual(report.snapshots, [])
        XCTAssertEqual(report.unreadableFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
    }

    func testDraftRestoreRejectsMismatchedFileIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileDraftStore(directory: root)
        let snapshot = MobileDraftSnapshot(
            id: UUID(), displayName: "identity.txt", content: "safe",
            encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
            sourceRevision: nil, isDirty: true
        )
        try await store.checkpoint(snapshot)
        let original = root.appendingPathComponent(
            snapshot.id.uuidString.lowercased()
        ).appendingPathExtension("json")
        let mismatched = root.appendingPathComponent(
            UUID().uuidString.lowercased()
        ).appendingPathExtension("json")
        try FileManager.default.moveItem(at: original, to: mismatched)

        let report = try await store.restoreReport()
        XCTAssertEqual(report.snapshots, [])
        XCTAssertEqual(report.unreadableFileCount, 1)
    }

    func testNewerDraftGenerationWinsWhenTimestampsAreEqual() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileDraftStore(directory: root)
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 42)
        let newer = MobileDraftSnapshot(
            id: id, displayName: "generation.txt", content: "newer",
            encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
            sourceRevision: nil, isDirty: true, checkpointGeneration: 2,
            checkpointedAt: timestamp
        )
        let older = MobileDraftSnapshot(
            id: id, displayName: "generation.txt", content: "older",
            encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
            sourceRevision: nil, isDirty: true, checkpointGeneration: 1,
            checkpointedAt: timestamp
        )
        try await store.checkpoint(newer)
        try await store.checkpoint(older)
        let restored = try await store.restoreAll()
        XCTAssertEqual(restored, [newer])
    }

    func testEqualGenerationAndTimestampCannotReplaceCurrentDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileDraftStore(directory: root)
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 42)
        let current = MobileDraftSnapshot(
            id: id, displayName: "generation.txt", content: "current",
            encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
            sourceRevision: nil, isDirty: true, checkpointGeneration: 2,
            checkpointedAt: timestamp
        )
        var stale = current
        stale.content = "stale"
        try await store.checkpoint(current)
        try await store.checkpoint(stale)
        let restored = try await store.restoreAll()
        XCTAssertEqual(restored, [current])
    }

    func testEncodingRecoveryBytesRoundTripInProtectedDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileDraftStore(directory: root)
        let bytes = Data([0xff, 0x61, 0x80])
        let snapshot = MobileDraftSnapshot(
            id: UUID(), displayName: "uncertain.txt", content: "�a�",
            encoding: .utf8, lineEnding: .lf, bookmarkData: Data([1]),
            sourceRevision: "sha256:source", isDirty: false,
            requiresEncodingConfirmation: true, checkpointGeneration: 1,
            encodingRecoveryData: bytes
        )
        try await store.checkpoint(snapshot)
        let restored = try await store.restoreAll()
        XCTAssertEqual(restored.first?.encodingRecoveryData, bytes)
    }

    func testLegacyDraftWithoutNewOptionalFieldsStillRestores() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "id": id.uuidString,
            "displayName": "legacy.txt",
            "content": "legacy",
            "encoding": "utf8",
            "lineEnding": "LF",
            "sourceRevision": "sha256:legacy",
            "isDirty": true,
            "requiresEncodingConfirmation": false,
            "selectionLocation": 0,
            "selectionLength": 0,
            "checkpointedAt": 1_000
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: root.appendingPathComponent(
            id.uuidString.lowercased()
        ).appendingPathExtension("json"))

        let restored = try await MobileDraftStore(directory: root).restoreAll()
        XCTAssertEqual(restored.count, 1)
        XCTAssertNil(restored.first?.checkpointGeneration)
        XCTAssertNil(restored.first?.encodingRecoveryData)
    }

    func testRecoveryCountIsBoundedWithoutDeletingDeferredDrafts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileDraftStore(directory: root)
        for index in 0..<(MobileDraftStore.maximumRestoredCount + 2) {
            let snapshot = MobileDraftSnapshot(
                id: UUID(), displayName: "\(index).txt", content: "\(index)",
                encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
                sourceRevision: nil, isDirty: true, checkpointGeneration: 1,
                checkpointedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            try await store.checkpoint(snapshot)
            let file = root.appendingPathComponent(
                snapshot.id.uuidString.lowercased()
            ).appendingPathExtension("json")
            try FileManager.default.setAttributes(
                [.modificationDate: snapshot.checkpointedAt], ofItemAtPath: file.path
            )
        }
        let report = try await store.restoreReport()
        XCTAssertEqual(report.snapshots.count, MobileDraftStore.maximumRestoredCount)
        XCTAssertEqual(report.deferredFileCount, 2)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).count,
            MobileDraftStore.maximumRestoredCount + 2
        )
        XCTAssertFalse(report.snapshots.contains { $0.displayName == "0.txt" })
        XCTAssertFalse(report.snapshots.contains { $0.displayName == "1.txt" })
    }

    func testRecoveryPreflightDefersFilesOutsideStartupBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MobileDraftStore(directory: root)
        let snapshot = MobileDraftSnapshot(
            id: UUID(), displayName: "deferred.txt", content: "recover me",
            encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
            sourceRevision: nil, isDirty: true, checkpointGeneration: 1
        )
        try await writer.checkpoint(snapshot)

        let constrained = MobileDraftStore(
            directory: root, maximumRestoredMemoryByteCount:
                MobileWorkspaceCapacity.perDocumentOverheadByteCount
        )
        let report = try await constrained.restoreReport()
        XCTAssertEqual(report.snapshots, [])
        XCTAssertEqual(report.unreadableFileCount, 0)
        XCTAssertEqual(report.deferredFileCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    func testRecoveryBudgetAccountsForSerializedAndDecodedPayloadTogether() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MobileDraftStore(directory: root)
        let snapshot = MobileDraftSnapshot(
            id: UUID(), displayName: "combined-budget.txt",
            content: String(repeating: "a", count: 2_048),
            encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
            sourceRevision: nil, isDirty: true, checkpointGeneration: 1
        )
        try await writer.checkpoint(snapshot)
        let file = root.appendingPathComponent(
            snapshot.id.uuidString.lowercased()
        ).appendingPathExtension("json")
        let serializedByteCount = try Data(contentsOf: file).count
        let decodedByteCount = MobileWorkspaceCapacity.estimatedPayloadByteCount(
            utf16UnitCount: snapshot.content.utf16.count
        )
        let requiredCombinedBudget = serializedByteCount + decodedByteCount
        let constrained = MobileDraftStore(
            directory: root, maximumRestoredMemoryByteCount: max(
                serializedByteCount * 3,
                requiredCombinedBudget - 1
            )
        )
        let report = try await constrained.restoreReport()
        XCTAssertEqual(report.snapshots, [])
        XCTAssertEqual(report.unreadableFileCount, 0)
        XCTAssertEqual(report.deferredFileCount, 1)
    }

    func testEncodingRecoveryBytesRequireConfirmationState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileDraftStore(directory: root)
        let invalid = MobileDraftSnapshot(
            id: UUID(), displayName: "invalid.txt", content: "text",
            encoding: .utf8, lineEnding: .lf, bookmarkData: nil,
            sourceRevision: nil, isDirty: true, requiresEncodingConfirmation: false,
            encodingRecoveryData: Data([0xff])
        )
        do {
            try await store.checkpoint(invalid)
            XCTFail("Expected invalid encoding recovery data to be rejected")
        } catch {
            XCTAssertEqual(error as? MobileDraftStoreError, .invalidEncodingRecoveryData)
        }
    }

    func testRecentFilesAreBoundedAndMoveToFront() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileRecentStore(fileURL: root.appendingPathComponent("recent.json"))
        for index in 0..<(MobileRecentStore.maximumCount + 2) {
            _ = try await store.record(
                displayName: "\(index).txt", bookmarkData: Data("bookmark-\(index)".utf8),
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        var records = await store.records()
        XCTAssertEqual(records.count, MobileRecentStore.maximumCount)
        XCTAssertEqual(records.first?.displayName, "31.txt")

        _ = try await store.record(
            displayName: "renamed.txt", bookmarkData: Data("bookmark-30".utf8),
            date: Date(timeIntervalSince1970: 100)
        )
        records = await store.records()
        XCTAssertEqual(records.first?.displayName, "renamed.txt")
        XCTAssertEqual(records.count, MobileRecentStore.maximumCount)
    }

    func testInvalidRecentBookmarkDoesNotDiscardCachedRecords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileRecentStore(fileURL: root.appendingPathComponent("recent.json"))
        _ = try await store.record(
            displayName: "kept.txt", bookmarkData: Data("kept".utf8)
        )
        let records = try await store.record(displayName: "invalid.txt", bookmarkData: Data())
        XCTAssertEqual(records.map(\.displayName), ["kept.txt"])
        XCTAssertGreaterThan(
            MobileRecentStore.maximumStoreByteCount,
            MobileRecentStore.maximumCount * MobileRecentStore.maximumBookmarkByteCount
        )
    }
}
