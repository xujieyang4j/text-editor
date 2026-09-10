@preconcurrency import Foundation

struct WorkspaceFileSystemEvent: Equatable, Sendable {
    enum Kind: Comparable, Sendable {
        case changed
        case renamed
        case deleted
        case rootInvalidated

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.precedence < rhs.precedence
        }

        var precedence: Int {
            switch self {
            case .changed: 0
            case .renamed: 1
            case .deleted: 2
            case .rootInvalidated: 3
            }
        }
    }

    let rootURL: URL
    let kind: Kind
    let changedURL: URL?

    init(rootURL: URL, kind: Kind, changedURL: URL? = nil) {
        self.rootURL = rootURL.standardizedFileURL
        if kind == .rootInvalidated {
            self.kind = .rootInvalidated
            self.changedURL = nil
        } else if let changedURL {
            let normalized = changedURL.standardizedFileURL
            let rootPath = self.rootURL.path
            let path = normalized.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if path != rootPath, path.hasPrefix(prefix) {
                self.kind = kind
                self.changedURL = normalized
            } else {
                self.kind = .rootInvalidated
                self.changedURL = nil
            }
        } else {
            self.kind = .rootInvalidated
            self.changedURL = nil
        }
    }

    var callbackURL: URL { changedURL ?? rootURL }
    var isRootInvalidation: Bool { kind == .rootInvalidated }

    func merged(with other: WorkspaceFileSystemEvent) -> WorkspaceFileSystemEvent {
        precondition(rootURL == other.rootURL)
        precondition(callbackURL == other.callbackURL)
        return kind >= other.kind ? self : other
    }

    static func changed(rootURL: URL, changedURL: URL) -> WorkspaceFileSystemEvent {
        WorkspaceFileSystemEvent(
            rootURL: rootURL,
            kind: .changed,
            changedURL: changedURL
        )
    }

    static func renamed(rootURL: URL, changedURL: URL) -> WorkspaceFileSystemEvent {
        WorkspaceFileSystemEvent(
            rootURL: rootURL,
            kind: .renamed,
            changedURL: changedURL
        )
    }

    static func deleted(rootURL: URL, changedURL: URL) -> WorkspaceFileSystemEvent {
        WorkspaceFileSystemEvent(
            rootURL: rootURL,
            kind: .deleted,
            changedURL: changedURL
        )
    }

    static func rootInvalidated(rootURL: URL) -> WorkspaceFileSystemEvent {
        WorkspaceFileSystemEvent(rootURL: rootURL, kind: .rootInvalidated)
    }
}

protocol WorkspaceFileWatching: AnyObject {
    var rootURL: URL { get }
    func cancel()
}

protocol WorkspaceFileWatcherFactory: AnyObject, Sendable {
    var maximumWatchedRoots: Int { get }

    func makeWatcher(
        for rootURL: URL,
        onEvent: @escaping @Sendable (WorkspaceFileSystemEvent) -> Void
    ) throws -> any WorkspaceFileWatching
}

extension WorkspaceFileWatcherFactory {
    var maximumWatchedRoots: Int { 20 }
}

enum WorkspaceFileWatcherError: Error, LocalizedError, Sendable {
    case invalidRoot(URL)
    case couldNotCreateStream(URL)
    case couldNotStartStream(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidRoot(url):
            "The workspace watcher requires an absolute local directory: \(url.path)"
        case let .couldNotCreateStream(url):
            "The recursive workspace event stream could not be created: \(url.path)"
        case let .couldNotStartStream(url):
            "The recursive workspace event stream could not be started: \(url.path)"
        }
    }
}

#if os(macOS)
import CoreServices

/// A per-root FSEvents stream. `FileEvents` supplies recursive descendant
/// changes instead of only observing the root directory vnode. The stream
/// never opens a changed child and therefore cannot expand filesystem access.
final class FSEventsWorkspaceFileWatcherFactory: WorkspaceFileWatcherFactory,
    @unchecked Sendable {
    let maximumWatchedRoots: Int
    let latency: TimeInterval

    init(maximumWatchedRoots: Int = 20, latency: TimeInterval = 0.1) {
        precondition(maximumWatchedRoots >= 0)
        precondition(latency >= 0 && latency.isFinite)
        self.maximumWatchedRoots = maximumWatchedRoots
        self.latency = latency
    }

    func makeWatcher(
        for rootURL: URL,
        onEvent: @escaping @Sendable (WorkspaceFileSystemEvent) -> Void
    ) throws -> any WorkspaceFileWatching {
        try FSEventsWorkspaceFileWatcher(
            rootURL: rootURL, latency: latency, onEvent: onEvent
        )
    }
}

