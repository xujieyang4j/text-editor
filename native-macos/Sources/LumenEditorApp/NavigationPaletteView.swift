import AppKit
import SwiftUI

/// Presentation-only native palette for Goto Anything, files, symbols, and
/// line locations. The containing shell owns sheet/popover presentation.
struct NavigationPaletteView: View {
    @ObservedObject var controller: NavigationController
    let onDismiss: () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var queryIsFocused: Bool

    init(
        controller: NavigationController,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
            if let issue = controller.issue {
                Divider()
                issueView(issue)
            }
        }
        .frame(minWidth: 480, idealWidth: 620, maxWidth: 780)
        .frame(minHeight: 280, idealHeight: 430, maxHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocale.text(Accessibility.palette, zh: "导航面板"))
        .accessibilityIdentifier(Accessibility.paletteID)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .onAppear { queryIsFocused = true }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: dismiss)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: modeIcon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $controller.query)
                .textFieldStyle(.plain)
                .focused($queryIsFocused)
                .onSubmit(acceptSelection)
                .accessibilityLabel(appLocale.text(Accessibility.query, zh: "导航查询"))
                .accessibilityHint(
                    appLocale.text(
                        Accessibility.queryHint,
                        zh: "输入内容以筛选，使用上、下方向键选择，按回车键打开，按 Esc 键关闭。"
                    )
                )
                .accessibilityIdentifier(Accessibility.queryID)

            if controller.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        appLocale.text(Accessibility.loading, zh: "正在加载导航结果")
                    )
                    .accessibilityIdentifier(Accessibility.loadingID)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if controller.items.isEmpty, !controller.isBusy {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(28)
                        .accessibilityLabel(emptyMessage)
                        .accessibilityIdentifier(Accessibility.emptyID)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(controller.items.indices, id: \.self) { index in
                            resultRow(controller.items[index], index: index)
                                .id(controller.items[index].id)
                        }
                    }
                    .padding(6)
                }
            }
            .accessibilityLabel(appLocale.text(Accessibility.results, zh: "导航结果"))
            .accessibilityIdentifier(Accessibility.resultsID)
            .onChange(of: controller.selectedIndex) { _, index in
                guard let index, controller.items.indices.contains(index) else { return }
                if reduceMotion {
                    proxy.scrollTo(controller.items[index].id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(controller.items[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func resultRow(_ item: NavigationPaletteItem, index: Int) -> some View {
        let selected = controller.selectedIndex == index
        return Button {
            controller.selectItem(at: index)
            Task { _ = await controller.acceptSelection() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: item.kind))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    highlightedLabel(item)
                        .lineLimit(1)
                    if let detail = localizedDetail(for: item) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(selectionOpacity) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        selected && colorSchemeContrast == .increased
                            ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localizedLabel(for: item))
        .accessibilityValue(localizedDetail(for: item) ?? "")
        .accessibilityHint(
            appLocale.text(
                Accessibility.openHint,
                zh: "打开此导航位置"
            )
        )
        .accessibilityIdentifier(Accessibility.itemID(item.id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// SwiftUI Text concatenation lets us highlight ranges without converting
    /// UTF-16 offsets to Character indices (which would corrupt emoji offsets).
    private func highlightedLabel(_ item: NavigationPaletteItem) -> Text {
        if item.kind == .line { return Text(localizedLabel(for: item)) }

        let label = item.label as NSString
        let matched = Set(item.matchedUTF16Offsets)
        guard !matched.isEmpty else { return Text(item.label) }

        var result = Text("")
        var offset = 0
        while offset < label.length {
            let composed = label.rangeOfComposedCharacterSequence(at: offset)
            let fragment = label.substring(with: composed)
            let overlapsMatch = (composed.location..<NSMaxRange(composed)).contains {
                matched.contains($0)
            }
            result = result + (overlapsMatch
                ? Text(fragment).bold().foregroundColor(.accentColor)
                : Text(fragment))
            offset = NSMaxRange(composed)
        }
        return result
    }

    private func issueView(_ issue: NavigationPresentationIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(
                    colorSchemeContrast == .increased ? Color.primary : Color.orange
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocale.localizedNavigationIssueTitle(issue.titleContent))
                    .font(.caption.weight(.semibold))
                Text(appLocale.localizedNavigationIssue(issue.content))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(appLocale.text("Dismiss", zh: "忽略")) { controller.dismissIssue() }
                .accessibilityLabel(
                    appLocale.text(Accessibility.dismissIssue, zh: "忽略导航错误")
                )
                .accessibilityIdentifier(Accessibility.dismissIssueID)
        }
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Accessibility.issueID)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .down: controller.moveSelection(by: 1)
        case .up: controller.moveSelection(by: -1)
        default: break
        }
    }

    private func acceptSelection() {
        Task { _ = await controller.acceptSelection() }
    }

    private func dismiss() {
        controller.dismiss()
        onDismiss()
    }

    private var placeholder: String {
        switch controller.mode {
        case .anything:
            return appLocale.text(
                "Goto Anything — file, :line[:column], @symbol, #project symbol",
                zh: "转到任意位置 — 文件、:行[:列]、@符号、#项目符号"
            )
        case .file:
            return appLocale.text("Goto File", zh: "转到文件")
        case .symbol:
            return appLocale.text("Goto Symbol in File", zh: "转到当前文件中的符号")
        case .projectSymbol:
            return appLocale.text("Goto Symbol in Project", zh: "转到项目中的符号")
        case .line:
            return appLocale.text(
                "Goto Line (for example 42:8, +10, 50%)",
                zh: "转到行（例如 42:8、+10、50%）"
            )
        }
    }

    private var emptyMessage: String {
        if let issue = controller.issue {
            return appLocale.localizedNavigationIssue(issue.content)
        }
        switch controller.effectiveMode {
        case .file:
            return appLocale.text("No matching workspace files.", zh: "没有匹配的工作区文件。")
        case .symbol:
            return appLocale.text(
                "No matching symbols in the current document.",
                zh: "当前文档中没有匹配的符号。"
            )
        case .projectSymbol:
            return appLocale.text("No matching project symbols.", zh: "没有匹配的项目符号。")
        case .line:
            return appLocale.text(
                "Enter a valid line or line:column location.",
                zh: "请输入有效的行号或“行:列”位置。"
            )
        case .anything:
            return appLocale.text("No matching navigation locations.", zh: "没有匹配的导航位置。")
        }
    }

    private var selectionOpacity: Double {
        colorSchemeContrast == .increased ? 0.34 : 0.18
    }

    private func localizedLabel(for item: NavigationPaletteItem) -> String {
        guard item.kind == .line, let line = item.destination.line else {
            return item.label
        }
        let column = item.destination.column ?? 1
        return appLocale.text(
            "Go to \(line):\(column)",
            zh: "转到 \(line):\(column)"
        )
    }

    private func localizedDetail(for item: NavigationPaletteItem) -> String? {
        guard item.kind == .symbol, let line = item.destination.line else {
            return item.detail
        }
        return appLocale.text("Ln \(line)", zh: "第 \(line) 行")
    }

    private var modeIcon: String {
        switch controller.effectiveMode {
        case .anything, .file: return "doc.text.magnifyingglass"
        case .symbol, .projectSymbol: return "number"
        case .line: return "text.line.first.and.arrowtriangle.forward"
        }
    }

    private func icon(for kind: NavigationPaletteItem.Kind) -> String {
        switch kind {
        case .file: return "doc"
        case .line: return "text.line.first.and.arrowtriangle.forward"
        case .symbol, .projectSymbol: return "number"
        }
    }

    enum Accessibility {
        static let palette = "Navigation Palette"
        static let query = "Navigation Query"
        static let loading = "Loading Navigation Results"
        static let results = "Navigation Results"
        static let openHint = "Opens this navigation location"
        static let dismissIssue = "Dismiss Navigation Error"
        static let queryHint =
            "Type to filter, use Up and Down to choose, Return to open, and Escape to close."

        static let paletteID = "panel.navigation"
        static let queryID = "panel.navigation.query"
        static let loadingID = "panel.navigation.loading"
        static let resultsID = "panel.navigation.results"
        static let emptyID = "panel.navigation.empty"
        static let issueID = "panel.navigation.issue"
        static let dismissIssueID = "panel.navigation.issue.dismiss"

        static func itemID(_ id: String) -> String {
            "panel.navigation.item." + id
        }
    }
}
