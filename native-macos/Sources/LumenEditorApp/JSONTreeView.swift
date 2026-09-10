import LumenEditorCore
import SwiftUI

struct JSONTreeLimits: Equatable, Sendable {
    static let hardMaximumDepth = 128
    static let hardMaximumNodes = LosslessJSONLimits.defaultMaximumNodes
    static let hardMaximumPreviewCharacters = 4_096
    static let `default` = JSONTreeLimits()

    let maximumDepth: Int
    let maximumNodes: Int
    let maximumPreviewCharacters: Int

    init(
        maximumDepth: Int = 32,
        maximumNodes: Int = 10_000,
        maximumPreviewCharacters: Int = 512
    ) {
        precondition((0 ... Self.hardMaximumDepth).contains(maximumDepth))
        precondition((1 ... Self.hardMaximumNodes).contains(maximumNodes))
        precondition(
            (1 ... Self.hardMaximumPreviewCharacters).contains(maximumPreviewCharacters)
        )
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumPreviewCharacters = maximumPreviewCharacters
    }
}

struct JSONTreeSnapshot: Equatable, Sendable {
    let root: JSONTreeNode
    let statistics: LosslessJSONStatistics
    let limits: JSONTreeLimits
    let renderedNodeCount: Int
    let reachedDepthLimit: Bool
    let reachedNodeLimit: Bool

    init(value: LosslessJSONValue, limits: JSONTreeLimits = .default) {
        let bounded = Self.boundedStatistics(of: value, limits: limits)
        var builder = JSONTreeSnapshotBuilder(limits: limits)
        root = builder.makeNode(
            value: value,
            label: "$",
            path: [],
            depth: 0
        )!
        statistics = bounded.statistics
        self.limits = limits
        renderedNodeCount = builder.renderedNodeCount
        reachedDepthLimit = builder.reachedDepthLimit || bounded.reachedDepthLimit
        reachedNodeLimit = builder.reachedNodeLimit || bounded.reachedNodeLimit
    }

    private static func boundedStatistics(
        of value: LosslessJSONValue,
        limits: JSONTreeLimits
    ) -> (
        statistics: LosslessJSONStatistics,
        reachedDepthLimit: Bool,
        reachedNodeLimit: Bool
    ) {
        var result = LosslessJSONStatistics()
        var visited = 0
        var stack: [(LosslessJSONValue, Int)] = [(value, 0)]
        var reachedDepthLimit = false
        while let (current, depth) = stack.popLast(),
              visited < limits.maximumNodes,
              depth <= limits.maximumDepth {
            visited += 1
            result.maxDepth = max(result.maxDepth, depth)
            switch current {
            case let .array(items):
                result.arrays += 1
                if depth < limits.maximumDepth {
                    let available = max(0, limits.maximumNodes - visited - stack.count)
                    let accepted = min(items.count, available)
                    if accepted < items.count { reachedNodeLimit = true }
                    for item in items.prefix(accepted).reversed() {
                        stack.append((item, depth + 1))
                    }
                } else if !items.isEmpty {
                    reachedDepthLimit = true
                }
            case let .object(object):
                result.objects += 1
                result.keys += object.count
                if depth < limits.maximumDepth {
                    let available = max(0, limits.maximumNodes - visited - stack.count)
                    let accepted = min(object.count, available)
                    if accepted < object.count { reachedNodeLimit = true }
                    for member in object.prefix(accepted).reversed() {
                        stack.append((member.value, depth + 1))
                    }
                } else if !object.isEmpty {
                    reachedDepthLimit = true
                }
            case .null, .bool, .string, .number:
                result.values += 1
            }
        }
        return (result, reachedDepthLimit, reachedNodeLimit || !stack.isEmpty)
    }
}

struct JSONTreeNode: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case null
        case boolean(Bool)
        case string
        case number
        case array(count: Int)
        case object(count: Int)
    }

    enum Omission: Equatable, Sendable {
        case depthLimit(omittedChildren: Int)
        case nodeLimit(omittedChildren: Int)
    }

    let id: Int
    let label: String
    let path: LosslessJSONPath
    let depth: Int
    let kind: Kind
    let displayValue: String?
    let children: [JSONTreeNode]
    let omission: Omission?

    var outlineChildren: [JSONTreeNode]? {
        children.isEmpty ? nil : children
    }

    var containerCount: Int? {
        switch kind {
        case let .array(count), let .object(count): count
        case .null, .boolean, .string, .number: nil
        }
    }
}

