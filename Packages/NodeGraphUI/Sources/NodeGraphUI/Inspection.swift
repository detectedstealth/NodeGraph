import NodeGraphCore

/// One property of the inspected node: its definition, current value, and whether that is the
/// default.
public struct InspectedProperty: Hashable, Sendable, Identifiable {
    public var id: String { definition.id.rawValue }
    public var definition: PropertyDefinition
    public var spec: NodeWidgetSpec
    public var value: GraphValue
    /// Whether the node has no override, so the value is the definition's default.
    public var isDefault: Bool
}

/// One port of the inspected node.
public struct InspectedPort: Hashable, Sendable, Identifiable {
    public var id: String { "\(definition.direction.rawValue).\(definition.id.rawValue)" }
    public var definition: PortDefinition
    /// The port type's display name, or its id if the type is not registered.
    public var typeName: String
    public var color: RGBAColor
    public var linkCount: Int
}

/// Everything the inspector shows for one selected node.
public struct NodeInspection: Hashable, Sendable {
    public var id: NodeID
    public var typeID: NodeTypeID
    /// The definition's display name; the node's own title replaces it when set.
    public var typeName: String
    public var category: String
    /// The node's own title, or empty when it uses the type's name.
    public var title: String
    public var color: RGBAColor?
    public var mode: NodeMode
    public var isPinned: Bool
    public var isCollapsed: Bool
    public var position: GraphPoint
    public var size: GraphSize
    public var properties: [InspectedProperty]
    public var inputs: [InspectedPort]
    public var outputs: [InspectedPort]
    /// False for a node whose type is not registered: it has no properties or ports to show.
    public var isKnownType: Bool
}

/// What the inspector shows for several selected nodes: only what they can all be set to.
public struct NodesInspection: Hashable, Sendable {
    public var ids: [NodeID]
    /// The mode all share, or nil if they differ.
    public var mode: NodeMode?
    public var isPinned: Bool?
    public var isCollapsed: Bool?
    public var color: RGBAColor?
    public var hasMixedColors: Bool
}

public struct LinkInspection: Hashable, Sendable {
    public var id: LinkID
    /// "Node title · port", for each end.
    public var source: String
    public var target: String
    public var typeName: String
    public var waypointCount: Int
}

public struct GroupInspection: Hashable, Sendable {
    public var id: GroupID
    public var title: String
    public var color: RGBAColor?
    public var bounds: GraphRect
    public var memberCount: Int
}

public struct GraphSummary: Hashable, Sendable {
    public var nodeCount: Int
    public var linkCount: Int
    public var groupCount: Int
}

/// What the inspector is looking at, decided from the selection.
public enum Inspection: Hashable, Sendable {
    case graph(GraphSummary)
    case node(NodeInspection)
    case nodes(NodesInspection)
    case link(LinkInspection)
    case group(GroupInspection)
}

extension GraphEditorModel {
    /// What to show in the inspector for the current selection: one node, several nodes, one
    /// link, one group, or, with nothing selected, a summary of the graph.
    public func inspection() -> Inspection {
        let nodes = graph.nodes.values.filter { selection.nodes.contains($0.id) }
        if nodes.count == 1, let node = nodes.first { return .node(inspect(node)) }
        if nodes.count > 1 { return .nodes(inspect(nodes)) }
        if selection.links.count == 1, let id = selection.links.first, let link = graph.links[id] {
            return .link(inspect(link))
        }
        if selection.groups.count == 1, let id = selection.groups.first, let group = graph.groups[id] {
            return .group(inspect(group))
        }
        return .graph(GraphSummary(nodeCount: graph.nodes.count, linkCount: graph.links.count, groupCount: graph.groups.count))
    }

    private func inspect(_ node: Node) -> NodeInspection {
        let definition = definition(of: node)
        let size = layout(of: node.id)?.frame.size ?? node.size ?? GraphSize(width: 0, height: 0)
        func port(_ port: PortDefinition) -> InspectedPort {
            let address = PortAddress(node: node.id, port: port.id, direction: port.direction)
            let links = port.direction == .input ? graph.links(into: address) : graph.links(from: address)
            return InspectedPort(
                definition: port,
                typeName: port.kind == .trigger ? "Trigger" : editor.types.info(for: port.type)?.displayName ?? port.type.rawValue,
                color: color(of: port), linkCount: links.count)
        }
        return NodeInspection(
            id: node.id, typeID: node.typeID, typeName: definition?.displayName ?? node.typeID.rawValue,
            category: definition?.category ?? "", title: node.title ?? "", color: node.color, mode: node.mode,
            isPinned: node.isPinned, isCollapsed: node.isCollapsed, position: node.position, size: size,
            properties: (definition?.properties ?? []).map { property in
                InspectedProperty(
                    definition: property, spec: NodeWidgetSpec(property),
                    value: node.properties[property.id] ?? property.defaultValue,
                    isDefault: node.properties[property.id] == nil)
            },
            inputs: (definition?.inputs ?? []).map(port), outputs: (definition?.outputs ?? []).map(port),
            isKnownType: definition != nil)
    }

    private func inspect(_ nodes: [Node]) -> NodesInspection {
        func common<T: Equatable>(_ value: (Node) -> T) -> T? {
            guard let first = nodes.first.map(value), nodes.allSatisfy({ value($0) == first }) else { return nil }
            return first
        }
        let colors = Set(nodes.map(\.color))
        return NodesInspection(
            ids: nodes.map(\.id), mode: common(\.mode), isPinned: common(\.isPinned),
            isCollapsed: common(\.isCollapsed), color: colors.count == 1 ? colors.first ?? nil : nil,
            hasMixedColors: colors.count > 1)
    }

    private func inspect(_ link: Link) -> LinkInspection {
        func name(_ address: PortAddress) -> String {
            guard let node = graph.nodes[address.node] else { return address.port.rawValue }
            let title = node.title ?? definition(of: node)?.displayName ?? node.typeID.rawValue
            let port = definition(of: node)?.port(address.port, direction: address.direction)?.displayName ?? address.port.rawValue
            return "\(title) · \(port)"
        }
        let type = layout(of: link.source.node)?.port(link.source)?.definition
        return LinkInspection(
            id: link.id, source: name(link.source), target: name(link.target),
            typeName: type.map { $0.kind == .trigger ? "Trigger" : editor.types.info(for: $0.type)?.displayName ?? $0.type.rawValue } ?? "",
            waypointCount: link.waypoints.count)
    }

    private func inspect(_ group: NodeGroup) -> GroupInspection {
        GroupInspection(
            id: group.id, title: group.title, color: group.color, bounds: group.bounds,
            memberCount: graph.members(of: group, frame: editor.nodes.frame(of:)).count)
    }
}
