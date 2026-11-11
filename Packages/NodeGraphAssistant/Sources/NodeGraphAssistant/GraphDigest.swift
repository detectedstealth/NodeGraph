import NodeGraphCore

/// A compact, stable text form of a graph, a selection or a neighborhood, for a language model
/// (or a person) to read.
///
/// Nodes get short aliases (`n1`, `n2`, ...) numbered in storage order across the whole graph, so
/// an alias means the same node whichever part is shown and however the digest is sized. There
/// are no UUIDs and no layout. Only properties that differ from the definition's default appear.
/// ```
/// nodes:
/// n1 const value=4.0
/// n2 add "Sum" [muted]
/// links:
/// n1.out -> n2.a
/// ```
/// Use ``fitting(tokenBudget:graph:registry:scope:maxDetail:)`` to get the richest form that
/// fits a context budget.
public struct GraphDigest: Sendable {
    /// Which nodes to describe.
    public enum Scope: Sendable {
        /// Every node.
        case all
        /// Exactly these nodes.
        case nodes(Set<NodeID>)
        /// These nodes and everything within `depth` links of them, following links either way.
        case neighborhood(of: Set<NodeID>, depth: Int)
    }

    /// How much to say about each node, least first.
    public enum Detail: Int, Sendable, Comparable, CaseIterable {
        /// Alias and type only, plus links.
        case outline
        /// Adds titles, mode and non-default properties (values cut short).
        case compact
        /// Adds groups, variables and longer values.
        case full

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The digest as text.
    public let text: String
    public let detail: Detail
    /// Nodes in the scope that were left out to respect `maxNodes`.
    public let omittedNodeCount: Int
    /// The nodes the text describes, in order.
    public let shownNodes: [NodeID]

    private let aliasByNode: [NodeID: String]
    private let nodeByAlias: [String: NodeID]

    /// A rough token count: three characters to a token, which errs high for English and code.
    public var estimatedTokens: Int { (text.utf8.count + 2) / 3 }

    /// The alias of a node of the graph this digest was made from.
    public func alias(for node: NodeID) -> String? { aliasByNode[node] }

    /// The node an alias names, for turning a model's answer back into ids.
    public func node(for alias: String) -> NodeID? { nodeByAlias[alias] }

    /// Describes `graph`.
    ///
    /// - Parameter maxNodes: Describe at most this many nodes of the scope, the earliest in storage
    ///   order. The rest are counted in ``omittedNodeCount`` and their links appear as boundary links.
    public init(
        graph: Graph, registry: NodeRegistry, scope: Scope = .all, detail: Detail = .full, maxNodes: Int? = nil
    ) {
        var aliasByNode: [NodeID: String] = [:]
        var nodeByAlias: [String: NodeID] = [:]
        for (index, id) in graph.nodes.keys.enumerated() {
            aliasByNode[id] = "n\(index + 1)"
            nodeByAlias["n\(index + 1)"] = id
        }
        self.aliasByNode = aliasByNode
        self.nodeByAlias = nodeByAlias
        self.detail = detail

        let inScope = Self.nodes(in: scope, of: graph)
        var shown: [NodeID] = graph.nodes.keys.filter(inScope.contains)
        if let maxNodes, shown.count > max(maxNodes, 0) { shown = Array(shown.prefix(max(maxNodes, 0))) }
        omittedNodeCount = inScope.count - shown.count
        shownNodes = shown
        let shownSet = Set(shown)

        var sections: [String] = []
        let nodeLines = shown.compactMap { id in
            graph.nodes[id].map { Self.line(for: $0, alias: aliasByNode[id] ?? "?", registry: registry, detail: detail) }
        }
        if !nodeLines.isEmpty { sections.append(Self.section("nodes", nodeLines)) }

        var inner: [String] = []
        var boundary: [String] = []
        for link in graph.links.values {
            let sourceShown = shownSet.contains(link.source.node), targetShown = shownSet.contains(link.target.node)
            guard sourceShown || targetShown else { continue }
            let text = "\(Self.endpoint(link.source, aliasByNode)) -> \(Self.endpoint(link.target, aliasByNode))"
            if sourceShown && targetShown { inner.append(text) } else { boundary.append(text) }
        }
        if !inner.isEmpty { sections.append(Self.section("links", inner)) }
        if !boundary.isEmpty { sections.append(Self.section("boundary links", boundary)) }

        if detail == .full {
            let groupLines = graph.groups.values.compactMap { group -> String? in
                let members = graph.members(of: group, frame: registry.frame(of:)).filter(shownSet.contains)
                guard !members.isEmpty else { return nil }
                return "\(Self.quote(group.title)): " + members.compactMap { aliasByNode[$0] }.joined(separator: " ")
            }
            if !groupLines.isEmpty { sections.append(Self.section("groups", groupLines)) }
            let variableLines = graph.variables.values.map { variable in
                var text = "\(variable.name) = \(Self.format(variable.value, limit: 60)) (\(variable.type.rawValue))"
                if !variable.summary.isEmpty { text += " - \(variable.summary)" }
                return text
            }
            if !variableLines.isEmpty { sections.append(Self.section("variables", variableLines)) }
        }
        if omittedNodeCount > 0 { sections.append("(\(omittedNodeCount) more nodes not shown)") }
        text = sections.joined(separator: "\n")
    }

