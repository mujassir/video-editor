import SwiftUI
import EditorKit

@main
struct CutlineApp: App {
    init() {
        if LaunchOptions.resetLibrary {
            let root = ProjectStore.defaultStore().rootURL
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: RecentAudioStore.defaultStore().rootURL)
        }
        if LaunchOptions.disableAnimations { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
