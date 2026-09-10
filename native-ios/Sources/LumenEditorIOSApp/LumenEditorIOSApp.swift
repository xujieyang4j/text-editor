import Foundation
import SwiftUI

@main
struct LumenEditorIOSApp: App {
    private let uiTestSessionID: UUID? = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LUMEN_UI_TEST_SESSION"]
            .flatMap(UUID.init(uuidString:))
        #else
        return nil
        #endif
    }()

    var body: some Scene {
        WindowGroup { RootView(uiTestSessionID: uiTestSessionID) }
    }
}
