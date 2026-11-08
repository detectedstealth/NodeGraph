import Foundation
import NodeGraphCore
import Testing
@testable import NodeGraphRobotics

/// `examples/demo.nodegraph` at the repo root, the file the app's demo graph was exported to.
private func demoDocument() throws -> GraphDocument {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try GraphDocument.decode(from: Data(contentsOf: root.appendingPathComponent("examples/demo.nodegraph")))
}

@Test func theDemoFileLoadsWithoutPlaceholders() throws {
    let document = try demoDocument()
    let (nodes, types) = RoboticsPack.makeRegistries()
    let editor = GraphEditor(document: document, nodes: nodes, types: types)
    #expect(document.graph.nodes.count == 16 && document.graph.links.count == 13)
    #expect(document.subgraphs.count == 1)
    #expect(editor.graph.nodes.values.allSatisfy { nodes.definition(for: $0.typeID) != nil || $0.typeID.subgraphID != nil })
}

@Test func theDemoControlLoopSettlesOnItsSetpoint() async throws {
    let document = try demoDocument()
    let (nodes, _) = RoboticsPack.makeRegistries()
    let runner = try GraphRunner(document: document, registry: nodes)
    var last: TickResult?
    for await tick in runner.run(.deterministic(fixedDelta: .milliseconds(10), ticks: 1000)) { last = tick }
    let tick = try #require(last)
    #expect(tick.succeeded)
    let plant = try #require(document.graph.nodes.values.first { $0.typeID == "robotics.plant" })
    let reading = try #require(tick.outputs(of: plant.id)?.values["output"]?.numberValue)
    #expect(abs(reading - 1) < 0.01)
}
