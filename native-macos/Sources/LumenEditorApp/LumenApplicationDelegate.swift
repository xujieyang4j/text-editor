import AppKit
import Combine
import Darwin
import LumenEditorCore

/// Opt-in packaged-application smoke used by CI and release verification. It
/// deliberately resolves both the parser bundle and helper through
/// `Bundle.main`, exactly like an editor window, and never accepts paths from
/// the command line. Running the signed app itself also exercises inherited
/// sandbox execution instead of testing a loose SwiftPM helper in isolation.
enum PackagedParserSmoke {
    static let argument = "--lumen-parser-smoke"

    @MainActor
    static func startIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().contains(argument) else {
            return false
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task.detached(priority: .userInitiated) {
            let service = CodeMirrorParserService()
            let javascriptText = "😀 const value = 1\n"
            let swiftText = "func run() {\n  let value = 1\n}\n"
            let javascript = await service.analyze(
                text: javascriptText, language: "JavaScript"
            )
            let swift = await service.analyze(
                text: swiftText, language: "Swift",
                tabWidth: 4, indentWidth: 2, insertSpaces: true
            )
            let passed = validate(
                javascript: javascript, javascriptText: javascriptText,
                swift: swift, swiftText: swiftText
            )

            let output = passed
                ? "Packaged parser smoke passed.\n"
                : "Packaged parser smoke failed.\n"
            let handle = passed ? FileHandle.standardOutput : FileHandle.standardError
            try? handle.write(contentsOf: Data(output.utf8))
            exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        return true
    }

    static func validate(
        javascript: CodeMirrorParserAnalysis?, javascriptText: String,
        swift: CodeMirrorParserAnalysis?, swiftText: String
    ) -> Bool {
        guard let javascript, let swift else { return false }
        return javascript.supported
            && javascript.parserKind == .lezer
            && javascript.sourceUTF16Length == javascriptText.utf16.count
            && javascript.highlights.contains {
                $0.kind == .keyword && $0.from == 3
            }
            && swift.supported
            && swift.parserKind == .stream
            && swift.sourceUTF16Length == swiftText.utf16.count
            && swift.highlights.contains { $0.kind == .keyword }
            && swift.indentation.count == 4
    }
}

/// Exercises the packaged application through its normal SwiftUI/AppKit
/// lifecycle. Unlike the parser-only smoke above, this mode keeps the regular
/// activation policy, waits for an editor scene to connect, verifies a usable
/// visible window, proves that the main actor is still servicing work, and
/// then asks AppKit to perform the normal application-termination transaction.
enum PackagedWindowSmoke {
    static let argument = "--lumen-window-smoke"
    static let timeout: TimeInterval = 20

    static var isRequested: Bool {
        CommandLine.arguments.dropFirst().contains(argument)
    }

    @MainActor
    static func evidence(
        status: String,
        editorSessionCount: Int,
        mainActorRoundTrips: Int,
        window: NSWindow? = nil,
        failure: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "probe": "native-macos-packaged-window",
            "status": status,
            "platform": "macOS",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "processId": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier.map { $0 as Any } ?? NSNull(),
            "appVersion": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ).map { $0 as Any } ?? NSNull(),
            "editorSessionCount": editorSessionCount,
            "mainActorRoundTrips": mainActorRoundTrips,
            "recordedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let window {
            payload["window"] = [
                "visible": window.isVisible,
                "key": window.isKeyWindow,
                "canBecomeKey": window.canBecomeKey,
                "width": Int(window.frame.width.rounded()),
                "height": Int(window.frame.height.rounded()),
                "hasContentView": window.contentView != nil
            ]
        }
        if let failure { payload["failure"] = failure }
        return payload
    }

    static func write(_ payload: [String: Any], to handle: FileHandle) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]
              ) else {
            try? FileHandle.standardError.write(contentsOf: Data(
                "Could not serialize packaged window smoke evidence.\n".utf8
            ))
            return
        }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data("\n".utf8))
        try? handle.synchronize()
    }
}

