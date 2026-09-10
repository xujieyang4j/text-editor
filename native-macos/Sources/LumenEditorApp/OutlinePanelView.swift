import AppKit
import LumenEditorCore
import SwiftUI

struct OutlinePanelView: View {
    @ObservedObject private var controller: OutlineController
    @FocusState private var filterIsFocused: Bool
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(controller: OutlineController) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filter
            Divider()
            symbols
        }
        .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("Document Outline", "文档大纲"))
        .accessibilityIdentifier(AppAccessibility.id("outline panel"))
        .onAppear { filterIsFocused = true }
        .onExitCommand { controller.setVisible(false) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.indent")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(l("OUTLINE", "大纲"))
                    .font(.caption.weight(.semibold))
                if !controller.documentName.isEmpty {
                    Text(controller.documentName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if controller.isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(l("Updating Outline", "正在更新大纲"))
            }
            Text(localizedResultSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(l(
                    "Outline status: \(localizedResultSummary)",
                    "大纲状态：\(localizedResultSummary)"
                ))
            Button { controller.setVisible(false) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(l("Close Outline", "关闭大纲"))
            .accessibilityIdentifier(AppAccessibility.id("outline close"))
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private var filter: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(l("Filter symbols…", "筛选符号…"), text: $controller.query)
                .textFieldStyle(.plain)
                .focused($filterIsFocused)
                .accessibilityLabel(l("Filter outline symbols", "筛选大纲符号"))
                .accessibilityIdentifier(AppAccessibility.id("outline filter"))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    @ViewBuilder
    private var symbols: some View {
        if controller.filteredSymbols.isEmpty {
            ContentUnavailableView(
                controller.documentName.isEmpty
                    ? l("No Active Document", "没有活动文档")
                    : l("No Symbols", "没有符号"),
                systemImage: "list.bullet.indent"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.filteredSymbols) { symbol in
                            symbolRow(symbol)
                                .id(symbol.id)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                }
                .onChange(of: controller.activeSymbolID) { _, symbolID in
                    guard let symbolID else { return }
                    withAnimation(
                        AppAccessibility.animation(reduceMotion: reduceMotion, duration: 0.12)
                    ) {
                        proxy.scrollTo(symbolID, anchor: .center)
                    }
                }
            }
        }
    }

    private func symbolRow(_ symbol: OutlineSymbol) -> some View {
        Button {
            Task { _ = await controller.select(symbol) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon(for: symbol.kind))
                    .frame(width: 15)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(symbol.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 5)
                Text(l("Ln \(symbol.line)", "第 \(symbol.line) 行"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, CGFloat(min(symbol.level, 8)) * 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(symbol.id == controller.activeSymbolID
                        ? Color.accentColor.opacity(
                            AppAccessibility.selectionOpacity(for: colorSchemeContrast)
                        )
                        : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l(
            "\(symbol.label), line \(symbol.line)",
            "\(symbol.label)，第 \(symbol.line) 行"
        ))
        .accessibilityValue(
            symbol.id == controller.activeSymbolID
                ? l("Current symbol", "当前符号")
                : ""
        )
    }

    private func icon(for kind: OutlineSymbolKind) -> String {
        switch kind {
        case .type: "shippingbox"
        case .function: "function"
        case .method: "f.cursive"
        case .variable: "v.square"
        case .heading: "number"
        }
    }

    private var localizedResultSummary: String {
        guard appLocale == .zhCN else { return controller.resultSummary }
        guard !controller.documentName.isEmpty else { return "没有活动文档" }
        guard !controller.filteredSymbols.isEmpty else { return "没有符号" }
        let truncated = controller.sourceWasTruncated || controller.symbolsWereTruncated
            ? "（已截断）"
            : ""
        return "\(controller.filteredSymbols.count)\(truncated)"
    }

    private func l(_ english: String, _ chinese: String) -> String {
        appLocale.text(english, zh: chinese)
    }
}
