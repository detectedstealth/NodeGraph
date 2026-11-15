import NodeGraphCore
import Testing
@testable import TemperaturePack

@Test func numbersFeedTemperaturesAndTemperaturesFeedNumbers() {
    var types = TypeRegistry()
    registerTemperatureType(in: &types)
    #expect(types.connectability(from: .init("number"), to: .temperature) == .accepted)
    #expect(types.connectability(from: .temperature, to: .init("number")) == .converted)
    #expect(types.connectability(from: .temperature, to: .init("string")) == .incompatible)
}

private func makeTemperatureEditor() -> GraphEditor {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    TemperaturePack.register(nodes: &nodes, types: &types)
    return GraphEditor(nodes: nodes, types: types)
}

@Test func aSensorFeedsAConverter() async throws {
    let editor = makeTemperatureEditor()
    let sensor = Node(typeID: "temperature.sensor", properties: ["celsius": 100.0])
    let convert = Node(typeID: "temperature.convert", properties: ["unit": "fahrenheit"])
    try editor.apply(.addNode(node: sensor))
    try editor.apply(.addNode(node: convert))
    try editor.apply(.addLink(link: Link(
        sourceNode: sensor.id, sourcePort: "value", targetNode: convert.id, targetPort: "temperature")))

    let runner = try GraphRunner(graph: editor.graph, registry: editor.nodes)
    var last: TickResult?
    for await tick in runner.run(.once) { last = tick }
    #expect(last?.outputs(of: convert.id)?["result"] == 212.0)
}
