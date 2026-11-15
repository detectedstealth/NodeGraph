import NodeGraphCore

/// Runs the graph once and returns what happened.
func runOnce(_ editor: GraphEditor) async throws -> TickResult? {
    let runner = try GraphRunner(graph: editor.graph, registry: editor.nodes)
    for await tick in runner.run(.once) {
        return tick
    }
    return nil
}

/// The number the add node produced, if it ran.
func additionResult(in tick: TickResult, of editor: GraphEditor) -> Double? {
    guard let add = editor.graph.nodes.values.first(where: { $0.typeID == "math.add" }) else { return nil }
    return tick.outputs(of: add.id)?["result"]?.numberValue
}
