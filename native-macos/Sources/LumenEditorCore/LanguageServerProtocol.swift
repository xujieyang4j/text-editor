import Foundation

/// Hard protocol and buffering limits shared by the native language-server
/// transport. These values intentionally match the Electron implementation.
public enum LSPProtocolLimits {
    public static let maximumHeaderBytes = 16 * 1024
    public static let maximumPayloadBytes = 8 * 1024 * 1024
    public static let maximumInputQueueBytes = 16 * 1024 * 1024

    public static let maximumLogCharacters = 64 * 1024
    public static let logFlushMilliseconds = 100
    public static let maximumLogBatchBytes = 64 * 1024
    public static let maximumLogBytesPerSecond = 256 * 1024
    public static let maximumLogChunksPerBucket = 256
    public static let logSentinelReserveBytes = 256

    public static let maximumDiagnostics = 1_000
    public static let maximumDiagnosticMessageBytes = 256 * 1024
    public static let maximumDiagnosticPathCharacters = 32 * 1024
    public static let maximumDiagnosticEventsPerSecond = 20
    public static let maximumDiagnosticIPCBytesPerSecond = 1024 * 1024
    public static let maximumCapabilityNames = 128
    public static let maximumCapabilityCharacters = 32 * 1024
    public static let maximumCompletionItems = 200
    public static let maximumFormattingEdits = 1_000
    public static let maximumFormattingEditTextUTF16CodeUnits = 4 * 1_024 * 1_024
    public static let maximumFormattingTotalTextUTF16CodeUnits = 4 * 1_024 * 1_024
    public static let maximumExternalDetailCharacters = 2_000
    public static let initializeTimeoutMilliseconds = 15_000
}

/// A JSON value used only at the LSP boundary. Keeping this type independent
/// prevents arbitrary Foundation objects from entering protocol messages.
public indirect enum LSPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([LSPJSONValue])
    case object([String: LSPJSONValue])

    private static let maximumDecodingDepth = 128

    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= Self.maximumDecodingDepth else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "LSP JSON nesting exceeds the hard decoding limit."
            ))
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LSPJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: LSPJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "LSP payload contains an unsupported JSON value."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "LSP JSON numbers must be finite."
                ))
            }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var objectValue: [String: LSPJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    fileprivate var isJavaScriptTruthy: Bool {
        switch self {
        case .null, .bool(false), .integer(0):
            false
        case let .number(value):
            value != 0 && !value.isNaN
        case .string(""):
            false
        default:
            true
        }
    }
}

public typealias LSPMessage = [String: LSPJSONValue]

