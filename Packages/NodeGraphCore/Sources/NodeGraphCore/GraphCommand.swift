/// A node and where to put it. Used by ``GraphCommand/setNodePositions(_:)``.
public struct NodePlacement: Hashable, Sendable, Codable {
    public var node: NodeID
    public var position: GraphPoint

    public init(node: NodeID, position: GraphPoint) {
        self.node = node
        self.position = position
    }
}

/// One editable field of a node other than its properties.
public enum NodeAttribute: Hashable, Sendable, Codable {
    /// `nil` falls back to the definition's default size.
    case size(value: GraphSize?)
    /// `nil` falls back to the definition's display name.
    case title(value: String?)
    case color(value: RGBAColor?)
    case mode(value: NodeMode)
    case isCollapsed(value: Bool)
    case isPinned(value: Bool)

    /// The field this attribute sets, ignoring its value.
    var field: String {
        switch self {
        case .size: "size"
        case .title: "title"
        case .color: "color"
        case .mode: "mode"
        case .isCollapsed: "isCollapsed"
        case .isPinned: "isPinned"
        }
    }

    /// The node's current value of the same field.
    func current(in node: Node) -> NodeAttribute {
        switch self {
        case .size: .size(value: node.size)
        case .title: .title(value: node.title)
        case .color: .color(value: node.color)
        case .mode: .mode(value: node.mode)
        case .isCollapsed: .isCollapsed(value: node.isCollapsed)
        case .isPinned: .isPinned(value: node.isPinned)
        }
    }

    func apply(to node: inout Node) {
        switch self {
        case .size(let v): node.size = v
        case .title(let v): node.title = v
        case .color(let v): node.color = v
        case .mode(let v): node.mode = v
        case .isCollapsed(let v): node.isCollapsed = v
        case .isPinned(let v): node.isPinned = v
        }
    }
}

/// A single edit to a graph. Plain data: `Codable`, so it doubles as the undo record and the
/// change-log entry a server will replay.
///
/// Apply commands with ``GraphEditor``. Add commands carry an optional `index` so that undoing
/// a removal restores the original storage order.
public indirect enum GraphCommand: Hashable, Sendable, Codable {
    case addNode(node: Node, index: Int? = nil)
    /// Also removes every link attached to the node.
    case removeNode(id: NodeID)
    /// Sets absolute positions. Absolute (not relative) so undo is exact.
    case setNodePositions(placements: [NodePlacement])
    case setNodeAttribute(node: NodeID, attribute: NodeAttribute)
    /// Sets a property value, or removes the override when `value` is nil.
    case setNodeProperty(node: NodeID, property: PropertyID, value: GraphValue?)
    /// Sets how many ports a node has in one of its dynamic port groups. Shrinking removes the
    /// links to the ports that go away; undo puts them back. Growing and shrinking happen from the
    /// end, so the numbers of the remaining ports never change.
    case setPortCount(node: NodeID, group: String, count: Int)
    case addLink(link: Link, index: Int? = nil)
    case removeLink(id: LinkID)
    /// Replaces the points a link is drawn through. Empty makes it a straight run between its ends.
    /// Only the picture changes; what the graph computes does not.
    case setLinkWaypoints(link: LinkID, waypoints: [GraphPoint])
    case addGroup(group: NodeGroup, index: Int? = nil)
    case removeGroup(id: GroupID)
    /// Replaces a group, matched by id.
    case updateGroup(group: NodeGroup)
    /// Adds a subgraph definition. Subgraph commands work only at the top level of a document, not
    /// inside ``inSubgraph(id:command:)``.
    case addSubgraph(definition: SubgraphDefinition, index: Int? = nil)
    /// Removes a definition that has no instances anywhere.
    case removeSubgraph(id: SubgraphID)
    /// Replaces a definition's name, ports and promoted properties. Links and property values on
    /// instances that the new interface no longer supports are removed in the same step.
    case setSubgraphInterface(id: SubgraphID, interface: SubgraphInterface)
    /// Replaces a whole definition (interface, inner graph and origin), matched by id, for example
    /// to take a newer version from a library. Instances are cleaned up as for
    /// ``setSubgraphInterface(id:interface:)``.
    case updateSubgraph(definition: SubgraphDefinition)
    /// Applies `command` to a subgraph's inner graph. The inner graph is edited with the same
    /// commands as the root graph.
    case inSubgraph(id: SubgraphID, command: GraphCommand)
    /// Commands applied in order as one undoable step. Applies fully or not at all.
    case batch(commands: [GraphCommand])
}

