import Foundation

/// The exact command subset recorded by the Electron macro implementation.
///
/// Persisting an enum instead of an arbitrary command string is a deliberate
/// security boundary: loading a project file can never manufacture a route to
/// file, process, workspace, plug-in, or macro-management commands.
public enum MacroCommand: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case toggleComment = "toggle-comment"
    case moveLineUp = "move-line-up"
    case moveLineDown = "move-line-down"
    case copyLineUp = "copy-line-up"
    case copyLineDown = "copy-line-down"
    case deleteLine = "delete-line"
    case duplicateSelection = "duplicate-selection"
    case sortLines = "sort-lines"
    case wrapParagraph80 = "wrap-paragraph-80"
    case unwrapParagraph = "unwrap-paragraph"

    public var commandID: String { rawValue }
}

/// One ordered macro operation, wire-compatible with Electron's `MacroStep`.
public enum MacroStep: Equatable, Sendable {
    case command(MacroCommand)
    case edits([TextEdit])

    public var command: MacroCommand? {
        guard case let .command(command) = self else { return nil }
        return command
    }

    public var edits: [TextEdit]? {
        guard case let .edits(edits) = self else { return nil }
        return edits
    }
}

public enum MacroReplayOperation: Equatable, Sendable {
    case command(MacroCommand)
    case edits([TextEdit])
    case legacyText(String)
}

extension MacroStep: Codable {
    private enum Kind: String, Codable {
        case command
        case edits
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case command
        case edits
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .command:
            self = .command(try values.decode(MacroCommand.self, forKey: .command))
        case .edits:
            let edits = try values.decode([TextEdit].self, forKey: .edits)
            guard !edits.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .edits, in: values,
                    debugDescription: "A macro edit step cannot be empty."
                )
            }
            self = .edits(edits)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .command(command):
            try values.encode(Kind.command, forKey: .kind)
            try values.encode(command, forKey: .command)
        case let .edits(edits):
            try values.encode(Kind.edits, forKey: .kind)
            try values.encode(edits, forKey: .edits)
        }
    }
}

/// A project-owned declarative macro. `commands`, `edits`, and `text` retain
/// compatibility with the older Electron formats; new recordings use `steps`.
public struct SavedMacro: Codable, Equatable, Sendable {
    public var name: String
    public var commands: [MacroCommand]
    public var steps: [MacroStep]?
    public var edits: [TextEdit]?
    public var text: String?

    public init(
        name: String,
        commands: [MacroCommand] = [],
        steps: [MacroStep]? = nil,
        edits: [TextEdit]? = nil,
        text: String? = nil
    ) {
        self.name = name
        self.commands = commands
        self.steps = steps
        self.edits = edits
        self.text = text
    }

    /// Ordered operations to execute, preserving Electron's compatibility
    /// precedence: steps, otherwise legacy edits/snapshot, then commands.
    public var replayOperations: [MacroReplayOperation] {
        if let steps, !steps.isEmpty {
            return steps.map { step in
                switch step {
                case let .command(command): .command(command)
                case let .edits(edits): .edits(edits)
                }
            }
        }
        var result: [MacroReplayOperation] = []
        if let edits, !edits.isEmpty {
            result.append(.edits(edits))
        } else if let text {
            result.append(.legacyText(text))
        }
        result.append(contentsOf: commands.map(MacroReplayOperation.command))
        return result
    }
}

public struct MacroLimits: Equatable, Sendable {
    public static let standard = MacroLimits()

    public var maximumMacros: Int
    public var maximumSteps: Int
    public var maximumLegacyCommands: Int
    public var maximumEditsPerStep: Int
    public var maximumTotalEdits: Int
    public var maximumNameUTF16Length: Int
    public var maximumCommandUTF16Length: Int
    public var maximumInsertUTF16Length: Int
    public var maximumTotalInsertedUTF16Length: Int
    public var maximumLegacyTextUTF16Length: Int
    public var maximumPosition: Int
    public var maximumSerializedBytes: Int