public extension Dictionary where Key == String, Value == LSPJSONValue {
    /// Decode a framed dynamic message into a strongly typed JSON-RPC DTO.
    func decode<Message: Decodable>(
        _ type: Message.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Message {
        try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}

/// A framing error is fatal when the next frame boundary can no longer be
/// trusted. Payload errors are nonfatal after all declared bytes are consumed.
public struct LSPProtocolError: Error, Equatable, LocalizedError, Sendable {
    public let message: String
    public let fatal: Bool

    public init(_ message: String, fatal: Bool) {
        self.message = message
        self.fatal = fatal
    }

    public var errorDescription: String? { message }
}

public struct LSPReaderOutput: Equatable, Sendable {
    public var messages: [LSPMessage]
    public var errors: [LSPProtocolError]

    public init(messages: [LSPMessage] = [], errors: [LSPProtocolError] = []) {
        self.messages = messages
        self.errors = errors
    }
}

/// Incrementally parses Content-Length framed JSON-RPC messages. The instance
/// is deliberately stateful and should be confined to one actor or queue.
public final class LSPMessageReader {
    private enum State {
        case header
        case payload
        case stopped
    }

    private static let headerSeparator = Data([13, 10, 13, 10])
    private static let maximumSafeJSONInteger: UInt64 = 9_007_199_254_740_991

    private var state: State = .header
    private var header = Data()
    private var payload = Data()
    private var expectedPayloadLength = 0
    private let onMessage: ((LSPMessage) -> Void)?
    private let onError: ((LSPProtocolError) -> Void)?

    public init(
        onMessage: ((LSPMessage) -> Void)? = nil,
        onError: ((LSPProtocolError) -> Void)? = nil
    ) {
        self.onMessage = onMessage
        self.onError = onError
        header.reserveCapacity(LSPProtocolLimits.maximumHeaderBytes + 4)
    }

    public var isStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    /// Consume one arbitrary chunk. A chunk may contain a partial frame, many
    /// complete frames, or both. Empty input is a no-op.
    @discardableResult
    public func append(_ chunk: Data) -> LSPReaderOutput {
        var output = LSPReaderOutput()
        guard !chunk.isEmpty, !isStopped else { return output }

        var offset = 0
        while offset < chunk.count, !isStopped {
            switch state {
            case .header:
                let index = chunk.index(chunk.startIndex, offsetBy: offset)
                let byte = chunk[index]
                offset += 1
                guard byte <= 0x7f else {
                    fail("LSP header must contain only ASCII bytes.", output: &output)
                    continue
                }
                header.append(byte)

                if header.count >= Self.headerSeparator.count,
                   header.suffix(Self.headerSeparator.count) == Self.headerSeparator {
                    let headerBytes = Data(header.dropLast(Self.headerSeparator.count))
                    header.removeAll(keepingCapacity: true)
                    switch Self.parseHeader(headerBytes) {
                    case let .success(length):
                        expectedPayloadLength = length
                        payload.removeAll(keepingCapacity: false)
                        payload.reserveCapacity(length)
                        state = .payload
                        if length == 0 { completePayload(output: &output) }
                    case let .failure(error):
                        fail(error.message, output: &output)
                    }
                    continue
                }

                let separatorPrefix = Self.trailingHeaderSeparatorPrefixLength(header)
                if header.count - separatorPrefix > LSPProtocolLimits.maximumHeaderBytes {
                    fail(
                        "LSP header exceeds the \(LSPProtocolLimits.maximumHeaderBytes)-byte limit.",
                        output: &output
                    )
                }

            case .payload:
                let remaining = expectedPayloadLength - payload.count
                guard remaining > 0 else {
                    fail("Invalid internal LSP reader state.", output: &output)
                    continue
                }
                let copied = min(remaining, chunk.count - offset)
                let lower = chunk.index(chunk.startIndex, offsetBy: offset)
                let upper = chunk.index(lower, offsetBy: copied)
                payload.append(contentsOf: chunk[lower..<upper])
                offset += copied
                if payload.count == expectedPayloadLength {
                    completePayload(output: &output)
                }

            case .stopped:
                break
            }
        }
        return output
    }

    /// Callback-oriented spelling for stream adapters.
    public func receive(_ chunk: Data) {
        append(chunk)
    }

    private func completePayload(output: inout LSPReaderOutput) {
        let completed = payload
        payload.removeAll(keepingCapacity: false)
        expectedPayloadLength = 0
        state = .header

        guard String(data: completed, encoding: .utf8) != nil else {
            report("Invalid UTF-8 in LSP payload.", output: &output)
            return
        }

        let value: LSPJSONValue
        do {
            value = try JSONDecoder().decode(LSPJSONValue.self, from: completed)
        } catch {
            report("Invalid JSON in LSP payload.", output: &output)
            return
        }
        guard case let .object(message) = value else {
            report("LSP payload must be a JSON object.", output: &output)
            return
        }
        output.messages.append(message)
        onMessage?(message)
    }

    private func fail(_ message: String, output: inout LSPReaderOutput) {
        state = .stopped
        header.removeAll(keepingCapacity: false)
        payload.removeAll(keepingCapacity: false)
        expectedPayloadLength = 0
        let error = LSPProtocolError(message, fatal: true)
        output.errors.append(error)
        onError?(error)
    }

    private func report(_ message: String, output: inout LSPReaderOutput) {
        let error = LSPProtocolError(message, fatal: false)
        output.errors.append(error)
        onError?(error)
    }

    private static func trailingHeaderSeparatorPrefixLength(_ bytes: Data) -> Int {
        if bytes.count >= 3, bytes.suffix(3) == Data([13, 10, 13]) { return 3 }
        if bytes.count >= 2, bytes.suffix(2) == Data([13, 10]) { return 2 }
        return bytes.last == 13 ? 1 : 0
    }

    private static func parseHeader(_ bytes: Data) -> Result<Int, LSPProtocolError> {
        guard !bytes.isEmpty else {
            return .failure(LSPProtocolError("Missing LSP Content-Length header.", fatal: true))
        }
        let source = String(decoding: bytes, as: UTF8.self)
        var contentLength: Int?

        for line in source.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                return .failure(LSPProtocolError("Malformed LSP header.", fatal: true))
            }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            guard isValidHeaderName(name), isValidHeaderValue(value) else {
                return .failure(LSPProtocolError("Malformed LSP header.", fatal: true))
            }
            guard name.lowercased() == "content-length" else { continue }
            guard contentLength == nil else {
                return .failure(LSPProtocolError("Duplicate LSP Content-Length header.", fatal: true))
            }
            guard let parsed = parseContentLength(value) else {
                return .failure(LSPProtocolError("Invalid LSP Content-Length header.", fatal: true))
            }
            guard parsed <= UInt64(LSPProtocolLimits.maximumPayloadBytes) else {
                return .failure(LSPProtocolError(
                    "LSP payload exceeds the \(LSPProtocolLimits.maximumPayloadBytes)-byte limit.",
                    fatal: true
                ))
            }
            contentLength = Int(parsed)
        }

        guard let contentLength else {
            return .failure(LSPProtocolError("Missing LSP Content-Length header.", fatal: true))
        }
        return .success(contentLength)
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        return name.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || punctuation.contains(byte)
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || (32...126).contains($0) }
    }

    private static func parseContentLength(_ value: String) -> UInt64? {
        let bytes = Array(value.utf8)
        var lower = 0
        var upper = bytes.count
        while lower < upper, bytes[lower] == 9 || bytes[lower] == 32 { lower += 1 }
        while upper > lower, bytes[upper - 1] == 9 || bytes[upper - 1] == 32 { upper -= 1 }
        guard lower < upper else { return nil }

        var result: UInt64 = 0
        for byte in bytes[lower..<upper] {
            guard (48...57).contains(byte) else { return nil }
            let multiplied = result.multipliedReportingOverflow(by: 10)
            guard !multiplied.overflow else { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(UInt64(byte - 48))
            guard !added.overflow else { return nil }
            result = added.partialValue
        }
        return result <= maximumSafeJSONInteger ? result : nil
    }
}

