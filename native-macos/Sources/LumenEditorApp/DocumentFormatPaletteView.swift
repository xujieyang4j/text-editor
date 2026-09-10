import SwiftUI

struct DocumentFormatPaletteView: View {
    @Environment(\.appLocale) private var appLocale
    @ObservedObject var controller: DocumentFormatController
    let onDismiss: () -> Void

    @FocusState private var queryIsFocused: Bool

    init(
        controller: DocumentFormatController,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "textformat")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(operationTitle, text: $controller.query)
                    .textFieldStyle(.plain)
                    .focused($queryIsFocused)
                    .onSubmit(acceptSelection)
                    .accessibilityLabel(appLocale.text(
                        Accessibility.query, zh: "文档格式查询"
                    ))
                    .accessibilityHint(appLocale.text(
                        Accessibility.queryHint,
                        zh: "输入内容以筛选，使用上、下方向键选择，按回车键确认，按 Esc 键关闭。"
                    ))
                    .accessibilityIdentifier(Accessibility.queryID)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(appLocale.text("Close", zh: "关闭"))
                .accessibilityLabel(appLocale.text("Close", zh: "关闭"))
                .accessibilityHint(appLocale.text(
                    "Closes the document format palette.",
                    zh: "关闭文档格式面板。"
                ))
                .accessibilityIdentifier(Accessibility.closeID)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if controller.items.isEmpty {
                        Text(appLocale.text(
                            "No matching formats.", zh: "没有匹配的格式。"
                        ))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(28)
                            .accessibilityLabel(appLocale.text(
                                Accessibility.emptyResults, zh: "没有匹配的格式"
                            ))
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
                .accessibilityLabel(appLocale.text(
                    Accessibility.results, zh: "文档格式选项"
                ))
                .accessibilityIdentifier(Accessibility.resultsID)
                .onChange(of: controller.selectedIndex) { _, index in
                    guard let index, controller.items.indices.contains(index) else { return }
                    proxy.scrollTo(controller.items[index].id, anchor: .center)
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 500, maxWidth: 640)
        .frame(minHeight: 260, idealHeight: 400, maxHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocale.text(
            Accessibility.palette, zh: "文档格式面板"
        ))
        .accessibilityIdentifier(Accessibility.paletteID)
        .onAppear { queryIsFocused = true }
        .onMoveCommand { direction in
            switch direction {
            case .down: controller.moveSelection(by: 1)
            case .up: controller.moveSelection(by: -1)
            default: break
            }
        }
        .onExitCommand(perform: dismiss)
    }

    private func row(_ item: DocumentFormatPickerItem, at index: Int) -> some View {
        let selected = controller.selectedIndex == index
        let title = itemTitle(item)
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
                Text(title)
                Spacer(minLength: 8)
                if item.isCurrent {
                    Text(appLocale.text("Current", zh: "当前"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(
            item.isCurrent
                ? appLocale.text("Current format", zh: "当前格式") : ""
        )
        .accessibilityHint(appLocale.text(
            Accessibility.selectHint, zh: "选择此文档格式选项"
        ))
        .accessibilityIdentifier(Accessibility.itemID(item.id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var operationTitle: String {
        guard let operation = controller.operation else {
            return appLocale.text("Document Format", zh: "文档格式")
        }
        switch operation {
        case .openUsingEncoding:
            return appLocale.text("Open File with Encoding", zh: "以编码打开文件")
        case .selectSaveEncoding:
            return appLocale.text("Select Encoding for Save", zh: "选择保存编码")
        case .selectLineEnding:
            return appLocale.text("Select Line Ending", zh: "选择换行符")
        case .reopenUsingEncoding:
            return appLocale.text("Reopen with Encoding", zh: "以编码重新打开")
        }
    }

    private func itemTitle(_ item: DocumentFormatPickerItem) -> String {
        switch item.choice {
        case .automaticEncoding:
            appLocale.text("Auto Detect", zh: "自动检测")
        case let .encoding(encoding):
            encoding.displayName
        case let .lineEnding(lineEnding):
            lineEnding.rawValue
        }
    }

    private func acceptSelection() {
        Task { @MainActor in
            _ = await controller.acceptSelection(beforePerform: onDismiss)
        }
    }

    private func dismiss() {
        controller.dismiss()
        onDismiss()
    }

    enum Accessibility {
        static let palette = "Document Format Palette"
        static let query = "Document Format Query"
        static let queryHint =
            "Type to filter, use Up and Down to choose, Return to select, and Escape to close."
        static let results = "Document Format Choices"
        static let emptyResults = "No Matching Document Formats"
        static let selectHint = "Selects this document format option"
        static let paletteID = "panel.documentFormat"
        static let queryID = "panel.documentFormat.query"
        static let resultsID = "panel.documentFormat.results"
        static let emptyID = "panel.documentFormat.empty"
        static let closeID = "panel.documentFormat.close"

        static func itemID(_ id: String) -> String {
            "panel.documentFormat.item." + id
        }
    }
}
