import AppKit
import Foundation
import LumenEditorCore
import SwiftUI

struct LanguageServerNavigationTarget: Equatable, Sendable {
    let url: URL
    let line: Int
    let column: Int

    init?(_ location: LanguageLocation) {
        guard !location.filePath.isEmpty, location.filePath.hasPrefix("/") else {
            return nil
        }
        url = URL(fileURLWithPath: location.filePath).standardizedFileURL
        line = Self.oneBased(location.line)
        column = Self.oneBased(location.character)
    }

    private static func oneBased(_ value: Int) -> Int {
        value >= Int.max ? Int.max : max(0, value) + 1
    }
}

enum LanguageServerResultPresentation {
    static func requiresPanel(
        method: LanguageServerMethod, result: LanguageServerInteractiveResult
    ) -> Bool {
        switch method {
        case .definition:
            return (result.locations?.count ?? 0) != 1
        case .completion, .hover, .references:
            return true
        case .rename:
            return false
        }
    }
}

/// A read-only inspector for persistent language-server instances. Explicit
/// lifecycle actions flow through `LanguageServerController`; closing the
/// inspector only dismisses it and does not stop a selected service.
struct LanguageServerPanelView: View {
    private struct DisplayedLog: Identifiable {
        struct ID: Hashable {
            let key: LanguageServerInstanceKey
            let generation: UInt64
            let sequence: UInt64
        }

        let id: ID
        let entry: LanguageServerLogEntry
    }

    @ObservedObject private var controller: LanguageServerController
    private let onOpenLocation: @MainActor (LanguageLocation) -> Void
    private let onDismiss: () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var selectedKey: LanguageServerInstanceKey?

