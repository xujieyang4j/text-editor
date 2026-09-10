import Darwin
import Foundation
import XCTest
@testable import LumenEditorCore

final class WorkspaceServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    func testAtomicRootReplacementRollsBackPartialMultiRootRemoval() async throws {
        struct InjectedFailure: Error {}

        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        let replacement = try makeTemporaryDirectory()
        let retained = first.appendingPathComponent("open.txt")
        try Data("open".utf8).write(to: retained)
        let service = WorkspaceService(
            beforeRootReplacementRemoval: { index, _ in
                if index == 1 { throw InjectedFailure() }
            }
        )
        let firstRoot = try await service.addRoot(first)
        let secondRoot = try await service.addRoot(second, makePrimary: true)
        let before = await service.registeredRoots()

        do {
            _ = try await service.replaceRoots(
                with: replacement,
                removing: [
                    WorkspaceRootReplacementRemoval(
                        id: firstRoot.id, retainingOpenFiles: [retained]
                    ),
                    WorkspaceRootReplacementRemoval(id: secondRoot.id),
                ]
            )
            XCTFail("Expected injected replacement failure")
        } catch is InjectedFailure {}

        let after = await service.registeredRoots()
        let replacementRoot = await service.root(containing: replacement)
        let retainedRoot = await service.root(containing: retained)
        XCTAssertEqual(after, before)
        XCTAssertNil(replacementRoot)
        XCTAssertNotNil(retainedRoot)
    }

    func testReplacingWithSameRootPreservesIdentityAndOnlyUpdatesPrimary() async throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        let service = WorkspaceService()
        let firstRoot = try await service.addRoot(first)
        let secondRoot = try await service.addRoot(second, makePrimary: true)

        let replacement = try await service.replaceRoots(
            with: first,
            removing: [WorkspaceRootReplacementRemoval(id: secondRoot.id)]
        )

        XCTAssertEqual(replacement.id, firstRoot.id)
        let roots = await service.registeredRoots()
        XCTAssertEqual(
            roots,
            [WorkspaceRoot(
                id: firstRoot.id, url: firstRoot.url,
                displayName: firstRoot.displayName, isPrimary: true
            )]
        )
    }

    func testRootReplacementBeginDoesNotExposeStagedStateAndDiscardKeepsLiveState() async throws {
        let first = try makeTemporaryDirectory()
        let replacement = try makeTemporaryDirectory()
        let service = WorkspaceService()
        let firstRoot = try await service.addRoot(first, makePrimary: true)

        let transaction = try await service.beginRootReplacement(
            with: replacement,
            removing: [WorkspaceRootReplacementRemoval(id: firstRoot.id)]
        )

        let rootsBeforeDiscard = await service.registeredRoots()
        let replacementBeforeDiscard = await service.root(containing: replacement)
        XCTAssertEqual(rootsBeforeDiscard, [firstRoot])
        XCTAssertNil(replacementBeforeDiscard)
        try await service.finishRootReplacement(transaction, commit: false)
        let rootsAfterDiscard = await service.registeredRoots()
        XCTAssertEqual(rootsAfterDiscard, [firstRoot])
    }

    func testRootReplacementCommitRejectsInterveningCapabilityMutation() async throws {
        let first = try makeTemporaryDirectory()
        let replacement = try makeTemporaryDirectory()
        let directContainer = try makeTemporaryDirectory()
        let directlyAuthorized = directContainer.appendingPathComponent("direct.txt")
        try Data("direct".utf8).write(to: directlyAuthorized)
        let service = WorkspaceService()
        let firstRoot = try await service.addRoot(first, makePrimary: true)
        let transaction = try await service.beginRootReplacement(
            with: replacement,
            removing: [WorkspaceRootReplacementRemoval(id: firstRoot.id)]
        )
        try await service.authorizeFile(directlyAuthorized)

        await assertWorkspaceError(.rootReplacementRollbackFailed) {
            try await service.finishRootReplacement(transaction, commit: true)
        }

        let roots = await service.registeredRoots()
        let replacementRoot = await service.root(containing: replacement)
        XCTAssertEqual(roots, [firstRoot])
        _ = try await service.openFile(directlyAuthorized)
        XCTAssertNil(replacementRoot)
    }

    func testCancelledRootReplacementCommitLeavesLiveStateUntouched() async throws {
        let first = try makeTemporaryDirectory()
        let replacement = try makeTemporaryDirectory()
        let service = WorkspaceService()
        let firstRoot = try await service.addRoot(first, makePrimary: true)
        let transaction = try await service.beginRootReplacement(
            with: replacement,
            removing: [WorkspaceRootReplacementRemoval(id: firstRoot.id)]
        )

        let commit = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            try await service.finishRootReplacement(transaction, commit: true)
        }
        do {
            try await commit.value
            XCTFail("Expected cancellation at atomic commit boundary")
        } catch is CancellationError {}

        let roots = await service.registeredRoots()
        let replacementRoot = await service.root(containing: replacement)
        XCTAssertEqual(roots, [firstRoot])
        XCTAssertNil(replacementRoot)
    }

    func testRootMutationLeaseRejectsRemovalAndReplacementCommitUntilReleased() async throws {
        let first = try makeTemporaryDirectory()
        let replacement = try makeTemporaryDirectory()
        let file = first.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: file)
        let service = WorkspaceService()
        let firstRoot = try await service.addRoot(first, makePrimary: true)
        let transaction = try await service.beginRootReplacement(
            with: replacement,
            removing: [WorkspaceRootReplacementRemoval(id: firstRoot.id)]
        )
        let lease = try await service.acquireMutationLease(for: [
            (rootID: firstRoot.id, url: file)
        ])

        await assertWorkspaceError(.rootReplacementInProgress) {
            try await service.removeRoot(firstRoot.id)
        }
        await assertWorkspaceError(.rootReplacementInProgress) {
            try await service.finishRootReplacement(transaction, commit: true)
        }
        let rootsWhileLeased = await service.registeredRoots()
        XCTAssertEqual(rootsWhileLeased, [firstRoot])

        lease.release()
        try await service.finishRootReplacement(transaction, commit: true)
        let rootsAfterCommit = await service.registeredRoots()
        XCTAssertEqual(rootsAfterCommit.map(\.id), [transaction.replacement.id])
    }

    func testCancelledMutationLeaseAcquisitionDoesNotBlockRootRemoval() async throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("file.txt")
        try Data("old".utf8).write(to: file)
        let service = WorkspaceService()
        let registered = try await service.addRoot(root)

        let acquisition = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await service.acquireMutationLease(for: [
                (rootID: registered.id, url: file)
            ])
        }
        do {
            _ = try await acquisition.value
            XCTFail("Expected cancellation before lease acquisition")
        } catch is CancellationError {}

        try await service.removeRoot(registered.id)
        let rootsAfterRemoval = await service.registeredRoots()
        XCTAssertTrue(rootsAfterRemoval.isEmpty)
    }

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testMultiRootModelChoosesMostSpecificRootAndPromotesFirstRemainingRoot() async throws {
        let container = try makeTemporaryDirectory()
        let outer = container.appendingPathComponent("outer", isDirectory: true)
        let nested = outer.appendingPathComponent("packages/app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let service = WorkspaceService()

        let outerRoot = try await service.addRoot(outer)
        let nestedRoot = try await service.addRoot(nested, makePrimary: true)

        var roots = await service.registeredRoots()
        XCTAssertEqual(roots.map(\.id), [outerRoot.id, nestedRoot.id])
        XCTAssertEqual(roots.filter(\.isPrimary).map(\.id), [nestedRoot.id])
        let mostSpecific = await service.root(
            containing: nested.appendingPathComponent("Sources/main.swift")
        )
        XCTAssertEqual(mostSpecific?.id, nestedRoot.id)

        try await service.removeRoot(nestedRoot.id)
        roots = await service.registeredRoots()
        XCTAssertEqual(roots.map(\.id), [outerRoot.id])
        XCTAssertEqual(roots.filter(\.isPrimary).map(\.id), [outerRoot.id])
        let remainingMatch = await service.root(containing: nested)
        XCTAssertEqual(remainingMatch?.id, outerRoot.id)
    }

    func testRootLimitAndDuplicateResolvedRootAreRejected() async throws {
        let container = try makeTemporaryDirectory()
        let first = container.appendingPathComponent("first", isDirectory: true)
        let second = container.appendingPathComponent("second", isDirectory: true)
        let alias = container.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)

        let duplicateService = WorkspaceService()
        _ = try await duplicateService.addRoot(first)
        await assertWorkspaceError(.rootAlreadyRegistered(alias)) {
            try await duplicateService.addRoot(alias)
        }

        let limitedService = WorkspaceService(limits: .init(maximumRoots: 1))
        _ = try await limitedService.addRoot(first)
        await assertWorkspaceError(.tooManyRoots(maximum: 1)) {
            try await limitedService.addRoot(second)
        }
    }

    func testChildrenAreImmediateSortedAndApplyBuiltInAndProjectExclusions() async throws {
        let root = try makeTemporaryDirectory()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let build = root.appendingPathComponent("build", isDirectory: true)
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
        try write("nested", to: sources.appendingPathComponent("nested.swift"))
        try write("ignored", to: build.appendingPathComponent("artifact.o"))
        try write("visible dotfile", to: root.appendingPathComponent(".env"))
        try write("a", to: root.appendingPathComponent("a.swift"))
        try write("z", to: root.appendingPathComponent("z.swift"))
        try write("temporary", to: root.appendingPathComponent("notes.TMP"))

        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let listing = try await service.children(
            of: root,
            exclusions: WorkspaceExclusionPolicy(globPatterns: ["build/**", "*.tmp"])
        )

        XCTAssertFalse(listing.isTruncated)
        XCTAssertEqual(listing.entries.first?.name, "Sources")
        XCTAssertEqual(listing.entries.first?.kind, .directory)
        XCTAssertEqual(Set(listing.entries.map(\.name)), ["Sources", ".env", "a.swift", "z.swift"])
        XCTAssertFalse(listing.entries.contains { $0.name == "nested.swift" })
        let fileNames = listing.entries.filter { !$0.isDirectory }.map(\.name)
        XCTAssertLessThan(
            try XCTUnwrap(fileNames.firstIndex(of: "a.swift")),
            try XCTUnwrap(fileNames.firstIndex(of: "z.swift"))
        )
    }

    func testDirectoryListingIsBoundedAndReportsTruncation() async throws {
        let root = try makeTemporaryDirectory()
        for index in 0..<5 {
            try write("\(index)", to: root.appendingPathComponent("file-\(index).txt"))
        }
        let service = WorkspaceService(limits: .init(maximumDirectoryEntries: 2))
        _ = try await service.addRoot(root)

        let listing = try await service.children(of: root)

        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertTrue(listing.isTruncated)
    }

    func testExactDirectoryEntryLimitIsNotReportedAsTruncated() async throws {
        let root = try makeTemporaryDirectory()
        try write("one", to: root.appendingPathComponent("one.txt"))
        try write("two", to: root.appendingPathComponent("two.txt"))
        let service = WorkspaceService(limits: .init(maximumDirectoryEntries: 2))
        _ = try await service.addRoot(root)

        let listing = try await service.children(of: root)

        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertFalse(listing.isTruncated)
    }

    func testRecursiveListingDoesNotFollowLinksAndHonoursFileAndDepthLimits() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let nested = root.appendingPathComponent("one/two", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try write("root", to: root.appendingPathComponent("root.txt"))
        try write("one", to: root.appendingPathComponent("one/one.txt"))
        try write("two", to: nested.appendingPathComponent("two.txt"))
        try write("secret", to: outside.appendingPathComponent("outside-secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        let depthService = WorkspaceService(limits: .init(
            maximumRecursiveFiles: 10,
            maximumRecursionDepth: 0
        ))
        let depthRoot = try await depthService.addRoot(root)
        let depthListing = try await depthService.recursiveFiles(in: depthRoot.id)
        XCTAssertEqual(depthListing.files.map(\.lastPathComponent), ["root.txt"])
        XCTAssertTrue(depthListing.isTruncated)

        let countService = WorkspaceService(limits: .init(maximumRecursiveFiles: 2))
        let countRoot = try await countService.addRoot(root)
        let countListing = try await countService.recursiveFiles(in: countRoot.id)
        XCTAssertEqual(countListing.files.count, 2)
        XCTAssertTrue(countListing.isTruncated)
        XCTAssertFalse(countListing.files.contains { $0.lastPathComponent == "outside-secret.txt" })
    }

    func testRecursiveEntryLimitStopsBeforeEnumeratingDescendants() async throws {
        let root = try makeTemporaryDirectory()
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try write("nested", to: child.appendingPathComponent("nested.txt"))
        let service = WorkspaceService(limits: .init(maximumRecursiveEntries: 1))
        let registered = try await service.addRoot(root)

        let listing = try await service.recursiveFiles(in: registered.id)

        XCTAssertTrue(listing.files.isEmpty)
        XCTAssertTrue(listing.isTruncated)
    }

    func testExcludedEntriesStillConsumeTheRecursiveEntryBudget() async throws {
        let root = try makeTemporaryDirectory()
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try write("hidden", to: first.appendingPathComponent("one.tmp"))
        try write("hidden", to: second.appendingPathComponent("two.tmp"))
        let service = WorkspaceService(limits: .init(maximumRecursiveEntries: 2))
        let registered = try await service.addRoot(root)

        let listing = try await service.recursiveFiles(
            in: registered.id,
            exclusions: WorkspaceExclusionPolicy(globPatterns: ["**/*.tmp"])
        )

        XCTAssertTrue(listing.files.isEmpty)
        XCTAssertTrue(listing.isTruncated)
    }

    func testOpenFileEnforcesByteLimitAndPreservesLogicalSymlinkURL() async throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        let oversized = root.appendingPathComponent("large.txt")
        try write("safe", to: target)
        try write("12345", to: oversized)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = WorkspaceService(limits: .init(maximumEditableBytes: 4))
        _ = try await service.addRoot(root)

        let linked = try await service.openFile(link)
        XCTAssertEqual(linked.url, link)
        XCTAssertEqual(linked.content, "safe")
        XCTAssertFalse(linked.isTooLarge)

        let large = try await service.openFile(oversized)
        XCTAssertEqual(large.url, oversized)
        XCTAssertEqual(large.byteLength, 5)
        XCTAssertEqual(large.content, "")
        XCTAssertTrue(large.isTooLarge)
    }

    func testEditorConfigResolutionRequiresExactRegisteredRootCapability() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let nested = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let target = nested.appendingPathComponent("main.swift")
        try write("print(1)", to: target)
        try write("[*]\nindent_size=3\nend_of_line=crlf",
                  to: root.appendingPathComponent(".editorconfig"))
        let service = WorkspaceService()
        let registered = try await service.addRoot(root)

        let resolved = try await service.resolveEditorConfig(
            for: target,
            in: registered.id
        )

        XCTAssertEqual(resolved.indentSize, .columns(3))
        XCTAssertEqual(resolved.endOfLine, .crlf)
        XCTAssertEqual(resolved.sources, [root.appendingPathComponent(".editorconfig")])

        let unknownID = WorkspaceRoot.ID()
        await assertWorkspaceError(.rootNotRegistered(unknownID)) {
            try await service.resolveEditorConfig(for: target, in: unknownID)
        }
        let outside = container.appendingPathComponent("outside.swift")
        try write("outside", to: outside)
        await assertWorkspaceError(.unauthorized(outside)) {
            try await service.resolveEditorConfig(for: outside, in: registered.id)
        }
    }

    func testEditorConfigResolutionRejectsEscapingTargetSymlink() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let secret = outside.appendingPathComponent("secret.swift")
        try write("secret", to: secret)
        let link = root.appendingPathComponent("linked.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let service = WorkspaceService()
        let registered = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(link)) {
            try await service.resolveEditorConfig(for: link, in: registered.id)
        }
    }

    func testFileAtExactByteLimitRemainsEditable() async throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("exact.txt")
        try write("1234", to: file)
        let service = WorkspaceService(limits: .init(maximumEditableBytes: 4))
        _ = try await service.addRoot(root)

        let opened = try await service.openFile(file)

        XCTAssertEqual(opened.content, "1234")
        XCTAssertFalse(opened.isTooLarge)
    }

    func testReadAndTraversalRejectSymlinksEscapingTheAuthorisedRoot() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let externalFile = outside.appendingPathComponent("secret.txt")
        let fileLink = root.appendingPathComponent("file-link.txt")
        let directoryLink = root.appendingPathComponent("directory-link", isDirectory: true)
        try write("secret", to: externalFile)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: externalFile)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)

        let rootListing = try await service.children(of: root)
        XCTAssertEqual(rootListing.entries.first { $0.name == "file-link.txt" }?.kind, .symbolicLink)
        XCTAssertEqual(rootListing.entries.first { $0.name == "directory-link" }?.kind, .symbolicLink)
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(fileLink)) {
            try await service.openFile(fileLink)
        }
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(directoryLink)) {
            try await service.children(of: directoryLink)
        }
        await assertWorkspaceError(.unauthorized(externalFile)) {
            try await service.openFile(externalFile)
        }
    }

    func testRetargetedRootSymlinkInvalidatesTheOriginalCapability() async throws {
        let container = try makeTemporaryDirectory()
        let first = container.appendingPathComponent("first", isDirectory: true)
        let second = container.appendingPathComponent("second", isDirectory: true)
        let rootLink = container.appendingPathComponent("selected-root", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try write("one", to: first.appendingPathComponent("one.txt"))
        try write("two", to: second.appendingPathComponent("two.txt"))
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: first)
        let service = WorkspaceService()
        _ = try await service.addRoot(rootLink)
        let initialListing = try await service.children(of: rootLink)
        XCTAssertEqual(initialListing.entries.map(\.name), ["one.txt"])

        try FileManager.default.removeItem(at: rootLink)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: second)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(rootLink)) {
            try await service.children(of: rootLink)
        }
    }

    func testReplacingRootDirectoryAtSamePathInvalidatesItsCapability() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try write("old", to: root.appendingPathComponent("old.txt"))
        let service = WorkspaceService()
        _ = try await service.addRoot(root)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try write("replacement", to: root.appendingPathComponent("replacement.txt"))

        await assertWorkspaceError(.rootChanged(root)) {
            try await service.children(of: root)
        }
    }

    func testDirectFileAuthorizationIsExactAndPinnedToItsResolvedTarget() async throws {
        let container = try makeTemporaryDirectory()
        let first = container.appendingPathComponent("first.txt")
        let second = container.appendingPathComponent("second.txt")
        let link = container.appendingPathComponent("selected.txt")
        try write("first", to: first)
        try write("second", to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let service = WorkspaceService()
        try await service.authorizeFile(link)

        let selected = try await service.openFile(link)
        XCTAssertEqual(selected.content, "first")
        await assertWorkspaceError(.unauthorized(second)) {
            try await service.openFile(second)
        }

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(link)) {
            try await service.openFile(link)
        }
    }

    func testDirectFileAuthorizationRejectsAReplacementAtTheSamePath() async throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("selected.txt")
        try write("first", to: file)
        let service = WorkspaceService()
        try await service.authorizeFile(file)

        try FileManager.default.removeItem(at: file)
        try write("replacement", to: file)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(file)) {
            try await service.openFile(file)
        }
    }

    func testDirectGrantDescriptorIdentityMatchesTheAuthorisedInode() async throws {
        let root = try makeTemporaryDirectory()
        let selected = root.appendingPathComponent("selected.txt")
        let replacement = root.appendingPathComponent("replacement.txt")
        try write("authorised", to: selected)
        try write("replacement", to: replacement)
        let service = WorkspaceService()
        try await service.authorizeFile(selected)

        try FileManager.default.removeItem(at: selected)
        try FileManager.default.moveItem(at: replacement, to: selected)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(selected)) {
            try await service.openFile(selected)
        }
    }

    func testWorkspaceOpenRejectsFinalSymlinkRetargetedOutsideRoot() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let inside = root.appendingPathComponent("inside.txt")
        let secret = outside.appendingPathComponent("secret.txt")
        let link = root.appendingPathComponent("link.txt")
        try write("inside", to: inside)
        try write("secret", to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let initiallyOpened = try await service.openFile(link)
        XCTAssertEqual(initiallyOpened.content, "inside")

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(link)) {
            try await service.openFile(link)
        }
    }

    func testWorkspaceFileSwapBetweenAuthorizationAndDescriptorOpenIsRejected() async throws {
        let root = try makeTemporaryDirectory()
        let selected = root.appendingPathComponent("selected.txt")
        let replacement = root.appendingPathComponent("replacement.txt")
        try write("authorised", to: selected)
        try write("replacement", to: replacement)
        let swap = OneShotFileSwap(source: selected, replacement: replacement)
        let service = WorkspaceService(beforeOpeningFileDescriptor: { _ in
            try swap.perform()
        })
        _ = try await service.addRoot(root)

        do {
            _ = try await service.openFile(selected)
            XCTFail("Expected the swapped inode to be rejected")
        } catch {
            XCTAssertEqual(error as? TextFileCodecError, .fileChangedDuringOpen)
        }
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "replacement")
    }

    func testAllowedSymlinkTargetSwapCannotEscapeBeforeDescriptorOpen() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let inside = root.appendingPathComponent("inside.txt")
        let logicalLink = root.appendingPathComponent("selected.txt")
        let secret = outside.appendingPathComponent("secret.txt")
        try write("inside", to: inside)
        try write("secret", to: secret)
        try FileManager.default.createSymbolicLink(at: logicalLink, withDestinationURL: inside)
        let retarget = OneShotSymlinkRetarget(link: inside, destination: secret)
        let service = WorkspaceService(beforeOpeningFileDescriptor: { _ in
            try retarget.perform()
        })
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(logicalLink)) {
            try await service.openFile(logicalLink)
        }
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "secret")
    }

    func testDirectGrantSwapBetweenAuthorizationAndDescriptorOpenIsRejected() async throws {
        let root = try makeTemporaryDirectory()
        let selected = root.appendingPathComponent("selected.txt")
        let replacement = root.appendingPathComponent("replacement.txt")
        try write("authorised", to: selected)
        try write("replacement", to: replacement)
        let swap = OneShotFileSwap(source: selected, replacement: replacement)
        let service = WorkspaceService(beforeOpeningFileDescriptor: { _ in
            try swap.perform()
        })
        try await service.authorizeFile(selected)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(selected)) {
            try await service.openFile(selected)
        }
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "replacement")
    }

    func testRemovingRootRevokesDescendantsButCanRetainExactOpenFiles() async throws {
        let root = try makeTemporaryDirectory()
        let retained = root.appendingPathComponent("retained.txt")
        let revoked = root.appendingPathComponent("revoked.txt")
        try write("keep", to: retained)
        try write("drop", to: revoked)
        let service = WorkspaceService()
        let registered = try await service.addRoot(root)

        try await service.removeRoot(registered.id, retainingOpenFiles: [retained])

        let retainedFile = try await service.openFile(retained)
        XCTAssertEqual(retainedFile.content, "keep")
        await assertWorkspaceError(.unauthorized(revoked)) {
            try await service.openFile(revoked)
        }
        await assertWorkspaceError(.unauthorized(root)) {
            try await service.children(of: root)
        }
    }

    func testRetainedAndDirectFileAuthorizationsAreBounded() async throws {
        let root = try makeTemporaryDirectory()
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try write("first", to: first)
        try write("second", to: second)
        let retainService = WorkspaceService(limits: .init(maximumRetainedFiles: 0))
        let registered = try await retainService.addRoot(root)
        await assertWorkspaceError(.tooManyRetainedFiles(maximum: 0)) {
            try await retainService.removeRoot(registered.id, retainingOpenFiles: [first])
        }

        let directoryRetainService = WorkspaceService()
        let directoryRoot = try await directoryRetainService.addRoot(root)
        await assertWorkspaceError(.notAFile(root)) {
            try await directoryRetainService.removeRoot(
                directoryRoot.id,
                retainingOpenFiles: [root]
            )
        }
        let rootsAfterRejectedRemoval = await directoryRetainService.registeredRoots()
        XCTAssertEqual(rootsAfterRejectedRemoval.count, 1)

        let directService = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 1))
        try await directService.authorizeFile(first)
        await assertWorkspaceError(.tooManyDirectFileAuthorizations(maximum: 1)) {
            try await directService.authorizeFile(second)
        }
    }

    func testRetainedFilesCannotBypassCumulativeDirectGrantLimit() async throws {
        let firstRoot = try makeTemporaryDirectory()
        let secondRoot = try makeTemporaryDirectory()
        let first = firstRoot.appendingPathComponent("first.txt")
        let second = secondRoot.appendingPathComponent("second.txt")
        try write("first", to: first)
        try write("second", to: second)
        let service = WorkspaceService(
            limits: .init(maximumDirectFileAuthorizations: 1)
        )
        let firstRegistration = try await service.addRoot(firstRoot)
        let secondRegistration = try await service.addRoot(secondRoot)

        try await service.removeRoot(
            firstRegistration.id,
            retainingOpenFiles: [first]
        )
        await assertWorkspaceError(.tooManyDirectFileAuthorizations(maximum: 1)) {
            try await service.removeRoot(
                secondRegistration.id,
                retainingOpenFiles: [second]
            )
        }

        let retainedFirst = try await service.openFile(first)
        let stillRootAuthorisedSecond = try await service.openFile(second)
        XCTAssertEqual(retainedFirst.content, "first")
        XCTAssertEqual(stillRootAuthorisedSecond.content, "second")
    }

    func testDirectFileGrantCannotBeUsedAsACreateParent() async throws {
        let root = try makeTemporaryDirectory()
        let selected = root.appendingPathComponent("selected.txt")
        try write("selected", to: selected)
        let service = WorkspaceService()
        try await service.authorizeFile(selected)

        await assertWorkspaceError(.unauthorized(selected)) {
            try await service.createFile(in: selected, named: "child.txt")
        }
    }

    func testCreateRenameAndMoveNeverOverwriteExistingItems() async throws {
        let root = try makeTemporaryDirectory()
        let service = WorkspaceService()
        _ = try await service.addRoot(root)

        let destination = try await service.createDirectory(in: root, named: "destination")
        let created = try await service.createFile(in: root, named: "draft.txt")
        XCTAssertEqual(created.kind, .file)
        XCTAssertEqual(try Data(contentsOf: created.url), Data())
        await assertWorkspaceError(.itemAlreadyExists(created.url)) {
            try await service.createFile(in: root, named: "draft.txt")
        }
        await assertWorkspaceError(.invalidName("../escape")) {
            try await service.createFile(in: root, named: "../escape")
        }
        let missing = root.appendingPathComponent("missing.txt")
        await assertWorkspaceError(.itemNotFound(missing)) {
            try await service.rename(missing, toName: "unexpected.txt")
        }

        let renamed = try await service.rename(created.url, toName: "renamed.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        let moved = try await service.move(renamed, toDirectory: destination.url)
        XCTAssertEqual(moved, destination.url.appendingPathComponent("renamed.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))

        let sourceCollision = root.appendingPathComponent("collision.txt")
        let targetCollision = destination.url.appendingPathComponent("collision.txt")
        try write("source", to: sourceCollision)
        try write("target", to: targetCollision)
        await assertWorkspaceError(.itemAlreadyExists(targetCollision)) {
            try await service.move(sourceCollision, toDirectory: destination.url)
        }
        XCTAssertEqual(try String(contentsOf: sourceCollision, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: targetCollision, encoding: .utf8), "target")
    }

    func testCreateFileRejectsParentReplacedByEscapingSymlinkBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let swap = OneShotDirectorySymlinkSwap(directory: parent, destination: outside)
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(parent)) {
            try await service.createFile(in: parent, named: "escaped.txt")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("escaped.txt").path
        ))
    }

    func testCreateDirectoryRejectsParentReplacedByEscapingSymlinkBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let swap = OneShotDirectorySymlinkSwap(directory: parent, destination: outside)
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(parent)) {
            try await service.createDirectory(in: parent, named: "escaped")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("escaped").path
        ))
    }

    func testCreateRejectsRootReplacementBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let replacement = OneShotDirectoryReplacement(directory: root)
        let service = WorkspaceService(beforeMutation: { _ in try replacement.perform() })
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.rootChanged(root)) {
            try await service.createFile(in: root, named: "new.txt")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("new.txt").path
        ))
    }

    func testRenameRejectsSourceParentSymlinkSwapBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let source = parent.appendingPathComponent("source.txt")
        let outsideSource = outside.appendingPathComponent("source.txt")
        try write("inside", to: source)
        try write("outside", to: outsideSource)
        let swap = OneShotDirectorySymlinkSwap(directory: parent, destination: outside)
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(parent)) {
            try await service.rename(source, toName: "renamed.txt")
        }
        XCTAssertEqual(try String(contentsOf: outsideSource, encoding: .utf8), "outside")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("renamed.txt").path
        ))
    }

    func testRenameRejectsSourceEntrySwapBeforeMutation() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let replacement = root.appendingPathComponent("replacement.txt")
        try write("authorised", to: source)
        try write("replacement", to: replacement)
        let swap = OneShotFileSwap(source: source, replacement: replacement)
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(source)) {
            try await service.rename(source, toName: "renamed.txt")
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("renamed.txt").path
        ))
    }

    func testMoveRejectsDestinationParentSymlinkSwapBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        try write("inside", to: source)
        let swap = OneShotDirectorySymlinkSwap(directory: destination, destination: outside)
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(destination)) {
            try await service.move(source, toDirectory: destination)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("source.txt").path
        ))
    }

    func testDirectMoveAuthorizationRejectsDestinationReplacementBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        try write("inside", to: source)
        let swap = OneShotDirectorySymlinkSwap(
            directory: destination, destination: outside
        )
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(destination)) {
            try await service.move(source, using: authorization)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("source.txt").path
        ))
    }

    func testDirectMoveAuthorizationRejectsDestinationSymlinkAtCreation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let link = container.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(link)) {
            try await service.authorizeMoveDestination(userSelectedDirectory: link)
        }
    }

    func testDirectMoveAuthorizationRejectsDestinationInodeReplacementBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        try write("inside", to: source)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(destination)) {
            try await service.move(source, using: authorization)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("source.txt").path
        ))
    }

    func testMoveDestinationAuthorizationKeepsVerifiedIdentityIfPathChangesBeforeReturn() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        try write("source", to: source)
        let replacement = OneShotDirectoryReplacement(directory: destination)
        let service = WorkspaceService(
            beforeMoveDestinationAuthorization: { _ in try replacement.perform() }
        )
        _ = try await service.addRoot(root)

        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(destination)) {
            try await service.move(source, using: authorization)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRootContainedLogicalDestinationThatResolvesOutsideReceivesDirectGrant() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        let actualDestination = outside.appendingPathComponent("destination", isDirectory: true)
        let linkedDestination = link.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: actualDestination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside
        )
        let source = root.appendingPathComponent("source.txt")
        try write("source", to: source)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: linkedDestination
        )

        let moved = try await service.move(source, using: authorization)
        let opened = try await service.openFile(moved)

        XCTAssertEqual(opened.content, "source")
    }

    func testExternalMoveRejectsEscapingAndDanglingSymlinksBeforeDiskMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let secret = container.appendingPathComponent("secret.txt")
        let escaping = root.appendingPathComponent("escaping.txt")
        let dangling = root.appendingPathComponent("dangling.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("secret", to: secret)
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: container.appendingPathComponent("missing.txt")
        )
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.externalSpecialItemMoveUnsupported) {
            try await service.move(escaping, using: authorization)
        }
        await assertWorkspaceError(.externalSpecialItemMoveUnsupported) {
            try await service.move(dangling, using: authorization)
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: escaping.path),
            secret.path
        )
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dangling.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("escaping.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("dangling.txt").path
        ))
    }

    func testExternalDirectoryMoveRejectsSourceParentAndEntrySwapBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let source = parent.appendingPathComponent("folder", isDirectory: true)
        let replacement = parent.appendingPathComponent("replacement", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("authorised", to: source.appendingPathComponent("value.txt"))
        try write("replacement", to: replacement.appendingPathComponent("value.txt"))
        let swap = OneShotFileSwap(source: source, replacement: replacement)
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(source)) {
            try await service.move(source, using: authorization)
        }
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("value.txt"), encoding: .utf8),
            "replacement"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("folder").path
        ))
    }

    func testExternalDirectoryMoveRejectsSourceParentSymlinkSwapBeforeMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let outsideSource = container.appendingPathComponent("outside-source", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = parent.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outsideSource.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let swap = OneShotDirectorySymlinkSwap(
            directory: parent, destination: outsideSource
        )
        let service = WorkspaceService(beforeMutation: { _ in try swap.perform() })
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(parent)) {
            try await service.move(source, using: authorization)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outsideSource.appendingPathComponent("folder").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("folder").path
        ))
    }

    func testMoveRejectsUnauthorizedDestinationDescendantAndRegisteredRootMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.unauthorized(outside)) {
            try await service.move(parent, toDirectory: outside)
        }
        await assertWorkspaceError(.moveIntoDescendant) {
            try await service.move(parent, toDirectory: child)
        }
        await assertWorkspaceError(.cannotMutateWorkspaceRoot(root)) {
            try await service.rename(root, toName: "renamed-root")
        }
    }

    func testUserSelectedDirectoryAuthorizationMovesOutsideWorkspaceWithoutGrantingDirectory() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("move-me.txt")
        try write("moved", to: source)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        let moved = try await service.move(source, using: authorization)

        XCTAssertEqual(moved, destination.appendingPathComponent("move-me.txt"))
        let opened = try await service.openFile(moved)
        XCTAssertEqual(opened.content, "moved")
        await assertWorkspaceError(.unauthorized(destination)) {
            try await service.children(of: destination)
        }
    }

    func testMovedExternalFileReplacementCannotBeRenamedMovedOrTrashed() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let secondDestination = container.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondDestination, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("move-me.txt")
        try write("original", to: source)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )
        let moved = try await service.move(source, using: authorization)
        let secondAuthorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: secondDestination
        )
        try FileManager.default.removeItem(at: moved)
        try write("replacement", to: moved)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(moved)) {
            try await service.rename(moved, toName: "renamed.txt")
        }
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(moved)) {
            try await service.move(moved, using: secondAuthorization)
        }
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(moved)) {
            try await service.moveToTrash(moved)
        }

        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: secondDestination.appendingPathComponent("move-me.txt").path
        ))
    }

    func testMovedExternalDirectoryCapabilityRejectsTrashWithoutCallingHandler() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let trash = CountingTrashHandler()
        let service = WorkspaceService(trashHandler: trash)
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )
        let moved = try await service.move(source, using: authorization)

        await assertWorkspaceError(.directDirectoryTrashUnsupported) {
            try await service.moveToTrash(moved)
        }

        XCTAssertEqual(trash.callCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testMovedExternalDirectoryDescendantRejectsTrashWithoutCallingHandler() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let child = source.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("child", to: child)
        let trash = CountingTrashHandler()
        let service = WorkspaceService(trashHandler: trash)
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )
        let moved = try await service.move(source, using: authorization)
        let movedChild = moved.appendingPathComponent("child.txt")

        await assertWorkspaceError(.directDirectoryTrashUnsupported) {
            try await service.moveToTrash(movedChild)
        }

        XCTAssertEqual(trash.callCount, 0)
        XCTAssertEqual(try String(contentsOf: movedChild, encoding: .utf8), "child")
    }

    func testExternalMoveReservesDirectGrantCapacityBeforeChangingDisk() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let alreadyGranted = container.appendingPathComponent("already-granted.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("grant", to: alreadyGranted)
        let source = root.appendingPathComponent("stay.txt")
        try write("stay", to: source)
        let service = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 1))
        _ = try await service.addRoot(root)
        try await service.authorizeFile(alreadyGranted)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.tooManyDirectFileAuthorizations(maximum: 1)) {
            try await service.move(source, using: authorization)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("stay.txt").path
        ))
    }

    func testExternalDirectoryMoveReservesDirectGrantCapacityBeforeChangingDisk() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let alreadyGranted = container.appendingPathComponent("already-granted.txt")
        let source = root.appendingPathComponent("stay", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("grant", to: alreadyGranted)
        let service = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 1))
        _ = try await service.addRoot(root)
        try await service.authorizeFile(alreadyGranted)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.tooManyDirectFileAuthorizations(maximum: 1)) {
            try await service.move(source, using: authorization)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("stay").path
        ))
    }

    func testExternalDirectoryMoveCollapsesDescendantGrantWithinCapacity() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let child = source.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("child", to: child)
        let service = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 1))
        _ = try await service.addRoot(root)
        try await service.authorizeFile(child)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        let moved = try await service.move(source, using: authorization)
        let opened = try await service.openFile(moved.appendingPathComponent("child.txt"))
        let extra = container.appendingPathComponent("extra.txt")
        try write("extra", to: extra)

        await assertWorkspaceError(.tooManyDirectFileAuthorizations(maximum: 1)) {
            try await service.authorizeFile(extra)
        }

        XCTAssertEqual(opened.content, "child")
    }

    func testExternalDirectoryMovePreservesAuthorizedDescendantSymlinkGrant() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let secret = container.appendingPathComponent("secret.txt")
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("secret", to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let service = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 2))
        _ = try await service.addRoot(root)
        try await service.authorizeFile(link)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        let moved = try await service.move(source, using: authorization)
        let movedLink = moved.appendingPathComponent("link.txt")

        let movedFile = try await service.openFile(movedLink)
        XCTAssertEqual(movedFile.content, "secret")
        await assertWorkspaceError(.unauthorized(link)) {
            try await service.openFile(link)
        }
        let extra = container.appendingPathComponent("extra.txt")
        try write("extra", to: extra)
        await assertWorkspaceError(.tooManyDirectFileAuthorizations(maximum: 2)) {
            try await service.authorizeFile(extra)
        }
    }

    func testExternalDirectoryMoveCountsPreservedSymlinkBeforeDiskMutation() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let secret = container.appendingPathComponent("secret.txt")
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("secret", to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let service = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 1))
        _ = try await service.addRoot(root)
        try await service.authorizeFile(link)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.tooManyDirectFileAuthorizations(maximum: 1)) {
            try await service.move(source, using: authorization)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("folder").path
        ))
        let retainedFile = try await service.openFile(link)
        XCTAssertEqual(retainedFile.content, "secret")
    }

    func testDirectGrantSourceCanMoveExternallyTwiceWithoutLeakingOldPath() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let first = container.appendingPathComponent("first", isDirectory: true)
        let second = container.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("value.txt")
        try write("value", to: source)
        let service = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 1))
        _ = try await service.addRoot(root)
        let firstAuthorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: first
        )
        let firstMoved = try await service.move(source, using: firstAuthorization)
        let secondAuthorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: second
        )

        let secondMoved = try await service.move(firstMoved, using: secondAuthorization)

        let reopened = try await service.openFile(secondMoved)
        XCTAssertEqual(reopened.content, "value")
        await assertWorkspaceError(.unauthorized(firstMoved)) {
            try await service.openFile(firstMoved)
        }
    }

    func testUserSelectedDirectoryAuthorizationMovesDirectoryOutsideWorkspace() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        let child = nested.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("nested", to: child)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        let moved = try await service.move(source, using: authorization)
        let movedChild = moved.appendingPathComponent("Nested/child.txt")

        XCTAssertEqual(moved, destination.appendingPathComponent("folder"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: movedChild, encoding: .utf8), "nested")
        let movedListing = try await service.children(of: moved)
        let reopenedChild = try await service.openFile(movedChild)
        let created = try await service.createFile(in: moved, named: "created.txt")
        XCTAssertEqual(movedListing.entries.map(\.name), ["Nested"])
        XCTAssertEqual(reopenedChild.content, "nested")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.url.path))
        await assertWorkspaceError(.unauthorized(destination)) {
            try await service.children(of: destination)
        }
    }

    func testSuccessfulExternalDirectoryMoveCommitsProjectedNestedGrantPath() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        let selected = nested.appendingPathComponent("selected.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("selected", to: selected)
        let service = WorkspaceService(limits: .init(maximumDirectFileAuthorizations: 1))
        _ = try await service.addRoot(root)
        try await service.authorizeFile(selected)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        let moved = try await service.move(source, using: authorization)
        let movedSelected = moved.appendingPathComponent("Nested/selected.txt")

        let reopened = try await service.openFile(movedSelected)
        XCTAssertEqual(reopened.content, "selected")
        await assertWorkspaceError(.unauthorized(selected)) {
            try await service.openFile(selected)
        }
    }

    func testMovedExternalDirectoryGrantRejectsReplacementAndEscapingDescendantSymlink() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let secret = container.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("secret", to: secret)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )
        let moved = try await service.move(source, using: authorization)
        let link = moved.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(link)) {
            try await service.openFile(link)
        }

        try FileManager.default.removeItem(at: moved)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(moved)) {
            try await service.children(of: moved)
        }
    }

    func testMovedExternalDirectoryEnumerationUsesPinnedDescriptorAfterPathReplacement() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("safe", to: source.appendingPathComponent("safe.txt"))
        let swap = DeferredDirectoryReplacement()
        let service = WorkspaceService(beforeOpeningFileDescriptor: { url in
            try swap.perform(on: url)
        })
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )
        let moved = try await service.move(source, using: authorization)

        let listing = try await service.children(of: moved)

        XCTAssertEqual(listing.entries.map(\.name), ["safe.txt"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("replacement.txt").path
        ))
    }

    func testExactChildGrantDoesNotGoStaleAcrossRenameAndMoveUnderDirectoryGrant() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let firstDestination = container.appendingPathComponent("first", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let child = source.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstDestination, withIntermediateDirectories: false)
        try write("child", to: child)
        let service = WorkspaceService()
        _ = try await service.addRoot(root)
        try await service.authorizeFile(child)
        let firstAuthorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: firstDestination
        )
        let moved = try await service.move(source, using: firstAuthorization)
        let movedChild = moved.appendingPathComponent("child.txt")
        let renamed = try await service.rename(movedChild, toName: "renamed.txt")
        let nested = try await service.createDirectory(in: moved, named: "Nested")

        let movedAgain = try await service.move(renamed, toDirectory: nested.url)
        let reopened = try await service.openFile(movedAgain)

        XCTAssertEqual(renamed.lastPathComponent, "renamed.txt")
        XCTAssertEqual(movedAgain, nested.url.appendingPathComponent("renamed.txt"))
        XCTAssertEqual(reopened.content, "child")
    }

    func testCrossVolumeExternalDirectoryMoveLeavesSourceIntact() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let child = source.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("keep", to: child)
        let service = WorkspaceService(moveItemFailure: { _, _, _, _ in EXDEV })
        _ = try await service.addRoot(root)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )

        await assertWorkspaceError(.crossVolumeMoveUnsupported) {
            try await service.move(source, using: authorization)
        }

        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("folder").path
        ))
    }

    func testRollbackFailureReportsCommittedRenameAndMigratesGrant() async throws {
        let container = try makeTemporaryDirectory()
        let selected = container.appendingPathComponent("selected.txt")
        let target = container.appendingPathComponent("renamed.txt")
        try write("value", to: selected)
        let service = WorkspaceService(
            afterMoveBeforeValidation: { _ in throw CocoaError(.fileReadUnknown) },
            rollbackMoveFailure: { _, _, _, _ in EIO }
        )
        _ = try await service.addRoot(container)

        await assertWorkspaceError(.moveRollbackFailed(
            source: selected, target: target, rollbackErrno: EIO,
            outcome: .committedAtTarget
        )) {
            try await service.rename(selected, toName: target.lastPathComponent)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let reopened = try await service.openFile(target)
        XCTAssertEqual(reopened.content, "value")
    }

    func testRollbackFailureReportsCommittedExternalMoveAndCommitsProjectedGrants() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let destination = container.appendingPathComponent("destination", isDirectory: true)
        let source = root.appendingPathComponent("folder", isDirectory: true)
        let secret = container.appendingPathComponent("secret.txt")
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try write("secret", to: secret)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let service = WorkspaceService(
            limits: .init(maximumDirectFileAuthorizations: 2),
            afterMoveBeforeValidation: { _ in throw CocoaError(.fileReadUnknown) },
            rollbackMoveFailure: { _, _, _, _ in EIO }
        )
        _ = try await service.addRoot(root)
        try await service.authorizeFile(link)
        let authorization = try await service.authorizeMoveDestination(
            userSelectedDirectory: destination
        )
        let moved = destination.appendingPathComponent("folder", isDirectory: true)
        let movedLink = moved.appendingPathComponent("link.txt")

        await assertWorkspaceError(.moveRollbackFailed(
            source: source, target: moved, rollbackErrno: EIO,
            outcome: .committedAtTarget
        )) {
            try await service.move(source, using: authorization)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let reopened = try await service.openFile(movedLink)
        XCTAssertEqual(reopened.content, "secret")
        await assertWorkspaceError(.unauthorized(link)) {
            try await service.openFile(link)
        }
    }

    func testUnknownRollbackIdentityObservationIsIndeterminate() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("target.txt")
        try write("value", to: source)
        let service = WorkspaceService(
            afterMoveBeforeValidation: { _ in throw CocoaError(.fileReadUnknown) },
            rollbackMoveFailure: { _, _, _, _ in EIO },
            rollbackIdentityObservationFailure: { url in
                url.path == source.path ? EACCES : nil
            }
        )
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.moveRollbackFailed(
            source: source, target: target, rollbackErrno: EIO,
            outcome: .indeterminate
        )) {
            try await service.rename(source, toName: target.lastPathComponent)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testUnknownIdentitySuppliesDiagnosticErrnoAfterSuccessfulRollback() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("target.txt")
        try write("value", to: source)
        let service = WorkspaceService(
            afterMoveBeforeValidation: { _ in throw CocoaError(.fileReadUnknown) },
            rollbackMoveFailure: { sourceDirectory, sourceName, destinationDirectory,
                                   destinationName in
                sourceName.withCString { sourceComponent in
                    destinationName.withCString { destinationComponent in
                        Darwin.renameatx_np(
                            sourceDirectory, sourceComponent, destinationDirectory,
                            destinationComponent, UInt32(RENAME_EXCL)
                        )
                    }
                } == 0 ? 0 : errno
            },
            rollbackIdentityObservationFailure: { url in
                url.path == source.path ? EACCES : nil
            }
        )
        _ = try await service.addRoot(root)

        await assertWorkspaceError(.moveRollbackFailed(
            source: source, target: target, rollbackErrno: EACCES,
            outcome: .indeterminate
        )) {
            try await service.rename(source, toName: target.lastPathComponent)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testTrashUsesInjectedRecoverableHandlerAndEscapingLinkOperationsDoNotTouchTarget() async throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let testTrash = container.appendingPathComponent("test-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: testTrash, withIntermediateDirectories: false)
        let target = outside.appendingPathComponent("keep.txt")
        let originalLink = root.appendingPathComponent("external-link.txt")
        try write("keep me", to: target)
        try FileManager.default.createSymbolicLink(at: originalLink, withDestinationURL: target)
        let trash = RecordingTrashHandler(destinationDirectory: testTrash)
        let service = WorkspaceService(trashHandler: trash)
        _ = try await service.addRoot(root)

        let renamedLink = try await service.rename(originalLink, toName: "renamed-link.txt")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep me")
        await assertWorkspaceError(.symbolicLinkEscapesWorkspace(renamedLink)) {
            try await service.openFile(renamedLink)
        }

        try await service.moveToTrash(renamedLink)

        XCTAssertEqual(trash.recordedURLs(), [renamedLink])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: renamedLink.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep me")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: testTrash.path).count, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: nil
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: [.withoutOverwriting])
    }

    private func assertWorkspaceError<T>(
        _ expected: WorkspaceServiceError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WorkspaceServiceError, expected, file: file, line: line)
        }
    }
}

