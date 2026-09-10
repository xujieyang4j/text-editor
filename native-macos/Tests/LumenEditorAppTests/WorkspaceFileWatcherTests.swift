import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class WorkspaceFileWatcherTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testEventNormalizesUnsafePathsToRootInvalidation() {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        XCTAssertEqual(
            WorkspaceFileSystemEvent.changed(
                rootURL: root, changedURL: URL(fileURLWithPath: "/outside/file.txt")
            ),
            .rootInvalidated(rootURL: root)
        )
        XCTAssertEqual(
            WorkspaceFileSystemEvent.deleted(rootURL: root, changedURL: root),
            .rootInvalidated(rootURL: root)
        )
    }

    func testEventMergingKeepsTheStrongestKindForOnePath() {
        let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let file = root.appendingPathComponent("file.txt")
        XCTAssertEqual(
            WorkspaceFileSystemEvent.changed(rootURL: root, changedURL: file)
                .merged(with: .renamed(rootURL: root, changedURL: file)),
            .renamed(rootURL: root, changedURL: file)
        )
        XCTAssertEqual(
            WorkspaceFileSystemEvent.renamed(rootURL: root, changedURL: file)
                .merged(with: .deleted(rootURL: root, changedURL: file)),
            .deleted(rootURL: root, changedURL: file)
        )
    }

    @MainActor
    func testRootLifecycleCreatesAndCancelsIndependentWatchers() async throws {
        let first = try temporaryDirectory(named: "first")
        let second = try temporaryDirectory(named: "second")
        let factory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 2)
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: factory, watcherDebounceNanoseconds: 0
        )

        let didAddFirst = await controller.addRoot(first)
        let didAddSecond = await controller.addRoot(second)
        XCTAssertTrue(didAddFirst)
        XCTAssertTrue(didAddSecond)
        XCTAssertEqual(Set(factory.createdPaths), Set([first.path, second.path]))
        XCTAssertEqual(controller.watchedRootCount, 2)

        let firstRoot = try XCTUnwrap(controller.roots.first(where: {
            $0.url.standardizedFileURL == first.standardizedFileURL
        }))
        let didRemoveFirst = await controller.removeRoot(firstRoot)
        XCTAssertTrue(didRemoveFirst)
        XCTAssertEqual(factory.cancelCount(for: first), 1)
        XCTAssertEqual(factory.cancelCount(for: second), 0)
        XCTAssertEqual(controller.watchedRootCount, 1)
    }

    @MainActor
    func testWatcherCountIsCappedIndependentlyOfWorkspaceService() async throws {
        let factory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 1)
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: factory, watcherDebounceNanoseconds: 0
        )
        let first = try temporaryDirectory(named: "first")
        let second = try temporaryDirectory(named: "second")

        let didAddFirst = await controller.addRoot(first)
        let didAddSecond = await controller.addRoot(second)
        XCTAssertTrue(didAddFirst)
        XCTAssertTrue(didAddSecond)

        XCTAssertEqual(factory.createdPaths.count, 1)
        XCTAssertEqual(factory.activeCount, 1)
        XCTAssertEqual(controller.roots.count, 2)
        XCTAssertEqual(controller.watchedRootCount, 1)
    }

    @MainActor
    func testSeparateWindowControllersDoNotShareWatchers() async throws {
        let root = try temporaryDirectory(named: "shared-root")
        let firstFactory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 1)
        let secondFactory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 1)
        let first = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: firstFactory, watcherDebounceNanoseconds: 0
        )
        let second = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: secondFactory, watcherDebounceNanoseconds: 0
        )

        let firstAdded = await first.addRoot(root)
        let secondAdded = await second.addRoot(root)
        XCTAssertTrue(firstAdded)
        XCTAssertTrue(secondAdded)
        XCTAssertEqual(first.watchedRootCount, 1)
        XCTAssertEqual(second.watchedRootCount, 1)
        XCTAssertEqual(firstFactory.createdPaths, [root.path])
        XCTAssertEqual(secondFactory.createdPaths, [root.path])
    }

    @MainActor
    func testChangedPathEventsRefreshImpactedDirectoriesAndNotifyOncePerPath() async throws {
        let root = try temporaryDirectory(named: "root")
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        let sibling = root.appendingPathComponent("Sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let factory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 2)
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: factory, watcherDebounceNanoseconds: 1_000_000
        )
        var callbacks: [URL] = []
        controller.setFileSystemChangeHandler { callbacks.append($0) }
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)
        controller.loadChildren(of: root)
        await waitForDirectory(controller, url: root)
        controller.setExpanded(true, directory: nested)
        await waitForDirectory(controller, url: nested)
        controller.setExpanded(true, directory: sibling)
        await waitForDirectory(controller, url: sibling)

        let created = nested.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: created)

        factory.emitChanged(root, changedURL: created)
        factory.emitRenamed(root, changedURL: created)
        for _ in 0..<4 { await Task.yield() }
        await controller.waitForPendingFileSystemRefresh()

        XCTAssertEqual(callbacks.map { $0.standardizedFileURL.path }, [created.path])
        XCTAssertEqual(controller.state(for: root).loadState, .loaded)
        XCTAssertEqual(controller.state(for: nested).loadState, .loaded)
        XCTAssertEqual(
            controller.state(for: nested).entries.map(\.name),
            ["note.txt"]
        )
        XCTAssertEqual(controller.state(for: sibling).entries, [])
    }

    @MainActor
    func testRootInvalidationRefreshesAllVisibleDirectoriesAndNotifiesRoot() async throws {
        let root = try temporaryDirectory(named: "invalidated")
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let factory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 1)
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: factory, watcherDebounceNanoseconds: 0
        )
        var callbacks: [URL] = []
        controller.setFileSystemChangeHandler { callbacks.append($0) }
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)
        controller.loadChildren(of: root)
        await waitForDirectory(controller, url: root)
        controller.setExpanded(true, directory: first)
        await waitForDirectory(controller, url: first)
        controller.setExpanded(true, directory: second)
        await waitForDirectory(controller, url: second)

        try Data().write(to: first.appendingPathComponent("a.txt"))
        try Data().write(to: second.appendingPathComponent("b.txt"))

        factory.emitRootInvalidated(root)
        await controller.waitForPendingFileSystemRefresh()

        XCTAssertEqual(callbacks.map { $0.standardizedFileURL.path }, [root.path])
        XCTAssertEqual(controller.state(for: first).entries.map(\.name), ["a.txt"])
        XCTAssertEqual(controller.state(for: second).entries.map(\.name), ["b.txt"])
    }

    @MainActor
    func testDeletedExpandedDirectoryRefreshesParentWithoutFolderFailure() async throws {
        let root = try temporaryDirectory(named: "deleted-directory")
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let factory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 1)
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: factory, watcherDebounceNanoseconds: 0
        )

        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)
        controller.loadChildren(of: root)
        await waitForDirectory(controller, url: root)
        controller.setExpanded(true, directory: nested)
        await waitForDirectory(controller, url: nested)

        try FileManager.default.removeItem(at: nested)
        factory.emitDeleted(root, changedURL: nested)
        await controller.waitForPendingFileSystemRefresh()

        XCTAssertEqual(controller.state(for: root).entries, [])
        XCTAssertEqual(controller.state(for: root).loadState, .loaded)
        XCTAssertEqual(controller.state(for: nested).loadState, .loaded)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testRemovedRootDropsQueuedEventBeforeDebounceFires() async throws {
        let root = try temporaryDirectory(named: "removed")
        let factory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 1)
        let controller = WorkspaceController(
            service: WorkspaceService(), openFile: { _ in },
            fileWatcherFactory: factory, watcherDebounceNanoseconds: 50_000_000
        )
        var callbacks = 0
        controller.setFileSystemChangeHandler { _ in callbacks += 1 }
        let didAddRoot = await controller.addRoot(root)
        XCTAssertTrue(didAddRoot)
        let registered = try XCTUnwrap(controller.roots.first)

        factory.emit(root)
        for _ in 0..<4 { await Task.yield() }
        let didRemoveRoot = await controller.removeRoot(registered)
        XCTAssertTrue(didRemoveRoot)
        await controller.waitForPendingFileSystemRefresh()

        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(factory.cancelCount(for: root), 1)
        XCTAssertEqual(controller.watchedRootCount, 0)
    }

    @MainActor
    func testExclusionChangeDropsWatcherCallbackQueuedUnderOldPolicy() async throws {
        let root = try temporaryDirectory(named: "exclusion-epoch")
        let changed = root.appendingPathComponent("generated.tmp")
        try Data().write(to: changed)
        let gate = WatcherDirectoryReadGate()
        defer { gate.releaseAll() }
        let factory = TestWorkspaceWatcherFactory(maximumWatchedRoots: 1)
        let controller = WorkspaceController(
            service: WorkspaceService(beforeOpeningFileDescriptor: { _ in
                gate.intercept()
            }), openFile: { _ in },
            fileWatcherFactory: factory, watcherDebounceNanoseconds: 0
        )
        var callbacks: [URL] = []
        controller.setFileSystemChangeHandler { callbacks.append($0) }
        XCTAssertTrue(await controller.addRoot(root))

        factory.emitChanged(root, changedURL: changed)
        await waitForDirectoryRead(gate, count: 1)
        controller.setProjectExclusions(["*.tmp"])
        gate.releaseFirst()
        await waitForDirectoryRead(gate, count: 2)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(controller.state(for: root).loadState, .loading)

        gate.releaseSecond()
        await waitForDirectory(controller, url: root)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertTrue(controller.state(for: root).entries.isEmpty)
        XCTAssertEqual(controller.projectExclusionGeneration, 1)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkspaceFileWatcherTests-\(UUID().uuidString)", isDirectory: true
        )
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(base)
        return url
    }

    @MainActor
    private func waitForDirectory(_ controller: WorkspaceController, url: URL) async {
        for _ in 0..<100 {
            if controller.state(for: url).loadState != .loading { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for workspace directory")
    }

    @MainActor
    private func waitForDirectoryRead(
        _ gate: WatcherDirectoryReadGate, count: Int
    ) async {
        for _ in 0..<1_000 {
            if gate.callCount >= count { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controlled directory read")
    }
}

private final class WatcherDirectoryReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstRelease = DispatchSemaphore(value: 0)
    private let secondRelease = DispatchSemaphore(value: 0)
    private var interceptedCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return interceptedCount
    }

    func intercept() {
        lock.lock()
        interceptedCount += 1
        let call = interceptedCount
        lock.unlock()
        if call == 1 {
            firstRelease.wait()
        } else if call == 2 {
            secondRelease.wait()
        }
    }

    func releaseFirst() { firstRelease.signal() }
    func releaseSecond() { secondRelease.signal() }

    func releaseAll() {
        firstRelease.signal()
        secondRelease.signal()
    }
}

#if os(macOS)
extension WorkspaceFileWatcherTests {
    func testFSEventsClassificationMapsFlagsToFineGrainedKinds() throws {
        let root = try temporaryDirectory(named: "classify")
        let file = root.appendingPathComponent("child.txt")

        let changed = FSEventsWorkspaceFileWatcher.classifyEvent(
            rootURL: root,
            eventPath: file.path,
            flags: FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagItemModified))
        )
        XCTAssertEqual(changed, .changed(rootURL: root, changedURL: file))

        let renamed = FSEventsWorkspaceFileWatcher.classifyEvent(
            rootURL: root,
            eventPath: file.path,
            flags: FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagItemRenamed))
        )
        XCTAssertEqual(renamed, .renamed(rootURL: root, changedURL: file))

        let deleted = FSEventsWorkspaceFileWatcher.classifyEvent(
            rootURL: root,
            eventPath: file.path,
            flags: FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagItemRemoved))
        )
        XCTAssertEqual(deleted, .deleted(rootURL: root, changedURL: file))

        let invalidated = FSEventsWorkspaceFileWatcher.classifyEvent(
            rootURL: root,
            eventPath: file.path,
            flags: FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        )
        XCTAssertEqual(invalidated, .rootInvalidated(rootURL: root))
    }

    func testFSEventsWatcherLifecycleSerializesOperationsOnStreamQueue() throws {
        let root = try temporaryDirectory(named: "lifecycle")
        let recorder = LifecycleRecorder()
        let watcher = try FSEventsWorkspaceFileWatcher(
            rootURL: root,
            latency: 0,
            onEvent: { _ in },
            lifecycleObserver: { recorder.record($0) }
        )

        watcher.cancel()
        XCTAssertTrue(
            recorder.waitForEventCount(4, timeout: 2),
            "Timed out waiting for start/stop/invalidate/release"
        )

        let events = recorder.events
        XCTAssertEqual(events.map(\.kind), [.start, .stop, .invalidate, .release])
        XCTAssertTrue(events.allSatisfy(\.isOnStreamQueue))
    }

    func testFSEventsWatcherCancelFromCallbackDefersTeardownSafely() throws {
        let root = try temporaryDirectory(named: "callback-cancel")
        let recorder = LifecycleRecorder()
        var watcher: FSEventsWorkspaceFileWatcher?
        watcher = try FSEventsWorkspaceFileWatcher(
            rootURL: root,
            latency: 0,
            onEvent: { _ in watcher?.cancel() },
            lifecycleObserver: { recorder.record($0) }
        )

        watcher?.emitTestCallbackOnStreamQueue()
        XCTAssertTrue(
            recorder.waitForEventCount(5, timeout: 2),
            "Timed out waiting for callback-driven teardown"
        )
        watcher = nil

        let events = recorder.events
        XCTAssertEqual(
            events.map(\.kind),
            [.start, .callback, .stop, .invalidate, .release]
        )
        XCTAssertTrue(events.allSatisfy(\.isOnStreamQueue))
    }
}

