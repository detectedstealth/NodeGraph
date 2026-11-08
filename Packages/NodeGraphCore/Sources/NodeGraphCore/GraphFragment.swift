import Foundation

/// A piece of a graph, cut out so it can be pasted again: some nodes, the links among them,
/// some groups, and the subgraph definitions the nodes are instances of.
///
/// Plain `Codable` data with its own file form, so it can travel through a clipboard, between
/// documents and windows, or from a tool that builds graphs. Nothing in it refers to the graph it
/// came from; pasting gives everything fresh ids.
public struct GraphFragment: Hashable, Sendable, Codable {
    /// Marks the file form, so unrelated JSON is not mistaken for a fragment.
    public static let kind = "nodegraph.fragment"
    public static let currentVersion = 1

    public var schemaVersion: Int
    public var nodes: [Node]
    /// Links with both ends among ``nodes``.
    public var links: [Link]
    /// Links that fed ``nodes`` from nodes outside the fragment, as they were in the graph it was
    /// cut from. Only ``GraphEditor/pasteCommand(_:translatedBy:in:keepingConnections:)`` with
    /// `keepingConnections` uses them, and only for sources that exist where it pastes.
    public var inputLinks: [Link]
    public var groups: [NodeGroup]
    /// Definitions of the subgraphs that ``nodes`` are instances of, and of the subgraphs those
    /// contain, each after the ones it depends on.
    public var subgraphs: [SubgraphDefinition]

    public init(
        nodes: [Node] = [], links: [Link] = [], inputLinks: [Link] = [], groups: [NodeGroup] = [],
        subgraphs: [SubgraphDefinition] = []
    ) {
        schemaVersion = Self.currentVersion
        self.nodes = nodes
        self.links = links
        self.inputLinks = inputLinks
        self.groups = groups
        self.subgraphs = subgraphs
    }

    public var isEmpty: Bool { nodes.isEmpty && groups.isEmpty }

    /// The smallest rectangle holding every node and group, or nil if there are none.
    /// `frame` gives a node's frame, normally ``NodeRegistry/frame(of:)``.
    public func bounds(frame: (Node) -> GraphRect) -> GraphRect? {
        let rects = nodes.map(frame) + groups.map(\.bounds)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { union, rect in
            let minX = Swift.min(union.minX, rect.minX), minY = Swift.min(union.minY, rect.minY)
            return GraphRect(
                x: minX, y: minY, width: Swift.max(union.maxX, rect.maxX) - minX,
                height: Swift.max(union.maxY, rect.maxY) - minY)
        }
    }

    // MARK: File form

    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion, nodes, links, inputLinks, groups, subgraphs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == Self.kind else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Not a graph fragment")
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "Fragment version \(schemaVersion) is newer than this app understands")
        }
        nodes = try container.decode([Node].self, forKey: .nodes)
        links = try container.decodeIfPresent([Link].self, forKey: .links) ?? []
        inputLinks = try container.decodeIfPresent([Link].self, forKey: .inputLinks) ?? []
        groups = try container.decodeIfPresent([NodeGroup].self, forKey: .groups) ?? []
        subgraphs = try container.decodeIfPresent([SubgraphDefinition].self, forKey: .subgraphs) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(links, forKey: .links)
        if !inputLinks.isEmpty { try container.encode(inputLinks, forKey: .inputLinks) }
        try container.encode(groups, forKey: .groups)
        if !subgraphs.isEmpty { try container.encode(subgraphs, forKey: .subgraphs) }
    }

    /// The fragment as JSON, with sorted keys so the same fragment always gives the same text.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Reads a fragment, throwing if the data is not one.
    public static func decode(from data: Data) throws -> GraphFragment {
        try JSONDecoder().decode(GraphFragment.self, from: data)
    }
}

/// What ``GraphEditor/pasteCommand(_:translatedBy:in:)`` made: the command, and the ids of the
/// new nodes and groups so a caller can select them.
public struct GraphPaste: Sendable {
    public var command: GraphCommand
    public var nodes: [NodeID]
    public var groups: [GroupID]
}

extension GraphEditor {
    /// Cuts the given nodes and groups out of the graph edited in `scope` as a fragment. Links
    /// are kept only when both ends are among the nodes. Throws if an id is not in the graph.
    public func fragment(
        nodes nodeIDs: some Collection<NodeID>, groups groupIDs: [GroupID] = [],
        in scope: SubgraphID? = nil
    ) throws -> GraphFragment {
        guard let source = editedGraph(in: scope) else { throw GraphEditError.subgraphNotFound(scope!) }
        let wanted = Set(nodeIDs)
        var nodes: [Node] = []
        for node in source.nodes.values where wanted.contains(node.id) { nodes.append(node) }
        if let missing = wanted.subtracting(nodes.map(\.id)).first { throw GraphEditError.nodeNotFound(missing) }
        let links = source.links.values.filter { wanted.contains($0.source.node) && wanted.contains($0.target.node) }
        let inputLinks = source.links.values.filter { wanted.contains($0.target.node) && !wanted.contains($0.source.node) }
        let wantedGroups = Set(groupIDs)
        let groups = source.groups.values.filter { wantedGroups.contains($0.id) }
        if let missing = wantedGroups.subtracting(groups.map(\.id)).first { throw GraphEditError.groupNotFound(missing) }
        return GraphFragment(nodes: nodes, links: Array(links), inputLinks: Array(inputLinks), groups: Array(groups), subgraphs: definitions(used: nodes))
    }

