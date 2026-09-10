import Foundation

/// A bounded Find in Files request. An empty `rootIDs` list produces no roots;
/// callers must explicitly identify each user-authorised workspace capability.
/// Supplying IDs never grants access: every ID is resolved by
/// `WorkspaceService` when the operation begins.
public struct WorkspaceSearchRequest: Equatable, Sendable {
    public var rootIDs: [WorkspaceRoot.ID]
    public var query: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var useRegex: Bool
    public var include: String?
    public var exclude: String?
    public var maxResults: Int?

    public init(
        rootIDs: [WorkspaceRoot.ID] = [],
        query: String,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        useRegex: Bool = false,
        include: String? = nil,
        exclude: String? = nil,
        maxResults: Int? = nil
    ) {
        self.rootIDs = rootIDs
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.useRegex = useRegex
        self.include = include
        self.exclude = exclude
        self.maxResults = maxResults
    }

    /// Spelling used by Foundation-facing clients.
    public var useRegularExpression: Bool {
        get { useRegex }
        set { useRegex = newValue }
    }

    public var maximumResults: Int? {
        get { maxResults }
        set { maxResults = newValue }
    }
}

public struct WorkspaceReplaceRequest: Equatable, Sendable {
    public var search: WorkspaceSearchRequest
    public var replacement: String

    public init(search: WorkspaceSearchRequest, replacement: String) {
        self.search = search
        self.replacement = replacement
    }

    public init(
        rootIDs: [WorkspaceRoot.ID] = [],
        query: String,
        replacement: String,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        useRegex: Bool = false,
        include: String? = nil,
        exclude: String? = nil,
        maxResults: Int? = nil
    ) {
        self.init(
            search: WorkspaceSearchRequest(
                rootIDs: rootIDs,
                query: query,
                caseSensitive: caseSensitive,
                wholeWord: wholeWord,
                useRegex: useRegex,
                include: include,
                exclude: exclude,
                maxResults: maxResults
            ),
            replacement: replacement
        )
    }

    public var rootIDs: [WorkspaceRoot.ID] { search.rootIDs }
    public var query: String { search.query }
    public var caseSensitive: Bool { search.caseSensitive }
    public var wholeWord: Bool { search.wholeWord }
    public var useRegex: Bool { search.useRegex }
    public var include: String? { search.include }
    public var exclude: String? { search.exclude }
    public var maxResults: Int? { search.maxResults }
}

/// One result in normalized editor text. `line`, `column`, and `utf16Range`
/// deliberately use JavaScript/NSRange UTF-16 units so navigation agrees with
/// the Electron renderer and Cocoa text APIs, including before emoji.
public struct WorkspaceMatch: Equatable, Sendable {
    public let url: URL
    public let line: Int
    public let column: Int
    public let lineText: String
    public let matchText: String
    public let utf16Range: NSRange

    public init(
        url: URL,
        line: Int,
        column: Int,
        lineText: String,
        matchText: String,
        utf16Range: NSRange
    ) {
        self.url = url
        self.line = line
        self.column = column
        self.lineText = lineText
        self.matchText = matchText
        self.utf16Range = utf16Range
    }

    public var path: String { url.path }
}

public struct WorkspaceSearchResult: Equatable, Sendable {
    public let matches: [WorkspaceMatch]
    public let isTruncated: Bool

    public init(matches: [WorkspaceMatch], isTruncated: Bool) {
        self.matches = matches
        self.isTruncated = isTruncated
    }
}

fileprivate struct WorkspacePlannedMatch: Equatable, Sendable {
    let range: NSRange
    let replacement: String
}

fileprivate struct WorkspacePlannedFile: Equatable, Sendable {
    let rootID: WorkspaceRoot.ID
    let url: URL
    let revision: String
    let encoding: TextEncoding
    let lineEnding: LineEnding
    let matches: [WorkspacePlannedMatch]
}

/// The exact, revision-pinned set shown to the user before a bulk edit.
/// Applying this value changes only its represented ranges; it never reruns a
/// broader replacement behind the preview.
public struct WorkspaceReplacePreview: Equatable, Sendable {
    public let id: UUID
    public let files: Int
    public let replacements: Int
    public let matches: [WorkspaceMatch]
    public let isTruncated: Bool
    public let fileURLs: [URL]

    fileprivate let ownerID: UUID
    fileprivate let plans: [WorkspacePlannedFile]
    fileprivate let projectExclusions: [String]

    fileprivate init(
        id: UUID,
        ownerID: UUID,
        matches: [WorkspaceMatch],
        plans: [WorkspacePlannedFile],
        isTruncated: Bool,
        projectExclusions: [String]
    ) {
        self.id = id
        self.ownerID = ownerID
        self.files = plans.count
        self.replacements = plans.reduce(0) { $0 + $1.matches.count }
        self.matches = matches
        self.isTruncated = isTruncated
        self.fileURLs = plans.map(\.url)
        self.plans = plans
        self.projectExclusions = projectExclusions
    }
}

fileprivate struct WorkspaceUndoFile: Equatable, Sendable {
    let rootID: WorkspaceRoot.ID
    let url: URL
    let originalData: Data
    let replacedRevision: String
}

