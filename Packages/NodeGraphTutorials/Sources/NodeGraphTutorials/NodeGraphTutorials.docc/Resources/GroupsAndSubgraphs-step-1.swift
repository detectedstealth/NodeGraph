import NodeGraphCore
import NodeGraphUI

/// Draws a labelled box around the two number nodes.
@MainActor
func groupTheNumbers(in model: GraphEditorModel) -> Bool {
    let numbers = model.graph.nodes.values.filter { $0.typeID == "util.number" }
    return model.groupNodes(numbers.map(\.id))
}
