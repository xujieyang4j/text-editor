import Foundation

/// A JSON/JavaScript string represented as UTF-16 code units.
///
/// Swift `String` repairs isolated UTF-16 surrogates, while ECMAScript strings
/// may contain them and JSON.parse accepts their escaped form. Keeping the code
/// units makes `"\uD800"` round-trip exactly like JSON.parse/JSON.stringify.
/// `stringValue` is convenient for UI display; it necessarily substitutes
/// U+FFFD if the JSON string contains an isolated surrogate.
public struct LosslessJSONString: Hashable, Sendable, CustomStringConvertible {
    public let utf16: [UInt16]

    public init(_ value: String) {
        utf16 = Array(value.utf16)
    }

    public init(utf16: [UInt16]) {
        self.utf16 = utf16
    }

    public var stringValue: String { String(decoding: utf16, as: UTF16.self) }
    public var description: String { stringValue }
}

/// A JSON number kept in its original lexical form.
///
/// No binary floating-point conversion is performed, so integers of any size,
/// negative zero, decimal trailing zeroes, and exponent spelling all survive a
/// parse/stringify round trip. As in the Electron implementation, manually
/// constructed values are trusted by the serializer.
public struct LosslessJSONNumber: Equatable, Hashable, Sendable {
    public let raw: String

    public var rawValue: String { raw }

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(raw: String) {
        self.raw = raw
    }

    public init(rawValue: String) {
        self.raw = rawValue
    }
}

/// One enumerable property in a lossless JSON object.
public struct LosslessJSONObjectMember: Sendable {
    public let losslessKey: LosslessJSONString
    public var value: LosslessJSONValue

    public var key: String { losslessKey.stringValue }

    public init(key: String, value: LosslessJSONValue) {
        losslessKey = LosslessJSONString(key)
        self.value = value
    }

    public init(losslessKey: LosslessJSONString, value: LosslessJSONValue) {
        self.losslessKey = losslessKey
        self.value = value
    }
}

extension LosslessJSONObjectMember: Equatable {
    public static func == (
        lhs: LosslessJSONObjectMember,
        rhs: LosslessJSONObjectMember
    ) -> Bool {
        lhs.losslessKey == rhs.losslessKey && lhs.value == rhs.value
    }
}

/// An ordered, unique-key object matching JavaScript own-property enumeration.
///
/// Defining an existing key replaces its value without moving the key. New
/// canonical array-index keys (`0` ... `4294967294`) are enumerated first in
/// numeric order; other keys retain insertion order. This reproduces the
/// `Object.create(null)` plus `Object.defineProperty` behavior used by the
/// Electron lossless JSON parser, including its last-value-wins duplicate-key
/// policy.
public struct LosslessJSONObject: Sendable {
    fileprivate var storage: [LosslessJSONObjectMember]
    private var keyIndices: [[UInt16]: Int]

    public init() {
        storage = []
        keyIndices = [:]
    }

