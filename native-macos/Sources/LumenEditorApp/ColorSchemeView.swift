import SwiftUI

struct ColorSchemeView: View {
    @ObservedObject var controller: ColorSchemeController
    let onDismiss: () -> Void

    @Environment(\.appLocale) private var appLocale
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appLocale.text("Select Color Scheme", zh: "选择配色方案"))
                    .font(.headline)
                Spacer()
                Button(appLocale.text("Done", zh: "完成"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("panel.colorScheme.done")
            }
            .padding(14)
            Divider()
            List(controller.items.indices, id: \.self, selection: Binding(
                get: { controller.selectedIndex },
                set: { index in if let index { controller.selectItem(at: index) } }
            )) { index in
                let item = controller.items[index]
                let selected = controller.selectedIndex == index
                Button {
                    controller.selectItem(at: index)
                    accept()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isCurrent ? "checkmark" : "circle.fill")
                            .foregroundStyle(
                                item.isCurrent
                                    ? currentIndicatorColor : Color.clear
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localizedTitle(for: item))
                            Text(localizedDetail(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                selected
                                    ? Color.accentColor.opacity(selectionOpacity) : .clear
                            )
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
                .tag(index)
                .accessibilityLabel(localizedTitle(for: item))
                .accessibilityValue(
                    item.isCurrent ? appLocale.text("Current", zh: "当前") : ""
                )
                .accessibilityHint(
                    appLocale.text(
                        "Applies this color scheme",
                        zh: "应用此配色方案"
                    )
                )
                .accessibilityIdentifier("panel.colorScheme.item." + item.id)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            .accessibilityLabel(
                appLocale.text("Color Scheme Choices", zh: "配色方案选项")
            )
            .accessibilityIdentifier("panel.colorScheme.list")
        }
        .frame(minWidth: 430, minHeight: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            appLocale.text("Select Color Scheme", zh: "选择配色方案")
        )
        .accessibilityIdentifier("panel.colorScheme")
        .onMoveCommand { direction in
            switch direction {
            case .down: controller.moveSelection(by: 1)
            case .up: controller.moveSelection(by: -1)
            default: break
            }
        }
        .onSubmit(accept)
        .onExitCommand(perform: dismiss)
    }

    private func accept() {
        guard controller.acceptSelection() else { return }
        onDismiss()
    }

    private func dismiss() {
        controller.dismiss()
        onDismiss()
    }

    private func localizedTitle(for item: ColorSchemeItem) -> String {
        switch item.scheme {
        case .dark: return appLocale.text(item.title, zh: "深色")
        case .light: return appLocale.text(item.title, zh: "浅色")
        case .solarizedDark: return appLocale.text(item.title, zh: "Solarized 深色")
        case .dracula: return appLocale.text(item.title, zh: "Dracula")
        }
    }

    private func localizedDetail(for item: ColorSchemeItem) -> String {
        switch item.scheme {
        case .dark:
            return appLocale.text(item.detail, zh: "默认深色界面和编辑器")
        case .light:
            return appLocale.text(item.detail, zh: "浅色界面和编辑器")
        case .solarizedDark:
            return appLocale.text(item.detail, zh: "低对比度 Solarized 配色")
        case .dracula:
            return appLocale.text(item.detail, zh: "紫色 Dracula 配色")
        }
    }

    private var selectionOpacity: Double {
        colorSchemeContrast == .increased ? 0.34 : 0.14
    }

    private var currentIndicatorColor: Color {
        colorSchemeContrast == .increased ? .primary : .accentColor
    }
}
