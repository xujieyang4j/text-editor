import Foundation
import LumenEditorCore
import XCTest
@testable import LumenEditorApp

final class PreviewControllerTests: XCTestCase {
    @MainActor
    func testFormatJSONSubmitsOneRevisionPinnedWholeDocumentEdit() throws {
        let source = #"{"emoji":"🙂","id":7651669476812652838}"#
        var submitted: [TextTransaction] = []
        let controller = PreviewController(applyTransaction: { transaction in
            submitted.append(transaction)
            return true
        })

        XCTAssertTrue(controller.formatJSON(source: source, expectedRevision: 41))
        let transaction = try XCTUnwrap(submitted.first)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(transaction.expectedRevision, 41)
        XCTAssertNil(transaction.selection)
        XCTAssertEqual(transaction.edits.count, 1)
        XCTAssertEqual(transaction.edits[0].from, 0)
        XCTAssertEqual(transaction.edits[0].to, source.utf16.count)
        XCTAssertEqual(
            transaction.edits[0].insert,
            """
            {
              "emoji": "🙂",
              "id": 7651669476812652838
            }

            """
        )
        XCTAssertEqual(try transaction.applying(to: source), transaction.edits[0].insert)
        XCTAssertNil(controller.issue)
    }

    @MainActor
    func testCompactJSONPreservesNumberLexemesAndHasNoFinalNewline() throws {
        let source = """
        {
          "large": 999999999999999999999999,
          "decimal": -1.2300e+10
        }
        """
        var submitted: TextTransaction?
        let controller = PreviewController(applyTransaction: { transaction in
            submitted = transaction
            return true
        })

        XCTAssertTrue(controller.compactJSON(source: source, expectedRevision: 7))

        let transaction = try XCTUnwrap(submitted)
        XCTAssertEqual(transaction.edits.count, 1)
        XCTAssertEqual(
            transaction.edits[0].insert,
            #"{"large":999999999999999999999999,"decimal":-1.2300e+10}"#
        )
        XCTAssertFalse(transaction.edits[0].insert.hasSuffix("\n"))
        XCTAssertEqual(transaction.expectedRevision, 7)
    }

