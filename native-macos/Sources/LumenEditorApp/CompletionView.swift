import AppKit
import LumenEditorCore

@MainActor
final class CompletionPopoverPresenter {
    private let popover = NSPopover()
    private let controller = CompletionListViewController()
    private weak var textView: NSTextView?
    private var onAccept: (() -> Void)?
    private var isShowingOrUpdating = false

    init() {
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: 360, height: 220)
        popover.contentViewController = controller
    }

    var isShown: Bool { popover.isShown }

    func show(
        _ presentation: CompletionPresentation, in textView: NSTextView,
        locale: EditorLocale, onSelect: @escaping (Int) -> Void,
        onAccept: @escaping () -> Void
    ) {
        guard !isShowingOrUpdating else { return }
        isShowingOrUpdating = true
        defer { isShowingOrUpdating = false }
        self.textView = textView
        self.onAccept = onAccept
        controller.update(
            presentation, locale: locale, onSelect: onSelect
        ) { [weak self] in self?.onAccept?() }
        guard let rect = caretRect(in: textView) else { return }
        if !popover.isShown {
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        }
    }

    func dismiss() {
        popover.close()
        textView = nil
        onAccept = nil
    }

    private func caretRect(in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let textLength = (textView.string as NSString).length
        let character = min(textLength, max(0, textView.selectedRange().location))
        let glyph = character < textLength
            ? layoutManager.glyphIndexForCharacter(at: character)
            : layoutManager.numberOfGlyphs
        var rect: NSRect
        if glyph < layoutManager.numberOfGlyphs {
            rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer
            )
        } else {
            rect = layoutManager.extraLineFragmentRect
        }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        if rect.height <= 0 { rect.size.height = textView.font?.pointSize ?? 14 }
        if rect.width <= 0 { rect.size.width = 1 }
        return rect
    }
}

@MainActor
private final class CompletionListViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var suggestions: [CompletionSuggestion] = []
    private var locale = EditorLocale.zhCN
    private var onAccept: (() -> Void)?
    private var onSelect: ((Int) -> Void)?
    private var isSynchronizingSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.allowsEmptySelection = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(acceptRow)
        tableView.action = #selector(selectRow)
        tableView.setAccessibilityIdentifier(AppAccessibility.id("completion list"))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
    }

    func update(
        _ presentation: CompletionPresentation, locale: EditorLocale,
        onSelect: @escaping (Int) -> Void,
        onAccept: @escaping () -> Void
    ) {
        loadViewIfNeeded()
        suggestions = presentation.suggestions
        self.locale = locale
        self.onSelect = onSelect
        self.onAccept = onAccept
        tableView.reloadData()
        if suggestions.indices.contains(presentation.selectedIndex) {
            isSynchronizingSelection = true
            defer { isSynchronizingSelection = false }
            if tableView.selectedRow != presentation.selectedIndex {
                tableView.selectRowIndexes(
                    IndexSet(integer: presentation.selectedIndex),
                    byExtendingSelection: false
                )
            }
            tableView.scrollRowToVisible(presentation.selectedIndex)
        }
        tableView.setAccessibilityLabel(locale.text(
            "Code completion suggestions", zh: "代码补全建议"
        ))
        tableView.setAccessibilityHelp(locale.text(
            "Use Up and Down Arrow to choose, Return or Tab to insert, and Escape to close.",
            zh: "使用上、下方向键选择，按回车或 Tab 插入，按 Escape 关闭。"
        ))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard suggestions.indices.contains(row) else { return nil }
        let item = suggestions[row]
        let identifier = NSUserInterfaceItemIdentifier("completion.row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let field: NSTextField
        if let existing = cell.textField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let detail = item.detail.flatMap { $0.isEmpty ? nil : $0 }
        field.stringValue = detail.map { "\(item.label) — \($0)" } ?? item.label
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.toolTip = item.documentation
        cell.setAccessibilityLabel([item.label, detail, item.documentation]
            .compactMap { $0 }.joined(separator: ", "))
        cell.setAccessibilityIdentifier(AppAccessibility.id(
            "completion row \(row)"
        ))
        return cell
    }

    @objc private func acceptRow() { onAccept?() }
    @objc private func selectRow() {
        guard !isSynchronizingSelection, tableView.selectedRow >= 0 else { return }
        onSelect?(tableView.selectedRow)
    }
}
