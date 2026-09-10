import AppKit
import LumenEditorCore
import SwiftUI

@MainActor
struct EditorCommands: Commands {
    /// Public catalog routes intentionally surfaced in the File menu. Keeping
    /// this list as data makes menu discoverability testable without duplicating
    /// either route's implementation.
    static let fileRecentCommandIDs = [
        "open-recent-file",
        "open-recent-project"
    ]

    /// macOS 14's SwiftUI Commands API has no full-screen ButtonRole or
    /// dedicated command-group placement, so preserve the standard AppKit
    /// responder-chain action and its conventional shortcut explicitly.
    static var toggleFullScreenAction: Selector {
        #selector(NSWindow.toggleFullScreen(_:))
    }
    static let toggleFullScreenShortcut = KeyboardShortcut(
        "f", modifiers: [.control, .command]
    )

    let newWindow: () -> Void
    @ObservedObject var model: AppModel
    @ObservedObject var actions: EditorActionController
    @ObservedObject var settings: SettingsController
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var router: CommandRouter
    @ObservedObject var workspaceSearch: WorkspaceSearchController
    @ObservedObject var git: GitController
    @ObservedObject var build: BuildController
    @ObservedObject var terminal: TerminalController
    @ObservedObject var navigation: NavigationController
    @ObservedObject var languageServers: LanguageServerController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(text("New Window", zh: "新建窗口"), action: newWindow)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(hasBlockingInteraction)
                .accessibilityIdentifier(AppAccessibility.id("menu command new-window"))

            Divider()

            routedButton("New Document", commandID: "new-file")
                .keyboardShortcut("n", modifiers: .command)

            routedButton("Open…", commandID: "open-file")
                .keyboardShortcut("o", modifiers: .command)

            Menu(text("Open Using Encoding", zh: "以编码打开")) {
                ForEach(TextEncoding.allCases, id: \.rawValue) { encoding in
                    Button(encoding.displayName) {
                        Task { await actions.openDocuments(forcedEncoding: encoding) }
                    }
                    .accessibilityLabel(text(
                        "Open using \(encoding.displayName)",
                        zh: "使用 \(encoding.displayName) 打开"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id(
                        "menu open encoding \(encoding.rawValue)"
                    ))
                }
            }
            .disabled(hasBlockingInteraction)
            .accessibilityIdentifier(AppAccessibility.id("menu open using encoding"))

            Divider()

            routedButton("Open Folder…", commandID: "open-folder")
                .keyboardShortcut("o", modifiers: [.command, .shift])

            ForEach(Self.fileRecentCommandIDs, id: \.self) { commandID in
                routedCatalogButton(commandID)
            }

            routedButton(
                "Add Folder to Workspace…",
                commandID: "add-folder-to-project"
            )
        }

        CommandGroup(replacing: .saveItem) {
            routedButton("Save", commandID: "save")
                .keyboardShortcut("s", modifiers: .command)

            routedButton("Save As…", commandID: "save-as")
                .keyboardShortcut("s", modifiers: [.command, .shift])

            routedButton("Save All", commandID: "save-all")
                .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            routedButton("Cycle Auto Save Mode", commandID: "cycle-auto-save")
        }

        CommandGroup(replacing: .undoRedo) {
            Button(localized(.undo)) {
                actions.undoCurrentDocument()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!actions.canUndoCurrentDocument)
            .accessibilityIdentifier(AppAccessibility.id("menu command undo"))

            Button(localized(.redo)) {
                actions.redoCurrentDocument()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!actions.canRedoCurrentDocument)
            .accessibilityIdentifier(AppAccessibility.id("menu command redo"))
        }

        CommandGroup(after: .saveItem) {
            Divider()
            routedButton("Close Tab", commandID: "close-tab")
                .keyboardShortcut("w", modifiers: .command)
        }

