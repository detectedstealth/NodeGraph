#if !os(tvOS) && !os(watchOS)
import CoreGraphics
import NodeGraphCore

extension GraphInteractionController {
    /// Runs a command against the current selection. Returns whether it changed anything or
    /// was otherwise meaningful, so a key handler knows whether to consume the key.
    @discardableResult
    public func perform(_ command: CanvasCommand) -> Bool {
        if command.isEdit && !model.isEditable { return false }
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

        case .deleteSelection, .deleteAndReconnect:
            guard !selection.isEmpty else { return false }
            let bridging = command == .deleteAndReconnect
            return edit(bridging ? "Delete and Reconnect" : "Delete") {
                // Links first, so each removal is its own step in the batch and links that
                // vanish with their node are not removed twice.
                for id in model.graph.links.keys where selection.links.contains(id) {
                    try model.perform(.removeLink(id: id))
                }
                for node in nodes {
                    // Read the bridge before the node goes; connect it after, when its links no
                    // longer block the ports. A refused connection is skipped, not an error.
                    let bridges = bridging ? model.editor.bridgeProposals(deleting: node.id, in: model.currentScope) : []
                    try model.perform(.removeNode(id: node.id))
                    for proposal in bridges { _ = try? model.connect(proposal) }
                }
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
                    let move = try model.editor.beginGroupMove(id, in: model.currentScope)
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
        case .toggleLinkArrows:
            model.showsLinkArrows.toggle()
            return true
        case .toggleExecutionOrder:
            model.showsExecutionOrder.toggle()
            return true
        case .toggleStats:
            model.showsStats.toggle()
            return true
        case .exportImage:
            return model.exportImage()
        case .copy:
            return copySelection()
        case .cut:
            return cutSelection()
        case .paste(let point):
            return paste(at: point)
        case .pasteWithConnections(let point):
            return paste(at: point, keepingConnections: true)
        case .duplicate:
            return duplicateSelection()
        case .align(let edge):
            return model.align(selection.nodes, to: edge)
        case .distribute(let axis):
            return model.distribute(selection.nodes, along: axis)
        case .autoArrange:
            return model.autoArrange(selection.nodes.count >= 2 ? selection.nodes : Set(model.graph.nodes.keys))
        case .groupSelection:
            return model.groupNodes(selection.nodes)
        case .addGroup(let point):
            return model.addGroup(centeredAt: point)
        case .createSubgraph:
            closeEditor(commit: true)
            cancelAddNode()
            return model.beginCreateSubgraph()
        case .unpackSubgraph:
            guard selection.nodes.count == 1, let id = selection.nodes.first else { return false }
            return model.unpackSubgraph(instance: id)
        case .openSubgraph:
            guard selection.nodes.count == 1, let id = selection.nodes.first else { return false }
            return enterSubgraph(of: id)
        case .leaveSubgraph:
            return leaveSubgraph()
        case .addNode(let point):
            beginAddNode(at: point.map { model.camera.screenPoint(for: $0) })
            return true
        case .addDefaultNode(let port):
            return addDefaultNode(for: port) != nil
        case .renamePort(let port):
            return beginRenamePort(port)

        case .toggleCollapsed:
            let collapse = nodes.contains { !$0.isCollapsed }
            return setAttribute(on: nodes, name: collapse ? "Collapse" : "Expand", .isCollapsed(value: collapse))
        case .togglePinned:
            let pin = nodes.contains { !$0.isPinned }
            return setAttribute(on: nodes, name: pin ? "Pin" : "Unpin", .isPinned(value: pin))
        case .setMode(let mode):
            return setAttribute(on: nodes, name: "Set Mode", .mode(value: mode))
        case .toggleMode(let mode):
            let target = NodeMode.toggled(mode, among: nodes.map(\.mode))
            return setAttribute(on: nodes, name: target == .always ? "Enable" : "Set Mode", .mode(value: target))
        case .setShape(let shape):
            return setAttribute(on: nodes, name: "Set Shape", .shape(value: shape))
        case .setTitleMode(let mode):
            return setAttribute(on: nodes, name: "Set Title Bar", .titleMode(value: mode))

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
        let items = editableContextMenu(at: point, kind: kind)
        return model.isEditable ? items : items.map { $0.disablingEdits() }
    }

    private func editableContextMenu(at point: CGPoint, kind: PointerKind) -> [CanvasMenuItem] {
        let subject = subject(at: point, kind: kind)
        // A port gets its own item ahead of the menu of the node it belongs to.
        guard case .port(let port) = subject else { return menu(for: subject, at: point) }
        let title = defaultNodeType(for: port).flatMap { model.editor.nodes.definition(for: $0)?.displayName }
        let add = title.map { [CanvasMenuItem("Add \($0) Node", .addDefaultNode(for: port))] } ?? []
        let item = add + [CanvasMenuItem("Rename Port…", .renamePort(port)), .separator]
        return item + menu(for: .node(port.node), at: point)
    }

    private func menu(for subject: Subject, at point: CGPoint) -> [CanvasMenuItem] {
        switch subject {
        case .port:
            return []
        case .node(let id):
            if !model.selection.nodes.contains(id) { model.selection = GraphSelection(nodes: [id]) }
            let nodes = model.graph.nodes.values.filter { model.selection.nodes.contains($0.id) }
            let modes = Set(nodes.map(\.mode))
            // What each node is drawn with, so the menu checks the one they all share.
            let shapes = Set(nodes.map { $0.resolvedShape(in: model.definition(of: $0)) })
            let titleModes = Set(nodes.map { $0.resolvedTitleMode(in: model.definition(of: $0)) })
            let opens = nodes.count == 1 && model.subgraph(of: id) != nil
            let authoring = [CanvasMenuItem("Group", .groupSelection), CanvasMenuItem("Create Subgraph…", .createSubgraph)]
                + (opens ? [CanvasMenuItem("Unpack Subgraph", .unpackSubgraph)] : [])
            var arrange: [CanvasMenuItem] = []
            if nodes.count >= 2 {
                arrange.append(CanvasMenuItem("Align", submenu: AlignEdge.allCases.map { CanvasMenuItem($0.title, .align($0)) }))
            }
            if nodes.count >= 2 { arrange.append(CanvasMenuItem("Auto-Arrange", .autoArrange)) }
            if nodes.count >= 3 {
                arrange.append(CanvasMenuItem("Distribute", submenu: DistributeAxis.allCases.map { CanvasMenuItem($0.title, .distribute($0)) }))
            }
            return (opens ? [CanvasMenuItem("Open Subgraph", .openSubgraph), .separator] : []) + [
                CanvasMenuItem("Copy", .copy),
                CanvasMenuItem("Cut", .cut),
                CanvasMenuItem("Duplicate", .duplicate),
                .separator,
                CanvasMenuItem(nodes.allSatisfy(\.isCollapsed) ? "Expand" : "Collapse", .toggleCollapsed),
                CanvasMenuItem(nodes.allSatisfy(\.isPinned) ? "Unpin" : "Pin", .togglePinned),
                CanvasMenuItem("Mode", submenu: NodeMode.allCases.map {
                    CanvasMenuItem($0.menuTitle, .setMode($0), isChecked: modes == [$0])
                }),
                CanvasMenuItem("Shape", submenu: NodeShape.allCases.map { shape in
                    CanvasMenuItem(shape.menuTitle, .setShape(shape), isChecked: shapes == [shape])
                }),
                CanvasMenuItem("Title Bar", submenu: NodeTitleMode.allCases.map { mode in
                    CanvasMenuItem(mode.menuTitle, .setTitleMode(mode), isChecked: titleModes == [mode])
                }),
                CanvasMenuItem(
                    "Disconnect All", .disconnectSelection,
                    isEnabled: nodes.contains { !model.graph.links(attachedTo: $0.id).isEmpty }),
            ] + (arrange.isEmpty ? [] : [.separator] + arrange) + [.separator] + authoring + [
                .separator,
                CanvasMenuItem("Delete", .deleteSelection),
                CanvasMenuItem(
                    "Delete and Reconnect", .deleteAndReconnect,
                    isEnabled: nodes.contains { !model.editor.bridgeProposals(deleting: $0.id, in: model.currentScope).isEmpty }),
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
            return [
                CanvasMenuItem("Copy", .copy),
                CanvasMenuItem("Cut", .cut),
                CanvasMenuItem("Duplicate", .duplicate),
                .separator,
                CanvasMenuItem("Delete Group", .deleteSelection),
            ]
        case .empty:
            model.clearSelection()
            return (model.currentScope == nil ? [] : [CanvasMenuItem("Leave Subgraph", .leaveSubgraph), .separator]) + [
                CanvasMenuItem("Add Node…", .addNode(at: model.camera.graphPoint(forScreen: point))),
                CanvasMenuItem("Add Group", .addGroup(at: model.camera.graphPoint(forScreen: point))),
                CanvasMenuItem("Paste", .paste(at: model.camera.graphPoint(forScreen: point)), isEnabled: clipboard.mayHaveFragment),
                CanvasMenuItem(
                    "Paste with Connections", .pasteWithConnections(at: model.camera.graphPoint(forScreen: point)),
                    isEnabled: clipboard.mayHaveFragment),
                .separator,
                CanvasMenuItem("Select All", .selectAll, isEnabled: !model.graph.nodes.isEmpty),
                CanvasMenuItem("Auto-Arrange All", .autoArrange, isEnabled: model.graph.nodes.count >= 2),
                .separator,
                CanvasMenuItem("Zoom to Fit", .zoomToFit, isEnabled: !model.graph.nodes.isEmpty),
                CanvasMenuItem("Actual Size", .resetZoom),
                CanvasMenuItem("Snap to Grid", .toggleSnapToGrid, isChecked: model.snapsToGrid),
                .separator,
                CanvasMenuItem("Show Link Arrows", .toggleLinkArrows, isChecked: model.showsLinkArrows),
                CanvasMenuItem("Show Execution Order", .toggleExecutionOrder, isChecked: model.showsExecutionOrder),
                CanvasMenuItem("Show Statistics", .toggleStats, isChecked: model.showsStats),
                CanvasMenuItem(
                    "Export as Image…", .exportImage,
                    isEnabled: model.onExportImage != nil && !model.graph.nodes.isEmpty),
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

extension NodeShape {
    var menuTitle: String {
        switch self {
        case .box: "Box"
        case .round: "Round"
        case .card: "Card"
        }
    }
}

extension NodeTitleMode {
    var menuTitle: String {
        switch self {
        case .normal: "Normal"
        case .hidden: "Hidden"
        case .transparent: "Transparent"
        case .autohide: "Show on Hover"
        }
    }
}
#endif