/// Opaque, copyable proof of a completed replace transaction. It contains the
/// exact original bytes but exposes no unchecked write primitive. Receipts are
/// tied to their creating `WorkspaceSearch` actor and can succeed only once.
public struct WorkspaceReplaceReceipt: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let files: Int
    public let replacements: Int

    fileprivate let ownerID: UUID
    fileprivate let snapshots: [WorkspaceUndoFile]

    fileprivate init(
        id: UUID,
        ownerID: UUID,
        replacements: Int,
        snapshots: [WorkspaceUndoFile]
    ) {
        self.id = id
        self.ownerID = ownerID
        self.files = snapshots.count
        self.replacements = replacements
        self.snapshots = snapshots
    }
}

public struct WorkspaceReplaceResult: Equatable, Sendable {
    public let files: Int
    public let replacements: Int
    public let receipt: WorkspaceReplaceReceipt?

    public init(files: Int, replacements: Int, receipt: WorkspaceReplaceReceipt? = nil) {
        self.files = files
        self.replacements = replacements
        self.receipt = receipt
    }

    public var changedFiles: Int { files }
}

public enum WorkspaceSearchError: Error, Equatable, LocalizedError, Sendable {
    case emptyQuery
    case invalidRegularExpression
    case tooManyRoots(maximum: Int)
    case previewFromAnotherWorkspace
    case previewAlreadyApplied
    case projectExclusionsChanged
    case fileChanged(URL)
    case fileBecameIneligible(URL)
    case couldNotRead(URL)
    case couldNotWrite(URL)
    case rollbackFailed([URL])
    case receiptFromAnotherWorkspace
    case receiptAlreadyUsed

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Find in Files needs a search term."
        case .invalidRegularExpression:
            return "The search expression is invalid."
        case let .tooManyRoots(maximum):
            return "A workspace search supports at most \(maximum) roots."
        case .previewFromAnotherWorkspace:
            return "This replacement preview belongs to another workspace search session."
        case .previewAlreadyApplied:
            return "This replacement preview has already been applied."
        case .projectExclusionsChanged:
            return "Project exclusions changed. Create a new replacement preview."
        case .fileChanged:
            return "A previewed file changed on disk. Create a new replacement preview."
        case .fileBecameIneligible:
            return "A previewed file is no longer safe for unattended replacement."
        case .couldNotRead:
            return "A previewed file could not be read."
        case .couldNotWrite:
            return "A workspace replacement could not be written."
        case .rollbackFailed:
            return "A workspace replacement failed and one or more completed files could not be rolled back."
        case .receiptFromAnotherWorkspace:
            return "This replacement receipt belongs to another workspace search session."
        case .receiptAlreadyUsed:
            return "This workspace replacement receipt has already been used."
        }
    }
}

enum WorkspaceSearchMutationKind: Sendable {
    case apply
    case undo
}