private final class LifecycleRecorder: @unchecked Sendable {
    struct RecordedEvent: Equatable {
        enum Kind: Equatable {
            case start
            case callback
            case stop
            case invalidate
            case release
        }

        let kind: Kind
        let isOnStreamQueue: Bool
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var recorded: [RecordedEvent] = []

    var events: [RecordedEvent] { lock.withWatcherLock { recorded } }

    func record(_ event: FSEventsWorkspaceFileWatcher.LifecycleEvent) {
        lock.withWatcherLock {
            recorded.append(
                RecordedEvent(kind: kind(for: event), isOnStreamQueue: isOnStreamQueue(for: event))
            )
        }
        semaphore.signal()
    }

    func waitForEventCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while events.count < count {
            if semaphore.wait(timeout: deadline) == .timedOut {
                return events.count >= count
            }
        }
        return true
    }

    private func kind(for event: FSEventsWorkspaceFileWatcher.LifecycleEvent) -> RecordedEvent.Kind {
        switch event {
        case .start:
            return .start
        case .callback:
            return .callback
        case .stop:
            return .stop
        case .invalidate:
            return .invalidate
        case .release:
            return .release
        }
    }

    private func isOnStreamQueue(for event: FSEventsWorkspaceFileWatcher.LifecycleEvent) -> Bool {
        switch event {
        case let .start(isOnStreamQueue),
            let .callback(isOnStreamQueue),
            let .stop(isOnStreamQueue),
            let .invalidate(isOnStreamQueue),
            let .release(isOnStreamQueue):
            return isOnStreamQueue
        }
    }
}
#endif

