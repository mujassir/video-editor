import Foundation
import Observation

/// Owns the project being edited and its undo/redo history.
///
/// Projects are value types, so each history entry is a full snapshot. A
/// snapshot is small (clip metadata only – never media), which keeps undo
/// instant and makes it impossible for undo to drift out of sync with state.
@MainActor
@Observable
public final class EditSession {
    public private(set) var project: Project
    public private(set) var undoStack: [(label: String, project: Project)] = []
    public private(set) var redoStack: [(label: String, project: Project)] = []
    public var selection: Selection = .none
    /// Incremented on every change; renderers watch this to rebuild compositions.
    public private(set) var revision = 0

    public let historyLimit: Int
    private let onChange: (@MainActor (Project) -> Void)?

    public enum Selection: Hashable, Sendable {
        case none
        case clip(UUID)
        case text(UUID)
        case audio(UUID)
        case captions
    }

    public init(project: Project, historyLimit: Int = 200, onChange: (@MainActor (Project) -> Void)? = nil) {
        self.project = project
        self.historyLimit = historyLimit
        self.onChange = onChange
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    /// Applies an edit as one undoable step. Throwing edits leave the project untouched.
    @discardableResult
    public func apply<T>(_ label: String, _ edit: (inout Project) throws -> T) rethrows -> T {
        var next = project
        let result = try edit(&next)
        next.refitMusic()
        commit(label, next)
        return result
    }

    /// Applies a continuous change (slider drags) – consecutive changes with the
    /// same label and `coalescingKey` merge into one undo step.
    public func applyCoalescing(_ label: String, key: AnyHashable, _ edit: (inout Project) -> Void) {
        var next = project
        edit(&next)
        next.refitMusic()
        if lastCoalescingKey == key, !undoStack.isEmpty {
            redoStack.removeAll()
            setProject(next)
        } else {
            commit(label, next)
            lastCoalescingKey = key
        }
    }

    private var lastCoalescingKey: AnyHashable?

    private func commit(_ label: String, _ next: Project) {
        guard next != project else { return }
        undoStack.append((label, project))
        if undoStack.count > historyLimit { undoStack.removeFirst(undoStack.count - historyLimit) }
        redoStack.removeAll()
        lastCoalescingKey = nil
        setProject(next)
    }

    public func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append((entry.label, project))
        lastCoalescingKey = nil
        setProject(entry.project)
        validateSelection()
    }

    public func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append((entry.label, project))
        lastCoalescingKey = nil
        setProject(entry.project)
        validateSelection()
    }

    /// Replaces the project without recording history (e.g. after loading).
    public func replaceWithoutHistory(_ project: Project) {
        setProject(project)
    }

    private func setProject(_ next: Project) {
        var next = next
        next.modifiedAt = Date()
        project = next
        revision &+= 1
        validateSelection()
        onChange?(next)
    }

    private func validateSelection() {
        switch selection {
        case .clip(let id) where project.clipIndex(id) == nil: selection = .none
        case .text(let id) where !project.textOverlays.contains(where: { $0.id == id }): selection = .none
        case .audio(let id) where !project.audioClips.contains(where: { $0.id == id }): selection = .none
        default: break
        }
    }

    public var selectedClip: VideoClip? {
        if case .clip(let id) = selection, let i = project.clipIndex(id) { return project.clips[i] }
        return nil
    }
}
