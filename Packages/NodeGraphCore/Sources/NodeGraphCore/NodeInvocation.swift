import Foundation

/// A node execution that did not succeed.
public struct NodeFailure: Hashable, Sendable, Codable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// The result of running one node.
public struct NodeRunResult: Hashable, Sendable {
    /// Why a node was not run.
    public enum SkipReason: Hashable, Sendable {
        /// A node feeding it failed, was skipped, or was cancelled.
        case upstreamFailed
    }

    public enum Outcome: Hashable, Sendable {
        case success(NodeOutputs)
        case failure(NodeFailure)
        /// The task was cancelled before or during execution.
        case cancelled
        /// The node was deliberately not run.
        case skipped(SkipReason)
    }

    public var node: NodeID
    public var outcome: Outcome
    /// Wall-clock time spent in the executor.
    public var duration: Duration

    public init(node: NodeID, outcome: Outcome, duration: Duration) {
        self.node = node
        self.outcome = outcome
        self.duration = duration
    }

    /// The outputs if the node succeeded.
    public var outputs: NodeOutputs? {
        if case .success(let outputs) = outcome { outputs } else { nil }
    }
}

/// Runs a single node's executor with timing, cancellation and error capture.
public enum NodeInvocation {
    /// Runs `executor` for the node in `context`. Never throws: errors become a `.failure`
    /// outcome and cancellation becomes `.cancelled`, so one bad node cannot abort a run.
    ///
    /// Outputs for ports the definition does not declare are a failure, which catches typos
    /// in node implementations early.
    public static func run(_ executor: NodeExecutor, context: NodeContext) async -> NodeRunResult {
        guard !Task.isCancelled else {
            return NodeRunResult(node: context.nodeID, outcome: .cancelled, duration: .zero)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome: NodeRunResult.Outcome
        do {
            let outputs = try await executor(context)
            let declared = Set(context.definition.outputs.map(\.id))
            if let stray = outputs.values.keys.sorted().first(where: { !declared.contains($0) }) {
                outcome = .failure(NodeFailure(message: describe(NodeExecutionError.undeclaredOutput(stray))))
            } else {
                outcome = .success(outputs)
            }
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failure(NodeFailure(message: describe(error)))
        }
        return NodeRunResult(node: context.nodeID, outcome: outcome, duration: clock.now - start)
    }

    /// Runs the executor registered for the node's type.
    public static func run(
        node: Node, registry: NodeRegistry, context: NodeContext
    ) async -> NodeRunResult {
        guard let executor = registry.executor(for: node.typeID) else {
            return NodeRunResult(
                node: node.id,
                outcome: .failure(NodeFailure(message: describe(NodeExecutionError.notExecutable(node.typeID)))),
                duration: .zero)
        }
        return await run(executor, context: context)
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }
}
