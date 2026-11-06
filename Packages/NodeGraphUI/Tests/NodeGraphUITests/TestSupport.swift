import NodeGraphCore
@testable import NodeGraphUI

/// A tiny registry for layout and model tests: a source with one output, a sink with two inputs,
/// and a node with a keep-one-free input group.
enum TestKit {
    static let source = NodeTypeID("test.source")
    static let sink = NodeTypeID("test.sink")
    static let merge = NodeTypeID("test.merge")

    static func registries() -> (nodes: NodeRegistry, types: TypeRegistry) {
        var nodes = NodeRegistry()
        nodes.register(NodeDefinition(
            typeID: source, displayName: "Source",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")]))
        nodes.register(NodeDefinition(
            typeID: sink, displayName: "Sink",
            ports: [
                PortDefinition(id: "a", direction: .input, type: "number"),
                PortDefinition(id: "b", direction: .input, type: "number"),
            ],
            defaultSize: GraphSize(width: 160, height: 40)))
        nodes.register(NodeDefinition(
            typeID: merge, displayName: "Merge",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")],
            dynamicPorts: [DynamicPortGroup(
                id: "in", direction: .input, type: "number", minimum: 1, resizing: .keepOneFree)]))
        var types = TypeRegistry()
        types.register(PortTypeInfo(
            type: "number", displayName: "Number", color: RGBAColor(red: 0.2, green: 0.4, blue: 0.9)))
        return (nodes, types)
    }

    @MainActor
    static func makeModel(graph: Graph = Graph()) -> GraphEditorModel {
        let (nodes, types) = registries()
        return GraphEditorModel(editor: GraphEditor(graph: graph, nodes: nodes, types: types))
    }
}
