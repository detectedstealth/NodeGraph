import CoreGraphics
import Foundation
import NodeGraphCore
import Observation

/// What is selected on the canvas.
public struct GraphSelection: Hashable, Sendable {
    public var nodes: Set<NodeID> = []
    public var links: Set<LinkID> = []
    public var groups: Set<GroupID> = []

    public init(nodes: Set<NodeID> = [], links: Set<LinkID> = [], groups: Set<GroupID> = []) {
        self.nodes = nodes
        self.links = links
        self.groups = groups
    }

    public var isEmpty: Bool { nodes.isEmpty && links.isEmpty && groups.isEmpty }
}

/// The state the editor views read and the one place they send edits.
///
/// Wraps a ``GraphEditor`` and its ``GraphHistory`` and publishes the graph through Observation.
/// Views never touch the `Graph` or the editor directly: edits go through ``perform(_:name:coalescing:)``,
/// ``connect(_:name:)``, ``undo()`` and ``redo()``, which keep ``graph``, the selection and the
/// layout cache in step.
///
/// If something else edits ``editor`` (a server change, say), call ``refresh()`` afterwards.
@MainActor
@Observable
public final class GraphEditorModel {
    /// The editor this model drives. Read-only for views; apply edits through the model.
    @ObservationIgnored public let editor: GraphEditor
    @ObservationIgnored public let history: GraphHistory

    /// A copy of the editor's graph, replaced after every edit.
    public private(set) var graph: Graph
    /// Increments with every edit, including undo and redo.
    public private(set) var revision: Int

    /// The platform undo manager to keep in step with ``history``, typically the one SwiftUI
    /// provides as `@Environment(\.undoManager)`. Set it from the view; set nil to detach.
    ///
    /// The model sets `groupsByEvent` to false on it and groups each step itself, so one Undo
    /// command always reverts exactly one history step, however many edits arrive in one event.
    public var undoManager: UndoManager? {
        didSet {
            guard undoManager !== oldValue else { return }
            oldValue?.removeAllActions(withTarget: self)
            undoManager?.groupsByEvent = false
            undoManager?.levelsOfUndo = history.limit
        }
    }
    /// ``GraphHistory/recordedStepCount`` when the undo manager was last told about a step.
    private var registeredStepCount = 0

    public var camera = GraphCamera()
    public var selection = GraphSelection()
    public var theme: GraphTheme
    /// The size of the canvas view, kept up to date by the view. Actions that depend on the
    /// visible area, such as ``zoomToFit()``, use it.
    public var viewSize = CGSize(width: 800, height: 600)
    /// How links are drawn and picked. Changing it re-routes every link.
    public var linkStyle: LinkStyle = .spline {
        didSet { cachedSpatialIndex = nil }
    }
    public var metrics: NodeLayoutMetrics {
        didSet {
            layoutCache.removeAll()
            cachedSpatialIndex = nil
        }
    }

    /// Built on demand by hit testing and dropped by every edit. Not observed.
    @ObservationIgnored var cachedSpatialIndex: SpatialIndex<CanvasItem>?

    private struct CachedLayout {
        var node: Node
        var layout: NodeLayout
    }

    /// Layouts keyed by node. An entry is reused while the node is unchanged. Not observed: the
    /// observable `graph` already changes whenever a layout could.
    @ObservationIgnored private var layoutCache: [NodeID: CachedLayout] = [:]

    public init(editor: GraphEditor, theme: GraphTheme = .dark, metrics: NodeLayoutMetrics = .standard) {
        self.editor = editor
        self.history = GraphHistory(editor: editor)
        self.graph = editor.graph
        self.revision = editor.revision
        self.theme = theme
        self.metrics = metrics
    }

    // MARK: Editing

    /// Applies and records a command. See ``GraphHistory/perform(_:name:coalescing:)``.
    /// On failure nothing changes and the error is rethrown.
    @discardableResult
    public func perform(
        _ command: GraphCommand, name: String? = nil, coalescing: Bool = false
    ) throws -> GraphChange {
        let change = try history.perform(command, name: name, coalescing: coalescing)
        didEdit(affectingDefinitions: command.changesDefinitions)
        registerUndoIfStepRecorded()
        return change
    }

    /// Connects two ports and records it. See ``GraphHistory/connect(_:name:)``.
    @discardableResult
    public func connect(_ proposal: ConnectionProposal, name: String? = nil) throws -> GraphChange {
        let change = try history.connect(proposal, name: name)
        didEdit(affectingDefinitions: false)
        registerUndoIfStepRecorded()
        return change
    }

    /// Runs `body` and records everything it performs as one undo step.
    public func group(name: String? = nil, _ body: () throws -> Void) throws {
        defer {
            didEdit(affectingDefinitions: true)
            registerUndoIfStepRecorded()
        }
        try history.group(name: name, body)
    }

    /// Ends a drag or slider sweep, so the next edit starts a new undo step.
    public func endCoalescing() {
        history.endCoalescing()
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    public var undoName: String? { history.undoName }
    public var redoName: String? { history.redoName }

    /// Undoes the newest step. Goes through the undo manager when one is attached, so its
    /// stacks and the Edit menu stay in step.
    public func undo() throws {
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
        } else {
            try performHistoryStep(redo: false)
        }
    }

    public func redo() throws {
        if let undoManager, undoManager.canRedo {
            undoManager.redo()
        } else {
            try performHistoryStep(redo: true)
        }
    }