public enum LSPMessageEncodingError: Error, Equatable, LocalizedError, Sendable {
    case topLevelMustBeObject
    case notJSONSerializable
    case payloadTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .topLevelMustBeObject:
            "LSP message must be a non-null JSON object."
        case .notJSONSerializable:
            "LSP message is not JSON serializable."
        case let .payloadTooLarge(limit):
            "LSP payload exceeds the \(limit)-byte limit."
        }
    }
}

public enum LSPMessageFraming {
    /// Encode one object with the byte-counted Content-Length framing required
    /// by LSP. The length is UTF-8 bytes, never Swift characters.
    public static func encode<Message: Encodable>(
        _ message: Message,
        using encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let payload: Data
        do {
            payload = try encoder.encode(message)
        } catch {
            throw LSPMessageEncodingError.notJSONSerializable
        }
        guard payload.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 else {
            throw LSPMessageEncodingError.topLevelMustBeObject
        }
        guard payload.count <= LSPProtocolLimits.maximumPayloadBytes else {
            throw LSPMessageEncodingError.payloadTooLarge(
                limit: LSPProtocolLimits.maximumPayloadBytes
            )
        }
        var frame = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        frame.append(payload)
        return frame
    }
}

public enum LSPRequestID: Codable, Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    /// JSON-RPC peers implemented in JavaScript cannot distinguish consecutive
    /// integer ids beyond this value.
    public static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self),
           (-Self.maximumSafeInteger...Self.maximumSafeInteger).contains(value) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A JSON-RPC request id must be an integer or string."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value):
            guard (-Self.maximumSafeInteger...Self.maximumSafeInteger).contains(value) else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A numeric JSON-RPC request id must be a safe integer."
                ))
            }
            try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

public enum LSPRequestIDGeneratorError: Error, Equatable, Sendable {
    case exhausted
}

/// Monotonic request ids. Exhaustion is explicit, so an old pending id can
/// never be silently reused after integer overflow.
public struct LSPRequestIDGenerator: Sendable {
    private var nextValue: Int64?

    public init(startingAt value: Int64 = 1) {
        precondition(value >= 0, "Generated LSP request ids must be non-negative.")
        nextValue = value
    }

    public mutating func next() throws -> LSPRequestID {
        guard let value = nextValue else { throw LSPRequestIDGeneratorError.exhausted }
        guard value <= LSPRequestID.maximumSafeInteger else {
            nextValue = nil
            throw LSPRequestIDGeneratorError.exhausted
        }
        nextValue = value == LSPRequestID.maximumSafeInteger ? nil : value + 1
        return .integer(value)
    }
}

