import Collections
import Logging

/// How ``GraphRunner/run(_:)`` drives evaluation.
public enum RunMode: Sendable {
    /// Evaluate once and finish.
    case once
    /// Evaluate repeatedly, aiming to start a pass every `interval`, until cancelled. Results
    /// are dropped if the consumer falls behind; only the newest is kept.
    case continuous(interval: Duration)
    /// Evaluate when ``GraphRunner/requestEvaluation()`` is called, until cancelled. Requests
    /// made while a pass is running collapse into one follow-up pass.
    case eventDriven
    /// Evaluate `ticks` times as fast as possible with simulated time advancing by `fixedDelta`
    /// per tick. Nodes run one at a time in plan order, so a run is exactly reproducible.
    /// For robotics simulation and tests.
    case deterministic(fixedDelta: Duration, ticks: Int)
}

/// The outcome of one evaluation of the whole graph.
public struct TickResult: Hashable, Sendable {
    /// Evaluation count, starting at 0.
    public var tick: Int
    public var time: ExecutionTime
    /// One result per node, in execution order. Nodes not reached because the run was
    /// cancelled are reported as `.cancelled`.
    public var results: OrderedDictionary<NodeID, NodeRunResult>
    /// Wall-clock time for the whole pass.
    public var duration: Duration
    public var wasCancelled: Bool

    /// The outputs a node produced, if it succeeded.
    public func outputs(of node: NodeID) -> NodeOutputs? {
        results[node]?.outputs
    }

    /// Nodes that threw an error.
    public var failedNodes: [NodeID] {
        results.values.compactMap { if case .failure = $0.outcome { $0.node } else { nil } }
    }

    /// Whether every node succeeded.
    public var succeeded: Bool {
        results.values.allSatisfy { if case .success = $0.outcome { true } else { false } }
    }
}

