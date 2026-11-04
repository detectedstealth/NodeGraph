/// A connection from an output port to an input port.
public struct Link: Hashable, Sendable, Codable {
    public var id: LinkID
    /// The output port the link starts at (`direction == .output`).
    public var source: PortAddress
    /// The input port the link ends at (`direction == .input`).
    public var target: PortAddress

    public init(
        id: LinkID = LinkID(),
        sourceNode: NodeID, sourcePort: PortID,
        targetNode: NodeID, targetPort: PortID
    ) {
        self.id = id
        self.source = PortAddress(node: sourceNode, port: sourcePort, direction: .output)
        self.target = PortAddress(node: targetNode, port: targetPort, direction: .input)
    }

    /// Whether either end is on `node`.
    public func touches(_ node: NodeID) -> Bool {
        source.node == node || target.node == node
    }
}
