import Foundation

/// A bounded, editor-independent view of the syntax information produced by
/// the bundled CodeMirror/Lezer parser. All positions are UTF-16 offsets so
/// the snapshot can be consumed by both AppKit and the transaction planners.
///
/// The failable initializer is deliberately strict. Parser output crosses a
/// JavaScript boundary and must never be trusted merely because it decoded.
public struct ParsedSyntaxSnapshot: Equatable, Sendable {
    public static let maximumNodes = 50_000
    public static let maximumBracketPairs = 10_000
    public static let maximumIndentationEntries = 100_000
    public static let maximumNodeTypeUTF16Length = 128
    public static let maximumIndentationColumns = 1_000_000

    public struct Node: Equatable, Hashable, Sendable {
        public let from: Int
        public let to: Int
        /// Index of the containing node in the preorder `nodes` array, or -1
        /// for the root. A parent must always precede its child.
        public let parent: Int
        public let type: String

        public init(from: Int, to: Int, parent: Int, type: String) {
            self.from = from
            self.to = to
            self.parent = parent
            self.type = type
        }
    }

    public struct BracketPair: Equatable, Hashable, Sendable {
        /// UTF-16 positions of the opening and closing one-unit tokens.
        public let open: Int
        public let close: Int

        public init(open: Int, close: Int) {
            self.open = open
            self.close = close
        }
    }

    public struct LineIndentation: Equatable, Hashable, Sendable {
        public let lineFrom: Int
        public let columns: Int

        public init(lineFrom: Int, columns: Int) {
            self.lineFrom = lineFrom
            self.columns = columns
        }
    }

    public let sourceUTF16Length: Int
    public let nodes: [Node]
    public let bracketPairs: [BracketPair]
    public let indentation: [LineIndentation]
    public let nodesWereTruncated: Bool
    public let bracketPairsWereTruncated: Bool
    public let indentationWasTruncated: Bool
    public let expectedRevision: UInt64

    public init?(
        sourceUTF16Length: Int,
        nodes: [Node],
        bracketPairs: [BracketPair],
        indentation: [LineIndentation],
        nodesWereTruncated: Bool = false,
        bracketPairsWereTruncated: Bool = false,
        indentationWasTruncated: Bool = false,
        expectedRevision: UInt64
    ) {
        guard sourceUTF16Length >= 0,
              nodes.count <= Self.maximumNodes,
              bracketPairs.count <= Self.maximumBracketPairs,
              indentation.count <= Self.maximumIndentationEntries,
              Self.validNodes(nodes, sourceUTF16Length: sourceUTF16Length),
              Self.validBracketPairs(
                  bracketPairs, sourceUTF16Length: sourceUTF16Length
              ),
              Self.validIndentation(
                  indentation, sourceUTF16Length: sourceUTF16Length
              ) else { return nil }
        self.sourceUTF16Length = sourceUTF16Length
        self.nodes = nodes
        self.bracketPairs = bracketPairs
        self.indentation = indentation
        self.nodesWereTruncated = nodesWereTruncated
        self.bracketPairsWereTruncated = bracketPairsWereTruncated
        self.indentationWasTruncated = indentationWasTruncated
        self.expectedRevision = expectedRevision
    }

    /// Return the smallest syntax node that strictly contains the selection.
    /// The root is intentionally excluded to match CodeMirror's
    /// `selectParentSyntax` behavior.
    public func parentRange(containing selection: DirectedSelection) -> DirectedSelection? {
        var best: Node?
        for node in nodes where node.parent >= 0 {
            guard node.from <= selection.from, node.to >= selection.to,
                  node.from < selection.from || node.to > selection.to else { continue }
            guard let current = best else {
                best = node
                continue
            }
            let candidateLength = node.to - node.from
            let currentLength = current.to - current.from
            if candidateLength < currentLength
                || (candidateLength == currentLength && node.from > current.from) {
                best = node
            }
        }
        return best.map { DirectedSelection(anchor: $0.from, head: $0.to) }
    }

    public func matchingBracket(atUTF16Offset offset: Int)
        -> (match: Int, opening: Bool)? {
        for pair in bracketPairs {
            if pair.open == offset { return (pair.close, true) }
            if pair.close == offset { return (pair.open, false) }
            if pair.open > offset { break }
        }
        return nil
    }

    public func indentationColumnsByLineStart() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: indentation.map { ($0.lineFrom, $0.columns) })
    }
}

private extension ParsedSyntaxSnapshot {
    static func validNodes(_ nodes: [Node], sourceUTF16Length: Int) -> Bool {
        var activeAncestors: [Int] = []
        var lastChildEnd: [Int: Int] = [:]
        for (index, node) in nodes.enumerated() {
            guard node.from >= 0, node.to >= node.from, node.to <= sourceUTF16Length,
                  !node.type.isEmpty,
                  node.type.utf16.count <= maximumNodeTypeUTF16Length,
                  node.parent >= -1, node.parent < index else { return false }
            guard (index == 0 && node.parent == -1)
                    || (index > 0 && node.parent >= 0) else { return false }
            if index == 0 {
                guard node.from == 0, node.to == sourceUTF16Length else { return false }
                activeAncestors.append(index)
                continue
            }
            // Lezer legitimately emits zero-width recovery nodes exactly at a
            // parent's end. Follow the declared preorder parent chain here;
            // containment and sibling monotonicity below still reject crossing
            // or forged trees.
            while !activeAncestors.isEmpty, activeAncestors.last != node.parent {
                activeAncestors.removeLast()
            }
            guard activeAncestors.last == node.parent,
                  node.from >= (lastChildEnd[node.parent] ?? nodes[node.parent].from)
            else { return false }
            if node.parent >= 0 {
                let parent = nodes[node.parent]
                guard parent.from <= node.from, parent.to >= node.to else { return false }
            }
            lastChildEnd[node.parent] = node.to
            activeAncestors.append(index)
        }
        return true
    }

    static func validBracketPairs(
        _ pairs: [BracketPair], sourceUTF16Length: Int
    ) -> Bool {
        var previousOpen = -1
        var seenPositions = Set<Int>()
        var containingCloses: [Int] = []
        for pair in pairs {
            while let close = containingCloses.last, pair.open > close {
                containingCloses.removeLast()
            }
            guard pair.open >= 0, pair.open < pair.close,
                  pair.close < sourceUTF16Length, pair.open > previousOpen,
                  containingCloses.last.map({ pair.close < $0 }) ?? true,
                  seenPositions.insert(pair.open).inserted,
                  seenPositions.insert(pair.close).inserted else { return false }
            previousOpen = pair.open
            containingCloses.append(pair.close)
        }
        return true
    }

    static func validIndentation(
        _ entries: [LineIndentation], sourceUTF16Length: Int
    ) -> Bool {
        var previousLineFrom = -1
        for entry in entries {
            guard entry.lineFrom >= 0, entry.lineFrom <= sourceUTF16Length,
                  entry.lineFrom > previousLineFrom, entry.columns >= 0,
                  entry.columns <= maximumIndentationColumns else { return false }
            previousLineFrom = entry.lineFrom
        }
        return true
    }
}
