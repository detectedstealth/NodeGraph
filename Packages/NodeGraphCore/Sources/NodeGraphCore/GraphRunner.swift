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

    /// Nodes served from the cache instead of running.
    public var cachedNodes: [NodeID] {
        results.values.compactMap { if case .cached = $0.outcome { $0.node } else { nil } }
    }

    /// Whether every node ran successfully (or was served from the cache).
    public var succeeded: Bool {
        results.values.allSatisfy {
            switch $0.outcome {
            case .success, .cached: true
            default: false
            }
        }
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
    private struct CacheKey: Hashable, Sendable {
        var inputs: [PortID: GraphValue]
        var triggered: Set<PortID>
        var properties: [PropertyID: GraphValue]
    }

    private struct CacheEntry: Sendable {
        var key: CacheKey
        var outputs: NodeOutputs
    }

    private let cachingEnabled: Bool
    /// Outputs of pure nodes with the exact inputs that produced them.
    private var cache: [NodeID: CacheEntry] = [:]
    /// Last data outputs of `onTrigger` nodes, published again on passes where they don't run.
    private var heldOutputs: [NodeID: NodeOutputs] = [:]
    private var lastTickStart: ContinuousClock.Instant?
    private var runStart: ContinuousClock.Instant?
    private var inFlight: Task<TickResult, Never>?

    private let eventBroadcaster = Broadcaster<ExecutionEvent>()

    private let requests: AsyncStream<Void>
    private let requestContinuation: AsyncStream<Void>.Continuation

    /// - Throws: ``ExecutionPlanError`` if the graph has a cycle no feedback node breaks.
    public init(
        graph: Graph,
        registry: NodeRegistry,
        services: ServiceContainer = ServiceContainer(),
        logger: Logger = Logger(label: "NodeGraph.runner"),
        caching: Bool = true,
        onProgress: @escaping @Sendable (NodeProgress) -> Void = { _ in }
    ) throws {
        cachingEnabled = caching
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
        let previous = snapshot
        snapshot = try Self.makeSnapshot(graph: graph, registry: registry)
        // Cached outputs stay valid only for nodes whose type definition is unchanged. Executors
        // are code and cannot be compared; after swapping one, call `invalidateAll()`.
        cache = cache.filter { id, _ in
            guard let node = graph.nodes[id], let old = previous.graph.nodes[id], node.typeID == old.typeID
            else { return false }
            return registry.definition(for: node.typeID) == previous.registry.definition(for: node.typeID)
        }
        feedbackOutputs = feedbackOutputs.filter { snapshot.feedbackSources.contains($0.key) }
        heldOutputs = heldOutputs.filter { snapshot.graph.nodes[$0.key]?.mode == .onTrigger }
    }

    /// Forces the given nodes to run on the next pass, even if their inputs are unchanged. Use it
    /// when something a "pure" node reads has changed outside the graph.
    public func invalidate(_ nodes: Set<NodeID>) {
        for node in nodes { cache[node] = nil }
    }

    /// Forces every node to run on the next pass.
    public func invalidateAll() {
        cache = [:]
    }

    /// Forgets the tick count, feedback values and run clock, as if freshly created.
    public func reset() {
        tickCount = 0
        feedbackOutputs = [:]
        heldOutputs = [:]
        cache = [:]
        lastTickStart = nil
        runStart = nil
    }

    /// A new stream of ``ExecutionEvent``s for every pass from now on, for driving a UI's
    /// running, error and progress indicators. Each call returns an independent stream that
    /// ends when the runner is released. Events are never dropped by default; pass a bounded
    /// policy only if the consumer can recover from missing events (see ``ExecutionState``).
    public nonisolated func events(
        bufferingPolicy: AsyncStream<ExecutionEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<ExecutionEvent> {
        eventBroadcaster.stream(bufferingPolicy: bufferingPolicy)
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
        eventBroadcaster.send(.passStarted(tick: tick, time: time))
        let pass = await runNodes(
            snapshot, time: time, tick: tick, sequential: fixedDelta != nil,
            feedback: feedbackOutputs, held: heldOutputs, cache: cache)
        let results = pass.results
        let wasCancelled = pass.wasCancelled
        heldOutputs = pass.held
        cache = pass.cache

        for source in snapshot.feedbackSources {
            if let outputs = results[source]?.outputs { feedbackOutputs[source] = outputs }
        }
        tickCount += 1
        let duration = clock.now - started
        eventBroadcaster.send(.passFinished(tick: tick, duration: duration, wasCancelled: wasCancelled))
        return TickResult(
            tick: tick, time: time, results: results,
            duration: duration, wasCancelled: wasCancelled)
    }

    private struct PassOutput {
        var results: OrderedDictionary<NodeID, NodeRunResult>
        var wasCancelled: Bool
        var held: [NodeID: NodeOutputs]
        var cache: [NodeID: CacheEntry]
    }

    /// Why a node's outputs are unavailable to the nodes after it.
    private enum Unusable {
        case failed
        case disabled
    }

    private func runNodes(
        _ snapshot: Snapshot, time: ExecutionTime, tick: Int, sequential: Bool,
        feedback: [NodeID: NodeOutputs], held: [NodeID: NodeOutputs], cache: [NodeID: CacheEntry]
    ) async -> PassOutput {
        var results = OrderedDictionary<NodeID, NodeRunResult>()
        var outputs: [NodeID: NodeOutputs] = [:]
        var unusable: [NodeID: Unusable] = [:]
        var held = held
        var cache = cache
        var wasCancelled = false
        let events = eventBroadcaster
        let forwardProgress: @Sendable (NodeProgress) -> Void = { [onProgress] progress in
            onProgress(progress)
            events.send(.nodeProgress(progress))
        }

        func skipped(_ id: NodeID, _ reason: NodeRunResult.SkipReason) -> NodeRunResult {
            NodeRunResult(node: id, outcome: .skipped(reason), duration: .zero)
        }

        for level in snapshot.plan.levels {
            if Task.isCancelled { wasCancelled = true }
            if wasCancelled {
                for id in level {
                    let result = NodeRunResult(node: id, outcome: .cancelled, duration: .zero)
                    results[id] = result
                    events.send(.nodeFinished(node: id, tick: tick, status: result.status, duration: .zero))
                }
                continue
            }

            // Decide what each node does and build its context before any suspension.
            var jobs: [(index: Int, executor: NodeExecutor, context: NodeContext, key: CacheKey?)] = []
            var levelResults = [NodeRunResult?](repeating: nil, count: level.count)
            for (index, id) in level.enumerated() {
                guard let node = snapshot.graph.nodes[id] else { continue }
                let definition = snapshot.registry.definition(for: node.typeID)

                // These modes need nothing from the node's type or inputs.
                if node.mode == .never { levelResults[index] = skipped(id, .disabled); continue }
                if node.mode == .muted { levelResults[index] = skipped(id, .muted); continue }

                let bindings = snapshot.bindings[id] ?? []
                let blockers = bindings.flatMap(\.sources).filter { !$0.isFeedback }.compactMap { unusable[$0.node] }
                if !blockers.isEmpty {
                    levelResults[index] = skipped(id, blockers.contains(.failed) ? .upstreamFailed : .upstreamDisabled)
                    continue
                }

                guard let definition else {
                    levelResults[index] = NodeRunResult(
                        node: id,
                        outcome: .failure(NodeFailure(message: "\(NodeExecutionError.notExecutable(node.typeID))")),
                        duration: .zero)
                    continue
                }
                let resolved = Self.resolveInputs(bindings, outputs: outputs, feedback: feedback)
                let context = NodeContext(
                    node: node, definition: definition,
                    linkedInputs: resolved.values, triggered: resolved.triggered,
                    time: time, services: services, logger: logger, onProgress: forwardProgress)

                if node.mode == .bypassed {
                    levelResults[index] = NodeRunResult(
                        node: id,
                        outcome: .bypassed(definition.bypassedOutputs(inputs: context.inputs, triggered: context.triggered)),
                        duration: .zero)
                    continue
                }
                if node.mode == .onTrigger, resolved.triggered.isEmpty {
                    levelResults[index] = skipped(id, .notTriggered)
                    continue
                }
                guard let executor = snapshot.registry.executor(for: node.typeID) else {
                    levelResults[index] = NodeRunResult(
                        node: id,
                        outcome: .failure(NodeFailure(message: "\(NodeExecutionError.notExecutable(node.typeID))")),
                        duration: .zero)
                    continue
                }
                var key: CacheKey?
                if cachingEnabled, definition.isPure {
                    let candidate = CacheKey(
                        inputs: context.inputs, triggered: context.triggered, properties: context.properties)
                    if let entry = cache[id], entry.key == candidate {
                        levelResults[index] = NodeRunResult(node: id, outcome: .cached(entry.outputs), duration: .zero)
                        continue
                    }
                    key = candidate
                }
                jobs.append((index, executor, context, key))
            }

            // Executed nodes announce themselves live; everything else is announced below.
            let executed = Set(jobs.map(\.index))
            @Sendable func execute(_ job: (index: Int, executor: NodeExecutor, context: NodeContext, key: CacheKey?)) async -> (Int, NodeRunResult) {
                events.send(.nodeStarted(node: job.context.nodeID, tick: tick))
                let result = await NodeInvocation.run(job.executor, context: job.context)
                events.send(.nodeFinished(node: result.node, tick: tick, status: result.status, duration: result.duration))
                return (job.index, result)
            }
            if sequential || jobs.count < 2 {
                for job in jobs {
                    let (index, result) = await execute(job)
                    levelResults[index] = result
                }
            } else {
                await withTaskGroup(of: (Int, NodeRunResult).self) { group in
                    for job in jobs { group.addTask { await execute(job) } }
                    for await (index, result) in group { levelResults[index] = result }
                }
            }

            let keyByIndex = Dictionary(jobs.compactMap { job in job.key.map { (job.index, $0) } },
                                        uniquingKeysWith: { first, _ in first })
            for (index, id) in level.enumerated() {
                guard let result = levelResults[index] else { continue }
                results[id] = result
                if !executed.contains(index) {
                    events.send(.nodeFinished(node: id, tick: tick, status: result.status, duration: result.duration))
                }
                switch result.outcome {
                case .success(let produced):
                    if let key = keyByIndex[index] { cache[id] = CacheEntry(key: key, outputs: produced) }
                case .failure, .cancelled:
                    cache[id] = nil
                default:
                    break
                }
                switch result.outcome {
                case .success(let produced), .cached(let produced):
                    outputs[id] = produced
                    if snapshot.graph.nodes[id]?.mode == .onTrigger {
                        held[id] = NodeOutputs(produced.values)
                    }
                case .bypassed(let produced):
                    outputs[id] = produced
                case .skipped(.muted):
                    outputs[id] = .empty
                case .skipped(.notTriggered):
                    outputs[id] = held[id] ?? .empty
                case .skipped(.disabled), .skipped(.upstreamDisabled):
                    unusable[id] = .disabled
                case .skipped(.upstreamFailed), .failure:
                    unusable[id] = .failed
                case .cancelled:
                    unusable[id] = .failed
                    wasCancelled = true
                }
            }
        }
        return PassOutput(results: results, wasCancelled: wasCancelled, held: held, cache: cache)
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
