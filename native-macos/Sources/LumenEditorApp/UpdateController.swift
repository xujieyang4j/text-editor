import AppKit
import Combine
import Foundation
import LumenEditorCore

struct UpdatePresentationIssue: Identifiable, Equatable {
    let id = UUID()
    let titleContent: AppLocalizedCopy
    let content: AppPresentationText

    /// Stable English compatibility for diagnostics and controller-only tests.
    /// The update view resolves the payload again with the live runtime locale.
    var title: String { EditorLocale.enUS.localizedApp(titleContent) }
    var message: String { EditorLocale.enUS.localizedPresentation(content) }
}

enum UpdateCheckOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(AppPresentationText)
}

struct UpdateReleaseConfirmation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let information: UpdateInformation

    var releaseURL: URL? { information.releaseURL }
}

@MainActor
final class UpdateController: ObservableObject {
    typealias Checker = @Sendable (String) async throws -> UpdateInformation
    typealias OpenRelease = @MainActor (URL) -> Bool

    @Published private(set) var isChecking = false
    @Published private(set) var result: UpdateInformation?
    @Published private(set) var issue: UpdatePresentationIssue?
    @Published private(set) var isPresented = false
    @Published private(set) var pendingReleaseConfirmation: UpdateReleaseConfirmation?

    let currentVersion: String
    private let checker: Checker
    private let openRelease: OpenRelease
    private var generation: UInt64 = 0

    init(
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0",
        service: UpdateService = UpdateService(),
        checker: Checker? = nil,
        openRelease: @escaping OpenRelease = { NSWorkspace.shared.open($0) }
    ) {
        self.currentVersion = currentVersion
        self.checker = checker ?? { version in try await service.check(currentVersion: version) }
        self.openRelease = openRelease
    }

    func presentAndCheckOutcome() async -> UpdateCheckOutcome {
        generation &+= 1
        let requestGeneration = generation
        isPresented = true
        isChecking = true
        result = nil
        issue = nil
        pendingReleaseConfirmation = nil
        do {
            let value = try await checker(currentVersion)
            guard requestGeneration == generation else { return .cancelled }
            result = value
            isChecking = false
            return .completed
        } catch is CancellationError {
            guard requestGeneration == generation else { return .cancelled }
            isChecking = false
            return .cancelled
        } catch {
            guard requestGeneration == generation else { return .cancelled }
            isChecking = false
            let content = Self.presentationText(for: error)
            issue = UpdatePresentationIssue(
                titleContent: .couldNotCheckForUpdates, content: content
            )
            return .failed(content)
        }
    }

    @discardableResult
    func presentAndCheck() async -> Bool {
        await presentAndCheckOutcome() == .completed
    }

    func retry() async { _ = await presentAndCheck() }

    func dismiss() {
        generation &+= 1
        isChecking = false
        isPresented = false
        pendingReleaseConfirmation = nil
    }

    func requestOpenReleasePage() {
        guard isPresented, !isChecking,
              let result, result.isAvailable, result.releaseURL != nil else {
            pendingReleaseConfirmation = nil
            return
        }
        pendingReleaseConfirmation = UpdateReleaseConfirmation(information: result)
    }

    func cancelOpenReleasePage() {
        pendingReleaseConfirmation = nil
    }

    /// Consumes the confirmation before opening so repeated actions fail closed.
    /// The result snapshot and URL allowlist are both checked again at this final boundary.
    @discardableResult
    func confirmOpenReleasePage() -> Bool {
        guard let pending = pendingReleaseConfirmation else { return false }
        pendingReleaseConfirmation = nil
        guard isPresented, !isChecking, result == pending.information,
              pending.information.isAvailable,
              let url = pending.releaseURL,
              UpdateService.isApprovedReleaseURL(url) else { return false }
        return openRelease(url)
    }

    @discardableResult
    func registerCommand(
        on router: CommandRouter,
        replaceExisting: Bool = false,
        prepareForCommand: @escaping @MainActor () async -> Void = {},
        presentPanel: @escaping @MainActor () -> Void = {}
    ) throws -> CommandHandlerToken {
        try router.register(
            "check-for-updates", replaceExisting: replaceExisting,
            enablement: { [weak self] _ in
                guard let self else { return .disabled(reason: "Update service unavailable") }
                return self.isChecking
                    ? .disabled(reason: "An update check is already running")
                    : .enabled
            }
        ) { [weak self] _ in
            await prepareForCommand()
            guard let self else {
                throw CommandHandlerSignal.unavailable(
                    reason: "Update service unavailable"
                )
            }
            presentPanel()
            switch await self.presentAndCheckOutcome() {
            case .completed:
                throw CommandHandlerSignal.visiblePanel
            case .cancelled:
                throw CommandHandlerSignal.noChange
            case let .failed(content):
                throw CommandHandlerSignal.failed(.app(content))
            }
        }
    }

    static func presentationText(for error: any Error) -> AppPresentationText {
        guard let error = error as? UpdateCheckError else {
            return .verbatim(error.localizedDescription)
        }
        return .app(switch error {
        case .invalidEndpoint: .updateEndpointNotApproved
        case .redirected: .updateRedirectedUnexpectedly
        case .invalidResponse: .updateInvalidResponse
        case let .responseTooLarge(maximumBytes):
            .updateResponseTooLarge(maximumBytes: maximumBytes)
        case .invalidPayload: .updateMalformedReleaseMetadata
        })
    }
}
