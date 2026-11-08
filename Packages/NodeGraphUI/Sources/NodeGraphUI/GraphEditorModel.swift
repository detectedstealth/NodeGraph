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

/// Why the model refused an edit.
public enum GraphEditorModelError: Error, Hashable, Sendable {
    /// ``GraphEditorModel/isEditable`` is false.
    case readOnly
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

    /// A copy of the graph being edited, replaced after every edit. It is the root graph, or the
    /// inner graph of the subgraph named by ``currentScope``.
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

    /// Whether the graph can be edited. When false the canvas is a viewer: the camera, the
    /// selection and navigating into subgraphs still work, but every edit, undo and redo is
    /// refused with ``GraphEditorModelError/readOnly``, and the canvas, menus, inspector and
    /// VoiceOver actions stop offering edits. Edits made directly on ``editor`` (a server
    /// change, say) are not affected; call ``refresh()`` after them.
    public var isEditable = true

    public var camera = GraphCamera()
    public var selection = GraphSelection()
    public var theme: GraphTheme
    /// Whether moving and resizing snap to the theme's grid spacing. Holding Option while
    /// dragging inverts it.
    public var snapsToGrid = false
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
    /// How much larger than normal the user's preferred text size is, kept up to date by the
    /// view from Dynamic Type (see ``textScale(for:)``). Text and the rows that hold it grow by
    /// this factor; ports and hit areas do not.
    public var textScale = 1.0 {
        didSet {
            guard textScale != oldValue else { return }
            layoutCache.removeAll()
            cachedSpatialIndex = nil
        }
    }
    /// ``metrics`` with the rows that hold text scaled by ``textScale``. Layout uses these.
    public var layoutMetrics: NodeLayoutMetrics {
        var scaled = metrics
        scaled.headerHeight *= textScale
        scaled.portRowHeight *= textScale
        scaled.widgetRowHeight *= textScale
        scaled.minimumWidth *= textScale
        return scaled
    }

    /// Built on demand by hit testing and dropped by every edit. Not observed.
    @ObservationIgnored var cachedSpatialIndex: SpatialIndex<CanvasItem>?

    /// Adds widgets that are not properties, such as buttons. Set before the first draw, or
    /// layouts already made are dropped.
    public var widgetProvider: (any NodeWidgetProvider)? {
        didSet {
            layoutCache.removeAll()
            cachedSpatialIndex = nil
        }
    }
    /// Called when a button widget is pressed, with the node and the button's action name.
    @ObservationIgnored public var onWidgetAction: ((NodeID, String) -> Void)?
    /// Renderers for custom widgets, by name.
    @ObservationIgnored public private(set) var widgetRenderers: [String: WidgetRenderer] = [:]

    /// Custom body drawing for node types, set with ``registerContentDrawing(for:_:)``.
    @ObservationIgnored public private(set) var contentDrawings: [NodeTypeID: NodeContentDrawing] = [:]

    private struct CachedLayout {
        var node: Node
        var layout: NodeLayout
    }

    /// Layouts keyed by node. An entry is reused while the node is unchanged. Not observed: the
    /// observable `graph` already changes whenever a layout could.
    @ObservationIgnored private var layoutCache: [NodeID: CachedLayout] = [:]

    /// How the latest run went, per node, for the canvas's badges and progress bars. Fed by
    /// ``apply(_:)`` or ``observeExecution(_:)``.
    public internal(set) var executionState = ExecutionState()

    /// The Create Subgraph form, while it is open.
    public var createSubgraphRequest: CreateSubgraphRequest?

    /// The port chooser for drawing a link without dragging, while it is open. See
    /// ``beginConnection(from:)``.
    public var connectionRequest: ConnectionRequest?

