import Foundation
import XCTest
@testable import LumenEditorCore

final class ProjectSettingsTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testParsesEveryElectronProjectDTOField() throws {
        let settings = try ProjectSettingsSanitizer.parse(jsonData([
            "exclude": ["**/build/**"],
            "buildCommand": "swift test",
            "keyBindings": ["Mod+R": "build"],
            "plugins": ["team-tools"],
            "pluginPermissions": ["team-tools": ["document-read", "network"]],
            "languageTools": ["Swift": ["command": "swift-format", "args": ["format"]]],
            "languageServers": ["Swift": ["command": "sourcekit-lsp", "args": ["--stdio"]]],
            "buildSystems": [[
                "name": "Tests", "command": "swift", "args": ["test"],
                "workingDirectory": "Sources", "fileRegex": "(.+):(\\d+)",
                "saveBeforeBuild": true, "shell": false, "env": ["MODE": "test"],
                "variants": [["name": "Release", "args": ["test", "-c", "release"]]]
            ]],
            "keyBindingRules": [[
                "keys": ["Mod+K", "Mod+C"], "command": "toggle-line-comment",
                "when": "editor"
            ]],
            "marketplaceUrls": ["https://plugins.example.test/index.json"],
            "snippets": [[
                "label": "Log", "text": "print(${1:value})",
                "trigger": "log-value", "scope": "Swift"
            ]]
        ]))

