import AppKit
import Foundation
import LumenEditorCore
import SwiftUI

private enum WorkspaceSidebarDialog: Identifiable {
    case removeRoot(WorkspaceRoot)
    case createFile(parent: URL)
    case createFolder(parent: URL)
    case rename(WorkspaceEntry)
    case trash(WorkspaceEntry, openDocumentCount: Int)

    var id: String {
        switch self {
        case let .removeRoot(root):
            "remove-root-\(root.id.rawValue.uuidString)"
        case let .createFile(parent):
            "create-file-\(parent.standardizedFileURL.path)"
        case let .createFolder(parent):
            "create-folder-\(parent.standardizedFileURL.path)"
        case let .rename(entry):
            "rename-\(entry.url.standardizedFileURL.path)"
        case let .trash(entry, _):
            "trash-\(entry.url.standardizedFileURL.path)"
        }
    }
}

private enum WorkspaceSidebarAccessibility {
    static let sidebarID = "sidebar.workspace"
    static let treeID = "sidebar.workspace.tree"
    static let actionsID = "sidebar.workspace.actions"
    static let updatingID = "sidebar.workspace.updating"
    static let openFolderID = "sidebar.workspace.openFolder"
    static let addFolderID = "sidebar.workspace.addFolder"
    static let emptyOpenFolderID = "sidebar.workspace.empty.openFolder"
    static let dialogNameID = "sidebar.workspace.dialog.name"
    static let dialogCancelID = "sidebar.workspace.dialog.cancel"
    static let dialogCommitID = "sidebar.workspace.dialog.commit"
    static let issueID = "sidebar.workspace.issue"
    static let dismissIssueID = "sidebar.workspace.issue.dismiss"
    static let noticeID = "sidebar.workspace.notice"
    static let dismissNoticeID = "sidebar.workspace.notice.dismiss"

    static func rootID(_ root: WorkspaceRoot) -> String {
        "sidebar.workspace.root.\(root.id.rawValue.uuidString)"
    }

    static func entryID(_ entry: WorkspaceEntry) -> String {
        "sidebar.workspace.entry.\(entry.url.standardizedFileURL.path)"
    }
}

struct WorkspaceSidebarView: View {
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: WorkspaceController
    let activeFileURL: URL?
    @State private var pendingDialog: WorkspaceSidebarDialog?
    @State private var itemName = ""

