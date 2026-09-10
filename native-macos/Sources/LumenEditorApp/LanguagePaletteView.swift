import AppKit
import SwiftUI

/// Presentation-only searchable syntax picker. The shell owns sheet/popover
/// placement; all mutation and stale-document checks stay in the controller.
struct LanguagePaletteView: View {
    @ObservedObject var controller: LanguageController
    let onDismiss: () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var queryIsFocused: Bool

    init(
        controller: LanguageController,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    appLocale.text("Set syntax…", zh: "设置语法…"),
                    text: $controller.query
                )
                    .textFieldStyle(.plain)
                    .focused($queryIsFocused)
                    .onSubmit(acceptSelection)
                    .accessibilityLabel(
                        appLocale.text(Accessibility.query, zh: "语言查询")
                    )
                    .accessibilityHint(
                        appLocale.text(
                            Accessibility.queryHint,
                            zh: "输入内容以筛选，使用上、下方向键选择，按回车键确认，按 Esc 键关闭。"
                        )
                    )
                    .accessibilityIdentifier(Accessibility.queryID)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if controller.items.isEmpty {
                        Text(appLocale.text("No matching languages.", zh: "没有匹配的语言。"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(28)
                            .accessibilityLabel(
                                appLocale.text(Accessibility.emptyResults, zh: "没有匹配的语言")
                            )
                            .accessibilityIdentifier(Accessibility.emptyID)
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(controller.items.indices, id: \.self) { index in
                                row(controller.items[index], at: index)
                                    .id(controller.items[index].id)
                            }
                        }
                        .padding(6)
                    }
                }
                .accessibilityLabel(
                    appLocale.text(Accessibility.results, zh: "语言结果")
                )
                .accessibilityIdentifier(Accessibility.resultsID)
                .onChange(of: controller.selectedIndex) { _, index in
                    guard let index, controller.items.indices.contains(index) else { return }
                    withAnimation(AppAccessibility.animation(
                        reduceMotion: reduceMotion, duration: 0.1
                    )) {
                        proxy.scrollTo(controller.items[index].id, anchor: .center)
                    }
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 680)
        .frame(minHeight: 280, idealHeight: 420, maxHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            appLocale.text(Accessibility.palette, zh: "语言面板")
        )
        .accessibilityIdentifier(Accessibility.paletteID)
        .onAppear { queryIsFocused = true }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: dismiss)
    }

    private func row(_ item: LanguagePaletteItem, at index: Int) -> some View {
        let selected = controller.selectedIndex == index
        return Button {
            controller.selectItem(at: index)
            acceptSelection()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isCurrent ? "checkmark" : "circle.fill")
                    .font(item.isCurrent ? .body : .system(size: 4))
                    .foregroundStyle(item.isCurrent ? Color.accentColor : Color.clear)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                highlightedName(item)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.language.isPlainText {
                    Text(appLocale.text("Auto", zh: "自动"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .accessibilityLabel(item.name)
        .accessibilityValue(
            item.isCurrent
                ? appLocale.text("Current language", zh: "当前语言") : ""
        )
        .accessibilityHint(
            appLocale.text(Accessibility.selectHint, zh: "设置此文档的语法语言")
        )
        .accessibilityIdentifier(Accessibility.itemID(item.id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func highlightedName(_ item: LanguagePaletteItem) -> Text {
        let name = item.name as NSString
        let matched = Set(item.matchedUTF16Offsets)
        guard !matched.isEmpty else { return Text(item.name) }

        var result = Text("")
        var offset = 0
        while offset < name.length {
            let range = name.rangeOfComposedCharacterSequence(at: offset)
            let fragment = name.substring(with: range)
            let overlaps = (range.location..<NSMaxRange(range)).contains {
                matched.contains($0)
            }
            result = result + (overlaps
                ? Text(fragment).bold().foregroundColor(.accentColor)
                : Text(fragment))
            offset = NSMaxRange(range)
        }
        return result
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .down: controller.moveSelection(by: 1)
        case .up: controller.moveSelection(by: -1)
        default: break
        }
    }

    private func acceptSelection() {
        guard controller.acceptSelection() else { return }
        onDismiss()
    }

    private func dismiss() {
        controller.dismiss()
        onDismiss()
    }

    private var selectionOpacity: Double {
        colorSchemeContrast == .increased ? 0.36 : 0.18
    }

    enum Accessibility {
        static let palette = "Language Palette"
        static let query = "Language Query"
        static let results = "Language Results"
        static let emptyResults = "No Matching Languages"
        static let selectHint = "Sets this document's syntax language"
        static let queryHint =
            "Type to filter, use Up and Down to choose, Return to select, and Escape to close."

        static let paletteID = "panel.language"
        static let queryID = "panel.language.query"
        static let resultsID = "panel.language.results"
        static let emptyID = "panel.language.empty"

        static func itemID(_ id: String) -> String {
            "panel.language.item." + id
        }
    }
}
