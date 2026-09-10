import AppKit
import SwiftUI

struct BuildSystemPaletteView: View {
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ObservedObject var controller: BuildController
    let onDismiss: () -> Void
    let onAccept: @MainActor () async -> Bool

    @State private var isAccepting = false
    @FocusState private var searchFocused: Bool

    init(
        controller: BuildController,
        onDismiss: @escaping () -> Void,
        onAccept: @escaping @MainActor () async -> Bool
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
        self.onAccept = onAccept
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(minWidth: 480, idealWidth: 620, maxWidth: 760)
        .frame(minHeight: 300, idealHeight: 440, maxHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocale.text(Accessibility.palette, zh: "构建系统面板"))
        .accessibilityIdentifier(Accessibility.paletteID)
        .onAppear { searchFocused = true }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand(perform: dismiss)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                appLocale.text("Select Build System", zh: "选择构建系统"),
                text: $controller.buildSystemQuery
            )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(acceptSelection)
                .disabled(isAccepting)
                .accessibilityLabel(
                    appLocale.text(Accessibility.query, zh: "构建系统查询")
                )
                .accessibilityHint(appLocale.text(
                    Accessibility.queryHint,
                    zh: "输入内容以筛选，使用上、下方向键选择，按回车键运行，按 Esc 键关闭。"
                ))
                .accessibilityIdentifier(Accessibility.queryID)
            if isAccepting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(appLocale.text("Preparing build", zh: "正在准备构建"))
                    .accessibilityIdentifier(Accessibility.progressID)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .disabled(isAccepting)
                .accessibilityLabel(appLocale.text("Close", zh: "关闭"))
                .accessibilityIdentifier(Accessibility.closeID)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if controller.buildSystemPaletteItems.isEmpty {
                    Text(appLocale.text(
                        "No matching build systems.", zh: "没有匹配的构建系统。"
                    ))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(28)
                        .accessibilityIdentifier(Accessibility.emptyID)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(controller.buildSystemPaletteItems.indices, id: \.self) { index in
                            row(controller.buildSystemPaletteItems[index], at: index)
                                .id(controller.buildSystemPaletteItems[index].id)
                        }
                    }
                    .padding(6)
                }
            }
            .accessibilityLabel(appLocale.text(Accessibility.results, zh: "构建系统结果"))
            .accessibilityIdentifier(Accessibility.resultsID)
            .onChange(of: controller.selectedBuildSystemPaletteIndex) { _, index in
                guard let index, controller.buildSystemPaletteItems.indices.contains(index)
                else { return }
                withAnimation(AppAccessibility.animation(
                    reduceMotion: reduceMotion, duration: 0.1
                )) {
                    proxy.scrollTo(
                        controller.buildSystemPaletteItems[index].id, anchor: .center
                    )
                }
            }
        }
    }

    private func row(_ item: BuildSystemPaletteItem, at index: Int) -> some View {
        let selected = controller.selectedBuildSystemPaletteIndex == index
        return Button {
            controller.selectBuildSystemPaletteItem(at: index)
            acceptSelection()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                highlightedLabel(item)
                Text(item.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .disabled(isAccepting)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.detail)
        .accessibilityHint(appLocale.text(
            Accessibility.selectHint, zh: "选择并运行此构建系统"
        ))
        .accessibilityIdentifier(Accessibility.itemID(item.id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func highlightedLabel(_ item: BuildSystemPaletteItem) -> Text {
        let label = item.label as NSString
        let matched = Set(item.matchedUTF16Offsets)
        guard !matched.isEmpty else { return Text(item.label) }
        var result = Text("")
        var offset = 0
        while offset < label.length {
            let range = label.rangeOfComposedCharacterSequence(at: offset)
            let fragment = label.substring(with: range)
            let overlaps = (range.location ..< NSMaxRange(range)).contains {
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
        guard !isAccepting else { return }
        switch direction {
        case .down: controller.moveBuildSystemPaletteSelection(by: 1)
        case .up: controller.moveBuildSystemPaletteSelection(by: -1)
        default: break
        }
    }

    private func acceptSelection() {
        guard !isAccepting, controller.selectedBuildSystemPaletteItem != nil else { return }
        isAccepting = true
        Task { @MainActor in
            let accepted = await onAccept()
            if !accepted { isAccepting = false }
        }
    }

    private func dismiss() {
        guard !isAccepting else { return }
        controller.dismissBuildSystemPalette()
        onDismiss()
    }

    private var selectionOpacity: Double {
        colorSchemeContrast == .increased ? 0.36 : 0.18
    }

    enum Accessibility {
        static let palette = "Build System Palette"
        static let query = "Build System Query"
        static let queryHint =
            "Type to filter, use Up and Down to choose, Return to run, and Escape to close."
        static let results = "Build System Results"
        static let selectHint = "Selects and runs this build system"
        static let paletteID = "panel.buildSystem"
        static let queryID = "panel.buildSystem.query"
        static let resultsID = "panel.buildSystem.results"
        static let emptyID = "panel.buildSystem.empty"
        static let closeID = "panel.buildSystem.close"
        static let progressID = "panel.buildSystem.progress"

        static func itemID(_ id: String) -> String {
            "panel.buildSystem.item." + id
        }
    }
}