private final class RecordingTrashHandler: WorkspaceTrashHandling, @unchecked Sendable {
    private let destinationDirectory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var urls: [URL] = []

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    func trashItem(at url: URL) throws {
        let destination = destinationDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.moveItem(at: url, to: destination)
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func recordedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

private final class CountingTrashHandler: WorkspaceTrashHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func trashItem(at url: URL) throws {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

private final class OneShotFileSwap: @unchecked Sendable {
    private let source: URL
    private let replacement: URL
    private let lock = NSLock()
    private var didRun = false

    init(source: URL, replacement: URL) {
        self.source = source
        self.replacement = replacement
    }

    func perform() throws {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: replacement, to: source)
    }
}

private final class OneShotSymlinkRetarget: @unchecked Sendable {
    private let link: URL
    private let destination: URL
    private let lock = NSLock()
    private var didRun = false

    init(link: URL, destination: URL) {
        self.link = link
        self.destination = destination
    }

    func perform() throws {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }
}

private final class OneShotDirectorySymlinkSwap: @unchecked Sendable {
    private let directory: URL
    private let destination: URL
    private let lock = NSLock()
    private var didRun = false

    init(directory: URL, destination: URL) {
        self.directory = directory
        self.destination = destination
    }

    func perform() throws {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(
            at: directory, withDestinationURL: destination
        )
    }
}

private final class OneShotDirectoryReplacement: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var didRun = false

    init(directory: URL) {
        self.directory = directory
    }

    func perform() throws {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
    }
}

private final class DeferredDirectoryReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false

    func perform(on directory: URL) throws {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        let displaced = directory.deletingLastPathComponent().appendingPathComponent(
            "displaced-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.moveItem(at: directory, to: displaced)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        try Data("replacement".utf8).write(
            to: directory.appendingPathComponent("replacement.txt")
        )
    }
}
