import Foundation
import Darwin
import XCTest
@testable import LumenEditorCore

final class TextFileCodecTests: XCTestCase {
    func testEncodingIdentifiersRoundTripThroughCodable() throws {
        for encoding in TextEncoding.allCases {
            let data = try JSONEncoder().encode(encoding)
            XCTAssertEqual(try JSONDecoder().decode(TextEncoding.self, from: data), encoding)
        }
        XCTAssertEqual(TextEncoding.utf16leNoBom.rawValue, "utf16le-nobom")
        XCTAssertEqual(TextEncoding.shiftJIS.rawValue, "shiftjis")
        XCTAssertEqual(TextEncoding.isoLatin1.rawValue, "iso88591")
    }

    func testBOMDetectionHasPriority() {
        XCTAssertEqual(TextFileCodec.detectEncoding(in: Data([0xef, 0xbb, 0xbf, 0, 65, 0, 66])), .utf8bom)
        XCTAssertEqual(TextFileCodec.detectEncoding(in: Data([0xff, 0xfe, 0xff])), .utf16le)
        XCTAssertEqual(TextFileCodec.detectEncoding(in: Data([0xfe, 0xff, 0xff])), .utf16be)
        XCTAssertEqual(TextFileCodec.detectEncoding(in: Data()), .utf8)
    }

    func testConservativeBomlessUTF16Detection() throws {
        let text = "hello world 中文"
        let little = try TextFileCodec.encode(text, encoding: .utf16leNoBom, lineEnding: .lf)
        let big = try TextFileCodec.encode(text, encoding: .utf16beNoBom, lineEnding: .lf)
        XCTAssertEqual(TextFileCodec.detectEncoding(in: little), .utf16leNoBom)
        XCTAssertEqual(TextFileCodec.detectEncoding(in: big), .utf16beNoBom)
        XCTAssertEqual(TextFileCodec.detectEncoding(in: Data([65, 0, 66, 0])), .utf8)
        XCTAssertEqual(TextFileCodec.detectEncoding(in: Data(repeating: 0, count: 16)), .utf8)
    }

    func testUnicodeBOMAndStrictDecode() throws {
        let utf8 = try TextFileCodec.encode("A中🙂", encoding: .utf8bom, lineEnding: .lf)
        XCTAssertEqual(Array(utf8.prefix(3)), [0xef, 0xbb, 0xbf])
        XCTAssertEqual(try TextFileCodec.decodeText(utf8, encoding: .utf8bom), "A中🙂")
        XCTAssertEqual(try TextFileCodec.decodeText(utf8, encoding: .utf8), "\u{feff}A中🙂")

        for encoding in [TextEncoding.utf16le, .utf16be, .utf16leNoBom, .utf16beNoBom] {
            let data = try TextFileCodec.encode("A中🙂", encoding: encoding, lineEnding: .lf)
            XCTAssertEqual(try TextFileCodec.decodeText(data, encoding: encoding), "A中🙂")
        }

        XCTAssertThrowsError(try TextFileCodec.decodeText(Data([0xc0, 0xaf]), encoding: .utf8))
        XCTAssertThrowsError(try TextFileCodec.decodeText(Data([0xff, 0xfe, 0x41]), encoding: .utf16le))
    }

    func testPhysicalEncodingTracksMissingBOM() {
        let utf8 = TextFileCodec.decodeForDisplay(Data("plain".utf8), encoding: .utf8bom)
        XCTAssertEqual(utf8.encoding, .utf8)
        let utf16 = TextFileCodec.decodeForDisplay(Data([0x41, 0]), encoding: .utf16le)
        XCTAssertEqual(utf16.encoding, .utf16leNoBom)
    }

    func testMalformedInputRemainsDisplayableWithIssue() throws {
        let opened = try TextFileCodec.decode(
            Data([0xf0, 0x9f, 0x98]),
            sourceURL: URL(fileURLWithPath: "/tmp/malformed.txt")
        )
        XCTAssertEqual(opened.encodingIssue, .invalidBytes)
        XCTAssertTrue(opened.content.contains("\u{fffd}"))
    }

