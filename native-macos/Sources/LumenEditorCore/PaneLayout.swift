import Foundation

/// The layout vocabulary shared with the version-two window-session schema.
public typealias PaneLayoutKind = WindowSessionLayoutKind

/// In-memory editor-pane and tab state for one window.
///
/// Documents remain shared buffers outside this value. This type owns only
/// pane membership, focus, tab ordering and a separate selection value for
/// every `(pane, document)` view.
public struct PaneLayout: Equatable, Sendable {
    public typealias Kind = WindowSessionLayoutKind

    public enum TabDropPosition: Equatable, Sendable {
        case before
        case after
    }

    /// One editor pane. `viewID` identifies the pane rather than its active
    /// document, so it remains stable while tabs are switched.
    public struct Pane: Identifiable, Equatable, Sendable {
        fileprivate enum RemovalSelection {
            case first
            case adjacent
        }

        public let viewID: EditorViewID
        public private(set) var documentIDs: [String]
        public private(set) var activeDocumentID: String?
        public private(set) var selectionsByDocumentID: [String: SelectionSet]

        public var id: EditorViewID { viewID }
        public var docIDs: [String] { documentIDs }
        public var selections: [String: SelectionSet] { selectionsByDocumentID }
        public var selection: SelectionSet? { activeSelection }
        public var isEmpty: Bool { documentIDs.isEmpty }

        public var activeSelection: SelectionSet? {
            activeDocumentID.flatMap { selectionsByDocumentID[$0] }
        }

        public init(
            viewID: EditorViewID,
            documentIDs: [String] = [],
            activeDocumentID: String? = nil,
            selectionsByDocumentID: [String: SelectionSet] = [:]
        ) {
            precondition(!viewID.rawValue.isEmpty, "A pane view ID cannot be empty")
            let orderedIDs = Self.orderedUnique(documentIDs)
            precondition(
                orderedIDs.allSatisfy { !$0.isEmpty },
                "A pane document ID cannot be empty"
            )

            self.viewID = viewID
            self.documentIDs = orderedIDs
            if let activeDocumentID, orderedIDs.contains(activeDocumentID) {
                self.activeDocumentID = activeDocumentID
            } else {
                self.activeDocumentID = orderedIDs.first
            }

            var normalizedSelections: [String: SelectionSet] = [:]
            normalizedSelections.reserveCapacity(orderedIDs.count)
            for documentID in orderedIDs {
                normalizedSelections[documentID] =
                    selectionsByDocumentID[documentID] ?? .cursor(at: 0)
            }
            self.selectionsByDocumentID = normalizedSelections
        }

        public init(
            viewID: EditorViewID,
            documentIDs: [String],
            activeDocumentID: String? = nil,
            selection: SelectionSet
        ) {
            var selections: [String: SelectionSet] = [:]
            for documentID in documentIDs { selections[documentID] = selection }
            self.init(
                viewID: viewID,
                documentIDs: documentIDs,
                activeDocumentID: activeDocumentID,
                selectionsByDocumentID: selections
            )
        }

        public func contains(_ documentID: String) -> Bool {
            documentIDs.contains(documentID)
        }

        public func selection(for documentID: String) -> SelectionSet? {
            selectionsByDocumentID[documentID]
        }

        @discardableResult
        fileprivate mutating func insert(
            _ documentID: String,
            selection: SelectionSet,
            activate: Bool
        ) -> Bool {
            precondition(!documentID.isEmpty, "A pane document ID cannot be empty")
            let inserted: Bool
            if documentIDs.contains(documentID) {
                inserted = false
            } else {
                documentIDs.append(documentID)
                selectionsByDocumentID[documentID] = selection
                inserted = true
            }
            if activate || activeDocumentID == nil {
                activeDocumentID = documentID
            }
            return inserted
        }

        @discardableResult
        fileprivate mutating func activate(_ documentID: String) -> Bool {
            guard documentIDs.contains(documentID) else { return false }
            activeDocumentID = documentID
            return true
        }

