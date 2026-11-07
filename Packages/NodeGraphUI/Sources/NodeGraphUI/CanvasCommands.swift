import CoreGraphics
import NodeGraphCore

extension GraphInteractionController {
    /// Runs a command against the current selection. Returns whether it changed anything or
    /// was otherwise meaningful, so a key handler knows whether to consume the key.
    @discardableResult
    public func perform(_ command: CanvasCommand) -> Bool {
        let selection = model.selection
        let nodes = model.graph.nodes.values.filter { selection.nodes.contains($0.id) }
        switch command {
        case .selectAll:
            model.selection = GraphSelection(
                nodes: Set(model.graph.nodes.keys), groups: Set(model.graph.groups.keys))
            return true

        case .escape:
            if addNodeRequest != nil {
                cancelAddNode()
                return true
            }
            if editor != nil {
                closeEditor(commit: false)
                return true
            }
            if isDragging {
                cancel()
                return true
            }
            guard !selection.isEmpty else { return false }
            model.clearSelection()
            return true

        case .deleteSelection:
            guard !selection.isEmpty else { return false }
            return edit("Delete") {
                // Links first, so each removal is its own step in the batch and links that
                // vanish with their node are not removed twice.
                for id in model.graph.links.keys where selection.links.contains(id) {
                    try model.perform(.removeLink(id: id))
                }
                for node in nodes { try model.perform(.removeNode(id: node.id)) }
                for id in model.graph.groups.keys where selection.groups.contains(id) {
                    try model.perform(.removeGroup(id: id))
                }
            }

        case .nudge(let dx, let dy):
            let cell = model.theme.gridSpacing
            let delta = GraphPoint(x: Double(dx) * cell, y: Double(dy) * cell)
            return edit("Nudge") {
                // A selected group carries the nodes inside it, so those are not moved twice.
                var carried = Set<NodeID>()
                for id in model.graph.groups.keys where selection.groups.contains(id) {
                    let move = try model.editor.beginGroupMove(id)
                    carried.formUnion(move.members.map(\.node))
                    try model.perform(move.command(delta: delta))
                }
                let placements = nodes.filter { !$0.isPinned && !carried.contains($0.id) }.map {
                    NodePlacement(node: $0.id, position: GraphPoint(x: $0.position.x + delta.x, y: $0.position.y + delta.y))
                }
                if !placements.isEmpty { try model.perform(.setNodePositions(placements: placements)) }
            }

        case .zoomToFit:
            model.zoomToFit()
            return true
        case .resetZoom:
            setZoom(1)
            return true
        case .zoomIn:
            setZoom(model.camera.zoom * Self.zoomStep)
            return true
        case .zoomOut:
            setZoom(model.camera.zoom / Self.zoomStep)
            return true
        case .toggleSnapToGrid:
            model.snapsToGrid.toggle()
            return true
        case .addNode(let point):
            beginAddNode(at: point.map { model.camera.screenPoint(for: $0) })
            return true

        case .toggleCollapsed:
            let collapse = nodes.contains { !$0.isCollapsed }
            return setAttribute(on: nodes, name: collapse ? "Collapse" : "Expand", .isCollapsed(value: collapse))
        case .togglePinned:
            let pin = nodes.contains { !$0.isPinned }
            return setAttribute(on: nodes, name: pin ? "Pin" : "Unpin", .isPinned(value: pin))
        case .setMode(let mode):
            return setAttribute(on: nodes, name: "Set Mode", .mode(value: mode))

        case .disconnectSelection:
            let links = Set(nodes.flatMap { model.graph.links(attachedTo: $0.id) }.map(\.id))
            guard !links.isEmpty else { return false }
            return edit("Disconnect") {
                for id in model.graph.links.keys where links.contains(id) { try model.perform(.removeLink(id: id)) }
            }

        case .addWaypoint(let id, let point):
            guard let link = model.graph.links[id], let ends = model.endpoints(of: link) else { return false }
            var waypoints = link.waypoints
            waypoints.insert(point, at: Self.insertionIndex(of: point, start: ends.source, waypoints: waypoints, end: ends.target))
            return edit("Add Reroute Point") { try model.perform(.setLinkWaypoints(link: id, waypoints: waypoints)) }
        }
    }