    /// The subgraphs entered to reach the graph being edited, outermost first. Empty at the root.
    /// Each was opened from an instance of it in the one before, so this is the breadcrumb.
    public private(set) var scopePath: [SubgraphID] = []
    /// The subgraph being edited, or nil at the root.
    public var currentScope: SubgraphID? { scopePath.last }
    /// The view of each level the user has left, so coming back finds it as they left it.
    @ObservationIgnored private var savedCameras: [SubgraphID?: GraphCamera] = [:]

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
    ///
    /// Inside a subgraph the command is applied to its inner graph. Pass `isScoped: true` for a
    /// command that already names its scope, such as one from ``GraphEditor/pasteCommand(_:translatedBy:in:)``.
    @discardableResult
    public func perform(
        _ command: GraphCommand, name: String? = nil, coalescing: Bool = false, isScoped: Bool = false
    ) throws -> GraphChange {
        try requireEditable()
        let change = try history.perform(isScoped ? command : scoped(command), name: name, coalescing: coalescing)
        didEdit(affectingDefinitions: command.changesDefinitions || isScoped)
        registerUndoIfStepRecorded()
        return change
    }

    /// Connects two ports and records it. See ``GraphHistory/connect(_:name:)``.
    @discardableResult
    public func connect(_ proposal: ConnectionProposal, name: String? = nil) throws -> GraphChange {
        try requireEditable()
        let change = try history.connect(proposal, name: name, in: currentScope)
        didEdit(affectingDefinitions: false)
        registerUndoIfStepRecorded()
        return change
    }

    /// Runs `body` and records everything it performs as one undo step.
    public func group(name: String? = nil, _ body: () throws -> Void) throws {
        try requireEditable()
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

    /// Whether an edit is allowed right now; throws ``GraphEditorModelError/readOnly`` if not.
    private func requireEditable() throws {
        guard isEditable else { throw GraphEditorModelError.readOnly }
    }

    public var canUndo: Bool { isEditable && history.canUndo }
    public var canRedo: Bool { isEditable && history.canRedo }
    public var undoName: String? { history.undoName }
    public var redoName: String? { history.redoName }

    /// Undoes the newest step. Goes through the undo manager when one is attached, so its
    /// stacks and the Edit menu stay in step.
    public func undo() throws {
        try requireEditable()
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
        } else {
            try performHistoryStep(redo: false)
        }
    }

    public func redo() throws {
        try requireEditable()
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
        // A subgraph that no longer exists (an undone creation) cannot be shown; step out to
        // the nearest level that does.
        if let missing = scopePath.firstIndex(where: { editor.subgraphs[$0] == nil }) {
            scopePath.removeSubrange(missing...)
            layoutCache.removeAll()
            selection = GraphSelection()
        }
        graph = editor.editedGraph(in: currentScope) ?? editor.graph
        revision = editor.revision
        pruneSelection()
    }

    /// `command`, applied inside the subgraph being edited when there is one.
    private func scoped(_ command: GraphCommand) -> GraphCommand {
        currentScope.map { .inSubgraph(id: $0, command: command) } ?? command
    }

    // MARK: Subgraphs

    /// The display name of a level of the breadcrumb: the subgraph's name, or "Graph" for the root.
    public func scopeName(_ scope: SubgraphID?) -> String {
        scope.flatMap { editor.subgraphs[$0]?.interface.name } ?? "Graph"
    }

    /// The subgraph an instance node opens, if `node` is an instance of one that exists.
    public func subgraph(of node: NodeID) -> SubgraphID? {
        guard let id = graph.nodes[node]?.typeID.subgraphID, editor.subgraphs[id] != nil else { return nil }
        return id
    }

    /// Opens the subgraph a node is an instance of, for editing its inner graph. Returns whether
    /// it did. Entering the subgraph being edited, or one that would make the path loop, is refused.
    @discardableResult
    public func enterSubgraph(of node: NodeID) -> Bool {
        guard let id = subgraph(of: node), !scopePath.contains(id) else { return false }
        move(to: scopePath + [id])
        return true
    }

    /// Goes back out one level. Returns whether there was one to leave.
    @discardableResult
    public func leaveSubgraph() -> Bool {
        guard !scopePath.isEmpty else { return false }
        move(to: Array(scopePath.dropLast()))
        return true
    }

    /// Goes to a level of the breadcrumb: 0 is the root, `scopePath.count` the current subgraph.
    public func navigate(toDepth depth: Int) {
        guard depth >= 0, depth < scopePath.count else { return }
        move(to: Array(scopePath.prefix(depth)))
    }

