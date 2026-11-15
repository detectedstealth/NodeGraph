import NodeGraphCore

/// Wraps the addition graph in a history, so edits made through it can be undone.
func makeHistory() throws -> GraphHistory {
    GraphHistory(editor: try makeAdditionGraph())
}

/// The value of the second number node, the one the tutorial edits.
func secondNumber(in history: GraphHistory) -> Double? {
    let numbers = history.editor.graph.nodes.values.filter { $0.typeID == "util.number" }
    return numbers.last?.properties["value"]?.numberValue
}

/// Sets the second number as an undoable step.
func changeSecondNumber(to value: Double, in history: GraphHistory) throws {
    guard let node = history.editor.graph.nodes.values.last(where: { $0.typeID == "util.number" }) else { return }
    try history.perform(
        .setNodeProperty(node: node.id, property: "value", value: .double(value)),
        name: "Change Number")
}
