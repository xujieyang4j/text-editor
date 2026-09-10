import Combine
import Foundation
import LumenEditorCore

enum DocumentFormatOperation: String, Equatable, Sendable {
    case openUsingEncoding
    case selectSaveEncoding
    case selectLineEnding
    case reopenUsingEncoding

    var commandID: String {
        switch self {
        case .openUsingEncoding: "open-file-with-encoding"
        case .selectSaveEncoding: "select-encoding"
        case .selectLineEnding: "select-line-ending"
        case .reopenUsingEncoding: "reopen-with-encoding"
        }
    }

    var title: String {
        switch self {
        case .openUsingEncoding: "Open File with Encoding"
        case .selectSaveEncoding: "Select Encoding for Save"
        case .selectLineEnding: "Select Line Ending"
        case .reopenUsingEncoding: "Reopen with Encoding"
        }
    }
}

enum DocumentFormatChoice: Equatable, Sendable, Identifiable {
    case automaticEncoding
    case encoding(TextEncoding)
    case lineEnding(LineEnding)

    var id: String {
        switch self {
        case .automaticEncoding: "encoding:auto"
        case let .encoding(value): "encoding:\(value.rawValue)"
        case let .lineEnding(value): "eol:\(value.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .automaticEncoding: "Auto Detect"
        case let .encoding(value): value.displayName
        case let .lineEnding(value): value.rawValue
        }
    }
}

struct DocumentFormatPickerItem: Identifiable, Equatable, Sendable {
    let choice: DocumentFormatChoice
    let isCurrent: Bool

    var id: String { choice.id }
    var title: String { choice.title }
}

/// Owns the palette shared by the four encoding and line-ending commands.
///
/// The controller captures the active document when a document-scoped palette
/// opens and checks the identity again before applying a choice. This prevents
/// a stale sheet from changing a tab that became active underneath it.
@MainActor
final class DocumentFormatController: ObservableObject {
    typealias ActiveDocument = @MainActor () -> EditorDocument?
    typealias OpenUsingEncoding = @MainActor (TextEncoding) async -> Void
    typealias ApplySaveEncoding = @MainActor (EditorDocument, TextEncoding) -> Bool
    typealias ApplyLineEnding = @MainActor (EditorDocument, LineEnding) -> Bool
    typealias RequestReopen = @MainActor (EditorDocument, TextEncoding?) -> Bool
    typealias PresentationAction = @MainActor () -> Void

    static let commandIDs = DocumentFormatOperation.allCommandIDs
    static let maximumQueryUTF16Count = 128

    @Published var query = "" {
        didSet {
            let bounded = Self.boundedPrefix(
                query, maximumUTF16Count: Self.maximumQueryUTF16Count
            )
            if bounded != query { query = bounded }
            guard query != oldValue else { return }
            rebuildItems(preserving: selectedItem?.id)
        }
    }
    @Published private(set) var operation: DocumentFormatOperation?
    @Published private(set) var items: [DocumentFormatPickerItem] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var isPresented = false
    @Published private(set) var presentedDocumentID: String?

    private let activeDocument: ActiveDocument
    private let openUsingEncoding: OpenUsingEncoding
    private let applySaveEncoding: ApplySaveEncoding
    private let applyLineEnding: ApplyLineEnding
    private let requestReopen: RequestReopen

    init(
        activeDocument: @escaping ActiveDocument,
        openUsingEncoding: @escaping OpenUsingEncoding,
        applySaveEncoding: @escaping ApplySaveEncoding,
        applyLineEnding: @escaping ApplyLineEnding,
        requestReopen: @escaping RequestReopen
    ) {
        self.activeDocument = activeDocument
        self.openUsingEncoding = openUsingEncoding
        self.applySaveEncoding = applySaveEncoding
        self.applyLineEnding = applyLineEnding
        self.requestReopen = requestReopen
    }

    var selectedItem: DocumentFormatPickerItem? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    @discardableResult
    func present(_ requestedOperation: DocumentFormatOperation) -> Bool {
        switch requestedOperation {
        case .openUsingEncoding:
            presentedDocumentID = nil
        case .selectSaveEncoding, .selectLineEnding:
            guard let document = activeDocument(), !document.isSaving else { return false }
            presentedDocumentID = document.sessionDocumentID
        case .reopenUsingEncoding:
            guard let document = activeDocument(), document.fileURL != nil,
                  !document.isSaving else { return false }
            presentedDocumentID = document.sessionDocumentID
        }
        operation = requestedOperation
        query = ""
        isPresented = true
        rebuildItems()
        return true
    }

    func dismiss() {
        isPresented = false
        operation = nil
        presentedDocumentID = nil
        query = ""
        items = []
        selectedIndex = nil
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex.flatMap { items.indices.contains($0) ? $0 : nil } ?? 0
        selectedIndex = ((current + delta) % items.count + items.count) % items.count
    }

