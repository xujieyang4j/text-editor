import AppKit
import SwiftUI

/// Native preview surface. It contains no WebView, script runtime, networking,
/// or direct workspace access; all link navigation returns through the injected
/// `PreviewController` opener.
struct DocumentPreviewView: View {
    @ObservedObject var controller: PreviewController
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Group {
            if controller.isVisible {
                VStack(spacing: 0) {
                    header
                    Divider()

                    if let issue = controller.issue {
                        issueView(issue)
                    } else {
                        previewContent
                    }
                }
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .environment(\.openURL, OpenURLAction { url in
                    controller.openLink(url) ? .handled : .discarded
                })
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
                .accessibilityIdentifier("preview.panel")
                .transaction { transaction in
                    if reduceMotion { transaction.animation = nil }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: iconName)
                .font(.headline)
            Spacer()
            Button { controller.hide() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(closePreviewTitle)
            .accessibilityLabel(closePreviewTitle)
            .accessibilityHint(
                appLocale.text(
                    "Hides the document preview",
                    zh: "隐藏文档预览"
                )
            )
            .accessibilityIdentifier("preview.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("preview.header")
    }

    @ViewBuilder
    private var previewContent: some View {
        switch controller.mode {
        case .hidden:
            Color.clear
        case .markdown:
            SafeMarkdownPreviewView(document: controller.markdownDocument)
                .id(controller.contentRevision)
        case .json:
            if let snapshot = controller.jsonSnapshot {
                JSONTreeView(
                    snapshot: snapshot,
                    controller: controller,
                    sessionGeneration: controller.jsonEditSessionGeneration,
                    locale: appLocale
                )
            } else {
                emptyView(
                    appLocale.text("No JSON to display", zh: "没有可显示的 JSON"),
                    systemImage: "curlybraces",
                    identifier: "preview.json.empty"
                )
            }
        }
    }

    private func issueView(_ issue: DocumentPreviewIssue) -> some View {
        let issueTitle = issueTitle(for: issue)
        return VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(warningColor)
                .accessibilityHidden(true)
            Text(issueTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(localizedIssueMessage(issue))
                .foregroundStyle(secondaryTextColor)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityLabel(
                    localizedIssueDetails(issue)
                )
            Button(appLocale.text("Dismiss", zh: "忽略")) {
                controller.dismissIssue()
            }
            .accessibilityHint(
                appLocale.text(
                    "Dismisses this message and returns to the preview",
                    zh: "关闭此消息并返回预览"
                )
            )
            .accessibilityIdentifier("preview.issue.dismiss")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(issueTitle)
        .accessibilityIdentifier("preview.issue")
    }

    private func emptyView(
        _ title: String,
        systemImage: String,
        identifier: String
    ) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
    }

    private var title: String {
        switch controller.mode {
        case .hidden: return appLocale.text("Preview", zh: "预览")
        case .markdown: return appLocale.text("Markdown Preview", zh: "Markdown 预览")
        case .json: return appLocale.text("JSON View", zh: "JSON 视图")
        }
    }

    private var closePreviewTitle: String {
        appLocale.text("Close Preview", zh: "关闭预览")
    }

    private func issueTitle(for issue: DocumentPreviewIssue) -> String {
        if issue.kind == .invalidJSON {
            return appLocale.text("Invalid JSON", zh: "JSON 无效")
        }
        return appLocale.text("Preview Unavailable", zh: "预览不可用")
    }

    private func localizedIssueMessage(_ issue: DocumentPreviewIssue) -> String {
        appLocale.localizedPresentation(issue.content)
    }

    private func localizedIssueDetails(_ issue: DocumentPreviewIssue) -> String {
        let message = localizedIssueMessage(issue)
        return appLocale.text(
            "Details: \(message)",
            zh: "详细信息：\(message)"
        )
    }

    private var warningColor: Color {
        colorSchemeContrast == .increased ? .primary : .orange
    }

    private var secondaryTextColor: Color {
        colorSchemeContrast == .increased ? .primary : .secondary
    }

    private var iconName: String {
        switch controller.mode {
        case .hidden: return "eye"
        case .markdown: return "doc.richtext"
        case .json: return "curlybraces"
        }
    }
}

private struct SafeMarkdownPreviewView: View {
    let document: SafeMarkdownDocument
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        if document.blocks.isEmpty {
            ContentUnavailableView(
                appLocale.text("Nothing to preview", zh: "没有可预览的内容"),
                systemImage: "doc.richtext",
                description: Text(
                    appLocale.text(
                        "The Markdown document is empty.",
                        zh: "Markdown 文档为空。"
                    )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(
                appLocale.text(
                    "Nothing to preview. The Markdown document is empty.",
                    zh: "没有可预览的内容。Markdown 文档为空。"
                )
            )
            .accessibilityIdentifier("preview.markdown.empty")
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(document.blocks) { block in
                        blockView(block)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(appLocale.text("Markdown preview", zh: "Markdown 预览"))
            .accessibilityIdentifier("preview.markdown.content")
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: SafeMarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            VStack(alignment: .leading, spacing: 5) {
                Text(block.content)
                    .font(headingFont(level))
                    .accessibilityAddTraits(.isHeader)
                if level <= 2 { Divider() }
            }
        case .paragraph:
            Text(block.content)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case let .code(language):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(verbatim: language)
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                }
                Text(block.content)
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(colorSchemeContrast == .increased ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: 6)
            )
        case .blockQuote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor.opacity(colorSchemeContrast == .increased ? 1 : 0.65))
                    .frame(width: colorSchemeContrast == .increased ? 4 : 3)
                    .accessibilityHidden(true)
                Text(block.content)
                    .foregroundStyle(secondaryTextColor)
            }
        case let .unorderedListItem(depth, task):
            listItem(
                marker: taskMarker(task) ?? "•",
                content: block.content,
                depth: depth,
                isTask: task != nil
            )
        case let .orderedListItem(number, depth, task):
            listItem(
                marker: taskMarker(task) ?? "\(number).",
                content: block.content,
                depth: depth,
                isTask: task != nil
            )
        case .thematicBreak:
            Divider()
                .padding(.vertical, 6)
        case .table:
            if let table = block.table {
                tableView(table)
            }
        }
    }

    private func listItem(
        marker: String,
        content: AttributedString,
        depth: Int,
        isTask: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .frame(minWidth: isTask ? 26 : 18, alignment: .trailing)
                .foregroundStyle(secondaryTextColor)
            Text(content)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth * 18))
    }

    private func taskMarker(_ task: SafeMarkdownTaskState?) -> String? {
        switch task {
        case .checked:
            "☑"
        case .unchecked:
            "☐"
        case nil:
            nil
        }
    }

    private func tableView(_ table: SafeMarkdownTable) -> some View {
        VStack(spacing: 0) {
            tableRow(table.header, emphasized: true)
                .background(Color.secondary.opacity(colorSchemeContrast == .increased ? 0.18 : 0.10))
            Divider()
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                tableRow(row, emphasized: false)
                    .background(index.isMultiple(of: 2)
                        ? Color.clear
                        : Color.secondary.opacity(colorSchemeContrast == .increased ? 0.10 : 0.05))
                if index != table.rows.count - 1 {
                    Divider()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(colorSchemeContrast == .increased ? 0.5 : 0.25))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tableRow(_ row: SafeMarkdownTableRow, emphasized: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                Text(cell.content)
                    .font(emphasized ? .headline : .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if index != row.cells.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        case 3: return .title2.bold()
        case 4: return .title3.bold()
        default: return .headline
        }
    }

    private var secondaryTextColor: Color {
        colorSchemeContrast == .increased ? .primary : .secondary
    }
}
