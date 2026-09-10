import AppKit
import SwiftUI

/// Presentation-only current-document find/replace bar. The containing editor
/// decides whether this is an overlay, safe-area inset, or toolbar attachment.
struct FindBarView: View {
    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ObservedObject var controller: FindBarController
    let onDismiss: () -> Void

    @FocusState private var focusedField: Field?

    init(
        controller: FindBarController,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField(appLocale.text("Find", zh: "查找"), text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .query)
                    .onSubmit { Task { _ = await controller.findNext() } }
                    .accessibilityLabel(
                        appLocale.text(Accessibility.query, zh: "查找文本")
                    )
                    .accessibilityHint(
                        appLocale.text(
                            "Press Return to select the next match. Escape closes the find bar.",
                            zh: "按下回车键选择下一个匹配项，按下 Escape 键关闭查找栏。"
                        )
                    )
                    .accessibilityIdentifier(Accessibility.queryID)

                if !controller.searchHistory.isEmpty {
                    historyMenu(
                        items: controller.searchHistory,
                        title: appLocale.text("Recent searches", zh: "最近搜索"),
                        identifier: Accessibility.searchHistoryID
                    ) { controller.query = $0 }
                }

                resultNavigation
                optionToggles

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(appLocale.text("Close Find Bar", zh: "关闭查找栏"))
                .accessibilityLabel(
                    appLocale.text(Accessibility.close, zh: "关闭查找栏")
                )
                .accessibilityIdentifier(Accessibility.closeID)
            }

            if controller.mode == .replace {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField(
                        appLocale.text("Replace", zh: "替换"),
                        text: $controller.replacement
                    )
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .replacement)
                        .onSubmit { Task { _ = await controller.replaceNext() } }
                        .accessibilityLabel(
                            appLocale.text(Accessibility.replacement, zh: "替换文本")
                        )
                        .accessibilityIdentifier(Accessibility.replacementID)

                    if !controller.replaceHistory.isEmpty {
                        historyMenu(
                            items: controller.replaceHistory,
                            title: appLocale.text("Recent replacements", zh: "最近替换"),
                            identifier: Accessibility.replaceHistoryID,
                            labelsEmptyValue: true
                        ) { controller.replacement = $0 }
                    }

                    Button(appLocale.text("Replace", zh: "替换")) {
                        Task { _ = await controller.replaceNext() }
                    }
                    .disabled(!controller.canReplace)
                    .accessibilityLabel(
                        appLocale.text(Accessibility.replace, zh: "替换当前匹配项")
                    )
                    .accessibilityIdentifier(Accessibility.replaceID)