        @discardableResult
        fileprivate mutating func setSelection(
            _ selection: SelectionSet,
            for documentID: String
        ) -> Bool {
            guard documentIDs.contains(documentID) else { return false }
            selectionsByDocumentID[documentID] = selection
            return true
        }

        @discardableResult
        fileprivate mutating func remove(
            _ documentID: String,
            selecting replacement: RemovalSelection
        ) -> SelectionSet? {
            guard let index = documentIDs.firstIndex(of: documentID) else { return nil }
            documentIDs.remove(at: index)
            let selection = selectionsByDocumentID.removeValue(forKey: documentID)
            if activeDocumentID == documentID {
                switch replacement {
                case .first:
                    // Moving the active tab selects the source's first tab.
                    activeDocumentID = documentIDs.first
                case .adjacent:
                    // Closing selects the successor at the removed index, or
                    // the preceding final tab when there is no successor.
                    activeDocumentID = documentIDs.isEmpty ? nil
                        : documentIDs[min(index, documentIDs.count - 1)]
                }
            }
            return selection
        }

        fileprivate mutating func replaceOrder(with orderedIDs: [String]) {
            precondition(
                orderedIDs.count == documentIDs.count
                    && Set(orderedIDs) == Set(documentIDs),
                "A reordered tab list must contain exactly the pane's documents"
            )
            documentIDs = orderedIDs
        }

        private static func orderedUnique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
    }

    /// Compatibility vocabulary for call sites ported directly from Electron.
    public typealias Group = Pane

    public private(set) var kind: Kind
    public private(set) var panes: [Pane]
    public private(set) var activePaneIndex: Int

    /// Ctrl/Cmd-click tab selection is window-global in the Electron app.
    public private(set) var selectedDocumentIDs: Set<String>

    /// Includes both live and retired IDs so destroying and recreating a pane
    /// within this model instance cannot reconnect it to old view history. A
    /// caller rebuilding the model around live buffers must supply fresh IDs.
    private var usedViewIDs: Set<EditorViewID>

    /// Electron keeps a document's group state after its tab membership is
    /// removed. Mirror that behavior for the lifetime of this layout so adding
    /// the same document back to the same pane restores its last selection.
    private var retainedSelectionsByViewID: [EditorViewID: [String: SelectionSet]]

    public var layoutKind: Kind { kind }
    public var groups: [Pane] { panes }
    public var activeGroup: Int { activePaneIndex }
    public var activePane: Pane { panes[activePaneIndex] }
    public var activeViewID: EditorViewID { activePane.viewID }
    public var activeDocumentID: String? { activePane.activeDocumentID }
    public var selectedTabIDs: Set<String> { selectedDocumentIDs }

    /// Unique document references in first pane/tab encounter order.
    public var orderedDocumentIDs: [String] {
        var seen = Set<String>()
        return panes.flatMap(\.documentIDs).filter { seen.insert($0).inserted }
    }

    public var referencedDocumentIDs: Set<String> { Set(orderedDocumentIDs) }

    public func referenceCount(for documentID: String) -> Int {
        panes.reduce(into: 0) { count, pane in
            if pane.contains(documentID) { count += 1 }
        }
    }

    public func isDocumentReferenced(_ documentID: String) -> Bool {
        panes.contains { $0.contains(documentID) }
    }

    /// Construct a normal window, then grow it using the same active-document
    /// seeding rule as Electron's `setLayout`.
    public init(
        kind: Kind = .single,
        documentIDs: [String] = [],
        activeDocumentID: String? = nil,
        selection: SelectionSet = .cursor(at: 0),
        primaryViewID: EditorViewID = .default
    ) {
        var selections: [String: SelectionSet] = [:]
        for documentID in documentIDs { selections[documentID] = selection }
        let primary = Pane(
            viewID: primaryViewID,
            documentIDs: documentIDs,
            activeDocumentID: activeDocumentID,
            selectionsByDocumentID: selections
        )
        self.kind = .single
        self.panes = [primary]
        self.activePaneIndex = 0
        self.selectedDocumentIDs = []
        self.usedViewIDs = [primaryViewID]
        self.retainedSelectionsByViewID = [:]
        setLayout(kind)
    }

