import SwiftUI

struct DocumentSwitcherView: View {
    @ObservedObject var workspace: MobileWorkspaceModel
    let openFile: () -> Void
    let newDocument: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDiscard: MobileDocumentSession?

    var body: some View {
        NavigationStack {
            List {
                if !workspace.documents.isEmpty {
                    Section(String(localized: "open_documents")) {
                        ForEach(workspace.documents) { document in
                            Button {
                                workspace.activeDocumentID = document.id
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: document.fileReference == nil ? "doc" : "doc.text")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(document.displayName)
                                                .lineLimit(1)
                                            if document.isDirty {
                                                Circle().frame(width: 7, height: 7)
                                                    .accessibilityLabel(String(localized: "unsaved"))
                                            }
                                        }
                                        Text(document.fileReference?.url.deletingLastPathComponent().lastPathComponent
                                            ?? String(localized: "local_draft"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if workspace.activeDocumentID == document.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("DocumentRow-\(document.displayName)")
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    if document.isDirty { pendingDiscard = document }
                                    else { workspace.close(document) }
                                } label: {
                                    Label(String(localized: "close"), systemImage: "xmark")
                                }
                            }
                        }
                    }
                }

                if !workspace.recentFiles.isEmpty {
                    Section(String(localized: "recent_files")) {
                        ForEach(workspace.recentFiles) { recent in
                            Button {
                                workspace.openRecent(recent)
                                dismiss()
                            } label: {
                                Label(recent.displayName, systemImage: "clock.arrow.circlepath")
                                    .lineLimit(1)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    workspace.removeRecent(recent)
                                } label: {
                                    Label(String(localized: "remove_recent"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if workspace.documents.isEmpty && workspace.recentFiles.isEmpty {
                    ContentUnavailableView(
                        String(localized: "no_open_documents"),
                        systemImage: "doc.text"
                    )
                }
            }
            .navigationTitle(String(localized: "documents"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(action: openFile) {
                            Label(String(localized: "open_file"), systemImage: "folder")
                        }
                        Button(action: newDocument) {
                            Label(String(localized: "new_document"), systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("NewDocumentMenuButton")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "add_document"))
                    .accessibilityIdentifier("AddDocumentButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
        .confirmationDialog(
            String(localized: "discard_changes_title"),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "discard_changes"), role: .destructive) {
                if let pendingDiscard { workspace.discardAndClose(pendingDiscard) }
                pendingDiscard = nil
            }
            Button(String(localized: "keep_editing"), role: .cancel) { pendingDiscard = nil }
        } message: {
            Text(String(localized: "discard_changes_message"))
        }
    }
}
