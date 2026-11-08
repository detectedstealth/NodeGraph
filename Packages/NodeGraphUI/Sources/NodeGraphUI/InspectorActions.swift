import NodeGraphCore

/// The edits the inspector makes. Each is an ordinary undoable command; editing several nodes is
/// one step.
extension GraphEditorModel {
    /// Sets (or with nil, clears) the title of each node.
    @discardableResult
    public func setTitle(_ title: String?, of ids: some Collection<NodeID>) -> Bool {
        setAttribute(.title(value: title?.isEmpty == true ? nil : title), of: ids, name: "Rename")
    }

    @discardableResult
    public func setColor(_ color: RGBAColor?, of ids: some Collection<NodeID>) -> Bool {
        setAttribute(.color(value: color), of: ids, name: "Set Color")
    }

    @discardableResult
    public func setMode(_ mode: NodeMode, of ids: some Collection<NodeID>) -> Bool {
        setAttribute(.mode(value: mode), of: ids, name: "Set Mode")
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, of ids: some Collection<NodeID>) -> Bool {
        setAttribute(.isPinned(value: pinned), of: ids, name: pinned ? "Pin" : "Unpin")
    }

    @discardableResult
    public func setCollapsed(_ collapsed: Bool, of ids: some Collection<NodeID>) -> Bool {
        setAttribute(.isCollapsed(value: collapsed), of: ids, name: collapsed ? "Collapse" : "Expand")
    }

    /// Sets the outline of each node. Nil goes back to the node type's own.
    @discardableResult
    public func setShape(_ shape: NodeShape?, of ids: some Collection<NodeID>) -> Bool {
        setAttribute(.shape(value: shape), of: ids, name: "Set Shape")
    }

    /// Sets how each node's title bar is shown. Nil goes back to the node type's own.
    @discardableResult
    public func setTitleMode(_ mode: NodeTitleMode?, of ids: some Collection<NodeID>) -> Bool {
        setAttribute(.titleMode(value: mode), of: ids, name: "Set Title Bar")
    }

    /// Moves one node to an exact position.
    @discardableResult
    public func setPosition(_ position: GraphPoint, of id: NodeID) -> Bool {
        attempt(.setNodePositions(placements: [NodePlacement(node: id, position: position)]), name: "Move")
    }

    /// Sets a node's size, never smaller than its ports and widgets need.
    @discardableResult
    public func setSize(_ size: GraphSize, of id: NodeID) -> Bool {
        guard let minimum = layout(of: id)?.minimumSize else { return false }
        let clamped = GraphSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
        return attempt(.setNodeAttribute(node: id, attribute: .size(value: clamped)), name: "Resize")
    }

    /// Sets a property, limited to its range. A nil value removes the override, so the property
    /// goes back to its default. With `coalescing`, repeated calls (a slider sweep) are one step.
    @discardableResult
    public func setProperty(
        _ value: GraphValue?, named property: PropertyID, of id: NodeID, coalescing: Bool = false
    ) -> Bool {
        guard let node = graph.nodes[id], let definition = definition(of: node),
              let propertyDefinition = definition.property(property) else { return false }
        let new = value.map(propertyDefinition.clamped)
        guard new != node.properties[property] else { return false }
        return attempt(
            .setNodeProperty(node: id, property: property, value: new),
            name: "Set \(propertyDefinition.displayName)", coalescing: coalescing)
    }

    @discardableResult
    public func setGroupTitle(_ title: String, of id: GroupID) -> Bool {
        updateGroup(id, name: "Rename Group") { $0.title = title }
    }

    @discardableResult
    public func setGroupColor(_ color: RGBAColor?, of id: GroupID) -> Bool {
        updateGroup(id, name: "Set Color") { $0.color = color }
    }

    /// Removes every reroute point from a link.
    @discardableResult
    public func clearWaypoints(of id: LinkID) -> Bool {
        guard graph.links[id]?.waypoints.isEmpty == false else { return false }
        return attempt(.setLinkWaypoints(link: id, waypoints: []), name: "Remove Reroute Points")
    }

    /// Lines the nodes up on `edge` of the box around them, as one undoable move. Pinned nodes are
    /// measured but stay where they are. Returns whether anything moved.
    @discardableResult
    public func align(_ ids: some Collection<NodeID>, to edge: AlignEdge) -> Bool {
        arrange(ids, name: "Align \(edge.title)") { Arrangement.aligned($0, to: edge) }
    }

