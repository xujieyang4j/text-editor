import CryptoKit
import Foundation

public enum MobileTextCodecError: Error, Equatable, LocalizedError, Sendable {
    case invalidMaximumByteCount
    case invalidData(MobileTextEncoding)
    case oddUTF16ByteCount(MobileTextEncoding)
    case unsupportedEncoding(MobileTextEncoding)
    case cannotRepresent(MobileTextEncoding)

    public var errorDescription: String? {
        switch self {
        case .invalidMaximumByteCount:
            NSLocalizedString("error_invalid_byte_limit", comment: "")
        case let .invalidData(encoding):
            String(
                format: NSLocalizedString("error_invalid_encoding_data", comment: ""),
                encoding.displayName
            )
        case let .oddUTF16ByteCount(encoding):
            String(
                format: NSLocalizedString("error_odd_utf16_data", comment: ""),
                encoding.displayName
            )
        case let .unsupportedEncoding(encoding):
            String(
                format: NSLocalizedString("error_encoding_unavailable", comment: ""),
                encoding.displayName
            )
        case let .cannotRepresent(encoding):
            String(
                format: NSLocalizedString("error_encoding_cannot_represent", comment: ""),
                encoding.displayName
            )
        }
    }
}

public enum MobileTextCodec {
    /// Mobile deliberately uses a lower memory ceiling than desktop.
    public static let defaultMaximumByteCount: Int64 = 20 * 1_024 * 1_024

    private static let utf8BOM = Data([0xef, 0xbb, 0xbf])
    private static let utf16LEBOM = Data([0xff, 0xfe])
    private static let utf16BEBOM = Data([0xfe, 0xff])

    public static func decode(
        _ data: Data,
        forcedEncoding: MobileTextEncoding? = nil,
        maximumByteCount: Int64 = defaultMaximumByteCount
    ) throws -> MobileOpenedTextFile {
        guard maximumByteCount >= 0 else { throw MobileTextCodecError.invalidMaximumByteCount }
        let byteLength = Int64(data.count)
        let rawRevision = revision(of: data)
        guard byteLength <= maximumByteCount else {
            return MobileOpenedTextFile(
                content: "", encoding: forcedEncoding ?? .utf8, lineEnding: .lf,
                revision: rawRevision, byteLength: byteLength, isBinary: false, isTooLarge: true
            )
        }

        let detected = detectEncoding(in: data)
        let selected = forcedEncoding ?? detected
        guard !isBinary(data, encoding: selected) else {
            return MobileOpenedTextFile(
                content: "", encoding: selected, lineEnding: .lf, revision: rawRevision,
                byteLength: byteLength, isBinary: true, isTooLarge: false
            )
        }

        let decoded: DisplayDecode
        if let forcedEncoding {
            let content = try decodeText(data, encoding: forcedEncoding)
            decoded = DisplayDecode(
                content: content,
                physicalEncoding: physicalEncoding(for: data, requested: forcedEncoding),
                hadErrors: false
            )
        } else {
            decoded = decodeForDisplay(data, encoding: selected)
        }
        let issue: MobileEncodingIssue? = decoded.hadErrors
            ? .invalidBytes
            : (forcedEncoding == nil && (selected == .utf16leNoBom || selected == .utf16beNoBom)
                ? .uncertain : nil)
        return MobileOpenedTextFile(
            content: normalizeLineEndings(decoded.content),
            encoding: decoded.physicalEncoding,
            lineEnding: detectLineEnding(in: decoded.content),
            revision: rawRevision,
            byteLength: byteLength,
            isBinary: false,
            isTooLarge: false,
            encodingIssue: issue,
            encodingRecoveryData: issue == nil ? nil : data
        )
    }

