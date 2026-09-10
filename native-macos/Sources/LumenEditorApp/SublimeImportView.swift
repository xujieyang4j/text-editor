import Foundation
import LumenEditorCore
import SwiftUI

/// Confirmation UI for immutable Sublime previews. The view captures the
/// presentation token for every action, so an older sheet cannot confirm or
/// cancel a preview that replaced it.
struct SublimeImportView: View {
    enum Accessibility {
        static let panel = "Sublime Import Preview"
        static let source = "Sublime Import Source"
        static let details = "Sublime Import Details"
        static let cancel = "Cancel Sublime Import"
        static let confirm = "Confirm Sublime Import"
        static let dismissIssue = "Dismiss Sublime Import Error"
    }

    @ObservedObject var controller: SublimeImportController
    let onDismiss: () -> Void
    @Environment(\.appLocale) private var appLocale
    @State private var isConfirming = false

    init(
        controller: SublimeImportController,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let presentation = controller.presentation {
                preview(presentation)
            } else if isConfirming {
                VStack(spacing: 12) {
                    ProgressView()
                        .accessibilityLabel(l("Importing Sublime data", "正在导入 Sublime 数据"))
                    Text(localizedStatusMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let issue = controller.issue {
                issueView(issue)
            } else {
                Text(localizedStatusMessage)
                    .foregroundStyle(.secondary)
                Button(l("Close", "关闭"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AppAccessibility.id("sublime import close"))
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 260, idealHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "Sublime 导入预览"))
        .accessibilityIdentifier(AppAccessibility.id("sublime import panel"))
        .onDisappear {
            guard let token = controller.confirmationToken else { return }
            _ = controller.cancel(token: token)
        }
    }

    @ViewBuilder
    private func preview(_ presentation: SublimeImportPresentation) -> some View {
        Text(previewTitle(for: presentation.kind))
            .font(.title2.weight(.semibold))
        Text(previewMessage(for: presentation.preview))
            .foregroundStyle(.secondary)
        LabeledContent(l("Source", "来源")) {
            Text(presentation.sourceURL.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel(l(
                    "Sublime import source: \(presentation.sourceURL.path)",
                    "Sublime 导入来源：\(presentation.sourceURL.path)"
                ))
                .accessibilityIdentifier(Accessibility.source)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                previewDetails(presentation.preview)
                if let issue = controller.issue {
                    Divider()
                    issueSummary(issue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(l(Accessibility.details, "Sublime 导入详情"))
        .accessibilityIdentifier(Accessibility.details)

        Divider()
        HStack {
            if controller.isBusy { ProgressView().controlSize(.small) }
            Text(localizedStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(l("Cancel", "取消")) {
                guard controller.cancel(token: presentation.token) else { return }
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(controller.isBusy)
            .accessibilityLabel(l(Accessibility.cancel, "取消 Sublime 导入"))
            .accessibilityIdentifier(Accessibility.cancel)
            Button(l("Import", "导入")) {
                Task { @MainActor in
                    isConfirming = true
                    let imported = await controller.confirm(token: presentation.token)
                    isConfirming = false
                    if imported {
                        onDismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(controller.isBusy)
            .accessibilityLabel(l(Accessibility.confirm, "确认 Sublime 导入"))
            .accessibilityIdentifier(Accessibility.confirm)
        }
    }

    @ViewBuilder
    private func previewDetails(_ preview: SublimeImportPreview) -> some View {
        switch preview {
        case let .project(value):
            section(l("Project folders", "项目文件夹"), values: value.roots.map(\.path))
            section(l("Exclusions", "排除项"), values: value.exclusions)
            section(l("Build systems", "构建系统"), values: value.buildSystems.map {
                "\($0.name): \($0.command) \($0.arguments.joined(separator: " "))"
                    .trimmingCharacters(in: .whitespaces)
            })
        case let .settings(value):
            section(l("Setting changes", "设置更改"), values: value.changes.map {
                "\($0.key.rawValue): \($0.oldValue) → \($0.newValue)"
            })
        case let .keymap(value):
            section(l("Key bindings", "快捷键绑定"), values: value.overrides.map { binding in
                let sequence = binding.binding?.sequence.map(\.displayString)
                    .joined(separator: " ") ?? l("Unbound", "未绑定")
                return "\(sequence) — \(binding.commandID)"
            })
            Text(l(
                "Inspected \(value.inspected); skipped \(value.skipped)"
                    + (value.wasTruncated ? "; input was truncated" : "") + ".",
                "已检查 \(value.inspected) 项；跳过 \(value.skipped) 项"
                    + (value.wasTruncated ? "；输入已截断" : "") + "。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .snippet(value):
            section(l("Snippet", "代码片段"), values: [
                l("Label: \(value.label)", "标签：\(value.label)"),
                l(
                    "Trigger: \(value.trigger ?? "None")",
                    "触发词：\(value.trigger ?? "无")"
                ),
                l("Scope: \(value.scope ?? "Any")", "作用域：\(value.scope ?? "任意")")
            ])
            Text(value.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case let .build(value):
            section(l("Build system", "构建系统"), values: [
                l("Name: \(value.system.name)", "名称：\(value.system.name)"),
                l(
                    "Command: \(value.system.command) \(value.system.arguments.joined(separator: " "))",
                    "命令：\(value.system.command) \(value.system.arguments.joined(separator: " "))"
                )
                    .trimmingCharacters(in: .whitespaces),
                l(
                    "Working directory: \(value.system.workingDirectory ?? "Workspace root")",
                    "工作目录：\(value.system.workingDirectory ?? "工作区根目录")"
                ),
                l(
                    "Uses shell: \(value.system.usesShell ? "Yes" : "No")",
                    "使用 shell：\(value.system.usesShell ? "是" : "否")"
                ),
                l("Variants: \(value.system.variants.count)", "变体：\(value.system.variants.count)")
            ])
            Text(l(
                "Importing this declaration does not run its command. Build execution has a separate approval.",
                "导入此声明不会运行其命令。执行构建仍需单独授权。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            Text(title).font(.headline)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func issueSummary(
        _ issue: SublimeImportPresentationIssue
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appLocale.localizedSublimeImportIssueTitle(issue.titleContent))
                .font(.headline)
                .foregroundStyle(.red)
            Text(appLocale.localizedSublimeImportIssue(issue.content))
                .foregroundStyle(.secondary)
        }
    }

    private func issueView(_ issue: SublimeImportPresentationIssue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            issueSummary(issue)
            Spacer()
            HStack {
                Spacer()
                Button(l("Close", "关闭")) {
                    controller.dismissIssue()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(l(Accessibility.dismissIssue, "关闭 Sublime 导入错误"))
                .accessibilityIdentifier(Accessibility.dismissIssue)
            }
        }
    }

    private var localizedStatusMessage: String {
        switch controller.status {
        case .idle:
            l("Ready to import from Sublime Text.", "已准备好从 Sublime Text 导入。")
        case let .requestingSource(kind):
            l(
                "Choose a Sublime \(kind.displayName.lowercased()) file.",
                "选择一个 Sublime \(localizedKindName(kind))文件。"
            )
        case let .parsing(kind):
            l(
                "Reading Sublime \(kind.displayName.lowercased()) preview…",
                "正在读取 Sublime \(localizedKindName(kind))预览…"
            )
        case let .awaitingConfirmation(kind):
            l(
                "Review the Sublime \(kind.displayName.lowercased()) preview.",
                "请检查 Sublime \(localizedKindName(kind))预览。"
            )
        case let .applying(kind):
            l(
                "Applying Sublime \(kind.displayName.lowercased())…",
                "正在应用 Sublime \(localizedKindName(kind))…"
            )
        case let .completed(kind):
            l(
                "Imported Sublime \(kind.displayName.lowercased()).",
                "已导入 Sublime \(localizedKindName(kind))。"
            )
        case let .cancelled(kind):
            l(
                "Cancelled Sublime \(kind.displayName.lowercased()) import.",
                "已取消导入 Sublime \(localizedKindName(kind))。"
            )
        case let .failed(kind):
            l(
                "Sublime \(kind.displayName.lowercased()) import failed.",
                "导入 Sublime \(localizedKindName(kind))失败。"
            )
        }
    }

    private func previewTitle(for kind: SublimeImportKind) -> String {
        l(
            "Import Sublime \(kind.displayName)?",
            "导入 Sublime \(localizedKindName(kind))？"
        )
    }

    private func previewMessage(for preview: SublimeImportPreview) -> String {
        switch preview {
        case let .project(value):
            let roots = value.roots.count
            let builds = value.buildSystems.count
            return l(
                "Import \(roots) project root\(roots == 1 ? "" : "s"), "
                    + "\(value.exclusions.count) exclusion pattern"
                    + "\(value.exclusions.count == 1 ? "" : "s"), and \(builds) "
                    + "declarative build system\(builds == 1 ? "" : "s")? "
                    + "Sublime plug-ins and code will not run.",
                "导入 \(roots) 个项目根目录、\(value.exclusions.count) 个排除模式和 "
                    + "\(builds) 个声明式构建系统？Sublime 插件和代码不会运行。"
            )
        case let .settings(value):
            return l(
                "Apply \(value.changes.count) supported setting change"
                    + "\(value.changes.count == 1 ? "" : "s")?",
                "应用 \(value.changes.count) 项受支持的设置更改？"
            )
        case let .keymap(value):
            return l(
                "Import \(value.overrides.count) supported key binding"
                    + "\(value.overrides.count == 1 ? "" : "s")? \(value.skipped) "
                    + "\(value.skipped == 1 ? "entry was" : "entries were") skipped.",
                "导入 \(value.overrides.count) 个受支持的快捷键绑定？"
                    + "已跳过 \(value.skipped) 项。"
            )
        case let .snippet(value):
            let englishTrigger = value.trigger.map { " (trigger: \($0))" } ?? ""
            let chineseTrigger = value.trigger.map { "（触发词：\($0)）" } ?? ""
            return l(
                "Import snippet ‘\(value.label)’\(englishTrigger)? Only declarative text, "
                    + "trigger, and scope are imported.",
                "导入代码片段“\(value.label)”\(chineseTrigger)？"
                    + "只会导入声明式文本、触发词和作用域。"
            )
        case let .build(value):
            let arguments = value.system.arguments.isEmpty
                ? "" : " " + value.system.arguments.joined(separator: " ")
            return l(
                "Import declarative build system ‘\(value.system.name)’? Command: "
                    + "\(value.system.command)\(arguments). Importing will not run it; "
                    + "execution still requires separate approval.",
                "导入声明式构建系统“\(value.system.name)”？命令："
                    + "\(value.system.command)\(arguments)。导入不会运行该命令；"
                    + "执行时仍需单独授权。"
            )
        }
    }

    private func localizedKindName(_ kind: SublimeImportKind) -> String {
        switch kind {
        case .project: "项目"
        case .settings: "设置"
        case .keymap: "快捷键映射"
        case .snippet: "代码片段"
        case .build: "构建系统"
        }
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }
}