    public init(_ members: [LosslessJSONObjectMember]) {
        var uniqueMembers: [LosslessJSONObjectMember] = []
        var creationIndices: [[UInt16]: Int] = [:]
        uniqueMembers.reserveCapacity(members.count)
        creationIndices.reserveCapacity(members.count)
        for member in members {
            let identity = member.losslessKey.utf16
            if let existing = creationIndices[identity] {
                uniqueMembers[existing].value = member.value
            } else {
                creationIndices[identity] = uniqueMembers.count
                uniqueMembers.append(member)
            }
        }

        // Object.entries enumerates canonical array-index properties before
        // other strings. Including the creation offset in every comparison
        // makes ordinary-key insertion order independent of sort stability.
        storage = uniqueMembers.enumerated().sorted { lhs, rhs in
            let lhsIndex = Self.arrayIndex(for: lhs.element.losslessKey)
            let rhsIndex = Self.arrayIndex(for: rhs.element.losslessKey)
            switch (lhsIndex, rhsIndex) {
            case let (lhsIndex?, rhsIndex?): return lhsIndex < rhsIndex
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
        keyIndices = [:]
        keyIndices.reserveCapacity(storage.count)
        for index in storage.indices {
            keyIndices[storage[index].losslessKey.utf16] = index
        }
    }

    public init(members: [LosslessJSONObjectMember]) {
        self.init(members)
    }

    public var members: [LosslessJSONObjectMember] { storage }
    public var keys: [String] { storage.map(\.key) }
    public var losslessKeys: [LosslessJSONString] { storage.map(\.losslessKey) }
    public var values: [LosslessJSONValue] { storage.map(\.value) }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public subscript(key: String) -> LosslessJSONValue? {
        get { self[LosslessJSONString(key)] }
        set { self[LosslessJSONString(key)] = newValue }
    }

    public subscript(key: LosslessJSONString) -> LosslessJSONValue? {
        get {
            guard let index = index(forKey: key) else { return nil }
            return storage[index].value
        }
        set {
            if let newValue {
                setValue(newValue, forKey: key)
            } else {
                _ = removeValue(forKey: key)
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        contains(LosslessJSONString(key))
    }

    public func contains(_ key: LosslessJSONString) -> Bool {
        index(forKey: key) != nil
    }

    /// Implements JavaScript's DefineOwnProperty replacement and enumeration
    /// order for the string-keyed object used by the reference parser.
    public mutating func setValue(_ value: LosslessJSONValue, forKey key: String) {
        setValue(value, forKey: LosslessJSONString(key))
    }

    public mutating func setValue(
        _ value: LosslessJSONValue,
        forKey key: LosslessJSONString
    ) {
        if let existing = index(forKey: key) {
            storage[existing].value = value
            return
        }

        let member = LosslessJSONObjectMember(losslessKey: key, value: value)
        guard let arrayIndex = Self.arrayIndex(for: key) else {
            keyIndices[key.utf16] = storage.count
            storage.append(member)
            return
        }

        var lowerBound = storage.startIndex
        var upperBound = storage.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            guard let middleIndex = Self.arrayIndex(for: storage[middle].losslessKey) else {
                upperBound = middle
                continue
            }
            if middleIndex < arrayIndex {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let insertionIndex = lowerBound
        storage.insert(member, at: insertionIndex)
        rebuildKeyIndices(startingAt: insertionIndex)
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> LosslessJSONValue? {
        removeValue(forKey: LosslessJSONString(key))
    }

    @discardableResult
    public mutating func removeValue(
        forKey key: LosslessJSONString
    ) -> LosslessJSONValue? {
        guard let index = index(forKey: key) else { return nil }
        let result = storage.remove(at: index).value
        keyIndices.removeValue(forKey: key.utf16)
        rebuildKeyIndices(startingAt: index)
        return result
    }

    fileprivate func index(forKey key: String) -> Int? {
        index(forKey: LosslessJSONString(key))
    }

    fileprivate func index(forKey key: LosslessJSONString) -> Int? {
        keyIndices[key.utf16]
    }

    private mutating func rebuildKeyIndices(startingAt start: Int) {
        guard start < storage.endIndex else { return }
        for index in start ..< storage.endIndex {
            keyIndices[storage[index].losslessKey.utf16] = index
        }
    }

    /// ECMA-262 array-index property names are canonical UInt32 spellings
    /// except for UInt32.max. Comparing the decimal spelling also rejects
    /// leading zeroes, signs, and whitespace accepted by integer initializers.
    fileprivate static func arrayIndex(for key: LosslessJSONString) -> UInt32? {
        guard !key.utf16.isEmpty else { return nil }
        if key.utf16.count > 1, key.utf16[0] == 0x30 { return nil }
        var parsed: UInt64 = 0
        for codeUnit in key.utf16 {
            guard codeUnit >= 0x30, codeUnit <= 0x39 else { return nil }
            parsed = parsed * 10 + UInt64(codeUnit - 0x30)
            guard parsed < UInt64(UInt32.max) else { return nil }
        }
        return UInt32(parsed)
    }
}

extension LosslessJSONObject: Equatable {
    public static func == (lhs: LosslessJSONObject, rhs: LosslessJSONObject) -> Bool {
        lhs.storage == rhs.storage
    }
}

extension LosslessJSONObject: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = LosslessJSONObjectMember

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }

    public func index(after index: Int) -> Int { storage.index(after: index) }
    public func index(before index: Int) -> Int { storage.index(before: index) }
    public subscript(position: Int) -> LosslessJSONObjectMember { storage[position] }
}

/// The complete value DTO used by formatting and JSON tree editing.
public indirect enum LosslessJSONValue: Sendable {
    case null
    case bool(Bool)
    case string(LosslessJSONString)
    case number(LosslessJSONNumber)
    case array([LosslessJSONValue])
    case object(LosslessJSONObject)

    public static func object(
        members: [LosslessJSONObjectMember]
    ) -> LosslessJSONValue {
        .object(LosslessJSONObject(members))
    }

    public static func string(_ value: String) -> LosslessJSONValue {
        .string(LosslessJSONString(value))
    }

}

extension LosslessJSONValue: Equatable {
    public static func == (lhs: LosslessJSONValue, rhs: LosslessJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            true
        case let (.bool(lhs), .bool(rhs)):
            lhs == rhs
        case let (.string(lhs), .string(rhs)):
            lhs == rhs
        case let (.number(lhs), .number(rhs)):
            lhs == rhs
        case let (.array(lhs), .array(rhs)):
            lhs == rhs
        case let (.object(lhs), .object(rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

/// One component in a JSON tree path. String keys and array offsets remain
/// distinct, just like the `(string | number)[]` path in the Electron view.
public enum LosslessJSONPathComponent: Sendable {
    case key(LosslessJSONString)
    case index(Int)

    public static func key(_ value: String) -> LosslessJSONPathComponent {
        .key(LosslessJSONString(value))
    }
}

extension LosslessJSONPathComponent: Hashable {
    public static func == (
        lhs: LosslessJSONPathComponent,
        rhs: LosslessJSONPathComponent
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.key(lhs), .key(rhs)):
            lhs == rhs
        case let (.index(lhs), .index(rhs)):
            lhs == rhs
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .key(key):
            hasher.combine(0)
            hasher.combine(key)
        case let .index(index):
            hasher.combine(1)
            hasher.combine(index)
        }
    }
}

public typealias LosslessJSONPath = [LosslessJSONPathComponent]

public struct LosslessJSONStatistics: Equatable, Sendable {
    public var keys: Int
    public var objects: Int
    public var arrays: Int
    public var values: Int
    public var maxDepth: Int

    public init(
        keys: Int = 0,
        objects: Int = 0,
        arrays: Int = 0,
        values: Int = 0,
        maxDepth: Int = 0
    ) {
        self.keys = keys
        self.objects = objects
        self.arrays = arrays
        self.values = values
        self.maxDepth = maxDepth
    }
}

/// Resource budgets applied before and during parsing untrusted editor text.
/// Root depth is zero and every JSON value, including a container, is one node.
public struct LosslessJSONLimits: Equatable, Sendable {
    public static let hardMaximumDepth = 1_024
    public static let defaultMaximumDepth = 256
    public static let defaultMaximumNodes = 100_000
    public static let defaultMaximumSourceLength = 2 * 1_024 * 1_024
    public static let defaultMaximumBytes = defaultMaximumSourceLength
    public static let defaultMaximumIndent = 64
    public static let `default` = LosslessJSONLimits()

    public var maximumDepth: Int
    public var maximumNodes: Int
    /// Maximum UTF-16 code units accepted or emitted, matching `source.length`
    /// in the Electron JSON view rather than the UTF-8 file byte count.
    public var maximumBytes: Int
    public var maximumIndent: Int

    public var maximumNodeCount: Int { maximumNodes }
    public var maximumSourceLength: Int { maximumBytes }
    public var maximumSourceUTF16Count: Int { maximumBytes }

    public init(
        maximumDepth: Int = LosslessJSONLimits.defaultMaximumDepth,
        maximumNodes: Int = LosslessJSONLimits.defaultMaximumNodes,
        maximumBytes: Int = LosslessJSONLimits.defaultMaximumBytes,
        maximumIndent: Int = LosslessJSONLimits.defaultMaximumIndent
    ) {
        precondition(
            maximumDepth >= 0 && maximumDepth <= Self.hardMaximumDepth,
            "maximumDepth must be within 0...\(Self.hardMaximumDepth)"
        )
        precondition(maximumNodes >= 0, "maximumNodes must not be negative")
        precondition(maximumBytes >= 0, "maximumBytes must not be negative")
        precondition(maximumIndent >= 0, "maximumIndent must not be negative")
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumBytes = maximumBytes
        self.maximumIndent = maximumIndent
    }

    public init(
        maximumSourceLength: Int,
        maximumDepth: Int,
        maximumNodeCount: Int,
        maximumIndent: Int = LosslessJSONLimits.defaultMaximumIndent
    ) {
        self.init(
            maximumDepth: maximumDepth,
            maximumNodes: maximumNodeCount,
            maximumBytes: maximumSourceLength,
            maximumIndent: maximumIndent
        )
    }

    public init(
        maximumSourceUTF16Count: Int,
        maximumDepth: Int,
        maximumNodeCount: Int,
        maximumIndent: Int = LosslessJSONLimits.defaultMaximumIndent
    ) {
        self.init(
            maximumSourceLength: maximumSourceUTF16Count,
            maximumDepth: maximumDepth,
            maximumNodeCount: maximumNodeCount,
            maximumIndent: maximumIndent
        )
    }
}

/// Structured parser failure with the same one-based UTF-16 line and column
/// convention as the JavaScript implementation.
public struct LosslessJSONParseError: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        case syntax
        case sourceTooLarge(actualLength: Int, maximumLength: Int)
        case nestingTooDeep(actualDepth: Int, maximumDepth: Int)
        case tooManyNodes(actualNodes: Int, maximumNodes: Int)
    }

    public let message: String
    public let line: Int
    public let column: Int
    public let utf16Offset: Int
    public let kind: Kind

    public init(
        message: String,
        line: Int,
        column: Int,
        utf16Offset: Int,
        kind: Kind = .syntax
    ) {
        self.message = message
        self.line = line
        self.column = column
        self.utf16Offset = utf16Offset
        self.kind = kind
    }

    public var errorDescription: String? { description }

    public var description: String {
        "\(message) Line \(line), column \(column)."
    }
}

extension LosslessJSONParseError: CustomStringConvertible {}

public enum LosslessJSONResourceError: Error, Equatable, LocalizedError, Sendable {
    case sourceTooLarge(actualLength: Int, maximumLength: Int)
    case nestingTooDeep(actualDepth: Int, maximumDepth: Int)
    case tooManyNodes(actualNodes: Int, maximumNodes: Int)
    case indentTooLarge(actualIndent: Int, maximumIndent: Int)

    public var errorDescription: String? {
        switch self {
        case let .sourceTooLarge(actual, maximum):
            "JSON output uses \(actual) UTF-16 code units; the maximum is \(maximum)."
        case let .nestingTooDeep(actual, maximum):
            "JSON depth \(actual) exceeds the maximum of \(maximum)."
        case let .tooManyNodes(actual, maximum):
            "JSON node count \(actual) exceeds the maximum of \(maximum)."
        case let .indentTooLarge(actual, maximum):
            "JSON indent \(actual) exceeds the maximum of \(maximum)."
        }
    }

}

public enum LosslessJSONContainerKind: String, Equatable, Sendable {
    case array
    case object
}

public enum LosslessJSONTreeError: Error, Equatable, LocalizedError, Sendable {
    case pathNotFound(LosslessJSONPath)
    case typeMismatch(path: LosslessJSONPath, expected: LosslessJSONContainerKind)
    case invalidObjectKey(String)
    case duplicateObjectKey(String)
    case cannotRemoveRoot

    public var errorDescription: String? {
        switch self {
        case .pathNotFound:
            "The JSON path does not exist."
        case let .typeMismatch(_, expected):
            "The JSON path does not identify an \(expected.rawValue)."
        case .invalidObjectKey:
            "The object key is empty or protected."
        case .duplicateObjectKey:
            "The object key already exists."
        case .cannotRemoveRoot:
            "The JSON root cannot be removed."
        }
    }
}

/// Foundation-only lossless JSON parsing, formatting, and tree operations.
public enum LosslessJSON {
    public static func parse(
        _ source: String,
        limits: LosslessJSONLimits = .default
    ) throws -> LosslessJSONValue {
        let sourceLength = source.utf16.count
        guard sourceLength <= limits.maximumBytes else {
            throw LosslessJSONParseError(
                message: "JSON input exceeds the \(limits.maximumBytes)-UTF-16-code-unit limit.",
                line: 1,
                column: 1,
                utf16Offset: 0,
                kind: .sourceTooLarge(
                    actualLength: sourceLength,
                    maximumLength: limits.maximumBytes
                )
            )
        }
        return try LosslessJSONParser(source: source, limits: limits).parse()
    }

    /// Serializes with no optional whitespace when `indent <= 0`; a positive
    /// indent uses LF and that many spaces per level. No final newline is added.
    /// The explicit work stack and budgets also protect manually-created DTOs.
    public static func stringify(
        _ value: LosslessJSONValue,
        indent: Int = 0,
        limits: LosslessJSONLimits = .default
    ) throws -> String {
        guard indent <= limits.maximumIndent else {
            throw LosslessJSONResourceError.indentTooLarge(
                actualIndent: indent, maximumIndent: limits.maximumIndent
            )
        }
        let pretty = indent > 0
        enum Work {
            case value(LosslessJSONValue, Int)
            case text(String)
            case jsonString(LosslessJSONString)
            case padding(Int)
        }

        var result = ""
        var outputLength = 0
        var nodeCount = 0
        var stack: [Work] = [.value(value, 0)]

        func appendChecked(_ text: String) throws {
            let added = text.utf16.count
            let sum = outputLength.addingReportingOverflow(added)
            guard !sum.overflow, sum.partialValue <= limits.maximumBytes else {
                throw LosslessJSONResourceError.sourceTooLarge(
                    actualLength: sum.overflow ? Int.max : sum.partialValue,
                    maximumLength: limits.maximumBytes
                )
            }
            result.append(contentsOf: text)
            outputLength = sum.partialValue
        }

        func appendCheckedJSONString(_ value: LosslessJSONString) throws {
            let added = jsonStringLength(value)
            let sum = outputLength.addingReportingOverflow(added)
            guard !sum.overflow, sum.partialValue <= limits.maximumBytes else {
                throw LosslessJSONResourceError.sourceTooLarge(
                    actualLength: sum.overflow ? Int.max : sum.partialValue,
                    maximumLength: limits.maximumBytes
                )
            }
            result.append(contentsOf: jsonString(value))
            outputLength = sum.partialValue
        }

        while let work = stack.popLast() {
            switch work {
            case let .text(text):
                try appendChecked(text)
            case let .jsonString(value):
                try appendCheckedJSONString(value)
            case let .padding(depth):
                let count = depth.multipliedReportingOverflow(by: indent)
                guard !count.overflow else {
                    throw LosslessJSONResourceError.sourceTooLarge(
                        actualLength: Int.max, maximumLength: limits.maximumBytes
                    )
                }
                let sum = outputLength.addingReportingOverflow(count.partialValue)
                guard !sum.overflow, sum.partialValue <= limits.maximumBytes else {
                    throw LosslessJSONResourceError.sourceTooLarge(
                        actualLength: sum.overflow ? Int.max : sum.partialValue,
                        maximumLength: limits.maximumBytes
                    )
                }
                result.append(String(repeating: " ", count: count.partialValue))
                outputLength = sum.partialValue
            case let .value(current, depth):
                guard depth <= limits.maximumDepth else {
                    throw LosslessJSONResourceError.nestingTooDeep(
                        actualDepth: depth, maximumDepth: limits.maximumDepth
                    )
                }
                let nextCount = nodeCount.addingReportingOverflow(1)
                guard !nextCount.overflow, nextCount.partialValue <= limits.maximumNodes else {
                    throw LosslessJSONResourceError.tooManyNodes(
                        actualNodes: nextCount.overflow ? Int.max : nextCount.partialValue,
                        maximumNodes: limits.maximumNodes
                    )
                }
                nodeCount = nextCount.partialValue
                switch current {
                case .null:
                    try appendChecked("null")
                case let .bool(value):
                    try appendChecked(value ? "true" : "false")
                case let .string(value):
                    try appendCheckedJSONString(value)
                case let .number(number):
                    try appendChecked(number.raw)
                case let .array(items):
                    guard !items.isEmpty else { try appendChecked("[]"); continue }
                    stack.append(.text(pretty ? "\n]" : "]"))
                    if pretty {
                        stack.removeLast()
                        stack.append(.text("]"))
                        stack.append(.padding(depth))
                        stack.append(.text("\n"))
                    }
                    for index in items.indices.reversed() {
                        stack.append(.value(items[index], depth + 1))
                        if pretty { stack.append(.padding(depth + 1)) }
                        if index > items.startIndex {
                            stack.append(.text(pretty ? ",\n" : ","))
                        }
                    }
                    stack.append(.text("[" + (pretty ? "\n" : "")))
                case let .object(object):
                    guard !object.isEmpty else { try appendChecked("{}"); continue }
                    stack.append(.text("}"))
                    if pretty {
                        stack.append(.padding(depth))
                        stack.append(.text("\n"))
                    }
                    for index in object.indices.reversed() {
                        let member = object[index]
                        stack.append(.value(member.value, depth + 1))
                        stack.append(.text(pretty ? ": " : ":"))
                        stack.append(.jsonString(member.losslessKey))
                        if pretty { stack.append(.padding(depth + 1)) }
                        if index > object.startIndex {
                            stack.append(.text(pretty ? ",\n" : ","))
                        }
                    }
                    stack.append(.text("{" + (pretty ? "\n" : "")))
                }
            }
        }
        return result
    }

    public static func clone(
        _ value: LosslessJSONValue,
        limits: LosslessJSONLimits = .default
    ) throws -> LosslessJSONValue {
        try clone(value, indent: 0, limits: limits)
    }

    public static func clone(
        _ value: LosslessJSONValue,
        indent: Int,
        limits: LosslessJSONLimits = .default
    ) throws -> LosslessJSONValue {
        try parse(stringify(value, indent: indent, limits: limits), limits: limits)
    }

    @discardableResult
    public static func validate(
        _ value: LosslessJSONValue,
        limits: LosslessJSONLimits = .default
    ) throws -> LosslessJSONStatistics {
        var result = LosslessJSONStatistics()
        var nodeCount = 0
        var compactLength = 0
        var stack: [(LosslessJSONValue, Int)] = [(value, 0)]

        func addLength(_ amount: Int) throws {
            let sum = compactLength.addingReportingOverflow(amount)
            guard !sum.overflow, sum.partialValue <= limits.maximumBytes else {
                throw LosslessJSONResourceError.sourceTooLarge(
                    actualLength: sum.overflow ? Int.max : sum.partialValue,
                    maximumLength: limits.maximumBytes
                )
            }
            compactLength = sum.partialValue
        }

        while let (current, depth) = stack.popLast() {
            guard depth <= limits.maximumDepth else {
                throw LosslessJSONResourceError.nestingTooDeep(
                    actualDepth: depth, maximumDepth: limits.maximumDepth
                )
            }
            let nextCount = nodeCount.addingReportingOverflow(1)
            guard !nextCount.overflow, nextCount.partialValue <= limits.maximumNodes else {
                throw LosslessJSONResourceError.tooManyNodes(
                    actualNodes: nextCount.overflow ? Int.max : nextCount.partialValue,
                    maximumNodes: limits.maximumNodes
                )
            }
            nodeCount = nextCount.partialValue
            result.maxDepth = max(result.maxDepth, depth)

            switch current {
            case .null:
                result.values += 1
                try addLength(4)
            case let .bool(value):
                result.values += 1
                try addLength(value ? 4 : 5)
            case let .number(number):
                result.values += 1
                try addLength(number.raw.utf16.count)
            case let .string(value):
                result.values += 1
                try addLength(jsonStringLength(value))
            case let .array(items):
                result.arrays += 1
                try addLength(2 + max(0, items.count - 1))
                for item in items.reversed() { stack.append((item, depth + 1)) }
            case let .object(object):
                result.objects += 1
                result.keys += object.count
                try addLength(2 + max(0, object.count - 1))
                for member in object.reversed() {
                    try addLength(jsonStringLength(member.losslessKey) + 1)
                    stack.append((member.value, depth + 1))
                }
            }
        }
        return result
    }

    public static func statistics(of root: LosslessJSONValue) -> LosslessJSONStatistics {
        var result = LosslessJSONStatistics()
        var stack: [(LosslessJSONValue, Int)] = [(root, 0)]
        while let (value, depth) = stack.popLast() {
            result.maxDepth = max(result.maxDepth, depth)
            switch value {
            case let .array(items):
                result.arrays += 1
                for item in items.reversed() { stack.append((item, depth + 1)) }
            case let .object(object):
                result.objects += 1
                result.keys += object.count
                for member in object.reversed() {
                    stack.append((member.value, depth + 1))
                }
            case .null, .bool, .string, .number:
                result.values += 1
            }
        }
        return result
    }

    private static func jsonString(_ value: LosslessJSONString) -> String {
        var codeUnits: [UInt16] = [0x22]
        codeUnits.reserveCapacity(value.utf16.count + 2)
        var index = 0
        while index < value.utf16.count {
            let codeUnit = value.utf16[index]
            switch codeUnit {
            case 0x08: appendASCII("\\b", to: &codeUnits)
            case 0x09: appendASCII("\\t", to: &codeUnits)
            case 0x0a: appendASCII("\\n", to: &codeUnits)
            case 0x0c: appendASCII("\\f", to: &codeUnits)
            case 0x0d: appendASCII("\\r", to: &codeUnits)
            case 0x22: appendASCII("\\\"", to: &codeUnits)
            case 0x5c: appendASCII("\\\\", to: &codeUnits)
            case 0x00 ... 0x1f:
                appendUnicodeEscape(codeUnit, to: &codeUnits)
            case 0xd800 ... 0xdbff:
                if index + 1 < value.utf16.count,
                   value.utf16[index + 1] >= 0xdc00,
                   value.utf16[index + 1] <= 0xdfff {
                    codeUnits.append(codeUnit)
                    index += 1
                    codeUnits.append(value.utf16[index])
                } else {
                    appendUnicodeEscape(codeUnit, to: &codeUnits)
                }
            case 0xdc00 ... 0xdfff:
                appendUnicodeEscape(codeUnit, to: &codeUnits)
            default:
                codeUnits.append(codeUnit)
            }
            index += 1
        }
        codeUnits.append(0x22)
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private static func jsonStringLength(_ value: LosslessJSONString) -> Int {
        var length = 2
        var index = 0
        while index < value.utf16.count {
            let codeUnit = value.utf16[index]
            switch codeUnit {
            case 0x08, 0x09, 0x0a, 0x0c, 0x0d, 0x22, 0x5c:
                length += 2
            case 0x00 ... 0x1f, 0xdc00 ... 0xdfff:
                length += 6
            case 0xd800 ... 0xdbff:
                if index + 1 < value.utf16.count,
                   value.utf16[index + 1] >= 0xdc00,
                   value.utf16[index + 1] <= 0xdfff {
                    length += 2
                    index += 1
                } else {
                    length += 6
                }
            default:
                length += 1
            }
            index += 1
        }
        return length
    }

    private static func appendASCII(_ value: String, to result: inout [UInt16]) {
        result.append(contentsOf: value.utf16)
    }

    private static func appendUnicodeEscape(_ value: UInt16, to result: inout [UInt16]) {
        appendASCII("\\u", to: &result)
        let digits = Array("0123456789abcdef".utf16)
        result.append(digits[Int((value >> 12) & 0x0f)])
        result.append(digits[Int((value >> 8) & 0x0f)])
        result.append(digits[Int((value >> 4) & 0x0f)])
        result.append(digits[Int(value & 0x0f)])
    }
}

extension LosslessJSONValue {
    public var numberValue: LosslessJSONNumber? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public var arrayValue: [LosslessJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var objectValue: LosslessJSONObject? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value.stringValue
    }

    public var losslessStringValue: LosslessJSONString? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public func value(at path: LosslessJSONPath) -> LosslessJSONValue? {
        var current = self
        for component in path {
            switch (current, component) {
            case let (.array(items), .index(index))
                    where items.indices.contains(index):
                current = items[index]
            case let (.object(object), .key(key)):
                guard let child = object[key] else { return nil }
                current = child
            default:
                return nil
            }
        }
        return current
    }

    /// Replaces a node, including the root when `path` is empty.
    public mutating func replaceValue(
        at path: LosslessJSONPath,
        with replacement: LosslessJSONValue,
        limits: LosslessJSONLimits = .default
    ) throws {
        try Self.validatePathLength(path, limits: limits)
        let candidate = try modifyingValue(at: path[...], fullPath: path) { value in
            value = replacement
        }
        try LosslessJSON.validate(candidate, limits: limits)
        self = candidate
    }

    /// Adds a new unique object key. The default key policy matches the JSON
    /// tree UI, which rejects empty and prototype-sensitive names.
    public mutating func addObjectMember(
        key: String,
        value: LosslessJSONValue,
        at path: LosslessJSONPath,
        rejectProtectedKeys: Bool = true,
        limits: LosslessJSONLimits = .default
    ) throws {
        try Self.validatePathLength(path, limits: limits)
        if rejectProtectedKeys && !Self.isAllowedTreeObjectKey(key) {
            throw LosslessJSONTreeError.invalidObjectKey(key)
        }
        let candidate = try modifyingValue(at: path[...], fullPath: path) { target in
            guard case var .object(object) = target else {
                throw LosslessJSONTreeError.typeMismatch(path: path, expected: .object)
            }
            guard !object.contains(key) else {
                throw LosslessJSONTreeError.duplicateObjectKey(key)
            }
            object.setValue(value, forKey: key)
            target = .object(object)
        }
        try LosslessJSON.validate(candidate, limits: limits)
        self = candidate
    }

    public mutating func appendArrayItem(
        _ value: LosslessJSONValue,
        at path: LosslessJSONPath,
        limits: LosslessJSONLimits = .default
    ) throws {
        try Self.validatePathLength(path, limits: limits)
        let candidate = try modifyingValue(at: path[...], fullPath: path) { target in
            guard case var .array(items) = target else {
                throw LosslessJSONTreeError.typeMismatch(path: path, expected: .array)
            }
            items.append(value)
            target = .array(items)
        }
        try LosslessJSON.validate(candidate, limits: limits)
        self = candidate
    }

    public mutating func removeValue(
        at path: LosslessJSONPath,
        limits: LosslessJSONLimits = .default
    ) throws {
        try Self.validatePathLength(path, limits: limits)
        guard let final = path.last else {
            throw LosslessJSONTreeError.cannotRemoveRoot
        }
        let parentPath = Array(path.dropLast())
        let candidate = try modifyingValue(at: parentPath[...], fullPath: path) { parent in
            switch (parent, final) {
            case (var .array(items), let .index(index)):
                guard items.indices.contains(index) else {
                    throw LosslessJSONTreeError.pathNotFound(path)
                }
                items.remove(at: index)
                parent = .array(items)
            case (var .object(object), let .key(key)):
                guard object.removeValue(forKey: key) != nil else {
                    throw LosslessJSONTreeError.pathNotFound(path)
                }
                parent = .object(object)
            case (.array, .key):
                throw LosslessJSONTreeError.typeMismatch(
                    path: parentPath, expected: .object
                )
            case (.object, .index):
                throw LosslessJSONTreeError.typeMismatch(
                    path: parentPath, expected: .array
                )
            default:
                let expected: LosslessJSONContainerKind
                switch final {
                case .key: expected = .object
                case .index: expected = .array
                }
                throw LosslessJSONTreeError.typeMismatch(
                    path: parentPath, expected: expected
                )
            }
        }
        try LosslessJSON.validate(candidate, limits: limits)
        self = candidate
    }

    public static func isAllowedTreeObjectKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key != "__proto__" && key != "prototype" && key != "constructor"
    }

    private static func validatePathLength(
        _ path: LosslessJSONPath,
        limits: LosslessJSONLimits
    ) throws {
        guard path.count <= limits.maximumDepth else {
            throw LosslessJSONResourceError.nestingTooDeep(
                actualDepth: path.count, maximumDepth: limits.maximumDepth
            )
        }
    }

    private func modifyingValue(
        at remainingPath: ArraySlice<LosslessJSONPathComponent>,
        fullPath: LosslessJSONPath,
        operation: (inout LosslessJSONValue) throws -> Void
    ) throws -> LosslessJSONValue {
        guard let component = remainingPath.first else {
            var result = self
            try operation(&result)
            return result
        }

        let tail = remainingPath.dropFirst()
        switch (self, component) {
        case (var .array(items), let .index(index)):
            guard items.indices.contains(index) else {
                throw LosslessJSONTreeError.pathNotFound(fullPath)
            }
            items[index] = try items[index].modifyingValue(
                at: tail, fullPath: fullPath, operation: operation
            )
            return .array(items)
        case (var .object(object), let .key(key)):
            guard let memberIndex = object.index(forKey: key) else {
                throw LosslessJSONTreeError.pathNotFound(fullPath)
            }
            object.storage[memberIndex].value = try object.storage[memberIndex].value
                .modifyingValue(at: tail, fullPath: fullPath, operation: operation)
            return .object(object)
        case (.array, .key):
            throw LosslessJSONTreeError.typeMismatch(
                path: Array(fullPath.dropLast(remainingPath.count)),
                expected: .object
            )
        case (.object, .index):
            throw LosslessJSONTreeError.typeMismatch(
                path: Array(fullPath.dropLast(remainingPath.count)),
                expected: .array
            )
        default:
            let expected: LosslessJSONContainerKind
            switch component {
            case .key: expected = .object
            case .index: expected = .array
            }
            throw LosslessJSONTreeError.typeMismatch(
                path: Array(fullPath.dropLast(remainingPath.count)),
                expected: expected
            )
        }
    }
}

private final class LosslessJSONParser {
    private let codeUnits: [UInt16]
    private let limits: LosslessJSONLimits
    private var position = 0
    private var nodeCount = 0

    init(source: String, limits: LosslessJSONLimits) {
        codeUnits = Array(source.utf16)
        self.limits = limits
    }

    func parse() throws -> LosslessJSONValue {
        whitespace()
        let result = try value(depth: 0)
        whitespace()
        if position != codeUnits.count {
            throw error("Unexpected trailing content.")
        }
        return result
    }

    private func value(depth: Int) throws -> LosslessJSONValue {
        whitespace()
        guard depth <= limits.maximumDepth else {
            throw error(
                "JSON nesting exceeds the depth limit of \(limits.maximumDepth).",
                kind: .nestingTooDeep(
                    actualDepth: depth, maximumDepth: limits.maximumDepth
                )
            )
        }
        let nextCount = nodeCount.addingReportingOverflow(1)
        guard !nextCount.overflow, nextCount.partialValue <= limits.maximumNodes else {
            let actual = nextCount.overflow ? Int.max : nextCount.partialValue
            throw error(
                "JSON node count exceeds the limit of \(limits.maximumNodes).",
                kind: .tooManyNodes(
                    actualNodes: actual, maximumNodes: limits.maximumNodes
                )
            )
        }
        nodeCount = nextCount.partialValue

        guard let codeUnit = current else {
            throw error("Expected a JSON value.")
        }
        switch codeUnit {
        case Self.leftBrace:
            return try object(depth: depth)
        case Self.leftBracket:
            return try array(depth: depth)
        case Self.quote:
            return .string(try string())
        case Self.lowerT:
            try literal("true")
            return .bool(true)
        case Self.lowerF:
            try literal("false")
            return .bool(false)
        case Self.lowerN:
            try literal("null")
            return .null
        case Self.minus, Self.zero ... Self.nine:
            return .number(try number())
        default:
            throw error("Expected a JSON value.")
        }
    }

    private func object(depth: Int) throws -> LosslessJSONValue {
        try expect(Self.leftBrace, display: "{")
        var members: [LosslessJSONObjectMember] = []
        var memberIndices: [[UInt16]: Int] = [:]
        whitespace()
        if current == Self.rightBrace {
            position += 1
            return .object(LosslessJSONObject())
        }
        while true {
            whitespace()
            guard current == Self.quote else {
                throw error("Expected an object key.")
            }
            let key = try string()
            whitespace()
            try expect(Self.colon, display: ":")
            let child = try value(depth: depth + 1)
            if let existing = memberIndices[key.utf16] {
                members[existing].value = child
            } else {
                memberIndices[key.utf16] = members.count
                members.append(.init(losslessKey: key, value: child))
            }
            whitespace()
            if current == Self.rightBrace {
                position += 1
                return .object(LosslessJSONObject(members))
            }
            try expect(Self.comma, display: ",")
        }
    }

    private func array(depth: Int) throws -> LosslessJSONValue {
        try expect(Self.leftBracket, display: "[")
        var result: [LosslessJSONValue] = []
        whitespace()
        if current == Self.rightBracket {
            position += 1
            return .array(result)
        }
        while true {
            result.append(try value(depth: depth + 1))
            whitespace()
            if current == Self.rightBracket {
                position += 1
                return .array(result)
            }
            try expect(Self.comma, display: ",")
        }
    }

    private func string() throws -> LosslessJSONString {
        let start = position
        try expect(Self.quote, display: "\"")
        while position < codeUnits.count {
            let codeUnit = codeUnits[position]
            if codeUnit == Self.quote {
                position += 1
                guard let decoded = decodeStringToken(
                    from: start + 1, through: position - 1
                ) else {
                    throw error("Invalid JSON string.")
                }
                return decoded
            }
            if codeUnit == Self.backslash {
                position += 2
                continue
            }
            if codeUnit < 0x20 {
                throw error("Control character in JSON string.")
            }
            position += 1
        }
        throw error("Unterminated JSON string.")
    }

    /// The range excludes the opening and closing quote. Invalid escapes are
    /// deliberately reported after the closing quote, matching JSON.parse in
    /// the reference scanner.
    private func decodeStringToken(
        from start: Int,
        through end: Int
    ) -> LosslessJSONString? {
        var decoded: [UInt16] = []
        decoded.reserveCapacity(max(0, end - start))
        var cursor = start
        while cursor < end {
            let codeUnit = codeUnits[cursor]
            guard codeUnit == Self.backslash else {
                decoded.append(codeUnit)
                cursor += 1
                continue
            }
            cursor += 1
            guard cursor < end else { return nil }
            switch codeUnits[cursor] {
            case Self.quote, Self.backslash, Self.slash:
                decoded.append(codeUnits[cursor])
                cursor += 1
            case 0x62: // b
                decoded.append(0x08)
                cursor += 1
            case 0x66: // f
                decoded.append(0x0c)
                cursor += 1
            case 0x6e: // n
                decoded.append(0x0a)
                cursor += 1
            case 0x72: // r
                decoded.append(0x0d)
                cursor += 1
            case 0x74: // t
                decoded.append(0x09)
                cursor += 1
            case 0x75: // u
                guard cursor + 4 < end else { return nil }
                var value: UInt16 = 0
                for offset in 1 ... 4 {
                    guard let digit = Self.hexDigit(codeUnits[cursor + offset]) else {
                        return nil
                    }
                    value = value &* 16 &+ digit
                }
                decoded.append(value)
                cursor += 5
            default:
                return nil
            }
        }
        return LosslessJSONString(utf16: decoded)
    }

    private func number() throws -> LosslessJSONNumber {
        let start = position
        if current == Self.minus { position += 1 }
        guard position < codeUnits.count else {
            position = start
            throw error("Invalid JSON number.")
        }

        if codeUnits[position] == Self.zero {
            position += 1
        } else if Self.isOneThroughNine(codeUnits[position]) {
            position += 1
            while position < codeUnits.count, Self.isDigit(codeUnits[position]) {
                position += 1
            }
        } else {
            position = start
            throw error("Invalid JSON number.")
        }

        if position < codeUnits.count, codeUnits[position] == Self.period,
           position + 1 < codeUnits.count, Self.isDigit(codeUnits[position + 1]) {
            position += 2
            while position < codeUnits.count, Self.isDigit(codeUnits[position]) {
                position += 1
            }
        }

        if position < codeUnits.count,
           codeUnits[position] == Self.lowerE || codeUnits[position] == Self.upperE {
            var exponentCursor = position + 1
            if exponentCursor < codeUnits.count,
               codeUnits[exponentCursor] == Self.plus
                || codeUnits[exponentCursor] == Self.minus {
                exponentCursor += 1
            }
            if exponentCursor < codeUnits.count, Self.isDigit(codeUnits[exponentCursor]) {
                position = exponentCursor + 1
                while position < codeUnits.count, Self.isDigit(codeUnits[position]) {
                    position += 1
                }
            }
        }

        return LosslessJSONNumber(String(decoding: codeUnits[start ..< position], as: UTF16.self))
    }

    private func literal(_ literal: String) throws {
        let expected = Array(literal.utf16)
        guard expected.count <= codeUnits.count - position,
              codeUnits[position...].starts(with: expected) else {
            throw error("Expected \(literal).")
        }
        position += expected.count
    }

    private func whitespace() {
        while let codeUnit = current, Self.isWhitespace(codeUnit) {
            position += 1
        }
    }

    private func expect(_ codeUnit: UInt16, display: String) throws {
        whitespace()
        guard current == codeUnit else {
            throw error("Expected “\(display)”.")
        }
        position += 1
    }

    private var current: UInt16? {
        guard codeUnits.indices.contains(position) else { return nil }
        return codeUnits[position]
    }

    private func error(
        _ message: String,
        kind: LosslessJSONParseError.Kind = .syntax
    ) -> LosslessJSONParseError {
        let prefixEnd = min(max(position, 0), codeUnits.count)
        var line = 1
        var lastLineFeed = -1
        if prefixEnd > 0 {
            for index in 0 ..< prefixEnd where codeUnits[index] == Self.lineFeed {
                line += 1
                lastLineFeed = index
            }
        }
        return LosslessJSONParseError(
            message: message,
            line: line,
            column: position - lastLineFeed,
            utf16Offset: position,
            kind: kind
        )
    }

    private static func isDigit(_ value: UInt16) -> Bool {
        value >= zero && value <= nine
    }

    private static func isOneThroughNine(_ value: UInt16) -> Bool {
        value >= 0x31 && value <= nine
    }

    private static func isWhitespace(_ value: UInt16) -> Bool {
        value == space || value == horizontalTab || value == lineFeed || value == carriageReturn
    }

    private static func hexDigit(_ value: UInt16) -> UInt16? {
        switch value {
        case 0x30 ... 0x39: value - 0x30
        case 0x41 ... 0x46: value - 0x41 + 10
        case 0x61 ... 0x66: value - 0x61 + 10
        default: nil
        }
    }

    private static let horizontalTab: UInt16 = 0x09
    private static let lineFeed: UInt16 = 0x0a
    private static let carriageReturn: UInt16 = 0x0d
    private static let space: UInt16 = 0x20
    private static let quote: UInt16 = 0x22
    private static let plus: UInt16 = 0x2b
    private static let comma: UInt16 = 0x2c
    private static let minus: UInt16 = 0x2d
    private static let period: UInt16 = 0x2e
    private static let slash: UInt16 = 0x2f
    private static let zero: UInt16 = 0x30
    private static let nine: UInt16 = 0x39
    private static let colon: UInt16 = 0x3a
    private static let leftBracket: UInt16 = 0x5b
    private static let backslash: UInt16 = 0x5c
    private static let rightBracket: UInt16 = 0x5d
    private static let leftBrace: UInt16 = 0x7b
    private static let rightBrace: UInt16 = 0x7d
    private static let upperE: UInt16 = 0x45
    private static let lowerE: UInt16 = 0x65
    private static let lowerF: UInt16 = 0x66
    private static let lowerN: UInt16 = 0x6e
    private static let lowerT: UInt16 = 0x74
}

// Swift-spelled and source-compatible aliases for adapters shared with the
// Electron implementation.
public typealias JSONNumber = LosslessJSONNumber
public typealias JsonNumber = LosslessJSONNumber
public typealias LosslessJsonValue = LosslessJSONValue
public typealias LosslessJsonObject = LosslessJSONObject
public typealias JSONPath = LosslessJSONPath
public typealias JSONPathComponent = LosslessJSONPathComponent
public typealias JSONStatistics = LosslessJSONStatistics

public func parseLosslessJSON(
    _ source: String,
    limits: LosslessJSONLimits = .default
) throws -> LosslessJSONValue {
    try LosslessJSON.parse(source, limits: limits)
}

public func stringifyLosslessJSON(
    _ value: LosslessJSONValue,
    indent: Int = 0,
    limits: LosslessJSONLimits = .default
) throws -> String {
    try LosslessJSON.stringify(value, indent: indent, limits: limits)
}

public func cloneLosslessJSON(
    _ value: LosslessJSONValue,
    limits: LosslessJSONLimits = .default
) throws -> LosslessJSONValue {
    try LosslessJSON.clone(value, limits: limits)
}

// Preserve the lower-camel JSON spelling used by the TypeScript functions.
public func parseLosslessJson(
    _ source: String,
    limits: LosslessJSONLimits = .default
) throws -> LosslessJSONValue {
    try parseLosslessJSON(source, limits: limits)
}

public func stringifyLosslessJson(
    _ value: LosslessJSONValue,
    indent: Int = 0,
    limits: LosslessJSONLimits = .default
) throws -> String {
    try stringifyLosslessJSON(value, indent: indent, limits: limits)
}

public func cloneLosslessJson(
    _ value: LosslessJSONValue,
    limits: LosslessJSONLimits = .default
) throws -> LosslessJSONValue {
    try cloneLosslessJSON(value, limits: limits)
}