    func testLineEndingsAreDetectedNormalizedAndRestored() throws {
        let bytes = Data("one\r\ntwo\r\n".utf8)
        let opened = try TextFileCodec.decode(
            bytes,
            sourceURL: URL(fileURLWithPath: "/tmp/crlf.txt")
        )
        XCTAssertEqual(opened.lineEnding, .crlf)
        XCTAssertEqual(opened.content, "one\ntwo\n")
        XCTAssertEqual(
            try TextFileCodec.encode(opened.content, encoding: .utf8, lineEnding: .cr),
            Data("one\rtwo\r".utf8)
        )
        XCTAssertEqual(TextFileCodec.detectLineEnding(in: "a\rb\n"), .cr)
    }

    func testBinaryAndLargePolicies() throws {
        let binary = try TextFileCodec.decode(
            Data([65, 0, 66]),
            sourceURL: URL(fileURLWithPath: "/tmp/binary.dat")
        )
        XCTAssertTrue(binary.isBinary)
        XCTAssertNotNil(binary.revision)

        let allowedUTF16 = try TextFileCodec.decode(
            Data([65, 0, 66, 0]),
            sourceURL: URL(fileURLWithPath: "/tmp/utf16.txt"),
            forcedEncoding: .utf16leNoBom
        )
        XCTAssertFalse(allowedUTF16.isBinary)
        XCTAssertEqual(allowedUTF16.content, "AB")

        let large = try TextFileCodec.decode(
            Data("12345".utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/large.txt"),
            maximumByteCount: 4
        )
        XCTAssertTrue(large.isTooLarge)
        XCTAssertNotNil(large.revision)
    }

    func testReadUsesDescriptorAndPreservesLogicalSymlinkURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileCodecDescriptor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("selected.txt")
        try Data("descriptor bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let opened = try TextFileCodec.read(from: link)

        XCTAssertEqual(opened.url, link)
        XCTAssertEqual(opened.content, "descriptor bytes")
        XCTAssertEqual(opened.revision, TextFileCodec.revision(of: Data("descriptor bytes".utf8)))
    }

    func testDescriptorReadFollowsResolvedSymlinkButRejectsNonRegularDescriptor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileCodecNoFollow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        try Data("safe".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let followed = try TextFileCodec.readDescriptor(from: link)
        XCTAssertEqual(followed.file.url, link)
        XCTAssertEqual(followed.file.content, "safe")
        let rawLinkDescriptor = Darwin.open(link.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertLessThan(rawLinkDescriptor, 0)
        if rawLinkDescriptor >= 0 { _ = Darwin.close(rawLinkDescriptor) }

        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { if directoryDescriptor >= 0 { _ = Darwin.close(directoryDescriptor) } }
        XCTAssertThrowsError(try TextFileCodec.readDescriptor(
            directoryDescriptor,
            sourceURL: directory
        )) { error in
            XCTAssertEqual(error as? TextFileCodecError, .notARegularFile)
        }
    }

    func testDescriptorIdentityMismatchIsRejectedBeforeReadingBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileCodecIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let firstRead = try TextFileCodec.readDescriptor(from: first)
        let secondDescriptor = Darwin.open(second.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(secondDescriptor, 0)
        defer { if secondDescriptor >= 0 { _ = Darwin.close(secondDescriptor) } }

        XCTAssertThrowsError(try TextFileCodec.readDescriptor(
            secondDescriptor,
            sourceURL: second,
            expectedIdentity: firstRead.identity
        )) { error in
            XCTAssertEqual(error as? TextFileCodecError, .fileChangedDuringOpen)
        }
    }

    func testOpenDescriptorRemainsPinnedAfterPathReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileCodecPinned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selected.txt")
        let oldPath = directory.appendingPathComponent("old.txt")
        try Data("authorised bytes".utf8).write(to: file)
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        var openedStatus = stat()
        XCTAssertEqual(Darwin.fstat(descriptor, &openedStatus), 0)
        let expected = TextFileCodec.DescriptorIdentity(
            device: UInt64(openedStatus.st_dev),
            inode: UInt64(openedStatus.st_ino)
        )

        try FileManager.default.moveItem(at: file, to: oldPath)
        try Data("replacement bytes".utf8).write(to: file)
        let read = try TextFileCodec.readDescriptor(
            descriptor,
            sourceURL: file,
            expectedIdentity: expected
        )

        XCTAssertEqual(read.file.url, file)
        XCTAssertEqual(read.file.content, "authorised bytes")
        XCTAssertEqual(read.identity, expected)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "replacement bytes")
    }

