import Combine
import Foundation
import LumenEditorCore

/// Resolves workspace-owned .editorconfig files after a document is opened.
/// Resolution is generation guarded; applying the result changes editor
/// presentation/default-save policy only and never mutates document text.
@MainActor
public final class EditorConfigController: ObservableObject {
    public typealias Resolver = (URL, URL, Bool) async throws -> ResolvedEditorConfig
    public typealias CapabilityResolver = (
        URL, WorkspaceRoot.ID, Bool
    ) async throws -> ResolvedEditorConfig

    @Published public private(set) var issue: EditorConfigPresentationIssue?
    private var generations: [String: UInt64] = [:]
    private let resolver: Resolver
    private var capabilityResolver: CapabilityResolver?

    public init(resolver: @escaping Resolver = { target, root, allowMissingTarget in
        try await Task.detached(priority: .utility) {
            try EditorConfig.resolve(
                for: target,
                workspaceRoot: root,
                allowMissingTarget: allowMissingTarget
            )
        }.value
    }) {
        self.resolver = resolver
        capabilityResolver = nil
    }

    public convenience init(capabilityResolver: @escaping CapabilityResolver) {
        self.init(resolver: { _, _, _ in ResolvedEditorConfig() })
        self.capabilityResolver = capabilityResolver
    }

    public func resolve(
        for document: EditorDocument,
        workspaceRoots: [WorkspaceRoot]
    ) async {
        let key = document.sessionDocumentID
        let generation = (generations[key] ?? 0) &+ 1
        generations[key] = generation
        issue = nil
        guard let fileURL = document.fileURL else {
            document.setEditorConfig(nil)
            return
        }
        let documentIdentity = ObjectIdentifier(document)
        let roots = workspaceRoots.filter { root in
            Self.contains(root.url, fileURL)
        }
        guard let root = Self.mostSpecificRoot(in: roots) else {
            document.setEditorConfig(nil)
            return
        }
        do {
            let resolved = if let capabilityResolver {
                try await capabilityResolver(fileURL, root.id, false)
            } else {
                try await resolver(fileURL, root.url, false)
            }
            guard generations[key] == generation,
                  ObjectIdentifier(document) == documentIdentity,
                  document.fileURL == fileURL else { return }
            document.setEditorConfig(resolved)
        } catch {
            guard generations[key] == generation,
                  ObjectIdentifier(document) == documentIdentity,
                  document.fileURL == fileURL else { return }
            document.setEditorConfig(nil)
            issue = EditorConfigPresentationIssue(error: error)
        }
    }

    public func resolveAll(
        _ documents: [EditorDocument],
        workspaceRoots: [WorkspaceRoot]
    ) async {
        for document in documents {
            await resolve(for: document, workspaceRoots: workspaceRoots)
        }
    }

    public func invalidateAndClear(_ document: EditorDocument) {
        cancel(for: document.sessionDocumentID)
        document.setEditorConfig(nil)
    }

    /// Capability-scoped production adapter. The chosen root is revalidated
    /// by WorkspaceService immediately before its bounded config reads.
    static func connected(to workspace: WorkspaceController) -> EditorConfigController {
        EditorConfigController(capabilityResolver: { target, rootID, allowMissingTarget in
            try await workspace.service.resolveEditorConfig(
                for: target,
                in: rootID,
                allowMissingTarget: allowMissingTarget
            )
        })
    }

    /// Resolve the effective EOL immediately before a write. Explicit choices
    /// are authoritative; config failures fall back to the document's current
    /// physical EOL so an otherwise authorised save remains available.
    public func lineEndingForSave(
        document: EditorDocument,
        destination: URL,
        workspaceRoots: [WorkspaceRoot],
        allowMissingTarget: Bool = true
    ) async -> LineEnding {
        if let explicit = document.eolOverride { return explicit }
        let roots = workspaceRoots.filter { Self.contains($0.url, destination) }
        guard let root = Self.mostSpecificRoot(in: roots) else {
            return document.lineEnding
        }
        do {
            let resolved = if let capabilityResolver {
                try await capabilityResolver(
                    destination, root.id, allowMissingTarget
                )
            } else {
                try await resolver(destination, root.url, allowMissingTarget)
            }
            return resolved.endOfLine ?? document.lineEnding
        } catch {
            return document.lineEnding
        }
    }

    public func cancel(for documentID: String) {
        generations[documentID, default: 0] &+= 1
    }

    public func dismissIssue() { issue = nil }

    private static func contains(_ rootURL: URL, _ candidateURL: URL) -> Bool {
        let root = (rootURL.path as NSString).standardizingPath
        let candidate = (candidateURL.path as NSString).standardizingPath
        return candidate == root
            || root == "/"
            || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func mostSpecificRoot(in roots: [WorkspaceRoot]) -> WorkspaceRoot? {
        roots.max { left, right in
            let leftPath = (left.url.path as NSString).standardizingPath
            let rightPath = (right.url.path as NSString).standardizingPath
            let leftDepth = leftPath.split(separator: "/").count
            let rightDepth = rightPath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return leftPath.count < rightPath.count
        }
    }
}

public struct EditorConfigPresentationIssue: Identifiable, Equatable, Sendable {
    public enum Title: Equatable, Sendable {
        case resolve
    }

    public enum Message: Equatable, Sendable {
        case resolution(EditorConfigResolutionError)
        case workspace(WorkspaceServiceError)
        case verbatim(String)
    }

    public let id: UUID
    public let titleContent: Title
    public let content: Message

    public var title: String {
        EditorLocale.enUS.localizedEditorConfigIssueTitle(titleContent)
    }
    public var message: String {
        EditorLocale.enUS.localizedEditorConfigIssue(content)
    }

    public init(id: UUID = UUID(), error: any Error) {
        self.id = id
        titleContent = .resolve
        if let resolutionError = error as? EditorConfigResolutionError {
            content = .resolution(resolutionError)
        } else if let workspaceError = error as? WorkspaceServiceError {
            content = .workspace(workspaceError)
        } else {
            content = .verbatim(error.localizedDescription)
        }
    }
}
