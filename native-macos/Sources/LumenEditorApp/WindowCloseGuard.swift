import AppKit
import LumenEditorCore
import SwiftUI

private final class WindowCloseGuardObserverCleanup {
    private var observers: [any NSObjectProtocol] = []

    func replace(with observers: [any NSObjectProtocol]) {
        clear()
        self.observers = observers
    }

    func clear() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        clear()
    }
}

/// Intercepts a window close and, when supplied a session composition, also
/// owns that window's focus callbacks and persisted presentation state.
struct WindowCloseGuard: NSViewRepresentable {
    let prepareToClose: ClosePreparation
    let session: WindowSessionComposition?
    let becameKey: @MainActor () -> Void
    let resignedKey: @MainActor () -> Void
    let willClose: @MainActor (WindowSessionPresentation?) -> Void

    init(prepareToClose: @escaping ClosePreparation) {
        self.init(
            prepareToClose: prepareToClose,
            session: nil,
            becameKey: {},
            resignedKey: {},
            willClose: { _ in }
        )
    }

    init(
        prepareToClose: @escaping ClosePreparation,
        session: WindowSessionComposition?,
        becameKey: @escaping @MainActor () -> Void,
        resignedKey: @escaping @MainActor () -> Void,
        willClose: @escaping @MainActor (WindowSessionPresentation?) -> Void
    ) {
        self.prepareToClose = prepareToClose
        self.session = session
        self.becameKey = becameKey
        self.resignedKey = resignedKey
        self.willClose = willClose
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            prepareToClose: prepareToClose,
            session: session,
            becameKey: becameKey,
            resignedKey: resignedKey,
            willClose: willClose
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = HostingProbeView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.prepareToClose = prepareToClose
        context.coordinator.becameKey = becameKey
        context.coordinator.resignedKey = resignedKey
        context.coordinator.willClose = willClose
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var prepareToClose: ClosePreparation
        let session: WindowSessionComposition?
        var becameKey: @MainActor () -> Void
        var resignedKey: @MainActor () -> Void
        var willClose: @MainActor (WindowSessionPresentation?) -> Void
        private weak var window: NSWindow?
        private var forwardedDelegate: (any NSWindowDelegate)?
        private var isWaitingForDecision = false
        private var mayCloseOnce = false
        private var didReportClose = false
        private var restoredInitialPresentation = false
        private var normalFrame: NSRect?
        private let observerCleanup = WindowCloseGuardObserverCleanup()

        init(
            prepareToClose: @escaping ClosePreparation,
            session: WindowSessionComposition?,
            becameKey: @escaping @MainActor () -> Void,
            resignedKey: @escaping @MainActor () -> Void,
            willClose: @escaping @MainActor (WindowSessionPresentation?) -> Void
        ) {
            self.prepareToClose = prepareToClose
            self.session = session
            self.becameKey = becameKey
            self.resignedKey = resignedKey
            self.willClose = willClose
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            self.window = window
            forwardedDelegate = window.delegate
            window.delegate = self
            didReportClose = false
            normalFrame = window.frame
            installPresentationObservers(for: window)
            restorePresentationIfNeeded()
            if window.isKeyWindow { becameKey() }
        }

        func detach() {
            if window?.delegate === self {
                window?.delegate = forwardedDelegate
            }
            window = nil
            forwardedDelegate = nil
            observerCleanup.clear()
            isWaitingForDecision = false
            mayCloseOnce = false
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if mayCloseOnce {
                mayCloseOnce = false
                return true
            }
            guard !isWaitingForDecision else { return false }
            // The forwarded delegate's veto must happen before the close flow
            // flushes and commits destructive discards. The second close pass
            // is therefore only the already-authorized AppKit handoff.
            guard forwardedDelegate?.windowShouldClose?(sender) ?? true else {
                return false
            }
            isWaitingForDecision = true
            prepareToClose { [weak self, weak sender] shouldClose in
                Task { @MainActor [weak self, weak sender] in
                    guard let self, let sender else { return }
                    self.isWaitingForDecision = false
                    guard shouldClose else { return }
                    // Avoid nesting a second windowShouldClose call in the first
                    // one when a clean workspace resolves synchronously.
                    self.mayCloseOnce = true
                    sender.performClose(nil)
                }
            }
            return false
        }

        func windowWillClose(_ notification: Notification) {
            reportCloseOnce()
            forwardedDelegate?.windowWillClose?(notification)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            becameKey()
            recordPresentation()
            forwardedDelegate?.windowDidBecomeKey?(notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            resignedKey()
            recordPresentation()
            forwardedDelegate?.windowDidResignKey?(notification)
        }

        private func installPresentationObservers(for window: NSWindow) {
            guard session != nil else { return }
            let center = NotificationCenter.default
            var observers: [any NSObjectProtocol] = []
            for name in [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ] {
                observers.append(center.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.recordPresentation() }
                })
            }
            observers.append(center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistPresentation() }
            })
            observerCleanup.replace(with: observers)
        }

        private func restorePresentationIfNeeded() {
            guard !restoredInitialPresentation, let window else { return }
            restoredInitialPresentation = true
            guard let presentation = session?.presentation else { return }
            if let bounds = presentation.bounds, bounds.isValid {
                let requested = NSRect(
                    x: bounds.x, y: bounds.y,
                    width: bounds.width, height: bounds.height
                )
                window.setFrame(Self.visibleFrame(for: requested), display: false)
                normalFrame = window.frame
            }
            switch presentation.state {
            case .normal, .minimized:
                break
            case .maximized:
                window.zoom(nil)
            case .fullScreen:
                Task { @MainActor [weak window] in
                    window?.toggleFullScreen(nil)
                }
            }
        }

        private func recordPresentation() {
            guard let presentation = currentPresentation() else { return }
            session?.stagePresentation(presentation)
        }

        private func persistPresentation() {
            guard let presentation = currentPresentation() else { return }
            try? session?.updatePresentation(presentation)
        }

        private func currentPresentation() -> WindowSessionPresentation? {
            guard session != nil, let window, !didReportClose else { return nil }
            let state: WindowSessionState
            if window.styleMask.contains(.fullScreen) {
                state = .fullScreen
            } else if window.isZoomed {
                state = .maximized
            } else if window.isMiniaturized {
                state = .minimized
            } else {
                state = .normal
                normalFrame = window.frame
            }
            let frame = normalFrame ?? window.frame
            return WindowSessionPresentation(
                bounds: WindowSessionBounds(
                    x: frame.origin.x, y: frame.origin.y,
                    width: frame.width, height: frame.height
                ),
                state: state
            )
        }

        private func reportCloseOnce() {
            guard !didReportClose else { return }
            let presentation = currentPresentation()
            if let presentation { session?.stagePresentation(presentation) }
            didReportClose = true
            willClose(presentation)
        }

        private static func visibleFrame(for requested: NSRect) -> NSRect {
            let screens = NSScreen.screens
            guard !screens.isEmpty else { return requested }
            if screens.contains(where: { $0.visibleFrame.intersects(requested) }) {
                return requested
            }
            let target = NSScreen.main?.visibleFrame ?? screens[0].visibleFrame
            let width = min(max(requested.width, 720), target.width)
            let height = min(max(requested.height, 480), target.height)
            return NSRect(
                x: target.midX - width / 2,
                y: target.midY - height / 2,
                width: width, height: height
            )
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector)
                || forwardedDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: selector) == true {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}

private final class HostingProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
