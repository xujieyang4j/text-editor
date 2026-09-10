import AppKit
import LumenEditorCore

private final class NotificationObserverTokenBox {
    private var observer: (any NSObjectProtocol)?

    func replace(with observer: (any NSObjectProtocol)?) {
        if let current = self.observer {
            NotificationCenter.default.removeObserver(current)
        }
        self.observer = observer
    }

    func clear() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

enum NativeMinimapPlanner {
    static let maximumRows = 2_048
    static let maximumColumns = 120
    static let maximumLineProbeUTF16Length = 512

    struct Row: Equatable {
        let sourceFraction: Double
        let runs: [Range<Int>]
    }

    struct Plan: Equatable {
        let rows: [Row]
        let wasSampled: Bool
    }

    static func scrollTargetY(
        pointerY: CGFloat, minimapHeight: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat
    ) -> CGFloat {
        guard minimapHeight.isFinite, minimapHeight > 0,
              documentHeight.isFinite, documentHeight > 0,
              viewportHeight.isFinite, viewportHeight >= 0
        else { return 0 }
        let clampedPointerY = min(max(0, pointerY), minimapHeight)
        let maximumY = max(0, documentHeight - viewportHeight)
        guard maximumY > 0 else { return 0 }
        let fraction = clampedPointerY / minimapHeight
        return min(maximumY, max(0, fraction * maximumY))
    }

    static func viewportRect(
        minimapBounds: NSRect, documentHeight: CGFloat, visibleRect: NSRect
    ) -> NSRect? {
        guard minimapBounds.width > 0, minimapBounds.height > 0,
              documentHeight.isFinite, documentHeight > 0
        else { return nil }
        let scale = minimapBounds.height / documentHeight
        let height = min(minimapBounds.height, max(8, visibleRect.height * scale))
        let y = min(max(0, minimapBounds.height - height), max(0, visibleRect.minY * scale))
        return NSRect(x: 1, y: y, width: max(0, minimapBounds.width - 2), height: height)
    }

    static func plan(text: String, maximumRows requestedRows: Int = maximumRows) -> Plan {
        let source = text as NSString
        let limit = min(maximumRows, max(1, requestedRows))
        guard source.length > 0 else { return Plan(rows: [], wasSampled: false) }
        let sampleCount = min(limit, source.length)
        var rows: [Row] = []
        var priorStart = -1
        rows.reserveCapacity(sampleCount)
        for sample in 0..<sampleCount {
            let target = sampleCount == 1 ? 0
                : Int((Double(sample) / Double(sampleCount - 1)) * Double(source.length - 1))
            let start = boundedLineStart(near: target, source: source)
            guard start != priorStart else { continue }
            priorStart = start
            let end = boundedLineEnd(from: start, source: source)
            rows.append(Row(
                sourceFraction: Double(start) / Double(max(1, source.length)),
                runs: visibleRuns(source: source, start: start, end: end)
            ))
        }
        return Plan(rows: rows, wasSampled: sampleCount < source.length)
    }

    private static func boundedLineStart(near target: Int, source: NSString) -> Int {
        var index = min(max(0, target), max(0, source.length - 1))
        let lower = max(0, index - maximumLineProbeUTF16Length)
        while index > lower {
            let prior = source.character(at: index - 1)
            if prior == 0x0A || prior == 0x0D { break }
            index -= 1
        }
        return index
    }

    private static func boundedLineEnd(from start: Int, source: NSString) -> Int {
        let upper = min(source.length, start + maximumLineProbeUTF16Length)
        var index = start
        while index < upper {
            let unit = source.character(at: index)
            if unit == 0x0A || unit == 0x0D { break }
            index += 1
        }
        return index
    }

    private static func visibleRuns(source: NSString, start: Int, end: Int) -> [Range<Int>] {
        let upper = min(end, start + maximumColumns)
        var result: [Range<Int>] = []
        var runStart: Int?
        for index in start..<upper {
            let unit = source.character(at: index)
            let visible = unit != 0x20 && unit != 0x09
            if visible, runStart == nil { runStart = index - start }
            if !visible, let begun = runStart {
                result.append(begun..<(index - start))
                runStart = nil
            }
        }
        if let begun = runStart { result.append(begun..<(upper - start)) }
        return result
    }
}

@MainActor
final class NativeEditorContainerView: NSView {
    let scrollView = NSScrollView(frame: .zero)
    private let minimap = NativeEditorMinimapView(frame: .zero)
    private(set) var showsMinimap = false
    private let accessibilityDisplayObserverToken = NotificationObserverTokenBox()
    private var accessibilityDisplayChange: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(scrollView)
        addSubview(minimap)
        minimap.attach(to: scrollView)
    }

    required init?(coder: NSCoder) { nil }

