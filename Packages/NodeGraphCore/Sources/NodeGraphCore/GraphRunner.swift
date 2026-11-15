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

/// Why a run's variable value was refused.
public enum VariableOverrideError: Error, Hashable, Sendable {
    /// The graph declares no variable with this name.
    case undeclared(String)
    /// The value is not the same kind as the variable's declared value (an int for a double, say).
    case kindMismatch(name: String, expected: String, found: String)
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
/// The runner works on its own copy of the graph; call ``update(graph:registry:subgraphs:)`` to change it.
public actor GraphRunner {
    private var snapshot: Snapshot
    private let services: ServiceContainer
    private let logger: Logger
    private let onProgress: @Sendable (NodeProgress) -> Void

    private var tickCount = 0
    /// Values that replace declared variables in this run. Always names the graph declares.
    private var variableOverrides: [String: GraphValue] = [:]
    private let cachingEnabled: Bool
    /// What the root graph remembers between passes.
    private var rootState = FrameState()
    private var subgraphs: [SubgraphID: CompiledSubgraph]
    private let store = SubgraphStateStore()
    private var lastTickStart: ContinuousClock.Instant?
    private var runStart: ContinuousClock.Instant?
    private var inFlight: Task<TickResult, Never>?

    private let eventBroadcaster = Broadcaster<ExecutionEvent>()

    private let requests: AsyncStream<Void>
    private let requestContinuation: AsyncStream<Void>.Continuation

    /// - Parameters:
    ///   - graph: The graph to run. The runner keeps its own copy.
    ///   - registry: Node definitions and executors for every node type the graph uses.
    ///   - subgraphs: Definitions of the subgraphs the graph (or another definition) has instances
    ///     of. Their instance node types are registered for you.
    ///   - services: Shared services nodes can look up while they run.
    ///   - overrides: Values for graph variables that replace their declared values for this runner.
    ///   - logger: Where nodes' log output goes.
    ///   - caching: Whether to skip nodes whose inputs have not changed since the last pass.
    ///   - onProgress: Called with progress reports from nodes that run long.
    /// - Throws: ``ExecutionPlanError`` if the graph has a cycle no feedback node breaks.
    public init(
        graph: Graph,
        registry: NodeRegistry,
        subgraphs: [SubgraphDefinition] = [],
        services: ServiceContainer = ServiceContainer(),
        variables overrides: [String: GraphValue] = [:],
        logger: Logger = Logger(label: "NodeGraph.runner"),
        caching: Bool = true,
        onProgress: @escaping @Sendable (NodeProgress) -> Void = { _ in }
    ) throws {
        cachingEnabled = caching
        let registry = registry.registeringSubgraphs(subgraphs)
        snapshot = try Snapshot.make(graph: graph, registry: registry)
        self.subgraphs = Self.compile(subgraphs, registry: registry)
        self.services = services
        self.logger = logger
        self.onProgress = onProgress
        variableOverrides = try Self.checked(overrides, against: graph)
        (requests, requestContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Runs a saved document's graph, with its subgraph definitions.
    public init(
        document: GraphDocument,
        registry: NodeRegistry,
        services: ServiceContainer = ServiceContainer(),
        variables overrides: [String: GraphValue] = [:],
        logger: Logger = Logger(label: "NodeGraph.runner"),
        caching: Bool = true,
        onProgress: @escaping @Sendable (NodeProgress) -> Void = { _ in }
    ) throws {
        try self.init(
            graph: document.graph, registry: registry, subgraphs: document.subgraphs, services: services,
            variables: overrides, logger: logger, caching: caching, onProgress: onProgress)
    }

    /// Compiles every definition once. One that cannot run (its inner graph has a cycle) is
    /// kept with its error, so only its instances fail.
    private static func compile(_ definitions: [SubgraphDefinition], registry: NodeRegistry) -> [SubgraphID: CompiledSubgraph] {
        Dictionary(definitions.map { definition in
            do {
                return (definition.id, CompiledSubgraph(
                    definition: definition, snapshot: try Snapshot.make(graph: definition.graph, registry: registry)))
            } catch ExecutionPlanError.cycle {
                return (definition.id, CompiledSubgraph(definition: definition, error: "its inner graph has a cycle"))
            } catch {
                return (definition.id, CompiledSubgraph(definition: definition, error: "\(error)"))
            }
        }, uniquingKeysWith: { _, last in last })
    }

    /// Checks `values` against the variables `graph` declares: every name declared, every value
    /// the same kind as the declared one.
    private static func checked(_ values: [String: GraphValue], against graph: Graph) throws -> [String: GraphValue] {
        for (name, value) in values {
            guard let declared = graph.variables[name] else { throw VariableOverrideError.undeclared(name) }
            guard value.kindName == declared.value.kindName else {
                throw VariableOverrideError.kindMismatch(
                    name: name, expected: declared.value.kindName, found: value.kindName)
            }
        }
        return values
    }

    /// The variables nodes see: each declared value, or the run's override of it.
    public var variables: [String: GraphValue] {
        Dictionary(uniqueKeysWithValues: snapshot.graph.variables.map { ($0.key, $0.value.value) })
            .merging(variableOverrides) { _, override in override }
    }

    /// Replaces a variable's value for this run, from the next pass on, without touching the
    /// graph. Pass nil to go back to the declared value.
    ///
    /// - Throws: ``VariableOverrideError`` for an undeclared name or a value of another kind
    ///   than the declared one.
    public func setVariable(_ name: String, to value: GraphValue?) throws {
        guard let value else {
            variableOverrides[name] = nil
            return
        }
        variableOverrides = variableOverrides.merging(
            try Self.checked([name: value], against: snapshot.graph)) { _, new in new }
    }

    /// Replaces every override at once. All or nothing: if any value is refused, none is applied.
    public func setVariables(_ values: [String: GraphValue]) throws {
        variableOverrides = try Self.checked(values, against: snapshot.graph)
    }

    /// The number of passes completed since creation or the last ``reset()``.
    public var completedTicks: Int { tickCount }

    /// Replaces the graph, registry and subgraph definitions, recompiling the plans. State of
    /// nodes that still exist is kept. A pass already running finishes on the old graph.
    ///
    /// - Throws: ``ExecutionPlanError``; the runner keeps its previous graph in that case.
    public func update(graph: Graph, registry: NodeRegistry, subgraphs definitions: [SubgraphDefinition] = []) throws {
        let previous = snapshot
        let previousDefinitions = subgraphs.mapValues(\.definition)
        let registry = registry.registeringSubgraphs(definitions)
        let next = try Snapshot.make(graph: graph, registry: registry)
        snapshot = next
        subgraphs = Self.compile(definitions, registry: registry)

        // Cached outputs stay valid only for nodes whose type definition is unchanged. Executors
        // are code and cannot be compared; after swapping one, call `invalidateAll()`.
        rootState.cache = rootState.cache.filter { id, _ in
            guard let node = graph.nodes[id], let old = previous.graph.nodes[id], node.typeID == old.typeID
            else { return false }
            return registry.definition(for: node.typeID) == previous.registry.definition(for: node.typeID)
        }
        // An override of a variable the new graph no longer declares, or declares as another kind,
        // is dropped rather than failing an update that is otherwise fine.
        variableOverrides = variableOverrides.filter { name, value in
            graph.variables[name]?.value.kindName == value.kindName
        }
        rootState.nodeState = rootState.nodeState.filter { id, _ in
            graph.nodes[id]?.typeID == previous.graph.nodes[id]?.typeID
        }
        rootState.feedback = rootState.feedback.filter { next.feedbackSources.contains($0.key) }
        rootState.held = rootState.held.filter { next.graph.nodes[$0.key]?.mode == .onTrigger }

        // Instance state is dropped when any definition changed (inner nodes may have been
        // rewired), and otherwise for instances that no longer exist.
        if Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) }) != previousDefinitions {
            store.removeAll()
        } else {
            store.prune(keeping: Set(graph.nodes.values.filter { $0.typeID.subgraphID != nil }.map(\.id)))
        }
    }

