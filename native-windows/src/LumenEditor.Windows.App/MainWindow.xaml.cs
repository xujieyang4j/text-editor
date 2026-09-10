using LumenEditor.Windows.Core;
using LumenEditor.Windows.Core.Build;
using LumenEditor.Windows.Core.Documents;
using LumenEditor.Windows.Core.Settings;
using LumenEditor.Windows.Core.Terminal;
using LumenEditor.Windows.Core.Updates;
using LumenEditor.Windows.Core.Editing;
using LumenEditor.Windows.Core.Find;
using LumenEditor.Windows.Core.Git;
using LumenEditor.Windows.Core.Language;
using LumenEditor.Windows.Core.Layout;
using LumenEditor.Windows.Core.Localization;
using LumenEditor.Windows.Core.Navigation;
using LumenEditor.Windows.Core.Parsing;
using LumenEditor.Windows.Core.Processes;
using LumenEditor.Windows.Core.Plugins;
using LumenEditor.Windows.Core.Recent;
using LumenEditor.Windows.Core.Workspace;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation;
using Microsoft.Web.WebView2.Core;
using Rectangle = Microsoft.UI.Xaml.Shapes.Rectangle;
using LineShape = Microsoft.UI.Xaml.Shapes.Line;
using Windows.System;
using WinRT.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using System.Text.Json;

namespace LumenEditor.Windows.App;

public sealed partial class MainWindow : Window
{
    private readonly DocumentWorkspace workspace = new();
    private readonly WindowsCommandRouter commandRouter = new();
    private readonly DocumentOpenService opener = new();
    private readonly FileWriteService writer = new();
    private readonly WorkspaceTree workspaceTree = new();
    private readonly WorkspaceSearchRunner workspaceSearchRunner = new();
    private readonly WorkspaceReplaceService workspaceReplaceService = new();
    private readonly PaneLayout paneLayout = new();
    private readonly NavigationHistory navigationHistory = new();
    private readonly BoundedProcessRunner processRunner = new();
    private readonly GitService gitService;
    private readonly UpdateService updateService = new();
    private readonly MarketplaceClient marketplaceClient = new();
    private readonly List<DeclarativePlugin> plugins = [];
    private readonly Dictionary<string, PluginWorkerProcess> pluginWorkers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, PluginWorkerCommandRoute> pluginWorkerCommands = new(StringComparer.Ordinal);
    private long pluginWorkerGeneration;
    private Task pluginWorkerShutdown = Task.CompletedTask;
    private CodeMirrorParserWorkerProcess? parserWorker;
    private Task<CodeMirrorParserWorkerProcess>? parserWorkerStartup;
    private bool markdownPreviewReady;
    private string? pendingMarkdownHtml;
    private readonly List<string> workspaceRoots = [];
    private readonly List<WorkspaceFileWatcher> workspaceWatchers = [];
    private WorkspaceExclusionPolicy projectExclusions = WorkspaceExclusionPolicy.Empty;
    private EditorSettings settings = EditorSettings.Sanitize(null);
    private readonly SettingsStore settingsStore = new();
    private readonly SessionStore sessionStore = new(Path.Combine(
        SettingsStore.DefaultDirectory, "session.json"));
    private readonly RecentItemsStore recentItemsStore = new(Path.Combine(
        SettingsStore.DefaultDirectory, "recent.json"));
    private readonly Task initialization;
    private bool applyingEditorText;
    private bool uiReady;
    private EditorBuffer buffer = new();
    private readonly NativeCodeEditor[] editors;
    private readonly Border[] paneHosts;
    private readonly Border[] lineNumberGutters;
    private readonly Canvas[] lineNumberCanvases;
    private readonly Canvas[] whitespaceCanvases;
    private readonly Canvas[] decorationCanvases;
    private readonly Canvas[] multiSelectionCanvases;
    private readonly Canvas[] minimapCanvases;
    private readonly Dictionary<NativeCodeEditor, ScrollViewer> editorScrollViewers = [];
    private readonly SparseLineIndex?[] paneLineIndexes = new SparseLineIndex?[4];
    private readonly bool[] lineNumberRefreshQueued = new bool[4];
    private readonly bool[] minimapDirty = [true, true, true, true];
    private readonly Rectangle?[] minimapViewports = new Rectangle?[4];
    private bool imeCompositionActive;
    private bool nativeMultiEditPending;
    private readonly CancellationTokenSource?[] syntaxHighlightCancellations = new CancellationTokenSource?[4];
    private NativeCodeEditor Editor => editors[paneLayout.ActivePane];
    private readonly Dictionary<string, EditorBuffer> documentBuffers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, SelectionHistory> documentSelectionHistories = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Stack<TextSelection>> documentExpansionHistories = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, BookmarkSet> documentBookmarks = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, CodeFoldingState> documentFoldingStates = new(StringComparer.OrdinalIgnoreCase);
    private const int MaximumParserSnapshots = 4;
    private readonly Dictionary<string, ParserDocumentSnapshot> documentParserSnapshots = new(StringComparer.OrdinalIgnoreCase);
    private const int MaximumDiffSnapshots = 4;
    private readonly Dictionary<string, string> documentSavedBaselines = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DiffDecorationSnapshot> documentDiffSnapshots = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? diffDecorationCancellation;
    private readonly Dictionary<string, LanguageDefinition> documentLanguages = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<KeyboardAccelerator> defaultKeyboardAccelerators;
    private readonly List<KeyboardAccelerator> projectKeyboardAccelerators = [];
    private readonly Stack<string> recentlyClosedPaths = new();
    private readonly MacroRecorder macroRecorder = new();
    private readonly MacroStore macroStore = new(Path.Combine(SettingsStore.DefaultDirectory, "saved-macro.json"));
    private bool replayingMacro;
    private CancellationTokenSource? autoSaveDelayCancellation;
    private readonly HashSet<string> autoSaveConflictedPaths = new(StringComparer.OrdinalIgnoreCase);
    private bool autoSaveRunning;
    private bool autoSavePassRequested;
    private bool sidebarVisibleBeforeDistraction = true;
    private CancellationTokenSource? workspaceSearchCancellation;
    private WorkspaceReplacePreview? workspaceReplacePreview;
    private WorkspaceReplaceUndo? workspaceReplaceUndo;
    private List<WorkspaceSearchListItem> workspaceResultItems = [];
    private int workspaceResultIndex = -1;
    private CancellationTokenSource? buildCancellation;
    private DetectedBuildSystem? selectedBuildSystem;
    private WindowsPseudoConsoleSession? terminalSession;
    private long terminalGeneration;
    private LanguageServerClient? languageServer;
    private readonly LanguageRenameService languageRenameService = new();
    private LanguageRenamePreview? languageRenamePreview;
    private LanguageRenameUndo? languageRenameUndo;
    private CancellationTokenSource? languageServerRequestCancellation;
    private CancellationTokenSource? languageServerSyncCancellation;
    private CancellationTokenSource? completionCancellation;
    private readonly Flyout completionFlyout = new();
    private readonly ListView completionList = new()
    {
        DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single,
        IsItemClickEnabled = true, MaxHeight = 300, MinWidth = 280
    };
    private CompletionPrefix? completionPrefix;
    private string? completionPath;
    private ulong completionRevision;
    private IReadOnlyList<string> workspaceWords = [];
    private DateTimeOffset workspaceWordsAt = DateTimeOffset.MinValue;
    private Task? workspaceWordsRefresh;
    private CancellationTokenSource? workspaceWordsCancellation;
    private string? languageServerRoot;
    private IReadOnlyList<string> workspaceFileIndex = [];
    private IReadOnlyList<DocumentSymbol> projectSymbolIndex = [];
    private readonly List<string> browserPreviewFiles = [];
    private readonly Dictionary<string, LanguageDiagnosticSnapshot> languageDiagnostics = new(StringComparer.OrdinalIgnoreCase);
    private sealed record WorkspaceTreeItem(string Path, string Name, bool IsDirectory, bool IsRoot = false)
    {
        public override string ToString() => Name;
    }
    private sealed record WorkspaceSearchListItem(WorkspaceSearchMatch Match)
    {
        public string Display => $"{Path.GetFileName(Match.Path)}:{Match.Line}:{Match.Column}  {Match.LineText.Trim()}";
    }
    private sealed record LanguageDiagnosticListItem(LanguageDiagnostic Diagnostic)
    {
        public string Display => $"{Diagnostic.Severity}: {Path.GetFileName(Diagnostic.Path)}:{Diagnostic.Line + 1}:{Diagnostic.Character + 1} — {Diagnostic.Message}";
    }
    private sealed record CompletionListItem(LanguageCompletionItem Completion)
    {
        public string Display => String.IsNullOrWhiteSpace(Completion.Detail)
            ? Completion.Label : $"{Completion.Label} — {Completion.Detail}";
    }
    private sealed record SearchHistoryItem(string Value, bool IsReplacement, string Display);
    private sealed record PluginListItem(DeclarativePlugin Plugin)
    {
        public string Display => $"{Plugin.Name} {Plugin.Version} — {Plugin.Commands.Count} command(s), {Plugin.Snippets.Count} snippet(s)";
    }
    private sealed record PluginCommandListItem(string Id, string Display, string InsertText);
    private sealed record PluginWorkerCommandRoute(
        string RouteId, string PluginId, string PluginName, string CommandId, string Title,
        IReadOnlyList<PluginPermission> Permissions);
    private sealed record PluginSnippetListItem(string Display, string Text);
    private sealed record ParserDocumentSnapshot(
        string Text, string Language, CodeMirrorParserAnalysis Analysis);
    private sealed record DiffDecorationSnapshot(
        ulong Revision, IReadOnlyList<IncrementalChange> Changes);
    private sealed record FoldMarkerTag(int PaneIndex, string Path, int Line);
    private sealed record WorkspaceFileListItem(WorkspaceFileMatch Match)
    {
        public string Display => Match.RelativePath;
    }
    private sealed record SymbolListItem(DocumentSymbol Symbol)
    {
        public string Display => $"{Symbol.Name} — {Symbol.Kind} · {Path.GetFileName(Symbol.Path)}:{Symbol.Line}";
    }
    private sealed record RecentItemListItem(string Path, bool IsProject)
    {
        public string Display => $"{(IsProject ? "Project" : "File")} — {Path}";
    }
    public MainWindow()
    {
        InitializeComponent();
        defaultKeyboardAccelerators = Root.KeyboardAccelerators.ToList();
        editors = [Editor0, Editor1, Editor2, Editor3];
        paneHosts = [Pane0Host, Pane1Host, Pane2Host, Pane3Host];
        lineNumberGutters = [LineNumberGutter0, LineNumberGutter1, LineNumberGutter2, LineNumberGutter3];
        lineNumberCanvases = [LineNumberCanvas0, LineNumberCanvas1, LineNumberCanvas2, LineNumberCanvas3];
        whitespaceCanvases = [WhitespaceCanvas0, WhitespaceCanvas1, WhitespaceCanvas2, WhitespaceCanvas3];
        decorationCanvases = [DecorationCanvas0, DecorationCanvas1, DecorationCanvas2, DecorationCanvas3];
        multiSelectionCanvases = [MultiSelectionCanvas0, MultiSelectionCanvas1, MultiSelectionCanvas2, MultiSelectionCanvas3];
        minimapCanvases = [MinimapCanvas0, MinimapCanvas1, MinimapCanvas2, MinimapCanvas3];
        completionFlyout.Content = completionList;
        completionList.ItemClick += CompletionList_ItemClick;
        MarkdownPreview.CoreWebView2Initialized += MarkdownPreview_CoreWebView2Initialized;
        for (var index = 0; index < editors.Length; index++)
        {
            var paneIndex = index;
            editors[index].TextChanging += Editor_TextChanging;
            editors[index].TextChanged += Editor_TextChanged;
            editors[index].SelectionChanged += Editor_SelectionChanged;
            editors[index].TextCompositionStarted += Editor_TextCompositionStarted;
            editors[index].TextCompositionEnded += Editor_TextCompositionEnded;
            editors[index].KeyDown += Editor_KeyDown;
            editors[index].CharacterReceived += Editor_CharacterReceived;
            editors[index].GotFocus += Editor_GotFocus;
            editors[index].Loaded += (_, _) => AttachEditorScrollViewer(paneIndex);
            editors[index].SizeChanged += (_, _) =>
            {
                minimapDirty[paneIndex] = true;
                QueueLineNumberRefresh(paneIndex);
            };
        }
        gitService = new GitService(processRunner);
        uiReady = true;
        RegisterCommands();
        Title = "文本编辑器(徐洁阳) Native for Windows";
        var initial = workspace.NewUntitled();
        paneLayout.AddToActive(initial.Path);
        ApplyPaneLayoutVisuals();
        RefreshWorkspace();
        Activated += Window_Activated;
        Closed += (_, _) => PersistAtClose();
        initialization = RestoreAsync();
    }

    private void New_Click(object sender, RoutedEventArgs args)
    {
        var document = workspace.NewUntitled();
        paneLayout.Activate(document.Path);
        RefreshWorkspace();
    }

    private async void Open_Click(object sender, RoutedEventArgs args)
    {
        await PickAndOpenFilesAsync();
    }

    private async void OpenWithEncoding_Click(object sender, RoutedEventArgs args) => await PickAndOpenFilesWithEncodingAsync();

    private async void OpenRecent_Click(object sender, RoutedEventArgs args) => await ShowRecentItemsAsync();