    func observeAccessibilityDisplayChanges(_ action: @escaping () -> Void) {
        accessibilityDisplayChange = action
        let observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accessibilityDisplayChange?()
            }
        }
        accessibilityDisplayObserverToken.replace(with: observer)
    }

    func configureMinimap(
        shown: Bool, text: String, documentID: String, revision: UInt64,
        palette: NativeEditorPalette, locale: EditorLocale
    ) {
        showsMinimap = shown
        minimap.isHidden = !shown
        minimap.configure(
            text: text, documentID: documentID, revision: revision,
            palette: palette, locale: locale
        )
        needsLayout = true
    }

    func refreshMinimapPalette(_ palette: NativeEditorPalette) {
        minimap.refreshPalette(palette)
    }

    override func layout() {
        super.layout()
        let minimapWidth: CGFloat = showsMinimap && bounds.width >= 320
            ? min(120, max(78, floor(bounds.width * 0.14))) : 0
        scrollView.frame = NSRect(
            x: 0, y: 0, width: max(0, bounds.width - minimapWidth), height: bounds.height
        )
        minimap.frame = NSRect(
            x: max(0, bounds.width - minimapWidth), y: 0,
            width: minimapWidth, height: bounds.height
        )
    }
}

@MainActor
private final class NativeEditorMinimapView: NSView {
    private struct Identity: Equatable {
        let documentID: String
        let revision: UInt64
    }

    override var isFlipped: Bool { true }
    private weak var scrollView: NSScrollView?
    private let boundsObserverToken = NotificationObserverTokenBox()
    private var identity: Identity?
    private var plan = NativeMinimapPlanner.Plan(rows: [], wasSampled: false)
    private var palette = NativeEditorPalette.make(colorScheme: .dark, compatibleWith: .dark)
    private var pointerNavigationActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityIdentifier("editor.minimap")
    }

    required init?(coder: NSCoder) { nil }

    func attach(to scrollView: NSScrollView) {
        self.scrollView = scrollView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.needsDisplay = true }
        }
        boundsObserverToken.replace(with: observer)
    }

    func configure(
        text: String, documentID: String, revision: UInt64,
        palette: NativeEditorPalette, locale: EditorLocale
    ) {
        setAccessibilityLabel(locale.localizedApp(.documentMinimap))
        let nextIdentity = Identity(documentID: documentID, revision: revision)
        if identity != nextIdentity {
            identity = nextIdentity
            plan = NativeMinimapPlanner.plan(text: text)
        }
        if self.palette != palette { self.palette = palette }
        if isHidden { endPointerNavigation() }
        needsDisplay = true
    }

    func refreshPalette(_ palette: NativeEditorPalette) {
        guard self.palette != palette else { return }
        self.palette = palette
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        palette.gutterBackground.setFill()
        dirtyRect.fill()
        guard bounds.width > 0, bounds.height > 0 else { return }

        palette.foreground.withAlphaComponent(0.42).setFill()
        let usableWidth = max(1, bounds.width - 8)
        let columnWidth = usableWidth / CGFloat(NativeMinimapPlanner.maximumColumns)
        let rowHeight = max(1, min(2, bounds.height / CGFloat(max(1, plan.rows.count))))
        for row in plan.rows {
            let y = floor(CGFloat(row.sourceFraction) * max(0, bounds.height - rowHeight))
            for run in row.runs {
                NSRect(
                    x: 4 + CGFloat(run.lowerBound) * columnWidth, y: y,
                    width: max(1, CGFloat(run.count) * columnWidth), height: rowHeight
                ).fill()
            }
        }

        if let viewport = viewportRect {
            palette.selectionBackground.withAlphaComponent(0.48).setFill()
            viewport.fill()
            palette.ruler.setStroke()
            NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        pointerNavigationActive = true
        navigate(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pointerNavigationActive else {
            super.mouseDragged(with: event)
            return
        }
        navigate(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard pointerNavigationActive else {
            super.mouseUp(with: event)
            return
        }
        navigate(with: event)
        endPointerNavigation()
    }

    override func cancelOperation(_ sender: Any?) {
        endPointerNavigation()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard pointerNavigationActive else { return }
        if (NSEvent.pressedMouseButtons & 1) == 0 {
            endPointerNavigation()
        }
    }

    private var viewportRect: NSRect? {
        guard let scrollView, let documentView = scrollView.documentView,
              documentView.bounds.height > 0 else { return nil }
        return NativeMinimapPlanner.viewportRect(
            minimapBounds: bounds,
            documentHeight: documentView.bounds.height,
            visibleRect: scrollView.contentView.bounds
        )
    }

    private func navigate(with event: NSEvent) {
        guard let scrollView, let documentView = scrollView.documentView else {
            endPointerNavigation()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let target = NativeMinimapPlanner.scrollTargetY(
            pointerY: point.y,
            minimapHeight: bounds.height,
            documentHeight: documentView.bounds.height,
            viewportHeight: scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(
            x: scrollView.contentView.bounds.origin.x, y: target
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsDisplay = true
    }

    private func endPointerNavigation() {
        guard pointerNavigationActive else { return }
        pointerNavigationActive = false
        needsDisplay = true
    }
}