private struct JSONTreeSnapshotBuilder {
    let limits: JSONTreeLimits
    var renderedNodeCount = 0
    var reachedDepthLimit = false
    var reachedNodeLimit = false

    mutating func makeNode(
        value: LosslessJSONValue,
        label: String,
        path: LosslessJSONPath,
        depth: Int
    ) -> JSONTreeNode? {
        guard renderedNodeCount < limits.maximumNodes else {
            reachedNodeLimit = true
            return nil
        }

        let id = renderedNodeCount
        renderedNodeCount += 1

        switch value {
        case .null:
            return leaf(id: id, label: label, path: path, depth: depth, kind: .null, text: "null")
        case let .bool(boolean):
            return leaf(
                id: id,
                label: label,
                path: path,
                depth: depth,
                kind: .boolean(boolean),
                text: boolean ? "true" : "false"
            )
        case let .number(number):
            return leaf(
                id: id,
                label: label,
                path: path,
                depth: depth,
                kind: .number,
                text: clipped(number.raw)
            )
        case let .string(string):
            return leaf(
                id: id,
                label: label,
                path: path,
                depth: depth,
                kind: .string,
                text: escapedJSONString(string)
            )
        case let .array(items):
            let kind = JSONTreeNode.Kind.array(count: items.count)
            if let limited = limitedContainer(
                id: id, label: label, path: path, depth: depth,
                kind: kind, childCount: items.count
            ) {
                return limited
            }
            var children: [JSONTreeNode] = []
            children.reserveCapacity(min(items.count, limits.maximumNodes - renderedNodeCount))
            var omission: JSONTreeNode.Omission?
            for index in items.indices {
                guard let next = makeNode(
                    value: items[index],
                    label: "[\(index)]",
                    path: path + [.index(index)],
                    depth: depth + 1
                ) else {
                    omission = .nodeLimit(omittedChildren: items.count - index)
                    break
                }
                children.append(next)
            }
            return container(
                id: id, label: label, path: path, depth: depth,
                kind: kind, children: children, omission: omission
            )
        case let .object(object):
            let kind = JSONTreeNode.Kind.object(count: object.count)
            if let limited = limitedContainer(
                id: id, label: label, path: path, depth: depth,
                kind: kind, childCount: object.count
            ) {
                return limited
            }
            var children: [JSONTreeNode] = []
            children.reserveCapacity(min(object.count, limits.maximumNodes - renderedNodeCount))
            var omission: JSONTreeNode.Omission?
            for index in object.indices {
                let member = object[index]
                guard let next = makeNode(
                    value: member.value,
                    label: escapedJSONString(member.losslessKey),
                    path: path + [.key(member.losslessKey)],
                    depth: depth + 1
                ) else {
                    omission = .nodeLimit(omittedChildren: object.count - index)
                    break
                }
                children.append(next)
            }
            return container(
                id: id, label: label, path: path, depth: depth,
                kind: kind, children: children, omission: omission
            )
        }
    }

    private mutating func limitedContainer(
        id: Int,
        label: String,
        path: LosslessJSONPath,
        depth: Int,
        kind: JSONTreeNode.Kind,
        childCount: Int
    ) -> JSONTreeNode? {
        guard childCount > 0 else {
            return JSONTreeNode(
                id: id,
                label: label,
                path: path,
                depth: depth,
                kind: kind,
                displayValue: nil,
                children: [],
                omission: nil
            )
        }

        guard depth < limits.maximumDepth else {
            reachedDepthLimit = true
            return JSONTreeNode(
                id: id,
                label: label,
                path: path,
                depth: depth,
                kind: kind,
                displayValue: nil,
                children: [],
                omission: .depthLimit(omittedChildren: childCount)
            )
        }

        return nil
    }

    private func container(
        id: Int,
        label: String,
        path: LosslessJSONPath,
        depth: Int,
        kind: JSONTreeNode.Kind,
        children: [JSONTreeNode],
        omission: JSONTreeNode.Omission?
    ) -> JSONTreeNode {
        JSONTreeNode(
            id: id,
            label: label,
            path: path,
            depth: depth,
            kind: kind,
            displayValue: nil,
            children: children,
            omission: omission
        )
    }

