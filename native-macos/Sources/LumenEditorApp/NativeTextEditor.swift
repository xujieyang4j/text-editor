import AppKit
import LumenEditorCore
import SwiftUI

private final class NativeTextEditorNotificationObserverBox {
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

private final class NativeTextEditorDeferredTaskBox {
    var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    func beginReplacement() -> UInt64 {
        task?.cancel()
        generation &+= 1
        task = nil
        return generation
    }

    func install(_ task: Task<Void, Never>, for generation: UInt64) {
        guard self.generation == generation else {
            task.cancel()
            return
        }
        self.task = task
    }

    func clearIfCurrent(_ generation: UInt64) {
        guard self.generation == generation else { return }
        task = nil
    }

    func cancel() {
        _ = beginReplacement()
    }

    var isPending: Bool { task != nil }

    deinit {
        task?.cancel()
    }
}

typealias NativeTextEditorScrollPosition = EditorPaneScrollPosition

/// Pure accessibility copy and identity so AppKit metadata can be tested
/// without replacing NSTextView's native value or selection attributes.
enum NativeTextEditorAccessibility {
    struct Metadata: Equatable {
        let identifier: String
        let label: String
    }

    static func metadata(
        documentDisplayName: String, paneIndex: Int, viewID: EditorViewID,
        locale: EditorLocale
    ) -> Metadata {
        let paneNumber = max(0, paneIndex) + 1
        let label = locale.isSimplifiedChinese
            ? "\(documentDisplayName)，第 \(paneNumber) 个窗格编辑器"
            : "\(documentDisplayName), editor, pane \(paneNumber)"
        return Metadata(
            identifier: AppAccessibility.id(
                "editor pane \(viewID.rawValue) text"
            ),
            label: label
        )
    }

    static func help(
        diagnostics: [LanguageServerDiagnostic], locale: EditorLocale
    ) -> String {
        guard !diagnostics.isEmpty else {
            return locale.isSimplifiedChinese ? "纯文本编辑器。" : "Plain-text editor."
        }
        var errors = 0
        var warnings = 0
        var information = 0
        for diagnostic in diagnostics {
            switch diagnostic.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .info: information += 1
            }
        }
        if locale.isSimplifiedChinese {
            return "当前文档有 \(diagnostics.count) 个诊断：\(errors) 个错误，\(warnings) 个警告，\(information) 个信息"
        }
        return "Current document has \(diagnostics.count) diagnostics: \(errors) errors, \(warnings) warnings, \(information) information"
    }

    static let foldGutterIdentifier = AppAccessibility.id("editor fold gutter")

    static func foldGutterLabel(locale: EditorLocale) -> String {
        locale.text("Code folding gutter", zh: "代码折叠槽")
    }

    static func foldGutterValue(
        markerCount: Int, foldedCount: Int, locale: EditorLocale
    ) -> String {
        locale.text(
            "\(markerCount) foldable regions, \(foldedCount) folded",
            zh: "\(markerCount) 个可折叠区域，\(foldedCount) 个已折叠"
        )
    }

    static func foldMarkerIdentifier(_ marker: NativeTextEditorVisualPlanner.FoldMarker)
        -> String {
        "\(foldGutterIdentifier).marker.\(marker.id)"
    }

    static func foldMarkerLabel(
        _ marker: NativeTextEditorVisualPlanner.FoldMarker, locale: EditorLocale
    ) -> String {
        if marker.isFolded {
            return locale.text(
                "Unfold lines \(marker.startLine) through \(marker.endLine)",
                zh: "展开第 \(marker.startLine) 至 \(marker.endLine) 行"
            )
        }
        return locale.text(
            "Fold lines \(marker.startLine) through \(marker.endLine)",
            zh: "折叠第 \(marker.startLine) 至 \(marker.endLine) 行"
        )
    }

    static func foldMarkerValue(
        _ marker: NativeTextEditorVisualPlanner.FoldMarker, locale: EditorLocale
    ) -> String {
        locale.text(
            marker.isFolded ? "Folded" : "Expanded",
            zh: marker.isFolded ? "已折叠" : "已展开"
        )
    }

    static func foldActionAnnouncement(
        marker: NativeTextEditorVisualPlanner.FoldMarker,
        willFold: Bool,
        locale: EditorLocale
    ) -> String {
        if locale.isSimplifiedChinese {
            return "已\(willFold ? "折叠" : "展开")第 \(marker.startLine) 至 \(marker.endLine) 行"
        }
        return "\(willFold ? "Folded" : "Unfolded") lines \(marker.startLine) through \(marker.endLine)"
    }

    @MainActor
    static func apply(_ metadata: Metadata, to textView: NSTextView) {
        textView.setAccessibilityIdentifier(metadata.identifier)
        textView.setAccessibilityLabel(metadata.label)
    }
}

/// An AppKit-backed plain-text editor suitable for editing large documents.
struct NativeTextEditor: NSViewRepresentable {
    private let text: String
    private let documentID: String
    private let documentDisplayName: String
    private let fileURL: URL?
    private let viewID: EditorViewID
    private let paneIndex: Int
    private let documentRevision: UInt64
    private let selections: SelectionSet
    private let scrollPosition: NativeTextEditorScrollPosition
    @Binding private var isFocused: Bool
    private let isEditable: Bool

    private let fontSize: CGFloat
    private let tabWidth: Int
    private let indentWidth: Int
    private let insertSpaces: Bool
    private let softWrap: Bool
    private let showLineNumbers: Bool
    private let showWhitespace: Bool
    private let showIndentGuides: Bool
    private let highlightTrailingWhitespace: Bool
    private let rulers: [Int]
    private let spellChecking: Bool
    private let theme: EditorTheme
    private let colorScheme: EditorColorScheme
    private let language: String
    private let parsedHighlighting: NativeSyntaxHighlighter.ParsedSnapshot?
    private let parsedIndentation: CodeMirrorIndentationSnapshot?
    private let diagnosticSnapshot: LanguageServerDiagnosticPresentationSnapshot?
    private let showMinimap: Bool
    private let incrementalDiffMarkers: [IncrementalDiffMarker]
    private let findHighlightSnapshot: FindHighlightSnapshot?
    private let foldSnapshot: TextKitFoldSnapshot?
    private let onToggleFoldMarker: ((String) -> Bool)?
    private let onRevealFoldedContent: ((Int) -> Bool)?
    private let onSnippetNavigation: ((SnippetNavigationDirection) -> Bool)?
    private let onCancelSnippetSession: (() -> Bool)?
    @ObservedObject private var completionController: CompletionController
    private let locale: EditorLocale
    private let onTextChange: (TextTransaction) -> Bool
    private let onSelectionChange: (SelectionSet) -> Bool
    private let onManualSelectionChange: (SelectionSet, SelectionSet) -> Void
    private let onScrollChange: (NativeTextEditorScrollPosition) -> Void

