import Combine
import Foundation

@MainActor
final class MobileEditorCommandCenter: ObservableObject {
    struct Request {
        let id = UUID()
        let action: Action
    }

    enum Action {
        case focus
        case undo
        case redo
        case indent
        case outdent
        case duplicateLines
        case select(NSRange)
        case replaceDocument(String, selection: NSRange)
        case dismissKeyboard
    }

    @Published private(set) var request: Request?

    func send(_ action: Action) { request = Request(action: action) }
}
