//# step 1
import NodeGraphCore

/// Runs the graph once and returns what happened.
func runOnce(_ editor: GraphEditor) async throws -> TickResult? {
    let runner = try GraphRunner(graph: editor.graph, registry: editor.nodes)
//# step 2
    for await tick in runner.run(.once) {
        return tick
    }
//# step 1
    return nil
}
//# step 3

/// The number the add node produced, if it ran.
func additionResult(in tick: TickResult, of editor: GraphEditor) -> Double? {
    guard let add = editor.graph.nodes.values.first(where: { $0.typeID == "math.add" }) else { return nil }
    return tick.outputs(of: add.id)?["result"]?.numberValue
}
//# step 4

/// Divides 1 by `divisor` and returns the message of every node that failed.
func divisionFailures(by divisor: Double) async throws -> [String] {
    let editor = makeEditor()
    let number = Node(typeID: "util.number", properties: ["value": .double(divisor)])
    let divide = Node(typeID: "math.divide")
    try editor.apply(.addNode(node: number))
    try editor.apply(.addNode(node: divide))
    try editor.apply(.addLink(link: Link(
        sourceNode: number.id, sourcePort: "value", targetNode: divide.id, targetPort: "b")))

    guard let tick = try await runOnce(editor) else { return [] }
    return tick.results.values.compactMap { result in
        if case .failure(let failure) = result.outcome { failure.message } else { nil }
    }
}
