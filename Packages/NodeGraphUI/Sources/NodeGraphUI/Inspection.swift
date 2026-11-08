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
    /// Inside a subgraph: whether the subgraph exposes this property. Nil at the root.
    public var isExposed: Bool?
}

/// One port of the inspected node.
public struct InspectedPort: Hashable, Sendable, Identifiable {
    public var id: String { "\(definition.direction.rawValue).\(definition.id.rawValue)" }
    public var definition: PortDefinition
    /// The port type's display name, or its id if the type is not registered.
    public var typeName: String
    public var color: RGBAColor
    public var linkCount: Int
    /// Inside a subgraph: whether the subgraph exposes this port. Nil at the root.
    public var isExposed: Bool?
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
    /// The node's own outline, or nil when it uses its type's.
    public var shape: NodeShape?
    /// The node's own title bar style, or nil when it uses its type's.
    public var titleMode: NodeTitleMode?
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

/// One exposed input, output or property of the subgraph being edited.
public struct InterfaceEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    /// The type's name, or the kind of property.
    public var typeName: String
    public var color: RGBAColor?
    /// What it connects to inside, in words: "feeds Add · a".
    public var detail: String
    public var canMoveUp: Bool
    public var canMoveDown: Bool
}

/// The subgraph being edited, as the inspector shows it when nothing inside is selected.
public struct SubgraphInspection: Hashable, Sendable {
    public var id: SubgraphID
    public var name: String
    public var category: String
    public var inputs: [InterfaceEntry]
    public var outputs: [InterfaceEntry]
    public var properties: [InterfaceEntry]
    /// How many nodes, in the document, are instances of it.
    public var instanceCount: Int
    /// The inner graph, counted.
    public var summary: GraphSummary
}

/// What the inspector is looking at, decided from the selection.
public enum Inspection: Hashable, Sendable {
    case graph(GraphSummary)
    /// Nothing selected while editing inside a subgraph: its name and interface.
    case subgraph(SubgraphInspection)
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
        let summary = GraphSummary(nodeCount: graph.nodes.count, linkCount: graph.links.count, groupCount: graph.groups.count)
        if let scope = currentScope, let definition = editor.subgraphs[scope] {
            return .subgraph(inspect(definition, summary: summary))
        }
        return .graph(summary)
    }

    private func inspect(_ subgraph: SubgraphDefinition, summary: GraphSummary) -> SubgraphInspection {
        let interface = subgraph.interface
        func name(of node: NodeID) -> String {
            guard let node = graph.nodes[node] else { return "missing node" }
            return node.title ?? definition(of: node)?.displayName ?? node.typeID.rawValue
        }
        func port(_ address: PortAddress) -> String {
            let displayName = graph.nodes[address.node].flatMap { self.definition(of: $0) }?
                .port(address.port, direction: address.direction)?.displayName ?? address.port.rawValue
            return "\(name(of: address.node)) · \(displayName)"
        }
        func typeName(_ type: PortType, _ kind: PortKind) -> String {
            kind == .trigger ? "Trigger" : editor.types.info(for: type)?.displayName ?? type.rawValue
        }
        func entries<T>(_ items: [T], _ make: (T) -> (String, String, String, RGBAColor?, String)) -> [InterfaceEntry] {
            items.enumerated().map { index, item in
                let (id, displayName, typeName, color, detail) = make(item)
                return InterfaceEntry(
                    id: id, displayName: displayName, typeName: typeName, color: color, detail: detail,
                    canMoveUp: index > 0, canMoveDown: index < items.count - 1)
            }
        }
        let instances = (graph(of: nil) + editor.subgraphs.values.map(\.graph)).reduce(0) { total, graph in
            total + graph.nodes.values.filter { $0.typeID == subgraph.typeID }.count
        }
        return SubgraphInspection(
            id: subgraph.id, name: interface.name, category: interface.category,
            inputs: entries(interface.inputs) {
                ($0.id.rawValue, $0.displayName, typeName($0.type, $0.kind), editor.types.info(for: $0.type)?.color,
                 $0.targets.isEmpty ? "feeds nothing" : "feeds " + $0.targets.map(port).joined(separator: ", "))
            },
            outputs: entries(interface.outputs) {
                ($0.id.rawValue, $0.displayName, typeName($0.type, $0.kind), editor.types.info(for: $0.type)?.color,
                 $0.source.map { "from " + port($0) } ?? "not connected")
            },
            properties: entries(interface.properties) {
                ($0.id.rawValue, $0.displayName, NodeWidgetSpec(PropertyDefinition(
                    id: $0.id, displayName: $0.displayName, kind: $0.kind, defaultValue: $0.defaultValue)).kind.label, nil,
                 $0.targets.isEmpty ? "sets nothing" : "sets " + $0.targets.map { "\(name(of: $0.node)) · \($0.property.rawValue)" }.joined(separator: ", "))
            },
            instanceCount: instances, summary: summary)
    }

    /// The root graph when `scope` is nil, else that subgraph's inner graph, as a plain value.
    private func graph(of scope: SubgraphID?) -> [Graph] {
        [editor.editedGraph(in: scope) ?? editor.graph]
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
                color: color(of: port), linkCount: links.count,
                isExposed: port.direction == .input ? isExposed(input: address) : isExposed(output: address))
        }
        return NodeInspection(
            id: node.id, typeID: node.typeID, typeName: definition?.displayName ?? node.typeID.rawValue,
            category: definition?.category ?? "", title: node.title ?? "", color: node.color, mode: node.mode,
            shape: node.shape, titleMode: node.titleMode, isPinned: node.isPinned, isCollapsed: node.isCollapsed, position: node.position, size: size,
            properties: (definition?.properties ?? []).map { property in
                InspectedProperty(
                    definition: property, spec: NodeWidgetSpec(property),
                    value: node.properties[property.id] ?? property.defaultValue,
                    isDefault: node.properties[property.id] == nil,
                    isExposed: isExposed(property: PropertyTarget(node: node.id, property: property.id)))
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