    public static func decodeText(_ data: Data, encoding: MobileTextEncoding) throws -> String {
        switch encoding {
        case .utf8, .utf8bom, .utf16le, .utf16be, .utf16leNoBom, .utf16beNoBom:
            let result = decodeUnicode(data, encoding: encoding)
            if result.oddByteCount { throw MobileTextCodecError.oddUTF16ByteCount(encoding) }
            guard !result.hadErrors else { throw MobileTextCodecError.invalidData(encoding) }
            return result.content
        case .windows1252:
            let result = decodeWindows1252(data)
            guard !result.hadErrors else { throw MobileTextCodecError.invalidData(encoding) }
            return result.content
        case .isoLatin1:
            return decodeISOLatin1(data)
        case .gb18030, .gbk, .big5, .shiftJIS:
            let foundationEncoding = try foundationEncoding(for: encoding)
            guard let string = String(data: data, encoding: foundationEncoding),
                  let roundTrip = string.data(using: foundationEncoding, allowLossyConversion: false),
                  roundTrip == data else {
                throw MobileTextCodecError.invalidData(encoding)
            }
            return string
        }
    }

    public static func encode(
        _ content: String,
        encoding: MobileTextEncoding,
        lineEnding: MobileLineEnding
    ) throws -> Data {
        let text = applyLineEnding(content, lineEnding: lineEnding)
        switch encoding {
        case .utf8: return Data(text.utf8)
        case .utf8bom: return utf8BOM + Data(text.utf8)
        case .utf16le: return utf16LEBOM + encodeUTF16Body(text, littleEndian: true)
        case .utf16be: return utf16BEBOM + encodeUTF16Body(text, littleEndian: false)
        case .utf16leNoBom: return encodeUTF16Body(text, littleEndian: true)
        case .utf16beNoBom: return encodeUTF16Body(text, littleEndian: false)
        case .isoLatin1:
            guard text.unicodeScalars.allSatisfy({ $0.value <= 0xff }) else {
                throw MobileTextCodecError.cannotRepresent(encoding)
            }
            return Data(text.unicodeScalars.map { UInt8($0.value) })
        case .windows1252:
            guard let result = encodeWindows1252(text) else {
                throw MobileTextCodecError.cannotRepresent(encoding)
            }
            return result
        case .gb18030, .gbk, .big5, .shiftJIS:
            let foundationEncoding = try foundationEncoding(for: encoding)
            guard let result = text.data(using: foundationEncoding, allowLossyConversion: false),
                  String(data: result, encoding: foundationEncoding) == text else {
                throw MobileTextCodecError.cannotRepresent(encoding)
            }
            return result
        }
    }