    public init(
        maximumMacros: Int = 100,
        maximumSteps: Int = 1_000,
        maximumLegacyCommands: Int = 200,
        maximumEditsPerStep: Int = 1_000,
        maximumTotalEdits: Int = 1_000,
        maximumNameUTF16Length: Int = 100,
        maximumCommandUTF16Length: Int = 100,
        maximumInsertUTF16Length: Int = 2 * 1_024 * 1_024,
        maximumTotalInsertedUTF16Length: Int = 2 * 1_024 * 1_024,
        maximumLegacyTextUTF16Length: Int = 2 * 1_024 * 1_024,
        maximumPosition: Int = 200_000_000,
        maximumSerializedBytes: Int = 16 * 1_024 * 1_024
    ) {
        precondition(maximumMacros >= 1)
        precondition(maximumSteps >= 1)
        precondition(maximumLegacyCommands >= 1)
        precondition(maximumEditsPerStep >= 1)
        precondition(maximumTotalEdits >= 1)
        precondition(maximumNameUTF16Length >= 1)
        precondition(maximumCommandUTF16Length >= 1)
        precondition(maximumInsertUTF16Length >= 0)
        precondition(maximumTotalInsertedUTF16Length >= 0)
        precondition(maximumLegacyTextUTF16Length >= 0)
        precondition(maximumPosition >= 0)
        precondition(maximumSerializedBytes >= 2)
        self.maximumMacros = maximumMacros
        self.maximumSteps = maximumSteps
        self.maximumLegacyCommands = maximumLegacyCommands
        self.maximumEditsPerStep = maximumEditsPerStep
        self.maximumTotalEdits = maximumTotalEdits
        self.maximumNameUTF16Length = maximumNameUTF16Length
        self.maximumCommandUTF16Length = maximumCommandUTF16Length
        self.maximumInsertUTF16Length = maximumInsertUTF16Length
        self.maximumTotalInsertedUTF16Length = maximumTotalInsertedUTF16Length
        self.maximumLegacyTextUTF16Length = maximumLegacyTextUTF16Length
        self.maximumPosition = maximumPosition
        self.maximumSerializedBytes = maximumSerializedBytes
    }
}

public enum MacroSanitizerError: Error, Equatable, LocalizedError, Sendable {
    case serializedDataTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJSON
    case invalidRoot
    case invalidMacro

    public var errorDescription: String? {
        switch self {
        case let .serializedDataTooLarge(actual, maximum):
            return "Macro data uses \(actual) bytes; the maximum is \(maximum) bytes."
        case .invalidJSON:
            return "The macro file is not valid JSON."
        case .invalidRoot:
            return "The macro file must contain a JSON array."
        case .invalidMacro:
            return "The macro is invalid or exceeds a resource limit."
        }
    }
}

public enum MacroRecordingError: Error, Equatable, LocalizedError, Sendable {
    case editStepRejected
    case recordingLimitReached(maximumSteps: Int)

    public var errorDescription: String? {
        switch self {
        case .editStepRejected:
            return "The editor transaction cannot be represented as a safe macro step."
        case let .recordingLimitReached(maximum):
            return "Macro recording reached the \(maximum)-step limit."
        }
    }
}

/// Value-type recording state used by the application controller. Commands
/// are typed at the API boundary and selections are intentionally omitted.
public struct MacroRecording: Equatable, Sendable {
    public let limits: MacroLimits
    public private(set) var isRecording = false
    public private(set) var steps: [MacroStep] = []
    private var recordedEditCount = 0
    private var recordedInsertedUTF16Count = 0

    public init(limits: MacroLimits = .standard) {
        self.limits = limits
    }

    public mutating func start() {
        steps.removeAll(keepingCapacity: true)
        recordedEditCount = 0
        recordedInsertedUTF16Count = 0
        isRecording = true
    }

    @discardableResult
    public mutating func stop() -> [MacroStep] {
        isRecording = false
        return steps
    }

    public mutating func toggle() -> Bool {
        if isRecording {
            stop()
        } else {
            start()
        }
        return isRecording
    }

    public mutating func record(command: MacroCommand) throws {
        try append(.command(command))
    }

    public mutating func record(edits: [TextEdit]) throws {
        guard isRecording else { return }
        let safe = try MacroSanitizer.validatedRecordingEdits(edits, limits: limits)
        let inserted = safe.reduce(0) { partial, edit in
            let count = edit.insert.utf16.count
            return partial > Int.max - count ? Int.max : partial + count
        }
        guard recordedEditCount <= limits.maximumTotalEdits - safe.count,
              inserted <= limits.maximumTotalInsertedUTF16Length
                - recordedInsertedUTF16Count else {
            isRecording = false
            throw MacroRecordingError.recordingLimitReached(
                maximumSteps: limits.maximumSteps
            )
        }
        try append(.edits(safe))
        recordedEditCount += safe.count
        recordedInsertedUTF16Count += inserted
    }