/// Bridges lifecycle events that SwiftUI scenes do not expose reliably when the
/// executable is launched by Finder rather than from `swift run`.
@MainActor
final class LumenApplicationDelegate: NSObject, NSApplicationDelegate {
    private let mainMenuProvider: @MainActor () -> NSMenu?
    private let servicesMenuProvider: @MainActor () -> NSMenu?
    private let windowsMenuProvider: @MainActor () -> NSMenu?
    private var menuLocale: EditorLocale = .zhCN
    private weak var menuLocalizationSettings: SettingsController?
    private var menuLocalizationSubscription: AnyCancellable?
    private var isMenuRefreshScheduled = false
    private var queuedOpenURLs: [URL] = []
    private var packagedWindowSmokeTask: Task<Void, Never>?
    private var pendingPackagedWindowSmokeEvidence: [String: Any]?
    var openNewWindow: (() -> Void)?
    private struct WindowLifecycle {
        let openURLs: ([URL]) -> Void
        let flushSession: @MainActor () -> Bool
        let preflightTerminationPersistence: @MainActor () -> Bool
        let prepareToTerminate: ClosePreparation
        let validateTerminationPreparation: @MainActor () -> Bool
        let commitTerminationPreparation: @MainActor () -> Void
        let abortTerminationPreparation: @MainActor () async -> Void
        let finalizeTermination: @MainActor () async -> Void
    }

    private var windows: [WindowSessionID: WindowLifecycle] = [:]
    private var activeWindowID: WindowSessionID?
    private var isAwaitingTerminationReply = false
    private var terminationPreparedWindowIDs: Set<WindowSessionID> = []
    private var didPreflightGlobalStateForTermination = false
    private var didCommitApplicationTermination = false
    private(set) var isApplicationTerminationCommitted = false
    var terminationCommitStateDidChange: ((Bool) -> Void)?
    var flushGlobalState: (() -> Bool)?
    var prepareGlobalStateTerminationCommit: (() -> Bool)? = { true }
    var abortGlobalStateTerminationCommit: (() -> Void)?
    var beginTerminationPersistenceTransaction: ((Set<WindowSessionID>) -> Bool)? = { _ in
        true
    }
    var commitTerminationPersistenceTransaction: (() -> Bool)? = { true }
    var abortTerminationPersistenceTransaction: (() -> Void)?
    var finalizeTerminationPersistenceTransaction: (() -> Void)?

    override init() {
        mainMenuProvider = { NSApplication.shared.mainMenu }
        servicesMenuProvider = { NSApplication.shared.servicesMenu }
        windowsMenuProvider = { NSApplication.shared.windowsMenu }
        super.init()
    }

    /// Test seam for exercising launch and runtime menu localisation without
    /// replacing `NSApplication.shared.mainMenu`.
    init(
        mainMenuProvider: @escaping @MainActor () -> NSMenu?,
        servicesMenuProvider: @escaping @MainActor () -> NSMenu? = {
            NSApplication.shared.servicesMenu
        },
        windowsMenuProvider: @escaping @MainActor () -> NSMenu? = {
            NSApplication.shared.windowsMenu
        }
    ) {
        self.mainMenuProvider = mainMenuProvider
        self.servicesMenuProvider = servicesMenuProvider
        self.windowsMenuProvider = windowsMenuProvider
        super.init()
    }

    /// Keeps system-owned AppKit menu titles in sync with the single,
    /// application-scoped settings source. This subscription deliberately
    /// lives outside editor windows so a Settings-only app can change locale.
    func bindMenuLocalization(to settings: SettingsController) {
        if menuLocalizationSettings === settings {
            updateMenuLocale(settings.locale)
            return
        }

        menuLocalizationSettings = settings
        menuLocalizationSubscription = settings.$settings
            .map(\.locale)
            .removeDuplicates()
            .sink { [weak self] locale in
                self?.updateMenuLocale(locale)
            }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           PackagedParserSmoke.startIfRequested() { return }
        // SwiftUI has installed its command menus by this lifecycle point. Do
        // one synchronous pass before the first visible frame, then one
        // coalesced pass for any final command-menu reconciliation.
        refreshMainMenuLocalization()
        scheduleMainMenuLocalizationRefresh()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           PackagedWindowSmoke.isRequested {
            startPackagedWindowSmoke()
        }
    }

