import AppKit
import LumenEditorCore
import SwiftUI

/// Project-scoped plugin management. The shell supplies trusted folder-picking
/// and confirmation UI; this view never invents filesystem authority.
struct PluginManagerView: View {
    @ObservedObject private var controller: PluginController
    private let installLocalPlugin: @MainActor () async -> Bool
    private let onOpenMarketplace: @MainActor () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var pendingRemoval: InstalledPlugin?

    init(
        controller: PluginController,
        installLocalPlugin: @escaping @MainActor () async -> Bool = { false },
        onOpenMarketplace: @escaping @MainActor () -> Void = {}
    ) {
        self.controller = controller
        self.installLocalPlugin = installLocalPlugin
        self.onOpenMarketplace = onOpenMarketplace
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let issue = controller.issue {
                issueBanner(issue)
                Divider()
            }
            content
        }
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 900)
        .frame(minHeight: 360, idealHeight: 560, maxHeight: 780)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "插件管理器"))
        .accessibilityIdentifier(AppAccessibility.id("plugin manager panel"))
        .confirmationDialog(
            l("Move Plugin to Trash?", "将插件移到废纸篓？"),
            isPresented: removalBinding,
            presenting: pendingRemoval
        ) { plugin in
            Button(l(
                "Move ‘\(plugin.manifest.name)’ to Trash",
                "将“\(plugin.manifest.name)”移到废纸篓"
            ), role: .destructive) {
                _ = controller.uninstallPlugin(id: plugin.id)
                pendingRemoval = nil
            }
            .accessibilityIdentifier(AppAccessibility.id("plugin confirm removal"))
            Button(l("Cancel", "取消"), role: .cancel) { pendingRemoval = nil }
                .accessibilityIdentifier(AppAccessibility.id("plugin cancel removal"))
        } message: { _ in
            Text(l(
                "The project-scoped plugin directory will be moved to the system Trash. "
                    + "Its declarative commands, snippets and grants will be removed immediately.",
                "项目范围的插件目录将移到系统废纸篓。其声明式命令、代码片段和授权将立即移除。"
            ))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .accessibilityHidden(true)
            Text(l("PLUGINS", "插件")).font(.caption.weight(.semibold))
            Spacer()
            Button(l("Install Local…", "安装本地插件…")) {
                Task { _ = await installLocalPlugin() }
            }
            .disabled(controller.workspaceURL == nil || controller.isBusy)
            .accessibilityHint(l(
                "Choose a declarative plugin directory containing plugin.json.",
                "选择包含 plugin.json 的声明式插件目录。"
            ))
            .accessibilityIdentifier(AppAccessibility.id("plugin install local"))

            Button(l("Marketplace…", "插件市场…"), action: onOpenMarketplace)
                .disabled(controller.workspaceURL == nil || controller.isBusy)
                .accessibilityHint(l(
                    "Browse declarative plugins from configured HTTPS sources.",
                    "浏览来自已配置 HTTPS 来源的声明式插件。"
                ))
                .accessibilityIdentifier(AppAccessibility.id("plugin open marketplace"))
            Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(controller.workspaceURL == nil || controller.isBusy)
                .accessibilityLabel(l(Accessibility.refresh, "刷新插件"))
                .accessibilityIdentifier(AppAccessibility.id("plugin refresh"))
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if controller.workspaceURL == nil {
            emptyState(
                icon: "folder",
                title: l("No Workspace Open", "未打开工作区"),
                message: l(
                    "Plugins and their permissions are scoped to an open project.",
                    "插件及其权限仅作用于已打开的项目。"
                ),
                identifier: "plugin manager no workspace"
            )
        } else if controller.plugins.isEmpty {
            emptyState(
                icon: "puzzlepiece.extension",
                title: l("No Plugins Installed", "未安装插件"),
                message: l(
                    "Install a declarative local plugin or browse a configured HTTPS marketplace.",
                    "安装声明式本地插件，或浏览已配置的 HTTPS 插件市场。"
                ),
                identifier: "plugin manager empty"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.plugins) { plugin in pluginCard(plugin) }
                }
                .padding(12)
            }
        }
    }

    private func pluginCard(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.manifest.name).font(.headline)
                    Text("\(plugin.id) · \(plugin.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    l("Enabled", "已启用"),
                    isOn: Binding(
                        get: { plugin.isEnabled },
                        set: { _ = controller.setEnabled($0, pluginID: plugin.id) }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityLabel(l(
                    "Enable \(plugin.manifest.name)",
                    "启用 \(plugin.manifest.name)"
                ))
                .accessibilityHint(l(
                    "Makes this plugin's granted contributions available.",
                    "允许使用此插件已授权的功能。"
                ))
                .accessibilityIdentifier(AppAccessibility.id("plugin enabled \(plugin.id)"))
                Button(l("Remove…", "移除…"), role: .destructive) {
                    pendingRemoval = plugin
                }
                    .disabled(controller.isBusy)
                    .accessibilityLabel(l(
                        "Remove \(plugin.manifest.name)",
                        "移除 \(plugin.manifest.name)"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id("plugin remove \(plugin.id)"))
            }

            Text(contributionSummary(plugin))
            .font(.caption)
            .foregroundStyle(.secondary)

            if let extensionManifest = plugin.manifest.extensionManifest {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        controller.workerExecutionSupport == .isolatedProcess
                            && plugin.workerExecutionSupport == .isolatedProcess
                            ? l(
                                "Worker runs in an isolated helper after explicit approval.",
                                "明确授权后，worker 将在隔离的辅助进程中运行。"
                            )
                            : l(
                                "Worker execution is unavailable in this build.",
                                "此构建版本无法执行 worker。"
                            ),
                        systemImage: controller.workerExecutionSupport == .isolatedProcess
                            && plugin.workerExecutionSupport == .isolatedProcess
                            ? "checkmark.shield" : "nosign"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(requestedPermissions(in: extensionManifest), id: \.rawValue) { permission in
                        Toggle(
                            permissionTitle(permission),
                            isOn: Binding(
                                get: { plugin.grantedPermissions.contains(permission) },
                                set: {
                                    _ = controller.setPermission(
                                        permission, granted: $0, pluginID: plugin.id
                                    )
                                }
                            )
                        )
                        .disabled(controller.isBusy || !plugin.isEnabled)
                        .accessibilityHint(permissionHint(permission, plugin: plugin))
                        .accessibilityIdentifier(AppAccessibility.id(
                            "plugin \(plugin.id) permission \(permission.rawValue)"
                        ))
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(
            Color.secondary.opacity(
                AppAccessibility.separatorOpacity(for: colorSchemeContrast)
            ),
            lineWidth: colorSchemeContrast == .increased ? 2 : 1
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(
            "Plugin \(plugin.manifest.name)",
            "插件 \(plugin.manifest.name)"
        ))
        .accessibilityIdentifier(AppAccessibility.id("plugin card \(plugin.id)"))
    }

    private func permissionTitle(_ permission: PluginPermission) -> String {
        switch permission {
        case .documentRead: return l("Allow Document Read", "允许读取文档")
        case .documentEdit: return l("Allow Document Edit", "允许编辑文档")
        }
    }

    private func permissionHint(
        _ permission: PluginPermission, plugin: InstalledPlugin
    ) -> String {
        switch permission {
        case .documentRead:
            return l(
                "Allows \(plugin.manifest.name) to read the active document after worker approval.",
                "允许 \(plugin.manifest.name) 在 worker 获得授权后读取当前文档。"
            )
        case .documentEdit:
            return l(
                "Allows \(plugin.manifest.name) to edit the active document after worker approval.",
                "允许 \(plugin.manifest.name) 在 worker 获得授权后编辑当前文档。"
            )
        }
    }

    private func contributionSummary(_ plugin: InstalledPlugin) -> String {
        let commands = plugin.manifest.commands.filter { $0.insertText != nil }.count
        let snippets = plugin.manifest.snippets.count
        return l(
            "\(commands) text command\(commands == 1 ? "" : "s"), "
                + "\(snippets) snippet\(snippets == 1 ? "" : "s")",
            "\(commands) 个文本命令，\(snippets) 个代码片段"
        )
    }

    private func requestedPermissions(
        in extensionManifest: PluginExtensionManifest
    ) -> [PluginPermission] {
        var seen = Set<PluginPermission>()
        return extensionManifest.permissions.filter { seen.insert($0).inserted }
    }

    private func issueBanner(_ issue: PluginPresentationIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
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
                .accessibilityLabel(l(Accessibility.dismissError, "关闭插件错误"))
                .accessibilityIdentifier(AppAccessibility.id("plugin dismiss error"))
        }
        .padding(10)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.18 : 0.08))
        .accessibilityIdentifier(AppAccessibility.id("plugin issue"))
    }

    private func emptyState(
        icon: String, title: String, message: String, identifier: String
    ) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(AppAccessibility.id(identifier))
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    enum Accessibility {
        static let panel = "Plugin Manager"
        static let refresh = "Refresh Plugins"
        static let dismissError = "Dismiss Plugin Error"
    }
}