    /// Construct an explicit layout, useful for restoration and deterministic
    /// tests. Programmatic callers are expected to supply a valid pane count
    /// and distinct stable view IDs.
    public init(
        kind: Kind,
        panes: [Pane],
        activePaneIndex: Int = 0,
        selectedDocumentIDs: Set<String> = []
    ) {
        precondition(
            panes.count == kind.groupCount,
            "The pane count must match the selected layout kind"
        )
        precondition(
            panes.indices.contains(activePaneIndex),
            "The active pane index is out of range"
        )
        let viewIDs = panes.map(\.viewID)
        precondition(
            Set(viewIDs).count == viewIDs.count,
            "Every pane must have a distinct view ID"
        )

        self.kind = kind
        self.panes = panes
        self.activePaneIndex = activePaneIndex
        self.usedViewIDs = Set(viewIDs)
        self.retainedSelectionsByViewID = [:]
        let referenced = Set(panes.flatMap(\.documentIDs))
        self.selectedDocumentIDs = selectedDocumentIDs.intersection(referenced)
    }

    /// Restore tab membership and focus from a version-two session layout.
    /// Selection dictionaries are supplied separately because the persisted
    /// view records live on `WindowSessionDocument`, not on its layout groups.
    public init(
        windowSessionLayout layout: WindowSessionLayout,
        viewIDs: [EditorViewID]? = nil,
        selectionsByGroup: [Int: [String: SelectionSet]] = [:]
    ) {
        precondition(
            layout.groups.count == layout.kind.groupCount,
            "The session group count must match its layout kind"
        )
        precondition(
            layout.groups.indices.contains(layout.activeGroup),
            "The session active group is out of range"
        )

        var assignedViewIDs = viewIDs ?? []
        if let viewIDs {
            precondition(
                viewIDs.count == layout.groups.count,
                "Restored view IDs must match the session group count"
            )
            precondition(
                Set(viewIDs).count == viewIDs.count
                    && viewIDs.allSatisfy { !$0.rawValue.isEmpty },
                "Restored view IDs must be non-empty and distinct"
            )
        } else {
            assignedViewIDs.reserveCapacity(layout.groups.count)
            var used = Set<EditorViewID>()
            for index in layout.groups.indices {
                let viewID: EditorViewID
                if index == 0 {
                    viewID = .default
                } else {
                    viewID = Self.uniqueViewID(excluding: used)
                }
                assignedViewIDs.append(viewID)
                used.insert(viewID)
            }
        }

        let restoredPanes = layout.groups.indices.map { index in
            let group = layout.groups[index]
            return Pane(
                viewID: assignedViewIDs[index],
                documentIDs: group.documentIDs,
                activeDocumentID: group.activeDocumentID,
                selectionsByDocumentID: selectionsByGroup[index] ?? [:]
            )
        }
        self.init(
            kind: layout.kind,
            panes: restoredPanes,
            activePaneIndex: layout.activeGroup
        )
    }

    public init(
        sessionLayout: WindowSessionLayout,
        viewIDs: [EditorViewID]? = nil,
        selectionsByGroup: [Int: [String: SelectionSet]] = [:]
    ) {
        self.init(
            windowSessionLayout: sessionLayout,
            viewIDs: viewIDs,
            selectionsByGroup: selectionsByGroup
        )
    }

    public static func == (left: PaneLayout, right: PaneLayout) -> Bool {
        left.kind == right.kind
            && left.panes == right.panes
            && left.activePaneIndex == right.activePaneIndex
            && left.selectedDocumentIDs == right.selectedDocumentIDs
            && left.usedViewIDs == right.usedViewIDs
            && left.retainedSelectionsByViewID == right.retainedSelectionsByViewID
    }