    private mutating func append(_ step: MacroStep) throws {
        guard isRecording else { return }
        guard steps.count < limits.maximumSteps else {
            isRecording = false
            throw MacroRecordingError.recordingLimitReached(
                maximumSteps: limits.maximumSteps
            )
        }
        steps.append(step)
    }
}

/// Strict, field-by-field parser for untrusted project macro JSON. Unknown
/// commands and malformed child edits are discarded rather than dispatched.
public enum MacroSanitizer {
    public static func parse(
        _ data: Data,
        limits: MacroLimits = .standard
    ) throws -> [SavedMacro] {
        guard data.count <= limits.maximumSerializedBytes else {
            throw MacroSanitizerError.serializedDataTooLarge(
                actualBytes: data.count, maximumBytes: limits.maximumSerializedBytes
            )
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw MacroSanitizerError.invalidJSON
        }
        guard let values = root as? [Any] else {
            throw MacroSanitizerError.invalidRoot
        }
        return sanitizeObjects(values, limits: limits)
    }

    public static func encodedData(
        _ macros: [SavedMacro],
        limits: MacroLimits = .standard
    ) throws -> Data {
        var bounded: [SavedMacro] = []
        for macro in macros {
            if let safe = sanitize(macro, limits: limits) { bounded.append(safe) }
            if bounded.count == limits.maximumMacros { break }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bounded)
        guard data.count <= limits.maximumSerializedBytes else {
            throw MacroSanitizerError.serializedDataTooLarge(
                actualBytes: data.count, maximumBytes: limits.maximumSerializedBytes
            )
        }
        return data
    }

    public static func sanitize(
        _ macro: SavedMacro,
        limits: MacroLimits = .standard
    ) -> SavedMacro? {
        let name = macro.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.utf8.contains(0),
              name.utf16.count <= limits.maximumNameUTF16Length else { return nil }

        let commands = Array(macro.commands.prefix(limits.maximumLegacyCommands))
        var budget = EditBudget(limits: limits)
        let steps = macro.steps.map { sanitizeSteps($0, budget: &budget) }
        var legacyBudget = EditBudget(limits: limits)
        let edits = macro.edits.map { sanitizeEdits($0, budget: &legacyBudget) }
        let text = macro.text.flatMap { value in
            value.utf16.count <= limits.maximumLegacyTextUTF16Length ? value : nil
        }
        return SavedMacro(
            name: name,
            commands: commands,
            steps: steps.flatMap { $0.isEmpty ? nil : $0 },
            edits: edits.flatMap { $0.isEmpty ? nil : $0 },
            text: text
        )
    }

    public static func sanitizedEdits(
        _ edits: [TextEdit],
        limits: MacroLimits = .standard
    ) -> [TextEdit] {
        var budget = EditBudget(limits: limits)
        return sanitizeEdits(edits, budget: &budget)
    }

    public static func validatedRecordingEdits(
        _ edits: [TextEdit],
        limits: MacroLimits = .standard
    ) throws -> [TextEdit] {
        guard !edits.isEmpty, edits.count <= limits.maximumEditsPerStep,
              edits.count <= limits.maximumTotalEdits else {
            throw MacroRecordingError.editStepRejected
        }
        var inserted = 0
        for edit in edits {
            let count = edit.insert.utf16.count
            guard edit.from >= 0, edit.to >= edit.from,
                  edit.from <= limits.maximumPosition, edit.to <= limits.maximumPosition,
                  count <= limits.maximumInsertUTF16Length,
                  count <= limits.maximumTotalInsertedUTF16Length - inserted else {
                throw MacroRecordingError.editStepRejected
            }
            inserted += count
        }
        guard let transaction = try? TextTransaction(edits: edits) else {
            throw MacroRecordingError.editStepRejected
        }
        return transaction.edits
    }

    private struct EditBudget {
        let limits: MacroLimits
        var editCount = 0
        var insertedUTF16Count = 0

        mutating func accepts(_ edit: TextEdit) -> Bool {
            let inserted = edit.insert.utf16.count
            guard editCount < limits.maximumTotalEdits,
                  edit.from >= 0, edit.to >= edit.from,
                  edit.from <= limits.maximumPosition, edit.to <= limits.maximumPosition,
                  inserted <= limits.maximumInsertUTF16Length,
                  inserted <= limits.maximumTotalInsertedUTF16Length - insertedUTF16Count
            else { return false }
            editCount += 1
            insertedUTF16Count += inserted
            return true
        }
    }

