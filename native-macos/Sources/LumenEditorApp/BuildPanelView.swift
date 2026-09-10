import AppKit
import SwiftUI

struct BuildPanelView: View {
    typealias OpenProblem = @MainActor (BuildProblem) async -> Bool

    @ObservedObject private var controller: BuildController
    private let buildSystems: [BuildSystem]
    private let openProblem: OpenProblem
    private let onDismiss: () -> Void

    @State private var selectedSystemName: String?
    @State private var selectedVariantName: String?
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        controller: BuildController,
        buildSystems: [BuildSystem] = [],
        openProblem: @escaping OpenProblem = { _ in false },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.buildSystems = buildSystems
        self.openProblem = openProblem
        self.onDismiss = onDismiss
        _selectedSystemName = State(initialValue: controller.selectedBuildSystem?.name)
        _selectedVariantName = State(initialValue: controller.selectedBuildVariantName)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let issue = controller.issue {
                issueBanner(issue)
                Divider()
            }
            output
            if !controller.problems.isEmpty {
                Divider()
                problems
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 520, idealWidth: 760, maxWidth: 1_100)
        .frame(minHeight: 300, idealHeight: 480, maxHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "构建输出"))
        .accessibilityIdentifier(AppAccessibility.id("build panel"))
        .onChange(of: controller.exitCode) { _, code in
            guard let code else { return }
            AppAccessibility.announce(
                code == 0
                    ? l("Build completed successfully", "构建成功完成")
                    : l("Build exited with code \(code)", "构建退出，代码为 \(code)"),
                priority: code == 0 ? .medium : .high
            )
        }
        .onChange(of: controller.issue?.id) { _, issueID in
            guard issueID != nil, let issue = controller.issue else { return }
            AppAccessibility.announce(
                issue.localizedTitle(locale: appLocale) + ": "
                    + issue.localizedMessage(locale: appLocale),
                priority: .high
            )
        }
        .onExitCommand(perform: onDismiss)
        .confirmationDialog(
            controller.pendingApproval?.title(locale: appLocale)
                ?? l("Confirm External Build", "确认外部构建"),
            isPresented: approvalBinding,
            presenting: controller.pendingApproval
        ) { _ in
            Button(l("Run Build", "运行构建")) {
                Task { await controller.confirmPendingBuild() }
            }
                .keyboardShortcut(.defaultAction)
            Button(l("Cancel", "取消"), role: .cancel) {
                controller.declinePendingBuild()
            }
        } message: { request in
            Text(approvalMessage(request))
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hammer")
                    .accessibilityHidden(true)
                TextField(
                    l("Build command, for example swift test", "构建命令，例如 swift test"),
                    text: $controller.freeFormCommand
                )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await controller.requestFreeFormBuild() } }
                    .accessibilityLabel(l(Accessibility.command, "构建命令"))
                    .accessibilityIdentifier(AppAccessibility.id("build command"))
                Button(appLocale.localized(.run)) {
                    Task { await controller.requestFreeFormBuild() }
                }
                    .disabled(!controller.canRun || controller.freeFormCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(l(Accessibility.run, "运行构建"))
                    .accessibilityIdentifier(AppAccessibility.id("build run"))
                Button(appLocale.localized(.stop)) { Task { await controller.cancel() } }
                    .disabled(!controller.isRunning || controller.isCancelling)
                    .accessibilityLabel(l(Accessibility.stop, "停止构建"))
                    .accessibilityIdentifier(AppAccessibility.id("build stop"))
                Button(l("Clear", "清除")) { controller.clearOutput() }
                    .disabled(controller.logEntries.isEmpty)
                    .accessibilityLabel(l(Accessibility.clear, "清除构建输出"))
                    .accessibilityIdentifier(AppAccessibility.id("build clear"))
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(l(Accessibility.close, "关闭构建面板"))
                    .accessibilityIdentifier(AppAccessibility.id("build close"))
            }

            if !buildSystems.isEmpty {
                HStack(spacing: 8) {
                    Picker(l("Build System", "构建系统"), selection: $selectedSystemName) {
                        Text(l("Select Build System", "选择构建系统")).tag(String?.none)
                        ForEach(buildSystems) { system in
                            Text(system.name).tag(Optional(system.name))
                        }
                    }
                    .accessibilityLabel(l(Accessibility.system, "构建系统"))
                    .accessibilityIdentifier(AppAccessibility.id("build system"))
                    Picker(l("Variant", "变体"), selection: $selectedVariantName) {
                        Text(l("Default", "默认")).tag(String?.none)
                        ForEach(selectedSystem?.variants ?? []) { variant in
                            Text(variant.name).tag(Optional(variant.name))
                        }
                    }
                    .disabled(selectedSystem == nil || selectedSystem?.variants.isEmpty == true)
                    .accessibilityLabel(l(Accessibility.variant, "构建变体"))
                    .accessibilityIdentifier(AppAccessibility.id("build variant"))
                    Button(l("Run Selected", "运行所选项")) {
                        guard let selectedSystem else { return }
                        controller.selectBuildSystem(
                            selectedSystem, variantName: selectedVariantName
                        )
                        Task { await controller.runSelectedBuildSystem() }
                    }
                    .disabled(selectedSystem == nil || !controller.canRun)
                    .accessibilityIdentifier(AppAccessibility.id("build run selected"))
                }
                .onChange(of: selectedSystemName) { _, _ in selectedVariantName = nil }
            }
        }
        .padding(10)
    }

    private var output: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if controller.wasOutputTruncated {
                    Text(l(
                        "[Earlier build output discarded]\n",
                        "[较早的构建输出已丢弃]\n"
                    ))
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.logEntries) { entry in
                    Text(entry.text)
                        .foregroundStyle(entry.stream == .standardError ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel(l(Accessibility.output, "构建日志"))
        .accessibilityIdentifier(AppAccessibility.id("build output"))
        .accessibilityValue(controller.outputText)
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l(
                "PROBLEMS (\(controller.problems.count))",
                "问题（\(controller.problems.count)）"
            ))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.problems) { problem in
                        Button { Task { _ = await openProblem(problem) } } label: {
                            HStack(spacing: 7) {
                                Image(systemName: icon(for: problem.severity))
                                    .foregroundStyle(color(for: problem.severity))
                                Text("\(problem.url.lastPathComponent):\(problem.line):\(problem.column)")
                                    .font(.system(.caption, design: .monospaced))
                                Text(problem.message).lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l(
                            "\(severityName(problem.severity)), \(problem.url.lastPathComponent), line \(problem.line), column \(problem.column), \(problem.message)",
                            "\(severityName(problem.severity))，\(problem.url.lastPathComponent)，第 \(problem.line) 行，第 \(problem.column) 列，\(problem.message)"
                        ))
                    }
                }
            }
            .frame(maxHeight: 150)
            .accessibilityLabel(l(Accessibility.problems, "构建问题"))
            .accessibilityIdentifier(AppAccessibility.id("build problems"))
        }
        .padding(8)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if controller.isCancelling {
                ProgressView().controlSize(.small)
                Text(l("Stopping build…", "正在停止构建…"))
            } else if controller.isRunning {
                ProgressView().controlSize(.small)
                Text(l("Building…", "正在构建…"))
            } else if let code = controller.exitCode {
                Text(code == 0
                    ? l("Build completed successfully.", "构建成功完成。")
                    : l("Build exited with code \(code).", "构建退出，代码为 \(code)。"))
            } else {
                Text(controller.workspaceRoot == nil
                    ? l("Open a workspace to build.", "请打开工作区以进行构建。")
                    : l("Ready", "就绪"))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .accessibilityLabel(l(Accessibility.status, "构建状态"))
        .accessibilityIdentifier(AppAccessibility.id("build status"))
    }

    private func issueBanner(_ issue: BuildPresentationIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.localizedTitle(locale: appLocale)).font(.callout.weight(.semibold))
                Text(issue.localizedMessage(locale: appLocale))
                    .font(.caption).textSelection(.enabled)
            }
            Spacer()
            Button { controller.dismissIssue() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(l(Accessibility.dismissError, "关闭构建错误"))
                .accessibilityIdentifier(AppAccessibility.id("build dismiss error"))
        }
        .padding(10)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.18 : 0.08))
    }

    private var selectedSystem: BuildSystem? {
        guard let selectedSystemName else { return nil }
        return buildSystems.first { $0.name == selectedSystemName }
    }

    private var approvalBinding: Binding<Bool> {
        Binding(
            get: { controller.pendingApproval != nil },
            set: { if !$0 { controller.declinePendingBuild() } }
        )
    }

    private func approvalMessage(_ request: BuildApprovalRequest) -> String {
        appLocale.localizedApprovalDescription(request.identityDescription)
            + l(
                "\nThis approval lasts only for the current window session and this exact configuration.",
                "\n此授权仅适用于当前窗口会话及这一精确配置。"
            )
    }

    private func severityName(_ severity: BuildProblem.Severity) -> String {
        switch severity {
        case .error: return l("error", "错误")
        case .warning: return l("warning", "警告")
        case .info: return l("information", "信息")
        }
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    private func icon(for severity: BuildProblem.Severity) -> String {
        switch severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for severity: BuildProblem.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    enum Accessibility {
        static let panel = "Build Output"
        static let command = "Build Command"
        static let run = "Run Build"
        static let stop = "Stop Build"
        static let clear = "Clear Build Output"
        static let close = "Close Build Panel"
        static let system = "Build System"
        static let variant = "Build Variant"
        static let output = "Build Log"
        static let problems = "Build Problems"
        static let status = "Build Status"
        static let dismissError = "Dismiss Build Error"
    }
}
