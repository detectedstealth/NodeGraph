/// The latest values each node published, for watch displays and link tooltips.
///
/// ``ExecutionState`` says how a run went; this says what it produced. Fold each pass's
/// ``TickResult`` in with ``apply(_:)``. A node keeps its values until it is reached again, so a
/// display does not blank between passes, and loses them when a pass leaves it with nothing
/// current to show (it failed, was muted, disabled or cancelled). An `onTrigger` node that did
/// not fire keeps showing its last values, as it keeps publishing them.
///
/// It also remembers why a node has no values: the message of a node that failed, and the reason a
/// node was skipped, so an explanation can say "n20 failed: Division by zero" instead of only
/// "no value". Both follow the values: a node that runs again clears its old failure.
///
/// Only the root graph is covered: nodes inside a subgraph instance are not reported by the
/// runner.
public struct RunValues: Hashable, Sendable {
    public private(set) var nodes: [NodeID: [PortID: GraphValue]] = [:]
    /// The message of each node whose latest pass failed.
    public private(set) var failures: [NodeID: String] = [:]
    /// Why each node whose latest pass was skipped was skipped. A node that did not fire because
    /// it runs only on a trigger is not listed: it keeps its last values.
    public private(set) var skipped: [NodeID: NodeRunResult.SkipReason] = [:]
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
            if case .skipped(.notTriggered) = run.outcome, run.outputs == nil { continue }
            failures[node] = nil
            skipped[node] = nil
            switch run.outcome {
            case .failure(let failure): failures[node] = failure.message
            case .skipped(let reason): skipped[node] = reason
            default: break
            }
            nodes[node] = run.outputs?.values
        }
    }

    /// Forgets nodes that are not in `keeping`, for example after nodes were deleted.
    public mutating func prune(keeping live: Set<NodeID>) {
        nodes = nodes.filter { live.contains($0.key) }
        failures = failures.filter { live.contains($0.key) }
        skipped = skipped.filter { live.contains($0.key) }
    }
}