    private func leaf(
        id: Int,
        label: String,
        path: LosslessJSONPath,
        depth: Int,
        kind: JSONTreeNode.Kind,
        text: String
    ) -> JSONTreeNode {
        JSONTreeNode(
            id: id,
            label: label,
            path: path,
            depth: depth,
            kind: kind,
            displayValue: text,
            children: [],
            omission: nil
        )
    }

    private func clipped(_ value: String) -> String {
        let prefix = value.prefix(limits.maximumPreviewCharacters + 1)
        guard prefix.count > limits.maximumPreviewCharacters else { return String(prefix) }
        return String(prefix.prefix(limits.maximumPreviewCharacters)) + "…"
    }

    /// Produces a bounded, unambiguous representation without first allocating
    /// the full serialized scalar. Escaping Unicode direction controls avoids a
    /// key or value visually reordering the surrounding tree row.
    private func escapedJSONString(_ value: LosslessJSONString) -> String {
        var result = "\""
        var emittedCharacters = 0
        var index = 0
        var truncated = false

        func append(_ text: String) -> Bool {
            let characters = text.count
            guard emittedCharacters + characters <= limits.maximumPreviewCharacters else {
                return false
            }
            result.append(contentsOf: text)
            emittedCharacters += characters
            return true
        }

        escapeLoop: while index < value.utf16.count {
            let unit = value.utf16[index]
            let escaped: String
            switch unit {
            case 0x08: escaped = "\\b"
            case 0x09: escaped = "\\t"
            case 0x0a: escaped = "\\n"
            case 0x0c: escaped = "\\f"
            case 0x0d: escaped = "\\r"
            case 0x22: escaped = "\\\""
            case 0x5c: escaped = "\\\\"
            case 0x00 ... 0x1f, 0x7f, 0x061c, 0x200e ... 0x200f,
                    0x202a ... 0x202e, 0x2066 ... 0x2069:
                escaped = unicodeEscape(unit)
            case 0xd800 ... 0xdbff:
                if index + 1 < value.utf16.count {
                    let low = value.utf16[index + 1]
                    if (0xdc00 ... 0xdfff).contains(low) {
                        let scalar = String(decoding: [unit, low], as: UTF16.self)
                        guard append(scalar) else {
                            truncated = true
                            break escapeLoop
                        }
                        index += 2
                        continue
                    }
                }
                escaped = unicodeEscape(unit)
            case 0xdc00 ... 0xdfff:
                escaped = unicodeEscape(unit)
            default:
                escaped = String(decoding: [unit], as: UTF16.self)
            }

            guard append(escaped) else {
                truncated = true
                break
            }
            index += 1
        }

        if truncated { result.append("…") }
        result.append("\"")
        return result
    }

    private func unicodeEscape(_ value: UInt16) -> String {
        let raw = String(value, radix: 16, uppercase: false)
        return "\\u" + String(repeating: "0", count: 4 - raw.count) + raw
    }
}

struct JSONTreeView: View {
    enum Accessibility {
        static let tree = "preview.json.tree"
        static let outline = "preview.json.outline"
        static let summary = "preview.json.summary"
        static let limit = "preview.json.limit"
        static let editor = "preview.json.editor"
        static let editorKey = "preview.json.editor.key"
        static let editorValue = "preview.json.editor.value"
        static let editorSubmit = "preview.json.editor.submit"
        static let editorCancel = "preview.json.editor.cancel"
        static let editorError = "preview.json.editor.error"
        static let editError = "preview.json.edit-error"
        static let editErrorDismiss = "preview.json.edit-error.dismiss"

        static func node(_ id: Int) -> String { "preview.json.node.\(id)" }
        static func edit(_ id: Int) -> String { node(id) + ".edit" }
        static func addKey(_ id: Int) -> String { node(id) + ".add-key" }
        static func addItem(_ id: Int) -> String { node(id) + ".add-item" }
        static func delete(_ id: Int) -> String { node(id) + ".delete" }
    }