    private static func sanitizeObjects(
        _ values: [Any],
        limits: MacroLimits
    ) -> [SavedMacro] {
        var result: [SavedMacro] = []
        result.reserveCapacity(min(values.count, limits.maximumMacros))
        for value in values {
            guard result.count < limits.maximumMacros,
                  let raw = value as? [String: Any],
                  let rawName = raw["name"] as? String,
                  raw["commands"] is [Any]
            else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.utf8.contains(0),
                  name.utf16.count <= limits.maximumNameUTF16Length else { continue }

            let commands = ((raw["commands"] as? [Any]) ?? [])
                .compactMap { value -> MacroCommand? in
                    guard let commandID = value as? String,
                          commandID.utf16.count <= limits.maximumCommandUTF16Length
                    else { return nil }
                    return MacroCommand(rawValue: commandID)
                }
            let boundedCommands = Array(commands.prefix(limits.maximumLegacyCommands))
            var stepBudget = EditBudget(limits: limits)
            let steps = sanitizeRawSteps(raw["steps"], budget: &stepBudget)
            var legacyBudget = EditBudget(limits: limits)
            let edits = sanitizeRawEdits(raw["edits"], budget: &legacyBudget)
            let text = (raw["text"] as? String).flatMap { value in
                value.utf16.count <= limits.maximumLegacyTextUTF16Length ? value : nil
            }
            result.append(SavedMacro(
                name: name,
                commands: boundedCommands,
                steps: steps.isEmpty ? nil : steps,
                edits: edits.isEmpty ? nil : edits,
                text: text
            ))
        }
        return result
    }

    private static func sanitizeSteps(
        _ input: [MacroStep],
        budget: inout EditBudget
    ) -> [MacroStep] {
        var result: [MacroStep] = []
        for step in input {
            guard result.count < budget.limits.maximumSteps else { break }
            switch step {
            case let .command(command):
                result.append(.command(command))
            case let .edits(edits):
                let safe = sanitizeEdits(edits, budget: &budget)
                if !safe.isEmpty { result.append(.edits(safe)) }
            }
        }
        return result
    }

    private static func sanitizeRawSteps(
        _ value: Any?,
        budget: inout EditBudget
    ) -> [MacroStep] {
        guard let values = value as? [Any] else { return [] }
        var result: [MacroStep] = []
        for value in values {
            guard result.count < budget.limits.maximumSteps else { break }
            guard let raw = value as? [String: Any],
                  let kind = raw["kind"] as? String else { continue }
            if kind == "command",
               let commandID = raw["command"] as? String,
               commandID.utf16.count <= budget.limits.maximumCommandUTF16Length,
               let command = MacroCommand(rawValue: commandID) {
                result.append(.command(command))
            } else if kind == "edits" {
                let edits = sanitizeRawEdits(raw["edits"], budget: &budget)
                if !edits.isEmpty { result.append(.edits(edits)) }
            }
        }
        return result
    }

    private static func sanitizeEdits(
        _ input: [TextEdit],
        budget: inout EditBudget
    ) -> [TextEdit] {
        var result: [TextEdit] = []
        for edit in input {
            guard result.count < budget.limits.maximumEditsPerStep else { break }
            guard budget.accepts(edit) else { continue }
            result.append(edit)
        }
        return normalizedEdits(result)
    }

    private static func sanitizeRawEdits(
        _ value: Any?,
        budget: inout EditBudget
    ) -> [TextEdit] {
        guard let values = value as? [Any] else { return [] }
        var result: [TextEdit] = []
        for value in values {
            guard result.count < budget.limits.maximumEditsPerStep else { break }
            guard let raw = value as? [String: Any],
                  let from = integer(raw["from"]),
                  let to = integer(raw["to"]),
                  let insert = raw["insert"] as? String else { continue }
            let edit = TextEdit(from: from, to: to, insert: insert)
            guard budget.accepts(edit) else { continue }
            result.append(edit)
        }
        return normalizedEdits(result)
    }

    /// Invalid overlap invalidates only that edit batch. It must never be
    /// deferred until replay where it could partially mutate a document.
    private static func normalizedEdits(_ edits: [TextEdit]) -> [TextEdit] {
        guard !edits.isEmpty, let transaction = try? TextTransaction(edits: edits) else {
            return []
        }
        return transaction.edits
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type != "c" && type != "B" else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
    }

}
