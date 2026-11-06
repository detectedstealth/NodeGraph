/// A connection from an output port to an input port.
public struct Link: Hashable, Sendable {
    public var id: LinkID
    /// The output port the link starts at (`direction == .output`).
    public var source: PortAddress
    /// The input port the link ends at (`direction == .input`).
    public var target: PortAddress
    /// Points the drawn link passes through between its ends, in order, in graph space. They only
    /// shape how the link is drawn, to route it around nodes; execution ignores them. Edit them with
    /// ``GraphCommand/setLinkWaypoints(link:waypoints:)``.
    public var waypoints: [GraphPoint]

    public init(
        id: LinkID = LinkID(),
        sourceNode: NodeID, sourcePort: PortID,
        targetNode: NodeID, targetPort: PortID,
        waypoints: [GraphPoint] = []
    ) {
        self.id = id
        self.source = PortAddress(node: sourceNode, port: sourcePort, direction: .output)
        self.target = PortAddress(node: targetNode, port: targetPort, direction: .input)
        self.waypoints = waypoints
    }

    /// Whether either end is on `node`.
    public func touches(_ node: NodeID) -> Bool {
        source.node == node || target.node == node
    }
}

extension Link: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, source, target, waypoints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LinkID.self, forKey: .id)
        source = try container.decode(PortAddress.self, forKey: .source)
        target = try container.decode(PortAddress.self, forKey: .target)
        waypoints = try container.decodeIfPresent([GraphPoint].self, forKey: .waypoints) ?? []
    }

    /// Waypoints are omitted when there are none, so links without them keep their original form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(target, forKey: .target)
        if !waypoints.isEmpty { try container.encode(waypoints, forKey: .waypoints) }
    }
}
