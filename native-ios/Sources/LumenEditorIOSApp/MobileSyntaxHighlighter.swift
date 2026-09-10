import UIKit

/// A bounded lexical highlighter. It never edits characters and yields to IME composition.
enum MobileSyntaxHighlighter {
    static let maximumUTF16Length = 1_000_000

    private struct Rule {
        let expression: NSRegularExpression
        let color: UIColor
    }

    static func apply(to textView: UITextView, fileName: String) {
        guard textView.markedTextRange == nil else { return }
        let storageLength = textView.textStorage.length
        let fullRange = NSRange(location: 0, length: storageLength)
        guard storageLength <= maximumUTF16Length else {
            textView.textStorage.setAttributes(baseAttributes(), range: fullRange)
            return
        }
        let text = textView.text ?? ""
        let selectedRange = textView.selectedRange
        textView.undoManager?.disableUndoRegistration()
        defer { textView.undoManager?.enableUndoRegistration() }
        textView.textStorage.beginEditing()
        textView.textStorage.setAttributes(baseAttributes(), range: fullRange)
        for rule in rules(for: fileName) {
            rule.expression.enumerateMatches(in: text, range: fullRange) { result, _, _ in
                guard let result else { return }
                textView.textStorage.addAttribute(
                    .foregroundColor, value: rule.color, range: result.range
                )
            }
        }
        textView.textStorage.endEditing()
        textView.selectedRange = selectedRange
        textView.typingAttributes = baseAttributes()
    }

    static func shouldHighlight(_ textView: UITextView) -> Bool {
        textView.textStorage.length <= maximumUTF16Length
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: UIFontMetrics(forTextStyle: .body).scaledFont(
                for: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            ),
            .foregroundColor: UIColor.label
        ]
    }

    private static func rules(for fileName: String) -> [Rule] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let keywords: String
        switch ext {
        case "swift":
            keywords = "actor|associatedtype|async|await|break|case|catch|class|continue|default|defer|do|else|enum|extension|fallthrough|false|for|func|guard|if|import|in|init|inout|is|let|nil|nonisolated|protocol|repeat|return|self|some|static|struct|super|switch|throw|throws|true|try|typealias|var|where|while"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            keywords = "async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|false|finally|for|from|function|if|import|in|instanceof|interface|let|new|null|of|return|static|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|with|yield"
        case "py":
            keywords = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield"
        default:
            keywords = "break|case|class|const|continue|default|else|enum|false|for|func|function|if|import|let|nil|null|return|static|struct|switch|true|var|while"
        }
        return [
            rule("\\b(?:\(keywords))\\b", color: .systemPurple),
            rule("(?:\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')", color: .systemRed),
            rule("(?m)//.*$|#(?![A-Fa-f0-9]{3,8}\\b).*$|/\\*[\\s\\S]*?\\*/", color: .systemGreen),
            rule("\\b(?:0x[0-9A-Fa-f]+|[0-9]+(?:\\.[0-9]+)?)\\b", color: .systemOrange)
        ].compactMap { $0 }
    }

    private static func rule(_ pattern: String, color: UIColor) -> Rule? {
        try? Rule(expression: NSRegularExpression(pattern: pattern), color: color)
    }
}
