import AppKit
import SwiftUI

/// Accessible plain-text presentation for a real PTY-backed terminal. Process
/// ownership and approval remain in `TerminalController`; dismissing this view
/// only hides it. The host awaits `close()` when permanently discarding the
/// window/controller.
struct TerminalPanelView: View {
    @ObservedObject private var controller: TerminalController
    private let onDismiss: () -> Void

    @FocusState private var inputIsFocused: Bool
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        controller: TerminalController,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
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
            Divider()
            inputRow
            Divider()
            statusBar
        }
        .frame(minWidth: 520, idealWidth: 760, maxWidth: 1_100)
        .frame(minHeight: 300, idealHeight: 480, maxHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { resizeTerminal(for: geometry.size) }
                    .onChange(of: geometry.size) { _, size in resizeTerminal(for: size) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "终端"))
        .accessibilityIdentifier(AppAccessibility.id("terminal panel"))
        .onAppear { focusPreferredControl() }
        .onChange(of: controller.state) { _, _ in
            focusPreferredControl()
            AppAccessibility.announce(statusText)
        }
        .onChange(of: controller.issue?.id) { _, issueID in
            guard issueID != nil, let issue = controller.issue else { return }
            AppAccessibility.announce(
                appLocale.localizedTerminalIssueTitle(issue.titleContent) + ": "
                    + appLocale.localizedTerminalIssue(issue.content),
                priority: .high
            )
        }
        .onExitCommand(perform: dismissPanel)
        .confirmationDialog(
            l("Start Project Terminal?", "启动项目终端？"),
            isPresented: approvalBinding,
            presenting: controller.pendingApproval
        ) { _ in
            Button(l("Start Terminal", "启动终端")) {
                Task { await controller.confirmPendingStart() }
            }
            .keyboardShortcut(.defaultAction)
            Button(l("Cancel", "取消"), role: .cancel) {
                controller.declinePendingStart()
            }
        } message: { request in
            Text(approvalMessage(request))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .accessibilityHidden(true)
            Text(appLocale.localized(.terminal))
                .font(.headline)
            Spacer()
            Button(l("Start", "启动")) { Task { await controller.requestStart() } }
                .disabled(!controller.canStart)
                .accessibilityLabel(l(Accessibility.start, "启动终端"))
                .accessibilityIdentifier(AppAccessibility.id("terminal start"))
            Button(appLocale.localized(.stop)) { Task { await controller.stop() } }
                .disabled(!controller.canStop)
                .accessibilityLabel(l(Accessibility.stop, "停止终端"))
                .accessibilityIdentifier(AppAccessibility.id("terminal stop"))
            Button(l("Clear", "清除")) { controller.clearOutput() }
                .disabled(controller.logEntries.isEmpty)
                .accessibilityLabel(l(Accessibility.clear, "清除终端输出"))
                .accessibilityIdentifier(AppAccessibility.id("terminal clear"))
            Button(action: dismissPanel) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(l(Accessibility.close, "关闭终端面板"))
                .accessibilityIdentifier(AppAccessibility.id("terminal close"))
        }
        .padding(10)
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if controller.wasOutputTruncated {
                        Text(l(
                            "[Earlier terminal output discarded]\n",
                            "[较早的终端输出已丢弃]\n"
                        ))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.logEntries) { entry in
                        Text(entry.text(locale: appLocale))
                            .foregroundStyle(color(for: entry.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
            }
            .onChange(of: controller.logEntries.last?.id) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel(l(Accessibility.output, "终端输出"))
        .accessibilityIdentifier(AppAccessibility.id("terminal output"))
        .accessibilityValue(controller.outputText(locale: appLocale))
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                l(
                    "Type a command and press Return; use Interrupt for Ctrl-C",
                    "输入命令并按下 Return；使用“中断”发送 Ctrl-C"
                ),
                text: $controller.input
            )
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .focused($inputIsFocused)
            .disabled(!controller.isRunning)
            .onSubmit { Task { await controller.submitInput() } }
            .accessibilityLabel(l(Accessibility.input, "终端命令输入"))
            .accessibilityHint(l(
                "Press Return to send the line, including an empty line. Use Interrupt to send Ctrl-C to the foreground command.",
                "按 Return 发送当前行，空行也会发送。使用“中断”向前台命令发送 Ctrl-C。"
            ))
            .accessibilityIdentifier(AppAccessibility.id("terminal input"))

            Button(l("Send", "发送")) { Task { await controller.submitInput() } }
                .disabled(!controller.isRunning)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(l(Accessibility.send, "发送终端输入"))
                .accessibilityIdentifier(AppAccessibility.id("terminal send"))
            Button(l("Interrupt", "中断")) { Task { await controller.sendInterrupt() } }
                .disabled(!controller.isRunning)
                .accessibilityLabel(l(Accessibility.interrupt, "中断终端命令"))
                .accessibilityIdentifier(AppAccessibility.id("terminal interrupt"))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if controller.isStarting || controller.isStopping {
                ProgressView().controlSize(.small)
                Text(controller.isStarting
                    ? l("Starting terminal…", "正在启动终端…")
                    : l("Stopping terminal…", "正在停止终端…"))
            } else {
                Text(statusText)
            }
            Spacer()
            if let sessionID = controller.activeSessionID {
                Text(sessionID)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .accessibilityLabel(l(Accessibility.status, "终端状态"))
        .accessibilityValue(statusText)
        .accessibilityIdentifier(AppAccessibility.id("terminal status"))
    }

    private func issueBanner(_ issue: TerminalPresentationIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocale.localizedTerminalIssueTitle(issue.titleContent))
                    .font(.callout.weight(.semibold))
                Text(appLocale.localizedTerminalIssue(issue.content))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Spacer()
            Button { controller.dismissIssue() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(l(Accessibility.dismissError, "关闭终端错误"))
                .accessibilityIdentifier(AppAccessibility.id("terminal dismiss error"))
        }
        .padding(10)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.18 : 0.08))
    }

    private var approvalBinding: Binding<Bool> {
        Binding(
            get: { controller.pendingApproval != nil },
            set: { if !$0 { controller.declinePendingStart() } }
        )
    }

    private var statusText: String {
        switch controller.state {
        case .idle:
            if let code = controller.lastExitCode {
                return code == 0
                    ? l("Terminal exited.", "终端已退出。")
                    : l("Terminal exited with code \(code).", "终端退出，代码为 \(code)。")
            }
            return controller.workspaceRoot == nil
                ? l("Open a workspace to start the terminal.", "请打开工作区以启动终端。")
                : l("Terminal stopped.", "终端已停止。")
        case .awaitingApproval:
            return l("Waiting for approval.", "正在等待授权。")
        case .starting:
            return l("Starting terminal…", "正在启动终端…")
        case .running:
            return l(
                "Terminal running (PTY; accessible plain-text display).",
                "终端正在运行（PTY；无障碍纯文本显示）。"
            )
        case .stopping:
            return l("Stopping terminal…", "正在停止终端…")
        }
    }

    private func approvalMessage(_ request: TerminalApprovalRequest) -> String {
        appLocale.localizedApprovalDescription(request.identityDescription) + "\n\n"
            + l(
                "This starts a local shell. Commands can read, modify, or delete workspace files and may access the network. "
                    + "Approval is limited to this window session and this exact configuration.",
                "这将启动本地 shell。命令可以读取、修改或删除工作区文件，也可能访问网络。"
                    + "授权仅限当前窗口会话及这一精确配置。"
            )
    }

    private func color(for kind: TerminalLogEntry.Kind) -> Color {
        switch kind {
        case .standardOutput: return .primary
        case .standardError: return .red
        case .status: return .secondary
        }
    }

    private func focusPreferredControl() {
        if controller.isRunning { inputIsFocused = true }
    }

    private func resizeTerminal(for size: CGSize) {
        // The output uses the system caption monospace font. These metrics are
        // intentionally conservative: PTY consumers receive a useful viewport
        // while the accessible log remains free to wrap at platform font sizes.
        let columns = max(20, min(300, Int((size.width - 24) / 7.2)))
        let rows = max(4, min(200, Int((size.height - 118) / 15)))
        Task { await controller.resize(columns: columns, rows: rows) }
    }

    /// Close-button and Escape behavior matches the Electron panel: presentation
    /// is hidden while the controller-owned shell continues running.
    func dismissPanel() { onDismiss() }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    enum Accessibility {
        static let panel = "Terminal"
        static let start = "Start Terminal"
        static let stop = "Stop Terminal"
        static let clear = "Clear Terminal Output"
        static let close = "Close Terminal Panel"
        static let output = "Terminal Output"
        static let input = "Terminal Command Input"
        static let send = "Send Terminal Input"
        static let interrupt = "Interrupt Terminal Command"
        static let status = "Terminal Status"
        static let dismissError = "Dismiss Terminal Error"
    }
}
