import AppKit
import LumenEditorCore
import SwiftUI

/// A presentation-only source-control panel. Its owner supplies workspace and
/// active-document context to GitController and decides how file URLs open.
struct GitPanelView: View {
    @ObservedObject private var controller: GitController

    @State private var commitMessage = ""
    @State private var branchName = ""
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        controller: GitController
    ) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let issue = controller.issue {
                GitIssueBanner(issue: issue) { controller.dismissIssue() }
                Divider()
            }

            if let request = controller.pendingDiscard {
                discardConfirmation(request)
                Divider()
            }

            if let request = controller.pendingConfirmation {
                mutationConfirmation(request)
                Divider()
            }

            Group {
                if !controller.hasWorkspace {
                    emptyState(
                        icon: "folder",
                        title: l("No Workspace Open", "未打开工作区"),
                        message: l(
                            "Open a folder to inspect its Git changes.",
                            "打开文件夹以查看其 Git 更改。"
                        )
                    )
                } else if let status = controller.status, !status.available {
                    emptyState(
                        icon: "arrow.triangle.branch",
                        title: l("No Git Repository", "没有 Git 仓库"),
                        message: l(
                            "The primary workspace folder is not a Git repository.",
                            "主工作区文件夹不是 Git 仓库。"
                        )
                    )
                } else if controller.status == nil {
                    loadingState
                } else {
                    repositoryContent
                }
            }
        }
        .frame(minWidth: 270, idealWidth: 360, maxWidth: 560)
        .frame(minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("Source Control", "源代码管理"))
        .accessibilityIdentifier(AppAccessibility.id("git panel"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .accessibilityHidden(true)

                Text(l("SOURCE CONTROL", "源代码管理"))
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 4)

                if let progress = controller.confirmationProgress {
                    let description = progress.localizedDescription(locale: appLocale)
                    ProgressView()
                        .controlSize(.small)
                        .help(description)
                        .accessibilityLabel(description)
                        .accessibilityIdentifier(
                            AppAccessibility.id("git confirmation progress")
                        )
                } else if let operation = controller.operation {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(localizedOperationDescription(operation))
                }

                Button {
                    Task { await controller.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!controller.hasWorkspace || controller.isBusy)
                .help(l("Refresh Git Status", "刷新 Git 状态"))
                .accessibilityLabel(l("Refresh Git Status", "刷新 Git 状态"))
                .accessibilityIdentifier(AppAccessibility.id("git refresh"))
            }

            if let status = controller.status, status.available {
                repositorySummary(status)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func repositorySummary(_ status: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(status.branch ?? l("Detached HEAD", "分离的 HEAD"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if let tracking = status.tracking,
                   let ahead = tracking.ahead, let behind = tracking.behind {
                    Text("↑\(max(0, ahead)) ↓\(max(0, behind))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(l(
                            "\(max(0, ahead)) ahead, \(max(0, behind)) behind",
                            "领先 \(max(0, ahead))，落后 \(max(0, behind))"
                        ))
                }
            }

            if let upstream = status.tracking?.upstream, !upstream.isEmpty {
                Text(l("Upstream: \(upstream)", "上游：\(upstream)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            let remotes = (status.remotes ?? []).map(GitRemotePresentation.init)
            if !remotes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l(
                        "Remotes (\(remotes.count))",
                        "远程仓库（\(remotes.count)）"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(remotes, id: \.name) { remote in
                        remoteSummary(remote)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remoteSummary(_ remote: GitRemotePresentation) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(remote.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            ForEach(remote.addresses) { address in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(address.kind.label(locale: appLocale) + ":")
                        .foregroundStyle(.secondary)
                    Text(address.value)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(address.value)
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remote.accessibilityLabel(locale: appLocale))
        .accessibilityIdentifier(AppAccessibility.id("git remote \(remote.name)"))
    }

    private var repositoryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                commitSection
                branchSection
                changesSection
                conflictsSection
                detailSection
            }
            .padding(10)
        }
    }

    private var commitSection: some View {
        GitPanelSection(title: l("COMMIT", "提交")) {
            HStack(spacing: 7) {
                TextField(l("Commit message", "提交信息"), text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                    .disabled(confirmationIsUnavailable)
                    .accessibilityLabel(l("Commit Message", "提交信息"))
                    .accessibilityIdentifier(AppAccessibility.id("git commit message"))

                Button(appLocale.localized(.commit), action: commit)
                    .disabled(
                        confirmationIsUnavailable
                            || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityHint(l(
                        "Commits the staged changes",
                        "提交已暂存的更改"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id("git commit"))
            }
        }
    }

    private var branchSection: some View {
        GitPanelSection(title: l("BRANCH", "分支")) {
            HStack(spacing: 7) {
                TextField(l("Branch name", "分支名称"), text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(confirmationIsUnavailable)
                    .accessibilityLabel(l("Branch Name", "分支名称"))
                    .accessibilityIdentifier(AppAccessibility.id("git branch name"))

                Button(l("Switch", "切换")) {
                    controller.requestCheckoutBranch(trimmedBranchName)
                }
                .disabled(confirmationIsUnavailable || trimmedBranchName.isEmpty)
                .accessibilityIdentifier(AppAccessibility.id("git switch branch"))

                Button(l("New", "新建")) {
                    controller.requestCreateBranch(trimmedBranchName)
                }
                .disabled(confirmationIsUnavailable || trimmedBranchName.isEmpty)
                .accessibilityLabel(l("Create Branch", "创建分支"))
                .accessibilityIdentifier(AppAccessibility.id("git create branch"))
            }
        }
    }

    private var changesSection: some View {
        GitPanelSection(title: l("CHANGES", "更改")) {
            let entries = controller.status?.entries ?? []
            if entries.isEmpty {
                Text(l("No changes", "没有更改"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .accessibilityLabel(l("Working tree clean", "工作树干净"))
            } else {
                HStack(spacing: 7) {
                    Button(l("All", "全部")) { controller.selectAllChanges() }
                        .accessibilityLabel(l("Select All Changes", "选择所有更改"))
                        .accessibilityIdentifier(AppAccessibility.id("git select all changes"))
                    Button(l("None", "无")) { controller.clearSelection() }
                        .accessibilityLabel(l("Clear Change Selection", "清除更改选择"))
                        .accessibilityIdentifier(AppAccessibility.id("git clear selection"))
                    Spacer()
                    Text(l(
                        "\(controller.selectedPaths.count) selected",
                        "已选择 \(controller.selectedPaths.count) 项"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(l(
                            "\(controller.selectedPaths.count) changes selected",
                            "已选择 \(controller.selectedPaths.count) 项更改"
                        ))
                }

                LazyVStack(spacing: 2) {
                    ForEach(entries, id: \.path) { entry in
                        changeRow(entry)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(l("Git Changed Files", "Git 已更改文件"))
                .accessibilityIdentifier(AppAccessibility.id("git changed files"))

                HStack(spacing: 7) {
                    Button(appLocale.localized(.stage)) {
                        controller.requestStage()
                    }
                    .accessibilityIdentifier(AppAccessibility.id("git stage selected"))
                    Button(appLocale.localized(.unstage)) {
                        controller.requestUnstage()
                    }
                    .accessibilityIdentifier(AppAccessibility.id("git unstage selected"))
                    Button(appLocale.localized(.discard), role: .destructive) {
                        controller.requestDiscard()
                    }
                    .accessibilityIdentifier(AppAccessibility.id("git discard selected"))
                    Spacer()
                }
                .disabled(confirmationIsUnavailable || controller.selectedPaths.isEmpty)
            }
        }
    }

    private func changeRow(_ entry: GitStatusEntry) -> some View {
        let selected = controller.selectedPaths.contains(entry.path)
        let active = controller.activePath == entry.path
        return HStack(spacing: 7) {
            Button { controller.toggleSelection(of: entry.path) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected
                ? l("Deselect \(entry.path)", "取消选择 \(entry.path)")
                : l("Select \(entry.path)", "选择 \(entry.path)"))

            Button {
                controller.setActivePath(entry.path)
                Task { await controller.loadDiffAndHunks(for: entry.path) }
            } label: {
                HStack(spacing: 7) {
                    Text(entry.indexStatus + entry.worktreeStatus)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(statusColor(entry))
                        .frame(width: 22, alignment: .leading)
                    Text(entry.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 3)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 5)
                .frame(height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active
                            ? Color.accentColor.opacity(
                                AppAccessibility.selectionOpacity(for: colorSchemeContrast)
                            )
                            : .clear)
                )
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)
            .accessibilityLabel(l(
                "\(entry.path), Git status \(spokenStatus(entry))",
                "\(entry.path)，Git 状态 \(spokenStatus(entry))"
            ))
            .accessibilityHint(l("Shows the file diff and hunks", "显示文件差异与区块"))

            Button {
                if let conflict = controller.conflictPresentations.first(where: { $0.path == entry.path }) {
                    Task { _ = await controller.openConflict(.worktree, conflict: conflict) }
                } else {
                    Task { _ = await controller.openFile(entry.path) }
                }
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help(appLocale.localized(.openFile))
            .accessibilityLabel(l("Open \(entry.path)", "打开 \(entry.path)"))
        }
    }

    @ViewBuilder
    private var conflictsSection: some View {
        if !controller.conflictPresentations.isEmpty {
            GitPanelSection(title: l("CONFLICTS", "冲突")) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(controller.conflictPresentations) { conflict in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(conflict.path, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 7) {
                                Button(l("Worktree", "工作树")) {
                                    Task { _ = await controller.openConflict(.worktree, conflict: conflict) }
                                }
                                if let ours = conflict.ours {
                                    Button(l("Ours", "本地")) {
                                        Task { _ = await controller.openConflict(.ours, conflict: conflict) }
                                    }
                                    .help(ours)
                                }
                                if let theirs = conflict.theirs {
                                    Button(l("Theirs", "对端")) {
                                        Task { _ = await controller.openConflict(.theirs, conflict: conflict) }
                                    }
                                    .help(theirs)
                                }
                                if conflict.ours != nil || conflict.theirs != nil {
                                    Button(l("Compare", "比较")) {
                                        Task { _ = await controller.openConflict(.compare, conflict: conflict) }
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .disabled(controller.isBusy)
                        }
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(l(
                            "Open merge conflict variants for \(conflict.path)",
                            "打开 \(conflict.path) 的合并冲突变体"
                        ))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(l("Git Conflicts", "Git 冲突"))
                .accessibilityIdentifier(AppAccessibility.id("git conflicts"))
            }
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        if let activePath = controller.activePath {
            GitPanelSection(title: l("DETAILS", "详细信息")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(activePath)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 7) {
                        Button(l("Diff", "差异")) {
                            Task { await controller.loadDiffAndHunks(for: activePath) }
                        }
                        Button(appLocale.localized(.history)) {
                            Task { await controller.loadHistory(for: activePath) }
                        }
                        Button(appLocale.localized(.blame)) {
                            Task { await controller.loadBlame(for: activePath) }
                        }
                        Spacer()
                    }
                    .disabled(controller.isBusy)

                    detailContent

                    if controller.detailKind == .diff, !controller.hunks.isEmpty {
                        Divider()
                        hunkControls
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch controller.detailKind {
        case .diff:
            GitMonospacedPreview(
                text: controller.diff?.diff ?? l(
                    "Select Diff to load changes.",
                    "选择“差异”以载入更改。"
                ),
                accessibilityLabel: l("Git Diff Preview", "Git 差异预览"),
                accessibilityIdentifier: AppAccessibility.id("git diff preview")
            )
        case .history:
            if controller.history.isEmpty {
                Text(l("No committed history for this file.", "此文件没有提交历史。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.history, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.subject)
                                .lineLimit(2)
                            Text("\(entry.shortId) · \(entry.author) · \(entry.date)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityLabel(l("Git File History", "Git 文件历史"))
                .accessibilityIdentifier(AppAccessibility.id("git file history"))
            }
        case .blame:
            GitMonospacedPreview(
                text: controller.blame?.blame ?? l(
                    "Select Blame to load attribution.",
                    "选择“追溯”以载入归属信息。"
                ),
                accessibilityLabel: l("Git Blame", "Git 追溯"),
                accessibilityIdentifier: AppAccessibility.id("git blame")
            )
        }
    }

    private var hunkControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker(l("Hunk", "区块"), selection: hunkSelection) {
                ForEach(Array(controller.hunks.enumerated()), id: \.offset) { index, hunk in
                    Text(l(
                        "Hunk \(index + 1): \(hunk.header)",
                        "区块 \(index + 1)：\(hunk.header)"
                    ))
                        .tag(index)
                }
            }
            .accessibilityLabel(l("Select Git Hunk", "选择 Git 区块"))
            .accessibilityIdentifier(AppAccessibility.id("git hunk picker"))

            if let hunk = controller.selectedHunk {
                GitMonospacedPreview(
                    text: hunk.patch,
                    accessibilityLabel: l("Selected Git Hunk", "所选 Git 区块"),
                    accessibilityIdentifier: AppAccessibility.id("git selected hunk")
                )
                HStack(spacing: 7) {
                    Button(l("Stage Hunk", "暂存区块")) {
                        controller.requestStage(hunk: hunk)
                    }
                    Button(l("Discard Hunk", "丢弃区块"), role: .destructive) {
                        controller.requestDiscard(hunk: hunk)
                    }
                }
                .disabled(confirmationIsUnavailable)
            }
        }
    }

    private var hunkSelection: Binding<Int> {
        Binding(
            get: {
                guard let selected = controller.selectedHunk else { return 0 }
                return controller.hunks.firstIndex(of: selected) ?? 0
            },
            set: { index in
                guard controller.hunks.indices.contains(index) else { return }
                controller.selectHunk(controller.hunks[index])
            }
        )
    }

    private func discardConfirmation(_ request: GitDiscardRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                l("Discard uncommitted changes?", "丢弃未提交的更改？"),
                systemImage: "exclamationmark.triangle.fill"
            )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)

            Text(discardSummary(request))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(l("This cannot be undone by Lumen Editor.", "Lumen Editor 无法撤销此操作。"))
                .font(.caption)

            HStack(spacing: 8) {
                Button(l("Cancel", "取消")) { controller.cancelDiscard() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(controller.isConfirmingMutation)
                    .accessibilityIdentifier(AppAccessibility.id("git discard confirmation cancel"))
                Button(appLocale.localized(.discard), role: .destructive) {
                    Task { await controller.confirmDiscard() }
                }
                .disabled(controller.isBusy || controller.isConfirmingMutation)
                .accessibilityIdentifier(AppAccessibility.id("git discard confirmation confirm"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.22 : 0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("Confirm Discard Git Changes", "确认丢弃 Git 更改"))
        .accessibilityIdentifier(AppAccessibility.id("git confirm discard"))
    }

    private func mutationConfirmation(_ request: GitMutationConfirmation) -> some View {
        let presentation = GitMutationConfirmationPresentation(
            request: request, locale: appLocale
        )
        return VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: "questionmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(l("Cancel", "取消")) { controller.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(controller.isConfirmingMutation)
                    .accessibilityIdentifier(AppAccessibility.id("git confirmation cancel"))
                Button(l("Confirm", "确认")) {
                    Task {
                        if await controller.confirmPendingMutation() {
                            if presentation.clearsCommitInput { commitMessage = "" }
                            if presentation.clearsBranchInput { branchName = "" }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isBusy || controller.isConfirmingMutation)
                .accessibilityIdentifier(AppAccessibility.id("git confirmation confirm"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.18 : 0.07))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier(AppAccessibility.id("git mutation confirmation"))
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(l("Loading Git status…", "正在载入 Git 状态…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(l("Loading Git Status", "正在载入 Git 状态"))
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var trimmedBranchName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var confirmationIsUnavailable: Bool {
        controller.isBusy
            || controller.isConfirmingMutation
            || controller.pendingConfirmation != nil
            || controller.pendingDiscard != nil
    }

    private func commit() {
        controller.requestCommit(message: commitMessage)
    }

    private func statusColor(_ entry: GitStatusEntry) -> Color {
        let status = entry.indexStatus + entry.worktreeStatus
        if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status) {
            return .orange
        }
        if status.contains("?") || status.contains("A") { return .green }
        if status.contains("D") { return .red }
        return .blue
    }

    private func localizedOperationDescription(_ operation: GitControllerOperation) -> String {
        operation.localizedDescription(locale: appLocale)
    }

    private func spokenStatus(_ entry: GitStatusEntry) -> String {
        let unchanged = l("unchanged", "未更改")
        return l("index", "索引")
            + " \(entry.indexStatus == " " ? unchanged : entry.indexStatus), "
            + l("working tree", "工作树")
            + " \(entry.worktreeStatus == " " ? unchanged : entry.worktreeStatus)"
    }

    private func discardSummary(_ request: GitDiscardRequest) -> String {
        let paths = request.affectedPaths
        if paths.count == 1 { return paths[0] }
        return l("\(paths.count) selected files", "已选择 \(paths.count) 个文件")
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }
}

struct GitMutationConfirmationPresentation: Equatable {
    let title: String
    let detail: String
    let accessibilityLabel: String
    let clearsCommitInput: Bool
    let clearsBranchInput: Bool

    init(request: GitMutationConfirmation, locale: EditorLocale) {
        self.init(target: request.target, locale: locale)
    }

    init(target: GitMutationConfirmation.Target, locale: EditorLocale) {
        clearsCommitInput = {
            if case .commit = target { return true }
            return false
        }()
        clearsBranchInput = {
            switch target {
            case .checkoutBranch, .createBranch: return true
            default: return false
            }
        }()

        switch target {
        case let .stagePaths(paths):
            title = locale.text("Stage selected files?", zh: "暂存所选文件？")
            detail = Self.fileCountDetail("Stage", zhVerb: "暂存", paths: paths, locale: locale)
        case let .unstagePaths(paths):
            title = locale.text("Unstage selected files?", zh: "取消暂存所选文件？")
            detail = Self.fileCountDetail("Unstage", zhVerb: "取消暂存", paths: paths, locale: locale)
        case let .stageHunk(hunk):
            title = locale.text("Stage selected hunk?", zh: "暂存所选区块？")
            detail = locale.text(
                "Stage selected hunk in “\(hunk.path)”?",
                zh: "要暂存“\(hunk.path)”中所选的更改区块吗？"
            )
        case let .commit(message):
            title = locale.text("Create commit?", zh: "创建提交？")
            detail = locale.text(
                "Create commit with message:\n\n\(message)",
                zh: "要使用以下信息创建提交吗：\n\n\(message)"
            )
        case let .checkoutBranch(name):
            title = locale.text("Switch branch?", zh: "切换分支？")
            detail = locale.text("Switch to branch “\(name)”?", zh: "要切换到分支“\(name)”吗？")
        case let .createBranch(name):
            title = locale.text("Create branch?", zh: "创建分支？")
            detail = locale.text(
                "Create and switch to branch “\(name)”?",
                zh: "要创建并切换到分支“\(name)”吗？"
            )
        }
        accessibilityLabel = locale.text(
            "Confirm Git mutation. \(detail)",
            zh: "确认 Git 更改。\(detail)"
        )
    }

    private static func fileCountDetail(
        _ verb: String, zhVerb: String, paths: [String], locale: EditorLocale
    ) -> String {
        locale.text(
            "\(verb) \(paths.count) selected file\(paths.count == 1 ? "" : "s")?",
            zh: "要对所选的 \(paths.count) 个文件执行“\(zhVerb)”吗？"
        )
    }
}

/// Pure view data derived from GitService's already-sanitized remote DTO.
/// Internal visibility keeps compact-row and accessibility copy testable.
struct GitRemotePresentation: Equatable {
    struct Address: Equatable, Identifiable {
        enum Kind: Hashable {
            case fetch
            case push
            case fetchAndPush

            func label(locale: EditorLocale) -> String {
                switch self {
                case .fetch: return locale.text("Fetch", zh: "拉取")
                case .push: return locale.text("Push", zh: "推送")
                case .fetchAndPush:
                    return locale.text("Fetch / Push", zh: "拉取/推送")
                }
            }

            func accessibilityLabel(value: String, locale: EditorLocale) -> String {
                switch self {
                case .fetch:
                    return locale.text("fetch URL \(value)", zh: "拉取地址 \(value)")
                case .push:
                    return locale.text("push URL \(value)", zh: "推送地址 \(value)")
                case .fetchAndPush:
                    return locale.text(
                        "fetch and push URL \(value)",
                        zh: "拉取和推送地址 \(value)"
                    )
                }
            }
        }

        let kind: Kind
        let value: String

        var id: Kind { kind }
    }

    let name: String
    let addresses: [Address]

    init(_ remote: GitRemote) {
        name = remote.name
        // Production values are already sanitized and bounded by GitService.
        // Reusing that sanitizer here keeps presentation fail-closed if a new
        // caller ever constructs a GitRemote outside the production service.
        let fetch = Self.safeAddress(remote.fetchURL)
        let push = Self.safeAddress(remote.pushURL)
        if let fetch, fetch == push {
            addresses = [Address(kind: .fetchAndPush, value: fetch)]
        } else {
            addresses = [
                fetch.map { Address(kind: .fetch, value: $0) },
                push.map { Address(kind: .push, value: $0) }
            ].compactMap { $0 }
        }
    }

    func accessibilityLabel(locale: EditorLocale) -> String {
        let remote = locale.text("Git remote \(name)", zh: "Git 远程仓库 \(name)")
        guard !addresses.isEmpty else { return remote }
        let separator = locale.isSimplifiedChinese ? "，" : ", "
        return ([remote] + addresses.map {
            $0.kind.accessibilityLabel(value: $0.value, locale: locale)
        }).joined(separator: separator)
    }

    private static func safeAddress(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = GitService.sanitizeRemoteURL(value)
        guard !sanitized.isEmpty else { return nil }
        let maximumUnits = GitServiceLimits.default.maximumRemoteURLUTF16Units
        guard sanitized.utf16.count > maximumUnits else { return sanitized }
        return String(decoding: Array(sanitized.utf16.prefix(maximumUnits)), as: UTF16.self)
    }
}

private struct GitPanelSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GitMonospacedPreview: View {
    let text: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
        }
        .frame(minHeight: 70, maxHeight: 220)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    Color.secondary.opacity(
                        AppAccessibility.separatorOpacity(for: colorSchemeContrast)
                    ),
                    lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                )
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(text)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct GitIssueBanner: View {
    let issue: GitPresentationIssue
    let dismiss: () -> Void
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(appLocale.localizedGitIssueTitle(issue.titleContent))
                    .font(.callout.weight(.semibold))
                Text(appLocale.localizedGitIssue(issue.content))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(appLocale.text("Dismiss Git Error", zh: "关闭 Git 错误"))
            .accessibilityIdentifier(AppAccessibility.id("git dismiss error"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.18 : 0.08))
        .accessibilityElement(children: .contain)
    }
}