        XCTAssertEqual(settings.exclude, ["**/build/**"])
        XCTAssertEqual(settings.buildCommand, "swift test")
        XCTAssertEqual(settings.keyBindings, ["Mod+R": "build"])
        XCTAssertEqual(settings.plugins, ["team-tools"])
        XCTAssertEqual(settings.pluginPermissions, ["team-tools": [.documentRead]])
        XCTAssertEqual(settings.languageTools["Swift"]?.command, "swift-format")
        XCTAssertEqual(settings.languageTools["Swift"]?.args, ["format"])
        XCTAssertEqual(settings.languageServers["Swift"]?.args, ["--stdio"])
        XCTAssertEqual(settings.buildSystems.first?.name, "Tests")
        XCTAssertEqual(settings.buildSystems.first?.variants.first?.name, "Release")
        XCTAssertEqual(settings.buildSystems.first?.env, ["MODE": "test"])
        XCTAssertEqual(settings.keyBindingRules.first?.keys, ["Mod+K", "Mod+C"])
        XCTAssertEqual(settings.keyBindingRules.first?.when, .editor)
        XCTAssertEqual(settings.marketplaceUrls, ["https://plugins.example.test/index.json"])
        XCTAssertEqual(settings.snippets.first?.trigger, "log-value")
    }

    func testLanguageToolConfigKeepsLegacyJSONAndAddsExecutionFields() throws {
        let legacy = try JSONDecoder().decode(
            LanguageToolConfig.self,
            from: jsonData(["command": "swift-format", "args": ["format"]])
        )
        XCTAssertEqual(
            legacy,
            LanguageToolConfig(command: "swift-format", args: ["format"])
        )
        XCTAssertNil(legacy.shell)
        XCTAssertNil(legacy.workingDirectory)
        XCTAssertNil(legacy.env)
        let legacyJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)
        ) as? [String: Any]
        XCTAssertEqual(
            Set(legacyJSON?.keys.map { $0 } ?? []),
            Set(["command", "args"])
        )

        var extended = LanguageToolConfig(
            command: "swift-format",
            args: ["format"],
            shell: false,
            workingDirectory: "Sources",
            env: ["MODE": "check"]
        )
        XCTAssertEqual(extended.environment, ["MODE": "check"])
        extended.environment = ["MODE": "write"]
        XCTAssertEqual(extended.env, ["MODE": "write"])

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(extended)
        ) as? [String: Any]
        XCTAssertEqual(encoded?["command"] as? String, "swift-format")
        XCTAssertEqual(encoded?["args"] as? [String], ["format"])
        XCTAssertEqual(encoded?["shell"] as? Bool, false)
        XCTAssertEqual(encoded?["workingDirectory"] as? String, "Sources")
        let encodedEnvironment = encoded?["env"] as? [String: Any]
        XCTAssertEqual(encodedEnvironment?["MODE"] as? String, "write")
        XCTAssertNil(encoded?["environment"])
    }

    func testLanguageToolsAreBoundedInBothSanitizerPaths() throws {
        let command = String(
            repeating: "c",
            count: ToolExecutionLimits.maximumExecutableUTF16CodeUnits + 5
        )
        let args = (0..<(ToolExecutionLimits.maximumArguments + 5)).map { index in
            String(
                repeating: "a",
                count: ToolExecutionLimits.maximumArgumentUTF16CodeUnits + 5
            ) + "\(index)"
        }
        let workingDirectory = String(
            repeating: "w",
            count: ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits + 5
        )
        let environment = Dictionary(uniqueKeysWithValues:
            (0..<(ToolExecutionLimits.maximumEnvironmentVariables + 5)).map { index in
                (String(format: "KEY_%03d", index), "value")
            }
        )
        let maximumEnvironmentValue = String(
            repeating: "v",
            count: ToolExecutionLimits.maximumEnvironmentValueUTF16CodeUnits
        )
        let oversizedEnvironmentValue = maximumEnvironmentValue + "v"

        let losslessSettings = try ProjectSettingsSanitizer.parse(jsonData([
            "languageTools": [
                "Swift": [
                    "command": command,
                    "args": args,
                    "shell": true,
                    "workingDirectory": workingDirectory,
                    "env": environment
                ],
                "Environment": [
                    "command": "env-tool",
                    "args": [],
                    "env": [
                        "AT_LIMIT": maximumEnvironmentValue,
                        "OVER_LIMIT": oversizedEnvironmentValue
                    ]
                ]
            ]
        ]))
        let sessionSettings = ProjectSettingsSanitizer.sanitize(WindowSessionProject([
            "languageTools": .object([
                "Swift": .object([
                    "command": .string(command),
                    "args": .array(args.map(WindowSessionJSONValue.string)),
                    "shell": .bool(true),
                    "workingDirectory": .string(workingDirectory),
                    "env": .object(environment.mapValues(WindowSessionJSONValue.string))
                ]),
                "Environment": .object([
                    "command": .string("env-tool"),
                    "args": .array([]),
                    "env": .object([
                        "AT_LIMIT": .string(maximumEnvironmentValue),
                        "OVER_LIMIT": .string(oversizedEnvironmentValue)
                    ])
                ])
            ])
        ]))
        let typedSettings = ProjectSettings(
            languageTools: [
                "Swift": LanguageToolConfig(
                    command: command,
                    args: args,
                    shell: true,
                    workingDirectory: workingDirectory,
                    env: environment
                ),
                "Environment": LanguageToolConfig(
                    command: "env-tool",
                    args: [],
                    env: [
                        "AT_LIMIT": maximumEnvironmentValue,
                        "OVER_LIMIT": oversizedEnvironmentValue
                    ]
                )
            ]
        ).sanitized()

        for settings in [losslessSettings, sessionSettings, typedSettings] {
            let tool = try XCTUnwrap(settings.languageTools["Swift"])
            XCTAssertEqual(
                tool.command.utf16.count,
                ToolExecutionLimits.maximumExecutableUTF16CodeUnits
            )
            XCTAssertEqual(tool.args.count, ToolExecutionLimits.maximumArguments)
            XCTAssertTrue(tool.args.allSatisfy {
                $0.utf16.count <= ToolExecutionLimits.maximumArgumentUTF16CodeUnits
            })
            XCTAssertEqual(
                tool.workingDirectory?.utf16.count,
                ToolExecutionLimits.maximumWorkingDirectoryUTF16CodeUnits
            )
            XCTAssertEqual(tool.shell, true)
            XCTAssertEqual(
                tool.env?.count,
                ToolExecutionLimits.maximumEnvironmentVariables
            )

            let valueTool = try XCTUnwrap(settings.languageTools["Environment"])
            XCTAssertEqual(valueTool.env?["AT_LIMIT"], maximumEnvironmentValue)
            XCTAssertNil(valueTool.env?["OVER_LIMIT"])
        }
    }

    func testLanguageToolWrongTypesDoNotHideKnownFields() throws {
        let losslessSettings = try ProjectSettingsSanitizer.parse(jsonData([
            "languageTools": [
                "Swift": [
                    "command": "swift-format",
                    "args": ["format", 7],
                    "shell": "false",
                    "workingDirectory": false,
                    "env": ["not-an-object"],
                    "futureOption": ["enabled": true]
                ],
                "Bad command": ["command": false, "args": []]
            ]
        ]))
        let sessionSettings = ProjectSettingsSanitizer.sanitize(WindowSessionProject([
            "languageTools": .object([
                "Swift": .object([
                    "command": .string("swift-format"),
                    "args": .array([.string("format"), .number(7)]),
                    "shell": .string("false"),
                    "workingDirectory": .bool(false),
                    "env": .array([.string("not-an-object")]),
                    "futureOption": .object(["enabled": .bool(true)])
                ]),
                "Bad command": .object([
                    "command": .bool(false), "args": .array([])
                ])
            ])
        ]))

        for settings in [losslessSettings, sessionSettings] {
            XCTAssertEqual(settings.languageTools.count, 1)
            let tool = try XCTUnwrap(settings.languageTools["Swift"])
            XCTAssertEqual(tool.command, "swift-format")
            XCTAssertEqual(tool.args, ["format"])
            XCTAssertNil(tool.shell)
            XCTAssertNil(tool.workingDirectory)
            XCTAssertNil(tool.env)
        }
    }

    func testLanguageToolNullBytesAndEnvironmentErrorsAreFiltered() throws {
        let tooLongKey = String(
            repeating: "K",
            count: ToolExecutionLimits.maximumEnvironmentKeyASCIICharacters + 1
        )
        let losslessSettings = try ProjectSettingsSanitizer.parse(jsonData([
            "languageTools": [
                "Swift": [
                    "command": "swift-format",
                    "args": ["good", "bad\u{0}arg"],
                    "workingDirectory": "bad\u{0}directory",
                    "env": [
                        "GOOD": "value",
                        "bad-key": "value",
                        tooLongKey: "value",
                        "NULL_VALUE": "bad\u{0}value",
                        "WRONG_TYPE": 7
                    ]
                ],
                "Null command": ["command": "bad\u{0}command", "args": []]
            ]
        ]))
        let sessionSettings = ProjectSettingsSanitizer.sanitize(WindowSessionProject([
            "languageTools": .object([
                "Swift": .object([
                    "command": .string("swift-format"),
                    "args": .array([.string("good"), .string("bad\u{0}arg")]),
                    "workingDirectory": .string("bad\u{0}directory"),
                    "env": .object([
                        "GOOD": .string("value"),
                        "bad-key": .string("value"),
                        tooLongKey: .string("value"),
                        "NULL_VALUE": .string("bad\u{0}value"),
                        "WRONG_TYPE": .number(7)
                    ])
                ]),
                "Null command": .object([
                    "command": .string("bad\u{0}command"), "args": .array([])
                ])
            ])
        ]))

        for settings in [losslessSettings, sessionSettings] {
            XCTAssertEqual(settings.languageTools.count, 1)
            let tool = try XCTUnwrap(settings.languageTools["Swift"])
            XCTAssertEqual(tool.args, ["good"])
            XCTAssertNil(tool.workingDirectory)
            XCTAssertEqual(tool.env, ["GOOD": "value"])
        }
    }

    func testStoreKeepsKnownLanguageToolFieldsWhileCanonicalizingUnknownFields() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        try jsonData([
            "futureTopLevel": ["keep": false],
            "languageTools": [
                "Swift": [
                    "command": "swift-format",
                    "args": ["format"],
                    "shell": false,
                    "workingDirectory": "Sources",
                    "env": ["MODE": "check"],
                    "futureOption": "ignored"
                ]
            ],
            "languageServers": [
                "Swift": [
                    "command": "sourcekit-lsp",
                    "args": ["--stdio"],
                    "shell": true,
                    "workingDirectory": "Sources",
                    "env": ["MODE": "ignored"]
                ]
            ]
        ]).write(to: store.settingsURL)

        let snapshot = try store.load()
        XCTAssertEqual(snapshot.settings.languageTools["Swift"]?.shell, false)
        XCTAssertEqual(
            snapshot.settings.languageTools["Swift"]?.workingDirectory,
            "Sources"
        )
        XCTAssertEqual(
            snapshot.settings.languageTools["Swift"]?.env,
            ["MODE": "check"]
        )
        XCTAssertEqual(snapshot.settings.languageServers["Swift"]?.command, "sourcekit-lsp")
        XCTAssertEqual(snapshot.settings.languageServers["Swift"]?.args, ["--stdio"])
        _ = try store.save(snapshot.settings, expectedRevision: snapshot.revision)

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.settingsURL)
        ) as? [String: Any]
        XCTAssertNil(saved?["futureTopLevel"])
        let tools = saved?["languageTools"] as? [String: Any]
        let tool = tools?["Swift"] as? [String: Any]
        XCTAssertNil(tool?["futureOption"])
        XCTAssertEqual(tool?["workingDirectory"] as? String, "Sources")
        let savedEnvironment = tool?["env"] as? [String: Any]
        XCTAssertEqual(savedEnvironment?["MODE"] as? String, "check")

        let servers = saved?["languageServers"] as? [String: Any]
        let server = servers?["Swift"] as? [String: Any]
        XCTAssertEqual(Set(server?.keys.map { $0 } ?? []), Set(["command", "args"]))
    }

    func testWrongTypesFallBackAndBadChildrenAreFiltered() throws {
        let settings = try ProjectSettingsSanitizer.parse(jsonData([
            "exclude": "not-array",
            "buildCommand": 42,
            "keyBindings": ["good": "save", "bad": 4],
            "plugins": ["valid-id", "bad id", 7],
            "pluginPermissions": ["bad id": ["document-read"]],
            "languageTools": ["Swift": ["args": []]],
            "languageServers": ["Swift": ["command": "lsp", "args": [1, "--stdio"]]],
            "buildSystems": [NSNull(), ["name": "missing-command"]],
            "keyBindingRules": [["keys": 4, "command": "save"]],
            "marketplaceUrls": ["http://insecure.test"],
            "snippets": [["label": "missing-text"]]
        ]))

        XCTAssertEqual(settings.exclude, [])
        XCTAssertEqual(settings.buildCommand, "")
        XCTAssertEqual(settings.keyBindings, ["good": "save"])
        XCTAssertEqual(settings.plugins, ["valid-id"])
        XCTAssertEqual(settings.pluginPermissions, [:])
        XCTAssertEqual(settings.languageTools, [:])
        XCTAssertEqual(settings.languageServers["Swift"]?.args, ["--stdio"])
        XCTAssertEqual(settings.buildSystems, [])
        XCTAssertEqual(settings.keyBindingRules, [])
        XCTAssertEqual(settings.marketplaceUrls, [])
        XCTAssertEqual(settings.snippets, [])
    }

    func testSanitizerAppliesCollectionAndUTF16Limits() throws {
        let exclusions = (0..<110).map { String(repeating: "e", count: 205) + "\($0)" }
        let plugins = (0..<60).map { "plugin-\($0)" }
        let languageServers = Dictionary(uniqueKeysWithValues: (0..<35).map { index in
            ("Language \(index)", [
                "command": String(repeating: "c", count: 1_005),
                "args": ["--stdio"]
            ] as [String: Any])
        })
        let settings = try ProjectSettingsSanitizer.parse(jsonData([
            "exclude": exclusions,
            "buildCommand": String(repeating: "b", count: 1_005),
            "plugins": plugins,
            "languageServers": languageServers,
            "marketplaceUrls": (0..<25).map { "https://market\($0).example.test/index.json" }
        ]))

        XCTAssertEqual(settings.exclude.count, 100)
        XCTAssertEqual(settings.exclude[0].utf16.count, 200)
        XCTAssertEqual(settings.buildCommand.utf16.count, 1_000)
        XCTAssertEqual(settings.plugins.count, 50)
        XCTAssertEqual(settings.languageServers.count, 30)
        let first = try XCTUnwrap(settings.languageServers.values.first)
        XCTAssertEqual(first.command.utf16.count, 1_000)
        XCTAssertEqual(settings.marketplaceUrls.count, 20)

        // Keep this independent fixture below the parser's 1 MiB input cap
        // while still exercising both per-configuration argument limits.
        let argumentSettings = try ProjectSettingsSanitizer.parse(jsonData([
            "languageServers": [
                "Swift": [
                    "command": "sourcekit-lsp",
                    "args": (0..<55).map {
                        String(repeating: "a", count: 4_005) + "\($0)"
                    }
                ]
            ]
        ]))
        let argumentServer = try XCTUnwrap(argumentSettings.languageServers["Swift"])
        XCTAssertEqual(argumentServer.args.count, 50)
        XCTAssertEqual(argumentServer.args.first?.utf16.count, 4_000)
    }

    func testMapLimitsFollowElectronObjectEntriesOrder() throws {
        let pairs = (0..<35).map { index in
            "\"L\(index)\":{\"command\":\"tool-\(index)\",\"args\":[]}"
        }
        let source = "{\"languageTools\":{" + pairs.joined(separator: ",") + "}}"
        let settings = try ProjectSettingsSanitizer.parse(Data(source.utf8))

        XCTAssertEqual(settings.languageTools.count, 30)
        XCTAssertNotNil(settings.languageTools["L0"])
        XCTAssertNotNil(settings.languageTools["L29"])
        XCTAssertNil(settings.languageTools["L30"])
    }

    func testEnvironmentMatchesElectronNameAndValueBounds() throws {
        let settings = try ProjectSettingsSanitizer.parse(jsonData([
            "buildSystems": [[
                "name": "Safe environment",
                "command": "swift",
                "env": [
                    "MODE": "debug",
                    "NODE_OPTIONS": "--require ./evil.js",
                    "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
                    "bad-key": "value"
                ]
            ]]
        ]))

        XCTAssertEqual(settings.buildSystems.first?.env, [
            "MODE": "debug",
            "NODE_OPTIONS": "--require ./evil.js",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"
        ])
    }

    func testParserRejectsNonObjectMalformedAndOversizedJSON() throws {
        XCTAssertThrowsError(try ProjectSettingsSanitizer.parse(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? ProjectSettingsParseError, .expectedObject)
        }
        XCTAssertThrowsError(try ProjectSettingsSanitizer.parse(Data("{".utf8))) { error in
            XCTAssertEqual(error as? ProjectSettingsParseError, .invalidJSON)
        }
        let oversized = Data(
            repeating: 0x20,
            count: ProjectSettingsSanitizer.maximumSerializedBytes + 1
        )
        XCTAssertThrowsError(try ProjectSettingsSanitizer.parse(oversized)) { error in
            XCTAssertEqual(
                error as? ProjectSettingsParseError,
                .inputTooLarge(
                    actualBytes: oversized.count,
                    maximumBytes: ProjectSettingsSanitizer.maximumSerializedBytes
                )
            )
        }
    }

    func testStoreLoadsMissingAsDefaultsThenAtomicallyRoundTrips() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let missing = try store.load()
        XCTAssertEqual(missing.settings, .empty)
        XCTAssertNil(missing.revision)

        let expected = ProjectSettings(
            exclude: ["**/.build/**"],
            buildCommand: "swift test",
            plugins: ["team-tools"],
            marketplaceUrls: ["https://plugins.example.test/index.json"]
        )
        let result = try store.save(expected, expectedRevision: nil)

        XCTAssertTrue(result.wroteBytes)
        XCTAssertEqual(try store.load().settings, expected)
        XCTAssertEqual(try store.load().revision, result.revision)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: store.settingsURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.path)
            .contains { $0.hasSuffix(".tmp") })
    }

    func testStoreRejectsSymlinkHardLinkAndNonRegularTarget() throws {
        let symlinkWorkspace = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        let symlinkStore = ProjectSettingsStore(workspaceURL: symlinkWorkspace)
        try FileManager.default.createSymbolicLink(at: symlinkStore.settingsURL, withDestinationURL: outside)
        XCTAssertThrowsError(try symlinkStore.load()) { error in
            XCTAssertEqual(error as? ProjectSettingsStoreError, .symbolicLinkEncountered)
        }
        XCTAssertThrowsError(try symlinkStore.save(.empty, expectedRevision: nil))
        XCTAssertEqual(try String(contentsOf: outside), "{}")

        let hardLinkWorkspace = try temporaryDirectory()
        let hardStore = ProjectSettingsStore(workspaceURL: hardLinkWorkspace)
        try Data("{}".utf8).write(to: hardStore.settingsURL)
        try FileManager.default.linkItem(
            at: hardStore.settingsURL,
            to: hardLinkWorkspace.appendingPathComponent("alias.json")
        )
        XCTAssertThrowsError(try hardStore.load()) { error in
            XCTAssertEqual(error as? ProjectSettingsStoreError, .hardLinkedFile)
        }

        let directoryWorkspace = try temporaryDirectory()
        let directoryStore = ProjectSettingsStore(workspaceURL: directoryWorkspace)
        try FileManager.default.createDirectory(
            at: directoryStore.settingsURL, withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try directoryStore.load()) { error in
            XCTAssertEqual(error as? ProjectSettingsStoreError, .notARegularFile)
        }
    }

    func testStoreRejectsSymlinkWorkspaceAndOversizedFile() throws {
        let real = try temporaryDirectory()
        let parent = try temporaryDirectory()
        let link = parent.appendingPathComponent("linked-workspace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try ProjectSettingsStore(workspaceURL: link).load()) { error in
            XCTAssertEqual(error as? ProjectSettingsStoreError, .invalidWorkspace(link))
        }
        let nestedReal = try temporaryDirectory()
        let linkedParent = parent.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(
            at: linkedParent, withDestinationURL: nestedReal
        )
        let throughAncestorLink = linkedParent.appendingPathComponent("child")
        try FileManager.default.createDirectory(
            at: nestedReal.appendingPathComponent("child"),
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try ProjectSettingsStore(workspaceURL: throughAncestorLink).load()) { error in
            XCTAssertEqual(
                error as? ProjectSettingsStoreError,
                .invalidWorkspace(throughAncestorLink)
            )
        }

        let store = ProjectSettingsStore(workspaceURL: real)
        try Data(
            repeating: 0x20,
            count: ProjectSettingsStore.maximumSerializedBytes + 1
        ).write(to: store.settingsURL)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .fileTooLarge = error as? ProjectSettingsStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStoreRejectsWorkspacePathReplacementAfterAuthorization() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let moved = workspace.deletingLastPathComponent()
            .appendingPathComponent("moved-" + UUID().uuidString)
        try FileManager.default.moveItem(at: workspace, to: moved)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        temporaryDirectories.append(moved)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ProjectSettingsStoreError, .workspaceChanged(workspace))
        }
    }

    func testOptimisticSaveRejectsExternalChangesWithoutOverwriting() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let first = try store.save(
            ProjectSettings(buildCommand: "swift test"), expectedRevision: nil
        )
        try ProjectSettingsSanitizer.encodedData(
            ProjectSettings(buildCommand: "external edit")
        ).write(to: store.settingsURL)

        XCTAssertThrowsError(try store.save(
            ProjectSettings(buildCommand: "stale edit"),
            expectedRevision: first.revision
        )) { error in
            guard case .conflict = error as? ProjectSettingsStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try store.load().settings.buildCommand, "external edit")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.path)
            .contains { $0.hasSuffix(".tmp") })
    }

    func testSameBytesAreIdempotentDespiteStaleRevision() throws {
        let workspace = try temporaryDirectory()
        let store = ProjectSettingsStore(workspaceURL: workspace)
        let settings = ProjectSettings(buildCommand: "swift test")
        let first = try store.save(settings, expectedRevision: nil)
        let result = try store.save(settings, expectedRevision: nil)

        XCTAssertFalse(result.wroteBytes)
        XCTAssertEqual(result.revision, first.revision)
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-settings-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }
}
