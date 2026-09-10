import AppKit
import SwiftUI

/// Shared accessibility conventions for native UI. Visible labels may change
/// with locale, but identifiers stay language-independent for UI automation.
enum AppAccessibility {
    private static let prefix = "lumen"

    static func id(_ component: String) -> String {
        let normalized = component
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .joined(separator: ".")
        return normalized.isEmpty ? prefix : "\(prefix).\(normalized)"
    }

    /// Small state transitions should disappear when Reduce Motion is enabled.
    static func animation(
        reduceMotion: Bool,
        duration: Double = 0.15
    ) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    /// Selected backgrounds need a stronger separation in Increase Contrast.
    static func selectionOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.38 : 0.22
    }

    /// Hairline separators can otherwise disappear against macOS materials.
    static func separatorOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.72 : 0.32
    }

    /// Posts a native VoiceOver announcement for important asynchronous state.
    /// The message is supplied by the caller's current runtime locale.
    @MainActor
    static func announce(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }
}