    /// The definitions of the subgraphs `nodes` are instances of, and of those they contain, with
    /// each definition after the ones it depends on.
    private func definitions(used nodes: [Node]) -> [SubgraphDefinition] {
        var ordered: [SubgraphDefinition] = []
        var seen = Set<SubgraphID>()
        func visit(_ id: SubgraphID) {
            guard seen.insert(id).inserted, let definition = subgraphs[id] else { return }
            for dependency in definition.directDependencies.sorted() { visit(dependency) }
            ordered.append(definition)
        }
        for node in nodes { if let id = node.typeID.subgraphID { visit(id) } }
        return ordered
    }

    /// The node types in `fragment` that this editor cannot create: not registered, and not an
    /// instance of a subgraph the fragment brings along.
    public func missingNodeTypes(in fragment: GraphFragment) -> [NodeTypeID] {
        let provided = Set(fragment.subgraphs.map(\.typeID))
        var missing: [NodeTypeID] = []
        for node in fragment.nodes
        where nodes.definition(for: node.typeID) == nil && !provided.contains(node.typeID) && !missing.contains(node.typeID) {
            missing.append(node.typeID)
        }
        return missing
    }

    /// The command that pastes `fragment` into the graph edited in `scope`, every node, link and
    /// group moved by `delta` and given a new id. Subgraph definitions the document lacks are added
    /// first; one it already has (by id) is used as it is.
    ///
    /// The command is complete as it is: it already places the paste inside `scope`, so apply it
    /// as it comes, not wrapped in ``GraphCommand/inSubgraph(id:command:)`` again. Throws
    /// `unknownNodeType` if the fragment has a node this editor cannot create.
    ///
    /// With `keepingConnections`, each pasted node is also linked again to the outside nodes that
    /// fed the original, where those nodes exist in `scope` and the connection rules allow it;
    /// the others are left unlinked.
    public func pasteCommand(
        _ fragment: GraphFragment, translatedBy delta: GraphPoint = .zero, in scope: SubgraphID? = nil,
        keepingConnections: Bool = false
    ) throws -> GraphPaste {
        guard editedGraph(in: scope) != nil else { throw GraphEditError.subgraphNotFound(scope!) }
        if let missing = missingNodeTypes(in: fragment).first { throw GraphEditError.unknownNodeType(missing) }

        func moved(_ point: GraphPoint) -> GraphPoint { GraphPoint(x: point.x + delta.x, y: point.y + delta.y) }
        var nodeIDs: [NodeID: NodeID] = [:]
        var inner: [GraphCommand] = []
        for var node in fragment.nodes {
            let new = NodeID()
            nodeIDs[node.id] = new
            node.id = new
            node.position = moved(node.position)
            inner.append(.addNode(node: node))
        }
        for var link in fragment.links {
            guard let source = nodeIDs[link.source.node], let target = nodeIDs[link.target.node] else { continue }
            link = Link(
                sourceNode: source, sourcePort: link.source.port, targetNode: target, targetPort: link.target.port,
                waypoints: link.waypoints.map(moved))
            inner.append(.addLink(link: link))
        }
        if keepingConnections, var scratch = editedGraph(in: scope) {
            // Check against a copy holding the paste so far, so two restored links to one
            // single-link port, or one that closes a cycle, are caught.
            for case .addNode(let node, _) in inner { scratch.insert(node) }
            for case .addLink(let link, _) in inner { scratch.insert(link) }
            for old in fragment.inputLinks {
                guard let target = nodeIDs[old.target.node], scratch.nodes[old.source.node] != nil else { continue }
                let proposal = ConnectionProposal(
                    source: old.source, target: PortAddress(node: target, port: old.target.port, direction: .input))
                let check = connectionValidator.check(
                    proposal, in: ValidationContext(graph: scratch, nodes: nodes, types: types))
                guard check.isAllowed, check.replacedLinks.isEmpty else { continue }
                let link = Link(
                    sourceNode: old.source.node, sourcePort: old.source.port,
                    targetNode: target, targetPort: old.target.port, waypoints: [])
                scratch.insert(link)
                inner.append(.addLink(link: link))
            }
        }
        var groupIDs: [GroupID] = []
        for var group in fragment.groups {
            group.id = GroupID()
            group.bounds.origin = moved(group.bounds.origin)
            groupIDs.append(group.id)
            inner.append(.addGroup(group: group))
        }

        let newDefinitions = fragment.subgraphs.filter { subgraphs[$0.id] == nil }.map { GraphCommand.addSubgraph(definition: $0) }
        let placement = GraphCommand.batch(commands: inner)
        let scoped = scope.map { GraphCommand.inSubgraph(id: $0, command: placement) } ?? placement
        let command = newDefinitions.isEmpty ? scoped : .batch(commands: newDefinitions + [scoped])
        return GraphPaste(command: command, nodes: fragment.nodes.compactMap { nodeIDs[$0.id] }, groups: groupIDs)
    }
}