private final class TestWorkspaceWatcherFactory: WorkspaceFileWatcherFactory,
    @unchecked Sendable {
    let maximumWatchedRoots: Int
    private let lock = NSLock()
    private var watchers: [String: TestWorkspaceWatcher] = [:]
    private var allWatchers: [TestWorkspaceWatcher] = []

    init(maximumWatchedRoots: Int) {
        self.maximumWatchedRoots = maximumWatchedRoots
    }

    var createdPaths: [String] { lock.withWatcherLock { allWatchers.map { $0.rootURL.path } } }
    var activeCount: Int { lock.withWatcherLock { watchers.values.filter { !$0.isCancelled }.count } }

    func cancelCount(for url: URL) -> Int {
        lock.withWatcherLock {
            allWatchers.first(where: { $0.rootURL.path == url.standardizedFileURL.path })?
                .recordedCancelCount ?? 0
        }
    }

    func emit(_ url: URL) {
        emitRootInvalidated(url)
    }

    func emitChanged(_ rootURL: URL, changedURL: URL) {
        lock.withWatcherLock { watchers[rootURL.standardizedFileURL.path] }?
            .emitChanged(changedURL)
    }

    func emitRenamed(_ rootURL: URL, changedURL: URL) {
        lock.withWatcherLock { watchers[rootURL.standardizedFileURL.path] }?
            .emitRenamed(changedURL)
    }

    func emitDeleted(_ rootURL: URL, changedURL: URL) {
        lock.withWatcherLock { watchers[rootURL.standardizedFileURL.path] }?
            .emitDeleted(changedURL)
    }

    func emitRootInvalidated(_ rootURL: URL) {
        lock.withWatcherLock { watchers[rootURL.standardizedFileURL.path] }?
            .emitRootInvalidated()
    }

    func makeWatcher(
        for rootURL: URL,
        onEvent: @escaping @Sendable (WorkspaceFileSystemEvent) -> Void
    ) throws -> any WorkspaceFileWatching {
        let watcher = TestWorkspaceWatcher(rootURL: rootURL, onEvent: onEvent)
        lock.withWatcherLock {
            watchers[rootURL.standardizedFileURL.path] = watcher
            allWatchers.append(watcher)
        }
        return watcher
    }
}

private final class TestWorkspaceWatcher: WorkspaceFileWatching, @unchecked Sendable {
    let rootURL: URL
    private let onEvent: @Sendable (WorkspaceFileSystemEvent) -> Void
    private let lock = NSLock()
    private var cancelCount = 0
    var isCancelled: Bool { lock.withWatcherLock { cancelCount > 0 } }
    var recordedCancelCount: Int { lock.withWatcherLock { cancelCount } }

    init(
        rootURL: URL,
        onEvent: @escaping @Sendable (WorkspaceFileSystemEvent) -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.onEvent = onEvent
    }

    func emitChanged(_ changedURL: URL) {
        onEvent(.changed(rootURL: rootURL, changedURL: changedURL))
    }

    func emitRenamed(_ changedURL: URL) {
        onEvent(.renamed(rootURL: rootURL, changedURL: changedURL))
    }

    func emitDeleted(_ changedURL: URL) {
        onEvent(.deleted(rootURL: rootURL, changedURL: changedURL))
    }

    func emitRootInvalidated() {
        onEvent(.rootInvalidated(rootURL: rootURL))
    }

    func cancel() { lock.withWatcherLock { cancelCount += 1 } }
}

private extension NSLock {
    func withWatcherLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
