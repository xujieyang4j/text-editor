import CryptoKit
import Darwin
import Foundation

public enum TextFileCodecError: Error, Equatable, LocalizedError, Sendable {
    case notARegularFile
    case invalidMaximumByteCount
    case fileChangedDuringOpen
    case invalidData(TextEncoding)
    case oddUTF16ByteCount(TextEncoding)
    case unsupportedEncoding(TextEncoding)
    case cannotRepresent(TextEncoding)

    public var errorDescription: String? {
        switch self {
        case .notARegularFile:
            "The selected path is not a regular file."
        case .invalidMaximumByteCount:
            "The maximum editable byte count must not be negative."
        case .fileChangedDuringOpen:
            "The selected file changed while it was being opened."
        case let .invalidData(encoding):
            "Invalid \(encoding.displayName) data."
        case let .oddUTF16ByteCount(encoding):
            "Invalid \(encoding.displayName) data: the UTF-16 byte length is odd."
        case let .unsupportedEncoding(encoding):
            "\(encoding.displayName) is not available on this macOS installation."
        case let .cannotRepresent(encoding):
            "\(encoding.displayName) cannot represent every character in this document without data loss."
        }
    }
}

/// Foundation-backed conversion between exact disk bytes and editor text.
public enum TextFileCodec {
    /// Matches the native first-run setting (200 MiB). Callers can still use a
    /// stricter user-selected value; this only prevents the lower-level codec
    /// from unexpectedly falling back to the obsolete 20 MiB default.
    public static let defaultMaximumByteCount: Int64 = 200 * 1_024 * 1_024

    private static let utf8BOM = Data([0xef, 0xbb, 0xbf])
    private static let utf16LEBOM = Data([0xff, 0xfe])
    private static let utf16BEBOM = Data([0xfe, 0xff])

    /// The stable identity obtained from the exact descriptor used for a read.
    /// Callers can compare it with a previously authorised `stat` identity
    /// without reopening the path.
    struct DescriptorIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    struct DescriptorRead: Equatable, Sendable {
        let file: OpenedTextFile
        let identity: DescriptorIdentity

        init(file: OpenedTextFile, identity: DescriptorIdentity) {
            self.file = file
            self.identity = identity
        }
    }

    /// Read a regular file from one non-following descriptor while enforcing
    /// the editor's memory budget before loading its bytes. The same `fstat`ed
    /// descriptor supplies all bytes, eliminating path check/read races.
    public static func read(
        from url: URL,
        forcedEncoding: TextEncoding? = nil,
        maximumByteCount: Int64 = defaultMaximumByteCount
    ) throws -> OpenedTextFile {
        guard maximumByteCount >= 0 else {
            throw TextFileCodecError.invalidMaximumByteCount
        }
        let sourceURL = url.standardizedFileURL
        let resolvedURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        return try readDescriptor(
            from: resolvedURL,
            sourceURL: sourceURL,
            forcedEncoding: forcedEncoding,
            maximumByteCount: maximumByteCount,
            expectedIdentity: nil
        ).file
    }

    static func readDescriptor(
        from url: URL,
        forcedEncoding: TextEncoding? = nil,
        maximumByteCount: Int64 = defaultMaximumByteCount
    ) throws -> DescriptorRead {
        let sourceURL = url.standardizedFileURL
        let physicalURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        return try readDescriptor(
            from: physicalURL,
            sourceURL: sourceURL,
            forcedEncoding: forcedEncoding,
            maximumByteCount: maximumByteCount,
            expectedIdentity: nil
        )
    }

