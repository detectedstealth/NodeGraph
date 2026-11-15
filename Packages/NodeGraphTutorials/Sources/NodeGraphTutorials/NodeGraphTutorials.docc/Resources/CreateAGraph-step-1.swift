import NodeGraphCore
import NodeGraphNodes

/// Makes an editor that knows every built-in node type.
func makeEditor() -> GraphEditor {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    return GraphEditor(nodes: nodes, types: types)
}