        CommandMenu(text("Document", zh: "文档")) {
            routedButton("Open Using Encoding…", commandID: "open-file-with-encoding")
            routedButton("Copy File Path", commandID: "copy-file-path")
            routedButton("Copy Relative File Path", commandID: "copy-relative-file-path")
            routedButton("Pin / Unpin Tab", commandID: "toggle-pin-tab")
            routedButton("Close Other Tabs", commandID: "close-other-tabs")
            routedButton("Close Tabs to the Right", commandID: "close-tabs-to-right")
            routedButton("Close All Tabs", commandID: "close-all-tabs")
            routedButton("Reopen Closed Tab", commandID: "reopen-tab")
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()

            Menu(text("Save Encoding", zh: "保存编码")) {
                ForEach(TextEncoding.allCases, id: \.rawValue) { encoding in
                    Button {
                        if let document = model.selectedDocument {
                            actions.chooseEncodingForSave(encoding, document: document)
                        }
                    } label: {
                        Label(
                            encoding.displayName,
                            systemImage: model.selectedDocument?.encoding == encoding
                                ? "checkmark"
                                : "circle.dashed"
                        )
                    }
                    .accessibilityLabel(encoding.displayName)
                    .accessibilityValue(
                        model.selectedDocument?.encoding == encoding
                            ? localized(.current) : ""
                    )
                    .accessibilityIdentifier(AppAccessibility.id(
                        "menu save encoding \(encoding.rawValue)"
                    ))
                }
            }
            .disabled(!canChangeFormat)
            .accessibilityIdentifier(AppAccessibility.id("menu save encoding"))

            Menu(text("Line Endings", zh: "换行符")) {
                ForEach(LineEnding.allCases, id: \.rawValue) { lineEnding in
                    Button {
                        if let document = model.selectedDocument {
                            actions.chooseLineEndingForSave(lineEnding, document: document)
                        }
                    } label: {
                        Label(
                            lineEnding.rawValue,
                            systemImage: model.selectedDocument?.lineEnding == lineEnding
                                ? "checkmark"
                                : "circle.dashed"
                        )
                    }
                    .accessibilityLabel(lineEnding.rawValue)
                    .accessibilityValue(
                        model.selectedDocument?.lineEnding == lineEnding
                            ? localized(.current) : ""
                    )
                    .accessibilityIdentifier(AppAccessibility.id(
                        "menu line ending \(lineEnding.rawValue)"
                    ))
                }
            }
            .disabled(!canChangeFormat)
            .accessibilityIdentifier(AppAccessibility.id("menu line endings"))

            Menu(text("Reopen Using Encoding", zh: "以编码重新打开")) {
                ForEach(TextEncoding.allCases, id: \.rawValue) { encoding in
                    Button(encoding.displayName) {
                        if let document = model.selectedDocument {
                            actions.requestReopen(document, using: encoding)
                        }
                    }
                    .accessibilityLabel(text(
                        "Reopen using \(encoding.displayName)",
                        zh: "使用 \(encoding.displayName) 重新打开"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id(
                        "menu reopen encoding \(encoding.rawValue)"
                    ))
                }
            }
            .disabled(!canChangeFormat || model.selectedDocument?.isUntitled != false)
            .accessibilityIdentifier(AppAccessibility.id("menu reopen using encoding"))

            Divider()

            Button(text("Check for External Changes", zh: "检查外部更改")) {
                Task { await actions.checkForExternalChanges() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(hasBlockingInteraction)
            .accessibilityIdentifier(AppAccessibility.id("menu check external changes"))
        }

        CommandMenu(localized(.find)) {
            routedButton("Find…", commandID: "find")
                .keyboardShortcut("f", modifiers: .command)
            routedButton("Replace…", commandID: "replace")
                .keyboardShortcut("h", modifiers: .command)
            routedButton("Find Next", commandID: "find-next")
            routedButton("Find Previous", commandID: "find-previous")
            Divider()
            routedButton(
                "Find in Files…", commandID: "find-in-files",
                accessibilityID: "menu find find-in-files"
            )
            routedButton(
                "Replace in Files…", commandID: "replace-in-files",
                accessibilityID: "menu find replace-in-files"
            )
        }

        CommandMenu(text("Navigate", zh: "导航")) {
            routedButton("Goto Anything…", commandID: "goto-anything")
                .keyboardShortcut("p", modifiers: .command)
            routedButton("Goto Symbol…", commandID: "goto-symbol")
                .keyboardShortcut("r", modifiers: .command)
            routedButton("Goto Project Symbol…", commandID: "goto-project-symbol")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            routedButton("Goto Line…", commandID: "go-to-line")
                .keyboardShortcut("g", modifiers: .command)
            Divider()
            routedButton("Back", commandID: "navigate-back")
            routedButton("Forward", commandID: "navigate-forward")
            routedButton("Goto Matching Bracket", commandID: "goto-matching-bracket")
            Divider()
            routedButton("Toggle Bookmark", commandID: "toggle-bookmark")
            routedButton("Next Bookmark", commandID: "next-bookmark")
            routedButton("Previous Bookmark", commandID: "prev-bookmark")
            Divider()
            routedButton("Next Change", commandID: "next-change")
            routedButton("Previous Change", commandID: "prev-change")
        }

        CommandMenu(localized(.selection)) {
            ForEach(selectionCommandIDs, id: \.self) { commandID in
                routedCatalogButton(commandID)
            }
        }

        CommandMenu(text("Text", zh: "文本")) {
            ForEach(textCommandIDs, id: \.self) { commandID in
                routedCatalogButton(commandID)
            }
        }

        CommandMenu(text("Workspace", zh: "工作区")) {
            routedButton(
                "Find in Files…", commandID: "find-in-files",
                accessibilityID: "menu workspace find-in-files"
            )
                .keyboardShortcut("f", modifiers: [.command, .shift])
            routedButton(
                "Replace in Files…", commandID: "replace-in-files",
                accessibilityID: "menu workspace replace-in-files"
            )
                .keyboardShortcut("h", modifiers: [.command, .shift])
            routedButton(
                "Undo Last Replace in Files",
                commandID: "undo-replace-in-files"
            )
            routedButton("Next Search Result", commandID: "find-results-next")
            routedButton("Previous Search Result", commandID: "find-results-prev")

            Divider()

            routedButton("Show Git Changes", commandID: "toggle-git")
            routedButton("Refresh Git Changes", commandID: "refresh-git")
            routedButton("Open Merge Conflicts", commandID: "open-git-conflicts")
            routedButton("Revert Current Change", commandID: "revert-current-change")

            Divider()

            routedButton("Build…", commandID: "build")
                .keyboardShortcut("b", modifiers: [.command, .shift])
            routedButton("Show Build Output", commandID: "toggle-problems")
            routedButton("Project Terminal", commandID: "toggle-terminal")
                .keyboardShortcut("t", modifiers: [.command, .option])
            routedButton("Select Build System…", commandID: "select-build-system")
            routedButton("Configure Project…", commandID: "project-settings")
            routedButton("Remove Folder from Project…", commandID: "remove-folder-from-project")

            Divider()

            routedButton("Markdown Preview", commandID: "toggle-preview")
            routedButton("Open in Browser", commandID: "open-in-browser")
            routedButton("Format JSON", commandID: "format-json")
            routedButton("Compact JSON", commandID: "compact-json")
            routedButton("JSON View", commandID: "toggle-json-view")
            routedButton("Document Statistics", commandID: "document-statistics")
            routedButton("Format Document", commandID: "format-document")

            Divider()

            routedButton("Language Servers", commandID: "toggle-language-servers")
            routedButton("Show Hover", commandID: "lsp-hover")
            routedButton("Go to Definition", commandID: "lsp-definition")
            routedButton("Find References", commandID: "lsp-references")
            routedButton("Rename Symbol…", commandID: "lsp-rename")
            routedButton("Configure Language Tool…", commandID: "language-tools")

            Divider()

            routedButton("Install Local Plugin…", commandID: "install-plugin")
            routedButton("Manage Plugins…", commandID: "manage-plugins")
            routedButton("Plugin Marketplace…", commandID: "open-marketplace")

            Divider()

            routedButton("Import Sublime Project…", commandID: "import-sublime-project")
            routedButton("Import Sublime Settings…", commandID: "import-sublime-settings")
            routedButton("Import Sublime Keymap…", commandID: "import-sublime-keymap")
            routedButton("Import Sublime Snippet…", commandID: "import-sublime-snippet")
            routedButton("Import Sublime Build System…", commandID: "import-sublime-build")

            Divider()

            routedButton("Start / Stop Macro Recording", commandID: "record-macro")
            routedButton("Run Last Macro", commandID: "run-macro")
            routedButton("Save Last Macro…", commandID: "save-macro")
            routedButton("Run Saved Macro…", commandID: "run-saved-macro")
            routedButton("Insert Snippet…", commandID: "insert-snippet")
        }

        CommandGroup(after: .toolbar) {
            routedButton("Command Palette…", commandID: "command-palette")
                .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            routedButton("Toggle Sidebar", commandID: "toggle-sidebar")
                .keyboardShortcut("b", modifiers: .command)

            routedButton(
                "Reveal Active File in Sidebar",
                commandID: "reveal-active-file-in-sidebar"
            )

            routedButton("Set Syntax…", commandID: "select-language")

            Divider()

            Menu(text("Editor Layout", zh: "编辑器布局")) {
                layoutButton("Single", kind: .single, commandID: "layout-single")
                layoutButton("Two Columns", kind: .columns2, commandID: "layout-columns2")
                layoutButton("Three Columns", kind: .columns3, commandID: "layout-columns3")
                layoutButton("Grid (4 Panes)", kind: .grid4, commandID: "layout-grid4")
            }
            .disabled(hasBlockingInteraction)
            .accessibilityIdentifier(AppAccessibility.id("menu editor layout"))

            routedButton("Toggle Split Editor", commandID: "split-editor")
                .keyboardShortcut("2", modifiers: [.command, .option])
            routedButton("Split Selected Tabs into Groups", commandID: "split-selected-tabs")

            routedButton("Move File to Next Pane", commandID: "move-file-next-group")
            routedButton("Clone File to Next Pane", commandID: "clone-file-next-group")

            routedButton("Focus Next Pane", commandID: "focus-next-group")
                .keyboardShortcut("]", modifiers: [.command, .option])
            routedButton("Focus Previous Pane", commandID: "focus-prev-group")
                .keyboardShortcut("[", modifiers: [.command, .option])

            routedButton("Next Tab", commandID: "next-tab")
            routedButton("Previous Tab", commandID: "prev-tab")

            Divider()

            Toggle(
                text("Show Line Numbers", zh: "显示行号"),
                isOn: routedToggleBinding(
                    commandID: "toggle-line-numbers",
                    value: settings.settings.showLineNumbers
                )
            )
            .disabled(routeIsDisabled("toggle-line-numbers"))
            .accessibilityIdentifier(AppAccessibility.id("menu command toggle line numbers"))

            Toggle(
                text("Word Wrap", zh: "自动换行"),
                isOn: routedToggleBinding(
                    commandID: "toggle-word-wrap",
                    value: settings.settings.wordWrap
                )
            )
                .keyboardShortcut("z", modifiers: .option)
                .disabled(routeIsDisabled("toggle-word-wrap"))
                .accessibilityIdentifier(AppAccessibility.id("menu command toggle word wrap"))
            routedButton("Toggle Theme", commandID: "toggle-theme")
                .keyboardShortcut("k", modifiers: .command)
            routedButton("Select Color Scheme…", commandID: "select-color-scheme")
            Toggle(
                text("Spell Check", zh: "拼写检查"),
                isOn: routedToggleBinding(
                    commandID: "toggle-spell-check",
                    value: settings.settings.spellCheck
                )
            )
            .disabled(routeIsDisabled("toggle-spell-check"))
            .accessibilityIdentifier(AppAccessibility.id("menu command toggle spell check"))

            Toggle(
                text("Show Minimap", zh: "显示缩略图"),
                isOn: routedToggleBinding(
                    commandID: "toggle-minimap",
                    value: settings.settings.showMinimap
                )
            )
            .disabled(routeIsDisabled("toggle-minimap"))
            .accessibilityIdentifier(AppAccessibility.id("menu command toggle minimap"))

            Toggle(
                text("Show Whitespace", zh: "显示空白字符"),
                isOn: routedToggleBinding(
                    commandID: "toggle-whitespace",
                    value: settings.settings.showWhitespace
                )
            )
            .disabled(routeIsDisabled("toggle-whitespace"))
            .accessibilityIdentifier(AppAccessibility.id("menu command toggle whitespace"))

            Toggle(
                text("Show Outline", zh: "显示大纲"),
                isOn: routedToggleBinding(
                    commandID: "toggle-outline",
                    value: settings.settings.showOutline
                )
            )
            .disabled(routeIsDisabled("toggle-outline"))
            .accessibilityIdentifier(AppAccessibility.id("menu command toggle outline"))

            routedButton("Fold Current", commandID: "fold-current")
            routedButton("Unfold Current", commandID: "unfold-current")
            routedButton("Fold All", commandID: "fold-all")
            routedButton("Unfold All", commandID: "unfold-all")

            Toggle(
                text("Distraction Free Mode", zh: "专注模式"),
                isOn: routedToggleBinding(
                    commandID: "toggle-distraction-free",
                    value: settings.settings.distractionFree
                )
            )
            .disabled(routeIsDisabled("toggle-distraction-free"))
            .accessibilityIdentifier(AppAccessibility.id("menu command distraction free"))

            Divider()

            routedButton("Zoom In", commandID: "font-zoom-in")
                .keyboardShortcut("=", modifiers: .command)
            routedButton("Zoom Out", commandID: "font-zoom-out")
                .keyboardShortcut("-", modifiers: .command)
            routedButton("Actual Size", commandID: "font-zoom-reset")
                .keyboardShortcut("0", modifiers: .command)

            Divider()
            routedButton("Open Settings…", commandID: "open-settings")
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .help) {
            routedButton("Check for Updates…", commandID: "check-for-updates")
        }

        CommandGroup(replacing: .appInfo) {
            Button(editorLocale.localizedApp(.aboutApp(appName: editorLocale.localizedApp(.systemAppName)))) {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id("menu about app"))
        }

        CommandGroup(replacing: .appVisibility) {
            Button(editorLocale.localizedApp(.hideApp(appName: editorLocale.localizedApp(.systemAppName)))) {
                NSApp.hide(nil)
            }
            .keyboardShortcut("h", modifiers: .command)
            .accessibilityIdentifier(AppAccessibility.id("menu hide app"))

            Button(editorLocale.localizedApp(.hideOthers)) {
                NSApp.hideOtherApplications(nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .accessibilityIdentifier(AppAccessibility.id("menu hide others"))

            Button(editorLocale.localizedApp(.showAll)) {
                NSApp.unhideAllApplications(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id("menu show all"))
        }

        CommandGroup(replacing: .appTermination) {
            Button(editorLocale.localizedApp(.quitApp(appName: editorLocale.localizedApp(.systemAppName)))) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityIdentifier(AppAccessibility.id("menu quit app"))
        }

        CommandGroup(replacing: .windowArrangement) {
            Button(editorLocale.localizedApp(.minimize)) {
                NSApp.keyWindow?.performMiniaturize(nil)
            }
            .keyboardShortcut("m", modifiers: .command)
            .accessibilityIdentifier(AppAccessibility.id("menu window minimize"))

            Button(editorLocale.localizedApp(.zoom)) {
                NSApp.keyWindow?.performZoom(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id("menu window zoom"))

            Button(editorLocale.localizedApp(.toggleFullScreen)) {
                NSApp.sendAction(
                    Self.toggleFullScreenAction,
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(Self.toggleFullScreenShortcut)
            .disabled(!canToggleFullScreen)
            .accessibilityIdentifier(AppAccessibility.id("menu window toggle full screen"))

            Divider()

            Button(editorLocale.localizedApp(.bringAllToFront)) {
                NSApp.arrangeInFront(nil)
            }
            .accessibilityIdentifier(AppAccessibility.id("menu window arrange in front"))
        }
    }

    private var hasBlockingInteraction: Bool {
        !actions.canExecuteRoutedCommand
    }

    private var canChangeFormat: Bool {
        !hasBlockingInteraction && model.selectedDocument?.isSaving == false
    }

    private var canToggleFullScreen: Bool {
        let action = Self.toggleFullScreenAction
        return Self.systemActionIsEnabled(
            action,
            target: NSApp.target(forAction: action)
        )
    }

    /// Mirrors AppKit's target/action menu validation for the SwiftUI button
    /// that represents a system selector. The target is first resolved through
    /// NSApplication's responder chain by the caller.
    @MainActor
    static func systemActionIsEnabled(_ action: Selector, target: Any?) -> Bool {
        guard let target else { return false }
        let menuItem = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let validator = target as? any NSMenuItemValidation {
            return validator.validateMenuItem(menuItem)
        }
        if let validator = target as? any NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(menuItem)
        }
        return true
    }

    private func routeIsDisabled(_ commandID: String) -> Bool {
        router.status(
            for: commandID,
            context: routingContext
        )?.isEnabled != true
    }

    private func execute(_ commandID: String) {
        Task {
            let result = await router.execute(
                commandID,
                context: routingContext
            )
            actions.handleCommandExecutionResult(result)
        }
    }

    private func routedButton(
        _ title: String,
        commandID: String,
        accessibilityID: String? = nil
    ) -> some View {
        Button(commandTitle(commandID, fallback: title)) { execute(commandID) }
            .disabled(routeIsDisabled(commandID))
            .accessibilityIdentifier(AppAccessibility.id(
                accessibilityID ?? "menu command \(commandID)"
            ))
    }

    private var routingContext: CommandRoutingContext {
        actions.commandRoutingContext(
            hasFindResults: workspaceSearch.hasResults,
            hasGitRepository: git.isRepositoryAvailable,
            hasNavigationHistory: navigation.canGoBack || navigation.canGoForward,
            hasLanguageService: languageServers.runningServerCount > 0
        )
    }

    private var selectionCommandIDs: [String] {
        [
            "add-cursor-above", "add-cursor-below", "undo-selection",
            "redo-selection", "select-next-occurrence",
            "skip-current-occurrence", "remove-last-cursor",
            "select-all-occurrences", "add-cursors-line-starts",
            "add-cursors-line-ends", "select-line",
            "select-matching-bracket", "select-parent-syntax",
            "expand-selection", "shrink-selection", "split-selection-lines"
        ]
    }

    private var textCommandIDs: [String] {
        [
            "toggle-comment", "toggle-block-comment", "move-line-up",
            "move-line-down", "copy-line-up", "copy-line-down",
            "duplicate-selection", "delete-line", "delete-word-backward",
            "delete-word-forward", "delete-to-line-start", "delete-to-line-end",
            "insert-blank-line-above", "insert-blank-line",
            "transpose-characters", "sort-lines", "sort-lines-descending",
            "reverse-lines", "unique-lines", "remove-blank-lines",
            "trim-trailing-whitespace", "ensure-single-final-newline",
            "convert-indent-spaces", "convert-indent-tabs", "to-upper-case",
            "to-lower-case", "to-title-case", "swap-case", "join-lines",
            "wrap-paragraph-80", "unwrap-paragraph", "indent-selection",
            "outdent-selection", "reindent-selection"
        ]
    }

    private func routedCatalogButton(_ commandID: String) -> some View {
        routedButton(
            CommandCatalog.command(id: commandID)?.name(
                for: editorLocale.commandLocale
            ) ?? commandID,
            commandID: commandID
        )
    }

    private func routedToggleBinding(
        commandID: String,
        value: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { value },
            set: { _ in execute(commandID) }
        )
    }

    private func layoutButton(
        _ title: String,
        kind: PaneLayoutKind,
        commandID: String
    ) -> some View {
        Button { execute(commandID) } label: {
            Label(
                commandTitle(commandID, fallback: title),
                systemImage: model.paneLayout.kind == kind
                    ? "checkmark"
                    : "circle.dashed"
            )
        }
        .disabled(routeIsDisabled(commandID))
        .accessibilityIdentifier(AppAccessibility.id("menu command \(commandID)"))
    }

    private var editorLocale: EditorLocale { settings.locale }

    private func localized(_ key: LocalizationKey) -> String {
        editorLocale.localized(key)
    }

    private func text(_ english: String, zh chinese: String) -> String {
        editorLocale.text(english, zh: chinese)
    }

    private func commandTitle(_ commandID: String, fallback: String) -> String {
        Localization.commandLabel(
            for: commandID, locale: editorLocale, fallback: fallback
        )
    }

}