    init(
        text: String,
        documentID: String,
        documentDisplayName: String,
        fileURL: URL? = nil,
        viewID: EditorViewID,
        paneIndex: Int,
        documentRevision: UInt64,
        selections: SelectionSet,
        scrollPosition: NativeTextEditorScrollPosition = .zero,
        isFocused: Binding<Bool>,
        isEditable: Bool = true,
        fontSize: CGFloat = 14,
        tabWidth: Int = 4,
        indentWidth: Int? = nil,
        insertSpaces: Bool = true,
        softWrap: Bool = false,
        showLineNumbers: Bool = true,
        showWhitespace: Bool = false,
        showIndentGuides: Bool = true,
        highlightTrailingWhitespace: Bool = true,
        rulers: [Int] = [],
        spellChecking: Bool = false,
        theme: EditorTheme = .dark,
        colorScheme: EditorColorScheme = .dark,
        language: String = "Plain Text",
        parsedHighlighting: NativeSyntaxHighlighter.ParsedSnapshot? = nil,
        parsedIndentation: CodeMirrorIndentationSnapshot? = nil,
        diagnosticSnapshot: LanguageServerDiagnosticPresentationSnapshot? = nil,
        showMinimap: Bool = false,
        incrementalDiffMarkers: [IncrementalDiffMarker] = [],
        findHighlightSnapshot: FindHighlightSnapshot? = nil,
        foldSnapshot: TextKitFoldSnapshot? = nil,
        onToggleFoldMarker: ((String) -> Bool)? = nil,
        onRevealFoldedContent: ((Int) -> Bool)? = nil,
        onSnippetNavigation: ((SnippetNavigationDirection) -> Bool)? = nil,
        onCancelSnippetSession: (() -> Bool)? = nil,
        completionController: CompletionController,
        locale: EditorLocale = .zhCN,
        onTextChange: @escaping (TextTransaction) -> Bool,
        onSelectionChange: @escaping (SelectionSet) -> Bool,
        onManualSelectionChange: @escaping (SelectionSet, SelectionSet) -> Void = { _, _ in },
        onScrollChange: @escaping (NativeTextEditorScrollPosition) -> Void
    ) {
        self.text = text
        self.documentID = documentID
        self.documentDisplayName = documentDisplayName
        self.fileURL = fileURL
        self.viewID = viewID
        self.paneIndex = paneIndex
        self.documentRevision = documentRevision
        self.selections = selections
        self.scrollPosition = scrollPosition
        _isFocused = isFocused
        self.isEditable = isEditable
        self.fontSize = fontSize
        self.tabWidth = min(16, max(1, tabWidth))
        self.indentWidth = min(16, max(1, indentWidth ?? tabWidth))
        self.insertSpaces = insertSpaces
        self.softWrap = softWrap
        self.showLineNumbers = showLineNumbers
        self.showWhitespace = showWhitespace
        self.showIndentGuides = showIndentGuides
        self.highlightTrailingWhitespace = highlightTrailingWhitespace
        self.rulers = Array(rulers.lazy.filter { $0 > 0 && $0 <= 500 }.prefix(10))
        self.spellChecking = spellChecking
        self.theme = theme
        self.colorScheme = colorScheme
        self.language = language
        self.parsedHighlighting = parsedHighlighting
        self.parsedIndentation = parsedIndentation
        self.diagnosticSnapshot = diagnosticSnapshot
        self.showMinimap = showMinimap
        self.incrementalDiffMarkers = incrementalDiffMarkers
        self.findHighlightSnapshot = findHighlightSnapshot
        self.foldSnapshot = foldSnapshot
        self.onToggleFoldMarker = onToggleFoldMarker
        self.onRevealFoldedContent = onRevealFoldedContent
        self.onSnippetNavigation = onSnippetNavigation
        self.onCancelSnippetSession = onCancelSnippetSession
        self.completionController = completionController
        self.locale = locale
        self.onTextChange = onTextChange
        self.onSelectionChange = onSelectionChange
        self.onManualSelectionChange = onManualSelectionChange
        self.onScrollChange = onScrollChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NativeEditorContainerView {
        let container = NativeEditorContainerView(frame: .zero)
        let scrollView = container.scrollView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        // Build an explicit TextKit 1 stack. Besides being stable on macOS 14, this
        // gives the ruler a direct and predictable glyph-to-line mapping.
        let textStorage = NSTextStorage()
        let layoutManager = NativeTextEditorLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: scrollView.contentSize.width,
                height: .greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = NativeTextView(
            frame: NSRect(origin: .zero, size: scrollView.contentSize),
            textContainer: textContainer
        )
        textView.configureRectangularSelectionIdentity(
            documentID: documentID, revision: documentRevision
        )
        textView.decorationLayoutManager = layoutManager
        layoutManager.configureSelectionVisuals(
            NativeTextEditorVisualPlanner.VisualSelection(
                anchor: selections.main.anchor, head: selections.main.head
            )
        )
        textView.completionEventHandler = context.coordinator.handleCompletionEvent(_:in:)
        textView.completionDismissHandler = context.coordinator.dismissCompletion
        textView.rectangularSelectionHandler =
            context.coordinator.applyRectangularSelection(_:appending:initialSelection:in:)
        textView.optionClickSelectionHandler =
            context.coordinator.applyOptionClickSelection(_:in:)
        textView.selectionDirectionAnchorProvider = { [weak coordinator = context.coordinator] in
            coordinator.map {
                NativeTextEditorAdapter.directionAnchors(from: $0.nativeSelections)
            } ?? []
        }
        textView.delegate = context.coordinator
        NativeTextEditorAdapter.applyEditability(isEditable, to: textView)
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        // DocumentBuffer owns atomic undo/redo, including selections. Keeping
        // AppKit's independent stack enabled would make the two histories drift.
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // NativeTextView paints the background before fixed-column rulers; a
        // second NSTextView fill would cover those rulers.
        textView.drawsBackground = false
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.string = text
        configureAccessibilityMetadata(on: textView)

        scrollView.documentView = textView
        configureFont(on: textView)
        configureTheme(on: textView, in: scrollView)
        configureParagraphStyle(on: textView)
        configureWrapping(on: textView, in: scrollView)
        configureSpellChecking(on: textView)
        configureVisualDecorations(on: textView)
        configureSyntaxHighlighting(on: layoutManager)
        configureDiagnostics(on: layoutManager, textView: textView, ruler: nil)
        configureFindHighlights(on: layoutManager, textView: textView)
        configureFolding(on: layoutManager)

        let ruler = LineNumberRulerView(
            scrollView: scrollView,
            orientation: .verticalRuler
        )
        ruler.clientView = textView
        ruler.palette = palette
        ruler.update(markers: incrementalDiffMarkers, showsLineNumbers: showLineNumbers)
        ruler.updateDiagnosticMarkers(layoutManager.diagnosticMarkedLines)
        configureFoldMarkers(on: ruler, textView: textView)
        ruler.rebuildLineStarts()
        scrollView.verticalRulerView = ruler
        let showsRuler = showsGutter
        scrollView.hasVerticalRuler = showsRuler
        scrollView.rulersVisible = showsRuler

        context.coordinator.attach(textView: textView, scrollView: scrollView, ruler: ruler)
        configureAccessibilityDisplayObserver(
            on: container, textView: textView, scrollView: scrollView, ruler: ruler
        )
        context.coordinator.applySelections(
            selections.clamped(toUTF16Length: textStorage.length),
            to: textView,
            force: true
        )
        context.coordinator.restoreScroll(scrollPosition, in: scrollView, force: true)
        context.coordinator.applyFocus(to: textView)
        container.configureMinimap(
            shown: showMinimap, text: text, documentID: documentID,
            revision: documentRevision, palette: palette, locale: locale
        )
        return container
    }

    func updateNSView(_ container: NativeEditorContainerView, context: Context) {
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? NativeTextView else { return }

        let coordinator = context.coordinator
        NativeTextEditorAdapter.applyEditability(isEditable, to: textView)
        if !isEditable { coordinator.dismissCompletion() }
        textView.configureRectangularSelectionIdentity(
            documentID: documentID, revision: documentRevision
        )
        configureAccessibilityMetadata(on: textView)
        let identityChanged = coordinator.adopt(parent: self)
        if identityChanged {
            textView.cancelRectangularSelection()
            coordinator.ruler?.resetFoldMarkerAccessibilityCache()
        }

        let awaitingAcceptedNativeChange = coordinator.isAwaitingNativeText(text)
        var replacedText = false
        if textView.string != text, !awaitingAcceptedNativeChange {
            coordinator.replaceText(with: text, in: textView)
            replacedText = true
        }

        configureFont(on: textView)
        configureTheme(on: textView, in: scrollView)
        configureParagraphStyle(on: textView)
        configureWrapping(on: textView, in: scrollView)
        configureSpellChecking(on: textView)
        configureVisualDecorations(on: textView)
        if let layoutManager = textView.layoutManager as? NativeTextEditorLayoutManager {
            configureSyntaxHighlighting(on: layoutManager)
            configureDiagnostics(
                on: layoutManager, textView: textView, ruler: coordinator.ruler
            )
            configureFindHighlights(on: layoutManager, textView: textView)
        }
        let hiddenSelectionOffset = foldSnapshot?.hiddenRanges.lazy.compactMap { range in
            selections.ranges.lazy.map(\.head).first { offset in
                offset >= range.location && offset < NSMaxRange(range)
            }
        }.first
        if let hiddenSelectionOffset {
            (textView.layoutManager as? NativeTextEditorLayoutManager)?
                .configureFolding(nil, documentID: documentID, viewID: viewID,
                                  documentRevision: documentRevision)
            let reveal = onRevealFoldedContent
            Task { @MainActor in
                _ = reveal?(hiddenSelectionOffset)
            }
        } else if let layoutManager = textView.layoutManager as? NativeTextEditorLayoutManager {
            configureFolding(on: layoutManager)
        }

        if !awaitingAcceptedNativeChange {
            coordinator.applySelections(
                selections.clamped(toUTF16Length: (textView.string as NSString).length),
                to: textView,
                force: identityChanged || replacedText
            )
        }

        let showsRuler = showsGutter
        if scrollView.hasVerticalRuler != showsRuler {
            scrollView.hasVerticalRuler = showsRuler
        }
        if scrollView.rulersVisible != showsRuler {
            scrollView.rulersVisible = showsRuler
        }
        if showsRuler, !coordinator.wasShowingRuler {
            coordinator.ruler?.rebuildLineStarts()
        }
        coordinator.wasShowingRuler = showsRuler
        coordinator.ruler?.update(
            markers: incrementalDiffMarkers, showsLineNumbers: showLineNumbers
        )
        if let ruler = coordinator.ruler {
            configureFoldMarkers(on: ruler, textView: textView)
        }
        if coordinator.ruler?.palette != palette {
            coordinator.ruler?.palette = palette
        }
        coordinator.ruler?.refreshAppearance()
        configureAccessibilityDisplayObserver(
            on: container, textView: textView, scrollView: scrollView,
            ruler: coordinator.ruler
        )
        coordinator.restoreScroll(
            scrollPosition,
            in: scrollView,
            force: identityChanged || replacedText
        )
        coordinator.applyFocus(to: textView)
        container.configureMinimap(
            shown: showMinimap, text: text, documentID: documentID,
            revision: documentRevision, palette: palette, locale: locale
        )
    }

    static func dismantleNSView(
        _ container: NativeEditorContainerView, coordinator: Coordinator
    ) {
        (container.scrollView.documentView as? NSTextView)?.delegate = nil
        coordinator.detach()
    }

    private func configureFont(on textView: NSTextView) {
        let safeSize = fontSize.isFinite ? max(1, fontSize) : 14
        let desiredFont = NSFont.monospacedSystemFont(ofSize: safeSize, weight: .regular)
        if textView.font?.fontName != desiredFont.fontName
            || textView.font?.pointSize != desiredFont.pointSize {
            textView.font = desiredFont
            var attributes = textView.typingAttributes
            attributes[.font] = desiredFont
            attributes[.foregroundColor] = palette.foreground
            textView.typingAttributes = attributes
            textView.needsDisplay = true
        }
    }

    private func configureTheme(on textView: NSTextView, in scrollView: NSScrollView) {
        Self.applyPalette(palette, to: textView, in: scrollView)
    }

    private static func applyPalette(
        _ palette: NativeEditorPalette,
        to textView: NSTextView,
        in scrollView: NSScrollView
    ) {
        scrollView.appearance = NSAppearance(named: palette.appearanceName)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.background
        textView.drawsBackground = false
        textView.backgroundColor = palette.background
        textView.textColor = palette.foreground
        textView.insertionPointColor = palette.insertionPoint
        textView.selectedTextAttributes = [
            .backgroundColor: palette.selectionBackground,
            .foregroundColor: palette.foreground
        ]
        if let nativeTextView = textView as? NativeTextView {
            nativeTextView.decorationBackgroundColor = palette.background
            nativeTextView.rulerColor = palette.ruler
        }
        if let layoutManager = textView.layoutManager as? NativeTextEditorLayoutManager,
           layoutManager.palette != palette {
            layoutManager.palette = palette
        }

        var attributes = textView.typingAttributes
        attributes[.foregroundColor] = palette.foreground
        textView.typingAttributes = attributes
        textView.needsDisplay = true
        scrollView.needsDisplay = true
    }

    private func configureAccessibilityDisplayObserver(
        on container: NativeEditorContainerView,
        textView: NSTextView,
        scrollView: NSScrollView,
        ruler: LineNumberRulerView?
    ) {
        let colorScheme = colorScheme
        let theme = theme
        container.observeAccessibilityDisplayChanges {
            [weak container, weak textView, weak scrollView, weak ruler] in
            guard let container, let textView, let scrollView else { return }
            let refreshed = NativeEditorPalette.make(
                colorScheme: colorScheme, compatibleWith: theme
            )
            Self.applyPalette(refreshed, to: textView, in: scrollView)
            ruler?.palette = refreshed
            ruler?.refreshAppearance()
            container.refreshMinimapPalette(refreshed)
        }
    }

    private func configureAccessibilityMetadata(on textView: NSTextView) {
        let metadata = NativeTextEditorAccessibility.metadata(
            documentDisplayName: documentDisplayName,
            paneIndex: paneIndex,
            viewID: viewID,
            locale: locale
        )
        NativeTextEditorAccessibility.apply(metadata, to: textView)
        // NSTextView continues to expose its native text value and selection.
        // Diagnostics are intentionally the only content placed in help.
    }

    private var palette: NativeEditorPalette {
        NativeEditorPalette.make(colorScheme: colorScheme, compatibleWith: theme)
    }

    private var showsGutter: Bool {
        showLineNumbers || !incrementalDiffMarkers.isEmpty
            || diagnosticSnapshot?.entries.isEmpty == false
            || acceptedFoldSnapshot?.markers.isEmpty == false
    }

    private func configureParagraphStyle(on textView: NSTextView) {
        let font = textView.font ?? NSFont.monospacedSystemFont(
            ofSize: max(1, fontSize), weight: .regular
        )
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = max(1, spaceWidth * CGFloat(tabWidth))
        paragraph.tabStops = []
        if textView.defaultParagraphStyle != paragraph {
            textView.defaultParagraphStyle = paragraph
            var attributes = textView.typingAttributes
            attributes[.paragraphStyle] = paragraph
            textView.typingAttributes = attributes
        }
    }

    private func configureWrapping(on textView: NSTextView, in scrollView: NSScrollView) {
        guard let textContainer = textView.textContainer else { return }

        scrollView.hasHorizontalScroller = !softWrap
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )

        if softWrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(
                width: max(0, scrollView.contentSize.width),
                height: .greatestFiniteMagnitude
            )
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.minSize = scrollView.contentSize
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: .greatestFiniteMagnitude,
                height: .greatestFiniteMagnitude
            )
        }
    }

    private func configureSpellChecking(on textView: NSTextView) {
        if textView.isContinuousSpellCheckingEnabled != spellChecking {
            textView.isContinuousSpellCheckingEnabled = spellChecking
        }
        textView.isAutomaticSpellingCorrectionEnabled = false
    }

    private func configureVisualDecorations(on textView: NSTextView) {
        guard let layoutManager = textView.layoutManager as? NativeTextEditorLayoutManager
        else { return }
        let font = textView.font
            ?? NSFont.monospacedSystemFont(ofSize: max(1, fontSize), weight: .regular)
        let characterWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        layoutManager.configure(
            showWhitespace: showWhitespace,
            showIndentGuides: showIndentGuides,
            highlightTrailingWhitespace: highlightTrailingWhitespace,
            tabWidth: tabWidth,
            characterWidth: characterWidth
        )
        if let textView = textView as? NativeTextView {
            textView.rulerColumns = rulers
            textView.needsDisplay = true
        }
    }

    private func configureFolding(on layoutManager: NativeTextEditorLayoutManager) {
        layoutManager.configureFolding(
            acceptedFoldSnapshot, documentID: documentID, viewID: viewID,
            documentRevision: documentRevision
        )
    }

    private var acceptedFoldSnapshot: TextKitFoldSnapshot? {
        foldSnapshot.flatMap { snapshot in
            snapshot.documentID == documentID
                && snapshot.viewID == viewID
                && snapshot.documentRevision == documentRevision
                ? snapshot : nil
        }
    }

    private func configureFoldMarkers(
        on ruler: LineNumberRulerView, textView: NSTextView
    ) {
        let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
            text: textView.string, markers: acceptedFoldSnapshot?.markers.map { marker in
                NativeTextEditorVisualPlanner.FoldMarker(
                    id: marker.id, startLine: marker.startLine,
                    endLine: marker.endLine, fullRange: marker.fullRange,
                    hiddenRange: marker.hiddenRange, isFolded: marker.isFolded
                )
            } ?? []
        )
        ruler.updateFoldMarkers(
            plan, locale: locale, onToggle: onToggleFoldMarker
        )
    }

    private func configureFindHighlights(
        on layoutManager: NativeTextEditorLayoutManager, textView: NSTextView
    ) {
        let accepted = findHighlightSnapshot.flatMap { snapshot in
            snapshot.identity.documentID == documentID
                && snapshot.identity.viewID == viewID
                && snapshot.identity.paneIndex == paneIndex
                && snapshot.documentRevision == documentRevision
                ? snapshot : nil
        }
        let plan = NativeTextEditorVisualPlanner.findHighlightPlan(
            text: textView.string, matches: accepted?.matches.map(\.range) ?? [],
            selectedMatchIndex: accepted?.selectedMatchIndex
        )
        layoutManager.configureFindHighlights(
            plan, documentID: documentID, viewID: viewID, paneIndex: paneIndex,
            documentRevision: documentRevision
        )
    }

    private func configureSyntaxHighlighting(
        on layoutManager: NativeTextEditorLayoutManager
    ) {
        layoutManager.configureSyntaxHighlighting(
            language: language, documentID: documentID, revision: documentRevision,
            parsedSnapshot: parsedHighlighting
        )
    }

    private func configureDiagnostics(
        on layoutManager: NativeTextEditorLayoutManager,
        textView: NSTextView,
        ruler: LineNumberRulerView?
    ) {
        let accepted = diagnosticSnapshot.flatMap { snapshot in
            snapshot.documentID == documentID
                && snapshot.documentRevision == documentRevision
                && fileURL.map(Self.canonicalFilePath) == snapshot.filePath
                ? snapshot : nil
        }
        let diagnostics = accepted?.entries.map { entry in
            NativeTextEditorVisualPlanner.Diagnostic(
                line: entry.diagnostic.line, column: entry.diagnostic.column,
                endLine: entry.diagnostic.endLine, endColumn: entry.diagnostic.endColumn,
                severity: Self.diagnosticSeverity(entry.diagnostic.severity)
            )
        } ?? []
        let plan = layoutManager.configureDiagnostics(
            text: textView.string, diagnostics: diagnostics,
            documentID: documentID, documentRevision: documentRevision,
            serverKey: accepted?.serverKey, filePath: accepted?.filePath,
            generation: accepted?.generation,
            presentationRevision: accepted?.presentationRevision
        )
        ruler?.updateDiagnosticMarkers(plan.markedLines)
        let summary = NativeTextEditorAccessibility.help(
            diagnostics: accepted?.entries.map(\.diagnostic) ?? [],
            locale: locale
        )
        textView.setAccessibilityHelp(summary)
    }

    private static func diagnosticSeverity(
        _ severity: LanguageServerDiagnosticSeverity
    ) -> NativeTextEditorVisualPlanner.DiagnosticSeverity {
        switch severity {
        case .error: .error
        case .warning: .warning
        case .info: .information
        }
    }

    private static func canonicalFilePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    fileprivate static func clamped(_ range: NSRange, toUTF16Length length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: min(length, max(0, length)), length: 0)
        }
        let location = min(length, max(0, range.location))
        let rangeLength = min(max(0, range.length), length - location)
        return NSRange(location: location, length: rangeLength)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var parent: NativeTextEditor
        fileprivate weak var textView: NSTextView?
        fileprivate weak var scrollView: NSScrollView?
        fileprivate weak var ruler: LineNumberRulerView?

        private var isApplyingExternalText = false
        private var isApplyingExternalSelection = false
        private var isApplyingExternalScroll = false
        private var focusRequestGeneration = 0
        private var identityGeneration = 0
        private var identity: Identity
        private var committedText: String
        private var committedRevision: UInt64
        private var nativeSelections: SelectionSet
        private var inputProvenance: NativeTextInputProvenance = .empty
        /// May temporarily lead SwiftUI by one revision after a proven
        /// single-character transition. It is never used without the
        /// planner's exact text/language/settings/revision validation.
        private var localParsedIndentation: CodeMirrorIndentationSnapshot?
        private var pendingNativeChange: PendingNativeChange?
        private let boundsObserverToken = NativeTextEditorNotificationObserverBox()
        private let scrollPublishTask = NativeTextEditorDeferredTaskBox()
        private let scrollRestoreTask = NativeTextEditorDeferredTaskBox()
        private let focusTask = NativeTextEditorDeferredTaskBox()
        private let completionRequestTask = NativeTextEditorDeferredTaskBox()
        private let completionPresenter = CompletionPopoverPresenter()
        private var lastModelScroll: NativeTextEditorScrollPosition
        private var lastObservedScroll: NativeTextEditorScrollPosition?
        private var lastPublishedScroll: NativeTextEditorScrollPosition?
        fileprivate var wasShowingRuler: Bool

        fileprivate init(parent: NativeTextEditor) {
            self.parent = parent
            identity = Identity(documentID: parent.documentID, viewID: parent.viewID)
            committedText = parent.text
            committedRevision = parent.documentRevision
            localParsedIndentation = parent.parsedIndentation
            nativeSelections = parent.selections.clamped(
                toUTF16Length: parent.text.utf16.count
            )
            lastModelScroll = parent.scrollPosition
            wasShowingRuler = parent.showsGutter
        }

        fileprivate func attach(
            textView: NativeTextView,
            scrollView: NSScrollView,
            ruler: LineNumberRulerView
        ) {
            self.textView = textView
            self.scrollView = scrollView
            self.ruler = ruler
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.clipViewBoundsDidChange()
                }
            }
            boundsObserverToken.replace(with: observer)
            lastObservedScroll = NativeTextEditorAdapter.scrollPosition(
                from: clipView.bounds.origin
            )
            parent.completionController.setPresentationObserver {
                [weak self, weak textView] presentation in
                guard let self, let textView else { return }
                self.updateCompletionPresentation(presentation, in: textView)
            }
        }

        fileprivate func detach() {
            parent.completionController.setPresentationObserver(nil)
            invalidateDeferredWork()
            dismissCompletion()
            boundsObserverToken.clear()
            ruler?.stopObserving()
            ruler?.resetFoldMarkerAccessibilityCache()
            textView = nil
            scrollView = nil
        }

        fileprivate func adopt(parent newParent: NativeTextEditor) -> Bool {
            let newIdentity = Identity(
                documentID: newParent.documentID,
                viewID: newParent.viewID
            )
            let changed = newIdentity != identity
            if changed {
                invalidateDeferredWork()
                dismissCompletion()
                identity = newIdentity
                committedText = newParent.text
                committedRevision = newParent.documentRevision
                nativeSelections = newParent.selections.clamped(
                    toUTF16Length: newParent.text.utf16.count
                )
                inputProvenance = .empty
                localParsedIndentation = newParent.parsedIndentation
                pendingNativeChange = nil
                lastModelScroll = newParent.scrollPosition
                lastObservedScroll = nil
                lastPublishedScroll = nil
            }
            if !changed, newParent.text == committedText {
                if pendingNativeChange == nil,
                   newParent.documentRevision != committedRevision {
                    // A revision that did not originate from this coordinator
                    // may be undo, redo, reload, or another pane. The model
                    // does not expose that transaction here, so retaining a
                    // marker would be an unsafe provenance guess.
                    inputProvenance = .empty
                    localParsedIndentation = nil
                }
                committedRevision = newParent.documentRevision
            }
            if newParent.completionController !== parent.completionController {
                parent.completionController.setPresentationObserver(nil)
                newParent.completionController.setPresentationObserver {
                    [weak self, weak textView] presentation in
                    guard let self, let textView else { return }
                    self.updateCompletionPresentation(presentation, in: textView)
                }
            }
            parent = newParent
            if let incoming = newParent.parsedIndentation, incoming.matches(
                text: committedText, language: newParent.language,
                revision: committedRevision, tabWidth: newParent.tabWidth,
                indentWidth: newParent.indentWidth,
                insertSpaces: newParent.insertSpaces
            ) {
                localParsedIndentation = incoming
            }
            return changed
        }

        fileprivate func isAwaitingNativeText(_ text: String) -> Bool {
            pendingNativeChange?.expectedText == text
        }

        fileprivate func replaceText(with newText: String, in textView: NSTextView) {
            dismissCompletion()
            isApplyingExternalText = true
            defer { isApplyingExternalText = false }

            if textView.hasMarkedText() { textView.unmarkText() }
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: 0, length: textView.textStorage?.length ?? 0),
                with: newText
            )
            committedText = newText
            committedRevision = parent.documentRevision
            inputProvenance = .empty
            localParsedIndentation = parent.parsedIndentation
            pendingNativeChange = nil
            if parent.showsGutter {
                ruler?.rebuildLineStarts()
            }
            textView.needsDisplay = true
        }

        fileprivate func applySelections(
            _ selections: SelectionSet,
            to textView: NSTextView,
            force: Bool = false
        ) {
            guard force || selections != nativeSelections else { return }
            isApplyingExternalSelection = true
            defer { isApplyingExternalSelection = false }
            let ranges = NativeTextEditorAdapter.appKitRanges(from: selections)
            let affinity: NSSelectionAffinity = selections.main.isBackward
                ? .upstream : .downstream
            textView.setSelectedRanges(
                ranges.map { NSValue(range: $0) },
                affinity: affinity,
                stillSelecting: false
            )
            nativeSelections = selections
            configureSelectionVisuals(selections, in: textView)
            ruler?.selectionDidChange()
        }

        fileprivate func restoreScroll(
            _ position: NativeTextEditorScrollPosition,
            in scrollView: NSScrollView,
            force: Bool
        ) {
            let modelPositionChanged = position != lastModelScroll
            lastModelScroll = position
            if !force, scrollPublishTask.isPending { return }
            let current = NativeTextEditorAdapter.scrollPosition(
                from: scrollView.contentView.bounds.origin
            )
            if current == position {
                lastObservedScroll = current
                if force { lastPublishedScroll = current }
                return
            }
            if !force, !modelPositionChanged, lastPublishedScroll == current {
                // The model publication caused this update and may not yet have
                // propagated into this representable value. Do not snap back.
                return
            }

            let taskGeneration = scrollRestoreTask.beginReplacement()
            let generation = identityGeneration
            let expectedIdentity = identity
            let task = Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView,
                      generation == self.identityGeneration,
                      expectedIdentity == self.identity else { return }
                self.scrollRestoreTask.clearIfCurrent(taskGeneration)
                self.isApplyingExternalScroll = true
                let clipView = scrollView.contentView
                clipView.scroll(to: NSPoint(
                    x: CGFloat(position.x),
                    y: CGFloat(position.y)
                ))
                scrollView.reflectScrolledClipView(clipView)
                let applied = NativeTextEditorAdapter.scrollPosition(
                    from: clipView.bounds.origin
                )
                self.lastObservedScroll = applied
                self.lastPublishedScroll = applied
                self.isApplyingExternalScroll = false
            }
            scrollRestoreTask.install(task, for: taskGeneration)
        }

        fileprivate func applyFocus(to textView: NSTextView) {
            focusRequestGeneration &+= 1
            let generation = focusRequestGeneration
            let expectedIdentityGeneration = identityGeneration
            let wantsFocus = parent.isFocused

            if wantsFocus {
                guard textView.window?.firstResponder !== textView else { return }
                let taskGeneration = focusTask.beginReplacement()
                let task = Task { @MainActor [weak self, weak textView] in
                    guard let self,
                          let textView,
                          generation == self.focusRequestGeneration,
                          expectedIdentityGeneration == self.identityGeneration,
                          self.parent.isFocused,
                          let window = textView.window,
                          window.firstResponder !== textView else { return }
                    window.makeFirstResponder(textView)
                    self.focusTask.clearIfCurrent(taskGeneration)
                }
                focusTask.install(task, for: taskGeneration)
            } else if textView.window?.firstResponder === textView {
                focusTask.cancel()
                textView.window?.makeFirstResponder(nil)
            }
        }

        fileprivate func applyRectangularSelection(
            _ selection: SelectionSet,
            appending: Bool,
            initialSelection: SelectionSet,
            in textView: NativeTextView
        ) {
            dismissCompletion()
            let planned = appending
                ? RectangularSelectionPlanner.merging(
                    selection, into: initialSelection,
                    maximumSelections: RectangularSelectionPlanner.maximumLines
                )
                : selection
            let clamped = planned.clamped(
                toUTF16Length: (textView.string as NSString).length
            )
            let previous = nativeSelections
            applySelections(clamped, to: textView, force: true)
            nativeSelections = clamped
            if parent.onSelectionChange(clamped) {
                parent.onManualSelectionChange(previous, clamped)
            }
        }

        fileprivate func applyOptionClickSelection(
            _ selection: SelectionSet,
            in textView: NativeTextView
        ) {
            dismissCompletion()
            let clamped = selection.clamped(
                toUTF16Length: (textView.string as NSString).length
            )
            let previous = nativeSelections
            applySelections(clamped, to: textView, force: true)
            nativeSelections = clamped
            if parent.onSelectionChange(clamped) {
                parent.onManualSelectionChange(previous, clamped)
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString else { return true }
            return shouldAllowTextChange(
                in: textView,
                affectedRanges: [affectedCharRange],
                replacementStrings: [replacementString]
            )
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if parent.completionController.isPresented {
                    dismissCompletion()
                    return true
                }
                return parent.onCancelSnippetSession?() == true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               !textView.hasMarkedText(),
               let plan = NativeTextInputPlanner.pairedBackspacePlan(
                   text: committedText, selections: currentSelection(in: textView),
                   revision: committedRevision, provenance: inputProvenance
               ) {
                return applyPlannedTransaction(plan, in: textView)
            }
            let direction: SnippetNavigationDirection
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                direction = .next
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                direction = .previous
            } else {
                return false
            }
            guard !textView.hasMarkedText() else { return false }
            if parent.onSnippetNavigation?(direction) == true { return true }
            let selection = currentSelection(in: textView)
            let transaction: TextTransaction?
            if direction == .previous || selection.ranges.contains(where: { !$0.isEmpty }) {
                let snapshot = EditingCommandSnapshot(
                    text: committedText, selection: selection,
                    language: parent.language, tabWidth: parent.tabWidth,
                    indentWidth: parent.indentWidth, insertSpaces: parent.insertSpaces,
                    expectedRevision: committedRevision
                )
                transaction = try? EditingCommands.transaction(
                    for: direction == .previous ? "outdent-selection" : "indent-selection",
                    snapshot: snapshot
                )
            } else {
                transaction = NativeTextInputPlanner.insertion(
                    text: committedText, selections: selection, replacement: "\t",
                    tabWidth: parent.tabWidth, indentWidth: parent.indentWidth,
                    insertSpaces: parent.insertSpaces,
                    language: parent.language, revision: committedRevision
                )
            }
            guard let transaction else { return false }
            return applyPlannedTransaction(transaction, in: textView)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard let replacementStrings else { return true }
            return shouldAllowTextChange(
                in: textView,
                affectedRanges: affectedRanges.map { $0.rangeValue },
                replacementStrings: replacementStrings
            )
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else { return }

            let actualText = textView.string
            let pending = pendingNativeChange
            pendingNativeChange = nil
            let preferredSelections = pending?.selections ?? nativeSelections
            let actualSelections = selection(from: textView, preserving: preferredSelections)

            if let pending, actualText == pending.expectedText {
                committedText = actualText
                nativeSelections = pending.selections
                inputProvenance = pending.provenance
                if actualSelections != pending.selections {
                    nativeSelections = actualSelections
                    _ = parent.onSelectionChange(actualSelections)
                }
            } else if actualText != committedText {
                reconcileUnexpectedNativeText(
                    actualText,
                    selections: actualSelections,
                    in: textView
                )
            } else {
                publishSelection(actualSelections, recordInHistory: false)
            }
            configureSelectionVisuals(nativeSelections, in: textView)
            if parent.showsGutter {
                ruler?.rebuildLineStarts()
            }
            textView.needsDisplay = true
            if committedText == actualText {
                scheduleCompletionRequest(in: textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalText, !isApplyingExternalSelection,
                  pendingNativeChange == nil,
                  let textView = notification.object as? NSTextView else { return }
            publishSelection(selection(from: textView, preserving: nativeSelections))
            configureSelectionVisuals(nativeSelections, in: textView)
            ruler?.selectionDidChange()
            parent.completionController.editorContextDidChange()
        }

        func textDidBeginEditing(_ notification: Notification) {
            focusRequestGeneration &+= 1
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            focusRequestGeneration &+= 1
            dismissCompletion()
            if parent.isFocused { parent.isFocused = false }
        }

        fileprivate func handleCompletionEvent(
            _ event: NSEvent, in textView: NSTextView
        ) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let controller = parent.completionController
            if controller.isPresented {
                switch event.keyCode {
                case 125:
                    controller.moveSelection(by: 1)
                    return true
                case 126:
                    controller.moveSelection(by: -1)
                    return true
                case 48:
                    let direction: SnippetNavigationDirection = event.modifierFlags
                        .contains(.shift) ? .previous : .next
                    if parent.onSnippetNavigation?(direction) == true {
                        dismissCompletion()
                        return true
                    }
                    _ = acceptCompletion(using: controller, in: textView)
                    completionPresenter.dismiss()
                    return true
                case 36:
                    _ = acceptCompletion(using: controller, in: textView)
                    completionPresenter.dismiss()
                    return true
                case 53:
                    dismissCompletion()
                    return true
                default:
                    break
                }
            }
            return false
        }

        private func requestCompletionIfEligible(in textView: NSTextView) {
            let selection = currentSelection(in: textView)
            guard !textView.hasMarkedText(), selection.ranges.count == 1,
                  selection.main.isEmpty else {
                dismissCompletion()
                return
            }
            completionPresenter.dismiss()
            parent.completionController.request()
        }

        private func scheduleCompletionRequest(in textView: NSTextView) {
            let generation = identityGeneration
            let expectedIdentity = identity
            let taskGeneration = completionRequestTask.beginReplacement()
            let task = Task { @MainActor [weak self, weak textView] in
                guard let self, let textView, generation == self.identityGeneration,
                      expectedIdentity == self.identity,
                      textView.window?.firstResponder === textView else { return }
                self.requestCompletionIfEligible(in: textView)
                self.completionRequestTask.clearIfCurrent(taskGeneration)
            }
            completionRequestTask.install(task, for: taskGeneration)
        }

        private func updateCompletionPresentation(
            _ presentation: CompletionPresentation?, in textView: NSTextView
        ) {
            let selected = currentSelection(in: textView)
            guard !textView.hasMarkedText(), selected.ranges.count == 1,
                  selected.main.isEmpty, let presentation else {
                completionPresenter.dismiss()
                return
            }
            let controller = parent.completionController
            completionPresenter.show(
                presentation, in: textView, locale: parent.locale,
                onSelect: { [weak controller] index in controller?.select(at: index) }
            ) { [weak self] in
                guard let self else { return }
                _ = self.acceptCompletion(
                    using: self.parent.completionController, in: textView
                )
                self.completionPresenter.dismiss()
            }
        }

        private func acceptCompletion(
            using controller: CompletionController, in textView: NSTextView
        ) -> Bool {
            guard let (suggestion, query) = controller.consumeSelectionForNativeEditor(),
                  let transaction = CompletionPlanner.insertionTransaction(
                    suggestion: suggestion, query: query
                  ),
                  transaction.expectedRevision == committedRevision
            else {
                controller.dismiss()
                return false
            }
            return applyPlannedTransaction(
                transaction, in: textView, requestsCompletion: false
            )
        }

        fileprivate func dismissCompletion() {
            parent.completionController.cancelRequest()
            completionPresenter.dismiss()
        }

        private func shouldAllowTextChange(
            in textView: NSTextView,
            affectedRanges: [NSRange],
            replacementStrings: [String]
        ) -> Bool {
            guard parent.isEditable else { return false }
            let structuralReplacement = replacementStrings.first.flatMap { candidate in
                replacementStrings.allSatisfy { $0 == candidate } ? candidate : nil
            }
            let priorSelection = currentSelection(in: textView)
            let canMapParsedIndentation = !textView.hasMarkedText()
                && (textView as? NativeTextView)?.isUpdatingMarkedText != true
            if !textView.hasMarkedText(),
               (textView as? NativeTextView)?.isUpdatingMarkedText != true,
               rangesMatchCurrentSelection(affectedRanges, in: textView),
               let structuralReplacement,
               let plan = NativeTextInputPlanner.insertionPlan(
                   text: committedText, selections: currentSelection(in: textView),
                   replacement: structuralReplacement,
                   tabWidth: parent.tabWidth, indentWidth: parent.indentWidth,
                   insertSpaces: parent.insertSpaces, language: parent.language,
                   revision: committedRevision,
                   parsedIndentation: localParsedIndentation,
                   provenance: inputProvenance
               ) {
                return !applyPlannedTransaction(plan, in: textView)
            }
            guard !isApplyingExternalText,
                  affectedRanges.count == replacementStrings.count,
                  !affectedRanges.isEmpty,
                  let edits = NativeTextEditorAdapter.textEdits(
                    in: textView.string,
                    affectedRanges: affectedRanges,
                    replacementStrings: replacementStrings
                  ),
                  let transaction = try? TextTransaction(
                    edits: edits,
                    selection: NativeTextEditorAdapter.selectionsAfterReplacing(
                        selection(from: textView, preserving: nativeSelections),
                        affectedRanges: affectedRanges,
                        replacementStrings: replacementStrings,
                        originalUTF16Length: (textView.string as NSString).length
                    ),
                    expectedRevision: committedRevision
                  ),
                  let expectedText = try? transaction.applying(to: textView.string)
            else { return false }

            guard let selectionsAfter = transaction.selection else { return false }
            let nextProvenance = inputProvenance.mapped(
                through: transaction, from: textView.string, to: expectedText
            )
            if expectedText == textView.string {
                // Replacing an automatic closer with the same visible
                // character is textually a no-op, but it is still a manual
                // overwrite and must invalidate that provenance.
                inputProvenance = nextProvenance
                return true
            }
            let priorCommittedText = committedText
            let generation = identityGeneration
            let expectedIdentity = identity
            pendingNativeChange = PendingNativeChange(
                expectedText: expectedText,
                selections: selectionsAfter,
                provenance: nextProvenance
            )
            committedText = expectedText

            let accepted = parent.onTextChange(transaction)
            // The model has already accepted the command. If that synchronous
            // callback replaced this coordinator's identity, report it as
            // handled without applying the old document to the new view.
            guard generation == identityGeneration, expectedIdentity == identity
            else { return accepted }
            if !accepted {
                pendingNativeChange = nil
                committedText = priorCommittedText
            } else {
                inputProvenance = nextProvenance
                precondition(
                    committedRevision < UInt64.max,
                    "Document revision exhausted"
                )
                committedRevision += 1
                localParsedIndentation = NativeTextEditorAdapter
                    .mappedIndentationAfterAcceptedEdit(
                        localParsedIndentation, transaction: transaction,
                        oldText: priorCommittedText, newText: expectedText,
                        nextRevision: committedRevision,
                        selectionBefore: priorSelection,
                        selectionAfter: selectionsAfter,
                        allowsSingleCharacterTransition: canMapParsedIndentation
                    )
                hideDiagnosticsAfterAcceptedEdit(in: textView)
            }
            return accepted
        }

        private func currentSelection(in textView: NSTextView) -> SelectionSet {
            selection(from: textView, preserving: nativeSelections)
        }

        private func rangesMatchCurrentSelection(
            _ ranges: [NSRange], in textView: NSTextView
        ) -> Bool {
            let expected = currentSelection(in: textView).ranges.map(\.range).sorted {
                $0.location < $1.location
            }
            let actual = ranges.sorted { $0.location < $1.location }
            return expected.count == actual.count
                && zip(expected, actual).allSatisfy { pair in
                    NSEqualRanges(pair.0, pair.1)
                }
        }

        private func applyPlannedTransaction(
            _ plan: NativeTextInputPlan, in textView: NSTextView,
            requestsCompletion: Bool = true
        ) -> Bool {
            applyPlannedTransaction(
                plan.transaction, in: textView, requestsCompletion: requestsCompletion,
                resultingProvenance: plan.provenance
            )
        }

        private func applyPlannedTransaction(
            _ transaction: TextTransaction, in textView: NSTextView,
            requestsCompletion: Bool = true,
            resultingProvenance: NativeTextInputProvenance? = nil
        ) -> Bool {
            guard parent.isEditable,
                  transaction.expectedRevision == committedRevision,
                  let nextText = try? transaction.applying(to: committedText),
                  let nextSelection = transaction.selection else { return false }
            let nextProvenance = resultingProvenance ?? inputProvenance.mapped(
                through: transaction, from: committedText, to: nextText
            )
            let generation = identityGeneration
            let expectedIdentity = identity
            guard parent.onTextChange(transaction) else { return false }
            // The model has already accepted the input. If that synchronous
            // callback replaced this coordinator's identity, consume the
            // AppKit event without applying the old document to the new view.
            guard generation == identityGeneration, expectedIdentity == identity
            else { return true }
            let priorRevision = committedRevision
            let priorText = committedText
            let priorSelection = nativeSelections
            let canMapParsedIndentation = !textView.hasMarkedText()
                && (textView as? NativeTextView)?.isUpdatingMarkedText != true
            isApplyingExternalText = true
            if textView.hasMarkedText() { textView.unmarkText() }
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: 0, length: textView.textStorage?.length ?? 0),
                with: nextText
            )
            isApplyingExternalText = false
            committedText = nextText
            if transaction.edits.isEmpty {
                committedRevision = priorRevision
            } else {
                precondition(priorRevision < UInt64.max, "Document revision exhausted")
                committedRevision = priorRevision + 1
            }
            if transaction.edits.isEmpty {
                // A selection-only transaction does not invalidate syntax.
            } else {
                localParsedIndentation = NativeTextEditorAdapter
                    .mappedIndentationAfterAcceptedEdit(
                        localParsedIndentation, transaction: transaction,
                        oldText: priorText, newText: nextText,
                        nextRevision: committedRevision,
                        selectionBefore: priorSelection,
                        selectionAfter: nextSelection,
                        allowsSingleCharacterTransition: canMapParsedIndentation
                    )
            }
            inputProvenance = nextProvenance
            if !transaction.edits.isEmpty {
                hideDiagnosticsAfterAcceptedEdit(in: textView)
            }
            pendingNativeChange = nil
            nativeSelections = nextSelection
            applySelections(nextSelection, to: textView, force: true)
            if parent.showsGutter {
                ruler?.rebuildLineStarts()
            }
            textView.needsDisplay = true
            if requestsCompletion { scheduleCompletionRequest(in: textView) }
            return true
        }

        private func reconcileUnexpectedNativeText(
            _ actualText: String,
            selections: SelectionSet,
            in textView: NSTextView
        ) {
            let previousText = committedText
            let previousRevision = committedRevision
            let previousSelections = nativeSelections
            let previousProvenance = inputProvenance
            let previousParsedIndentation = localParsedIndentation
            guard let edit = NativeTextEditorAdapter.reconcileEdit(
                from: previousText,
                to: actualText
            ) else {
                committedText = actualText
                inputProvenance = .empty
                localParsedIndentation = nil
                publishSelection(selections, recordInHistory: false)
                return
            }

            let generation = identityGeneration
            committedText = actualText
            nativeSelections = selections
            guard let transaction = try? TextTransaction(
                edits: [edit],
                selection: selections,
                expectedRevision: committedRevision
            ) else {
                replaceText(with: previousText, in: textView)
                committedRevision = previousRevision
                localParsedIndentation = previousParsedIndentation
                applySelections(previousSelections, to: textView, force: true)
                inputProvenance = previousProvenance
                return
            }
            let nextProvenance = previousProvenance.mapped(
                through: transaction, from: previousText, to: actualText
            )
            let accepted = parent.onTextChange(transaction)
            guard generation == identityGeneration else { return }
            if !accepted {
                committedText = previousText
                nativeSelections = previousSelections
                replaceText(with: previousText, in: textView)
                committedRevision = previousRevision
                localParsedIndentation = previousParsedIndentation
                applySelections(previousSelections, to: textView, force: true)
                inputProvenance = previousProvenance
            } else {
                inputProvenance = nextProvenance
                precondition(
                    committedRevision < UInt64.max,
                    "Document revision exhausted"
                )
                committedRevision += 1
                localParsedIndentation = nil
                hideDiagnosticsAfterAcceptedEdit(in: textView)
            }
        }

        private func hideDiagnosticsAfterAcceptedEdit(in textView: NSTextView) {
            if let layoutManager = textView.layoutManager as? NativeTextEditorLayoutManager {
                layoutManager.configureDiagnostics(
                    text: textView.string, diagnostics: [],
                    documentID: identity.documentID,
                    documentRevision: committedRevision, serverKey: nil,
                    filePath: nil, generation: nil, presentationRevision: nil
                )
                layoutManager.configureFindHighlights(
                    .init(highlights: []), documentID: identity.documentID,
                    viewID: identity.viewID, paneIndex: parent.paneIndex,
                    documentRevision: committedRevision
                )
            }
            ruler?.updateDiagnosticMarkers([:])
            textView.setAccessibilityHelp(NativeTextEditorAccessibility.help(
                diagnostics: [], locale: parent.locale
            ))
            textView.needsDisplay = true
        }

        private func selection(
            from textView: NSTextView,
            preserving previous: SelectionSet
        ) -> SelectionSet {
            NativeTextEditorAdapter.selectionSet(
                fromAppKitRanges: textView.selectedRanges.map { $0.rangeValue },
                mainRange: textView.selectedRange(),
                preserving: previous,
                directionAnchors: (textView as? NativeTextView)?.selectionDirectionAnchors,
                utf16Length: (textView.string as NSString).length
            )
        }

        private func publishSelection(
            _ selections: SelectionSet, recordInHistory: Bool = true
        ) {
            guard selections != nativeSelections else { return }
            let previous = nativeSelections
            nativeSelections = selections
            let accepted = parent.onSelectionChange(selections)
            if accepted, recordInHistory {
                parent.onManualSelectionChange(previous, selections)
            }
        }

        private func configureSelectionVisuals(
            _ selections: SelectionSet, in textView: NSTextView
        ) {
            (textView.layoutManager as? NativeTextEditorLayoutManager)?
                .configureSelectionVisuals(
                    NativeTextEditorVisualPlanner.VisualSelection(
                        anchor: selections.main.anchor, head: selections.main.head
                    )
                )
            textView.needsDisplay = true
        }

        private func clipViewBoundsDidChange() {
            guard !isApplyingExternalScroll, let scrollView else { return }
            let position = NativeTextEditorAdapter.scrollPosition(
                from: scrollView.contentView.bounds.origin
            )
            guard position != lastObservedScroll || scrollPublishTask.isPending else { return }
            lastObservedScroll = position
            let taskGeneration = scrollPublishTask.beginReplacement()

            let generation = identityGeneration
            let expectedIdentity = identity
            let task = Task { @MainActor [weak self, weak scrollView] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let scrollView,
                      !Task.isCancelled,
                      generation == self.identityGeneration,
                      expectedIdentity == self.identity else { return }
                self.scrollPublishTask.clearIfCurrent(taskGeneration)
                let latest = NativeTextEditorAdapter.scrollPosition(
                    from: scrollView.contentView.bounds.origin
                )
                self.lastObservedScroll = latest
                guard latest != self.lastPublishedScroll else { return }
                self.lastPublishedScroll = latest
                self.parent.onScrollChange(latest)
            }
            scrollPublishTask.install(task, for: taskGeneration)
        }

        private func invalidateDeferredWork() {
            focusRequestGeneration &+= 1
            identityGeneration &+= 1
            focusTask.cancel()
            completionRequestTask.cancel()
            scrollPublishTask.cancel()
            scrollRestoreTask.cancel()
        }

        private struct Identity: Equatable {
            let documentID: String
            let viewID: EditorViewID
        }

        private struct PendingNativeChange {
            let expectedText: String
            let selections: SelectionSet
            let provenance: NativeTextInputProvenance
        }
    }
}

