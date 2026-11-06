import Collections

/// Nodes, links and groups. A value type with deterministic, insertion-ordered storage.
///
/// Reading is public. Mutation is internal on purpose: outside Core, every change goes
/// through a `GraphCommand` applied by `GraphEditor`, so undo and the change log stay correct.
/// Methods here are primitives and do not enforce connection rules; `ConnectionValidator` does.
public struct Graph: Sendable {
    public private(set) var nodes: OrderedDictionary<NodeID, Node> = [:]
    public private(set) var links: OrderedDictionary<LinkID, Link> = [:]
    public private(set) var groups: OrderedDictionary<GroupID, NodeGroup> = [:]

    /// Derived lookups so link queries do not scan every link. Always rebuilt from `links`, never
    /// encoded, and ignored by `==` and `hash`.
    private var linkIDsByTarget: [PortAddress: [LinkID]] = [:]
    private var linkIDsBySource: [PortAddress: [LinkID]] = [:]
    private var linkIDsByNode: [NodeID: [LinkID]] = [:]

    public init() {}

    // MARK: Queries

    /// Links ending at `node` or starting from it, in storage order.
    public func links(attachedTo node: NodeID) -> [Link] {
        resolve(linkIDsByNode[node])
    }

    /// Links that start at the given output port, in storage order.
    public func links(from source: PortAddress) -> [Link] {
        resolve(linkIDsBySource[source])
    }

    /// Links that end at the given input port, in storage order.
    public func links(into target: PortAddress) -> [Link] {
        resolve(linkIDsByTarget[target])
    }

    /// Links that start at any output port of `node`, in storage order.
    public func outgoingLinks(of node: NodeID) -> [Link] {
        links(attachedTo: node).filter { $0.source.node == node }
    }

    private func resolve(_ ids: [LinkID]?) -> [Link] {
        guard let ids, !ids.isEmpty else { return [] }
        if ids.count == 1 { return links[ids[0]].map { [$0] } ?? [] }
        return ids.compactMap { id in links.index(forKey: id).map { ($0, links.values[$0]) } }
            .sorted { $0.0 < $1.0 }.map(\.1)
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
        if let existing = links[link.id] {
            unindex(existing)
            links[link.id] = link
        } else if let index {
            links.updateValue(link, forKey: link.id, insertingAt: index)
        } else {
            links[link.id] = link
        }
        self.index(link)
    }

    private mutating func index(_ link: Link) {
        linkIDsByTarget[link.target, default: []].append(link.id)
        linkIDsBySource[link.source, default: []].append(link.id)
        linkIDsByNode[link.source.node, default: []].append(link.id)
        if link.target.node != link.source.node { linkIDsByNode[link.target.node, default: []].append(link.id) }
    }

    private mutating func unindex(_ link: Link) {
        func drop<K: Hashable>(_ key: K, from table: inout [K: [LinkID]]) {
            guard var ids = table[key], let at = ids.firstIndex(of: link.id) else { return }
            ids.remove(at: at)
            table[key] = ids.isEmpty ? nil : ids
        }
        drop(link.target, from: &linkIDsByTarget)
        drop(link.source, from: &linkIDsBySource)
        drop(link.source.node, from: &linkIDsByNode)
        if link.target.node != link.source.node { drop(link.target.node, from: &linkIDsByNode) }
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
        guard let removed = links.removeValue(forKey: id) else { return nil }
        unindex(removed)
        return removed
    }

    /// Replaces a link's waypoints in place. Returns false if the link does not exist.
    @discardableResult
    mutating func setWaypoints(of id: LinkID, to waypoints: [GraphPoint]) -> Bool {
        guard links[id] != nil else { return false }
        links[id]!.waypoints = waypoints
        return true
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
        for link in links.values { index(link) }
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

// MARK: - Equality

/// Two graphs are equal when their nodes, links and groups are equal and in the same order.
extension Graph: Hashable {
    public static func == (lhs: Graph, rhs: Graph) -> Bool {
        lhs.nodes == rhs.nodes && lhs.links == rhs.links && lhs.groups == rhs.groups
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(nodes)
        hasher.combine(links)
        hasher.combine(groups)
    }
}