    /// Change the pane count while retaining all distinct document references.
    /// Removed panes are merged into pane zero from the tail inward, matching
    /// Electron's observable ordering. Empty panes are seeded with the document
    /// active before the change.
    @discardableResult
    public mutating func setLayout(_ newKind: Kind) -> Bool {
        let previousKind = kind
        let previousPanes = panes
        let previousActivePaneIndex = activePaneIndex
        let previousSelection = selectedDocumentIDs
        let seedDocumentID = activeDocumentID
        let seedSelection = seedDocumentID.flatMap {
            panes[activePaneIndex].selection(for: $0)
        }
        let requiredCount = newKind.groupCount

        while panes.count > requiredCount {
            let removed = panes.removeLast()
            merge(removed, intoPaneAt: 0)
            retainedSelectionsByViewID.removeValue(forKey: removed.viewID)
        }
        while panes.count < requiredCount {
            let viewID = makeUniqueViewID()
            panes.append(Pane(
                viewID: viewID,
                documentIDs: seedDocumentID.map { [$0] } ?? [],
                activeDocumentID: seedDocumentID,
                selectionsByDocumentID: seedDocumentID.map {
                    [$0: seedSelection ?? .cursor(at: 0)]
                } ?? [:]
            ))
        }

        if let seedDocumentID {
            for index in panes.indices where panes[index].isEmpty {
                insert(
                    seedDocumentID,
                    intoPaneAt: index,
                    selection: seedSelection ?? .cursor(at: 0),
                    activate: true
                )
            }
        }

        kind = newKind
        activePaneIndex = min(activePaneIndex, panes.count - 1)
        selectedDocumentIDs.formIntersection(referencedDocumentIDs)
        return previousKind != kind
            || previousPanes != panes
            || previousActivePaneIndex != activePaneIndex
            || previousSelection != selectedDocumentIDs
    }

    @discardableResult
    public mutating func changeLayout(to newKind: Kind) -> Bool {
        setLayout(newKind)
    }

    /// Electron's legacy split shortcut toggles only two-column layout.
    @discardableResult
    public mutating func toggleSplitEditor() -> Bool {
        setLayout(kind == .columns2 ? .single : .columns2)
    }

    /// Add a tab without allowing duplicate membership in the target pane.
    @discardableResult
    public mutating func addDocument(
        _ documentID: String,
        toPaneAt paneIndex: Int? = nil,
        selection: SelectionSet? = nil,
        activate: Bool = true
    ) -> Bool {
        let index = paneIndex ?? activePaneIndex
        guard panes.indices.contains(index), !documentID.isEmpty else { return false }
        insert(
            documentID,
            intoPaneAt: index,
            selection: selection ?? .cursor(at: 0),
            preferRetainedSelection: selection == nil,
            activate: activate
        )
        if activate { activePaneIndex = index }
        return true
    }

    /// Remove one pane's reference without deciding the lifetime of the shared
    /// document buffer. Call `referenceCount(for:)` afterwards to make that
    /// application-level decision.
    @discardableResult
    public mutating func removeDocument(
        _ documentID: String,
        fromPaneAt paneIndex: Int
    ) -> Bool {
        guard panes.indices.contains(paneIndex),
              let selection = panes[paneIndex].remove(
                  documentID,
                  selecting: .adjacent
              ) else {
            return false
        }
        retain(selection, for: documentID, inPaneAt: paneIndex)
        if !isDocumentReferenced(documentID) {
            discardRetainedSelections(for: documentID)
        }
        // Tab selection is global in Electron; closing one occurrence clears
        // the selected decoration from every pane that clones the document.
        selectedDocumentIDs.remove(documentID)
        return true
    }

    @discardableResult
    public mutating func removeDocument(
        documentID: String,
        fromPaneAt paneIndex: Int
    ) -> Bool {
        removeDocument(documentID, fromPaneAt: paneIndex)
    }