    init(controller: WorkspaceController, activeFileURL: URL? = nil) {
        self.controller = controller
        self.activeFileURL = activeFileURL
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let issue = controller.issue {
                WorkspaceIssueBanner(issue: issue, controller: controller)
                Divider()
            }

            if let notice = controller.notice {
                WorkspaceNoticeBanner(notice: notice, controller: controller)
                Divider()
            }

            if controller.roots.isEmpty {
                emptyWorkspace
            } else {
                workspaceTree
            }
        }
        .frame(minWidth: 190, idealWidth: 240, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            appLocale.text("Workspace Sidebar", zh: "工作区侧边栏")
        )
        .accessibilityIdentifier(WorkspaceSidebarAccessibility.sidebarID)
        .task(id: activeFileURL) {
            await controller.synchronizeActiveFile(activeFileURL)
        }
        .alert(
            pendingDialog.map(dialogTitle)
                ?? appLocale.text("Workspace Action", zh: "工作区操作"),
            isPresented: Binding(
                get: { pendingDialog != nil },
                set: { if !$0 { pendingDialog = nil } }
            ),
            presenting: pendingDialog
        ) { dialog in
            switch dialog {
            case let .removeRoot(root):
                Button(appLocale.text("Cancel", zh: "取消"), role: .cancel) {
                    pendingDialog = nil
                }
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.dialogCancelID)
                Button(
                    appLocale.text("Remove Folder", zh: "移除文件夹"),
                    role: .destructive
                ) {
                    pendingDialog = nil
                    Task { await controller.removeRoot(root) }
                }
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.dialogCommitID)
            case .createFile, .createFolder, .rename:
                TextField(appLocale.text("Name", zh: "名称"), text: $itemName)
                    .accessibilityIdentifier(WorkspaceSidebarAccessibility.dialogNameID)
                Button(appLocale.text("Cancel", zh: "取消"), role: .cancel) {
                    pendingDialog = nil
                }
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.dialogCancelID)
                Button(dialogCommitTitle(dialog)) { commitNameDialog(dialog) }
                    .disabled(trimmedItemName.isEmpty)
                    .accessibilityIdentifier(WorkspaceSidebarAccessibility.dialogCommitID)
            case let .trash(entry, _):
                Button(appLocale.text("Cancel", zh: "取消"), role: .cancel) {
                    pendingDialog = nil
                }
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.dialogCancelID)
                Button(
                    appLocale.text("Move to Trash", zh: "移到废纸篓"),
                    role: .destructive
                ) {
                    pendingDialog = nil
                    Task { await controller.moveToTrash(entry.url) }
                }
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.dialogCommitID)
            }
        } message: { dialog in
            Text(dialogMessage(dialog))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(appLocale.text("EXPLORER", zh: "资源管理器"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if controller.isChangingRoots
                || controller.isRevealingActiveFile
                || controller.isMutatingItems {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        appLocale.text("Updating Workspace", zh: "正在更新工作区")
                    )
                    .accessibilityIdentifier(WorkspaceSidebarAccessibility.updatingID)
            }

            Menu {
                Button(appLocale.text("Open Folder…", zh: "打开文件夹…")) {
                    Task { await controller.openFolder(locale: appLocale) }
                }
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.openFolderID)
                Button(
                    appLocale.text("Add Folder to Workspace…", zh: "将文件夹添加到工作区…")
                ) {
                    Task { await controller.addFolder(locale: appLocale) }
                }
                .disabled(controller.roots.isEmpty || controller.isBusy)
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.addFolderID)
                Divider()
                Button(appLocale.text("Refresh Workspace", zh: "刷新工作区")) {
                    controller.refreshWorkspace()
                }
                .disabled(controller.roots.isEmpty)
                if controller.roots.count == 1, let root = controller.roots.first {
                    Divider()
                    Button(
                        appLocale.text("Remove Folder from Workspace…", zh: "从工作区移除文件夹…")
                    ) {
                        requestRootRemoval(root)
                    }
                } else if controller.roots.count > 1 {
                    Menu(
                        appLocale.text("Remove Folder from Workspace", zh: "从工作区移除文件夹")
                    ) {
                        ForEach(controller.roots) { root in
                            Button(root.displayName) { requestRootRemoval(root) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(controller.isBusy)
            .help(appLocale.text("Workspace Actions", zh: "工作区操作"))
            .accessibilityLabel(
                appLocale.text("Workspace Actions", zh: "工作区操作")
            )
            .accessibilityIdentifier(WorkspaceSidebarAccessibility.actionsID)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(appLocale.text("No Folder Open", zh: "未打开文件夹"))
                .font(.headline)
            Text(
                appLocale.text(
                    "Open a folder to browse its files.",
                    zh: "打开文件夹以浏览其中的文件。"
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(appLocale.text("Open Folder…", zh: "打开文件夹…")) {
                Task { await controller.openFolder(locale: appLocale) }
            }
            .disabled(controller.isBusy)
            .accessibilityIdentifier(WorkspaceSidebarAccessibility.emptyOpenFolderID)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceTree: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if controller.roots.count == 1, let root = controller.roots.first {
                            WorkspaceDirectoryContents(
                                directory: root.url,
                                depth: 0,
                                controller: controller,
                                requestCreate: requestCreate,
                                requestRename: requestRename,
                                requestTrash: requestTrash
                            )
                            .task(id: root.id) {
                                controller.loadChildren(of: root.url)
                            }
                        } else {
                            ForEach(controller.roots) { root in
                                WorkspaceRootRow(
                                    root: root,
                                    controller: controller,
                                    requestRemoval: { requestRootRemoval(root) },
                                    requestCreate: requestCreate,
                                    requestRename: requestRename,
                                    requestTrash: requestTrash
                                )
                            }
                        }
                    }
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                    .contentShape(Rectangle())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                }
                .scrollIndicators(.automatic)
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.treeID)
                .onChange(of: controller.selectedURL) { _, selectedURL in
                    guard let selectedURL else { return }
                    if reduceMotion {
                        proxy.scrollTo(selectedURL, anchor: .center)
                    } else {
                        withAnimation(
                            AppAccessibility.animation(reduceMotion: reduceMotion)
                        ) {
                            proxy.scrollTo(selectedURL, anchor: .center)
                        }
                    }
                }
                .contextMenu {
                    if controller.roots.count == 1, let root = controller.roots.first {
                        Button(appLocale.text("New File…", zh: "新建文件…")) {
                            requestCreate(root.url, false)
                        }
                            .disabled(controller.isBusy)
                        Button(appLocale.text("New Folder…", zh: "新建文件夹…")) {
                            requestCreate(root.url, true)
                        }
                            .disabled(controller.isBusy)
                        Divider()
                        Button(appLocale.text("Refresh", zh: "刷新")) {
                            controller.refresh(root.url)
                        }
                            .disabled(controller.isBusy)
                        Button(appLocale.text("Reveal in Finder", zh: "在访达中显示")) {
                            Task { await controller.revealInFinder(root.url) }
                        }
                        .disabled(controller.isBusy)
                        Button(appLocale.text("Copy Path", zh: "复制路径")) {
                            Task { await controller.copyPath(root.url) }
                        }
                        .disabled(controller.isBusy)
                        Button(appLocale.text("Copy Relative Path", zh: "复制相对路径")) {
                            Task {
                                await controller.copyPath(
                                    root.url,
                                    relativeToWorkspace: true
                                )
                            }
                        }
                        .disabled(controller.isBusy)
                        Button(
                            appLocale.text("Remove Folder from Workspace", zh: "从工作区移除文件夹")
                        ) {
                            requestRootRemoval(root)
                        }
                        .disabled(controller.isBusy)
                    }
                    Button(
                        appLocale.text("Add Folder to Workspace…", zh: "将文件夹添加到工作区…")
                    ) {
                        Task { await controller.addFolder(locale: appLocale) }
                    }
                    .disabled(controller.isBusy)
                }
            }
        }
    }

    private var trimmedItemName: String {
        itemName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dialogTitle(_ dialog: WorkspaceSidebarDialog) -> String {
        switch dialog {
        case let .removeRoot(root):
            appLocale.text(
                "Remove \(root.displayName) from the workspace?",
                zh: "要从工作区中移除 \(root.displayName) 吗？"
            )
        case .createFile:
            appLocale.text("New File", zh: "新建文件")
        case .createFolder:
            appLocale.text("New Folder", zh: "新建文件夹")
        case let .rename(entry):
            appLocale.text("Rename \(entry.name)", zh: "重命名 \(entry.name)")
        case let .trash(entry, _):
            appLocale.text(
                "Move \(entry.name) to the Trash?",
                zh: "要将 \(entry.name) 移到废纸篓吗？"
            )
        }
    }

    private func dialogCommitTitle(_ dialog: WorkspaceSidebarDialog) -> String {
        switch dialog {
        case .createFile, .createFolder:
            appLocale.text("Create", zh: "创建")
        case .rename:
            appLocale.text("Rename", zh: "重命名")
        case .removeRoot:
            appLocale.text("Remove Folder", zh: "移除文件夹")
        case .trash:
            appLocale.text("Move to Trash", zh: "移到废纸篓")
        }
    }

    private func dialogMessage(_ dialog: WorkspaceSidebarDialog) -> String {
        switch dialog {
        case .removeRoot:
            appLocale.text(
                "Open tabs are kept, but this folder will no longer be browsable as a workspace root.",
                zh: "打开的标签页会保留，但此文件夹将无法再作为工作区根目录浏览。"
            )
        case .createFile:
            appLocale.text(
                "Enter a simple file name without path separators. Existing items are never overwritten.",
                zh: "请输入不含路径分隔符的文件名。现有项目不会被覆盖。"
            )
        case .createFolder:
            appLocale.text(
                "Enter a simple folder name without path separators. Existing items are never overwritten.",
                zh: "请输入不含路径分隔符的文件夹名称。现有项目不会被覆盖。"
            )
        case .rename:
            appLocale.text(
                "Enter a simple name. Renaming stays within the current folder and never overwrites another item.",
                zh: "请输入简单名称。重命名仅在当前文件夹内进行，且不会覆盖其他项目。"
            )
        case let .trash(_, openDocumentCount):
            guard openDocumentCount > 0 else {
                return appLocale.text(
                    "The item will be moved to the system Trash and can be recovered there.",
                    zh: "此项目将移到系统废纸篓，并可从那里恢复。"
                )
            }
            let englishNoun = openDocumentCount == 1 ? "file is" : "files are"
            return appLocale.text(
                "\(openDocumentCount) open \(englishNoun) inside this item. "
                    + "The operation may be refused if unsaved changes would be lost.",
                zh: "此项目中有 \(openDocumentCount) 个打开的文件。"
                    + "如果操作会导致未保存的更改丢失，系统可能会拒绝执行。"
            )
        }
    }

    private func requestRootRemoval(_ root: WorkspaceRoot) {
        pendingDialog = .removeRoot(root)
    }

    private func requestCreate(_ parent: URL, _ isDirectory: Bool) {
        itemName = ""
        pendingDialog = isDirectory
            ? .createFolder(parent: parent)
            : .createFile(parent: parent)
    }

    private func requestRename(_ entry: WorkspaceEntry) {
        itemName = entry.name
        pendingDialog = .rename(entry)
    }

    private func requestTrash(_ entry: WorkspaceEntry) {
        pendingDialog = .trash(
            entry,
            openDocumentCount: controller.openDocumentCount(under: entry.url)
        )
    }

    private func commitNameDialog(_ dialog: WorkspaceSidebarDialog) {
        let name = trimmedItemName
        guard !name.isEmpty else { return }
        pendingDialog = nil
        Task {
            switch dialog {
            case let .createFile(parent):
                _ = await controller.createFile(in: parent, named: name)
            case let .createFolder(parent):
                _ = await controller.createDirectory(in: parent, named: name)
            case let .rename(entry):
                _ = await controller.rename(entry.url, toName: name)
            case .removeRoot, .trash:
                break
            }
        }
    }
}

private struct WorkspaceRootRow: View {
    @Environment(\.appLocale) private var appLocale
    let root: WorkspaceRoot
    @ObservedObject var controller: WorkspaceController
    let requestRemoval: () -> Void
    let requestCreate: (URL, Bool) -> Void
    let requestRename: (WorkspaceEntry) -> Void
    let requestTrash: (WorkspaceEntry) -> Void

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { controller.expandedDirectories.contains(root.url.standardizedFileURL) },
            set: { controller.setExpanded($0, directory: root.url) }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            WorkspaceDirectoryContents(
                directory: root.url,
                depth: 1,
                controller: controller,
                requestCreate: requestCreate,
                requestRename: requestRename,
                requestTrash: requestTrash
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text(root.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if root.isPrimary {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(appLocale.text("Primary", zh: "主要文件夹"))
                }
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle())
            .help(root.url.path)
            .contextMenu {
                Button(appLocale.text("New File…", zh: "新建文件…")) {
                    requestCreate(root.url, false)
                }
                .disabled(controller.isBusy)
                Button(appLocale.text("New Folder…", zh: "新建文件夹…")) {
                    requestCreate(root.url, true)
                }
                .disabled(controller.isBusy)
                Divider()
                Button(appLocale.text("Refresh", zh: "刷新")) {
                    controller.refresh(root.url)
                }
                .disabled(controller.isBusy)
                Button(appLocale.text("Reveal in Finder", zh: "在访达中显示")) {
                    Task { await controller.revealInFinder(root.url) }
                }
                .disabled(controller.isBusy)
                Button(appLocale.text("Copy Path", zh: "复制路径")) {
                    Task { await controller.copyPath(root.url) }
                }
                .disabled(controller.isBusy)
                Button(appLocale.text("Copy Relative Path", zh: "复制相对路径")) {
                    Task {
                        await controller.copyPath(
                            root.url,
                            relativeToWorkspace: true
                        )
                    }
                }
                .disabled(controller.isBusy)
                Divider()
                Button(
                    appLocale.text("Remove Folder from Workspace…", zh: "从工作区移除文件夹…"),
                    action: requestRemoval
                )
                .disabled(controller.isBusy)
            }
        }
        .disclosureGroupStyle(WorkspaceDisclosureStyle())
        .id(root.url.standardizedFileURL)
        .accessibilityIdentifier(WorkspaceSidebarAccessibility.rootID(root))
    }
}