/// Pure UTF-16 adapter operations kept separate from AppKit delegate timing.
/// They are internal so the app test target can validate edge cases directly.
enum NativeTextEditorAdapter {
    @MainActor
    static func applyEditability(_ isEditable: Bool, to textView: NSTextView) {
        textView.isEditable = isEditable
        textView.isSelectable = true
    }

    static let optionClickDragThreshold: CGFloat = 4

    static func mappedIndentationAfterAcceptedEdit(
        _ snapshot: CodeMirrorIndentationSnapshot?,
        transaction: TextTransaction, oldText: String, newText: String,
        nextRevision: UInt64, selectionBefore: SelectionSet,
        selectionAfter: SelectionSet, allowsSingleCharacterTransition: Bool
    ) -> CodeMirrorIndentationSnapshot? {
        guard allowsSingleCharacterTransition,
              selectionBefore.ranges.count == 1, selectionBefore.main.isEmpty,
              selectionAfter.ranges.count == 1, selectionAfter.main.isEmpty,
              transaction.edits.count == 1, let edit = transaction.edits.first,
              edit.from == edit.to, edit.from == selectionBefore.main.head,
              selectionAfter.main.head == edit.from + edit.insert.utf16.count
        else { return nil }
        return snapshot?.mappedThroughSingleCharacterInsertion(
            transaction, from: oldText, to: newText, revision: nextRevision
        )
    }