    // MARK: Menus

    /// The context menu for a right-click at `point`, after selecting what is under it the way
    /// a right-click should: an unselected node, link or group becomes the selection, and
    /// empty canvas keeps nothing selected.
    public func contextMenu(at point: CGPoint, kind: PointerKind = .mouse) -> [CanvasMenuItem] {
        switch subject(at: point, kind: kind) {
        case .node(let id):
            if !model.selection.nodes.contains(id) { model.selection = GraphSelection(nodes: [id]) }
            let nodes = model.graph.nodes.values.filter { model.selection.nodes.contains($0.id) }
            let modes = Set(nodes.map(\.mode))
            return [
                CanvasMenuItem(nodes.allSatisfy(\.isCollapsed) ? "Expand" : "Collapse", .toggleCollapsed),
                CanvasMenuItem(nodes.allSatisfy(\.isPinned) ? "Unpin" : "Pin", .togglePinned),
                CanvasMenuItem("Mode", submenu: NodeMode.allCases.map {
                    CanvasMenuItem($0.menuTitle, .setMode($0), isChecked: modes == [$0])
                }),
                CanvasMenuItem(
                    "Disconnect All", .disconnectSelection,
                    isEnabled: nodes.contains { !model.graph.links(attachedTo: $0.id).isEmpty }),
                .separator,
                CanvasMenuItem("Delete", .deleteSelection),
            ]
        case .link(let id, let graphPoint):
            model.selection = GraphSelection(links: [id])
            return [
                CanvasMenuItem("Add Reroute Point", .addWaypoint(id, at: graphPoint)),
                .separator,
                CanvasMenuItem("Delete Link", .deleteSelection),
            ]
        case .group(let id):
            model.selection = GraphSelection(groups: [id])
            return [CanvasMenuItem("Delete Group", .deleteSelection)]
        case .empty:
            model.clearSelection()
            return [
                CanvasMenuItem("Add Node…", .addNode(at: model.camera.graphPoint(forScreen: point))),
                .separator,
                CanvasMenuItem("Select All", .selectAll, isEnabled: !model.graph.nodes.isEmpty),
                .separator,
                CanvasMenuItem("Zoom to Fit", .zoomToFit, isEnabled: !model.graph.nodes.isEmpty),
                CanvasMenuItem("Actual Size", .resetZoom),
                CanvasMenuItem("Snap to Grid", .toggleSnapToGrid, isChecked: model.snapsToGrid),
            ]
        }
    }

    // MARK: Helpers

    static let zoomStep = 1.25

    /// Zooms about the middle of the view.
    private func setZoom(_ zoom: Double) {
        let center = CGPoint(x: model.viewSize.width / 2, y: model.viewSize.height / 2)
        model.camera.setZoom(zoom, anchoredAtScreen: center)
    }

    /// Runs `body` as one undo step. Returns whether it succeeded.
    private func edit(_ name: String, _ body: () throws -> Void) -> Bool {
        (try? model.group(name: name, body)) != nil
    }

    private func setAttribute(on nodes: [Node], name: String, _ attribute: NodeAttribute) -> Bool {
        guard !nodes.isEmpty else { return false }
        return edit(name) {
            for node in nodes { try model.perform(.setNodeAttribute(node: node.id, attribute: attribute)) }
        }
    }

    /// Where a new waypoint goes in the list: between the two consecutive stops it adds the
    /// least extra length to.
    static func insertionIndex(of point: GraphPoint, start: GraphPoint, waypoints: [GraphPoint], end: GraphPoint) -> Int {
        let stops = [start] + waypoints + [end]
        var best = (index: 0, detour: Double.infinity)
        for index in 0..<(stops.count - 1) {
            let a = stops[index], b = stops[index + 1]
            let detour = a.distance(to: point) + point.distance(to: b) - a.distance(to: b)
            if detour < best.detour { best = (index, detour) }
        }
        return best.index
    }
}

extension NodeMode {
    var menuTitle: String {
        switch self {
        case .always: "Always"
        case .never: "Never"
        case .muted: "Muted"
        case .bypassed: "Bypassed"
        case .onTrigger: "On Trigger"
        }
    }
}
