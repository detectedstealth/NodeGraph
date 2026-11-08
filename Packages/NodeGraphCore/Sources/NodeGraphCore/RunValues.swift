/// The latest values each node published, for watch displays and link tooltips.
///
/// ``ExecutionState`` says how a run went; this says what it produced. Fold each pass's
/// ``TickResult`` in with ``apply(_:)``. A node keeps its values until it is reached again, so a
/// display does not blank between passes, and loses them when a pass leaves it with nothing
/// current to show (it failed, was muted, disabled or cancelled). An `onTrigger` node that did
/// not fire keeps showing its last values, as it keeps publishing them.
///
/// Only the root graph is covered: nodes inside a subgraph instance are not reported by the
/// runner.
public struct RunValues: Hashable, Sendable {
    public private(set) var nodes: [NodeID: [PortID: GraphValue]] = [:]
    /// The tick of the pass most recently applied.
    public private(set) var tick: Int?

    public init() {}

    /// The values a node last published, by port.
    public subscript(node: NodeID) -> [PortID: GraphValue] { nodes[node] ?? [:] }

    /// The value last published at a node's output port, or nil.
    public subscript(node: NodeID, port: PortID) -> GraphValue? { nodes[node]?[port] }

    /// The value last carried by a link: whatever its source port published.
    public func value(of link: Link) -> GraphValue? {
        self[link.source.node, link.source.port]
    }

    public mutating func apply(_ result: TickResult) {
        tick = result.tick
        for (node, run) in result.results {
            if let outputs = run.outputs {
                nodes[node] = outputs.values
            } else if case .skipped(.notTriggered) = run.outcome {
                continue
            } else {
                nodes[node] = nil
            }
        }
    }

    /// Forgets nodes that are not in `keeping`, for example after nodes were deleted.
    public mutating func prune(keeping live: Set<NodeID>) {
        nodes = nodes.filter { live.contains($0.key) }
    }
}