    private func startPackagedWindowSmoke() {
        packagedWindowSmokeTask?.cancel()
        packagedWindowSmokeTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(PackagedWindowSmoke.timeout)
            var mainActorRoundTrips = 0
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                mainActorRoundTrips += 1
                guard let self else { return }
                let window = NSApplication.shared.windows.first { candidate in
                    candidate.isVisible
                        && !candidate.isMiniaturized
                        && candidate.canBecomeKey
                        && candidate.contentView != nil
                        && candidate.frame.width > 0
                        && candidate.frame.height > 0
                }
                guard !self.windows.isEmpty, mainActorRoundTrips >= 2,
                      let window else { continue }

                window.makeKeyAndOrderFront(nil)
                await Task.yield()
                guard window.isVisible, !window.isMiniaturized,
                      window.contentView != nil else { continue }
                let payload = PackagedWindowSmoke.evidence(
                    status: "passed",
                    editorSessionCount: self.windows.count,
                    mainActorRoundTrips: mainActorRoundTrips,
                    window: window
                )
                // Do not publish success until AppKit reaches
                // applicationWillTerminate. If the normal quit transaction is
                // rejected or hangs, the outer watchdog must fail instead of
                // accepting a window that merely appeared.
                self.pendingPackagedWindowSmokeEvidence = payload
                NSApplication.shared.terminate(nil)
                return
            }

