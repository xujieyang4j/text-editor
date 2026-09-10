import AppKit
import LumenEditorCore

/// Colors for the plain-text editor surface. Values mirror the Electron
/// CodeMirror themes while `appearanceName` keeps native controls compatible
/// with the window-level light/dark preference.
struct NativeEditorPalette: Equatable {
    let appearanceName: NSAppearance.Name
    let background: NSColor
    let foreground: NSColor
    let insertionPoint: NSColor
    let selectionBackground: NSColor
    let currentLineBackground: NSColor
    let selectionMatchBackground: NSColor
    let matchingBracketBorder: NSColor
    let matchingBracketLineWidth: CGFloat
    let gutterBackground: NSColor
    let gutterForeground: NSColor
    let ruler: NSColor
    let whitespace: NSColor
    let indentGuide: NSColor
    let trailingWhitespace: NSColor
    let diffAdded: NSColor
    let diffModified: NSColor
    let diffDeleted: NSColor
    let diagnosticError: NSColor
    let diagnosticWarning: NSColor
    let diagnosticInformation: NSColor
    let syntaxKeyword: NSColor
    let syntaxString: NSColor
    let syntaxNumber: NSColor
    let syntaxComment: NSColor
    let syntaxType: NSColor
    let syntaxConstant: NSColor
    let syntaxMarkup: NSColor