    public static func revision(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func detectEncoding(in data: Data) -> MobileTextEncoding {
        if data.starts(with: utf8BOM) { return .utf8bom }
        if data.starts(with: utf16LEBOM) { return .utf16le }
        if data.starts(with: utf16BEBOM) { return .utf16be }
        return detectBomlessUTF16(data) ?? .utf8
    }

    public static func detectLineEnding(in text: String) -> MobileLineEnding {
        if text.range(of: "\r\n") != nil { return .crlf }
        if text.range(of: "\r") != nil { return .cr }
        return .lf
    }

    public static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    public static func applyLineEnding(_ text: String, lineEnding: MobileLineEnding) -> String {
        let normalized = normalizeLineEndings(text)
        switch lineEnding {
        case .lf: return normalized
        case .crlf: return normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return normalized.replacingOccurrences(of: "\n", with: "\r")
        }
    }

    public static func isBinary(_ data: Data, encoding: MobileTextEncoding) -> Bool {
        !encoding.isUTF16 && data.prefix(8_192).contains(0)
    }

    private struct DisplayDecode {
        let content: String
        let physicalEncoding: MobileTextEncoding
        let hadErrors: Bool
    }

    private static func decodeForDisplay(
        _ data: Data,
        encoding: MobileTextEncoding
    ) -> DisplayDecode {
        let physical = physicalEncoding(for: data, requested: encoding)
        switch encoding {
        case .utf8, .utf8bom, .utf16le, .utf16be, .utf16leNoBom, .utf16beNoBom:
            let result = decodeUnicode(data, encoding: encoding)
            return DisplayDecode(
                content: result.content, physicalEncoding: physical,
                hadErrors: result.hadErrors || result.oddByteCount
            )
        case .windows1252:
            let result = decodeWindows1252(data)
            return DisplayDecode(
                content: result.content, physicalEncoding: physical, hadErrors: result.hadErrors
            )
        case .isoLatin1:
            return DisplayDecode(
                content: decodeISOLatin1(data), physicalEncoding: physical, hadErrors: false
            )
        case .gb18030, .gbk, .big5, .shiftJIS:
            if let exact = try? decodeText(data, encoding: encoding) {
                return DisplayDecode(content: exact, physicalEncoding: physical, hadErrors: false)
            }
            return DisplayDecode(
                content: decodeLegacyLossily(data, encoding: encoding),
                physicalEncoding: physical, hadErrors: true
            )
        }
    }

    private static func detectBomlessUTF16(_ data: Data) -> MobileTextEncoding? {
        guard data.count >= 8, data.count.isMultiple(of: 2) else { return nil }
        let bytes = [UInt8](data)
        let pairCount = min(bytes.count / 2, 4_096)
        var evenNuls = 0
        var oddNuls = 0
        var evenASCII = 0
        var oddASCII = 0
        for pair in 0..<pairCount {
            let even = bytes[pair * 2]
            let odd = bytes[pair * 2 + 1]
            if even == 0 { evenNuls += 1 }
            if odd == 0 { oddNuls += 1 }
            if isASCIILike(even) { evenASCII += 1 }
            if isASCIILike(odd) { oddASCII += 1 }
        }
        let expectedMinimum = Int(ceil(Double(pairCount) * 0.6))
        let unexpectedMaximum = Int(floor(Double(pairCount) * 0.05))
        if oddNuls >= expectedMinimum, evenNuls <= unexpectedMaximum,
           evenASCII >= expectedMinimum { return .utf16leNoBom }
        if evenNuls >= expectedMinimum, oddNuls <= unexpectedMaximum,
           oddASCII >= expectedMinimum { return .utf16beNoBom }
        return nil
    }

    private static func isASCIILike(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0a || byte == 0x0d || (0x20...0x7e).contains(byte)
    }

    private static func physicalEncoding(
        for data: Data,
        requested: MobileTextEncoding
    ) -> MobileTextEncoding {
        switch requested {
        case .utf8bom where !data.starts(with: utf8BOM): return .utf8
        case .utf16le where !data.starts(with: utf16LEBOM): return .utf16leNoBom
        case .utf16be where !data.starts(with: utf16BEBOM): return .utf16beNoBom
        default: return requested
        }
    }

    private struct UnicodeDecodeResult {
        let content: String
        let hadErrors: Bool
        let oddByteCount: Bool
    }

    private static func decodeUnicode(
        _ data: Data,
        encoding: MobileTextEncoding
    ) -> UnicodeDecodeResult {
        let payload: Data
        switch encoding {
        case .utf8bom where data.starts(with: utf8BOM): payload = data.dropFirst(3)
        case .utf16le where data.starts(with: utf16LEBOM): payload = data.dropFirst(2)
        case .utf16be where data.starts(with: utf16BEBOM): payload = data.dropFirst(2)
        default: payload = data
        }
        if encoding == .utf8 || encoding == .utf8bom {
            let content = String(decoding: payload, as: UTF8.self)
            return UnicodeDecodeResult(
                content: content, hadErrors: Data(content.utf8) != payload, oddByteCount: false
            )
        }
        let littleEndian = encoding == .utf16le || encoding == .utf16leNoBom
        let bytes = [UInt8](payload)
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            units.append(littleEndian ? first | (second << 8) : (first << 8) | second)
            index += 2
        }
        var content = String(decoding: units, as: UTF16.self)
        let complete = Data(payload.prefix(bytes.count - (bytes.count % 2)))
        let malformed = encodeUTF16Body(content, littleEndian: littleEndian) != complete
        let odd = !bytes.count.isMultiple(of: 2)
        if odd { content.append("\u{fffd}") }
        return UnicodeDecodeResult(content: content, hadErrors: malformed, oddByteCount: odd)
    }

