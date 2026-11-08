import NodeGraphCore

/// A value to record each tick of a scenario: one output port of one node.
public struct ScenarioProbe: Hashable, Sendable {
    public var node: NodeID
    public var port: PortID

    public init(node: NodeID, port: PortID) {
        self.node = node
        self.port = port
    }
}

/// What a scenario recorded, one entry per tick.
public struct ScenarioTrace: Sendable {
    /// Simulated seconds at the start of each tick.
    public var times: [Double]
    /// The probed values per tick; nil where the node produced no such output (it failed or was skipped).
    public var series: [ScenarioProbe: [GraphValue?]]
    /// Nodes that failed in any tick, so a scenario can be rejected.
    public var failedNodes: Set<NodeID>

    public func numbers(_ probe: ScenarioProbe) -> [Double?] {
        (series[probe] ?? []).map { $0?.numberValue }
    }

    public var succeeded: Bool { failedNodes.isEmpty }
}

/// Runs a graph in simulated time with a fixed step, and records what you ask for. The same
/// graph and inputs give the same trace on every run, whatever the machine's speed.
public enum FixedStepScenario {
    public static func run(
        graph: Graph,
        registry: NodeRegistry,
        subgraphs: [SubgraphDefinition] = [],
        step: Duration,
        ticks: Int,
        variables: [String: GraphValue] = [:],
        probes: [ScenarioProbe]
    ) async throws -> ScenarioTrace {
        let runner = try GraphRunner(
            graph: graph, registry: registry, subgraphs: subgraphs, variables: variables, caching: false)
        var trace = ScenarioTrace(times: [], series: [:], failedNodes: [])
        for await tick in runner.run(.deterministic(fixedDelta: step, ticks: ticks)) {
            trace.times.append(tick.time.elapsedSeconds)
            trace.failedNodes.formUnion(tick.failedNodes)
            for probe in probes {
                trace.series[probe, default: []].append(tick.outputs(of: probe.node)?.values[probe.port])
            }
        }
        return trace
    }
}
