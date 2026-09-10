import AppKit
import LumenEditorCore
import SwiftUI

struct LanguageToolsConfigurationView: View {
    @ObservedObject var controller: LanguageToolsController
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(l("Language", "语言")) {
                    TextField(
                        l("Language display name", "语言显示名称"),
                        text: binding(for: \.language)
                    )
                    .accessibilityLabel(l(Accessibility.language, "语言工具的语言"))
                    .accessibilityIdentifier(AppAccessibility.id("language tool language"))
                }

                Section {
                    HStack {
                        TextField(
                            l(
                                "Executable path or allowlisted command",
                                "可执行文件路径或允许的命令"
                            ),
                            text: binding(for: \.command)
                        )
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel(l(Accessibility.command, "语言工具命令"))
                        .accessibilityIdentifier(AppAccessibility.id("language tool command"))
                        Button(l("Choose…", "选择…")) {
                            Task { await controller.chooseExecutable() }
                        }
                        .accessibilityLabel(l(
                            Accessibility.chooseExecutable,
                            "选择语言工具可执行文件"
                        ))
                        .accessibilityHint(l(
                            "Choose the exact executable to request approval for.",
                            "选择需要请求执行授权的确切可执行文件。"
                        ))
                        .accessibilityIdentifier(
                            AppAccessibility.id("language tool choose executable")
                        )
                    }
                    Toggle(
                        l("Run as an explicit shell command", "作为显式 shell 命令运行"),
                        isOn: Binding(
                            get: { controller.draft.shell },
                            set: { controller.setShell($0) }
                        )
                    )
                    .accessibilityLabel(l(Accessibility.shell, "语言工具使用 Shell"))
                    .accessibilityHint(l(
                        "When enabled, Command is parsed by the shell and Arguments must be empty.",
                        "启用后，命令将由 shell 解析，参数必须为空。"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id("language tool shell"))
                    TextField(
                        l(
                            "Working directory (relative to workspace)",
                            "工作目录（相对于工作区）"
                        ),
                        text: binding(for: \.workingDirectory)
                    )
                    .accessibilityLabel(l(
                        Accessibility.workingDirectory,
                        "语言工具工作目录"
                    ))
                    .accessibilityIdentifier(
                        AppAccessibility.id("language tool working directory")
                    )
                } header: {
                    Text(l("Execution", "执行"))
                } footer: {
                    Text(l(
                        "Direct argv execution is the default. Shell parsing is used only "
                            + "when the switch is enabled, and requires the full command in "
                            + "Command with an empty argument list.",
                        "默认直接使用 argv 执行。只有启用此开关时才使用 shell 解析；"
                            + "此时必须在“命令”中填写完整命令，并将参数列表留空。"
                    ))
                }

                Section {
                    jsonEditor(
                        l("Arguments (JSON array)", "参数（JSON 数组）"),
                        text: binding(for: \.argumentsJSON),
                        accessibilityLabel: l(Accessibility.arguments, "语言工具参数"),
                        accessibilityHint: l(
                            "Enter an array of argument strings.",
                            "输入由参数字符串组成的数组。"
                        ),
                        accessibilityIdentifier: "language tool arguments"
                    )
                    .disabled(controller.draft.shell)
                    jsonEditor(
                        l("Environment (JSON object)", "环境变量（JSON 对象）"),
                        text: binding(for: \.environmentJSON),
                        accessibilityLabel: l(Accessibility.environment, "语言工具环境变量"),
                        accessibilityHint: l(
                            "Enter an object containing environment-variable names and values.",
                            "输入包含环境变量名称和值的对象。"
                        ),
                        accessibilityIdentifier: "language tool environment"
                    )
                } header: {
                    Text(l("Structured Values", "结构化值"))
                } footer: {
                    Text(l(
                        "Saving only writes .lumen-project.json. The exact executable, arguments, "
                            + "directory, environment, shell flag, workspace, and purpose are "
                            + "approved separately before first execution in this window session.",
                        "保存操作只会写入 .lumen-project.json。在此窗口会话中首次执行前，"
                            + "仍需针对确切的可执行文件、参数、目录、环境变量、shell 标志、"
                            + "工作区和用途单独授权。"
                    ))
                }

                if !controller.diagnostics.isEmpty {
                    Section(l(
                        "Latest Diagnostics (\(controller.diagnostics.count))",
                        "最新诊断（\(controller.diagnostics.count)）"
                    )) {
                        ForEach(Array(controller.diagnostics.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: icon(for: item.severity))
                                    .foregroundStyle(color(for: item.severity))
                                    .accessibilityHidden(true)
                                Text("\(item.line):\(item.column)")
                                    .font(.system(.caption, design: .monospaced))
                                Text(item.message).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(diagnosticAccessibilityLabel(item))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(l("Cancel", "取消")) { controller.dismissConfiguration() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AppAccessibility.id("language tool cancel"))
                Button(primaryActionTitle) {
                    _ = controller.saveConfiguration()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isSavingConfiguration)
                .accessibilityLabel(primaryActionAccessibilityLabel)
                .accessibilityIdentifier(AppAccessibility.id("language tool primary action"))
            }
            .padding(14)
            .background(.bar)
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 900)
        .frame(minHeight: 540, idealHeight: 650, maxHeight: 820)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "语言工具配置"))
        .accessibilityIdentifier(AppAccessibility.id("language tool configuration"))
    }

    private var statusText: String {
        switch controller.runState {
        case .idle: l("Ready", "已就绪")
        case .awaitingApproval: l("Waiting for approval", "正在等待授权")
        case let .running(source):
            l("Running \(sourceTitle(source))…", "正在运行\(sourceTitle(source))…")
        case let .completed(source, changed, diagnosticCount):
            l(
                "\(sourceTitle(source)) completed"
                    + (changed ? "; document updated" : "; no text change")
                    + "; \(diagnosticCount) diagnostic"
                    + (diagnosticCount == 1 ? "" : "s"),
                "\(sourceTitle(source))已完成"
                    + (changed ? "；文档已更新" : "；文本未更改")
                    + "；\(diagnosticCount) 条诊断"
            )
        case .discardedStale: l("Stale formatter result discarded", "已丢弃过期的格式化结果")
        }
    }

    private var primaryActionTitle: String {
        isRemovingConfiguration ? l("Remove", "移除") : l("Save", "保存")
    }

    private var primaryActionAccessibilityLabel: String {
        isRemovingConfiguration
            ? l("Remove Language Tool", "移除语言工具")
            : l(Accessibility.save, "保存语言工具")
    }

    private var isRemovingConfiguration: Bool {
        controller.draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && controller.hasConfiguration
    }

    private func jsonEditor(
        _ title: String, text: Binding<String>, accessibilityLabel: String,
        accessibilityHint: String, accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 95)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.quaternary, lineWidth: 1)
                }
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
                .accessibilityIdentifier(AppAccessibility.id(accessibilityIdentifier))
        }
        .padding(.vertical, 4)
    }

    private func binding<Value>(
        for keyPath: WritableKeyPath<LanguageToolDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.draft[keyPath: keyPath] },
            set: { controller.setDraft($0, for: keyPath) }
        )
    }

    private func icon(for severity: LanguageToolDiagnosticSeverity) -> String {
        switch severity {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func color(for severity: LanguageToolDiagnosticSeverity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private func sourceTitle(_ source: LanguageToolFormatSource) -> String {
        switch source {
        case .languageServer: l("language server", "语言服务器")
        case .languageTool: l("language tool", "语言工具")
        case .builtIn: l("built-in formatter", "内置格式化器")
        }
    }

    private func diagnosticAccessibilityLabel(_ diagnostic: LanguageToolDiagnostic) -> String {
        let severity: String
        switch diagnostic.severity {
        case .error: severity = l("Error", "错误")
        case .warning: severity = l("Warning", "警告")
        case .info: severity = l("Information", "信息")
        }
        return l(
            "\(severity), line \(diagnostic.line), column \(diagnostic.column): \(diagnostic.message)",
            "\(severity)，第 \(diagnostic.line) 行，第 \(diagnostic.column) 列：\(diagnostic.message)"
        )
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    enum Accessibility {
        static let panel = "Language Tool Configuration"
        static let language = "Language Tool Language"
        static let command = "Language Tool Command"
        static let chooseExecutable = "Choose Language Tool Executable"
        static let shell = "Use Shell for Language Tool"
        static let workingDirectory = "Language Tool Working Directory"
        static let arguments = "Language Tool Arguments"
        static let environment = "Language Tool Environment"
        static let save = "Save Language Tool"
    }
}

@MainActor
enum LanguageToolExecutablePicker {
    static func choose(locale: EditorLocale) async -> URL? {
        await choose(
            title: locale.text(
                "Choose Language Tool Executable",
                zh: "选择语言工具可执行文件"
            ),
            message: locale.text(
                "Choose the exact executable that this window may offer for language-tool approval.",
                zh: "选择此窗口可以请求语言工具执行授权的确切可执行文件。"
            ),
            prompt: locale.text("Choose", zh: "选择")
        )
    }

    static func chooseLanguageServer(locale: EditorLocale) async -> URL? {
        await choose(
            title: locale.text(
                "Choose Language Server Executable",
                zh: "选择语言服务器可执行文件"
            ),
            message: locale.text(
                "Choose the exact executable that this window may offer for language-server approval.",
                zh: "选择此窗口可以请求语言服务器执行授权的确切可执行文件。"
            ),
            prompt: locale.text("Choose", zh: "选择")
        )
    }

    private static func choose(
        title: String, message: String, prompt: String
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = title
            panel.message = message
            panel.prompt = prompt
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            } else {
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
    }
}
