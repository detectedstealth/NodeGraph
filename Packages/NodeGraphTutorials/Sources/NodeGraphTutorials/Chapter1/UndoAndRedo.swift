//# step 1
import NodeGraphCore

/// Wraps the addition graph in a history, so edits made through it can be undone.
func makeHistory() throws -> GraphHistory {
    GraphHistory(editor: try makeAdditionGraph())
}
//# step 2

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
//# step 3

/// The second number after an edit, an undo and a redo.
func numberAcrossUndoAndRedo() throws -> [Double?] {
    let history = try makeHistory()
    var seen: [Double?] = [secondNumber(in: history)]

    try changeSecondNumber(to: 10, in: history)
    seen.append(secondNumber(in: history))

    try history.undo()
    seen.append(secondNumber(in: history))

    try history.redo()
    seen.append(secondNumber(in: history))
    return seen
}
//# step 4

/// Sets every number to zero as one step: a single undo brings them all back.
func resetNumbers(in history: GraphHistory) throws {
    try history.group(name: "Reset Numbers") {
        for node in history.editor.graph.nodes.values where node.typeID == "util.number" {
            try history.perform(.setNodeProperty(node: node.id, property: "value", value: 0.0))
        }
    }
}
