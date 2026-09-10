@preconcurrency import Foundation
import Darwin
import XCTest
@testable import LumenEditorCore

final class GitServiceTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/Lumen Git Workspace", isDirectory: true)

    func testPorcelainV1ZParsesStatusesSpacesUnicodeAndRenameSource() {
        let porcelain = Data(
            " M Sources/My File.swift\0R  Sources/新.swift\0Sources/old.swift\0?? --literal\0".utf8
        )

        XCTAssertEqual(GitParsers.parsePorcelainV1Z(porcelain), [
            GitStatusEntry(path: "Sources/My File.swift", indexStatus: " ", worktreeStatus: "M"),
            GitStatusEntry(path: "Sources/新.swift", indexStatus: "R", worktreeStatus: " "),
            GitStatusEntry(path: "--literal", indexStatus: "?", worktreeStatus: "?")
        ])
    }

    func testPorcelainV1ZIgnoresMalformedAndTruncatedRecords() {
        let porcelain = Data("bad\0 M \0AA valid.txt\0".utf8)
        XCTAssertEqual(
            GitParsers.parsePorcelainV1Z(porcelain),
            [GitStatusEntry(path: "valid.txt", indexStatus: "A", worktreeStatus: "A")]
        )
    }

    func testRemoteSanitizerRemovesCredentialsQueryAndFragment() {
        XCTAssertEqual(
            GitParsers.sanitizeRemoteURL("https://alice:secret@example.com/org/repo.git"),
            "https://example.com/org/repo.git"
        )
        XCTAssertEqual(
            GitParsers.sanitizeRemoteURL("git@example.com:org/repo.git"),
            "example.com:org/repo.git"
        )
        XCTAssertEqual(
            GitParsers.sanitizeRemoteURL("ssh://git@example.com/org/repo.git"),
            "ssh://example.com/org/repo.git"
        )
        XCTAssertEqual(
            GitParsers.sanitizeRemoteURL("https://example.com/repo.git?token=secret#private"),
            "https://example.com/repo.git"
        )
        XCTAssertEqual(
            GitParsers.sanitizeRemoteURL("alice:secret@example.com:org/repo.git"),
            "example.com:org/repo.git"
        )
        XCTAssertEqual(
            GitParsers.sanitizeRemoteURL("foo::https://alice:secret@example.com/org/repo.git"),
            "foo::https://example.com/org/repo.git"
        )
        XCTAssertEqual(
            GitParsers.sanitizeRemoteURL("ext::sh -c token=secret"),
            "ext::[redacted]"
        )
    }

    func testRemoteParserSupportsInlineAndSplitConfigAndKeepsFirstURL() {
        let text = [
            "remote.upstream.url https://token@example.com/org/%E4%B8%BB%E4%BB%93%E5%BA%93.git",
            "remote.origin.url",
            "git@example.com:org/repo.git",
            "remote.origin.url https://ignored.example/repo.git",
            "remote.origin.pushurl ssh://git:secret@example.com/org/repo.git"
        ].joined(separator: "\n")

        XCTAssertEqual(GitParsers.parseRemoteLines(text), [
            GitRemote(
                name: "origin",
                fetchUrl: "example.com:org/repo.git",
                pushUrl: "ssh://example.com/org/repo.git"
            ),
            GitRemote(name: "upstream", fetchUrl: "https://example.com/org/主仓库.git")
        ])
    }

    func testRemoteParserBoundsCountAndUTF16Length() {
        let text = (0..<5).map { "remote.r\($0).url https://example.com/😀😀😀" }
            .joined(separator: "\n")
        let remotes = GitParsers.parseRemoteLines(
            text,
            maximumRemotes: 2,
            maximumURLUTF16Units: 22
        )

        XCTAssertEqual(remotes.map(\.name), ["r0", "r1"])
        XCTAssertTrue(remotes.allSatisfy { ($0.fetchUrl?.utf16.count ?? 0) <= 22 })
    }

    func testTrackingRequiresExactlyTwoSafeNonnegativeIntegers() {
        XCTAssertEqual(
            GitParsers.parseTracking(
                upstreamText: " origin/main\n",
                aheadBehindText: "3\t2\n",
                remoteText: "origin",
                remoteRefText: "refs/heads/main"
            ),
            GitTrackingStatus(
                upstream: "origin/main",
                remote: "origin",
                remoteBranch: "main",
                ahead: 3,
                behind: 2
            )
        )
        XCTAssertEqual(
            GitParsers.parseTracking(upstreamText: "origin/main", aheadBehindText: "bad 2"),
            GitTrackingStatus(upstream: "origin/main")
        )
        XCTAssertEqual(
            GitParsers.parseTracking(upstreamText: "", aheadBehindText: "1 2 3"),
            GitTrackingStatus()
        )
        XCTAssertNil(
            GitParsers.parseTracking(
                upstreamText: "origin/main",
                aheadBehindText: "9007199254740992 0"
            ).ahead
        )
    }

    func testHunkParserRepeatsFileHeaderAndBoundsResults() throws {
        let diff = [
            "diff --git a/file.txt b/file.txt",
            "--- a/file.txt",
            "+++ b/file.txt",
            "@@ -1 +1 @@ first",
            "-old",
            "+new",
            "@@ -5 +5 @@ second",
            "-before",
            "+after"
        ].joined(separator: "\n")

        let hunks = GitParsers.parseHunks(relativePath: "file.txt", diff: diff)

        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].header, "@@ -1 +1 @@ first")
        XCTAssertEqual(hunks[1].header, "@@ -5 +5 @@ second")
        XCTAssertTrue(hunks[0].patch.hasPrefix("diff --git a/file.txt b/file.txt\n"))
        XCTAssertTrue(hunks[1].patch.hasPrefix("diff --git a/file.txt b/file.txt\n"))
        XCTAssertFalse(hunks[1].patch.contains("-old"))
        XCTAssertEqual(
            GitParsers.parseHunks(relativePath: "file.txt", diff: diff, maximumCount: 1).count,
            1
        )
    }

    func testHistoryAndConflictParsersBuildDTOs() {
        let history = [
            "aaaaaaaa", "aaaa", "Ada", "2026-08-31T10:00:00Z", "First",
            "\nbbbbbbbb", "bbbb", "Lin", "2026-08-30T10:00:00Z", "Second",
            ""
        ].joined(separator: "\0")

        XCTAssertEqual(GitParsers.parseHistory(history), [
            GitHistoryEntry(
                id: "aaaaaaaa",
                shortId: "aaaa",
                author: "Ada",
                date: "2026-08-31T10:00:00Z",
                subject: "First"
            ),
            GitHistoryEntry(
                id: "bbbbbbbb",
                shortId: "bbbb",
                author: "Lin",
                date: "2026-08-30T10:00:00Z",
                subject: "Second"
            )
        ])
        XCTAssertEqual(
            GitParsers.parseConflicts(Data("one.swift\0line\nbreak.swift\0".utf8)),
            [GitConflict(path: "one.swift"), GitConflict(path: "line\nbreak.swift")]
        )
        XCTAssertEqual(
            GitParsers.parseConflicts("one.swift\r\ntwo.swift\n\n"),
            [GitConflict(path: "one.swift"), GitConflict(path: "two.swift")]
        )
        XCTAssertEqual(
            GitParsers.truncateDisplayText("abcdef", maximumUTF16Units: 4),
            "abcd"
        )
    }

    func testReadCommandsUseAbsoluteGitNoShellAndPathSeparator() throws {
        let builder = try GitCommandBuilder(rootURL: root)

        let status = builder.porcelainStatusCommand()
        XCTAssertEqual(status.executableURL.path, "/usr/bin/git")
        XCTAssertEqual(
            status.arguments,
            [
                "-C", root.path, "--literal-pathspecs", "-c", "core.fsmonitor=false",
                "status", "--porcelain=v1", "-z"
            ]
        )
        XCTAssertEqual(status.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(status.environment["GIT_LITERAL_PATHSPECS"], "1")
        XCTAssertEqual(status.timeout, 10)
        XCTAssertEqual(status.maximumOutputBytes, 8 * 1_024 * 1_024)

        XCTAssertEqual(
            try builder.diffCommand(relativePath: "Sources/-option.swift").arguments,
            [
                "-C", root.path, "--literal-pathspecs", "-c", "core.fsmonitor=false",
                "diff", "--no-ext-diff", "--no-textconv", "--", "Sources/-option.swift"
            ]
        )
        XCTAssertEqual(
            try builder.historyCommand(relativePath: "notes.txt").arguments,
            [
                "-C", root.path, "--literal-pathspecs", "-c", "core.fsmonitor=false",
                "log", "-n", "100",
                "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00", "--", "notes.txt"
            ]
        )
        XCTAssertEqual(
            try builder.blameCommand(relativePath: "notes.txt").arguments.suffix(4),
            ["blame", "--date=short", "--", "notes.txt"]
        )
        XCTAssertEqual(
            try builder.conflictBlobCommand(relativePath: "notes.txt", side: .ours).arguments.suffix(2),
            ["show", ":2:notes.txt"]
        )
        XCTAssertEqual(
            try builder.conflictBlobCommand(relativePath: "notes.txt", side: .theirs).arguments.suffix(2),
            ["show", ":3:notes.txt"]
        )
    }

    func testActionCommandsValidateRootAndPutPathsAfterSeparator() throws {
        let builder = try GitCommandBuilder(rootURL: root)
        let stage = try builder.actionCommand(for: GitActionRequest(
            root: root,
            action: .stage,
            paths: ["-strange name.txt", "Sources/main.swift"]
        ))
        XCTAssertEqual(
            stage.arguments,
            [
                "-C", root.path, "--literal-pathspecs", "-c", "core.fsmonitor=false",
                "add", "--", "-strange name.txt", "Sources/main.swift"
            ]
        )

        let unstage = try builder.actionCommand(for: GitActionRequest(
            root: root,
            action: .unstage,
            paths: ["main.swift"]
        ))
        XCTAssertEqual(unstage.arguments.suffix(4), ["restore", "--staged", "--", "main.swift"])

        let commit = try builder.actionCommand(for: GitActionRequest(
            root: root,
            action: .commit,
            message: "  subject; $(never-shell)  "
        ))
        XCTAssertEqual(commit.arguments.suffix(3), ["commit", "-m", "subject; $(never-shell)"])

        XCTAssertThrowsError(try builder.actionCommand(for: GitActionRequest(
            root: "/tmp/not-the-authorized-root",
            action: .stage,
            paths: ["main.swift"]
        )))
    }

    func testHunkCommandsPutPatchOnlyOnStandardInput() throws {
        let builder = try GitCommandBuilder(rootURL: root)
        let patch = "diff --git a/a b/a\n@@ -1 +1 @@\n-old\n+new\n"

        let stage = try builder.actionCommand(for: GitActionRequest(
            root: root, action: .stageHunk, paths: ["a"], patch: patch
        ))
        XCTAssertEqual(stage.arguments.suffix(3), ["apply", "--cached", "-"] )
        XCTAssertEqual(stage.standardInput, Data(patch.utf8))

        let discard = try builder.actionCommand(for: GitActionRequest(
            root: root, action: .discardHunk, paths: ["a"], patch: patch
        ))
        XCTAssertEqual(discard.arguments.suffix(3), ["apply", "--reverse", "-"] )
    }

    func testRelativePathValidationRejectsTraversalAbsoluteAndAmbiguousPaths() throws {
        let builder = try GitCommandBuilder(rootURL: root)
        for path in ["", "../secret", "safe/../secret", "name..txt", "/tmp/file", "./file", "dir//file"] {
            XCTAssertThrowsError(try builder.diffCommand(relativePath: path), path)
        }
        XCTAssertNoThrow(try builder.diffCommand(relativePath: "Sources/file.swift"))
        let literalMagicPath = try builder.diffCommand(relativePath: ":(glob)**")
        XCTAssertEqual(literalMagicPath.arguments.last, ":(glob)**")
    }

    func testBranchAndRequiredActionValidation() throws {
        let builder = try GitCommandBuilder(rootURL: root)
        XCTAssertThrowsError(try builder.actionCommand(for: GitActionRequest(root: root, action: .stage)))
        XCTAssertThrowsError(try builder.actionCommand(for: GitActionRequest(
            root: root, action: .checkoutBranch, branch: "--detach"
        )))
        XCTAssertThrowsError(try builder.actionCommand(for: GitActionRequest(
            root: root, action: .createBranch, branch: "feature/../main"
        )))
        XCTAssertEqual(
            try builder.actionCommand(for: GitActionRequest(
                root: root, action: .checkoutBranch, branch: "feature/native-v1"
            )).arguments.suffix(2),
            ["switch", "feature/native-v1"]
        )
    }

    func testServiceMapsInjectedResultsWithoutRequiringGit() async throws {
        let runner = QueueGitRunner(results: [
            .success(output: "main\n"),
            .success(output: " M file.swift\0"),
            .success(output: "remote.origin.url https://token@example.com/repo.git\n"),
            .success(output: "refs/heads/main\n"),
            .success(output: "origin\n"),
            .success(output: "origin/main\n"),
            .success(output: "2 1\n")
        ])
        let service = try GitService(rootURL: root, runner: runner)

        let status = try await service.status()

        XCTAssertEqual(status, GitStatus(
            available: true,
            branch: "main",
            entries: [GitStatusEntry(path: "file.swift", indexStatus: " ", worktreeStatus: "M")],
            tracking: GitTrackingStatus(
                upstream: "origin/main", remote: "origin", remoteBranch: "main", ahead: 2, behind: 1
            ),
            remotes: [GitRemote(name: "origin", fetchUrl: "https://example.com/repo.git")]
        ))
        let commandCount = await runner.receivedCommands().count
        XCTAssertEqual(commandCount, 7)
    }

    func testServiceMapsNotRepositoryAndBestEffortConflicts() async throws {
        let unavailableRunner = QueueGitRunner(results: [
            .failure(code: 128, error: "fatal: not a git repository")
        ])
        let unavailable = try GitService(rootURL: root, runner: unavailableRunner)
        let unavailableStatus = try await unavailable.status()
        XCTAssertEqual(unavailableStatus, GitStatus(available: false, entries: []))

        let conflictRunner = QueueGitRunner(results: [.failure(code: 1, error: "index unavailable")])
        let conflictService = try GitService(rootURL: root, runner: conflictRunner)
        let conflicts = try await conflictService.conflicts()
        XCTAssertEqual(conflicts, [])
    }

    func testConflictsPopulateOursAndTheirsLabelsAndSnapshots() async throws {
        let runner = QueueGitRunner(results: [
            .success(output: "conflicted.swift\0"),
            .success(output: "ours\n"),
            .success(output: "theirs\n"),
            .success(output: "theirs\n")
        ])
        let service = try GitService(rootURL: root, runner: runner)

        let conflicts = try await service.conflicts()
        XCTAssertEqual(
            conflicts,
            [GitConflict(path: "conflicted.swift", ours: "Ours", theirs: "Theirs")]
        )

        let snapshot = try await service.conflictSnapshot(
            relativePath: "conflicted.swift",
            side: .theirs
        )
        XCTAssertEqual(snapshot.content, "theirs\n")
        XCTAssertTrue(snapshot.url.path.contains(".git/lumen-conflicts/theirs/conflicted.swift"))
    }

    func testHunkActionRevalidatesCurrentPatchBeforeApply() async throws {
        let currentDiff = [
            "diff --git a/a.txt b/a.txt",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            ""
        ].joined(separator: "\n")
        let patch = try XCTUnwrap(
            GitParsers.parseHunks(relativePath: "a.txt", diff: currentDiff).first?.patch
        )
        let staleRunner = QueueGitRunner(results: [.success(output: currentDiff)])
        let service = try GitService(rootURL: root, runner: staleRunner)

        do {
            _ = try await service.perform(GitActionRequest(
                root: root,
                action: .stageHunk,
                paths: ["a.txt"],
                patch: patch + "changed"
            ))
            XCTFail("Expected stale hunk rejection")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .staleHunk)
        }
        let commandCount = await staleRunner.receivedCommands().count
        XCTAssertEqual(commandCount, 1)
    }

    func testDTOsUseElectronRawActionAndURLKeys() throws {
        let request = GitActionRequest(root: "/tmp/repo", action: .stageHunk, paths: ["a"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["action"] as? String, "stage-hunk")

        let remote = GitRemote(name: "origin", fetchUrl: "safe", pushUrl: "push")
        let remoteObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(remote)) as? [String: Any]
        )
        XCTAssertEqual(remoteObject["fetchUrl"] as? String, "safe")
        XCTAssertEqual(remoteObject["pushUrl"] as? String, "push")
    }

    func testStatusPropagatesCancellationFromBestEffortMetadata() async throws {
        let runner = QueueGitRunner(results: [
            .success(output: "main\n"),
            .success(output: ""),
            .cancelled
        ])
        let service = try GitService(rootURL: root, runner: runner)

        do {
            _ = try await service.status()
            XCTFail("Expected cancellation")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testSuccessfulMutationIsCommittedWhenFollowUpStatusFails() async throws {
        let runner = QueueGitRunner(results: [
            .success(output: ""),
            .failure(code: 128, error: "status unavailable")
        ])
        let service = try GitService(rootURL: root, runner: runner)

        let result = try await service.perform(GitActionRequest(
            root: root, action: .discard, paths: ["file.swift"]
        ))

        XCTAssertEqual(result, .committed(statusRefresh: .failed(
            .processFailed(exitCode: 128, stderr: "status unavailable")
        )))
        let commands = await runner.receivedCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(Array(commands[0].arguments.suffix(4)), [
            "restore", "--worktree", "--", "file.swift"
        ])
    }

    func testCancellationAfterSuccessfulMutationIsOnlyStatusRefreshFailure() async throws {
        let runner = QueueGitRunner(results: [
            .success(output: ""),
            .cancelled
        ])
        let service = try GitService(rootURL: root, runner: runner)

        let result = try await service.perform(GitActionRequest(
            root: root, action: .checkoutBranch, branch: "feature/native"
        ))

        XCTAssertEqual(result, .committed(statusRefresh: .failed(.cancelled)))
    }

    func testCancellationWhileLaunchedMutationIsIndeterminate() async throws {
        let runner = IndeterminateGitRunner()
        let service = try GitService(rootURL: root, runner: runner)
        let operation = Task {
            try await service.perform(GitActionRequest(
                root: self.root, action: .discard, paths: ["file.swift"]
            ))
        }
        await runner.waitUntilMutationStarted()

        operation.cancel()
        await runner.finishCancellation()
        let result = try await operation.value

        XCTAssertEqual(result, .indeterminate(.cancelled))
    }

    func testCancellationBeforeMutationHandoffThrowsWithoutRunningCommand() async throws {
        let runner = QueueGitRunner(results: [])
        let service = try GitService(rootURL: root, runner: runner)
        let operation = Task {
            try await service.perform(GitActionRequest(
                root: self.root, action: .discard, paths: ["file.swift"]
            ))
        }
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("Expected pre-handoff cancellation")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let commandCount = await runner.receivedCommands().count
        XCTAssertEqual(commandCount, 0)
    }

    func testCancelledMutationWaiterDoesNotRunOrConsumePermit() async throws {
        let runner = BlockingGitRunner()
        let service = try GitService(rootURL: root, runner: runner)
        let rootPath = root.path
        let first = Task {
            try await service.perform(GitActionRequest(
                root: rootPath, action: .stage, paths: ["first.swift"]
            ))
        }
        await runner.waitUntilFirstCommandStarts()

        let waiting = Task {
            try await service.perform(GitActionRequest(
                root: rootPath, action: .stage, paths: ["second.swift"]
            ))
        }
        waiting.cancel()
        await runner.releaseFirstCommand()
        _ = try await first.value

        do {
            _ = try await waiting.value
            XCTFail("Expected waiting mutation cancellation")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let paths = await runner.stagedPaths()
        XCTAssertEqual(paths, ["first.swift"])
    }

    func testGitProcessRunnerCancellationReapsDescendantProcessGroup() async throws {
        let runner = GitProcessRunner()
        let pidFile = URL(fileURLWithPath:
            "/tmp/lumen-git-descendant-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let command = GitCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "trap '' TERM; sleep 30 & child=$!; printf '%d' \"$child\" > \"$1\"; wait",
                "lumen-git-test",
                pidFile.path
            ],
            timeout: 10,
            maximumOutputBytes: 1_024,
            maximumErrorBytes: 1_024
        )
        let operation = Task { try await runner.run(command) }
        let descendantPID = try await waitForPID(in: pidFile)

        await runner.cancelAll()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(Darwin.kill(descendantPID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Git descendant survived process-group teardown")
    }

    func testGitProcessRunnerCancelAllJoinsConcurrentCommands() async throws {
        let runner = GitProcessRunner()
        let firstPIDFile = URL(fileURLWithPath:
            "/tmp/lumen-git-first-\(UUID().uuidString)"
        )
        let secondPIDFile = URL(fileURLWithPath:
            "/tmp/lumen-git-second-\(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: firstPIDFile)
            try? FileManager.default.removeItem(at: secondPIDFile)
        }
        func trackedCommand(_ file: URL) -> GitCommand {
            GitCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '%d' \"$$\" > \"$1\"; trap '' TERM; sleep 30",
                    "lumen-git-test",
                    file.path
                ],
                timeout: 10,
                maximumOutputBytes: 1_024,
                maximumErrorBytes: 1_024
            )
        }
        let first = Task { try await runner.run(trackedCommand(firstPIDFile)) }
        let second = Task { try await runner.run(trackedCommand(secondPIDFile)) }
        _ = try await waitForPID(in: firstPIDFile)
        _ = try await waitForPID(in: secondPIDFile)

        await runner.cancelAll()
        for operation in [first, second] {
            do {
                _ = try await operation.value
                XCTFail("Expected cancellation")
            } catch let error as GitServiceError {
                XCTAssertEqual(error, .cancelled)
            }
        }
    }

    func testServiceShutdownCancelsRunningAndQueuedMutations() async throws {
        let runner = ShutdownTrackingGitRunner()
        let service = try GitService(rootURL: root, runner: runner)
        let first = Task {
            try await service.perform(GitActionRequest(
                root: root.path, action: .stage, paths: ["first.swift"]
            ))
        }
        await runner.waitUntilCommandStarts()
        let queued = Task {
            try await service.perform(GitActionRequest(
                root: root.path, action: .stage, paths: ["second.swift"]
            ))
        }

        let shutdown = Task { await service.shutdown() }
        await runner.waitUntilCancellationRequested()
        let returnedBeforeTeardown = await runner.hasReturnedFromCancelAll()
        XCTAssertFalse(returnedBeforeTeardown)
        await runner.finishCancellation()
        await shutdown.value

        for operation in [first, queued] {
            do {
                _ = try await operation.value
                XCTFail("Expected shutdown cancellation")
            } catch let error as GitServiceError {
                XCTAssertEqual(error, .cancelled)
            }
        }
        let paths = await runner.startedPaths()
        XCTAssertEqual(paths, ["first.swift"])
    }

    private func waitForPID(in file: URL) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let value = Int32(String(decoding: data, as: UTF8.self)),
               value > 1 {
                return value
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestDeadlineError.elapsed
    }

}

private enum TestDeadlineError: Error { case elapsed }

private actor QueueGitRunner: GitCommandRunning {
    enum Stub {
        case success(output: String, error: String = "", code: Int32 = 0)
        case failure(code: Int32, error: String)
        case cancelled
    }

    private var stubs: [Stub]
    private var commands: [GitCommand] = []

    init(results: [Stub]) {
        stubs = results
    }

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        commands.append(command)
        guard !stubs.isEmpty else {
            XCTFail("Unexpected Git command: \(command.arguments)")
            return GitProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
        }
        let stub = stubs.removeFirst()
        switch stub {
        case let .success(output, error, code):
            return GitProcessResult(
                standardOutput: Data(output.utf8),
                standardError: Data(error.utf8),
                exitCode: code
            )
        case let .failure(code, error):
            return GitProcessResult(
                standardOutput: Data(),
                standardError: Data(error.utf8),
                exitCode: code
            )
        case .cancelled:
            throw GitServiceError.cancelled
        }
    }

    func receivedCommands() -> [GitCommand] { commands }
}