public struct LSPRequest<Parameters: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let id: LSPRequestID
    public let method: String
    public let params: Parameters

    public init(id: LSPRequestID, method: String, params: Parameters) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

extension LSPRequest: Equatable where Parameters: Equatable {}

public struct LSPNotification<Parameters: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: Parameters

    public init(method: String, params: Parameters) {
        jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

extension LSPNotification: Equatable where Parameters: Equatable {}

public struct LSPResponseError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: LSPJSONValue?

    public init(code: Int, message: String, data: LSPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct LSPResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: LSPRequestID
    public let result: LSPJSONValue?
    public let error: LSPResponseError?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(id: LSPRequestID, result: LSPJSONValue) {
        jsonrpc = "2.0"
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: LSPRequestID, error: LSPResponseError) {
        jsonrpc = "2.0"
        self.id = id
        result = nil
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try values.decode(String.self, forKey: .jsonrpc)
        guard jsonrpc == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc, in: values, debugDescription: "Unsupported JSON-RPC version."
            )
        }
        id = try values.decode(LSPRequestID.self, forKey: .id)
        let hasResult = values.contains(.result)
        let hasError = values.contains(.error)
        guard hasResult != hasError else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A JSON-RPC response must contain exactly one of result or error."
            ))
        }
        if hasResult {
            result = try values.decode(LSPJSONValue.self, forKey: .result)
            error = nil
        } else {
            result = nil
            error = try values.decode(LSPResponseError.self, forKey: .error)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(jsonrpc, forKey: .jsonrpc)
        try values.encode(id, forKey: .id)
        if let result {
            try values.encode(result, forKey: .result)
        } else if let error {
            try values.encode(error, forKey: .error)
        } else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "A JSON-RPC response must contain a result or error."
            ))
        }
    }
}

public struct LSPClientCapabilities: Codable, Equatable, Sendable {
    public var values: [String: LSPJSONValue]

    public init(_ values: [String: LSPJSONValue] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        values = try [String: LSPJSONValue](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }
}

public struct LSPServerCapabilities: Codable, Equatable, Sendable {
    public var values: [String: LSPJSONValue]

    public init(_ values: [String: LSPJSONValue] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        values = try [String: LSPJSONValue](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }

    public subscript(name: String) -> LSPJSONValue? { values[name] }

    /// Stable, bounded capability names for status UI. Values use JavaScript
    /// truthiness to retain parity with the Electron implementation.
    public func summarizedNames(
        maximumCount: Int = LSPProtocolLimits.maximumCapabilityNames,
        maximumUTF16Units: Int = LSPProtocolLimits.maximumCapabilityCharacters
    ) -> [String] {
        let countLimit = max(0, min(maximumCount, LSPProtocolLimits.maximumCapabilityNames))
        let characterLimit = max(0, min(
            maximumUTF16Units, LSPProtocolLimits.maximumCapabilityCharacters
        ))
        var result: [String] = []
        var used = 0
        for name in values.keys.filter({ values[$0]?.isJavaScriptTruthy == true }).sorted() {
            guard result.count < countLimit else { break }
            let added = name.utf16.count + (result.isEmpty ? 0 : 2)
            guard used <= characterLimit, added <= characterLimit - used else { continue }
            result.append(name)
            used += added
        }
        return result
    }
}

public struct LSPInitializeParams: Codable, Equatable, Sendable {
    public let processID: Int?
    public let rootURI: String?
    public let capabilities: LSPClientCapabilities

    private enum CodingKeys: String, CodingKey {
        case processID = "processId"
        case rootURI = "rootUri"
        case capabilities
    }

    public init(
        processID: Int?,
        rootURI: String?,
        capabilities: LSPClientCapabilities = LSPClientCapabilities()
    ) {
        self.processID = processID
        self.rootURI = rootURI
        self.capabilities = capabilities
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processID = try values.decodeIfPresent(Int.self, forKey: .processID)
        rootURI = try values.decodeIfPresent(String.self, forKey: .rootURI)
        capabilities = try values.decode(LSPClientCapabilities.self, forKey: .capabilities)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let processID {
            try values.encode(processID, forKey: .processID)
        } else {
            try values.encodeNil(forKey: .processID)
        }
        if let rootURI {
            try values.encode(rootURI, forKey: .rootURI)
        } else {
            try values.encodeNil(forKey: .rootURI)
        }
        try values.encode(capabilities, forKey: .capabilities)
    }
}

public struct LSPServerInfo: Codable, Equatable, Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

public struct LSPInitializeResult: Codable, Equatable, Sendable {
    public let capabilities: LSPServerCapabilities
    public let serverInfo: LSPServerInfo?

