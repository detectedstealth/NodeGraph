import NodeGraphCore
@testable import NodeGraphUI

/// A tiny registry for layout and model tests: a source with one output, a sink with two inputs,
/// and a node with a keep-one-free input group.
enum TestKit {
    static let source = NodeTypeID("test.source")
    static let sink = NodeTypeID("test.sink")
    static let merge = NodeTypeID("test.merge")
    static let widgets = NodeTypeID("test.widgets")
    static let relay = NodeTypeID("test.relay")
    static let reader = NodeTypeID("test.reader")

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
            typeID: relay, displayName: "Relay",
            ports: [
                PortDefinition(id: "in", direction: .input, type: "number"),
                PortDefinition(id: "out", direction: .output, type: "number"),
            ]))
        nodes.register(NodeDefinition(
            typeID: merge, displayName: "Merge",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")],
            dynamicPorts: [DynamicPortGroup(
                id: "in", direction: .input, type: "number", minimum: 1, resizing: .keepOneFree)]))
        nodes.register(NodeDefinition(
            typeID: widgets, displayName: "Widgets",
            properties: [
                PropertyDefinition(id: "flag", displayName: "Flag", kind: .bool, defaultValue: .bool(false)),
                PropertyDefinition(id: "gain", displayName: "Gain", kind: .double(min: 0, max: 1, step: 0.1), defaultValue: .double(0.5)),
                PropertyDefinition(id: "count", displayName: "Count", kind: .int(min: 0, max: nil, step: nil), defaultValue: .int(3)),
                PropertyDefinition(id: "label", displayName: "Label", kind: .string(), defaultValue: .string("hi")),
                PropertyDefinition(
                    id: "mode", displayName: "Mode",
                    kind: .choice([PropertyChoice(value: "a", label: "Alpha"), PropertyChoice(value: "b", label: "Beta")]),
                    defaultValue: .string("a")),
                PropertyDefinition(id: "tint", displayName: "Tint", kind: .color, defaultValue: .color(RGBAColor(red: 1, green: 0, blue: 0))),
                PropertyDefinition(id: "notes", displayName: "Notes", kind: .string(multiline: true), defaultValue: .string("")),
            ],
            defaultSize: GraphSize(width: 220, height: 80),
            help: "Has one of every widget."))
        nodes.register(NodeDefinition(
            typeID: reader, displayName: "Reader",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")],
            properties: [PropertyDefinition(id: "name", displayName: "Name", kind: .variable, defaultValue: "")]))
        var types = TypeRegistry()
        types.register(PortTypeInfo(
            type: "number", displayName: "Number", color: RGBAColor(red: 0.2, green: 0.4, blue: 0.9),
            defaultProducer: source, defaultConsumer: sink))
        return (nodes, types)
    }

    @MainActor
    static func makeModel(graph: Graph = Graph()) -> GraphEditorModel {
        let (nodes, types) = registries()
        return GraphEditorModel(editor: GraphEditor(graph: graph, nodes: nodes, types: types))
    }
}