    static func reconcileEdit(from oldText: String, to newText: String) -> TextEdit? {
        guard oldText != newText else { return nil }
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        let sharedLimit = min(oldUnits.count, newUnits.count)
        var prefix = 0
        while prefix < sharedLimit, oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }
        while prefix > 0,
              splitsSurrogatePair(oldUnits, at: prefix)
                || splitsSurrogatePair(newUnits, at: prefix) {
            prefix -= 1
        }

        var suffix = 0
        while suffix < oldUnits.count - prefix,
              suffix < newUnits.count - prefix,
              oldUnits[oldUnits.count - suffix - 1]
                == newUnits[newUnits.count - suffix - 1] {
            suffix += 1
        }
        while suffix > 0,
              splitsSurrogatePair(oldUnits, at: oldUnits.count - suffix)
                || splitsSurrogatePair(newUnits, at: newUnits.count - suffix) {
            suffix -= 1
        }

        let replacementEnd = newUnits.count - suffix
        let replacement = String(
            decoding: newUnits[prefix..<replacementEnd],
            as: UTF16.self
        )
        return TextEdit(
            from: prefix,
            to: oldUnits.count - suffix,
            insert: replacement
        )
    }

    static func textEdits(
        in text: String,
        affectedRanges: [NSRange],
        replacementStrings: [String]
    ) -> [TextEdit]? {
        guard !affectedRanges.isEmpty,
              affectedRanges.count == replacementStrings.count else { return nil }
        let length = (text as NSString).length
        let replacements = zip(affectedRanges, replacementStrings).enumerated().map {
            Replacement(range: $0.element.0, string: $0.element.1, order: $0.offset)
        }
        guard replacements.allSatisfy({ isValid($0.range, forUTF16Length: length) }) else {
            return nil
        }
        let edits = replacements.map { replacement in
            TextEdit(
                from: replacement.range.location,
                to: NSMaxRange(replacement.range),
                insert: replacement.string
            )
        }
        guard let transaction = try? TextTransaction(edits: edits),
              (try? transaction.validate(forUTF16Length: length)) != nil else { return nil }
        return transaction.edits
    }

    static func applying(_ edit: TextEdit, to text: String) -> String? {
        let length = (text as NSString).length
        guard edit.from >= 0, edit.to >= edit.from, edit.to <= length else { return nil }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.insert)
        return result as String
    }

    static func appKitRanges(from selections: SelectionSet) -> [NSRange] {
        var ranges = [selections.main.range]
        ranges.reserveCapacity(selections.ranges.count)
        for index in selections.ranges.indices where index != selections.mainIndex {
            ranges.append(selections.ranges[index].range)
        }
        return ranges
    }

    static func directionAnchors(from selections: SelectionSet) -> [Int] {
        var anchors = [selections.main.anchor]
        anchors.reserveCapacity(selections.ranges.count)
        for index in selections.ranges.indices where index != selections.mainIndex {
            anchors.append(selections.ranges[index].anchor)
        }
        return anchors
    }

    static func selectionSet(
        fromAppKitRanges ranges: [NSRange],
        mainRange: NSRange? = nil,
        preserving previous: SelectionSet?,
        directionAnchors: [Int]? = nil,
        utf16Length: Int
    ) -> SelectionSet {
        let clampedRanges = ranges.isEmpty
            ? [NSRange(location: utf16Length, length: 0)]
            : ranges.map { NativeTextEditor.clamped($0, toUTF16Length: utf16Length) }
        // AppKit may normalize selectedRanges into document order, so ask its
        // singular API which range is active instead of relying on array order.
        let previousMain = previous?.main.range
        let sameRangesAsPrevious = previous.map { previous in
            let previousRanges = previous.ranges.map(\.range)
            return previousRanges.count == clampedRanges.count
                && Self.sameRangeMultiset(previousRanges, clampedRanges)
        } ?? false
        let activeRange = sameRangesAsPrevious ? previousMain : mainRange
        let clampedMain = activeRange.map {
            NativeTextEditor.clamped($0, toUTF16Length: utf16Length)
        }
        let mainIndex = clampedMain.flatMap { main in
            clampedRanges.firstIndex { NSEqualRanges($0, main) }
        } ?? 0

        var usedPreviousIndices = Set<Int>()
        let previousMatches = clampedRanges.map { range -> Int? in
            guard let previous,
                  let match = previous.ranges.indices.first(where: { index in
                      !usedPreviousIndices.contains(index)
                          && NSEqualRanges(previous.ranges[index].range, range)
                  }) else { return nil }
            usedPreviousIndices.insert(match)
            return match
        }

        // Direction hints are captured in the same active-first order used by
        // appKitRanges(from:). Prefer exact previous-range identity, then pair
        // newly-shaped ranges in active-first order. Matching by anchor value
        // alone is ambiguous for adjacent ranges that share an endpoint.
        var hintedAnchors = [Int?](repeating: nil, count: clampedRanges.count)
        var usedAnchorIndices = Set<Int>()
        if let directionAnchors {
            if let previous, directionAnchors.count == previous.ranges.count {
                let previousActiveFirst = [previous.mainIndex]
                    + previous.ranges.indices.filter { $0 != previous.mainIndex }
                var hintIndexByPreviousIndex: [Int: Int] = [:]
                for (hintIndex, previousIndex) in zip(
                    directionAnchors.indices, previousActiveFirst
                ) {
                    hintIndexByPreviousIndex[previousIndex] = hintIndex
                }
                for rangeIndex in clampedRanges.indices
                where hintedAnchors[rangeIndex] == nil {
                    guard let previousIndex = previousMatches[rangeIndex],
                          let hintIndex = hintIndexByPreviousIndex[previousIndex],
                          !usedAnchorIndices.contains(hintIndex) else { continue }
                    let anchor = directionAnchors[hintIndex]
                    let range = clampedRanges[rangeIndex]
                    guard anchor == range.location
                            || anchor == NSMaxRange(range) else { continue }
                    hintedAnchors[rangeIndex] = anchor
                    usedAnchorIndices.insert(hintIndex)
                }
            }

            let activeFirst = [mainIndex] + clampedRanges.indices.filter { $0 != mainIndex }
            let remainingAnchorIndices = directionAnchors.indices.filter {
                !usedAnchorIndices.contains($0)
            }
            let remainingRangeIndices = activeFirst.filter {
                hintedAnchors[$0] == nil
            }
            for (anchorIndex, rangeIndex) in zip(
                remainingAnchorIndices, remainingRangeIndices
            ) {
                let anchor = directionAnchors[anchorIndex]
                let range = clampedRanges[rangeIndex]
                if anchor == range.location || anchor == NSMaxRange(range) {
                    hintedAnchors[rangeIndex] = anchor
                    usedAnchorIndices.insert(anchorIndex)
                }
            }

            // A count-changing native gesture can leave no positional match.
            // Accept only an unambiguous endpoint value rather than guessing
            // between two differently directed adjacent selections.
            for rangeIndex in clampedRanges.indices
            where hintedAnchors[rangeIndex] == nil {
                let range = clampedRanges[rangeIndex]
                let candidates = directionAnchors.indices.filter { anchorIndex in
                    !usedAnchorIndices.contains(anchorIndex)
                        && (directionAnchors[anchorIndex] == range.location
                            || directionAnchors[anchorIndex] == NSMaxRange(range))
                }
                let candidateValues = Set(candidates.map { directionAnchors[$0] })
                guard candidateValues.count == 1, let anchorIndex = candidates.first else {
                    continue
                }
                hintedAnchors[rangeIndex] = directionAnchors[anchorIndex]
                usedAnchorIndices.insert(anchorIndex)
            }
        }

        let directed = clampedRanges.enumerated().map { index, range -> DirectedSelection in
            if let anchor = hintedAnchors[index] {
                let head = anchor == range.location ? NSMaxRange(range) : range.location
                return DirectedSelection(anchor: anchor, head: head)
            }
            if let previous, let match = previousMatches[index] {
                return previous.ranges[match]
            }
            return DirectedSelection(
                anchor: range.location,
                head: NSMaxRange(range)
            )
        }
        return SelectionSet(ranges: directed, mainIndex: mainIndex)
    }

    private static func sameRangeMultiset(_ left: [NSRange], _ right: [NSRange]) -> Bool {
        guard left.count == right.count else { return false }
        var unmatched = right
        for candidate in left {
            guard let match = unmatched.firstIndex(where: {
                NSEqualRanges($0, candidate)
            }) else { return false }
            unmatched.remove(at: match)
        }
        return true
    }

    static func selectionsAfterReplacing(
        _ selections: SelectionSet,
        affectedRanges: [NSRange],
        replacementStrings: [String],
        originalUTF16Length: Int
    ) -> SelectionSet {
        guard affectedRanges.count == replacementStrings.count else { return selections }
        var replacements = zip(affectedRanges, replacementStrings).enumerated().map {
            Replacement(range: $0.element.0, string: $0.element.1, order: $0.offset)
        }
        guard replacements.allSatisfy({ isValid(
            $0.range,
            forUTF16Length: originalUTF16Length
        ) }) else { return selections }
        replacements.sort { left, right in
            if left.range.location != right.range.location {
                return left.range.location < right.range.location
            }
            return left.order < right.order
        }

        let edits = replacements.map { replacement in
            TextEdit(
                from: replacement.range.location,
                to: NSMaxRange(replacement.range),
                insert: replacement.string
            )
        }
        guard let transaction = try? TextTransaction(edits: edits) else { return selections }
        var cursorByReplacement = [Int: Int]()
        var delta = 0
        for replacement in replacements {
            cursorByReplacement[replacement.order] = replacement.range.location
                + delta + replacement.string.utf16.count
            delta += replacement.string.utf16.count - replacement.range.length
        }

        let mapped = selections.ranges.map { selection -> DirectedSelection in
            if let replacement = replacements.first(where: {
                NSEqualRanges($0.range, selection.range)
            }), let cursor = cursorByReplacement[replacement.order] {
                return DirectedSelection(anchor: cursor, head: cursor)
            }
            return transaction.mapSelection(selection)
        }
        let finalLength = max(0, originalUTF16Length + delta)
        return SelectionSet(ranges: mapped, mainIndex: selections.mainIndex)
            .clamped(toUTF16Length: finalLength)
    }

    static func scrollPosition(from point: NSPoint) -> NativeTextEditorScrollPosition {
        NativeTextEditorScrollPosition(
            x: integerPoint(point.x),
            y: integerPoint(point.y)
        )
    }

    static func beginsRectangularSelectionDrag(
        from start: NSPoint,
        to current: NSPoint,
        threshold: CGFloat = optionClickDragThreshold
    ) -> Bool {
        guard start.x.isFinite, start.y.isFinite,
              current.x.isFinite, current.y.isFinite,
              threshold.isFinite, threshold > 0
        else { return false }
        let dx = current.x - start.x
        let dy = current.y - start.y
        return dx * dx + dy * dy >= threshold * threshold
    }

    static func findHighlightInvalidationRange(
        previous: [NativeTextEditorVisualPlanner.FindHighlight],
        current: [NativeTextEditorVisualPlanner.FindHighlight],
        textLength: Int
    ) -> NSRange? {
        let highlights = previous + current
        guard !highlights.isEmpty else { return nil }
        let length = max(0, textLength)
        var lower = length
        var upper = 0
        for highlight in highlights {
            let location = min(length, max(0, highlight.range.location))
            let end = min(length, max(location, NSMaxRange(highlight.range)))
            lower = min(lower, location)
            upper = max(upper, end)
            if highlight.range.length == 0, length > 0 {
                // A point decoration must invalidate a neighboring character
                // so TextKit has a real glyph/line to redraw.
                if location < length {
                    upper = max(upper, location + 1)
                } else {
                    lower = min(lower, length - 1)
                }
            }
        }
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    /// Advances through sorted, disjoint ranges while character indexes stay
    /// monotonic. Complex-script glyph clusters may repeat or decrease their
    /// indexes, so those transitions resume with a logarithmic lower-bound.
    static func foldedCharacterMask(
        characterIndexes: [Int], foldedRanges: [NSRange]
    ) -> [Bool] {
        var result = Array(repeating: false, count: characterIndexes.count)
        var rangeIndex = 0
        var previousCharacter: Int?
        for (index, character) in characterIndexes.enumerated() {
            if let previousCharacter, character < previousCharacter {
                rangeIndex = foldedRangeIndex(
                    containingOrFollowing: character, in: foldedRanges
                )
            }
            while rangeIndex < foldedRanges.count,
                  NSMaxRange(foldedRanges[rangeIndex]) <= character {
                rangeIndex += 1
            }
            guard rangeIndex < foldedRanges.count else {
                // A later glyph in a complex-script cluster may map back to an
                // earlier character. Keep scanning so that decrease can reset
                // the range cursor with the binary-search path above.
                previousCharacter = character
                continue
            }
            let range = foldedRanges[rangeIndex]
            result[index] = character >= range.location
                && character < NSMaxRange(range)
            previousCharacter = character
        }
        return result
    }

    private static func foldedRangeIndex(
        containingOrFollowing character: Int, in ranges: [NSRange]
    ) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(ranges[middle]) <= character {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    static func optionClickSelection(
        in text: String,
        at position: RectangularSelectionPlanner.Position,
        initialSelection: SelectionSet,
        tabWidth requestedTabWidth: Int,
        maximumSelections: Int = RectangularSelectionPlanner.maximumLines
    ) -> SelectionSet {
        let offset = optionClickOffset(
            in: text,
            at: position,
            tabWidth: requestedTabWidth
        )
        let cursor = DirectedSelection(anchor: offset, head: offset)
        let merged = RectangularSelectionPlanner.merging(
            SelectionSet(ranges: [cursor]),
            into: initialSelection,
            maximumSelections: maximumSelections
        )
        return SelectionSet(ranges: merged.ranges, mainIndex: merged.mainIndex)
    }

    private static func isValid(_ range: NSRange, forUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private static func splitsSurrogatePair(_ units: [UInt16], at boundary: Int) -> Bool {
        guard boundary > 0, boundary < units.count else { return false }
        return (0xD800...0xDBFF).contains(units[boundary - 1])
            && (0xDC00...0xDFFF).contains(units[boundary])
    }

    private static func integerPoint(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        if rounded >= CGFloat(Int.max) { return Int.max }
        return Int(rounded)
    }

    private static func optionClickOffset(
        in text: String,
        at position: RectangularSelectionPlanner.Position,
        tabWidth requestedTabWidth: Int
    ) -> Int {
        let source = text as NSString
        let lines = optionClickPhysicalLines(in: source)
        let lineIndex = min(max(0, position.line), max(0, lines.count - 1))
        let line = lines[lineIndex]
        let target = max(0, position.visualColumn)
        let tabWidth = min(16, max(1, requestedTabWidth))
        var location = line.location
        var column = 0
        while location < NSMaxRange(line) {
            let unit = source.character(at: location)
            let characterRange = source.rangeOfComposedCharacterSequence(at: location)
            let nextColumn = unit == 0x09
                ? column + tabWidth - column % tabWidth
                : column + 1
            if target < nextColumn {
                let leftDistance = target - column
                let rightDistance = nextColumn - target
                return leftDistance < rightDistance ? location : NSMaxRange(characterRange)
            }
            if target == nextColumn { return NSMaxRange(characterRange) }
            column = nextColumn
            location = NSMaxRange(characterRange)
        }
        return NSMaxRange(line)
    }

    private static func optionClickPhysicalLines(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var lines: [NSRange] = []
        var location = 0
        while location < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                nil, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            guard lineEnd > location else { break }
            lines.append(NSRange(location: location, length: contentsEnd - location))
            location = lineEnd
        }
        if location == source.length, optionClickEndsInLineTerminator(source) {
            lines.append(NSRange(location: source.length, length: 0))
        }
        return lines.isEmpty ? [NSRange(location: 0, length: 0)] : lines
    }

    private static func optionClickEndsInLineTerminator(_ source: NSString) -> Bool {
        guard source.length > 0 else { return false }
        switch source.character(at: source.length - 1) {
        case 0x0A, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private struct Replacement {
        let range: NSRange
        let string: String
        let order: Int
    }
}

/// TextKit 1 layer for editor presentation. Decorations remain draw-only, while
/// folding substitutes null glyph properties so hidden UTF-16 content stops
/// participating in layout without changing the backing text storage.
final class NativeTextEditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    fileprivate var palette = NativeEditorPalette.make(
        colorScheme: .dark,
        compatibleWith: .dark
    ) {
        didSet {
            guard oldValue != palette else { return }
            invalidateDisplay(forCharacterRange: NSRange(
                location: 0,
                length: textStorage?.length ?? 0
            ))
        }
    }
    private var showWhitespace = false
    private var showIndentGuides = true
    private var highlightTrailingWhitespace = true
    private var tabWidth = 4
    private var characterWidth: CGFloat = 8
    private var foldedCharacterRanges: [NSRange] = []
    private var foldMarkers: [NativeTextEditorVisualPlanner.FoldMarker] = []
    private var foldIdentity: FoldIdentity?
    private var syntaxLanguage = "Plain Text"
    private var syntaxDocumentID = ""
    private var syntaxRevision: UInt64 = 0
    private var parsedSyntaxHighlighting: NativeSyntaxHighlighter.ParsedSnapshot?
    private var diagnosticPlan = NativeTextEditorVisualPlanner.DiagnosticPlan(
        marks: [], markedLines: [:]
    )
    private var diagnosticIdentity: DiagnosticIdentity?
    fileprivate var diagnosticMarkedLines: [
        Int: NativeTextEditorVisualPlanner.DiagnosticSeverity
    ] { diagnosticPlan.markedLines }
    fileprivate var documentRevision: UInt64 { syntaxRevision }
    fileprivate var foldedRangesForTesting: [NSRange] { foldedCharacterRanges }
    fileprivate var foldSnapshotIdentityForTesting: (String, EditorViewID, UInt64)? {
        foldIdentity.map { ($0.documentID, $0.viewID, $0.documentRevision) }
    }
    private var findHighlightPlan = NativeTextEditorVisualPlanner.FindHighlightPlan(
        highlights: []
    )
    private var findHighlightIdentity: FindHighlightIdentity?
    private var visualSelection: NativeTextEditorVisualPlanner.VisualSelection?
    private weak var textView: NSTextView?
    private var pendingZeroLengthFindHighlights: [
        NativeTextEditorVisualPlanner.FindHighlight
    ] = []

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    private struct DiagnosticIdentity: Equatable {
        let documentID: String
        let documentRevision: UInt64
        let serverKey: LanguageServerInstanceKey?
        let filePath: String?
        let generation: UInt64?
        let presentationRevision: UInt64?
    }

    private struct FoldIdentity: Equatable {
        let documentID: String
        let viewID: EditorViewID
        let documentRevision: UInt64
        let presentationRevision: UInt64
        let hiddenRanges: [NSRange]
        let markers: [TextKitFoldMarker]
    }

    private struct FindHighlightIdentity: Equatable {
        let documentID: String
        let viewID: EditorViewID
        let paneIndex: Int
        let documentRevision: UInt64
        let highlights: [NativeTextEditorVisualPlanner.FindHighlight]
    }

    enum FindHighlightDrawingPass: Equatable {
        case editorBackgroundDecorations
        case textKitBackground
        case zeroWidthForeground
    }

    static let findHighlightDrawingOrder: [FindHighlightDrawingPass] = [
        .editorBackgroundDecorations, .textKitBackground, .zeroWidthForeground
    ]

    fileprivate func configureFolding(
        _ snapshot: TextKitFoldSnapshot?,
        documentID: String,
        viewID: EditorViewID,
        documentRevision: UInt64
    ) {
        let accepted = snapshot.flatMap { value in
            value.documentID == documentID
                && value.viewID == viewID
                && value.documentRevision == documentRevision
                ? value : nil
        }
        let identity = accepted.map { value in
            FoldIdentity(
                documentID: value.documentID, viewID: value.viewID,
                documentRevision: value.documentRevision,
                presentationRevision: value.presentationRevision,
                hiddenRanges: value.hiddenRanges, markers: value.markers
            )
        }
        guard identity != foldIdentity else { return }

        let previousRanges = foldedCharacterRanges
        let previousMarkers = foldMarkers
        foldMarkers = accepted.map { snapshot in
            let plan = NativeTextEditorVisualPlanner.foldMarkerPlan(
                text: textStorage?.string ?? "", markers: snapshot.markers.map { marker in
                    NativeTextEditorVisualPlanner.FoldMarker(
                        id: marker.id, startLine: marker.startLine,
                        endLine: marker.endLine, fullRange: marker.fullRange,
                        hiddenRange: marker.hiddenRange, isFolded: marker.isFolded
                    )
                }
            )
            return plan.markerByStartLine.values.filter(\.isFolded).sorted { left, right in
                if left.startLine != right.startLine { return left.startLine < right.startLine }
                return left.id < right.id
            }
        } ?? []
        foldIdentity = identity
        let textLength = textStorage?.length ?? 0
        foldedCharacterRanges = Self.normalizedFoldRanges(
            accepted?.hiddenRanges ?? [], textLength: textLength
        )
        let allCharacters = NSRange(location: 0, length: textLength)
        guard foldedCharacterRanges != previousRanges else {
            if foldMarkers != previousMarkers {
                invalidateDisplay(forCharacterRange: allCharacters)
                textView?.needsDisplay = true
            }
            return
        }
        guard allCharacters.length > 0 else {
            textView?.needsDisplay = true
            return
        }
        invalidateGlyphs(
            forCharacterRange: allCharacters, changeInLength: 0,
            actualCharacterRange: nil
        )
        invalidateLayout(forCharacterRange: allCharacters, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: allCharacters)
        textView?.needsDisplay = true
    }

    private static func normalizedFoldRanges(
        _ ranges: [NSRange], textLength: Int
    ) -> [NSRange] {
        let normalized = ranges.compactMap { requested -> NSRange? in
            guard requested.location != NSNotFound, requested.location >= 0,
                  requested.length > 0, requested.location < textLength else { return nil }
            return NSRange(
                location: requested.location,
                length: min(requested.length, textLength - requested.location)
            )
        }.sorted { left, right in
            left.location != right.location
                ? left.location < right.location
                : left.length > right.length
        }
        var result: [NSRange] = []
        for range in normalized {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !foldedCharacterRanges.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        let characterIndexes = Array(
            UnsafeBufferPointer(start: charIndexes, count: glyphRange.length)
        )
        let foldedMask = NativeTextEditorAdapter.foldedCharacterMask(
            characterIndexes: characterIndexes, foldedRanges: foldedCharacterRanges
        )
        var changed = false
        for offset in properties.indices where foldedMask[offset] {
            properties[offset].insert(.null)
            changed = true
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { rewritten in
            guard let baseAddress = rewritten.baseAddress else { return }
            layoutManager.setGlyphs(
                glyphs, properties: baseAddress, characterIndexes: charIndexes,
                font: aFont, forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    fileprivate func isFoldedCharacter(at location: Int) -> Bool {
        foldedCharacterRanges.contains { NSLocationInRange(location, $0) }
    }

    fileprivate func configure(
        showWhitespace: Bool,
        showIndentGuides: Bool,
        highlightTrailingWhitespace: Bool,
        tabWidth: Int,
        characterWidth: CGFloat
    ) {
        let tabWidth = min(16, max(1, tabWidth))
        let characterWidth = max(1, characterWidth.isFinite ? characterWidth : 8)
        guard self.showWhitespace != showWhitespace
                || self.showIndentGuides != showIndentGuides
                || self.highlightTrailingWhitespace != highlightTrailingWhitespace
                || self.tabWidth != tabWidth
                || abs(self.characterWidth - characterWidth) > 0.01
        else { return }

        self.showWhitespace = showWhitespace
        self.showIndentGuides = showIndentGuides
        self.highlightTrailingWhitespace = highlightTrailingWhitespace
        self.tabWidth = tabWidth
        self.characterWidth = characterWidth
        invalidateDisplay(forCharacterRange: NSRange(
            location: 0,
            length: textStorage?.length ?? 0
        ))
    }

    fileprivate func configureSyntaxHighlighting(
        language: String, documentID: String, revision: UInt64,
        parsedSnapshot: NativeSyntaxHighlighter.ParsedSnapshot?
    ) {
        guard syntaxLanguage != language || syntaxDocumentID != documentID
                || syntaxRevision != revision
                || parsedSyntaxHighlighting != parsedSnapshot else { return }
        syntaxLanguage = language
        syntaxDocumentID = documentID
        syntaxRevision = revision
        parsedSyntaxHighlighting = parsedSnapshot
        invalidateDisplay(forCharacterRange: NSRange(
            location: 0, length: textStorage?.length ?? 0
        ))
    }

    fileprivate func configureDiagnostics(
        text: String, diagnostics: [NativeTextEditorVisualPlanner.Diagnostic],
        documentID: String, documentRevision: UInt64,
        serverKey: LanguageServerInstanceKey?, filePath: String?, generation: UInt64?,
        presentationRevision: UInt64?
    ) -> NativeTextEditorVisualPlanner.DiagnosticPlan {
        let identity = DiagnosticIdentity(
            documentID: documentID, documentRevision: documentRevision,
            serverKey: serverKey, filePath: filePath, generation: generation,
            presentationRevision: presentationRevision
        )
        guard identity != diagnosticIdentity else { return diagnosticPlan }
        let plan = NativeTextEditorVisualPlanner.diagnosticPlan(
            text: text, diagnostics: diagnostics
        )
        diagnosticIdentity = identity
        diagnosticPlan = plan
        invalidateDisplay(forCharacterRange: NSRange(
            location: 0, length: textStorage?.length ?? 0
        ))
        return plan
    }

    fileprivate func configureFindHighlights(
        _ plan: NativeTextEditorVisualPlanner.FindHighlightPlan,
        documentID: String,
        viewID: EditorViewID,
        paneIndex: Int,
        documentRevision: UInt64
    ) {
        let identity = FindHighlightIdentity(
            documentID: documentID, viewID: viewID, paneIndex: paneIndex,
            documentRevision: documentRevision, highlights: plan.highlights
        )
        guard identity != findHighlightIdentity else { return }
        let previous = findHighlightPlan.highlights
        findHighlightIdentity = identity
        findHighlightPlan = plan
        if let changed = NativeTextEditorAdapter.findHighlightInvalidationRange(
            previous: previous, current: plan.highlights,
            textLength: textStorage?.length ?? 0
        ) {
            invalidateDisplay(forCharacterRange: changed)
            // A zero-width decoration has no TextKit character span of its
            // own. In particular, an empty document cannot produce a glyph
            // invalidation, so make the attached view participate as well.
            if (previous + plan.highlights).contains(where: { $0.range.length == 0 }) {
                textView?.needsDisplay = true
            }
        }
    }

    fileprivate func configureSelectionVisuals(
        _ selection: NativeTextEditorVisualPlanner.VisualSelection?
    ) {
        guard visualSelection != selection else { return }
        visualSelection = selection
    }

    fileprivate func attachTextView(_ textView: NSTextView) {
        self.textView = textView
    }

    fileprivate func drawEmptyDocumentCurrentLine(
        in textView: NSTextView, dirtyRect: NSRect
    ) {
        guard textStorage?.length == 0, visualSelection?.head == 0 else { return }
        let font = textView.font
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let origin = textView.textContainerOrigin
        let height = defaultLineHeight(for: font)
        let rect = NSRect(
            x: origin.x, y: origin.y,
            width: max(0, textView.bounds.width - origin.x), height: height
        )
        let clipped = NSIntersectionRect(rect, dirtyRect)
        guard !clipped.isEmpty else { return }
        palette.currentLineBackground.setFill()
        clipped.fill()
    }

    fileprivate func drawEmptyDocumentFindHighlights(
        in textView: NSTextView, dirtyRect: NSRect
    ) {
        guard textStorage?.length == 0 else { return }
        for highlight in findHighlightPlan.highlights
        where highlight.range == NSRange(location: 0, length: 0) {
            guard let rect = zeroLengthFindHighlightRect(
                at: 0, origin: textView.textContainerOrigin
            ) else { continue }
            let clipped = NSIntersectionRect(rect, dirtyRect)
            guard !clipped.isEmpty else { continue }
            fillZeroLengthFindHighlight(highlight, in: clipped)
        }
    }

    fileprivate func beginZeroLengthFindHighlightDrawing() {
        pendingZeroLengthFindHighlights.removeAll(keepingCapacity: true)
    }

    fileprivate func accumulateZeroLengthFindHighlights(in characterRange: NSRange) {
        let candidates = visibleZeroLengthFindHighlights(in: characterRange)
        for highlight in candidates where !pendingZeroLengthFindHighlights.contains(highlight) {
            pendingZeroLengthFindHighlights.append(highlight)
        }
    }

    fileprivate func takePendingZeroLengthFindHighlights()
        -> [NativeTextEditorVisualPlanner.FindHighlight] {
        defer { pendingZeroLengthFindHighlights.removeAll(keepingCapacity: true) }
        return pendingZeroLengthFindHighlights
    }

    fileprivate func configureFindHighlightsForTesting(
        _ highlights: [NativeTextEditorVisualPlanner.FindHighlight]
    ) {
        findHighlightPlan = .init(highlights: highlights)
        beginZeroLengthFindHighlightDrawing()
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage, glyphsToShow.length > 0 else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let dirtyCharacterRange = self.characterRange(
            forGlyphRange: glyphsToShow,
            actualGlyphRange: nil
        )
        let characterRange = visibleCharacterRange() ?? dirtyCharacterRange
        let plan = NativeTextEditorVisualPlanner.plan(
            text: textStorage.string,
            visibleCharacterRange: dirtyCharacterRange,
            tabWidth: tabWidth,
            includeWhitespaceMarkers: false,
            includeIndentation: showIndentGuides,
            includeTrailingWhitespace: highlightTrailingWhitespace
        )
        let decorations = NativeTextEditorVisualPlanner.decorationPlan(
            text: textStorage.string, visibleCharacterRange: characterRange,
            selection: visualSelection
        )

        for pass in Self.findHighlightDrawingOrder {
            switch pass {
            case .editorBackgroundDecorations:
                drawCurrentLine(
                    decorations.currentLineRange.map {
                        NSIntersectionRange($0, dirtyCharacterRange)
                    },
                    glyphsToShow: glyphsToShow, origin: origin
                )
                palette.selectionMatchBackground.setFill()
                for range in decorations.selectedWordMatchRanges {
                    let dirtyRange = NSIntersectionRange(range, dirtyCharacterRange)
                    guard dirtyRange.length > 0 else { continue }
                    enumerateRects(forCharacterRange: dirtyRange, origin: origin) { rect in
                        rect.fill()
                    }
                }

                if highlightTrailingWhitespace {
                    palette.trailingWhitespace.setFill()
                    for line in plan.lines {
                        guard let range = line.trailingWhitespaceRange else { continue }
                        enumerateRects(forCharacterRange: range, origin: origin) { rect in
                            rect.fill()
                        }
                    }
                }

                if showIndentGuides {
                    drawIndentGuides(in: plan, glyphsToShow: glyphsToShow, origin: origin)
                }
                drawDiagnostics(in: dirtyCharacterRange, origin: origin)
                // Normal Find ranges remain backgrounds, but are the final
                // editor-owned background layer before AppKit selection.
                drawFindHighlightRanges(in: dirtyCharacterRange, origin: origin)
            case .textKitBackground:
                // AppKit's selection remains above normal highlight fills.
                super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            case .zeroWidthForeground:
                // Capture only; NativeTextView paints these after its complete
                // AppKit glyph/background/selection draw pass.
                accumulateZeroLengthFindHighlights(in: dirtyCharacterRange)
            }
        }
        let visibleBrackets = decorations.matchingBracketRanges.filter {
            characterRangeIsDrawable($0)
        }
        guard visibleBrackets.count == decorations.matchingBracketRanges.count else { return }
        drawMatchingBrackets(
            visibleBrackets.filter { NSIntersectionRange($0, dirtyCharacterRange).length > 0 },
            origin: origin
        )
    }

    private func drawFindHighlightRanges(in dirtyRange: NSRange, origin: NSPoint) {
        for highlight in findHighlightPlan.highlights where highlight.range.length > 0 {
            let range = NSIntersectionRange(highlight.range, dirtyRange)
            guard range.length > 0 else { continue }
            let base = palette.selectionMatchBackground
            let fill = highlight.isCurrent
                ? base.withAlphaComponent(
                    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.78 : 0.56
                )
                : base
            fill.setFill()
            for drawableRange in drawableCharacterRanges(in: range) {
                enumerateRects(forCharacterRange: drawableRange, origin: origin) { rect in
                    rect.fill()
                    if highlight.isCurrent {
                        palette.matchingBracketBorder.setStroke()
                        let outline = NSBezierPath(roundedRect: rect.insetBy(
                            dx: 0.5, dy: 0.5
                        ), xRadius: 2, yRadius: 2)
                        outline.lineWidth = palette.matchingBracketLineWidth
                        outline.stroke()
                    }
                }
            }
        }
    }

    private func visibleZeroLengthFindHighlights(in dirtyRange: NSRange)
        -> [NativeTextEditorVisualPlanner.FindHighlight] {
        let dirtyUpperBound = NSMaxRange(dirtyRange)
        let textLength = textStorage?.length ?? 0
        return findHighlightPlan.highlights.filter { highlight in
            highlight.range.length == 0 && highlight.range.location >= dirtyRange.location
                && (highlight.range.location < dirtyUpperBound
                    || (highlight.range.location == textLength
                        && dirtyUpperBound == textLength)
                    || (dirtyRange.length == 0
                        && highlight.range.location == dirtyRange.location))
        }
    }

    fileprivate func drawPendingZeroLengthFindHighlights(in textView: NSTextView) {
        let highlights = takePendingZeroLengthFindHighlights()
        guard textStorage?.length ?? 0 > 0 else { return }
        let origin = textView.textContainerOrigin
        for highlight in highlights {
            drawZeroLengthFindHighlight(highlight, origin: origin)
        }
    }

    private func drawZeroLengthFindHighlight(
        _ highlight: NativeTextEditorVisualPlanner.FindHighlight, origin: NSPoint
    ) {
        guard let rect = zeroLengthFindHighlightRect(
            at: highlight.range.location, origin: origin
        ) else { return }
        fillZeroLengthFindHighlight(highlight, in: rect)
    }

    fileprivate func zeroLengthFindHighlightRect(
        at requestedLocation: Int, origin: NSPoint
    ) -> NSRect? {
        guard let textStorage, let textContainer = textContainers.first else { return nil }
        let textLength = textStorage.length
        guard requestedLocation >= 0, requestedLocation <= textLength else { return nil }
        ensureLayout(for: textContainer)

        if textLength == 0 {
            let fragment = !extraLineFragmentRect.isEmpty
                ? extraLineFragmentRect
                : NSRect(
                    x: 0, y: 0, width: max(1, textContainer.containerSize.width),
                    height: defaultLineHeight(for: textView?.font
                        ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
                )
            return zeroLengthFindHighlightRect(x: fragment.minX, lineRect: fragment,
                                               origin: origin)
        }

        if requestedLocation < textLength {
            guard !isFoldedCharacter(at: requestedLocation) else { return nil }
            let glyph = glyphIndexForCharacter(at: requestedLocation)
            guard glyph < numberOfGlyphs else { return nil }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let glyphLocation = location(forGlyphAt: glyph)
            return zeroLengthFindHighlightRect(
                x: line.minX + glyphLocation.x, lineRect: line, origin: origin
            )
        }

        if !extraLineFragmentRect.isEmpty, endsInLineTerminator(textStorage.string) {
            return zeroLengthFindHighlightRect(
                x: extraLineFragmentRect.minX, lineRect: extraLineFragmentRect, origin: origin
            )
        }

        // A non-newline-terminated document has no extra line fragment. Its
        // EOF insertion point is the trailing edge of the final glyph. Ask
        // TextKit for that exact laid-out glyph rectangle rather than using
        // the line fragment origin.
        let glyph = numberOfGlyphs - 1
        guard glyph >= 0 else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphBounds = boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer
        )
        return zeroLengthFindHighlightRect(
            x: glyphBounds.maxX, lineRect: line, origin: origin
        )
    }

    private func endsInLineTerminator(_ text: String) -> Bool {
        let source = text as NSString
        guard source.length > 0 else { return false }
        switch source.character(at: source.length - 1) {
        case 0x0A, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private func zeroLengthFindHighlightRect(
        x: CGFloat, lineRect: NSRect, origin: NSPoint
    ) -> NSRect {
        NSRect(
            x: x + origin.x, y: lineRect.minY + origin.y + 1,
            width: 3, height: max(2, lineRect.height - 2)
        )
    }

    private func fillZeroLengthFindHighlight(
        _ highlight: NativeTextEditorVisualPlanner.FindHighlight, in rect: NSRect
    ) {
        let color = highlight.isCurrent
            ? palette.matchingBracketBorder : palette.selectionMatchBackground
        color.setFill()
        NSRect(
            x: rect.minX, y: rect.minY, width: highlight.isCurrent ? 3 : 2,
            height: rect.height
        ).fill()
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        applySyntaxHighlighting(to: glyphsToShow)
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawFoldPlaceholders(forGlyphRange: glyphsToShow, origin: origin)
        guard showWhitespace, let textStorage, glyphsToShow.length > 0,
              let textContainer = textContainers.first else { return }

        let characterRange = self.characterRange(
            forGlyphRange: glyphsToShow,
            actualGlyphRange: nil
        )
        let plan = NativeTextEditorVisualPlanner.plan(
            text: textStorage.string,
            visibleCharacterRange: characterRange,
            tabWidth: tabWidth,
            includeIndentation: false,
            includeTrailingWhitespace: false
        )
        let markerColor = palette.whitespace
        markerColor.setFill()
        markerColor.setStroke()

        for marker in plan.whitespaceMarkers {
            guard marker.location < textStorage.length,
                  !isFoldedCharacter(at: marker.location) else { continue }
            let glyphIndex = glyphIndexForCharacter(at: marker.location)
            guard glyphIndex < numberOfGlyphs else { continue }
            enumerateEnclosingRects(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                let rect = rect.offsetBy(dx: origin.x, dy: origin.y)
                switch marker.kind {
                case .space:
                    let diameter = max(1.5, min(2.5, rect.height * 0.14))
                    NSBezierPath(ovalIn: NSRect(
                        x: rect.midX - diameter / 2,
                        y: rect.midY - diameter / 2,
                        width: diameter,
                        height: diameter
                    )).fill()
                case .tab:
                    drawTabMarker(in: rect)
                }
            }
        }
    }

    private func drawFoldPlaceholders(
        forGlyphRange visibleGlyphs: NSRange, origin: NSPoint
    ) {
        guard !foldMarkers.isEmpty, let textStorage else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: palette.foreground
        ]
        for marker in foldMarkers where marker.isFolded {
            let anchor = max(
                marker.fullRange.location,
                min(max(0, textStorage.length - 1), marker.hiddenRange.location - 1)
            )
            guard anchor >= 0, anchor < textStorage.length else { continue }
            let glyph = glyphIndexForCharacter(at: anchor)
            guard glyph < numberOfGlyphs, NSLocationInRange(glyph, visibleGlyphs),
                  !isFoldedCharacter(at: anchor) else { continue }
            let used = lineFragmentUsedRect(
                forGlyphAt: glyph, effectiveRange: nil
            ).offsetBy(dx: origin.x, dy: origin.y)
            let label = " … " as NSString
            let size = label.size(withAttributes: attributes)
            let rect = NSRect(
                x: used.maxX + 3, y: used.midY - size.height / 2,
                width: size.width + 4, height: size.height
            )
            palette.selectionMatchBackground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            label.draw(
                at: NSPoint(x: rect.minX + 2, y: rect.minY),
                withAttributes: attributes
            )
        }
    }

    private func applySyntaxHighlighting(to glyphRange: NSRange) {
        guard let textStorage, glyphRange.length > 0 else { return }
        let characterRange = self.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil
        )
        removeTemporaryAttribute(.foregroundColor, forCharacterRange: characterRange)
        let plan = NativeSyntaxHighlighter.plan(
            text: textStorage.string, language: syntaxLanguage,
            visibleRange: characterRange, documentID: syntaxDocumentID,
            documentRevision: syntaxRevision,
            parsedSnapshot: parsedSyntaxHighlighting
        )
        for span in plan.spans {
            addTemporaryAttribute(
                .foregroundColor, value: palette.syntaxColor(for: span.kind),
                forCharacterRange: span.range
            )
        }
    }

    private func drawIndentGuides(
        in plan: NativeTextEditorVisualPlanner.Plan,
        glyphsToShow: NSRange,
        origin: NSPoint
    ) {
        let indentWidth = characterWidth * CGFloat(tabWidth)
        palette.indentGuide.setStroke()

        for line in plan.lines {
            let levels = line.indentationColumns / tabWidth
            guard levels > 0 else { continue }
            let lineGlyphRange = glyphRange(
                forCharacterRange: line.contentsRange,
                actualCharacterRange: nil
            )
            let visibleLineGlyphs = NSIntersectionRange(lineGlyphRange, glyphsToShow)
            guard visibleLineGlyphs.length > 0 else { continue }

            enumerateLineFragments(forGlyphRange: visibleLineGlyphs) {
                fragmentRect, _, _, _, _ in
                let fragmentRect = fragmentRect.offsetBy(dx: origin.x, dy: origin.y)
                let path = NSBezierPath()
                path.lineWidth = 1
                for level in 1...levels {
                    let x = fragmentRect.minX + CGFloat(level) * indentWidth + 0.5
                    path.move(to: NSPoint(x: x, y: fragmentRect.minY))
                    path.line(to: NSPoint(x: x, y: fragmentRect.maxY))
                }
                path.stroke()
            }
        }
    }

    private func visibleCharacterRange() -> NSRange? {
        guard let textView, let textContainer = textContainers.first else { return nil }
        ensureLayout(for: textContainer)
        let origin = textView.textContainerOrigin
        let rect = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = glyphRange(forBoundingRect: rect, in: textContainer)
        guard glyphs.length > 0 else { return nil }
        return characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func characterRangeIsDrawable(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        return !foldedCharacterRanges.contains {
            NSIntersectionRange($0, range).length > 0
        }
    }

    private func drawCurrentLine(
        _ characterRange: NSRange?,
        glyphsToShow: NSRange,
        origin: NSPoint
    ) {
        guard let characterRange else { return }
        palette.currentLineBackground.setFill()
        let glyphRange: NSRange
        if characterRange.length == 0 {
            if characterRange.location == textStorage?.length,
               !extraLineFragmentRect.isEmpty {
                var rect = extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
                rect.fill()
            }
            return
        } else {
            glyphRange = self.glyphRange(
                forCharacterRange: characterRange, actualCharacterRange: nil
            )
        }
        let visibleGlyphs = NSIntersectionRange(glyphRange, glyphsToShow)
        guard visibleGlyphs.length > 0 else { return }
        enumerateLineFragments(forGlyphRange: visibleGlyphs) { fragment, _, _, _, _ in
            fragment.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    private func drawMatchingBrackets(_ ranges: [NSRange], origin: NSPoint) {
        guard !ranges.isEmpty else { return }
        palette.matchingBracketBorder.setStroke()
        for range in ranges {
            enumerateRects(forCharacterRange: range, origin: origin) { rect in
                let inset = palette.matchingBracketLineWidth / 2
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: inset, dy: inset),
                    xRadius: 2, yRadius: 2
                )
                outline.lineWidth = palette.matchingBracketLineWidth
                outline.stroke()
            }
        }
    }

    private func drawDiagnostics(in dirtyRange: NSRange, origin: NSPoint) {
        for mark in diagnosticPlan.marks {
            let range = NSIntersectionRange(mark.range, dirtyRange)
            guard range.length > 0 else { continue }
            let color = palette.diagnosticColor(for: mark.severity)
            for drawableRange in drawableCharacterRanges(in: range) {
                enumerateRects(forCharacterRange: drawableRange, origin: origin) { rect in
                    let baseline = min(rect.maxY - 1, rect.minY + rect.height * 0.82)
                    let path = NSBezierPath()
                    path.lineWidth = mark.severity == .error ? 1.5 : 1.25
                    color.setStroke()
                    let step: CGFloat = 4
                    let amplitude: CGFloat = mark.severity == .information ? 0 : 1.25
                    var x = rect.minX
                    path.move(to: NSPoint(x: x, y: baseline))
                    var rises = true
                    while x < rect.maxX {
                        x = min(rect.maxX, x + step / 2)
                        path.line(to: NSPoint(
                            x: x, y: baseline + (rises ? amplitude : -amplitude)
                        ))
                        rises.toggle()
                    }
                    path.stroke()
                }
            }
        }
    }

    private func drawableCharacterRanges(in range: NSRange) -> [NSRange] {
        guard range.length > 0 else { return [] }
        var result: [NSRange] = []
        var location = range.location
        let end = NSMaxRange(range)
        for hidden in foldedCharacterRanges {
            guard hidden.location < end, NSMaxRange(hidden) > location else { continue }
            if hidden.location > location {
                result.append(NSRange(
                    location: location, length: min(end, hidden.location) - location
                ))
            }
            location = max(location, NSMaxRange(hidden))
            if location >= end { break }
        }
        if location < end {
            result.append(NSRange(location: location, length: end - location))
        }
        return result
    }

    private func enumerateRects(
        forCharacterRange characterRange: NSRange,
        origin: NSPoint,
        body: (NSRect) -> Void
    ) {
        guard characterRange.length > 0, let textContainer = textContainers.first else {
            return
        }
        let glyphRange = self.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            body(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    private func drawTabMarker(in rect: NSRect) {
        let left = rect.minX + min(2, rect.width * 0.12)
        let right = rect.maxX - min(2, rect.width * 0.12)
        guard right - left >= 3 else { return }
        let y = rect.midY
        let head = min(3.5, max(2, rect.height * 0.2))
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: left, y: y))
        path.line(to: NSPoint(x: right, y: y))
        path.move(to: NSPoint(x: right - head, y: y - head))
        path.line(to: NSPoint(x: right, y: y))
        path.line(to: NSPoint(x: right - head, y: y + head))
        path.stroke()
    }
}

/// NSTextView subclass used only for fixed-column rulers. `draw(_:)` receives
/// the viewport dirty rectangle, so ruler work is independent of document size.
@MainActor
private final class NativeTextView: NSTextView {
    fileprivate var completionEventHandler: ((NSEvent, NativeTextView) -> Bool)?
    fileprivate var completionDismissHandler: (() -> Void)?
    fileprivate var rectangularSelectionHandler: ((
        SelectionSet, Bool, SelectionSet, NativeTextView
    ) -> Void)?
    fileprivate var optionClickSelectionHandler: ((SelectionSet, NativeTextView) -> Void)?
    fileprivate var selectionDirectionAnchorProvider: (() -> [Int])?
    fileprivate var selectionDirectionAnchors: [Int]?
    fileprivate var isUpdatingMarkedText = false
    fileprivate weak var decorationLayoutManager: NativeTextEditorLayoutManager? {
        didSet { decorationLayoutManager?.attachTextView(self) }
    }
    fileprivate var decorationBackgroundColor = NSColor.textBackgroundColor
    fileprivate var rulerColor = NSColor.separatorColor
    fileprivate var rulerColumns: [Int] = [] {
        didSet {
            if oldValue != rulerColumns { needsDisplay = true }
        }
    }
    private var rectangularDragAnchor: RectangularSelectionPlanner.Position?
    private var rectangularDragInitialSelection: SelectionSet?
    private var rectangularDragAppends = false
    private var optionModifierIsDown = false
    private var rectangularMouseSequenceActive = false
    private var rectangularDragDidStart = false
    private var optionMouseDownLocation: NSPoint?
    private var rectangularEditorIdentity: RectangularEditorIdentity?

    private struct RectangularEditorIdentity: Equatable {
        let documentID: String
        let revision: UInt64
    }

    override func draw(_ dirtyRect: NSRect) {
        decorationLayoutManager?.beginZeroLengthFindHighlightDrawing()
        decorationBackgroundColor.setFill()
        dirtyRect.fill()
        drawColumnRulers(in: dirtyRect)
        decorationLayoutManager?.drawEmptyDocumentCurrentLine(in: self, dirtyRect: dirtyRect)
        super.draw(dirtyRect)
        // This is caret-like foreground content. Drawing it after NSTextView
        // prevents AppKit's normal background/selection pass from covering it.
        decorationLayoutManager?.drawEmptyDocumentFindHighlights(
            in: self, dirtyRect: dirtyRect
        )
        decorationLayoutManager?.drawPendingZeroLengthFindHighlights(in: self)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if completionEventHandler?(event, self) == true { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) {
            selectionDirectionAnchors = selectionDirectionAnchorProvider?()
        }
        defer { selectionDirectionAnchors = nil }
        super.keyDown(with: event)
    }

    override func setMarkedText(
        _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
        completionDismissHandler?()
        isUpdatingMarkedText = true
        defer { isUpdatingMarkedText = false }
        super.setMarkedText(
            string, selectedRange: selectedRange, replacementRange: replacementRange
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option),
              !hasMarkedText(),
              let anchor = rectangularPosition(for: event) else {
            rectangularDragAnchor = nil
            rectangularMouseSequenceActive = false
            rectangularDragDidStart = false
            optionMouseDownLocation = nil
            optionModifierIsDown = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask).contains(.option)
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            selectionDirectionAnchors = modifiers.contains(.shift)
                ? selectionDirectionAnchorProvider?()
                : selectionOffset(for: event).map { [$0] }
            defer { selectionDirectionAnchors = nil }
            super.mouseDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        optionModifierIsDown = true
        rectangularDragAnchor = anchor
        rectangularMouseSequenceActive = true
        rectangularDragDidStart = false
        optionMouseDownLocation = event.locationInWindow
        rectangularDragAppends = modifiers.contains(.command)
        rectangularDragInitialSelection = NativeTextEditorAdapter.selectionSet(
            fromAppKitRanges: selectedRanges.map(\.rangeValue),
            mainRange: selectedRange(), preserving: nil,
            utf16Length: (string as NSString).length
        )
        NSCursor.crosshair.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard rectangularMouseSequenceActive else {
            super.mouseDragged(with: event)
            return
        }
        guard let rectangularDragAnchor, let optionMouseDownLocation else {
            cancelRectangularSelection()
            return
        }
        guard !hasMarkedText(), let target = rectangularPosition(for: event) else {
            cancelRectangularSelection(endingMouseSequence: false)
            return
        }
        if !rectangularDragDidStart {
            guard NativeTextEditorAdapter.beginsRectangularSelectionDrag(
                from: optionMouseDownLocation,
                to: event.locationInWindow
            ) else { return }
            rectangularDragDidStart = true
        }
        updateRectangularSelection(from: rectangularDragAnchor, to: target)
        autoscroll(with: event)
        NSCursor.crosshair.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard rectangularMouseSequenceActive else {
            super.mouseUp(with: event)
            return
        }
        if rectangularDragDidStart,
           let target = rectangularPosition(for: event),
           let anchor = rectangularDragAnchor {
            updateRectangularSelection(from: anchor, to: target)
        } else if !hasMarkedText(),
                  let target = rectangularPosition(for: event),
                  let initialSelection = rectangularDragInitialSelection {
            optionClickSelectionHandler?(
                NativeTextEditorAdapter.optionClickSelection(
                    in: string,
                    at: target,
                    initialSelection: initialSelection,
                    tabWidth: rectangularTabWidth
                ),
                self
            )
        }
        cancelRectangularSelection()
    }

    private func updateRectangularSelection(to target: RectangularSelectionPlanner.Position) {
        updateRectangularSelection(from: target, to: target)
    }

    private func updateRectangularSelection(
        from anchor: RectangularSelectionPlanner.Position,
        to target: RectangularSelectionPlanner.Position
    ) {
        let plan = RectangularSelectionPlanner.plan(
            text: string, anchor: anchor, target: target,
            tabWidth: rectangularTabWidth
        )
        let initial = rectangularDragInitialSelection ?? plan.selection
        rectangularSelectionHandler?(
            plan.selection, rectangularDragAppends, initial, self
        )
    }

    fileprivate func cancelRectangularSelection(endingMouseSequence: Bool = true) {
        rectangularDragAnchor = nil
        rectangularDragInitialSelection = nil
        rectangularDragAppends = false
        rectangularDragDidStart = false
        optionMouseDownLocation = nil
        if endingMouseSequence { rectangularMouseSequenceActive = false }
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard optionKeyIsDown
        else { return }
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        optionModifierIsDown = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask).contains(.option)
        window?.invalidateCursorRects(for: self)
    }

    private var optionKeyIsDown: Bool {
        optionModifierIsDown || rectangularDragAnchor != nil
    }

    private func selectionOffset(for event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let length = (string as NSString).length
        let offset = characterIndexForInsertion(at: point)
        guard offset != NSNotFound else { return nil }
        return min(length, max(0, offset))
    }

    private func rectangularPosition(
        for event: NSEvent
    ) -> RectangularSelectionPlanner.Position? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: nil
        )
        let length = (string as NSString).length
        let offset = glyphIndex < layoutManager.numberOfGlyphs
            ? layoutManager.characterIndexForGlyph(at: glyphIndex)
            : length
        let base = RectangularSelectionPlanner.position(
            text: string, utf16Offset: offset, tabWidth: rectangularTabWidth
        )
        let font = self.font
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let width = max(1, (" " as NSString).size(withAttributes: [.font: font]).width)
        return RectangularSelectionPlanner.position(
            text: string, line: base.line, x: Double(containerPoint.x),
            characterWidth: Double(width)
        )
    }

    private var rectangularTabWidth: Int {
        guard let paragraph = defaultParagraphStyle else { return 4 }
        let font = self.font
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let width = max(1, (" " as NSString).size(withAttributes: [.font: font]).width)
        return min(16, max(1, Int((paragraph.defaultTabInterval / width).rounded())))
    }

    fileprivate func configureRectangularSelectionIdentity(
        documentID: String, revision: UInt64
    ) {
        let next = RectangularEditorIdentity(documentID: documentID, revision: revision)
        if let rectangularEditorIdentity, rectangularEditorIdentity != next {
            cancelRectangularSelection(endingMouseSequence: false)
        }
        rectangularEditorIdentity = next
    }

    private func drawColumnRulers(in dirtyRect: NSRect) {
        guard !rulerColumns.isEmpty else { return }
        let font = self.font
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let characterWidth = max(1, (" " as NSString).size(
            withAttributes: [.font: font]
        ).width)
        let contentOrigin = textContainerOrigin
        rulerColor.setFill()

        for column in rulerColumns {
            let x = contentOrigin.x + CGFloat(column) * characterWidth
            guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { continue }
            NSRect(
                x: floor(x),
                y: dirtyRect.minY,
                width: 1,
                height: dirtyRect.height
            ).fill()
        }
    }
}

@MainActor
final class FoldMarkerAccessibilityElement: NSAccessibilityElement {
    let markerID: String
    private(set) var markerFrameInParent: NSRect
    private(set) var isActive = true
    private let startLine: Int
    private let endLine: Int
    private let fullRange: NSRange
    private let hiddenRange: NSRange
    private let onPress: (FoldMarkerAccessibilityElement) -> Bool

    init(
        marker: NativeTextEditorVisualPlanner.FoldMarker,
        frameInParent: NSRect, parent: LineNumberRulerView,
        locale: EditorLocale,
        onPress: @escaping (FoldMarkerAccessibilityElement) -> Bool
    ) {
        markerID = marker.id
        markerFrameInParent = frameInParent
        startLine = marker.startLine
        endLine = marker.endLine
        fullRange = marker.fullRange
        hiddenRange = marker.hiddenRange
        self.onPress = onPress
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frameInParent)
        setAccessibilityIdentifier(
            NativeTextEditorAccessibility.foldMarkerIdentifier(marker)
        )
        setAccessibilityLabel(
            NativeTextEditorAccessibility.foldMarkerLabel(marker, locale: locale)
        )
        setAccessibilityValue(
            NativeTextEditorAccessibility.foldMarkerValue(marker, locale: locale)
        )
    }

    func update(
        marker: NativeTextEditorVisualPlanner.FoldMarker,
        frameInParent: NSRect, parent: LineNumberRulerView, locale: EditorLocale
    ) {
        precondition(represents(marker))
        isActive = true
        markerFrameInParent = frameInParent
        setAccessibilityHidden(false)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frameInParent)
        setAccessibilityIdentifier(
            NativeTextEditorAccessibility.foldMarkerIdentifier(marker)
        )
        setAccessibilityLabel(
            NativeTextEditorAccessibility.foldMarkerLabel(marker, locale: locale)
        )
        setAccessibilityValue(
            NativeTextEditorAccessibility.foldMarkerValue(marker, locale: locale)
        )
    }

    func deactivate() {
        isActive = false
        markerFrameInParent = .zero
        setAccessibilityHidden(true)
        setAccessibilityFrameInParentSpace(.zero)
        setAccessibilityParent(nil)
    }

    func represents(_ marker: NativeTextEditorVisualPlanner.FoldMarker) -> Bool {
        marker.id == markerID
            && marker.startLine == startLine
            && marker.endLine == endLine
            && marker.fullRange == fullRange
            && marker.hiddenRange == hiddenRange
    }

    override func accessibilityPerformPress() -> Bool {
        isActive && onPress(self)
    }
}

@MainActor
final class LineNumberRulerView: NSRulerView {
    fileprivate var palette = NativeEditorPalette.make(
        colorScheme: .dark,
        compatibleWith: .dark
    ) {
        didSet {
            if oldValue != palette { needsDisplay = true }
        }
    }
    private var lineStarts = [0]
    private var markers: [IncrementalDiffMarker] = []
    private var markerByLine: [Int: IncrementalDiffChangeKind] = [:]
    private var diagnosticMarkerByLine: [
        Int: NativeTextEditorVisualPlanner.DiagnosticSeverity
    ] = [:]
    private var foldedStartLines: Set<Int> = []
    private var foldMarkerPlan = NativeTextEditorVisualPlanner.FoldMarkerPlan(
        markers: [], markerByStartLine: [:]
    )
    private var foldMarkerRects: [String: NSRect] = [:]
    private var foldAccessibilityElements: [FoldMarkerAccessibilityElement] = []
    private var foldAccessibilityElementByMarkerID: [
        String: FoldMarkerAccessibilityElement
    ] = [:]
    private var foldMarkerGeometryIsValid = false
    private var foldMarkerGeometryBounds = NSRect.null
    private var foldAccessibilityNotificationIsPending = false
    private var foldLocale: EditorLocale = .zhCN
    private var onToggleFoldMarker: ((String) -> Bool)?
    private var showsLineNumbers = true
    private let boundsObserverToken = NativeTextEditorNotificationObserverBox()

    override init(scrollView: NSScrollView, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 40
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(NativeTextEditorAccessibility.foldGutterIdentifier)

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.viewportDidChange()
            }
        }
        boundsObserverToken.replace(with: observer)
    }

    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView does not support decoding")
    }

    fileprivate func stopObserving() {
        boundsObserverToken.clear()
    }

    func resetFoldMarkerAccessibilityCache() {
        foldAccessibilityElements.forEach { $0.deactivate() }
        foldAccessibilityElements.removeAll(keepingCapacity: false)
        for element in foldAccessibilityElementByMarkerID.values {
            element.deactivate()
        }
        foldAccessibilityElementByMarkerID.removeAll(keepingCapacity: false)
        foldMarkerRects.removeAll(keepingCapacity: false)
        foldMarkerPlan = .init(markers: [], markerByStartLine: [:])
        foldedStartLines.removeAll(keepingCapacity: false)
        onToggleFoldMarker = nil
        foldMarkerGeometryIsValid = false
        foldMarkerGeometryBounds = .null
    }

    private func viewportDidChange() {
        invalidateFoldMarkerGeometry(notifyAccessibility: true)
        needsDisplay = true
    }

    private func invalidateFoldMarkerGeometry(notifyAccessibility: Bool) {
        foldMarkerGeometryIsValid = false
        foldAccessibilityElements.forEach { $0.deactivate() }
        foldAccessibilityElements.removeAll(keepingCapacity: true)
        guard notifyAccessibility, !foldAccessibilityNotificationIsPending else { return }
        foldAccessibilityNotificationIsPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.foldAccessibilityNotificationIsPending = false
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    fileprivate func rebuildLineStarts() {
        guard let textView = clientView as? NSTextView else { return }
        let string = textView.string as NSString
        var starts = [0]
        var location = 0

        while location < string.length {
            var lineEnd = 0
            var contentsEnd = 0
            string.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            guard lineEnd > location else { break }
            if lineEnd < string.length || lineEnd > contentsEnd {
                starts.append(lineEnd)
            }
            location = lineEnd
        }

        lineStarts = starts
        invalidateFoldMarkerGeometry(notifyAccessibility: true)
        refreshAppearance(notifyAccessibility: false)
    }

    fileprivate func selectionDidChange() {
        needsDisplay = true
    }

    fileprivate func update(
        markers: [IncrementalDiffMarker], showsLineNumbers: Bool
    ) {
        guard self.markers != markers || self.showsLineNumbers != showsLineNumbers else {
            return
        }
        self.markers = markers
        self.showsLineNumbers = showsLineNumbers
        var byLine: [Int: IncrementalDiffChangeKind] = [:]
        for marker in markers {
            let upper = marker.line.addingReportingOverflow(marker.lineCount)
            let end = upper.overflow ? Int.max : upper.partialValue
            guard marker.line < end else { continue }
            for line in marker.line..<end { byLine[line] = marker.kind }
        }
        markerByLine = byLine
        refreshAppearance()
    }

    fileprivate func updateDiagnosticMarkers(
        _ markers: [Int: NativeTextEditorVisualPlanner.DiagnosticSeverity]
    ) {
        guard markers != diagnosticMarkerByLine else { return }
        diagnosticMarkerByLine = markers
        refreshAppearance()
    }

    func updateFoldMarkers(
        _ plan: NativeTextEditorVisualPlanner.FoldMarkerPlan,
        locale: EditorLocale,
        onToggle: ((String) -> Bool)?
    ) {
        let changed = plan != foldMarkerPlan || locale != foldLocale
        foldMarkerPlan = plan
        var markerByID: [String: NativeTextEditorVisualPlanner.FoldMarker] = [:]
        var ambiguousMarkerIDs: Set<String> = []
        for marker in plan.markers {
            if let existing = markerByID[marker.id],
               existing.startLine != marker.startLine
                || existing.endLine != marker.endLine
                || existing.fullRange != marker.fullRange
                || existing.hiddenRange != marker.hiddenRange {
                ambiguousMarkerIDs.insert(marker.id)
            } else {
                markerByID[marker.id] = marker
            }
        }
        let obsoleteMarkerIDs = foldAccessibilityElementByMarkerID.compactMap {
            markerID, element in
            guard !ambiguousMarkerIDs.contains(markerID),
                  let marker = markerByID[markerID],
                  element.represents(marker) else { return markerID }
            return nil
        }
        for markerID in obsoleteMarkerIDs {
            foldAccessibilityElementByMarkerID.removeValue(forKey: markerID)?.deactivate()
        }
        foldedStartLines = Set(plan.markers.lazy.filter(\.isFolded).map(\.startLine))
        foldLocale = locale
        onToggleFoldMarker = onToggle
        invalidateFoldMarkerGeometry(notifyAccessibility: changed)
        setAccessibilityLabel(NativeTextEditorAccessibility.foldGutterLabel(locale: locale))
        let visibleMarkers = plan.markerByStartLine.values
        setAccessibilityValue(NativeTextEditorAccessibility.foldGutterValue(
            markerCount: visibleMarkers.count,
            foldedCount: visibleMarkers.filter(\.isFolded).count,
            locale: locale
        ))
        if changed { refreshAppearance(notifyAccessibility: false) }
    }

    override func accessibilityChildren() -> [Any]? {
        refreshFoldMarkerGeometry()
        return foldAccessibilityElements
    }

    func foldMarkerAccessibilityElements() -> [FoldMarkerAccessibilityElement] {
        refreshFoldMarkerGeometry()
        return foldAccessibilityElements
    }

    func foldMarkerAccessibilityHitTest(inParent point: NSPoint)
        -> FoldMarkerAccessibilityElement? {
        refreshFoldMarkerGeometry()
        return foldAccessibilityElements.first(where: { element in
            element.markerFrameInParent.contains(point)
        })
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let windowPoint = window?.convertPoint(fromScreen: point) ?? point
        let localPoint = window == nil ? point : convert(windowPoint, from: nil)
        return foldMarkerAccessibilityHitTest(inParent: localPoint)
            ?? super.accessibilityHitTest(point)
    }

    fileprivate func refreshAppearance(notifyAccessibility: Bool = true) {
        guard let textView = clientView as? NSTextView else { return }
        invalidateFoldMarkerGeometry(notifyAccessibility: notifyAccessibility)
        let size = max(9, (textView.font?.pointSize ?? 14) - 2)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let digits = max(2, String(max(1, lineStarts.count)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 16
        let foldWidth: CGFloat = foldLaneWidth
        let desiredThickness = showsLineNumbers
            ? max(36 + foldWidth, width + 6 + foldWidth)
            : max(6, foldWidth)
        if abs(ruleThickness - desiredThickness) > 0.5 {
            ruleThickness = desiredThickness
            scrollView?.tile()
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        palette.gutterBackground.setFill()
        rect.fill()

        palette.ruler.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        layoutManager.ensureLayout(for: textContainer)
        let origin = textView.textContainerOrigin
        let containerVisibleRect = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: containerVisibleRect,
            in: textContainer
        )
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )

        let stringLength = (textView.string as NSString).length
        let firstVisibleLocation = min(stringLength, characterRange.location)
        let lastVisibleLocation = min(stringLength, NSMaxRange(characterRange))
        let firstLine = max(0, lineIndex(containing: firstVisibleLocation) - 1)
        let lastLine = min(lineStarts.count - 1, lineIndex(containing: lastVisibleLocation) + 1)

        let selectedRange = NativeTextEditor.clamped(
            textView.selectedRange(),
            toUTF16Length: stringLength
        )
        let firstSelectedLine = lineIndex(containing: selectedRange.location)
        let selectedEnd = selectedRange.length > 0
            ? selectedRange.location + selectedRange.length - 1
            : selectedRange.location
        let lastSelectedLine = lineIndex(containing: selectedEnd)

        let fontSize = max(9, (textView.font?.pointSize ?? 14) - 2)
        let regularFont = NSFont.monospacedDigitSystemFont(
            ofSize: fontSize,
            weight: .regular
        )
        let selectedFont = NSFont.monospacedDigitSystemFont(
            ofSize: fontSize,
            weight: .semibold
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        refreshFoldMarkerGeometry()

        guard firstLine <= lastLine else { return }
        for lineIndex in firstLine...lastLine {
            guard let fragmentRect = lineFragmentRect(
                forLineAt: lineIndex,
                stringLength: stringLength,
                textView: textView,
                layoutManager: layoutManager
            ) else { continue }

            let rulerRect = convert(fragmentRect, from: textView)
            guard rulerRect.maxY >= rect.minY, rulerRect.minY <= rect.maxY else { continue }

            if let kind = markerByLine[lineIndex + 1] {
                markerColor(for: kind).setFill()
                NSRect(
                    x: 1, y: rulerRect.minY, width: 4,
                    height: max(2, rulerRect.height)
                ).fill()
            }
            if let severity = diagnosticMarkerByLine[lineIndex + 1] {
                palette.diagnosticColor(for: severity).setFill()
                let size = max(4, min(7, rulerRect.height * 0.42))
                NSBezierPath(ovalIn: NSRect(
                    x: max(1, ruleThickness - foldLaneWidth - size - 2),
                    y: rulerRect.midY - size / 2, width: size, height: size
                )).fill()
            }
            if let marker = foldMarkerPlan.markerByStartLine[lineIndex + 1],
               let hitRect = foldMarkerRects[marker.id] {
                drawFoldMarker(marker, in: hitRect.insetBy(dx: 2, dy: 2))
            }
            guard showsLineNumbers else { continue }

            let isSelected = lineIndex >= firstSelectedLine && lineIndex <= lastSelectedLine
            let font = isSelected ? selectedFont : regularFont
            let color = isSelected ? palette.foreground : palette.gutterForeground
            let labelHeight = ceil(font.ascender - font.descender + font.leading)
            let labelRect = NSRect(
                x: 7,
                y: rulerRect.minY + floor((rulerRect.height - labelHeight) / 2),
                width: max(0, ruleThickness - 15 - foldLaneWidth),
                height: labelHeight
            )
            (String(lineIndex + 1) as NSString).draw(
                in: labelRect,
                withAttributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle
                ]
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard activateFoldMarkerForPointer(at: point) != nil else {
            super.mouseDown(with: event)
            return
        }
    }

    /// Deterministic test/accessibility activation that follows the same exact
    /// region-ID callback as a pointer click.
    @discardableResult
    func activateFoldMarker(id: String) -> Bool {
        guard let marker = visibleFoldMarkers.first(where: { $0.id == id }) else {
            return false
        }
        return performToggle(marker)
    }

    private func activateFoldMarker(
        fromAccessibilityElement element: FoldMarkerAccessibilityElement
    ) -> Bool {
        guard element.isActive,
              foldAccessibilityElementByMarkerID[element.markerID] === element,
              foldAccessibilityElements.contains(where: { $0 === element }),
              let marker = visibleFoldMarkers.first(where: {
                $0.id == element.markerID && element.represents($0)
              }) else { return false }
        return performToggle(marker)
    }

    private func performToggle(
        _ marker: NativeTextEditorVisualPlanner.FoldMarker
    ) -> Bool {
        guard onToggleFoldMarker?(marker.id) == true else { return false }
        let updated = NativeTextEditorVisualPlanner.FoldMarker(
            id: marker.id, startLine: marker.startLine, endLine: marker.endLine,
            fullRange: marker.fullRange, hiddenRange: marker.hiddenRange,
            isFolded: !marker.isFolded
        )
        let markers = foldMarkerPlan.markers.map {
            $0.id == marker.id ? updated : $0
        }
        let byLine = NativeTextEditorVisualPlanner.markerByStartLine(for: markers)
        foldMarkerPlan = .init(markers: markers, markerByStartLine: byLine)
        foldedStartLines = Set(markers.lazy.filter(\.isFolded).map(\.startLine))
        invalidateFoldMarkerGeometry(notifyAccessibility: true)
        let visibleMarkers = byLine.values
        setAccessibilityValue(NativeTextEditorAccessibility.foldGutterValue(
            markerCount: visibleMarkers.count,
            foldedCount: visibleMarkers.filter(\.isFolded).count, locale: foldLocale
        ))
        needsDisplay = true
        AppAccessibility.announce(
            NativeTextEditorAccessibility.foldActionAnnouncement(
                marker: marker, willFold: !marker.isFolded, locale: foldLocale
            )
        )
        return true
    }

    private var visibleFoldMarkers: [NativeTextEditorVisualPlanner.FoldMarker] {
        foldMarkerPlan.markerByStartLine.values.sorted { left, right in
            if left.startLine != right.startLine { return left.startLine < right.startLine }
            return left.id < right.id
        }
    }

    private func refreshFoldMarkerGeometry() {
        guard !foldMarkerGeometryIsValid || foldMarkerGeometryBounds != bounds else { return }
        foldMarkerRects.removeAll(keepingCapacity: true)
        foldAccessibilityElements.forEach { $0.deactivate() }
        foldAccessibilityElements.removeAll(keepingCapacity: true)
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let stringLength = (textView.string as NSString).length
        let visibleRect = bounds
        for marker in visibleFoldMarkers {
            let lineIndex = marker.startLine - 1
            guard lineStarts.indices.contains(lineIndex),
                  let fragmentRect = lineFragmentRect(
                    forLineAt: lineIndex, stringLength: stringLength,
                    textView: textView, layoutManager: layoutManager
                  ) else { continue }
            let rulerRect = convert(fragmentRect, from: textView)
            guard rulerRect.maxY >= visibleRect.minY,
                  rulerRect.minY <= visibleRect.maxY else { continue }
            let markerSize = max(9, min(13, rulerRect.height * 0.72))
            let markerRect = NSRect(
                x: max(6, ruleThickness - markerSize - 3),
                y: rulerRect.midY - markerSize / 2,
                width: markerSize, height: markerSize
            ).insetBy(dx: -2, dy: -2)
            foldMarkerRects[marker.id] = markerRect
            let element: FoldMarkerAccessibilityElement
            if let existing = foldAccessibilityElementByMarkerID[marker.id],
               existing.represents(marker) {
                existing.update(
                    marker: marker, frameInParent: markerRect, parent: self,
                    locale: foldLocale
                )
                element = existing
            } else {
                foldAccessibilityElementByMarkerID.removeValue(
                    forKey: marker.id
                )?.deactivate()
                element = FoldMarkerAccessibilityElement(
                    marker: marker, frameInParent: markerRect, parent: self,
                    locale: foldLocale, onPress: { [weak self] element in
                        self?.activateFoldMarker(
                            fromAccessibilityElement: element
                        ) ?? false
                    }
                )
                foldAccessibilityElementByMarkerID[marker.id] = element
            }
            foldAccessibilityElements.append(element)
        }
        foldMarkerGeometryBounds = bounds
        foldMarkerGeometryIsValid = true
    }

    private func marker(at point: NSPoint)
        -> NativeTextEditorVisualPlanner.FoldMarker? {
        refreshFoldMarkerGeometry()
        return visibleFoldMarkers.first(where: { marker in
            foldMarkerRects[marker.id]?.contains(point) == true
        })
    }

    private func activateFoldMarkerForPointer(at point: NSPoint) -> Bool? {
        guard let marker = marker(at: point) else { return nil }
        if !performToggle(marker) {
            NSSound.beep()
        }
        return true
    }

    @discardableResult
    func activateFoldMarker(at point: NSPoint) -> Bool {
        guard let marker = marker(at: point) else { return false }
        return performToggle(marker)
    }

    private func drawFoldMarker(
        _ marker: NativeTextEditorVisualPlanner.FoldMarker, in rect: NSRect
    ) {
        let color = palette.gutterForeground
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        if marker.isFolded {
            path.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 2))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 2))
        } else {
            path.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 3))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 3))
        }
        path.close()
        path.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 2, yRadius: 2)
            border.lineWidth = 1
            border.stroke()
        }
    }

    private func markerColor(
        for kind: IncrementalDiffChangeKind
    ) -> NSColor {
        switch kind {
        case .added: palette.diffAdded
        case .modified: palette.diffModified
        case .deleted: palette.diffDeleted
        }
    }

    private func lineIndex(containing location: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if lineStarts[middle] <= location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(0, lowerBound - 1)
    }

    private func lineFragmentRect(
        forLineAt lineIndex: Int,
        stringLength: Int,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) -> NSRect? {
        let characterIndex = lineStarts[lineIndex]
        var containerRect: NSRect

        if characterIndex < stringLength, layoutManager.numberOfGlyphs > 0 {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
            containerRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            if containerRect.isEmpty, foldedStartLines.contains(lineIndex + 1),
               let marker = foldMarkerPlan.markerByStartLine[lineIndex + 1] {
                let anchor = max(
                    marker.fullRange.location, min(
                        max(0, stringLength - 1), marker.hiddenRange.location - 1
                    )
                )
                let anchorGlyph = layoutManager.glyphIndexForCharacter(at: anchor)
                guard anchorGlyph < layoutManager.numberOfGlyphs else { return nil }
                containerRect = layoutManager.lineFragmentRect(
                    forGlyphAt: anchorGlyph, effectiveRange: nil
                )
            }
        } else {
            let extraRect = layoutManager.extraLineFragmentRect
            if !extraRect.isEmpty {
                containerRect = extraRect
            } else {
                let font = textView.font
                    ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                containerRect = NSRect(
                    x: 0,
                    y: layoutManager.usedRect(for: textView.textContainer!).maxY,
                    width: max(1, textView.textContainer!.containerSize.width),
                    height: layoutManager.defaultLineHeight(for: font)
                )
            }
        }

        return containerRect.offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
    }

    private var foldLaneWidth: CGFloat {
        foldMarkerPlan.markers.isEmpty ? 0 : 18
    }
}
