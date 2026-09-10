import Foundation
import LumenEditorMobileCore
import SwiftUI

struct RootView: View {
    @StateObject private var workspace: MobileWorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @State private var showSwitcher = false

    init(uiTestSessionID: UUID? = nil) {
        guard let uiTestSessionID else {
            _workspace = StateObject(wrappedValue: MobileWorkspaceModel())
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenEditorUITests", isDirectory: true)
            .appendingPathComponent(uiTestSessionID.uuidString, isDirectory: true)
        _workspace = StateObject(wrappedValue: MobileWorkspaceModel(
            drafts: MobileDraftStore(
                directory: root.appendingPathComponent("RecoveryDrafts", isDirectory: true)
            ),
            files: MobileFileAccess(),
            recents: MobileRecentStore(
                fileURL: root.appendingPathComponent("RecentFiles.json")
            )
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let document = workspace.activeDocument {
                    EditorScreen(
                        workspace: workspace,
                        document: document,
                        showDocumentSwitcher: { showSwitcher = true }
                    )
                    .id(document.id)
                } else {
                    ContentUnavailableView {
                        Label(String(localized: "welcome_title"), systemImage: "doc.text")
                    } description: {
                        Text(String(localized: "welcome_message"))
                    } actions: {
                        Button { showPicker = true } label: {
                            Label(String(localized: "open_file"), systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("OpenFileButton")
                        Button { workspace.newDocument() } label: {
                            Label(String(localized: "new_document"), systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("NewDocumentButton")
                    }
                }
            }
            .disabled(workspace.isBusy)
            .toolbar {
                if workspace.activeDocument == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showPicker = true } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityLabel(String(localized: "open_file"))
                    }
                }
            }
        }
        .overlay {
            if workspace.isBusy {
                ProgressView(String(localized: "opening"))
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .sheet(isPresented: $showPicker) {
            SystemDocumentPicker(
                onPick: { urls in
                    showPicker = false
                    workspace.openPickedURLs(urls)
                },
                onCancel: { showPicker = false }
            )
        }
        .sheet(isPresented: $showSwitcher) {
            DocumentSwitcherView(
                workspace: workspace,
                openFile: {
                    showSwitcher = false
                    Task { @MainActor in
                        await Task.yield()
                        showPicker = true
                    }
                },
                newDocument: {
                    workspace.newDocument()
                    showSwitcher = false
                }
            )
                .presentationDetents([.medium, .large])
        }
        .alert(
            String(localized: "error"),
            isPresented: Binding(
                get: { workspace.alertMessage != nil },
                set: { if !$0 { workspace.alertMessage = nil } }
            )
        ) {
            Button(String(localized: "ok"), role: .cancel) { workspace.alertMessage = nil }
        } message: {
            Text(workspace.alertMessage ?? "")
        }
        .onOpenURL { workspace.openURL($0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { workspace.applicationDidBecomeActive() }
            else { workspace.applicationWillResignActive() }
        }
    }
}