    /// Steps the history and registers the matching action on the undo manager: while it is
    /// undoing that lands on its redo stack, and while redoing, back on its undo stack.
    private func performHistoryStep(redo: Bool) throws {
        let affectsDefinitions = redo
            ? history.redoStack.last?.command.changesDefinitions ?? false
            : history.undoStack.last?.inverse.changesDefinitions ?? false
        // The manager may hold older actions than the history keeps; those do nothing.
        guard redo ? history.canRedo : history.canUndo else { return }
        let name = redo ? history.redoName : history.undoName
        do {
            if redo { try history.redo() } else { try history.undo() }
        } catch {
            // The history cleared itself; the manager's stacks no longer match it.
            undoManager?.removeAllActions(withTarget: self)
            didEdit(affectingDefinitions: true)
            throw error
        }
        didEdit(affectingDefinitions: affectsDefinitions)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            try? model.performHistoryStep(redo: !redo)
        }
        undoManager.setActionName(name ?? "")
    }

    /// Tells the undo manager about a step the history just recorded. An edit that merged into
    /// the previous step (a drag, a slider sweep) is not a new step and registers nothing.
    private func registerUndoIfStepRecorded() {
        guard history.recordedStepCount != registeredStepCount else { return }
        registeredStepCount = history.recordedStepCount
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            try? model.performHistoryStep(redo: false)
        }
        undoManager.setActionName(history.undoName ?? "")
        undoManager.endUndoGrouping()
    }

    /// Re-reads the editor after something else changed it. Layouts are rebuilt in full, since
    /// the node registry may have changed too.
    public func refresh() {
        didEdit(affectingDefinitions: true)
    }

    private func didEdit(affectingDefinitions: Bool) {
        if affectingDefinitions { layoutCache.removeAll() }
        cachedSpatialIndex = nil
        graph = editor.graph
        revision = editor.revision
        pruneSelection()
    }

    /// Drops selected items that no longer exist, for example after a delete or an undo.
    private func pruneSelection() {
        var pruned = selection
        pruned.nodes = pruned.nodes.filter { graph.nodes[$0] != nil }
        pruned.links = pruned.links.filter { graph.links[$0] != nil }
        pruned.groups = pruned.groups.filter { graph.groups[$0] != nil }
        if pruned != selection { selection = pruned }
        // Forget layouts of nodes that are gone, so the cache cannot grow without bound.
        if layoutCache.count > graph.nodes.count {
            layoutCache = layoutCache.filter { graph.nodes[$0.key] != nil }
        }
    }

    // MARK: Layout

    /// The definition of `node` including its dynamic ports, or nil for an unregistered type.
    public func definition(of node: Node) -> NodeDefinition? {
        editor.nodes.definition(for: node)
    }

    /// The geometry of a node, or nil if there is no such node.
    public func layout(of id: NodeID) -> NodeLayout? {
        guard let node = graph.nodes[id] else { return nil }
        if let cached = layoutCache[id], cached.node == node { return cached.layout }
        let layout = NodeLayout(node: node, definition: definition(of: node), metrics: metrics)
        layoutCache[id] = CachedLayout(node: node, layout: layout)
        return layout
    }

    /// Where a link starts and ends, or nil if either end is missing. A link whose port does not
    /// exist (an unregistered node type, say) attaches at the node's edge instead.
    public func endpoints(of link: Link) -> (source: GraphPoint, target: GraphPoint)? {
        guard let source = layout(of: link.source.node), let target = layout(of: link.target.node) else {
            return nil
        }
        let start = source.port(link.source)?.position
            ?? GraphPoint(x: source.frame.maxX, y: source.frame.minY + source.header.size.height / 2)
        let end = target.port(link.target)?.position
            ?? GraphPoint(x: target.frame.minX, y: target.frame.minY + target.header.size.height / 2)
        return (start, end)
    }

    /// The route a link is drawn along, or nil if either end is missing.
    public func linkPath(of link: Link) -> LinkPath? {
        guard let ends = endpoints(of: link) else { return nil }
        return LinkPath(from: ends.source, to: ends.target, waypoints: link.waypoints, style: linkStyle)
    }

    /// The color a port is drawn with.
    public func color(of port: PortDefinition) -> RGBAColor {
        theme.color(for: port, in: editor.types)
    }

    /// Everything in the graph: the union of node frames and group bounds. Nil for an empty graph.
    public var contentBounds: GraphRect? {
        var rects = graph.groups.values.map(\.bounds)
        rects += graph.nodes.keys.compactMap { layout(of: $0)?.frame }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { union, rect in
            let minX = min(union.minX, rect.minX), minY = min(union.minY, rect.minY)
            return GraphRect(
                x: minX, y: minY, width: max(union.maxX, rect.maxX) - minX, height: max(union.maxY, rect.maxY) - minY)
        }
    }

    /// Moves and zooms the camera so the whole graph is visible. Does nothing for an empty graph.
    public func zoomToFit(padding: Double = 40) {
        guard let bounds = contentBounds else { return }
        camera = GraphCamera.framing(bounds, in: viewSize, padding: padding)
    }

    // MARK: Selection

    /// Replaces the selection with one node.
    public func select(node id: NodeID) {
        selection = GraphSelection(nodes: [id])
    }

    public func clearSelection() {
        selection = GraphSelection()
    }
}

extension GraphCommand {
    /// Whether the command can change what a node's ports look like for nodes it does not name:
    /// anything that edits a subgraph definition, at any depth of a batch.
    fileprivate var changesDefinitions: Bool {
        switch self {
        case .addSubgraph, .removeSubgraph, .setSubgraphInterface, .updateSubgraph, .inSubgraph: true
        case .batch(let commands): commands.contains { $0.changesDefinitions }
        default: false
        }
    }
}
