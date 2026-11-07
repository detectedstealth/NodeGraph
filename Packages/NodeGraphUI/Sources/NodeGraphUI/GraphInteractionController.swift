import CoreGraphics
import Foundation
import NodeGraphCore
import Observation

/// Turns pointer and gesture input into edits and camera moves.
///
/// A state machine with no SwiftUI in it, so every behavior is unit-tested by calling
/// ``pointerDown(at:modifiers:kind:)``, ``pointerMoved(to:modifiers:)`` and ``pointerUp(at:)``.
/// Points are screen points in the canvas view. All edits go through the model, so they are
/// undoable; a drag is one undo step.
///
/// What a press means depends on what is under it, tested in this order: a port (drag out a
/// link, pick up a connected input's link, or with Shift move all of an output's links), a
/// node's resize corner, a node, a link, a group's title bar or resize corner, then empty
/// canvas (marquee select with a mouse or pencil, pan with a finger).
@MainActor
@Observable
public final class GraphInteractionController {
    public let model: GraphEditorModel

    /// How far a press must travel, in screen points, before it counts as a drag.
    public var dragThreshold = 3.0
    /// Maximum distance, in screen points, from a link at which a press picks it.
    public var linkPickDistance = 6.0
    /// Reads the time, so tests can drive double-clicks without waiting.
    @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }
    /// Two clicks on empty canvas within this long (and ``doubleClickDistance``) are a double click.
    public var doubleClickInterval = Duration.milliseconds(400)
    public var doubleClickDistance = 16.0
    /// The selection rectangle being dragged, in graph space.
    public private(set) var marquee: GraphRect?
    /// The link being dragged out or moved.
    public private(set) var draft: ConnectionDraft?
    /// Links the canvas should not draw because the draft stands in for them.
    public private(set) var hiddenLinks: Set<LinkID> = []

    /// What the pointer is over while no drag is in progress, for highlighting.
    public enum Hover: Hashable, Sendable {
        case node(NodeID)
        case port(PortAddress)
        case link(LinkID)
    }
    public private(set) var hover: Hover?

    /// What a right-click landed on.
    enum Subject {
        case node(NodeID)
        case link(LinkID, GraphPoint)
        case group(GroupID)
        case empty
    }

    /// Whether a drag is in progress.
    public var isDragging: Bool {
        if case .idle = state { return false }
        if case .pressed = state { return false }
        return true
    }

    private enum Target {
        case empty
        case node(NodeID)
        case port(PortLayout)
        case nodeResize(NodeID)
        case link(LinkID)
        case groupTitle(GroupID)
        case groupResize(GroupID)
        case widget(NodeID, WidgetLayout)
    }

    private struct Press {
        var target: Target
        var startScreen: CGPoint
        var startGraph: GraphPoint
        var modifiers: InputModifiers
        var kind: PointerKind
        /// A plain click on an already selected node narrows the selection to it on release.
        var narrowsOnRelease = false
    }

    private enum State {
        case idle
        case pressed(Press)
        case panning(startCamera: GraphCamera, startScreen: CGPoint)
        case movingNodes(starts: [NodePlacement], anchor: NodePlacement, startGraph: GraphPoint)
        case movingGroup(GroupMove, startGraph: GraphPoint)
        case resizingNode(NodeID, startSize: GraphSize, minimum: GraphSize, startGraph: GraphPoint)
        case resizingGroup(GroupNode, startGraph: GraphPoint)
        case marquee(start: GraphPoint, base: GraphSelection)
        case connecting(anchor: PortAddress, replacing: Link?)
        case movingLinks(source: PortAddress, links: [Link])
        case adjustingSlider(node: NodeID, widget: WidgetLayout)
        case scrubbing(node: NodeID, widget: WidgetLayout, start: GraphValue, startScreenX: Double)
        case magnifying(startCamera: GraphCamera)
        case multiTouch(startCamera: GraphCamera, startCentroid: CGPoint)
    }

    /// A group with the bounds it had when its resize began.
    private struct GroupNode {
        var id: GroupID
        var startBounds: GraphRect
    }

    /// A widget being edited in an overlay (text, number, choice, color), or nil.
    public private(set) var editor: WidgetEditor?

    /// A request to add a node, shown as the search panel, or nil.
    public private(set) var addNodeRequest: AddNodeRequest?
    private var lastEmptyClick: (point: CGPoint, time: ContinuousClock.Instant)?
    private var lastNodeClick: (node: NodeID, time: ContinuousClock.Instant)?
    /// The last place the pointer was reported, for commands that act where it is.
    private var lastPointer: CGPoint?

    private var state = State.idle
    /// The kind of pointer of the press in progress, which sets how close counts as on a port.
    private var pressKind = PointerKind.mouse
    /// Whether the drag in progress has applied an edit, so cancelling knows to undo one.
    private var appliedEdit = false

    public init(model: GraphEditorModel) {
        self.model = model
    }

    // MARK: Pointer

    public func pointerDown(
        at point: CGPoint, modifiers: InputModifiers = [], kind: PointerKind = .platformDefault
    ) {
        closeEditor(commit: true)
        cancelAddNode()
        if isActive { cancel() }
        pressKind = kind
        let graphPoint = model.camera.graphPoint(forScreen: point)
        var press = Press(
            target: target(at: graphPoint, kind: kind), startScreen: point, startGraph: graphPoint,
            modifiers: modifiers, kind: kind)

        // Selection changes on press, so feedback is immediate and a drag moves what was picked.
        switch press.target {
        case .node(let id), .nodeResize(let id), .widget(let id, _):
            if modifiers.extendsSelection {
                if model.selection.nodes.contains(id), case .node = press.target {
                    model.selection.nodes.remove(id)
                    state = .idle
                    return
                }
                model.selection.nodes.insert(id)
            } else if !model.selection.nodes.contains(id) {
                model.selection = GraphSelection(nodes: [id])
            } else if model.selection.nodes.count > 1 {
                press.narrowsOnRelease = true
            }
        case .link(let id):
            if modifiers.extendsSelection { model.selection.links.insert(id) } else {
                model.selection = GraphSelection(links: [id])
            }
        case .groupTitle(let id), .groupResize(let id):
            if modifiers.extendsSelection { model.selection.groups.insert(id) } else {
                model.selection = GraphSelection(groups: [id])
            }
        case .port, .empty:
            break
        }
        // A slider follows the pointer from the moment it is pressed.
        if case .widget(let id, let widget) = press.target, case .slider = widget.spec.kind {
            beginSlider(id, widget, atGraphX: graphPoint.x)
            return
        }
        state = .pressed(press)
    }

    public func pointerMoved(to point: CGPoint, modifiers: InputModifiers = []) {
        if case .pressed(let press) = state {
            guard hypot(point.x - press.startScreen.x, point.y - press.startScreen.y) >= dragThreshold else { return }
            beginDrag(press)
        }
        let graphPoint = model.camera.graphPoint(forScreen: point)
        switch state {
        case .idle, .pressed, .magnifying, .multiTouch:
            break
        case .panning(let startCamera, let startScreen):
            var camera = startCamera
            camera.pan(byScreen: CGSize(width: point.x - startScreen.x, height: point.y - startScreen.y))
            model.camera = camera
        case .adjustingSlider(let id, let widget):
            setSlider(id, widget, atGraphX: graphPoint.x)
        case .scrubbing(let id, let widget, let start, let startScreenX):
            if let value = widget.spec.kind.scrubbed(from: start, by: point.x - startScreenX) {
                setValue(value, on: id, widget, coalescing: true)
            }
        case .movingNodes(let starts, let anchor, let startGraph):
            let delta = snappedDelta(
                GraphPoint(x: graphPoint.x - startGraph.x, y: graphPoint.y - startGraph.y),
                from: anchor.position, modifiers: modifiers)
            apply(.setNodePositions(placements: starts.map {
                NodePlacement(node: $0.node, position: GraphPoint(x: $0.position.x + delta.x, y: $0.position.y + delta.y))
            }), name: "Move")
        case .movingGroup(let move, let startGraph):
            let delta = GraphPoint(x: graphPoint.x - startGraph.x, y: graphPoint.y - startGraph.y)
            apply(move.command(delta: snappedDelta(delta, from: move.group.bounds.origin, modifiers: modifiers)), name: "Move Group")
        case .resizingNode(let id, let startSize, let minimum, let startGraph):
            var width = startSize.width + graphPoint.x - startGraph.x
            var height = startSize.height + graphPoint.y - startGraph.y
            if snaps(modifiers) {
                width = snap(width)
                height = snap(height)
            }
            let size = GraphSize(width: max(width, minimum.width), height: max(height, minimum.height))
            apply(.setNodeAttribute(node: id, attribute: .size(value: size)), name: "Resize")
        case .resizingGroup(let group, let startGraph):
            var width = group.startBounds.size.width + graphPoint.x - startGraph.x
            var height = group.startBounds.size.height + graphPoint.y - startGraph.y
            if snaps(modifiers) {
                width = snap(width)
                height = snap(height)
            }
            guard var updated = model.graph.groups[group.id] else { break }
            updated.bounds = GraphRect(
                origin: group.startBounds.origin,
                size: GraphSize(width: max(width, Self.minimumGroupSize), height: max(height, Self.minimumGroupSize)))
            apply(.updateGroup(group: updated), name: "Resize Group")
        case .marquee(let start, let base):
            let rect = GraphRect(
                x: min(start.x, graphPoint.x), y: min(start.y, graphPoint.y),
                width: abs(graphPoint.x - start.x), height: abs(graphPoint.y - start.y))
            marquee = rect
            var selection = base
            selection.nodes.formUnion(model.nodes(in: rect))
            selection.groups.formUnion(model.graph.groups.values.filter { rect.contains($0.bounds) }.map(\.id))
            model.selection = selection
        case .connecting(let anchor, let replacing):
            updateDraft(anchor: anchor, pointer: graphPoint, ignoring: replacing.map { [$0] } ?? [])
        case .movingLinks(let source, let links):
            updateDraft(anchor: source, pointer: graphPoint, ignoring: links, movingLinks: true)
        }
    }

    public func pointerUp(at point: CGPoint) {
        // A finger lifting while two are driving the camera is not the end of that gesture.
        switch state {
        case .multiTouch, .magnifying: return
        default: break
        }
        let graphPoint = model.camera.graphPoint(forScreen: point)
        defer { reset() }
        switch state {
        case .idle, .magnifying, .multiTouch:
            break
        case .pressed(let press):
            click(press)
        case .panning, .movingNodes, .movingGroup, .resizingNode, .resizingGroup, .adjustingSlider, .scrubbing:
            model.endCoalescing()
        case .marquee:
            break
        case .connecting(let anchor, let replacing):
            finishConnection(anchor: anchor, replacing: replacing, at: graphPoint, screen: point)
        case .movingLinks(let source, let links):
            finishLinkMove(from: source, links: links)
        }
    }

    /// Abandons the drag in progress and puts everything back as it was.
    public func cancel() {
        switch state {
        case .movingNodes, .movingGroup, .resizingNode, .resizingGroup, .adjustingSlider, .scrubbing:
            model.endCoalescing()
            if appliedEdit { try? model.undo() }
        case .magnifying(let startCamera), .multiTouch(let startCamera, _):
            model.camera = startCamera
        case .panning(let startCamera, _):
            model.camera = startCamera
        default:
            break
        }
        reset()
    }

    // MARK: Hover and scroll

    /// Reports where the pointer is, or nil when it leaves the canvas. Ignored during a drag.
    public func hover(at point: CGPoint?) {
        lastPointer = point
        var result: Hover?
        if let point, !isActive {
            switch target(at: model.camera.graphPoint(forScreen: point)) {
            case .port(let port): result = .port(port.address)
            case .node(let id), .nodeResize(let id), .widget(let id, _): result = .node(id)
            case .link(let id): result = .link(id)
            case .empty, .groupTitle, .groupResize: result = nil
            }
        }
        if result != hover { hover = result }
    }

    /// Handles a scroll wheel or trackpad scroll at `point`.
    ///
    /// A trackpad (`isPrecise`) pans the view, and zooms about the pointer while Command or
    /// Option is held. A physical wheel zooms about the pointer, as node editors usually do.
    public func scroll(by delta: CGSize, at point: CGPoint, modifiers: InputModifiers = [], isPrecise: Bool) {
        if isPrecise && !modifiers.contains(.command) && !modifiers.contains(.option) {
            pan(byScreen: delta)
            return
        }
        let sensitivity = isPrecise ? 0.01 : 0.06
        let factor = exp(Double(delta.height) * sensitivity)
        model.camera.setZoom(model.camera.zoom * factor, anchoredAtScreen: point)
    }

    func subject(at point: CGPoint, kind: PointerKind = .mouse) -> Subject {
        let graphPoint = model.camera.graphPoint(forScreen: point)
        switch target(at: graphPoint, kind: kind) {
        case .node(let id), .nodeResize(let id), .widget(let id, _): return .node(id)
        case .port(let port): return .node(port.address.node)
        case .link(let id): return .link(id, graphPoint)
        case .groupTitle(let id), .groupResize(let id): return .group(id)
        case .empty: return .empty
        }
    }

    // MARK: Zoom and pan

    /// Moves the view by `delta` screen points, for scroll wheels and two-finger drags.
    public func pan(byScreen delta: CGSize) {
        model.camera.pan(byScreen: delta)
    }

    /// Sets the zoom to the zoom at the start of the pinch times `totalScale`, around `anchor`.
    /// Pass the gesture's total magnification each time, not the change since the last call:
    /// that is what keeps repeated updates from compounding.
    public func magnify(totalScale: Double, anchor: CGPoint) {
        let startZoom: Double
        if case .magnifying(let startCamera) = state {
            startZoom = startCamera.zoom
        } else if isPointerDown || isMultiTouch {
            // A pointer button or fingers already own the input. A trackpad can report a stray
            // pinch while it is being clicked or dragged, and that must not cut the drag short.
            return
        } else {
            startZoom = model.camera.zoom
            state = .magnifying(startCamera: model.camera)
        }
        // Applied to the camera as it is now, not as it was at the start, so a scroll that pans
        // during the pinch is kept. The zoom itself is absolute from the start, so it cannot
        // compound.
        model.camera.setZoom(startZoom * totalScale, anchoredAtScreen: anchor)
    }

    public func endMagnify() {
        if case .magnifying = state { reset() }
    }

    /// Whether a pointer or finger is pressed, from the press to its release.
    public var isPointerDown: Bool {
        switch state {
        case .idle, .magnifying, .multiTouch: false
        default: true
        }
    }

    /// Whether two or more fingers are down and driving the camera.
    public var isMultiTouch: Bool {
        if case .multiTouch = state { return true }
        return false
    }

    /// Two fingers came down: abandon whatever one finger was doing and start driving the camera.
    public func multiTouchBegan(centroid: CGPoint) {
        if isActive { cancel() }
        state = .multiTouch(startCamera: model.camera, startCentroid: centroid)
    }

    /// The fingers moved. `centroid` is where their midpoint is now and `scale` how far apart
    /// they are relative to when they came down. Both are totals since the start, so the zoom
    /// cannot compound, and the graph point under the fingers' midpoint follows it: pinching
    /// zooms about the fingers and dragging both pans.
    public func multiTouchMoved(centroid: CGPoint, scale: Double) {
        guard case .multiTouch(let startCamera, let startCentroid) = state else { return }
        var camera = startCamera
        camera.setZoom(startCamera.zoom * scale, anchoredAtScreen: startCentroid)
        camera.pan(byScreen: CGSize(width: centroid.x - startCentroid.x, height: centroid.y - startCentroid.y))
        model.camera = camera
    }

    public func multiTouchEnded() {
        if case .multiTouch = state { reset() }
    }

    // MARK: Press targets

    private var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    /// How much bigger targets are for a pointer kind: a fingertip is far less precise than a
    /// mouse or a pencil tip.
    static func reach(of kind: PointerKind) -> Double {
        kind == .touch ? 2 : 1
    }

    private func target(at point: GraphPoint, kind: PointerKind = .mouse) -> Target {
        let lod = LevelOfDetail(zoom: model.camera.zoom)
        let zoom = model.camera.zoom
        let reach = Self.reach(of: kind)
        if lod.drawsPorts, let port = model.port(at: point, radius: model.metrics.portHitRadius * reach) {
            return .port(port)
        }
        if let id = model.node(at: point) {
            if let layout = model.layout(of: id), !layout.isCollapsed {
                let grip = Self.gripSlop * reach / zoom
                let handle = layout.resizeHandle
                let inflated = GraphRect(
                    x: handle.minX - grip, y: handle.minY - grip,
                    width: handle.size.width + 2 * grip, height: handle.size.height + 2 * grip)
                if inflated.contains(point), layout.frame.contains(point) { return .nodeResize(id) }
            }
            if lod.tier == .full, let widget = model.layout(of: id)?.widget(at: point) { return .widget(id, widget) }
            return .node(id)
        }
        if let id = model.link(at: point, tolerance: linkPickDistance * reach / zoom) { return .link(id) }
        if let id = model.group(at: point), let group = model.graph.groups[id] {
            let corner = Self.groupHandleSize
            if point.x >= group.bounds.maxX - corner, point.y >= group.bounds.maxY - corner { return .groupResize(id) }
            if point.y <= group.bounds.minY + Self.groupTitleHeight { return .groupTitle(id) }
        }
        return .empty
    }

    static let gripSlop = 4.0
    static let groupTitleHeight = 28.0
    static let groupHandleSize = 16.0
    static let minimumGroupSize = 40.0

    // MARK: Starting a drag

    private func beginDrag(_ press: Press) {
        model.endCoalescing()
        appliedEdit = false
        switch press.target {
        case .empty:
            if press.kind == .touch {
                state = .panning(startCamera: model.camera, startScreen: press.startScreen)
            } else {
                let base = press.modifiers.extendsSelection ? model.selection : GraphSelection()
                model.selection = base
                state = .marquee(start: press.startGraph, base: base)
            }
        case .node(let id):
            let movable = model.selection.nodes.contains(id) ? model.selection.nodes : [id]
            let starts = model.graph.nodes.values
                .filter { movable.contains($0.id) && !$0.isPinned }
                .map { NodePlacement(node: $0.id, position: $0.position) }
            guard let anchor = starts.first(where: { $0.node == id }) ?? starts.first else {
                state = .idle  // everything picked is pinned
                return
            }
            state = .movingNodes(starts: starts, anchor: anchor, startGraph: press.startGraph)
        case .nodeResize(let id):
            guard let layout = model.layout(of: id) else { state = .idle; return }
            state = .resizingNode(id, startSize: layout.frame.size, minimum: layout.minimumSize, startGraph: press.startGraph)
        case .widget(let id, let widget):
            // Only a number can be dragged; the other widgets act on release.
            if case .number = widget.spec.kind, let value = currentValue(of: widget, on: id) {
                state = .scrubbing(node: id, widget: widget, start: value, startScreenX: press.startScreen.x)
            } else {
                state = .idle
            }
        case .link:
            state = .idle  // links are selected, not dragged
        case .groupTitle(let id):
            guard let move = try? model.editor.beginGroupMove(id, in: model.currentScope) else { state = .idle; return }
            state = .movingGroup(move, startGraph: press.startGraph)
        case .groupResize(let id):
            guard let group = model.graph.groups[id] else { state = .idle; return }
            state = .resizingGroup(GroupNode(id: id, startBounds: group.bounds), startGraph: press.startGraph)
        case .port(let port):
            beginLinkDrag(from: port, press: press)
        }
    }

    private func beginLinkDrag(from port: PortLayout, press: Press) {
        let address = port.address
        let attached = address.direction == .input
            ? model.graph.links(into: address) : model.graph.links(from: address)
        if address.direction == .input, let link = attached.first {
            // Pick up the link by its input end; its source stays put.
            hiddenLinks = [link.id]
            state = .connecting(anchor: link.source, replacing: link)
        } else if address.direction == .output, press.modifiers.contains(.shift), !attached.isEmpty {
            hiddenLinks = Set(attached.map(\.id))
            state = .movingLinks(source: address, links: attached)
        } else {
            state = .connecting(anchor: address, replacing: nil)
        }
        if case .connecting(let anchor, _) = state { updateDraft(anchor: anchor, pointer: press.startGraph, ignoring: []) }
        if case .movingLinks(let source, let links) = state {
            updateDraft(anchor: source, pointer: press.startGraph, ignoring: links, movingLinks: true)
        }
    }

    // MARK: Clicks

    private func click(_ press: Press) {
        switch press.target {
        case .node(let id):
            if press.narrowsOnRelease { model.selection = GraphSelection(nodes: [id]) }
            // A double click on a subgraph instance opens it.
            let time = now()
            if let last = lastNodeClick, last.node == id, time - last.time <= doubleClickInterval, model.subgraph(of: id) != nil {
                lastNodeClick = nil
                enterSubgraph(of: id)
            } else {
                lastNodeClick = (id, time)
            }
        case .widget(let id, let widget):
            activate(widget, on: id)
        case .empty:
            if !press.modifiers.extendsSelection { model.clearSelection() }
            let time = now()
            if let last = lastEmptyClick, time - last.time <= doubleClickInterval,
               hypot(press.startScreen.x - last.point.x, press.startScreen.y - last.point.y) <= doubleClickDistance {
                lastEmptyClick = nil
                beginAddNode(at: press.startScreen)
            } else {
                lastEmptyClick = (press.startScreen, time)
            }
        default:
            break
        }
    }

    // MARK: Edits

    private func apply(_ command: GraphCommand, name: String) {
        if (try? model.perform(command, name: name, coalescing: true)) != nil { appliedEdit = true }
    }

    private func snaps(_ modifiers: InputModifiers) -> Bool {
        model.snapsToGrid != modifiers.contains(.option)
    }

    private func snap(_ value: Double) -> Double {
        let spacing = model.theme.gridSpacing
        return spacing > 0 ? (value / spacing).rounded() * spacing : value
    }

    /// `delta`, adjusted when snapping so the item that started at `origin` lands on the grid.
    /// Everything moved shifts by the same amount, keeping its position relative to the others.
    private func snappedDelta(_ delta: GraphPoint, from origin: GraphPoint, modifiers: InputModifiers) -> GraphPoint {
        guard snaps(modifiers) else { return delta }
        return GraphPoint(x: snap(origin.x + delta.x) - origin.x, y: snap(origin.y + delta.y) - origin.y)
    }

    // MARK: Links

    private func updateDraft(
        anchor: PortAddress, pointer: GraphPoint, ignoring links: [Link], movingLinks: Bool = false
    ) {
        guard let anchorLayout = model.layout(of: anchor.node)?.port(anchor) else { return }
        var draft = ConnectionDraft(anchor: anchor, anchorPosition: anchorLayout.position, pointer: pointer)
        let reach = model.metrics.portHitRadius * Self.reach(of: pressKind)
        if let port = model.port(at: pointer, radius: reach)?.address, port != anchor {
            // Moving links wants another output; connecting wants the opposite end.
            let wanted = movingLinks ? anchor.direction : (anchor.direction == .output ? .input : .output)
            if port.direction == wanted {
                if isAllowed(anchor: anchor, port: port, ignoring: links, movingLinks: movingLinks) {
                    draft.candidate = port
                } else {
                    draft.rejected = port
                }
            }
        }
        self.draft = draft
    }

    private func isAllowed(anchor: PortAddress, port: PortAddress, ignoring links: [Link], movingLinks: Bool) -> Bool {
        let editor = model.editor
        if movingLinks {
            return links.allSatisfy { link in
                let context = ValidationContext(
                    graph: model.graph, nodes: editor.nodes, types: editor.types, ignoring: link.id)
                return editor.connectionValidator
                    .check(ConnectionProposal(source: port, target: link.target), in: context).isAllowed
            }
        }
        let context = ValidationContext(
            graph: model.graph, nodes: editor.nodes, types: editor.types, ignoring: links.first?.id)
        return editor.connectionValidator.check(ConnectionProposal(source: anchor, target: port).oriented(), in: context).isAllowed
    }

    private func finishConnection(anchor: PortAddress, replacing: Link?, at point: GraphPoint, screen: CGPoint) {
        var port = draft?.candidate
        // Dropped on a node's body rather than on a port: take its first port that works.
        if port == nil, draft?.rejected == nil, let id = model.node(at: point) {
            port = firstAcceptingPort(on: id, anchor: anchor, ignoring: replacing)
        }
        if let port {
            if port == replacing?.target { return }  // put back where it was
            do {
                try model.group(name: replacing == nil ? "Connect" : "Reconnect") {
                    if let replacing { try model.perform(.removeLink(id: replacing.id)) }
                    try model.connect(ConnectionProposal(source: anchor, target: port))
                }
            } catch {
                // Refused after all: leave the graph as it was.
            }
        } else if let replacing {
            if draft?.rejected == nil { _ = try? model.perform(.removeLink(id: replacing.id), name: "Disconnect") }
        } else if draft?.rejected == nil, model.node(at: point) == nil {
            beginAddNode(at: screen, from: anchor)
        }
    }

    private func firstAcceptingPort(on node: NodeID, anchor: PortAddress, ignoring replacing: Link?) -> PortAddress? {
        guard node != anchor.node, let layout = model.layout(of: node) else { return nil }
        let candidates = anchor.direction == .output ? layout.inputs : layout.outputs
        return candidates.map(\.address).first {
            isAllowed(anchor: anchor, port: $0, ignoring: replacing.map { [$0] } ?? [], movingLinks: false)
        }
    }

    private func finishLinkMove(from source: PortAddress, links: [Link]) {
        guard let port = draft?.candidate else { return }
        do {
            try model.group(name: "Move Links") {
                for link in links {
                    try model.perform(.removeLink(id: link.id))
                    try model.perform(.addLink(link: Link(
                        id: link.id, sourceNode: port.node, sourcePort: port.port,
                        targetNode: link.target.node, targetPort: link.target.port, waypoints: link.waypoints)))
                }
            }
        } catch {
            // Refused after all: leave the graph as it was.
        }
    }

    // MARK: Clipboard

    /// Where Copy and Cut put things and Paste reads them. The system clipboard by default.
    @ObservationIgnored public var clipboard: any GraphClipboard = SystemClipboard()

    /// What copying the selection takes: the selected nodes and groups, the nodes inside each
    /// selected group, and the groups nested in it.
    private func copyTargets() -> (nodes: [NodeID], groups: [GroupID]) {
        var nodes = model.selection.nodes
        var groups = model.selection.groups
        let graph = model.graph
        for id in model.selection.groups {
            guard let group = graph.groups[id] else { continue }
            nodes.formUnion(graph.members(of: group, frame: model.editor.nodes.frame(of:)))
            groups.formUnion(graph.nestedGroups(in: group))
        }
        // Storage order, so a paste keeps the original stacking.
        return (graph.nodes.keys.filter(nodes.contains), graph.groups.keys.filter(groups.contains))
    }

    /// Puts the selection on the clipboard. Returns whether there was anything to copy.
    @discardableResult
    public func copySelection() -> Bool {
        let targets = copyTargets()
        guard !targets.nodes.isEmpty || !targets.groups.isEmpty,
              let fragment = try? model.editor.fragment(nodes: targets.nodes, groups: targets.groups, in: model.currentScope)
        else { return false }
        clipboard.write(fragment)
        return true
    }

    /// Copies the selection, then removes it (a selected group goes with what is inside it).
    @discardableResult
    public func cutSelection() -> Bool {
        guard copySelection() else { return false }
        let targets = copyTargets()
        return (try? model.group(name: "Cut") {
            for id in targets.nodes { try model.perform(.removeNode(id: id)) }
            for id in targets.groups { try model.perform(.removeGroup(id: id)) }
        }) != nil
    }

    /// Pastes the clipboard centered on `point`, or on the pointer (or the middle of the view)
    /// when nil, and selects what was pasted. Returns whether anything was pasted; a fragment
    /// with a node type this editor does not have is refused.
    @discardableResult
    public func paste(at point: GraphPoint? = nil) -> Bool {
        guard let fragment = clipboard.read(), !fragment.isEmpty,
              let bounds = fragment.bounds(frame: model.editor.nodes.frame(of:)) else { return false }
        let target = point ?? model.camera.graphPoint(
            forScreen: lastPointer ?? CGPoint(x: model.viewSize.width / 2, y: model.viewSize.height / 2))
        var delta = GraphPoint(
            x: target.x - (bounds.minX + bounds.size.width / 2), y: target.y - (bounds.minY + bounds.size.height / 2))
        if model.snapsToGrid {
            let spacing = model.theme.gridSpacing
            if spacing > 0 {
                delta = GraphPoint(
                    x: (( bounds.minX + delta.x) / spacing).rounded() * spacing - bounds.minX,
                    y: ((bounds.minY + delta.y) / spacing).rounded() * spacing - bounds.minY)
            }
        }
        return place(fragment, translatedBy: delta, name: "Paste")
    }

    /// Copies the selection to just beside itself and selects the copy, leaving the clipboard alone.
    @discardableResult
    public func duplicateSelection() -> Bool {
        let targets = copyTargets()
        guard !targets.nodes.isEmpty || !targets.groups.isEmpty,
              let fragment = try? model.editor.fragment(nodes: targets.nodes, groups: targets.groups, in: model.currentScope)
        else { return false }
        let offset = Self.duplicateOffset
        return place(fragment, translatedBy: GraphPoint(x: offset, y: offset), name: "Duplicate")
    }

    /// How far a duplicate sits from its original, in graph units.
    static let duplicateOffset = 24.0

    private func place(_ fragment: GraphFragment, translatedBy delta: GraphPoint, name: String) -> Bool {
        guard let paste = try? model.editor.pasteCommand(fragment, translatedBy: delta, in: model.currentScope),
              (try? model.perform(paste.command, name: name, isScoped: true)) != nil else { return false }
        model.selection = GraphSelection(nodes: Set(paste.nodes), groups: Set(paste.groups))
        return true
    }

    // MARK: Subgraphs

    /// Opens the subgraph a node is an instance of. Anything half done (a drag, an open editor
    /// or search) is abandoned first, since it belongs to the graph being left.
    @discardableResult
    public func enterSubgraph(of node: NodeID) -> Bool {
        guard model.subgraph(of: node) != nil else { return false }
        prepareForNavigation()
        return model.enterSubgraph(of: node)
    }

    @discardableResult
    public func leaveSubgraph() -> Bool {
        guard !model.scopePath.isEmpty else { return false }
        prepareForNavigation()
        return model.leaveSubgraph()
    }

    /// Goes to a level of the breadcrumb. See ``GraphEditorModel/navigate(toDepth:)``.
    public func navigate(toDepth depth: Int) {
        prepareForNavigation()
        model.navigate(toDepth: depth)
    }

    private func prepareForNavigation() {
        closeEditor(commit: true)
        cancelAddNode()
        if isActive { cancel() }
        hover = nil
        lastEmptyClick = nil
        lastNodeClick = nil
    }

    // MARK: Adding nodes

    /// A request to add a node: where, and the port a link is being dragged from, if any.
    public struct AddNodeRequest: Hashable, Sendable {
        public var screenPoint: CGPoint
        public var graphPoint: GraphPoint
        /// The port the user dragged a link from and released on empty canvas. The new node is
        /// linked to it.
        public var anchor: PortAddress?
        /// What the search should require of a node so the link can attach, if there is an anchor.
        public var filter: PortFilter?
    }

    /// Opens the add-node search at `screenPoint` (the pointer's last position, or the middle of
    /// the view, when nil). With an `anchor`, only nodes the link can end on are offered, and the
    /// new node is linked to that port.
    public func beginAddNode(at screenPoint: CGPoint? = nil, from anchor: PortAddress? = nil) {
        closeEditor(commit: true)
        let point = screenPoint ?? lastPointer ?? CGPoint(x: model.viewSize.width / 2, y: model.viewSize.height / 2)
        addNodeRequest = AddNodeRequest(
            screenPoint: point, graphPoint: model.camera.graphPoint(forScreen: point), anchor: anchor,
            filter: anchor.flatMap { model.filter(for: $0) })
    }

    public func cancelAddNode() {
        if addNodeRequest != nil { addNodeRequest = nil }
    }

    /// Adds the matched node where the request was made and, if the request came from a dragged
    /// link, connects it to the matched port. One undo step. Returns the new node's id.
    @discardableResult
    public func addNode(_ match: NodeCatalogMatch) -> NodeID? {
        guard let request = addNodeRequest else { return nil }
        addNodeRequest = nil
        let typeID = match.entry.id
        guard let preview = model.previewLayout(of: typeID) else { return nil }

        // Put the node so the port the link will use lands on the release point; without a link,
        // center it on the point.
        var position: GraphPoint
        if let anchor = request.anchor, let port = match.port,
           let offset = preview.port(PortAddress(
               node: preview.node, port: port.id, direction: anchor.direction == .output ? .input : .output))?.position {
            position = GraphPoint(x: request.graphPoint.x - offset.x, y: request.graphPoint.y - offset.y)
        } else {
            position = GraphPoint(
                x: request.graphPoint.x - preview.frame.size.width / 2,
                y: request.graphPoint.y - model.metrics.headerHeight / 2)
        }
        if model.snapsToGrid {
            let spacing = model.theme.gridSpacing
            if spacing > 0 {
                position = GraphPoint(x: (position.x / spacing).rounded() * spacing, y: (position.y / spacing).rounded() * spacing)
            }
        }

        let node = Node(typeID: typeID, position: position)
        let added = (try? model.group(name: "Add \(match.entry.displayName)") {
            try model.perform(.addNode(node: node))
            if let anchor = request.anchor, let port = match.port {
                let end = PortAddress(node: node.id, port: port.id, direction: anchor.direction == .output ? .input : .output)
                // A refused link leaves the node added without it.
                _ = try? model.connect(ConnectionProposal(source: anchor, target: end))
            }
        }) != nil
        guard added else { return nil }
        model.select(node: node.id)
        return node.id
    }

    // MARK: Widgets

    /// A widget being edited in an overlay.
    public struct WidgetEditor: Hashable, Sendable {
        public var node: NodeID
        public var spec: NodeWidgetSpec
        /// What the text field holds while typing. Applied when the editor closes with a commit.
        public var draftText: String
    }

    /// The edited widget's frame in graph space, following the node if it moves.
    public var editorFrame: GraphRect? {
        guard let editor else { return nil }
        return model.layout(of: editor.node)?.widgets.first { $0.spec.id == editor.spec.id }?.frame
    }

    /// Records what has been typed so far.
    public func updateDraft(_ text: String) {
        editor?.draftText = text
    }

    /// Closes the editor. With `commit`, a text or number editor applies what was typed (a
    /// number that does not parse is dropped); choice and color editors commit through
    /// ``commitEditor(_:)`` instead.
    public func closeEditor(commit: Bool) {
        guard let editor else { return }
        self.editor = nil
        model.endCoalescing()
        guard commit, let value = editor.spec.kind.value(fromText: editor.draftText),
              let widget = model.layout(of: editor.node)?.widgets.first(where: { $0.spec.id == editor.spec.id })
        else { return }
        setValue(value, on: editor.node, widget, coalescing: false)
    }

    /// Applies `value` from an editor that stays open (a color picker being dragged). Repeated
    /// calls merge into one undo step, which ends when the editor closes.
    public func applyLive(_ value: GraphValue) {
        guard let editor, let widget = model.layout(of: editor.node)?.widgets.first(where: { $0.spec.id == editor.spec.id }) else { return }
        setValue(value, on: editor.node, widget, coalescing: true)
    }

    /// Applies `value` from a choice or color editor and closes it.
    public func commitEditor(_ value: GraphValue) {
        guard let editor, let widget = model.layout(of: editor.node)?.widgets.first(where: { $0.spec.id == editor.spec.id }) else {
            self.editor = nil
            return
        }
        self.editor = nil
        setValue(value, on: editor.node, widget, coalescing: false)
    }

    /// The widget's property value, falling back to the property's default.
    func currentValue(of widget: WidgetLayout, on id: NodeID) -> GraphValue? {
        guard let node = model.graph.nodes[id], let property = widget.spec.property,
              let definition = model.definition(of: node) else { return nil }
        return node.value(of: property, in: definition)
    }

    /// What releasing on a widget does: flip a toggle, press a button, or open an editor.
    private func activate(_ widget: WidgetLayout, on id: NodeID) {
        let current = currentValue(of: widget, on: id)
        switch widget.spec.kind {
        case .toggle:
            if case .bool(let on)? = current { setValue(.bool(!on), on: id, widget, coalescing: false) }
        case .button(let action):
            model.onWidgetAction?(id, action)
        case .number, .text, .multilineText:
            editor = WidgetEditor(node: id, spec: widget.spec, draftText: Self.editableText(current))
        case .combo, .color:
            editor = WidgetEditor(node: id, spec: widget.spec, draftText: "")
        case .slider, .readOnly, .custom:
            break
        }
    }

    /// The text a text field starts with: the value without a trailing format.
    static func editableText(_ value: GraphValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .int(let v)?: String(v)
        case .double(let v)?: WidgetKind.format(v)
        default: ""
        }
    }

    private func beginSlider(_ id: NodeID, _ widget: WidgetLayout, atGraphX x: Double) {
        model.endCoalescing()
        appliedEdit = false
        state = .adjustingSlider(node: id, widget: widget)
        setSlider(id, widget, atGraphX: x)
    }

    private func setSlider(_ id: NodeID, _ widget: WidgetLayout, atGraphX x: Double) {
        let frame = widget.frame
        guard frame.size.width > 0,
              let value = widget.spec.kind.sliderValue(atFraction: (x - frame.minX) / frame.size.width) else { return }
        setValue(value, on: id, widget, coalescing: true)
    }

    /// Sets the widget's property, limited to its range, as an undoable edit. Does nothing if the
    /// value would not change.
    private func setValue(_ value: GraphValue, on id: NodeID, _ widget: WidgetLayout, coalescing: Bool) {
        guard let property = widget.spec.property, let node = model.graph.nodes[id],
              let definition = model.definition(of: node), let propertyDefinition = definition.property(property)
        else { return }
        let clamped = propertyDefinition.clamped(value)
        guard clamped != node.value(of: property, in: definition) else { return }
        let change = try? model.perform(
            .setNodeProperty(node: id, property: property, value: clamped),
            name: "Set \(widget.spec.title)", coalescing: coalescing)
        if change != nil { appliedEdit = true }
    }

    private func reset() {
        // Observation treats every assignment as a change, so only assign when it is one.
        if hover != nil { hover = nil }
        state = .idle
        marquee = nil
        draft = nil
        hiddenLinks = []
        appliedEdit = false
    }
}
