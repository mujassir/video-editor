import Foundation

/// Stores projects on disk:
///
///     Documents/Projects/<id>/project.json
///     Documents/Projects/<id>/Media/<files>
///     Documents/Projects/<id>/thumbnail.jpg
///
/// Writes are atomic so a crash mid-save can never corrupt a project.
public final class ProjectStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public static func defaultStore() -> ProjectStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ProjectStore(rootURL: docs.appendingPathComponent("Projects", isDirectory: true))
    }

    public func directory(for projectID: UUID) -> URL {
        rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    public func mediaDirectory(for projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("Media", isDirectory: true)
    }

    public func cacheDirectory(for projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("Cache", isDirectory: true)
    }

    public func thumbnailURL(for projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("thumbnail.jpg")
    }

    public func mediaURL(_ item: MediaItem, projectID: UUID) -> URL {
        mediaDirectory(for: projectID).appendingPathComponent(item.fileName)
    }

    private func projectFile(_ id: UUID) -> URL {
        directory(for: id).appendingPathComponent("project.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }()

    public func create(name: String) throws -> Project {
        let project = Project(name: name)
        try FileManager.default.createDirectory(at: mediaDirectory(for: project.id), withIntermediateDirectories: true)
        try save(project)
        return project
    }

    public func save(_ project: Project) throws {
        let dir = directory(for: project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(project)
        try data.write(to: projectFile(project.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> Project {
        let data = try Data(contentsOf: projectFile(id))
        return try Self.decoder.decode(Project.self, from: data)
    }

    /// All projects, most recently modified first. Unreadable projects are skipped.
    public func listProjects() -> [Project] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
            return try? load(id)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }

    public func duplicate(_ id: UUID) throws -> Project {
        var copy = try load(id)
        let newID = UUID()
        try FileManager.default.copyItem(at: directory(for: id), to: directory(for: newID))
        copy.id = newID
        copy.name += " Copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        try save(copy)
        return copy
    }

    /// Copies a file into the project's media folder and returns the stored file name.
    public func importFile(at url: URL, projectID: UUID) throws -> String {
        let dir = mediaDirectory(for: projectID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        let destination = dir.appendingPathComponent(name)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: destination)
        return name
    }
}

/// Debounced autosave: coalesces rapid edits into one write off the main thread.
public actor Autosaver {
    private let store: ProjectStore
    private var pending: Project?
    private var task: Task<Void, Never>?
    private let delay: Duration

    public init(store: ProjectStore, delay: Duration = .milliseconds(400)) {
        self.store = store
        self.delay = delay
    }

    public func schedule(_ project: Project) {
        pending = project
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    public func flush() {
        guard let project = pending else { return }
        pending = nil
        try? store.save(project)
    }
}