final class FSEventsWorkspaceFileWatcher: WorkspaceFileWatching,
    @unchecked Sendable {
    enum LifecycleEvent: Equatable, Sendable {
        case start(isOnStreamQueue: Bool)
        case callback(isOnStreamQueue: Bool)
        case stop(isOnStreamQueue: Bool)
        case invalidate(isOnStreamQueue: Bool)
        case release(isOnStreamQueue: Bool)
    }

    private final class CallbackBox: @unchecked Sendable {
        let rootURL: URL
        let onEvent: @Sendable (WorkspaceFileSystemEvent) -> Void
        private let lifecycleObserver: (@Sendable (LifecycleEvent) -> Void)?
        private let isOnStreamQueue: @Sendable () -> Bool
        private let lock = NSLock()
        private var isCancelled = false

        init(
            rootURL: URL,
            onEvent: @escaping @Sendable (WorkspaceFileSystemEvent) -> Void,
            lifecycleObserver: (@escaping @Sendable (LifecycleEvent) -> Void)? = nil,
            isOnStreamQueue: @escaping @Sendable () -> Bool
        ) {
            self.rootURL = rootURL
            self.onEvent = onEvent
            self.lifecycleObserver = lifecycleObserver
            self.isOnStreamQueue = isOnStreamQueue
        }

        func emit(_ event: WorkspaceFileSystemEvent) {
            lock.lock()
            let shouldEmit = !isCancelled
            lock.unlock()
            guard shouldEmit else { return }
            lifecycleObserver?(.callback(isOnStreamQueue: isOnStreamQueue()))
            onEvent(event)
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }
    }

    let rootURL: URL
    private let callbackBox: CallbackBox
    private let stateLock = NSLock()
    private let streamQueue: DispatchQueue
    private let streamQueueKey: DispatchSpecificKey<UInt8>
    private let lifecycleObserver: (@Sendable (LifecycleEvent) -> Void)?
    private var stream: FSEventStreamRef?
    init(
        rootURL: URL,
        latency: TimeInterval,
        onEvent: @escaping @Sendable (WorkspaceFileSystemEvent) -> Void,
        lifecycleObserver: (@escaping @Sendable (LifecycleEvent) -> Void)? = nil
    ) throws {
        let root = rootURL.standardizedFileURL
        guard root.isFileURL, root.host == nil || root.host?.isEmpty == true,
              root.path.hasPrefix("/"), !root.path.contains("\0") else {
            throw WorkspaceFileWatcherError.invalidRoot(rootURL)
        }
        let streamQueue = DispatchQueue(
            label: "LumenEditor.WorkspaceFSEvents.\(UUID().uuidString)",
            qos: .utility
        )
        let streamQueueKey = DispatchSpecificKey<UInt8>()
        streamQueue.setSpecific(key: streamQueueKey, value: 1)
        self.rootURL = root
        self.streamQueue = streamQueue
        self.streamQueueKey = streamQueueKey
        self.lifecycleObserver = lifecycleObserver
        callbackBox = CallbackBox(
            rootURL: root,
            onEvent: onEvent,
            lifecycleObserver: lifecycleObserver,
            isOnStreamQueue: { DispatchQueue.getSpecific(key: streamQueueKey) != nil }
        )

        let callback: FSEventStreamCallback = {
            _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
            guard eventCount > 0, let callbackInfo, let eventPaths else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(callbackInfo)
                .retain()
                .takeRetainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            let count = min(Int(eventCount), paths.count)
            for index in 0..<count {
                let flags = eventFlags[index]
                if flags & FSEventStreamEventFlags(
                    UInt32(kFSEventStreamEventFlagEventIdsWrapped)
                        | UInt32(kFSEventStreamEventFlagHistoryDone)
                ) != 0 {
                    continue
                }
                guard let event = classifyEvent(
                    rootURL: box.rootURL,
                    eventPath: paths[index] as? String ?? box.rootURL.path,
                    flags: flags
                ) else { continue }
                box.emit(event)
            }
        }
        // The stream retains the callback box via explicit context callbacks,
        // and the callback takes an additional temporary retain so a cancel
        // triggered from within the callback cannot free the box mid-stack.
        let callbackInfo = Unmanaged.passUnretained(callbackBox).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: callbackInfo,
            retain: { info in
                guard let info else { return nil }
                return Unmanaged<CallbackBox>.fromOpaque(info).retain().toOpaque()
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            UInt32(kFSEventStreamCreateFlagFileEvents)
                | UInt32(kFSEventStreamCreateFlagWatchRoot)
                | UInt32(kFSEventStreamCreateFlagNoDefer)
                | UInt32(kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags
        ) else {
            throw WorkspaceFileWatcherError.couldNotCreateStream(root)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(
            stream, streamQueue
        )
        let didStart = streamQueue.sync { () -> Bool in
            lifecycleObserver?(
                .start(
                    isOnStreamQueue: DispatchQueue.getSpecific(key: streamQueueKey)
                        != nil
                )
            )
            return FSEventStreamStart(stream)
        }
        guard didStart else {
            self.stream = nil
            streamQueue.sync {
                lifecycleObserver?(
                    .invalidate(
                        isOnStreamQueue: DispatchQueue.getSpecific(
                            key: streamQueueKey
                        ) != nil
                    )
                )
                FSEventStreamInvalidate(stream)
                lifecycleObserver?(
                    .release(
                        isOnStreamQueue: DispatchQueue.getSpecific(
                            key: streamQueueKey
                        ) != nil
                    )
                )
                FSEventStreamRelease(stream)
            }
            throw WorkspaceFileWatcherError.couldNotStartStream(root)
        }
    }

    func cancel() {
        callbackBox.cancel()
        let stream: FSEventStreamRef?
        stateLock.lock()
        stream = self.stream
        self.stream = nil
        stateLock.unlock()
        guard let stream else { return }
        scheduleTeardown(stream: stream, shouldStop: true)
    }

    deinit { cancel() }

    func emitTestCallbackOnStreamQueue() {
        streamQueue.async { [callbackBox] in
            callbackBox.emit(.changed(rootURL: callbackBox.rootURL, changedURL: callbackBox.rootURL))
        }
    }

    static func classifyEvent(
        rootURL: URL,
        eventPath: String,
        flags: FSEventStreamEventFlags
    ) -> WorkspaceFileSystemEvent? {
        let root = rootURL.standardizedFileURL
        let fallbackFlags = FSEventStreamEventFlags(
            UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                | UInt32(kFSEventStreamEventFlagRootChanged)
                | UInt32(kFSEventStreamEventFlagKernelDropped)
                | UInt32(kFSEventStreamEventFlagUserDropped)
                | UInt32(kFSEventStreamEventFlagMount)
                | UInt32(kFSEventStreamEventFlagUnmount)
        )
        if flags & fallbackFlags != 0 {
            return .rootInvalidated(rootURL: root)
        }

        let changedURL = URL(
            fileURLWithPath: eventPath,
            isDirectory: flags & FSEventStreamEventFlags(
                UInt32(kFSEventStreamEventFlagItemIsDir)
            ) != 0
        ).standardizedFileURL
        let rootPath = root.path
        let changedPath = changedURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard changedPath == rootPath || changedPath.hasPrefix(prefix) else {
            return .rootInvalidated(rootURL: root)
        }
        guard changedPath != rootPath else {
            return .rootInvalidated(rootURL: root)
        }

        if flags & FSEventStreamEventFlags(
            UInt32(kFSEventStreamEventFlagItemRenamed)
        ) != 0 {
            return .renamed(rootURL: root, changedURL: changedURL)
        }
        if flags & FSEventStreamEventFlags(
            UInt32(kFSEventStreamEventFlagItemRemoved)
        ) != 0 {
            return .deleted(rootURL: root, changedURL: changedURL)
        }
        let changedFlags = FSEventStreamEventFlags(
            UInt32(kFSEventStreamEventFlagItemCreated)
                | UInt32(kFSEventStreamEventFlagItemModified)
                | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
                | UInt32(kFSEventStreamEventFlagItemFinderInfoMod)
                | UInt32(kFSEventStreamEventFlagItemChangeOwner)
                | UInt32(kFSEventStreamEventFlagItemXattrMod)
                | UInt32(kFSEventStreamEventFlagItemCloned)
        )
        if flags & changedFlags != 0 {
            return .changed(rootURL: root, changedURL: changedURL)
        }
        return .changed(rootURL: root, changedURL: changedURL)
    }

    private func scheduleTeardown(
        stream: FSEventStreamRef,
        shouldStop: Bool
    ) {
        let streamQueue = self.streamQueue
        let streamQueueKey = self.streamQueueKey
        let lifecycleObserver = self.lifecycleObserver
        streamQueue.async {
            let isOnStreamQueue = DispatchQueue.getSpecific(key: streamQueueKey)
                != nil
            if shouldStop {
                lifecycleObserver?(.stop(isOnStreamQueue: isOnStreamQueue))
                FSEventStreamStop(stream)
            }
            lifecycleObserver?(.invalidate(isOnStreamQueue: isOnStreamQueue))
            FSEventStreamInvalidate(stream)
            lifecycleObserver?(.release(isOnStreamQueue: isOnStreamQueue))
            FSEventStreamRelease(stream)
        }
    }
}
#else
/// Tests inject a watcher factory. This fallback only keeps the source tree
/// type-checkable on non-macOS hosts and is never used by the macOS product.
final class FSEventsWorkspaceFileWatcherFactory: WorkspaceFileWatcherFactory,
    @unchecked Sendable {
    let maximumWatchedRoots: Int

    init(maximumWatchedRoots: Int = 20, latency: TimeInterval = 0.1) {
        precondition(maximumWatchedRoots >= 0)
        precondition(latency >= 0 && latency.isFinite)
        self.maximumWatchedRoots = maximumWatchedRoots
    }

    func makeWatcher(
        for rootURL: URL,
        onEvent: @escaping @Sendable (WorkspaceFileSystemEvent) -> Void
    ) throws -> any WorkspaceFileWatching {
        throw WorkspaceFileWatcherError.couldNotCreateStream(rootURL)
    }
}
#endif
