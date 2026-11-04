import Collections

/// Nodes, links and groups. A value type with deterministic, insertion-ordered storage.
///
/// Reading is public. Mutation is internal on purpose: outside Core, every change goes
/// through a `GraphCommand` applied by `GraphEditor`, so undo and the change log stay correct.
/// Methods here are primitives and do not enforce connection rules; `ConnectionValidator` does.
public struct Graph: Hashable, Sendable {
    public private(set) var nodes: OrderedDictionary<NodeID, Node> = [:]
    public private(set) var links: OrderedDictionary<LinkID, Link> = [:]
    public private(set) var groups: OrderedDictionary<GroupID, NodeGroup> = [:]

    public init() {}

    // MARK: Queries

    /// Links ending at `node` or starting from it.
    public func links(attachedTo node: NodeID) -> [Link] {
        links.values.filter { $0.touches(node) }
    }

    /// Links that start at the given output port.
    public func links(from source: PortAddress) -> [Link] {
        links.values.filter { $0.source == source }
    }

    /// Links that end at the given input port.
    public func links(into target: PortAddress) -> [Link] {
        links.values.filter { $0.target == target }
    }

    /// Nodes whose frame lies entirely inside the group's bounds, in storage order.
    ///
    /// Membership is derived, never stored, so it follows nodes and groups as they move.
    public func members(of group: NodeGroup, frame: (Node) -> GraphRect) -> [NodeID] {
        nodes.values.filter { group.bounds.contains(frame($0)) }.map(\.id)
    }

    /// Other groups lying entirely inside the group's bounds, in storage order. A group with
    /// identical bounds is not nested, so two coincident groups never move each other.
    public func nestedGroups(in group: NodeGroup) -> [GroupID] {
        groups.values
            .filter { $0.id != group.id && $0.bounds != group.bounds && group.bounds.contains($0.bounds) }
            .map(\.id)
    }

    // MARK: Primitive mutation


    /// Adds a node, or replaces the existing node with the same id in place.
    /// A new node goes at `index`, or at the end when nil. `index` must be in `0...nodes.count`.
    mutating func insert(_ node: Node, at index: Int? = nil) {
        if let index, nodes[node.id] == nil {
            nodes.updateValue(node, forKey: node.id, insertingAt: index)
        } else {
            nodes[node.id] = node
        }
    }

    /// Same placement rules as inserting a node.
    mutating func insert(_ link: Link, at index: Int? = nil) {
        if let index, links[link.id] == nil {
            links.updateValue(link, forKey: link.id, insertingAt: index)
        } else {
            links[link.id] = link
        }
    }

    /// Same placement rules as inserting a node.
    mutating func insert(_ group: NodeGroup, at index: Int? = nil) {
        if let index, groups[group.id] == nil {
            groups.updateValue(group, forKey: group.id, insertingAt: index)
        } else {
            groups[group.id] = group
        }
    }

    /// Removes a node only. Attached links are the caller's responsibility.
    @discardableResult
    mutating func removeNode(_ id: NodeID) -> Node? {
        nodes.removeValue(forKey: id)
    }

    @discardableResult
    mutating func removeLink(_ id: LinkID) -> Link? {
        links.removeValue(forKey: id)
    }

    @discardableResult
    mutating func removeGroup(_ id: GroupID) -> NodeGroup? {
        groups.removeValue(forKey: id)
    }

    /// Applies `change` to a node in place. Returns false if it does not exist.
    @discardableResult
    mutating func updateNode(_ id: NodeID, _ change: (inout Node) -> Void) -> Bool {
        guard nodes[id] != nil else { return false }
        change(&nodes[id]!)
        return true
    }
}

// MARK: - Codable

/// Encodes as plain arrays in storage order, so output is deterministic and diff-friendly.
extension Graph: Codable {
    private enum CodingKeys: String, CodingKey {
        case nodes, links, groups
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for node in try container.decode([Node].self, forKey: .nodes) {
            guard nodes.updateValue(node, forKey: node.id) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nodes, in: container, debugDescription: "Duplicate node id \(node.id)")
            }
        }
        for link in try container.decode([Link].self, forKey: .links) {
            guard links.updateValue(link, forKey: link.id) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .links, in: container, debugDescription: "Duplicate link id \(link.id)")
            }
        }
        for group in try container.decodeIfPresent([NodeGroup].self, forKey: .groups) ?? [] {
            guard groups.updateValue(group, forKey: group.id) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .groups, in: container, debugDescription: "Duplicate group id \(group.id)")
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Array(nodes.values), forKey: .nodes)
        try container.encode(Array(links.values), forKey: .links)
        try container.encode(Array(groups.values), forKey: .groups)
    }
}