    @MainActor
    func testInvalidJSONAndRejectedApplyNeverReportSuccess() {
        var applicationCount = 0
        let controller = PreviewController(applyTransaction: { _ in
            applicationCount += 1
            return false
        })

        XCTAssertFalse(controller.formatJSON(source: #"{"bad":}"#, expectedRevision: 1))
        XCTAssertEqual(applicationCount, 0)
        XCTAssertEqual(controller.issue?.kind, .invalidJSON)

        XCTAssertFalse(controller.compactJSON(source: #"{"valid":true}"#, expectedRevision: 1))
        XCTAssertEqual(applicationCount, 1)
        XCTAssertEqual(controller.issue?.kind, .transactionRejected)
    }

    @MainActor
    func testJSONPreviewStoresTypedCopyThatRerendersAfterLocaleSwitch() throws {
        let controller = PreviewController(applyTransaction: { _ in true })

        XCTAssertTrue(controller.toggleJSONView(source: #"{"bad":}"#))
        let issue = try XCTUnwrap(controller.issue)
        guard case .app = issue.content else {
            return XCTFail("Expected application-owned JSON parser copy")
        }
        XCTAssertEqual(
            EditorLocale.enUS.localizedPresentation(issue.content),
            issue.message
        )
        XCTAssertNotEqual(
            EditorLocale.zhCN.localizedPresentation(issue.content),
            issue.message
        )
        XCTAssertTrue(
            EditorLocale.zhCN.localizedPresentation(issue.content).contains("JSON 值")
        )
    }

    @MainActor
    func testJSONEditingFixedFailureRetainsTypedCopy() throws {
        let source = #"{"value":1}"#
        let controller = PreviewController(
            applyTransaction: { _ in true },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: "document-a", source: source, revision: 0
                )
            }
        )
        XCTAssertTrue(controller.toggleJSONView(source: source))

        XCTAssertFalse(controller.replaceJSONValue(
            at: [.key("value")], with: "not-json",
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        let issue = try XCTUnwrap(controller.jsonEditingIssue)
        guard case .app = issue.content else {
            return XCTFail("Expected application-owned JSON edit copy")
        }
        XCTAssertNotEqual(
            EditorLocale.enUS.localizedPresentation(issue.content),
            EditorLocale.zhCN.localizedPresentation(issue.content)
        )
    }

    @MainActor
    func testJSONInputAndPrettyOutputRespectUTF16ResourceLimit() {
        let limits = LosslessJSONLimits(
            maximumDepth: 8,
            maximumNodes: 20,
            maximumBytes: 8,
            maximumIndent: 2
        )
        var applicationCount = 0
        let controller = PreviewController(jsonLimits: limits, applyTransaction: { _ in
            applicationCount += 1
            return true
        })

        XCTAssertFalse(controller.compactJSON(source: #""🙂🙂🙂🙂""#, expectedRevision: 1))
        XCTAssertEqual(controller.issue?.kind, .resourceLimit)
        XCTAssertEqual(applicationCount, 0)

        // Compact input fits exactly, but pretty output plus its required final
        // newline crosses the same output budget.
        XCTAssertFalse(controller.formatJSON(source: "12345678", expectedRevision: 1))
        XCTAssertEqual(controller.issue?.kind, .resourceLimit)
        XCTAssertEqual(applicationCount, 0)
    }

    @MainActor
    func testJSONPreviewClassifiesDepthAndNodeBudgetsAsResourceLimits() {
        let depthController = PreviewController(
            jsonLimits: LosslessJSONLimits(
                maximumDepth: 0,
                maximumNodes: 100,
                maximumBytes: 100,
                maximumIndent: 2
            ),
            applyTransaction: { _ in true }
        )
        XCTAssertTrue(depthController.toggleJSONView(source: "[0]"))
        XCTAssertEqual(depthController.issue?.kind, .resourceLimit)
        XCTAssertNil(depthController.jsonSnapshot)

        let nodeController = PreviewController(
            jsonLimits: LosslessJSONLimits(
                maximumDepth: 8,
                maximumNodes: 1,
                maximumBytes: 100,
                maximumIndent: 2
            ),
            applyTransaction: { _ in true }
        )
        XCTAssertTrue(nodeController.toggleJSONView(source: "[0]"))
        XCTAssertEqual(nodeController.issue?.kind, .resourceLimit)
        XCTAssertNil(nodeController.jsonSnapshot)
    }

    @MainActor
    func testPreviewModeToggleAndLiveUpdateContract() {
        let controller = PreviewController(applyTransaction: { _ in true })
        XCTAssertEqual(controller.mode, .hidden)
        XCTAssertFalse(controller.isVisible)

        XCTAssertTrue(controller.toggleMarkdownPreview(source: "# First"))
        XCTAssertEqual(controller.mode, .markdown)
        XCTAssertEqual(controller.markdownDocument.plainText, "First")
        let markdownRevision = controller.contentRevision

        controller.update(source: "# Second")
        XCTAssertEqual(controller.markdownDocument.plainText, "Second")
        XCTAssertGreaterThan(controller.contentRevision, markdownRevision)

        XCTAssertTrue(controller.toggleJSONView(source: #"{"value":1}"#))
        XCTAssertEqual(controller.mode, .json)
        XCTAssertNotNil(controller.jsonSnapshot)
        XCTAssertFalse(controller.toggleJSONView(source: "ignored while closing"))
        XCTAssertEqual(controller.mode, .hidden)
    }

    @MainActor
    func testJSONTreeValueEditUsesOneRevisionPinnedUTF16Transaction() throws {
        let source = #"{"emoji":"🙂","id":7651669476812652838}"#
        let buffer = DocumentBuffer(text: source)
        var submitted: [TextTransaction] = []
        let controller = PreviewController(
            applyTransaction: { transaction in
                submitted.append(transaction)
                do {
                    _ = try buffer.apply(transaction)
                    return true
                } catch {
                    return false
                }
            },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: "document-a",
                    source: buffer.text,
                    revision: buffer.revision
                )
            }
        )

        XCTAssertTrue(controller.toggleJSONView(source: source))
        let renderedRevision = controller.jsonEditSessionGeneration
        XCTAssertEqual(
            controller.serializedJSONValue(
                at: [.key("id")], expectedSessionGeneration: renderedRevision
            ),
            "7651669476812652838"
        )

        XCTAssertTrue(controller.replaceJSONValue(
            at: [.key("id")],
            with: #"[true,"新"]"#,
            expectedSessionGeneration: renderedRevision
        ))

        let transaction = try XCTUnwrap(submitted.first)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(transaction.expectedRevision, 0)
        XCTAssertEqual(transaction.edits.count, 1)
        XCTAssertEqual(transaction.edits[0].from, 0)
        XCTAssertEqual(transaction.edits[0].to, source.utf16.count)
        XCTAssertEqual(
            buffer.text,
            """
            {
              "emoji": "🙂",
              "id": [
                true,
                "新"
              ]
            }

            """
        )
        XCTAssertEqual(buffer.revision, 1)
        XCTAssertEqual(buffer.undoDepth, 1)
        XCTAssertNil(controller.jsonEditingIssue)
        XCTAssertEqual(
            controller.serializedJSONValue(
                at: [.key("id")],
                expectedSessionGeneration: controller.jsonEditSessionGeneration
            ),
            #"[true,"新"]"#
        )
    }

    @MainActor
    func testJSONTreeUsesInstalledProductionTransactionAdapterOnlyForMutation() {
        let buffer = DocumentBuffer(text: #"{"value":1}"#)
        var fallbackCount = 0
        var installedCount = 0
        var reject = true
        let controller = PreviewController(
            applyTransaction: { transaction in
                fallbackCount += 1
                return false
            },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: "document-a", source: buffer.text, revision: buffer.revision
                )
            }
        )
        controller.setJSONTransactionApplier { transaction in
            installedCount += 1
            guard !reject else { return false }
            return (try? buffer.apply(transaction)) != nil
        }
        XCTAssertTrue(controller.toggleJSONView(source: buffer.text))

        XCTAssertFalse(controller.replaceJSONValue(
            at: [.key("value")], with: "2",
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertEqual(installedCount, 1)
        XCTAssertEqual(fallbackCount, 0)

        reject = false
        XCTAssertTrue(controller.replaceJSONValue(
            at: [.key("value")], with: "2",
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertEqual(installedCount, 2)
        XCTAssertEqual(fallbackCount, 0)
        XCTAssertEqual(buffer.revision, 1)
    }

    @MainActor
    func testJSONTreeCanAddObjectMemberAppendArrayItemAndDeleteNode() throws {
        let buffer = DocumentBuffer(text: #"{"object":{},"items":[1]}"#)
        var transactionCount = 0
        let controller = PreviewController(
            applyTransaction: { transaction in
                do {
                    _ = try buffer.apply(transaction)
                    transactionCount += 1
                    return true
                } catch {
                    return false
                }
            },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: "document-a", source: buffer.text, revision: buffer.revision
                )
            }
        )
        XCTAssertTrue(controller.toggleJSONView(source: buffer.text))

        XCTAssertTrue(controller.addJSONObjectMember(
            at: [.key("object")], key: "large",
            valueSource: "999999999999999999999999",
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertTrue(controller.appendJSONArrayItem(
            at: [.key("items")], valueSource: #"{"ok":true}"#,
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertTrue(controller.removeJSONValue(
            at: [.key("items"), .index(0)],
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))

        XCTAssertEqual(transactionCount, 3)
        XCTAssertEqual(buffer.revision, 3)
        XCTAssertEqual(buffer.undoDepth, 3)
        XCTAssertEqual(
            buffer.text,
            """
            {
              "object": {
                "large": 999999999999999999999999
              },
              "items": [
                {
                  "ok": true
                }
              ]
            }

            """
        )
    }

    @MainActor
    func testJSONTreeEditRejectsInvalidValuesAndObjectKeysWithoutMutation() {
        let source = #"{"object":{"present":1}}"#
        let buffer = DocumentBuffer(text: source)
        let controller = PreviewController(
            applyTransaction: { transaction in
                (try? buffer.apply(transaction)) != nil
            },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: "document-a", source: buffer.text, revision: buffer.revision
                )
            }
        )
        XCTAssertTrue(controller.toggleJSONView(source: source))

        XCTAssertFalse(controller.replaceJSONValue(
            at: [.key("object"), .key("present")], with: "not-json",
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .invalidValue)

        XCTAssertFalse(controller.addJSONObjectMember(
            at: [.key("object")], key: "__proto__", valueSource: "null",
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .invalidObjectKey)

        XCTAssertFalse(controller.addJSONObjectMember(
            at: [.key("object")], key: "present", valueSource: "null",
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .duplicateObjectKey)
        XCTAssertEqual(buffer.text, source)
        XCTAssertEqual(buffer.revision, 0)
        XCTAssertEqual(buffer.undoDepth, 0)
    }

    @MainActor
    func testJSONTreeEditsRootPrimitiveAndRejectsRootRemoval() {
        let buffer = DocumentBuffer(text: "true")
        let controller = PreviewController(
            applyTransaction: { transaction in
                (try? buffer.apply(transaction)) != nil
            },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: "document-a", source: buffer.text, revision: buffer.revision
                )
            }
        )
        XCTAssertTrue(controller.toggleJSONView(source: buffer.text))
        XCTAssertTrue(controller.replaceJSONValue(
            at: [], with: #"{"root":null}"#,
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertEqual(buffer.text, "{\n  \"root\": null\n}\n")

        XCTAssertFalse(controller.removeJSONValue(
            at: [], expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .pathUnavailable)
    }

    @MainActor
    func testJSONTreeEditRejectsStaleTreeAndSwitchedDocumentIdentity() throws {
        let source = #"{"value":1}"#
        let buffer = DocumentBuffer(text: source)
        var documentID = "document-a"
        var applicationCount = 0
        let controller = PreviewController(
            applyTransaction: { transaction in
                applicationCount += 1
                return (try? buffer.apply(transaction)) != nil
            },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: documentID, source: buffer.text, revision: buffer.revision
                )
            }
        )
        XCTAssertTrue(controller.toggleJSONView(source: source))
        let renderedRevision = controller.jsonEditSessionGeneration

        documentID = "document-b"
        XCTAssertNil(controller.serializedJSONValue(
            at: [.key("value")], expectedSessionGeneration: renderedRevision
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .documentChanged)
        XCTAssertFalse(controller.replaceJSONValue(
            at: [.key("value")], with: "2",
            expectedSessionGeneration: renderedRevision
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .documentChanged)
        XCTAssertEqual(applicationCount, 0)
        XCTAssertEqual(buffer.text, source)

        documentID = "document-a"
        _ = try buffer.apply(TextTransaction(
            edits: [TextEdit(from: source.utf16.count, to: source.utf16.count, insert: " ")]
        ))
        XCTAssertFalse(controller.replaceJSONValue(
            at: [.key("value")], with: "3",
            expectedSessionGeneration: renderedRevision
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .documentChanged)
        XCTAssertEqual(applicationCount, 0)
    }

    @MainActor
    func testJSONTreeEditRejectsStaleRenderedViewToken() {
        let source = #"{"value":1}"#
        let buffer = DocumentBuffer(text: source)
        let controller = PreviewController(
            applyTransaction: { transaction in
                (try? buffer.apply(transaction)) != nil
            },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: "document-a", source: buffer.text, revision: buffer.revision
                )
            }
        )
        XCTAssertTrue(controller.toggleJSONView(source: source))
        let staleSessionGeneration = controller.jsonEditSessionGeneration
        controller.update(source: source)

        XCTAssertFalse(controller.replaceJSONValue(
            at: [.key("value")], with: "2",
            expectedSessionGeneration: staleSessionGeneration
        ))
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .documentChanged)
        XCTAssertEqual(buffer.text, source)
    }

    @MainActor
    func testCurrentDocumentRefreshIgnoresSelectionOnlyChangesAndRetargetsIdenticalTabs() {
        let source = #"{"value":1}"#
        let buffer = DocumentBuffer(text: source)
        var documentID = "document-a"
        let controller = PreviewController(
            applyTransaction: { _ in true },
            currentDocumentSnapshot: {
                JSONEditorDocumentSnapshot(
                    documentID: documentID, source: buffer.text, revision: buffer.revision
                )
            }
        )
        XCTAssertTrue(controller.toggleJSONView(source: source))
        let initialRender = controller.contentRevision

        controller.updateForCurrentDocument()
        XCTAssertEqual(controller.contentRevision, initialRender)

        documentID = "document-b"
        controller.updateForCurrentDocument()
        XCTAssertGreaterThan(controller.contentRevision, initialRender)
        XCTAssertEqual(
            controller.serializedJSONValue(
                at: [.key("value")],
                expectedSessionGeneration: controller.jsonEditSessionGeneration
            ),
            "1"
        )
    }

    @MainActor
    func testProductionPreviewAdapterMutatesSelectedDocumentAndCreatesOneUndoEntry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONPreviewAdapterTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: directory.appendingPathComponent("session.json")
            )
        )
        let document = try XCTUnwrap(model.selectedDocument)
        let source = #"{"emoji":"🙂","value":1}"#
        document.text = source
        let revisionBeforeEdit = document.buffer.revision
        let undoDepthBeforeEdit = document.buffer.undoDepth
        let controller = NativeFeatureCoordinator.makePreviewController(model: model)

        XCTAssertTrue(controller.toggleJSONView(source: source))
        XCTAssertTrue(controller.replaceJSONValue(
            at: [.key("value")], with: #"{"nested":true}"#,
            expectedSessionGeneration: controller.jsonEditSessionGeneration
        ))

        XCTAssertEqual(document.buffer.revision, revisionBeforeEdit + 1)
        XCTAssertEqual(document.buffer.undoDepth, undoDepthBeforeEdit + 1)
        XCTAssertEqual(
            document.text,
            """
            {
              "emoji": "🙂",
              "value": {
                "nested": true
              }
            }

            """
        )
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.text, source)
    }

    @MainActor
    func testProductionPreviewAdapterRejectsEditAfterSelectedTabChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONPreviewRetargetTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            sessionStore: SessionStore(
                sessionURL: directory.appendingPathComponent("session.json")
            )
        )
        let first = try XCTUnwrap(model.selectedDocument)
        first.text = #"{"value":1}"#
        let controller = NativeFeatureCoordinator.makePreviewController(model: model)
        XCTAssertTrue(controller.toggleJSONView(source: first.text))
        let renderedGeneration = controller.jsonEditSessionGeneration

        let second = model.newDocument()
        second.text = #"{"value":1}"#
        XCTAssertFalse(controller.replaceJSONValue(
            at: [.key("value")], with: "2",
            expectedSessionGeneration: renderedGeneration
        ))

        XCTAssertEqual(first.text, #"{"value":1}"#)
        XCTAssertEqual(second.text, #"{"value":1}"#)
        XCTAssertEqual(controller.jsonEditingIssue?.kind, .documentChanged)
    }

    @MainActor
    func testMarkdownTreatsRawHTMLImagesAndCodeAsTextAndAttributesOnlyAllowedLinks() throws {
        let source = """
        # Safe preview
        <script>[injected](https://evil.example)</script>
        [website](HTTPS://example.com/path)
        [script](javascript:alert(1))
        [local](file:///etc/passwd)
        ![remote image](https://image.example/pixel.png)
        <mailto:test@example.com>
        <div data-value="[fake](https://fake.example)">literal HTML</div>
        ```html
        [code link](https://code.example)
        <img src="https://asset.example/pixel.png">
        ```
        """

        let document = try SafeMarkdownRenderer.render(source)

        XCTAssertTrue(document.plainText.contains("<script>"))
        XCTAssertTrue(document.plainText.contains("<div data-value="))
        XCTAssertTrue(document.plainText.contains("<img src="))
        XCTAssertEqual(
            document.links.map(\.absoluteString),
            ["HTTPS://example.com/path", "mailto:test@example.com"]
        )

        let website = try XCTUnwrap(document.blocks.first {
            $0.plainText.contains("[website]")
        })
        XCTAssertEqual(
            attributedLinks(in: website.content).map(\.absoluteString),
            ["HTTPS://example.com/path"]
        )

        let html = try XCTUnwrap(document.blocks.first {
            $0.plainText.hasPrefix("<script>")
        })
        XCTAssertTrue(attributedLinks(in: html.content).isEmpty)
        let code = try XCTUnwrap(document.blocks.first {
            if case .code = $0.kind { return true }
            return false
        })
        XCTAssertTrue(attributedLinks(in: code.content).isEmpty)
    }

    @MainActor
    func testLinkOpenerIsInjectedAndRechecksAllowlist() {
        var opened: [URL] = []
        let controller = PreviewController(
            applyTransaction: { _ in true },
            openURL: { url in
                opened.append(url)
                return true
            }
        )

        XCTAssertFalse(controller.openLink(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(controller.openLink(URL(fileURLWithPath: "/tmp/private")))
        XCTAssertFalse(controller.openLink(URL(string: "https:///missing-host")!))
        XCTAssertFalse(controller.openLink(URL(string: "https://example.com/%0Apath")!))
        XCTAssertNil(PreviewURLPolicy.urlIfAllowed("https://example.com/%ZZ"))
        XCTAssertFalse(controller.openLink(URL(string: "mailto:?subject=missing-recipient")!))
        XCTAssertFalse(controller.openLink(URL(
            string: "mailto:hello@example.com?subject=ok%0D%0ABcc:evil@example.com"
        )!))
        XCTAssertTrue(controller.openLink(URL(string: "https://example.com")!))
        XCTAssertTrue(controller.openLink(URL(string: "mailto:hello@example.com")!))
        XCTAssertEqual(
            opened.map(\.absoluteString),
            ["https://example.com", "mailto:hello@example.com"]
        )
    }

    @MainActor
    func testMarkdownSupportsEmphasisNestedListsTasksTablesRulesAndSafeImages() throws {
        let source = """
        Intro with *emphasis* and **strong**.

        1. Parent
          - Child
            - [x] Done
            - [ ] Todo

        ---

        | Name | Link |
        | --- | --- |
        | Alpha | [docs](https://example.com/docs) |

        ![remote image](https://image.example/pixel.png)
        ![local image](file:///tmp/private.png)
        """

        let document = try SafeMarkdownRenderer.render(source)

        XCTAssertEqual(document.blocks.count, 9)
        XCTAssertEqual(document.links.map(\.absoluteString), [
            "https://example.com/docs",
            "https://image.example/pixel.png"
        ])

        guard case .paragraph = document.blocks[0].kind else {
            return XCTFail("Expected paragraph block")
        }
        #if canImport(AppKit)
        let inlineIntentKinds = document.blocks[0].content.runs.compactMap {
            $0.inlinePresentationIntent
        }
        XCTAssertTrue(inlineIntentKinds.contains(.emphasized))
        XCTAssertTrue(inlineIntentKinds.contains(.stronglyEmphasized))
        #else
        XCTAssertEqual(document.blocks[0].plainText, "Intro with *emphasis* and **strong**.")
        #endif

        guard case let .orderedListItem(number, depth, task) = document.blocks[1].kind else {
            return XCTFail("Expected ordered list item")
        }
        XCTAssertEqual(number, 1)
        XCTAssertEqual(depth, 0)
        XCTAssertNil(task)

        guard case let .unorderedListItem(depth, task) = document.blocks[2].kind else {
            return XCTFail("Expected nested unordered list item")
        }
        XCTAssertEqual(depth, 1)
        XCTAssertNil(task)

        guard case let .unorderedListItem(doneDepth, doneTask) = document.blocks[3].kind else {
            return XCTFail("Expected checked task item")
        }
        XCTAssertEqual(doneDepth, 2)
        XCTAssertEqual(doneTask, .checked)
        XCTAssertEqual(document.blocks[3].plainText, "Done")

        guard case let .unorderedListItem(todoDepth, todoTask) = document.blocks[4].kind else {
            return XCTFail("Expected unchecked task item")
        }
        XCTAssertEqual(todoDepth, 2)
        XCTAssertEqual(todoTask, .unchecked)
        XCTAssertEqual(document.blocks[4].plainText, "Todo")

        guard case .thematicBreak = document.blocks[5].kind else {
            return XCTFail("Expected thematic break")
        }

        guard case .table = document.blocks[6].kind,
              let table = document.blocks[6].table else {
            return XCTFail("Expected table block")
        }
        XCTAssertEqual(table.header.cells.map(\.plainText), ["Name", "Link"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].cells.map(\.plainText), [
            "Alpha", "[docs](https://example.com/docs)"
        ])
        XCTAssertEqual(
            attributedLinks(in: table.rows[0].cells[1].content).map(\.absoluteString),
            ["https://example.com/docs"]
        )

        XCTAssertEqual(document.blocks[7].plainText, "Image: remote image")
        XCTAssertEqual(
            attributedLinks(in: document.blocks[7].content).map(\.absoluteString),
            ["https://image.example/pixel.png"]
        )
        XCTAssertEqual(document.blocks[8].plainText, "Image: local image")
        XCTAssertTrue(attributedLinks(in: document.blocks[8].content).isEmpty)
    }

    @MainActor
    func testMarkdownFencedCodeKeepsEveryLine() throws {
        let source = """
        ```swift
        first()
        second()
        third()
        ```
        """

        let document = try SafeMarkdownRenderer.render(source)

        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].plainText, "first()\nsecond()\nthird()")
        XCTAssertTrue(attributedLinks(in: document.blocks[0].content).isEmpty)
    }

    @MainActor
    func testMarkdownUTF16LimitStopsRendering() {
        let controller = PreviewController(
            maximumMarkdownUTF16Count: 4,
            applyTransaction: { _ in true }
        )

        XCTAssertTrue(controller.toggleMarkdownPreview(source: "🙂🙂a"))
        XCTAssertEqual(controller.issue?.kind, .resourceLimit)
        XCTAssertTrue(controller.markdownDocument.blocks.isEmpty)
    }

    @MainActor
    func testMarkdownBlockLimitStopsViewAmplification() {
        let controller = PreviewController(
            maximumMarkdownUTF16Count: 1_000,
            maximumMarkdownBlocks: 2,
            applyTransaction: { _ in true }
        )

        XCTAssertTrue(controller.toggleMarkdownPreview(source: "a\nb\nc"))
        XCTAssertEqual(controller.issue?.kind, .resourceLimit)
        XCTAssertTrue(controller.markdownDocument.blocks.isEmpty)
    }

    private func attributedLinks(in value: AttributedString) -> [URL] {
        value.runs.compactMap { $0.link }
    }
}
