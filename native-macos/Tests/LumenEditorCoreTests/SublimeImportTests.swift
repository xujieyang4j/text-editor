import Foundation
import XCTest
@testable import LumenEditorCore

final class SublimeImportTests: XCTestCase {
    func testStandaloneBuildSystemSupportsCommentsAndUsesFilenameFallback() throws {
        let source = URL(fileURLWithPath: "/tmp/Swift Tests.sublime-build")
        let data = Data(#"""
        {
          // A standalone build file does not normally declare a name.
          "cmd": ["swift", "test"],
          "working_dir": "$file_path",
          "env": {"MODE": "test", "9BAD": "ignored"},
          "variants": [
            {"name": "Release", "shell_cmd": "swift test -c release"},
          ],
        }
        """#.utf8)

        let result = try SublimeImportParser.parseBuildSystem(data, sourceURL: source)

        XCTAssertEqual(result.name, "Swift Tests")
        XCTAssertEqual(result.command, "swift")
        XCTAssertEqual(result.arguments, ["test"])
        XCTAssertEqual(result.workingDirectory, "$file_path")
        XCTAssertEqual(result.environment, ["MODE": "test"])
        XCTAssertEqual(result.variants, [
            SublimeBuildVariantImport(
                name: "Release", command: "swift test -c release", usesShell: true
            )
        ])
    }

    func testStandaloneBuildSystemRejectsOversizeNonObjectAndMissingCommand() throws {
        let source = URL(fileURLWithPath: "/tmp/Build.sublime-build")
        XCTAssertThrowsError(try SublimeImportParser.parseBuildSystem(
            Data(repeating: 0x20, count: 9), sourceURL: source,
            limits: SublimeImportLimits(maximumJSONBytes: 8)
        )) { error in
            XCTAssertEqual(
                error as? SublimeImportError,
                .inputTooLarge(actualBytes: 9, maximumBytes: 8)
            )
        }
        XCTAssertThrowsError(try SublimeImportParser.parseBuildSystem(
            Data(#"["swift"]"#.utf8), sourceURL: source
        )) { XCTAssertEqual($0 as? SublimeImportError, .expectedObject) }
        XCTAssertThrowsError(try SublimeImportParser.parseBuildSystem(
            Data(#"{"cmd":["swift"]"#.utf8), sourceURL: source
        )) { XCTAssertEqual($0 as? SublimeImportError, .invalidJSON) }
        XCTAssertThrowsError(try SublimeImportParser.parseBuildSystem(
            Data(#"{"name":"No command"}"#.utf8), sourceURL: source
        )) { XCTAssertEqual($0 as? SublimeImportError, .missingBuildCommand) }
        XCTAssertThrowsError(try SublimeImportParser.parseBuildSystem(
            Data(#"{"cmd":["swift"],}"#.utf8),
            sourceURL: URL(string: "https://example.com/Build.sublime-build")!
        )) { XCTAssertEqual($0 as? SublimeImportError, .invalidSourceURL) }
    }

    func testProjectResolvesRootsBoundsExcludesAndBuildSystemsWithoutIO() throws {
        let source = URL(fileURLWithPath: "/projects/demo/demo.sublime-project")
        let data = Data(#"""
        {
          "folders": [
            {"path": "src", "file_exclude_patterns": ["*.min.js"], "folder_exclude_patterns": ["build"]},
            {"path": "../shared"},
            {"path": "src"}
          ],
          "build_systems": [{
            "name": "Tests", "cmd": ["swift", "test"],
            "working_dir": "$project_path",
            "env": {"GOOD": "yes", "9BAD": "no"},
            "variants": [{"name": "Release", "cmd": ["swift", "test", "-c", "release"]}]
          }]
        }
        """#.utf8)

        let result = try SublimeImportParser.parseProject(data, sourceURL: source)

        XCTAssertEqual(result.roots.map(\.path), [
            "/projects/demo/src", "/projects/shared"
        ])
        XCTAssertEqual(result.exclusions, ["*.min.js", "**/build/**"])
        XCTAssertEqual(result.buildSystems.first?.name, "Tests")
        XCTAssertEqual(result.buildSystems.first?.command, "swift")
        XCTAssertEqual(result.buildSystems.first?.arguments, ["test"])
        XCTAssertEqual(result.buildSystems.first?.environment, ["GOOD": "yes"])
        XCTAssertEqual(result.buildSystems.first?.variants.first?.name, "Release")
        guard case let .array(values)? = result.projectSettings.values["buildSystems"] else {
            return XCTFail("Build systems must be exported as project JSON")
        }
        XCTAssertEqual(values.count, 1)
    }

    func testProjectIsStrictJSONAndHasBoundedInputAndRoots() throws {
        let source = URL(fileURLWithPath: "/tmp/a.sublime-project")
        XCTAssertThrowsError(try SublimeImportParser.parseProject(
            Data(#"{"folders": [],}"#.utf8), sourceURL: source
        )) { XCTAssertEqual($0 as? SublimeImportError, .invalidJSON) }
        XCTAssertThrowsError(try SublimeImportParser.parseProject(
            Data(repeating: 0x20, count: 9), sourceURL: source,
            limits: SublimeImportLimits(maximumJSONBytes: 8)
        )) { error in
            XCTAssertEqual(
                error as? SublimeImportError,
                .inputTooLarge(actualBytes: 9, maximumBytes: 8)
            )
        }

        let folders = (0..<25).map { #"{"path": "root\#($0)"}"# }
            .joined(separator: ",")
        let result = try SublimeImportParser.parseProject(
            Data("{\"folders\":[\(folders)]}".utf8), sourceURL: source
        )
        XCTAssertEqual(result.roots.count, 20)
    }

    func testSettingsSupportsCommentsTrailingCommasAndProducesDiffOnly() throws {
        var current = EditorSettings.default
        current.highlightTrailingWhitespace = false
        current.showMinimap = false
        let source = URL(fileURLWithPath: "/tmp/Preferences.sublime-settings")
        let data = Data(#"""
        {
          // ordinary comment
          "font_size": 99,
          "tab_size": 2,
          "translate_tabs_to_spaces": false,
          "line_numbers": false,
          "draw_white_space": "selection",
          "rulers": [80, 600, 120,],
          "color_scheme": "Packages/Dracula.tmTheme",
        }
        """#.utf8)

        let result = try SublimeImportParser.parseSettings(
            data, sourceURL: source, current: current
        )

        XCTAssertEqual(result.settings.fontSize, 40)
        XCTAssertEqual(result.settings.tabSize, 2)
        XCTAssertFalse(result.settings.insertSpaces)
        XCTAssertFalse(result.settings.showLineNumbers)
        XCTAssertTrue(result.settings.showWhitespace)
        XCTAssertEqual(result.settings.rulers, [80, 120])
        XCTAssertEqual(result.settings.colorScheme, .dracula)
        XCTAssertFalse(result.settings.highlightTrailingWhitespace)
        XCTAssertFalse(result.settings.showMinimap)
        XCTAssertEqual(Set(result.changes.map(\.key)), Set([
            .fontSize, .tabSize, .insertSpaces, .showLineNumbers,
            .showWhitespace, .rulers, .colorScheme
        ]))
    }

    func testCommentStripperDoesNotDamageStrings() throws {
        let current = EditorSettings.default
        let data = Data(#"{"color_scheme": "https://x/,}]light", /* c */}"#.utf8)
        let result = try SublimeImportParser.parseSettings(
            data, sourceURL: URL(fileURLWithPath: "/tmp/a.sublime-settings"),
            current: current
        )
        XCTAssertEqual(result.settings.colorScheme, .light)
    }

    func testKeymapMapsSafeKnownCommandsAndRejectsArgsContextsAndBadKeys() throws {
        let data = Data(#"""
        [
          {"keys": ["super+k", "ctrl+s"], "command": "save"},
          {"keys": ["alt+left"], "command": "goto_line"},
          {"keys": ["ctrl+b"], "command": "build", "args": {"x": 1}},
          {"keys": ["ctrl+x"], "command": "save", "context": [{"key": "selector"}]},
          {"keys": ["ctrl+x"], "command": "package_command"},
          {"keys": ["not-a-real-key"], "command": "save"}
        ]
        """#.utf8)
        let result = try SublimeImportParser.parseKeymap(
            data, sourceURL: URL(fileURLWithPath: "/tmp/Default.sublime-keymap")
        )

        XCTAssertEqual(result.overrides.count, 2)
        XCTAssertEqual(result.skipped, 4)
        XCTAssertEqual(result.overrides[0].commandID, "save")
        XCTAssertEqual(result.overrides[0].binding?.sequence, [
            CommandKeyEquivalent(key: "k", modifiers: .command),
            CommandKeyEquivalent(key: "s", modifiers: .command)
        ])
        XCTAssertEqual(
            result.overrides[1].binding?.singleKeyEquivalent,
            CommandKeyEquivalent(key: "left", modifiers: .option)
        )
    }

    func testKeymapBoundsInspectedAndImportedEntries() throws {
        let entries = (0..<505).map { _ in
            #"{"keys":["ctrl+s"],"command":"save"}"#
        }.joined(separator: ",")
        let result = try SublimeImportParser.parseKeymap(
            Data("[\(entries)]".utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/a.sublime-keymap")
        )
        XCTAssertEqual(result.inspected, 500)
        XCTAssertEqual(result.overrides.count, 200)
        XCTAssertEqual(result.skipped, 305)
        XCTAssertTrue(result.wasTruncated)
    }

    func testSnippetHandlesCDATAEntitiesAndBoundsMetadata() throws {
        let source = URL(fileURLWithPath: "/tmp/Print.sublime-snippet")
        let data = Data(#"""
        <snippet>
          <content><![CDATA[print(${1:value})]]></content>
          <tabTrigger>log-me</tabTrigger>
          <scope>source.swift &amp; source.test</scope>
        </snippet>
        """#.utf8)
        let result = try SublimeImportParser.parseSnippet(data, sourceURL: source)
        XCTAssertEqual(result.label, "Print")
        XCTAssertEqual(result.text, "print(${1:value})")
        XCTAssertEqual(result.trigger, "log-me")
        XCTAssertEqual(result.scope, "source.swift & source.test")

        let invalid = Data("<snippet><content>x</content><tabTrigger>bad trigger</tabTrigger></snippet>".utf8)
        XCTAssertNil(try SublimeImportParser.parseSnippet(invalid, sourceURL: source).trigger)
    }

}
