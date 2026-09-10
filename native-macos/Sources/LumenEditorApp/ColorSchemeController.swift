import Combine
import Foundation
import LumenEditorCore

struct ColorSchemeItem: Identifiable, Equatable, Sendable {
    let scheme: EditorColorScheme
    let title: String
    let detail: String
    let isCurrent: Bool

    var id: String { scheme.rawValue }
}

@MainActor
final class ColorSchemeController: ObservableObject {
    typealias CurrentScheme = @MainActor () -> EditorColorScheme
    typealias ApplyScheme = @MainActor (EditorColorScheme) -> Void

    @Published private(set) var items: [ColorSchemeItem] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var isPresented = false

    private let currentScheme: CurrentScheme
    private let applyScheme: ApplyScheme

    init(
        currentScheme: @escaping CurrentScheme,
        apply: @escaping ApplyScheme
    ) {
        self.currentScheme = currentScheme
        applyScheme = apply
    }

    convenience init(settings: SettingsController) {
        self.init(
            currentScheme: { settings.settings.colorScheme },
            apply: { scheme in
                settings.update { value in
                    value.colorScheme = scheme
                    value.theme = scheme == .light ? .light : .dark
                }
            }
        )
    }

    @discardableResult
    func present() -> Bool {
        isPresented = true
        rebuildItems()
        return true
    }

    func dismiss() {
        isPresented = false
        items = []
        selectedIndex = nil
    }

    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { selectedIndex = nil; return }
        let current = selectedIndex.flatMap { items.indices.contains($0) ? $0 : nil } ?? 0
        selectedIndex = ((current + delta) % items.count + items.count) % items.count
    }

    @discardableResult
    func acceptSelection() -> Bool {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return false }
        applyScheme(items[selectedIndex].scheme)
        dismiss()
        return true
    }

    @discardableResult
    func registerCommand(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        presentPanel: @escaping @MainActor () -> Void = {}
    ) throws -> CommandHandlerToken {
        try router.register(
            "select-color-scheme", replaceExisting: replaceExisting
        ) { [weak self] _ in
            await prepareForCommand()
            guard let self else {
                throw CommandHandlerSignal.unavailable(
                    reason: "Color scheme selection unavailable"
                )
            }
            guard self.present() else { throw CommandHandlerSignal.noChange }
            presentPanel()
        }
    }

    private func rebuildItems() {
        let current = currentScheme()
        let ordered = [current] + EditorColorScheme.allCases.filter { $0 != current }
        items = ordered.map { scheme in
            let copy = Self.copy(for: scheme)
            return ColorSchemeItem(
                scheme: scheme, title: copy.title, detail: copy.detail,
                isCurrent: scheme == current
            )
        }
        selectedIndex = items.isEmpty ? nil : 0
    }

    private static func copy(
        for scheme: EditorColorScheme
    ) -> (title: String, detail: String) {
        switch scheme {
        case .dark: ("Dark", "Default dark interface and editor")
        case .light: ("Light", "Light interface and editor")
        case .solarizedDark: ("Solarized Dark", "Low-contrast Solarized palette")
        case .dracula: ("Dracula", "Purple Dracula palette")
        }
    }
}