    /// Forces the given nodes to run on the next pass, even if their inputs are unchanged. Use it
    /// when something a "pure" node reads has changed outside the graph. Pure nodes inside
    /// subgraph instances are re-run by ``invalidateAll()``.
    public func invalidate(_ nodes: Set<NodeID>) {
        for node in nodes { rootState.cache[node] = nil }
    }

    /// Forces every node, including those inside subgraph instances, to run on the next pass.
    public func invalidateAll() {
        rootState.cache = [:]
        store.removeAll()
    }

    /// Forgets the tick count, feedback values and run clock, as if freshly created.
    public func reset() {
        tickCount = 0
        rootState = FrameState()
        store.removeAll()
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

    /// Evaluates one pass as if the run were at `elapsed`, for time-based graphs such as video
    /// ("the frame at 2.5 s") where a caller wants any moment without running the ones before it.
    /// Nodes run one at a time in plan order, like a deterministic run. State that nodes keep
    /// between passes carries over from whatever pass ran last, so a graph that is a pure function
    /// of time gives the same result in any order.
    public func step(at elapsed: Duration, delta: Duration = .zero) async -> TickResult {
        await serialized(fixedDelta: delta, elapsed: elapsed)
    }

    // MARK: One pass

    /// Queues a pass behind any pass already running, so passes never overlap even though the
    /// actor is re-entered while nodes are awaited.
    private func serialized(fixedDelta: Duration?, elapsed: Duration? = nil) async -> TickResult {
        let previous = inFlight
        let task = Task { [self] () -> TickResult in
            _ = await previous?.value
            return await evaluate(fixedDelta: fixedDelta, elapsed: elapsed)
        }
        inFlight = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func evaluate(fixedDelta: Duration?, elapsed: Duration? = nil) async -> TickResult {
        let clock = ContinuousClock()
        let started = clock.now
        let tick = tickCount

        let time: ExecutionTime
        if let fixedDelta {
            time = ExecutionTime(tick: tick, elapsed: elapsed ?? fixedDelta * tick, delta: fixedDelta)
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
        let environment = PassEnvironment(
            services: services, logger: logger, onProgress: onProgress, cachingEnabled: cachingEnabled,
            events: eventBroadcaster, subgraphs: subgraphs, store: store, variables: variables)
        let pass = await PassEvaluator.run(
            snapshot, environment: environment,
            request: PassRequest(time: time, tick: tick, sequential: fixedDelta != nil),
            state: rootState)
        let results = pass.results
        let wasCancelled = pass.wasCancelled
        rootState = pass.state

        tickCount += 1
        let duration = clock.now - started
        eventBroadcaster.send(.passFinished(tick: tick, duration: duration, wasCancelled: wasCancelled))
        return TickResult(
            tick: tick, time: time, results: results,
            duration: duration, wasCancelled: wasCancelled)
    }
}