    /// Remove every pane membership for a document while leaving the pane
    /// count and pane identities intact. Empty panes remain valid.
    @discardableResult
    public mutating func removeDocumentEverywhere(_ documentID: String) -> Bool {
        var removed = false
        for index in panes.indices where panes[index].contains(documentID) {
            panes[index].remove(documentID, selecting: .adjacent)
            removed = true
        }
        if removed {
            selectedDocumentIDs.remove(documentID)
            discardRetainedSelections(for: documentID)
        }
        return removed
    }

    @discardableResult
    public mutating func removeDocumentEverywhere(documentID: String) -> Bool {
        removeDocumentEverywhere(documentID)
    }

    /// Activate an existing tab and its pane.
    @discardableResult
    public mutating func activate(
        documentID: String,
        inPaneAt paneIndex: Int,
        selection: SelectionSet? = nil
    ) -> Bool {
        guard panes.indices.contains(paneIndex), !documentID.isEmpty else { return false }
        insert(
            documentID,
            intoPaneAt: paneIndex,
            selection: selection ?? .cursor(at: 0),
            preferRetainedSelection: selection == nil,
            activate: true
        )
        activePaneIndex = paneIndex
        return true
    }

    @discardableResult
    public mutating func activate(
        documentID: String,
        inGroup groupIndex: Int,
        selection: SelectionSet? = nil
    ) -> Bool {
        activate(
            documentID: documentID,
            inPaneAt: groupIndex,
            selection: selection
        )
    }

    /// User tab activation also clears the global multi-tab selection.
    @discardableResult
    public mutating func selectTab(
        documentID: String,
        inPaneAt paneIndex: Int
    ) -> Bool {
        guard panes.indices.contains(paneIndex),
              panes[paneIndex].contains(documentID),
              activate(documentID: documentID, inPaneAt: paneIndex) else { return false }
        selectedDocumentIDs.removeAll()
        return true
    }

    @discardableResult
    public mutating func setSelection(
        _ selection: SelectionSet,
        forDocumentID documentID: String,
        inPaneAt paneIndex: Int
    ) -> Bool {
        guard panes.indices.contains(paneIndex) else { return false }
        return panes[paneIndex].setSelection(selection, for: documentID)
    }

    public func selection(
        forDocumentID documentID: String,
        inPaneAt paneIndex: Int
    ) -> SelectionSet? {
        guard panes.indices.contains(paneIndex) else { return nil }
        return panes[paneIndex].selection(for: documentID)
    }

    @discardableResult
    public mutating func focusPane(at index: Int) -> Bool {
        guard panes.indices.contains(index) else { return false }
        activePaneIndex = index
        return true
    }

    @discardableResult
    public mutating func focusGroup(_ index: Int) -> Bool {
        focusPane(at: index)
    }

    @discardableResult
    public mutating func focusNextPane() -> Bool {
        let previous = activePaneIndex
        activePaneIndex = (activePaneIndex + 1) % panes.count
        return activePaneIndex != previous
    }

    @discardableResult
    public mutating func focusPreviousPane() -> Bool {
        let previous = activePaneIndex
        activePaneIndex = (activePaneIndex - 1 + panes.count) % panes.count
        return activePaneIndex != previous
    }

    @discardableResult
    public mutating func focusNextGroup() -> Bool { focusNextPane() }

    @discardableResult
    public mutating func focusPreviousGroup() -> Bool { focusPreviousPane() }

    /// Move the active tab to the next pane, creating a two-column split first
    /// when necessary. The target's existing tab and selection win if present.
    @discardableResult
    public mutating func moveActiveToNextPane() -> Bool {
        transferActiveToNextPane(removingFromSource: true)
    }

    @discardableResult
    public mutating func moveActiveToNextGroup() -> Bool {
        moveActiveToNextPane()
    }

    @discardableResult
    public mutating func moveActiveDocumentToNextPane() -> Bool {
        moveActiveToNextPane()
    }