private struct WorkspaceDirectoryContents: View {
    @Environment(\.appLocale) private var appLocale
    let directory: URL
    let depth: Int
    @ObservedObject var controller: WorkspaceController
    let requestCreate: (URL, Bool) -> Void
    let requestRename: (WorkspaceEntry) -> Void
    let requestTrash: (WorkspaceEntry) -> Void

    private var state: WorkspaceController.DirectoryState {
        controller.state(for: directory)
    }

    @ViewBuilder
    var body: some View {
        switch state.loadState {
        case .unloaded:
            Color.clear
                .frame(height: 1)
                .task(id: directory.standardizedFileURL) {
                    controller.loadChildren(of: directory)
                }
        case .loading:
            if state.entries.isEmpty {
                WorkspaceTreeStatusRow(
                    text: appLocale.text("Loading…", zh: "正在加载…"),
                    systemImage: nil,
                    showsProgress: true,
                    depth: depth
                )
            } else {
                entries
                WorkspaceTreeStatusRow(
                    text: appLocale.text("Refreshing…", zh: "正在刷新…"),
                    systemImage: nil,
                    showsProgress: true,
                    depth: depth
                )
            }
        case .loaded:
            if state.entries.isEmpty {
                WorkspaceTreeStatusRow(
                    text: appLocale.text("Empty Folder", zh: "空文件夹"),
                    systemImage: "tray",
                    depth: depth
                )
            } else {
                entries
            }
            if state.isTruncated {
                WorkspaceTreeStatusRow(
                    text: appLocale.text(
                        "More items are hidden by the workspace limit.",
                        zh: "工作区数量限制隐藏了更多项目。"
                    ),
                    systemImage: "exclamationmark.triangle",
                    depth: depth
                )
            }
        case .failed:
            VStack(alignment: .leading, spacing: 5) {
                WorkspaceTreeStatusRow(
                    text: state.errorContent.map {
                        appLocale.localizedWorkspaceIssue($0)
                    } ?? appLocale.text(
                        "The folder could not be read.",
                        zh: "无法读取此文件夹。"
                    ),
                    systemImage: "exclamationmark.triangle.fill",
                    depth: depth
                )
                Button(appLocale.text("Retry", zh: "重试")) {
                    controller.refresh(directory)
                }
                .controlSize(.small)
                .padding(.leading, CGFloat(depth) * 14 + 22)
            }
        }
    }

