import NodeGraphCore
import Testing
@testable import NodeGraphTutorials

// Chapter 3: the finished code of "Using the pack". The pack's own tests are in Chapter3/.

@Test func aPackSitsBesideTheBuiltInNodes() throws {
    let editor = try addSensorToANumber()
    #expect(editor.graph.links.count == 1)
}

@Test func aTemperatureCannotFeedAString() throws {
    let editor = makeEditorWithTemperatures()
    let sensor = Node(typeID: "temperature.sensor")
    let upper = Node(typeID: "string.uppercase")
    try editor.apply(.addNode(node: sensor))
    try editor.apply(.addNode(node: upper))
    #expect(throws: (any Error).self) {
        try editor.apply(.addLink(link: Link(
            sourceNode: sensor.id, sourcePort: "value", targetNode: upper.id, targetPort: "value")))
    }
}
