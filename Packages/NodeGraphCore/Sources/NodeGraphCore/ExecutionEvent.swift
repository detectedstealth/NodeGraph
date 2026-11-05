/// What happened to a node in one evaluation pass, without its outputs.
public enum NodeRunStatus: Hashable, Sendable, Codable {
    case succeeded
    case failed(message: String)
    case cancelled
    case skipped(NodeRunResult.SkipReason)
    case bypassed
    case cached
}

/// Something that happened during a run, for showing execution state in a UI or log.
///
/// Events carry state, not data: results and outputs come from ``TickResult``. Per pass the order
/// is `passStarted`, then for each node `nodeStarted` (only if it actually runs) and exactly one
/// `nodeFinished`, then `passFinished`. Events of different nodes in one level may interleave.
public enum ExecutionEvent: Hashable, Sendable {
    case passStarted(tick: Int, time: ExecutionTime)
    /// The node's executor is about to run.
    case nodeStarted(node: NodeID, tick: Int)
    case nodeProgress(NodeProgress)
    case nodeFinished(node: NodeID, tick: Int, status: NodeRunStatus, duration: Duration)
    case passFinished(tick: Int, duration: Duration, wasCancelled: Bool)
}

/// The latest known execution state of one node.
public enum NodeRunState: Hashable, Sendable {
    /// No event seen for this node.
    case idle
    /// The executor is running. `progress` is 0...1 once the node has reported any.
    case running(progress: Double?, message: String?)
    case finished(NodeRunStatus, duration: Duration)
}

/// Folds ``ExecutionEvent``s into per-node state, ready to drive a UI.
///
/// A node keeps the state from its last pass until it is reached again, so the canvas does not
/// blank between passes of a continuous run.
public struct ExecutionState: Hashable, Sendable {
    public private(set) var nodes: [NodeID: NodeRunState] = [:]
    /// The tick of the pass in progress or most recently finished.
    public private(set) var tick: Int?
    /// Whether a pass is in progress.
    public private(set) var isRunning = false
    public private(set) var wasCancelled = false

    public init() {}

    public subscript(node: NodeID) -> NodeRunState { nodes[node] ?? .idle }

    public mutating func apply(_ event: ExecutionEvent) {
        switch event {
        case .passStarted(let tick, _):
            self.tick = tick
            isRunning = true
            wasCancelled = false
        case .nodeStarted(let node, _):
            nodes[node] = .running(progress: nil, message: nil)
        case .nodeProgress(let progress):
            if case .running = nodes[progress.node] {
                nodes[progress.node] = .running(progress: progress.fraction, message: progress.message)
            }
        case .nodeFinished(let node, _, let status, let duration):
            nodes[node] = .finished(status, duration: duration)
        case .passFinished(_, _, let cancelled):
            isRunning = false
            wasCancelled = cancelled
        }
    }

    /// Forgets nodes that are not in `keeping`, for example after nodes were deleted.
    public mutating func prune(keeping live: Set<NodeID>) {
        nodes = nodes.filter { live.contains($0.key) }
    }
}
