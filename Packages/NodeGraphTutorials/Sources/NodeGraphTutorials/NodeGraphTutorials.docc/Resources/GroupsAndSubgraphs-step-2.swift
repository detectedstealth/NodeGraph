import NodeGraphCore
import NodeGraphUI

/// Draws a labelled box around the two number nodes.
@MainActor
func groupTheNumbers(in model: GraphEditorModel) -> Bool {
    let numbers = model.graph.nodes.values.filter { $0.typeID == "util.number" }
    return model.groupNodes(numbers.map(\.id))
}

/// Replaces every node with one subgraph node that holds them.
@MainActor
func makeSubgraphOfTheAddition(in model: GraphEditorModel) -> Bool {
    model.selection = GraphSelection(nodes: Set(model.graph.nodes.keys))
    guard model.beginCreateSubgraph() else { return false }
    return model.createSubgraph(name: "Add Two Numbers")
}