    @ViewBuilder
    private var entries: some View {
        ForEach(state.entries) { entry in
            WorkspaceEntryRow(
                entry: entry,
                depth: depth,
                controller: controller,
                requestCreate: requestCreate,
                requestRename: requestRename,
                requestTrash: requestTrash
            )
        }
    }
}

private struct WorkspaceEntryRow: View {
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let entry: WorkspaceEntry
    let depth: Int
    @ObservedObject var controller: WorkspaceController
    let requestCreate: (URL, Bool) -> Void
    let requestRename: (WorkspaceEntry) -> Void
    let requestTrash: (WorkspaceEntry) -> Void

    private var isSelected: Bool {
        controller.selectedURL == entry.url.standardizedFileURL
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { controller.expandedDirectories.contains(entry.url.standardizedFileURL) },
            set: { controller.setExpanded($0, directory: entry.url) }
        )
    }

    @ViewBuilder
    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: isExpanded) {
                WorkspaceDirectoryContents(
                    directory: entry.url,
                    depth: depth + 1,
                    controller: controller,
                    requestCreate: requestCreate,
                    requestRename: requestRename,
                    requestTrash: requestTrash
                )
            } label: {
                label
            }
            .disclosureGroupStyle(WorkspaceDisclosureStyle())
            .id(entry.url.standardizedFileURL)
            .accessibilityIdentifier(WorkspaceSidebarAccessibility.entryID(entry))
            .contextMenu {
                Button(appLocale.text("New File…", zh: "新建文件…")) {
                    requestCreate(entry.url, false)
                }
                .disabled(controller.isBusy)
                Button(appLocale.text("New Folder…", zh: "新建文件夹…")) {
                    requestCreate(entry.url, true)
                }
                .disabled(controller.isBusy)
                Divider()
                Button(appLocale.text("Refresh", zh: "刷新")) {
                    controller.refresh(entry.url)
                }
                .disabled(controller.isBusy)
                itemActions
            }
        } else {
            Button {
                if isOpenable { controller.open(entry) }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .id(entry.url.standardizedFileURL)
            .disabled(controller.isBusy || !isOpenable)
            .accessibilityHint(
                isOpenable
                    ? appLocale.text("Opens this file", zh: "打开此文件")
                    : appLocale.text("This item cannot be opened", zh: "无法打开此项目")
            )
            .accessibilityIdentifier(WorkspaceSidebarAccessibility.entryID(entry))
            .contextMenu { itemActions }
        }
    }

    @ViewBuilder
    private var itemActions: some View {
        Button(appLocale.text("Rename…", zh: "重命名…")) { requestRename(entry) }
            .disabled(controller.isBusy)
        Button(appLocale.text("Move To…", zh: "移动到…")) {
            Task { await controller.move(entry.url, locale: appLocale) }
        }
        .disabled(controller.isBusy)
        Divider()
        Button(appLocale.text("Reveal in Finder", zh: "在访达中显示")) {
            Task { await controller.revealInFinder(entry.url) }
        }
        .disabled(controller.isBusy)
        Button(appLocale.text("Copy Path", zh: "复制路径")) {
            Task { await controller.copyPath(entry.url) }
        }
        .disabled(controller.isBusy)
        Button(appLocale.text("Copy Relative Path", zh: "复制相对路径")) {
            Task { await controller.copyPath(entry.url, relativeToWorkspace: true) }
        }
        .disabled(controller.isBusy)
        Divider()
        Button(appLocale.text("Move to Trash", zh: "移到废纸篓"), role: .destructive) {
            requestTrash(entry)
        }
        .disabled(controller.isBusy)
    }

    private var label: some View {
        HStack(spacing: 6) {
            if controller.openingFileURLs.contains(entry.url.standardizedFileURL) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 15)
                    .accessibilityLabel(appLocale.text("Opening", zh: "正在打开"))
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 15)
            }
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
        }
        .font(.callout)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? selectedBackground : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected && colorSchemeContrast == .increased
                        ? Color.accentColor
                        : .clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(Rectangle())
        .accessibilityLabel(entry.name)
        .accessibilityValue(
            isSelected ? appLocale.text("Selected", zh: "已选择") : ""
        )
    }

    private var selectedBackground: Color {
        Color.accentColor.opacity(AppAccessibility.selectionOpacity(for: colorSchemeContrast))
    }

    private var iconName: String {
        switch entry.kind {
        case .file: fileIconName
        case .directory: "folder.fill"
        case .symbolicLink: "arrow.turn.up.right"
        case .other: "questionmark.square.dashed"
        }
    }

    private var isOpenable: Bool {
        entry.kind == .file || entry.kind == .symbolicLink
    }

    private var iconColor: Color {
        switch entry.kind {
        case .directory: .accentColor
        case .symbolicLink, .other: .secondary
        case .file: .primary
        }
    }

    private var fileIconName: String {
        switch entry.url.pathExtension.lowercased() {
        case "swift": "swift"
        case "md", "markdown": "doc.richtext"
        case "json": "curlybraces.square"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": "photo"
        default: "doc.text"
        }
    }
}

