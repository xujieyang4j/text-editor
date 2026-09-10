import LumenEditorMobileCore
import SwiftUI
import UIKit

struct NativeTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let fileName: String
    let isEditable: Bool
    @ObservedObject var commands: MobileEditorCommandCenter
    let onSave: () -> Void
    let onShowFind: () -> Void
    let onShowDocumentSwitcher: () -> Void
    let canReplaceContent: (Int) -> Bool
    let onEdit: () -> Void
    let onSelectionChange: (MobileCursorStatus) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LumenTextView {
        let view = LumenTextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.backgroundColor = .systemBackground
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.alwaysBounceVertical = true
        view.isEditable = isEditable
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 36, right: 12)
        view.textContainer.lineFragmentPadding = 4
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityLabel = String(localized: "editor_accessibility_label")
        view.accessibilityIdentifier = "LumenMobileEditor"
        view.commandHandler = { [weak coordinator = context.coordinator] action in
            coordinator?.perform(action, in: view)
        }
        view.routeKeyCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.route(command)
        }
        view.inputAccessoryView = makeAccessory(coordinator: context.coordinator, view: view)
        view.text = text
        view.selectedRange = clamped(selection, to: view.textStorage.length)
        MobileSyntaxHighlighter.apply(to: view, fileName: fileName)
        context.coordinator.lastHighlightedFileName = fileName
        return view
    }

    func updateUIView(_ view: LumenTextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEditable
        if view.markedTextRange == nil {
            var needsHighlight = context.coordinator.lastHighlightedFileName != fileName
            if view.text != text {
                view.text = text
                view.selectedRange = clamped(selection, to: view.textStorage.length)
                needsHighlight = true
            }
            if needsHighlight {
                MobileSyntaxHighlighter.apply(to: view, fileName: fileName)
                context.coordinator.lastHighlightedFileName = fileName
            }
        }
        if view.markedTextRange == nil, view.selectedRange != selection {
            view.selectedRange = clamped(selection, to: view.textStorage.length)
        }
        if let request = commands.request, request.id != context.coordinator.lastRequestID {
            context.coordinator.lastRequestID = request.id
            context.coordinator.perform(request.action, in: view)
        }
    }

    private func makeAccessory(coordinator: Coordinator, view: LumenTextView) -> UIView {
        let bar = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let actions: [(String, String, MobileEditorCommandCenter.Action)] = [
            ("arrow.uturn.backward", String(localized: "undo"), .undo),
            ("arrow.uturn.forward", String(localized: "redo"), .redo),
            ("decrease.indent", String(localized: "outdent"), .outdent),
            ("increase.indent", String(localized: "indent"), .indent),
            ("chevron.down", String(localized: "dismiss_keyboard"), .dismissKeyboard)
        ]
        for (symbol, label, action) in actions {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = label
            button.addAction(UIAction { [weak coordinator, weak view] _ in
                guard let coordinator, let view else { return }
                coordinator.perform(action, in: view)
            }, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
        }
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48)
        ])
        return bar
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextEditor
        var lastRequestID: UUID?
        var lastHighlightedFileName: String?
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: NativeTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            synchronizeCommittedText(textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            let currentLength = textView.textStorage.length
            guard range.location >= 0, range.length >= 0,
                  range.location <= currentLength,
                  range.length <= currentLength - range.location,
                  let prospectiveLength = MobileWorkspaceCapacity.utf16UnitCount(
                      current: currentLength, replacing: range.length,
                      with: text.utf16.count
                  ) else { return false }
            return parent.canReplaceContent(prospectiveLength)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            synchronizeCommittedText(textView)
        }

        private func synchronizeCommittedText(_ textView: UITextView) {
            guard parent.text != textView.text else { return }
            let committedText = textView.text ?? ""
            guard parent.canReplaceContent(textView.textStorage.length) else {
                textView.text = parent.text
                textView.selectedRange = parent.clamped(
                    parent.selection, to: textView.textStorage.length
                )
                MobileSyntaxHighlighter.apply(to: textView, fileName: parent.fileName)
                return
            }
            parent.text = committedText
            parent.onEdit()
            scheduleHighlight(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            publishSelection(from: textView)
        }

        func perform(_ action: MobileEditorCommandCenter.Action, in textView: UITextView) {
            switch action {
            case .focus:
                textView.becomeFirstResponder()
            case .undo:
                guard textView.isEditable else { return }
                textView.undoManager?.undo()
            case .redo:
                guard textView.isEditable else { return }
                textView.undoManager?.redo()
            case .indent:
                guard textView.isEditable else { return }
                if textView.selectedRange.length == 0 {
                    textView.insertText("    " )
                    return
                }
                let result = MobileEditingCore.indent(
                    textView.text ?? "", selection: textView.selectedRange
                )
                replaceDocument(
                    result.text, selection: result.selection, in: textView,
                    actionName: String(localized: "indent")
                )
            case .outdent:
                guard textView.isEditable else { return }
                let result = MobileEditingCore.outdent(
                    textView.text ?? "", selection: textView.selectedRange
                )
                replaceDocument(
                    result.text, selection: result.selection, in: textView,
                    actionName: String(localized: "outdent")
                )
            case .duplicateLines:
                guard textView.isEditable else { return }
                let result = MobileEditingCore.duplicateLines(
                    textView.text ?? "", selection: textView.selectedRange
                )
                replaceDocument(
                    result.text, selection: result.selection, in: textView,
                    actionName: String(localized: "duplicate_lines")
                )
            case let .select(range):
                let length = textView.textStorage.length
                let location = min(max(0, range.location), length)
                textView.selectedRange = NSRange(
                    location: location, length: min(max(0, range.length), length - location)
                )
                textView.scrollRangeToVisible(textView.selectedRange)
                textView.becomeFirstResponder()
                publishSelection(from: textView)
            case let .replaceDocument(text, selection):
                guard textView.isEditable else { return }
                replaceDocument(
                    text, selection: selection, in: textView,
                    actionName: String(localized: "replace")
                )
            case .dismissKeyboard:
                textView.resignFirstResponder()
            }
        }

        private func scheduleHighlight(in textView: UITextView) {
            highlightWorkItem?.cancel()
            guard MobileSyntaxHighlighter.shouldHighlight(textView) else { return }
            let expectedText = textView.text
            let fileName = parent.fileName
            let work = DispatchWorkItem { [weak textView] in
                guard let textView, textView.text == expectedText,
                      textView.markedTextRange == nil else { return }
                MobileSyntaxHighlighter.apply(to: textView, fileName: fileName)
            }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
        }

        private func replaceDocument(
            _ text: String,
            selection: NSRange,
            in textView: UITextView,
            actionName: String
        ) {
            guard textView.markedTextRange == nil else { return }
            let previousText = textView.text ?? ""
            let previousSelection = textView.selectedRange
            guard previousText != text else {
                perform(.select(selection), in: textView)
                return
            }
            guard parent.canReplaceContent(text.utf16.count) else { return }
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.replaceDocument(
                    previousText, selection: previousSelection, in: textView,
                    actionName: actionName
                )
            }
            textView.undoManager?.setActionName(actionName)
            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            textView.textStorage.replaceCharacters(in: fullRange, with: text)
            let length = textView.textStorage.length
            let location = min(max(0, selection.location), length)
            textView.selectedRange = NSRange(
                location: location, length: min(max(0, selection.length), length - location)
            )
            parent.text = text
            parent.onEdit()
            publishSelection(from: textView)
            MobileSyntaxHighlighter.apply(to: textView, fileName: parent.fileName)
            lastHighlightedFileName = parent.fileName
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        private func publishSelection(from textView: UITextView) {
            let selection = textView.selectedRange
            let length = textView.textStorage.length
            parent.selection = selection
            let status = MobileEditingCore.cursorStatus(
                in: textView.text ?? "",
                selection: selection,
                knownUTF16Length: length
            )
            parent.onSelectionChange(status)
        }

        func route(_ command: LumenTextView.AppCommand) {
            switch command {
            case .save: parent.onSave()
            case .find: parent.onShowFind()
            case .switchDocument: parent.onShowDocumentSwitcher()
            }
        }
    }
}

final class LumenTextView: UITextView {
    enum AppCommand { case save, find, switchDocument }
    var commandHandler: ((MobileEditorCommandCenter.Action) -> Void)?
    var routeKeyCommand: ((AppCommand) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(input: "s", modifierFlags: .command, action: #selector(saveKey)),
            UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findKey)),
            UIKeyCommand(input: "p", modifierFlags: .command, action: #selector(switchKey)),
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoKey)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoKey)),
            UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(indentKey)),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(outdentKey)),
            UIKeyCommand(
                input: "d", modifierFlags: [.command, .shift],
                action: #selector(duplicateKey)
            )
        ]
    }

    @objc private func undoKey() { commandHandler?(.undo) }
    @objc private func redoKey() { commandHandler?(.redo) }
    @objc private func indentKey() { commandHandler?(.indent) }
    @objc private func outdentKey() { commandHandler?(.outdent) }
    @objc private func duplicateKey() { commandHandler?(.duplicateLines) }
    @objc private func saveKey() { routeKeyCommand?(.save) }
    @objc private func findKey() { routeKeyCommand?(.find) }
    @objc private func switchKey() { routeKeyCommand?(.switchDocument) }
}
