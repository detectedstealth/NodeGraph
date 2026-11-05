import Synchronization
import Collections
import Logging

// The machinery that evaluates one pass over one graph. `GraphRunner` uses it for the root graph;
// subgraph instances use it recursively for their inner graphs.

/// How a node's inputs are fed: which links lead into it.
struct InputBinding: Sendable {
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

/// A graph compiled for evaluation.
struct Snapshot: Sendable {
    var graph: Graph
    var registry: NodeRegistry
    var plan: ExecutionPlan
    var bindings: [NodeID: [InputBinding]]
    var feedbackSources: Set<NodeID>

    static func make(graph: Graph, registry: NodeRegistry) throws -> Snapshot {
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

struct CacheKey: Hashable, Sendable {
    var inputs: [PortID: GraphValue]
    var triggered: Set<PortID>
    var properties: [PropertyID: GraphValue]
}

struct CacheEntry: Sendable {
    var key: CacheKey
    var outputs: NodeOutputs
}

/// What one graph remembers from pass to pass.
struct FrameState: Sendable {
    /// Outputs of feedback nodes from the last pass that produced them.
    var feedback: [NodeID: NodeOutputs] = [:]
    /// Last data outputs of `onTrigger` nodes, published again on passes where they don't run.
    var held: [NodeID: NodeOutputs] = [:]
    /// Outputs of pure nodes with the exact inputs that produced them.
    var cache: [NodeID: CacheEntry] = [:]
}

/// A subgraph definition compiled for running, or why it cannot be.
struct CompiledSubgraph: Sendable {
    var definition: SubgraphDefinition
    var snapshot: Snapshot?
    var error: String?
}

/// Where instances of subgraphs keep their state between passes, keyed by the chain of instance
/// node ids from the root, so two instances of one definition never share state.
final class SubgraphStateStore: Sendable {
    private let frames = Mutex<[[NodeID]: FrameState]>([:])

    func state(at path: [NodeID]) -> FrameState { frames.withLock { $0[path] ?? FrameState() } }
    func save(_ state: FrameState, at path: [NodeID]) { frames.withLock { $0[path] = state } }
    func removeAll() { frames.withLock { $0 = [:] } }

    /// Forgets instances whose outermost node is not in `keeping`.
    func prune(keeping roots: Set<NodeID>) {
        frames.withLock { $0 = $0.filter { roots.contains($0.key[0]) } }
    }
}

/// Values and triggers a subgraph instance feeds into inner input ports.
struct ExternalInputs: Sendable {
    var values: [NodeID: [PortID: GraphValue]] = [:]
    var triggers: [NodeID: Set<PortID>] = [:]
}

/// What a pass needs from whoever runs it.
struct PassEnvironment: Sendable {
    var services: ServiceContainer
    var logger: Logger
    var onProgress: @Sendable (NodeProgress) -> Void
    var cachingEnabled: Bool
    /// Where events go; nil inside subgraph instances, whose inner nodes have no id of their
    /// own that a listener could place.
    var events: Broadcaster<ExecutionEvent>?
    var subgraphs: [SubgraphID: CompiledSubgraph]
    var store: SubgraphStateStore
}

/// How one pass is posed.
struct PassRequest: Sendable {
    var time: ExecutionTime
    var tick: Int
    var sequential: Bool
    /// Instance ids from the root to this graph; empty for the root graph.
    var path: [NodeID] = []
    var external = ExternalInputs()
    /// Property values to write over inner nodes, from an instance's promoted properties.
    var propertyOverrides: [NodeID: [PropertyID: GraphValue]] = [:]
}

struct PassOutput: Sendable {
    var results: OrderedDictionary<NodeID, NodeRunResult>
    var wasCancelled: Bool
    var state: FrameState
    /// What each node made available to the nodes after it. Differs from `results` for muted
    /// and `onTrigger` nodes, which publish nothing or their held outputs without running.
    var published: [NodeID: NodeOutputs]
}

/// How deep instances may nest before a run is stopped, which catches a subgraph that contains
/// itself.
let maximumSubgraphDepth = 32

enum PassEvaluator {
    /// Why a node's outputs are unavailable to the nodes after it.
    private enum Unusable {
        case failed
        case disabled
    }

    typealias Job = (index: Int, executor: NodeExecutor, context: NodeContext, key: CacheKey?)

    static func run(
        _ snapshot: Snapshot, environment env: PassEnvironment, request: PassRequest, state: FrameState
    ) async -> PassOutput {
        var results = OrderedDictionary<NodeID, NodeRunResult>()
        var outputs: [NodeID: NodeOutputs] = [:]
        var unusable: [NodeID: Unusable] = [:]
        var state = state
        var wasCancelled = false
        let events = env.events
        let tick = request.tick
        let forwardProgress: @Sendable (NodeProgress) -> Void = { [onProgress = env.onProgress] progress in
            onProgress(progress)
            events?.send(.nodeProgress(progress))
        }

        func skipped(_ id: NodeID, _ reason: NodeRunResult.SkipReason) -> NodeRunResult {
            NodeRunResult(node: id, outcome: .skipped(reason), duration: .zero)
        }
        func failed(_ id: NodeID, _ message: String) -> NodeRunResult {
            NodeRunResult(node: id, outcome: .failure(NodeFailure(message: message)), duration: .zero)
        }

        for level in snapshot.plan.levels {
            if Task.isCancelled { wasCancelled = true }
            if wasCancelled {
                for id in level {
                    let result = NodeRunResult(node: id, outcome: .cancelled, duration: .zero)
                    results[id] = result
                    events?.send(.nodeFinished(node: id, tick: tick, status: result.status, duration: .zero))
                }
                continue
            }

            // Decide what each node does and build its context before any suspension.
            var jobs: [Job] = []
            var levelResults = [NodeRunResult?](repeating: nil, count: level.count)
            for (index, id) in level.enumerated() {
                guard var node = snapshot.graph.nodes[id] else { continue }
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
                    levelResults[index] = failed(id, "\(NodeExecutionError.notExecutable(node.typeID))")
                    continue
                }
                var resolved = resolveInputs(bindings, outputs: outputs, feedback: state.feedback)
                if let external = request.external.values[id] {
                    resolved.values.merge(external) { _, outer in outer }
                }
                if let fired = request.external.triggers[id] { resolved.triggered.formUnion(fired) }
                if let overrides = request.propertyOverrides[id] {
                    node.properties.merge(overrides) { _, outer in outer }
                }
                let context = NodeContext(
                    node: node, definition: definition,
                    linkedInputs: resolved.values, triggered: resolved.triggered,
                    time: request.time, services: env.services, logger: env.logger, onProgress: forwardProgress)

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

                // An instance runs its inner graph; any other node runs its registered executor.
                let executor: NodeExecutor
                var cacheable = definition.isPure
                if let subgraph = node.typeID.subgraphID {
                    guard let compiled = env.subgraphs[subgraph] else {
                        levelResults[index] = failed(id, "Subgraph \(subgraph) is not defined")
                        continue
                    }
                    executor = instanceExecutor(for: compiled, instance: id, environment: env, request: request)
                    cacheable = false
                } else if let registered = snapshot.registry.executor(for: node.typeID) {
                    executor = registered
                } else {
                    levelResults[index] = failed(id, "\(NodeExecutionError.notExecutable(node.typeID))")
                    continue
                }

                var key: CacheKey?
                if env.cachingEnabled, cacheable {
                    let candidate = CacheKey(
                        inputs: context.inputs, triggered: context.triggered, properties: context.properties)
                    if let entry = state.cache[id], entry.key == candidate {
                        levelResults[index] = NodeRunResult(node: id, outcome: .cached(entry.outputs), duration: .zero)
                        continue
                    }
                    key = candidate
                }
                jobs.append((index, executor, context, key))
            }

            // Executed nodes announce themselves live; everything else is announced below.
            let executed = Set(jobs.map(\.index))
            @Sendable func execute(_ job: Job) async -> (Int, NodeRunResult) {
                events?.send(.nodeStarted(node: job.context.nodeID, tick: tick))
                let result = await NodeInvocation.run(job.executor, context: job.context)
                events?.send(.nodeFinished(node: result.node, tick: tick, status: result.status, duration: result.duration))
                return (job.index, result)
            }
            if request.sequential || jobs.count < 2 {
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
                    events?.send(.nodeFinished(node: id, tick: tick, status: result.status, duration: result.duration))
                }
                switch result.outcome {
                case .success(let produced):
                    if let key = keyByIndex[index] { state.cache[id] = CacheEntry(key: key, outputs: produced) }
                case .failure, .cancelled:
                    state.cache[id] = nil
                default:
                    break
                }
                switch result.outcome {
                case .success(let produced), .cached(let produced):
                    outputs[id] = produced
                    if snapshot.graph.nodes[id]?.mode == .onTrigger {
                        state.held[id] = NodeOutputs(produced.values)
                    }
                case .bypassed(let produced):
                    outputs[id] = produced
                case .skipped(.muted):
                    outputs[id] = .empty
                case .skipped(.notTriggered):
                    outputs[id] = state.held[id] ?? .empty
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

        for source in snapshot.feedbackSources {
            if let produced = results[source]?.outputs { state.feedback[source] = produced }
        }
        return PassOutput(results: results, wasCancelled: wasCancelled, state: state, published: outputs)
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

    // MARK: Subgraph instances

    /// The executor of one instance node: runs the definition's inner graph for one pass.
    ///
    /// Inputs and promoted properties of the instance are mapped onto the inner graph, the inner
    /// pass runs with the state this instance kept from earlier passes, and the inner outputs it
    /// is bound to become the instance's outputs. Any inner failure fails the instance.
    private static func instanceExecutor(
        for compiled: CompiledSubgraph, instance: NodeID, environment env: PassEnvironment, request: PassRequest
    ) -> NodeExecutor {
        { context in
            let interface = compiled.definition.interface
            guard let inner = compiled.snapshot else {
                throw NodeExecutionError.failed("Subgraph \"\(interface.name)\" cannot run: \(compiled.error ?? "invalid")")
            }
            guard request.path.count < maximumSubgraphDepth else {
                throw NodeExecutionError.failed("Subgraphs are nested too deeply; does \"\(interface.name)\" contain itself?")
            }

            var external = ExternalInputs()
            for input in interface.inputs {
                for target in input.targets {
                    if input.kind == .trigger {
                        if context.triggered.contains(input.id) { external.triggers[target.node, default: []].insert(target.port) }
                    } else if let value = context.inputs[input.id] {
                        external.values[target.node, default: [:]][target.port] = value
                    }
                }
            }
            var overrides: [NodeID: [PropertyID: GraphValue]] = [:]
            for property in interface.properties {
                guard let value = context.properties[property.id] else { continue }
                for target in property.targets { overrides[target.node, default: [:]][target.property] = value }
            }

            let path = request.path + [instance]
            var innerEnvironment = env
            innerEnvironment.events = nil
            innerEnvironment.onProgress = { _ in }
            let pass = await run(
                inner, environment: innerEnvironment,
                request: PassRequest(
                    time: request.time, tick: request.tick, sequential: request.sequential, path: path,
                    external: external, propertyOverrides: overrides),
                state: env.store.state(at: path))
            env.store.save(pass.state, at: path)

            if pass.wasCancelled { throw CancellationError() }
            if let failure = pass.results.values.first(where: { if case .failure = $0.outcome { true } else { false } }),
               case .failure(let reason) = failure.outcome {
                let type = inner.graph.nodes[failure.node]?.typeID.rawValue ?? "a node"
                throw NodeExecutionError.failed("In \"\(interface.name)\", \(type): \(reason.message)")
            }

            var outputs = NodeOutputs.empty
            for output in interface.outputs {
                guard let source = output.source, let produced = pass.published[source.node] else { continue }
                if output.kind == .trigger {
                    if produced.triggers.contains(source.port) { outputs.triggers.insert(output.id) }
                } else if let value = produced.values[source.port] {
                    outputs.values[output.id] = value
                }
            }
            return outputs
        }
    }
}
