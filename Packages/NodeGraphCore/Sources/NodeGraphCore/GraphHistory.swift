/// One undoable step.
public struct HistoryEntry: Hashable, Sendable, Codable {
    /// Shown in menus, for example "Move Nodes". Nil when the caller gave no name.
    public var name: String?
    public var command: GraphCommand
    /// Applying this undoes `command`.
    public var inverse: GraphCommand

    public init(name: String? = nil, command: GraphCommand, inverse: GraphCommand) {
        self.name = name
        self.command = command
        self.inverse = inverse
    }
}

/// Undo and redo for a ``GraphEditor``, built on command inverses rather than snapshots.
///
/// Make edits through ``perform(_:name:coalescing:)`` or ``group(name:_:)`` so they are recorded.
/// Edits applied straight to the editor (for example from a server) are not recorded; if they
/// make a recorded step inapplicable, undo or redo throws and the history is cleared.
///
/// Like the editor it wraps, it is not `Sendable`; keep both on one actor. Core stays free of
/// UI, so a UI layer bridges ``undo()`` and ``redo()`` to the platform `UndoManager`.
public final class GraphHistory {
    public let editor: GraphEditor
    /// Most undo steps kept. The oldest are dropped first.
    public var limit: Int {
        didSet { trim() }
    }

    public private(set) var undoStack: [HistoryEntry] = []
    public private(set) var redoStack: [HistoryEntry] = []

    /// Counts undo steps ever recorded. Increases when an edit starts a new step and stays put when
    /// it merges into the previous one, so a bridge to a platform undo manager can tell the two apart
    /// (the stack size cannot, once the limit trims it).
    public private(set) var recordedStepCount = 0

    /// Whether the newest undo entry may still absorb a coalescing edit.
    private var canMerge = false
    /// Changes collected by an open ``group(name:_:)``, or nil when no group is open.
    private var openGroup: [GraphChange]?

    public init(editor: GraphEditor, limit: Int = 100) {
        self.editor = editor
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Applies a command and records it.
    ///
    /// With `coalescing` true, the edit merges into the previous step when both edit the same
    /// target and no ``endCoalescing()`` happened in between. Use it for every event of a drag
    /// or slider sweep, then call ``endCoalescing()`` when the gesture ends. A new edit clears
    /// the redo stack.
    @discardableResult
    public func perform(
        _ command: GraphCommand, name: String? = nil, coalescing: Bool = false
    ) throws -> GraphChange {
        let change = try editor.apply(command)
        if openGroup != nil {
            openGroup?.append(change)
            return change
        }
        record(change, name: name, coalescing: coalescing)
        return change
    }

    /// Connects two ports and records it. See ``GraphEditor/connect(_:)``.
    @discardableResult
    public func connect(_ proposal: ConnectionProposal, name: String? = nil) throws -> GraphChange {
        try perform(editor.connectCommand(for: proposal), name: name)
    }

    /// Runs `body` and records everything it performs as one undo step.
    ///
    /// If `body` throws, edits already made are rolled back and the error is rethrown.
    /// Nested groups join the outermost one.
    public func group(name: String? = nil, _ body: () throws -> Void) throws {
        guard openGroup == nil else {
            try body()
            return
        }
        openGroup = []
        do {
            try body()
        } catch {
            let applied = openGroup ?? []
            openGroup = nil
            for change in applied.reversed() { _ = try? editor.revert(change) }
            throw error
        }
        let changes = openGroup ?? []
        openGroup = nil
        guard !changes.isEmpty else { return }
        record(
            GraphChange(
                revision: editor.revision,
                command: .batch(commands: changes.map(\.command)),
                inverse: .batch(commands: changes.reversed().map(\.inverse))),
            name: name, coalescing: false)
    }

    /// Stops the next coalescing edit from merging into the previous step.
    public func endCoalescing() {
        canMerge = false
    }

    /// Undoes the newest step. Does nothing when there is none.
    public func undo() throws {
        guard let entry = undoStack.last else { return }
        do {
            try editor.apply(entry.inverse, validation: .structural, adjustsPorts: false)
        } catch {
            clear()
            throw error
        }
        undoStack.removeLast()
        redoStack.append(entry)
        canMerge = false
    }

    /// Reapplies the most recently undone step. Does nothing when there is none.
    public func redo() throws {
        guard let entry = redoStack.last else { return }
        do {
            try editor.apply(entry.command, validation: .structural)
        } catch {
            clear()
            throw error
        }
        redoStack.removeLast()
        undoStack.append(entry)
        canMerge = false
    }

    /// Forgets all history.
    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        canMerge = false
    }

    private func record(_ change: GraphChange, name: String?, coalescing: Bool) {
        redoStack.removeAll()
        if coalescing, canMerge, let last = undoStack.last,
           let merged = GraphChange(revision: 0, command: last.command, inverse: last.inverse)
               .coalesced(with: change) {
            undoStack[undoStack.count - 1] = HistoryEntry(
                name: last.name ?? name, command: merged.command, inverse: merged.inverse)
        } else {
            undoStack.append(HistoryEntry(name: name, command: change.command, inverse: change.inverse))
            recordedStepCount += 1
            trim()
        }
        canMerge = coalescing
    }

    private func trim() {
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - max(limit, 0)) }
    }
}
