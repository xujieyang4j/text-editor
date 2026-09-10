import Darwin
import Foundation
import XCTest
@testable import LumenEditorCore

final class WorkspaceSearchTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-workspace-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func testSearchesMultipleAuthorisedRootsWithLiteralCaseAndWholeWordOptions() async throws {
        let first = try makeRoot("first")
        let second = try makeRoot("second")
        try write("cat scatter Cat\n", to: first.appendingPathComponent("one.txt"))
        try write("CAT dog cat\n", to: second.appendingPathComponent("two.txt"))
        let (workspace, roots) = try await service(registering: [first, second])
        let search = WorkspaceSearch(workspace: workspace)

        let insensitive = try await search.search(WorkspaceSearchRequest(
            rootIDs: roots.map(\.id),
            query: "cat",
            wholeWord: true
        ))
        XCTAssertEqual(insensitive.map(\.matchText), ["cat", "Cat", "CAT", "cat"])
        XCTAssertEqual(Set(insensitive.map(\.url)), Set([
            first.appendingPathComponent("one.txt"),
            second.appendingPathComponent("two.txt")
        ]))

        let sensitive = try await search.search(WorkspaceSearchRequest(
            rootIDs: roots.map(\.id),
            query: "cat",
            caseSensitive: true,
            wholeWord: true
        ))
        XCTAssertEqual(sensitive.map(\.matchText), ["cat", "cat"])
    }

    func testRegexCapturesAndUTF16LocationsDrivePreviewAndReplacement() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("emoji.txt")
        try write("😀 alpha-12 omega\nalpha-7", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let request = WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "(alpha)-(\\d+)",
            replacement: "$2:$1:$&:$99",
            caseSensitive: true,
            useRegex: true
        )

        let preview = try await search.previewReplace(request)

        XCTAssertEqual(preview.files, 1)
        XCTAssertEqual(preview.replacements, 2)
        XCTAssertEqual(preview.matches[0].line, 1)
        XCTAssertEqual(preview.matches[0].column, 4, "emoji occupies two UTF-16 units")
        XCTAssertEqual(preview.matches[0].utf16Range, NSRange(location: 3, length: 8))
        XCTAssertEqual(preview.matches[0].lineText, "😀 alpha-12 omega")
        XCTAssertEqual(preview.matches[1].line, 2)
        XCTAssertEqual(preview.matches[1].column, 1)

        let result = try await search.apply(preview)
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(result.replacements, 2)
        XCTAssertNotNil(result.receipt)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "😀 12:alpha:alpha-12:2 omega\n7:alpha:alpha-7:9"
        )
    }

    func testIncludeAndExcludeUseCommaSeparatedCaseInsensitiveGlobSubset() async throws {
        let root = try makeRoot("root")
        let sources = root.appendingPathComponent("Sources/Nested", isDirectory: true)
        let tests = root.appendingPathComponent("Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try write("needle", to: root.appendingPathComponent("top.SWIFT"))
        try write("needle", to: sources.appendingPathComponent("keep.swift"))
        try write("needle", to: sources.appendingPathComponent("drop.tmp"))
        try write("needle", to: tests.appendingPathComponent("skip.swift"))
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)

        let matches = try await search.search(WorkspaceSearchRequest(
            rootIDs: [roots[0].id],
            query: "needle",
            include: "**/*.swift, **/*.tmp",
            exclude: "**/tests/**,**/*.tmp"
        ))

        XCTAssertEqual(
            Set(matches.map { $0.url.lastPathComponent }),
            Set(["keep.swift", "top.SWIFT"])
        )
    }

    func testProjectExclusionsProtectSearchReplaceAndTransactionScope() async throws {
        let root = try makeRoot("root")
        let included = root.appendingPathComponent("Sources/keep.txt")
        let excluded = root.appendingPathComponent("Generated/skip.txt")
        try FileManager.default.createDirectory(
            at: included.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: excluded.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try write("old", to: included)
        try write("old", to: excluded)
        let (workspace, roots) = try await service(registering: [root])
        let exclusions = ["Generated/**"]
        let search = WorkspaceSearch(workspace: workspace)
        let request = WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        )

        let found = try await search.searchResult(
            request.search, projectExclusions: exclusions
        )
        XCTAssertEqual(found.matches.map(\.url), [included])

        let preview = try await search.previewReplace(
            request, projectExclusions: exclusions
        )
        XCTAssertEqual(preview.fileURLs, [included])
        await assertSearchError(.projectExclusionsChanged) {
            try await search.apply(preview, projectExclusions: [])
        }
        XCTAssertEqual(try String(contentsOf: included, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: excluded, encoding: .utf8), "old")

        let applied = try await search.apply(preview, projectExclusions: exclusions)
        let receipt = try XCTUnwrap(applied.receipt)
        XCTAssertEqual(try String(contentsOf: included, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: excluded, encoding: .utf8), "old")
        _ = try await search.undo(receipt)
        XCTAssertEqual(try String(contentsOf: included, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: excluded, encoding: .utf8), "old")
    }

    func testSkipsBinaryAndFilesLargerThanTwoMiBIncludingLimitPlusOne() async throws {
        let root = try makeRoot("root")
        let binary = root.appendingPathComponent("binary.bin")
        let exact = root.appendingPathComponent("exact.txt")
        let oversized = root.appendingPathComponent("oversized.txt")
        try Data([0, 110, 101, 101, 100, 108, 101]).write(to: binary)
        try paddedData(prefix: "needle", count: 2 * 1_024 * 1_024).write(to: exact)
        try paddedData(prefix: "needle", count: 2 * 1_024 * 1_024 + 1).write(to: oversized)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)

        let matches = try await search.search(WorkspaceSearchRequest(
            rootIDs: [roots[0].id],
            query: "needle"
        ))

        XCTAssertEqual(matches.map { $0.url.lastPathComponent }, ["exact.txt"])
    }

    func testMaximumResultsClampsBetweenOneAndFiveThousandAndBoundsZeroWidthRegex() async throws {
        let root = try makeRoot("root")
        try write(String(repeating: "a", count: 6_100), to: root.appendingPathComponent("many.txt"))
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)

        let globalLimit = try await search.search(WorkspaceSearchRequest(
            rootIDs: [roots[0].id],
            query: "a",
            caseSensitive: true,
            maxResults: 9_000
        ))
        XCTAssertEqual(globalLimit.count, 5_000)

        let minimum = try await search.search(WorkspaceSearchRequest(
            rootIDs: [roots[0].id],
            query: "(?=a)",
            caseSensitive: true,
            useRegex: true,
            maxResults: 0
        ))
        XCTAssertEqual(minimum.count, 1)
        XCTAssertEqual(minimum[0].matchText, "")
    }

    func testRejectsEmptyAndInvalidQueriesAndTruncatesLongQueriesWithoutWriting() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("unchanged", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)

        await assertSearchError(.emptyQuery) {
            try await search.search(WorkspaceSearchRequest(rootIDs: [roots[0].id], query: ""))
        }
        let longQuery = String(repeating: "x", count: 2_000) + "ignored"
        try write(String(repeating: "x", count: 2_000), to: file)
        let truncatedQueryMatches = try await search.search(WorkspaceSearchRequest(
            rootIDs: [roots[0].id],
            query: longQuery,
            caseSensitive: true
        ))
        XCTAssertEqual(truncatedQueryMatches.count, 1)
        await assertSearchError(.invalidRegularExpression) {
            try await search.previewReplace(WorkspaceReplaceRequest(
                rootIDs: [roots[0].id],
                query: "(",
                replacement: "changed",
                useRegex: true
            ))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), String(repeating: "x", count: 2_000))
    }

    func testPreviewSkipsUncertainEncodingButOrdinarySearchMayDisplayIt() async throws {
        let root = try makeRoot("root")
        let uncertain = root.appendingPathComponent("utf16-no-bom.txt")
        let body = "needle needle needle needle"
        var data = Data()
        for unit in body.utf16 {
            data.append(UInt8(unit & 0xff))
            data.append(UInt8(unit >> 8))
        }
        try data.write(to: uncertain)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let searchRequest = WorkspaceSearchRequest(rootIDs: [roots[0].id], query: "needle")

        let displayedMatches = try await search.search(searchRequest)
        XCTAssertEqual(displayedMatches.count, 4)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            search: searchRequest,
            replacement: "found"
        ))
        XCTAssertEqual(preview.files, 0)
        XCTAssertEqual(preview.replacements, 0)
    }

    func testPreviewRevisionMismatchPreventsEveryWrite() async throws {
        let root = try makeRoot("root")
        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try write("old one", to: first)
        try write("old two", to: second)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "old",
            replacement: "new"
        ))
        try write("external two", to: second)

        await assertSearchError(.fileChanged(second)) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "old one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "external two")
    }

    func testApplyPreflightRejectsFileThatBecomesBinaryWithoutWritingEarlierFiles() async throws {
        let root = try makeRoot("root")
        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try write("old one", to: first)
        try write("old two", to: second)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "old",
            replacement: "new"
        ))

        try Data([0x00, 0x6f, 0x6c, 0x64]).write(to: second)
        await assertSearchError(.fileBecameIneligible(second)) {
            try await search.apply(preview)
        }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "old one")
    }

    func testApplyChangesOnlyPreviewedRangesAndReceiptRestoresExactBytesOnce() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("windows.txt")
        let original = Data([0xef, 0xbb, 0xbf]) + Data("old\r\nold\r\n".utf8)
        try original.write(to: file)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "old",
            replacement: "new",
            maxResults: 1
        ))

        let applied = try await search.apply(preview)
        XCTAssertEqual(applied.replacements, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data([0xef, 0xbb, 0xbf]) + Data("new\r\nold\r\n".utf8))
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
        let receipt = try XCTUnwrap(applied.receipt)

        let undone = try await search.undo(receipt)
        XCTAssertEqual(undone.files, 1)
        XCTAssertEqual(undone.replacements, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
        await assertSearchError(.receiptAlreadyUsed) {
            try await search.undo(receipt)
        }
        await assertSearchError(.previewAlreadyApplied) {
            try await search.apply(preview)
        }
    }

    func testIdenticalReplacementIsANoOpWithoutReceiptOrInodeChange() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("same.txt")
        try write("same same", to: file)
        let inodeBefore = try inode(of: file)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "same",
            replacement: "same"
        ))

        XCTAssertEqual(preview.files, 1)
        XCTAssertEqual(preview.replacements, 2)
        let result = try await search.apply(preview)

        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(result.replacements, 0)
        XCTAssertNil(result.receipt)
        XCTAssertEqual(try inode(of: file), inodeBefore)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "same same")
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testRepeatedReplacementsLeaveNoRecoveryArtifacts() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("value-0", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)

        for index in 0..<100 {
            let preview = try await search.previewReplace(WorkspaceReplaceRequest(
                rootIDs: [roots[0].id],
                query: "value-\(index)",
                replacement: "value-\(index + 1)",
                caseSensitive: true
            ))
            let result = try await search.apply(preview)
            XCTAssertEqual(result.files, 1)
            XCTAssertEqual(result.replacements, 1)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "value-100")
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testLargeSameDirectoryBatchLeavesNoRecoveryArtifacts() async throws {
        let root = try makeRoot("root")
        let fileCount = 40
        for index in 0..<fileCount {
            try write("old \(index)", to: root.appendingPathComponent("\(index).txt"))
        }
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        ))

        let result = try await search.apply(preview)

        XCTAssertEqual(result.files, fileCount)
        XCTAssertEqual(result.replacements, fileCount)
        for index in 0..<fileCount {
            XCTAssertEqual(
                try String(
                    contentsOf: root.appendingPathComponent("\(index).txt"),
                    encoding: .utf8
                ),
                "new \(index)"
            )
        }
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testCapacityFilledAfterPreflightDoesNotConsumePreview() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let injection = WorkspaceSearchCapacityInterference(root: root)
        let workspace = WorkspaceService()
        let rootRecord = try await workspace.addRoot(root)
        let search = WorkspaceSearch(
            workspace: workspace,
            afterPrepareBeforeMutationLease: nil,
            afterMutationLeaseBeforeFinalPreflight: nil,
            afterRecoveryCapacityPreflight: { kind in
                if case .apply = kind { try injection.fillOnce() }
            }
        )
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [rootRecord.id], query: "old", replacement: "new"
        ))

        await assertSearchError(.couldNotWrite(file)) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
        XCTAssertEqual(try recoveryArtifacts(in: root).count, 64)

        try injection.removeArtifacts()
        let retried = try await search.apply(preview)
        XCTAssertEqual(retried.files, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testUndoRefusesExternalChangesWithoutRestoringAnyFile() async throws {
        let root = try makeRoot("root")
        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try write("old one", to: first)
        try write("old two", to: second)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "old",
            replacement: "new"
        ))
        let applied = try await search.apply(preview)
        let receipt = try XCTUnwrap(applied.receipt)
        try write("external", to: second)

        await assertSearchError(.fileChanged(second)) {
            try await search.undo(receipt)
        }

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "new one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "external")
    }

    func testRootIDsAreCapabilitiesAndEscapingSymlinksAreNeverRead() async throws {
        let root = try makeRoot("root")
        let outside = try makeRoot("outside")
        let secret = outside.appendingPathComponent("secret.txt")
        let link = root.appendingPathComponent("escape.txt")
        try write("needle", to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)

        let matches = try await search.search(WorkspaceSearchRequest(
            rootIDs: [roots[0].id],
            query: "needle"
        ))
        XCTAssertTrue(matches.isEmpty)
        let noCapabilities = try await search.search(WorkspaceSearchRequest(query: "needle"))
        XCTAssertTrue(noCapabilities.isEmpty)

        let unknown = WorkspaceRoot.ID()
        await assertWorkspaceError(.rootNotRegistered(unknown)) {
            try await search.search(WorkspaceSearchRequest(rootIDs: [unknown], query: "needle"))
        }
    }

    func testRemovingPreviewRootRevokesApplyAndUndoCapabilities() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "old",
            replacement: "new"
        ))

        try await workspace.removeRoot(roots[0].id)
        await assertWorkspaceError(.rootNotRegistered(roots[0].id)) {
            try await search.apply(preview)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")

        let restored = try await workspace.addRoot(root)
        let secondPreview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [restored.id],
            query: "old",
            replacement: "new"
        ))
        let applied = try await search.apply(secondPreview)
        let receipt = try XCTUnwrap(applied.receipt)
        try await workspace.removeRoot(restored.id)
        await assertWorkspaceError(.rootNotRegistered(restored.id)) {
            try await search.undo(receipt)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
    }

    func testApplyRevokedAfterPrepareCannotWrite() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let gate = WorkspaceSearchRaceGate()
        let search = WorkspaceSearch(
            workspace: workspace,
            afterPrepareBeforeMutationLease: { kind in
                if case .apply = kind { await gate.pause() }
            },
            afterMutationLeaseBeforeFinalPreflight: nil
        )
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        ))

        let apply = Task { try await search.apply(preview) }
        await gate.waitUntilPaused()
        try await workspace.removeRoot(roots[0].id)
        await gate.resume()

        await assertWorkspaceError(.rootNotRegistered(roots[0].id)) {
            try await apply.value
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
    }

    func testUndoRevokedAfterPrepareCannotWrite() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let gate = WorkspaceSearchRaceGate()
        let search = WorkspaceSearch(
            workspace: workspace,
            afterPrepareBeforeMutationLease: { kind in
                if case .undo = kind { await gate.pause() }
            },
            afterMutationLeaseBeforeFinalPreflight: nil
        )
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        ))
        let receipt = try XCTUnwrap(try await search.apply(preview).receipt)

        let undo = Task { try await search.undo(receipt) }
        await gate.waitUntilPaused()
        try await workspace.removeRoot(roots[0].id)
        await gate.resume()

        await assertWorkspaceError(.rootNotRegistered(roots[0].id)) {
            try await undo.value
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
    }

    func testApplyLeaseBlocksRootReplacementCommitThroughFinalPreflight() async throws {
        let root = try makeRoot("root")
        let replacement = try makeRoot("replacement")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let transaction = try await workspace.beginRootReplacement(
            with: replacement,
            removing: [WorkspaceRootReplacementRemoval(id: roots[0].id)]
        )
        let gate = WorkspaceSearchRaceGate()
        let search = WorkspaceSearch(
            workspace: workspace,
            afterPrepareBeforeMutationLease: nil,
            afterMutationLeaseBeforeFinalPreflight: { kind in
                if case .apply = kind { await gate.pause() }
            }
        )
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        ))

        let apply = Task { try await search.apply(preview) }
        await gate.waitUntilPaused()
        await assertWorkspaceError(.rootReplacementInProgress) {
            try await workspace.finishRootReplacement(transaction, commit: true)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
        await gate.resume()
        _ = try await apply.value
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")

        try await workspace.finishRootReplacement(transaction, commit: true)
        let rootsAfterCommit = await workspace.registeredRoots()
        XCTAssertEqual(
            rootsAfterCommit.map(\.id),
            [transaction.replacement.id]
        )
    }

    func testApplyLeaseRejectsEscapingSymlinkSwappedAfterAcquisition() async throws {
        let root = try makeRoot("root")
        let outside = try makeRoot("outside")
        let inside = root.appendingPathComponent("inside.txt")
        let external = outside.appendingPathComponent("external.txt")
        try write("old", to: inside)
        try write("old", to: external)
        let (workspace, roots) = try await service(registering: [root])
        let gate = WorkspaceSearchRaceGate()
        let search = WorkspaceSearch(
            workspace: workspace,
            afterPrepareBeforeMutationLease: nil,
            afterMutationLeaseBeforeFinalPreflight: { kind in
                if case .apply = kind { await gate.pause() }
            }
        )
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        ))

        let apply = Task { try await search.apply(preview) }
        await gate.waitUntilPaused()
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: external)
        await gate.resume()

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(inside)) {
            try await apply.value
        }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "old")
    }

    func testUndoLeaseRejectsEscapingSymlinkSwappedAfterAcquisition() async throws {
        let root = try makeRoot("root")
        let outside = try makeRoot("outside")
        let inside = root.appendingPathComponent("inside.txt")
        let external = outside.appendingPathComponent("external.txt")
        try write("old", to: inside)
        try write("new", to: external)
        let (workspace, roots) = try await service(registering: [root])
        let gate = WorkspaceSearchRaceGate()
        let search = WorkspaceSearch(
            workspace: workspace,
            afterPrepareBeforeMutationLease: nil,
            afterMutationLeaseBeforeFinalPreflight: { kind in
                if case .undo = kind { await gate.pause() }
            }
        )
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        ))
        let receipt = try XCTUnwrap(try await search.apply(preview).receipt)

        let undo = Task { try await search.undo(receipt) }
        await gate.waitUntilPaused()
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: external)
        await gate.resume()

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(inside)) {
            try await undo.value
        }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "new")
    }

    func testSwapValidationPreservesExternallyReplacedTargetAndOriginalBytes() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        let external = root.appendingPathComponent("external.txt")
        try write("old", to: file)
        try write("external winner", to: external)
        let interference = WorkspaceSearchSwapInterference(
            action: .replaceTarget(with: external)
        )
        let workspace = WorkspaceService(
            afterMutationLeaseSwapBeforeValidation: { target, swappedOut in
                try interference.perform(target: target, swappedOut: swappedOut)
            }
        )
        let rootRecord = try await workspace.addRoot(root)
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [rootRecord.id], query: "old", replacement: "new"
        ))

        await assertSearchError(.rollbackFailed([file])) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external winner")
        let swappedOut = try XCTUnwrap(interference.swappedOutURL())
        XCTAssertEqual(try String(contentsOf: swappedOut, encoding: .utf8), "old")
        await assertSearchError(.previewAlreadyApplied) {
            try await search.apply(preview)
        }
    }

    func testSwapValidationPreservesExternalInPlaceContentAndOriginalBytes() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let interference = WorkspaceSearchSwapInterference(
            action: .overwriteTarget(Data("external winner".utf8))
        )
        let workspace = WorkspaceService(
            afterMutationLeaseSwapBeforeValidation: { target, swappedOut in
                try interference.perform(target: target, swappedOut: swappedOut)
            }
        )
        let rootRecord = try await workspace.addRoot(root)
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [rootRecord.id], query: "old", replacement: "new"
        ))

        await assertSearchError(.rollbackFailed([file])) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external winner")
        let swappedOut = try XCTUnwrap(interference.swappedOutURL())
        XCTAssertEqual(try String(contentsOf: swappedOut, encoding: .utf8), "old")
    }

    func testSwapValidationNeverUnlinksExternallyReplacedSwappedOutArtifact() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        let external = root.appendingPathComponent("external.txt")
        try write("old", to: file)
        try write("external artifact", to: external)
        let interference = WorkspaceSearchSwapInterference(
            action: .replaceSwappedOut(with: external)
        )
        let workspace = WorkspaceService(
            afterMutationLeaseSwapBeforeValidation: { target, swappedOut in
                try interference.perform(target: target, swappedOut: swappedOut)
            }
        )
        let rootRecord = try await workspace.addRoot(root)
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [rootRecord.id], query: "old", replacement: "new"
        ))

        await assertSearchError(.rollbackFailed([file])) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        let swappedOut = try XCTUnwrap(interference.swappedOutURL())
        XCTAssertEqual(
            try String(contentsOf: swappedOut, encoding: .utf8),
            "external artifact"
        )
        await assertSearchError(.previewAlreadyApplied) {
            try await search.apply(preview)
        }
    }

    func testOpenSwappedOutArtifactMakesCleanupFailClosed() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let interference = WorkspaceSearchSwapInterference(
            action: .openSwappedOut
        )
        let workspace = WorkspaceService(
            afterMutationLeaseSwapBeforeValidation: { target, swappedOut in
                try interference.perform(target: target, swappedOut: swappedOut)
            }
        )
        let rootRecord = try await workspace.addRoot(root)
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [rootRecord.id], query: "old", replacement: "new"
        ))

        await assertSearchError(.rollbackFailed([file])) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        let swappedOut = try XCTUnwrap(interference.swappedOutURL())
        XCTAssertEqual(try String(contentsOf: swappedOut, encoding: .utf8), "old")
        XCTAssertEqual(try interference.openedData(), Data("old".utf8))
        await assertSearchError(.previewAlreadyApplied) {
            try await search.apply(preview)
        }
    }

    func testPreopenedTargetMakesSecludedSwapFailWithoutChangingFile() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id], query: "old", replacement: "new"
        ))
        let externalDescriptor = Darwin.open(file.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(externalDescriptor, 0)
        defer { if externalDescriptor >= 0 { _ = Darwin.close(externalDescriptor) } }

        await assertSearchError(.couldNotWrite(file)) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testDirectorySyncFailureKeepsBothVersionsAndConsumesPreview() async throws {
        struct InjectedSyncFailure: Error {}

        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let workspace = WorkspaceService(
            beforeMutationLeaseDirectorySync: { _ in throw InjectedSyncFailure() }
        )
        let rootRecord = try await workspace.addRoot(root)
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [rootRecord.id], query: "old", replacement: "new"
        ))

        await assertSearchError(.rollbackFailed([file])) {
            try await search.apply(preview)
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        let artifacts = try recoveryArtifacts(in: root)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try String(contentsOf: artifacts[0], encoding: .utf8), "old")
        await assertSearchError(.previewAlreadyApplied) {
            try await search.apply(preview)
        }
    }

    func testReplacingPreviewedFileWithEscapingSymlinkCannotWriteOutsideWorkspace() async throws {
        let root = try makeRoot("root")
        let outside = try makeRoot("outside")
        let inside = root.appendingPathComponent("inside.txt")
        let external = outside.appendingPathComponent("external.txt")
        try write("old inside", to: inside)
        try write("old secret", to: external)
        let (workspace, roots) = try await service(registering: [root])
        let search = WorkspaceSearch(workspace: workspace)
        let preview = try await search.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "old",
            replacement: "new"
        ))

        // Recursive scans deliberately skip symbolic links, so create the
        // preview through the regular path and then replace that path with an
        // escaping symlink before apply.
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: external)
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(inside)) {
            try await search.apply(preview)
        }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "old secret")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: inside.path), external.path)
    }

    func testPreviewAndReceiptCannotCrossWorkspaceSearchInstances() async throws {
        let root = try makeRoot("root")
        let file = root.appendingPathComponent("file.txt")
        try write("old", to: file)
        let (workspace, roots) = try await service(registering: [root])
        let first = WorkspaceSearch(workspace: workspace)
        let second = WorkspaceSearch(workspace: workspace)
        let preview = try await first.previewReplace(WorkspaceReplaceRequest(
            rootIDs: [roots[0].id],
            query: "old",
            replacement: "new"
        ))

        await assertSearchError(.previewFromAnotherWorkspace) {
            try await second.apply(preview)
        }
        let applied = try await first.apply(preview)
        let receipt = try XCTUnwrap(applied.receipt)
        await assertSearchError(.receiptFromAnotherWorkspace) {
            try await second.undo(receipt)
        }
    }

    // MARK: - Helpers

    private func makeRoot(_ name: String) throws -> URL {
        let root = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func service(
        registering URLs: [URL]
    ) async throws -> (WorkspaceService, [WorkspaceRoot]) {
        let service = WorkspaceService()
        var roots: [WorkspaceRoot] = []
        for url in URLs { roots.append(try await service.addRoot(url)) }
        return (service, roots)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func paddedData(prefix: String, count: Int) -> Data {
        var data = Data(prefix.utf8)
        data.append(Data(repeating: 0x78, count: count - data.count))
        return data
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func recoveryArtifacts(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".lumen-replace-recovery-") }
    }

    private func assertSearchError<T>(
        _ expected: WorkspaceSearchError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as WorkspaceSearchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private func assertWorkspaceError<T>(
        _ expected: WorkspaceServiceError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as WorkspaceServiceError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private final class WorkspaceSearchCapacityInterference: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var didFill = false

    init(root: URL) {
        self.root = root
    }

    func fillOnce() throws {
        lock.lock()
        guard !didFill else {
            lock.unlock()
            return
        }
        didFill = true
        lock.unlock()

        for index in 0..<64 {
            let artifact = root.appendingPathComponent(
                ".lumen-replace-recovery-capacity-\(index)"
            )
            try Data().write(to: artifact, options: [.withoutOverwriting])
        }
    }

    func removeArtifacts() throws {
        for artifact in try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) where artifact.lastPathComponent.hasPrefix(
            ".lumen-replace-recovery-capacity-"
        ) {
            try FileManager.default.removeItem(at: artifact)
        }
    }
}

private actor WorkspaceSearchRaceGate {
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        let waiting = observers
        observers.removeAll()
        for observer in waiting { observer.resume() }
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

private final class WorkspaceSearchSwapInterference: @unchecked Sendable {
    enum Action {
        case replaceTarget(with: URL)
        case overwriteTarget(Data)
        case replaceSwappedOut(with: URL)
        case openSwappedOut
    }

    private let action: Action
    private let lock = NSLock()
    private var didRun = false
    private var recordedSwappedOutURL: URL?
    private var openedDescriptor: Int32 = -1

    init(action: Action) {
        self.action = action
    }

    deinit {
        if openedDescriptor >= 0 { _ = Darwin.close(openedDescriptor) }
    }

    func perform(target: URL, swappedOut: URL) throws {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        recordedSwappedOutURL = swappedOut
        lock.unlock()

        switch action {
        case let .replaceTarget(replacement):
            try FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: replacement, to: target)
        case let .overwriteTarget(data):
            try data.write(to: target)
        case let .replaceSwappedOut(replacement):
            try FileManager.default.removeItem(at: swappedOut)
            try FileManager.default.moveItem(at: replacement, to: swappedOut)
        case .openSwappedOut:
            let descriptor = Darwin.open(swappedOut.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            lock.lock()
            openedDescriptor = descriptor
            lock.unlock()
        }
    }

    func swappedOutURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedSwappedOutURL
    }

    func openedData() throws -> Data {
        lock.lock()
        let descriptor = openedDescriptor
        lock.unlock()
        guard descriptor >= 0, Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Data(bytes.prefix(Int(count)))
    }
}
