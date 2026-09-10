import { readFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import ts from "typescript"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const paths = {
  commands: join(root, "src/renderer/src/commands.ts"),
  windowsCommands: join(root, "native-windows/src/LumenEditor.Windows.Core/WindowsCommandCatalog.cs"),
  builder: join(root, "electron-builder.yml"),
  manifest: join(root, "native-windows/src/LumenEditor.Windows.App/Packaging/Package.appxmanifest"),
  settings: join(root, "native-windows/src/LumenEditor.Windows.Core/Settings/EditorSettings.cs"),
  projectSettings: join(root, "native-windows/src/LumenEditor.Windows.Core/Build/ProjectBuildSettings.cs"),
  exclusionPolicy: join(root, "native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceExclusionPolicy.cs"),
  workspaceTree: join(root, "native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceTree.cs"),
  workspaceWatcher: join(root, "native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceFileWatcher.cs"),
  workspaceSearch: join(root, "native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceSearchService.cs"),
  workspaceReplace: join(root, "native-windows/src/LumenEditor.Windows.Core/Workspace/WorkspaceReplaceService.cs"),
  workspaceIndex: join(root, "native-windows/src/LumenEditor.Windows.Core/Navigation/WorkspaceFileIndex.cs"),
  gitService: join(root, "native-windows/src/LumenEditor.Windows.Core/Git/GitService.cs"),
  symbolIndex: join(root, "native-windows/src/LumenEditor.Windows.Core/Navigation/SymbolIndex.cs"),
  codec: join(root, "native-windows/src/LumenEditor.Windows.Core/Documents/TextFileCodec.cs"),
  languageCatalog: join(root, "native-windows/src/LumenEditor.Windows.Core/Documents/LanguageCatalog.Generated.cs"),
  writer: join(root, "native-windows/src/LumenEditor.Windows.Core/Documents/FileWriteService.cs"),
  nativeEditor: join(root, "native-windows/src/LumenEditor.Windows.App/NativeCodeEditor.cs"),
  multiSelection: join(root, "native-windows/src/LumenEditor.Windows.Core/Editing/MultiSelection.cs"),
  folding: join(root, "native-windows/src/LumenEditor.Windows.Core/Editing/CodeFolding.cs"),
  syntaxHighlighter: join(root, "native-windows/src/LumenEditor.Windows.Core/Editing/SyntaxHighlighter.cs"),
  previewRenderer: join(root, "native-windows/src/LumenEditor.Windows.Core/Documents/PreviewRenderer.cs"),
  completionEngine: join(root, "native-windows/src/LumenEditor.Windows.Core/Language/CompletionEngine.cs"),
  workspaceWordIndex: join(root, "native-windows/src/LumenEditor.Windows.Core/Navigation/WorkspaceWordIndex.cs"),
  parserModels: join(root, "native-windows/src/LumenEditor.Windows.Core/Parsing/CodeMirrorParserModels.cs"),
  parserWorkerHost: join(root, "native-windows/src/LumenEditor.Windows.Core/Parsing/CodeMirrorParserWorkerHost.cs"),
  parserWorkerProcess: join(root, "native-windows/src/LumenEditor.Windows.Core/Parsing/CodeMirrorParserWorkerProcess.cs"),
  pluginWorkerHost: join(root, "native-windows/src/LumenEditor.Windows.Core/Plugins/PluginWorkerHost.cs"),
  pluginWorkerProcess: join(root, "native-windows/src/LumenEditor.Windows.Core/Plugins/PluginWorkerProcess.cs"),
  windowXaml: join(root, "native-windows/src/LumenEditor.Windows.App/MainWindow.xaml"),
  app: join(root, "native-windows/src/LumenEditor.Windows.App/MainWindow.xaml.cs"),
  activation: join(root, "native-windows/src/LumenEditor.Windows.App/App.xaml.cs"),
  program: join(root, "native-windows/src/LumenEditor.Windows.App/Program.cs"),
  workerProgram: join(root, "native-windows/src/LumenEditor.Windows.Worker/Program.cs"),
  workerProject: join(root, "native-windows/src/LumenEditor.Windows.Worker/LumenEditor.Windows.Worker.csproj"),
  project: join(root, "native-windows/src/LumenEditor.Windows.App/LumenEditor.Windows.App.csproj"),
  packageScript: join(root, "native-windows/scripts/package-msix.ps1"),
  verifyPackageScript: join(root, "native-windows/scripts/verify-msix.ps1"),
  stagePackageScript: join(root, "native-windows/scripts/stage-msix.ps1"),
  smokePackageScript: join(root, "native-windows/scripts/smoke-installed-msix.ps1"),
  workerSmokeScript: join(root, "native-windows/scripts/test-plugin-worker.ps1"),
  parserSmokeScript: join(root, "native-windows/scripts/test-parser-worker.ps1"),
  verifyScript: join(root, "native-windows/scripts/verify.ps1"),
  verifyCoreScript: join(root, "native-windows/scripts/verify-core.sh"),
  portableWorkerSmoke: join(root, "native-windows/scripts/test-worker-process.mjs"),
  parserBundle: join(root, "native-macos/Sources/LumenEditorApp/Resources/CodeMirrorParserBundle.js"),
  workflow: join(root, ".github/workflows/native-windows.yml"),
  releaseWorkflow: join(root, ".github/workflows/release.yml"),
  packageJson: join(root, "package.json")
}

const menuOnlyCommands = new Set(["command-palette", "select-build-system"])
const expectedCommandCount = 169
const expectedImplementedCommandCount = 169
const expectedFileAssociationCount = 81
const expectedUnimplementedCommands = new Set()

function fail(message) { throw new Error("[native-windows] " + message) }
function check(condition, message) { if (!condition) fail(message) }

function parseElectronCommands(source) {
  const file = ts.createSourceFile("commands.ts", source, ts.ScriptTarget.Latest, true)
  const declaration = file.statements.flatMap(statement => {
    if (!ts.isVariableStatement(statement)) return []
    return statement.declarationList.declarations.filter(candidate =>
      ts.isIdentifier(candidate.name) && candidate.name.text === "COMMANDS")
  })
  check(declaration.length === 1, "expected one COMMANDS declaration")
  const initializer = declaration[0].initializer
  check(initializer && ts.isArrayLiteralExpression(initializer), "COMMANDS must be an array literal")
  const ids = initializer.elements.map((element, index) => {
    check(ts.isObjectLiteralExpression(element), "COMMANDS entry " + index + " must be an object")
    const property = element.properties.find(candidate =>
      ts.isPropertyAssignment(candidate) && ts.isIdentifier(candidate.name)
        && candidate.name.text === "id")
    check(property && ts.isPropertyAssignment(property) && ts.isStringLiteral(property.initializer),
      "COMMANDS entry " + index + " must have a literal id")
    return property.initializer.text
  })
  check(new Set(ids).size === ids.length, "Electron command IDs must be unique")
  return new Set(ids)
}

function parseWindowsStringArray(source, marker, label) {
  const start = source.indexOf(marker)
  check(start !== -1, label + " declaration is missing")
  const open = source.indexOf("[", start + marker.length)
  const close = source.indexOf("];", open)
  check(open !== -1 && close !== -1, label + " array is malformed")
  const ids = [...source.slice(open, close).matchAll(/"([^"]+)"/g)].map(match => match[1])
  check(ids.length > 0, label + " must not be empty")
  check(new Set(ids).size === ids.length, label + " contains duplicate values")
  return new Set(ids)
}

function parseElectronAssociations(source) {
  const start = source.indexOf("fileAssociations:\n")
  const end = source.indexOf("\nwin:", start)
  check(start !== -1 && end !== -1, "electron fileAssociations section is malformed")
  const extensions = [...source.slice(start, end).matchAll(
    /^\s*-\s*\{\s*ext:\s*([A-Za-z0-9.+-]+),\s*name:\s*[^,]+,\s*role:\s*Editor\s*\}\s*$/gm
  )].map(match => match[1])
  check(extensions.length === expectedFileAssociationCount,
    "Electron must declare " + expectedFileAssociationCount + " file associations")
  return new Set(extensions)
}

function parseManifestAssociations(source) {
  const extensions = [...source.matchAll(/<uap:FileType>\.([^<]+)<\/uap:FileType>/g)]
    .map(match => match[1])
  check(extensions.length === expectedFileAssociationCount,
    "Windows manifest must declare " + expectedFileAssociationCount + " file associations")
  check(new Set(extensions).size === extensions.length,
    "Windows manifest contains duplicate file associations")
  return new Set(extensions)
}

function assertSetEqual(actual, expected, label) {
  const missing = [...expected].filter(value => !actual.has(value)).sort()
  const extra = [...actual].filter(value => !expected.has(value)).sort()
  check(missing.length === 0 && extra.length === 0,
    label + ": missing [" + missing.join(", ") + "]; extra [" + extra.join(", ") + "]")
}

function assertXamlHandlersExist(xaml, codeBehind) {
  const handlers = [...xaml.matchAll(/(?:Click|Invoked|TextChanged|TextChanging|TextCompositionStarted|TextCompositionEnded|SelectionChanged|ItemClick|ItemInvoked|Expanding|Tapped)="([A-Za-z_][A-Za-z0-9_]*)"/g)]
    .map(match => match[1])
  check(handlers.length > 0, "MainWindow must declare event handlers")
  for (const handler of new Set(handlers)) {
    const declaration = new RegExp("(?:private|public|protected)\\s+(?:async\\s+)?(?:void|Task)\\s+" + handler + "\\s*\\(")
    check(declaration.test(codeBehind), "MainWindow XAML handler is missing in code-behind: " + handler)
  }
}

function pngDimensions(bytes, label) {
  check(bytes.length >= 24 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])),
    label + " must be a PNG")
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)]
}

