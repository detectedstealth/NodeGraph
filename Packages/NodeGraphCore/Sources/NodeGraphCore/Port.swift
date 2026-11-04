/// Stable name of a port, unique within one node and direction.
///
/// Ports are addressed by this id, never by array index, so links survive port reordering.
public struct PortID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Whether a port receives or produces.
public enum PortDirection: String, Hashable, Sendable, Codable, CaseIterable {
    case input
    case output
}

/// Whether a port carries values or trigger events.
public enum PortKind: String, Hashable, Sendable, Codable, CaseIterable {
    case data
    case trigger
}

/// A specific port on a specific node.
public struct PortAddress: Hashable, Sendable, Codable {
    public var node: NodeID
    public var port: PortID
    public var direction: PortDirection

    public init(node: NodeID, port: PortID, direction: PortDirection) {
        self.node = node
        self.port = port
        self.direction = direction
    }
}
