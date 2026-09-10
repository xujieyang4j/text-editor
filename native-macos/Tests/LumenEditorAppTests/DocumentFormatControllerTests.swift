import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

@MainActor
final class DocumentFormatControllerTests: XCTestCase {
    func testSaveEncodingOrdersCurrentFirstAndAppliesCapturedDocument() async throws {
        let document = makeDocument(encoding: .gbk)
        var active: EditorDocument? = document
        var applied: [(String, TextEncoding)] = []
        let controller = makeController(
            active: { active },
            applyEncoding: { target, encoding in
                applied.append((target.sessionDocumentID, encoding))
                target.chooseEncodingForSave(encoding)
                return true
            }
        )

        XCTAssertTrue(controller.present(.selectSaveEncoding))
        XCTAssertEqual(controller.items.first?.choice, .encoding(.gbk))
        XCTAssertEqual(controller.items.first?.isCurrent, true)
        let utf16 = try XCTUnwrap(controller.items.firstIndex {
            $0.choice == .encoding(.utf16leNoBom)
        })
        controller.selectItem(at: utf16)
        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        XCTAssertEqual(applied.map(\.1), [.utf16leNoBom])
        XCTAssertEqual(document.encoding, .utf16leNoBom)
        XCTAssertFalse(controller.isPresented)

        XCTAssertTrue(controller.present(.selectSaveEncoding))
        active = makeDocument(encoding: .utf8)
        let acceptedStale = await controller.acceptSelection()
        XCTAssertFalse(acceptedStale)
        XCTAssertEqual(applied.count, 1)
    }

    func testLineEndingUsesEffectiveEditorConfigValueAndFilters() async throws {
        let document = makeDocument()
        document.setEditorConfig(ResolvedEditorConfig(
            properties: EditorConfigProperties(endOfLine: .crlf),
            sources: []
        ))
        var selected: LineEnding?
        let controller = makeController(
            active: { document },
            applyLineEnding: { _, value in selected = value; return true }
        )

        XCTAssertTrue(controller.present(.selectLineEnding))
        XCTAssertEqual(controller.items.first?.choice, .lineEnding(.crlf))
        XCTAssertEqual(controller.items.first?.isCurrent, true)
        controller.query = "LF"
        XCTAssertEqual(controller.items.map(\.choice), [.lineEnding(.lf), .lineEnding(.crlf)])
        let lf = try XCTUnwrap(controller.items.firstIndex { $0.choice == .lineEnding(.lf) })
        controller.selectItem(at: lf)
        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        XCTAssertEqual(selected, .lf)
    }

    func testReopenOffersAutoDetectAndRejectsUntitledOrStaleDocument() async {
        let document = makeDocument()
        var active: EditorDocument? = document
        var requested: TextEncoding??
        let controller = makeController(
            active: { active },
            requestReopen: { _, encoding in requested = encoding; return true }
        )

        XCTAssertTrue(controller.present(.reopenUsingEncoding))
        XCTAssertEqual(controller.items.first?.choice, .automaticEncoding)
        XCTAssertEqual(controller.items.first?.isCurrent, true)
        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        XCTAssertNotNil(requested)
        XCTAssertNil(requested!)

        active = EditorDocument(
            fileURL: nil, displayName: "Untitled-1", text: "", savedText: ""
        )
        XCTAssertFalse(controller.present(.reopenUsingEncoding))
    }

    func testOpenUsingEncodingDoesNotRequireDocument() async throws {
        var opened: TextEncoding?
        let controller = makeController(
            active: { nil },
            open: { opened = $0 }
        )
        let router = CommandRouter()
        let tokens = try controller.registerCommands(on: router)
        XCTAssertEqual(Set(tokens.map(\.commandID)), Set(DocumentFormatController.commandIDs))
        let context = CommandRoutingContext()
        XCTAssertEqual(router.status(for: "open-file-with-encoding", context: context), .enabled)
        let routed = await router.execute(
            "open-file-with-encoding", context: context
        )
        XCTAssertTrue(routed.didExecuteSuccessfully)
        XCTAssertTrue(controller.isPresented)
        let shiftJIS = try XCTUnwrap(controller.items.firstIndex {
            $0.choice == .encoding(.shiftJIS)
        })
        controller.selectItem(at: shiftJIS)
        let accepted = await controller.acceptSelection()
        XCTAssertTrue(accepted)
        XCTAssertEqual(opened, .shiftJIS)
    }

    func testRegistrationRollsBackOnConflict() throws {
        let controller = makeController(active: { nil })
        let router = CommandRouter()
        _ = try router.register("select-encoding") { _ in }
        XCTAssertThrowsError(try controller.registerCommands(on: router))
        XCTAssertEqual(
            router.status(for: "open-file-with-encoding", context: .init()),
            .unsupported
        )
    }

    func testQueryIsBoundedByUTF16CodeUnitsAndAccessibilityIDsAreStable() {
        let controller = makeController(active: { nil })
        XCTAssertTrue(controller.present(.openUsingEncoding))
        controller.query = String(repeating: "😀", count: 100)
        XCTAssertLessThanOrEqual(controller.query.utf16.count, 128)
        XCTAssertEqual(
            DocumentFormatPaletteView.Accessibility.paletteID,
            "panel.documentFormat"
        )
        XCTAssertEqual(
            DocumentFormatPaletteView.Accessibility.queryID,
            "panel.documentFormat.query"
        )
    }

    private func makeDocument(encoding: TextEncoding = .utf8) -> EditorDocument {
        EditorDocument(
            fileURL: URL(fileURLWithPath: "/tmp/example.txt"),
            displayName: "example.txt", text: "text", savedText: "text",
            encoding: encoding, savedEncoding: encoding
        )
    }

    private func makeController(
        active: @escaping @MainActor () -> EditorDocument?,
        open: @escaping @MainActor (TextEncoding) async -> Void = { _ in },
        applyEncoding: @escaping @MainActor (EditorDocument, TextEncoding) -> Bool
            = { _, _ in true },
        applyLineEnding: @escaping @MainActor (EditorDocument, LineEnding) -> Bool
            = { _, _ in true },
        requestReopen: @escaping @MainActor (EditorDocument, TextEncoding?) -> Bool
            = { _, _ in true }
    ) -> DocumentFormatController {
        DocumentFormatController(
            activeDocument: active, openUsingEncoding: open,
            applySaveEncoding: applyEncoding, applyLineEnding: applyLineEnding,
            requestReopen: requestReopen
        )
    }
}
