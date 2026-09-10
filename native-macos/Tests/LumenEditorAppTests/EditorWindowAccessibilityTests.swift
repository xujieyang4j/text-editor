import XCTest
import Foundation
import LumenEditorCore
@testable import LumenEditorApp

final class EditorWindowAccessibilityTests: XCTestCase {
    func testDistractionFreeKeepsExplicitFindBarAndEscapeDismissesItFirst() {
        XCTAssertTrue(EditorWindowInteractionPlan.showsFindBar(
            isPresented: true, distractionFree: true
        ))
        XCTAssertFalse(EditorWindowInteractionPlan.showsFindBar(
            isPresented: false, distractionFree: true
        ))
        XCTAssertEqual(
            EditorWindowInteractionPlan.escapeAction(
                findIsPresented: true, distractionFree: true
            ),
            .dismissFind
        )
        XCTAssertEqual(
            EditorWindowInteractionPlan.escapeAction(
                findIsPresented: false, distractionFree: true
            ),
            .exitDistractionFree
        )
        XCTAssertEqual(
            EditorWindowInteractionPlan.escapeAction(
                findIsPresented: false, distractionFree: false
            ),
            .none
        )
        XCTAssertFalse(EditorWindowInteractionPlan.keyboardRoutingIsAvailable(
            hasTransientPanel: false, findIsPresented: true,
            navigationIsPresented: false
        ))
        XCTAssertTrue(EditorWindowInteractionPlan.keyboardRoutingIsAvailable(
            hasTransientPanel: false, findIsPresented: false,
            navigationIsPresented: false
        ))
    }

    func testWorkspaceTaskContinuationRequiresExactSnapshotAndLiveTask() {
        let root = WorkspaceRoot.ID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!)
        let workspaceRoot = WorkspaceRoot(
            id: root, url: URL(fileURLWithPath: "/tmp/root"),
            displayName: "root", isPrimary: true
        )
        let captured = WorkspaceContextSnapshot(
            primaryRoot: workspaceRoot,
            selectedFileURL: URL(fileURLWithPath: "/tmp/a.txt")
        )
        XCTAssertTrue(EditorWorkspaceTaskPlan.permitsContinuation(
            captured: captured, current: captured, isCancelled: false
        ))
        XCTAssertFalse(EditorWorkspaceTaskPlan.permitsContinuation(
            captured: captured, current: WorkspaceContextSnapshot(
                primaryRoot: workspaceRoot,
                selectedFileURL: URL(fileURLWithPath: "/tmp/b.txt")
            ), isCancelled: false
        ))
        XCTAssertFalse(EditorWorkspaceTaskPlan.permitsContinuation(
            captured: captured, current: captured, isCancelled: true
        ))
    }

    func testDialogActionIdentifiersAreStableAndUnique() {
        XCTAssertEqual(EditorWindowAccessibility.all, [
            "lumen.editor.language.tool.approval.approve",
            "lumen.editor.language.tool.approval.cancel",
            "lumen.editor.language.server.approval.approve",
            "lumen.editor.language.server.approval.cancel",
            "lumen.editor.plugin.worker.approval.approve",
            "lumen.editor.plugin.worker.approval.cancel",
            "lumen.editor.alert.ok",
            "lumen.editor.alert.cancel",
            "lumen.editor.alert.dont.save",
            "lumen.editor.alert.save",
            "lumen.editor.alert.reopen",
            "lumen.editor.alert.reload"
        ])
        XCTAssertEqual(
            Set(EditorWindowAccessibility.all).count,
            EditorWindowAccessibility.all.count
        )
    }
}
