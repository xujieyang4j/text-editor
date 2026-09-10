import SwiftUI

struct RecentItemsView: View {
    @ObservedObject var controller: RecentItemsController
    let onDismiss: () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var queryIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: controller.mode == .files ? "doc" : "folder")
                    .accessibilityHidden(true)
                TextField(
                    appLocale.text("Filter recent items", zh: "筛选最近打开项"),
                    text: $controller.query
                )
                    .textFieldStyle(.roundedBorder)
                    .focused($queryIsFocused)
                    .onSubmit { Task { await acceptSelection() } }
                    .accessibilityLabel(
                        appLocale.text("Filter Recent Items", zh: "筛选最近打开项")
                    )
                    .accessibilityHint(
                        appLocale.text(
                            "Type a file name or path to filter the list.",
                            zh: "输入文件名或路径以筛选列表。"
                        )
                    )
                    .accessibilityIdentifier(Accessibility.queryID)
                if controller.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            appLocale.text("Opening Recent Item", zh: "正在打开最近项")
                        )
                        .accessibilityIdentifier(Accessibility.loadingID)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        appLocale.text("Close Recent Items", zh: "关闭最近打开项")
                    )
                    .accessibilityIdentifier(Accessibility.closeID)
            }
            .padding(12)

            Divider()

            if controller.items.isEmpty {
                ContentUnavailableView(
                    emptyMessage,
                    systemImage: controller.mode == .files ? "doc" : "folder"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(emptyMessage)
                .accessibilityIdentifier(Accessibility.emptyID)
            } else {
                List(controller.items.indices, id: \.self) { index in
                    let item = controller.items[index]
                    Button {
                        controller.selectItem(at: index)
                        Task { await acceptSelection() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        controller.selectedIndex == index
                            ? Color.accentColor.opacity(selectionOpacity) : Color.clear
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                controller.selectedIndex == index
                                    && colorSchemeContrast == .increased
                                    ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    )
                    .accessibilityLabel(item.label)
                    .accessibilityValue(item.detail)
                    .accessibilityHint(
                        appLocale.text("Opens this recent item", zh: "打开此最近项目")
                    )
                    .accessibilityIdentifier(Accessibility.itemID(item.id))
                    .accessibilityAddTraits(
                        controller.selectedIndex == index ? .isSelected : []
                    )
                    .contextMenu {
                        Button(
                            appLocale.text("Remove from Recent", zh: "从最近使用记录中移除"),
                            role: .destructive
                        ) {
                            _ = controller.removeStale(item)
                        }
                        .accessibilityIdentifier(Accessibility.removeItemID(item.id))
                    }
                }
                .accessibilityLabel(
                    appLocale.text("Recent Items", zh: "最近打开项")
                )
                .accessibilityIdentifier(Accessibility.resultsID)
            }

            if let issue = controller.issue {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(
                            colorSchemeContrast == .increased ? Color.primary : Color.orange
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appLocale.localizedRecentIssueTitle(issue.titleContent))
                            .font(.callout.weight(.semibold))
                        Text(appLocale.localizedRecentIssue(issue.content))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if issue.canRemoveStaleItem {
                        Button(appLocale.text("Remove", zh: "移除")) {
                            _ = controller.removeUnavailableItem()
                        }
                        .accessibilityLabel(
                            appLocale.text("Remove Unavailable Item", zh: "移除不可用项目")
                        )
                        .accessibilityIdentifier(Accessibility.removeUnavailableID)
                    }
                    Button(appLocale.text("Dismiss", zh: "忽略")) {
                        controller.dismissIssue()
                    }
                    .accessibilityLabel(
                        appLocale.text("Dismiss Recent Item Error", zh: "忽略最近打开项错误")
                    )
                    .accessibilityIdentifier(Accessibility.dismissIssueID)
                }
                .padding(10)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(Accessibility.issueID)
            }
        }
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 900)
        .frame(minHeight: 320, idealHeight: 500, maxHeight: 760)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentationTitle)
        .accessibilityIdentifier(Accessibility.panelID)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .onAppear { queryIsFocused = true }
        .onChange(of: controller.focusGeneration) { _, _ in queryIsFocused = true }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: dismiss)
    }

    private var presentationTitle: String {
        switch controller.mode {
        case .files: return appLocale.text("Open Recent File", zh: "打开最近文件")
        case .projects: return appLocale.text("Open Recent Project", zh: "打开最近项目")
        }
    }

    private var emptyMessage: String {
        switch controller.mode {
        case .files:
            return appLocale.text(
                "No recent files are available.",
                zh: "没有可用的最近文件。"
            )
        case .projects:
            return appLocale.text(
                "No recent projects are available.",
                zh: "没有可用的最近项目。"
            )
        }
    }

    private var selectionOpacity: Double {
        colorSchemeContrast == .increased ? 0.3 : 0.14
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .down: controller.moveSelection(by: 1)
        case .up: controller.moveSelection(by: -1)
        default: break
        }
    }

    private func acceptSelection() async {
        if await controller.acceptSelection() { onDismiss() }
    }

    private func dismiss() {
        controller.dismiss()
        onDismiss()
    }

    enum Accessibility {
        static let panelID = "panel.recentItems"
        static let queryID = "panel.recentItems.query"
        static let loadingID = "panel.recentItems.loading"
        static let closeID = "panel.recentItems.close"
        static let resultsID = "panel.recentItems.results"
        static let emptyID = "panel.recentItems.empty"
        static let issueID = "panel.recentItems.issue"
        static let removeUnavailableID = "panel.recentItems.issue.remove"
        static let dismissIssueID = "panel.recentItems.issue.dismiss"

        static func itemID(_ id: String) -> String {
            "panel.recentItems.item." + id
        }

        static func removeItemID(_ id: String) -> String {
            itemID(id) + ".remove"
        }
    }
}
