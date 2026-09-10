import LumenEditorMobileCore
import SwiftUI

struct OutlineView: View {
    @ObservedObject var document: MobileDocumentSession
    @ObservedObject var commands: MobileEditorCommandCenter
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [MobileOutlineItem] {
        let all = MobileOutline.items(in: document.content)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(items) { item in
                Button {
                    document.selection = NSRange(location: item.location, length: 0)
                    commands.send(.select(document.selection))
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: icon(for: item.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Text("\(item.line)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: String(localized: "quick_open_prompt"))
            .navigationTitle(String(localized: "outline"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "heading": "number"
        case "class": "c.square"
        case "struct": "s.square"
        case "enum": "e.square"
        default: "function"
        }
    }
}