    public init(capabilities: LSPServerCapabilities, serverInfo: LSPServerInfo? = nil) {
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

public struct LSPEmptyObject: Codable, Equatable, Sendable {
    public init() {}

    public init(from decoder: any Decoder) throws {
        _ = try decoder.container(keyedBy: EmptyCodingKey.self)
    }

    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }

    private struct EmptyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

public typealias LSPInitializeRequest = LSPRequest<LSPInitializeParams>
public typealias LSPInitializedNotification = LSPNotification<LSPEmptyObject>
public typealias LSPPublishDiagnosticsNotification = LSPNotification<LSPPublishDiagnosticsParams>

public enum LSPInitializationMessages {
    public static func initialize(
        id: LSPRequestID,
        processID: Int?,
        rootURI: String?,
        capabilities: LSPClientCapabilities = LSPClientCapabilities()
    ) -> LSPInitializeRequest {
        LSPRequest(
            id: id,
            method: "initialize",
            params: LSPInitializeParams(
                processID: processID, rootURI: rootURI, capabilities: capabilities
            )
        )
    }

    public static func initialized() -> LSPInitializedNotification {
        LSPNotification(method: "initialized", params: LSPEmptyObject())
    }
}

public struct LSPPosition: Codable, Equatable, Hashable, Sendable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    fileprivate var nonnegative: LSPPosition {
        LSPPosition(line: max(0, line), character: max(0, character))
    }
}

public struct LSPRange: Codable, Equatable, Hashable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPTextDocumentIdentifier: Codable, Equatable, Sendable {
    public let uri: String

    public init(uri: String) { self.uri = uri }
}

public struct LSPTextDocumentPositionParams: Codable, Equatable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition

    public init(uri: String, position: LSPPosition) {
        textDocument = LSPTextDocumentIdentifier(uri: uri)
        self.position = position.nonnegative
    }
}

public struct LSPFormattingOptions: Codable, Equatable, Sendable {
    public let tabSize: Int
    public let insertSpaces: Bool

    public init(tabSize: Int = 4, insertSpaces: Bool = true) {
        self.tabSize = max(1, tabSize)
        self.insertSpaces = insertSpaces
    }
}

public struct LSPDocumentFormattingParams: Codable, Equatable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let options: LSPFormattingOptions

    public init(
        uri: String,
        options: LSPFormattingOptions = LSPFormattingOptions()
    ) {
        textDocument = LSPTextDocumentIdentifier(uri: uri)
        self.options = options
    }
}

public struct LSPReferenceContext: Codable, Equatable, Sendable {
    public let includeDeclaration: Bool

    public init(includeDeclaration: Bool = true) {
        self.includeDeclaration = includeDeclaration
    }
}

public struct LSPReferenceParams: Codable, Equatable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
    public let context: LSPReferenceContext

    public init(uri: String, position: LSPPosition, includeDeclaration: Bool = true) {
        textDocument = LSPTextDocumentIdentifier(uri: uri)
        self.position = position.nonnegative
        context = LSPReferenceContext(includeDeclaration: includeDeclaration)
    }
}

public struct LSPRenameParams: Codable, Equatable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
    public let newName: String

    public init(uri: String, position: LSPPosition, newName: String) {
        textDocument = LSPTextDocumentIdentifier(uri: uri)
        self.position = position.nonnegative
        self.newName = newName
    }
}

public struct LSPDiagnostic: Codable, Equatable, Sendable {
    public let range: LSPRange
    public let severity: Int?
    public let source: String?
    public let message: String

    public init(range: LSPRange, severity: Int? = nil, source: String? = nil, message: String) {
        self.range = range
        self.severity = severity
        self.source = source
        self.message = message
    }
}

public struct LSPPublishDiagnosticsParams: Codable, Equatable, Sendable {
    public let uri: String
    public let version: Int?
    public let diagnostics: [LSPDiagnostic]

    public init(uri: String, version: Int? = nil, diagnostics: [LSPDiagnostic]) {
        self.uri = uri
        self.version = version
        self.diagnostics = diagnostics
    }
}

public struct LSPLocation: Codable, Equatable, Sendable {
    public let uri: String
    public let range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    public var languageLocation: LanguageLocation? {
        guard let path = LSPFileURI.path(from: uri) else { return nil }
        let position = range.start.nonnegative
        return LanguageLocation(filePath: path, line: position.line, character: position.character)
    }
}