    @discardableResult
    public mutating func moveActiveDocumentToNextGroup() -> Bool {
        moveActiveToNextPane()
    }

    /// Clone only pane membership and value-type view state; the shared
    /// document buffer itself remains owned by the caller.
    @discardableResult
    public mutating func cloneActiveToNextPane() -> Bool {
        transferActiveToNextPane(removingFromSource: false)
    }

    @discardableResult
    public mutating func cloneActiveToNextGroup() -> Bool {
        cloneActiveToNextPane()
    }

    @discardableResult
    public mutating func cloneActiveDocumentToNextPane() -> Bool {
        cloneActiveToNextPane()
    }

    @discardableResult
    public mutating func cloneActiveDocumentToNextGroup() -> Bool {
        cloneActiveToNextPane()
    }

    public mutating func selectTabs<S: Sequence>(_ documentIDs: S)
    where S.Element == String {
        selectedDocumentIDs = Set(documentIDs).intersection(referencedDocumentIDs)
    }

    @discardableResult
    public mutating func toggleTabSelection(_ documentID: String) -> Bool {
        guard referencedDocumentIDs.contains(documentID) else { return false }
        if selectedDocumentIDs.contains(documentID) {
            selectedDocumentIDs.remove(documentID)
        } else {
            selectedDocumentIDs.insert(documentID)
        }
        return selectedDocumentIDs.contains(documentID)
    }

    public mutating func clearTabSelection() {
        selectedDocumentIDs.removeAll()
    }

    /// Split selected tabs in the active pane, using that pane's tab order.
    /// At most four tabs can be displayed; additional selections remain in
    /// their existing panes and are not lost. Fewer than two selected tabs use
    /// the same active-document clone fallback as Electron.
    @discardableResult
    public mutating func splitSelectedTabs() -> Bool {
        let sourceIndex = activePaneIndex
        let source = panes[sourceIndex]
        let orderedSelection = source.documentIDs.filter {
            selectedDocumentIDs.contains($0)
        }
        guard orderedSelection.count >= 2 else {
            return cloneActiveToNextPane()
        }

        let splitIDs = Array(orderedSelection.prefix(4))
        let sourceSelections = source.selectionsByDocumentID
        let newKind: Kind
        switch splitIDs.count {
        case 2: newKind = .columns2
        case 3: newKind = .columns3
        default: newKind = .grid4
        }
        setLayout(newKind)

        for (index, documentID) in splitIDs.enumerated() {
            insert(
                documentID,
                intoPaneAt: index,
                selection: sourceSelections[documentID] ?? .cursor(at: 0),
                preferRetainedSelection: true,
                activate: true
            )
        }
        activePaneIndex = 0
        selectedDocumentIDs.removeAll()
        return true
    }

    @discardableResult
    public mutating func splitSelectedTabs<S: Sequence>(_ documentIDs: S) -> Bool
    where S.Element == String {
        selectTabs(documentIDs)
        return splitSelectedTabs()
    }

    /// Reorder a dragged tab, or the active pane's selected block when the
    /// dragged tab is selected. Relative order inside the block is retained.
    @discardableResult
    public mutating func reorderTabs(
        inPaneAt paneIndex: Int,
        draggedDocumentID: String,
        relativeTo targetDocumentID: String? = nil,
        position: TabDropPosition = .before
    ) -> Bool {
        guard panes.indices.contains(paneIndex),
              panes[paneIndex].contains(draggedDocumentID) else { return false }

        let current = panes[paneIndex].documentIDs
        let moving = selectedDocumentIDs.contains(draggedDocumentID)
            ? current.filter { selectedDocumentIDs.contains($0) }
            : [draggedDocumentID]
        if let targetDocumentID, moving.contains(targetDocumentID) { return false }

        let movingSet = Set(moving)
        var remaining = current.filter { !movingSet.contains($0) }
        var insertionIndex = remaining.count
        if let targetDocumentID,
           let targetIndex = remaining.firstIndex(of: targetDocumentID) {
            insertionIndex = targetIndex + (position == .after ? 1 : 0)
        }
        remaining.insert(contentsOf: moving, at: insertionIndex)
        panes[paneIndex].replaceOrder(with: remaining)
        selectedDocumentIDs = movingSet
        return true
    }

