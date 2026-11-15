import NodeGraphCore

/// Runs the graph once and returns what happened.
func runOnce(_ editor: GraphEditor) async throws -> TickResult? {
    let runner = try GraphRunner(graph: editor.graph, registry: editor.nodes)
    return nil
}