public struct LSPLocationLink: Codable, Equatable, Sendable {
    public let originSelectionRange: LSPRange?
    public let targetURI: String
    public let targetRange: LSPRange
    public let targetSelectionRange: LSPRange

    private enum CodingKeys: String, CodingKey {
        case originSelectionRange
        case targetURI = "targetUri"
        case targetRange, targetSelectionRange
    }

    public init(
        originSelectionRange: LSPRange? = nil,
        targetURI: String,
        targetRange: LSPRange,
        targetSelectionRange: LSPRange
    ) {
        self.originSelectionRange = originSelectionRange
        self.targetURI = targetURI
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }

    public var languageLocation: LanguageLocation? {
        guard let path = LSPFileURI.path(from: targetURI) else { return nil }
        let position = targetSelectionRange.start.nonnegative
        return LanguageLocation(filePath: path, line: position.line, character: position.character)
    }
}

public struct LSPMarkupContent: Codable, Equatable, Sendable {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum LSPDocumentation: Codable, Equatable, Sendable {
    case string(String)
    case markup(LSPMarkupContent)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .markup(try container.decode(LSPMarkupContent.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .markup(value): try container.encode(value)
        }
    }

    public var text: String {
        switch self {
        case let .string(value): value
        case let .markup(value): value.value
        }
    }
}

public struct LSPCompletionItem: Codable, Equatable, Sendable {
    public let label: String
    public let detail: String?
    public let documentation: LSPDocumentation?
    public let insertText: String?

    public init(
        label: String,
        detail: String? = nil,
        documentation: LSPDocumentation? = nil,
        insertText: String? = nil
    ) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
    }

    public var languageCompletionItem: LanguageCompletionItem {
        LanguageCompletionItem(
            label: label, detail: detail, documentation: documentation?.text, insertText: insertText
        )
    }
}

public struct LSPCompletionList: Codable, Equatable, Sendable {
    public let isIncomplete: Bool
    public let items: [LSPCompletionItem]

    public init(isIncomplete: Bool, items: [LSPCompletionItem]) {
        self.isIncomplete = isIncomplete
        self.items = items
    }
}

public enum LSPCompletionResponse: Codable, Equatable, Sendable {
    case items([LSPCompletionItem])
    case list(LSPCompletionList)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let items = try? container.decode([LSPCompletionItem].self) {
            self = .items(items)
        } else {
            self = .list(try container.decode(LSPCompletionList.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .items(value): try container.encode(value)
        case let .list(value): try container.encode(value)
        }
    }

    public var items: [LSPCompletionItem] {
        let source: [LSPCompletionItem]
        switch self {
        case let .items(value): source = value
        case let .list(value): source = value.items
        }
        return Array(source.prefix(LSPProtocolLimits.maximumCompletionItems))
    }
}

public enum LSPMarkedString: Codable, Equatable, Sendable {
    case string(String)
    case language(language: String, value: String)

    private enum CodingKeys: String, CodingKey { case language, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self = .language(
            language: try values.decode(String.self, forKey: .language),
            value: try values.decode(String.self, forKey: .value)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .language(language, value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(language, forKey: .language)
            try container.encode(value, forKey: .value)
        }
    }

    public var text: String {
        switch self {
        case let .string(value): value
        case let .language(_, value): value
        }
    }
}

public enum LSPHoverContents: Codable, Equatable, Sendable {
    case markedString(LSPMarkedString)
    case markedStrings([LSPMarkedString])
    case markup(LSPMarkupContent)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([LSPMarkedString].self) {
            self = .markedStrings(values)
        } else if let markup = try? container.decode(LSPMarkupContent.self) {
            self = .markup(markup)
        } else {
            self = .markedString(try container.decode(LSPMarkedString.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .markedString(value): try container.encode(value)
        case let .markedStrings(value): try container.encode(value)
        case let .markup(value): try container.encode(value)
        }
    }

    public var text: String {
        switch self {
        case let .markedString(value): value.text
        case let .markedStrings(values): values.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        case let .markup(value): value.value
        }
    }
}

public struct LSPHover: Codable, Equatable, Sendable {
    public let contents: LSPHoverContents
    public let range: LSPRange?

    public init(contents: LSPHoverContents, range: LSPRange? = nil) {
        self.contents = contents
        self.range = range
    }

