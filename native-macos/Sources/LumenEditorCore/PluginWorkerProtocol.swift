import Foundation

/// Versioned, newline-delimited IPC shared by the native plugin runtime and
/// its isolated JavaScriptCore helper process. No filesystem or process handle
/// is represented in this protocol.
public enum PluginWorkerProtocol {
    public static let version = 1
    public static let maximumSourceBytes = PluginManifestSecurity.maximumWorkerByteCount
    public static let maximumDocumentBytes = 8 * 1_024 * 1_024
    public static let maximumReplacementBytes = 8 * 1_024 * 1_024
    public static let maximumMessageBytes = 16 * 1_024 * 1_024
    /// This counts plugin-emitted, nonterminal messages. Every request also
    /// carries exactly one `completed` or `failed` terminal response.
    public static let maximumMessagesPerRequest = 256
    public static let maximumWireMessagesPerRequest = maximumMessagesPerRequest + 1
    /// One request may return one maximum-size replacement plus bounded
    /// command/notification traffic and its required terminal response.
    public static let maximumControlResponseBytes = 4 * 1_024
    public static let maximumTerminalResponseBytes = 16 * 1_024
    public static let maximumResponseBytes = maximumMessageBytes
        + maximumMessagesPerRequest * maximumControlResponseBytes
        + maximumTerminalResponseBytes
    /// ToolProcessRunner's process cap is cumulative. Keep it distinct from
    /// the per-request budget so one valid large response cannot exhaust a
    /// persistent worker, while still bounding a runaway helper over its life.
    public static let maximumProcessOutputBytes = maximumResponseBytes * 16
    public static let maximumRetainedProcessOutputBytes = 64 * 1_024
    public static let maximumCommandsPerWorker = 50
    public static let maximumFailureUTF16Count = 2_000
}

public enum PluginWorkerRequestKind: String, Codable, Equatable, Sendable {
    case load
    case activate
    case runCommand = "run-command"
    case deactivate
}

public enum PluginWorkerResponseKind: String, Codable, Equatable, Sendable {
    case registerCommand = "register-command"
    case replaceDocument = "replace-document"
    case notify
    case completed
    case failed
}

public struct PluginWorkerSelection: Codable, Equatable, Sendable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = max(0, min(from, to))
        self.to = max(0, max(from, to))
    }
}

public struct PluginWorkerDocumentContext: Codable, Equatable, Sendable {
    public let text: String
    public let language: String
    public let selection: PluginWorkerSelection

    public init(text: String, language: String, selection: PluginWorkerSelection) throws {
        guard text.utf8.count <= PluginWorkerProtocol.maximumDocumentBytes else {
            throw PluginWorkerProtocolError.documentTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumDocumentBytes
            )
        }
        self.text = text
        self.language = Self.bounded(language, maximumUTF16Count: 100)
        let length = text.utf16.count
        self.selection = PluginWorkerSelection(
            from: min(selection.from, length),
            to: min(selection.to, length)
        )
    }

    private static func bounded(_ value: String, maximumUTF16Count: Int) -> String {
        guard value.utf16.count > maximumUTF16Count else { return value }
        var count = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let units = value[end..<next].utf16.count
            guard count <= maximumUTF16Count - units else { break }
            count += units
            end = next
        }
        return String(value[..<end])
    }
}

public struct PluginWorkerContext: Codable, Equatable, Sendable {
    public let permissions: [PluginPermission]
    public let document: PluginWorkerDocumentContext?

    public init(
        permissions: [PluginPermission],
        document: PluginWorkerDocumentContext? = nil
    ) {
        var seen = Set<PluginPermission>()
        self.permissions = permissions.filter { seen.insert($0).inserted }
        self.document = self.permissions.contains(.documentRead) ? document : nil
    }
}

public struct PluginWorkerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let type: PluginWorkerRequestKind
    public let requestID: String
    public let source: Data?
    public let sourceSHA256: String?
    public let commandID: String?
    public let context: PluginWorkerContext?

    public init(
        type: PluginWorkerRequestKind,
        requestID: String,
        source: Data? = nil,
        sourceSHA256: String? = nil,
        commandID: String? = nil,
        context: PluginWorkerContext? = nil
    ) {
        self.version = PluginWorkerProtocol.version
        self.type = type
        self.requestID = requestID
        self.source = source
        self.sourceSHA256 = sourceSHA256
        self.commandID = commandID
        self.context = context
    }
}

