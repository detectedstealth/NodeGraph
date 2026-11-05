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
        /// A node feeding it failed, was cancelled, or was itself skipped for that reason.
        case upstreamFailed
        /// A node feeding it is switched off (mode `never`), or was skipped because of one.
        case upstreamDisabled
        /// The node's mode is `never`.
        case disabled
        /// The node's mode is `muted`. It publishes no outputs, and nodes after it still run.
        case muted
        /// The node's mode is `onTrigger` and no trigger input fired. It keeps publishing the
        /// outputs of its last run.
        case notTriggered
    }

    public enum Outcome: Hashable, Sendable {
        case success(NodeOutputs)
        case failure(NodeFailure)
        /// The task was cancelled before or during execution.
        case cancelled
        /// The node was deliberately not run.
        case skipped(SkipReason)
        /// The node's mode is `bypassed`: its inputs were passed through to matching outputs.
        case bypassed(NodeOutputs)
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

    /// The outputs if the node ran or was bypassed.
    public var outputs: NodeOutputs? {
        switch outcome {
        case .success(let outputs), .bypassed(let outputs): outputs
        default: nil
        }
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
            if let problem = outputProblem(outputs, in: context.definition) {
                outcome = .failure(NodeFailure(message: describe(problem)))
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

    /// Values must go to declared data outputs and triggers to declared trigger outputs.
    private static func outputProblem(_ outputs: NodeOutputs, in definition: NodeDefinition) -> NodeExecutionError? {
        let declared = Dictionary(definition.outputs.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        for port in outputs.values.keys.sorted() {
            guard let kind = declared[port] else { return .undeclaredOutput(port) }
            if kind != .data { return .wrongPortKind(port) }
        }
        for port in outputs.triggers.sorted() {
            guard let kind = declared[port] else { return .undeclaredOutput(port) }
            if kind != .trigger { return .wrongPortKind(port) }
        }
        return nil
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }
}