    init(
        controller: LanguageServerController,
        onOpenLocation: @escaping @MainActor (LanguageLocation) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onOpenLocation = onOpenLocation
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
            HSplitView {
                services
                    .frame(minWidth: 210, idealWidth: 260, maxWidth: 340)
                details
                    .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 640, idealWidth: 860, maxWidth: 1_200)
        .frame(minHeight: 360, idealHeight: 560, maxHeight: 820)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.panel, "语言服务器"))
        .accessibilityIdentifier(AppAccessibility.id("language server panel"))
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .onAppear(perform: repairSelection)
        .onChange(of: controller.statuses.map(\.key)) { _, _ in
            repairSelection()
        }
        .onChange(of: controller.interactiveResultRevision) { _, _ in
            selectInteractiveResultServerIfAvailable()
            AppAccessibility.announce(
                l("Language server result updated", "语言服务器结果已更新")
            )
        }
        .onChange(of: controller.issue?.id) { _, issueID in
            guard issueID != nil, let issue = controller.issue else { return }
            AppAccessibility.announce(
                appLocale.localizedLanguageServerIssueTitle(issue.titleContent) + ": "
                    + appLocale.localizedLanguageServerIssue(issue.content),
                priority: .high
            )
        }
        .onExitCommand(perform: close)
        .confirmationDialog(
            l("Confirm Language Server", "确认语言服务器"),
            isPresented: approvalBinding,
            presenting: controller.pendingApproval
        ) { _ in
            Button(l("Run Language Server", "运行语言服务器")) {
                Task { await controller.confirmPendingApproval() }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AppAccessibility.id("language server approval run"))
            Button(l("Cancel", "取消"), role: .cancel) {
                controller.declinePendingApproval()
            }
            .accessibilityIdentifier(AppAccessibility.id("language server approval cancel"))
        } message: { request in
            Text(approvalMessage(request))
        }
        .accessibilityHint(
            controller.pendingApproval == nil
                ? ""
                : l(Accessibility.approval, "允许前请核对准确的语言服务器命令。")
        )
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .accessibilityHidden(true)
            Text(l("Language Servers", "语言服务器"))
                .font(.headline)
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(l(Accessibility.summary, "语言服务器摘要"))
                .accessibilityValue(summaryText)
                .accessibilityIdentifier(AppAccessibility.id("language server summary"))
            Spacer()
            Button(l("Restart", "重新启动")) {
                guard let selectedKey else { return }
                Task { @MainActor in await controller.restart(selectedKey) }
            }
            .disabled(selectedStatus == nil)
            .accessibilityLabel(l(Accessibility.restart, "重新启动语言服务器"))
            .accessibilityIdentifier(AppAccessibility.id("language server restart"))

            Button(appLocale.localized(.stop)) {
                guard let selectedKey else { return }
                Task { @MainActor in await controller.stop(selectedKey) }
            }
            .disabled(!canStopSelected)
            .accessibilityLabel(l(Accessibility.stop, "停止语言服务器"))
            .accessibilityIdentifier(AppAccessibility.id("language server stop"))

            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(l(Accessibility.close, "关闭语言服务器面板"))
                .accessibilityIdentifier(AppAccessibility.id("language server close"))
        }
        .padding(10)
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l("SERVICES", "服务"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if controller.statuses.isEmpty {
                ContentUnavailableView(
                    l("No Language Servers", "没有语言服务器"),
                    systemImage: "network.slash",
                    description: Text(l(
                        "Language servers appear here after a document starts one.",
                        "文档启动语言服务器后，它会显示在这里。"
                    ))
                )
                .accessibilityIdentifier(AppAccessibility.id("language server services empty"))
            } else {
                List(selection: $selectedKey) {
                    ForEach(controller.statuses, id: \.key) { status in
                        serviceRow(status)
                            .tag(status.key)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier(AppAccessibility.id("language server services list"))
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.services, "语言服务器服务列表"))
        .accessibilityIdentifier(AppAccessibility.id("language server services"))
    }

    private func serviceRow(_ status: LanguageServerStatus) -> some View {
        let state = stateName(status.state)
        return HStack(spacing: 8) {
            Circle()
                .fill(color(for: status.state))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.config.command)
                    .lineLimit(1)
                Text(status.root.lastPathComponent.isEmpty
                     ? status.root.path : status.root.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(state)
                .font(.caption2)
                .foregroundStyle(stateForeground(for: status.state))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(status.config.command), \(state), \(status.root.path)"
        )
        .accessibilityIdentifier(AppAccessibility.id(
            "language server service \(status.key.description)"
        ))
    }

    @ViewBuilder
    private var details: some View {
        if let selectedStatus {
            VStack(alignment: .leading, spacing: 0) {
                serviceDetails(selectedStatus)
                if shouldShowInteractiveResult(for: selectedStatus.key) {
                    Divider()
                    interactiveResultSection
                }
                Divider()
                diagnosticsSection(selectedStatus)
                Divider()
                logSection(selectedStatus)
            }
        } else if controller.interactiveResult != nil {
            VStack(alignment: .leading, spacing: 0) {
                interactiveResultSection
                Spacer(minLength: 0)
            }
        } else {
            ContentUnavailableView(
                l("Select a Language Server", "选择语言服务器"),
                systemImage: "network",
                description: Text(l(
                    "Choose a service to inspect its capabilities, diagnostics, and log.",
                    "选择一项服务以查看其功能、诊断和日志。"
                ))
            )
            .accessibilityIdentifier(AppAccessibility.id("language server details empty"))
        }
    }

    private func serviceDetails(_ status: LanguageServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.config.command)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(stateName(status.state))
                    .foregroundStyle(stateForeground(for: status.state))
                    .accessibilityLabel(l(
                        Accessibility.selectedStatus,
                        "所选语言服务器状态"
                    ))
                    .accessibilityValue(stateName(status.state))
                    .accessibilityIdentifier(AppAccessibility.id(
                        "language server selected status"
                    ))
            }
            Text(status.root.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let message = status.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        status.state == .failed ? errorForeground : Color.secondary
                    )
                    .textSelection(.enabled)
            }
            Group {
                if status.capabilities.isEmpty {
                    Text(l("Capabilities: none reported", "功能：未报告"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(l(
                        "Capabilities: \(status.capabilities.joined(separator: ", "))",
                        "功能：\(status.capabilities.joined(separator: ", "))"
                    ))
                }
            }
            .font(.caption)
            .textSelection(.enabled)
            .accessibilityLabel(l(Accessibility.capabilities, "语言服务器功能"))
            .accessibilityValue(capabilitiesAccessibilityValue(status.capabilities))
            .accessibilityIdentifier(AppAccessibility.id("language server capabilities"))
        }
        .padding(10)
        .accessibilityIdentifier(AppAccessibility.id("language server details"))
    }

    @ViewBuilder
    private var interactiveResultSection: some View {
        if let result = controller.interactiveResult,
           let method = controller.interactiveResultMethod {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(interactiveResultHeading(method: method, result: result))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(l("Clear Result", "清除结果")) {
                        controller.clearInteractiveResult()
                    }
                    .controlSize(.small)
                    .accessibilityLabel(l(
                        Accessibility.clearInteractiveResult,
                        "清除语言服务器交互结果"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id(
                        "language server clear interactive result"
                    ))
                }

                switch method {
                case .completion:
                    completionResults(result.completions ?? [])
                case .hover:
                    hoverResult(result.hover)
                case .definition, .references:
                    locationResults(result.locations ?? [], method: method)
                case .rename:
                    Text(l(
                        "Rename results are reviewed before edits are applied.",
                        "重命名结果会在应用编辑前单独审阅。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(minHeight: 90, idealHeight: 180, maxHeight: 300)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l(
                Accessibility.interactiveResults,
                "语言服务器交互结果"
            ))
            .accessibilityIdentifier(AppAccessibility.id(
                "language server interactive results"
            ))
        }
    }

    @ViewBuilder
    private func completionResults(_ items: [LanguageCompletionItem]) -> some View {
        if items.isEmpty {
            emptyInteractiveResult(
                english: "No completions returned", chinese: "未返回补全项"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        completionRow(items[index], index: index)
                        if index < items.count - 1 { Divider() }
                    }
                }
            }
            .accessibilityIdentifier(AppAccessibility.id(
                "language server completion results"
            ))
        }
    }

    private func completionRow(
        _ item: LanguageCompletionItem, index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
            if let detail = nonempty(item.detail) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let documentation = nonempty(item.documentation) {
                Text(documentation)
                    .font(.caption)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if let insertText = nonempty(item.insertText), insertText != item.label {
                Text(l("Insert: \(insertText)", "插入：\(insertText)"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(completionAccessibilityLabel(item))
        .accessibilityIdentifier(AppAccessibility.id(
            "language server completion \(controller.interactiveResultRevision) \(index)"
        ))
    }

    @ViewBuilder
    private func hoverResult(_ hover: LanguageHover?) -> some View {
        if let text = hover.flatMap({ nonempty($0.text) }) {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .accessibilityLabel(l(Accessibility.hoverResult, "悬停信息结果"))
            .accessibilityValue(text)
            .accessibilityIdentifier(AppAccessibility.id(
                "language server hover result"
            ))
        } else {
            emptyInteractiveResult(
                english: "No hover information returned", chinese: "未返回悬停信息"
            )
        }
    }

    @ViewBuilder
    private func locationResults(
        _ locations: [LanguageLocation], method: LanguageServerMethod
    ) -> some View {
        if locations.isEmpty {
            emptyInteractiveResult(
                english: method == .definition
                    ? "No definitions returned" : "No references returned",
                chinese: method == .definition
                    ? "未返回定义位置" : "未返回引用位置"
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(locations.indices, id: \.self) { index in
                            locationRow(locations[index], method: method, index: index)
                                .id(index)
                        }
                    }
                }
                .onChange(of: controller.interactiveResultRevision) { _, _ in
                    proxy.scrollTo(0, anchor: .top)
                }
            }
            .accessibilityIdentifier(AppAccessibility.id(
                "language server location results"
            ))
        }
    }

    private func locationRow(
        _ location: LanguageLocation, method: LanguageServerMethod, index: Int
    ) -> some View {
        let url = URL(fileURLWithPath: location.filePath)
        let fileName = url.lastPathComponent.isEmpty ? location.filePath : url.lastPathComponent
        let position = locationPosition(location)
        return Button {
            onOpenLocation(location)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: method == .definition
                    ? "arrow.turn.down.right" : "text.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fileName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(position)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(location.filePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .disabled(LanguageServerNavigationTarget(location) == nil)
        .accessibilityLabel(locationAccessibilityLabel(location, method: method))
        .accessibilityHint(l(
            "Opens this location and records it in navigation history.",
            "打开此位置并将其记录到导航历史。"
        ))
        .accessibilityIdentifier(AppAccessibility.id(
            "language server location \(controller.interactiveResultRevision) \(index)"
        ))
    }

    private func emptyInteractiveResult(english: String, chinese: String) -> some View {
        Text(l(english, chinese))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityIdentifier(AppAccessibility.id(
                "language server interactive result empty"
            ))
    }

    private func diagnosticsSection(_ status: LanguageServerStatus) -> some View {
        let entries = controller.diagnostics(for: status.key)
        return VStack(alignment: .leading, spacing: 4) {
            Text(l(
                "DIAGNOSTICS (\(entries.count))",
                "诊断（\(entries.count)）"
            ))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text(l("No diagnostics", "没有诊断"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { entry in diagnosticRow(entry) }
                    }
                }
            }
        }
        .padding(10)
        .frame(minHeight: 90, idealHeight: 150, maxHeight: 220)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.diagnostics, "语言服务器诊断"))
        .accessibilityValue(diagnosticsCountText(entries.count))
        .accessibilityIdentifier(AppAccessibility.id("language server diagnostics"))
    }

    private func diagnosticRow(_ entry: LanguageServerDiagnosticEntry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon(for: entry.diagnostic.severity))
                .foregroundStyle(color(for: entry.diagnostic.severity))
                .accessibilityHidden(true)
            Text(
                "\(URL(fileURLWithPath: entry.filePath).lastPathComponent):"
                    + "\(entry.diagnostic.line):\(entry.diagnostic.column)"
            )
                .font(.system(.caption, design: .monospaced))
            Text(entry.diagnostic.message)
                .font(.caption)
                .lineLimit(3)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(diagnosticAccessibilityLabel(entry))
        .accessibilityIdentifier(AppAccessibility.id(
            "language server diagnostic \(entry.id.revision) \(entry.id.index)"
        ))
    }

    private func logSection(_ status: LanguageServerStatus) -> some View {
        let entries = controller.logs(for: status.key)
        let displayed = entries.map { entry in
            DisplayedLog(
                id: .init(
                    key: entry.key, generation: entry.generation, sequence: entry.sequence
                ),
                entry: entry
            )
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l("LOG (\(entries.count))", "日志（\(entries.count)）"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if controller.wasLogTruncated {
                    Text(l("Earlier entries discarded", "较早的记录已丢弃"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l("Clear", "清除")) { controller.clearLogs() }
                    .disabled(controller.logEntries.isEmpty)
                    .controlSize(.small)
                    .accessibilityLabel(l(Accessibility.clearLog, "清除语言服务器日志"))
                    .accessibilityIdentifier(AppAccessibility.id("language server clear log"))
            }
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if entries.isEmpty {
                            Text(l("No log output", "没有日志输出"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(displayed) { displayedEntry in
                                Text(logText(displayedEntry.entry))
                                    .foregroundStyle(color(for: displayedEntry.entry.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(displayedEntry.id)
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                }
                .onChange(of: displayed.last?.id) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityIdentifier(AppAccessibility.id("language server log output"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.log, "语言服务器日志"))
        .accessibilityValue(entries.map(\.text).joined(separator: "\n"))
        .accessibilityIdentifier(AppAccessibility.id("language server log"))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if controller.isInteractiveRequestRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(l(
                        "Running language server request",
                        "正在运行语言服务器请求"
                    ))
                    .accessibilityIdentifier(AppAccessibility.id(
                        "language server request progress"
                    ))
                Text(interactiveRequestStatus)
            } else {
                Text(summaryText)
            }
            Spacer()
            if !controller.diagnostics.isEmpty {
                Text(diagnosticsCountText(controller.diagnostics.count))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .accessibilityLabel(l(Accessibility.statusBar, "语言服务器面板状态"))
        .accessibilityValue(statusAccessibilityValue)
        .accessibilityIdentifier(AppAccessibility.id("language server status"))
    }

    private func issueBanner(_ issue: LanguageServerPresentationIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(warningForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocale.localizedLanguageServerIssueTitle(issue.titleContent))
                    .font(.callout.weight(.semibold))
                Text(appLocale.localizedLanguageServerIssue(issue.content))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Spacer()
            Button { controller.dismissIssue() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(l(
                    Accessibility.dismissError,
                    "忽略语言服务器错误"
                ))
                .accessibilityIdentifier(AppAccessibility.id(
                    "language server dismiss error"
                ))
        }
        .padding(10)
        .background(Color.orange.opacity(colorSchemeContrast == .increased ? 0.18 : 0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l(Accessibility.error, "语言服务器错误"))
        .accessibilityIdentifier(AppAccessibility.id("language server error"))
    }

    private var selectedStatus: LanguageServerStatus? {
        guard let selectedKey else { return nil }
        return controller.status(for: selectedKey)
    }

    private var approvalBinding: Binding<Bool> {
        Binding(
            get: { controller.pendingApproval != nil },
            set: { if !$0 { controller.declinePendingApproval() } }
        )
    }

    private var canStopSelected: Bool {
        guard let state = selectedStatus?.state else { return false }
        switch state {
        case .starting, .running, .restarting, .stopping:
            return true
        case .stopped, .failed:
            return false
        }
    }

    private var summaryText: String {
        let total = controller.statuses.count
        return l(
            "\(total) \(total == 1 ? "server" : "servers"), "
                + "\(controller.runningServerCount) running",
            "\(total) 个服务器，\(controller.runningServerCount) 个正在运行"
        )
    }

    private func repairSelection() {
        if let selectedKey, controller.status(for: selectedKey) != nil { return }
        selectedKey = controller.statuses.first?.key
        selectInteractiveResultServerIfAvailable()
    }

    private func selectInteractiveResultServerIfAvailable() {
        guard let key = controller.interactiveResultKey,
              controller.status(for: key) != nil else { return }
        selectedKey = key
    }

    private func shouldShowInteractiveResult(
        for key: LanguageServerInstanceKey
    ) -> Bool {
        guard controller.interactiveResult != nil else { return false }
        guard let resultKey = controller.interactiveResultKey else { return true }
        return resultKey == key || controller.status(for: resultKey) == nil
    }

    private func close() {
        onDismiss()
    }

    private func logText(_ entry: LanguageServerLogEntry) -> String {
        "[\(logLevelName(entry.level))] [\(logStreamName(entry.stream))] \(entry.text)"
    }

    private func approvalMessage(_ request: LanguageServerApprovalRequest) -> String {
        appLocale.localizedApprovalDescription(request.identityDescription)
            + l(
                "\nThis approval lasts only for the current window session.",
                "\n此授权仅在当前窗口会话中有效。"
            )
    }

    private var interactiveRequestStatus: String {
        guard let method = controller.activeInteractiveMethod else {
            return l("Running request…", "正在运行请求…")
        }
        return l(
            "Running \(method.rawValue)…",
            "正在运行\(interactiveMethodName(method))…"
        )
    }

    private var statusAccessibilityValue: String {
        var parts = [controller.isInteractiveRequestRunning ? interactiveRequestStatus : summaryText]
        if !controller.diagnostics.isEmpty {
            parts.append(diagnosticsCountText(controller.diagnostics.count))
        }
        return parts.joined(separator: appLocale.isSimplifiedChinese ? "，" : ", ")
    }

    private func capabilitiesAccessibilityValue(_ capabilities: [String]) -> String {
        capabilities.isEmpty
            ? l("None reported", "未报告")
            : capabilities.joined(separator: ", ")
    }

    private func diagnosticsCountText(_ count: Int) -> String {
        l(
            "\(count) \(count == 1 ? "diagnostic" : "diagnostics")",
            "\(count) 条诊断"
        )
    }

    private func diagnosticAccessibilityLabel(
        _ entry: LanguageServerDiagnosticEntry
    ) -> String {
        let file = URL(fileURLWithPath: entry.filePath).lastPathComponent
        return l(
            "\(severityName(entry.diagnostic.severity)), \(file), "
                + "line \(entry.diagnostic.line), column \(entry.diagnostic.column), "
                + entry.diagnostic.message,
            "\(severityName(entry.diagnostic.severity))，\(file)，"
                + "第 \(entry.diagnostic.line) 行，第 \(entry.diagnostic.column) 列，"
                + entry.diagnostic.message
        )
    }

    private func interactiveResultHeading(
        method: LanguageServerMethod, result: LanguageServerInteractiveResult
    ) -> String {
        switch method {
        case .completion:
            let count = result.completions?.count ?? 0
            return l("COMPLETIONS (\(count))", "补全（\(count)）")
        case .hover:
            return l("HOVER", "悬停信息")
        case .definition:
            let count = result.locations?.count ?? 0
            return l("DEFINITIONS (\(count))", "定义（\(count)）")
        case .references:
            let count = result.locations?.count ?? 0
            return l("REFERENCES (\(count))", "引用（\(count)）")
        case .rename:
            return l("RENAME", "重命名")
        }
    }

    private func completionAccessibilityLabel(_ item: LanguageCompletionItem) -> String {
        var parts = [item.label]
        if let detail = nonempty(item.detail) { parts.append(detail) }
        if let documentation = nonempty(item.documentation) { parts.append(documentation) }
        if let insertText = nonempty(item.insertText), insertText != item.label {
            parts.append(l("insert \(insertText)", "插入 \(insertText)"))
        }
        return parts.joined(separator: appLocale.isSimplifiedChinese ? "，" : ", ")
    }

    private func locationPosition(_ location: LanguageLocation) -> String {
        l(
            "Ln \(oneBased(location.line)), Col \(oneBased(location.character))",
            "第 \(oneBased(location.line)) 行，第 \(oneBased(location.character)) 列"
        )
    }

    private func locationAccessibilityLabel(
        _ location: LanguageLocation, method: LanguageServerMethod
    ) -> String {
        let file = URL(fileURLWithPath: location.filePath).lastPathComponent
        let kind = method == .definition
            ? l("definition", "定义")
            : l("reference", "引用")
        return l(
            "\(kind), \(file), line \(oneBased(location.line)), "
                + "column \(oneBased(location.character)), \(location.filePath)",
            "\(kind)，\(file)，第 \(oneBased(location.line)) 行，"
                + "第 \(oneBased(location.character)) 列，\(location.filePath)"
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func oneBased(_ value: Int) -> Int {
        value >= Int.max ? Int.max : max(0, value) + 1
    }

    private func stateName(_ state: LanguageServerClientState) -> String {
        switch state {
        case .stopped: return l("Stopped", "已停止")
        case .starting: return l("Starting", "正在启动")
        case .running: return l("Running", "正在运行")
        case .stopping: return l("Stopping", "正在停止")
        case .restarting: return l("Restarting", "正在重新启动")
        case .failed: return l("Failed", "失败")
        }
    }

    private func severityName(_ severity: LanguageServerDiagnosticSeverity) -> String {
        switch severity {
        case .error: return l("error", "错误")
        case .warning: return l("warning", "警告")
        case .info: return l("information", "信息")
        }
    }

    private func logLevelName(_ level: LanguageServerLogLevel) -> String {
        switch level {
        case .info: return l("info", "信息")
        case .warning: return l("warning", "警告")
        case .error: return l("error", "错误")
        }
    }

    private func logStreamName(_ stream: LanguageServerLogStream) -> String {
        switch stream {
        case .standardError: return l("stderr", "标准错误")
        case .server: return l("server", "服务器")
        }
    }

    private func interactiveMethodName(_ method: LanguageServerMethod) -> String {
        switch method {
        case .completion: return l("completion", "补全")
        case .hover: return l("hover", "悬停信息")
        case .definition: return l("definition", "定义查询")
        case .references: return l("references", "引用查询")
        case .rename: return l("rename", "重命名")
        }
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }

    private var warningForeground: Color {
        colorSchemeContrast == .increased ? .primary : .orange
    }

    private var errorForeground: Color {
        colorSchemeContrast == .increased ? .primary : .red
    }

    private func stateForeground(for state: LanguageServerClientState) -> Color {
        colorSchemeContrast == .increased ? .primary : color(for: state)
    }

    private func color(for state: LanguageServerClientState) -> Color {
        switch state {
        case .running: return .green
        case .starting, .restarting: return .blue
        case .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private func icon(for severity: LanguageServerDiagnosticSeverity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for severity: LanguageServerDiagnosticSeverity) -> Color {
        if colorSchemeContrast == .increased { return .primary }
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    private func color(for level: LanguageServerLogLevel) -> Color {
        if colorSchemeContrast == .increased { return .primary }
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    enum Accessibility {
        static let panel = "Language Servers"
        static let summary = "Language Server Summary"
        static let services = "Language Server Services"
        static let selectedStatus = "Selected Language Server Status"
        static let capabilities = "Language Server Capabilities"
        static let diagnostics = "Language Server Diagnostics"
        static let log = "Language Server Log"
        static let statusBar = "Language Server Panel Status"
        static let restart = "Restart Language Server"
        static let stop = "Stop Language Server"
        static let clearLog = "Clear Language Server Log"
        static let close = "Close Language Server Panel"
        static let error = "Language Server Error"
        static let dismissError = "Dismiss Language Server Error"
        static let approval = "Review the exact language server command before allowing it."
        static let interactiveResults = "Language Server Interactive Results"
        static let hoverResult = "Language Server Hover Result"
        static let clearInteractiveResult = "Clear Language Server Interactive Result"
    }
}