    static func readDescriptor(
        from physicalURL: URL,
        sourceURL: URL,
        forcedEncoding: TextEncoding? = nil,
        maximumByteCount: Int64 = defaultMaximumByteCount,
        expectedIdentity: DescriptorIdentity?
    ) throws -> DescriptorRead {
        guard maximumByteCount >= 0 else {
            throw TextFileCodecError.invalidMaximumByteCount
        }
        let descriptor = Darwin.open(
            physicalURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        return try readDescriptor(
            descriptor,
            sourceURL: sourceURL,
            forcedEncoding: forcedEncoding,
            maximumByteCount: maximumByteCount,
            expectedIdentity: expectedIdentity
        )
    }

    /// Internal entry point for a descriptor already opened with trusted path
    /// traversal. Ownership stays with the caller; this method never closes it.
    static func readDescriptor(
        _ descriptor: Int32,
        sourceURL: URL,
        forcedEncoding: TextEncoding? = nil,
        maximumByteCount: Int64 = defaultMaximumByteCount,
        expectedIdentity: DescriptorIdentity? = nil
    ) throws -> DescriptorRead {
        guard maximumByteCount >= 0 else {
            throw TextFileCodecError.invalidMaximumByteCount
        }

        let status = try descriptorStatus(descriptor)
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw TextFileCodecError.notARegularFile
        }
        guard status.st_size >= 0 else { throw posixError(.EIO) }
        let identity = descriptorIdentity(status)
        guard expectedIdentity == nil || expectedIdentity == identity else {
            throw TextFileCodecError.fileChangedDuringOpen
        }
        let statedLength = Int64(status.st_size)
        if statedLength > maximumByteCount {
            return DescriptorRead(
                file: OpenedTextFile(
                    url: sourceURL,
                    content: "",
                    encoding: .utf8,
                    lineEnding: .lf,
                    revision: nil,
                    byteLength: statedLength,
                    isBinary: false,
                    isTooLarge: true,
                    encodingLocked: forcedEncoding != nil
                ),
                identity: identity
            )
        }

        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
        var data = Data()
        data.reserveCapacity(Int(min(statedLength, 1_048_576)))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = maximumByteCount - Int64(data.count)
            let requested = remaining >= Int64(buffer.count)
                ? buffer.count
                : Int(remaining) + 1
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            guard Int64(count) <= remaining else {
                let finalStatus = try descriptorStatus(descriptor)
                guard descriptorIdentity(finalStatus) == identity,
                      (finalStatus.st_mode & S_IFMT) == S_IFREG else {
                    throw TextFileCodecError.fileChangedDuringOpen
                }
                return DescriptorRead(
                    file: OpenedTextFile(
                        url: sourceURL,
                        content: "",
                        encoding: .utf8,
                        lineEnding: .lf,
                        revision: nil,
                        byteLength: max(
                            Int64(finalStatus.st_size),
                            Int64(data.count) + Int64(count)
                        ),
                        isBinary: false,
                        isTooLarge: true,
                        encodingLocked: forcedEncoding != nil
                    ),
                    identity: identity
                )
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        let finalStatus = try descriptorStatus(descriptor)
        guard descriptorRemainedStable(from: status, to: finalStatus),
              Int64(finalStatus.st_size) == Int64(data.count) else {
            throw TextFileCodecError.fileChangedDuringOpen
        }

        let decoded = try decode(
            data,
            sourceURL: sourceURL,
            forcedEncoding: forcedEncoding,
            maximumByteCount: maximumByteCount
        )
        return DescriptorRead(file: decoded, identity: identity)
    }

    /// Apply file-open policy to bytes already in memory.
    public static func decode(
        _ data: Data,
        sourceURL: URL,
        forcedEncoding: TextEncoding? = nil,
        maximumByteCount: Int64 = defaultMaximumByteCount
    ) throws -> OpenedTextFile {
        guard maximumByteCount >= 0 else {
            throw TextFileCodecError.invalidMaximumByteCount
        }

        let byteLength = Int64(data.count)
        let rawRevision = revision(of: data)
        if byteLength > maximumByteCount {
            return OpenedTextFile(
                url: sourceURL,
                content: "",
                encoding: .utf8,
                lineEnding: .lf,
                revision: rawRevision,
                byteLength: byteLength,
                isBinary: false,
                isTooLarge: true,
                encodingLocked: forcedEncoding != nil
            )
        }

        let detected = detectEncoding(in: data)
        let binaryEncoding = forcedEncoding ?? detected
        if isBinary(data, encoding: binaryEncoding) {
            return OpenedTextFile(
                url: sourceURL,
                content: "",
                encoding: binaryEncoding,
                lineEnding: .lf,
                revision: rawRevision,
                byteLength: byteLength,
                isBinary: true,
                isTooLarge: false,
                encodingLocked: forcedEncoding != nil
            )
        }

        let decoded = forcedEncoding.map { decodeForDisplay(data, encoding: $0) }
            ?? decodeAutomatically(data)
        let lineEnding = detectLineEnding(in: decoded.content)
        let issue: EncodingIssue? = decoded.hadDecodingErrors
            ? .invalidBytes
            : (decoded.uncertain ? .uncertain : nil)

        return OpenedTextFile(
            url: sourceURL,
            content: normalizeLineEndings(decoded.content),
            encoding: decoded.encoding,
            lineEnding: lineEnding,
            revision: rawRevision,
            byteLength: byteLength,
            isBinary: false,
            isTooLarge: false,
            encodingLocked: forcedEncoding != nil,
            encodingIssue: issue
        )
    }

    /// Strictly decode bytes using an explicitly selected encoding. Only a BOM
    /// matching a BOM-bearing encoding is removed.
    public static func decodeText(
        _ data: Data,
        encoding: TextEncoding
    ) throws -> String {
        switch encoding {
        case .utf8, .utf8bom, .utf16le, .utf16be, .utf16leNoBom, .utf16beNoBom:
            let result = decodeUnicode(data, encoding: encoding)
            if result.oddByteCount {
                throw TextFileCodecError.oddUTF16ByteCount(encoding)
            }
            guard !result.hadErrors else {
                throw TextFileCodecError.invalidData(encoding)
            }
            return result.content
        case .windows1252:
            return decodeWindows1252(data).content
        case .isoLatin1:
            return decodeISOLatin1(data)
        case .gb18030, .gbk, .big5, .shiftJIS:
            let foundationEncoding = try foundationEncoding(for: encoding)
            guard let string = String(data: data, encoding: foundationEncoding),
                  let roundTrip = string.data(using: foundationEncoding, allowLossyConversion: false),
                  roundTrip == data else {
                throw TextFileCodecError.invalidData(encoding)
            }
            return string
        }
    }

    /// Decode for display, replacing malformed Unicode and recording whether
    /// the original bytes failed an exact round trip.
    public static func decodeForDisplay(
        _ data: Data,
        encoding requestedEncoding: TextEncoding
    ) -> DecodedText {
        let physicalEncoding = physicalEncoding(for: data, requested: requestedEncoding)
        switch requestedEncoding {
        case .utf8, .utf8bom, .utf16le, .utf16be, .utf16leNoBom, .utf16beNoBom:
            let result = decodeUnicode(data, encoding: requestedEncoding)
            return DecodedText(
                content: result.content,
                encoding: physicalEncoding,
                hadDecodingErrors: result.hadErrors || result.oddByteCount,
                uncertain: false
            )
        case .windows1252:
            let result = decodeWindows1252(data)
            return DecodedText(
                content: result.content,
                encoding: physicalEncoding,
                hadDecodingErrors: result.hadErrors,
                uncertain: false
            )
        case .isoLatin1:
            return DecodedText(
                content: decodeISOLatin1(data),
                encoding: physicalEncoding,
                hadDecodingErrors: false,
                uncertain: false
            )
        case .gb18030, .gbk, .big5, .shiftJIS:
            do {
                return DecodedText(
                    content: try decodeText(data, encoding: requestedEncoding),
                    encoding: physicalEncoding,
                    hadDecodingErrors: false,
                    uncertain: false
                )
            } catch {
                let fallback = decodeLegacyLossily(data, encoding: requestedEncoding)
                return DecodedText(
                    content: fallback,
                    encoding: physicalEncoding,
                    hadDecodingErrors: true,
                    uncertain: false
                )
            }
        }
    }

    /// Automatically detect BOM-bearing Unicode and conservatively recognisable
    /// BOM-less UTF-16. All other input is treated as UTF-8.
    public static func decodeAutomatically(_ data: Data) -> DecodedText {
        let encoding = detectEncoding(in: data)
        let decoded = decodeForDisplay(data, encoding: encoding)
        return DecodedText(
            content: decoded.content,
            encoding: decoded.encoding,
            hadDecodingErrors: decoded.hadDecodingErrors,
            uncertain: encoding == .utf16leNoBom || encoding == .utf16beNoBom
        )
    }

    /// Encode editor text after converting every existing line-break spelling
    /// to the requested physical convention. Legacy writes are accepted only
    /// when they round-trip exactly.
    public static func encode(
        _ content: String,
        encoding: TextEncoding,
        lineEnding: LineEnding
    ) throws -> Data {
        let text = applyLineEnding(content, lineEnding: lineEnding)
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8bom:
            return utf8BOM + Data(text.utf8)
        case .utf16le:
            return utf16LEBOM + encodeUTF16Body(text, littleEndian: true)
        case .utf16be:
            return utf16BEBOM + encodeUTF16Body(text, littleEndian: false)
        case .utf16leNoBom:
            return encodeUTF16Body(text, littleEndian: true)
        case .utf16beNoBom:
            return encodeUTF16Body(text, littleEndian: false)
        case .isoLatin1:
            guard text.unicodeScalars.allSatisfy({ $0.value <= 0xff }) else {
                throw TextFileCodecError.cannotRepresent(encoding)
            }
            return Data(text.unicodeScalars.map { UInt8($0.value) })
        case .windows1252:
            guard let result = encodeWindows1252(text) else {
                throw TextFileCodecError.cannotRepresent(encoding)
            }
            return result
        case .gb18030, .gbk, .big5, .shiftJIS:
            let foundationEncoding = try foundationEncoding(for: encoding)
            guard let result = text.data(using: foundationEncoding, allowLossyConversion: false),
                  let roundTrip = String(data: result, encoding: foundationEncoding),
                  roundTrip == text else {
                throw TextFileCodecError.cannotRepresent(encoding)
            }
            return result
        }
    }