    /// Stable-partition every tab row so pinned documents lead without
    /// disturbing the relative order inside either partition.
    public mutating func organizePinnedTabs(_ pinnedDocumentIDs: Set<String>) {
        for index in panes.indices {
            let current = panes[index].documentIDs
            let pinned = current.filter { pinnedDocumentIDs.contains($0) }
            let unpinned = current.filter { !pinnedDocumentIDs.contains($0) }
            panes[index].replaceOrder(with: pinned + unpinned)
        }
    }

    /// Set an exact tab order while rejecting missing, duplicated or foreign
    /// IDs. This is useful for non-drag UI adapters.
    @discardableResult
    public mutating func reorderTabs(
        inPaneAt paneIndex: Int,
        to documentIDs: [String]
    ) -> Bool {
        guard panes.indices.contains(paneIndex),
              documentIDs.count == panes[paneIndex].documentIDs.count,
              Set(documentIDs).count == documentIDs.count,
              Set(documentIDs) == Set(panes[paneIndex].documentIDs) else { return false }
        panes[paneIndex].replaceOrder(with: documentIDs)
        return true
    }

    @discardableResult
    public mutating func cycleActiveTab(by delta: Int) -> String? {
        let paneIndex = activePaneIndex
        let documents = panes[paneIndex].documentIDs
        guard !documents.isEmpty else { return nil }
        let currentIndex = panes[paneIndex].activeDocumentID
            .flatMap { documents.firstIndex(of: $0) } ?? 0
        let offset = delta % documents.count
        let nextIndex: Int
        if offset >= 0 {
            nextIndex = (currentIndex + offset) % documents.count
        } else {
            // Avoid overflowing when callers pass `Int.min`.
            let magnitude = -(offset + 1) + 1
            nextIndex = (currentIndex - (magnitude % documents.count)
                + documents.count) % documents.count
        }
        let documentID = documents[nextIndex]
        panes[paneIndex].activate(documentID)
        return documentID
    }

    @discardableResult
    public mutating func selectNextTab() -> String? { cycleActiveTab(by: 1) }

    @discardableResult
    public mutating func selectPreviousTab() -> String? { cycleActiveTab(by: -1) }

    /// Stable, lossless mapping of pane order, tab order and focus into the
    /// version-two persistence DTO. View IDs and selections intentionally live
    /// outside `WindowSessionLayout`.
    public func toWindowSessionLayout() -> WindowSessionLayout {
        WindowSessionLayout(
            kind: kind,
            activeGroup: activePaneIndex,
            groups: panes.map { pane in
                WindowSessionGroup(
                    documentIDs: pane.documentIDs,
                    activeDocumentID: pane.activeDocumentID
                )
            }
        )
    }

    public var windowSessionLayout: WindowSessionLayout {
        toWindowSessionLayout()
    }

    public var sessionLayout: WindowSessionLayout {
        toWindowSessionLayout()
    }

    /// Convert one pane-local selection to the corresponding session view
    /// record. Scroll values are supplied by the UI adapter.
    public func windowSessionViewState(
        forDocumentID documentID: String,
        inPaneAt paneIndex: Int,
        scrollX: Int = 0,
        scrollY: Int = 0
    ) -> WindowSessionViewState? {
        guard let selection = selection(
            forDocumentID: documentID,
            inPaneAt: paneIndex
        ) else { return nil }
        return WindowSessionViewState(
            group: paneIndex,
            selections: selection.ranges.map {
                WindowSessionSelection(anchor: $0.anchor, head: $0.head)
            },
            mainIndex: selection.mainIndex,
            scrollX: scrollX,
            scrollY: scrollY
        )
    }