    private static func encodeUTF16Body(_ text: String, littleEndian: Bool) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            if littleEndian {
                bytes.append(UInt8(truncatingIfNeeded: unit))
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
            } else {
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
                bytes.append(UInt8(truncatingIfNeeded: unit))
            }
        }
        return Data(bytes)
    }

    private static func foundationEncoding(
        for encoding: MobileTextEncoding
    ) throws -> String.Encoding {
        switch encoding {
        case .gbk: return String.Encoding(rawValue: 0x8000_0631)
        case .gb18030: return String.Encoding(rawValue: 0x8000_0632)
        case .big5: return String.Encoding(rawValue: 0x8000_0a03)
        case .shiftJIS: return .shiftJIS
        case .windows1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        default: throw MobileTextCodecError.unsupportedEncoding(encoding)
        }
    }

    private static func decodeLegacyLossily(
        _ data: Data,
        encoding: MobileTextEncoding
    ) -> String {
        guard let foundationEncoding = try? foundationEncoding(for: encoding) else {
            return String(repeating: "\u{fffd}", count: data.count)
        }
        let bytes = [UInt8](data)
        let maximumUnit = encoding == .gb18030 ? 4 : 2
        var output = ""
        var index = 0
        while index < bytes.count {
            var decoded: String?
            var consumed = 0
            for length in stride(
                from: min(maximumUnit, bytes.count - index), through: 1, by: -1
            ) {
                let slice = Data(bytes[index..<(index + length)])
                if let candidate = String(data: slice, encoding: foundationEncoding),
                   candidate.data(using: foundationEncoding, allowLossyConversion: false) == slice {
                    decoded = candidate
                    consumed = length
                    break
                }
            }
            if let decoded {
                output += decoded
                index += consumed
            } else {
                output.append("\u{fffd}")
                index += 1
            }
        }
        return output
    }

    private static let windows1252Decode: [UInt8: UnicodeScalar] = [
        0x80: "€", 0x82: "‚", 0x83: "ƒ", 0x84: "„", 0x85: "…",
        0x86: "†", 0x87: "‡", 0x88: "ˆ", 0x89: "‰", 0x8a: "Š",
        0x8b: "‹", 0x8c: "Œ", 0x8e: "Ž", 0x91: "‘", 0x92: "’",
        0x93: "“", 0x94: "”", 0x95: "•", 0x96: "–", 0x97: "—",
        0x98: "˜", 0x99: "™", 0x9a: "š", 0x9b: "›", 0x9c: "œ",
        0x9e: "ž", 0x9f: "Ÿ"
    ]

    private static func decodeWindows1252(
        _ data: Data
    ) -> (content: String, hadErrors: Bool) {
        let undefined: Set<UInt8> = [0x81, 0x8d, 0x8f, 0x90, 0x9d]
        var scalars = String.UnicodeScalarView()
        var hadErrors = false
        for byte in data {
            if let scalar = windows1252Decode[byte] {
                scalars.append(scalar)
            } else if undefined.contains(byte) {
                scalars.append("\u{fffd}")
                hadErrors = true
            } else {
                scalars.append(UnicodeScalar(UInt32(byte))!)
            }
        }
        return (String(scalars), hadErrors)
    }

    private static func decodeISOLatin1(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for byte in data { scalars.append(UnicodeScalar(UInt32(byte))!) }
        return String(scalars)
    }

    private static func encodeWindows1252(_ text: String) -> Data? {
        let special = Dictionary(uniqueKeysWithValues: windows1252Decode.map { ($0.value, $0.key) })
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if let byte = special[scalar] {
                bytes.append(byte)
            } else if scalar.value <= 0x7f || (0xa0...0xff).contains(scalar.value) {
                bytes.append(UInt8(scalar.value))
            } else {
                return nil
            }
        }
        return Data(bytes)
    }
}
