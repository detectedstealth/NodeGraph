import NodeGraphCore
import NodeGraphNodes

/// An editor with the built-in nodes and the temperature pack side by side.
func makeEditorWithTemperatures() -> GraphEditor {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    TemperaturePack.register(nodes: &nodes, types: &types)
    return GraphEditor(nodes: nodes, types: types)
}
