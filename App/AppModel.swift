import SwiftUI
import EditorKit

/// App-wide state: the project library.
@Observable
final class AppModel {
    let store: ProjectStore
    var projects: [Project] = []
    var openProject: Project?

    init(store: ProjectStore = .defaultStore()) {
        self.store = store
        reload()
    }

    func reload() {
        projects = store.listProjects()
    }

    func createProject() throws -> Project {
        let count = projects.count + 1
        let project = try store.create(name: "Project \(count)")
        reload()
        return project
    }

    func delete(_ project: Project) {
        try? store.delete(project.id)
        reload()
    }

    func duplicate(_ project: Project) {
        _ = try? store.duplicate(project.id)
        reload()
    }

    func rename(_ project: Project, to name: String) {
        guard var p = try? store.load(project.id) else { return }
        p.name = name
        try? store.save(p)
        reload()
    }
}

/// UI-test / demo hooks driven by launch arguments.
enum LaunchOptions {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    /// Start from an empty library.
    static var resetLibrary: Bool { arguments.contains("-resetLibrary") }
    /// Import bundled sample clips without the photo picker (UI tests / demo).
    static var useSampleMedia: Bool { arguments.contains("-sampleMedia") }
    /// Folder with demo clips to import instead of generated samples.
    static var demoMediaFolder: URL? {
        guard let i = arguments.firstIndex(of: "-demoMedia"), i + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[i + 1])
    }
    static var disableAnimations: Bool { arguments.contains("-noAnimations") }
}