    /// Consumes the current presentation before invoking an action. The caller
    /// may therefore close the SwiftUI sheet synchronously and safely present an
    /// NSOpenPanel or destructive-reopen confirmation from the callback.
    @discardableResult
    func acceptSelection(beforePerform: PresentationAction = {}) async -> Bool {
        guard let operation, let choice = selectedItem?.choice else { return false }
        let document: EditorDocument?
        if operation == .openUsingEncoding {
            document = nil
        } else {
            guard let active = activeDocument(),
                  active.sessionDocumentID == presentedDocumentID else { return false }
            document = active
        }

        dismiss()
        beforePerform()
        await Task.yield()

        switch (operation, choice) {
        case let (.openUsingEncoding, .encoding(encoding)):
            await openUsingEncoding(encoding)
            return true
        case let (.selectSaveEncoding, .encoding(encoding)):
            guard let document else { return false }
            return applySaveEncoding(document, encoding)
        case let (.selectLineEnding, .lineEnding(lineEnding)):
            guard let document else { return false }
            return applyLineEnding(document, lineEnding)
        case (.reopenUsingEncoding, .automaticEncoding):
            guard let document else { return false }
            return requestReopen(document, nil)
        case let (.reopenUsingEncoding, .encoding(encoding)):
            guard let document else { return false }
            return requestReopen(document, encoding)
        default:
            return false
        }
    }

    @discardableResult
    func registerCommands(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        presentPalette: @escaping PresentationAction = {}
    ) throws -> [CommandHandlerToken] {
        var tokens: [CommandHandlerToken] = []
        do {
            for operation in DocumentFormatOperation.allCasesForCommands {
                let token = try router.register(
                    operation.commandID,
                    replaceExisting: replaceExisting,
                    enablement: { [weak self] context in
                        guard let self else {
                            return .disabled(reason: "Document format selection unavailable")
                        }
                        switch operation {
                        case .openUsingEncoding:
                            return .enabled
                        case .selectSaveEncoding, .selectLineEnding:
                            return context.availableRequirements.contains(.document)
                                && self.activeDocument()?.isSaving == false
                                ? .enabled : .disabled(reason: "No editable document")
                        case .reopenUsingEncoding:
                            return context.availableRequirements.contains(.savedDocument)
                                && self.activeDocument()?.isSaving == false
                                ? .enabled : .disabled(reason: "No saved document")
                        }
                    },
                    handler: { [weak self] _ in
                        await prepareForCommand()
                        guard let self else {
                            throw CommandHandlerSignal.unavailable(
                                reason: "Document format selection unavailable"
                            )
                        }
                        guard self.present(operation) else {
                            throw CommandHandlerSignal.noChange
                        }
                        presentPalette()
                    }
                )
                tokens.append(token)
            }
            return tokens
        } catch {
            for token in tokens { _ = router.unregister(token) }
            throw error
        }
    }

    private func rebuildItems(preserving preferredID: String? = nil) {
        guard isPresented, let operation else {
            items = []
            selectedIndex = nil
            return
        }
        let document = activeDocument()
        let candidates: [DocumentFormatPickerItem]
        switch operation {
        case .openUsingEncoding:
            candidates = TextEncoding.allCases.map {
                DocumentFormatPickerItem(choice: .encoding($0), isCurrent: false)
            }
        case .selectSaveEncoding:
            guard document?.sessionDocumentID == presentedDocumentID else {
                items = []
                selectedIndex = nil
                return
            }
            let current = document?.encoding
            candidates = orderedEncodings(current: current).map {
                DocumentFormatPickerItem(choice: .encoding($0), isCurrent: $0 == current)
            }
        case .selectLineEnding:
            guard document?.sessionDocumentID == presentedDocumentID else {
                items = []
                selectedIndex = nil
                return
            }
            let current = document?.effectiveLineEnding
            let ordered = current.map { value in
                [value] + LineEnding.allCases.filter { $0 != value }
            } ?? LineEnding.allCases
            candidates = ordered.map {
                DocumentFormatPickerItem(choice: .lineEnding($0), isCurrent: $0 == current)
            }
        case .reopenUsingEncoding:
            guard document?.sessionDocumentID == presentedDocumentID else {
                items = []
                selectedIndex = nil
                return
            }
            let current = document?.savedEncoding
            var values = [DocumentFormatPickerItem(
                choice: .automaticEncoding, isCurrent: document?.encodingLocked == false
            )]
            values += orderedEncodings(current: current).map {
                DocumentFormatPickerItem(
                    choice: .encoding($0),
                    isCurrent: document?.encodingLocked == true && $0 == current
                )
            }
            candidates = values
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        items = needle.isEmpty ? candidates : candidates.filter { item in
            item.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil
            ).contains(needle)
        }
        if let preferredID, let index = items.firstIndex(where: { $0.id == preferredID }) {
            selectedIndex = index
        } else if let index = items.firstIndex(where: \.isCurrent) {
            selectedIndex = index
        } else {
            selectedIndex = items.isEmpty ? nil : 0
        }
    }

    private func orderedEncodings(current: TextEncoding?) -> [TextEncoding] {
        guard let current else { return TextEncoding.allCases }
        return [current] + TextEncoding.allCases.filter { $0 != current }
    }

    private static func boundedPrefix(
        _ value: String, maximumUTF16Count: Int
    ) -> String {
        guard value.utf16.count > maximumUTF16Count else { return value }
        var end = value.startIndex
        var count = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let width = value[end..<next].utf16.count
            guard count + width <= maximumUTF16Count else { break }
            count += width
            end = next
        }
        return String(value[..<end])
    }
}

private extension DocumentFormatOperation {
    static let allCasesForCommands: [Self] = [
        .openUsingEncoding, .selectSaveEncoding, .selectLineEnding, .reopenUsingEncoding
    ]

    static let allCommandIDs = allCasesForCommands.map(\.commandID)
}
