import Foundation
import XCTest
@testable import LumenEditorCore

final class CommandCatalogTests: XCTestCase {
    func testCatalogContainsTheCompleteUniqueCommandAndMenuUnion() {
        let expectedIDs = Set("""
        new-file open-file open-file-with-encoding open-folder copy-file-path
        copy-relative-file-path open-recent-file save save-as save-all
        select-line-ending select-encoding reopen-with-encoding toggle-pin-tab close-tab
        close-other-tabs close-tabs-to-right close-all-tabs reopen-tab goto-anything
        goto-symbol goto-project-symbol go-to-line goto-matching-bracket navigate-back
        navigate-forward find find-next find-previous replace find-in-files
        replace-in-files undo-replace-in-files find-results-next find-results-prev next-change
        prev-change revert-current-change toggle-comment toggle-block-comment add-cursor-above
        add-cursor-below undo-selection redo-selection select-next-occurrence skip-current-occurrence
        remove-last-cursor select-all-occurrences add-cursors-line-starts add-cursors-line-ends select-line
        select-matching-bracket select-parent-syntax expand-selection shrink-selection move-line-up
        move-line-down copy-line-up copy-line-down duplicate-selection delete-line
        delete-word-backward delete-word-forward delete-to-line-start delete-to-line-end insert-blank-line-above
        insert-blank-line transpose-characters sort-lines sort-lines-descending reverse-lines
        unique-lines remove-blank-lines toggle-bookmark next-bookmark prev-bookmark
        record-macro run-macro save-macro run-saved-macro insert-snippet
        select-language toggle-preview open-in-browser toggle-sidebar reveal-active-file-in-sidebar
        split-editor split-selected-tabs toggle-line-numbers toggle-minimap toggle-whitespace
        toggle-outline fold-current unfold-current fold-all unfold-all
        toggle-distraction-free cycle-auto-save toggle-spell-check format-json compact-json
        toggle-json-view toggle-word-wrap toggle-theme font-zoom-in font-zoom-out
        font-zoom-reset build toggle-terminal document-statistics import-sublime-build
        format-document trim-trailing-whitespace ensure-single-final-newline convert-indent-spaces convert-indent-tabs
        convert-eol-lf convert-eol-crlf convert-eol-cr to-upper-case to-lower-case
        to-title-case swap-case join-lines wrap-paragraph-80 unwrap-paragraph
        split-selection-lines indent-selection outdent-selection reindent-selection toggle-problems
        select-color-scheme toggle-git refresh-git open-git-conflicts check-for-updates
        open-marketplace project-settings language-tools install-plugin manage-plugins
        next-tab prev-tab layout-single layout-columns2 layout-columns3
        layout-grid4 move-file-next-group clone-file-next-group focus-next-group focus-prev-group
        new-window add-folder-to-project remove-folder-from-project open-recent-project import-sublime-project
        import-sublime-settings import-sublime-snippet import-sublime-keymap set-ui-language-zh set-ui-language-en
        open-settings lsp-hover lsp-definition lsp-references lsp-rename
        toggle-language-servers command-palette select-build-system
        """.split(whereSeparator: \.isWhitespace).map(String.init))
        let actualIDs = CommandCatalog.all.map(\.id)

        XCTAssertEqual(CommandCatalog.all.count, 169)
        XCTAssertEqual(Set(actualIDs).count, actualIDs.count, "Command IDs must be unique")
        XCTAssertEqual(Set(actualIDs), expectedIDs)
    }

    func testCatalogCarriesLocalizedTitlesCategoriesAndLookup() throws {
        let command = try XCTUnwrap(CommandCatalog.command(id: "save-as"))

        XCTAssertEqual(command.category, .file)
        XCTAssertEqual(command.englishName, "Save As…")
        XCTAssertEqual(command.chineseName, "另存为…")
        XCTAssertEqual(command.title(for: .english), "File: Save As…")
        XCTAssertEqual(command.title(for: .simplifiedChinese), "文件：另存为…")
        XCTAssertNil(CommandCatalog.command(id: "not-a-command"))
        XCTAssertTrue(CommandCatalog.commands(in: .git).allSatisfy { $0.category == .git })
    }

    func testContextRequirementsDistinguishDocumentAndWorkspaceCommands() throws {
        let save = try XCTUnwrap(CommandCatalog.command(id: "save"))
        XCTAssertTrue(save.requiresDocument)
        XCTAssertFalse(save.requiresWorkspace)

        let search = try XCTUnwrap(CommandCatalog.command(id: "find-in-files"))
        XCTAssertFalse(search.requiresDocument)
        XCTAssertTrue(search.requiresWorkspace)

        let relativePath = try XCTUnwrap(CommandCatalog.command(id: "copy-relative-file-path"))
        XCTAssertTrue(relativePath.requiresDocument)
        XCTAssertTrue(relativePath.requiresWorkspace)
        XCTAssertTrue(relativePath.requirements.contains(.savedDocument))

        let lsp = try XCTUnwrap(CommandCatalog.command(id: "lsp-definition"))
        XCTAssertTrue(lsp.requirements.contains([.savedDocument, .workspace]))
        XCTAssertFalse(lsp.requirements.contains(.languageService))

        let lspRename = try XCTUnwrap(CommandCatalog.command(id: "lsp-rename"))
        XCTAssertTrue(lspRename.requirements.contains(.languageService))

        let browser = try XCTUnwrap(CommandCatalog.command(id: "open-in-browser"))
        XCTAssertTrue(browser.requiresDocument)
        XCTAssertFalse(browser.requirements.contains(.savedDocument))
    }

