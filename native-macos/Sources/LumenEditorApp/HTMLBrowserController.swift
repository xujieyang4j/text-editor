import AppKit
import Combine
import Foundation
import LumenEditorCore

private final class HTMLBrowserTerminationObserverCleanup {
    private let notificationCenter: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func setObserver(_ observer: any NSObjectProtocol) {
        self.observer = observer
    }

    func removeObserver() {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    deinit {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
    }
}

struct HTMLBrowserPreviewIssue: Identifiable, Equatable {
    let id = UUID()
    let titleContent: AppPresentationText
    let content: AppPresentationText

    /// Stable English text retained for controller diagnostics and existing
    /// non-view callers. Presentation resolves the payload at runtime.
    var title: String { EditorLocale.enUS.localizedPresentation(titleContent) }
    var message: String { EditorLocale.enUS.localizedPresentation(content) }

    init(
        title: AppPresentationText = .app(.couldNotOpenBrowserPreview),
        content: AppPresentationText
    ) {
        titleContent = title
        self.content = content
    }
}

/// App-level snapshot captured synchronously from the active editor before any
/// filesystem work or system-browser launch occurs.
struct HTMLBrowserDocumentSnapshot: Equatable, @unchecked Sendable {
    let documentID: String
    let sourceURL: URL?
    let content: String
    let isDirty: Bool
    let language: String

    @MainActor
    init(document: EditorDocument) {
        documentID = document.sessionDocumentID
        sourceURL = document.fileURL
        content = document.buffer.text
        isDirty = document.isDirty
        language = document.language
    }

    var request: HTMLBrowserPreviewRequest {
        HTMLBrowserPreviewRequest(
            sourceURL: sourceURL, content: content,
            isDirty: isDirty, language: language
        )
    }
}

/// Opens HTML exclusively in the user's system browser. There is deliberately
/// no WKWebView, JavaScript bridge, or save operation in this controller.
@MainActor
final class HTMLBrowserController: ObservableObject {
    typealias OpenURL = @MainActor (URL) -> Bool
    typealias DocumentSnapshot = @MainActor () -> HTMLBrowserDocumentSnapshot?

    @Published private(set) var issue: HTMLBrowserPreviewIssue?
    @Published private(set) var lastOpenedTarget: HTMLBrowserPreviewTarget?
    @Published private(set) var isOpening = false

    private let store: HTMLBrowserPreviewStore
    private let openURL: OpenURL
    private let notificationCenter: NotificationCenter
    private let terminationObserverCleanup: HTMLBrowserTerminationObserverCleanup

    init(
        store: HTMLBrowserPreviewStore = HTMLBrowserPreviewStore(),
        notificationCenter: NotificationCenter = .default,
        openURL: @escaping OpenURL = { url in
            guard url.isFileURL, url.path.hasPrefix("/"),
                  url.host?.isEmpty != false, url.fragment == nil
            else { return false }
            return NSWorkspace.shared.open(url)
        }
    ) {
        self.store = store
        self.openURL = openURL
        self.notificationCenter = notificationCenter
        terminationObserverCleanup = HTMLBrowserTerminationObserverCleanup(
            notificationCenter: notificationCenter
        )
        let terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak store] _ in
            store?.shutdown()
        }
        terminationObserverCleanup.setObserver(terminationObserver)
    }

    var retainedTemporarySnapshotURLs: [URL] { store.retainedSnapshotURLs }

    func canOpen(_ snapshot: HTMLBrowserDocumentSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return HTMLBrowserPreview.supports(
            sourceURL: snapshot.sourceURL, language: snapshot.language
        )
    }

    @discardableResult
    func open(_ snapshot: HTMLBrowserDocumentSnapshot) async -> Bool {
        guard !isOpening else { return false }
        isOpening = true
        defer { isOpening = false }

        do {
            let request = snapshot.request
            let store = self.store
            let target = try await Task.detached(priority: .userInitiated) {
                try store.prepare(request)
            }.value
            guard openURL(HTMLBrowserPreview.browserURL(for: target)) else {
                if target.kind == .temporarySnapshot {
                    store.discardTemporarySnapshot(at: target.url)
                }
                throw HTMLBrowserPreviewControllerError.systemBrowserRejectedURL
            }
            lastOpenedTarget = target
            issue = nil
            return true
        } catch {
            issue = HTMLBrowserPreviewIssue(
                content: Self.presentationText(for: error)
            )
            return false
        }
    }

    func cleanupTemporarySnapshots() {
        store.cleanup()
        if lastOpenedTarget?.kind == .temporarySnapshot { lastOpenedTarget = nil }
    }

    func shutdown() {
        terminationObserverCleanup.removeObserver()
        store.shutdown()
        if lastOpenedTarget?.kind == .temporarySnapshot { lastOpenedTarget = nil }
    }

    func dismissIssue() { issue = nil }

    static func presentationText(for error: any Error) -> AppPresentationText {
        if let error = error as? any AppPresentationError {
            return error.presentationText
        }
        return .verbatim(error.localizedDescription)
    }
}

