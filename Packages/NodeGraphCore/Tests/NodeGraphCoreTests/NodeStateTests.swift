import Foundation
import Testing
@testable import NodeGraphCore

/// A node that counts the passes it has run, by storing the count as its state.
private func tallyRegistry() -> NodeRegistry {
    var nodes = runnable().0
    nodes.register(NodeDefinition(
        typeID: "tally", displayName: "Tally",
        ports: [
            PortDefinition(id: "fail", direction: .input, type: "bool", defaultValue: false),
            PortDefinition(id: "count", direction: .output, type: number),
        ])
    ) { ctx in
        if try ctx.bool("fail") { throw NodeExecutionError.failed("no") }
        let next = (ctx.state?.intValue ?? 0) + 1
        return NodeOutputs(["count": .double(Double(next))], state: .int(next))
    }
    nodes.register(NodeDefinition(
        typeID: "yes", displayName: "Yes",
        ports: [PortDefinition(id: "out", direction: .output, type: "bool")], isPure: true)
    ) { _ in ["out": true] }
    nodes.register(NodeDefinition(
        typeID: "forgetful", displayName: "Forgetful",
        ports: [PortDefinition(id: "seen", direction: .output, type: number)])
    ) { ctx in
        return NodeOutputs(["seen": .double(Double(ctx.state?.intValue ?? -1))], state: ctx.state == nil ? .int(1) : .null)
    }
    return nodes
}

private func counts(_ runner: GraphRunner, _ node: NodeID, passes: Int) async -> [GraphValue?] {
    var values: [GraphValue?] = []
    for _ in 0..<passes { values.append(await runner.step().outputs(of: node)?["count"]) }
    return values
}

@Test func aNodeSeesTheStateItStoredOnTheLastPass() async throws {
    var graph = Graph()
    let node = Node(typeID: "tally")
    graph.insert(node)
    let runner = try GraphRunner(graph: graph, registry: tallyRegistry())
    #expect(await counts(runner, node.id, passes: 3) == [1.0, 2.0, 3.0])
    await runner.reset()
    #expect(await counts(runner, node.id, passes: 1) == [1.0], "reset forgets node state")
}

@Test func deterministicRunsRepeatExactly() async throws {
    var graph = Graph()
    graph.insert(Node(typeID: "tally"))
    let registry = tallyRegistry()
    func run() async throws -> [GraphValue?] {
        var values: [GraphValue?] = []
        for await tick in try GraphRunner(graph: graph, registry: registry).run(.deterministic(fixedDelta: .milliseconds(10), ticks: 4)) {
            values.append(tick.results.values.first?.outputs?["count"])
        }
        return values
    }
    #expect(try await run() == [1.0, 2.0, 3.0, 4.0])
    #expect(try await run() == [1.0, 2.0, 3.0, 4.0])
}

@Test func stateIsKeptWhenANodeFailsOrIsNotRun() async throws {
    var graph = Graph()
    let node = Node(typeID: "tally")
    graph.insert(node)
    let runner = try GraphRunner(graph: graph, registry: tallyRegistry())
    #expect(await counts(runner, node.id, passes: 2) == [1.0, 2.0])

    // A node that always fires `true` into the tally's `fail` input makes it throw.
    var failing = graph
    let yes = Node(typeID: "yes")
    failing.insert(yes)
    failing.insert(Link(sourceNode: yes.id, sourcePort: "out", targetNode: node.id, targetPort: "fail"))
    try await runner.update(graph: failing, registry: tallyRegistry())
    let failed = await runner.step()
    #expect(failed.failedNodes == [node.id])

    var muted = graph
    muted.insert(Node(id: node.id, typeID: "tally", mode: .muted))
    try await runner.update(graph: muted, registry: tallyRegistry())
    _ = await runner.step()
    try await runner.update(graph: graph, registry: tallyRegistry())
    #expect(await counts(runner, node.id, passes: 1) == [3.0], "a failed and a muted pass leaves state alone")
}

@Test func returningNullForgetsTheState() async throws {
    var graph = Graph()
    let node = Node(typeID: "forgetful")
    graph.insert(node)
    let runner = try GraphRunner(graph: graph, registry: tallyRegistry())
    var seen: [GraphValue?] = []
    for _ in 0..<4 { seen.append(await runner.step().outputs(of: node.id)?["seen"]) }
    #expect(seen == [-1.0, 1.0, -1.0, 1.0])
}

@Test func updatingKeepsStateOnlyForNodesOfTheSameType() async throws {
    var graph = Graph()
    let node = Node(typeID: "tally")
    graph.insert(node)
    let registry = tallyRegistry()
    let runner = try GraphRunner(graph: graph, registry: registry)
    _ = await counts(runner, node.id, passes: 2)

    try await runner.update(graph: graph, registry: registry)
    #expect(await counts(runner, node.id, passes: 1) == [3.0])

    var retyped = graph
    retyped.insert(Node(id: node.id, typeID: "forgetful"))
    try await runner.update(graph: retyped, registry: registry)
    #expect(await runner.step().outputs(of: node.id)?["seen"] == -1.0, "another type never sees the old state")
}

@Test func eachSubgraphInstanceKeepsItsOwnNodeState() async throws {
    let tally = Node(typeID: "tally")
    var inner = Graph()
    inner.insert(tally)
    let definition = SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Counts",
            outputs: [SubgraphOutput(id: "count", type: number,
                                     source: PortAddress(node: tally.id, port: "count", direction: .output))]),
        graph: inner)
    var graph = Graph()
    let first = Node(typeID: definition.typeID), second = Node(typeID: definition.typeID)
    graph.insert(first); graph.insert(second)
    let runner = try GraphRunner(graph: graph, registry: tallyRegistry(), subgraphs: [definition])

    _ = await runner.step()
    let tick = await runner.step()
    #expect(tick.outputs(of: first.id)?["count"] == 2.0)
    #expect(tick.outputs(of: second.id)?["count"] == 2.0)

    // A third pass for one instance only: mute the other, then compare.
    var muted = graph
    muted.insert(Node(id: second.id, typeID: definition.typeID, mode: .muted))
    try await runner.update(graph: muted, registry: tallyRegistry(), subgraphs: [definition])
    _ = await runner.step()
    try await runner.update(graph: graph, registry: tallyRegistry(), subgraphs: [definition])
    let after = await runner.step()
    #expect(after.outputs(of: first.id)?["count"] == 4.0)
    #expect(after.outputs(of: second.id)?["count"] == 3.0)
}
