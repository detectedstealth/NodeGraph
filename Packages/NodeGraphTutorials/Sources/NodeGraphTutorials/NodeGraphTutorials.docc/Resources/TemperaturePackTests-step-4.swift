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

@Test func thePeakNodeRemembersTheHighestReading() async throws {
    let editor = makeTemperatureEditor()
    let sensor = Node(typeID: "temperature.sensor", properties: ["celsius": 30.0])
    let peak = Node(typeID: "temperature.peak")
    try editor.apply(.addNode(node: sensor))
    try editor.apply(.addNode(node: peak))
    try editor.apply(.addLink(link: Link(
        sourceNode: sensor.id, sourcePort: "value", targetNode: peak.id, targetPort: "temperature")))
    let runner = try GraphRunner(graph: editor.graph, registry: editor.nodes)

    #expect(await runner.step().outputs(of: peak.id)?["peak"] == 30.0)

    // The sensor drops to 10. The peak stays at 30.
    try editor.apply(.setNodeProperty(node: sensor.id, property: "celsius", value: 10.0))
    try await runner.update(graph: editor.graph, registry: editor.nodes)
    #expect(await runner.step().outputs(of: peak.id)?["peak"] == 30.0)

    try editor.apply(.setNodeProperty(node: sensor.id, property: "celsius", value: 50.0))
    try await runner.update(graph: editor.graph, registry: editor.nodes)
    #expect(await runner.step().outputs(of: peak.id)?["peak"] == 50.0)
}

@Test func everyDefinitionIsWellFormedAndHasHelp() {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    TemperaturePack.register(nodes: &nodes, types: &types)
    for definition in nodes.registeredDefinitions {
        #expect(definition.problems.isEmpty)
        #expect(definition.help != nil)
    }
}
