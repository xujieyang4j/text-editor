import SwiftUI
import UniformTypeIdentifiers

struct DropLoadSummary: Equatable, Sendable {
    static let maximumItems = 32

    let providerCount: Int
    let truncatedCount: Int
    let parseFailureCount: Int
    let urls: [URL]

    var acceptedCount: Int { urls.count }
    var rejectedCount: Int { parseFailureCount + truncatedCount }

    init(
        providerCount: Int,
        truncatedCount: Int,
        parseFailureCount: Int,
        urls: [URL]
    ) {
        self.providerCount = providerCount
        self.truncatedCount = truncatedCount
        self.parseFailureCount = parseFailureCount
        self.urls = urls.map(\.standardizedFileURL)
    }

    static func plan(urls: [URL], providerCount: Int, parseFailureCount: Int) -> DropLoadSummary {
        let limit = min(providerCount, maximumItems)
        var seenPaths: Set<String> = []
        var accepted: [URL] = []
        for url in urls.prefix(limit) where url.isFileURL {
            let canonicalURL = url.standardizedFileURL
            guard seenPaths.insert(canonicalURL.path).inserted else { continue }
            accepted.append(canonicalURL)
        }
        return DropLoadSummary(
            providerCount: providerCount,
            truncatedCount: max(0, providerCount - maximumItems),
            parseFailureCount: parseFailureCount,
            urls: accepted
        )
    }
}

/// Finder drag-and-drop entry point. File URLs are decoded from the system
/// pasteboard and handed back to the same capability-aware open pipeline used
/// by Open and Open Folder. A hard cap mirrors Electron's drop boundary.
struct WorkspaceDropModifier: ViewModifier {
    let handleDrop: @MainActor (DropLoadSummary) async -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $isTargeted,
                perform: receive(providers:)
            )
    }

    private func receive(providers: [NSItemProvider]) -> Bool {
        let providerCount = providers.count
        guard providerCount > 0 else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            var parseFailureCount = 0
            for provider in providers.prefix(DropLoadSummary.maximumItems) {
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) else {
                    parseFailureCount += 1
                    continue
                }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let value = item as? String {
                    url = URL(string: value)
                } else {
                    url = nil
                }
                if let url, url.isFileURL {
                    urls.append(url)
                } else {
                    parseFailureCount += 1
                }
            }
            let summary = DropLoadSummary.plan(
                urls: urls,
                providerCount: providerCount,
                parseFailureCount: parseFailureCount
            )
            await handleDrop(summary)
        }
        return true
    }
}

extension View {
    func acceptsWorkspaceFileDrops(
        _ action: @escaping @MainActor (DropLoadSummary) async -> Void
    ) -> some View {
        modifier(WorkspaceDropModifier(handleDrop: action))
    }
}
