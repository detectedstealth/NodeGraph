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

    public var camera = GraphCamera()
    public var selection = GraphSelection()
    public var theme: GraphTheme
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
        return change
    }

    /// Connects two ports and records it. See ``GraphHistory/connect(_:name:)``.
    @discardableResult
    public func connect(_ proposal: ConnectionProposal, name: String? = nil) throws -> GraphChange {
        let change = try history.connect(proposal, name: name)
        didEdit(affectingDefinitions: false)
        return change
    }

    /// Runs `body` and records everything it performs as one undo step.
    public func group(name: String? = nil, _ body: () throws -> Void) throws {
        defer { didEdit(affectingDefinitions: true) }
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

    public func undo() throws {
        let affectsDefinitions = history.undoStack.last?.inverse.changesDefinitions ?? false
        defer { didEdit(affectingDefinitions: affectsDefinitions) }
        try history.undo()
    }

    public func redo() throws {
        let affectsDefinitions = history.redoStack.last?.command.changesDefinitions ?? false
        defer { didEdit(affectingDefinitions: affectsDefinitions) }
        try history.redo()
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

    /// The color a port is drawn with.
    public func color(of port: PortDefinition) -> RGBAColor {
        theme.color(for: port, in: editor.types)
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