/// Foundation-only workspace Find/Replace core.
///
/// The actor serializes previews, applies, and receipt consumption. Files are
/// discovered and opened through `WorkspaceService`, preserving its capability
/// checks. Apply and undo acquire a service-owned lease whose pinned directory
/// descriptors cover final preflight, every atomic commit, and compensation.
public actor WorkspaceSearch {
    public static let maximumFileByteCount: Int64 = 2 * 1_024 * 1_024
    public static let maximumResultCount = 5_000
    public static let maximumRootCount = 12
    public static let maximumQueryUTF16Length = 2_000

    private let workspace: WorkspaceService
    private let ownerID = UUID()
    private let afterPrepareBeforeMutationLease: (
        @Sendable (WorkspaceSearchMutationKind) async -> Void
    )?
    private let afterMutationLeaseBeforeFinalPreflight: (
        @Sendable (WorkspaceSearchMutationKind) async -> Void
    )?
    private let afterRecoveryCapacityPreflight: (
        @Sendable (WorkspaceSearchMutationKind) throws -> Void
    )?
    private var appliedPreviews: Set<UUID> = []
    private var usedReceipts: Set<UUID> = []

    public init(workspace: WorkspaceService) {
        self.workspace = workspace
        afterPrepareBeforeMutationLease = nil
        afterMutationLeaseBeforeFinalPreflight = nil
        afterRecoveryCapacityPreflight = nil
    }

    public init(service: WorkspaceService) {
        self.workspace = service
        afterPrepareBeforeMutationLease = nil
        afterMutationLeaseBeforeFinalPreflight = nil
        afterRecoveryCapacityPreflight = nil
    }

    /// Test-only suspension points bracketing lease acquisition. No lock is
    /// held while either hook runs. Production construction has no suspension
    /// between lease acquisition, final preflight, commit, and compensation.
    init(
        workspace: WorkspaceService,
        afterPrepareBeforeMutationLease: (
            @Sendable (WorkspaceSearchMutationKind) async -> Void
        )?,
        afterMutationLeaseBeforeFinalPreflight: (
            @Sendable (WorkspaceSearchMutationKind) async -> Void
        )?,
        afterRecoveryCapacityPreflight: (
            @Sendable (WorkspaceSearchMutationKind) throws -> Void
        )? = nil
    ) {
        self.workspace = workspace
        self.afterPrepareBeforeMutationLease = afterPrepareBeforeMutationLease
        self.afterMutationLeaseBeforeFinalPreflight =
            afterMutationLeaseBeforeFinalPreflight
        self.afterRecoveryCapacityPreflight = afterRecoveryCapacityPreflight
    }

    /// Return at most 5,000 matches over the selected authorised roots.
    public func search(_ request: WorkspaceSearchRequest) async throws -> [WorkspaceMatch] {
        let result = try await searchResult(request)
        return result.matches
    }

    public func search(
        request: WorkspaceSearchRequest
    ) async throws -> [WorkspaceMatch] {
        return try await search(request)
    }

    /// Search metadata for callers that need to distinguish a complete result
    /// set from one stopped by a result or workspace traversal budget.
    public func searchResult(
        _ request: WorkspaceSearchRequest
    ) async throws -> WorkspaceSearchResult {
        try await searchResult(request, projectExclusions: [])
    }

    public func searchResult(
        _ request: WorkspaceSearchRequest, projectExclusions: [String]
    ) async throws -> WorkspaceSearchResult {
        let scan = try await scan(
            request, replacement: nil, replacementSafeOnly: false,
            projectExclusions: Self.normalizedExclusions(projectExclusions)
        )
        return WorkspaceSearchResult(matches: scan.matches, isTruncated: scan.isTruncated)
    }

    /// Build a revision-pinned replacement transaction without writing files.
    public func previewReplace(
        _ request: WorkspaceReplaceRequest
    ) async throws -> WorkspaceReplacePreview {
        try await previewReplace(request, projectExclusions: [])
    }

    public func previewReplace(
        _ request: WorkspaceReplaceRequest, projectExclusions: [String]
    ) async throws -> WorkspaceReplacePreview {
        let projectExclusions = Self.normalizedExclusions(projectExclusions)
        let scan = try await scan(
            request.search,
            replacement: request.replacement,
            replacementSafeOnly: true,
            projectExclusions: projectExclusions
        )
        return WorkspaceReplacePreview(
            id: UUID(),
            ownerID: ownerID,
            matches: scan.matches,
            plans: scan.plans,
            isTruncated: scan.isTruncated,
            projectExclusions: projectExclusions
        )
    }

    public func preview(
        _ request: WorkspaceReplaceRequest
    ) async throws -> WorkspaceReplacePreview {
        return try await previewReplace(request)
    }

    public func previewReplace(
        request: WorkspaceReplaceRequest
    ) async throws -> WorkspaceReplacePreview {
        return try await previewReplace(request)
    }

    /// Apply exactly one preview after checking every file revision.
    /// No file is changed when preflight fails. Each file commit is atomic; a
    /// commit-time race triggers compensating rollback of earlier commits. If
    /// compensation itself loses a race, `.rollbackFailed` explicitly reports
    /// the files whose final state may be partial.
    public func apply(
        _ preview: WorkspaceReplacePreview
    ) async throws -> WorkspaceReplaceResult {
        try await apply(preview, projectExclusions: [])
    }

    public func apply(
        _ preview: WorkspaceReplacePreview, projectExclusions: [String]
    ) async throws -> WorkspaceReplaceResult {
        guard preview.ownerID == ownerID else {
            throw WorkspaceSearchError.previewFromAnotherWorkspace
        }
        guard !appliedPreviews.contains(preview.id) else {
            throw WorkspaceSearchError.previewAlreadyApplied
        }
        guard preview.projectExclusions == Self.normalizedExclusions(projectExclusions) else {
            throw WorkspaceSearchError.projectExclusionsChanged
        }
        if preview.plans.isEmpty {
            appliedPreviews.insert(preview.id)
            return WorkspaceReplaceResult(files: 0, replacements: 0)
        }

        let allPrepared = try await prepareApply(preview.plans)
        await afterPrepareBeforeMutationLease?(.apply)
        // `prepareApply` awaits WorkspaceService, so another call may have
        // claimed this preview while its file preflight was running.
        guard !appliedPreviews.contains(preview.id) else {
            throw WorkspaceSearchError.previewAlreadyApplied
        }
        try Task.checkCancellation()
        let changedPrepared = allPrepared.filter {
            $0.originalRevision != $0.replacementRevision
        }
        let lease = try await workspace.acquireMutationLease(for: allPrepared.map {
            (rootID: $0.rootID, url: $0.url)
        })
        defer { lease.release() }
        await afterMutationLeaseBeforeFinalPreflight?(.apply)
        try Task.checkCancellation()
        do {
            try AtomicFileWriter.withExclusiveTransaction {
                try finalPreflightApply(allPrepared, lease: lease)
                try lease.preflightRecoveryCapacity(for: allPrepared.indices.filter {
                    allPrepared[$0].originalRevision != allPrepared[$0].replacementRevision
                })
                try afterRecoveryCapacityPreflight?(.apply)
            // The test seam above can reenter this actor. Recheck ownership
            // before claiming the preview and entering the synchronous batch.
            guard !appliedPreviews.contains(preview.id) else {
                throw WorkspaceSearchError.previewAlreadyApplied
            }
            appliedPreviews.insert(preview.id)
            guard !changedPrepared.isEmpty else { return }
            var completed: [(targetIndex: Int, item: PreparedApply)] = []
            var attemptedURL = changedPrepared.first?.url
            do {
                for (index, item) in allPrepared.enumerated() {
                    guard item.originalRevision != item.replacementRevision else {
                        continue
                    }
                    try Task.checkCancellation()
                    attemptedURL = item.url
                    let result = try lease.write(
                        item.replacementData, at: index,
                        expectedRevision: item.originalRevision,
                        maximumByteCount: Self.maximumFileByteCount
                    )
                    guard result.wroteBytes else {
                        throw FileWriteFailure.conflict(
                            actualRevision: result.revision
                        )
                    }
                    completed.append((targetIndex: index, item: item))
                }
                try Task.checkCancellation()
            } catch {
                let rollbackFailures = rollbackApplied(
                    completed, lease: lease
                )
                if let leaseError = error as? WorkspaceMutationLeaseError,
                   case let .recoveryFailed(url) = leaseError {
                    appliedPreviews.insert(preview.id)
                    throw WorkspaceSearchError.rollbackFailed(
                        Self.uniqueURLs([url] + rollbackFailures)
                    )
                }
                if !rollbackFailures.isEmpty {
                    throw WorkspaceSearchError.rollbackFailed(rollbackFailures)
                }
                appliedPreviews.remove(preview.id)
                if let leaseError = error as? WorkspaceMutationLeaseError,
                   case .recoveryCapacityExceeded = leaseError {
                    throw WorkspaceSearchError.couldNotWrite(
                        attemptedURL ?? preview.plans[0].url
                    )
                }
                if error is CancellationError { throw error }
                if let failure = error as? FileWriteFailure {
                    switch failure {
                    case .conflict:
                        throw WorkspaceSearchError.fileChanged(
                            attemptedURL ?? preview.plans[0].url
                        )
                    case .hardLinked, .invalidExpectedRevision:
                        break
                    }
                }
                throw WorkspaceSearchError.couldNotWrite(
                    attemptedURL ?? preview.plans[0].url
                )
            }
            }
        } catch let leaseError as WorkspaceMutationLeaseError {
            if case .recoveryCapacityExceeded = leaseError {
                throw WorkspaceSearchError.couldNotWrite(
                    changedPrepared.first?.url ?? preview.plans[0].url
                )
            }
            throw leaseError
        }
        guard !changedPrepared.isEmpty else {
            return WorkspaceReplaceResult(files: 0, replacements: 0)
        }

        let receipt = WorkspaceReplaceReceipt(
            id: UUID(),
            ownerID: ownerID,
            replacements: changedPrepared.reduce(0) { $0 + $1.replacementCount },
            snapshots: changedPrepared.map { item in
                WorkspaceUndoFile(
                    rootID: item.rootID,
                    url: item.url,
                    originalData: item.originalData,
                    replacedRevision: item.replacementRevision
                )
            }
        )
        return WorkspaceReplaceResult(
            files: changedPrepared.count,
            replacements: changedPrepared.reduce(0) { $0 + $1.replacementCount },
            receipt: receipt
        )
    }

    public func replace(
        using preview: WorkspaceReplacePreview
    ) async throws -> WorkspaceReplaceResult {
        return try await apply(preview)
    }

    public func apply(
        preview: WorkspaceReplacePreview
    ) async throws -> WorkspaceReplaceResult {
        return try await apply(preview)
    }

    /// Restore the exact original bytes if every replaced file still has the
    /// revision produced by the corresponding apply. Receipts are one-shot.
    public func undo(
        _ receipt: WorkspaceReplaceReceipt
    ) async throws -> WorkspaceReplaceResult {
        guard receipt.ownerID == ownerID else {
            throw WorkspaceSearchError.receiptFromAnotherWorkspace
        }
        guard !usedReceipts.contains(receipt.id) else {
            throw WorkspaceSearchError.receiptAlreadyUsed
        }
        let allPrepared = try await prepareUndo(receipt.snapshots)
        await afterPrepareBeforeMutationLease?(.undo)
        guard !usedReceipts.contains(receipt.id) else {
            throw WorkspaceSearchError.receiptAlreadyUsed
        }
        try Task.checkCancellation()
        let changedPrepared = allPrepared.filter {
            $0.originalRevision != $0.replacedRevision
        }
        let lease = try await workspace.acquireMutationLease(for: allPrepared.map {
            (rootID: $0.rootID, url: $0.url)
        })
        defer { lease.release() }
        await afterMutationLeaseBeforeFinalPreflight?(.undo)
        try Task.checkCancellation()
        do {
            try AtomicFileWriter.withExclusiveTransaction {
                try finalPreflightUndo(allPrepared, lease: lease)
                try lease.preflightRecoveryCapacity(for: allPrepared.indices.filter {
                    allPrepared[$0].originalRevision != allPrepared[$0].replacedRevision
                })
                try afterRecoveryCapacityPreflight?(.undo)
            guard !usedReceipts.contains(receipt.id) else {
                throw WorkspaceSearchError.receiptAlreadyUsed
            }
            usedReceipts.insert(receipt.id)
            guard !changedPrepared.isEmpty else { return }
            var completed: [(targetIndex: Int, item: PreparedUndo)] = []
            var attemptedURL = changedPrepared.first?.url
            do {
                for (index, item) in allPrepared.enumerated() {
                    guard item.originalRevision != item.replacedRevision else {
                        continue
                    }
                    try Task.checkCancellation()
                    attemptedURL = item.url
                    let result = try lease.write(
                        item.originalData, at: index,
                        expectedRevision: item.replacedRevision,
                        maximumByteCount: Self.maximumFileByteCount
                    )
                    guard result.wroteBytes else {
                        throw FileWriteFailure.conflict(
                            actualRevision: result.revision
                        )
                    }
                    completed.append((targetIndex: index, item: item))
                }
                try Task.checkCancellation()
            } catch {
                let rollbackFailures = rollbackUndo(
                    completed, lease: lease
                )
                if let leaseError = error as? WorkspaceMutationLeaseError,
                   case let .recoveryFailed(url) = leaseError {
                    usedReceipts.insert(receipt.id)
                    throw WorkspaceSearchError.rollbackFailed(
                        Self.uniqueURLs([url] + rollbackFailures)
                    )
                }
                if !rollbackFailures.isEmpty {
                    throw WorkspaceSearchError.rollbackFailed(rollbackFailures)
                }
                usedReceipts.remove(receipt.id)
                if let leaseError = error as? WorkspaceMutationLeaseError,
                   case .recoveryCapacityExceeded = leaseError {
                    throw WorkspaceSearchError.couldNotWrite(
                        attemptedURL ?? receipt.snapshots[0].url
                    )
                }
                if error is CancellationError { throw error }
                if let failure = error as? FileWriteFailure {
                    switch failure {
                    case .conflict:
                        throw WorkspaceSearchError.fileChanged(
                            attemptedURL ?? receipt.snapshots[0].url
                        )
                    case .hardLinked, .invalidExpectedRevision:
                        break
                    }
                }
                throw WorkspaceSearchError.couldNotWrite(
                    attemptedURL ?? receipt.snapshots[0].url
                )
            }
            }
        } catch let leaseError as WorkspaceMutationLeaseError {
            if case .recoveryCapacityExceeded = leaseError {
                throw WorkspaceSearchError.couldNotWrite(
                    changedPrepared.first?.url ?? receipt.snapshots[0].url
                )
            }
            throw leaseError
        }

        return WorkspaceReplaceResult(
            files: changedPrepared.count,
            replacements: 0,
            receipt: nil
        )
    }

    public func undo(
        receipt: WorkspaceReplaceReceipt
    ) async throws -> WorkspaceReplaceResult {
        return try await undo(receipt)
    }

    // MARK: - Search and preview

    private struct ScanResult {
        var matches: [WorkspaceMatch]
        var plans: [WorkspacePlannedFile]
        var isTruncated: Bool
    }

    private nonisolated func scan(
        _ request: WorkspaceSearchRequest,
        replacement: String?,
        replacementSafeOnly: Bool,
        projectExclusions: [String]
    ) async throws -> ScanResult {
        let expression = try makeExpression(request)
        let roots = try await selectedRoots(request.rootIDs)
        let limit = min(max(request.maxResults ?? Self.maximumResultCount, 1), Self.maximumResultCount)
        let includes = GlobList(request.include)
        let excludes = GlobList(request.exclude)
        var result = ScanResult(matches: [], plans: [], isTruncated: false)
        var seenFiles: Set<String> = []

        rootLoop: for root in roots {
            let listing = try await workspace.recursiveFiles(
                in: root.id,
                exclusions: WorkspaceExclusionPolicy(globPatterns: projectExclusions)
            )
            if listing.isTruncated { result.isTruncated = true }
            for url in listing.files {
                if result.matches.count >= limit {
                    result.isTruncated = true
                    break rootLoop
                }
                // Nested registered roots can enumerate the same logical file.
                // Treat one physical editor document as one replace target.
                let fileKey = url.standardizedFileURL.resolvingSymlinksInPath().path
                if seenFiles.contains(fileKey) { continue }
                let relativePath = Self.relativePath(of: url, to: root.url)
                if !includes.matches(relativePath, emptyResult: true) ||
                    excludes.matches(relativePath, emptyResult: false) {
                    continue
                }
                do {
                    guard try Self.isWithinSearchSize(url) else { continue }
                } catch {
                    // Files may disappear between enumeration and the bounded
                    // size check. That is an ordinary best-effort scan race.
                    continue
                }

                do {
                    // Validate the specific requested root rather than merely
                    // accepting access through a different overlapping root.
                    try await validateRoot(root.id, contains: url)
                    let opened = try await workspace.openFile(url)
                    guard !opened.isBinary, !opened.isTooLarge,
                          opened.byteLength <= Self.maximumFileByteCount else { continue }
                    if opened.encodingIssue == .invalidBytes { continue }
                    if replacementSafeOnly, opened.encodingIssue != nil { continue }
                    guard let revision = opened.revision else { continue }

                    let remaining = limit - result.matches.count
                    let occurrences = Self.occurrences(
                        in: opened.content,
                        url: opened.url,
                        expression: expression,
                        replacementTemplate: replacement,
                        useRegexReplacement: request.useRegex,
                        limit: remaining
                    )
                    guard !occurrences.isEmpty else {
                        seenFiles.insert(fileKey)
                        continue
                    }
                    result.matches.append(contentsOf: occurrences.map(\.match))
                    if replacement != nil {
                        result.plans.append(WorkspacePlannedFile(
                            rootID: root.id,
                            url: opened.url,
                            revision: revision,
                            encoding: opened.encoding,
                            lineEnding: opened.lineEnding,
                            matches: occurrences.map {
                                WorkspacePlannedMatch(
                                    range: $0.match.utf16Range,
                                    replacement: $0.replacement ?? ""
                                )
                            }
                        ))
                    }
                    seenFiles.insert(fileKey)
                    if result.matches.count >= limit {
                        result.isTruncated = true
                        break rootLoop
                    }
                } catch let error as WorkspaceServiceError {
                    // Never downgrade a capability violation caused by a
                    // retargeted root or path to an unreadable-file skip.
                    if Self.isSecurityBoundaryError(error) { throw error }
                    continue
                } catch {
                    // Match the workspace scanner's best-effort read policy.
                    continue
                }
            }
        }
        return result
    }

    private static func normalizedExclusions(_ exclusions: [String]) -> [String] {
        exclusions.flatMap { value in
            value.split(separator: ",", omittingEmptySubsequences: true).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.filter { !$0.isEmpty }
    }

    private nonisolated func selectedRoots(
        _ requested: [WorkspaceRoot.ID]
    ) async throws -> [WorkspaceRoot] {
        let registered = await workspace.registeredRoots()
        var ids: [WorkspaceRoot.ID] = []
        for id in requested where !ids.contains(id) { ids.append(id) }
        guard ids.count <= Self.maximumRootCount else {
            throw WorkspaceSearchError.tooManyRoots(maximum: Self.maximumRootCount)
        }
        return try ids.map { id in
            guard let root = registered.first(where: { $0.id == id }) else {
                throw WorkspaceServiceError.rootNotRegistered(id)
            }
            return root
        }
    }

    private nonisolated func makeExpression(
        _ request: WorkspaceSearchRequest
    ) throws -> NSRegularExpression {
        let rawQuery = request.query as NSString
        let query = rawQuery.substring(
            to: min(rawQuery.length, Self.maximumQueryUTF16Length)
        )
        guard !query.isEmpty else { throw WorkspaceSearchError.emptyQuery }
        let body = request.useRegex
            ? query
            : NSRegularExpression.escapedPattern(for: query)
        let pattern = request.wholeWord ? "\\b(?:\(body))\\b" : body
        let options: NSRegularExpression.Options = request.caseSensitive ? [] : [.caseInsensitive]
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw WorkspaceSearchError.invalidRegularExpression
        }
    }

    private struct Occurrence {
        let match: WorkspaceMatch
        let replacement: String?
    }

    private static func occurrences(
        in content: String,
        url: URL,
        expression: NSRegularExpression,
        replacementTemplate: String?,
        useRegexReplacement: Bool,
        limit: Int
    ) -> [Occurrence] {
        guard limit > 0 else { return [] }
        let text = content as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let lineStarts = utf16LineStarts(in: text)
        var found: [Occurrence] = []
        var searchRange = fullRange
        while found.count < limit,
              let result = expression.firstMatch(in: content, range: searchRange) {
            let range = result.range
            guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { break }
            let lineIndex = lineIndex(containing: range.location, starts: lineStarts)
            let lineStart = lineStarts[lineIndex]
            let newline = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: lineStart, length: text.length - lineStart)
            )
            let lineEnd = newline.location == NSNotFound ? text.length : newline.location
            let sourceLine = text.substring(
                with: NSRange(location: lineStart, length: lineEnd - lineStart)
            )
            let replacement = replacementTemplate.map { template in
                useRegexReplacement
                    ? expandedReplacement(template, result: result, text: text)
                    : template
            }
            found.append(Occurrence(
                match: WorkspaceMatch(
                    url: url,
                    line: lineIndex + 1,
                    column: range.location - lineStart + 1,
                    lineText: sourceLine,
                    matchText: text.substring(with: range),
                    utf16Range: range
                ),
                replacement: replacement
            ))
            let nextLocation = range.length == 0 ? range.location + 1 : NSMaxRange(range)
            guard nextLocation <= text.length else { break }
            searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
        }
        return found
    }

    private static func utf16LineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        var location = 0
        while location < text.length {
            let range = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: location, length: text.length - location)
            )
            if range.location == NSNotFound { break }
            location = NSMaxRange(range)
            starts.append(location)
        }
        return starts
    }

    private static func lineIndex(containing location: Int, starts: [Int]) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= location { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }

    /// Electron replaces only `$<digits>` and `$&` in regex mode. Unknown or
    /// unmatched groups become empty; every other dollar remains literal.
    /// Mirror JavaScript `String.replace` expansion used by the Electron
    /// implementation: `$&` is the whole match; `$1`...`$99` choose the
    /// longest valid capture prefix, while unmatched captures are empty.
    private static func expandedReplacement(
        _ template: String,
        result: NSTextCheckingResult,
        text: NSString
    ) -> String {
        let scalars = Array(template.unicodeScalars)
        var index = 0
        var output = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 36 else {
                output.append(scalar)
                index += 1
                continue
            }
            guard index + 1 < scalars.count else {
                output.append(scalar)
                break
            }
            if scalars[index + 1].value == 38 {
                output.append(contentsOf: text.substring(with: result.range).unicodeScalars)
                index += 2
                continue
            }
            guard (UInt32(48)...UInt32(57)).contains(scalars[index + 1].value) else {
                output.append(scalar)
                index += 1
                continue
            }
            let firstDigit = Int(scalars[index + 1].value - 48)
            var number = firstDigit
            var consumedDigits = 1
            if index + 2 < scalars.count,
               (UInt32(48)...UInt32(57)).contains(scalars[index + 2].value) {
                let twoDigit = firstDigit * 10 + Int(scalars[index + 2].value - 48)
                if twoDigit > 0, twoDigit < result.numberOfRanges {
                    number = twoDigit
                    consumedDigits = 2
                }
            }
            if number > 0, number < result.numberOfRanges {
                let groupRange = result.range(at: number)
                if groupRange.location != NSNotFound {
                    output.append(contentsOf: text.substring(with: groupRange).unicodeScalars)
                }
                index += 1 + consumedDigits
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    // MARK: - Apply and undo

    private struct PreparedApply: Sendable {
        let rootID: WorkspaceRoot.ID
        let url: URL
        let originalData: Data
        let originalRevision: String
        let replacementData: Data
        let replacementRevision: String
        let replacementCount: Int
    }

    private nonisolated func prepareApply(
        _ plans: [WorkspacePlannedFile]
    ) async throws -> [PreparedApply] {
        var prepared: [PreparedApply] = []
        prepared.reserveCapacity(plans.count)
        for plan in plans {
            try await validateRoot(plan.rootID, contains: plan.url)
            let opened = try await workspace.openFile(plan.url)
            guard !opened.isBinary, !opened.isTooLarge, opened.encodingIssue == nil,
                  opened.byteLength <= Self.maximumFileByteCount else {
                throw WorkspaceSearchError.fileBecameIneligible(plan.url)
            }
            guard opened.revision == plan.revision,
                  opened.encoding == plan.encoding,
                  opened.lineEnding == plan.lineEnding else {
                throw WorkspaceSearchError.fileChanged(plan.url)
            }
            let originalData: Data
            do {
                // Keep an owned byte buffer, not a mapping of the target inode.
                // The secluded exchange must be able to prove that the old
                // inode has no open or mapped references, including our own.
                originalData = try Data(contentsOf: plan.url)
            } catch {
                throw WorkspaceSearchError.couldNotRead(plan.url)
            }
            guard Int64(originalData.count) <= Self.maximumFileByteCount,
                  TextFileCodec.revision(of: originalData) == plan.revision else {
                throw WorkspaceSearchError.fileChanged(plan.url)
            }

            let source = opened.content as NSString
            var changedReplacementCount = 0
            let mutable = NSMutableString(string: opened.content)
            for match in plan.matches.reversed() {
                guard match.range.location != NSNotFound,
                      NSMaxRange(match.range) <= mutable.length else {
                    throw WorkspaceSearchError.fileChanged(plan.url)
                }
                if source.substring(with: match.range) != match.replacement {
                    changedReplacementCount += 1
                }
                mutable.replaceCharacters(in: match.range, with: match.replacement)
            }
            let replacementData: Data
            do {
                replacementData = try TextFileCodec.encode(
                    mutable as String,
                    encoding: plan.encoding,
                    lineEnding: plan.lineEnding
                )
            } catch {
                throw WorkspaceSearchError.fileBecameIneligible(plan.url)
            }
            guard Int64(replacementData.count) <= Self.maximumFileByteCount else {
                throw WorkspaceSearchError.fileBecameIneligible(plan.url)
            }
            prepared.append(PreparedApply(
                rootID: plan.rootID,
                url: plan.url,
                originalData: originalData,
                originalRevision: plan.revision,
                replacementData: replacementData,
                replacementRevision: TextFileCodec.revision(of: replacementData),
                replacementCount: changedReplacementCount
            ))
        }
        return prepared
    }

    /// Re-read every byte after the service has atomically revalidated and
    /// leased the root capabilities. This is the last all-files check before
    /// the synchronous commit section, so a failure still writes nothing.
    private func finalPreflightApply(
        _ prepared: [PreparedApply], lease: WorkspaceMutationLease
    ) throws {
        for (index, item) in prepared.enumerated() {
            let data: Data
            do {
                data = try lease.readData(
                    at: index, maximumByteCount: Self.maximumFileByteCount
                )
            } catch WorkspaceMutationLeaseError.fileTooLarge {
                throw WorkspaceSearchError.fileBecameIneligible(item.url)
            }
            guard
                  TextFileCodec.revision(of: data) == item.originalRevision else {
                throw WorkspaceSearchError.fileChanged(item.url)
            }
        }
    }

    private func rollbackApplied(
        _ completed: [(targetIndex: Int, item: PreparedApply)],
        lease: WorkspaceMutationLease
    ) -> [URL] {
        var failures: [URL] = []
        let reversed = Array(completed.reversed())
        for (offset, completedItem) in reversed.enumerated() {
            do {
                let result = try lease.write(
                    completedItem.item.originalData, at: completedItem.targetIndex,
                    expectedRevision: completedItem.item.replacementRevision,
                    maximumByteCount: Self.maximumFileByteCount
                )
                if !result.wroteBytes { failures.append(completedItem.item.url) }
            } catch WorkspaceMutationLeaseError.recoveryFailed {
                failures.append(completedItem.item.url)
                failures.append(contentsOf: reversed.dropFirst(offset + 1).map {
                    $0.item.url
                })
                break
            } catch {
                failures.append(completedItem.item.url)
            }
        }
        return Array(failures.reversed())
    }

    private struct PreparedUndo: Sendable {
        let rootID: WorkspaceRoot.ID
        let url: URL
        let originalData: Data
        let originalRevision: String
        let replacedData: Data
        let replacedRevision: String
    }

    private nonisolated func prepareUndo(
        _ snapshots: [WorkspaceUndoFile]
    ) async throws -> [PreparedUndo] {
        var prepared: [PreparedUndo] = []
        prepared.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            try await validateRoot(snapshot.rootID, contains: snapshot.url)
            let opened = try await workspace.openFile(snapshot.url)
            guard opened.revision == snapshot.replacedRevision else {
                throw WorkspaceSearchError.fileChanged(snapshot.url)
            }
            let replacedData: Data
            do {
                // Do not retain a mapping which would make the old inode fail
                // the mutation lease's `RENAME_SECLUDE` check.
                replacedData = try Data(contentsOf: snapshot.url)
            } catch {
                throw WorkspaceSearchError.couldNotRead(snapshot.url)
            }
            guard TextFileCodec.revision(of: replacedData) == snapshot.replacedRevision else {
                throw WorkspaceSearchError.fileChanged(snapshot.url)
            }
            prepared.append(PreparedUndo(
                rootID: snapshot.rootID,
                url: snapshot.url,
                originalData: snapshot.originalData,
                originalRevision: TextFileCodec.revision(of: snapshot.originalData),
                replacedData: replacedData,
                replacedRevision: snapshot.replacedRevision
            ))
        }
        return prepared
    }

    private func finalPreflightUndo(
        _ prepared: [PreparedUndo], lease: WorkspaceMutationLease
    ) throws {
        for (index, item) in prepared.enumerated() {
            let data: Data
            do {
                data = try lease.readData(
                    at: index, maximumByteCount: Self.maximumFileByteCount
                )
            } catch WorkspaceMutationLeaseError.fileTooLarge {
                throw WorkspaceSearchError.fileChanged(item.url)
            }
            guard
                  TextFileCodec.revision(of: data) == item.replacedRevision else {
                throw WorkspaceSearchError.fileChanged(item.url)
            }
        }
    }

    private nonisolated func validateRoot(
        _ rootID: WorkspaceRoot.ID,
        contains url: URL
    ) async throws {
        let roots = await workspace.registeredRoots()
        guard let root = roots.first(where: { $0.id == rootID }) else {
            throw WorkspaceServiceError.rootNotRegistered(rootID)
        }
        let rootPath = root.url.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath == rootPath ||
                filePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else {
            throw WorkspaceServiceError.unauthorized(url)
        }
        // Force WorkspaceService to revalidate the registered root's pinned
        // identity even when another overlapping root still contains `url`.
        _ = try await workspace.children(of: root.url)
    }

    private func rollbackUndo(
        _ completed: [(targetIndex: Int, item: PreparedUndo)],
        lease: WorkspaceMutationLease
    ) -> [URL] {
        var failures: [URL] = []
        let reversed = Array(completed.reversed())
        for (offset, completedItem) in reversed.enumerated() {
            do {
                let result = try lease.write(
                    completedItem.item.replacedData, at: completedItem.targetIndex,
                    expectedRevision: completedItem.item.originalRevision,
                    maximumByteCount: Self.maximumFileByteCount
                )
                if !result.wroteBytes { failures.append(completedItem.item.url) }
            } catch WorkspaceMutationLeaseError.recoveryFailed {
                failures.append(completedItem.item.url)
                failures.append(contentsOf: reversed.dropFirst(offset + 1).map {
                    $0.item.url
                })
                break
            } catch {
                failures.append(completedItem.item.url)
            }
        }
        return Array(failures.reversed())
    }

    // MARK: - Bounds, paths, and globs

    private static func isWithinSearchSize(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return false }
        guard let fileSize = values.fileSize else { return false }
        return Int64(fileSize) <= maximumFileByteCount
    }

    private static func relativePath(of file: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return file.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
            .replacingOccurrences(of: "\\", with: "/")
    }

    private static func isSecurityBoundaryError(_ error: WorkspaceServiceError) -> Bool {
        switch error {
        case .invalidFileURL, .rootNotRegistered, .rootChanged, .unauthorized,
             .symbolicLinkEscapesWorkspace:
            return true
        default:
            return false
        }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

/// Alternate service-style spelling for clients that group workspace cores by
/// their dependency names.
public typealias WorkspaceSearchService = WorkspaceSearch

private struct GlobList {
    private let expressions: [NSRegularExpression]

    init(_ source: String?) {
        expressions = (source ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap(Self.expression)
    }

    func matches(_ path: String, emptyResult: Bool) -> Bool {
        guard !expressions.isEmpty else { return emptyResult }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return expressions.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    private static func expression(for glob: String) -> NSRegularExpression? {
        let characters = Array(glob)
        let regexSpecial = Set<Character>(".+^${}()|[]\\")
        var index = 0
        var source = "^"
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        source += "(?:.*/)?"
                        index += 3
                    } else {
                        source += ".*"
                        index += 2
                    }
                } else {
                    source += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                // Electron's compact glob implementation uses `.`, including
                // its ordinary no-newline behavior, for a single character.
                source += "."
                index += 1
            } else {
                if regexSpecial.contains(character) { source.append("\\") }
                source.append(character)
                index += 1
            }
        }
        source += "$"
        return try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }
}