    private mutating func transferActiveToNextPane(
        removingFromSource: Bool
    ) -> Bool {
        guard let documentID = activeDocumentID,
              let sourceSelection = panes[activePaneIndex].selection(for: documentID) else {
            return false
        }
        if panes.count < 2 { setLayout(.columns2) }

        let sourceIndex = activePaneIndex
        let targetIndex = (sourceIndex + 1) % panes.count
        insert(
            documentID,
            intoPaneAt: targetIndex,
            selection: sourceSelection,
            preferRetainedSelection: true,
            activate: true
        )
        if removingFromSource {
            if let selection = panes[sourceIndex].remove(documentID, selecting: .first) {
                retain(selection, for: documentID, inPaneAt: sourceIndex)
            }
        }
        activePaneIndex = targetIndex
        return true
    }

    private mutating func merge(_ removed: Pane, intoPaneAt destinationIndex: Int) {
        let inheritedActiveDocumentID = panes[destinationIndex].activeDocumentID == nil
            ? removed.activeDocumentID : nil
        for documentID in removed.documentIDs where !panes[destinationIndex].contains(documentID) {
            insert(
                documentID,
                intoPaneAt: destinationIndex,
                selection: removed.selection(for: documentID) ?? .cursor(at: 0),
                preferRetainedSelection: true,
                activate: false
            )
        }
        if let inheritedActiveDocumentID {
            panes[destinationIndex].activate(inheritedActiveDocumentID)
        }
    }

    private mutating func makeUniqueViewID() -> EditorViewID {
        let viewID = Self.uniqueViewID(excluding: usedViewIDs)
        usedViewIDs.insert(viewID)
        return viewID
    }

    @discardableResult
    private mutating func insert(
        _ documentID: String,
        intoPaneAt paneIndex: Int,
        selection: SelectionSet,
        preferRetainedSelection: Bool = true,
        activate: Bool
    ) -> Bool {
        if panes[paneIndex].contains(documentID) {
            return panes[paneIndex].insert(
                documentID,
                selection: selection,
                activate: activate
            )
        }
        let retained = takeRetainedSelection(
            for: documentID,
            inPaneAt: paneIndex
        )
        return panes[paneIndex].insert(
            documentID,
            selection: preferRetainedSelection ? retained ?? selection : selection,
            activate: activate
        )
    }

    private mutating func retain(
        _ selection: SelectionSet,
        for documentID: String,
        inPaneAt paneIndex: Int
    ) {
        let viewID = panes[paneIndex].viewID
        retainedSelectionsByViewID[viewID, default: [:]][documentID] = selection
    }

    private mutating func takeRetainedSelection(
        for documentID: String,
        inPaneAt paneIndex: Int
    ) -> SelectionSet? {
        let viewID = panes[paneIndex].viewID
        let selection = retainedSelectionsByViewID[viewID]?.removeValue(
            forKey: documentID
        )
        if retainedSelectionsByViewID[viewID]?.isEmpty == true {
            retainedSelectionsByViewID.removeValue(forKey: viewID)
        }
        return selection
    }

    private mutating func discardRetainedSelections(for documentID: String) {
        for viewID in Array(retainedSelectionsByViewID.keys) {
            retainedSelectionsByViewID[viewID]?.removeValue(forKey: documentID)
            if retainedSelectionsByViewID[viewID]?.isEmpty == true {
                retainedSelectionsByViewID.removeValue(forKey: viewID)
            }
        }
    }

    private static func uniqueViewID(excluding used: Set<EditorViewID>) -> EditorViewID {
        var candidate: EditorViewID
        repeat {
            candidate = EditorViewID("pane-\(UUID().uuidString.lowercased())")
        } while used.contains(candidate)
        return candidate
    }
}

public typealias EditorPane = PaneLayout.Pane
public typealias PaneState = PaneLayout.Pane
public typealias PaneGroup = PaneLayout.Pane