extension GraphCommand {
    /// Merges `next` into this command when both edit the same target, so a drag or slider
    /// sweep becomes one undo step. The result replaces both as the forward command.
    /// Returns nil when they cannot merge.
    public func coalesced(with next: GraphCommand) -> GraphCommand? {
        switch (self, next) {
        case (.setNodePositions(let a), .setNodePositions(let b)):
            Set(a.map(\.node)) == Set(b.map(\.node)) ? next : nil
        case (.setNodeAttribute(let n1, let a1), .setNodeAttribute(let n2, let a2)):
            n1 == n2 && a1.field == a2.field ? next : nil
        case (.setPortCount(let n1, let g1, _), .setPortCount(let n2, let g2, _)):
            n1 == n2 && g1 == g2 ? next : nil
        case (.setNodeProperty(let n1, let p1, _), .setNodeProperty(let n2, let p2, _)):
            n1 == n2 && p1 == p2 ? next : nil
        case (.setLinkWaypoints(let l1, _), .setLinkWaypoints(let l2, _)):
            l1 == l2 ? next : nil
        case (.updateGroup(let a), .updateGroup(let b)):
            a.id == b.id ? next : nil
        case (.inSubgraph(let id1, let a), .inSubgraph(let id2, let b)):
            id1 == id2 ? a.coalesced(with: b).map { .inSubgraph(id: id1, command: $0) } : nil
        case (.batch(let a), .batch(let b)):
            // Same shape, every pair mergeable: a repeated group move, for example.
            a.count == b.count && !a.isEmpty ? merge(a, b) : nil
        default:
            nil
        }
    }
}

private func merge(_ a: [GraphCommand], _ b: [GraphCommand]) -> GraphCommand? {
    var merged: [GraphCommand] = []
    for (first, second) in zip(a, b) {
        guard let command = first.coalesced(with: second) else { return nil }
        merged.append(command)
    }
    return .batch(commands: merged)
}

/// A command that was applied, with what is needed to undo it.
public struct GraphChange: Hashable, Sendable, Codable {
    /// The editor's revision after this change.
    public var revision: Int
    public var command: GraphCommand
    /// Applying this restores the graph to its state before `command`.
    public var inverse: GraphCommand

    public init(revision: Int, command: GraphCommand, inverse: GraphCommand) {
        self.revision = revision
        self.command = command
        self.inverse = inverse
    }

    /// Merges a following change into this one if their commands coalesce. The merged change
    /// does what `next` does and undoes back to the state before `self`.
    public func coalesced(with next: GraphChange) -> GraphChange? {
        command.coalesced(with: next.command).map {
            GraphChange(revision: next.revision, command: $0, inverse: inverse)
        }
    }
}

/// Why a command could not be applied. A failed command leaves the graph unchanged.
public enum GraphEditError: Error, Hashable, Sendable {
    case nodeNotFound(NodeID)
    case linkNotFound(LinkID)
    case groupNotFound(GroupID)
    case duplicateID(String)
    case indexOutOfRange(Int)
    case unknownNodeType(NodeTypeID)
    case unknownProperty(PropertyID)
    case invalidProperty(PropertyID, PropertyValidationError)
    case nonFiniteValue
    /// A group's bounds are not finite or have no positive width and height.
    case invalidGeometry
    /// The node's type has no dynamic port group with this id.
    case unknownPortGroup(String)
    /// The count is outside the group's limits.
    case portCountOutOfRange(group: String, count: Int)
    case subgraphNotFound(SubgraphID)
    /// The subgraph still has instances. Remove them first.
    case subgraphInUse(SubgraphID)
    /// The definition is inconsistent; the strings say how (see ``SubgraphDefinition/problems(nodes:)``).
    case invalidSubgraph([String])
    /// A subgraph command was used somewhere it is not allowed, such as inside another subgraph.
    case invalidScope
    /// The edit would make a subgraph contain an instance of itself, directly or through others.
    /// The ids run around the loop, starting and ending with the same subgraph.
    case recursiveSubgraph([SubgraphID])
    case invalidConnection([GraphDiagnostic])
}