private struct WorkspaceTreeStatusRow: View {
    let text: String
    let systemImage: String?
    var showsProgress = false
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView()
                    .controlSize(.mini)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .lineLimit(2)
            Spacer(minLength: 2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, CGFloat(depth) * 14 + 5)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceIssueBanner: View {
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let issue: WorkspacePresentationIssue
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(
                        colorSchemeContrast == .increased ? Color.primary : Color.orange
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(appLocale.localizedWorkspaceIssueTitle(issue.titleContent))
                        .font(.caption.weight(.semibold))
                    Text(appLocale.localizedWorkspaceIssue(issue.content))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                Button { controller.dismissIssue() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    appLocale.text("Dismiss Workspace Error", zh: "关闭工作区错误")
                )
                .accessibilityIdentifier(WorkspaceSidebarAccessibility.dismissIssueID)
            }
        }
        .padding(9)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.22 : 0.10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WorkspaceSidebarAccessibility.issueID)
    }
}

private struct WorkspaceNoticeBanner: View {
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let notice: WorkspacePresentationNotice
    @ObservedObject var controller: WorkspaceController

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(
                    colorSchemeContrast == .increased ? Color.primary : Color.green
                )
            Text(appLocale.localizedWorkspaceIssue(notice.content))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button { controller.dismissNotice() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                appLocale.text("Dismiss Workspace Notice", zh: "关闭工作区通知")
            )
            .accessibilityIdentifier(WorkspaceSidebarAccessibility.dismissNoticeID)
        }
        .padding(9)
        .background(Color.green.opacity(colorSchemeContrast == .increased ? 0.20 : 0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WorkspaceSidebarAccessibility.noticeID)
    }
}

private struct WorkspaceDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(
                        systemName: configuration.isExpanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