const [commands, windowsCommands, builder, manifest, settings, projectSettings, exclusionPolicy, workspaceTree, workspaceWatcher, workspaceSearch, workspaceReplace, workspaceIndex, gitService, symbolIndex, codec, languageCatalog, writer, nativeEditor, multiSelection, folding, syntaxHighlighter, previewRenderer, completionEngine, workspaceWordIndex, parserModels, parserWorkerHost, parserWorkerProcess, pluginWorkerHost, pluginWorkerProcess, windowXaml, app, activation, program, workerProgram, workerProject, project, packageScript, verifyPackageScript, stagePackageScript, smokePackageScript, workerSmokeScript, parserSmokeScript, verifyScript, verifyCoreScript, portableWorkerSmoke, parserBundle, workflow, releaseWorkflow, packageJson] = await Promise.all(
  Object.values(paths).map(path => readFile(path, "utf8"))
)

const electronCommands = parseElectronCommands(commands)
const nativeCommands = parseWindowsStringArray(windowsCommands, "public static readonly string[] All =", "Windows command catalog")
const expectedCommands = new Set([...electronCommands, ...menuOnlyCommands])
check(expectedCommands.size === expectedCommandCount, "Electron command baseline count drifted")
assertSetEqual(nativeCommands, expectedCommands, "Windows command catalog versus Electron")
const implementedCommands = new Set([...app.matchAll(/RegisterCommand\("([^"]+)"/g)].map(match => match[1]))
check(implementedCommands.size === expectedImplementedCommandCount,
  `Windows implemented-command baseline changed: expected ${expectedImplementedCommandCount}, found ${implementedCommands.size}`)
for (const command of implementedCommands) check(nativeCommands.has(command), `Unknown implemented Windows command: ${command}`)
assertSetEqual(
  new Set([...nativeCommands].filter(command => !implementedCommands.has(command))),
  expectedUnimplementedCommands,
  "Windows unimplemented command baseline"
)

assertSetEqual(
  parseManifestAssociations(manifest),
  parseElectronAssociations(builder),
  "Windows manifest versus Electron file associations"
)

check(/CurrentFormatVersion\s*=\s*2/.test(settings), "Windows settings must use schema version 2")
check(/DefaultMaximumFileSizeMb\s*=\s*200/.test(settings), "Windows default file limit must be 200 MB")
check(/JsonPropertyName\("maxFileSizeMB"\)/.test(settings)
  && /BuildCommand/.test(settings) && /SearchHistory/.test(settings)
  && /ReplaceHistory/.test(settings) && /EditorColorScheme/.test(settings),
  "Windows settings must retain the shared Electron/native schema fields")
check(/Utf8Bom/.test(codec) && /Utf16Le/.test(codec) && /NormalizeLineEndings/.test(codec),
  "Windows core must retain BOM, UTF-16 and line-ending codec support")
check((languageCatalog.match(/\bnew\("/g) ?? []).length === 144
  && /new\("tsx", "TSX", "TSX"/.test(languageCatalog)
  && /new\("csharp", "C#", "C#"/.test(languageCatalog),
  "Windows language catalog must mirror all 143 CodeMirror languages plus Plain Text")
check(/RevisionConflict/.test(writer) && /File\.Replace\(temporary, fullPath/.test(writer)
  && /File\.Move\(temporary, fullPath\)/.test(writer),
  "Windows core must retain revision-checked atomic replacement")
check(/class NativeCodeEditor : RichEditBox/.test(nativeEditor)
  && /CharacterFormat\.Hidden = FormatEffect\.On/.test(nativeEditor)
  && /MultiSelectionCommands\.ApplyPrimaryEdit/.test(app)
  && /TextCompositionStarted \+= Editor_TextCompositionStarted/.test(app)
  && /CodeFoldAnalyzer\.Analyze/.test(app)
  && /x:Name="LineNumberCanvas0"/.test(windowXaml)
  && /x:Name="MinimapCanvas0"/.test(windowXaml)
  && /x:Name="WhitespaceCanvas0"/.test(windowXaml)
  && /x:Name="MultiSelectionCanvas0"/.test(windowXaml)
  && /MaximumSelections\s*=\s*10_000/.test(multiSelection)
  && /MaximumRegions\s*=\s*10_000/.test(folding)
  && /MaximumSourceLength\s*=\s*2 \* 1024 \* 1024/.test(syntaxHighlighter)
  && /MaximumSourceUtf16Length\s*=\s*128 \* 1024/.test(parserModels)
  && /MaximumSyntaxNodes\s*=\s*50_000/.test(parserModels)
  && /CodeMirrorParserWorkerProcess/.test(app)
  && /ToSyntaxHighlightPlan/.test(app)
  && /ToFoldRegions/.test(app)
  && /ApplySyntaxHighlighting/.test(nativeEditor)
  && /ScheduleSyntaxHighlighting/.test(app),
  "Windows native editor must retain bounded multi-selection and folding/view layers")
check(/x:Name="DecorationCanvas0"/.test(windowXaml)
  && /ShowIndentGuides/.test(settings) && /HighlightTrailingWhitespace/.test(settings)
  && /Rulers/.test(settings) && /RefreshEditorDecorations/.test(app)
  && /LanguageDiagnosticSnapshot/.test(app) && /documentDiffSnapshots/.test(app)
  && /ScheduleDiffDecorations/.test(app)
  && /ToggleAtStartLine/.test(folding) && /FoldMarker_Click/.test(app),
  "Windows editor must retain bounded active-line, match, indentation, ruler, trailing-whitespace, and diagnostic decorations")
check(/x:Name="MarkdownPreview"/.test(windowXaml) && /WebView2/.test(windowXaml)
  && /MarkdownToSafeHtml/.test(previewRenderer) && /DisableHtml/.test(previewRenderer)
  && /Content-Security-Policy/.test(previewRenderer) && /IsScriptEnabled = false/.test(app)
  && /DownloadStarting/.test(app) && /NavigationStarting/.test(app),
  "Windows Markdown preview must be rich, bounded, script-free, and navigation-confined")
check(/ParseLsp/.test(completionEngine) && /MaximumServerItems\s*=\s*200/.test(completionEngine)
  && /MaximumWords\s*=\s*20_000/.test(workspaceWordIndex)
  && /ScheduleCompletion/.test(app) && /completionRevision/.test(app)
  && /textDocument\/completion/.test(app) && /ScheduleLanguageServerSync/.test(app)
  && /EditorInputPlanner\.InsertNewline/.test(app) && /EditorInputPlanner\.InsertPair/.test(app)
  && /EditorInputPlanner\.SkipClosing/.test(app) && /EditorInputPlanner\.DeleteEmptyPairs/.test(app),
  "Windows editor must provide revision-pinned LSP completion with a bounded workspace-word fallback")
check(/EditorColorScheme/.test(settings) && /SolarizedDark/.test(settings) && /Dracula/.test(settings)
  && /ApplyColorScheme/.test(nativeEditor) && /ColorSchemeSetting/.test(windowXaml),
  "Windows editor must expose the same four persisted color schemes as Electron")
check(/Interop\.Enabled = false/.test(parserWorkerHost)
  && /DisableStringCompilation/.test(parserWorkerHost)
  && /AssignProcessToJobObject/.test(parserWorkerProcess)
  && /KillOnClose/.test(parserWorkerProcess)
  && /--parser-worker/.test(workerProgram)
  && /TargetFramework>net8.0<\/TargetFramework>/.test(workerProject)
  && /PublishSingleFile>true/.test(workerProject)
  && /WorkerExecutablePath/.test(app)
  && !/--(?:parser|plugin)-worker/.test(program)
  && /CodeMirrorParserBundle\.js/.test(project)
  && /--parser-worker/.test(parserSmokeScript)
  && /syntaxNodes/.test(parserSmokeScript)
  && /test-parser-worker\.ps1/.test(verifyScript)
  && /test-plugin-worker\.ps1/.test(verifyScript)
  && /mktemp -d/.test(verifyCoreScript)
  && /CopyLocalLockFileAssemblies=true/.test(verifyCoreScript)
  && /test-worker-process\.mjs/.test(verifyCoreScript)
  && /--parser-worker/.test(portableWorkerSmoke)
  && /--plugin-worker/.test(portableWorkerSmoke)
  && parserBundle.length > 0 && Buffer.byteLength(parserBundle, "utf8") <= 8 * 1024 * 1024,
  "Windows app must use the bounded shared CodeMirror parser in an isolated worker")
check(/ParseExclusions/.test(projectSettings) && /MaximumPatterns\s*=\s*100/.test(exclusionPolicy)
  && /MaximumPatternCharacters\s*=\s*200/.test(exclusionPolicy)
  && /IsExcluded\(canonicalRoot, entry\.FullPath, entry\.IsDirectory\)/.test(workspaceTree)
  && /WorkspaceChangeAccumulator\(fullRoot, exclusions\)/.test(workspaceWatcher)
  && /ReadChildren\(root, directory, exclusions\)/.test(workspaceSearch)
  && /ProjectExclusions/.test(workspaceReplace) && /currentExclusions/.test(workspaceReplace)
  && /EnumerateFiles\(normalizedRoots, tree, exclusions\)/.test(workspaceIndex)
  && /EnumerateFiles\(roots, tree, exclusions\)/.test(symbolIndex)
  && /WorkspaceExclusionPolicy projectExclusions/.test(app)
  && /ReadChildren\(root, parent\.Path, projectExclusions\)/.test(app)
  && /currentExclusions: projectExclusions/.test(app),
  "Windows project exclusions must be bounded and shared by tree, indexes, search and replacement")
check(/PickMultipleFilesAsync()/.test(app), "Windows app must use a multi-file picker")
check(/OpenPathsAsync\(files\.Select/.test(app), "Windows picker must forward every selected file")
check(/initialization = RestoreAsync\(\)/.test(app) && /await initialization/.test(app),
  "Windows file activation must wait for session initialization")
check(/x:Name="FindPanel"/.test(windowXaml) && /ReplaceAll_Click/.test(windowXaml)
  && /FindEngine\.ReplaceAll/.test(app) && /FindEngine\.FindNext/.test(app)
  && /FindHistory_Click/.test(windowXaml) && /WorkspaceHistory_Click/.test(windowXaml)
  && /RememberSearchHistory/.test(app) && /SearchHistory/.test(settings) && /ReplaceHistory/.test(settings),
  "Windows app must expose current-document find and replace")
check(/x:Name="WorkspaceTreeView"/.test(windowXaml) && /PickSingleFolderAsync/.test(app)
  && /WorkspaceTree_Expanding/.test(app) && /session\.Folders/.test(app),
  "Windows app must expose and restore a lazy workspace tree")
check(/NewWorkspaceFile_Click/.test(windowXaml) && /RenameWorkspaceItem_Click/.test(windowXaml)
  && /RecycleWorkspaceItem_Click/.test(windowXaml) && /StorageDeleteOption\.Default/.test(app),
  "Windows app must expose root-confined workspace file operations and Recycle Bin deletion")
check(/x:Name="WorkspaceSearchPanel"/.test(windowXaml) && /WorkspaceResults_ItemClick/.test(windowXaml)
  && /SearchWorkspaceAsync/.test(app) && /TextNavigation\.LineColumnToOffset/.test(app),
  "Windows app must expose workspace search and result navigation")
check(/PreviewWorkspaceReplace_Click/.test(windowXaml) && /ApplyWorkspaceReplace_Click/.test(windowXaml)
  && /UndoWorkspaceReplace_Click/.test(windowXaml) && /workspaceReplaceService\.ApplyAsync/.test(app),
  "Windows app must preview, apply and undo workspace replacements")
check(/x:Name="SettingsPanel"/.test(windowXaml) && /ApplySettings_Click/.test(windowXaml)
  && /ApplySettingsToEditor/.test(app) && /settingsStore\.SaveAsync/.test(app),
  "Windows app must expose and persist editor settings")
check(/x:Name="EditorPaneGrid"/.test(windowXaml) && /Editor3/.test(windowXaml)
  && /PaneLayoutKind\.Grid4/.test(app) && /MoveDocumentToNextPane/.test(app),
  "Windows app must expose single, column and grid pane layouts")
check(/x:Name="DocumentList"[^>]*SelectionMode="Extended"/s.test(windowXaml)
  && /RegisterCommand\("split-selected-tabs"/.test(app) && /SplitSelectedTabs\(selectedPaths\)/.test(app),
  "Windows app must split Ctrl/Shift-selected documents into panes")
check(/CommandPalette_Invoked/.test(windowXaml) && /RegisterCommands\(\)/.test(app)
  && /commandRouter\.ExecuteAsync/.test(app),
  "Windows app must route implemented actions through a command palette")
check(/x:Name="BuildPanel"/.test(windowXaml) && /StopBuild_Click/.test(windowXaml)
  && /BuildSystemDetector\.Detect/.test(app) && /processRunner\.RunAsync/.test(app),
  "Windows app must expose confirmed, cancellable build execution")
check(/x:Name="GitPanel"/.test(windowXaml) && /StageGit_Click/.test(windowXaml)
  && /UnstageGit_Click/.test(windowXaml) && /DiscardGit_Click/.test(windowXaml)
  && /StageGitHunk_Click/.test(windowXaml) && /DiscardGitHunk_Click/.test(windowXaml)
  && /GitHistory_Click/.test(windowXaml) && /GitBlame_Click/.test(windowXaml)
  && /SwitchGitBranch_Click/.test(windowXaml) && /CreateGitBranch_Click/.test(windowXaml)
  && /SelectionMode="Extended"[^>]*SelectionChanged="GitFiles_SelectionChanged"/.test(windowXaml)
  && /ApplyHunkAsync/.test(gitService) && /ParseHunks/.test(gitService)
  && /HistoryAsync/.test(gitService) && /BlameAsync/.test(gitService)
  && /SwitchBranchAsync/.test(gitService) && /gitService\.CommitAsync/.test(app),
  "Windows app must expose Git status, diff, multi-file actions, hunks, history, blame, branches and commit")
check(/x:Name="TerminalPanel"/.test(windowXaml) && /TerminalInput_KeyDown/.test(windowXaml)
  && /WindowsPseudoConsoleSession/.test(app) && /StopTerminalAsync/.test(app),
  "Windows app must expose a native ConPTY terminal with lifecycle cleanup")
check(/x:Name="LanguageServerPanel"/.test(windowXaml) && /LspHover_Click/.test(windowXaml)
  && /LspDefinition_Click/.test(windowXaml) && /LspReferences_Click/.test(windowXaml)
  && /LspRename_Click/.test(windowXaml) && /ApplyLspRename_Click/.test(windowXaml)
  && /UndoLspRename_Click/.test(windowXaml) && /LanguageServerClient\.StartAsync/.test(app),
  "Windows app must expose confirmed persistent language-server features")
check(/x:Name="PluginsPanel"/.test(windowXaml) && /InstallPlugin_Click/.test(windowXaml)
  && /DeclarativePluginStore/.test(app) && /PluginWorkerProcess\.StartAsync/.test(app)
  && /--plugin-worker/.test(workerProgram) && /Interop\.Enabled = false/.test(pluginWorkerHost)
  && /AssignProcessToJobObject/.test(pluginWorkerProcess) && /KillOnClose/.test(pluginWorkerProcess)
  && /PluginPermission\.DocumentEdit/.test(app) && /MaxStatements\(1_000_000\)/.test(pluginWorkerHost)
  && /--plugin-worker/.test(workerSmokeScript) && /run-command/.test(workerSmokeScript),
  "Windows app must isolate bounded plugin workers behind explicit permissions")
check(/AutoSaveMode/.test(settings) && /AutoSaveDelayMs/.test(settings)
  && /Window_Activated/.test(app) && /AutoSaveDirtyDocumentsAsync/.test(app),
  "Windows app must expose bounded after-delay and focus-change auto save")
check(/ShowRecentItemsAsync/.test(app) && /RecentItemsStore/.test(app),
  "Windows app must expose recent files and projects")
check(/ProjectSettingsStore/.test(app) && /ImportSublimeBuildAsync/.test(app)
  && /ImportSublimeProjectAsync/.test(app) && /ImportSublimeSettingsAsync/.test(app)
  && /ImportSublimeSnippetAsync/.test(app) && /ImportSublimeKeymapAsync/.test(app),
  "Windows app must expose revision-pinned project settings and bounded Sublime migration")
check(/CheckForUpdatesAsync/.test(app) && /OpenMarketplaceAsync/.test(app),
  "Windows app must expose bounded update checks and declarative marketplace installs")
assertXamlHandlersExist(windowXaml, app)
check(/cleanPaths/.test(app) && /opener\.OpenAsync\(cleanPaths, settings\)/.test(app)
  && /document\.Draft is not null/.test(app),
  "Windows session restore must reload clean files and retain dirty drafts")
check(/IFileActivatedEventArgs/.test(activation) && /OpenFileActivation/.test(activation)
  && /FindOrRegisterForKey/.test(program) && /RedirectActivationToAsync/.test(program),
  "Windows app must handle file-type activation")
check(/Microsoft.WindowsAppSDK/.test(project) && /UseWinUI>true/.test(project)
  && /DISABLE_XAML_GENERATED_MAIN/.test(project) && /LumenXamlStubBuild/.test(project),
  "Windows project must use WinUI 3 via Windows App SDK")
check(/<WindowsPackageType[^>]*>MSIX<\/WindowsPackageType>/.test(project)
  && /<LumenPackageManifest[^>]*>Packaging\/Package\.appxmanifest<\/LumenPackageManifest>/.test(project)
  && /<AppxManifest Include="\$\(LumenPackageManifest\)"/.test(project)
  && /win-x64;win-arm64/.test(project) && /<WindowsAppSDKSelfContained[^>]*>true/.test(project)
  && /LumenWorkerPublishDir/.test(project) && /LumenEditor.Windows.Worker\.exe/.test(project),
  "Windows project must produce architecture-specific self-contained MSIX packages")
const appVersion = JSON.parse(packageJson).version
const manifestVersion = manifest.match(/<Identity[^>]+Version="([^"]+)"/)?.[1]
check(manifestVersion === `${appVersion}.0`, "Windows MSIX manifest version must match package.json")
check(/GenerateAppxPackageOnBuild=true/.test(packageScript) && /verify-msix\.ps1/.test(packageScript)
  && /ProcessorArchitecture/.test(verifyPackageScript) && /associations\.Count -ne 81/.test(verifyPackageScript)
  && /Get-PeMachine \$appExecutable/.test(verifyPackageScript)
  && /workerExecutables\.Count -ne 1/.test(verifyPackageScript)
  && /CodeMirrorParserBundle\.js/.test(verifyPackageScript)
  && /Get-FileHash/.test(verifyPackageScript)
  && /Markdig\.dll/.test(verifyPackageScript)
  && /LumenEditor\.Windows\.Worker\.exe/.test(verifyPackageScript)
  && /LumenWorkerPublishDir/.test(packageScript)
  && /native-windows-/.test(stagePackageScript) && /Copy-Item/.test(stagePackageScript),
  "Windows MSIX scripts must build and inspect architecture-specific packages")
check(/arch: \[x64, arm64\]/.test(workflow) && /package-msix\.ps1/.test(workflow)
  && /upload-artifact@/.test(workflow)
  && /smoke-installed-msix\.ps1/.test(workflow)
  && /runs-on: ubuntu-24\.04/.test(workflow)
  && /verify-core\.sh/.test(workflow)
  && /npm run check:native-parser/.test(workflow)
  && /New-SelfSignedCertificate/.test(smokePackageScript)
  && /Add-AppxPackage/.test(smokePackageScript)
  && /shell:AppsFolder/.test(smokePackageScript)
  && /FindVisibleWindow/.test(smokePackageScript)
  && /IsWindowVisible/.test(smokePackageScript)
  && /AutomationElement.*FromHandle/.test(smokePackageScript)
  && /LumenEditorRoot/.test(windowXaml)
  && /AutomationProperties\.AccessibilityView="Content"/.test(windowXaml)
  && /contentRoot/.test(smokePackageScript)
  && /ControlType\.Window/.test(smokePackageScript)
  && /IsResponsive/.test(smokePackageScript)
  && /RequestClose/.test(smokePackageScript)
  && /WaitForExit/.test(smokePackageScript)
  && /native-windows-installed-window/.test(smokePackageScript)
  && /ConvertTo-Json/.test(smokePackageScript)
  && /Remove-AppxPackage/.test(smokePackageScript),
  "Windows CI must install x64 and prove a visible, responsive UI window while packaging both architectures")
check(/smoke-installed-msix\.ps1/.test(releaseWorkflow)
  && /-PackagePath \$package/.test(releaseWorkflow)
  && /native-windows-release-evidence/.test(releaseWorkflow)
  && /native-release-evidence-windows-x64/.test(releaseWorkflow),
  "Windows tag release must exercise the signed installed MSIX and retain structured evidence")
check(/com.lumen.editor.native-preview.windows/.test(manifest),
  "Windows package identity must remain isolated from Electron/macOS native state")
check(/rescap:Capability Name="runFullTrust"/.test(manifest),
  "Windows package must declare runFullTrust for native filesystem and process tooling")
const assetRoot = join(root, "native-windows/src/LumenEditor.Windows.App/Assets")
const expectedAssets = new Map([
  ["StoreLogo.png", [50, 50]],
  ["Square44x44Logo.png", [44, 44]],
  ["Square150x150Logo.png", [150, 150]],
  ["Wide310x150Logo.png", [310, 150]]
])
for (const [name, dimensions] of expectedAssets) {
  const bytes = await readFile(join(assetRoot, name))
  check(JSON.stringify(pngDimensions(bytes, name)) === JSON.stringify(dimensions),
    `${name} must be ${dimensions[0]}x${dimensions[1]}`)
}

process.stdout.write(
  "Native Windows contract passed: " + nativeCommands.size + " commands ("
    + implementedCommands.size + " wired), "
    + expectedFileAssociationCount + " file associations, 144 language entries, WinUI 3 app and "
    + "200 MB settings baseline.\n"
)
