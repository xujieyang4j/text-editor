import Foundation
import XCTest
@testable import LumenEditorCore

final class UpdateServiceTests: XCTestCase {
    func testParsesLatestReleaseAndComparesNumericVersions() throws {
        let data = release("0.10.2", architecture: .arm64)
        let info = try UpdateService.parse(
            data, currentVersion: "0.9.12", architecture: .arm64
        )
        XCTAssertTrue(info.isAvailable)
        XCTAssertEqual(info.latestVersion, "0.10.2")
        XCTAssertEqual(info.releaseURL?.host, "github.com")
        XCTAssertEqual(UpdateService.compareVersions("1.0.0", "1"), .orderedSame)
        XCTAssertEqual(UpdateService.compareVersions("1.0.0", "1.0.0-beta"), .orderedDescending)
    }

    func testRejectsMalformedPayloadAndOversizedResponse() {
        XCTAssertThrowsError(try UpdateService.parse(Data(#"{"name":"missing tag"}"#.utf8), currentVersion: "1.0.0"))
        XCTAssertThrowsError(try UpdateService.parse(
            Data(repeating: 0x20, count: UpdateService.maximumResponseBytes + 1),
            currentVersion: "1.0.0"
        )) { error in
            XCTAssertEqual(
                error as? UpdateCheckError,
                .responseTooLarge(maximumBytes: UpdateService.maximumResponseBytes)
            )
        }
    }

    func testUnapprovedReleaseURLIsNotExposed() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": "2.0.0", "html_url": "https://evil.example/release",
            "assets": UpdateService.expectedAssetNames(
                version: "2.0.0", architecture: .x64
            ).map { ["name": $0] }
        ])
        let info = try UpdateService.parse(
            data, currentVersion: "1.0.0", architecture: .x64
        )
        XCTAssertTrue(info.isAvailable)
        XCTAssertNil(info.releaseURL)
        XCTAssertFalse(UpdateService.isApprovedReleaseURL(
            URL(string: "https://github.com.attacker.test/xujieyang4j/text-editor/releases")!
        ))
    }

    func testOlderOrEqualReleaseIsNotAvailable() throws {
        for version in ["0.1.0", "0.0.9"] {
            let data = release(version, architecture: .x64)
            XCTAssertFalse(try UpdateService.parse(
                data, currentVersion: "0.1.0", architecture: .x64
            ).isAvailable)
        }
    }

    func testElectronOnlyOrWrongArchitectureReleaseIsNotANativeUpdate() throws {
        let electronOnly = try JSONSerialization.data(withJSONObject: [
            "tag_name": "9.0.0",
            "html_url": "https://github.com/xujieyang4j/text-editor/releases/tag/v9.0.0",
            "assets": [["name": "text-editor-xujieyang-9.0.0-macos-arm64.zip"]]
        ])
        let info = try UpdateService.parse(
            electronOnly, currentVersion: "0.1.0", architecture: .arm64
        )
        XCTAssertFalse(info.isAvailable)
        XCTAssertNil(info.releaseURL)

        let armRelease = release("9.0.0", architecture: .arm64)
        XCTAssertFalse(try UpdateService.parse(
            armRelease, currentVersion: "0.1.0", architecture: .x64
        ).isAvailable)
    }

    private func release(
        _ version: String, architecture: NativeUpdateArchitecture
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": "v" + version,
            "html_url": "https://github.com/xujieyang4j/text-editor/releases/tag/v" + version,
            "assets": UpdateService.expectedAssetNames(
                version: version, architecture: architecture
            ).map { ["name": $0] }
        ])
    }
}
