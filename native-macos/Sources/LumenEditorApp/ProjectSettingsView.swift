import SwiftUI

/// Standalone project configuration panel. The application shell decides where
/// to present it; this view owns neither workspace selection nor command routing.
struct ProjectSettingsView: View {
    enum Accessibility {
        static let panel = "Project Settings"
        static let exclude = "Project Exclude Patterns"
        static let buildCommand = "Project Build Command"
        static let plugins = "Enabled Project Plugins"
        static let marketplaceURLs = "Project Marketplace URLs"
        static let chooseLanguageServerExecutable = "Choose Language Server Executable"
        static let save = "Save Project Settings"
    }

    @ObservedObject var controller: ProjectSettingsController
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                filesSection
                automationSection
                pluginsSection
                marketplaceSection
                advancedSection

                if let issue = controller.issue {
                    issueSection(issue)
                }
            }
            .formStyle(.grouped)

            Divider()
            actionBar
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 650, idealHeight: 780)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "项目设置"))
        .accessibilityIdentifier(AppAccessibility.id("project settings panel"))
    }

    private var filesSection: some View {
        Section {
            LabeledContent(l("Exclude patterns", "排除模式")) {
                TextEditor(text: binding(for: \.excludeText))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 92)
                    .accessibilityLabel(l(Accessibility.exclude, "项目排除模式"))
                    .accessibilityIdentifier(AppAccessibility.id("project settings exclude patterns"))
            }
        } header: {
            Text(l("Files", "文件"))
        } footer: {
            Text(l(
                "Enter one workspace glob per line. At most 100 patterns are saved.",
                "每行输入一个工作区 glob 模式，最多保存 100 个模式。"
            ))
        }
    }

    private var automationSection: some View {
        Section {
            TextField(
                l("Build command", "构建命令"),
                text: binding(for: \.buildCommand),
                prompt: Text(l("Optional project command", "可选的项目命令"))
            )
            .accessibilityLabel(l(Accessibility.buildCommand, "项目构建命令"))
            .accessibilityIdentifier(AppAccessibility.id("project settings build command"))

            LabeledContent(l("Language-server executables", "语言服务器可执行文件")) {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(l("Choose Executable…", "选择可执行文件…")) {
                        Task { await controller.chooseLanguageServerExecutable() }
                    }
                    .disabled(controller.isChoosingLanguageServerExecutable)
                    .accessibilityLabel(l(
                        Accessibility.chooseLanguageServerExecutable,
                        "选择语言服务器可执行文件"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id(
                        "project settings choose language server executable"
                    ))

                    ForEach(
                        controller.authorizedLanguageServerExecutableURLs, id: \.self
                    ) { url in
                        Text(url.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text(l("Build and Tools", "构建与工具"))
        } footer: {
            Text(l(
                "Saving a command never runs it. Build, formatter, and language-server "
                    + "controllers retain their own executable allowlists and approval scopes. "
                    + "Choose each absolute language-server executable here, then approve its "
                    + "exact command when first used in this window.",
                "保存命令不会执行它。构建、格式化和语言服务器控制器各自维护可执行文件允许列表与授权范围。"
                    + "请在此选择每个语言服务器的绝对可执行文件，并在本窗口首次使用其确切命令时确认授权。"
            ))
        }
    }

    private var pluginsSection: some View {
        Section {
            LabeledContent(l("Enabled plugin IDs", "已启用的插件 ID")) {
                TextEditor(text: binding(for: \.pluginsText))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 76)
                    .accessibilityLabel(l(Accessibility.plugins, "已启用的项目插件"))
                    .accessibilityIdentifier(AppAccessibility.id("project settings plugin ids"))
            }
        } header: {
            Text(l("Plugins", "插件"))
        } footer: {
            Text(l(
                "Enter one ASCII plugin ID per line. Invalid IDs are omitted.",
                "每行输入一个 ASCII 插件 ID，无效 ID 将被忽略。"
            ))
        }
    }

    private var marketplaceSection: some View {
        Section {
            LabeledContent(l("HTTPS catalog URLs", "HTTPS 目录网址")) {
                TextEditor(text: binding(for: \.marketplaceURLsText))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 76)
                    .accessibilityLabel(l(Accessibility.marketplaceURLs, "项目市场网址"))
                    .accessibilityIdentifier(AppAccessibility.id("project settings marketplace urls"))
            }
        } header: {
            Text(l("Marketplace", "扩展市场"))
        } footer: {
            Text(l(
                "Only absolute HTTPS sources without credentials or fragments are saved.",
                "仅保存不含凭据或片段的绝对 HTTPS 来源。"
            ))
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(l("Structured JSON", "结构化 JSON"), isExpanded: $showAdvanced) {
                jsonEditor(
                    l("Legacy key bindings", "旧版快捷键绑定"),
                    text: binding(for: \.keyBindingsJSON),
                    help: l(
                        "JSON object mapping shortcut strings to command IDs.",
                        "将快捷键字符串映射到命令 ID 的 JSON 对象。"
                    ),
                    identifier: "legacy key bindings"
                )
                jsonEditor(
                    l("Plugin permissions", "插件权限"),
                    text: binding(for: \.pluginPermissionsJSON),
                    help: l(
                        "JSON object; only document-read and document-edit are retained.",
                        "JSON 对象；仅保留 document-read 和 document-edit。"
                    ),
                    identifier: "plugin permissions"
                )
                jsonEditor(
                    l("Language tools", "语言工具"),
                    text: binding(for: \.languageToolsJSON),
                    help: l(
                        "JSON object keyed by language with command and args fields.",
                        "以语言为键、包含 command 与 args 字段的 JSON 对象。"
                    ),
                    identifier: "language tools"
                )
                jsonEditor(
                    l("Language servers", "语言服务器"),
                    text: binding(for: \.languageServersJSON),
                    help: l(
                        "JSON object keyed by language with command and args fields.",
                        "以语言为键、包含 command 与 args 字段的 JSON 对象。"
                    ),
                    identifier: "language servers"
                )
                jsonEditor(
                    l("Build systems", "构建系统"),
                    text: binding(for: \.buildSystemsJSON),
                    help: l(
                        "JSON array of bounded build-system declarations.",
                        "受限构建系统声明的 JSON 数组。"
                    ),
                    identifier: "build systems"
                )
                jsonEditor(
                    l("Key binding rules", "快捷键规则"),
                    text: binding(for: \.keyBindingRulesJSON),
                    help: l(
                        "JSON array of key sequence, command, and optional context declarations.",
                        "包含按键序列、命令和可选上下文声明的 JSON 数组。"
                    ),
                    identifier: "key binding rules"
                )
                jsonEditor(
                    l("Snippets", "代码片段"),
                    text: binding(for: \.snippetsJSON),
                    help: l(
                        "JSON array of declarative label/text/trigger/scope values.",
                        "声明式标签、文本、触发器和作用域值的 JSON 数组。"
                    ),
                    identifier: "snippets"
                )
            }
            .accessibilityIdentifier(AppAccessibility.id("project settings advanced"))
        } header: {
            Text(l("Advanced", "高级"))
        } footer: {
            Text(l(
                "Unknown fields and invalid child entries are discarded at the Core boundary.",
                "未知字段和无效子项会在核心层边界被丢弃。"
            ))
        }
    }

    private func jsonEditor(
        _ title: String,
        text: Binding<String>,
        help: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 105)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            Color.primary.opacity(
                                AppAccessibility.separatorOpacity(for: colorSchemeContrast)
                            ),
                            lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                        )
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier(
                    AppAccessibility.id("project settings \(identifier)")
                )
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func issueSection(_ issue: ProjectSettingsPresentationIssue) -> some View {
        Section {
            Label(localizedIssueMessage(issue.content), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            HStack {
                if controller.canReloadAfterConflict {
                    Button(l("Reload Disk Version", "重新载入磁盘版本")) {
                        _ = controller.reload()
                    }
                    .accessibilityIdentifier(AppAccessibility.id(
                        "project settings reload disk version"
                    ))
                }
                Button(l("Dismiss", "关闭"), action: controller.dismissIssue)
                    .accessibilityIdentifier(AppAccessibility.id(
                        "project settings dismiss issue"
                    ))
            }
        } header: {
            Text(localizedIssueTitle(issue.titleContent))
        }
    }

    private var actionBar: some View {
        HStack {
            if let url = controller.settingsURL {
                Text(url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(l("Revert", "还原"), action: controller.discardChanges)
                .disabled(!controller.hasPendingChanges || controller.isSaving)
                .accessibilityIdentifier(AppAccessibility.id("project settings revert"))
            Button(l("Cancel", "取消"), action: controller.dismiss)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AppAccessibility.id("project settings cancel"))
            Button(l("Save", "保存")) { _ = controller.saveAndDismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isSaving)
                .accessibilityLabel(l(Accessibility.save, "保存项目设置"))
                .accessibilityIdentifier(AppAccessibility.id("project settings save"))
        }
        .padding(14)
        .background(.bar)
    }

    private func binding<Value>(
        for keyPath: WritableKeyPath<ProjectSettingsDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.draft[keyPath: keyPath] },
            set: { controller.setDraft($0, for: keyPath) }
        )
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    private func localizedIssueTitle(
        _ title: ProjectSettingsPresentationIssue.Title
    ) -> String {
        appLocale.localizedProjectSettingsIssueTitle(title)
    }

    private func localizedIssueMessage(
        _ message: ProjectSettingsPresentationIssue.Message
    ) -> String {
        appLocale.localizedProjectSettingsIssue(message)
    }
}