    /// The richest digest, no richer than `maxDetail`, that fits `tokenBudget` estimated tokens.
    /// If even the outline is too long, nodes are dropped from the end of the scope until it
    /// fits (see ``omittedNodeCount``); an empty digest is returned if nothing fits.
    public static func fitting(
        tokenBudget: Int, graph: Graph, registry: NodeRegistry, scope: Scope = .all, maxDetail: Detail = .full
    ) -> GraphDigest {
        for detail in Detail.allCases.reversed() where detail <= maxDetail {
            let digest = GraphDigest(graph: graph, registry: registry, scope: scope, detail: detail)
            if digest.estimatedTokens <= tokenBudget { return digest }
        }
        // Longer text for more nodes, so the largest count that fits can be found by bisection.
        var low = 0, high = nodes(in: scope, of: graph).count
        while low < high {
            let middle = (low + high + 1) / 2
            let digest = GraphDigest(graph: graph, registry: registry, scope: scope, detail: .outline, maxNodes: middle)
            if digest.estimatedTokens <= tokenBudget { low = middle } else { high = middle - 1 }
        }
        return GraphDigest(graph: graph, registry: registry, scope: scope, detail: .outline, maxNodes: low)
    }

    // MARK: Pieces

    private static func nodes(in scope: Scope, of graph: Graph) -> Set<NodeID> {
        switch scope {
        case .all:
            return Set(graph.nodes.keys)
        case .nodes(let ids):
            return ids.filter { graph.nodes[$0] != nil }
        case .neighborhood(let seeds, let depth):
            var reached = seeds.filter { graph.nodes[$0] != nil }
            var frontier = reached
            for _ in 0..<max(depth, 0) {
                var next = Set<NodeID>()
                for id in frontier {
                    for link in graph.links(attachedTo: id) {
                        for other in [link.source.node, link.target.node] where reached.insert(other).inserted {
                            next.insert(other)
                        }
                    }
                }
                frontier = next
            }
            return reached
        }
    }

    private static func section(_ title: String, _ lines: [String]) -> String {
        ([title + ":"] + lines).joined(separator: "\n")
    }

    private static func endpoint(_ address: PortAddress, _ aliases: [NodeID: String]) -> String {
        "\(aliases[address.node] ?? "?").\(address.port.rawValue)"
    }

    private static func line(for node: Node, alias: String, registry: NodeRegistry, detail: Detail) -> String {
        let definition = registry.definition(for: node.typeID)
        var parts = [alias, typeName(of: node, definition: definition)]
        guard detail >= .compact else { return parts.joined(separator: " ") }
        if let title = node.title, !title.isEmpty { parts.append(quote(title)) }

        let valueLimit = detail == .full ? 60 : 24
        let declared = definition?.properties ?? []
        let declaredIDs = Set(declared.map(\.id))
        for property in declared {
            guard let value = node.properties[property.id], value != property.defaultValue else { continue }
            parts.append("\(property.id.rawValue)=\(format(value, limit: valueLimit))")
        }
        for (id, value) in node.properties.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !declaredIDs.contains(id) {
            parts.append("\(id.rawValue)=\(format(value, limit: valueLimit))")
        }
        for (group, count) in node.portCounts.sorted(by: { $0.key < $1.key }) { parts.append("\(group)×\(count)") }
        if node.mode != .always { parts.append("[\(node.mode.rawValue)]") }
        if definition == nil && node.typeID.subgraphID == nil { parts.append("[unregistered]") }
        return parts.joined(separator: " ")
    }

    /// The type id, or for a subgraph instance (whose id is a UUID) its name.
    private static func typeName(of node: Node, definition: NodeDefinition?) -> String {
        guard node.typeID.subgraphID != nil else { return node.typeID.rawValue }
        return "subgraph(\(quote(definition?.displayName ?? "unknown")))"
    }

    private static func format(_ value: GraphValue, limit: Int) -> String {
        guard case .string(let text) = value else { return value.summary(limit: limit) }
        let clipped = text.count > limit ? text.prefix(limit - 1) + "…" : text
        return quote(String(clipped))
    }

    private static func quote(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
