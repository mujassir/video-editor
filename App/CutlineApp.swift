import SwiftUI
import EditorKit

@main
struct CutlineApp: App {
    init() {
        if LaunchOptions.resetLibrary {
            let root = ProjectStore.defaultStore().rootURL
            try? FileManager.default.removeItem(at: root)
        }
        if LaunchOptions.disableAnimations { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