    let snapshot: JSONTreeSnapshot
    @ObservedObject var controller: PreviewController
    let sessionGeneration: UInt64
    let locale: EditorLocale
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var editRequest: JSONTreeEditRequest?
    @State private var removalRequest: JSONTreeRemovalRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if let editingIssue = controller.jsonEditingIssue {
                JSONEditingIssueBanner(
                    issue: editingIssue,
                    dismiss: { controller.dismissJSONEditingIssue() }
                )
            }
            Divider()
            ScrollView([.horizontal, .vertical]) {
                OutlineGroup([snapshot.root], children: \.outlineChildren) { node in
                    JSONTreeNodeRow(
                        node: node,
                        editValue: { presentValueEditor(for: node) },
                        addObjectMember: { presentObjectMemberEditor(for: node) },
                        appendArrayItem: { presentArrayItemEditor(for: node) },
                        remove: { presentRemovalConfirmation(for: node) }
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(Accessibility.outline)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocale.text("JSON tree", zh: "JSON 树"))
        .accessibilityIdentifier(Accessibility.tree)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .sheet(item: $editRequest) { request in
            JSONTreeEditView(
                request: request,
                controller: controller,
                locale: locale,
                dismiss: { editRequest = nil }
            )
        }
        .confirmationDialog(
            appLocale.text("Delete this JSON node?", zh: "删除这个 JSON 节点？"),
            isPresented: Binding(
                get: { removalRequest != nil },
                set: { if !$0 { removalRequest = nil } }
            ),
            presenting: removalRequest
        ) { request in
            Button(appLocale.text("Delete", zh: "删除"), role: .destructive) {
                let succeeded = controller.removeJSONValue(
                    at: request.path,
                    expectedSessionGeneration: request.expectedSessionGeneration
                )
                if succeeded {
                    removalRequest = nil
                } else if controller.jsonEditingIssue?.kind == .documentChanged {
                    removalRequest = nil
                }
            }
            Button(appLocale.text("Cancel", zh: "取消"), role: .cancel) {
                removalRequest = nil
            }
        } message: { request in
            Text(appLocale.text(
                "This removes \"\(request.label)\" and rewrites the JSON document.",
                zh: "这将删除“\(request.label)”并重写 JSON 文档。"
            ))
        }
    }

    private func presentValueEditor(for node: JSONTreeNode) {
        controller.dismissJSONEditingIssue()
        guard let value = controller.serializedJSONValue(
            at: node.path, expectedSessionGeneration: sessionGeneration
        ) else { return }
        editRequest = JSONTreeEditRequest(
            operation: .replaceValue,
            path: node.path,
            label: node.label,
            initialValueSource: value,
            expectedSessionGeneration: sessionGeneration
        )
    }

    private func presentObjectMemberEditor(for node: JSONTreeNode) {
        controller.dismissJSONEditingIssue()
        guard controller.isJSONEditRevisionCurrent(
            expectedSessionGeneration: sessionGeneration
        ) else { return }
        editRequest = JSONTreeEditRequest(
            operation: .addObjectMember,
            path: node.path,
            label: node.label,
            initialValueSource: "null",
            expectedSessionGeneration: sessionGeneration
        )
    }

    private func presentArrayItemEditor(for node: JSONTreeNode) {
        controller.dismissJSONEditingIssue()
        guard controller.isJSONEditRevisionCurrent(
            expectedSessionGeneration: sessionGeneration
        ) else { return }
        editRequest = JSONTreeEditRequest(
            operation: .appendArrayItem,
            path: node.path,
            label: node.label,
            initialValueSource: "null",
            expectedSessionGeneration: sessionGeneration
        )
    }

    private func presentRemovalConfirmation(for node: JSONTreeNode) {
        controller.dismissJSONEditingIssue()
        guard controller.isJSONEditRevisionCurrent(
            expectedSessionGeneration: sessionGeneration
        ) else { return }
        removalRequest = JSONTreeRemovalRequest(
            path: node.path, label: node.label,
            expectedSessionGeneration: sessionGeneration
        )
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Text(summaryDescription)
                .font(.caption)
                .foregroundStyle(colorSchemeContrast == .increased ? .primary : .secondary)
                .accessibilityLabel(summaryDescription)
                .accessibilityIdentifier(Accessibility.summary)

            Spacer(minLength: 8)

            if snapshot.reachedDepthLimit || snapshot.reachedNodeLimit {
                Label(limitDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(colorSchemeContrast == .increased ? .primary : .orange)
                    .help(limitDescription)
                    .accessibilityLabel(limitDescription)
                    .accessibilityIdentifier(Accessibility.limit)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var limitDescription: String {
        if snapshot.reachedDepthLimit && snapshot.reachedNodeLimit {
            return appLocale.text(
                "Tree limited to \(snapshot.limits.maximumNodes) nodes and depth \(snapshot.limits.maximumDepth)",
                zh: "树已限制为 \(snapshot.limits.maximumNodes) 个节点和 \(snapshot.limits.maximumDepth) 层深度"
            )
        }
        if snapshot.reachedDepthLimit {
            return appLocale.text(
                "Tree limited to depth \(snapshot.limits.maximumDepth)",
                zh: "树已限制为 \(snapshot.limits.maximumDepth) 层深度"
            )
        }
        return appLocale.text(
            "Tree limited to \(snapshot.limits.maximumNodes) nodes",
            zh: "树已限制为 \(snapshot.limits.maximumNodes) 个节点"
        )
    }

    private var summaryDescription: String {
        let statistics = snapshot.statistics
        return appLocale.text(
            "\(englishCount(statistics.keys, singular: "key", plural: "keys")) · "
                + "\(englishCount(statistics.objects, singular: "object", plural: "objects")) · "
                + "\(englishCount(statistics.arrays, singular: "array", plural: "arrays")) · "
                + "\(englishCount(statistics.values, singular: "value", plural: "values")) · "
                + "depth \(statistics.maxDepth)",
            zh: "\(statistics.keys) 个键 · \(statistics.objects) 个对象 · "
                + "\(statistics.arrays) 个数组 · \(statistics.values) 个值 · "
                + "深度 \(statistics.maxDepth)"
        )
    }

    private func englishCount(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

private struct JSONTreeNodeRow: View {
    let node: JSONTreeNode
    let editValue: () -> Void
    let addObjectMember: () -> Void
    let appendArrayItem: () -> Void
    let remove: () -> Void
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: node.label)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            if let count = node.containerCount {
                Text(containerBadge(count: count))
                    .foregroundStyle(secondaryTextColor)
            } else if let displayValue = node.displayValue {
                Button(action: editValue) {
                    Text(verbatim: displayValue)
                        .foregroundStyle(valueColor)
                        .textSelection(.enabled)
                }
                .buttonStyle(.plain)
                .help(appLocale.text("Edit JSON value", zh: "编辑 JSON 值"))
                .accessibilityLabel(appLocale.text(
                    "Edit value for \(node.label)",
                    zh: "编辑 \(node.label) 的值"
                ))
                .accessibilityHint(appLocale.text(
                    "Opens an editor that accepts any valid JSON value",
                    zh: "打开可输入任意合法 JSON 值的编辑器"
                ))
                .accessibilityIdentifier(JSONTreeView.Accessibility.edit(node.id))
            }

            if differentiateWithoutColor {
                Text(nodeTypeDescription)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color.secondary, lineWidth: 1))
                    .accessibilityHidden(true)
            }

            if let omission = node.omission {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(warningColor)
                    .accessibilityHidden(true)
                Text(omissionDescription(omission))
                    .font(.caption)
                    .foregroundStyle(warningColor)
            }

            Spacer(minLength: 8)
            nodeActions
        }
        .font(.system(.body, design: .monospaced))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(JSONTreeView.Accessibility.node(node.id))
    }

    @ViewBuilder
    private var nodeActions: some View {
        switch node.kind {
        case .object:
            compactAction(
                appLocale.text("+ Key", zh: "+ 键"),
                accessibilityLabel: appLocale.text(
                    "Add key to \(node.label)", zh: "向 \(node.label) 添加键"
                ),
                identifier: JSONTreeView.Accessibility.addKey(node.id),
                action: addObjectMember
            )
        case .array:
            compactAction(
                appLocale.text("+ Item", zh: "+ 项"),
                accessibilityLabel: appLocale.text(
                    "Add item to \(node.label)", zh: "向 \(node.label) 添加项"
                ),
                identifier: JSONTreeView.Accessibility.addItem(node.id),
                action: appendArrayItem
            )
        case .null, .boolean, .string, .number:
            EmptyView()
        }

        if !node.path.isEmpty {
            compactAction(
                appLocale.text("Delete", zh: "删除"),
                accessibilityLabel: appLocale.text(
                    "Delete \(node.label)", zh: "删除 \(node.label)"
                ),
                identifier: JSONTreeView.Accessibility.delete(node.id),
                action: remove
            )
        }
    }

    private func compactAction(
        _ title: String,
        accessibilityLabel: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    private func containerBadge(count: Int) -> String {
        switch node.kind {
        case .array: return "[\(count)]"
        case .object: return "{\(count)}"
        case .null, .boolean, .string, .number: return ""
        }
    }

    private var valueColor: Color {
        if colorSchemeContrast == .increased || differentiateWithoutColor {
            return .primary
        }
        switch node.kind {
        case .string: return .green
        case .number: return .blue
        case .boolean: return .purple
        case .null: return .secondary
        case .array, .object: return .primary
        }
    }

    private var warningColor: Color {
        colorSchemeContrast == .increased ? .primary : .orange
    }

    private var secondaryTextColor: Color {
        colorSchemeContrast == .increased ? .primary : .secondary
    }

    private var nodeTypeDescription: String {
        switch node.kind {
        case .null: return appLocale.text("null", zh: "空值")
        case .boolean: return appLocale.text("boolean", zh: "布尔值")
        case .string: return appLocale.text("string", zh: "字符串")
        case .number: return appLocale.text("number", zh: "数字")
        case .array: return appLocale.text("array", zh: "数组")
        case .object: return appLocale.text("object", zh: "对象")
        }
    }

    private var accessibilityDescription: String {
        let description: String
        switch node.kind {
        case .null:
            description = appLocale.text(
                "\(node.label), null value",
                zh: "\(node.label)，空值"
            )
        case let .boolean(value):
            description = appLocale.text(
                "\(node.label), boolean, \(value ? "true" : "false")",
                zh: "\(node.label)，布尔值，\(value ? "真" : "假")"
            )
        case .string:
            description = appLocale.text(
                "\(node.label), string, \(node.displayValue ?? "")",
                zh: "\(node.label)，字符串，\(node.displayValue ?? "")"
            )
        case .number:
            description = appLocale.text(
                "\(node.label), number, \(node.displayValue ?? "")",
                zh: "\(node.label)，数字，\(node.displayValue ?? "")"
            )
        case let .array(count):
            let englishItems = "\(count) \(count == 1 ? "item" : "items")"
            description = appLocale.text(
                "\(node.label), array, \(englishItems)",
                zh: "\(node.label)，数组，\(count) 项"
            )
        case let .object(count):
            let englishMembers = "\(count) \(count == 1 ? "member" : "members")"
            description = appLocale.text(
                "\(node.label), object, \(englishMembers)",
                zh: "\(node.label)，对象，\(count) 个成员"
            )
        }

        guard let omission = node.omission else { return description }
        return description + appLocale.text(
            ". \(omissionDescription(omission))",
            zh: "。\(omissionDescription(omission))"
        )
    }

    private func omissionDescription(_ omission: JSONTreeNode.Omission) -> String {
        switch omission {
        case let .depthLimit(count):
            return appLocale.text(
                "… \(count) hidden at depth limit",
                zh: "… 达到深度限制，已隐藏 \(count) 项"
            )
        case let .nodeLimit(count):
            return appLocale.text(
                "… \(count) hidden at node limit",
                zh: "… 达到节点限制，已隐藏 \(count) 项"
            )
        }
    }
}

private struct JSONTreeRemovalRequest: Identifiable {
    let id = UUID()
    let path: LosslessJSONPath
    let label: String
    let expectedSessionGeneration: UInt64
}

private struct JSONTreeEditRequest: Identifiable {
    enum Operation: Equatable {
        case replaceValue
        case addObjectMember
        case appendArrayItem
    }

    let id = UUID()
    let operation: Operation
    let path: LosslessJSONPath
    let label: String
    let initialValueSource: String
    let expectedSessionGeneration: UInt64
}

private struct JSONTreeEditView: View {
    let request: JSONTreeEditRequest
    @ObservedObject var controller: PreviewController
    let locale: EditorLocale
    let dismiss: () -> Void
    @Environment(\.appLocale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?
    @State private var key = ""
    @State private var valueSource: String

    private enum Field: Hashable {
        case key
        case value
    }

    init(
        request: JSONTreeEditRequest,
        controller: PreviewController,
        locale: EditorLocale,
        dismiss: @escaping () -> Void
    ) {
        self.request = request
        self.controller = controller
        self.locale = locale
        self.dismiss = dismiss
        _valueSource = State(initialValue: request.initialValueSource)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if request.operation == .addObjectMember {
                VStack(alignment: .leading, spacing: 5) {
                    Text(appLocale.text("Key", zh: "键名"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(appLocale.text("New key name", zh: "新键名"), text: $key)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .key)
                        .accessibilityLabel(appLocale.text("JSON key", zh: "JSON 键名"))
                        .accessibilityIdentifier(JSONTreeView.Accessibility.editorKey)
                        .onSubmit { focusedField = .value }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(appLocale.text("JSON value", zh: "JSON 值"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    appLocale.text("JSON value", zh: "JSON 值"),
                    text: $valueSource
                )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 430)
                    .focused($focusedField, equals: .value)
                    .accessibilityLabel(appLocale.text(
                        "JSON value source", zh: "JSON 值源码"
                    ))
                    .accessibilityHint(appLocale.text(
                        "Enter one complete JSON value. Strings require quotation marks.",
                        zh: "输入一个完整 JSON 值；字符串必须带引号。"
                    ))
                    .accessibilityIdentifier(JSONTreeView.Accessibility.editorValue)
                    .onSubmit { submit() }
            }

            Text(appLocale.text(
                "Enter one complete JSON value. Strings require quotation marks.",
                zh: "请输入一个完整 JSON 值；字符串请保留引号。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if let issue = controller.jsonEditingIssue {
                Label(localizedIssue(issue), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(JSONTreeView.Accessibility.editorError)
            }

            HStack {
                Spacer()
                Button(appLocale.text("Cancel", zh: "取消"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(JSONTreeView.Accessibility.editorCancel)

                Button(actionTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.operation == .addObjectMember && key.isEmpty)
                    .accessibilityHint(appLocale.text(
                        "Validates the value and applies one undoable document edit",
                        zh: "验证该值并应用一次可撤销的文档编辑"
                    ))
                    .accessibilityIdentifier(JSONTreeView.Accessibility.editorSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 500)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(JSONTreeView.Accessibility.editor)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .onAppear {
            focusedField = request.operation == .addObjectMember ? .key : .value
        }
        .onChange(of: controller.contentRevision) { _, _ in
            if !controller.isJSONEditRevisionCurrent(
                expectedSessionGeneration: request.expectedSessionGeneration
            ) {
                dismiss()
            }
        }
        .appLocale(locale)
    }

    private var title: String {
        switch request.operation {
        case .replaceValue:
            return appLocale.text(
                "Edit JSON Value — \(request.label)",
                zh: "编辑 JSON 值 — \(request.label)"
            )
        case .addObjectMember:
            return appLocale.text(
                "Add Key — \(request.label)",
                zh: "添加键 — \(request.label)"
            )
        case .appendArrayItem:
            return appLocale.text(
                "Add Array Item — \(request.label)",
                zh: "添加数组项 — \(request.label)"
            )
        }
    }

    private var actionTitle: String {
        switch request.operation {
        case .replaceValue: return appLocale.text("Replace", zh: "替换")
        case .addObjectMember, .appendArrayItem:
            return appLocale.text("Add", zh: "添加")
        }
    }

    private func submit() {
        let succeeded: Bool
        switch request.operation {
        case .replaceValue:
            succeeded = controller.replaceJSONValue(
                at: request.path,
                with: valueSource,
                expectedSessionGeneration: request.expectedSessionGeneration
            )
        case .addObjectMember:
            succeeded = controller.addJSONObjectMember(
                at: request.path,
                key: key,
                valueSource: valueSource,
                expectedSessionGeneration: request.expectedSessionGeneration
            )
        case .appendArrayItem:
            succeeded = controller.appendJSONArrayItem(
                at: request.path,
                valueSource: valueSource,
                expectedSessionGeneration: request.expectedSessionGeneration
            )
        }
        if succeeded { dismiss() }
    }

    private func localizedIssue(_ issue: JSONEditingIssue) -> String {
        let detail = appLocale.localizedPresentation(issue.content)
        switch issue.kind {
        case .invalidValue:
            return appLocale.text(
                "Invalid JSON value: \(detail)",
                zh: "JSON 值无效：\(detail)"
            )
        case .unexpected:
            return appLocale.text(
                "The JSON edit could not be completed: \(detail)",
                zh: "无法完成 JSON 编辑：\(detail)"
            )
        default:
            return detail
        }
    }
}

private struct JSONEditingIssueBanner: View {
    let issue: JSONEditingIssue
    let dismiss: () -> Void
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(appLocale.text("Dismiss", zh: "忽略"))
            .accessibilityLabel(appLocale.text("Dismiss JSON edit error", zh: "忽略 JSON 编辑错误"))
            .accessibilityIdentifier(JSONTreeView.Accessibility.editErrorDismiss)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(JSONTreeView.Accessibility.editError)
    }

    private var message: String {
        appLocale.localizedPresentation(issue.content)
    }
}
