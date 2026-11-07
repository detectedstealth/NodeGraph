/// A group drag in progress. Captures the group, the nodes it contains, and the groups nested
/// inside it when the drag starts, so every update is computed from the originals. That keeps
/// members fixed during the drag and avoids rounding drift from repeated small deltas.
public struct GroupMove: Sendable {
    public let group: NodeGroup
    public let nestedGroups: [NodeGroup]
    public let members: [NodePlacement]

    /// The command that places the group and its contents `delta` away from where they started.
    ///
    /// Commands from one `GroupMove` coalesce, so a drag is a single undo step when recorded
    /// with `coalescing: true`.
    public func command(delta: GraphPoint) -> GraphCommand {
        var commands: [GraphCommand] = [.updateGroup(group: shifted(group, by: delta))]
        commands += nestedGroups.map { .updateGroup(group: shifted($0, by: delta)) }
        if !members.isEmpty {
            commands.append(.setNodePositions(placements: members.map {
                NodePlacement(
                    node: $0.node,
                    position: GraphPoint(x: $0.position.x + delta.x, y: $0.position.y + delta.y))
            }))
        }
        return .batch(commands: commands)
    }

    private func shifted(_ group: NodeGroup, by delta: GraphPoint) -> NodeGroup {
        var moved = group
        moved.bounds.origin = GraphPoint(x: group.bounds.origin.x + delta.x, y: group.bounds.origin.y + delta.y)
        return moved
    }
}

extension GraphEditor {
    /// Nodes whose frames lie entirely inside the group.
    public func members(of group: GroupID) throws -> [NodeID] {
        guard let group = graph.groups[group] else { throw GraphEditError.groupNotFound(group) }
        return graph.members(of: group, frame: nodes.frame(of:))
    }

    /// Starts moving a group together with its member nodes and nested groups. With `scope`, the
    /// group is in that subgraph's inner graph (apply the move's commands inside it).
    public func beginGroupMove(_ id: GroupID, in scope: SubgraphID? = nil) throws -> GroupMove {
        guard let graph = editedGraph(in: scope) else { throw GraphEditError.subgraphNotFound(scope!) }
        guard let group = graph.groups[id] else { throw GraphEditError.groupNotFound(id) }
        let members = graph.members(of: group, frame: nodes.frame(of:)).compactMap { id in
            graph.nodes[id].map { NodePlacement(node: id, position: $0.position) }
        }
        let nested = graph.nestedGroups(in: group).compactMap { graph.groups[$0] }
        return GroupMove(group: group, nestedGroups: nested, members: members)
    }

    /// A command adding a group that encloses `nodes` with `padding` on every side. Resizing
    /// is an ordinary `updateGroup` with new bounds; membership follows automatically.
    public func groupCommand(
        around nodeIDs: [NodeID], title: String, padding: Double = 20, color: RGBAColor? = nil
    ) throws -> GraphCommand {
        var frames: [GraphRect] = []
        for id in nodeIDs {
            guard let node = graph.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
            frames.append(nodes.frame(of: node))
        }
        guard let first = frames.first else { throw GraphEditError.invalidGeometry }
        let minX = frames.reduce(first.minX) { Swift.min($0, $1.minX) } - padding
        let minY = frames.reduce(first.minY) { Swift.min($0, $1.minY) } - padding
        let maxX = frames.reduce(first.maxX) { Swift.max($0, $1.maxX) } + padding
        let maxY = frames.reduce(first.maxY) { Swift.max($0, $1.maxY) } + padding
        let group = NodeGroup(
            title: title, bounds: GraphRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            color: color)
        return .addGroup(group: group)
    }
}