    private async Task PickAndOpenFilesAsync()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is null) return;
        await OpenPathsAsync(files.Select(file => file.Path));
    }

    private async Task PickAndOpenFilesWithEncodingAsync()
    {
        var encoding = await ChooseEncodingAsync("Open File with Encoding");
        if (encoding is null) return;
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is null) return;
        await initialization;
        var result = await opener.OpenWithEncodingAsync(files.Select(file => file.Path), settings, encoding.Value);
        workspace.AddOrActivate(result.Documents);
        foreach (var document in result.Documents) paneLayout.Activate(document.Path);
        foreach (var document in result.Documents) await TryRememberFileAsync(document.Path);
        RefreshWorkspace();
        Status.Text = result.Failures.Count == 0
            ? $"Opened {result.Documents.Count} file(s) as {encoding}."
            : $"Opened {result.Documents.Count} file(s) as {encoding}; {result.Failures.Count} failed.";
    }

    private async void OpenFolder_Click(object sender, RoutedEventArgs args)
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        await OpenWorkspaceRootAsync(folder.Path);
    }

    private async Task ShowRecentItemsAsync(bool filesOnly = false, bool projectsOnly = false)
    {
        await initialization;
        var recent = await recentItemsStore.LoadAsync();
        var choices = new List<RecentItemListItem>();
        if (!projectsOnly) choices.AddRange(recent.Files.Select(path => new RecentItemListItem(path, IsProject: false)));
        if (!filesOnly) choices.AddRange(recent.Projects.Select(path => new RecentItemListItem(path, IsProject: true)));
        if (choices.Count == 0)
        {
            Status.Text = filesOnly ? "There are no recent files."
                : projectsOnly ? "There are no recent projects."
                : "There are no recent files or projects.";
            return;
        }

        var list = new ListView
        {
            ItemsSource = choices, DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single,
            SelectedIndex = 0, MaxHeight = 420
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = filesOnly ? "Open Recent File"
                : projectsOnly ? "Open Recent Project" : "Open Recent", Content = list,
            PrimaryButtonText = "Open", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || list.SelectedItem is not RecentItemListItem selected) return;

        if (selected.IsProject)
        {
            if (!Directory.Exists(selected.Path))
            {
                Status.Text = "That recent project is no longer available.";
                return;
            }
            await OpenWorkspaceRootAsync(selected.Path);
            return;
        }
        if (!File.Exists(selected.Path))
        {
            Status.Text = "That recent file is no longer available.";
            return;
        }
        await OpenPathsCoreAsync([selected.Path]);
    }

    private async Task OpenWorkspaceRootAsync(string path)
    {
        await initialization;
        var normalized = WorkspaceRoots.Normalize(workspaceRoots.Append(path));
        if (normalized.SequenceEqual(workspaceRoots, StringComparer.OrdinalIgnoreCase))
        {
            await TryRememberProjectAsync(path);
            Status.Text = "The selected folder is already open.";
            return;
        }
        workspaceRoots.Clear();
        workspaceRoots.AddRange(normalized);
        workspaceWordsCancellation?.Cancel();
        workspaceWords = [];
        workspaceWordsAt = DateTimeOffset.MinValue;
        await ReloadProjectExclusionsAsync();
        RefreshWorkspaceTree();
        RestartWorkspaceWatchers();
        ReloadPlugins();
        await ReloadProjectKeyBindingsAsync();
        await TryRememberProjectAsync(path);
        await PersistAsync();
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        Status.Text = $"Opened folder {(String.IsNullOrEmpty(name) ? path : name)}.";
    }

    private void RefreshWorkspace_Click(object sender, RoutedEventArgs args)
    {
        RefreshWorkspaceTree();
        Status.Text = workspaceRoots.Count == 0 ? "No workspace folder is open." : "Workspace refreshed.";
    }

    private async void RemoveFolder_Click(object sender, RoutedEventArgs args)
    {
        if (WorkspaceTreeView.SelectedNode?.Content is not WorkspaceTreeItem { IsRoot: true } selected)
        {
            Status.Text = "Select a workspace root to remove it.";
            return;
        }
        var root = workspaceRoots.FirstOrDefault(candidate =>
            StringComparer.OrdinalIgnoreCase.Equals(candidate, selected.Path));
        if (root is null) return;
        await RemoveWorkspaceRootAsync(root);
    }

    private async Task ShowRemoveWorkspaceRootAsync()
    {
        if (workspaceRoots.Count == 0)
        {
            Status.Text = "There is no workspace folder to remove.";
            return;
        }
        var list = new ListView
        {
            ItemsSource = workspaceRoots.ToList(), SelectionMode = ListViewSelectionMode.Single,
            SelectedIndex = 0, MaxHeight = 420
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Remove Folder from Project", Content = list,
            PrimaryButtonText = "Remove", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not string root) return;
        await RemoveWorkspaceRootAsync(root);
    }

    private async Task RemoveWorkspaceRootAsync(string root)
    {
        if (languageServerRoot is not null && WorkspaceTree.IsInside(root, languageServerRoot))
        {
            await StopLanguageServerAsync();
        }
        if (StringComparer.OrdinalIgnoreCase.Equals(GitRoot, root)) GitPanel.Visibility = Visibility.Collapsed;
        workspaceRoots.Remove(root);
        workspaceWordsCancellation?.Cancel();
        workspaceWords = [];
        workspaceWordsAt = DateTimeOffset.MinValue;
        await ReloadProjectExclusionsAsync();
        RefreshWorkspaceTree();
        RestartWorkspaceWatchers();
        ReloadPlugins();
        await ReloadProjectKeyBindingsAsync();
        await PersistAsync();
        Status.Text = $"Removed folder {Path.GetFileName(root)} from the workspace.";
    }

    private async Task TryRememberFileAsync(string path)
    {
        try { await recentItemsStore.AddFileAsync(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or ArgumentException or InvalidOperationException or NotSupportedException) { }
    }

    private async Task TryRememberProjectAsync(string path)
    {
        try { await recentItemsStore.AddProjectAsync(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or ArgumentException or InvalidOperationException or NotSupportedException) { }
    }

    private void WorkspaceTree_Expanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Node.Content is not WorkspaceTreeItem item || !item.IsDirectory) return;
        PopulateWorkspaceNode(args.Node, item);
    }

    private async void WorkspaceTree_ItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not WorkspaceTreeItem item) return;
        args.Handled = true;
        if (item.IsDirectory)
        {
            var node = FindWorkspaceNode(WorkspaceTreeView.RootNodes, item.Path);
            if (node is not null) node.IsExpanded = !node.IsExpanded;
            return;
        }
        await OpenPathsAsync([item.Path]);
    }

    private async void NewWorkspaceFile_Click(object sender, RoutedEventArgs args) =>
        await CreateWorkspaceItemAsync(directory: false);

    private async void NewWorkspaceFolder_Click(object sender, RoutedEventArgs args) =>
        await CreateWorkspaceItemAsync(directory: true);

    private async void RenameWorkspaceItem_Click(object sender, RoutedEventArgs args) => await RenameWorkspaceItemAsync();

    private async void RecycleWorkspaceItem_Click(object sender, RoutedEventArgs args) => await RecycleWorkspaceItemAsync();

    private async void RevealWorkspaceItem_Click(object sender, RoutedEventArgs args) => await RevealWorkspaceItemAsync();

    private (string Root, WorkspaceTreeItem Item)? SelectedWorkspaceItem()
    {
        if (WorkspaceTreeView.SelectedNode?.Content is not WorkspaceTreeItem item) return null;
        var root = workspaceRoots.FirstOrDefault(candidate => WorkspaceTree.IsInside(candidate, item.Path));
        return root is null ? null : (root, item);
    }

    private (string Root, string Parent)? WorkspaceCreationTarget()
    {
        var selected = SelectedWorkspaceItem();
        if (selected is not null)
        {
            var parent = selected.Value.Item.IsDirectory
                ? selected.Value.Item.Path
                : Path.GetDirectoryName(selected.Value.Item.Path);
            if (parent is not null) return (selected.Value.Root, parent);
        }
        var root = workspaceRoots.FirstOrDefault();
        return root is null ? null : (root, root);
    }

    private async Task CreateWorkspaceItemAsync(bool directory)
    {
        var target = WorkspaceCreationTarget();
        if (target is null)
        {
            Status.Text = "Open a workspace folder first.";
            return;
        }
        var input = new TextBox { PlaceholderText = directory ? "Folder name" : "File name", MaxLength = 255 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = directory ? "New Folder" : "New File", Content = input,
            PrimaryButtonText = "Create", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            var path = directory
                ? WorkspaceFileOperations.CreateDirectory(target.Value.Root, target.Value.Parent, input.Text)
                : await WorkspaceFileOperations.CreateFileAsync(target.Value.Root, target.Value.Parent, input.Text);
            RefreshWorkspaceTree();
            if (!directory) await OpenPathsAsync([path]);
            Status.Text = $"Created {Path.GetFileName(path)}.";
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException
            or IOException or UnauthorizedAccessException)
        {
            Status.Text = error.Message;
        }
    }

    private async Task RenameWorkspaceItemAsync()
    {
        var selected = SelectedWorkspaceItem();
        if (selected is null || selected.Value.Item.IsRoot)
        {
            Status.Text = "Select a file or subfolder to rename.";
            return;
        }
        var input = new TextBox { Text = selected.Value.Item.Name, MaxLength = 255 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = $"Rename {selected.Value.Item.Name}", Content = input,
            PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            var previousPath = selected.Value.Item.Path;
            var target = WorkspaceFileOperations.Rename(selected.Value.Root, previousPath, input.Text);
            var changes = workspace.RemapPaths(previousPath, target);
            foreach (var change in changes)
            {
                paneLayout.RenameDocument(change.PreviousPath, change.CurrentPath);
                if (documentBuffers.Remove(change.PreviousPath, out var previousBuffer))
                {
                    documentBuffers[change.CurrentPath] = previousBuffer;
                }
                if (documentSelectionHistories.Remove(change.PreviousPath, out var selectionHistory))
                {
                    documentSelectionHistories[change.CurrentPath] = selectionHistory;
                }
                if (documentExpansionHistories.Remove(change.PreviousPath, out var expansionHistory))
                {
                    documentExpansionHistories[change.CurrentPath] = expansionHistory;
                }
                if (documentBookmarks.Remove(change.PreviousPath, out var previousBookmarks))
                {
                    documentBookmarks[change.CurrentPath] = previousBookmarks;
                }
                if (documentFoldingStates.Remove(change.PreviousPath, out var previousFolding))
                {
                    documentFoldingStates[change.CurrentPath] = previousFolding;
                }
                if (documentParserSnapshots.Remove(change.PreviousPath, out var parserSnapshot))
                {
                    documentParserSnapshots[change.CurrentPath] = parserSnapshot;
                }
                if (documentSavedBaselines.Remove(change.PreviousPath, out var baseline))
                    documentSavedBaselines[change.CurrentPath] = baseline;
                if (documentDiffSnapshots.Remove(change.PreviousPath, out var diffSnapshot))
                    documentDiffSnapshots[change.CurrentPath] = diffSnapshot;
                if (languageDiagnostics.Remove(change.PreviousPath, out var diagnosticSnapshot))
                    languageDiagnostics[change.CurrentPath] = diagnosticSnapshot with { Path = change.CurrentPath };
            }
            RefreshWorkspaceTree();
            RefreshWorkspace();
            Status.Text = $"Renamed to {Path.GetFileName(target)}.";
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException
            or IOException or UnauthorizedAccessException)
        {
            Status.Text = error.Message;
        }
    }

    private async Task RecycleWorkspaceItemAsync()
    {
        var selected = SelectedWorkspaceItem();
        if (selected is null || selected.Value.Item.IsRoot
            || !WorkspaceFileOperations.IsSafeTrashTarget(selected.Value.Root, selected.Value.Item.Path))
        {
            Status.Text = "Select a regular file or subfolder inside the workspace.";
            return;
        }
        var affected = workspace.Documents.Where(document =>
            !document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)
            && WorkspaceTree.IsInside(selected.Value.Item.Path, document.Path)).ToList();
        if (affected.Any(document => document.IsDirty))
        {
            Status.Text = "Save or close unsaved documents inside this item before moving it to the Recycle Bin.";
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = $"Move {selected.Value.Item.Name} to the Recycle Bin?",
            Content = selected.Value.Item.Path, PrimaryButtonText = "Recycle", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            if (selected.Value.Item.IsDirectory)
            {
                var folder = await StorageFolder.GetFolderFromPathAsync(selected.Value.Item.Path);
                await folder.DeleteAsync(StorageDeleteOption.Default);
            }
            else
            {
                var file = await StorageFile.GetFileFromPathAsync(selected.Value.Item.Path);
                await file.DeleteAsync(StorageDeleteOption.Default);
            }
            foreach (var document in affected)
            {
                workspace.Close(document.Path);
                paneLayout.Remove(document.Path);
                documentBuffers.Remove(document.Path);
                documentSelectionHistories.Remove(document.Path);
                documentExpansionHistories.Remove(document.Path);
                documentBookmarks.Remove(document.Path);
                documentFoldingStates.Remove(document.Path);
            }
            RefreshWorkspaceTree();
            RefreshWorkspace();
            Status.Text = $"Moved {selected.Value.Item.Name} to the Recycle Bin.";
        }
        catch (Exception error)
        {
            Status.Text = $"Could not move the item to the Recycle Bin: {error.Message}";
        }
    }

    private async Task RevealWorkspaceItemAsync()
    {
        var selected = SelectedWorkspaceItem();
        var path = selected?.Item.Path ?? workspace.ActiveDocument?.Path;
        if (path is null || path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            var folderPath = Directory.Exists(path) ? path : Path.GetDirectoryName(path);
            if (folderPath is null) return;
            var folder = await StorageFolder.GetFolderFromPathAsync(folderPath);
            var options = new FolderLauncherOptions();
            if (File.Exists(path)) options.ItemsToSelect.Add(await StorageFile.GetFileFromPathAsync(path));
            if (!await Launcher.LaunchFolderAsync(folder, options)) Status.Text = "Explorer could not reveal the item.";
        }
        catch (Exception error)
        {
            Status.Text = $"Explorer could not reveal the item: {error.Message}";
        }
    }

    private async void Save_Click(object sender, RoutedEventArgs args)
    {
        await SaveActiveAsync();
    }

    private async void SaveAs_Click(object sender, RoutedEventArgs args) => await SaveActiveAsync(forcePicker: true);

    private async void SaveAll_Click(object sender, RoutedEventArgs args) => await SaveAllAsync();

    private async void AutoSave_Click(object sender, RoutedEventArgs args) => await CycleAutoSaveAsync();

    private async void CloseDocument_Click(object sender, RoutedEventArgs args)
    {
        await CloseActiveDocumentAsync();
    }

    private async void ReopenClosed_Click(object sender, RoutedEventArgs args) => await ReopenClosedDocumentAsync();

    private async void Encoding_Click(object sender, RoutedEventArgs args) => await SelectEncodingAsync();

    private async void ReopenEncoding_Click(object sender, RoutedEventArgs args) => await ReopenActiveWithEncodingAsync();

    private async void LineEnding_Click(object sender, RoutedEventArgs args) => await SelectLineEndingAsync();

    private void Undo_Click(object sender, RoutedEventArgs args)
    {
        if (buffer.Undo()) ApplyBufferToEditor();
    }

    private void Redo_Click(object sender, RoutedEventArgs args)
    {
        if (buffer.Redo()) ApplyBufferToEditor();
    }

    private void TrimWhitespace_Click(object sender, RoutedEventArgs args)
    {
        SynchronizeBufferSelection();
        if (buffer.TrimTrailingWhitespace())
        {
            ApplyBufferToEditor();
            Status.Text = "Trailing whitespace removed.";
        }
    }

    private void FinalNewline_Click(object sender, RoutedEventArgs args)
    {
        SynchronizeBufferSelection();
        if (buffer.EnsureSingleFinalNewline())
        {
            ApplyBufferToEditor();
            Status.Text = "Document now has one final newline.";
        }
    }

    private async void EditLines_Click(object sender, RoutedEventArgs args) => await ShowLineEditingMenuAsync();

    private async void EditMore_Click(object sender, RoutedEventArgs args) => await ShowMoreEditingMenuAsync();

    private async void Macro_Click(object sender, RoutedEventArgs args) => await ShowMacroMenuAsync();

    private async void Build_Click(object sender, RoutedEventArgs args) => await SelectAndRunBuildAsync();

    private async void Git_Click(object sender, RoutedEventArgs args) => await RefreshGitAsync();

    private void Preview_Click(object sender, RoutedEventArgs args) => TogglePreview();

    private async void LanguageStatus_Click(object sender, RoutedEventArgs args) => await SelectLanguageAsync();

    private async void Terminal_Click(object sender, RoutedEventArgs args)
    {
        TerminalPanel.Visibility = TerminalPanel.Visibility == Visibility.Visible
            ? Visibility.Collapsed : Visibility.Visible;
        BuildPanel.Visibility = Visibility.Collapsed;
        GitPanel.Visibility = Visibility.Collapsed;
        WorkspaceResultsPanel.Visibility = Visibility.Collapsed;
        if (TerminalPanel.Visibility == Visibility.Visible)
        {
            if (terminalSession is null) await StartTerminalAsync();
            TerminalInput.Focus(FocusState.Programmatic);
        }
    }

    private void LanguageServer_Click(object sender, RoutedEventArgs args) => ShowLanguageServerSettings();

    private void Plugins_Click(object sender, RoutedEventArgs args) => ShowPlugins();

    private async void StartTerminal_Click(object sender, RoutedEventArgs args) => await StartTerminalAsync();

    private async void StopTerminal_Click(object sender, RoutedEventArgs args) => await StopTerminalAsync();

    private void ClearTerminal_Click(object sender, RoutedEventArgs args) => TerminalOutput.Text = String.Empty;

    private void CloseTerminal_Click(object sender, RoutedEventArgs args)
    {
        TerminalPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private async void TerminalInput_KeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Enter || terminalSession is null) return;
        args.Handled = true;
        var text = TerminalInput.Text;
        TerminalInput.Text = String.Empty;
        if (String.IsNullOrEmpty(text)) return;
        try { await terminalSession.WriteAsync(text + "\r\n"); }
        catch (Exception error) when (error is ArgumentException or ObjectDisposedException or IOException)
        {
            TerminalStatus.Text = error.Message;
        }
    }

    private async void SaveLanguageServerSettings_Click(object sender, RoutedEventArgs args)
    {
        settings = EditorSettings.Sanitize(settings with
        {
            LanguageServerLanguageId = LanguageIdSetting.Text,
            LanguageServerCommand = LanguageServerCommandSetting.Text,
            LanguageServerArguments = LanguageServerArgumentsSetting.Text
        });
        await settingsStore.SaveAsync(settings);
        await StopLanguageServerAsync();
        LanguageServerSettingsPanel.Visibility = Visibility.Collapsed;
        LanguageServerPanel.Visibility = Visibility.Visible;
        LanguageServerStatus.Text = "Language-server configuration saved.";
    }

    private void CloseLanguageServerSettings_Click(object sender, RoutedEventArgs args)
    {
        LanguageServerSettingsPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private async void LspHover_Click(object sender, RoutedEventArgs args) => await RunLanguageRequestAsync("textDocument/hover");

    private async void LspDefinition_Click(object sender, RoutedEventArgs args) => await RunLanguageRequestAsync("textDocument/definition");

    private async void LspReferences_Click(object sender, RoutedEventArgs args) => await RunLanguageRequestAsync("textDocument/references");

    private async void LspRename_Click(object sender, RoutedEventArgs args)
    {
        var input = new TextBox { PlaceholderText = "New symbol name", MaxLength = 1_024 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Preview Rename", Content = input,
            PrimaryButtonText = "Preview", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || String.IsNullOrWhiteSpace(input.Text)) return;
        await RunLanguageRequestAsync("textDocument/rename", new { newName = input.Text.Trim() });
    }

    private async void ApplyLspRename_Click(object sender, RoutedEventArgs args)
    {
        if (languageRenamePreview is null)
        {
            LanguageServerStatus.Text = "Preview a rename before applying it.";
            return;
        }
        var dirtyPaths = workspace.Documents.Where(document => document.IsDirty)
            .Select(document => document.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (languageRenamePreview.Files.Any(file => dirtyPaths.Contains(file.Path)))
        {
            LanguageServerStatus.Text = "Save or close affected files with unsaved edits before applying rename.";
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Apply language-server rename?",
            Content = $"Apply {languageRenamePreview.EditCount} edit(s) to {languageRenamePreview.Files.Count} file(s)?",
            PrimaryButtonText = "Apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var result = await languageRenameService.ApplyAsync(languageRenamePreview);
        if (!result.Succeeded)
        {
            LanguageServerStatus.Text = result.Error ?? "Rename failed.";
            return;
        }
        languageRenameUndo = result.Undo;
        languageRenamePreview = null;
        await ReloadCleanOpenDocumentsAsync();
        LanguageServerStatus.Text = $"Applied {result.Edits} rename edit(s) to {result.Files} file(s).";
    }

    private async void UndoLspRename_Click(object sender, RoutedEventArgs args)
    {
        if (languageRenameUndo is null)
        {
            LanguageServerStatus.Text = "There is no recent language-server rename to undo.";
            return;
        }
        var result = await languageRenameService.UndoAsync(languageRenameUndo);
        if (!result.Succeeded)
        {
            LanguageServerStatus.Text = result.Error ?? "Rename could not be undone.";
            return;
        }
        languageRenameUndo = null;
        await ReloadCleanOpenDocumentsAsync();
        LanguageServerStatus.Text = $"Undid rename in {result.Files} file(s).";
    }

    private async void CloseLanguageServer_Click(object sender, RoutedEventArgs args)
    {
        await StopLanguageServerAsync();
        LanguageServerPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private async void InstallPlugin_Click(object sender, RoutedEventArgs args)
    {
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            PluginsStatus.Text = "Open a workspace folder before installing a plugin.";
            return;
        }
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        DeclarativePlugin manifest;
        try
        {
            var bytes = await File.ReadAllBytesAsync(Path.Combine(folder.Path, "plugin.json"));
            manifest = DeclarativePluginParser.Parse(bytes)
                ?? throw new InvalidDataException("plugin.json is invalid.");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            PluginsStatus.Text = error.Message;
            return;
        }
        var confirmation = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = $"Install {manifest.Name}?",
            Content = manifest.Extension is null
                ? $"This installs {manifest.Commands.Count} declarative text command(s) and {manifest.Snippets.Count} snippet(s)."
                : $"This installs {manifest.Commands.Count} declarative text command(s), {manifest.Snippets.Count} snippet(s), and one isolated worker. Its requested permissions will be reviewed separately before execution.",
            PrimaryButtonText = "Install", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            var installed = await new DeclarativePluginStore(root).InstallAsync(folder.Path);
            await EnableProjectPluginAsync(root, installed.Id);
            ReloadPlugins();
            PluginsStatus.Text = $"Installed {manifest.Name}.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or InvalidOperationException)
        {
            PluginsStatus.Text = error.Message;
        }
    }

    private async Task EnableProjectPluginAsync(string root, string pluginId)
    {
        var store = new ProjectSettingsStore(root);
        var snapshot = await store.LoadAsync();
        var saved = await store.SaveAsync(ProjectBuildSettings.EnablePlugin(snapshot.Json, pluginId), snapshot.Revision);
        if (!saved.Saved) throw new IOException(saved.Message ?? "Plugin could not be enabled for this project.");
    }

    private async void InsertSnippet_Click(object sender, RoutedEventArgs args) => await ShowSnippetPickerAsync();

    private void ClosePlugins_Click(object sender, RoutedEventArgs args)
    {
        PluginsPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private async void LanguageDiagnostic_ItemClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is not LanguageDiagnosticListItem item) return;
        await NavigateToAsync(item.Diagnostic.Path, item.Diagnostic.Line + 1, item.Diagnostic.Character + 1);
    }

    private void StopBuild_Click(object sender, RoutedEventArgs args)
    {
        buildCancellation?.Cancel();
        BuildStatus.Text = "Stopping build…";
    }

    private void CloseBuild_Click(object sender, RoutedEventArgs args)
    {
        BuildPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private async void GitFiles_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        await RefreshGitDiffAsync();
    }

    private async void StageGit_Click(object sender, RoutedEventArgs args)
    {
        await RunGitPathActionAsync(stage: true);
    }

    private async void UnstageGit_Click(object sender, RoutedEventArgs args)
    {
        await RunGitPathActionAsync(stage: false);
    }

    private async void DiscardGit_Click(object sender, RoutedEventArgs args) =>
        await DiscardGitSelectionAsync();

    private async void StageGitHunk_Click(object sender, RoutedEventArgs args) =>
        await ApplySelectedGitHunkAsync(stage: true);

    private async void DiscardGitHunk_Click(object sender, RoutedEventArgs args) =>
        await ApplySelectedGitHunkAsync(stage: false);

    private async void GitHistory_Click(object sender, RoutedEventArgs args) =>
        await ShowGitHistoryAsync();

    private async void GitBlame_Click(object sender, RoutedEventArgs args) =>
        await ShowGitBlameAsync();

    private async void SwitchGitBranch_Click(object sender, RoutedEventArgs args) =>
        await ChangeGitBranchAsync(create: false);

    private async void CreateGitBranch_Click(object sender, RoutedEventArgs args) =>
        await ChangeGitBranchAsync(create: true);

    private void GitHunkPicker_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (GitHunkPicker.SelectedItem is GitHunk hunk) GitDiffOutput.Text = hunk.Patch;
    }

    private async void CommitGit_Click(object sender, RoutedEventArgs args) => await CommitGitAsync();

    private void CloseGit_Click(object sender, RoutedEventArgs args)
    {
        GitPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private void LayoutSingle_Click(object sender, RoutedEventArgs args) => SetPaneLayout(PaneLayoutKind.Single);

    private void LayoutColumns2_Click(object sender, RoutedEventArgs args) => SetPaneLayout(PaneLayoutKind.Columns2);

    private void LayoutColumns3_Click(object sender, RoutedEventArgs args) => SetPaneLayout(PaneLayoutKind.Columns3);

    private void LayoutGrid4_Click(object sender, RoutedEventArgs args) => SetPaneLayout(PaneLayoutKind.Grid4);

    private void MoveDocumentNextPane_Click(object sender, RoutedEventArgs args) => MoveDocumentToNextPane(clone: false);

    private void CloneDocumentNextPane_Click(object sender, RoutedEventArgs args) => MoveDocumentToNextPane(clone: true);

    private void SplitSelectedTabs_Click(object sender, RoutedEventArgs args) => SplitSelectedTabs();

    private void FocusNextPane_Click(object sender, RoutedEventArgs args)
    {
        paneLayout.FocusNext();
        ActivateCurrentPaneDocument();
        Editor.Focus(FocusState.Programmatic);
    }

    private void SetPaneLayout(PaneLayoutKind kind)
    {
        SynchronizeBufferSelection();
        paneLayout.SetKind(kind);
        ApplyPaneLayoutVisuals();
        RefreshEditors();
        Status.Text = kind switch
        {
            PaneLayoutKind.Single => "Single-pane layout.",
            PaneLayoutKind.Columns2 => "Two-column layout.",
            PaneLayoutKind.Columns3 => "Three-column layout.",
            _ => "Four-pane grid layout."
        };
    }

    private void MoveDocumentToNextPane(bool clone)
    {
        var document = workspace.ActiveDocument;
        if (document is null) return;
        SynchronizeBufferSelection();
        if (paneLayout.Kind == PaneLayoutKind.Single) paneLayout.SetKind(PaneLayoutKind.Columns2);
        if (!paneLayout.MoveToNext(document.Path, clone)) return;
        ApplyPaneLayoutVisuals();
        RefreshEditors();
        Editor.Focus(FocusState.Programmatic);
        Status.Text = clone ? "Document cloned to the next pane." : "Document moved to the next pane.";
    }

    private void SplitSelectedTabs()
    {
        SynchronizeBufferSelection();
        var selectedPaths = DocumentList.SelectedItems
            .OfType<OpenedDocument>()
            .Select(document => document.Path)
            .ToList();
        var splitCount = paneLayout.Panes[paneLayout.ActivePane]
            .Count(selectedPaths.ToHashSet(StringComparer.Ordinal).Contains);
        if (!paneLayout.SplitSelectedTabs(selectedPaths)) return;
        ActivateCurrentPaneDocument();
        ApplyPaneLayoutVisuals();
        RefreshDocumentList();
        Editor.Focus(FocusState.Programmatic);
        Status.Text = splitCount >= 2
            ? Localize(
                $"Split {Math.Min(splitCount, 4)} selected documents into panes.",
                $"已将 {Math.Min(splitCount, 4)} 个所选文档拆分到窗格。")
            : Localize("The active document was cloned to the next pane.", "已将活动文档复制到下一窗格。");
        _ = PersistAsync();
    }

    private void ActivateCurrentPaneDocument()
    {
        var path = paneLayout.ActiveDocument;
        if (path is null && workspace.ActiveDocument is { } current)
        {
            paneLayout.Activate(current.Path);
            path = current.Path;
        }
        if (path is not null) workspace.Activate(path);
        DocumentList.SelectedItem = workspace.ActiveDocument;
        RefreshEditors();
    }

    private void ApplyPaneLayoutVisuals()
    {
        for (var index = 0; index < paneHosts.Length; index++)
        {
            paneHosts[index].Visibility = index < paneLayout.Panes.Count ? Visibility.Visible : Visibility.Collapsed;
            paneHosts[index].BorderThickness = index == paneLayout.ActivePane ? new Thickness(2) : new Thickness(1);
            Grid.SetRow(paneHosts[index], 0);
            Grid.SetColumn(paneHosts[index], index);
            Grid.SetRowSpan(paneHosts[index], 2);
            Grid.SetColumnSpan(paneHosts[index], 1);
        }
        EditorPaneGrid.ColumnDefinitions[0].Width = new GridLength(1, GridUnitType.Star);
        EditorPaneGrid.ColumnDefinitions[1].Width = paneLayout.Kind == PaneLayoutKind.Single
            ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        EditorPaneGrid.ColumnDefinitions[2].Width = paneLayout.Kind == PaneLayoutKind.Columns3
            ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        EditorPaneGrid.RowDefinitions[0].Height = new GridLength(1, GridUnitType.Star);
        EditorPaneGrid.RowDefinitions[1].Height = paneLayout.Kind == PaneLayoutKind.Grid4
            ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        if (paneLayout.Kind == PaneLayoutKind.Single) Grid.SetColumnSpan(Pane0Host, 3);
        if (paneLayout.Kind == PaneLayoutKind.Grid4)
        {
            for (var index = 0; index < paneHosts.Length; index++)
            {
                Grid.SetRow(paneHosts[index], index / 2);
                Grid.SetColumn(paneHosts[index], index % 2);
                Grid.SetRowSpan(paneHosts[index], 1);
            }
        }
        for (var index = 0; index < editors.Length; index++) QueueLineNumberRefresh(index);
    }

    private void AttachEditorScrollViewer(int paneIndex)
    {
        if (paneIndex < 0 || paneIndex >= editors.Length) return;
        var editor = editors[paneIndex];
        if (editorScrollViewers.ContainsKey(editor)) return;
        var scrollViewer = FindVisualChild<ScrollViewer>(editor);
        if (scrollViewer is null)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                var deferred = FindVisualChild<ScrollViewer>(editor);
                if (deferred is null || editorScrollViewers.ContainsKey(editor)) return;
                editorScrollViewers[editor] = deferred;
                deferred.ViewChanged += (_, _) => QueueLineNumberRefresh(paneIndex);
                QueueLineNumberRefresh(paneIndex);
            });
            return;
        }
        editorScrollViewers[editor] = scrollViewer;
        scrollViewer.ViewChanged += (_, _) => QueueLineNumberRefresh(paneIndex);
        QueueLineNumberRefresh(paneIndex);
    }

    private static T? FindVisualChild<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match) return match;
            if (FindVisualChild<T>(child) is { } descendant) return descendant;
        }
        return null;
    }

    private void InvalidateLineNumbers(int paneIndex)
    {
        if (paneIndex < 0 || paneIndex >= editors.Length) return;
        paneLineIndexes[paneIndex] = null;
        minimapDirty[paneIndex] = true;
        QueueLineNumberRefresh(paneIndex);
    }

    private void QueueLineNumberRefresh(int paneIndex)
    {
        if (paneIndex < 0 || paneIndex >= editors.Length || lineNumberRefreshQueued[paneIndex]) return;
        lineNumberRefreshQueued[paneIndex] = true;
        if (!DispatcherQueue.TryEnqueue(() =>
        {
            lineNumberRefreshQueued[paneIndex] = false;
            RefreshLineNumbers(paneIndex);
        }))
        {
            lineNumberRefreshQueued[paneIndex] = false;
        }
    }

    private void RefreshLineNumbers(int paneIndex)
    {
        var gutter = lineNumberGutters[paneIndex];
        var canvas = lineNumberCanvases[paneIndex];
        var whitespaceCanvas = whitespaceCanvases[paneIndex];
        var decorationCanvas = decorationCanvases[paneIndex];
        var selectionCanvas = multiSelectionCanvases[paneIndex];
        var minimapCanvas = minimapCanvases[paneIndex];
        canvas.Children.Clear();
        whitespaceCanvas.Children.Clear();
        decorationCanvas.Children.Clear();
        selectionCanvas.Children.Clear();
        if (paneHosts[paneIndex].Visibility != Visibility.Visible) return;

        var editor = editors[paneIndex];
        var path = paneIndex < paneLayout.ActiveDocuments.Count ? paneLayout.ActiveDocuments[paneIndex] : null;
        gutter.Visibility = settings.ShowLineNumbers
            || path is not null && documentFoldingStates.TryGetValue(path, out var gutterFolding)
                && gutterFolding.Regions.Count > 0
            || path is not null && documentDiffSnapshots.TryGetValue(path, out var gutterDiff)
                && gutterDiff.Changes.Count > 0
            ? Visibility.Visible : Visibility.Collapsed;
        var text = path is not null && documentBuffers.TryGetValue(path, out var indexedBuffer)
            ? indexedBuffer.Text : path is not null ? workspace.Find(path)?.Content ?? String.Empty : String.Empty;
        var hiddenRanges = path is not null && documentFoldingStates.TryGetValue(path, out var foldingState)
            ? foldingState.HiddenRanges : [];
        bool IsHidden(int offset) => hiddenRanges.Any(range => offset >= range.Start && offset < range.End);
        if (paneLineIndexes[paneIndex] is null)
        {
            paneLineIndexes[paneIndex] = new SparseLineIndex(text);
        }
        var lineIndex = paneLineIndexes[paneIndex] ?? new SparseLineIndex(text);
        var viewportHeight = Math.Max(editor.ActualHeight, 1);
        gutter.Width = settings.ShowLineNumbers ? Math.Clamp(22 + lineIndex.LineCount.ToString(
            System.Globalization.CultureInfo.InvariantCulture).Length * Math.Max(7, settings.FontSize * 0.62), 48, 112) : 18;
        global::Windows.Foundation.Rect LineRect(int offset)
        {
            if (text.Length == 0) return new global::Windows.Foundation.Rect(0, 4, 0, settings.FontSize * 1.4);
            return editor.GetRectFromCharacterIndex(offset, false);
        }
        var probeOffset = Math.Clamp(editor.SelectionStart, 0, text.Length);
        var firstLine = lineIndex.LineAtOffset(probeOffset);
        var low = 0;
        var high = lineIndex.LineCount - 1;
        while (low <= high && text.Length > 0)
        {
            var middle = low + (high - low) / 2;
            var y = LineRect(lineIndex.StartOffset(middle)).Y;
            if (y < -settings.FontSize * 2) low = middle + 1;
            else
            {
                firstLine = middle;
                high = middle - 1;
            }
        }

        const int maximumVisibleLines = 500;
        var visibleDetails = lineIndex.LineDetailsFrom(
            firstLine, maximumVisibleLines, tabWidth: settings.TabSize);
        RefreshEditorDecorations(paneIndex, editor, decorationCanvas, text, lineIndex,
            visibleDetails, IsHidden, viewportHeight, path);
        if (settings.ShowLineNumbers) foreach (var line in lineIndex.LinesFrom(firstLine, maximumVisibleLines))
        {
            if (IsHidden(line.StartOffset)) continue;
            var y = LineRect(line.StartOffset).Y;
            if (y > viewportHeight + settings.FontSize * 2) break;
            if (y < -settings.FontSize * 2) continue;
            var label = new TextBlock
            {
                Text = line.Number.ToString(System.Globalization.CultureInfo.InvariantCulture),
                FontFamily = editor.FontFamily, FontSize = editor.FontSize, Opacity = 0.62,
                Width = 42, TextAlignment = TextAlignment.Right, IsHitTestVisible = false
            };
            Canvas.SetTop(label, y);
            canvas.Children.Add(label);
        }
        if (path is not null && documentFoldingStates.TryGetValue(path, out var visibleFolding))
        {
            foreach (var region in visibleFolding.Regions
                .Where(region => region.StartLine - 1 >= firstLine
                    && region.StartLine - 1 < firstLine + maximumVisibleLines)
                .GroupBy(region => region.StartLine).Select(group => group.OrderBy(region => region.FullRange.Length).First()))
            {
                var y = LineRect(lineIndex.StartOffset(region.StartLine - 1)).Y;
                if (y < -settings.FontSize * 2 || y > viewportHeight + settings.FontSize * 2) continue;
                var folded = visibleFolding.IsFolded(region);
                var button = new Button
                {
                    Content = folded ? "▸" : "⌄", Tag = new FoldMarkerTag(paneIndex, path, region.StartLine),
                    Width = 16, Height = Math.Max(16, settings.FontSize * 1.25), Padding = new Thickness(0),
                    FontSize = Math.Max(8, settings.FontSize - 3), Background = null,
                    BorderThickness = new Thickness(0), IsTabStop = true
                };
                AutomationProperties.SetName(button, folded
                    ? $"Expand folded region starting at line {region.StartLine}"
                    : $"Fold region starting at line {region.StartLine}");
                button.Click += FoldMarker_Click;
                Canvas.SetLeft(button, 0);
                Canvas.SetTop(button, y);
                canvas.Children.Add(button);
            }
        }
        if (path is not null && documentBuffers.TryGetValue(path, out var diffBuffer)
            && documentDiffSnapshots.TryGetValue(path, out var diffSnapshot)
            && diffSnapshot.Revision == diffBuffer.Revision)
        {
            foreach (var change in diffSnapshot.Changes.Where(change =>
                change.Line - 1 >= firstLine && change.Line - 1 < firstLine + maximumVisibleLines))
            {
                var markerLine = Math.Clamp(change.Line - 1, 0, lineIndex.LineCount - 1);
                var y = LineRect(lineIndex.StartOffset(markerLine)).Y;
                if (y < -settings.FontSize * 2 || y > viewportHeight + settings.FontSize * 2) continue;
                var color = change.Kind switch
                {
                    IncrementalChangeKind.Added => global::Windows.UI.Color.FromArgb(255, 46, 160, 67),
                    IncrementalChangeKind.Deleted => global::Windows.UI.Color.FromArgb(255, 248, 81, 73),
                    _ => global::Windows.UI.Color.FromArgb(255, 210, 153, 34)
                };
                var marker = new Rectangle
                {
                    Width = 4, Height = Math.Min(viewportHeight, Math.Max(settings.FontSize * 1.3,
                        Math.Max(1, change.LineCount) * settings.FontSize * 1.3)),
                    Fill = new SolidColorBrush(color), IsHitTestVisible = false
                };
                Canvas.SetLeft(marker, Math.Max(0, gutter.Width - 4));
                Canvas.SetTop(marker, y);
                canvas.Children.Add(marker);
            }
        }
        if (settings.ShowWhitespace && text.Length > 0) foreach (var marker in lineIndex.WhitespaceFrom(firstLine, maximumVisibleLines))
        {
            if (IsHidden(marker.Offset)) continue;
            var rect = editor.GetRectFromCharacterIndex(marker.Offset, false);
            if (rect.Y < -settings.FontSize * 2 || rect.Y > viewportHeight + settings.FontSize * 2) continue;
            var label = new TextBlock
            {
                Text = marker.IsTab ? "→" : "·", FontFamily = editor.FontFamily,
                FontSize = editor.FontSize, Opacity = 0.46, IsHitTestVisible = false
            };
            Canvas.SetLeft(label, rect.X);
            Canvas.SetTop(label, rect.Y);
            whitespaceCanvas.Children.Add(label);
        }
        RefreshSecondarySelections(paneIndex, editor, selectionCanvas, lineIndex, viewportHeight);
        RefreshMinimap(paneIndex, editor, minimapCanvas, lineIndex, firstLine, viewportHeight);
    }

    private void RefreshEditorDecorations(
        int paneIndex, NativeCodeEditor editor, Canvas canvas, string text, SparseLineIndex lineIndex,
        IReadOnlyList<IndexedLineDetail> visibleLines, Func<int, bool> isHidden, double viewportHeight, string? path)
    {
        if (text.Length == 0) return;
        const int maximumDecorations = 2_000;
        var decorationCount = 0;
        var dark = settings.ColorScheme != EditorColorScheme.Light;
        var guideBrush = new SolidColorBrush(dark
            ? global::Windows.UI.Color.FromArgb(95, 98, 114, 135)
            : global::Windows.UI.Color.FromArgb(80, 87, 96, 106));
        var activeBrush = new SolidColorBrush(dark
            ? global::Windows.UI.Color.FromArgb(34, 136, 192, 208)
            : global::Windows.UI.Color.FromArgb(24, 9, 105, 218));
        var matchBrush = new SolidColorBrush(dark
            ? global::Windows.UI.Color.FromArgb(90, 229, 192, 123)
            : global::Windows.UI.Color.FromArgb(65, 191, 135, 0));
        var trailingBrush = new SolidColorBrush(dark
            ? global::Windows.UI.Color.FromArgb(110, 224, 108, 117)
            : global::Windows.UI.Color.FromArgb(85, 207, 34, 46));
        var diagnosticBrush = new SolidColorBrush(global::Windows.UI.Color.FromArgb(220, 224, 70, 70));
        var bracketBrush = new SolidColorBrush(dark
            ? global::Windows.UI.Color.FromArgb(130, 86, 182, 194)
            : global::Windows.UI.Color.FromArgb(100, 9, 105, 218));
        var activeLine = lineIndex.LineAtOffset(Math.Clamp(editor.SelectionStart, 0, text.Length));
        var activeStart = lineIndex.StartOffset(activeLine);
        if (!isHidden(activeStart))
        {
            var rect = TextPositionRect(editor, text, activeStart);
            if (rect.Y >= -editor.FontSize * 2 && rect.Y <= viewportHeight + editor.FontSize * 2)
            {
                var marker = new Rectangle
                {
                    Width = Math.Max(1, editor.ActualWidth), Height = Math.Max(rect.Height, editor.FontSize * 1.35),
                    Fill = activeBrush, IsHitTestVisible = false
                };
                Canvas.SetLeft(marker, 0);
                Canvas.SetTop(marker, rect.Y);
                canvas.Children.Add(marker);
                decorationCount++;
            }
        }

        var origin = TextPositionRect(editor, text, visibleLines.FirstOrDefault()?.StartOffset ?? 0);
        var cellWidth = Math.Max(1, editor.FontSize * 0.62);
        foreach (var column in settings.Rulers ?? [])
        {
            if (decorationCount >= maximumDecorations) break;
            var x = origin.X + column * cellWidth;
            var ruler = new LineShape
            {
                X1 = x, X2 = x, Y1 = 0, Y2 = viewportHeight, Stroke = guideBrush,
                StrokeThickness = 1, Opacity = 0.75, IsHitTestVisible = false
            };
            canvas.Children.Add(ruler);
            decorationCount++;
        }

        foreach (var line in visibleLines)
        {
            if (decorationCount >= maximumDecorations) break;
            if (isHidden(line.StartOffset)) continue;
            var lineRect = TextPositionRect(editor, text, line.StartOffset);
            if (lineRect.Y > viewportHeight + editor.FontSize * 2) break;
            if (lineRect.Y < -editor.FontSize * 2) continue;
            if (settings.ShowIndentGuides && line.IndentColumns >= settings.TabSize)
            {
                for (var column = settings.TabSize; column <= line.IndentColumns; column += settings.TabSize)
                {
                    if (decorationCount >= maximumDecorations) break;
                    var x = lineRect.X + column * cellWidth;
                    canvas.Children.Add(new LineShape
                    {
                        X1 = x, X2 = x, Y1 = lineRect.Y,
                        Y2 = lineRect.Y + Math.Max(lineRect.Height, editor.FontSize * 1.35),
                        Stroke = guideBrush, StrokeThickness = 1, IsHitTestVisible = false
                    });
                    decorationCount++;
                }
            }
            if (settings.HighlightTrailingWhitespace
                && line.TrailingWhitespaceStart < line.ContentEndOffset)
            {
                AddRangeDecoration(editor, canvas, text, line.TrailingWhitespaceStart,
                    line.ContentEndOffset, trailingBrush, 0.58);
                decorationCount++;
            }
        }
        if (path is not null && languageDiagnostics.TryGetValue(path, out var diagnosticSnapshot)
            && diagnosticSnapshot.Version is { } diagnosticVersion
            && languageServer?.SynchronizedDocument(path) is { } synchronized
            && synchronized.Version == diagnosticVersion && synchronized.Content == text)
        {
            foreach (var diagnostic in diagnosticSnapshot.Diagnostics.Take(1_000))
            {
                if (decorationCount >= maximumDecorations) break;
                var from = TextNavigation.LineColumnToOffset(
                    text, diagnostic.Line + 1, diagnostic.Character + 1);
                var to = TextNavigation.LineColumnToOffset(
                    text, diagnostic.EndLine + 1, diagnostic.EndCharacter + 1);
                if (to <= from || isHidden(from)) continue;
                var leading = TextPositionRect(editor, text, from);
                var trailing = TextPositionRect(editor, text, Math.Max(from, to - 1), trailing: true);
                if (leading.Y < -editor.FontSize * 2 || leading.Y > viewportHeight + editor.FontSize * 2
                    || Math.Abs(trailing.Y - leading.Y) > editor.FontSize * 1.5) continue;
                canvas.Children.Add(new LineShape
                {
                    X1 = leading.X, X2 = Math.Max(leading.X + 2, trailing.X),
                    Y1 = leading.Y + Math.Max(leading.Height, editor.FontSize * 1.25) - 2,
                    Y2 = leading.Y + Math.Max(leading.Height, editor.FontSize * 1.25) - 2,
                    Stroke = diagnosticBrush, StrokeThickness = 2, IsHitTestVisible = false
                });
                decorationCount++;
            }
        }
        if (path is not null && documentParserSnapshots.TryGetValue(path, out var parserSnapshot)
            && parserSnapshot.Text == text && !parserSnapshot.Analysis.Truncated.BracketPairs)
        {
            var caret = Math.Clamp(editor.SelectionStart, 0, text.Length);
            var pair = parserSnapshot.Analysis.BracketPairs.FirstOrDefault(candidate =>
                candidate.Open == caret || candidate.Close == caret
                    || candidate.Open + 1 == caret || candidate.Close + 1 == caret);
            if (pair is not null)
            {
                AddRangeDecoration(editor, canvas, text, pair.Open, pair.Open + 1, bracketBrush, 0.72);
                AddRangeDecoration(editor, canvas, text, pair.Close, pair.Close + 1, bracketBrush, 0.72);
            }
        }

        EditorBuffer? paneSelectionBuffer = null;
        if (paneIndex < paneLayout.ActiveDocuments.Count
            && paneLayout.ActiveDocuments[paneIndex] is { } paneSelectionPath)
            documentBuffers.TryGetValue(paneSelectionPath, out paneSelectionBuffer);
        var selection = paneSelectionBuffer?.Selection
            ?? new TextSelection(editor.SelectionStart, editor.SelectionStart + editor.SelectionLength);
        if (selection.Length is <= 0 or > 200 || selection.Start + selection.Length > text.Length
            || text.AsSpan(selection.Start, selection.Length).ContainsAny('\r', '\n')) return;
        var needle = text.Substring(selection.Start, selection.Length);
        var visibleStart = visibleLines.FirstOrDefault()?.StartOffset ?? 0;
        var visibleEnd = visibleLines.LastOrDefault()?.EndOffset ?? text.Length;
        var cursor = Math.Max(0, visibleStart);
        var matches = 0;
        while (cursor < visibleEnd && matches < 500 && decorationCount < maximumDecorations)
        {
            var found = text.IndexOf(needle, cursor, Math.Max(0, visibleEnd - cursor), StringComparison.Ordinal);
            if (found < 0) break;
            if (found != selection.Start && !isHidden(found))
            {
                AddRangeDecoration(editor, canvas, text, found, found + needle.Length, matchBrush, 0.5);
                matches++;
                decorationCount++;
            }
            cursor = found + Math.Max(1, needle.Length);
        }
    }

    private static void AddRangeDecoration(NativeCodeEditor editor, Canvas canvas, string text,
        int from, int to, Brush brush, double opacity)
    {
        if (from < 0 || to <= from || to > text.Length) return;
        var leading = TextPositionRect(editor, text, from);
        var trailing = TextPositionRect(editor, text, to - 1, trailing: true);
        if (Math.Abs(trailing.Y - leading.Y) > Math.Max(leading.Height, editor.FontSize * 1.5)) return;
        var marker = new Rectangle
        {
            Width = Math.Max(2, trailing.X - leading.X),
            Height = Math.Max(leading.Height, editor.FontSize * 1.25),
            Fill = brush, Opacity = opacity, IsHitTestVisible = false
        };
        Canvas.SetLeft(marker, leading.X);
        Canvas.SetTop(marker, leading.Y);
        canvas.Children.Add(marker);
    }

    private void FoldMarker_Click(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { Tag: FoldMarkerTag marker }
            || marker.PaneIndex < 0 || marker.PaneIndex >= editors.Length
            || !paneLayout.SetActivePane(marker.PaneIndex)) return;
        ActivateCurrentPaneDocument();
        if (!StringComparer.OrdinalIgnoreCase.Equals(workspace.ActiveDocument?.Path, marker.Path)) return;
        var state = CurrentFoldingState();
        if (!state.ToggleAtStartLine(marker.Line)) return;
        ApplyFoldingToEditors();
        QueueLineNumberRefresh(marker.PaneIndex);
    }

    private void RefreshSecondarySelections(
        int paneIndex, NativeCodeEditor editor, Canvas canvas, SparseLineIndex lineIndex, double viewportHeight)
    {
        var path = paneIndex < paneLayout.ActiveDocuments.Count ? paneLayout.ActiveDocuments[paneIndex] : null;
        if (path is null || !documentBuffers.TryGetValue(path, out var paneBuffer)
            || paneBuffer.Selections.Ranges.Count < 2) return;
        var text = paneBuffer.Text;
        var drawn = 0;
        const int maximumMarkers = 2_000;
        for (var selectionIndex = 0; selectionIndex < paneBuffer.Selections.Ranges.Count; selectionIndex++)
        {
            if (selectionIndex == paneBuffer.Selections.MainIndex) continue;
            var selection = paneBuffer.Selections.Ranges[selectionIndex];
            var firstLine = lineIndex.LineAtOffset(selection.Start);
            var endpoint = selection.End;
            if (selection.Length > 0 && endpoint > 0
                && lineIndex.StartOffset(lineIndex.LineAtOffset(endpoint)) == endpoint) endpoint--;
            var lastLine = lineIndex.LineAtOffset(endpoint);
            for (var line = firstLine; line <= lastLine && drawn < maximumMarkers; line++)
            {
                var lineStart = lineIndex.StartOffset(line);
                var lineEnd = line + 1 < lineIndex.LineCount
                    ? Math.Max(lineStart, lineIndex.StartOffset(line + 1) - 1) : text.Length;
                var from = selection.Length == 0 ? selection.Head : Math.Max(selection.Start, lineStart);
                var to = selection.Length == 0 ? selection.Head : Math.Min(selection.End, lineEnd);
                var leading = TextPositionRect(editor, text, from);
                if (leading.Y < -editor.FontSize * 2 || leading.Y > viewportHeight + editor.FontSize * 2) continue;
                var trailing = selection.Length == 0 ? leading
                    : TextPositionRect(editor, text, Math.Max(from, to - 1), trailing: true);
                var marker = new Rectangle
                {
                    Width = selection.Length == 0 ? 2 : Math.Max(2, trailing.X - leading.X),
                    Height = Math.Max(leading.Height, editor.FontSize * 1.25),
                    Fill = selection.Length == 0 ? editor.Foreground : editor.SelectionHighlightColor,
                    Opacity = selection.Length == 0 ? 0.9 : 0.58, IsHitTestVisible = false
                };
                Canvas.SetLeft(marker, leading.X);
                Canvas.SetTop(marker, leading.Y);
                canvas.Children.Add(marker);
                drawn++;
            }
            if (drawn >= maximumMarkers) break;
        }
    }

    private static global::Windows.Foundation.Rect TextPositionRect(
        NativeCodeEditor editor, string text, int offset, bool trailing = false)
    {
        if (text.Length == 0) return new global::Windows.Foundation.Rect(0, 4, 0, editor.FontSize * 1.4);
        offset = Math.Clamp(offset, 0, text.Length);
        if (offset < text.Length) return editor.GetRectFromCharacterIndex(offset, trailing);
        return editor.GetRectFromCharacterIndex(text.Length - 1, true);
    }

    private void Minimap_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs args)
    {
        if (sender is not Canvas canvas || !Int32.TryParse(canvas.Tag?.ToString(), out var paneIndex)
            || paneIndex < 0 || paneIndex >= editors.Length) return;
        if (!paneLayout.SetActivePane(paneIndex)) return;
        ActivateCurrentPaneDocument();
        var lineIndex = paneLineIndexes[paneIndex] ?? new SparseLineIndex(buffer.Text);
        var ratio = Math.Clamp(args.GetPosition(canvas).Y / Math.Max(canvas.ActualHeight, 1), 0, 1);
        var line = Math.Clamp((int)Math.Round(ratio * (lineIndex.LineCount - 1)), 0, lineIndex.LineCount - 1);
        var position = lineIndex.StartOffset(line);
        buffer.SetSelection(new TextSelection(position, position));
        ApplyBufferSelectionToEditor();
        Editor.Document.Selection.ScrollIntoView(Microsoft.UI.Text.PointOptions.None);
    }

    private void RefreshMinimap(
        int paneIndex, NativeCodeEditor editor, Canvas canvas, SparseLineIndex lineIndex, int firstLine, double viewportHeight)
    {
        if (canvas.Visibility != Visibility.Visible || viewportHeight <= 1) return;
        const double width = 94;
        if (minimapDirty[paneIndex])
        {
            canvas.Children.Clear();
            minimapDirty[paneIndex] = false;
            var samples = lineIndex.MinimapSamples();
            var rowHeight = Math.Max(0.75, viewportHeight / lineIndex.LineCount);
            foreach (var sample in samples)
            {
                if (sample.VisibleColumns == 0) continue;
                var scale = Math.Min(1.0, width / 220.0);
                var line = new Rectangle
                {
                    Width = Math.Max(1, sample.VisibleColumns * scale), Height = Math.Max(0.65, rowHeight * 0.72),
                    Fill = editor.Foreground, Opacity = 0.34, IsHitTestVisible = false
                };
                Canvas.SetLeft(line, 3 + Math.Min(40, sample.IndentColumns) * scale);
                Canvas.SetTop(line, (sample.Number - 1) * viewportHeight / lineIndex.LineCount);
                canvas.Children.Add(line);
            }
            minimapViewports[paneIndex] = new Rectangle
            {
                Width = width, Fill = editor.Foreground, Opacity = 0.12, IsHitTestVisible = false
            };
            canvas.Children.Add(minimapViewports[paneIndex]!);
        }
        var viewport = minimapViewports[paneIndex];
        if (viewport is null) return;
        var visibleLineCount = Math.Max(1, (int)Math.Ceiling(viewportHeight / Math.Max(editor.FontSize * 1.35, 1)));
        viewport.Height = Math.Clamp(visibleLineCount * viewportHeight / lineIndex.LineCount, 8, viewportHeight);
        Canvas.SetLeft(viewport, 0);
        Canvas.SetTop(viewport, firstLine * viewportHeight / lineIndex.LineCount);
    }

    private void Find_Click(object sender, RoutedEventArgs args) => ShowFind(replace: false);

    private void FindInFiles_Click(object sender, RoutedEventArgs args) => ShowWorkspaceSearch();

    private void Settings_Click(object sender, RoutedEventArgs args) => ShowSettings();

    private async void GoToLine_Click(object sender, RoutedEventArgs args) => await ShowGoToLineAsync();

    private async void CommandPalette_Click(object sender, RoutedEventArgs args) => await ShowCommandPaletteAsync();

    private async void GotoAnything_Click(object sender, RoutedEventArgs args) => await ShowGotoAnythingAsync();

    private async void GotoSymbol_Click(object sender, RoutedEventArgs args) => await ShowSymbolPickerAsync(project: false);

    private async void GotoProjectSymbol_Click(object sender, RoutedEventArgs args) => await ShowSymbolPickerAsync(project: true);

    private async void NavigateBack_Click(object sender, RoutedEventArgs args) => await NavigateHistoryAsync(reverse: true);

    private async void NavigateForward_Click(object sender, RoutedEventArgs args) => await NavigateHistoryAsync(reverse: false);

    private void FindNext_Click(object sender, RoutedEventArgs args) => SelectFindMatch(reverse: false);

    private void FindPrevious_Click(object sender, RoutedEventArgs args) => SelectFindMatch(reverse: true);

    private async void FindHistory_Click(object sender, RoutedEventArgs args) =>
        await ShowSearchHistoryAsync(FindInput, ReplaceInput);

    private async void WorkspaceHistory_Click(object sender, RoutedEventArgs args) =>
        await ShowSearchHistoryAsync(WorkspaceSearchInput, WorkspaceReplacementInput);

    private void ReplaceNext_Click(object sender, RoutedEventArgs args)
    {
        SynchronizeBufferSelection();
        var query = CurrentFindQuery();
        if (!ValidateFindQuery(query)) return;
        var outcome = FindEngine.ReplaceNextOrSelect(buffer, query, ReplaceInput.Text);
        switch (outcome)
        {
            case ReplaceNextOutcome.Selected:
                RememberSearchHistory(query.Text);
                ApplyBufferSelectionToEditor();
                FindStatus.Text = "Match selected; choose Replace again to replace it.";
                break;
            case ReplaceNextOutcome.Replaced:
                RememberSearchHistory(query.Text, ReplaceInput.Text);
                ApplyBufferToEditor();
                RefreshFindStatus();
                break;
            default:
                FindStatus.Text = "No matches.";
                break;
        }
    }

    private void ReplaceAll_Click(object sender, RoutedEventArgs args)
    {
        SynchronizeBufferSelection();
        var query = CurrentFindQuery();
        if (!ValidateFindQuery(query)) return;
        var matches = FindEngine.Find(buffer.Text, query);
        if (matches.Count == 0)
        {
            FindStatus.Text = "No matches.";
            return;
        }
        if (matches.Any(match => match.Length == 0))
        {
            FindStatus.Text = "Zero-width matches cannot be replaced.";
            return;
        }
        if (!FindEngine.ReplaceAll(buffer, query, ReplaceInput.Text))
        {
            FindStatus.Text = "Replace All could not be completed.";
            return;
        }
        ApplyBufferToEditor();
        RememberSearchHistory(query.Text, ReplaceInput.Text);
        FindStatus.Text = $"Replaced {matches.Count} match(es).";
    }

    private void FindInput_TextChanged(object sender, TextChangedEventArgs args) => RefreshFindStatus();

    private void FindOption_Click(object sender, RoutedEventArgs args) => RefreshFindStatus();

    private void CloseFind_Click(object sender, RoutedEventArgs args)
    {
        FindPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private void New_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        New_Click(sender, new RoutedEventArgs());
        args.Handled = true;
    }

    private async void Open_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await PickAndOpenFilesAsync();
    }

    private async void Save_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await SaveActiveAsync();
    }

    private void Undo_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (buffer.Undo()) ApplyBufferToEditor();
        args.Handled = true;
    }

    private void Redo_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (buffer.Redo()) ApplyBufferToEditor();
        args.Handled = true;
    }

    private async void CloseDocument_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await CloseActiveDocumentAsync();
    }

    private void NextDocument_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        CycleDocument(reverse: false);
        args.Handled = true;
    }

    private void PreviousDocument_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        CycleDocument(reverse: true);
        args.Handled = true;
    }

    private void CycleDocument(bool reverse)
    {
        if (!workspace.Next(reverse) || workspace.ActiveDocument is not { } document) return;
        paneLayout.Activate(document.Path);
        RefreshWorkspace();
    }

    private void Find_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        ShowFind(replace: false);
        args.Handled = true;
    }

    private void Replace_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        ShowFind(replace: true);
        args.Handled = true;
    }

    private void FindNext_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        SelectFindMatch(reverse: false);
        args.Handled = true;
    }

    private void FindPrevious_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        SelectFindMatch(reverse: true);
        args.Handled = true;
    }

    private async void FindResultNext_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await NavigateWorkspaceResultAsync(reverse: false);
    }

    private async void FindResultPrevious_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await NavigateWorkspaceResultAsync(reverse: true);
    }

    private void FindInFiles_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        ShowWorkspaceSearch();
        args.Handled = true;
    }

    private async void GoToLine_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await ShowGoToLineAsync();
    }

    private async void CommandPalette_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await ShowCommandPaletteAsync();
    }

    private async void GotoAnything_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await ShowGotoAnythingAsync();
    }

    private void SelectNextOccurrence_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        RunMultiSelectionCommand(value => MultiSelectionCommands.SelectNextOccurrence(value, skip: false),
            Localize("No further occurrence to select.", "没有更多可选择的匹配项。"));
    }

    private void SelectAllOccurrences_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        RunMultiSelectionCommand(MultiSelectionCommands.SelectAllOccurrences,
            Localize("No occurrence can be selected.", "没有可选择的匹配项。"));
    }

    private void AddCursorsLineEnds_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        RunMultiSelectionCommand(value => MultiSelectionCommands.AddLineBoundaries(value, atEnd: true),
            Localize("Could not add cursors to line ends.", "无法在行尾添加光标。"));
    }

    private void AddCursorAbove_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        RunMultiSelectionCommand(value => MultiSelectionCommands.AddVertical(value, below: false),
            Localize("There is no line above for another cursor.", "上方没有可添加光标的行。"));
    }

    private void AddCursorBelow_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        RunMultiSelectionCommand(value => MultiSelectionCommands.AddVertical(value, below: true),
            Localize("There is no line below for another cursor.", "下方没有可添加光标的行。"));
    }

    private async void NavigateBack_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await NavigateHistoryAsync(reverse: true);
    }

    private async void NavigateForward_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await NavigateHistoryAsync(reverse: false);
    }

    private NavigationLocation? CurrentNavigationLocation()
    {
        var document = workspace.ActiveDocument;
        if (document is null) return null;
        var selection = EditorSelection();
        return new(document.Path, paneLayout.ActivePane, selection.Anchor, selection.Head);
    }

    private async Task NavigateToAsync(string path, int line, int column, int selectionLength = 0, bool record = true)
    {
        var before = CurrentNavigationLocation();
        if (workspace.Find(path) is null) await OpenPathsAsync([path]);
        else
        {
            workspace.Activate(path);
            paneLayout.Activate(path);
            RefreshWorkspace();
        }
        if (workspace.ActiveDocument is null
            || !StringComparer.OrdinalIgnoreCase.Equals(workspace.ActiveDocument.Path, path)) return;
        var offset = TextNavigation.LineColumnToOffset(buffer.Text, line, column);
        var length = Math.Clamp(selectionLength, 0, buffer.Text.Length - offset);
        var after = new NavigationLocation(workspace.ActiveDocument.Path, paneLayout.ActivePane, offset, offset + length);
        if (record && before is not null) navigationHistory.Record(before, after);
        buffer.SetSelection(new TextSelection(offset, offset));
        ApplyBufferSelectionToEditor();
    }

    private async Task NavigateHistoryAsync(bool reverse)
    {
        var current = CurrentNavigationLocation();
        if (current is null) return;
        var destination = reverse ? navigationHistory.GoBack(current) : navigationHistory.GoForward(current);
        if (destination is null)
        {
            Status.Text = reverse ? "No previous location." : "No next location.";
            return;
        }
        if (workspace.Find(destination.DocumentPath) is null
            && !destination.DocumentPath.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
        {
            await OpenPathsAsync([destination.DocumentPath]);
        }
        if (!workspace.Activate(destination.DocumentPath)) return;
        paneLayout.Activate(destination.DocumentPath, Math.Clamp(destination.Pane, 0, paneLayout.Panes.Count - 1));
        RefreshWorkspace();
        buffer.SetSelection(new TextSelection(destination.Anchor, destination.Head));
        ApplyBufferSelectionToEditor();
    }

    private async Task<(string Baseline, IReadOnlyList<IncrementalChange> Changes)?> LoadIncrementalChangesAsync()
    {
        var document = workspace.ActiveDocument;
        if (document is null || document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)
            || document.Revision is null)
        {
            Status.Text = "Save the file before navigating changes.";
            return null;
        }
        try
        {
            var info = new FileInfo(document.Path);
            if (!info.Exists || info.Length > settings.MaximumEditableBytes)
            {
                Status.Text = "The saved file is unavailable or exceeds the configured size limit.";
                return null;
            }
            var bytes = await File.ReadAllBytesAsync(document.Path);
            if (!StringComparer.Ordinal.Equals(FileWriteService.ComputeRevision(bytes), document.Revision))
            {
                Status.Text = "The file changed on disk; resolve the external change before navigating edits.";
                return null;
            }
            var decoded = TextFileCodec.Decode(bytes, document.Encoding);
            var changes = IncrementalDiff.Compute(decoded.Content, buffer.Text);
            return (decoded.Content, changes);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or System.Text.DecoderFallbackException)
        {
            Status.Text = $"Saved content could not be read: {error.Message}";
            return null;
        }
    }

    private async Task NavigateIncrementalChangeAsync(bool reverse)
    {
        var state = await LoadIncrementalChangesAsync();
        if (state is null || state.Value.Changes.Count == 0)
        {
            if (state is not null) Status.Text = "There are no unsaved changes to navigate.";
            return;
        }
        var currentLine = TextNavigation.OffsetToLineColumn(buffer.Text, Editor.SelectionStart).Line;
        var target = reverse
            ? state.Value.Changes.LastOrDefault(change => change.Line < currentLine) ?? state.Value.Changes[^1]
            : state.Value.Changes.FirstOrDefault(change => change.Line > currentLine) ?? state.Value.Changes[0];
        if (workspace.ActiveDocument is not { } document) return;
        await NavigateToAsync(document.Path, target.Line, 1);
        Status.Text = $"{target.Kind.ToString().ToLowerInvariant()} change near line {target.Line}.";
    }

    private async Task RevertCurrentIncrementalChangeAsync()
    {
        var state = await LoadIncrementalChangesAsync();
        if (state is null || state.Value.Changes.Count == 0)
        {
            if (state is not null) Status.Text = "There is no unsaved change at the cursor.";
            return;
        }
        var currentLine = TextNavigation.OffsetToLineColumn(buffer.Text, Editor.SelectionStart).Line;
        var change = state.Value.Changes.FirstOrDefault(candidate =>
            currentLine >= candidate.Line && currentLine < candidate.Line + Math.Max(1, candidate.LineCount))
            ?? state.Value.Changes.LastOrDefault(candidate => candidate.Line <= currentLine);
        if (change is null)
        {
            Status.Text = "There is no unsaved change at the cursor.";
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = $"Revert {change.Kind.ToString().ToLowerInvariant()} change?",
            Content = $"Restore the saved content near line {change.Line}? This remains undoable.",
            PrimaryButtonText = "Revert", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var reverted = IncrementalDiff.Revert(buffer.Text, change);
        ApplyBufferCommand(value => value.Apply(reverted, new TextSelection(
            TextNavigation.LineColumnToOffset(reverted, change.Line, 1),
            TextNavigation.LineColumnToOffset(reverted, change.Line, 1))),
            $"Reverted change near line {change.Line}.");
    }

    private async Task ShowGotoAnythingAsync()
    {
        if (workspaceRoots.Count == 0)
        {
            Status.Text = "Open a workspace folder before using Goto Anything.";
            return;
        }
        var exclusions = projectExclusions;
        workspaceFileIndex = await Task.Run(() =>
            WorkspaceFileIndex.EnumerateFiles(workspaceRoots, workspaceTree, exclusions));
        var query = new TextBox { PlaceholderText = "Type a file name" };
        var results = new ListView { DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single, MaxHeight = 420 };
        void Filter()
        {
            results.ItemsSource = WorkspaceFileIndex.SearchFiles(workspaceFileIndex, workspaceRoots, query.Text)
                .Select(match => new WorkspaceFileListItem(match)).ToList();
            results.SelectedIndex = results.Items.Count > 0 ? 0 : -1;
        }
        query.TextChanged += (_, _) => Filter();
        Filter();
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(query);
        content.Children.Add(results);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Goto Anything", Content = content,
            PrimaryButtonText = "Open", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || results.SelectedItem is not WorkspaceFileListItem selected) return;
        await NavigateToAsync(selected.Match.Path, 1, 1);
    }

    private async Task ShowSymbolPickerAsync(bool project)
    {
        var document = workspace.ActiveDocument;
        if (document is null) return;
        IReadOnlyList<DocumentSymbol> source;
        if (project)
        {
            if (workspaceRoots.Count == 0)
            {
                Status.Text = "Open a workspace folder before searching project symbols.";
                return;
            }
            var exclusions = projectExclusions;
            projectSymbolIndex = await Task.Run(() =>
                new WorkspaceSymbolIndex().BuildAsync(workspaceRoots, workspaceTree, exclusions: exclusions));
            source = projectSymbolIndex;
        }
        else source = CurrentDocumentSymbols(document, buffer.Text, CurrentLanguage(document).Id);
        var query = new TextBox { PlaceholderText = project ? "Filter project symbols" : "Filter symbols" };
        var results = new ListView { DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single, MaxHeight = 420 };
        void Filter()
        {
            results.ItemsSource = WorkspaceSymbolIndex.Search(source, query.Text)
                .Select(symbol => new SymbolListItem(symbol)).ToList();
            results.SelectedIndex = results.Items.Count > 0 ? 0 : -1;
        }
        query.TextChanged += (_, _) => Filter();
        Filter();
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(query);
        content.Children.Add(results);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = project ? "Goto Project Symbol" : "Goto Symbol",
            Content = content, PrimaryButtonText = "Go", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || results.SelectedItem is not SymbolListItem selected) return;
        await NavigateToAsync(selected.Symbol.Path, selected.Symbol.Line, selected.Symbol.Column, selected.Symbol.Name.Length);
    }

    private void ToggleOutline()
    {
        settings = settings with { ShowOutline = !settings.ShowOutline };
        RefreshOutline();
        _ = PersistSettingsWithStatusAsync(settings.ShowOutline ? "Document outline shown." : "Document outline hidden.");
    }

    private void RefreshOutline()
    {
        OutlinePanel.Visibility = settings.ShowOutline ? Visibility.Visible : Visibility.Collapsed;
        if (!settings.ShowOutline || workspace.ActiveDocument is not { } document)
        {
            OutlineList.ItemsSource = Array.Empty<SymbolListItem>();
            return;
        }
        OutlineList.ItemsSource = CurrentDocumentSymbols(document, buffer.Text, CurrentLanguage(document).Id)
            .Select(symbol => new SymbolListItem(symbol)).ToList();
    }

    private IReadOnlyList<DocumentSymbol> CurrentDocumentSymbols(
        OpenedDocument document, string text, string language)
    {
        var parserLanguage = CurrentLanguage(document).ParserName;
        if (documentParserSnapshots.TryGetValue(document.Path, out var snapshot)
            && snapshot.Text == text && snapshot.Language == parserLanguage && snapshot.Analysis.Supported
            && snapshot.Analysis.ParserKind == CodeMirrorParserKind.Lezer
            && !snapshot.Analysis.Truncated.Source && !snapshot.Analysis.Truncated.Symbols)
            return snapshot.Analysis.ToDocumentSymbols(document.Path, text);
        return SymbolExtractor.Extract(document.Path, text, language);
    }

    private async void Outline_ItemClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is not SymbolListItem selected) return;
        await NavigateToAsync(selected.Symbol.Path, selected.Symbol.Line, selected.Symbol.Column, selected.Symbol.Name.Length);
    }

    private void CloseOutline_Click(object sender, RoutedEventArgs args)
    {
        if (!settings.ShowOutline) return;
        settings = settings with { ShowOutline = false };
        RefreshOutline();
        _ = PersistSettingsWithStatusAsync("Document outline hidden.");
        Editor.Focus(FocusState.Programmatic);
    }

    private async void SearchWorkspace_Click(object sender, RoutedEventArgs args)
    {
        var text = WorkspaceSearchInput.Text;
        if (workspaceRoots.Count == 0)
        {
            WorkspaceSearchStatus.Text = "Open a folder before searching across files.";
            return;
        }
        var prototype = new WorkspaceSearchQuery(
            workspaceRoots[0], text,
            WorkspaceMatchCaseToggle.IsChecked == true,
            WorkspaceWholeWordToggle.IsChecked == true,
            WorkspaceRegexToggle.IsChecked == true);
        if (String.IsNullOrWhiteSpace(text))
        {
            WorkspaceSearchStatus.Text = "Enter text to find.";
            return;
        }
        if (WorkspaceSearchPattern.Compile(prototype) is null)
        {
            WorkspaceSearchStatus.Text = "Invalid regular expression.";
            return;
        }

        workspaceSearchCancellation?.Cancel();
        workspaceSearchCancellation?.Dispose();
        workspaceSearchCancellation = new CancellationTokenSource();
        var cancellationToken = workspaceSearchCancellation.Token;
        var exclusions = projectExclusions;
        WorkspaceSearchStatus.Text = "Searching…";
        WorkspaceResultsPanel.Visibility = Visibility.Visible;
        WorkspaceResultsList.ItemsSource = Array.Empty<WorkspaceSearchListItem>();
        try
        {
            var matches = new List<WorkspaceSearchMatch>();
            var truncated = false;
            foreach (var root in workspaceRoots)
            {
                var remaining = 5_000 - matches.Count;
                if (remaining <= 0)
                {
                    truncated = true;
                    break;
                }
                var query = prototype with { Root = root, MaximumResults = remaining };
                var result = await Task.Run(
                    () => workspaceSearchRunner.SearchWorkspaceAsync(
                        query, workspaceTree, cancellationToken, exclusions),
                    cancellationToken);
                matches.AddRange(result.Matches);
                truncated |= result.IsTruncated;
            }
            SetWorkspaceResults(matches);
            RememberSearchHistory(text);
            WorkspaceSearchStatus.Text = truncated
                ? $"Showing the first {matches.Count} result(s)."
                : $"{matches.Count} result(s).";
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // A newer query owns the results panel.
        }
    }

    private void CloseWorkspaceSearch_Click(object sender, RoutedEventArgs args)
    {
        WorkspaceSearchPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private void CloseWorkspaceResults_Click(object sender, RoutedEventArgs args)
    {
        WorkspaceResultsPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private async void ApplySettings_Click(object sender, RoutedEventArgs args)
    {
        settings = EditorSettings.Sanitize(settings with
        {
            FontSize = (int)Math.Round(FontSizeSetting.Value),
            TabSize = (int)Math.Round(TabSizeSetting.Value),
            MaxFileSizeMb = (int)Math.Round(MaxFileSizeSetting.Value),
            InsertSpaces = InsertSpacesSetting.IsChecked == true,
            WordWrap = WordWrapSetting.IsChecked == true,
            ShowLineNumbers = LineNumbersSetting.IsChecked == true,
            ShowWhitespace = WhitespaceSetting.IsChecked == true,
            ShowMinimap = MinimapSetting.IsChecked == true,
            ShowIndentGuides = IndentGuidesSetting.IsChecked == true,
            HighlightTrailingWhitespace = TrailingWhitespaceSetting.IsChecked == true,
            Rulers = ParseRulers(RulersSetting.Text),
            ColorScheme = (EditorColorScheme)Math.Clamp(
                ColorSchemeSetting.SelectedIndex, 0, Enum.GetValues<EditorColorScheme>().Length - 1),
            BuildCommand = BuildCommandSetting.Text,
            AutoSave = AutoSaveSetting.SelectedIndex switch
            {
                1 => AutoSaveMode.AfterDelay,
                2 => AutoSaveMode.OnFocusChange,
                _ => AutoSaveMode.Off
            },
            AutoSaveDelayMs = (int)Math.Round(AutoSaveDelaySetting.Value)
        });
        CancelAutoSaveDelay();
        if (settings.AutoSave == AutoSaveMode.AfterDelay) ScheduleAutoSaveAfterEdit();
        ApplySettingsToEditor();
        try
        {
            await settingsStore.SaveAsync(settings);
            Status.Text = "Settings saved.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Status.Text = $"Settings could not be saved: {error.Message}";
        }
    }

    private void CloseSettings_Click(object sender, RoutedEventArgs args)
    {
        SettingsPanel.Visibility = Visibility.Collapsed;
        Editor.Focus(FocusState.Programmatic);
    }

    private void RememberSearchHistory(string search, string? replacement = null)
    {
        settings = settings with
        {
            SearchHistory = EditorSettings.RememberHistory(settings.SearchHistory, search),
            ReplaceHistory = replacement is null ? settings.ReplaceHistory
                : EditorSettings.RememberHistory(settings.ReplaceHistory, replacement)
        };
        _ = settingsStore.SaveAsync(settings);
    }

    private async Task ShowSearchHistoryAsync(TextBox searchTarget, TextBox replacementTarget)
    {
        var items = (settings.SearchHistory ?? []).Select(value => new SearchHistoryItem(
                value, false, $"Find: {value}"))
            .Concat((settings.ReplaceHistory ?? []).Select(value => new SearchHistoryItem(
                value, true, $"Replace: {value}"))).Take(100).ToList();
        if (items.Count == 0)
        {
            Status.Text = Localize("Search history is empty.", "搜索历史为空。");
            return;
        }
        var list = new ListView
        {
            ItemsSource = items, DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single,
            SelectedIndex = 0, MaxHeight = 360
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = Localize("Search History", "搜索历史"), Content = list,
            PrimaryButtonText = Localize("Use", "使用"), CloseButtonText = Localize("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || list.SelectedItem is not SearchHistoryItem selected) return;
        var target = selected.IsReplacement ? replacementTarget : searchTarget;
        target.Text = selected.Value;
        target.Focus(FocusState.Programmatic);
        target.SelectAll();
    }

    private async void WorkspaceResults_ItemClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is not WorkspaceSearchListItem item) return;
        await NavigateToAsync(item.Match.Path, item.Match.Line, item.Match.Column, item.Match.MatchText.Length);
        Status.Text = $"{item.Match.Path}:{item.Match.Line}:{item.Match.Column}";
    }

    private void SetWorkspaceResults(IEnumerable<WorkspaceSearchMatch> matches)
    {
        workspaceResultItems = matches.Select(match => new WorkspaceSearchListItem(match)).ToList();
        workspaceResultIndex = workspaceResultItems.Count > 0 ? 0 : -1;
        WorkspaceResultsList.ItemsSource = workspaceResultItems;
        WorkspaceResultsList.SelectedIndex = workspaceResultIndex;
    }

    private async Task NavigateWorkspaceResultAsync(bool reverse)
    {
        if (workspaceResultItems.Count == 0)
        {
            Status.Text = "There are no workspace search results.";
            return;
        }
        workspaceResultIndex = reverse
            ? (workspaceResultIndex + workspaceResultItems.Count - 1) % workspaceResultItems.Count
            : (workspaceResultIndex + 1) % workspaceResultItems.Count;
        WorkspaceResultsList.SelectedIndex = workspaceResultIndex;
        var item = workspaceResultItems[workspaceResultIndex];
        await NavigateToAsync(item.Match.Path, item.Match.Line, item.Match.Column, item.Match.MatchText.Length);
    }

    private async void PreviewWorkspaceReplace_Click(object sender, RoutedEventArgs args)
    {
        if (workspaceRoots.Count == 0 || String.IsNullOrWhiteSpace(WorkspaceSearchInput.Text))
        {
            WorkspaceSearchStatus.Text = "Open a folder and enter text before previewing replacements.";
            return;
        }
        var dirtyPaths = workspace.Documents.Where(document => document.IsDirty)
            .Select(document => document.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        workspaceSearchCancellation?.Cancel();
        workspaceSearchCancellation?.Dispose();
        workspaceSearchCancellation = new CancellationTokenSource();
        var exclusions = projectExclusions;
        WorkspaceSearchStatus.Text = "Preparing replacement preview…";
        try
        {
            var preview = await Task.Run(() => workspaceReplaceService.PreviewAsync(
                workspaceRoots, WorkspaceSearchInput.Text, WorkspaceReplacementInput.Text,
                WorkspaceMatchCaseToggle.IsChecked == true, WorkspaceWholeWordToggle.IsChecked == true,
                WorkspaceRegexToggle.IsChecked == true, workspaceTree,
                workspaceSearchCancellation.Token, exclusions));
            if (preview.Files.Any(file => dirtyPaths.Contains(file.Path)))
            {
                workspaceReplacePreview = null;
                WorkspaceSearchStatus.Text = "Save or close matching files with unsaved edits before replacing in files.";
                return;
            }
            workspaceReplacePreview = preview.Error is null && !preview.IsTruncated ? preview : null;
            if (workspaceReplacePreview is not null)
                RememberSearchHistory(WorkspaceSearchInput.Text, WorkspaceReplacementInput.Text);
            SetWorkspaceResults(preview.Matches);
            WorkspaceResultsPanel.Visibility = Visibility.Visible;
            WorkspaceSearchStatus.Text = preview.Error ??
                $"Preview: {preview.ReplacementCount} replacement(s) in {preview.Files.Count} file(s).";
        }
        catch (OperationCanceledException)
        {
            WorkspaceSearchStatus.Text = "Replacement preview cancelled.";
        }
    }

    private async void ApplyWorkspaceReplace_Click(object sender, RoutedEventArgs args)
    {
        var preview = workspaceReplacePreview;
        if (preview is null)
        {
            WorkspaceSearchStatus.Text = "Preview the replacement before applying it.";
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Apply workspace replacement?",
            Content = $"Replace {preview.ReplacementCount} match(es) in {preview.Files.Count} file(s)?",
            PrimaryButtonText = "Replace", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var result = await workspaceReplaceService.ApplyAsync(
            preview, currentExclusions: projectExclusions);
        if (!result.Succeeded)
        {
            WorkspaceSearchStatus.Text = result.Error ?? "Workspace replacement failed.";
            return;
        }
        workspaceReplaceUndo = result.Undo;
        workspaceReplacePreview = null;
        await ReloadCleanOpenDocumentsAsync();
        RefreshWorkspaceTree();
        WorkspaceSearchStatus.Text = $"Replaced {result.Replacements} match(es) in {result.Files} file(s).";
    }

    private async void UndoWorkspaceReplace_Click(object sender, RoutedEventArgs args)
    {
        if (workspaceReplaceUndo is null)
        {
            WorkspaceSearchStatus.Text = "There is no recent workspace replacement to undo.";
            return;
        }
        var result = await workspaceReplaceService.UndoAsync(workspaceReplaceUndo);
        if (!result.Succeeded)
        {
            WorkspaceSearchStatus.Text = result.Error ?? "Workspace replacement could not be undone.";
            return;
        }
        workspaceReplaceUndo = null;
        await ReloadCleanOpenDocumentsAsync();
        RefreshWorkspaceTree();
        WorkspaceSearchStatus.Text = $"Restored {result.Files} file(s).";
    }

    public async Task OpenPathsAsync(IEnumerable<string> paths)
    {
        await initialization;
        await OpenPathsCoreAsync(paths);
    }

    private async Task OpenPathsCoreAsync(IEnumerable<string> paths)
    {
        var result = await opener.OpenAsync(paths, settings);
        workspace.AddOrActivate(result.Documents);
        foreach (var document in result.Documents) StoreSavedBaseline(document.Path, document.Content);
        foreach (var document in result.Documents) paneLayout.Activate(document.Path);
        foreach (var document in result.Documents.Where(document =>
            !document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)))
        {
            await TryRememberFileAsync(document.Path);
        }
        RefreshWorkspace();
        Status.Text = result.Failures.Count == 0
            ? $"Opened {result.Documents.Count} file(s)."
            : $"Opened {result.Documents.Count} file(s); {result.Failures.Count} could not be opened.";
    }

    private async Task<bool> SaveActiveAsync(bool forcePicker = false)
    {
        var document = workspace.ActiveDocument;
        if (document is null) return false;
        var previousPath = document.Path;
        var target = document.Path;
        var choosingTarget = forcePicker || target.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase);
        if (choosingTarget)
        {
            var picker = new FileSavePicker();
            picker.FileTypeChoices.Add("Plain text", [".txt"]);
            picker.SuggestedFileName = document.DisplayName;
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            StorageFile? destination = await picker.PickSaveFileAsync();
            if (destination is null) return false;
            target = destination.Path;
        }
        var expectedRevision = choosingTarget && File.Exists(target)
            ? await FileWriteService.RevisionAsync(target)
            : document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase) || forcePicker
                ? null
                : document.Revision;

        var result = await writer.SaveAsync(
            target, buffer.Text, document.Encoding, document.LineEnding,
            expectedRevision);
        if (!result.Saved)
        {
            Status.Text = result.Message ?? "The document could not be saved.";
            return false;
        }

        var bytes = new FileInfo(target).Length;
        workspace.ReplaceActive(document with
        {
            Path = target,
            DisplayName = Path.GetFileName(target),
            Content = buffer.Text,
            ByteLength = bytes,
            Revision = result.Revision,
            IsDirty = false
        });
        autoSaveConflictedPaths.Remove(previousPath);
        autoSaveConflictedPaths.Remove(target);
        if (!StringComparer.OrdinalIgnoreCase.Equals(previousPath, target))
        {
            if (languageServer?.IsRunning == true)
            {
                try { await languageServer.CloseDocumentAsync(previousPath); }
                catch (Exception error) when (error is IOException or InvalidOperationException
                    or ObjectDisposedException or OperationCanceledException) { }
            }
            paneLayout.RenameDocument(previousPath, target);
            documentBuffers.Remove(previousPath);
            documentBuffers[target] = buffer;
            if (documentSelectionHistories.Remove(previousPath, out var selectionHistory))
            {
                documentSelectionHistories[target] = selectionHistory;
            }
            if (documentExpansionHistories.Remove(previousPath, out var expansionHistory))
            {
                documentExpansionHistories[target] = expansionHistory;
            }
            if (documentBookmarks.Remove(previousPath, out var previousBookmarks))
            {
                documentBookmarks[target] = previousBookmarks;
            }
            if (documentFoldingStates.Remove(previousPath, out var previousFolding))
            {
                documentFoldingStates[target] = previousFolding;
            }
            if (documentParserSnapshots.Remove(previousPath, out var parserSnapshot))
            {
                documentParserSnapshots[target] = parserSnapshot;
            }
            documentSavedBaselines.Remove(previousPath);
            documentDiffSnapshots.Remove(previousPath);
            languageDiagnostics.Remove(previousPath);
        }
        StoreSavedBaseline(target, buffer.Text);
        ScheduleLanguageServerSync();
        RefreshWorkspace();
        await TryRememberFileAsync(target);
        Status.Text = $"Saved {Path.GetFileName(target)}.";
        return true;
    }

    private async Task<bool> SaveAllAsync()
    {
        var paths = workspace.Documents.Where(document => document.IsDirty).Select(document => document.Path).ToList();
        var saved = 0;
        foreach (var path in paths)
        {
            if (!workspace.Activate(path)) continue;
            paneLayout.Activate(path);
            RefreshWorkspace();
            if (!await SaveActiveAsync()) break;
            saved++;
        }
        Status.Text = $"Saved {saved} document(s).";
        return saved == paths.Count;
    }

    private async Task<bool> CloseActiveDocumentAsync()
    {
        var document = workspace.ActiveDocument;
        if (document is null) return false;
        if (document.IsDirty)
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = $"Save changes to {document.DisplayName}?",
                Content = "Your changes will be lost if you close without saving.",
                PrimaryButtonText = "Save",
                SecondaryButtonText = "Don't Save",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary
            };
            var choice = await dialog.ShowAsync();
            if (choice == ContentDialogResult.None) return false;
            if (choice == ContentDialogResult.Primary && !await SaveActiveAsync()) return false;
            document = workspace.ActiveDocument;
            if (document is null) return false;
        }
        var closingPath = document.Path;
        if (languageServer?.IsRunning == true
            && !closingPath.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
        {
            try { await languageServer.CloseDocumentAsync(closingPath); }
            catch (Exception error) when (error is IOException or InvalidOperationException
                or ObjectDisposedException or OperationCanceledException) { }
        }
        if (!workspace.Close(closingPath)) return false;
        paneLayout.Remove(closingPath);
        if (!closingPath.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
        {
            recentlyClosedPaths.Push(closingPath);
            while (recentlyClosedPaths.Count > 100)
            {
                var retained = recentlyClosedPaths.Take(100).Reverse().ToArray();
                recentlyClosedPaths.Clear();
                foreach (var path in retained) recentlyClosedPaths.Push(path);
            }
        }
        documentBuffers.Remove(closingPath);
        documentSelectionHistories.Remove(closingPath);
        documentExpansionHistories.Remove(closingPath);
        documentBookmarks.Remove(closingPath);
        documentFoldingStates.Remove(closingPath);
        documentParserSnapshots.Remove(closingPath);
        documentSavedBaselines.Remove(closingPath);
        documentDiffSnapshots.Remove(closingPath);
        languageDiagnostics.Remove(closingPath);
        RefreshLanguageDiagnostics();
        if (workspace.ActiveDocument is { } active)
        {
            paneLayout.Activate(active.Path);
        }
        RefreshWorkspace();
        Status.Text = $"Closed {document.DisplayName}.";
        return true;
    }

    private async Task ReopenClosedDocumentAsync()
    {
        while (recentlyClosedPaths.TryPop(out var path))
        {
            if (!File.Exists(path)) continue;
            await OpenPathsAsync([path]);
            return;
        }
        Status.Text = "There are no recently closed files to reopen.";
    }

    private async Task SelectEncodingAsync()
    {
        var choices = Enum.GetValues<TextEncodingKind>().Select(value => value.ToString()).ToList();
        var list = new ListView { ItemsSource = choices, SelectionMode = ListViewSelectionMode.Single };
        list.SelectedItem = workspace.ActiveDocument?.Encoding.ToString();
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Select Encoding", Content = list,
            PrimaryButtonText = "Apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not string selected
            || !Enum.TryParse<TextEncodingKind>(selected, out var encoding) || workspace.ActiveDocument is not { } document) return;
        workspace.ReplaceActive(document with { Encoding = encoding, IsDirty = true });
        RefreshWorkspace();
        Status.Text = $"Encoding set to {encoding}; save to write the new encoding.";
    }

    private async Task<TextEncodingKind?> ChooseEncodingAsync(string title)
    {
        var choices = Enum.GetValues<TextEncodingKind>().Select(value => value.ToString()).ToList();
        var list = new ListView { ItemsSource = choices, SelectionMode = ListViewSelectionMode.Single, MaxHeight = 420, SelectedIndex = 0 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = title, Content = list,
            PrimaryButtonText = "Choose", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary
            && list.SelectedItem is string selected && Enum.TryParse<TextEncodingKind>(selected, out var encoding)
                ? encoding : null;
    }

    private async Task ReopenActiveWithEncodingAsync()
    {
        var document = workspace.ActiveDocument;
        if (document is null || document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
        {
            Status.Text = "Save the document before reopening it with an encoding.";
            return;
        }
        if (document.IsDirty)
        {
            var warning = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = $"Discard changes to {document.DisplayName}?",
                Content = "Reopening with another encoding reads the current bytes from disk and discards unsaved edits.",
                PrimaryButtonText = "Discard and Reopen", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await warning.ShowAsync() != ContentDialogResult.Primary) return;
        }
        var encoding = await ChooseEncodingAsync("Reopen with Encoding");
        if (encoding is null) return;
        var result = await opener.OpenWithEncodingAsync([document.Path], settings, encoding.Value);
        if (result.Documents.Count != 1)
        {
            Status.Text = result.Failures.FirstOrDefault()?.Message ?? "The document could not be reopened.";
            return;
        }
        workspace.Replace(document.Path, result.Documents[0]);
        documentBuffers.Remove(document.Path);
        documentSelectionHistories.Remove(document.Path);
        documentExpansionHistories.Remove(document.Path);
        documentFoldingStates.Remove(document.Path);
        documentParserSnapshots.Remove(document.Path);
        RefreshWorkspace();
        Status.Text = $"Reopened {document.DisplayName} as {encoding}.";
    }

    private async Task SelectLineEndingAsync()
    {
        var choices = Enum.GetValues<LineEnding>().Select(value => value.ToString()).ToList();
        var list = new ListView { ItemsSource = choices, SelectionMode = ListViewSelectionMode.Single };
        list.SelectedItem = workspace.ActiveDocument?.LineEnding.ToString();
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Select Line Ending", Content = list,
            PrimaryButtonText = "Apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not string selected
            || !Enum.TryParse<LineEnding>(selected, out var lineEnding) || workspace.ActiveDocument is not { } document) return;
        workspace.ReplaceActive(document with { LineEnding = lineEnding, IsDirty = true });
        RefreshWorkspace();
        Status.Text = $"Line ending set to {lineEnding}; save to write the new line endings.";
    }

    private void SetLineEnding(LineEnding lineEnding)
    {
        var document = workspace.ActiveDocument;
        if (document is null || document.LineEnding == lineEnding) return;
        workspace.ReplaceActive(document with { LineEnding = lineEnding, IsDirty = true });
        RefreshWorkspace();
        Status.Text = $"Line ending set to {lineEnding}; save to write the new line endings.";
    }

    private void DocumentList_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (args.AddedItems.LastOrDefault() is not OpenedDocument document) return;
        if (!workspace.Activate(document.Path)) return;
        paneLayout.Activate(document.Path);
        RefreshEditor();
    }

    private void Editor_TextChanging(object sender, RichEditBoxTextChangingEventArgs args)
    {
        nativeMultiEditPending = uiReady && !applyingEditorText && !imeCompositionActive
            && buffer.Selections.Ranges.Count > 1;
    }

    private void Editor_TextChanged(object sender, RoutedEventArgs args)
    {
        if (sender is NativeCodeEditor changedEditor) InvalidateLineNumbers(Array.IndexOf(editors, changedEditor));
        if (!uiReady || applyingEditorText) return;
        if (sender is NativeCodeEditor source) source.RefreshTextCache();
        var editedPath = workspace.ActiveDocument?.Path;
        var nativeText = Editor.Text;
        if (editedPath is not null && documentFoldingStates.TryGetValue(editedPath, out var folding)
            && folding.UnfoldAll())
        {
            applyingEditorText = true;
            try
            {
                for (var index = 0; index < editors.Length; index++)
                {
                    if (index < paneLayout.ActiveDocuments.Count
                        && StringComparer.OrdinalIgnoreCase.Equals(paneLayout.ActiveDocuments[index], editedPath))
                    {
                        editors[index].ApplyHiddenRanges([], buffer.Text.Length);
                    }
                }
            }
            finally { applyingEditorText = false; }
        }
        var before = buffer.Text;
        var selection = EditorSelection();
        if (!imeCompositionActive && buffer.Selections.Ranges.Count > 1
            && MultiSelectionCommands.ApplyPrimaryEdit(buffer, nativeText, selection))
        {
            nativeMultiEditPending = false;
            ClearActiveSelectionHistories();
            if (!replayingMacro) macroRecorder.Observe(before, buffer.Text, buffer.Selection);
            ApplyBufferToEditor();
            return;
        }
        nativeMultiEditPending = false;
        if (!buffer.Apply(nativeText, selection)) buffer.SetSelection(selection);
        else
        {
            ClearActiveSelectionHistories();
            if (!replayingMacro) macroRecorder.Observe(before, buffer.Text, buffer.Selection);
        }
        workspace.UpdateActiveContent(buffer.Text);
        RefreshDocumentList();
        RefreshFindStatus();
        RefreshPreview();
        if (editedPath is not null) documentParserSnapshots.Remove(editedPath);
        ScheduleSyntaxHighlighting(paneLayout.ActivePane);
        ScheduleDiffDecorations();
        ScheduleCompletion();
        ScheduleLanguageServerSync();
        ScheduleAutoSaveAfterEdit();
    }

    private void ScheduleAutoSaveAfterEdit()
    {
        if (AutoSavePolicy.DocumentChanged(settings.AutoSave) != AutoSaveAction.ScheduleAfterDelay) return;
        CancelAutoSaveDelay();
        autoSaveDelayCancellation = new CancellationTokenSource();
        _ = AutoSaveAfterDelayAsync(autoSaveDelayCancellation, settings.AutoSaveDelayMs);
    }

    private async Task AutoSaveAfterDelayAsync(CancellationTokenSource owner, int delayMilliseconds)
    {
        try
        {
            await Task.Delay(delayMilliseconds, owner.Token);
            if (!owner.IsCancellationRequested && settings.AutoSave == AutoSaveMode.AfterDelay)
            {
                await AutoSaveDirtyDocumentsAsync();
            }
        }
        catch (OperationCanceledException) when (owner.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(autoSaveDelayCancellation, owner)) autoSaveDelayCancellation = null;
            owner.Dispose();
        }
    }

    private async void Window_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState != WindowActivationState.Deactivated
            || AutoSavePolicy.WindowFocusLost(settings.AutoSave) != AutoSaveAction.SaveNow) return;
        CancelAutoSaveDelay();
        await AutoSaveDirtyDocumentsAsync();
    }

    private void CancelAutoSaveDelay()
    {
        var pending = autoSaveDelayCancellation;
        autoSaveDelayCancellation = null;
        pending?.Cancel();
    }

    private async Task CycleAutoSaveAsync()
    {
        settings = EditorSettings.Sanitize(settings with
        {
            AutoSave = settings.AutoSave switch
            {
                AutoSaveMode.Off => AutoSaveMode.AfterDelay,
                AutoSaveMode.AfterDelay => AutoSaveMode.OnFocusChange,
                _ => AutoSaveMode.Off
            }
        });
        CancelAutoSaveDelay();
        if (settings.AutoSave == AutoSaveMode.AfterDelay) ScheduleAutoSaveAfterEdit();
        try
        {
            await settingsStore.SaveAsync(settings);
            Status.Text = settings.AutoSave switch
            {
                AutoSaveMode.AfterDelay => $"Auto Save: after {settings.AutoSaveDelayMs} ms.",
                AutoSaveMode.OnFocusChange => "Auto Save: on focus change.",
                _ => "Auto Save: off."
            };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Status.Text = $"Auto Save setting could not be saved: {error.Message}";
        }
    }

    private async Task AutoSaveDirtyDocumentsAsync()
    {
        if (autoSaveRunning)
        {
            autoSavePassRequested = true;
            return;
        }
        autoSaveRunning = true;
        var totalSaved = 0;
        string? failure = null;
        try
        {
            do
            {
                autoSavePassRequested = false;
                var candidates = workspace.Documents.Where(document =>
                    AutoSavePolicy.IsEligible(document, autoSaveConflictedPaths.Contains(document.Path))).ToList();
                foreach (var snapshot in candidates)
                {
                    var result = await writer.SaveAsync(snapshot.Path, snapshot.Content, snapshot.Encoding,
                        snapshot.LineEnding, snapshot.Revision);
                    var current = workspace.Find(snapshot.Path);
                    if (current is null) continue;
                    if (!result.Saved)
                    {
                        if (result.Failure == FileWriteFailure.RevisionConflict)
                        {
                            autoSaveConflictedPaths.Add(snapshot.Path);
                        }
                        failure = result.Message ?? $"Auto Save could not save {snapshot.DisplayName}.";
                        continue;
                    }
                    var unchanged = StringComparer.Ordinal.Equals(current.Content, snapshot.Content)
                        && current.Encoding == snapshot.Encoding && current.LineEnding == snapshot.LineEnding;
                    var bytes = File.Exists(snapshot.Path) ? new FileInfo(snapshot.Path).Length : current.ByteLength;
                    workspace.Replace(snapshot.Path, current with
                    {
                        ByteLength = bytes, Revision = result.Revision, IsDirty = !unchanged
                    });
                    StoreSavedBaseline(snapshot.Path, snapshot.Content);
                    autoSaveConflictedPaths.Remove(snapshot.Path);
                    totalSaved++;
                    if (!unchanged) autoSavePassRequested = true;
                }
            } while (autoSavePassRequested && settings.AutoSave != AutoSaveMode.Off);
        }
        finally
        {
            autoSaveRunning = false;
            RefreshDocumentList();
            await PersistAsync();
        }
        Status.Text = failure ?? (totalSaved > 0 ? $"Auto Save saved {totalSaved} document(s)." : Status.Text);
    }

    private void Editor_SelectionChanged(object sender, RoutedEventArgs args)
    {
        if (!uiReady || applyingEditorText || nativeMultiEditPending) return;
        var previous = buffer.Selections;
        var current = EditorSelection();
        if (previous.Main != current || previous.Ranges.Count > 1)
        {
            CurrentSelectionHistory().Observe(previous, MultiSelectionSet.Single(current));
            CurrentExpansionHistory().Clear();
            buffer.SetSelection(current);
            QueueLineNumberRefresh(paneLayout.ActivePane);
        }
        RefreshFindStatus();
        RefreshDocumentStatus();
    }

    private void Editor_KeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (completionFlyout.IsOpen)
        {
            if (args.Key == VirtualKey.Escape)
            {
                HideCompletion();
                args.Handled = true;
                return;
            }
            if (args.Key is VirtualKey.Down or VirtualKey.Up && completionList.Items.Count > 0)
            {
                var delta = args.Key == VirtualKey.Down ? 1 : -1;
                completionList.SelectedIndex = Math.Clamp(
                    completionList.SelectedIndex + delta, 0, completionList.Items.Count - 1);
                completionList.ScrollIntoView(completionList.SelectedItem);
                args.Handled = true;
                return;
            }
            if (args.Key is VirtualKey.Enter or VirtualKey.Tab
                && completionList.SelectedItem is CompletionListItem selectedCompletion)
            {
                ApplyCompletion(selectedCompletion.Completion);
                args.Handled = true;
                return;
            }
        }
        if (!uiReady) return;
        if (args.Key == VirtualKey.Back && !imeCompositionActive)
        {
            SynchronizeBufferSelection();
            if (EditorInputPlanner.DeleteEmptyPairs(buffer))
            {
                ApplyBufferToEditor();
                args.Handled = true;
            }
            return;
        }
        if (args.Key == VirtualKey.Enter && !imeCompositionActive)
        {
            SynchronizeBufferSelection();
            IReadOnlyList<CodeMirrorNewlineIndentation> indentation = [];
            if (workspace.ActiveDocument is { } active)
            {
                var language = CurrentLanguage(active);
                if (documentParserSnapshots.TryGetValue(active.Path, out var snapshot)
                    && snapshot.Text == buffer.Text && snapshot.Language == language.ParserName
                    && snapshot.Analysis.Supported && !snapshot.Analysis.Truncated.Indentation)
                    indentation = snapshot.Analysis.NewlineIndentation;
                if (EditorInputPlanner.InsertNewline(
                    buffer, settings.TabSize, settings.InsertSpaces, indentation, language.Id))
                {
                    ApplyBufferToEditor();
                    args.Handled = true;
                }
            }
            return;
        }
        if (args.Key != VirtualKey.Tab) return;
        SynchronizeBufferSelection();
        var spaces = settings.InsertSpaces ? new string(' ', settings.TabSize) : "\t";
        var changed = buffer.Selections.Ranges.Count > 1
            ? MultiSelectionCommands.ApplyPrimaryEdit(buffer,
                buffer.Text[..buffer.Selection.Start] + spaces + buffer.Text[buffer.Selection.End..],
                new TextSelection(buffer.Selection.Start + spaces.Length, buffer.Selection.Start + spaces.Length))
            : buffer.Replace(buffer.Selection, spaces);
        if (!changed) return;
        ApplyBufferToEditor();
        args.Handled = true;
    }

    private void Editor_CharacterReceived(object sender, CharacterReceivedRoutedEventArgs args)
    {
        if (!uiReady || applyingEditorText || imeCompositionActive || args.Handled
            || args.Character > Char.MaxValue) return;
        SynchronizeBufferSelection();
        var character = (char)args.Character;
        var changed = character is ')' or ']' or '}' or '"' or '\'' or '`'
            && EditorInputPlanner.SkipClosing(buffer, character);
        if (!changed && character is '(' or '[' or '{' or '"' or '\'' or '`')
            changed = EditorInputPlanner.InsertPair(buffer, character);
        if (!changed) return;
        ApplyBufferToEditor();
        args.Handled = true;
    }

    private void ScheduleCompletion()
    {
        completionCancellation?.Cancel();
        completionCancellation?.Dispose();
        completionCancellation = null;
        HideCompletion(clearCancellation: false);
        if (imeCompositionActive || workspace.ActiveDocument is not { } document
            || buffer.Selections.Ranges.Count != 1 || buffer.Selection.Length != 0) return;
        var prefix = CompletionEngine.PrefixAt(buffer.Text, buffer.Selection.Head);
        if (prefix.Text.Length < 2) return;
        var owner = new CancellationTokenSource();
        completionCancellation = owner;
        _ = ShowCompletionsAsync(document, buffer.Text, buffer.Revision, prefix, owner);
    }

    private async Task ShowCompletionsAsync(OpenedDocument document, string text, ulong revision,
        CompletionPrefix prefix, CancellationTokenSource owner)
    {
        try
        {
            await Task.Delay(160, owner.Token);
            StartWorkspaceWordRefresh();
            IReadOnlyList<LanguageCompletionItem> candidates = [];
            var client = languageServer;
            if (client?.IsRunning == true && languageServerRoot is not null
                && WorkspaceTree.IsInside(languageServerRoot, document.Path)
                && !String.IsNullOrWhiteSpace(settings.LanguageServerLanguageId))
            {
                try
                {
                    await client.SyncDocumentAsync(
                        document.Path, settings.LanguageServerLanguageId, text, owner.Token);
                    var (line, column) = TextNavigation.OffsetToLineColumn(text, prefix.To);
                    var response = await client.RequestDocumentAsync(
                        "textDocument/completion", document.Path, line - 1, column - 1,
                        cancellationToken: owner.Token);
                    candidates = LanguageServerResults.ParseCompletions(response);
                }
                catch (Exception error) when (error is IOException or InvalidDataException
                    or InvalidOperationException or OperationCanceledException)
                {
                    if (owner.IsCancellationRequested) return;
                }
            }
            if (candidates.Count == 0)
            {
                var sources = workspace.Documents.Select(item => item.Content)
                    .Concat(workspaceWords).ToArray();
                candidates = await Task.Run(
                    () => CompletionEngine.WordFallback(prefix.Text, sources), owner.Token);
            }
            if (owner.IsCancellationRequested || candidates.Count == 0
                || !StringComparer.OrdinalIgnoreCase.Equals(workspace.ActiveDocument?.Path, document.Path)
                || buffer.Revision != revision || buffer.Selection.Head != prefix.To) return;
            var filtered = candidates.Where(item => item.Label.StartsWith(
                    prefix.Text, StringComparison.OrdinalIgnoreCase)
                && !item.Label.Equals(prefix.Text, StringComparison.Ordinal))
                .Take(CompletionEngine.MaximumVisibleItems).Select(item => new CompletionListItem(item)).ToList();
            if (filtered.Count == 0) return;
            completionPrefix = prefix;
            completionPath = document.Path;
            completionRevision = revision;
            completionList.ItemsSource = filtered;
            completionList.SelectedIndex = 0;
            var caret = TextPositionRect(Editor, text, prefix.To, trailing: true);
            completionFlyout.ShowAt(Editor, new FlyoutShowOptions
            {
                Position = new global::Windows.Foundation.Point(caret.X, caret.Y + caret.Height),
                Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft,
                ShowMode = FlyoutShowMode.Transient
            });
        }
        catch (OperationCanceledException) when (owner.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(completionCancellation, owner)) completionCancellation = null;
            owner.Dispose();
        }
    }

    private void CompletionList_ItemClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is CompletionListItem item) ApplyCompletion(item.Completion);
    }

    private void ApplyCompletion(LanguageCompletionItem completion)
    {
        if (completionPrefix is not { } prefix || completionPath is null
            || !StringComparer.OrdinalIgnoreCase.Equals(workspace.ActiveDocument?.Path, completionPath)
            || buffer.Revision != completionRevision || buffer.Selection.Head != prefix.To)
        {
            HideCompletion();
            return;
        }
        var inserted = completion.InsertText ?? completion.Label;
        if (buffer.Replace(new TextSelection(prefix.From, prefix.To), inserted)) ApplyBufferToEditor();
        HideCompletion();
    }

    private void HideCompletion(bool clearCancellation = true)
    {
        completionFlyout.Hide();
        completionList.ItemsSource = null;
        completionPrefix = null;
        completionPath = null;
        if (!clearCancellation) return;
        completionCancellation?.Cancel();
        completionCancellation?.Dispose();
        completionCancellation = null;
    }

    private void StartWorkspaceWordRefresh()
    {
        if (workspaceWordsRefresh is not null || workspaceRoots.Count == 0
            || DateTimeOffset.UtcNow - workspaceWordsAt < TimeSpan.FromMinutes(1)) return;
        var indexed = workspaceFileIndex.ToArray();
        var roots = workspaceRoots.ToArray();
        var exclusions = projectExclusions;
        workspaceWordsCancellation = new CancellationTokenSource();
        var cancellationToken = workspaceWordsCancellation.Token;
        workspaceWordsRefresh = Task.Run(async () =>
        {
            var files = indexed.Length > 0 ? indexed
                : WorkspaceFileIndex.EnumerateFiles(roots, workspaceTree, exclusions);
            return await WorkspaceWordIndex.BuildAsync(files, cancellationToken);
        }).ContinueWith(task =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (task.Status == TaskStatus.RanToCompletion)
                {
                    workspaceWords = task.Result;
                    workspaceWordsAt = DateTimeOffset.UtcNow;
                }
                workspaceWordsRefresh = null;
                workspaceWordsCancellation?.Dispose();
                workspaceWordsCancellation = null;
            });
        }, TaskScheduler.Default);
    }

    private void ScheduleLanguageServerSync()
    {
        languageServerSyncCancellation?.Cancel();
        languageServerSyncCancellation?.Dispose();
        languageServerSyncCancellation = null;
        var client = languageServer;
        var document = workspace.ActiveDocument;
        if (client?.IsRunning != true || document is null || languageServerRoot is null
            || document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)
            || !WorkspaceTree.IsInside(languageServerRoot, document.Path)
            || String.IsNullOrWhiteSpace(settings.LanguageServerLanguageId)) return;
        var owner = new CancellationTokenSource();
        languageServerSyncCancellation = owner;
        var text = buffer.Text;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(250, owner.Token);
                await client.SyncDocumentAsync(
                    document.Path, settings.LanguageServerLanguageId, text, owner.Token);
            }
            catch (Exception error) when (error is IOException or InvalidOperationException
                or OperationCanceledException or ObjectDisposedException) { }
            finally
            {
                if (ReferenceEquals(languageServerSyncCancellation, owner))
                    languageServerSyncCancellation = null;
                owner.Dispose();
            }
        }, owner.Token);
    }

    private void Editor_TextCompositionStarted(object sender, TextCompositionStartedEventArgs args)
    {
        imeCompositionActive = true;
        HideCompletion();
        if (buffer.Selections.Ranges.Count <= 1) return;
        var previous = buffer.Selections;
        buffer.SetSelection(EditorSelection());
        CurrentSelectionHistory().Observe(previous, buffer.Selections);
        QueueLineNumberRefresh(paneLayout.ActivePane);
    }

    private void Editor_TextCompositionEnded(object sender, TextCompositionEndedEventArgs args)
    {
        imeCompositionActive = false;
    }

    private void Editor_GotFocus(object sender, RoutedEventArgs args)
    {
        if (!uiReady || applyingEditorText || sender is not NativeCodeEditor editor
            || !Int32.TryParse(editor.Tag?.ToString(), out var paneIndex)
            || !paneLayout.SetActivePane(paneIndex)) return;
        ApplyPaneLayoutVisuals();
        ActivateCurrentPaneDocument();
        HideCompletion();
    }

    private void RefreshWorkspace()
    {
        RefreshDocumentList();
        RefreshEditors();
        RefreshOutline();
        ApplyFoldingToEditors();
    }

    private void RefreshDocumentList()
    {
        DocumentList.ItemsSource = null;
        DocumentList.ItemsSource = workspace.Documents;
        DocumentList.SelectedItem = workspace.ActiveDocument;
    }

    private void RefreshEditor()
    {
        var document = workspace.ActiveDocument;
        if (document is null)
        {
            buffer = new EditorBuffer();
        }
        else if (!documentBuffers.TryGetValue(document.Path, out var existing)
            || !StringComparer.Ordinal.Equals(existing.Text, document.Content))
        {
            buffer = new EditorBuffer(document.Content);
            documentBuffers[document.Path] = buffer;
        }
        else buffer = existing;
        applyingEditorText = true;
        Editor.Text = buffer.Text;
        Editor.Select(buffer.Selection.Start, buffer.Selection.Length);
        applyingEditorText = false;
        QueueLineNumberRefresh(paneLayout.ActivePane);
        RefreshDocumentStatus();
        RefreshPreview();
        RefreshOutline();
        ScheduleSyntaxHighlighting(paneLayout.ActivePane);
        ApplyFoldingToEditors();
        ScheduleDiffDecorations();
        ScheduleLanguageServerSync();
    }

    private void RefreshEditors()
    {
        applyingEditorText = true;
        try
        {
            for (var index = 0; index < editors.Length; index++)
            {
                var path = index < paneLayout.ActiveDocuments.Count ? paneLayout.ActiveDocuments[index] : null;
                var document = path is null ? null : workspace.Find(path);
                editors[index].Text = document?.Content ?? String.Empty;
                editors[index].IsReadOnly = document is null;
                if (index == paneLayout.ActivePane && document is not null)
                {
                    if (!documentBuffers.TryGetValue(document.Path, out var existing)
                        || !StringComparer.Ordinal.Equals(existing.Text, document.Content))
                    {
                        existing = new EditorBuffer(document.Content);
                        documentBuffers[document.Path] = existing;
                    }
                    buffer = existing;
                    editors[index].Select(buffer.Selection.Start, buffer.Selection.Length);
                }
            }
        }
        finally { applyingEditorText = false; }
        for (var index = 0; index < editors.Length; index++) QueueLineNumberRefresh(index);
        RefreshDocumentStatus();
        RefreshPreview();
        RefreshOutline();
        for (var index = 0; index < editors.Length; index++) ScheduleSyntaxHighlighting(index);
        ScheduleDiffDecorations();
        ScheduleLanguageServerSync();
    }

    private void ApplyBufferToEditor()
    {
        ClearActiveSelectionHistories();
        applyingEditorText = true;
        var activePath = workspace.ActiveDocument?.Path;
        for (var index = 0; index < editors.Length; index++)
        {
            if (activePath is not null && index < paneLayout.ActiveDocuments.Count
                && StringComparer.Ordinal.Equals(paneLayout.ActiveDocuments[index], activePath))
            {
                editors[index].Text = buffer.Text;
            }
        }
        Editor.Select(buffer.Selection.Start, buffer.Selection.Length);
        applyingEditorText = false;
        for (var index = 0; index < editors.Length; index++) QueueLineNumberRefresh(index);
        workspace.UpdateActiveContent(buffer.Text);
        RefreshDocumentStatus();
        RefreshOutline();
        ApplyFoldingToEditors();
        for (var index = 0; index < editors.Length; index++) ScheduleSyntaxHighlighting(index);
        ScheduleDiffDecorations();
        ScheduleAutoSaveAfterEdit();
    }

    private void ApplyBufferSelectionToEditor()
    {
        RevealSelectionFromFolds();
        applyingEditorText = true;
        Editor.Select(buffer.Selection.Start, buffer.Selection.Length);
        applyingEditorText = false;
        QueueLineNumberRefresh(paneLayout.ActivePane);
        Editor.Focus(FocusState.Programmatic);
    }

    private void RevealSelectionFromFolds()
    {
        var path = workspace.ActiveDocument?.Path;
        if (path is null || !documentFoldingStates.TryGetValue(path, out var state)) return;
        var changed = false;
        while (state.HiddenRanges.Any(range => buffer.Selection.Head >= range.Start
            && buffer.Selection.Head < range.End))
        {
            if (!state.UnfoldCurrent(buffer.Selection.Head)) break;
            changed = true;
        }
        if (changed) ApplyFoldingToEditors();
    }

    private CodeFoldingState CurrentFoldingState()
    {
        var document = workspace.ActiveDocument ?? throw new InvalidOperationException("No active document.");
        if (!documentFoldingStates.TryGetValue(document.Path, out var state))
        {
            state = new CodeFoldingState();
            documentFoldingStates[document.Path] = state;
        }
        var language = CurrentLanguage(document).Id;
        var parserLanguage = CurrentLanguage(document).ParserName;
        if (documentParserSnapshots.TryGetValue(document.Path, out var snapshot)
            && snapshot.Text == buffer.Text && snapshot.Language == parserLanguage
            && snapshot.Analysis.Supported && snapshot.Analysis.ParserKind == CodeMirrorParserKind.Lezer
            && !snapshot.Analysis.Truncated.Source && !snapshot.Analysis.Truncated.Folds)
            state.Update(snapshot.Analysis.ToFoldRegions(buffer.Text));
        else state.Update(CodeFoldAnalyzer.Analyze(buffer.Text, language));
        return state;
    }

    private void ApplyFoldingToEditors()
    {
        var wasApplying = applyingEditorText;
        applyingEditorText = true;
        try
        {
            for (var index = 0; index < editors.Length; index++)
            {
                var path = index < paneLayout.ActiveDocuments.Count ? paneLayout.ActiveDocuments[index] : null;
                var document = path is null ? null : workspace.Find(path);
                var ranges = path is not null && documentFoldingStates.TryGetValue(path, out var state)
                    ? state.HiddenRanges : [];
                editors[index].ApplyHiddenRanges(ranges, document?.Content.Length ?? 0);
                QueueLineNumberRefresh(index);
            }
        }
        finally { applyingEditorText = wasApplying; }
    }

    private void ScheduleSyntaxHighlighting(int paneIndex, bool immediate = false)
    {
        if (paneIndex < 0 || paneIndex >= editors.Length) return;
        syntaxHighlightCancellations[paneIndex]?.Cancel();
        syntaxHighlightCancellations[paneIndex]?.Dispose();
        var owner = new CancellationTokenSource();
        syntaxHighlightCancellations[paneIndex] = owner;
        _ = HighlightPaneAsync(paneIndex, owner, immediate);
    }

    private async Task HighlightPaneAsync(int paneIndex, CancellationTokenSource owner, bool immediate)
    {
        try
        {
            if (!immediate) await Task.Delay(120, owner.Token);
            var path = paneIndex < paneLayout.ActiveDocuments.Count ? paneLayout.ActiveDocuments[paneIndex] : null;
            var document = path is null ? null : workspace.Find(path);
            if (document is null) return;
            var text = documentBuffers.TryGetValue(document.Path, out var paneBuffer)
                ? paneBuffer.Text : document.Content;
            var language = CurrentLanguage(document).Id;
            var parserLanguage = CurrentLanguage(document).ParserName;
            SyntaxHighlightPlan? plan = null;
            CodeMirrorParserAnalysis? parserAnalysis = null;
            if (language is not "plain" and not "diff"
                && CodeMirrorParserProtocol.IsSourceWithinBudget(text))
            {
                CodeMirrorParserWorkerProcess? worker = null;
                try
                {
                    worker = await GetParserWorkerAsync();
                    var indentationPositions = paneBuffer is not null
                        && paneBuffer.Selections.Ranges.Count <= CodeMirrorParserProtocol.MaximumNewlineIndentationEntries
                        && paneBuffer.Selections.Ranges.All(selection => selection.Length == 0)
                        ? paneBuffer.Selections.Ranges.Select(selection => selection.Head).Distinct().Order().ToArray()
                        : [];
                    if (worker is not null) parserAnalysis = await worker.AnalyzeAsync(
                        text, parserLanguage, settings.TabSize, settings.TabSize, settings.InsertSpaces, owner.Token,
                        indentationPositions);
                    if (parserAnalysis?.Supported == true) plan = parserAnalysis.ToSyntaxHighlightPlan();
                }
                catch (Exception error) when (error is IOException or InvalidDataException
                    or InvalidOperationException or OperationCanceledException
                    or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
                {
                    if (worker is not null && !worker.IsUsable && ReferenceEquals(parserWorker, worker))
                    {
                        parserWorker = null;
                        await worker.DisposeAsync();
                    }
                }
            }
            plan ??= await Task.Run(() => SyntaxHighlighter.Plan(text, language), owner.Token);
            if (owner.IsCancellationRequested) return;
            var currentPath = paneIndex < paneLayout.ActiveDocuments.Count ? paneLayout.ActiveDocuments[paneIndex] : null;
            var current = currentPath is null ? null : workspace.Find(currentPath);
            if (!StringComparer.OrdinalIgnoreCase.Equals(currentPath, document.Path)
                || current is null || !StringComparer.Ordinal.Equals(current.Content, text)) return;
            var wasApplying = applyingEditorText;
            applyingEditorText = true;
            try
            {
                editors[paneIndex].ApplySyntaxHighlighting(plan, settings.ColorScheme, text.Length);
                if (parserAnalysis?.Supported == true)
                {
                    StoreParserSnapshot(document.Path, new(text, parserLanguage, parserAnalysis));
                    if (parserAnalysis.ParserKind == CodeMirrorParserKind.Lezer
                        && !parserAnalysis.Truncated.Source && !parserAnalysis.Truncated.Folds)
                    {
                        if (!documentFoldingStates.TryGetValue(document.Path, out var state))
                        {
                            state = new CodeFoldingState();
                            documentFoldingStates[document.Path] = state;
                        }
                        state.Update(parserAnalysis.ToFoldRegions(text));
                    }
                    else
                    {
                        if (!documentFoldingStates.TryGetValue(document.Path, out var state))
                        {
                            state = new CodeFoldingState();
                            documentFoldingStates[document.Path] = state;
                        }
                        state.Update(CodeFoldAnalyzer.Analyze(text, language));
                    }
                    ApplyFoldingToEditors();
                    if (StringComparer.OrdinalIgnoreCase.Equals(workspace.ActiveDocument?.Path, document.Path))
                        RefreshOutline();
                }
                else
                {
                    if (!documentFoldingStates.TryGetValue(document.Path, out var state))
                    {
                        state = new CodeFoldingState();
                        documentFoldingStates[document.Path] = state;
                    }
                    state.Update(CodeFoldAnalyzer.Analyze(text, language));
                    ApplyFoldingToEditors();
                }
            }
            finally { applyingEditorText = wasApplying; }
        }
        catch (OperationCanceledException) when (owner.IsCancellationRequested) { }
        finally
        {
            if (ReferenceEquals(syntaxHighlightCancellations[paneIndex], owner))
            {
                syntaxHighlightCancellations[paneIndex] = null;
            }
            owner.Dispose();
        }
    }

    private async Task<CodeMirrorParserWorkerProcess?> GetParserWorkerAsync()
    {
        if (parserWorker is not null) return parserWorker;
        if (!OperatingSystem.IsWindows()) return null;
        var executable = WorkerExecutablePath();
        var bundle = Path.Combine(AppContext.BaseDirectory, "Resources", "CodeMirrorParserBundle.js");
        if (String.IsNullOrWhiteSpace(executable) || !File.Exists(bundle)) return null;
        parserWorkerStartup ??= CodeMirrorParserWorkerProcess.StartAsync(executable, bundle);
        try
        {
            parserWorker = await parserWorkerStartup;
            return parserWorker;
        }
        finally { parserWorkerStartup = null; }
    }

    private void StoreParserSnapshot(string path, ParserDocumentSnapshot snapshot)
    {
        documentParserSnapshots[path] = snapshot;
        if (documentParserSnapshots.Count <= MaximumParserSnapshots) return;
        var visible = paneLayout.ActiveDocuments.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var stale in documentParserSnapshots.Keys.Where(candidate => !visible.Contains(candidate)
            && !StringComparer.OrdinalIgnoreCase.Equals(candidate, path)).ToList())
        {
            documentParserSnapshots.Remove(stale);
            if (documentParserSnapshots.Count <= MaximumParserSnapshots) break;
        }
    }

    private void StoreSavedBaseline(string path, string text)
    {
        if (path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase)
            || text.Length > 2_000_000 || text.Count(character => character == '\n') + 1
                > IncrementalDiff.MaximumLines) return;
        documentSavedBaselines[path] = text;
        documentDiffSnapshots.Remove(path);
        TrimVisibleCache(documentSavedBaselines);
    }

    private void ScheduleDiffDecorations()
    {
        diffDecorationCancellation?.Cancel();
        diffDecorationCancellation?.Dispose();
        diffDecorationCancellation = null;
        if (workspace.ActiveDocument is not { IsDirty: true } document
            || !documentSavedBaselines.TryGetValue(document.Path, out var baseline)
            || buffer.Text.Length > 2_000_000) return;
        var owner = new CancellationTokenSource();
        diffDecorationCancellation = owner;
        var text = buffer.Text;
        var revision = buffer.Revision;
        var path = document.Path;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(180, owner.Token);
                var changes = IncrementalDiff.Compute(baseline, text);
                owner.Token.ThrowIfCancellationRequested();
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (documentBuffers.TryGetValue(path, out var current)
                        && current.Revision == revision && current.Text == text)
                    {
                        documentDiffSnapshots[path] = new(revision, changes);
                        TrimVisibleCache(documentDiffSnapshots);
                        for (var pane = 0; pane < editors.Length; pane++) QueueLineNumberRefresh(pane);
                    }
                });
            }
            catch (OperationCanceledException) when (owner.IsCancellationRequested) { }
            finally
            {
                if (ReferenceEquals(diffDecorationCancellation, owner))
                    diffDecorationCancellation = null;
                owner.Dispose();
            }
        }, owner.Token);
    }

    private void TrimVisibleCache<T>(Dictionary<string, T> cache)
    {
        if (cache.Count <= MaximumDiffSnapshots) return;
        var visible = paneLayout.ActiveDocuments.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var path in cache.Keys.Where(path => !visible.Contains(path)).ToList())
        {
            cache.Remove(path);
            if (cache.Count <= MaximumDiffSnapshots) break;
        }
    }

    private void RunFoldingCommand(string command)
    {
        if (workspace.ActiveDocument is null) return;
        SynchronizeBufferSelection();
        var state = CurrentFoldingState();
        var changed = command switch
        {
            "fold-current" => state.FoldCurrent(buffer.Selection.Head),
            "unfold-current" => state.UnfoldCurrent(buffer.Selection.Head),
            "fold-all" => state.FoldAll(),
            "unfold-all" => state.UnfoldAll(),
            _ => false
        };
        if (!changed)
        {
            Status.Text = command.StartsWith("unfold", StringComparison.Ordinal)
                ? Localize("No folded code blocks to unfold.", "没有可展开的代码块。")
                : Localize("No foldable code block at the cursor.", "当前位置没有可折叠的代码块。");
            return;
        }
        if (command.StartsWith("fold", StringComparison.Ordinal)
            && state.FoldedRegions.Where(region => region.Contains(buffer.Selection.Head))
                .OrderBy(region => command == "fold-all" ? region.FullRange.Start : region.FullRange.Length)
                .FirstOrDefault() is { } folded)
        {
            buffer.SetSelection(new TextSelection(folded.FullRange.Start, folded.FullRange.Start));
            ApplyBufferSelectionToEditor();
        }
        ApplyFoldingToEditors();
        Status.Text = command.StartsWith("unfold", StringComparison.Ordinal)
            ? Localize("Code unfolded.", "代码已展开。")
            : Localize("Code folded.", "代码已折叠。");
    }

    private void RunMultiSelectionCommand(Func<EditorBuffer, bool> action, string noChangeMessage)
    {
        SynchronizeBufferSelection();
        var previous = buffer.Selections;
        if (!action(buffer))
        {
            Status.Text = noChangeMessage;
            return;
        }
        CurrentSelectionHistory().Observe(previous, buffer.Selections);
        CurrentExpansionHistory().Clear();
        ApplyBufferSelectionToEditor();
        RefreshDocumentStatus();
    }

    private SelectionHistory CurrentSelectionHistory()
    {
        var path = workspace.ActiveDocument?.Path ?? "__none__";
        if (!documentSelectionHistories.TryGetValue(path, out var history))
        {
            history = new SelectionHistory();
            documentSelectionHistories[path] = history;
        }
        return history;
    }

    private Stack<TextSelection> CurrentExpansionHistory()
    {
        var path = workspace.ActiveDocument?.Path ?? "__none__";
        if (!documentExpansionHistories.TryGetValue(path, out var history))
        {
            history = new Stack<TextSelection>();
            documentExpansionHistories[path] = history;
        }
        return history;
    }

    private void ClearActiveSelectionHistories()
    {
        if (workspace.ActiveDocument is not { } document) return;
        if (documentSelectionHistories.TryGetValue(document.Path, out var history)) history.Clear();
        if (documentExpansionHistories.TryGetValue(document.Path, out var expansion)) expansion.Clear();
    }

    private void RunSelectionCommand(Func<EditorBuffer, bool> action, string noChangeMessage, bool expansion = false)
    {
        SynchronizeBufferSelection();
        var previous = buffer.Selections;
        if (!action(buffer))
        {
            Status.Text = noChangeMessage;
            return;
        }
        CurrentSelectionHistory().Observe(previous, buffer.Selections);
        if (expansion)
        {
            var stack = CurrentExpansionHistory();
            stack.Push(previous.Main);
            if (stack.Count > SelectionHistory.MaximumEntries)
            {
                var retained = stack.Take(SelectionHistory.MaximumEntries).Reverse().ToArray();
                stack.Clear();
                foreach (var selection in retained) stack.Push(selection);
            }
        }
        else CurrentExpansionHistory().Clear();
        ApplyBufferSelectionToEditor();
    }

    private void UndoSelectionChange(bool redo)
    {
        SynchronizeBufferSelection();
        var target = redo
            ? CurrentSelectionHistory().Redo(buffer.Selections)
            : CurrentSelectionHistory().Undo(buffer.Selections);
        if (target is null || !target.IsValidFor(buffer.Text))
        {
            Status.Text = redo ? "No selection change to redo." : "No selection change to undo.";
            return;
        }
        buffer.SetSelections(target);
        CurrentExpansionHistory().Clear();
        ApplyBufferSelectionToEditor();
    }

    private void ShrinkSelection()
    {
        SynchronizeBufferSelection();
        var history = CurrentExpansionHistory();
        if (!history.TryPop(out var previous) || !previous.IsValidFor(buffer.Text))
        {
            Status.Text = "No expanded selection to shrink.";
            return;
        }
        CurrentSelectionHistory().Observe(buffer.Selection, previous);
        buffer.SetSelection(previous);
        ApplyBufferSelectionToEditor();
    }

    private TextSelection EditorSelection()
    {
        var text = buffer.Text;
        var start = Math.Clamp(Editor.SelectionStart, 0, text.Length);
        var end = Math.Clamp(start + Editor.SelectionLength, start, text.Length);
        var selection = new TextSelection(start, end);
        if (selection.IsValidFor(text)) return selection;
        if (start > 0 && start < text.Length
            && char.IsHighSurrogate(text[start - 1]) && char.IsLowSurrogate(text[start]))
        {
            start--;
        }
        if (end > 0 && end < text.Length
            && char.IsHighSurrogate(text[end - 1]) && char.IsLowSurrogate(text[end]))
        {
            end--;
        }
        return new TextSelection(start, Math.Max(start, end));
    }

    private void SynchronizeBufferSelection()
    {
        var current = EditorSelection();
        if (current != buffer.Selection) buffer.SetSelection(current);
    }

    private FindQuery CurrentFindQuery() => new(
        FindInput.Text,
        MatchCaseToggle.IsChecked == true,
        WholeWordToggle.IsChecked == true,
        RegexToggle.IsChecked == true);

    private bool ValidateFindQuery(FindQuery query)
    {
        if (String.IsNullOrEmpty(query.Text))
        {
            FindStatus.Text = "Enter text to find.";
            return false;
        }
        if (!FindEngine.IsValid(query))
        {
            FindStatus.Text = "Invalid regular expression.";
            return false;
        }
        return true;
    }

    private void SelectFindMatch(bool reverse)
    {
        if (FindPanel.Visibility != Visibility.Visible) ShowFind(replace: false);
        SynchronizeBufferSelection();
        var query = CurrentFindQuery();
        if (!ValidateFindQuery(query)) return;
        var match = FindEngine.FindNext(buffer.Text, query, buffer.Selection, reverse);
        if (match is null)
        {
            FindStatus.Text = "No matches.";
            return;
        }
        buffer.SetSelection(new TextSelection(match.Start, match.Start + match.Length));
        ApplyBufferSelectionToEditor();
        RefreshFindStatus();
    }

    private void ShowFind(bool replace)
    {
        WorkspaceSearchPanel.Visibility = Visibility.Collapsed;
        SettingsPanel.Visibility = Visibility.Collapsed;
        SynchronizeBufferSelection();
        if (FindPanel.Visibility != Visibility.Visible)
        {
            var selected = buffer.Text[buffer.Selection.Start..buffer.Selection.End];
            if (selected.Length is > 0 and <= 200 && !selected.Contains('\n') && !selected.Contains('\r'))
            {
                FindInput.Text = selected;
            }
            FindPanel.Visibility = Visibility.Visible;
        }
        if (replace) ReplaceInput.Focus(FocusState.Programmatic);
        else FindInput.Focus(FocusState.Programmatic);
        FindInput.SelectAll();
        RefreshFindStatus();
    }

    private void ShowWorkspaceSearch()
    {
        FindPanel.Visibility = Visibility.Collapsed;
        SettingsPanel.Visibility = Visibility.Collapsed;
        WorkspaceSearchPanel.Visibility = Visibility.Visible;
        if (WorkspaceSearchInput.Text.Length == 0)
        {
            SynchronizeBufferSelection();
            var selected = buffer.Text[buffer.Selection.Start..buffer.Selection.End];
            if (selected.Length is > 0 and <= 200 && !selected.Contains('\n') && !selected.Contains('\r'))
            {
                WorkspaceSearchInput.Text = selected;
            }
        }
        WorkspaceSearchInput.Focus(FocusState.Programmatic);
        WorkspaceSearchInput.SelectAll();
        WorkspaceSearchStatus.Text = workspaceRoots.Count == 0
            ? "Open a folder before searching across files."
            : "Ready to search.";
    }

    private void ShowSettings()
    {
        FindPanel.Visibility = Visibility.Collapsed;
        WorkspaceSearchPanel.Visibility = Visibility.Collapsed;
        LanguageServerSettingsPanel.Visibility = Visibility.Collapsed;
        FontSizeSetting.Value = settings.FontSize;
        TabSizeSetting.Value = settings.TabSize;
        MaxFileSizeSetting.Value = settings.MaxFileSizeMb;
        InsertSpacesSetting.IsChecked = settings.InsertSpaces;
        WordWrapSetting.IsChecked = settings.WordWrap;
        LineNumbersSetting.IsChecked = settings.ShowLineNumbers;
        WhitespaceSetting.IsChecked = settings.ShowWhitespace;
        MinimapSetting.IsChecked = settings.ShowMinimap;
        IndentGuidesSetting.IsChecked = settings.ShowIndentGuides;
        TrailingWhitespaceSetting.IsChecked = settings.HighlightTrailingWhitespace;
        RulersSetting.Text = String.Join(", ", settings.Rulers ?? []);
        ColorSchemeSetting.SelectedIndex = (int)settings.ColorScheme;
        BuildCommandSetting.Text = settings.BuildCommand;
        AutoSaveSetting.SelectedIndex = settings.AutoSave switch
        {
            AutoSaveMode.AfterDelay => 1,
            AutoSaveMode.OnFocusChange => 2,
            _ => 0
        };
        AutoSaveDelaySetting.Value = settings.AutoSaveDelayMs;
        SettingsPanel.Visibility = Visibility.Visible;
        FontSizeSetting.Focus(FocusState.Programmatic);
    }

    private static IReadOnlyList<int> ParseRulers(string? value) => (value ?? String.Empty)
        .Split([',', ';', ' ', '\t'], StringSplitOptions.RemoveEmptyEntries)
        .Select(token => Int32.TryParse(token, out var column) ? column : 0)
        .Where(column => column is >= 1 and <= 500).Take(10).ToArray();

    private void ShowLanguageServerSettings()
    {
        FindPanel.Visibility = Visibility.Collapsed;
        WorkspaceSearchPanel.Visibility = Visibility.Collapsed;
        SettingsPanel.Visibility = Visibility.Collapsed;
        LanguageIdSetting.Text = settings.LanguageServerLanguageId;
        LanguageServerCommandSetting.Text = settings.LanguageServerCommand;
        LanguageServerArgumentsSetting.Text = settings.LanguageServerArguments;
        LanguageServerSettingsPanel.Visibility = Visibility.Visible;
        LanguageServerPanel.Visibility = Visibility.Visible;
        LanguageServerCommandSetting.Focus(FocusState.Programmatic);
    }

    private void ApplySettingsToEditor()
    {
        Root.RequestedTheme = settings.Theme == EditorTheme.Light ? ElementTheme.Light : ElementTheme.Dark;
        foreach (var editor in editors)
        {
            editor.FontSize = settings.FontSize;
            editor.ApplyColorScheme(settings.ColorScheme);
            editor.IsSpellCheckEnabled = settings.SpellCheck;
            editor.TextWrapping = settings.WordWrap ? TextWrapping.Wrap : TextWrapping.NoWrap;
            ScrollViewer.SetHorizontalScrollBarVisibility(
                editor, settings.WordWrap ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto);
        }
        for (var index = 0; index < lineNumberGutters.Length; index++)
        {
            minimapDirty[index] = true;
            QueueLineNumberRefresh(index);
            minimapCanvases[index].Visibility = settings.ShowMinimap
                ? Visibility.Visible : Visibility.Collapsed;
        }
        ApplyDistractionFreeVisuals(settings.DistractionFree);
        ApplyLocalization();
        for (var index = 0; index < editors.Length; index++) ScheduleSyntaxHighlighting(index);
    }

    private string Localize(string english, string chinese) => settings.Locale == "zh-CN" ? chinese : english;

    private void ApplyLocalization()
    {
        Title = settings.Locale == "zh-CN"
            ? "文本编辑器(徐洁阳) Windows 原生版"
            : "Lumen Editor Native for Windows";
        LocalizeElement(Root);
    }

    private void LocalizeElement(DependencyObject element)
    {
        switch (element)
        {
            case AppBarButton appBar when !String.IsNullOrWhiteSpace(appBar.Label):
                appBar.Label = WindowsLocalization.Text(settings.Locale, appBar.Label);
                break;
            case Button button when button.Content is string content:
                button.Content = WindowsLocalization.Text(settings.Locale, content);
                break;
            case CheckBox checkBox when checkBox.Content is string content:
                checkBox.Content = WindowsLocalization.Text(settings.Locale, content);
                break;
            case ComboBoxItem item when item.Content is string content:
                item.Content = WindowsLocalization.Text(settings.Locale, content);
                break;
            case TextBlock textBlock when !String.IsNullOrWhiteSpace(textBlock.Text):
                textBlock.Text = WindowsLocalization.Text(settings.Locale, textBlock.Text);
                break;
            case TextBox textBox when !String.IsNullOrWhiteSpace(textBox.PlaceholderText):
                textBox.PlaceholderText = WindowsLocalization.Text(settings.Locale, textBox.PlaceholderText);
                break;
        }
        if (element is FrameworkElement frameworkElement)
        {
            var automationName = Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(frameworkElement);
            if (!String.IsNullOrWhiteSpace(automationName))
            {
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
                    frameworkElement, WindowsLocalization.Text(settings.Locale, automationName));
            }
            if (ToolTipService.GetToolTip(frameworkElement) is string toolTip)
            {
                ToolTipService.SetToolTip(frameworkElement, WindowsLocalization.Text(settings.Locale, toolTip));
            }
        }
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(element); index++)
        {
            LocalizeElement(VisualTreeHelper.GetChild(element, index));
        }
    }

    private async Task SetLocaleAsync(string locale)
    {
        settings = EditorSettings.Sanitize(settings with { Locale = locale });
        ApplyLocalization();
        try
        {
            await settingsStore.SaveAsync(settings);
            Status.Text = Localize("Interface language changed to English.", "界面语言已切换为简体中文。");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Status.Text = Localize($"Interface language could not be saved: {error.Message}", $"无法保存界面语言：{error.Message}");
        }
    }

    private async Task ShowGoToLineAsync()
    {
        var input = new NumberBox
        {
            Minimum = 1,
            Maximum = Math.Max(1, buffer.Text.Count(character => character == '\n') + 1),
            Value = TextNavigation.OffsetToLineColumn(buffer.Text, Editor.SelectionStart).Line,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Go to Line",
            Content = input,
            PrimaryButtonText = "Go",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (workspace.ActiveDocument is { } active)
        {
            await NavigateToAsync(active.Path, (int)Math.Round(input.Value), 1);
        }
    }

    private void RegisterCommands()
    {
        RegisterCommand("new-file", () => New_Click(this, new RoutedEventArgs()));
        RegisterCommand("new-window", OpenNewWindow);
        RegisterCommand("open-file", () => _ = PickAndOpenFilesAsync());
        RegisterCommand("open-file-with-encoding", () => _ = PickAndOpenFilesWithEncodingAsync());
        RegisterCommand("open-folder", () => OpenFolder_Click(this, new RoutedEventArgs()));
        RegisterCommand("add-folder-to-project", () => OpenFolder_Click(this, new RoutedEventArgs()));
        RegisterCommand("remove-folder-from-project", () => _ = ShowRemoveWorkspaceRootAsync());
        RegisterCommand("open-recent-file", () => _ = ShowRecentItemsAsync(filesOnly: true));
        RegisterCommand("open-recent-project", () => _ = ShowRecentItemsAsync(projectsOnly: true));
        RegisterCommand("save", () => _ = SaveActiveAsync());
        RegisterCommand("save-as", () => _ = SaveActiveAsync(forcePicker: true));
        RegisterCommand("save-all", () => _ = SaveAllAsync());
        RegisterCommand("cycle-auto-save", () => _ = CycleAutoSaveAsync());
        RegisterCommand("reopen-tab", () => _ = ReopenClosedDocumentAsync());
        RegisterCommand("select-encoding", () => _ = SelectEncodingAsync());
        RegisterCommand("reopen-with-encoding", () => _ = ReopenActiveWithEncodingAsync());
        RegisterCommand("select-line-ending", () => _ = SelectLineEndingAsync());
        RegisterCommand("convert-eol-lf", () => SetLineEnding(LineEnding.Lf));
        RegisterCommand("convert-eol-crlf", () => SetLineEnding(LineEnding.CrLf));
        RegisterCommand("convert-eol-cr", () => SetLineEnding(LineEnding.Cr));
        RegisterCommand("close-tab", () => _ = CloseActiveDocumentAsync());
        RegisterCommand("toggle-pin-tab", () =>
        {
            if (workspace.ActiveDocument is not { } document) return;
            var pinned = workspace.TogglePin(document.Path);
            RefreshDocumentList();
            Status.Text = pinned ? "Tab pinned." : "Tab unpinned.";
        });
        RegisterCommand("close-other-tabs", () => _ = CloseDocumentsAsync(
            workspace.Documents.Where(document => document.Path != workspace.ActiveDocument?.Path && !document.IsPinned).Select(document => document.Path)));
        RegisterCommand("close-tabs-to-right", () => _ = CloseDocumentsAsync(
            workspace.ActiveDocument is { } active ? workspace.DocumentsAfter(active.Path).Where(document => !document.IsPinned).Select(document => document.Path) : []));
        RegisterCommand("close-all-tabs", () => _ = CloseDocumentsAsync(workspace.Documents.Where(document => !document.IsPinned).Select(document => document.Path)));
        RegisterCommand("next-tab", () => CycleDocument(reverse: false));
        RegisterCommand("prev-tab", () => CycleDocument(reverse: true));
        RegisterCommand("find", () => ShowFind(replace: false));
        RegisterCommand("replace", () => ShowFind(replace: true));
        RegisterCommand("find-next", () => SelectFindMatch(reverse: false));
        RegisterCommand("find-previous", () => SelectFindMatch(reverse: true));
        RegisterCommand("find-in-files", ShowWorkspaceSearch);
        RegisterCommand("replace-in-files", () =>
        {
            ShowWorkspaceSearch();
            WorkspaceReplacementInput.Focus(FocusState.Programmatic);
        });
        RegisterCommand("undo-replace-in-files", () => UndoWorkspaceReplace_Click(this, new RoutedEventArgs()));
        RegisterCommand("find-results-next", () => _ = NavigateWorkspaceResultAsync(reverse: false));
        RegisterCommand("find-results-prev", () => _ = NavigateWorkspaceResultAsync(reverse: true));
        RegisterCommand("next-change", () => _ = NavigateIncrementalChangeAsync(reverse: false));
        RegisterCommand("prev-change", () => _ = NavigateIncrementalChangeAsync(reverse: true));
        RegisterCommand("revert-current-change", () => _ = RevertCurrentIncrementalChangeAsync());
        RegisterCommand("go-to-line", () => _ = ShowGoToLineAsync());
        RegisterCommand("goto-anything", () => _ = ShowGotoAnythingAsync());
        RegisterCommand("goto-symbol", () => _ = ShowSymbolPickerAsync(project: false));
        RegisterCommand("goto-project-symbol", () => _ = ShowSymbolPickerAsync(project: true));
        RegisterCommand("goto-matching-bracket", () =>
        {
            SynchronizeBufferSelection();
            if (buffer.GoToMatchingBracket()) ApplyBufferSelectionToEditor();
        });
        RegisterCommand("add-cursor-above", () => RunMultiSelectionCommand(
            value => MultiSelectionCommands.AddVertical(value, below: false),
            Localize("There is no line above for another cursor.", "上方没有可添加光标的行。")));
        RegisterCommand("add-cursor-below", () => RunMultiSelectionCommand(
            value => MultiSelectionCommands.AddVertical(value, below: true),
            Localize("There is no line below for another cursor.", "下方没有可添加光标的行。")));
        RegisterCommand("select-next-occurrence", () => RunMultiSelectionCommand(
            value => MultiSelectionCommands.SelectNextOccurrence(value, skip: false),
            Localize("No further occurrence to select.", "没有更多可选择的匹配项。")));
        RegisterCommand("skip-current-occurrence", () => RunMultiSelectionCommand(
            value => MultiSelectionCommands.SelectNextOccurrence(value, skip: true),
            Localize("No further occurrence to select.", "没有更多可选择的匹配项。")));
        RegisterCommand("remove-last-cursor", () => RunMultiSelectionCommand(
            MultiSelectionCommands.RemoveMain,
            Localize("No extra cursor to remove.", "没有可移除的额外光标。")));
        RegisterCommand("select-all-occurrences", () => RunMultiSelectionCommand(
            MultiSelectionCommands.SelectAllOccurrences,
            Localize("No occurrence can be selected.", "没有可选择的匹配项。")));
        RegisterCommand("add-cursors-line-starts", () => RunMultiSelectionCommand(
            value => MultiSelectionCommands.AddLineBoundaries(value, atEnd: false),
            Localize("Could not add cursors to line starts.", "无法在行首添加光标。")));
        RegisterCommand("add-cursors-line-ends", () => RunMultiSelectionCommand(
            value => MultiSelectionCommands.AddLineBoundaries(value, atEnd: true),
            Localize("Could not add cursors to line ends.", "无法在行尾添加光标。")));
        RegisterCommand("split-selection-lines", () => RunMultiSelectionCommand(
            value => MultiSelectionCommands.AddLineBoundaries(value, atEnd: false, requireNonEmpty: true),
            Localize("Select one or more text lines first.", "请先选择一个或多个文本行。")));
        RegisterCommand("navigate-back", () => _ = NavigateHistoryAsync(reverse: true));
        RegisterCommand("navigate-forward", () => _ = NavigateHistoryAsync(reverse: false));
        RegisterCommand("open-settings", ShowSettings);
        RegisterCommand("set-ui-language-zh", () => _ = SetLocaleAsync("zh-CN"));
        RegisterCommand("set-ui-language-en", () => _ = SetLocaleAsync("en-US"));
        RegisterCommand("trim-trailing-whitespace", () => TrimWhitespace_Click(this, new RoutedEventArgs()));
        RegisterCommand("ensure-single-final-newline", () => FinalNewline_Click(this, new RoutedEventArgs()));
        RegisterCommand("layout-single", () => SetPaneLayout(PaneLayoutKind.Single));
        RegisterCommand("layout-columns2", () => SetPaneLayout(PaneLayoutKind.Columns2));
        RegisterCommand("layout-columns3", () => SetPaneLayout(PaneLayoutKind.Columns3));
        RegisterCommand("layout-grid4", () => SetPaneLayout(PaneLayoutKind.Grid4));
        RegisterCommand("move-file-next-group", () => MoveDocumentToNextPane(clone: false));
        RegisterCommand("clone-file-next-group", () => MoveDocumentToNextPane(clone: true));
        RegisterCommand("focus-next-group", () => FocusNextPane_Click(this, new RoutedEventArgs()));
        RegisterCommand("focus-prev-group", () =>
        {
            paneLayout.FocusNext(reverse: true);
            ActivateCurrentPaneDocument();
            Editor.Focus(FocusState.Programmatic);
        });
        RegisterCommand("command-palette", () => _ = ShowCommandPaletteAsync());
        RegisterCommand("to-upper-case", () => ApplyBufferCommand(
            value => value.TransformSelection(text => text.ToUpperInvariant()), "Selection converted to upper case."));
        RegisterCommand("to-lower-case", () => ApplyBufferCommand(
            value => value.TransformSelection(text => text.ToLowerInvariant()), "Selection converted to lower case."));
        RegisterCommand("sort-lines", () => ApplyBufferCommand(
            value => value.TransformSelectedLines(lines => lines.Order(StringComparer.OrdinalIgnoreCase).ToList()),
            "Selected lines sorted."));
        RegisterCommand("sort-lines-descending", () => ApplyBufferCommand(
            value => value.TransformSelectedLines(lines => lines.OrderDescending(StringComparer.OrdinalIgnoreCase).ToList()),
            "Selected lines sorted descending."));
        RegisterCommand("reverse-lines", () => ApplyBufferCommand(
            value => value.TransformSelectedLines(lines => lines.Reverse().ToList()), "Selected lines reversed."));
        RegisterCommand("unique-lines", () => ApplyBufferCommand(
            value => value.TransformSelectedLines(lines => lines.Distinct(StringComparer.Ordinal).ToList()),
            "Duplicate selected lines removed."));
        RegisterCommand("remove-blank-lines", () => ApplyBufferCommand(
            value => value.TransformSelectedLines(lines => lines.Where(line => !String.IsNullOrWhiteSpace(line)).ToList()),
            "Blank selected lines removed."));
        RegisterCommand("delete-line", () => ApplyBufferCommand(value => value.DeleteSelectedLines(), "Selected line(s) deleted."));
        RegisterCommand("toggle-bookmark", ToggleBookmark);
        RegisterCommand("next-bookmark", () => _ = NavigateBookmarkAsync(reverse: false));
        RegisterCommand("prev-bookmark", () => _ = NavigateBookmarkAsync(reverse: true));
        RegisterCommand("select-line", () =>
            RunSelectionCommand(value => value.SelectLine(), "The current line is already selected."));
        RegisterCommand("select-matching-bracket", () =>
            RunSelectionCommand(value => value.SelectMatchingBracket(includeBrackets: true),
                "No matching bracket is available."));
        RegisterCommand("undo-selection", () => UndoSelectionChange(redo: false));
        RegisterCommand("redo-selection", () => UndoSelectionChange(redo: true));
        RegisterCommand("select-parent-syntax", () =>
            RunSelectionCommand(value => value.SelectParentSyntax(),
                "No enclosing syntax structure is available."));
        RegisterCommand("expand-selection", () =>
            RunSelectionCommand(value => value.ExpandSelection(),
                "The selection cannot be expanded further.", expansion: true));
        RegisterCommand("shrink-selection", ShrinkSelection);
        RegisterCommand("insert-blank-line-above", () => ApplyBufferCommand(
            value => value.InsertBlankLine(above: true), "Blank line inserted above."));
        RegisterCommand("insert-blank-line", () => ApplyBufferCommand(
            value => value.InsertBlankLine(above: false), "Blank line inserted below."));
        RegisterCommand("indent-selection", () => ApplyBufferCommand(
            value => value.IndentSelectedLines(settings.InsertSpaces ? new string(' ', settings.TabSize) : "\t"),
            "Selected lines indented."));
        RegisterCommand("outdent-selection", () => ApplyBufferCommand(
            value => value.IndentSelectedLines(settings.InsertSpaces ? new string(' ', settings.TabSize) : "\t", outdent: true),
            "Selected lines outdented."));
        RegisterCommand("toggle-comment", () => ApplyBufferCommand(
            value => value.ToggleLineComment(CommentPrefix()), "Line comment toggled."));
        RegisterCommand("toggle-block-comment", () => ApplyBufferCommand(
            value => value.ToggleBlockComment(), "Block comment toggled."));
        RegisterCommand("move-line-up", () => ApplyBufferCommand(
            value => value.MoveSelectedLines(down: false), "Selected line(s) moved up."));
        RegisterCommand("move-line-down", () => ApplyBufferCommand(
            value => value.MoveSelectedLines(down: true), "Selected line(s) moved down."));
        RegisterCommand("copy-line-up", () => ApplyBufferCommand(
            value => value.CopySelectedLines(down: false), "Selected line(s) copied up."));
        RegisterCommand("copy-line-down", () => ApplyBufferCommand(
            value => value.CopySelectedLines(down: true), "Selected line(s) copied down."));
        RegisterCommand("duplicate-selection", () => ApplyBufferCommand(
            value => value.DuplicateSelectionOrLine(), "Selection or line duplicated."));
        RegisterCommand("delete-word-backward", () => ApplyBufferCommand(
            value => value.DeleteWord(backward: true), "Previous word deleted."));
        RegisterCommand("delete-word-forward", () => ApplyBufferCommand(
            value => value.DeleteWord(backward: false), "Next word deleted."));
        RegisterCommand("delete-to-line-start", () => ApplyBufferCommand(
            value => value.DeleteToLineBoundary(start: true), "Deleted to line start."));
        RegisterCommand("delete-to-line-end", () => ApplyBufferCommand(
            value => value.DeleteToLineBoundary(start: false), "Deleted to line end."));
        RegisterCommand("transpose-characters", () => ApplyBufferCommand(
            value => value.TransposeCharacters(), "Characters transposed."));
        RegisterCommand("to-title-case", () => ApplyBufferCommand(
            value => value.ToTitleCase(), "Selection converted to title case."));
        RegisterCommand("swap-case", () => ApplyBufferCommand(
            value => value.SwapCase(), "Selection case swapped."));
        RegisterCommand("join-lines", () => ApplyBufferCommand(
            value => value.JoinSelectedLines(), "Selected lines joined."));
        RegisterCommand("wrap-paragraph-80", () => ApplyBufferCommand(
            value => value.WrapParagraph(80, settings.TabSize), "Paragraph wrapped at 80 columns."));
        RegisterCommand("unwrap-paragraph", () => ApplyBufferCommand(
            value => value.UnwrapParagraph(), "Paragraph unwrapped."));
        RegisterCommand("reindent-selection", () => ApplyBufferCommand(
            value => value.ReindentSelectedLines(settings.TabSize, settings.InsertSpaces),
            "Selected lines reindented."));
        RegisterCommand("convert-indent-spaces", () => ApplyBufferCommand(
            value => value.ConvertIndentation(settings.TabSize, toSpaces: true), "Indentation converted to spaces."));
        RegisterCommand("convert-indent-tabs", () => ApplyBufferCommand(
            value => value.ConvertIndentation(settings.TabSize, toSpaces: false), "Indentation converted to tabs."));
        RegisterCommand("record-macro", ToggleMacroRecording);
        RegisterCommand("run-macro", () => ReplayMacro(macroRecorder.LastMacro));
        RegisterCommand("save-macro", () => _ = SaveMacroAsync());
        RegisterCommand("run-saved-macro", () => _ = RunSavedMacroAsync());
        RegisterCommand("build", () => _ = SelectAndRunBuildAsync());
        RegisterCommand("select-build-system", () => _ = SelectAndRunBuildAsync());
        RegisterCommand("import-sublime-build", () => _ = ImportSublimeBuildAsync());
        RegisterCommand("project-settings", () => _ = ConfigureProjectAsync());
        RegisterCommand("import-sublime-project", () => _ = ImportSublimeProjectAsync());
        RegisterCommand("import-sublime-settings", () => _ = ImportSublimeSettingsAsync());
        RegisterCommand("import-sublime-snippet", () => _ = ImportSublimeSnippetAsync());
        RegisterCommand("import-sublime-keymap", () => _ = ImportSublimeKeymapAsync());
        RegisterCommand("toggle-git", () => _ = RefreshGitAsync());
        RegisterCommand("refresh-git", () => _ = RefreshGitAsync());
        RegisterCommand("open-git-conflicts", () => _ = OpenGitConflictsAsync());
        RegisterCommand("check-for-updates", () => _ = CheckForUpdatesAsync());
        RegisterCommand("open-marketplace", () => _ = OpenMarketplaceAsync());
        RegisterCommand("toggle-terminal", () => Terminal_Click(this, new RoutedEventArgs()));
        RegisterCommand("language-tools", ShowLanguageServerSettings);
        RegisterCommand("format-document", () => _ = FormatDocumentAsync());
        RegisterCommand("toggle-language-servers", ShowLanguageServerSettings);
        RegisterCommand("lsp-hover", () => _ = RunLanguageRequestAsync("textDocument/hover"));
        RegisterCommand("lsp-definition", () => _ = RunLanguageRequestAsync("textDocument/definition"));
        RegisterCommand("lsp-references", () => _ = RunLanguageRequestAsync("textDocument/references"));
        RegisterCommand("lsp-rename", () => LspRename_Click(this, new RoutedEventArgs()));
        RegisterCommand("install-plugin", () => InstallPlugin_Click(this, new RoutedEventArgs()));
        RegisterCommand("manage-plugins", ShowPlugins);
        RegisterCommand("insert-snippet", () => _ = ShowSnippetPickerAsync());
        RegisterCommand("format-json", () => FormatJson(compact: false));
        RegisterCommand("compact-json", () => FormatJson(compact: true));
        RegisterCommand("document-statistics", () => _ = ShowDocumentStatisticsAsync());
        RegisterCommand("toggle-word-wrap", ToggleWordWrap);
        RegisterCommand("toggle-line-numbers", ToggleLineNumbers);
        RegisterCommand("toggle-whitespace", ToggleWhitespace);
        RegisterCommand("toggle-minimap", ToggleMinimap);
        RegisterCommand("toggle-theme", ToggleTheme);
        RegisterCommand("select-color-scheme", () => _ = SelectColorSchemeAsync());
        RegisterCommand("toggle-spell-check", ToggleSpellCheck);
        RegisterCommand("toggle-distraction-free", ToggleDistractionFree);
        RegisterCommand("toggle-problems", ToggleProblems);
        RegisterCommand("font-zoom-in", () => ChangeFontSize(1));
        RegisterCommand("font-zoom-out", () => ChangeFontSize(-1));
        RegisterCommand("font-zoom-reset", () => ChangeFontSize(0, reset: true));
        RegisterCommand("copy-file-path", () => CopyActivePath(relative: false));
        RegisterCommand("copy-relative-file-path", () => CopyActivePath(relative: true));
        RegisterCommand("reveal-active-file-in-sidebar", () => _ = RevealWorkspaceItemAsync());
        RegisterCommand("select-language", () => _ = SelectLanguageAsync());
        RegisterCommand("toggle-preview", TogglePreview);
        RegisterCommand("open-in-browser", () => _ = OpenActiveHtmlInBrowserAsync());
        RegisterCommand("toggle-sidebar", ToggleSidebar);
        RegisterCommand("toggle-outline", ToggleOutline);
        RegisterCommand("fold-current", () => RunFoldingCommand("fold-current"));
        RegisterCommand("unfold-current", () => RunFoldingCommand("unfold-current"));
        RegisterCommand("fold-all", () => RunFoldingCommand("fold-all"));
        RegisterCommand("unfold-all", () => RunFoldingCommand("unfold-all"));
        RegisterCommand("split-editor", () => SetPaneLayout(
            paneLayout.Kind == PaneLayoutKind.Single ? PaneLayoutKind.Columns2 : PaneLayoutKind.Single));
        RegisterCommand("split-selected-tabs", SplitSelectedTabs);
        RegisterCommand("toggle-json-view", () =>
        {
            if (workspace.ActiveDocument is { } document) documentLanguages[document.Path] =
                LanguageDetector.Languages.First(language => language.Id == "json");
            if (PreviewPanel.Visibility != Visibility.Visible) TogglePreview();
            else RefreshPreview();
        });
    }

    private void RegisterCommand(string id, Action action)
    {
        if (!commandRouter.Register(id, _ =>
        {
            action();
            return Task.FromResult(CommandExecutionResult.Executed);
        }))
        {
            throw new InvalidOperationException($"Unknown Windows command ID: {id}");
        }
    }

    private async Task ShowCommandPaletteAsync()
    {
        var query = new TextBox
        {
            PlaceholderText = Localize("Filter commands", "筛选命令"),
            Text = String.Empty
        };
        var builtInCommands = commandRouter.RegisteredCommandIds
            .Select(id => new PluginCommandListItem(id, WindowsLocalization.CommandTitle(settings.Locale, id), String.Empty));
        var pluginCommands = plugins.SelectMany(plugin => plugin.Commands.Select(command =>
            new PluginCommandListItem($"plugin.{plugin.Id}.{command.Id}", $"{plugin.Name}: {command.Title}", command.InsertText)));
        var workerCommands = pluginWorkerCommands.Values.Select(route =>
            new PluginCommandListItem(route.RouteId, $"{route.PluginName}: {route.Title}", String.Empty));
        var allCommands = builtInCommands.Concat(pluginCommands).Concat(workerCommands).ToList();
        var commands = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 360,
            DisplayMemberPath = "Display",
            ItemsSource = allCommands
        };
        void Filter()
        {
            var needle = query.Text.Trim();
            commands.ItemsSource = allCommands
                .Where(item => item.Display.Contains(needle, StringComparison.OrdinalIgnoreCase))
                .ToList();
            commands.SelectedIndex = commands.Items.Count > 0 ? 0 : -1;
        }
        query.TextChanged += (_, _) => Filter();
        Filter();
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(query);
        content.Children.Add(commands);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = Localize("Command Palette", "命令面板"),
            Content = content,
            PrimaryButtonText = Localize("Run", "运行"),
            CloseButtonText = Localize("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || commands.SelectedItem is not PluginCommandListItem selected) return;
        if (!String.IsNullOrEmpty(selected.InsertText))
        {
            ApplyBufferCommand(value => value.Replace(value.Selection, selected.InsertText), $"Ran {selected.Display}.");
            return;
        }
        if (pluginWorkerCommands.TryGetValue(selected.Id, out var workerRoute))
        {
            await RunPluginWorkerCommandAsync(workerRoute);
            return;
        }
        var result = await commandRouter.ExecuteAsync(selected.Id);
        if (result.State != CommandExecutionState.Executed)
        {
            Status.Text = result.Message ?? $"Command {selected.Id} could not be executed.";
        }
    }

    private async Task ShowLineEditingMenuAsync()
    {
        var commands = new[]
        {
            "to-upper-case", "to-lower-case", "sort-lines", "sort-lines-descending",
            "reverse-lines", "unique-lines", "remove-blank-lines", "delete-line",
            "insert-blank-line-above", "insert-blank-line", "indent-selection", "outdent-selection"
        };
        var list = new ListView { ItemsSource = commands, SelectionMode = ListViewSelectionMode.Single, MaxHeight = 360 };
        list.SelectedIndex = 0;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Edit Lines", Content = list,
            PrimaryButtonText = "Run", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not string commandId) return;
        var result = await commandRouter.ExecuteAsync(commandId);
        if (result.State != CommandExecutionState.Executed) Status.Text = result.Message ?? "Command failed.";
    }

    private async Task ShowMoreEditingMenuAsync()
    {
        var commands = new[]
        {
            "toggle-comment", "toggle-block-comment", "move-line-up", "move-line-down",
            "copy-line-up", "copy-line-down", "duplicate-selection", "delete-word-backward",
            "delete-word-forward", "delete-to-line-start", "delete-to-line-end", "transpose-characters",
            "to-title-case", "swap-case", "join-lines", "wrap-paragraph-80", "unwrap-paragraph",
            "reindent-selection", "convert-indent-spaces", "convert-indent-tabs"
        };
        var list = new ListView { ItemsSource = commands, SelectionMode = ListViewSelectionMode.Single, MaxHeight = 420, SelectedIndex = 0 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Edit More", Content = list,
            PrimaryButtonText = "Run", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not string commandId) return;
        var result = await commandRouter.ExecuteAsync(commandId);
        if (result.State != CommandExecutionState.Executed) Status.Text = result.Message ?? "Command failed.";
    }

    private string CommentPrefix()
    {
        var document = workspace.ActiveDocument;
        var language = document is null ? "plain" : CurrentLanguage(document).Id;
        return language switch
        {
            "python" or "ruby" or "shell" or "powershell" or "yaml" => "#",
            "sql" => "--",
            _ => "//"
        };
    }

    private void ApplyBufferCommand(Func<EditorBuffer, bool> action, string message)
    {
        SynchronizeBufferSelection();
        var before = buffer.Text;
        if (!action(buffer)) return;
        if (!replayingMacro) macroRecorder.Observe(before, buffer.Text, buffer.Selection);
        ApplyBufferToEditor();
        Status.Text = message;
    }

    private async Task ShowMacroMenuAsync()
    {
        var commands = new[] { "record-macro", "run-macro", "save-macro", "run-saved-macro" };
        var list = new ListView { ItemsSource = commands, SelectionMode = ListViewSelectionMode.Single, SelectedIndex = 0 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Macro", Content = list,
            PrimaryButtonText = "Run", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not string command) return;
        await commandRouter.ExecuteAsync(command);
    }

    private void ToggleMacroRecording()
    {
        if (!macroRecorder.IsRecording)
        {
            Status.Text = macroRecorder.Start(buffer.Text) ? "Macro recording started." : "Macro recording could not start.";
            return;
        }
        var macro = macroRecorder.Stop();
        Status.Text = $"Macro recording stopped — {macro.Steps.Count} step(s).";
    }

    private void ReplayMacro(RecordedMacro? macro)
    {
        if (macroRecorder.IsRecording)
        {
            Status.Text = "Stop macro recording before replaying a macro.";
            return;
        }
        replayingMacro = true;
        try
        {
            if (!macroRecorder.Replay(buffer, macro))
            {
                Status.Text = "Macro cannot run because the current text does not match its recorded starting state.";
                return;
            }
            ApplyBufferToEditor();
            Status.Text = "Macro replayed as one undoable transaction.";
        }
        finally { replayingMacro = false; }
    }

    private async Task SaveMacroAsync()
    {
        if (macroRecorder.LastMacro is null)
        {
            Status.Text = "Record a macro before saving it.";
            return;
        }
        try
        {
            await macroStore.SaveAsync(macroRecorder.LastMacro);
            Status.Text = "Macro saved.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Status.Text = $"Macro could not be saved: {error.Message}";
        }
    }

    private async Task RunSavedMacroAsync()
    {
        var macro = await macroStore.LoadAsync();
        if (macro is null)
        {
            Status.Text = "No saved macro is available.";
            return;
        }
        ReplayMacro(macro);
    }

    private BookmarkSet CurrentBookmarks()
    {
        var path = workspace.ActiveDocument?.Path ?? "untitled://none";
        if (!documentBookmarks.TryGetValue(path, out var bookmarks))
        {
            bookmarks = new BookmarkSet();
            documentBookmarks[path] = bookmarks;
        }
        return bookmarks;
    }

    private void ToggleBookmark()
    {
        if (workspace.ActiveDocument is null) return;
        var line = TextNavigation.OffsetToLineColumn(buffer.Text, Editor.SelectionStart).Line;
        var added = CurrentBookmarks().Toggle(line);
        Status.Text = added ? $"Bookmark added on line {line}." : $"Bookmark removed from line {line}.";
    }

    private async Task NavigateBookmarkAsync(bool reverse)
    {
        var document = workspace.ActiveDocument;
        if (document is null) return;
        var currentLine = TextNavigation.OffsetToLineColumn(buffer.Text, Editor.SelectionStart).Line;
        var line = CurrentBookmarks().Next(currentLine, reverse);
        if (line is null)
        {
            Status.Text = "The active document has no bookmarks.";
            return;
        }
        await NavigateToAsync(document.Path, line.Value, 1);
    }

    private void FormatJson(bool compact)
    {
        var formatted = DocumentTransforms.FormatJson(buffer.Text, compact);
        if (formatted is null)
        {
            Status.Text = "The active document is not valid JSON.";
            return;
        }
        ApplyBufferCommand(value => value.Apply(formatted, new TextSelection(0, 0)),
            compact ? "JSON compacted." : "JSON formatted.");
    }

    private async Task ShowDocumentStatisticsAsync()
    {
        var selection = EditorSelection();
        var source = selection.Length > 0 ? buffer.Text[selection.Start..selection.End] : buffer.Text;
        var statistics = DocumentTransforms.Statistics(source);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = selection.Length > 0 ? "Selection Statistics" : "Document Statistics",
            Content = $"Lines: {statistics.Lines}\nUTF-16 characters: {statistics.Utf16Characters}\nNon-whitespace characters: {statistics.NonWhitespaceCharacters}\nWords/tokens: {statistics.Words}",
            CloseButtonText = "Close"
        };
        await dialog.ShowAsync();
    }

    private void ToggleWordWrap()
    {
        settings = settings with { WordWrap = !settings.WordWrap };
        ApplySettingsToEditor();
        _ = PersistSettingsWithStatusAsync(settings.WordWrap ? "Word wrap enabled." : "Word wrap disabled.");
    }

    private void ToggleLineNumbers()
    {
        settings = settings with { ShowLineNumbers = !settings.ShowLineNumbers };
        ApplySettingsToEditor();
        _ = PersistSettingsWithStatusAsync(settings.ShowLineNumbers
            ? Localize("Line numbers enabled.", "已显示行号。")
            : Localize("Line numbers disabled.", "已隐藏行号。"));
    }

    private void ToggleWhitespace()
    {
        settings = settings with { ShowWhitespace = !settings.ShowWhitespace };
        ApplySettingsToEditor();
        _ = PersistSettingsWithStatusAsync(settings.ShowWhitespace
            ? Localize("Whitespace characters enabled.", "已显示空白字符。")
            : Localize("Whitespace characters disabled.", "已隐藏空白字符。"));
    }

    private void ToggleMinimap()
    {
        settings = settings with { ShowMinimap = !settings.ShowMinimap };
        ApplySettingsToEditor();
        _ = PersistSettingsWithStatusAsync(settings.ShowMinimap
            ? Localize("Minimap enabled.", "已显示缩略图。")
            : Localize("Minimap disabled.", "已隐藏缩略图。"));
    }

    private void ToggleTheme()
    {
        settings = settings with { Theme = settings.Theme == EditorTheme.Dark ? EditorTheme.Light : EditorTheme.Dark };
        ApplySettingsToEditor();
        _ = PersistSettingsWithStatusAsync($"Theme: {settings.Theme}.");
    }

    private async Task SelectColorSchemeAsync()
    {
        var choices = Enum.GetValues<EditorColorScheme>().Select(value => value switch
        {
            EditorColorScheme.SolarizedDark => "Solarized Dark",
            _ => value.ToString()
        }).ToList();
        var list = new ListView
        {
            ItemsSource = choices, SelectionMode = ListViewSelectionMode.Single,
            SelectedItem = settings.ColorScheme == EditorColorScheme.SolarizedDark
                ? "Solarized Dark" : settings.ColorScheme.ToString()
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Select Color Scheme", Content = list,
            PrimaryButtonText = "Apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || list.SelectedIndex < 0 || list.SelectedIndex >= Enum.GetValues<EditorColorScheme>().Length) return;
        var scheme = Enum.GetValues<EditorColorScheme>()[list.SelectedIndex];
        settings = settings with { ColorScheme = scheme };
        ApplySettingsToEditor();
        RefreshPreview();
        await PersistSettingsWithStatusAsync($"Color scheme: {settings.ColorScheme}.");
    }

    private void ToggleSpellCheck()
    {
        settings = settings with { SpellCheck = !settings.SpellCheck };
        ApplySettingsToEditor();
        _ = PersistSettingsWithStatusAsync(settings.SpellCheck ? "Spell check enabled." : "Spell check disabled.");
    }

    private void ToggleDistractionFree()
    {
        var enable = !settings.DistractionFree;
        if (enable) sidebarVisibleBeforeDistraction = WorkspaceSidebar.Visibility == Visibility.Visible;
        settings = settings with { DistractionFree = enable };
        ApplyDistractionFreeVisuals(enable);
        _ = PersistSettingsWithStatusAsync(enable ? "Distraction-free mode enabled." : "Distraction-free mode disabled.");
    }

    private void ApplyDistractionFreeVisuals(bool enabled)
    {
        MainCommandBar.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        StatusBar.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        WorkspaceSidebar.Visibility = enabled || !sidebarVisibleBeforeDistraction
            ? Visibility.Collapsed : Visibility.Visible;
        WorkspaceEditorGrid.ColumnDefinitions[0].Width = WorkspaceSidebar.Visibility == Visibility.Visible
            ? new GridLength(280) : new GridLength(0);
    }

    private void ToggleProblems()
    {
        var show = BuildPanel.Visibility != Visibility.Visible;
        BuildPanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (show)
        {
            GitPanel.Visibility = Visibility.Collapsed;
            TerminalPanel.Visibility = Visibility.Collapsed;
            LanguageServerPanel.Visibility = Visibility.Collapsed;
            PluginsPanel.Visibility = Visibility.Collapsed;
            WorkspaceResultsPanel.Visibility = Visibility.Collapsed;
        }
        Status.Text = show ? "Build output shown." : "Build output hidden.";
    }

    private void OpenNewWindow()
    {
        var executable = Environment.ProcessPath;
        if (String.IsNullOrWhiteSpace(executable))
        {
            Status.Text = "The application executable could not be located.";
            return;
        }
        try
        {
            var start = new System.Diagnostics.ProcessStartInfo(executable) { UseShellExecute = false };
            start.ArgumentList.Add("--new-window");
            System.Diagnostics.Process.Start(start);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            Status.Text = $"A new window could not be opened: {error.Message}";
        }
    }

    private void ChangeFontSize(int delta, bool reset = false)
    {
        settings = EditorSettings.Sanitize(settings with { FontSize = reset ? 14 : settings.FontSize + delta });
        ApplySettingsToEditor();
        _ = PersistSettingsWithStatusAsync($"Font size: {settings.FontSize}.");
    }

    private async Task PersistSettingsWithStatusAsync(string message)
    {
        try
        {
            await settingsStore.SaveAsync(settings);
            Status.Text = message;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Status.Text = $"Settings could not be saved: {error.Message}";
        }
    }

    private void CopyActivePath(bool relative)
    {
        var path = workspace.ActiveDocument?.Path;
        if (path is null || path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
        {
            Status.Text = "The active document has no file path.";
            return;
        }
        var text = path;
        if (relative)
        {
            var root = workspaceRoots.FirstOrDefault(candidate => WorkspaceTree.IsInside(candidate, path));
            if (root is not null) text = Path.GetRelativePath(root, path);
        }
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        Status.Text = relative ? "Relative file path copied." : "File path copied.";
    }

    private void ToggleSidebar()
    {
        var visible = WorkspaceSidebar.Visibility == Visibility.Visible;
        WorkspaceSidebar.Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
        WorkspaceEditorGrid.ColumnDefinitions[0].Width = visible ? new GridLength(0) : new GridLength(280);
        Status.Text = visible ? "Sidebar hidden." : "Sidebar shown.";
    }

    private async Task OpenActiveHtmlInBrowserAsync()
    {
        var document = workspace.ActiveDocument;
        if (document is null || CurrentLanguage(document).Id != "html"
            && !PreviewRenderer.IsHtmlFileName(document.Path))
        {
            Status.Text = "The active document is not HTML.";
            return;
        }
        var directory = Path.Combine(Path.GetTempPath(), "LumenEditorNativeWindowsPreview", "browser-preview");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, $"preview-{Guid.NewGuid():N}.html");
        try
        {
            await File.WriteAllTextAsync(path, buffer.Text, new System.Text.UTF8Encoding(false));
            browserPreviewFiles.Add(path);
            var file = await StorageFile.GetFileFromPathAsync(path);
            if (!await Launcher.LaunchFileAsync(file)) Status.Text = "The system browser could not open the preview.";
            else Status.Text = "HTML preview opened in the system browser.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Status.Text = $"HTML preview could not be created: {error.Message}";
        }
    }

    private async Task CloseDocumentsAsync(IEnumerable<string> paths)
    {
        foreach (var path in paths.ToList())
        {
            if (!workspace.Activate(path)) continue;
            paneLayout.Activate(path);
            RefreshWorkspace();
            if (!await CloseActiveDocumentAsync()) break;
        }
    }

    private void ShowPlugins()
    {
        BuildPanel.Visibility = Visibility.Collapsed;
        GitPanel.Visibility = Visibility.Collapsed;
        TerminalPanel.Visibility = Visibility.Collapsed;
        LanguageServerPanel.Visibility = Visibility.Collapsed;
        PluginsPanel.Visibility = Visibility.Visible;
        ReloadPlugins();
    }

    private void ReloadPlugins()
    {
        var generation = Interlocked.Increment(ref pluginWorkerGeneration);
        pluginWorkerShutdown = StopPluginWorkersAsync();
        plugins.Clear();
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            PluginsList.ItemsSource = Array.Empty<PluginListItem>();
            PluginsStatus.Text = "Open a workspace folder to manage plugins.";
            return;
        }
        DeclarativePluginStore store;
        try
        {
            store = new DeclarativePluginStore(root);
            plugins.AddRange(store.Load());
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            PluginsStatus.Text = error.Message;
            return;
        }
        PluginsList.ItemsSource = plugins.Select(plugin => new PluginListItem(plugin)).ToList();
        PluginsStatus.Text = $"{plugins.Count} enabled declarative plugin(s).";
        _ = ActivatePluginWorkersAsync(root, store, generation);
    }

    private async Task ActivatePluginWorkersAsync(string root, DeclarativePluginStore store, long generation)
    {
        await pluginWorkerShutdown;
        if (generation != pluginWorkerGeneration) return;
        IReadOnlyDictionary<string, IReadOnlyList<PluginPermission>> grants;
        ProjectSettingsSnapshot projectSnapshot;
        try
        {
            projectSnapshot = await new ProjectSettingsStore(root).LoadAsync();
            var project = ProjectBuildSettings.ParseProject(projectSnapshot.Json);
            grants = ProjectBuildSettings.ParsePluginPermissions(project);
            var configured = ProjectBuildSettings.ParsePluginIds(project);
            if (configured.Count > 0)
            {
                plugins.RemoveAll(plugin => !configured.Contains(plugin.Id, StringComparer.OrdinalIgnoreCase));
                PluginsList.ItemsSource = plugins.Select(plugin => new PluginListItem(plugin)).ToList();
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or JsonException)
        {
            PluginsStatus.Text = $"Plugin permissions could not be loaded: {error.Message}";
            return;
        }
        var enabledIds = plugins.Select(plugin => plugin.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var package in store.LoadWorkerPackages().Where(package => enabledIds.Contains(package.Manifest.Id)))
        {
            if (generation != pluginWorkerGeneration) return;
            var requested = package.Permissions;
            var granted = grants.TryGetValue(package.Manifest.Id, out var configured) ? configured : [];
            var effective = requested.Where(granted.Contains).ToList();
            var missing = requested.Where(permission => !effective.Contains(permission)).ToList();
            if (missing.Count > 0)
            {
                var dialog = new ContentDialog
                {
                    XamlRoot = Root.XamlRoot, Title = $"Allow {package.Manifest.Name} worker?",
                    Content = $"Requested permissions: {String.Join(", ", missing.Select(PluginPermissionName))}\n\nThe worker runs in a separate constrained process without filesystem, network, DOM, process, or CLR access.",
                    PrimaryButtonText = "Allow", CloseButtonText = "Skip", DefaultButton = ContentDialogButton.Close
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) continue;
                effective = requested.ToList();
                try
                {
                    var saved = await new ProjectSettingsStore(root).SaveAsync(
                        ProjectBuildSettings.MergePluginPermissions(projectSnapshot.Json, package.Manifest.Id, effective),
                        projectSnapshot.Revision);
                    if (!saved.Saved)
                    {
                        PluginsStatus.Text = saved.Message ?? "Plugin permission could not be saved.";
                        continue;
                    }
                    projectSnapshot = await new ProjectSettingsStore(root).LoadAsync();
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
                {
                    PluginsStatus.Text = $"Plugin permission could not be saved: {error.Message}";
                    continue;
                }
            }
            PluginWorkerProcess? startedWorker = null;
            try
            {
                var executable = WorkerExecutablePath();
                var worker = await PluginWorkerProcess.StartAsync(executable, package, effective);
                startedWorker = worker;
                if (generation != pluginWorkerGeneration) { await worker.DisposeAsync(); return; }
                HandlePluginWorkerResponses(package.Manifest.Id, package.Manifest.Name, effective,
                    worker.StartupResponses, snapshotPath: null, snapshotRevision: null);
                var snapshotPath = workspace.ActiveDocument?.Path;
                var snapshotRevision = buffer.Revision;
                var responses = await worker.RequestAsync(new PluginWorkerRequest(
                    PluginWorkerProtocol.Version, PluginWorkerRequestKind.Activate, RequestId(),
                    Context: PluginContext(effective)));
                if (generation != pluginWorkerGeneration) { await worker.DisposeAsync(); return; }
                pluginWorkers[package.Manifest.Id] = worker;
                startedWorker = null;
                HandlePluginWorkerResponses(package.Manifest.Id, package.Manifest.Name, effective,
                    responses, snapshotPath, snapshotRevision);
            }
            catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException
                or OperationCanceledException or PlatformNotSupportedException or System.ComponentModel.Win32Exception)
            {
                if (pluginWorkers.Remove(package.Manifest.Id, out var failed)) await failed.DisposeAsync();
                else if (startedWorker is not null) await startedWorker.DisposeAsync();
                PluginsStatus.Text = $"{package.Manifest.Name} worker could not start: {error.Message}";
            }
        }
        if (pluginWorkers.Count > 0) PluginsStatus.Text = $"{plugins.Count} plugin(s), {pluginWorkers.Count} isolated worker(s).";
    }

    private PluginWorkerContext PluginContext(IReadOnlyList<PluginPermission> permissions)
    {
        PluginWorkerDocument? document = null;
        if (permissions.Contains(PluginPermission.DocumentRead) && workspace.ActiveDocument is { } active)
        {
            var selection = buffer.Selection;
            document = new(buffer.Text, CurrentLanguage(active).Id, new(selection.Start, selection.End));
        }
        return new(permissions, document);
    }

    private async Task RunPluginWorkerCommandAsync(PluginWorkerCommandRoute route)
    {
        if (!pluginWorkers.TryGetValue(route.PluginId, out var worker)) return;
        var document = workspace.ActiveDocument;
        var revision = buffer.Revision;
        var path = document?.Path;
        try
        {
            var responses = await worker.RequestAsync(new PluginWorkerRequest(
                PluginWorkerProtocol.Version, PluginWorkerRequestKind.RunCommand, RequestId(),
                CommandId: route.CommandId, Context: PluginContext(route.Permissions)));
            HandlePluginWorkerResponses(route.PluginId, route.PluginName, route.Permissions,
                responses, path, document is null ? null : revision);
        }
        catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException
            or OperationCanceledException)
        {
            PluginsStatus.Text = $"{route.PluginName} worker failed: {error.Message}";
            if (pluginWorkers.Remove(route.PluginId, out var failed)) await failed.DisposeAsync();
            foreach (var key in pluginWorkerCommands.Where(pair => pair.Value.PluginId == route.PluginId)
                .Select(pair => pair.Key).ToList()) pluginWorkerCommands.Remove(key);
        }
    }

    private void HandlePluginWorkerResponses(
        string pluginId, string pluginName, IReadOnlyList<PluginPermission> permissions,
        IEnumerable<PluginWorkerResponse> responses, string? snapshotPath, ulong? snapshotRevision)
    {
        foreach (var response in responses)
        {
            if (response.Type == PluginWorkerResponseKind.RegisterCommand)
            {
                var id = response.Id!;
                var routeId = $"plugin-worker:{pluginId}:{id}";
                var existingCount = pluginWorkerCommands.Values.Count(route =>
                    StringComparer.OrdinalIgnoreCase.Equals(route.PluginId, pluginId));
                if (!pluginWorkerCommands.ContainsKey(routeId)
                    && existingCount >= PluginWorkerProtocol.MaximumCommandsPerWorker)
                    throw new InvalidDataException("Plugin worker registered too many commands.");
                pluginWorkerCommands[routeId] = new(routeId, pluginId, pluginName, id, response.Title!, permissions);
            }
            else if (response.Type == PluginWorkerResponseKind.Notify)
            {
                Status.Text = $"{pluginName}: {response.Text}";
            }
            else if (response.Type == PluginWorkerResponseKind.ReplaceDocument)
            {
                if (!permissions.Contains(PluginPermission.DocumentEdit) || snapshotPath is null
                    || snapshotRevision is null || workspace.ActiveDocument?.Path != snapshotPath
                    || buffer.Revision != snapshotRevision)
                    throw new InvalidOperationException("The active document changed before the plugin result arrived.");
                if (buffer.Apply(response.Text!, new TextSelection(0, 0))) ApplyBufferToEditor();
            }
        }
    }

    private async Task StopPluginWorkersAsync()
    {
        var workers = pluginWorkers.Values.ToList();
        pluginWorkers.Clear();
        pluginWorkerCommands.Clear();
        foreach (var worker in workers) await worker.DisposeAsync();
    }

    private static string PluginPermissionName(PluginPermission permission) => permission switch
    {
        PluginPermission.DocumentRead => "document-read",
        PluginPermission.DocumentEdit => "document-edit",
        _ => "unknown"
    };
    private static string RequestId() => Guid.NewGuid().ToString("N");
    private static string WorkerExecutablePath()
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "LumenEditor.Windows.Worker.exe");
        if (!File.Exists(executable))
            throw new FileNotFoundException("The isolated native worker executable is missing.", executable);
        return executable;
    }

    private async Task ShowSnippetPickerAsync()
    {
        var snippets = plugins.SelectMany(plugin => plugin.Snippets.Select(snippet =>
            new PluginSnippetListItem($"{plugin.Name}: {snippet.Label}", snippet.Text))).ToList();
        var root = workspaceRoots.FirstOrDefault();
        if (root is not null)
        {
            try
            {
                var snapshot = await new ProjectSettingsStore(root).LoadAsync();
                using var project = JsonDocument.Parse(snapshot.Json, new JsonDocumentOptions { MaxDepth = 32 });
                snippets.InsertRange(0, SublimeImport.ParseProjectSnippets(project.RootElement)
                    .Select(snippet => new PluginSnippetListItem($"Project: {snippet.Label}", snippet.Text)));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException
                or InvalidDataException or JsonException)
            {
                Status.Text = $"Project snippets could not be loaded: {error.Message}";
            }
        }
        if (snippets.Count == 0)
        {
            Status.Text = "No declarative snippets are installed.";
            return;
        }
        var list = new ListView
        {
            ItemsSource = snippets, DisplayMemberPath = "Display",
            SelectionMode = ListViewSelectionMode.Single, SelectedIndex = 0, MaxHeight = 360
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Insert Snippet", Content = list,
            PrimaryButtonText = "Insert", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || list.SelectedItem is not PluginSnippetListItem snippet) return;
        ApplyBufferCommand(value => value.Replace(value.Selection, snippet.Text), $"Inserted {snippet.Display}.");
    }

    private async Task SelectAndRunBuildAsync()
    {
        if (workspaceRoots.Count == 0)
        {
            Status.Text = "Open a workspace folder before building.";
            return;
        }
        var systems = new List<DetectedBuildSystem>();
        foreach (var root in workspaceRoots)
        {
            systems.AddRange(BuildSystemDetector.Detect(root));
            try { systems.AddRange((await new ProjectSettingsStore(root).LoadAsync()).BuildSystems); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
            {
                Status.Text = $"Could not load project build systems from {Path.GetFileName(root)}: {error.Message}";
            }
        }
        if (BuildSystemDetector.FromCommand(workspaceRoots[0], settings.BuildCommand) is { } configured)
            systems.Insert(0, configured);
        if (systems.Count == 0)
        {
            Status.Text = "No supported build system was detected in the workspace roots.";
            return;
        }
        var list = new ListView
        {
            ItemsSource = systems.Select(system => system.Display).ToList(),
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 360,
            SelectedIndex = selectedBuildSystem is null
                ? 0
                : Math.Max(0, systems.FindIndex(system => system.Id == selectedBuildSystem.Id
                    && StringComparer.OrdinalIgnoreCase.Equals(system.WorkingDirectory, selectedBuildSystem.WorkingDirectory)))
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Select Build System", Content = list,
            PrimaryButtonText = "Review", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedIndex < 0) return;
        selectedBuildSystem = systems[list.SelectedIndex];
        var review = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = $"Run {selectedBuildSystem.Name}?",
            Content = $"Executable: {selectedBuildSystem.Executable}\nArguments: {String.Join(' ', selectedBuildSystem.Arguments)}\nWorking directory: {selectedBuildSystem.WorkingDirectory}",
            PrimaryButtonText = "Run", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await review.ShowAsync() != ContentDialogResult.Primary) return;
        await RunBuildAsync(selectedBuildSystem);
    }

    private async Task RunBuildAsync(DetectedBuildSystem system)
    {
        if (system.SaveBeforeBuild && !await SaveAllAsync())
        {
            BuildStatus.Text = "Build stopped because not every dirty document could be saved.";
            return;
        }
        buildCancellation?.Cancel();
        buildCancellation?.Dispose();
        buildCancellation = new CancellationTokenSource();
        BuildPanel.Visibility = Visibility.Visible;
        WorkspaceResultsPanel.Visibility = Visibility.Collapsed;
        BuildOutput.Text = $"> {system.Executable} {String.Join(' ', system.Arguments)}\n";
        BuildStatus.Text = $"Running {system.Name}…";
        var result = await processRunner.RunAsync(system.ToRequest(), buildCancellation.Token);
        BuildOutput.Text += result.StandardOutput;
        if (!String.IsNullOrEmpty(result.StandardError)) BuildOutput.Text += result.StandardError;
        if (result.WasTruncated) BuildOutput.Text += "\n[Earlier or excess output was truncated.]\n";
        BuildStatus.Text = result.WasCancelled ? "Build cancelled."
            : result.TimedOut ? "Build timed out."
            : !result.Started ? $"Build could not start: {result.Error}"
            : result.ExitCode == 0 ? "Build completed successfully."
            : $"Build exited with code {result.ExitCode}.";
    }

    private async Task ConfigureProjectAsync()
    {
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            Status.Text = "Open a workspace folder before configuring a project.";
            return;
        }
        try
        {
            var store = new ProjectSettingsStore(root);
            var snapshot = await store.LoadAsync();
            var input = new TextBox
            {
                Text = snapshot.Json, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono"),
                MinWidth = 720, MinHeight = 440, MaxLength = ProjectBuildSettings.MaximumSerializedBytes
            };
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Configure Project (.lumen-project.json)", Content = input,
                PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var result = await store.SaveAsync(input.Text, snapshot.Revision);
            if (!result.Saved)
            {
                Status.Text = result.Message ?? "Project settings could not be saved.";
                return;
            }
            ReloadPlugins();
            selectedBuildSystem = null;
            await ReloadProjectKeyBindingsAsync();
            await ReloadProjectExclusionsAsync();
            RefreshWorkspaceTree();
            RestartWorkspaceWatchers();
            Status.Text = "Project settings saved.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or DirectoryNotFoundException)
        {
            Status.Text = $"Project settings could not be edited: {error.Message}";
        }
    }

    private async Task ImportSublimeBuildAsync()
    {
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            Status.Text = "Open a workspace folder before importing a Sublime build system.";
            return;
        }
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".sublime-build");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var imported = ProjectBuildSettings.ParseSublimeBuild(await File.ReadAllBytesAsync(file.Path), file.Path);
            var review = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Import Sublime Build System?",
                Content = $"Name: {imported.Name}\nExecutable: {imported.Command}\nArguments: {String.Join(' ', imported.Arguments)}\n\nThe executable will still require explicit review before each run.",
                PrimaryButtonText = "Import", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await review.ShowAsync() != ContentDialogResult.Primary) return;
            var store = new ProjectSettingsStore(root);
            var snapshot = await store.LoadAsync();
            var merged = ProjectBuildSettings.MergeBuildSystem(snapshot.Json, imported);
            var result = await store.SaveAsync(merged, snapshot.Revision);
            if (!result.Saved)
            {
                Status.Text = result.Message ?? "Sublime build system could not be imported.";
                return;
            }
            selectedBuildSystem = null;
            Status.Text = $"Imported Sublime build system: {imported.Name}.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or DirectoryNotFoundException)
        {
            Status.Text = $"Sublime build system could not be imported: {error.Message}";
        }
    }

    private async Task ImportSublimeProjectAsync()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".sublime-project");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var imported = SublimeImport.ParseProject(await File.ReadAllBytesAsync(file.Path), file.Path);
            var review = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Import Sublime Project?",
                Content = $"Folders: {String.Join(", ", imported.Roots.Select(Path.GetFileName))}\nExclusions: {imported.Exclusions.Count}\nNon-shell build systems: {imported.BuildSystems.Count}\n\nOpen tabs remain available. Sublime Python plugins and shell commands are never imported.",
                PrimaryButtonText = "Import", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await review.ShowAsync() != ContentDialogResult.Primary) return;
            var roots = WorkspaceRoots.Normalize(imported.Roots);
            if (roots.Count == 0)
            {
                Status.Text = "The Sublime project has no accessible folders.";
                return;
            }
            var store = new ProjectSettingsStore(roots[0]);
            var snapshot = await store.LoadAsync();
            var result = await store.SaveAsync(SublimeImport.MergeProject(snapshot.Json, imported), snapshot.Revision);
            if (!result.Saved)
            {
                Status.Text = result.Message ?? "Sublime project settings could not be saved.";
                return;
            }
            workspaceRoots.Clear();
            workspaceRoots.AddRange(roots);
            await ReloadProjectExclusionsAsync();
            RefreshWorkspaceTree();
            RestartWorkspaceWatchers();
            ReloadPlugins();
            foreach (var root in roots) await TryRememberProjectAsync(root);
            selectedBuildSystem = null;
            await ReloadProjectKeyBindingsAsync();
            await PersistAsync();
            Status.Text = $"Imported Sublime project with {roots.Count} folder(s).";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or ArgumentException or NotSupportedException)
        {
            Status.Text = $"Sublime project could not be imported: {error.Message}";
        }
    }

    private async Task ImportSublimeSettingsAsync()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".sublime-settings");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var imported = SublimeImport.ParseSettings(await File.ReadAllBytesAsync(file.Path), settings);
            if (imported.Changes.Count == 0)
            {
                Status.Text = "The Sublime settings contain no supported changes.";
                return;
            }
            var review = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Import Sublime Settings?",
                Content = String.Join('\n', imported.Changes),
                PrimaryButtonText = "Apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await review.ShowAsync() != ContentDialogResult.Primary) return;
            settings = imported.Settings;
            CancelAutoSaveDelay();
            ApplySettingsToEditor();
            if (settings.AutoSave == AutoSaveMode.AfterDelay) ScheduleAutoSaveAfterEdit();
            await settingsStore.SaveAsync(settings);
            Status.Text = $"Imported {imported.Changes.Count} supported Sublime setting(s).";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or ArgumentException or NotSupportedException)
        {
            Status.Text = $"Sublime settings could not be imported: {error.Message}";
        }
    }

    private async Task ImportSublimeSnippetAsync()
    {
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            Status.Text = "Open a workspace folder before importing a Sublime snippet.";
            return;
        }
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".sublime-snippet");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var snippet = SublimeImport.ParseSnippet(await File.ReadAllBytesAsync(file.Path), file.Path);
            var review = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Import Sublime Snippet?",
                Content = $"Label: {snippet.Label}\nTrigger: {snippet.Trigger ?? "(none)"}\nScope: {snippet.Scope ?? "(none)"}\n\nOnly snippet text and metadata are imported.",
                PrimaryButtonText = "Import", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await review.ShowAsync() != ContentDialogResult.Primary) return;
            var store = new ProjectSettingsStore(root);
            var snapshot = await store.LoadAsync();
            var result = await store.SaveAsync(SublimeImport.MergeSnippet(snapshot.Json, snippet), snapshot.Revision);
            Status.Text = result.Saved ? $"Imported Sublime snippet: {snippet.Label}."
                : result.Message ?? "Sublime snippet could not be saved.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or ArgumentException or NotSupportedException)
        {
            Status.Text = $"Sublime snippet could not be imported: {error.Message}";
        }
    }

    private async Task ImportSublimeKeymapAsync()
    {
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            Status.Text = "Open a workspace folder before importing a Sublime keymap.";
            return;
        }
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".sublime-keymap");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var imported = ProjectKeyBindings.ParseSublime(await File.ReadAllBytesAsync(file.Path));
            var supported = imported.Bindings.Where(binding => commandRouter.IsRegistered(binding.CommandId)).ToList();
            var skipped = imported.Skipped + imported.Bindings.Count - supported.Count;
            if (supported.Count == 0)
            {
                Status.Text = $"No supported bindings were found; {skipped} rule(s) were skipped.";
                return;
            }
            var descriptions = String.Join('\n', supported.Take(20)
                .Select(binding => $"{binding.Display} → {binding.CommandId}"));
            var review = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Import Sublime Keymap?",
                Content = $"Import {supported.Count} single-step binding(s)?\n\n{descriptions}\n\nSkipped: {skipped}. Chords, parameterized/context rules, and unavailable commands are not imported.",
                PrimaryButtonText = "Import", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await review.ShowAsync() != ContentDialogResult.Primary) return;
            var store = new ProjectSettingsStore(root);
            var snapshot = await store.LoadAsync();
            var result = await store.SaveAsync(ProjectKeyBindings.Merge(snapshot.Json, supported), snapshot.Revision);
            if (!result.Saved)
            {
                Status.Text = result.Message ?? "Sublime keymap could not be saved.";
                return;
            }
            await ReloadProjectKeyBindingsAsync();
            Status.Text = $"Imported {supported.Count} Sublime key binding(s); skipped {skipped}.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or ArgumentException or NotSupportedException)
        {
            Status.Text = $"Sublime keymap could not be imported: {error.Message}";
        }
    }

    private async Task ReloadProjectKeyBindingsAsync()
    {
        foreach (var accelerator in projectKeyboardAccelerators) Root.KeyboardAccelerators.Remove(accelerator);
        projectKeyboardAccelerators.Clear();
        foreach (var accelerator in defaultKeyboardAccelerators)
        {
            if (!Root.KeyboardAccelerators.Contains(accelerator)) Root.KeyboardAccelerators.Add(accelerator);
        }
        var root = workspaceRoots.FirstOrDefault();
        if (root is null) return;
        try
        {
            var snapshot = await new ProjectSettingsStore(root).LoadAsync();
            using var project = JsonDocument.Parse(snapshot.Json, new JsonDocumentOptions { MaxDepth = 32 });
            foreach (var binding in ProjectKeyBindings.ParseProject(project.RootElement)
                .Where(binding => commandRouter.IsRegistered(binding.CommandId)))
            {
                if (!Enum.TryParse<VirtualKey>(binding.Key, ignoreCase: true, out var key)) continue;
                var modifiers = VirtualKeyModifiers.None;
                if (binding.Control) modifiers |= VirtualKeyModifiers.Control;
                if (binding.Alt) modifiers |= VirtualKeyModifiers.Menu;
                if (binding.Shift) modifiers |= VirtualKeyModifiers.Shift;
                foreach (var existing in Root.KeyboardAccelerators.Where(candidate =>
                    candidate.Key == key && candidate.Modifiers == modifiers).ToList())
                {
                    Root.KeyboardAccelerators.Remove(existing);
                }
                var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
                accelerator.Invoked += async (_, args) =>
                {
                    args.Handled = true;
                    var result = await commandRouter.ExecuteAsync(binding.CommandId);
                    if (result.State != CommandExecutionState.Executed)
                    {
                        Status.Text = result.Message ?? $"Command {binding.CommandId} could not be executed.";
                    }
                };
                Root.KeyboardAccelerators.Add(accelerator);
                projectKeyboardAccelerators.Add(accelerator);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or JsonException)
        {
            Status.Text = $"Project key bindings could not be loaded: {error.Message}";
        }
    }

    private string? GitRoot => workspaceRoots.FirstOrDefault();

    private async Task RefreshGitAsync()
    {
        var root = GitRoot;
        if (root is null)
        {
            Status.Text = "Open a workspace folder before using Git.";
            return;
        }
        GitPanel.Visibility = Visibility.Visible;
        BuildPanel.Visibility = Visibility.Collapsed;
        WorkspaceResultsPanel.Visibility = Visibility.Collapsed;
        GitStatusText.Text = "Refreshing Git status…";
        var result = await gitService.StatusAsync(root);
        if (!result.Succeeded)
        {
            GitFilesList.ItemsSource = Array.Empty<GitFileStatus>();
            GitDiffOutput.Text = result.Error ?? "Git status failed.";
            GitStatusText.Text = "Git unavailable.";
            return;
        }
        GitFilesList.ItemsSource = result.Files;
        var tracking = result.Upstream is null ? "no upstream"
            : result.Ahead is { } ahead && result.Behind is { } behind
                ? $"{result.Upstream} ↑{ahead} ↓{behind}" : result.Upstream;
        var remotes = result.Remotes is { Count: > 0 }
            ? $" — {String.Join(", ", result.Remotes.Select(remote =>
                $"{remote.Name}: {remote.FetchUrl ?? remote.PushUrl}"))}" : String.Empty;
        GitStatusText.Text = $"{result.Branch} — {tracking} — {result.Files.Count} changed file(s){remotes}";
        if (result.Files.Count > 0) GitFilesList.SelectedIndex = 0;
        else GitDiffOutput.Text = "Working tree clean.";
    }

    private async Task OpenGitConflictsAsync()
    {
        var root = GitRoot;
        if (root is null)
        {
            Status.Text = "Open a workspace folder before viewing Git conflicts.";
            return;
        }
        var result = await gitService.StatusAsync(root);
        if (!result.Succeeded)
        {
            Status.Text = result.Error ?? "Git status failed.";
            return;
        }
        var conflicts = result.Files.Where(file => file.HasConflict).ToList();
        if (conflicts.Count == 0)
        {
            Status.Text = "No Git merge conflicts were found.";
            return;
        }
        var list = new ListView
        {
            ItemsSource = conflicts, DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single,
            SelectedIndex = 0, MaxHeight = 420
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Open Git Conflict", Content = list,
            PrimaryButtonText = "Open", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not GitFileStatus selected) return;
        var path = Path.GetFullPath(Path.Combine(root, selected.Path));
        if (!WorkspaceTree.IsInside(root, path) || !File.Exists(path))
        {
            Status.Text = "The selected conflict path is unavailable or outside the workspace.";
            return;
        }
        await OpenPathsAsync([path]);
    }

    private async Task CheckForUpdatesAsync()
    {
        Status.Text = "Checking for updates…";
        try
        {
            var current = typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "0.1.0";
            var update = await updateService.CheckAsync(current);
            if (!update.IsAvailable || update.LatestVersion is null)
            {
                Status.Text = $"Lumen Editor {update.CurrentVersion} is up to date.";
                return;
            }
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = $"Lumen Editor {update.LatestVersion} is available",
                Content = $"Current version: {update.CurrentVersion}\n\nOpen the verified GitHub release page to download the signed native Windows MSIX?",
                PrimaryButtonText = "Open Release", CloseButtonText = "Later", DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || update.ReleaseUri is null) return;
            if (!await Launcher.LaunchUriAsync(update.ReleaseUri)) Status.Text = "The release page could not be opened.";
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException
            or InvalidDataException or JsonException)
        {
            Status.Text = $"Update check failed: {error.Message}";
        }
    }

    private async Task OpenMarketplaceAsync()
    {
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            Status.Text = "Open a workspace folder before browsing plugins.";
            return;
        }
        try
        {
            var snapshot = await new ProjectSettingsStore(root).LoadAsync();
            using var project = JsonDocument.Parse(snapshot.Json, new JsonDocumentOptions { MaxDepth = 32 });
            var sources = MarketplaceClient.ParseSources(project.RootElement);
            if (sources.Count == 0)
            {
                Status.Text = "Add one or more HTTPS marketplaceUrls to .lumen-project.json first.";
                return;
            }
            PluginsPanel.Visibility = Visibility.Visible;
            PluginsStatus.Text = "Loading plugin marketplaces…";
            var result = await marketplaceClient.FetchAsync(sources);
            if (result.Items.Count == 0)
            {
                PluginsStatus.Text = result.Failures.Count == 0
                    ? "Configured marketplaces returned no declarative plugins."
                    : $"No plugins loaded; {result.Failures.Count} marketplace request(s) failed.";
                return;
            }
            var list = new ListView
            {
                ItemsSource = result.Items, DisplayMemberPath = "Display",
                SelectionMode = ListViewSelectionMode.Single, SelectedIndex = 0, MaxHeight = 420
            };
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Plugin Marketplace", Content = list,
                PrimaryButtonText = "Review", CloseButtonText = "Close", DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not MarketplaceItem selected) return;
            PluginsStatus.Text = $"Downloading and validating {selected.Name} manifest…";
            var package = await marketplaceClient.FetchPackageAsync(selected);
            var manifest = package.Manifest;
            var review = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = $"{selected.Name} {selected.Version}",
                Content = $"{selected.Description ?? selected.Id}\n\nManifest: {selected.ManifestUri}\n\nInstall {manifest.Commands.Count} declarative text command(s), {manifest.Snippets.Count} snippet(s){(package.WorkerSource is null ? "" : ", and one integrity-verified isolated worker")}? Worker permissions require separate project approval before execution.",
                PrimaryButtonText = "Install", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await review.ShowAsync() != ContentDialogResult.Primary) return;
            var installed = await new DeclarativePluginStore(root).InstallManifestAsync(
                manifest, package.WorkerSource);
            await EnableProjectPluginAsync(root, installed.Id);
            ReloadPlugins();
            PluginsStatus.Text = $"Installed {installed.Name} from the marketplace.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException
            or JsonException or HttpRequestException or TaskCanceledException)
        {
            PluginsStatus.Text = $"Plugin marketplace could not be loaded: {error.Message}";
        }
    }

    private async Task RefreshGitDiffAsync()
    {
        var root = GitRoot;
        if (root is null || GitFilesList.SelectedItem is not GitFileStatus file) return;
        var result = await gitService.DiffAsync(root, file.Path, staged: file.IsStaged && file.WorkTreeStatus == " ");
        GitDiffOutput.Text = !result.Started ? result.Error ?? "Git diff failed."
            : result.ExitCode != 0 ? result.StandardError
            : String.IsNullOrEmpty(result.StandardOutput) ? "No textual diff is available." : result.StandardOutput;
        var hunks = result.Started && result.ExitCode == 0
            ? GitService.ParseHunks(file.Path, result.StandardOutput) : [];
        GitHunkPicker.ItemsSource = hunks;
        GitHunkPicker.SelectedIndex = hunks.Count > 0 ? 0 : -1;
    }

    private async Task RunGitPathActionAsync(bool stage)
    {
        var root = GitRoot;
        var files = GitFilesList.SelectedItems.Cast<GitFileStatus>().ToList();
        if (root is null || files.Count == 0) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = stage ? "Stage selected files?" : "Unstage selected files?",
            Content = $"Apply this Git operation to {files.Count} selected file(s)?",
            PrimaryButtonText = stage ? "Stage" : "Unstage", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var result = stage
            ? await gitService.StageAsync(root, files.Select(file => file.Path).ToArray())
            : await gitService.UnstageAsync(root, files.Select(file => file.Path).ToArray());
        if (!result.Started || result.ExitCode != 0)
        {
            GitStatusText.Text = result.Error ?? result.StandardError.Trim();
            return;
        }
        await RefreshGitAsync();
    }

    private async Task DiscardGitSelectionAsync()
    {
        var root = GitRoot;
        var files = GitFilesList.SelectedItems.Cast<GitFileStatus>().ToList();
        if (root is null || files.Count == 0) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Discard local changes?",
            Content = $"Discard tracked working-tree changes in {files.Count} selected file(s)? This cannot be undone.",
            PrimaryButtonText = "Discard", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var result = await gitService.DiscardAsync(root, files.Select(file => file.Path).ToArray());
        if (!result.Started || result.ExitCode != 0)
        {
            GitStatusText.Text = result.Error ?? result.StandardError.Trim();
            return;
        }
        await ReloadCleanOpenDocumentsAsync();
        await RefreshGitAsync();
    }

    private async Task ApplySelectedGitHunkAsync(bool stage)
    {
        var root = GitRoot;
        if (root is null || GitHunkPicker.SelectedItem is not GitHunk hunk) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = stage ? "Stage selected hunk?" : "Discard selected hunk?",
            Content = $"{hunk.Path}\n{hunk.Header}", PrimaryButtonText = stage ? "Stage" : "Discard",
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var result = await gitService.ApplyHunkAsync(root, hunk.Path, hunk.Patch, stage);
        if (!result.Started || result.ExitCode != 0)
        {
            GitStatusText.Text = result.Error ?? result.StandardError.Trim();
            return;
        }
        if (!stage) await ReloadCleanOpenDocumentsAsync();
        await RefreshGitAsync();
    }

    private async Task ShowGitHistoryAsync()
    {
        var root = GitRoot;
        if (root is null || GitFilesList.SelectedItem is not GitFileStatus file) return;
        var entries = await gitService.HistoryAsync(root, file.Path);
        GitDiffOutput.Text = entries.Count == 0 ? "No committed history for this file."
            : String.Join('\n', entries.Select(entry =>
                $"{entry.ShortId}  {entry.Date}  {entry.Author}  {entry.Subject}"));
    }

    private async Task ShowGitBlameAsync()
    {
        var root = GitRoot;
        if (root is null || GitFilesList.SelectedItem is not GitFileStatus file) return;
        var result = await gitService.BlameAsync(root, file.Path);
        GitDiffOutput.Text = !result.Started ? result.Error ?? "Git blame failed."
            : result.ExitCode != 0 ? result.StandardError : result.StandardOutput;
    }

    private async Task ChangeGitBranchAsync(bool create)
    {
        var root = GitRoot;
        if (root is null) return;
        var input = new TextBox { PlaceholderText = create ? "New branch name" : "Existing branch name", MaxLength = 255 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = create ? "Create and switch branch" : "Switch branch",
            Content = input, PrimaryButtonText = create ? "Create" : "Switch",
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || String.IsNullOrWhiteSpace(input.Text)) return;
        var result = await gitService.SwitchBranchAsync(root, input.Text.Trim(), create);
        if (!result.Started || result.ExitCode != 0)
        {
            GitStatusText.Text = result.Error ?? result.StandardError.Trim();
            return;
        }
        await ReloadCleanOpenDocumentsAsync();
        await RefreshGitAsync();
        RefreshWorkspaceTree();
    }

    private async Task CommitGitAsync()
    {
        var root = GitRoot;
        if (root is null) return;
        var input = new TextBox { PlaceholderText = "Commit message", AcceptsReturn = true, MaxLength = 10_000 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Commit staged changes", Content = input,
            PrimaryButtonText = "Commit", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || String.IsNullOrWhiteSpace(input.Text)) return;
        var review = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Confirm Git commit",
            Content = $"Repository: {root}\nMessage: {input.Text.Trim()}",
            PrimaryButtonText = "Commit", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await review.ShowAsync() != ContentDialogResult.Primary) return;
        var result = await gitService.CommitAsync(root, input.Text);
        if (!result.Started || result.ExitCode != 0)
        {
            GitStatusText.Text = result.Error ?? result.StandardError.Trim();
            return;
        }
        await RefreshGitAsync();
        GitDiffOutput.Text = result.StandardOutput;
    }

    private async Task StartTerminalAsync()
    {
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            TerminalStatus.Text = "Open a workspace folder before starting a terminal.";
            return;
        }
        await StopTerminalAsync();
        var generation = Interlocked.Increment(ref terminalGeneration);
        var executable = Environment.GetEnvironmentVariable("COMSPEC");
        if (String.IsNullOrWhiteSpace(executable)) executable = "cmd.exe";
        try
        {
            terminalSession = new WindowsPseudoConsoleSession(executable, ["/D", "/Q"], root, text =>
            {
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (generation != terminalGeneration) return;
                    AppendTerminalOutput(text);
                });
            });
            TerminalPanel.Visibility = Visibility.Visible;
            TerminalStatus.Text = $"Terminal — {root}";
            TerminalInput.IsEnabled = true;
            var session = terminalSession;
            _ = session.Completion.ContinueWith(_ => DispatcherQueue.TryEnqueue(() =>
            {
                if (generation != terminalGeneration) return;
                TerminalStatus.Text = "Terminal exited.";
                TerminalInput.IsEnabled = false;
                if (ReferenceEquals(terminalSession, session)) terminalSession = null;
            }), TaskScheduler.Default);
        }
        catch (Exception error) when (error is PlatformNotSupportedException or IOException
            or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            terminalSession = null;
            TerminalInput.IsEnabled = false;
            TerminalStatus.Text = $"Terminal could not start: {error.Message}";
        }
    }

    private async Task StopTerminalAsync()
    {
        Interlocked.Increment(ref terminalGeneration);
        var session = terminalSession;
        terminalSession = null;
        if (session is not null) await session.DisposeAsync();
        TerminalInput.IsEnabled = false;
        TerminalStatus.Text = "Terminal stopped.";
    }

    private void AppendTerminalOutput(string text)
    {
        var combined = TerminalOutput.Text + text;
        if (combined.Length > WindowsPseudoConsoleSession.MaximumOutputCharacters)
        {
            combined = "[Earlier terminal output discarded.]\n"
                + combined[^WindowsPseudoConsoleSession.MaximumOutputCharacters..];
        }
        TerminalOutput.Text = combined;
        TerminalOutput.SelectionStart = TerminalOutput.Text.Length;
    }

    private async Task<LanguageServerClient?> EnsureLanguageServerAsync()
    {
        var document = workspace.ActiveDocument;
        if (document is null || document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
        {
            LanguageServerStatus.Text = "Save the active document before using language features.";
            return null;
        }
        var root = workspaceRoots.FirstOrDefault(candidate => WorkspaceTree.IsInside(candidate, document.Path));
        if (root is null)
        {
            LanguageServerStatus.Text = "The active document is outside the open workspace roots.";
            return null;
        }
        if (String.IsNullOrWhiteSpace(settings.LanguageServerCommand)
            || String.IsNullOrWhiteSpace(settings.LanguageServerLanguageId))
        {
            ShowLanguageServerSettings();
            LanguageServerStatus.Text = "Configure a language-server executable and language ID first.";
            return null;
        }
        if (languageServer is not null && languageServer.IsRunning
            && StringComparer.OrdinalIgnoreCase.Equals(languageServerRoot, root)) return languageServer;
        await StopLanguageServerAsync();
        var arguments = settings.LanguageServerArguments
            .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Take(256).ToList();
        var review = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Start language server?",
            Content = $"Executable: {settings.LanguageServerCommand}\nArguments: {String.Join(' ', arguments)}\nWorkspace: {root}",
            PrimaryButtonText = "Start", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await review.ShowAsync() != ContentDialogResult.Primary) return null;
        LanguageServerStatus.Text = "Starting language server…";
        LanguageServerOutput.Text = String.Empty;
        try
        {
            var client = await LanguageServerClient.StartAsync(
                root,
                new LanguageServerConfiguration(settings.LanguageServerCommand, arguments),
                text => DispatcherQueue.TryEnqueue(() => AppendLanguageServerOutput(text)));
            languageServer = client;
            languageServerRoot = root;
            languageDiagnostics.Clear();
            LanguageDiagnosticsList.ItemsSource = Array.Empty<LanguageDiagnosticListItem>();
            client.NotificationReceived += message =>
            {
                var snapshot = LanguageServerResults.ParseDiagnosticSnapshot(message, root);
                if (snapshot is null) return;
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (!ReferenceEquals(languageServer, client)) return;
                    languageDiagnostics[snapshot.Path] = snapshot;
                    RefreshLanguageDiagnostics();
                    for (var pane = 0; pane < editors.Length; pane++) QueueLineNumberRefresh(pane);
                });
            };
            LanguageServerStatus.Text = "Language server running.";
            ScheduleLanguageServerSync();
            return client;
        }
        catch (Exception error) when (error is IOException or InvalidOperationException
            or ArgumentException or System.ComponentModel.Win32Exception or OperationCanceledException)
        {
            LanguageServerStatus.Text = $"Language server could not start: {error.Message}";
            return null;
        }
    }

    private async Task RunLanguageRequestAsync(string method, object? extra = null)
    {
        LanguageServerPanel.Visibility = Visibility.Visible;
        var client = await EnsureLanguageServerAsync();
        var document = workspace.ActiveDocument;
        if (client is null || document is null) return;
        languageServerRequestCancellation?.Cancel();
        languageServerRequestCancellation?.Dispose();
        languageServerRequestCancellation = new CancellationTokenSource();
        var cancellationToken = languageServerRequestCancellation.Token;
        try
        {
            await client.SyncDocumentAsync(
                document.Path, settings.LanguageServerLanguageId, buffer.Text, cancellationToken);
            var (line, column) = TextNavigation.OffsetToLineColumn(buffer.Text, Editor.SelectionStart);
            LanguageServerStatus.Text = $"Requesting {method}…";
            var result = await client.RequestDocumentAsync(
                method, document.Path, line - 1, column - 1,
                method == "textDocument/references" ? new { context = new { includeDeclaration = true } } : extra,
                cancellationToken);
            if (method == "textDocument/hover")
            {
                LanguageServerOutput.Text = LanguageServerResults.ParseHover(result) ?? "No hover information.";
            }
            else if (method is "textDocument/definition" or "textDocument/references")
            {
                var locations = LanguageServerResults.ParseLocations(result, languageServerRoot!);
                LanguageServerOutput.Text = locations.Count == 0 ? "No locations." : String.Join('\n', locations.Select(
                    location => $"{location.Path}:{location.Line + 1}:{location.Character + 1}"));
                if (locations.Count > 0)
                {
                    var first = locations[0];
                    await NavigateToAsync(first.Path, first.Line + 1, first.Character + 1);
                }
            }
            else if (method == "textDocument/rename")
            {
                var edits = LanguageServerResults.ParseRenameEdits(result, languageServerRoot!);
                var preview = await languageRenameService.PreviewAsync(edits, cancellationToken);
                languageRenamePreview = preview.Error is null ? preview : null;
                LanguageServerOutput.Text = edits.Count == 0 ? "No rename edits." : String.Join('\n', edits.Select(edit =>
                    $"{edit.Path}:{edit.StartLine + 1}:{edit.StartCharacter + 1} → {edit.NewText}"));
                LanguageServerOutput.Text += preview.Error is not null
                    ? $"\n\nRename preview rejected: {preview.Error}"
                    : edits.Count == 0 ? String.Empty
                    : $"\n\nPreview: {preview.EditCount} edit(s) in {preview.Files.Count} file(s). Choose Apply Rename to commit.";
            }
            LanguageServerStatus.Text = $"{method} completed.";
        }
        catch (OperationCanceledException)
        {
            LanguageServerStatus.Text = "Language-server request cancelled.";
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException)
        {
            LanguageServerStatus.Text = error.Message;
        }
    }

    private async Task FormatDocumentAsync()
    {
        LanguageServerPanel.Visibility = Visibility.Visible;
        var client = await EnsureLanguageServerAsync();
        var document = workspace.ActiveDocument;
        if (client is null || document is null) return;
        languageServerRequestCancellation?.Cancel();
        languageServerRequestCancellation?.Dispose();
        languageServerRequestCancellation = new CancellationTokenSource();
        var cancellationToken = languageServerRequestCancellation.Token;
        var snapshot = buffer.Text;
        try
        {
            await client.SyncDocumentAsync(
                document.Path, settings.LanguageServerLanguageId, snapshot, cancellationToken);
            LanguageServerStatus.Text = "Requesting document formatting…";
            var result = await client.RequestFormattingAsync(
                document.Path, settings.TabSize, settings.InsertSpaces, cancellationToken);
            var edits = LanguageServerResults.ParseFormattingEdits(result);
            if (edits.Count == 0)
            {
                LanguageServerStatus.Text = "The language server returned no formatting edits.";
                return;
            }
            if (!StringComparer.Ordinal.Equals(buffer.Text, snapshot))
            {
                LanguageServerStatus.Text = "Formatting was not applied because the document changed during the request.";
                return;
            }
            var formatted = LanguageServerResults.ApplyFormattingEdits(snapshot, edits);
            if (!buffer.Apply(formatted, new TextSelection(0, 0)))
            {
                LanguageServerStatus.Text = "The document is already formatted.";
                return;
            }
            ApplyBufferToEditor();
            LanguageServerStatus.Text = $"Applied {edits.Count} formatting edit(s).";
        }
        catch (OperationCanceledException)
        {
            LanguageServerStatus.Text = "Document formatting cancelled.";
        }
        catch (Exception error) when (error is IOException or InvalidDataException or InvalidOperationException
            or ObjectDisposedException)
        {
            LanguageServerStatus.Text = $"Document formatting failed: {error.Message}";
        }
    }

    private async Task StopLanguageServerAsync()
    {
        languageServerRequestCancellation?.Cancel();
        languageServerRequestCancellation?.Dispose();
        languageServerRequestCancellation = null;
        languageServerSyncCancellation?.Cancel();
        languageServerSyncCancellation?.Dispose();
        languageServerSyncCancellation = null;
        var server = languageServer;
        languageServer = null;
        languageServerRoot = null;
        languageDiagnostics.Clear();
        LanguageDiagnosticsList.ItemsSource = Array.Empty<LanguageDiagnosticListItem>();
        for (var pane = 0; pane < editors.Length; pane++) QueueLineNumberRefresh(pane);
        if (server is not null) await server.DisposeAsync();
    }

    private void RefreshLanguageDiagnostics()
    {
        var items = languageDiagnostics.Values.SelectMany(value => value.Diagnostics)
            .OrderBy(diagnostic => diagnostic.Path, StringComparer.OrdinalIgnoreCase)
            .ThenBy(diagnostic => diagnostic.Line)
            .ThenBy(diagnostic => diagnostic.Character)
            .Take(1_000)
            .Select(diagnostic => new LanguageDiagnosticListItem(diagnostic))
            .ToList();
        LanguageDiagnosticsList.ItemsSource = items;
        LanguageServerStatus.Text = $"Language server running — {items.Count} diagnostic(s).";
    }

    private void AppendLanguageServerOutput(string text)
    {
        var combined = LanguageServerOutput.Text + text;
        LanguageServerOutput.Text = combined.Length <= LanguageServerClient.MaximumLogCharacters
            ? combined
            : "[Earlier language-server output discarded.]\n" + combined[^LanguageServerClient.MaximumLogCharacters..];
    }

    private void RefreshFindStatus()
    {
        if (FindPanel.Visibility != Visibility.Visible) return;
        var query = CurrentFindQuery();
        if (!ValidateFindQuery(query)) return;
        var matches = FindEngine.Find(buffer.Text, query);
        if (matches.Count == 0)
        {
            FindStatus.Text = "No matches.";
            return;
        }
        var selected = EditorSelection();
        var current = matches.ToList().FindIndex(match =>
            match.Start == selected.Start && match.Length == selected.Length);
        FindStatus.Text = current >= 0
            ? $"{current + 1} of {matches.Count}"
            : $"{matches.Count} match(es)";
    }

    private void RefreshDocumentStatus()
    {
        var selection = EditorSelection();
        var (line, column) = TextNavigation.OffsetToLineColumn(buffer.Text, selection.Start);
        PositionStatus.Text = $"Ln {line}, Col {column}";
        var document = workspace.ActiveDocument;
        EncodingStatus.Text = document?.Encoding.ToString() ?? String.Empty;
        LineEndingStatus.Text = document?.LineEnding.ToString().ToUpperInvariant() ?? String.Empty;
        LanguageStatus.Content = document is null ? String.Empty : CurrentLanguage(document).Name;
        if (buffer.Selections.Ranges.Count > 1)
        {
            PositionStatus.Text += Localize(
                $" · {buffer.Selections.Ranges.Count} selections",
                $" · {buffer.Selections.Ranges.Count} 个选区");
        }
    }

    private LanguageDefinition CurrentLanguage(OpenedDocument document)
    {
        if (documentLanguages.TryGetValue(document.Path, out var language)) return language;
        language = LanguageDetector.Detect(document.Path);
        documentLanguages[document.Path] = language;
        documentParserSnapshots.Remove(document.Path);
        return language;
    }

    private async Task SelectLanguageAsync()
    {
        var document = workspace.ActiveDocument;
        if (document is null) return;
        var list = new ListView
        {
            ItemsSource = LanguageDetector.Languages.Select(language => language.Name)
                .OrderBy(name => name, StringComparer.CurrentCultureIgnoreCase).ToList(),
            SelectionMode = ListViewSelectionMode.Single, MaxHeight = 420
        };
        list.SelectedItem = CurrentLanguage(document).Name;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "Select Language", Content = list,
            PrimaryButtonText = "Apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not string selected) return;
        var language = LanguageDetector.Languages.First(candidate => candidate.Name == selected);
        documentLanguages[document.Path] = language;
        documentFoldingStates.Remove(document.Path);
        documentParserSnapshots.Remove(document.Path);
        ApplyFoldingToEditors();
        ScheduleSyntaxHighlighting(paneLayout.ActivePane, immediate: true);
        RefreshDocumentStatus();
        RefreshPreview();
    }

    private void TogglePreview()
    {
        PreviewPanel.Visibility = PreviewPanel.Visibility == Visibility.Visible
            ? Visibility.Collapsed : Visibility.Visible;
        EditorPaneGrid.SetValue(Grid.ColumnSpanProperty, PreviewPanel.Visibility == Visibility.Visible ? 1 : 2);
        RefreshPreview();
    }

    private void RefreshPreview()
    {
        if (PreviewPanel.Visibility != Visibility.Visible || workspace.ActiveDocument is not { } document) return;
        var language = CurrentLanguage(document).Id;
        if (language == "markdown" || PreviewRenderer.IsMarkdownFileName(document.Path))
        {
            PreviewOutput.Visibility = Visibility.Collapsed;
            MarkdownPreview.Visibility = Visibility.Visible;
            pendingMarkdownHtml = PreviewRenderer.MarkdownToSafeHtml(
                buffer.Text, settings.ColorScheme != EditorColorScheme.Light);
            if (markdownPreviewReady) MarkdownPreview.NavigateToString(pendingMarkdownHtml);
            else _ = EnsureMarkdownPreviewAsync();
            return;
        }
        MarkdownPreview.Visibility = Visibility.Collapsed;
        PreviewOutput.Visibility = Visibility.Visible;
        PreviewOutput.Text = language == "json"
            ? String.Join('\n', PreviewRenderer.JsonTree(buffer.Text))
            : "Preview is available for Markdown and JSON documents.";
    }

    private async Task EnsureMarkdownPreviewAsync()
    {
        if (markdownPreviewReady) return;
        try { await MarkdownPreview.EnsureCoreWebView2Async(); }
        catch (Exception error)
        {
            MarkdownPreview.Visibility = Visibility.Collapsed;
            PreviewOutput.Visibility = Visibility.Visible;
            PreviewOutput.Text = $"Markdown preview is unavailable: {error.Message}\n\n"
                + PreviewRenderer.MarkdownToSafeText(buffer.Text);
        }
    }

    private void MarkdownPreview_CoreWebView2Initialized(
        WebView2 sender, CoreWebView2InitializedEventArgs args)
    {
        if (args.Exception is not null || sender.CoreWebView2 is null) return;
        var core = sender.CoreWebView2;
        core.Settings.IsScriptEnabled = false;
        core.Settings.IsWebMessageEnabled = false;
        core.Settings.AreDefaultScriptDialogsEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.NavigationStarting += MarkdownPreview_NavigationStarting;
        core.NewWindowRequested += (_, request) => request.Handled = true;
        core.DownloadStarting += (_, download) => download.Cancel = true;
        markdownPreviewReady = true;
        if (pendingMarkdownHtml is not null) sender.NavigateToString(pendingMarkdownHtml);
    }

    private async void MarkdownPreview_NavigationStarting(
        CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (args.Uri == "about:blank") return;
        args.Cancel = true;
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri)
            || uri.Scheme is not ("https" or "http" or "mailto")) return;
        try { await Launcher.LaunchUriAsync(uri); }
        catch { Status.Text = "The preview link could not be opened."; }
    }

    private void RefreshWorkspaceTree()
    {
        WorkspaceTreeView.RootNodes.Clear();
        foreach (var root in WorkspaceRoots.Normalize(workspaceRoots))
        {
            var name = Path.GetFileName(root);
            if (String.IsNullOrEmpty(name)) name = root;
            WorkspaceTreeView.RootNodes.Add(new TreeViewNode
            {
                Content = new WorkspaceTreeItem(root, name, IsDirectory: true, IsRoot: true),
                HasUnrealizedChildren = true
            });
        }
    }

    private void PopulateWorkspaceNode(TreeViewNode node, WorkspaceTreeItem parent)
    {
        if (!node.HasUnrealizedChildren) return;
        node.Children.Clear();
        var root = workspaceRoots.FirstOrDefault(candidate => WorkspaceTree.IsInside(candidate, parent.Path));
        if (root is null)
        {
            node.HasUnrealizedChildren = false;
            return;
        }
        foreach (var entry in workspaceTree.ReadChildren(root, parent.Path, projectExclusions))
        {
            node.Children.Add(new TreeViewNode
            {
                Content = new WorkspaceTreeItem(entry.FullPath, entry.Name, entry.IsDirectory),
                HasUnrealizedChildren = entry.IsDirectory
            });
        }
        node.HasUnrealizedChildren = false;
    }

    private static TreeViewNode? FindWorkspaceNode(IList<TreeViewNode> nodes, string path)
    {
        foreach (var node in nodes)
        {
            if (node.Content is WorkspaceTreeItem item
                && StringComparer.OrdinalIgnoreCase.Equals(item.Path, path)) return node;
            var nested = FindWorkspaceNode(node.Children, path);
            if (nested is not null) return nested;
        }
        return null;
    }

    private void RestartWorkspaceWatchers()
    {
        foreach (var watcher in workspaceWatchers) watcher.Dispose();
        workspaceWatchers.Clear();
        var exclusions = projectExclusions;
        foreach (var root in workspaceRoots)
        {
            try
            {
                workspaceWatchers.Add(new WorkspaceFileWatcher(root, changes =>
                {
                    DispatcherQueue.TryEnqueue(() => _ = HandleWorkspaceChangesAsync(changes));
                }, exclusions: exclusions));
            }
            catch (IOException error)
            {
                Status.Text = $"Could not watch {Path.GetFileName(root)}: {error.Message}";
            }
            catch (UnauthorizedAccessException error)
            {
                Status.Text = $"Could not watch {Path.GetFileName(root)}: {error.Message}";
            }
        }
    }

    private async Task HandleWorkspaceChangesAsync(WorkspaceChangeBatch batch)
    {
        if (batch.Changes.Any(change => workspaceRoots.Any(root => StringComparer.OrdinalIgnoreCase.Equals(
            change.Path, Path.Combine(root, ProjectSettingsStore.FileName)))))
        {
            await ReloadProjectExclusionsAsync();
            RestartWorkspaceWatchers();
            ReloadPlugins();
            await ReloadProjectKeyBindingsAsync();
        }
        RefreshWorkspaceTree();
        var reloaded = 0;
        var conflicts = 0;
        foreach (var change in batch.Changes)
        {
            if (workspaceRoots.Any(root => projectExclusions.IsExcluded(root, change.Path, isDirectory: true)))
            {
                continue;
            }
            var document = workspace.Find(change.Path);
            if (document is null) continue;
            if (document.IsDirty)
            {
                conflicts++;
                continue;
            }
            if (change.Kind == WorkspaceChangeKind.Deleted || !File.Exists(change.Path)) continue;
            var opened = await opener.OpenAsync([change.Path], settings);
            if (opened.Documents.Count != 1) continue;
            workspace.Replace(change.Path, opened.Documents[0]);
            documentBuffers.Remove(change.Path);
            documentSelectionHistories.Remove(change.Path);
            documentExpansionHistories.Remove(change.Path);
            documentFoldingStates.Remove(change.Path);
            documentParserSnapshots.Remove(change.Path);
            StoreSavedBaseline(change.Path, opened.Documents[0].Content);
            reloaded++;
        }
        if (reloaded > 0) RefreshWorkspace();
        if (conflicts > 0)
        {
            Status.Text = $"{conflicts} changed file(s) also have unsaved edits; local text was preserved.";
        }
        else if (batch.IsOverflow) Status.Text = "Many workspace changes were detected; the tree was fully refreshed.";
        else if (reloaded > 0) Status.Text = $"Reloaded {reloaded} changed file(s).";
    }

    private async Task ReloadCleanOpenDocumentsAsync()
    {
        var cleanPaths = workspace.Documents
            .Where(document => !document.IsDirty && !document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
            .Select(document => document.Path)
            .ToList();
        var opened = await opener.OpenAsync(cleanPaths, settings);
        foreach (var document in opened.Documents)
        {
            workspace.Replace(document.Path, document);
            documentBuffers.Remove(document.Path);
            documentSelectionHistories.Remove(document.Path);
            documentExpansionHistories.Remove(document.Path);
            documentParserSnapshots.Remove(document.Path);
            StoreSavedBaseline(document.Path, document.Content);
        }
        RefreshWorkspace();
    }

    private async Task ReloadProjectExclusionsAsync()
    {
        workspaceSearchCancellation?.Cancel();
        workspaceReplacePreview = null;
        var root = workspaceRoots.FirstOrDefault();
        if (root is null)
        {
            projectExclusions = WorkspaceExclusionPolicy.Empty;
            workspaceFileIndex = [];
            projectSymbolIndex = [];
            return;
        }
        try
        {
            var snapshot = await new ProjectSettingsStore(root).LoadAsync();
            projectExclusions = new WorkspaceExclusionPolicy(snapshot.Exclusions);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or InvalidDataException or DirectoryNotFoundException)
        {
            projectExclusions = WorkspaceExclusionPolicy.Empty;
            Status.Text = Localize(
                $"Project exclusions could not be loaded: {error.Message}",
                $"无法加载项目排除规则：{error.Message}");
        }
        workspaceFileIndex = [];
        projectSymbolIndex = [];
    }

    private async Task RestoreAsync()
    {
        settings = await settingsStore.LoadAsync();
        ApplySettingsToEditor();
        var session = await sessionStore.LoadAsync();
        workspaceRoots.Clear();
        workspaceRoots.AddRange(WorkspaceRoots.Normalize(session.Folders ?? []));
        await ReloadProjectExclusionsAsync();
        RefreshWorkspaceTree();
        RestartWorkspaceWatchers();
        ReloadPlugins();
        await ReloadProjectKeyBindingsAsync();
        var cleanPaths = session.Documents
            .Where(document => document.Draft is null)
            .Select(document => document.Path);
        var clean = await opener.OpenAsync(cleanPaths, settings);
        var dirtyDiskPaths = session.Documents.Where(document => document.Draft is not null
            && !document.Path.StartsWith("untitled://", StringComparison.OrdinalIgnoreCase))
            .Select(document => document.Path);
        var dirtyDisk = await opener.OpenAsync(dirtyDiskPaths, settings);
        var cleanByPath = clean.Documents.ToDictionary(document => document.Path, StringComparer.OrdinalIgnoreCase);
        var restored = new List<OpenedDocument>();
        foreach (var document in session.Documents)
        {
            if (document.Draft is not null)
            {
                restored.Add(new OpenedDocument(
                    document.Path, document.DisplayName, document.Draft,
                    System.Text.Encoding.UTF8.GetByteCount(document.Draft),
                    document.Encoding, document.LineEnding, IsDirty: true, Revision: document.Revision,
                    IsPinned: document.IsPinned));
            }
            else if (cleanByPath.TryGetValue(document.Path, out var disk))
            {
                restored.Add(disk with { IsPinned = document.IsPinned });
            }
        }
        workspace.Restore(restored, session.ActivePath);
        documentSavedBaselines.Clear();
        documentDiffSnapshots.Clear();
        foreach (var document in restored.Where(document => !document.IsDirty))
            StoreSavedBaseline(document.Path, document.Content);
        foreach (var document in dirtyDisk.Documents)
            StoreSavedBaseline(document.Path, document.Content);
        documentBookmarks.Clear();
        foreach (var saved in session.Documents)
        {
            var document = workspace.Find(saved.Path);
            if (document is null || saved.Bookmarks is null) continue;
            var bookmarks = new BookmarkSet();
            bookmarks.Restore(saved.Bookmarks, Math.Max(1, document.Content.Count(character => character == '\n') + 1));
            documentBookmarks[document.Path] = bookmarks;
        }
        paneLayout.Restore(session.Layout, workspace.Documents.Select(document => document.Path), workspace.ActiveDocument?.Path);
        ApplyPaneLayoutVisuals();
        RefreshWorkspace();
        Status.Text = clean.Failures.Count == 0
            ? "Session restored."
            : $"Session restored; {clean.Failures.Count} clean file(s) could not be reopened.";
    }

    private async Task PersistAsync()
    {
        try
        {
            await settingsStore.SaveAsync(settings);
            var documents = workspace.Documents.Select(document => new SessionDocument(
                document.Path, document.DisplayName, document.IsDirty ? document.Content : null,
                document.Encoding, document.LineEnding, document.Revision,
                documentBookmarks.TryGetValue(document.Path, out var bookmarks) ? bookmarks.Lines : [],
                document.IsPinned)).ToList();
            await sessionStore.SaveAsync(new DocumentSession(
                DocumentSession.CurrentFormatVersion, documents, workspace.ActiveDocument?.Path,
                workspaceRoots, paneLayout.Snapshot()));
        }
        catch
        {
            // Closing remains possible; a later UI slice adds a visible retry action.
        }
    }

    private void PersistAtClose()
    {
        workspaceSearchCancellation?.Cancel();
        workspaceSearchCancellation?.Dispose();
        workspaceSearchCancellation = null;
        workspaceWordsCancellation?.Cancel();
        workspaceWordsCancellation?.Dispose();
        workspaceWordsCancellation = null;
        HideCompletion();
        diffDecorationCancellation?.Cancel();
        diffDecorationCancellation?.Dispose();
        diffDecorationCancellation = null;
        buildCancellation?.Cancel();
        buildCancellation?.Dispose();
        buildCancellation = null;
        Interlocked.Increment(ref terminalGeneration);
        terminalSession?.Dispose();
        terminalSession = null;
        languageServerRequestCancellation?.Cancel();
        languageServerRequestCancellation?.Dispose();
        languageServerRequestCancellation = null;
        languageServerSyncCancellation?.Cancel();
        languageServerSyncCancellation?.Dispose();
        languageServerSyncCancellation = null;
        Interlocked.Increment(ref pluginWorkerGeneration);
        foreach (var worker in pluginWorkers.Values) worker.Terminate();
        pluginWorkers.Clear();
        pluginWorkerCommands.Clear();
        parserWorker?.Terminate();
        parserWorker = null;
        parserWorkerStartup = null;
        MarkdownPreview.Close();
        foreach (var cancellation in syntaxHighlightCancellations)
        {
            cancellation?.Cancel();
            cancellation?.Dispose();
        }
        foreach (var path in browserPreviewFiles)
        {
            try { File.Delete(path); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        browserPreviewFiles.Clear();
        if (languageServer is not null)
        {
            languageServer.DisposeAsync().AsTask().GetAwaiter().GetResult();
            languageServer = null;
        }
        foreach (var watcher in workspaceWatchers) watcher.Dispose();
        workspaceWatchers.Clear();
        try
        {
            var settingsSnapshot = settings;
            var sessionSnapshot = new DocumentSession(
                DocumentSession.CurrentFormatVersion,
                workspace.Documents.Select(document => new SessionDocument(
                    document.Path, document.DisplayName, document.IsDirty ? document.Content : null,
                    document.Encoding, document.LineEnding, document.Revision,
                    documentBookmarks.TryGetValue(document.Path, out var bookmarks) ? bookmarks.Lines : [],
                    document.IsPinned)).ToList(),
                workspace.ActiveDocument?.Path,
                workspaceRoots.ToList(),
                paneLayout.Snapshot());
            Task.Run(async () =>
            {
                await settingsStore.SaveAsync(settingsSnapshot).ConfigureAwait(false);
                await sessionStore.SaveAsync(sessionSnapshot).ConfigureAwait(false);
            }).GetAwaiter().GetResult();
        }
        catch
        {
            // Native close must remain possible; Windows acceptance covers retry UX before release.
        }
    }
}