    /// `theme` controls the containing AppKit appearance for compatibility;
    /// `colorScheme` remains authoritative for editor-surface colors.
    static func make(
        colorScheme: EditorColorScheme,
        compatibleWith theme: EditorTheme,
        increasedContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    ) -> NativeEditorPalette {
        let appearanceName: NSAppearance.Name = theme == .dark ? .darkAqua : .aqua
        switch colorScheme {
        case .dark:
            NativeEditorPalette(
                appearanceName: appearanceName,
                background: color(0x282C34),
                foreground: color(0xABB2BF),
                insertionPoint: color(0x528BFF),
                selectionBackground: color(increasedContrast ? 0x50596B : 0x3E4451),
                currentLineBackground: color(
                    increasedContrast ? 0xFFFFFF : 0xFFFFFF,
                    alpha: increasedContrast ? 0.11 : 0.055
                ),
                selectionMatchBackground: color(
                    0x528BFF, alpha: increasedContrast ? 0.34 : 0.20
                ),
                matchingBracketBorder: color(
                    increasedContrast ? 0xFFFFFF : 0x61AFEF,
                    alpha: increasedContrast ? 1 : 0.90
                ),
                matchingBracketLineWidth: increasedContrast ? 2 : 1.25,
                gutterBackground: color(0x282C34),
                gutterForeground: color(increasedContrast ? 0xB8C0CC : 0x7D8799),
                ruler: color(0x5C6370, alpha: increasedContrast ? 0.95 : 0.60),
                whitespace: color(0xAAB2BF, alpha: increasedContrast ? 0.90 : 0.62),
                indentGuide: color(0x667085, alpha: increasedContrast ? 1 : 0.82),
                trailingWhitespace: color(0xFF5A5A, alpha: increasedContrast ? 0.48 : 0.25),
                diffAdded: color(0x3FB950), diffModified: color(0x58A6FF),
                diffDeleted: color(0xF0883E),
                diagnosticError: color(0xF85149),
                diagnosticWarning: color(0xD29922),
                diagnosticInformation: color(0x58A6FF),
                syntaxKeyword: color(0xC678DD), syntaxString: color(0x98C379),
                syntaxNumber: color(0xD19A66), syntaxComment: color(0x7F848E),
                syntaxType: color(0xE5C07B), syntaxConstant: color(0x56B6C2),
                syntaxMarkup: color(0xE06C75)
            )
        case .light:
            NativeEditorPalette(
                appearanceName: appearanceName,
                background: color(0xFFFFFF),
                foreground: color(0x24292F),
                insertionPoint: color(0x0969DA),
                selectionBackground: color(increasedContrast ? 0x78BFFF : 0xADD6FF),
                currentLineBackground: color(
                    increasedContrast ? 0x0969DA : 0x24292F,
                    alpha: increasedContrast ? 0.12 : 0.045
                ),
                selectionMatchBackground: color(
                    0x0969DA, alpha: increasedContrast ? 0.24 : 0.14
                ),
                matchingBracketBorder: color(
                    increasedContrast ? 0x0550AE : 0x0969DA,
                    alpha: increasedContrast ? 1 : 0.88
                ),
                matchingBracketLineWidth: increasedContrast ? 2 : 1.25,
                gutterBackground: color(0xF6F8FA),
                gutterForeground: color(increasedContrast ? 0x343A40 : 0x57606A),
                ruler: color(0x8C959F, alpha: increasedContrast ? 1 : 0.82),
                whitespace: color(0x57606A, alpha: increasedContrast ? 0.86 : 0.52),
                indentGuide: color(0x8C959F, alpha: increasedContrast ? 1 : 0.90),
                trailingWhitespace: color(0xD1242F, alpha: increasedContrast ? 0.48 : 0.25),
                diffAdded: color(0x1A7F37), diffModified: color(0x0969DA),
                diffDeleted: color(0xBC4C00),
                diagnosticError: color(0xCF222E),
                diagnosticWarning: color(0x9A6700),
                diagnosticInformation: color(0x0969DA),
                syntaxKeyword: color(0x8250DF), syntaxString: color(0x0A3069),
                syntaxNumber: color(0x953800), syntaxComment: color(0x6E7781),
                syntaxType: color(0x0550AE), syntaxConstant: color(0x0550AE),
                syntaxMarkup: color(0xCF222E)
            )
        case .solarizedDark:
            NativeEditorPalette(
                appearanceName: appearanceName,
                background: color(0x002B36),
                foreground: color(0x93A1A1),
                insertionPoint: color(0xB58900),
                selectionBackground: color(increasedContrast ? 0x145363 : 0x073642),
                currentLineBackground: color(
                    0x93A1A1, alpha: increasedContrast ? 0.14 : 0.065
                ),
                selectionMatchBackground: color(
                    0x268BD2, alpha: increasedContrast ? 0.34 : 0.20
                ),
                matchingBracketBorder: color(
                    increasedContrast ? 0xEEE8D5 : 0xB58900,
                    alpha: increasedContrast ? 1 : 0.92
                ),
                matchingBracketLineWidth: increasedContrast ? 2 : 1.25,
                gutterBackground: color(0x073642),
                gutterForeground: color(increasedContrast ? 0xB8C7C7 : 0x839496),
                ruler: color(0x839496, alpha: increasedContrast ? 1 : 0.78),
                whitespace: color(0x93A1A1, alpha: increasedContrast ? 0.92 : 0.62),
                indentGuide: color(0x839496, alpha: increasedContrast ? 1 : 0.70),
                trailingWhitespace: color(0xFF5A5A, alpha: increasedContrast ? 0.50 : 0.25),
                diffAdded: color(0x859900), diffModified: color(0x268BD2),
                diffDeleted: color(0xCB4B16),
                diagnosticError: color(0xDC322F),
                diagnosticWarning: color(0xB58900),
                diagnosticInformation: color(0x268BD2),
                syntaxKeyword: color(0x859900), syntaxString: color(0x2AA198),
                syntaxNumber: color(0xD33682), syntaxComment: color(0x586E75),
                syntaxType: color(0xB58900), syntaxConstant: color(0xCB4B16),
                syntaxMarkup: color(0x268BD2)
            )
        case .dracula:
            NativeEditorPalette(
                appearanceName: appearanceName,
                background: color(0x282A36),
                foreground: color(0xF8F8F2),
                insertionPoint: color(0xFF79C6),
                selectionBackground: color(increasedContrast ? 0x5B607A : 0x44475A),
                currentLineBackground: color(
                    0xF8F8F2, alpha: increasedContrast ? 0.12 : 0.055
                ),
                selectionMatchBackground: color(
                    0x8BE9FD, alpha: increasedContrast ? 0.32 : 0.18
                ),
                matchingBracketBorder: color(
                    increasedContrast ? 0xFFFFFF : 0xFFB86C,
                    alpha: increasedContrast ? 1 : 0.92
                ),
                matchingBracketLineWidth: increasedContrast ? 2 : 1.25,
                gutterBackground: color(0x282A36),
                gutterForeground: color(increasedContrast ? 0xB9C2EE : 0x6272A4),
                ruler: color(0x8292C9, alpha: increasedContrast ? 1 : 0.72),
                whitespace: color(0xD7D9E3, alpha: increasedContrast ? 0.92 : 0.62),
                indentGuide: color(0x8292C9, alpha: increasedContrast ? 1 : 0.72),
                trailingWhitespace: color(0xFF5A5A, alpha: increasedContrast ? 0.50 : 0.25),
                diffAdded: color(0x50FA7B), diffModified: color(0x8BE9FD),
                diffDeleted: color(0xFFB86C),
                diagnosticError: color(0xFF5555),
                diagnosticWarning: color(0xF1FA8C),
                diagnosticInformation: color(0x8BE9FD),
                syntaxKeyword: color(0xFF79C6), syntaxString: color(0xF1FA8C),
                syntaxNumber: color(0xBD93F9), syntaxComment: color(0x6272A4),
                syntaxType: color(0x8BE9FD), syntaxConstant: color(0xBD93F9),
                syntaxMarkup: color(0xFF79C6)
            )
        }
    }

    func syntaxColor(for kind: NativeSyntaxHighlighter.Kind) -> NSColor {
        switch kind {
        case .keyword: syntaxKeyword
        case .string: syntaxString
        case .number: syntaxNumber
        case .comment: syntaxComment
        case .type: syntaxType
        case .constant: syntaxConstant
        case .markup: syntaxMarkup
        }
    }

    func diagnosticColor(
        for severity: NativeTextEditorVisualPlanner.DiagnosticSeverity
    ) -> NSColor {
        switch severity {
        case .error: diagnosticError
        case .warning: diagnosticWarning
        case .information: diagnosticInformation
        }
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