    func testDefaultKeyEquivalentsComeOnlyFromMenuAccelerators() throws {
        XCTAssertEqual(CommandCatalog.all.filter { $0.defaultKeyEquivalent != nil }.count, 78)

        let palette = try XCTUnwrap(CommandCatalog.command(id: "command-palette"))
        XCTAssertEqual(
            palette.defaultKeyEquivalent,
            CommandKeyEquivalent(key: "p", modifiers: [.command, .shift])
        )
        XCTAssertEqual(palette.displayShortcut, "⇧⌘P")

        let redoSelection = try XCTUnwrap(CommandCatalog.command(id: "redo-selection"))
        XCTAssertEqual(
            redoSelection.defaultKeyEquivalent,
            CommandKeyEquivalent(key: "u", modifiers: [.command, .shift])
        )

        // commands.ts advertises this CodeMirror binding, but menu.ts has no
        // accelerator for it. The UI can show it without routing it twice.
        let fold = try XCTUnwrap(CommandCatalog.command(id: "fold-current"))
        XCTAssertEqual(fold.displayShortcut, "⌘⌥[")
        XCTAssertNil(fold.defaultKeyEquivalent)

        let deleteWord = try XCTUnwrap(CommandCatalog.command(id: "delete-word-backward"))
        XCTAssertEqual(deleteWord.displayShortcut, "⌥⌫")
        XCTAssertNil(deleteWord.defaultKeyEquivalent)

        XCTAssertNil(CommandCatalog.command(id: "select-build-system")?.defaultKeyEquivalent)
    }

    func testFuzzyScoreMatchesTypeScriptPort() throws {
        XCTAssertEqual(CommandFuzzyMatcher.score(query: "", text: "anything"), FuzzyResult(score: 1, matches: []))
        XCTAssertNil(CommandFuzzyMatcher.score(query: "xyz", text: "xylophone"))

        let consecutive = try XCTUnwrap(CommandFuzzyMatcher.score(query: "fb", text: "foobar"))
        XCTAssertEqual(consecutive.matches, [0, 3])
        XCTAssertEqual(consecutive.score, 32.4, accuracy: 0.000_001)

        let boundary = try XCTUnwrap(CommandFuzzyMatcher.score(query: "fb", text: "foo bar"))
        XCTAssertEqual(boundary.matches, [0, 4])
        XCTAssertEqual(boundary.score, 41.3, accuracy: 0.000_001)

        let camelCase = try XCTUnwrap(CommandFuzzyMatcher.score(query: "fb", text: "fooBar"))
        XCTAssertEqual(camelCase.matches, [0, 3])
        XCTAssertEqual(camelCase.score, 40.4, accuracy: 0.000_001)
        XCTAssertNotNil(CommandFuzzyMatcher.score(query: "保存", text: "文件：保存"))

        let supplementaryPlane = try XCTUnwrap(
            CommandFuzzyMatcher.score(query: "😀b", text: "😀ab")
        )
        XCTAssertEqual(supplementaryPlane.matches, [0, 1, 3])
        XCTAssertEqual(supplementaryPlane.score, 48.6, accuracy: 0.000_001)
    }

    func testFuzzyFilterSortsByScoreAndKeepsStableTies() {
        let source = ["foo_bar", "foobar", "foo bar", "not a match"]
        let results = CommandFuzzyMatcher.filter(query: "fb", items: source) { $0 }

        XCTAssertEqual(results.map { $0.item }, ["foo_bar", "foo bar", "foobar"])

        let tied = CommandFuzzyMatcher.filter(query: "a", items: ["ab", "ac"]) { $0 }
        XCTAssertEqual(tied.map { $0.item }, ["ab", "ac"])
    }

    func testCatalogSearchUsesLocalizedFullTitles() {
        let english = CommandCatalog.search("save as", locale: .english)
        XCTAssertEqual(english.first?.command.id, "save-as")
        XCTAssertFalse(english.first?.result.matches.isEmpty ?? true)

        let chinese = CommandCatalog.search("保存编码", locale: .simplifiedChinese)
        XCTAssertEqual(chinese.first?.command.id, "select-encoding")
    }

    func testKeyBindingOverridesCanReplaceScopeChordAndUnbind() throws {
        XCTAssertEqual(
            CommandCatalog.keyBinding(for: "save", overrides: [])?.singleKeyEquivalent,
            CommandKeyEquivalent(key: "s", modifiers: .command)
        )

        let chord = CommandKeyBinding(sequence: [
            CommandKeyEquivalent(key: "k", modifiers: .command),
            CommandKeyEquivalent(key: "s", modifiers: .command)
        ])
        let overrides = [
            KeyBindingOverride(commandID: "save", binding: chord, when: .editor),
            KeyBindingOverride.unbind("save", when: .build)
        ]
        XCTAssertEqual(
            CommandCatalog.keyBinding(for: "save", overrides: overrides, context: .editor),
            chord
        )
        XCTAssertNil(CommandCatalog.keyBinding(for: "save", overrides: overrides, context: .build))
        XCTAssertEqual(
            CommandCatalog.keyBinding(for: "save", overrides: overrides, context: .git)?.singleKeyEquivalent,
            CommandKeyEquivalent(key: "s", modifiers: .command)
        )

        let data = try JSONEncoder().encode(overrides)
        XCTAssertEqual(try JSONDecoder().decode([KeyBindingOverride].self, from: data), overrides)
    }
}