    public var languageHover: LanguageHover { LanguageHover(text: contents.text) }
}

public struct LSPTextEdit: Codable, Equatable, Sendable {
    public let range: LSPRange
    public let newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

public struct LSPWorkspaceEdit: Codable, Equatable, Sendable {
    public let changes: [String: [LSPTextEdit]]?

    public init(changes: [String: [LSPTextEdit]]? = nil) {
        self.changes = changes
    }

    public func languageRenameEdits() -> [LanguageRenameEdit] {
        var result: [LanguageRenameEdit] = []
        for uri in (changes ?? [:]).keys.sorted() {
            guard let path = LSPFileURI.path(from: uri), let edits = changes?[uri] else { continue }
            for edit in edits {
                let start = edit.range.start.nonnegative
                let end = edit.range.end.nonnegative
                result.append(LanguageRenameEdit(
                    filePath: path,
                    startLine: start.line, startCharacter: start.character,
                    endLine: end.line, endCharacter: end.character,
                    newText: edit.newText
                ))
            }
        }
        return result
    }
}

private enum LSPFileURI {
    static func path(from value: String) -> String? {
        guard value.utf16.count <= LSPProtocolLimits.maximumDiagnosticPathCharacters,
              let url = URL(string: value), url.isFileURL,
              url.host == nil || url.host == "" else { return nil }
        return url.path
    }
}

// MARK: - Application-facing DTOs matching src/shared/ipc.ts

public struct LanguageServerConfig: Codable, Equatable, Sendable {
    public let command: String
    public let args: [String]

    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
    }
}

public struct LanguageServerRequest: Codable, Equatable, Sendable {
    public let root: String
    public let config: LanguageServerConfig
    public let content: String
    public let filePath: String
    public let languageId: String

    public init(root: String, config: LanguageServerConfig, content: String, filePath: String, languageId: String) {
        self.root = root
        self.config = config
        self.content = content
        self.filePath = filePath
        self.languageId = languageId
    }
}

public struct LanguageServerSyncRequest: Codable, Equatable, Sendable {
    public let root: String
    public let config: LanguageServerConfig
    public let content: String
    public let filePath: String
    public let languageId: String
    public let version: Int

    public init(
        root: String, config: LanguageServerConfig, content: String,
        filePath: String, languageId: String, version: Int
    ) {
        self.root = root
        self.config = config
        self.content = content
        self.filePath = filePath
        self.languageId = languageId
        self.version = version
    }
}

public enum LanguageServerDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
    case info
}

public struct LanguageServerDiagnostic: Codable, Equatable, Sendable {
    public let line: Int
    public let column: Int
    public let endLine: Int?
    public let endColumn: Int?
    public let severity: LanguageServerDiagnosticSeverity
    public let message: String

    public init(
        line: Int, column: Int, endLine: Int? = nil, endColumn: Int? = nil,
        severity: LanguageServerDiagnosticSeverity, message: String
    ) {
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.severity = severity
        self.message = message
    }
}

public extension LSPDiagnostic {
    var languageServerDiagnostic: LanguageServerDiagnostic {
        let start = range.start.nonnegative
        let end = range.end.nonnegative
        let severity: LanguageServerDiagnosticSeverity = switch self.severity {
        case 2: .warning
        case 3, 4: .info
        default: .error
        }
        let boundedCharacters = LSPLogSanitizer.prefixUTF16(
            message, maximumUnits: LSPProtocolLimits.maximumExternalDetailCharacters
        )
        let boundedBytes = LSPLogSanitizer.prefixUTF8(
            boundedCharacters, maximumBytes: LSPProtocolLimits.maximumDiagnosticMessageBytes
        )
        return LanguageServerDiagnostic(
            line: Self.oneBased(start.line), column: Self.oneBased(start.character),
            endLine: Self.oneBased(end.line), endColumn: Self.oneBased(end.character),
            severity: severity, message: boundedBytes
        )
    }

    private static func oneBased(_ value: Int) -> Int {
        value >= Int.max ? Int.max : max(0, value) + 1
    }
}

public struct LanguageServerDiagnosticEvent: Codable, Equatable, Sendable {
    public let filePath: String
    public let diagnostics: [LanguageServerDiagnostic]

    public init(filePath: String, diagnostics: [LanguageServerDiagnostic]) {
        self.filePath = filePath
        self.diagnostics = diagnostics
    }
}

public struct LanguageServerTextEdit: Codable, Equatable, Sendable {
    public let startLine: Int
    public let startCharacter: Int
    public let endLine: Int
    public let endCharacter: Int
    public let newText: String