extension HTMLBrowserPreviewError: AppPresentationError {
    var presentationText: AppPresentationText {
        switch self {
        case .unsupportedDocument:
            .app(.htmlPreviewRequiresHTMLDocument)
        case let .invalidSourceURL(url):
            .app(.htmlSourceNotAbsoluteLocalFile(url: url.absoluteString))
        case let .invalidTemporaryDirectory(url):
            .app(.htmlPreviewTemporaryDirectoryUnsafe(path: url.path))
        case let .snapshotTooLarge(actual, maximum):
            .app(.htmlPreviewTooLarge(actual: actual, maximum: maximum))
        case .storeClosed:
            .app(.htmlPreviewStoreShutDown)
        case .tooManyTemporaryDirectoryCollisions:
            .app(.htmlPreviewCouldNotAllocatePrivateDirectory)
        case let .fileSystem(operation, path, code):
            .app(.htmlPreviewFileSystemFailure(
                operation: operation, path: path, code: code
            ))
        }
    }
}

enum HTMLBrowserPreviewControllerError: Error, Equatable, LocalizedError {
    case systemBrowserRejectedURL

    var errorDescription: String? {
        EditorLocale.enUS.localizedPresentation(presentationText)
    }
}

extension HTMLBrowserPreviewControllerError: AppPresentationError {
    var presentationText: AppPresentationText {
        .app(.systemBrowserRejectedHTMLPreviewURL)
    }
}

/// Production shell contract. Keep one controller alive for the application
/// lifetime, register this handler once, and call
/// `cleanupTemporarySnapshots()` from the existing preflight-shutdown hook as
/// an explicit complement to the termination observer and deinit fallback.
extension HTMLBrowserController {
    @discardableResult
    func registerCommandHandler(
        on router: CommandRouter,
        snapshot: @escaping DocumentSnapshot,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        additionalEnablement: @escaping CommandRouter.Enablement = { _ in .enabled }
    ) throws -> CommandHandlerToken {
        let api = commandHandlerAPI(
            snapshot: snapshot, prepareForCommand: prepareForCommand,
            additionalEnablement: additionalEnablement
        )
        return try router.register(
            "open-in-browser",
            enablement: api.enablement,
            handler: api.handler
        )
    }

    /// Convenience production wiring for the existing AppModel composition
    /// root. The document is snapshotted again after panel preparation so a
    /// stale palette row can never open a previously active tab.
    @discardableResult
    func registerCommandHandler(
        on router: CommandRouter,
        model: AppModel,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        additionalEnablement: @escaping CommandRouter.Enablement = { _ in .enabled }
    ) throws -> CommandHandlerToken {
        try registerCommandHandler(
            on: router,
            snapshot: {
                model.selectedDocument.map(HTMLBrowserDocumentSnapshot.init(document:))
            },
            prepareForCommand: prepareForCommand,
            additionalEnablement: additionalEnablement
        )
    }

    /// Closure pair for composition roots which centralize registrations in a
    /// helper function. Both closures always resnapshot the active document.
    func commandHandlerAPI(
        snapshot: @escaping DocumentSnapshot,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        additionalEnablement: @escaping CommandRouter.Enablement = { _ in .enabled }
    ) -> (enablement: CommandRouter.Enablement, handler: CommandRouter.Handler) {
        let enablement: CommandRouter.Enablement = { [weak self] context in
            guard let self, self.canOpen(snapshot()), !self.isOpening else {
                return .disabled(reason: "Requires an HTML document.")
            }
            return additionalEnablement(context)
        }
        let handler: CommandRouter.Handler = { [weak self] _ in
            await prepareForCommand()
            guard let self, let current = snapshot() else {
                throw HTMLBrowserPreviewError.unsupportedDocument
            }
            guard await self.open(current) else {
                throw self.issue.map { HTMLBrowserCommandError($0.content) }
                    ?? HTMLBrowserCommandError(.app(.browserPreviewCouldNotBeOpened))
            }
        }
        return (enablement, handler)
    }
}

private struct HTMLBrowserCommandError: Error, LocalizedError, AppPresentationError {
    let presentationText: AppPresentationText
    init(_ presentationText: AppPresentationText) {
        self.presentationText = presentationText
    }
    var errorDescription: String? {
        EditorLocale.enUS.localizedPresentation(presentationText)
    }
}
