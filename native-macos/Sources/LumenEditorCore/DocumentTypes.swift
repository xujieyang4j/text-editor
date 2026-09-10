import Foundation

/// Canonical on-disk text encodings understood by Lumen Editor.
///
/// The raw values intentionally match the identifiers used by the existing
/// Electron application and its persisted sessions.
public enum TextEncoding: String, CaseIterable, Codable, Equatable, Sendable {
    case utf8
    case utf8bom
    case utf16le
    case utf16be
    case utf16leNoBom = "utf16le-nobom"
    case utf16beNoBom = "utf16be-nobom"
    case gb18030
    case gbk
    case big5
    case shiftJIS = "shiftjis"
    case windows1252
    case isoLatin1 = "iso88591"

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8bom: "UTF-8 BOM"
        case .utf16le: "UTF-16 LE"
        case .utf16be: "UTF-16 BE"
        case .utf16leNoBom: "UTF-16 LE (no BOM)"
        case .utf16beNoBom: "UTF-16 BE (no BOM)"
        case .gb18030: "GB18030"
        case .gbk: "GBK"
        case .big5: "Big5"
        case .shiftJIS: "Shift JIS"
        case .windows1252: "Windows-1252"
        case .isoLatin1: "ISO-8859-1"
        }
    }

    /// Encodings that cannot be identified reliably without persisted intent.
    public var needsExplicitRead: Bool {
        switch self {
        case .utf8, .utf8bom, .utf16le, .utf16be:
            false
        case .utf16leNoBom, .utf16beNoBom, .gb18030, .gbk, .big5,
                .shiftJIS, .windows1252, .isoLatin1:
            true
        }
    }

    public var isUTF16: Bool {
        switch self {
        case .utf16le, .utf16be, .utf16leNoBom, .utf16beNoBom:
            true
        default:
            false
        }
    }
}

/// Physical newline convention retained while editor text uses logical LF.
public enum LineEnding: String, CaseIterable, Codable, Equatable, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
}

/// A warning attached to text that remains displayable but was not decoded
/// with complete confidence.
public enum EncodingIssue: String, Codable, Equatable, Sendable {
    case invalidBytes = "invalid-bytes"
    case uncertain
}

/// Result of decoding a byte buffer before file-policy metadata is attached.
public struct DecodedText: Codable, Sendable, Equatable {
    public let content: String
    public let encoding: TextEncoding
    public let hadDecodingErrors: Bool
    public let uncertain: Bool

    public init(
        content: String,
        encoding: TextEncoding,
        hadDecodingErrors: Bool,
        uncertain: Bool
    ) {
        self.content = content
        self.encoding = encoding
        self.hadDecodingErrors = hadDecodingErrors
        self.uncertain = uncertain
    }
}

/// A disk file prepared for the editor. `content` always uses logical LF;
/// `lineEnding` records the physical convention observed before normalisation.
public struct OpenedTextFile: Codable, Sendable, Equatable {
    public let url: URL
    public let content: String
    public let encoding: TextEncoding
    public let lineEnding: LineEnding
    public let revision: String?
    public let byteLength: Int64
    public let isBinary: Bool
    public let isTooLarge: Bool
    public let encodingLocked: Bool
    public let encodingIssue: EncodingIssue?

    public init(
        url: URL,
        content: String,
        encoding: TextEncoding,
        lineEnding: LineEnding,
        revision: String?,
        byteLength: Int64,
        isBinary: Bool,
        isTooLarge: Bool,
        encodingLocked: Bool = false,
        encodingIssue: EncodingIssue? = nil
    ) {
        self.url = url
        self.content = content
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.revision = revision
        self.byteLength = byteLength
        self.isBinary = isBinary
        self.isTooLarge = isTooLarge
        self.encodingLocked = encodingLocked
        self.encodingIssue = encodingIssue
    }

    /// Compatibility spelling used by the Electron document model.
    public var eol: LineEnding { lineEnding }

    /// Absolute file-system path, for callers that do not otherwise need a URL.
    public var path: String { url.path }
}