public struct PluginWorkerResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let type: PluginWorkerResponseKind
    public let requestID: String?
    public let id: String?
    public let title: String?
    public let text: String?

    public init(
        type: PluginWorkerResponseKind,
        requestID: String? = nil,
        id: String? = nil,
        title: String? = nil,
        text: String? = nil
    ) {
        self.version = PluginWorkerProtocol.version
        self.type = type
        self.requestID = requestID
        self.id = id
        self.title = title
        self.text = text
    }
}

public enum PluginWorkerProtocolError: Error, Equatable, LocalizedError, Sendable {
    case messageTooLarge(maximumBytes: Int)
    case sourceTooLarge(maximumBytes: Int)
    case documentTooLarge(maximumBytes: Int)
    case replacementTooLarge(maximumBytes: Int)
    case responseTooLarge(maximumBytes: Int)
    case invalidMessage
    case unsupportedVersion(Int)
    case invalidRequest
    case workerFailure(String)
    case tooManyMessages(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .messageTooLarge(maximum):
            "Plugin IPC messages may use at most \(maximum) bytes."
        case let .sourceTooLarge(maximum):
            "Plugin worker source may use at most \(maximum) bytes."
        case let .documentTooLarge(maximum):
            "Plugin document context may use at most \(maximum) UTF-8 bytes."
        case let .replacementTooLarge(maximum):
            "Plugin document replacements may use at most \(maximum) UTF-8 bytes."
        case let .responseTooLarge(maximum):
            "A plugin request may return at most \(maximum) encoded bytes."
        case .invalidMessage:
            "The plugin worker sent an invalid JSON message."
        case let .unsupportedVersion(version):
            "Plugin worker protocol version \(version) is unsupported."
        case .invalidRequest:
            "The plugin worker request is incomplete or inconsistent."
        case let .workerFailure(message):
            message
        case let .tooManyMessages(maximum):
            "A plugin request may emit at most \(maximum) messages."
        }
    }
}