    /// SHA-256 of exact bytes, formatted as the opaque revision used by saves.
    public static func revision(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func revision(ofFileAt url: URL) throws -> String {
        let physicalURL = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = Darwin.open(physicalURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        let status = try descriptorStatus(descriptor)
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw TextFileCodecError.notARegularFile
        }
        guard status.st_size >= 0 else { throw posixError(.EIO) }
        let identity = descriptorIdentity(status)
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError() }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            hash.update(data: Data(buffer.prefix(Int(count))))
        }
        let finalStatus = try descriptorStatus(descriptor)
        guard descriptorRemainedStable(from: status, to: finalStatus) else {
            throw TextFileCodecError.fileChangedDuringOpen
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func posixError(_ fallback: POSIXErrorCode = .EIO) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? fallback)
    }

    private static func descriptorStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        return status
    }

    private static func descriptorIdentity(_ status: stat) -> DescriptorIdentity {
        DescriptorIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    private static func descriptorRemainedStable(
        from initial: stat,
        to final: stat
    ) -> Bool {
        guard descriptorIdentity(initial) == descriptorIdentity(final),
              (final.st_mode & S_IFMT) == S_IFREG,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec else {
            return false
        }
        return final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec
            && final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec
    }

    public static func detectEncoding(in data: Data) -> TextEncoding {
        if data.starts(with: utf8BOM) { return .utf8bom }
        if data.starts(with: utf16LEBOM) { return .utf16le }
        if data.starts(with: utf16BEBOM) { return .utf16be }
        return detectBomlessUTF16(data) ?? .utf8
    }

    public static func detectLineEnding(in text: String) -> LineEnding {
        if text.range(of: "\r\n") != nil { return .crlf }
        if text.range(of: "\r") != nil { return .cr }
        return .lf
    }

    public static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    public static func applyLineEnding(
        _ text: String,
        lineEnding: LineEnding
    ) -> String {
        let normalized = normalizeLineEndings(text)
        switch lineEnding {
        case .lf: return normalized
        case .crlf: return normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return normalized.replacingOccurrences(of: "\n", with: "\r")
        }
    }

    public static func isBinary(_ data: Data, encoding: TextEncoding) -> Bool {
        guard !encoding.isUTF16 else { return false }
        return data.prefix(8_192).contains(0)
    }

    private static func detectBomlessUTF16(_ data: Data) -> TextEncoding? {
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
        if oddNuls >= expectedMinimum, evenNuls <= unexpectedMaximum, evenASCII >= expectedMinimum {
            return .utf16leNoBom
        }
        if evenNuls >= expectedMinimum, oddNuls <= unexpectedMaximum, oddASCII >= expectedMinimum {
            return .utf16beNoBom
        }
        return nil
    }

    private static func isASCIILike(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0a || byte == 0x0d || (0x20...0x7e).contains(byte)
    }

    private static func physicalEncoding(
        for data: Data,
        requested: TextEncoding
    ) -> TextEncoding {
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
        encoding: TextEncoding
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
                content: content,
                hadErrors: Data(content.utf8) != payload,
                oddByteCount: false
            )
        }

        let littleEndian = encoding == .utf16le || encoding == .utf16leNoBom
        let bytes = [UInt8](payload)
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            codeUnits.append(littleEndian ? first | (second << 8) : (first << 8) | second)
            index += 2
        }
        var content = String(decoding: codeUnits, as: UTF16.self)
        let completePayload = Data(payload.prefix(bytes.count - (bytes.count % 2)))
        let roundTrip = encodeUTF16Body(content, littleEndian: littleEndian)
        let malformed = roundTrip != completePayload
        let odd = !bytes.count.isMultiple(of: 2)
        if odd { content.append("\u{fffd}") }
        return UnicodeDecodeResult(
            content: content,
            hadErrors: malformed,
            oddByteCount: odd
        )
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

    private static func foundationEncoding(for encoding: TextEncoding) throws -> String.Encoding {
        // CFString encodings converted to NSStringEncoding have bit 31 set.
        switch encoding {
        case .gbk: return String.Encoding(rawValue: 0x8000_0631)
        case .gb18030: return String.Encoding(rawValue: 0x8000_0632)
        case .big5: return String.Encoding(rawValue: 0x8000_0a03)
        case .shiftJIS: return .shiftJIS
        case .windows1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        default: throw TextFileCodecError.unsupportedEncoding(encoding)
        }
    }

    private static func decodeLegacyLossily(_ data: Data, encoding: TextEncoding) -> String {
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
            for length in stride(from: min(maximumUnit, bytes.count - index), through: 1, by: -1) {
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

    private static func decodeWindows1252(_ data: Data) -> (content: String, hadErrors: Bool) {
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
        for byte in data {
            scalars.append(UnicodeScalar(UInt32(byte))!)
        }
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