/// Evaluates a graph. An actor, so it can run alongside an editor and the UI.
///
/// Each evaluation pass ("tick") runs every node once in the order given by an
/// ``ExecutionPlan``. Nodes in the same plan level run concurrently, except in deterministic
/// mode. A node's inputs come from the outputs of the nodes linked to it in the same pass; a
/// link leaving a feedback node delivers that node's output from the *previous* pass. An input
/// with several links receives their values as an `.array`, in link order. A trigger input fires
/// when any linked trigger output fired in the same pass (or the previous one, for a feedback
/// link); triggers carry events, never values. A node whose upstream
/// failed is skipped, and a failing node does not stop the rest of the graph.
///
/// The runner works on its own copy of the graph; call ``update(graph:registry:)`` to change it.
public actor GraphRunner {
    private struct InputBinding: Sendable {
        struct Source: Sendable {
            var node: NodeID
            var port: PortID
            var isFeedback: Bool
        }
        var port: PortID
        var kind: PortKind
        var sources: [Source]
        var isMultiple: Bool
    }

    private struct Snapshot: Sendable {
        var graph: Graph
        var registry: NodeRegistry
        var plan: ExecutionPlan
        var bindings: [NodeID: [InputBinding]]
        var feedbackSources: Set<NodeID>
    }

    private var snapshot: Snapshot
    private let services: ServiceContainer
    private let logger: Logger
    private let onProgress: @Sendable (NodeProgress) -> Void

    private var tickCount = 0
    /// Outputs of feedback nodes from the last pass that produced them.
    private var feedbackOutputs: [NodeID: NodeOutputs] = [:]
    private var lastTickStart: ContinuousClock.Instant?
    private var runStart: ContinuousClock.Instant?
    private var inFlight: Task<TickResult, Never>?

    private let requests: AsyncStream<Void>
    private let requestContinuation: AsyncStream<Void>.Continuation

    /// - Throws: ``ExecutionPlanError`` if the graph has a cycle no feedback node breaks.
    public init(
        graph: Graph,
        registry: NodeRegistry,
        services: ServiceContainer = ServiceContainer(),
        logger: Logger = Logger(label: "NodeGraph.runner"),
        onProgress: @escaping @Sendable (NodeProgress) -> Void = { _ in }
    ) throws {
        snapshot = try Self.makeSnapshot(graph: graph, registry: registry)
        self.services = services
        self.logger = logger
        self.onProgress = onProgress
        (requests, requestContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// The number of passes completed since creation or the last ``reset()``.
    public var completedTicks: Int { tickCount }

    /// Replaces the graph and registry, recompiling the plan. Feedback values of nodes that
    /// still exist are kept. A pass already running finishes on the old graph.
    ///
    /// - Throws: ``ExecutionPlanError``; the runner keeps its previous graph in that case.
    public func update(graph: Graph, registry: NodeRegistry) throws {
        snapshot = try Self.makeSnapshot(graph: graph, registry: registry)
        feedbackOutputs = feedbackOutputs.filter { snapshot.feedbackSources.contains($0.key) }
    }

    /// Forgets the tick count, feedback values and run clock, as if freshly created.
    public func reset() {
        tickCount = 0
        feedbackOutputs = [:]
        lastTickStart = nil
        runStart = nil
    }

    /// Asks an event-driven run to evaluate. Cheap and safe from anywhere.
    public nonisolated func requestEvaluation() {
        requestContinuation.yield()
    }

    // MARK: Driving

    /// Evaluates the whole graph once, in real time. Use it to step through a run by hand.
    ///
    /// Calls are serialized: if a pass is running, this one starts after it.
    public func step() async -> TickResult {
        await serialized(fixedDelta: nil)
    }

    /// Starts a run in the given mode and streams one ``TickResult`` per pass. Cancel by
    /// cancelling the consuming task or ending the stream.
    public nonisolated func run(_ mode: RunMode) -> AsyncStream<TickResult> {
        let policy: AsyncStream<TickResult>.Continuation.BufferingPolicy
        switch mode {
        case .once, .deterministic: policy = .unbounded
        case .continuous, .eventDriven: policy = .bufferingNewest(1)
        }
        return AsyncStream(bufferingPolicy: policy) { continuation in
            let task = Task { await self.drive(mode, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func drive(_ mode: RunMode, into continuation: AsyncStream<TickResult>.Continuation) async {
        switch mode {
        case .once:
            continuation.yield(await step())

        case .continuous(let interval):
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let started = clock.now
                continuation.yield(await step())
                let remaining = interval - (clock.now - started)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
            }

        case .eventDriven:
            for await _ in requests {
                if Task.isCancelled { break }
                continuation.yield(await step())
            }

        case .deterministic(let fixedDelta, let ticks):
            for _ in 0..<max(ticks, 0) {
                if Task.isCancelled { break }
                continuation.yield(await serialized(fixedDelta: fixedDelta))
            }
        }
        continuation.finish()
    }

    // MARK: One pass

    /// Queues a pass behind any pass already running, so passes never overlap even though the
    /// actor is re-entered while nodes are awaited.
    private func serialized(fixedDelta: Duration?) async -> TickResult {
        let previous = inFlight
        let task = Task { [self] () -> TickResult in
            _ = await previous?.value
            return await evaluate(fixedDelta: fixedDelta)
        }
        inFlight = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func evaluate(fixedDelta: Duration?) async -> TickResult {
        let clock = ContinuousClock()
        let started = clock.now
        let tick = tickCount

        let time: ExecutionTime
        if let fixedDelta {
            time = ExecutionTime(tick: tick, elapsed: fixedDelta * tick, delta: fixedDelta)
        } else {
            let runStart = runStart ?? started
            self.runStart = runStart
            time = ExecutionTime(
                tick: tick, elapsed: started - runStart,
                delta: lastTickStart.map { started - $0 } ?? .zero)
            lastTickStart = started
        }

        let snapshot = snapshot
        let (results, wasCancelled) = await runNodes(
            snapshot, time: time, sequential: fixedDelta != nil, feedback: feedbackOutputs)

        for source in snapshot.feedbackSources {
            if let outputs = results[source]?.outputs { feedbackOutputs[source] = outputs }
        }
        tickCount += 1
        return TickResult(
            tick: tick, time: time, results: results,
            duration: clock.now - started, wasCancelled: wasCancelled)
    }

    private func runNodes(
        _ snapshot: Snapshot, time: ExecutionTime, sequential: Bool, feedback: [NodeID: NodeOutputs]
    ) async -> (OrderedDictionary<NodeID, NodeRunResult>, Bool) {
        var results = OrderedDictionary<NodeID, NodeRunResult>()
        var outputs: [NodeID: NodeOutputs] = [:]
        var unusable = Set<NodeID>()   // failed, skipped or cancelled this pass
        var wasCancelled = false

        for level in snapshot.plan.levels {
            if Task.isCancelled { wasCancelled = true }
            if wasCancelled {
                for id in level { results[id] = NodeRunResult(node: id, outcome: .cancelled, duration: .zero) }
                continue
            }

            // Decide which nodes run and build their contexts before any suspension.
            var jobs: [(index: Int, executor: NodeExecutor, context: NodeContext)] = []
            var levelResults = [NodeRunResult?](repeating: nil, count: level.count)
            for (index, id) in level.enumerated() {
                let bindings = snapshot.bindings[id] ?? []
                if bindings.contains(where: { $0.sources.contains { !$0.isFeedback && unusable.contains($0.node) } }) {
                    levelResults[index] = NodeRunResult(node: id, outcome: .skipped(.upstreamFailed), duration: .zero)
                    continue
                }
                guard let node = snapshot.graph.nodes[id],
                      let definition = snapshot.registry.definition(for: node.typeID),
                      let executor = snapshot.registry.executor(for: node.typeID) else {
                    let type = snapshot.graph.nodes[id]?.typeID ?? ""
                    levelResults[index] = NodeRunResult(
                        node: id,
                        outcome: .failure(NodeFailure(message: "\(NodeExecutionError.notExecutable(type))")),
                        duration: .zero)
                    continue
                }
                let resolved = Self.resolveInputs(bindings, outputs: outputs, feedback: feedback)
                let context = NodeContext(
                    node: node, definition: definition,
                    linkedInputs: resolved.values, triggered: resolved.triggered,
                    time: time, services: services, logger: logger, onProgress: onProgress)
                jobs.append((index, executor, context))
            }

            if sequential || jobs.count < 2 {
                for job in jobs {
                    levelResults[job.index] = await NodeInvocation.run(job.executor, context: job.context)
                }
            } else {
                await withTaskGroup(of: (Int, NodeRunResult).self) { group in
                    for job in jobs {
                        group.addTask { (job.index, await NodeInvocation.run(job.executor, context: job.context)) }
                    }
                    for await (index, result) in group { levelResults[index] = result }
                }
            }

            for (index, id) in level.enumerated() {
                let result = levelResults[index]!
                results[id] = result
                if let produced = result.outputs { outputs[id] = produced } else { unusable.insert(id) }
                if case .cancelled = result.outcome { wasCancelled = true }
            }
        }
        return (results, wasCancelled)
    }

    /// Values and fired triggers for a node's inputs: from this pass's outputs, or last pass's for
    /// feedback links.
    private static func resolveInputs(
        _ bindings: [InputBinding], outputs: [NodeID: NodeOutputs], feedback: [NodeID: NodeOutputs]
    ) -> (values: [PortID: GraphValue], triggered: Set<PortID>) {
        var values: [PortID: GraphValue] = [:]
        var triggered = Set<PortID>()
        for binding in bindings {
            func produced(_ source: InputBinding.Source) -> NodeOutputs? {
                source.isFeedback ? feedback[source.node] : outputs[source.node]
            }
            if binding.kind == .trigger {
                if binding.sources.contains(where: { produced($0)?.triggers.contains($0.port) == true }) {
                    triggered.insert(binding.port)
                }
                continue
            }
            let linked = binding.sources.compactMap { produced($0)?.values[$0.port] }
            if binding.isMultiple {
                if !linked.isEmpty { values[binding.port] = .array(linked) }
            } else if let value = linked.first {
                values[binding.port] = value
            }
        }
        return (values, triggered)
    }

    private static func makeSnapshot(graph: Graph, registry: NodeRegistry) throws -> Snapshot {
        let plan = try ExecutionPlan.compile(graph, nodes: registry)
        let feedbackLinks = Set(plan.feedbackLinks)

        var linksByTarget: [PortAddress: [Link]] = [:]
        for link in graph.links.values { linksByTarget[link.target, default: []].append(link) }

        var bindings: [NodeID: [InputBinding]] = [:]
        for node in graph.nodes.values {
            guard let definition = registry.definition(for: node.typeID) else { continue }
            for port in definition.inputs {
                let address = PortAddress(node: node.id, port: port.id, direction: .input)
                guard let links = linksByTarget[address], !links.isEmpty else { continue }
                bindings[node.id, default: []].append(InputBinding(
                    port: port.id,
                    kind: port.kind,
                    sources: links.map {
                        .init(node: $0.source.node, port: $0.source.port, isFeedback: feedbackLinks.contains($0.id))
                    },
                    isMultiple: port.allowsMultipleLinks))
            }
        }
        let feedbackSources = Set(graph.links.values.filter { feedbackLinks.contains($0.id) }.map(\.source.node))
        return Snapshot(
            graph: graph, registry: registry, plan: plan, bindings: bindings, feedbackSources: feedbackSources)
    }
}
