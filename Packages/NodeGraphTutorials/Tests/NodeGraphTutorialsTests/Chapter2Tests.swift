import Foundation
import NodeGraphCore
import NodeGraphUI
import Testing
@testable import NodeGraphTutorials

// Chapter 2: the finished code of each tutorial, run without a window.

@MainActor
@Test func theModelShowsTheAdditionGraph() throws {
    let model = try makeAdditionModel()
    #expect(model.graph.nodes.count == 3)
    #expect(picture(of: model) != nil)
}

@MainActor
@Test func runningShowsResultsOnTheModelAndLogsToTheConsole() async throws {
    let model = try makeAdditionModel()
    let console = ConsoleModel()
    await run(model, console: console)
    let add = try #require(model.graph.nodes.values.first { $0.typeID == "math.add" })
    #expect(model.runValues[add.id, "result"]?.numberValue == 6)
    #expect(!console.entries.isEmpty)
}

@MainActor
@Test func theConsoleNamesAFailure() async throws {
    let editor = makeEditor()
    let number = Node(typeID: "util.number", properties: ["value": 0.0])
    let divide = Node(typeID: "math.divide")
    try editor.apply(.addNode(node: number))
    try editor.apply(.addNode(node: divide))
    try editor.apply(.addLink(link: Link(
        sourceNode: number.id, sourcePort: "value", targetNode: divide.id, targetPort: "b")))
    let console = ConsoleModel()
    await run(GraphEditorModel(editor: editor), console: console)
    #expect(console.entries.contains { $0.level == .error && $0.text.contains("Division by zero") })
}

@MainActor
@Test func groupsAndSubgraphsAreOneUndoStepEach() throws {
    let model = try makeAdditionModel()
    #expect(groupTheNumbers(in: model))
    #expect(model.graph.groups.count == 1)
    try model.undo()
    #expect(model.graph.groups.isEmpty)

    #expect(makeSubgraphOfTheAddition(in: model))
    #expect(model.graph.nodes.count == 1)
    #expect(model.editor.subgraphs.count == 1)
    #expect(lookInsideTheSubgraph(in: model))
    #expect(model.currentScope == nil)
    try model.undo()
    #expect(model.graph.nodes.count == 3)
}
