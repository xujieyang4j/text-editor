import Foundation
import XCTest
@testable import LumenEditorCore

final class EditorConfigTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testParserMatchesSupportedPropertiesAndUnsetSemantics() {
        let parsed = parseEditorConfig(
            "\u{feff} # BOM\r\nROOT = TRUE\r\n\r\n"
                + "[*]\r\nindent_style = SPACE\r\nindent_size = 2\r\n"
                + "tab_width = 8\r\nend_of_line = CRLF\r\nunknown = ignored\r\n\r\n"
                + "[*.md]\r\nindent_size = unset\r\n"
                + "end_of_line = lf # not an inline comment\r\nEND_OF_LINE = LF\r\n"
        )

        XCTAssertTrue(parsed.isValid)
        XCTAssertTrue(parsed.root)
        XCTAssertEqual(
            applyEditorConfig(EditorConfigProperties(), parsed, "docs/readme.md"),
            EditorConfigProperties(
                indentStyle: .space,
                tabWidth: 8,
                endOfLine: .lf
            )
        )
        XCTAssertEqual(
            applyEditorConfig(EditorConfigProperties(), parsed, "src/main.ts"),
            EditorConfigProperties(
                indentStyle: .space,
                indentSize: .columns(2),
                tabWidth: 8,
                endOfLine: .crlf
            )
        )

        let loneCR = parseEditorConfig("root=true\r[*]\rindent_size=2")
        XCTAssertFalse(loneCR.isValid)
        XCTAssertFalse(loneCR.root)
        XCTAssertTrue(loneCR.sections.isEmpty)

        let invalidValues = parseEditorConfig(
            "root=true\nindent_size=3\n[*]\nindent_style=spaces\n"
                + "indent_size=0\ntab_width=17\nend_of_line=unix"
        )
        XCTAssertTrue(invalidValues.root)
        XCTAssertEqual(
            applyEditorConfig(EditorConfigProperties(), invalidValues, "file.ts"),
            EditorConfigProperties()
        )
        XCTAssertFalse(parseEditorConfig("[*]\nroot=true").root)

