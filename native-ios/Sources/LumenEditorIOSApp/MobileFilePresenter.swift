import Foundation

enum MobilePresentedItemEvent: @unchecked Sendable {
    case changed
    case deleted
    case moved(URL)
}

/// Bridges File Provider changes into the main-actor document model.
final class MobileFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var itemURL: URL?
    private var isRegistered = false
    private var isAccessingSecurityScope = false
    private var securityScopedURL: URL?
    private let eventHandler: @Sendable (MobilePresentedItemEvent) -> Void

    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.lumen.editor.ios.file-presenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return itemURL
    }

    init(url: URL, eventHandler: @escaping @Sendable (MobilePresentedItemEvent) -> Void) {
        itemURL = url
        self.eventHandler = eventHandler
        super.init()
    }

    func start() {
        lock.lock()
        guard !isRegistered, let itemURL else {
            lock.unlock()
            return
        }
        isAccessingSecurityScope = itemURL.startAccessingSecurityScopedResource()
        securityScopedURL = isAccessingSecurityScope ? itemURL : nil
        isRegistered = true
        lock.unlock()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        lock.lock()
        guard isRegistered else {
            lock.unlock()
            return
        }
        isRegistered = false
        let shouldStopScope = isAccessingSecurityScope
        isAccessingSecurityScope = false
        let url = securityScopedURL
        securityScopedURL = nil
        lock.unlock()
        NSFileCoordinator.removeFilePresenter(self)
        if shouldStopScope { url?.stopAccessingSecurityScopedResource() }
    }

    func presentedItemDidChange() {
        lock.lock()
        let shouldNotify = isRegistered
        lock.unlock()
        if shouldNotify { eventHandler(.changed) }
    }

    func presentedItemDidMove(to newURL: URL) {
        let accessesNewScope = newURL.startAccessingSecurityScopedResource()
        lock.lock()
        guard isRegistered else {
            lock.unlock()
            if accessesNewScope { newURL.stopAccessingSecurityScopedResource() }
            return
        }
        let oldScopedURL = securityScopedURL
        let shouldStopOldScope = isAccessingSecurityScope
        itemURL = newURL
        isAccessingSecurityScope = accessesNewScope
        securityScopedURL = accessesNewScope ? newURL : nil
        lock.unlock()
        if shouldStopOldScope { oldScopedURL?.stopAccessingSecurityScopedResource() }
        eventHandler(.moved(newURL))
    }

    func accommodatePresentedItemDeletion(
        completionHandler: @escaping (Error?) -> Void
    ) {
        lock.lock()
        guard isRegistered else {
            lock.unlock()
            completionHandler(nil)
            return
        }
        itemURL = nil
        lock.unlock()
        eventHandler(.deleted)
        completionHandler(nil)
    }
}
