import Foundation
import XCTest
@testable import LumenEditorMobileCore

final class MobileTextCodecTests: XCTestCase {
    func testEverySupportedEncodingAndLineEndingRoundTripsStrictly() throws {
        XCTAssertEqual(MobileTextEncoding.allCases.count, 12)
        XCTAssertEqual(MobileLineEnding.allCases.count, 3)
        for encoding in MobileTextEncoding.allCases {
            for lineEnding in MobileLineEnding.allCases {
                let content = fixture(for: encoding) + "\nsecond line\n"
                let encoded = try MobileTextCodec.encode(
                    content, encoding: encoding, lineEnding: lineEnding
                )
                let opened = try MobileTextCodec.decode(
                    encoded, forcedEncoding: encoding
                )
                XCTAssertEqual(opened.content, content, "\(encoding) / \(lineEnding)")
                XCTAssertEqual(opened.encoding, encoding, "\(encoding) / \(lineEnding)")
                XCTAssertEqual(opened.lineEnding, lineEnding, "\(encoding) / \(lineEnding)")
                XCTAssertNil(opened.encodingIssue, "\(encoding) / \(lineEnding)")
                XCTAssertNil(opened.encodingRecoveryData, "\(encoding) / \(lineEnding)")
                XCTAssertEqual(try MobileTextCodec.encode(
                    opened.content, encoding: opened.encoding,
                    lineEnding: opened.lineEnding
                ), encoded, "\(encoding) / \(lineEnding)")
            }
        }
    }

    func testUTF8BOMAndCRLFRoundTrip() throws {
        let source = Data([0xef, 0xbb, 0xbf]) + Data("第一行\r\nsecond\r\n".utf8)
        let opened = try MobileTextCodec.decode(source)
        XCTAssertEqual(opened.content, "第一行\nsecond\n")
        XCTAssertEqual(opened.encoding, .utf8bom)
        XCTAssertEqual(opened.lineEnding, .crlf)
        XCTAssertEqual(try MobileTextCodec.encode(
            opened.content, encoding: opened.encoding, lineEnding: opened.lineEnding
        ), source)
    }

    func testEastAsianEncodingFixturesMatchStandardBytes() throws {
        let fixtures: [(MobileTextEncoding, String, [UInt8])] = [
            (.gbk, "中文", [0xd6, 0xd0, 0xce, 0xc4]),
            (.gb18030, "😀", [0x94, 0x39, 0xfc, 0x36]),
            (.big5, "中文", [0xa4, 0xa4, 0xa4, 0xe5]),
            (.shiftJIS, "日本語", [0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea])
        ]
        try assertStandardFixtures(fixtures)
    }

    func testWesternEncodingFixturesMatchStandardBytes() throws {
        let fixtures: [(MobileTextEncoding, String, [UInt8])] = [
            (.windows1252, "café € —", [
                0x63, 0x61, 0x66, 0xe9, 0x20, 0x80, 0x20, 0x97
            ]),
            (.isoLatin1, "café £", [0x63, 0x61, 0x66, 0xe9, 0x20, 0xa3])
        ]
        try assertStandardFixtures(fixtures)
    }

    private func assertStandardFixtures(
        _ fixtures: [(MobileTextEncoding, String, [UInt8])]
    ) throws {
        for (encoding, content, bytes) in fixtures {
            let data = Data(bytes)
            XCTAssertEqual(
                try MobileTextCodec.decodeText(data, encoding: encoding),
                content, encoding.displayName
            )
            XCTAssertEqual(try MobileTextCodec.encode(
                content, encoding: encoding, lineEnding: .lf
            ), data, encoding.displayName)
        }
    }

    func testUTF16BEWithoutBOMIsDetectedAndMarkedUncertain() throws {
        let data = try MobileTextCodec.encode(
            "alpha\nbeta\n", encoding: .utf16beNoBom, lineEnding: .lf
        )
        let opened = try MobileTextCodec.decode(data)
        XCTAssertEqual(opened.content, "alpha\nbeta\n")
        XCTAssertEqual(opened.encoding, .utf16beNoBom)
        XCTAssertEqual(opened.encodingIssue, .uncertain)
    }

    func testBinaryAndMobileSizeLimitAreRejectedBeforeEditing() throws {
        let binary = try MobileTextCodec.decode(Data([0x61, 0, 0x62]))
        XCTAssertTrue(binary.isBinary)
        let large = try MobileTextCodec.decode(Data(repeating: 0x61, count: 9), maximumByteCount: 8)
        XCTAssertTrue(large.isTooLarge)
        XCTAssertEqual(large.content, "")
    }

    func testLegacyEncodingWillNotSilentlyLoseCharacters() throws {
        XCTAssertThrowsError(try MobileTextCodec.encode(
            "snowman ☃", encoding: .windows1252, lineEnding: .lf
        )) { error in
            XCTAssertEqual(error as? MobileTextCodecError, .cannotRepresent(.windows1252))
        }
    }

    func testForcedEncodingUsesStrictDecode() {
        XCTAssertThrowsError(try MobileTextCodec.decode(
            Data([0xff]), forcedEncoding: .utf8
        )) { error in
            XCTAssertEqual(error as? MobileTextCodecError, .invalidData(.utf8))
        }
    }

    func testInvalidDisplayDecodeRetainsOriginalBytesForEncodingRecovery() throws {
        let source = Data([0xff, 0x61])
        let opened = try MobileTextCodec.decode(source)
        XCTAssertEqual(opened.encodingIssue, .invalidBytes)
        XCTAssertEqual(opened.encodingRecoveryData, source)
    }

    private func fixture(for encoding: MobileTextEncoding) -> String {
        switch encoding {
        case .utf8, .utf8bom, .utf16le, .utf16be,
             .utf16leNoBom, .utf16beNoBom:
            "Unicode 中文 😀"
        case .gb18030, .gbk:
            "简体中文"
        case .big5:
            "繁體中文"
        case .shiftJIS:
            "日本語"
        case .windows1252:
            "café € —"
        case .isoLatin1:
            "café £"
        }
    }
}