    func testDescriptorReadDetectsGrowthPastBoundInsteadOfOverAllocating() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileCodecBound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("growing.txt")
        try Data("12345".utf8).write(to: file)

        let opened = try TextFileCodec.read(from: file, maximumByteCount: 4)

        XCTAssertTrue(opened.isTooLarge)
        XCTAssertEqual(opened.byteLength, 5)
        XCTAssertNil(opened.revision)
    }

    func testDescriptorReadUsesCurrentDescriptorSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileCodecSizeRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selected.txt")
        try Data("abcdef".utf8).write(to: file)
        let descriptor = Darwin.open(file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        XCTAssertEqual(Darwin.ftruncate(descriptor, off_t(3)), 0)

        let read = try TextFileCodec.readDescriptor(descriptor, sourceURL: file)

        XCTAssertEqual(read.file.content, "abc")
        XCTAssertEqual(read.file.byteLength, 3)
    }

    func testDescriptorReadAtExactLimitDoesNotConsumeUnboundedExtraBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileCodecExactBound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("exact.txt")
        try Data("1234".utf8).write(to: file)

        let opened = try TextFileCodec.read(from: file, maximumByteCount: 4)

        XCTAssertFalse(opened.isTooLarge)
        XCTAssertEqual(opened.content, "1234")
        XCTAssertNotNil(opened.revision)
    }

    func testRevisionHashesExactBytes() {
        XCTAssertEqual(
            TextFileCodec.revision(of: Data("abc".utf8)),
            "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertNotEqual(
            TextFileCodec.revision(of: Data("a\nb".utf8)),
            TextFileCodec.revision(of: Data("a\r\nb".utf8))
        )
    }

    func testSingleByteLegacyEncodings() throws {
        let latin = try TextFileCodec.encode("café£", encoding: .isoLatin1, lineEnding: .lf)
        XCTAssertEqual(latin, Data([0x63, 0x61, 0x66, 0xe9, 0xa3]))
        XCTAssertEqual(try TextFileCodec.decodeText(latin, encoding: .isoLatin1), "café£")

        let windows = try TextFileCodec.encode("“café”—€", encoding: .windows1252, lineEnding: .lf)
        XCTAssertEqual(windows, Data([0x93, 0x63, 0x61, 0x66, 0xe9, 0x94, 0x97, 0x80]))
        XCTAssertEqual(try TextFileCodec.decodeText(windows, encoding: .windows1252), "“café”—€")
        XCTAssertThrowsError(try TextFileCodec.encode("中文", encoding: .windows1252, lineEnding: .lf))
    }

    func testMultibyteLegacyRoundTripsOnMacOS() throws {
        // These bytes intentionally match the Electron/iconv-lite codec. A
        // round-trip-only assertion would miss mapping-table differences that
        // could otherwise change an existing file during the migration.
        let fixtures: [(TextEncoding, String, [UInt8])] = [
            (TextEncoding.gb18030, "中文😀€", [0xd6, 0xd0, 0xce, 0xc4, 0x94, 0x39, 0xfc, 0x36, 0xa2, 0xe3]),
            (.gbk, "中文€", [0xd6, 0xd0, 0xce, 0xc4, 0x80]),
            (.big5, "中文€", [0xa4, 0xa4, 0xa4, 0xe5, 0xa3, 0xe1]),
            (.shiftJIS, "日本語", [0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea])
        ]
        for (encoding, text, bytes) in fixtures {
            let encoded = try TextFileCodec.encode(text, encoding: encoding, lineEnding: .lf)
            XCTAssertEqual(encoded, Data(bytes), "Byte mismatch for \(encoding)")
            XCTAssertEqual(try TextFileCodec.decodeText(encoded, encoding: encoding), text)
        }
        XCTAssertThrowsError(try TextFileCodec.encode("😀", encoding: .gbk, lineEnding: .lf))
        XCTAssertThrowsError(try TextFileCodec.encode("😀", encoding: .big5, lineEnding: .lf))
        XCTAssertThrowsError(try TextFileCodec.encode("😀", encoding: .shiftJIS, lineEnding: .lf))
        XCTAssertThrowsError(try TextFileCodec.encode("¥", encoding: .shiftJIS, lineEnding: .lf))
    }
}