    /// Spaces three or more nodes evenly along an axis, keeping the outer two where they are.
    @discardableResult
    public func distribute(_ ids: some Collection<NodeID>, along axis: DistributeAxis) -> Bool {
        arrange(ids, name: "Distribute \(axis.title)") { Arrangement.distributed($0, along: axis) }
    }

    /// Lays the nodes out in columns from the nodes that feed them to the ones they feed, as one
    /// undoable move. The box around them keeps its top-left corner. Returns whether anything moved.
    @discardableResult
    public func autoArrange(_ ids: some Collection<NodeID>) -> Bool {
        let set = Set(ids)
        let edges = graph.links.values.map { Arrangement.Edge(from: $0.source.node, to: $0.target.node) }
            .filter { set.contains($0.from) && set.contains($0.to) }
        return arrange(ids, name: "Auto-Arrange") { Arrangement.layered($0, links: edges) }
    }

    /// Adds a group around the nodes, with room for its title bar, and selects it. One undoable
    /// step. Returns whether a group was added.
    @discardableResult
    public func groupNodes(_ ids: some Collection<NodeID>) -> Bool {
        let frames = ids.compactMap { layout(of: $0)?.frame }
        guard let first = frames.first else { return false }
        let padding = 20.0, titleHeight = GraphInteractionController.groupTitleHeight
        let minX = frames.reduce(first.minX) { min($0, $1.minX) }, maxX = frames.reduce(first.maxX) { max($0, $1.maxX) }
        let minY = frames.reduce(first.minY) { min($0, $1.minY) }, maxY = frames.reduce(first.maxY) { max($0, $1.maxY) }
        let bounds = GraphRect(
            x: minX - padding, y: minY - padding - titleHeight,
            width: maxX - minX + 2 * padding, height: maxY - minY + 2 * padding + titleHeight)
        return addGroup(bounds)
    }

    /// Adds an empty group of a default size centered on a graph-space point, and selects it.
    @discardableResult
    public func addGroup(centeredAt point: GraphPoint) -> Bool {
        addGroup(GraphRect(x: point.x - 200, y: point.y - 150, width: 400, height: 300))
    }

    private func addGroup(_ bounds: GraphRect) -> Bool {
        let group = NodeGroup(title: "Group", bounds: bounds)
        guard attempt(.addGroup(group: group), name: "Add Group") else { return false }
        selection = GraphSelection(groups: [group.id])
        return true
    }

    private func arrange(_ ids: some Collection<NodeID>, name: String, _ compute: ([Arrangement.Item]) -> [NodePlacement]) -> Bool {
        let items = graph.nodes.values.filter { ids.contains($0.id) }.compactMap { node in
            layout(of: node.id).map { Arrangement.Item(node: node.id, frame: $0.frame, isPinned: node.isPinned) }
        }
        let placements = compute(items)
        guard !placements.isEmpty else { return false }
        return attempt(.setNodePositions(placements: placements), name: name)
    }

    // MARK: Helpers

    private func attempt(_ command: GraphCommand, name: String, coalescing: Bool = false) -> Bool {
        (try? perform(command, name: name, coalescing: coalescing)) != nil
    }

    /// Whether setting `attribute` would change `node`.
    private func differs(_ attribute: NodeAttribute, from node: Node) -> Bool {
        switch attribute {
        case .size(let value): node.size != value
        case .title(let value): node.title != value
        case .color(let value): node.color != value
        case .mode(let value): node.mode != value
        case .isCollapsed(let value): node.isCollapsed != value
        case .isPinned(let value): node.isPinned != value
        case .shape(let value): node.shape != value
        case .titleMode(let value): node.titleMode != value
        }
    }

    private func setAttribute(_ attribute: NodeAttribute, of ids: some Collection<NodeID>, name: String) -> Bool {
        let nodes = graph.nodes.values.filter { ids.contains($0.id) && differs(attribute, from: $0) }
        guard !nodes.isEmpty else { return false }
        return (try? group(name: name) {
            for node in nodes { try self.perform(.setNodeAttribute(node: node.id, attribute: attribute)) }
        }) != nil
    }

    private func updateGroup(_ id: GroupID, name: String, _ change: (inout NodeGroup) -> Void) -> Bool {
        guard var group = graph.groups[id] else { return false }
        let original = group
        change(&group)
        guard group != original else { return false }
        return attempt(.updateGroup(group: group), name: name)
    }
}