            guard let self else { return }
            let payload = PackagedWindowSmoke.evidence(
                status: "failed",
                editorSessionCount: self.windows.count,
                mainActorRoundTrips: mainActorRoundTrips,
                failure: "No connected, visible, usable editor window appeared before the deadline."
            )
            PackagedWindowSmoke.write(payload, to: .standardError)
            exit(EXIT_FAILURE)
        }
    }

    func updateMenuLocale(_ locale: EditorLocale) {
        menuLocale = locale
        refreshMainMenuLocalization()
        scheduleMainMenuLocalizationRefresh()
    }

    func connect(
        windowID: WindowSessionID,
        openURLs: @escaping ([URL]) -> Void,
        flushSession: @escaping @MainActor () -> Bool,
        preflightTerminationPersistence: @escaping @MainActor () -> Bool,
        prepareToTerminate: @escaping ClosePreparation,
        validateTerminationPreparation: @escaping @MainActor () -> Bool = { true },
        commitTerminationPreparation: @escaping @MainActor () -> Void = {},
        abortTerminationPreparation: @escaping @MainActor () async -> Void = {},
        finalizeTermination: @escaping @MainActor () async -> Void
    ) {
        if isApplicationTerminationCommitted {
            // A scene requested just before the commit may appear afterwards.
            // Freeze it synchronously and tear it down without admitting it to
            // the already-published transaction participant set.
            commitTerminationPreparation()
            Task { @MainActor in await finalizeTermination() }
            return
        }
        windows[windowID] = WindowLifecycle(
            openURLs: openURLs,
            flushSession: flushSession,
            preflightTerminationPersistence: preflightTerminationPersistence,
            prepareToTerminate: prepareToTerminate,
            validateTerminationPreparation: validateTerminationPreparation,
            commitTerminationPreparation: commitTerminationPreparation,
            abortTerminationPreparation: abortTerminationPreparation,
            finalizeTermination: finalizeTermination
        )
        activeWindowID = windowID
        reserveCommandWForTabs()

        guard !queuedOpenURLs.isEmpty else { return }
        let urls = queuedOpenURLs
        queuedOpenURLs.removeAll(keepingCapacity: false)
        openURLs(urls)
    }

    /// Compatibility adapter for previews and tests that still host exactly
    /// one legacy window. Production window scenes always pass an explicit ID.
    func connect(
        openURLs: @escaping ([URL]) -> Void,
        flushSession: @escaping @MainActor () -> Bool,
        preflightTerminationPersistence: @escaping @MainActor () -> Bool,
        prepareToTerminate: @escaping ClosePreparation,
        validateTerminationPreparation: @escaping @MainActor () -> Bool = { true },
        commitTerminationPreparation: @escaping @MainActor () -> Void = {},
        abortTerminationPreparation: @escaping @MainActor () async -> Void = {},
        finalizeTermination: @escaping @MainActor () async -> Void
    ) {
        connect(
            windowID: .legacy,
            openURLs: openURLs,
            flushSession: flushSession,
            preflightTerminationPersistence: preflightTerminationPersistence,
            prepareToTerminate: prepareToTerminate,
            validateTerminationPreparation: validateTerminationPreparation,
            commitTerminationPreparation: commitTerminationPreparation,
            abortTerminationPreparation: abortTerminationPreparation,
            finalizeTermination: finalizeTermination
        )
    }

    func disconnect(windowID: WindowSessionID) {
        windows.removeValue(forKey: windowID)
        terminationPreparedWindowIDs.remove(windowID)
        if activeWindowID == windowID {
            activeWindowID = windows.keys.sorted { $0.rawValue < $1.rawValue }.first
        }
    }

    func windowDidBecomeKey(_ windowID: WindowSessionID) {
        guard windows[windowID] != nil else { return }
        activeWindowID = windowID
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isAwaitingTerminationReply, !isApplicationTerminationCommitted else { return }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        if let handler = activeWindowID.flatMap({ windows[$0]?.openURLs })
            ?? windows.values.first?.openURLs {
            handler(fileURLs)
        } else {
            queuedOpenURLs.append(contentsOf: fileURLs)
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        beginApplicationTermination { [weak sender] shouldTerminate in
            sender?.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    /// Testable core of the AppKit termination handshake. The asynchronous
    /// reply is issued only after every window has prepared, every revision has
    /// been revalidated, and all commits and finalizers have completed.
    @discardableResult
    func beginApplicationTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard !isAwaitingTerminationReply else { return .terminateLater }
        guard flushGlobalState?() != false else {
            didPreflightGlobalStateForTermination = false
            return .terminateCancel
        }
        didPreflightGlobalStateForTermination = true
        let pending = windows
            .filter { !terminationPreparedWindowIDs.contains($0.key) }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value.prepareToTerminate) }
        guard !windows.isEmpty else {
            guard prepareGlobalStateTerminationCommit?() != false else {
                didPreflightGlobalStateForTermination = false
                return .terminateCancel
            }
            isApplicationTerminationCommitted = true
            terminationCommitStateDidChange?(true)
            didCommitApplicationTermination = true
            return .terminateNow
        }
        guard !pending.isEmpty else {
            terminationPreparedWindowIDs.removeAll()
            didPreflightGlobalStateForTermination = false
            return .terminateCancel
        }
        isAwaitingTerminationReply = true
        prepareSequentially(pending) { [weak self] shouldTerminate in
            // AppKit permits an asynchronous reply. Deferring also avoids replying
            // reentrantly when there are no dirty tabs to ask about.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard shouldTerminate else {
                    await self.abortPreparedTermination()
                    self.finishTerminationRequest(false, reply: reply)
                    return
                }

                let prepared = self.preparedWindowsInStableOrder()
                guard prepared.count == self.windows.count else {
                    await self.abortPreparedTermination()
                    self.finishTerminationRequest(false, reply: reply)
                    return
                }
                guard prepared.allSatisfy({
                          $0.1.validateTerminationPreparation()
                      }) else {
                    await self.abortPreparedTermination()
                    self.finishTerminationRequest(false, reply: reply)
                    return
                }
                guard self.beginTerminationPersistenceTransaction?(
                    Set(prepared.map(\.0))
                ) == true,
                      prepared.allSatisfy({
                          $0.1.preflightTerminationPersistence()
                      }),
                      prepared.allSatisfy({
                          $0.1.validateTerminationPreparation()
                      }) else {
                    self.abortTerminationPersistenceTransaction?()
                    await self.abortPreparedTermination()
                    self.finishTerminationRequest(false, reply: reply)
                    return
                }
                // Settings may change while dirty-document sheets are open.
                // Flush and lock them immediately before the durable marker.
                guard self.prepareGlobalStateTerminationCommit?() != false else {
                    self.abortTerminationPersistenceTransaction?()
                    await self.abortPreparedTermination()
                    self.finishTerminationRequest(false, reply: reply)
                    return
                }
                guard self.commitTerminationPersistenceTransaction?() == true else {
                    self.abortGlobalStateTerminationCommit?()
                    self.abortTerminationPersistenceTransaction?()
                    await self.abortPreparedTermination()
                    self.finishTerminationRequest(false, reply: reply)
                    return
                }

                // All fallible persistence and all validation have completed.
                // Main-actor isolation keeps the following synchronous commits
                // contiguous, so no window can become stale between validation
                // and its infallible in-memory teardown.
                self.isApplicationTerminationCommitted = true
                self.terminationCommitStateDidChange?(true)
                for (_, window) in prepared {
                    window.commitTerminationPreparation()
                }
                self.didCommitApplicationTermination = true
                self.terminationPreparedWindowIDs.removeAll()
                for (_, window) in prepared {
                    await window.finalizeTermination()
                }
                self.finalizeTerminationPersistenceTransaction?()
                self.finishTerminationRequest(true, reply: reply)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { requestNewWindow() }
        return true
    }

    func requestNewWindow() {
        guard !isAwaitingTerminationReply, !isApplicationTerminationCommitted else { return }
        openNewWindow?()
    }

    func applicationWillTerminate(_ notification: Notification) {
        packagedWindowSmokeTask?.cancel()
        if let evidence = pendingPackagedWindowSmokeEvidence {
            pendingPackagedWindowSmokeEvidence = nil
            PackagedWindowSmoke.write(evidence, to: .standardOutput)
        }
        guard !didCommitApplicationTermination else { return }
        if !didPreflightGlobalStateForTermination {
            _ = flushGlobalState?()
        }
        for (id, window) in windows where !terminationPreparedWindowIDs.contains(id) {
            _ = window.flushSession()
        }
    }

    /// A SwiftUI Window contributes a default Cmd-W item without a replaceable
    /// close-item command placement. Keep that clickable Close Window command,
    /// but remove its shortcut so the File > Close Tab command owns Cmd-W.
    private func reserveCommandWForTabs() {
        DispatchQueue.main.async {
            guard let mainMenu = NSApplication.shared.mainMenu else { return }
            Self.visitItems(in: mainMenu) { item in
                guard item.action == #selector(NSWindow.performClose(_:)),
                      item.keyEquivalent.lowercased() == "w",
                      item.keyEquivalentModifierMask.contains(.command)
                else { return }
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    private func refreshMainMenuLocalization() {
        menuLocale.localizeMainMenu(
            mainMenuProvider(),
            servicesMenu: servicesMenuProvider(),
            windowsMenu: windowsMenuProvider()
        )
    }

    private func scheduleMainMenuLocalizationRefresh() {
        guard !isMenuRefreshScheduled else { return }
        isMenuRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // SwiftUI can reconcile Commands on the first turn after its
            // observed settings change. Refresh one turn later so regenerated
            // system items cannot restore launch-language titles.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isMenuRefreshScheduled = false
                self.refreshMainMenuLocalization()
            }
        }
    }

    private static func visitItems(in menu: NSMenu, action: (NSMenuItem) -> Void) {
        for item in menu.items {
            action(item)
            if let submenu = item.submenu {
                visitItems(in: submenu, action: action)
            }
        }
    }

    private func prepareSequentially(
        _ preparations: [(WindowSessionID, ClosePreparation)],
        at index: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        guard preparations.indices.contains(index) else {
            completion(true)
            return
        }
        let (windowID, prepare) = preparations[index]
        prepare { [weak self] shouldContinue in
            guard shouldContinue else {
                completion(false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.terminationPreparedWindowIDs.insert(windowID)
                self.prepareSequentially(
                    preparations,
                    at: index + 1,
                    completion: completion
                )
            }
        }
    }

    private func preparedWindowsInStableOrder() -> [(WindowSessionID, WindowLifecycle)] {
        windows
            .filter { terminationPreparedWindowIDs.contains($0.key) }
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }

    private func abortPreparedTermination() async {
        for (_, window) in preparedWindowsInStableOrder() {
            await window.abortTerminationPreparation()
        }
        terminationPreparedWindowIDs.removeAll()
    }

    private func finishTerminationRequest(
        _ shouldTerminate: Bool,
        reply: @MainActor (Bool) -> Void
    ) {
        isAwaitingTerminationReply = false
        if !shouldTerminate { didPreflightGlobalStateForTermination = false }
        reply(shouldTerminate)
    }
}
