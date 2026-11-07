import CoreGraphics
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
    /// Called when a link dragged from a port is released over empty canvas, so the editor can
    /// offer to add a node there. Receives the port and the graph point.
    @ObservationIgnored public var onLinkReleasedOnEmpty: ((PortAddress, GraphPoint) -> Void)?

    /// The selection rectangle being dragged, in graph space.
    public private(set) var marquee: GraphRect?
    /// The link being dragged out or moved.
    public private(set) var draft: ConnectionDraft?
    /// Links the canvas should not draw because the draft stands in for them.
    public private(set) var hiddenLinks: Set<LinkID> = []

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
        case magnifying(startCamera: GraphCamera)
    }

    /// A group with the bounds it had when its resize began.
    private struct GroupNode {
        var id: GroupID
        var startBounds: GraphRect
    }

    private var state = State.idle
    /// Whether the drag in progress has applied an edit, so cancelling knows to undo one.
    private var appliedEdit = false

    public init(model: GraphEditorModel) {
        self.model = model
    }

    // MARK: Pointer

    public func pointerDown(
        at point: CGPoint, modifiers: InputModifiers = [], kind: PointerKind = .platformDefault
    ) {
        if isActive { cancel() }
        let graphPoint = model.camera.graphPoint(forScreen: point)
        var press = Press(
            target: target(at: graphPoint), startScreen: point, startGraph: graphPoint,
            modifiers: modifiers, kind: kind)

        // Selection changes on press, so feedback is immediate and a drag moves what was picked.
        switch press.target {
        case .node(let id), .nodeResize(let id):
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
        state = .pressed(press)
    }

    public func pointerMoved(to point: CGPoint, modifiers: InputModifiers = []) {
        if case .pressed(let press) = state {
            guard hypot(point.x - press.startScreen.x, point.y - press.startScreen.y) >= dragThreshold else { return }
            beginDrag(press)
        }
        let graphPoint = model.camera.graphPoint(forScreen: point)
        switch state {
        case .idle, .pressed, .magnifying:
            break
        case .panning(let startCamera, let startScreen):
            var camera = startCamera
            camera.pan(byScreen: CGSize(width: point.x - startScreen.x, height: point.y - startScreen.y))
            model.camera = camera
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
        let graphPoint = model.camera.graphPoint(forScreen: point)
        defer { reset() }
        switch state {
        case .idle, .magnifying:
            break
        case .pressed(let press):
            click(press)
        case .panning, .movingNodes, .movingGroup, .resizingNode, .resizingGroup:
            model.endCoalescing()
        case .marquee:
            break
        case .connecting(let anchor, let replacing):
            finishConnection(anchor: anchor, replacing: replacing, at: graphPoint)
        case .movingLinks(let source, let links):
            finishLinkMove(from: source, links: links)
        }
    }

    /// Abandons the drag in progress and puts everything back as it was.
    public func cancel() {
        switch state {
        case .movingNodes, .movingGroup, .resizingNode, .resizingGroup:
            model.endCoalescing()
            if appliedEdit { try? model.undo() }
        case .magnifying(let startCamera):
            model.camera = startCamera
        case .panning(let startCamera, _):
            model.camera = startCamera
        default:
            break
        }
        reset()
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
        let start: GraphCamera
        if case .magnifying(let startCamera) = state {
            start = startCamera
        } else {
            if isActive { cancel() }
            start = model.camera
            state = .magnifying(startCamera: start)
        }
        var camera = start
        // The anchor's graph point must stay under the anchor at the start camera's position,
        // so the pinch is measured from where it began.
        camera.setZoom(start.zoom * totalScale, anchoredAtScreen: anchor)
        model.camera = camera
    }

    public func endMagnify() {
        if case .magnifying = state { reset() }
    }

    // MARK: Press targets

    private var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    private func target(at point: GraphPoint) -> Target {
        let lod = LevelOfDetail(zoom: model.camera.zoom)
        let zoom = model.camera.zoom
        if lod.drawsPorts, let port = model.port(at: point) { return .port(port) }
        if let id = model.node(at: point) {
            if let layout = model.layout(of: id), !layout.isCollapsed {
                let grip = Self.gripSlop / zoom
                let handle = layout.resizeHandle
                let inflated = GraphRect(
                    x: handle.minX - grip, y: handle.minY - grip,
                    width: handle.size.width + 2 * grip, height: handle.size.height + 2 * grip)
                if inflated.contains(point), layout.frame.contains(point) { return .nodeResize(id) }
            }
            return .node(id)
        }
        if let id = model.link(at: point, tolerance: linkPickDistance / zoom) { return .link(id) }
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
        case .link:
            state = .idle  // links are selected, not dragged
        case .groupTitle(let id):
            guard let move = try? model.editor.beginGroupMove(id) else { state = .idle; return }
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
        case .empty:
            if !press.modifiers.extendsSelection { model.clearSelection() }
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
        if let port = model.port(at: pointer)?.address, port != anchor {
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
                    graph: editor.graph, nodes: editor.nodes, types: editor.types, ignoring: link.id)
                return editor.connectionValidator
                    .check(ConnectionProposal(source: port, target: link.target), in: context).isAllowed
            }
        }
        let context = ValidationContext(
            graph: editor.graph, nodes: editor.nodes, types: editor.types, ignoring: links.first?.id)
        return editor.connectionValidator.check(ConnectionProposal(source: anchor, target: port).oriented(), in: context).isAllowed
    }

    private func finishConnection(anchor: PortAddress, replacing: Link?, at point: GraphPoint) {
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
            onLinkReleasedOnEmpty?(anchor, point)
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

    private func reset() {
        state = .idle
        marquee = nil
        draft = nil
        hiddenLinks = []
        appliedEdit = false
    }
}
