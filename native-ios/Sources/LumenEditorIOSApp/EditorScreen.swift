import LumenEditorMobileCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EditorScreen: View {
    @ObservedObject var workspace: MobileWorkspaceModel
    @ObservedObject var document: MobileDocumentSession
    let showDocumentSwitcher: () -> Void

    @StateObject private var commands = MobileEditorCommandCenter()
    @State private var showFind = false
    @State private var showOutline = false
    @State private var showInspector = false
    @State private var isExporting = false
    @State private var exportDocument: ExportTextDocument?
    @State private var showExternalChangeActions = false
    @State private var shareSnapshot: MobileShareSnapshot?
    @State private var shareSnapshotToRemove: URL?

    var body: some View {
        NativeTextEditor(
            text: $document.content,
            selection: $document.selection,
            fileName: document.displayName,
            isEditable: !document.requiresEncodingConfirmation && !document.isSaving,
            commands: commands,
            onSave: save,
            onShowFind: { showFind = true },
            onShowDocumentSwitcher: showDocumentSwitcher,
            canReplaceContent: { length in
                workspace.canReplaceDocumentContent(document, withUTF16UnitCount: length)
            },
            onEdit: { workspace.documentDidEdit(document) },
            onSelectionChange: { status in
                workspace.documentSelectionDidChange(document, status: status)
            }
        )
        .accessibilityIdentifier("LumenMobileEditor")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if showFind {
                    FindBar(
                        document: document,
                        commands: commands,
                        maximumReplacementUTF16UnitCount: {
                            workspace.maximumReplacementUTF16UnitCount(for: document)
                        },
                        close: { showFind = false; commands.send(.focus) }
                    )
                }
                MobileEditorStatusBar(document: document)
            }
        }
        .navigationTitle(document.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .sheet(isPresented: $showOutline) {
            OutlineView(document: document, commands: commands)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showInspector) {
            DocumentInspector(
                document: document,
                didChange: { workspace.documentDidEdit(document) },
                confirmEncoding: { workspace.reopen(document, using: $0) }
            )
            .presentationDetents([.medium])
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: contentType,
            defaultFilename: document.displayName
        ) { result in
            defer { exportDocument = nil }
            switch result {
            case let .success(url):
                guard let exportDocument else { return }
                workspace.attachExportedFile(url, data: exportDocument.data, to: document)
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    document.notice = error.localizedDescription
                }
            }
        }
        .sheet(item: $shareSnapshot, onDismiss: removeShareSnapshot) { snapshot in
            SystemShareSheet(fileURL: snapshot.url) { shareSnapshot = nil }
                .ignoresSafeArea()
        }
        .confirmationDialog(
            externalChangeTitle,
            isPresented: $showExternalChangeActions,
            titleVisibility: .visible
        ) {
            externalChangeActions
        } message: {
            Text(externalChangeMessage)
        }
        .onAppear { showExternalChangeActions = document.externalChange != nil }
        .onChange(of: document.externalChange) { _, change in
            showExternalChangeActions = change != nil
        }
        .onChange(of: document.notice) { _, notice in
            guard let notice else { return }
            UIAccessibility.post(notification: .announcement, argument: notice)
        }
        .overlay(alignment: .top) {
            if let notice = document.notice {
                if document.externalChange != nil {
                    Button { showExternalChangeActions = true } label: {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.orange.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
                    .accessibilityHint(String(localized: "resolve_external_change"))
                } else {
                    Text(notice)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 6)
                        .onTapGesture { document.notice = nil }
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: showDocumentSwitcher) {
                Label(String(localized: "documents"), systemImage: "rectangle.stack")
            }
            .accessibilityIdentifier("DocumentSwitcherButton")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: save) {
                if document.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: saveSymbol)
                }
            }
            .accessibilityLabel(
                document.isSaving ? String(localized: "saving") : String(localized: "save")
            )
            .accessibilityIdentifier("SaveButton")
            .disabled(document.isSaving || document.requiresEncodingConfirmation)

            Menu {
                Button { showFind = true } label: {
                    Label(String(localized: "find"), systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("FindMenuButton")
                Button { showOutline = true } label: {
                    Label(String(localized: "outline"), systemImage: "list.bullet.indent")
                }
                Button { showInspector = true } label: {
                    Label(String(localized: "document_settings"), systemImage: "doc.badge.gearshape")
                }
                Button(action: saveAs) {
                    Label(String(localized: "save_as"), systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("SaveAsButton")
                .disabled(document.isSaving || document.requiresEncodingConfirmation)
                Button(action: share) {
                    Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("ShareButton")
                .disabled(document.isSaving || document.requiresEncodingConfirmation)
                Divider()
                Button { commands.send(.undo) } label: {
                    Label(String(localized: "undo"), systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("UndoMenuButton")
                Button { commands.send(.redo) } label: {
                    Label(String(localized: "redo"), systemImage: "arrow.uturn.forward")
                }
                .accessibilityIdentifier("RedoMenuButton")
                Divider()
                Button { commands.send(.indent) } label: {
                    Label(String(localized: "indent"), systemImage: "increase.indent")
                }
                Button { commands.send(.outdent) } label: {
                    Label(String(localized: "outdent"), systemImage: "decrease.indent")
                }
                Button { commands.send(.duplicateLines) } label: {
                    Label(String(localized: "duplicate_lines"), systemImage: "plus.square.on.square")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(String(localized: "more"))
            .accessibilityIdentifier("MoreButton")
        }
    }

    private var contentType: UTType {
        UTType(filenameExtension: (document.displayName as NSString).pathExtension) ?? .plainText
    }

    private var saveSymbol: String {
        if document.externalChange != nil { return "exclamationmark.triangle.fill" }
        return document.isDirty ? "square.and.arrow.down.fill" : "checkmark.circle"
    }

    private var externalChangeTitle: String {
        switch document.externalChange {
        case .modified: String(localized: "source_changed_title")
        case .deleted: String(localized: "source_deleted_title")
        case .unavailable: String(localized: "source_unavailable_title")
        case nil: String(localized: "external_change_title")
        }
    }

    private var externalChangeMessage: String {
        switch document.externalChange {
        case .modified: String(localized: "source_changed_message")
        case .deleted: String(localized: "source_deleted_message")
        case .unavailable: String(localized: "source_unavailable_message")
        case nil: ""
        }
    }

    @ViewBuilder
    private var externalChangeActions: some View {
        switch document.externalChange {
        case .modified:
            Button(String(localized: "keep_local_copy_and_reload")) {
                workspace.preserveLocalCopyAndReload(document)
            }
            Button(String(localized: "discard_local_and_reload"), role: .destructive) {
                workspace.discardLocalChangesAndReload(document)
            }
            Button(String(localized: "save_as"), action: saveAs)
            Button(String(localized: "keep_editing"), role: .cancel) {
                workspace.dismissExternalChange(document)
            }
        case .deleted:
            Button(String(localized: "keep_as_local_draft")) {
                workspace.keepDeletedSourceAsDraft(document)
            }
            Button(String(localized: "save_as"), action: saveAs)
            Button(String(localized: "keep_editing"), role: .cancel) {
                workspace.dismissExternalChange(document)
            }
        case .unavailable:
            Button(String(localized: "retry")) {
                workspace.retryExternalInspection(document)
            }
            Button(String(localized: "save_as"), action: saveAs)
            Button(String(localized: "keep_editing"), role: .cancel) {
                workspace.dismissExternalChange(document)
            }
        case nil:
            EmptyView()
        }
    }

    private func save() {
        if document.externalChange != nil {
            showExternalChangeActions = true
            return
        }
        if document.fileReference != nil {
            workspace.save(document)
            return
        }
        saveAs()
    }

    private func saveAs() {
        guard !document.isSaving, !document.requiresEncodingConfirmation else { return }
        document.isSaving = true
        Task {
            defer { document.isSaving = false }
            do {
                let data = try await workspace.exportData(for: document)
                exportDocument = ExportTextDocument(data: data)
                isExporting = true
            } catch {
                document.notice = error.localizedDescription
            }
        }
    }

    private func share() {
        guard !document.isSaving, !document.requiresEncodingConfirmation else { return }
        document.isSaving = true
        Task {
            defer { document.isSaving = false }
            do {
                let url = try await workspace.shareSnapshot(for: document)
                shareSnapshotToRemove = url
                shareSnapshot = MobileShareSnapshot(url: url)
            } catch {
                document.notice = error.localizedDescription
            }
        }
    }

    private func removeShareSnapshot() {
        guard let url = shareSnapshotToRemove else { return }
        shareSnapshotToRemove = nil
        workspace.removeShareSnapshot(at: url)
    }
}

private struct MobileShareSnapshot: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MobileEditorStatusBar: View {
    @ObservedObject var document: MobileDocumentSession

    private var status: MobileCursorStatus { document.cursorStatus }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let line = status.line, let column = status.column {
                    Text("\(String(localized: "line")) \(line)")
                    Text("\(String(localized: "column")) \(column)")
                } else {
                    Text("\(String(localized: "position")) \(status.utf16Offset)")
                }
                if status.selectionLength > 0 {
                    Text("\(String(localized: "selected")) \(status.selectionLength)")
                }
                if document.isDirty {
                    Label(String(localized: "unsaved"), systemImage: "circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 6))
                }
                Text(document.encoding.displayName)
                Text(document.lineEnding.rawValue)
            }
            .padding(.horizontal, 12)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minHeight: 28)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("EditorStatusBar")
    }
}

private struct DocumentInspector: View {
    @ObservedObject var document: MobileDocumentSession
    let didChange: () -> Void
    let confirmEncoding: (MobileTextEncoding) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEncoding: MobileTextEncoding
    @State private var selectedLineEnding: MobileLineEnding

    init(
        document: MobileDocumentSession,
        didChange: @escaping () -> Void,
        confirmEncoding: @escaping (MobileTextEncoding) -> Void
    ) {
        self.document = document
        self.didChange = didChange
        self.confirmEncoding = confirmEncoding
        _selectedEncoding = State(initialValue: document.encoding)
        _selectedLineEnding = State(initialValue: document.lineEnding)
    }

    var body: some View {
        NavigationStack {
            Form {
                if document.requiresEncodingConfirmation {
                    Section {
                        Text(String(localized: "encoding_confirmation_explanation"))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "reopen_with_encoding")) {
                            confirmEncoding(selectedEncoding)
                        }
                        .disabled(document.isSaving)
                    }
                }
                Picker(String(localized: "encoding"), selection: $selectedEncoding) {
                    ForEach(MobileTextEncoding.allCases, id: \.self) { encoding in
                        Text(encoding.displayName).tag(encoding)
                    }
                }
                .disabled(document.isSaving)
                Picker(String(localized: "line_ending"), selection: $selectedLineEnding) {
                    ForEach(MobileLineEnding.allCases, id: \.self) { ending in
                        Text(ending.rawValue).tag(ending)
                    }
                }
                .disabled(document.requiresEncodingConfirmation || document.isSaving)
                LabeledContent(String(localized: "characters"), value: "\(document.content.count)")
                LabeledContent(
                    String(localized: "utf16_units"),
                    value: "\(document.contentUTF16UnitCount)"
                )
            }
            .navigationTitle(String(localized: "document_settings"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .onChange(of: selectedEncoding) { _, value in
                guard !document.requiresEncodingConfirmation,
                      document.encoding != value else { return }
                document.encoding = value
                didChange()
            }
            .onChange(of: selectedLineEnding) { _, value in
                guard document.lineEnding != value else { return }
                document.lineEnding = value
                didChange()
            }
            .onChange(of: document.encoding) { _, value in
                if selectedEncoding != value { selectedEncoding = value }
            }
            .onChange(of: document.lineEnding) { _, value in
                if selectedLineEnding != value { selectedLineEnding = value }
            }
        }
    }
}
