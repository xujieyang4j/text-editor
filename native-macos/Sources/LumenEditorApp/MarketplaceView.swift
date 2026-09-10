import AppKit
import LumenEditorCore
import SwiftUI

/// Read-only browsing until the user explicitly confirms one selected item.
/// The controller then repeats ID, origin and SRI checks before installation.
struct MarketplaceView: View {
    @ObservedObject private var controller: PluginController
    private let onDismiss: @MainActor () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var query = ""
    @State private var pendingInstallation: MarketplaceItem?

    init(
        controller: PluginController,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    private var filteredItems: [MarketplaceItem] {
        CommandFuzzyMatcher.filter(query: query, items: controller.marketplaceItems) { item in
            [item.name, item.id, item.description ?? ""].joined(separator: " ")
        }.map { $0.item }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let issue = controller.issue {
                issueBanner(issue)
                Divider()
            }
            catalog
            if !controller.marketplaceFailures.isEmpty {
                Divider()
                failureSummary
            }
        }
        .frame(minWidth: 560, idealWidth: 720, maxWidth: 980)
        .frame(minHeight: 380, idealHeight: 580, maxHeight: 820)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            appLocale.text(Accessibility.panel, zh: "插件市场")
        )
        .accessibilityIdentifier(AppAccessibility.id("marketplace panel"))
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .task {
            if controller.marketplaceItems.isEmpty { await controller.refreshMarketplace() }
        }
        .confirmationDialog(
            appLocale.text("Install Declarative Plugin?", zh: "安装声明式插件？"),
            isPresented: installationBinding,
            presenting: pendingInstallation
        ) { item in
            Button(appLocale.text(
                "Install ‘\(item.name)’",
                zh: "安装“\(item.name)”"
            )) {
                pendingInstallation = nil
                Task { _ = await controller.installMarketplaceItem(item) }
            }
            .accessibilityIdentifier(
                AppAccessibility.id("marketplace confirm install \(item.id)")
            )
            Button(appLocale.text("Cancel", zh: "取消"), role: .cancel) {
                pendingInstallation = nil
            }
            .accessibilityIdentifier(AppAccessibility.id("marketplace cancel install"))
        } message: { item in
            Text(installationMessage(for: item))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Image(systemName: "shippingbox").accessibilityHidden(true)
            TextField(
                appLocale.text("Search marketplace", zh: "搜索插件市场"),
                text: $query
            )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(
                    appLocale.text(Accessibility.search, zh: "搜索插件市场")
                )
                .accessibilityIdentifier(AppAccessibility.id("marketplace search"))
            if controller.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        appLocale.text(Accessibility.loading, zh: "正在加载插件市场")
                    )
                    .accessibilityIdentifier(AppAccessibility.id("marketplace loading"))
            }
            Button { Task { await controller.refreshMarketplace() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(controller.workspaceURL == nil || controller.isBusy)
            .accessibilityLabel(
                appLocale.text(Accessibility.refresh, zh: "刷新插件市场")
            )
            .accessibilityIdentifier(AppAccessibility.id("marketplace refresh"))
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    appLocale.text(Accessibility.close, zh: "关闭插件市场")
                )
                .accessibilityIdentifier(AppAccessibility.id("marketplace close"))
        }
        .padding(10)
    }

    @ViewBuilder
    private var catalog: some View {
        if controller.workspaceURL == nil {
            ContentUnavailableView(
                appLocale.text("No Workspace Open", zh: "未打开工作区"),
                systemImage: "folder",
                description: Text(appLocale.text(
                    "Marketplace sources and installations are project-scoped.",
                    zh: "插件市场来源和安装仅作用于当前项目。"
                ))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(AppAccessibility.id("marketplace no workspace"))
        } else if !controller.isBusy && filteredItems.isEmpty {
            ContentUnavailableView(
                query.isEmpty
                    ? appLocale.text("No Marketplace Plugins", zh: "没有插件市场插件")
                    : appLocale.text("No Results", zh: "没有结果"),
                systemImage: "magnifyingglass",
                description: Text(
                    query.isEmpty
                        ? appLocale.text(
                            "Configured sources returned no declarative plugins.",
                            zh: "配置的来源未返回任何声明式插件。"
                        )
                        : appLocale.text(
                            "No plugin matches ‘\(query)’.",
                            zh: "没有插件与“\(query)”匹配。"
                        )
                )
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(AppAccessibility.id("marketplace empty"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredItems, id: \.id) { item in itemRow(item) }
                }
                .padding(12)
            }
            .accessibilityIdentifier(AppAccessibility.id("marketplace catalog"))
        }
    }

    private func itemRow(_ item: MarketplaceItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.headline)
                    Text(item.version).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let description = item.description, !description.isEmpty {
                    Text(description).font(.callout).lineLimit(3)
                }
                Text(item.manifestURL.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button(appLocale.text("Install…", zh: "安装…")) {
                pendingInstallation = item
            }
                .disabled(controller.isBusy || controller.plugins.contains { $0.id == item.id })
                .accessibilityLabel(appLocale.text(
                    "Install \(item.name)",
                    zh: "安装 \(item.name)"
                ))
                .accessibilityIdentifier(
                    AppAccessibility.id("marketplace install \(item.id)")
                )
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    Color.secondary.opacity(
                        AppAccessibility.separatorOpacity(for: colorSchemeContrast)
                    ),
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppAccessibility.id("marketplace item \(item.id)"))
    }

    private var failureSummary: some View {
        DisclosureGroup(appLocale.text(
            "Some marketplace sources failed",
            zh: "部分插件市场来源加载失败"
        )) {
            ForEach(controller.marketplaceFailures, id: \.sourceURL) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.sourceURL.absoluteString).font(.caption.monospaced())
                    Text(appLocale.localizedMarketplaceFailure(failure.reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .accessibilityIdentifier(AppAccessibility.id("marketplace failures"))
    }

    private func issueBanner(_ issue: PluginPresentationIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocale.localizedApp(issue.titleCopy))
                    .font(.callout.weight(.semibold))
                Text(appLocale.localizedPluginIssue(issue.content))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Spacer()
            Button { controller.dismissIssue() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    appLocale.text(Accessibility.dismissError, zh: "关闭插件市场错误")
                )
                .accessibilityIdentifier(AppAccessibility.id("marketplace dismiss error"))
        }
        .padding(10)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.18 : 0.08))
        .accessibilityIdentifier(AppAccessibility.id("marketplace issue"))
    }

    private func installationMessage(for item: MarketplaceItem) -> String {
        appLocale.text(
            "Install \(item.id) \(item.version) from:\n\n"
                + item.manifestURL.absoluteString
                + "\n\nIts manifest is sanitized and worker bytes are verified by "
                + "SHA-256 before installation. Worker execution requires a separate, "
                + "session-scoped approval.",
            zh: "安装来自以下地址的 \(item.id) \(item.version)：\n\n"
                + item.manifestURL.absoluteString
                + "\n\n清单会先经过清理，worker 字节也会先通过 SHA-256 完整性验证。"
                + "执行 worker 还需要当前会话中的单独授权。"
        )
    }

    private var installationBinding: Binding<Bool> {
        Binding(
            get: { pendingInstallation != nil },
            set: { if !$0 { pendingInstallation = nil } }
        )
    }

    enum Accessibility {
        static let panel = "Plugin Marketplace"
        static let search = "Search Plugin Marketplace"
        static let loading = "Loading Plugin Marketplace"
        static let refresh = "Refresh Plugin Marketplace"
        static let close = "Close Plugin Marketplace"
        static let dismissError = "Dismiss Marketplace Error"
    }
}