                    Button(appLocale.text("Replace All", zh: "全部替换")) {
                        Task { _ = await controller.replaceAll() }
                    }
                    .disabled(!controller.canReplace)
                    .accessibilityLabel(
                        appLocale.text(Accessibility.replaceAll, zh: "替换所有匹配项")
                    )
                    .accessibilityIdentifier(Accessibility.replaceAllID)
                }
                .padding(.leading, 2)
            }

            Text(localizedStatusMessage)
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .accessibilityLabel(
                    appLocale.text(Accessibility.status, zh: "查找状态")
                )
                .accessibilityValue(localizedStatusMessage)
                .accessibilityIdentifier(Accessibility.statusID)
        }
        .padding(10)
        .frame(minWidth: 500, idealWidth: 650, maxWidth: 820)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            appLocale.text(Accessibility.bar, zh: "查找和替换")
        )
        .accessibilityIdentifier(Accessibility.barID)
        .onAppear { focusInitialField() }
        .onChange(of: controller.focusGeneration) { _, _ in focusInitialField() }
        .onChange(of: controller.mode) { _, _ in focusInitialField() }
    }

    private var resultNavigation: some View {
        HStack(spacing: 3) {
            Button {
                Task { _ = await controller.findPrevious() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canFind)
            .help(appLocale.text("Find Previous", zh: "查找上一个"))
            .accessibilityLabel(
                appLocale.text(Accessibility.previous, zh: "查找上一个匹配项")
            )
            .accessibilityIdentifier(Accessibility.previousID)

            Button {
                Task { _ = await controller.findNext() }
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canFind)
            .help(appLocale.text("Find Next", zh: "查找下一个"))
            .accessibilityLabel(
                appLocale.text(Accessibility.next, zh: "查找下一个匹配项")
            )
            .accessibilityIdentifier(Accessibility.nextID)
        }
    }

    private func historyMenu(
        items: [String],
        title: String,
        identifier: String,
        labelsEmptyValue: Bool = false,
        select: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(Array(items.prefix(50).enumerated()), id: \.offset) { _, item in
                Button(labelsEmptyValue && item.isEmpty
                    ? appLocale.text("Empty replacement", zh: "空替换文本")
                    : item) {
                    select(item)
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private var optionToggles: some View {
        HStack(spacing: 3) {
            optionButton(
                title: "Aa",
                help: appLocale.text("Match Case", zh: "区分大小写"),
                accessibility: appLocale.text(Accessibility.caseSensitive, zh: "区分大小写"),
                identifier: Accessibility.caseSensitiveID,
                isOn: $controller.isCaseSensitive
            )
            optionButton(
                title: "W",
                help: appLocale.text("Match Whole Word", zh: "全字匹配"),
                accessibility: appLocale.text(Accessibility.wholeWord, zh: "全字匹配"),
                identifier: Accessibility.wholeWordID,
                isOn: $controller.isWholeWord
            )
            optionButton(
                title: ".*",
                help: appLocale.text("Use Regular Expression", zh: "使用正则表达式"),
                accessibility: appLocale.text(
                    Accessibility.regularExpression,
                    zh: "使用正则表达式"
                ),
                identifier: Accessibility.regularExpressionID,
                isOn: $controller.usesRegularExpression
            )
        }
    }

    private func optionButton(
        title: String,
        help: String,
        accessibility: String,
        identifier: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .frame(minWidth: 22)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? optionBackground : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isOn.wrappedValue && colorSchemeContrast == .increased
                                ? Color.accentColor
                                : .clear,
                            lineWidth: 1.5
                        )
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibility)
        .accessibilityValue(
            isOn.wrappedValue
                ? appLocale.text("On", zh: "开")
                : appLocale.text("Off", zh: "关")
        )
        .accessibilityIdentifier(identifier)
    }

    private var optionBackground: Color {
        Color.accentColor.opacity(AppAccessibility.selectionOpacity(for: colorSchemeContrast))
    }

    private var statusColor: Color {
        if case .invalidQuery = controller.status {
            return colorSchemeContrast == .increased
                ? .primary
                : .red
        }
        return .secondary
    }

    private var localizedStatusMessage: String {
        appLocale.localizedFindStatus(
            controller.status,
            queryIsEmpty: controller.query.isEmpty,
            purpose: .visible
        )
    }

    private func focusInitialField() {
        focusedField = controller.mode == .replace ? .replacement : .query
    }

    private func dismiss() {
        controller.dismiss()
        onDismiss()
    }

    private enum Field: Hashable {
        case query
        case replacement
    }

    enum Accessibility {
        static let bar = "Find and Replace"
        static let query = "Find Text"
        static let replacement = "Replacement Text"
        static let previous = "Find Previous Match"
        static let next = "Find Next Match"
        static let replace = "Replace Current Match"
        static let replaceAll = "Replace All Matches"
        static let caseSensitive = "Match Case"
        static let wholeWord = "Match Whole Word"
        static let regularExpression = "Use Regular Expression"
        static let status = "Find Status"
        static let close = "Close Find Bar"

        static let barID = "panel.find"
        static let queryID = "panel.find.query"
        static let replacementID = "panel.find.replacement"
        static let searchHistoryID = "panel.find.searchHistory"
        static let replaceHistoryID = "panel.find.replaceHistory"
        static let previousID = "panel.find.previous"
        static let nextID = "panel.find.next"
        static let replaceID = "panel.find.replace"
        static let replaceAllID = "panel.find.replaceAll"
        static let caseSensitiveID = "panel.find.caseSensitive"
        static let wholeWordID = "panel.find.wholeWord"
        static let regularExpressionID = "panel.find.regularExpression"
        static let statusID = "panel.find.status"
        static let closeID = "panel.find.close"
    }
}
