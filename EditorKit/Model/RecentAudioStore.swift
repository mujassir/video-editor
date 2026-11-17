import Foundation

/// The user's 5 most recently used audio tracks (MUS-10), shared by every project.
///
///     Documents/RecentAudio/recent.json      [RecentAudioStore.Entry], newest first
///     Documents/RecentAudio/<UUID>.<ext>     a private copy of each track
///
/// The store keeps its own copy of each file, so a recent track still works after the
/// project it was first used in is deleted. Adding a track that is already in the list
/// (same name and length) moves it to the top instead of adding it twice.
public final class RecentAudioStore: @unchecked Sendable {
    public struct Entry: Codable, Hashable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var fileName: String
        public var duration: MediaTime
        public var usedAt: Date

        public init(id: UUID = UUID(), name: String, fileName: String, duration: MediaTime, usedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.fileName = fileName
            self.duration = duration
            self.usedAt = usedAt
        }

        /// Two entries are the same track when the name and length (to 0.1 s) match.
        var key: String { "\(name.lowercased())|\(Int((duration.seconds * 10).rounded()))" }
    }

    public static let limit = 5

    public let rootURL: URL
    private var indexURL: URL { rootURL.appendingPathComponent("recent.json") }
    private let lock = NSLock()

    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public static func defaultStore() -> RecentAudioStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return RecentAudioStore(rootURL: docs.appendingPathComponent("RecentAudio", isDirectory: true))
    }

    public func url(for entry: Entry) -> URL { rootURL.appendingPathComponent(entry.fileName) }

    /// Newest first; entries whose file is missing are dropped.
    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// Records a track as just used. `fileURL` is copied unless it's already this store's copy.
    @discardableResult
    public func add(fileAt fileURL: URL, name: String, duration: MediaTime) throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        var entry = Entry(name: name, fileName: "", duration: duration)
        if let i = list.firstIndex(where: { $0.key == entry.key }) {
            entry = list.remove(at: i)
            entry.usedAt = Date()
        } else {
            let ext = fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension
            entry.fileName = "\(entry.id.uuidString).\(ext)"
            try FileManager.default.copyItem(at: fileURL, to: url(for: entry))
        }
        list.insert(entry, at: 0)
        for old in list.dropFirst(Self.limit) { try? FileManager.default.removeItem(at: url(for: old)) }
        list = Array(list.prefix(Self.limit))
        try save(list)
        return list
    }

    public func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(for: list[i]))
        list.remove(at: i)
        try? save(list)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? Self.decoder.decode([Entry].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save(_ list: [Entry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(list).write(to: indexURL, options: .atomic)
    }
}