        let emptyValue = parseEditorConfig("[*]\nindent_size=")
        XCTAssertEqual(
            applyEditorConfig(
                EditorConfigProperties(indentSize: .columns(4)),
                emptyValue,
                "a"
            ).indentSize,
            .columns(4)
        )
        let lastValidValue = parseEditorConfig(
            "[*]\nindent_size=unset\nindent_size=3"
        )
        XCTAssertEqual(
            applyEditorConfig(
                EditorConfigProperties(indentSize: .columns(4)),
                lastValidValue,
                "a"
            ).indentSize,
            .columns(3)
        )
    }

    func testMalformedSectionDoesNotLeakAndParserLimitsAreBounded() {
        let invalidSection = parseEditorConfig(
            "[*]\nindent_size=8\n[bad[\nindent_size=2\n[*]\nindent_size=4"
        )
        XCTAssertEqual(
            applyEditorConfig(EditorConfigProperties(), invalidSection, "file.ts")
                .indentSize,
            .columns(4)
        )

        let tooManyLines = Array(repeating: "", count: 4_097).joined(separator: "\n")
        XCTAssertFalse(parseEditorConfig(tooManyLines).isValid)
        let tooManySections = (0..<257).map { "[file\($0)]" }.joined(separator: "\n")
        XCTAssertFalse(parseEditorConfig(tooManySections).isValid)
        XCTAssertNil(compileEditorConfigGlob(String(repeating: "x", count: 513)))
        XCTAssertNotNil(compileEditorConfigGlob(String(repeating: "x", count: 512)))

        // The TypeScript limit counts UTF-16 code units, not grapheme clusters.
        XCTAssertNil(compileEditorConfigGlob(String(repeating: "🙂", count: 257)))
    }

    func testCommonEditorConfigGlobSubset() {
        let matches: [(String, String)] = [
            ("*.ts", "src/deep/main.ts"),
            ("src/*.ts", "src/main.ts"),
            ("/src/*.ts", "src/main.ts"),
            ("src/**/*.ts", "src/main.ts"),
            ("src/**/*.ts", "src/deep/main.ts"),
            ("src/?.ts", "src/a.ts"),
            ("[ab].ts", "deep/a.ts"),
            ("[!ab].ts", "deep/c.ts"),
            ("[a-z].ts", "deep/b.ts"),
            ("[!a-z].ts", "deep/7.ts"),
            ("[-a].ts", "deep/-.ts"),
            ("[a-].ts", "deep/-.ts"),
            ("[a\\-z].ts", "deep/-.ts"),
            ("*.{js,ts,tsx}", "deep/main.tsx"),
            ("file\\?.ts", "file?.ts"),
            ("file\\*.ts", "file*.ts"),
            ("*.ts", "folder\\name.ts"),
            ("Makefile", "src/Makefile")
        ]
        for (pattern, path) in matches {
            XCTAssertTrue(
                editorConfigGlobMatches(pattern, path),
                "Expected \(pattern) to match \(path)"
            )
        }

        let misses: [(String, String)] = [
            ("*.ts", "src/deep/main.js"),
            ("src/*.ts", "src/deep/main.ts"),
            ("src/?.ts", "src/ab.ts"),
            ("[!ab].ts", "deep/a.ts"),
            ("[a-z].ts", "deep/7.ts"),
            ("[!a-z].ts", "deep/b.ts"),
            ("src\\*.ts", "src/main.ts"),
            ("folder/*.ts", "folder\\name.ts"),
            ("Makefile", "src/makefile"),
            ("*.TS", "src/a.ts")
        ]
        for (pattern, path) in misses {
            XCTAssertFalse(
                editorConfigGlobMatches(pattern, path),
                "Expected \(pattern) not to match \(path)"
            )
        }

        for invalid in [
            "", "bad[", "bad{a,b", "{1..3}", "file{1..3}.ts",
            "{single}", "{a,}", "{a,{b,c}}", "src/", "bad]", "bad}\\"
        ] {
            XCTAssertNil(compileEditorConfigGlob(invalid), invalid)
        }
    }

    func testGlobUsesJavaScriptUTF16CodeUnitSemantics() {
        // JavaScript regexes without the `u` flag see an emoji as two UTF-16
        // code units, and a decomposed grapheme as its two constituent units.
        XCTAssertFalse(editorConfigGlobMatches("?", "🙂"))
        XCTAssertTrue(editorConfigGlobMatches("??", "🙂"))
        XCTAssertFalse(editorConfigGlobMatches("?", "e\u{301}"))
        XCTAssertTrue(editorConfigGlobMatches("??", "e\u{301}"))
        XCTAssertTrue(editorConfigGlobMatches("*", "🙂"))
        XCTAssertFalse(editorConfigGlobMatches("[🙂]", "🙂"))
        XCTAssertTrue(editorConfigGlobMatches("{🙂,x}", "🙂"))
        XCTAssertTrue(editorConfigGlobMatches("é", "é"))
        XCTAssertFalse(editorConfigGlobMatches("é", "e\u{301}"))
        XCTAssertTrue(editorConfigGlobMatches("e?", "e\u{301}"))

        // Swift treats the ASCII metacharacter plus variation selector as one
        // Character. Tokenising UTF-16 must still recognise the metacharacter.
        XCTAssertTrue(editorConfigGlobMatches("?\u{fe0f}", "*\u{fe0f}"))
        XCTAssertTrue(editorConfigGlobMatches("*\u{fe0f}", "name\u{fe0f}"))
        XCTAssertFalse(editorConfigGlobMatches("*\u{fe0f}", "name"))

        // The configured length limit is likewise measured in UTF-16 units.
        XCTAssertNotNil(compileEditorConfigGlob(String(repeating: "🙂", count: 256)))
        XCTAssertNil(compileEditorConfigGlob(String(repeating: "🙂", count: 257)))
    }

    func testRelativePathsSupportPOSIXDrivesAndUNC() {
        XCTAssertEqual(editorConfigRelativePath("/repo", "/repo/src/a.ts"), "src/a.ts")
        XCTAssertNil(editorConfigRelativePath("/repo", "/repo2/a.ts"))
        XCTAssertNil(editorConfigRelativePath("/repo", "/repo"))
        XCTAssertEqual(
            editorConfigRelativePath(
                "C:\\Repo",
                "c:\\repo\\src\\A.ts",
                .win32
            ),
            "src/A.ts"
        )
        XCTAssertNil(editorConfigRelativePath("C:\\repo", "D:\\repo\\a.ts", .win32))
        XCTAssertNil(editorConfigRelativePath("C:\\repo", "C:\\repo2\\a.ts", .win32))
        XCTAssertEqual(
            editorConfigRelativePath(
                "\\\\server\\share\\repo",
                "\\\\SERVER\\SHARE\\repo\\src\\a.ts",
                .win32
            ),
            "src/a.ts"
        )
        XCTAssertNil(editorConfigRelativePath("/repo", "/../repo/a.ts"))
    }

    func testCascadeIsOrderIndependentAndHonoursRootAndUnset() {
        let parent = "[*]\nindent_style=space\nindent_size=2\ntab_width=4\nend_of_line=lf"
        let child = "[*.ts]\nindent_style=tab\nindent_size=tab\ntab_width=8\nend_of_line=crlf"
        let expected = EditorConfigProperties(
            indentStyle: .tab,
            indentSize: .tab,
            tabWidth: 8,
            endOfLine: .crlf
        )
        XCTAssertEqual(
            applyEditorConfigChain([
                EditorConfigSource(path: "/repo/.editorconfig", source: parent),
                EditorConfigSource(path: "/repo/src/.editorconfig", source: child)
            ], "/repo/src/main.ts"),
            expected
        )
        XCTAssertEqual(
            applyEditorConfigChain([
                EditorConfigSource(path: "/repo/src/.editorconfig", source: child),
                EditorConfigSource(path: "/repo/.editorconfig", source: parent)
            ], "/repo/src/main.ts"),
            expected
        )

        XCTAssertEqual(
            applyEditorConfigChain([
                EditorConfigSource(path: "/repo/.editorconfig", source: parent),
                EditorConfigSource(
                    path: "/repo/src/.editorconfig",
                    source: "root=true\n[*.ts]\nindent_size=4"
                )
            ], "/repo/src/main.ts"),
            EditorConfigProperties(indentSize: .columns(4))
        )
        XCTAssertEqual(
            applyEditorConfigChain([
                EditorConfigSource(path: "/repo/.editorconfig", source: parent),
                EditorConfigSource(
                    path: "/repo/src/.editorconfig",
                    source: "[*.ts]\nindent_size=unset\nend_of_line=unset"
                )
            ], "/repo/src/main.ts"),
            EditorConfigProperties(indentStyle: .space, tabWidth: 4)
        )
        XCTAssertEqual(
            applyEditorConfigChain([
                EditorConfigSource(
                    path: "C:\\Repo\\.editorconfig",
                    source: "[src/**.ts]\nindent_size=2"
                )
            ], "c:\\repo\\src\\Main.ts", .win32).indentSize,
            .columns(2)
        )
    }

    func testIndentationResolutionMatchesEditorPrecedence() {
        XCTAssertEqual(
            resolveEditorConfigIndentation(
                EditorConfigProperties(
                    indentStyle: .tab, indentSize: .tab, tabWidth: 8
                ),
                IndentationPreferences(indentSize: 2, insertSpaces: true),
                4
            ),
            IndentationPreferences(indentSize: 8, tabWidth: 8, insertSpaces: false)
        )
        XCTAssertEqual(
            resolveEditorConfigIndentation(
                EditorConfigProperties(
                    indentStyle: .space, indentSize: .columns(2), tabWidth: 8
                ),
                IndentationPreferences(indentSize: 4, insertSpaces: false),
                4
            ),
            IndentationPreferences(indentSize: 2, tabWidth: 8, insertSpaces: true)
        )
        XCTAssertEqual(
            resolveEditorConfigIndentation(
                EditorConfigProperties(
                    indentStyle: .tab, indentSize: .columns(4), tabWidth: 8
                ),
                IndentationPreferences(indentSize: 2, insertSpaces: true),
                4
            ),
            IndentationPreferences(indentSize: 8, tabWidth: 8, insertSpaces: false)
        )
        XCTAssertEqual(
            resolveEditorConfigIndentation(
                EditorConfigProperties(tabWidth: 6),
                IndentationPreferences(indentSize: 3, insertSpaces: false),
                4
            ),
            IndentationPreferences(indentSize: 6, tabWidth: 6, insertSpaces: false)
        )
        XCTAssertEqual(
            resolveEditorConfigIndentation(
                EditorConfigProperties(indentSize: .tab),
                IndentationPreferences(indentSize: 2, insertSpaces: true),
                4
            ),
            IndentationPreferences(indentSize: 4, tabWidth: 4, insertSpaces: true)
        )
    }

    func testSafeResolverAppliesNestedFilesAndStopsAtRootDeclaration() throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let target = nested.appendingPathComponent("main.swift")
        try write("print(1)", to: target)
        try write(
            "[*]\nindent_style=space\nindent_size=2\ntab_width=4\nend_of_line=lf",
            to: root.appendingPathComponent(".editorconfig")
        )
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try write("[*.swift]\ntab_width=6", to: sources.appendingPathComponent(".editorconfig"))
        try write(
            "root=true\n[*.swift]\nindent_style=tab\nindent_size=tab\nend_of_line=crlf",
            to: nested.appendingPathComponent(".editorconfig")
        )

        let resolved = try resolveEditorConfig(for: target, workspaceRoot: root)

        XCTAssertFalse(resolved.isTruncated)
        XCTAssertEqual(resolved.sources, [nested.appendingPathComponent(".editorconfig")])
        XCTAssertEqual(
            resolved.properties,
            EditorConfigProperties(
                indentStyle: .tab,
                indentSize: .tab,
                endOfLine: .crlf
            )
        )
    }

    func testSafeResolverReturnsSourcesOutermostToInnermost() throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let target = nested.appendingPathComponent("main.swift")
        try write("print(1)", to: target)
        let rootConfig = root.appendingPathComponent(".editorconfig")
        let childConfig = root.appendingPathComponent("Sources/.editorconfig")
        try write("[*]\nindent_size=2\nend_of_line=lf", to: rootConfig)
        try write("[*.swift]\nindent_size=4", to: childConfig)

        let resolved = try EditorConfig.resolve(for: target, workspaceRoot: root)

        XCTAssertEqual(resolved.sources, [rootConfig, childConfig])
        XCTAssertEqual(resolved.indentSize, .columns(4))
        XCTAssertEqual(resolved.endOfLine, .lf)
    }

    func testSafeResolverRejectsLexicalAndResolvedWorkspaceEscapes() throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("workspace", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideFile = outside.appendingPathComponent("secret.swift")
        try write("secret", to: outsideFile)

        XCTAssertThrowsError(try EditorConfig.resolve(for: outsideFile, workspaceRoot: root)) { error in
            XCTAssertEqual(
                error as? EditorConfigResolutionError,
                .targetOutsideWorkspace(outsideFile)
            )
        }

        let link = root.appendingPathComponent("linked.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try EditorConfig.resolve(for: link, workspaceRoot: root)) { error in
            XCTAssertEqual(
                error as? EditorConfigResolutionError,
                .symbolicLinkEscapesWorkspace(link)
            )
        }
    }

    func testSafeResolverAcceptsCallerProvidedSymlinkRootButKeepsItsBoundary() throws {
        let container = try makeTemporaryDirectory()
        let physicalRoot = container.appendingPathComponent("physical", isDirectory: true)
        let logicalRoot = container.appendingPathComponent("logical", isDirectory: true)
        try FileManager.default.createDirectory(
            at: physicalRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: logicalRoot,
            withDestinationURL: physicalRoot
        )
        let target = logicalRoot.appendingPathComponent("main.swift")
        try write("print(1)", to: physicalRoot.appendingPathComponent("main.swift"))
        try write(
            "[*]\nindent_size=5",
            to: physicalRoot.appendingPathComponent(".editorconfig")
        )

        let resolved = try EditorConfig.resolve(for: target, workspaceRoot: logicalRoot)

        XCTAssertEqual(resolved.indentSize, .columns(5))
        XCTAssertEqual(
            resolved.sources,
            [logicalRoot.appendingPathComponent(".editorconfig")]
        )
    }

    func testSafeResolverRejectsConfigSymlinksAndInvalidUTF8() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("main.swift")
        let actualConfig = root.appendingPathComponent("actual-config")
        let config = root.appendingPathComponent(".editorconfig")
        try write("print(1)", to: target)
        try write("[*]\nindent_size=2", to: actualConfig)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: actualConfig)

        let linked = try EditorConfig.resolve(for: target, workspaceRoot: root)
        XCTAssertEqual(linked, ResolvedEditorConfig())

        try FileManager.default.removeItem(at: config)
        try Data([0xff, 0xfe]).write(to: config, options: [.withoutOverwriting])
        let malformed = try EditorConfig.resolve(for: target, workspaceRoot: root)
        XCTAssertTrue(malformed.isTruncated)
        XCTAssertTrue(malformed.sources.isEmpty)
        XCTAssertEqual(malformed.properties, EditorConfigProperties())
    }

    func testSafeResolverSupportsMissingTargetButNotEscapingParent() throws {
        let container = try makeTemporaryDirectory()
        let root = container.appendingPathComponent("workspace", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try write("[*]\nindent_size=3", to: root.appendingPathComponent(".editorconfig"))

        let missing = nested.appendingPathComponent("new.swift")
        XCTAssertEqual(
            try EditorConfig.resolve(
                for: missing,
                workspaceRoot: root,
                allowMissingTarget: true
            ).indentSize,
            .columns(3)
        )

        let outsideLink = root.appendingPathComponent("outside-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: outside)
        let escaping = outsideLink.appendingPathComponent("new.swift")
        XCTAssertThrowsError(
            try EditorConfig.resolve(
                for: escaping,
                workspaceRoot: root,
                allowMissingTarget: true
            )
        ) { error in
            XCTAssertEqual(
                error as? EditorConfigResolutionError,
                .symbolicLinkEscapesWorkspace(escaping)
            )
        }
    }

    func testSafeResolverEnforcesFileTotalAndDepthLimits() throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("one/two", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let target = nested.appendingPathComponent("main.swift")
        try write("print(1)", to: target)
        let config = nested.appendingPathComponent(".editorconfig")
        try write("[*]\nindent_size=2", to: config)

        let tooLarge = try EditorConfig.resolve(
            for: target,
            workspaceRoot: root,
            limits: EditorConfigLimits(maximumFileBytes: 10)
        )
        XCTAssertTrue(tooLarge.isTruncated)
        XCTAssertTrue(tooLarge.sources.isEmpty)
        XCTAssertEqual(tooLarge.properties, EditorConfigProperties())

        try FileManager.default.removeItem(at: config)
        let first = "[*]\nindent_size=2\n#12345678901234567890"
        let second = "[*.swift]\ntab_width=4\n#12345678901234567890"
        try write(first, to: root.appendingPathComponent(".editorconfig"))
        try write(second, to: root.appendingPathComponent("one/.editorconfig"))
        let totalLimited = try EditorConfig.resolve(
            for: target,
            workspaceRoot: root,
            limits: EditorConfigLimits(maximumFileBytes: 64, maximumTotalBytes: 70)
        )
        XCTAssertTrue(totalLimited.isTruncated)
        XCTAssertTrue(totalLimited.sources.isEmpty)

        let depthLimited = try EditorConfig.resolve(
            for: target,
            workspaceRoot: root,
            limits: EditorConfigLimits(maximumLevels: 1)
        )
        XCTAssertTrue(depthLimited.isTruncated)
        XCTAssertTrue(depthLimited.sources.isEmpty)
    }

    func testSafeResolverHonoursExactByteLimitAndRejectsOversizeDefaultConfig() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("main.swift")
        let config = root.appendingPathComponent(".editorconfig")
        try write("print(1)", to: target)

        let exact = "[*]\nindent_size=2"
        try write(exact, to: config)
        let exactResult = try EditorConfig.resolve(
            for: target,
            workspaceRoot: root,
            limits: EditorConfigLimits(maximumFileBytes: exact.utf8.count)
        )
        XCTAssertFalse(exactResult.isTruncated)
        XCTAssertEqual(exactResult.indentSize, .columns(2))

        try FileManager.default.removeItem(at: config)
        try Data(repeating: 0x20, count: 64 * 1_024 + 1).write(
            to: config,
            options: [.withoutOverwriting]
        )
        let oversized = try EditorConfig.resolve(for: target, workspaceRoot: root)
        XCTAssertTrue(oversized.isTruncated)
        XCTAssertEqual(oversized.properties, EditorConfigProperties())
        XCTAssertTrue(oversized.sources.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorConfigTests-\(UUID().uuidString)", isDirectory: true)
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
}
