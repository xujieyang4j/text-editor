import Foundation
import XCTest
@testable import LumenEditorCore

final class ToolExecutionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testConfigurationNormalizesPathsExecutableAndDefaults() throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("workspace", isDirectory: true)
        let build = root.appendingPathComponent("Build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let compiler = build.appendingPathComponent("bin/compiler", isDirectory: false)
        let resolver = try makeResolver(additional: ["compiler": compiler])

        let configuration = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: " ./tools/../bin/compiler ",
            args: ["--check", "value with spaces", ""],
            workingDirectory: "Sources/../Build",
            env: ["MODE": "debug"],
            authorizedRoot: root.appendingPathComponent(".", isDirectory: true),
            resolver: resolver
        )

        XCTAssertEqual(configuration.root, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(configuration.cwd, build.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(
            configuration.executable,
            "./tools/../bin/compiler"
        )
        XCTAssertEqual(
            configuration.executableURL,
            compiler.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(configuration.args, ["--check", "value with spaces", ""])
        XCTAssertFalse(configuration.shell)
        XCTAssertEqual(configuration.env, ["MODE": "debug"])

        let defaultCWD = try ToolExecutionConfiguration(
            kind: .languageServer,
            executable: "sourcekit-lsp",
            authorizedRoot: root,
            resolver: resolver
        )
        XCTAssertEqual(defaultCWD.cwd, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(defaultCWD.executable, "sourcekit-lsp")
        XCTAssertEqual(defaultCWD.args, [])
        XCTAssertEqual(defaultCWD.env, [:])
    }

    func testShellSourceIsTrimmedButNeverParsedOrRewritten() throws {
        let root = try makeTemporaryDirectory()
        let source = " npm test && printf '%s' '$HOME' "
        let resolver = try makeResolver()

        let configuration = try ToolExecutionConfiguration(
            kind: .buildCommand,
            executable: source,
            shell: true,
            authorizedRoot: root,
            resolver: resolver
        )

        XCTAssertEqual(configuration.executable, source.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(configuration.args, [])
        XCTAssertTrue(configuration.shell)
        let command = try configuration.makeCommand()
        XCTAssertEqual(command.executableURL, try resolver.resolveShell())
        XCTAssertEqual(command.arguments, ["-c", source.trimmingCharacters(in: .whitespaces)])
    }

    func testExecutableResolutionUsesOnlyFixedAllowlist() throws {
        let root = try makeTemporaryDirectory()
        let trusted = root.appendingPathComponent("tools/compiler", isDirectory: false)
        let resolver = try makeResolver(additional: ["compiler": trusted])

        let byAlias = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "compiler",
            authorizedRoot: root,
            resolver: resolver
        )
        let byAbsolutePath = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: trusted.path,
            authorizedRoot: root,
            resolver: resolver
        )
        let normalizedTrusted = trusted.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(byAlias.executableURL, normalizedTrusted)
        XCTAssertEqual(byAbsolutePath.executableURL, normalizedTrusted)

        assertToolError(.executableNotAllowed("unknown-tool")) {
            try ToolExecutionConfiguration(
                kind: .buildSystem,
                executable: "unknown-tool",
                authorizedRoot: root,
                resolver: resolver
            )
        }
        XCTAssertThrowsError(try resolver.resolve("tools/unknown")) { error in
            XCTAssertEqual(
                error as? ToolExecutionError,
                .relativeExecutablePathNotAllowed("tools/unknown")
            )
        }
        assertToolError(.executableNotAllowed("/tmp/not-approved")) {
            try ToolExecutionConfiguration(
                kind: .buildSystem,
                executable: "/tmp/not-approved",
                authorizedRoot: root,
                resolver: resolver
            )
        }
    }

    func testExecutableAllowlistNormalizesSymlinks() throws {
        let container = try makeTemporaryDirectory()
        let target = container.appendingPathComponent("target-tool", isDirectory: false)
        let alias = container.appendingPathComponent("alias-tool", isDirectory: false)
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let resolver = try ToolExecutableResolver(allowedExecutables: ["tool": alias])

        XCTAssertEqual(try resolver.resolve("tool"), target.standardizedFileURL)
        XCTAssertEqual(try resolver.resolve(target.path), target.standardizedFileURL)
    }

    func testDirectArgumentsAreNeverPassedThroughShell() throws {
        let root = try makeTemporaryDirectory()
        let resolver = try makeResolver()
        let dangerousLookingArguments = [
            "hello; touch /tmp/never",
            "$(whoami)",
            "$HOME",
            "value with spaces"
        ]
        let configuration = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "swift",
            args: dangerousLookingArguments,
            authorizedRoot: root,
            resolver: resolver
        )

        let command = try configuration.makeCommand()
        XCTAssertEqual(command.executableURL, try resolver.resolve("swift"))
        XCTAssertEqual(command.arguments, dangerousLookingArguments)
        XCTAssertFalse(configuration.shell)
    }

    func testShellModeIsPurposeRestrictedAndCannotMixProjectArgv() throws {
        let root = try makeTemporaryDirectory()
        let resolver = try makeResolver()
        assertToolError(.shellNotAllowed(kind: .languageServer)) {
            try ToolExecutionConfiguration(
                kind: .languageServer,
                executable: "server --stdio",
                shell: true,
                authorizedRoot: root,
                resolver: resolver
            )
        }
        assertToolError(.shellArgumentsNotAllowed) {
            try ToolExecutionConfiguration(
                kind: .buildSystem,
                executable: "swift test",
                args: ["; rm -rf /"],
                shell: true,
                authorizedRoot: root,
                resolver: resolver
            )
        }
    }

    func testShellPolicyIsExplicitForEveryToolKind() throws {
        let root = try makeTemporaryDirectory()
        let resolver = try makeResolver()
        let allowed: Set<ToolKind> = [.build, .buildCommand, .buildSystem, .languageTool]

        for kind in ToolKind.allCases {
            if allowed.contains(kind) {
                XCTAssertNoThrow(try ToolExecutionConfiguration(
                    kind: kind, executable: "true", shell: true,
                    authorizedRoot: root, resolver: resolver
                ))
            } else {
                assertToolError(.shellNotAllowed(kind: kind)) {
                    try ToolExecutionConfiguration(
                        kind: kind, executable: "true", shell: true,
                        authorizedRoot: root, resolver: resolver
                    )
                }
            }
        }
    }

    func testWorkingDirectoryMustStayInsideAuthorizedRoot() throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)

        XCTAssertThrowsError(try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "swift",
            workingDirectory: "../outside",
            authorizedRoot: root
        )) { error in
            guard case .workingDirectoryOutsideAuthorizedRoot = error as? ToolExecutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "swift",
            cwd: outside,
            authorizedRoot: root
        )) { error in
            guard case .workingDirectoryOutsideAuthorizedRoot = error as? ToolExecutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorkingDirectoryCannotEscapeThroughSymbolicLink() throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let escape = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        XCTAssertThrowsError(try ToolExecutionConfiguration(
            kind: .languageTool,
            executable: "formatter",
            workingDirectory: "escape",
            authorizedRoot: root
        )) { error in
            guard case .workingDirectoryOutsideAuthorizedRoot = error as? ToolExecutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRootAndWorkingDirectoryRequireAbsoluteLocalFileURLs() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertThrowsError(try ToolExecutionConfiguration(
            kind: .terminal,
            executable: "/bin/zsh",
            authorizedRoot: URL(string: "https://example.com/project")!
        )) { error in
            guard case .invalidAuthorizedRoot = error as? ToolExecutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try ToolExecutionConfiguration(
            kind: .terminal,
            executable: "/bin/zsh",
            cwd: URL(string: "file://remote.example/project")!,
            authorizedRoot: root
        )) { error in
            guard case .invalidWorkingDirectory = error as? ToolExecutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExecutableAndArgumentBoundsAreStrict() throws {
        let root = try makeTemporaryDirectory()
        let maximumArguments = Array(
            repeating: String(
                repeating: "x",
                count: ToolExecutionLimits.maximumArgumentUTF16CodeUnits
            ),
            count: ToolExecutionLimits.maximumArguments
        )

        let exact = try ToolExecutionConfiguration(
            kind: .languageServer,
            executable: String(
                repeating: "x",
                count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
            ),
            args: maximumArguments,
            authorizedRoot: root,
            resolver: try makeResolver(additional: [
                String(
                    repeating: "x",
                    count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
                ): URL(fileURLWithPath: "/usr/bin/exact-boundary-tool")
            ])
        )
        XCTAssertEqual(exact.args.count, ToolExecutionLimits.maximumArguments)

        assertToolError(.emptyExecutable) {
            try ToolExecutionConfiguration(
                kind: .buildCommand,
                executable: " \n\t ",
                shell: true,
                authorizedRoot: root
            )
        }
        assertToolError(.executableContainsNull) {
            try ToolExecutionConfiguration(
                kind: .languageTool,
                executable: "format\0tool",
                authorizedRoot: root
            )
        }
        assertToolError(.executableTooLong(
            maximumUTF16CodeUnits: ToolExecutionLimits.maximumExecutableUTF16CodeUnits
        )) {
            try ToolExecutionConfiguration(
                kind: .languageTool,
                executable: String(
                    repeating: "x",
                    count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits + 1
                ),
                authorizedRoot: root
            )
        }
        assertToolError(.tooManyArguments(maximum: ToolExecutionLimits.maximumArguments)) {
            try ToolExecutionConfiguration(
                kind: .languageServer,
                executable: "server",
                args: maximumArguments + ["overflow"],
                authorizedRoot: root
            )
        }
        assertToolError(.argumentContainsNull(index: 1)) {
            try ToolExecutionConfiguration(
                kind: .languageServer,
                executable: "server",
                args: ["safe", "not\0safe"],
                authorizedRoot: root
            )
        }
        assertToolError(.argumentTooLong(
            index: 0,
            maximumUTF16CodeUnits: ToolExecutionLimits.maximumArgumentUTF16CodeUnits
        )) {
            try ToolExecutionConfiguration(
                kind: .languageServer,
                executable: "server",
                args: [String(
                    repeating: "😀",
                    count: ToolExecutionLimits.maximumArgumentUTF16CodeUnits / 2 + 1
                )],
                authorizedRoot: root
            )
        }
    }

    func testEnvironmentValidationAllowsBoundariesAndRejectsInjection() throws {
        let root = try makeTemporaryDirectory()
        let exactEnvironment = Dictionary(uniqueKeysWithValues: (0..<ToolExecutionLimits.maximumEnvironmentVariables).map {
            ("SAFE_\($0)", String(
                repeating: "x",
                count: ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits
            ))
        })

        let exact = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "swift",
            env: exactEnvironment,
            authorizedRoot: root,
            resolver: try makeResolver()
        )
        XCTAssertEqual(exact.env.count, ToolExecutionLimits.maximumEnvironmentVariables)

        var excessive = exactEnvironment
        excessive["OVERFLOW"] = "1"
        assertToolError(.tooManyEnvironmentVariables(
            maximum: ToolExecutionLimits.maximumEnvironmentVariables
        )) {
            try ToolExecutionConfiguration(
                kind: .buildSystem,
                executable: "swift",
                env: excessive,
                authorizedRoot: root
            )
        }

        for key in ["", "1NAME", "HAS-DASH", "HAS=EQUALS", "非ASCII"] {
            assertToolError(.invalidEnvironmentKey(key)) {
                try ToolExecutionConfiguration(
                    kind: .buildSystem,
                    executable: "swift",
                    env: [key: "value"],
                    authorizedRoot: root
                )
            }
        }

        for key in [
            "DYLD_INSERT_LIBRARIES",
            "dyld_library_path",
            "LD_PRELOAD",
            "BASH_ENV",
            "NODE_OPTIONS",
            "PYTHONSTARTUP"
        ] {
            assertToolError(.unsafeEnvironmentKey(key)) {
                try ToolExecutionConfiguration(
                    kind: .buildSystem,
                    executable: "swift",
                    env: [key: "/tmp/inject"],
                    authorizedRoot: root
                )
            }
        }

        assertToolError(.environmentValueContainsNull(key: "SAFE")) {
            try ToolExecutionConfiguration(
                kind: .buildSystem,
                executable: "swift",
                env: ["SAFE": "before\0after"],
                authorizedRoot: root
            )
        }
        assertToolError(.environmentValueTooLong(
            key: "SAFE",
            maximumUTF16CodeUnits: ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits
        )) {
            try ToolExecutionConfiguration(
                kind: .buildSystem,
                executable: "swift",
                env: ["SAFE": String(
                    repeating: "😀",
                    count: ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits / 2 + 1
                )],
                authorizedRoot: root
            )
        }
    }

    func testInheritedEnvironmentIsAllowlistedSanitizedAndOverridden() throws {
        let root = try makeTemporaryDirectory()
        let configuration = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "swift",
            env: ["PATH": "/approved/bin", "CUSTOM": "explicit"],
            inheritedEnvironment: [
                "PATH": "/untrusted/bin",
                "HOME": "/Users/example",
                "LC_ALL": "C",
                "TOKEN": "must-not-leak",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "NODE_OPTIONS": "--require=/tmp/inject.js"
            ],
            authorizedRoot: root,
            resolver: try makeResolver()
        )

        XCTAssertEqual(configuration.env["PATH"], "/approved/bin")
        XCTAssertEqual(configuration.env["CUSTOM"], "explicit")
        XCTAssertEqual(configuration.env["HOME"], "/Users/example")
        XCTAssertEqual(configuration.env["LC_ALL"], "C")
        XCTAssertNil(configuration.env["TOKEN"])
        XCTAssertNil(configuration.env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(configuration.env["NODE_OPTIONS"])
    }

    func testCommandCarriesSeparateStreamLimitsTimeoutAndProcessGroupPolicy() throws {
        let root = try makeTemporaryDirectory()
        let configuration = try configuration(root: root)
        let input = Data("document".utf8)
        let limits = ToolProcessLimits(
            timeout: 9,
            maximumStandardInputBytes: 100,
            maximumStandardOutputBytes: 200,
            maximumStandardErrorBytes: 300,
            gracefulTerminationTimeout: 0.25,
            processGroupPolicy: .isolated
        )

        let command = try configuration.makeCommand(standardInput: input, limits: limits)
        XCTAssertEqual(command.standardInput, input)
        XCTAssertEqual(command.timeout, 9)
        XCTAssertEqual(command.maximumStandardInputBytes, 100)
        XCTAssertEqual(command.maximumStandardOutputBytes, 200)
        XCTAssertEqual(command.maximumRetainedStandardOutputBytes, 200)
        XCTAssertEqual(command.maximumStandardErrorBytes, 300)
        XCTAssertEqual(command.gracefulTerminationTimeout, 0.25)
        XCTAssertEqual(command.processGroupPolicy, .isolated)

        let streamingLimits = ToolProcessLimits(
            timeout: 9, maximumStandardInputBytes: 100,
            maximumStandardOutputBytes: 2_000,
            maximumRetainedStandardOutputBytes: 20,
            maximumStandardErrorBytes: 300
        )
        XCTAssertEqual(
            try configuration.makeCommand(limits: streamingLimits)
                .maximumRetainedStandardOutputBytes,
            20
        )

        assertToolError(.standardInputTooLarge(actualBytes: 101, maximumBytes: 100)) {
            try configuration.makeCommand(
                standardInput: Data(repeating: 0, count: 101),
                limits: limits
            )
        }
        assertToolError(.invalidProcessLimits) {
            try configuration.makeCommand(limits: ToolProcessLimits(timeout: .infinity))
        }
    }

    func testRunnerBoundaryCarriesResultsAndExplicitCancellationWithoutLaunching() async throws {
        let runner = RecordingToolRunner(result: ToolProcessResult(
            standardOutput: Data("output".utf8),
            standardError: Data("warning".utf8),
            exitCode: 7
        ))
        let configuration = try configuration(root: makeTemporaryDirectory())
        let command = try configuration.makeCommand()

        let result = try await runner.run(command)
        await runner.cancelAll()
        let received = await runner.receivedCommands()
        let cancellationCount = await runner.cancellationCount()
        XCTAssertEqual(result.stdout, "output")
        XCTAssertEqual(result.stderr, "warning")
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(received, [command])
        XCTAssertEqual(cancellationCount, 1)
    }

    func testIdentityIsStableForEquivalentConfigurationAndEnvironmentOrder() throws {
        let root = try makeTemporaryDirectory()
        let leftEnvironment = Dictionary(uniqueKeysWithValues: [
            ("ZETA", "last"),
            ("ALPHA", "first")
        ])
        let rightEnvironment = Dictionary(uniqueKeysWithValues: [
            ("ALPHA", "first"),
            ("ZETA", "last")
        ])

        let left = try configuration(root: root, env: leftEnvironment)
        let right = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: " swift ",
            args: ["test", "--parallel"],
            workingDirectory: "./",
            shell: false,
            env: rightEnvironment,
            authorizedRoot: root.appendingPathComponent(".", isDirectory: true),
            resolver: try makeResolver()
        )

        XCTAssertEqual(left, right)
        XCTAssertEqual(left.identity, right.identity)
        XCTAssertEqual(left.identity.rawValue.count, 71)
        XCTAssertTrue(left.identity.rawValue.hasPrefix("sha256:"))
        XCTAssertNotNil(String(left.identity.rawValue.dropFirst(7)).range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ))
    }

    func testEveryExecutionAffectingFieldChangesIdentity() throws {
        let root = try makeTemporaryDirectory()
        let otherRoot = try makeTemporaryDirectory()
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let baseline = try configuration(root: root)
        let variants = try [
            configuration(root: root, kind: .languageTool),
            configuration(root: root, executable: "swiftc"),
            configuration(root: root, args: ["test", "--release"]),
            configuration(root: root, cwd: child),
            configuration(root: root, env: ["MODE": "release"]),
            configuration(root: otherRoot)
        ]

        XCTAssertEqual(Set(variants.map(\.identity)).count, variants.count)
        for variant in variants {
            XCTAssertNotEqual(variant.identity, baseline.identity)
        }
        let directBuild = try configuration(
            root: root,
            kind: .buildCommand,
            args: [],
            shell: false
        )
        let shellBuild = try configuration(
            root: root,
            kind: .buildCommand,
            executable: "swift test",
            args: [],
            shell: true
        )
        XCTAssertNotEqual(directBuild.identity, shellBuild.identity)

        // Length prefixes prevent ambiguous concatenations from colliding.
        let first = try configuration(root: root, args: ["a", "bc"])
        let second = try configuration(root: root, args: ["ab", "c"])
        XCTAssertNotEqual(first.identity, second.identity)
    }

    func testResolvedExecutableURLIsPartOfIdentity() throws {
        let root = try makeTemporaryDirectory()
        let firstResolver = try makeResolver(additional: [
            "compiler": URL(fileURLWithPath: "/opt/toolchain-a/compiler")
        ])
        let secondResolver = try makeResolver(additional: [
            "compiler": URL(fileURLWithPath: "/opt/toolchain-b/compiler")
        ])
        let first = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "compiler",
            authorizedRoot: root,
            resolver: firstResolver
        )
        let second = try ToolExecutionConfiguration(
            kind: .buildSystem,
            executable: "compiler",
            authorizedRoot: root,
            resolver: secondResolver
        )

        XCTAssertNotEqual(first.executableURL, second.executableURL)
        XCTAssertNotEqual(first.identity, second.identity)
    }

    func testApprovalIsExactAndScopedToWindowAndSession() async throws {
        let root = try makeTemporaryDirectory()
        let approved = try configuration(root: root)
        let changed = try configuration(root: root, args: ["test", "--release"])
        let firstScope = ToolApprovalScope(windowID: "window-a", sessionID: "session-a")
        let otherWindow = ToolApprovalScope(windowID: "window-b", sessionID: "session-a")
        let otherSession = ToolApprovalScope(windowID: "window-a", sessionID: "session-b")
        let store = ToolApprovalStore()

        var state = await store.state(for: approved, in: firstScope)
        XCTAssertEqual(state, .required)
        let firstApprovalAdded = await store.approve(approved, in: firstScope)
        let duplicateApprovalAdded = await store.approve(approved, in: firstScope)
        XCTAssertTrue(firstApprovalAdded)
        XCTAssertFalse(duplicateApprovalAdded)

        state = await store.state(for: approved, in: firstScope)
        let changedState = await store.state(for: changed, in: firstScope)
        let otherWindowState = await store.state(for: approved, in: otherWindow)
        let otherSessionState = await store.state(for: approved, in: otherSession)
        XCTAssertEqual(state, .approved)
        XCTAssertEqual(changedState, .required)
        XCTAssertEqual(otherWindowState, .required)
        XCTAssertEqual(otherSessionState, .required)
        let approvalCount = await store.approvalCount(in: firstScope)
        XCTAssertEqual(approvalCount, 1)
    }

    func testRootReleaseRevokesOnlyDependentApprovals() async throws {
        let firstRoot = try makeTemporaryDirectory()
        let secondRoot = try makeTemporaryDirectory()
        let first = try configuration(root: firstRoot)
        let firstFormatter = try configuration(root: firstRoot, kind: .languageTool)
        let second = try configuration(root: secondRoot)
        let firstScope = ToolApprovalScope(windowID: "window-a", sessionID: "session-a")
        let secondScope = ToolApprovalScope(windowID: "window-b", sessionID: "session-b")
        let store = ToolApprovalStore()

        _ = await store.approve(first, in: firstScope)
        _ = await store.approve(firstFormatter, in: firstScope)
        _ = await store.approve(second, in: firstScope)
        _ = await store.approve(first, in: secondScope)

        let scopedReleaseCount = try await store.releaseRoot(
            firstRoot.appendingPathComponent(".", isDirectory: true),
            in: firstScope
        )
        XCTAssertEqual(scopedReleaseCount, 2)
        let firstStillApproved = await store.isApproved(first, in: firstScope)
        let secondStillApproved = await store.isApproved(second, in: firstScope)
        let otherScopeStillApproved = await store.isApproved(first, in: secondScope)
        XCTAssertFalse(firstStillApproved)
        XCTAssertTrue(secondStillApproved)
        XCTAssertTrue(otherScopeStillApproved)

        let globalReleaseCount = try await store.releaseRoot(firstRoot)
        let firstAfterGlobalRelease = await store.isApproved(first, in: secondScope)
        let secondAfterGlobalRelease = await store.isApproved(second, in: firstScope)
        XCTAssertEqual(globalReleaseCount, 1)
        XCTAssertFalse(firstAfterGlobalRelease)
        XCTAssertTrue(secondAfterGlobalRelease)
    }

    func testEndingSessionAndClosingWindowDropEphemeralTrust() async throws {
        let root = try makeTemporaryDirectory()
        let configuration = try configuration(root: root)
        let first = ToolApprovalScope(windowID: "window-a", sessionID: "one")
        let second = ToolApprovalScope(windowID: "window-a", sessionID: "two")
        let third = ToolApprovalScope(windowID: "window-b", sessionID: "one")
        let store = ToolSessionTrust()
        _ = await store.approve(configuration, in: first)
        _ = await store.approve(configuration, in: second)
        _ = await store.approve(configuration, in: third)

        let endedCount = await store.endSession(first)
        let firstAfterEnd = await store.isApproved(configuration, in: first)
        let closedCount = await store.closeWindow("window-a")
        let secondAfterClose = await store.isApproved(configuration, in: second)
        let thirdAfterClose = await store.isApproved(configuration, in: third)
        let revokedCount = await store.revokeAll()
        let thirdAfterRevokeAll = await store.isApproved(configuration, in: third)
        XCTAssertEqual(endedCount, 1)
        XCTAssertFalse(firstAfterEnd)
        XCTAssertEqual(closedCount, 1)
        XCTAssertFalse(secondAfterClose)
        XCTAssertTrue(thirdAfterClose)
        XCTAssertEqual(revokedCount, 1)
        XCTAssertFalse(thirdAfterRevokeAll)
    }

    func testResourceLimitsMatchExistingProcessAndLSPBoundaries() {
        XCTAssertEqual(ToolExecutionLimits.maximumRetainedOutputCharacters, 1_000_000)
        XCTAssertEqual(ToolExecutionLimits.maximumOutputChunkBytes, 256 * 1_024)
        XCTAssertEqual(ToolExecutionLimits.maximumStdinWriteBytes, 64 * 1_024)
        XCTAssertEqual(ToolExecutionLimits.maximumOneShotStdinBytes, 20 * 1_024 * 1_024)
        XCTAssertEqual(ToolExecutionLimits.maximumStandardOutputBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(ToolExecutionLimits.maximumStandardErrorBytes, 1 * 1_024 * 1_024)
        XCTAssertEqual(ToolExecutionLimits.oneShotTimeout, 15)
        XCTAssertEqual(ToolExecutionLimits.languageToolTimeout, 15)
        XCTAssertEqual(ToolExecutionLimits.languageServerInitializeTimeout, 15)
        XCTAssertEqual(ToolExecutionLimits.gracefulTerminationTimeout, 0.5)
        XCTAssertEqual(ToolExecutionLimits.maximumLSPHeaderBytes, 16 * 1_024)
        XCTAssertEqual(ToolExecutionLimits.maximumLSPPayloadBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(ToolExecutionLimits.maximumLSPStdinQueueBytes, 16 * 1_024 * 1_024)
    }

    private func configuration(
        root: URL,
        kind: ToolKind = .buildSystem,
        executable: String = "swift",
        args: [String] = ["test", "--parallel"],
        cwd: URL? = nil,
        shell: Bool = false,
        env: [String: String] = ["ALPHA": "first", "ZETA": "last"]
    ) throws -> ToolExecutionConfiguration {
        try ToolExecutionConfiguration(
            kind: kind,
            executable: executable,
            args: args,
            cwd: cwd,
            shell: shell,
            env: env,
            authorizedRoot: root,
            resolver: try makeResolver()
        )
    }

    private func makeResolver(
        additional: [String: URL] = [:]
    ) throws -> ToolExecutableResolver {
        var executables: [String: URL] = [
            "formatter": URL(fileURLWithPath: "/usr/bin/formatter"),
            "server": URL(fileURLWithPath: "/usr/bin/server"),
            "sh": URL(fileURLWithPath: "/bin/sh"),
            "sourcekit-lsp": URL(fileURLWithPath: "/usr/bin/sourcekit-lsp"),
            "swift": URL(fileURLWithPath: "/usr/bin/swift"),
            "swiftc": URL(fileURLWithPath: "/usr/bin/swiftc"),
            "true": URL(fileURLWithPath: "/usr/bin/true")
        ]
        additional.forEach { executables[$0.key] = $0.value }
        return try ToolExecutableResolver(
            allowedExecutables: executables,
            shellExecutableURL: executables["sh"]
        )
    }

    private func assertToolError<T>(
        _ expected: ToolExecutionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ToolExecutionError, expected, file: file, line: line)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenToolExecutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        temporaryDirectories.append(directory)
        return directory
    }
}

private actor RecordingToolRunner: ToolCommandRunning {
    private let result: ToolProcessResult
    private var commands: [ToolCommand] = []
    private var cancellations = 0

    init(result: ToolProcessResult) {
        self.result = result
    }

    func run(_ command: ToolCommand) async throws -> ToolProcessResult {
        commands.append(command)
        return result
    }

    func cancelAll() async {
        cancellations += 1
    }

    func receivedCommands() -> [ToolCommand] { commands }
    func cancellationCount() -> Int { cancellations }
}