public enum PluginWorkerWireCodec {
    public static func encode(_ request: PluginWorkerRequest) throws -> Data {
        if let source = request.source, source.count > PluginWorkerProtocol.maximumSourceBytes {
            throw PluginWorkerProtocolError.sourceTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumSourceBytes
            )
        }
        let data = try JSONEncoder().encode(request)
        guard data.count <= PluginWorkerProtocol.maximumMessageBytes else {
            throw PluginWorkerProtocolError.messageTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumMessageBytes
            )
        }
        return data + Data([0x0a])
    }

    public static func decodeRequest(_ data: Data) throws -> PluginWorkerRequest {
        let payload = try checkedPayload(data)
        let request: PluginWorkerRequest
        do { request = try JSONDecoder().decode(PluginWorkerRequest.self, from: payload) }
        catch { throw PluginWorkerProtocolError.invalidMessage }
        guard request.version == PluginWorkerProtocol.version else {
            throw PluginWorkerProtocolError.unsupportedVersion(request.version)
        }
        try validate(request)
        return request
    }

    public static func encode(_ response: PluginWorkerResponse) throws -> Data {
        if response.type == .replaceDocument,
           let text = response.text,
           text.utf8.count > PluginWorkerProtocol.maximumReplacementBytes {
            throw PluginWorkerProtocolError.replacementTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumReplacementBytes
            )
        }
        try validate(response)
        let data = try JSONEncoder().encode(response)
        guard data.count <= PluginWorkerProtocol.maximumMessageBytes else {
            throw PluginWorkerProtocolError.messageTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumMessageBytes
            )
        }
        return data + Data([0x0a])
    }

    public static func decodeResponse(_ data: Data) throws -> PluginWorkerResponse {
        let payload = try checkedPayload(data)
        let response: PluginWorkerResponse
        do { response = try JSONDecoder().decode(PluginWorkerResponse.self, from: payload) }
        catch { throw PluginWorkerProtocolError.invalidMessage }
        guard response.version == PluginWorkerProtocol.version else {
            throw PluginWorkerProtocolError.unsupportedVersion(response.version)
        }
        try validate(response)
        return response
    }

    private static func validate(_ response: PluginWorkerResponse) throws {
        guard let requestID = response.requestID, !requestID.isEmpty,
              requestID.utf16.count <= 100 else {
            throw PluginWorkerProtocolError.invalidMessage
        }
        switch response.type {
        case .registerCommand:
            guard let id = response.id, !id.isEmpty,
                  id.utf16.count <= PluginManifestSecurity.maximumCommandIDUTF16Count,
                  id.utf8.allSatisfy({ byte in
                      (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                          || (0x61...0x7A).contains(byte) || byte == 0x2D
                          || byte == 0x2E || byte == 0x5F
                  }),
                  let title = response.title,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.utf16.count <= PluginManifestSecurity.maximumCommandTitleUTF16Count,
                  response.text == nil else {
                throw PluginWorkerProtocolError.invalidMessage
            }
        case .replaceDocument:
            guard let text = response.text else {
                throw PluginWorkerProtocolError.invalidMessage
            }
            guard text.utf8.count <= PluginWorkerProtocol.maximumReplacementBytes else {
                throw PluginWorkerProtocolError.replacementTooLarge(
                    maximumBytes: PluginWorkerProtocol.maximumReplacementBytes
                )
            }
            guard response.id == nil, response.title == nil else {
                throw PluginWorkerProtocolError.invalidMessage
            }
        case .notify:
            guard let text = response.text, text.utf16.count <= 500,
                  response.id == nil, response.title == nil else {
                throw PluginWorkerProtocolError.invalidMessage
            }
        case .completed:
            guard response.id == nil, response.title == nil, response.text == nil else {
                throw PluginWorkerProtocolError.invalidMessage
            }
        case .failed:
            guard let text = response.text,
                  !text.isEmpty,
                  text.utf16.count <= PluginWorkerProtocol.maximumFailureUTF16Count,
                  response.id == nil, response.title == nil else {
                throw PluginWorkerProtocolError.invalidMessage
            }
        }
    }

    private static func checkedPayload(_ data: Data) throws -> Data {
        var payload = data
        if payload.last == 0x0a { payload.removeLast() }
        guard !payload.isEmpty, payload.count <= PluginWorkerProtocol.maximumMessageBytes else {
            throw PluginWorkerProtocolError.messageTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumMessageBytes
            )
        }
        return payload
    }

    private static func validate(_ request: PluginWorkerRequest) throws {
        guard !request.requestID.isEmpty, request.requestID.utf16.count <= 100 else {
            throw PluginWorkerProtocolError.invalidRequest
        }
        switch request.type {
        case .load:
            guard let source = request.source,
                  source.count <= PluginWorkerProtocol.maximumSourceBytes,
                  request.sourceSHA256?.isEmpty == false,
                  request.commandID == nil, request.context == nil else {
                throw PluginWorkerProtocolError.invalidRequest
            }
        case .activate, .deactivate:
            guard request.source == nil, request.sourceSHA256 == nil,
                  request.commandID == nil, request.context != nil else {
                throw PluginWorkerProtocolError.invalidRequest
            }
        case .runCommand:
            guard request.source == nil, request.sourceSHA256 == nil,
                  let commandID = request.commandID, !commandID.isEmpty,
                  commandID.utf16.count <= PluginManifestSecurity.maximumCommandIDUTF16Count,
                  request.context != nil else {
                throw PluginWorkerProtocolError.invalidRequest
            }
        }
    }
}

/// Incrementally frames newline-delimited messages while enforcing the bound
/// before allocating an unbounded line.
public struct PluginWorkerLineDecoder: Sendable {
    private var buffered = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffered.append(data)
        var messages: [Data] = []
        while let newline = buffered.firstIndex(of: 0x0a) {
            let line = Data(buffered[..<newline])
            buffered.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= PluginWorkerProtocol.maximumMessageBytes else {
                throw PluginWorkerProtocolError.messageTooLarge(
                    maximumBytes: PluginWorkerProtocol.maximumMessageBytes
                )
            }
            messages.append(line)
        }
        guard buffered.count <= PluginWorkerProtocol.maximumMessageBytes else {
            throw PluginWorkerProtocolError.messageTooLarge(
                maximumBytes: PluginWorkerProtocol.maximumMessageBytes
            )
        }
        return messages
    }

    public mutating func finish() throws {
        guard buffered.isEmpty else { throw PluginWorkerProtocolError.invalidMessage }
    }
}