    public init(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int, newText: String) {
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.newText = newText
    }
}

public struct LanguageServerResult: Codable, Equatable, Sendable {
    public let edits: [LanguageServerTextEdit]
    public let diagnostics: [LanguageServerDiagnostic]

    public init(edits: [LanguageServerTextEdit], diagnostics: [LanguageServerDiagnostic]) {
        self.edits = edits
        self.diagnostics = diagnostics
    }
}

public enum LanguageServerMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case completion
    case hover
    case definition
    case references
    case rename

    public var protocolMethod: String {
        switch self {
        case .completion: "textDocument/completion"
        case .hover: "textDocument/hover"
        case .definition: "textDocument/definition"
        case .references: "textDocument/references"
        case .rename: "textDocument/rename"
        }
    }
}

public struct LanguageServerInteractiveRequest: Codable, Equatable, Sendable {
    public let root: String
    public let config: LanguageServerConfig
    public let content: String
    public let filePath: String
    public let languageId: String
    public let method: LanguageServerMethod
    public let line: Int
    public let character: Int
    public let newName: String?

    public init(
        root: String, config: LanguageServerConfig, content: String, filePath: String,
        languageId: String, method: LanguageServerMethod, line: Int, character: Int,
        newName: String? = nil
    ) {
        self.root = root
        self.config = config
        self.content = content
        self.filePath = filePath
        self.languageId = languageId
        self.method = method
        self.line = line
        self.character = character
        self.newName = newName
    }
}

public struct LanguageLocation: Codable, Equatable, Sendable {
    public let filePath: String
    public let line: Int
    public let character: Int

    public init(filePath: String, line: Int, character: Int) {
        self.filePath = filePath
        self.line = line
        self.character = character
    }
}

public struct LanguageCompletionItem: Codable, Equatable, Sendable {
    public let label: String
    public let detail: String?
    public let documentation: String?
    public let insertText: String?

    public init(label: String, detail: String? = nil, documentation: String? = nil, insertText: String? = nil) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
    }
}

public struct LanguageHover: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) { self.text = text }
}

public struct LanguageRenameEdit: Codable, Equatable, Sendable {
    public let filePath: String
    public let startLine: Int
    public let startCharacter: Int
    public let endLine: Int
    public let endCharacter: Int
    public let newText: String

    public init(
        filePath: String, startLine: Int, startCharacter: Int,
        endLine: Int, endCharacter: Int, newText: String
    ) {
        self.filePath = filePath
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.newText = newText
    }
}

public struct LanguageServerInteractiveResult: Codable, Equatable, Sendable {
    public let completions: [LanguageCompletionItem]?
    public let hover: LanguageHover?
    public let locations: [LanguageLocation]?
    public let renameEdits: [LanguageRenameEdit]?

    public init(
        completions: [LanguageCompletionItem]? = nil, hover: LanguageHover? = nil,
        locations: [LanguageLocation]? = nil, renameEdits: [LanguageRenameEdit]? = nil
    ) {
        self.completions = completions
        self.hover = hover
        self.locations = locations
        self.renameEdits = renameEdits
    }
}

/// Unicode-safe truncation helpers for external language-server text.
public enum LSPLogSanitizer {
    public static let truncationSuffix = "\n[Language server log truncated]"

    public static func boundedLog(
        _ text: String,
        maximumUTF16Units: Int = LSPProtocolLimits.maximumLogCharacters
    ) -> String {
        let limit = max(0, min(maximumUTF16Units, LSPProtocolLimits.maximumLogCharacters))
        guard text.utf16.count > limit else { return text }
        let suffixUnits = truncationSuffix.utf16.count
        guard limit > suffixUnits else { return prefixUTF16(truncationSuffix, maximumUnits: limit) }
        return prefixUTF16(text, maximumUnits: limit - suffixUnits) + truncationSuffix
    }

    public static func prefixUTF16(_ text: String, maximumUnits: Int) -> String {
        guard maximumUnits > 0 else { return "" }
        var used = 0
        var result = String()
        result.reserveCapacity(min(text.count, maximumUnits))
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xffff ? 2 : 1
            guard width <= maximumUnits - used else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        return result
    }

    public static func prefixUTF8(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var used = 0
        var result = String()
        result.reserveCapacity(min(text.utf8.count, maximumBytes))
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            guard width <= maximumBytes - used else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        return result
    }
}