    private func move(to path: [SubgraphID]) {
        savedCameras[currentScope] = camera
        scopePath = path
        selection = GraphSelection()
        layoutCache.removeAll()
        cachedSpatialIndex = nil
        graph = editor.editedGraph(in: currentScope) ?? editor.graph
        if let saved = savedCameras[currentScope] {
            camera = saved
            autoFramedCamera = nil
        } else {
            autoFramedCamera = nil
            zoomToFit()
            autoFramedCamera = camera
        }
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
        let definition = definition(of: node)
        let layout = NodeLayout(
            node: node, definition: definition, widgets: widgetSpecs(for: node, definition: definition),
            contentHeight: contentDrawings[node.typeID]?.height ?? 0, metrics: layoutMetrics)
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

    /// The widgets in `node`'s body: one per property, then whatever ``widgetProvider`` adds.
    public func widgetSpecs(for node: Node, definition: NodeDefinition?) -> [NodeWidgetSpec] {
        guard let definition else { return [] }
        return definition.properties.map(NodeWidgetSpec.init)
            + (widgetProvider?.widgets(for: node, definition: definition) ?? [])
    }

    /// The node types that can be added right now, as a searchable list.
    ///
    /// Inside a subgraph, the subgraph itself and every subgraph that contains it are left out,
    /// since adding one would make a subgraph contain itself.
    public func makeNodeCatalog() -> NodeCatalog {
        var excluded = Set<SubgraphID>()
        if let scope = currentScope {
            excluded.insert(scope)
            var grew = true
            while grew {
                grew = false
                for definition in editor.subgraphs.values
                where !excluded.contains(definition.id) && !definition.directDependencies.isDisjoint(with: excluded) {
                    excluded.insert(definition.id)
                    grew = true
                }
            }
        }
        let hidden = Set(excluded.compactMap { editor.subgraphs[$0]?.typeID })
        return NodeCatalog(nodes: editor.nodes, types: editor.types, excluding: hidden)
    }

    /// The layout a new node of `typeID` would have at the origin, to place it by one of its ports.
    func previewLayout(of typeID: NodeTypeID) -> NodeLayout? {
        let node = Node(typeID: typeID)
        guard let definition = definition(of: node) else { return nil }
        return NodeLayout(node: node, definition: definition, widgets: widgetSpecs(for: node, definition: definition), contentHeight: contentDrawings[typeID]?.height ?? 0, metrics: layoutMetrics)
    }

    /// What a link dragged from `anchor` needs from a node it ends on.
    func filter(for anchor: PortAddress) -> PortFilter? {
        layout(of: anchor.node)?.port(anchor).map { PortFilter($0.definition) }
    }

    /// Registers the drawing for ``WidgetKind/custom(_:)`` widgets of this name. Packs call this
    /// at setup; a custom widget with no renderer shows its value as text.
    public func registerWidgetRenderer(named name: String, _ renderer: @escaping WidgetRenderer) {
        widgetRenderers[name] = renderer
    }

    /// Gives nodes of `typeID` an area below their widgets that `drawing` fills, for domain
    /// visuals such as thumbnails and scopes. Packs call this at setup; a later call for the same
    /// type replaces the earlier one.
    public func registerContentDrawing(for typeID: NodeTypeID, _ drawing: NodeContentDrawing) {
        contentDrawings[typeID] = drawing
        layoutCache.removeAll()
        cachedSpatialIndex = nil
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

    /// The camera the model last set by fitting the graph. While ``camera`` still equals it, the
    /// user has not moved the view, so resizing the view keeps the graph in frame.
    private var autoFramedCamera: GraphCamera?

    /// Tells the model how big the canvas view is. Until the camera is moved by hand, each new
    /// size refits the graph, so the view that first appears at a provisional size (as a window
    /// does on macOS) ends up framed correctly rather than stuck at the first guess.
    public func viewSizeChanged(to size: CGSize) {
        viewSize = size
        guard size.width > 0, size.height > 0 else { return }
        if autoFramedCamera == nil || camera == autoFramedCamera {
            zoomToFit()
            autoFramedCamera = camera
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