private actor IndeterminateGitRunner: GitCommandRunning {
    private var continuation: CheckedContinuation<GitProcessResult, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilMutationStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finishCancellation() {
        continuation?.resume(throwing: GitServiceError.cancelled)
        continuation = nil
    }
}

private actor BlockingGitRunner: GitCommandRunning {
    private var firstCommandStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var recordedPaths: [String] = []

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        if let addIndex = command.arguments.firstIndex(of: "add"),
           let path = command.arguments.dropFirst(addIndex + 1).last {
            recordedPaths.append(path)
            if !firstCommandStarted {
                firstCommandStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
            return GitProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
        }

        if command.arguments.contains("branch") {
            return GitProcessResult(standardOutput: Data("main\n".utf8), standardError: Data(), exitCode: 0)
        }
        return GitProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
    }

    func waitUntilFirstCommandStarts() async {
        guard !firstCommandStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstCommand() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func stagedPaths() -> [String] { recordedPaths }
}

private actor ShutdownTrackingGitRunner: GitCommandRunning {
    private var commandContinuation: CheckedContinuation<GitProcessResult, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelFinishContinuation: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false
    private var cancelAllReturned = false
    private var paths: [String] = []

    func run(_ command: GitCommand) async throws -> GitProcessResult {
        if let addIndex = command.arguments.firstIndex(of: "add"),
           let path = command.arguments.dropFirst(addIndex + 1).last {
            paths.append(path)
            let waiters = startWaiters
            startWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                commandContinuation = continuation
            }
        }
        return GitProcessResult(
            standardOutput: Data(), standardError: Data(), exitCode: 0
        )
    }

    func cancelAll() async {
        cancellationRequested = true
        let waiters = cancelWaiters
        cancelWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            cancelFinishContinuation = continuation
        }
        commandContinuation?.resume(throwing: GitServiceError.cancelled)
        commandContinuation = nil
        cancelAllReturned = true
    }

    func waitUntilCommandStarts() async {
        guard commandContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationRequested() async {
        guard !cancellationRequested else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append(continuation)
        }
    }

    func finishCancellation() {
        cancelFinishContinuation?.resume()
        cancelFinishContinuation = nil
    }

    func hasReturnedFromCancelAll() -> Bool { cancelAllReturned }
    func startedPaths() -> [String] { paths }
}
