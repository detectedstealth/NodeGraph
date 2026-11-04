import Foundation
import Testing
@testable import NodeGraphCore

private func makeHistory(limit: Int = 100) -> GraphHistory {
    var types = TypeRegistry()
    types.register(PortTypeInfo(
        type: "number", displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 0)))
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "pass", displayName: "Pass",
        ports: [
            PortDefinition(id: "in", direction: .input, type: "number"),
            PortDefinition(id: "out", direction: .output, type: "number"),
        ]))
    return GraphHistory(editor: GraphEditor(nodes: nodes, types: types), limit: limit)
}

private func addNode(_ history: GraphHistory, name: String? = nil) throws -> NodeID {
    let node = Node(typeID: "pass")
    try history.perform(.addNode(node: node), name: name)
    return node.id
}

private func move(_ history: GraphHistory, _ id: NodeID, to x: Double) throws {
    try history.perform(
        .setNodePositions(placements: [NodePlacement(node: id, position: GraphPoint(x: x, y: 0))]),
        name: "Move", coalescing: true)
}

@Test func undoAndRedoWalkTheHistory() throws {
    let history = makeHistory()
    let empty = history.editor.graph
    let a = try addNode(history, name: "Add Node")
    let withOne = history.editor.graph
    _ = try addNode(history)
    #expect(history.undoName == nil && history.canUndo && !history.canRedo)

    try history.undo()
    #expect(history.editor.graph == withOne && history.canRedo)
    try history.undo()
    #expect(history.editor.graph == empty && !history.canUndo)
    #expect(history.redoName == "Add Node")
    try history.redo()
    #expect(history.editor.graph.nodes[a] != nil)
    try history.redo()
    #expect(history.editor.graph.nodes.count == 2 && !history.canRedo)
}

@Test func undoAndRedoOnEmptyStacksDoNothing() throws {
    let history = makeHistory()
    try history.undo()
    try history.redo()
    #expect(history.editor.revision == 0)
}

@Test func newEditClearsRedo() throws {
    let history = makeHistory()
    _ = try addNode(history)
    try history.undo()
    #expect(history.canRedo)
    _ = try addNode(history)
    #expect(!history.canRedo)
}

@Test func failedEditIsNotRecorded() throws {
    let history = makeHistory()
    #expect(throws: GraphEditError.self) { try history.perform(.removeNode(id: NodeID())) }
    #expect(!history.canUndo)
}

@Test func coalescingMergesADragIntoOneStep() throws {
    let history = makeHistory()
    let id = try addNode(history)
    let before = history.editor.graph
    for x in 1...20 { try move(history, id, to: Double(x)) }
    #expect(history.undoStack.count == 2)
    #expect(history.undoName == "Move")
    #expect(history.editor.graph.nodes[id]?.position.x == 20)
    try history.undo()
    #expect(history.editor.graph == before)
    try history.redo()
    #expect(history.editor.graph.nodes[id]?.position.x == 20)
}

@Test func endCoalescingStartsANewStep() throws {
    let history = makeHistory()
    let id = try addNode(history)
    try move(history, id, to: 1)
    try move(history, id, to: 2)
    history.endCoalescing()
    try move(history, id, to: 3)
    #expect(history.undoStack.count == 3)
    try history.undo()
    #expect(history.editor.graph.nodes[id]?.position.x == 2)
}

@Test func otherEditsAndUndoBreakCoalescing() throws {
    let history = makeHistory()
    let id = try addNode(history)
    try move(history, id, to: 1)
    try history.perform(.setNodeAttribute(node: id, attribute: .isPinned(value: true)))
    try move(history, id, to: 2)
    #expect(history.undoStack.count == 4)
    try history.undo()
    try history.undo()
    try move(history, id, to: 5)
    #expect(history.undoStack.count == 3)
}

@Test func nonCoalescingEditsNeverMerge() throws {
    let history = makeHistory()
    let id = try addNode(history)
    for x in 1...3 {
        try history.perform(.setNodePositions(placements: [NodePlacement(node: id, position: GraphPoint(x: Double(x), y: 0))]))
    }
    #expect(history.undoStack.count == 4)
}

@Test func groupBecomesOneStep() throws {
    let history = makeHistory()
    let before = history.editor.graph
    try history.group(name: "Add Pair") {
        let a = try addNode(history)
        let b = try addNode(history)
        try history.connect(ConnectionProposal(
            source: PortAddress(node: a, port: "out", direction: .output),
            target: PortAddress(node: b, port: "in", direction: .input)))
    }
    #expect(history.undoStack.count == 1 && history.undoName == "Add Pair")
    #expect(history.editor.graph.links.count == 1)
    try history.undo()
    #expect(history.editor.graph == before)
    try history.redo()
    #expect(history.editor.graph.nodes.count == 2 && history.editor.graph.links.count == 1)
}

@Test func failedGroupRollsBack() throws {
    let history = makeHistory()
    _ = try addNode(history)
    let before = history.editor.graph
    #expect(throws: GraphEditError.self) {
        try history.group {
            _ = try addNode(history)
            try history.perform(.removeNode(id: NodeID()))
        }
    }
    #expect(history.editor.graph == before)
    #expect(history.undoStack.count == 1)
}

@Test func emptyGroupRecordsNothing() throws {
    let history = makeHistory()
    try history.group { }
    #expect(!history.canUndo)
}

@Test func nestedGroupsJoinTheOutermost() throws {
    let history = makeHistory()
    try history.group(name: "Outer") {
        _ = try addNode(history)
        try history.group(name: "Inner") { _ = try addNode(history) }
    }
    #expect(history.undoStack.count == 1 && history.undoName == "Outer")
}

@Test func limitDropsTheOldestSteps() throws {
    let history = makeHistory(limit: 3)
    for _ in 0..<5 { _ = try addNode(history) }
    #expect(history.undoStack.count == 3)
    history.limit = 1
    #expect(history.undoStack.count == 1)
}

@Test func externalChangesThatBreakHistoryClearIt() throws {
    let history = makeHistory()
    let id = try addNode(history)
    try history.editor.apply(.removeNode(id: id))
    #expect(throws: GraphEditError.self) { try history.undo() }
    #expect(!history.canUndo && !history.canRedo)
}

@Test func removalUndoRestoresLinksThroughHistory() throws {
    let history = makeHistory()
    let a = try addNode(history), b = try addNode(history)
    try history.perform(.addLink(link: Link(sourceNode: a, sourcePort: "out", targetNode: b, targetPort: "in")))
    let before = history.editor.graph
    try history.perform(.removeNode(id: a), name: "Delete")
    #expect(history.editor.graph.links.isEmpty)
    try history.undo()
    #expect(history.editor.graph == before)
}

@Test func connectingThroughHistoryUndoesLinkReplacement() throws {
    let history = makeHistory()
    let a = try addNode(history), b = try addNode(history), c = try addNode(history)
    func proposal(_ x: NodeID) -> ConnectionProposal {
        ConnectionProposal(
            source: PortAddress(node: x, port: "out", direction: .output),
            target: PortAddress(node: c, port: "in", direction: .input))
    }
    try history.connect(proposal(a))
    let before = history.editor.graph
    try history.connect(proposal(b), name: "Connect")
    #expect(history.editor.graph.links.count == 1)
    try history.undo()
    #expect(history.editor.graph == before)
}

@Test func redoThatCannotApplyClearsHistory() throws {
    let history = makeHistory()
    let id = try addNode(history)
    try history.undo()
    // Someone else adds a node with the same id, so redoing the original add must fail.
    try history.editor.apply(.addNode(node: Node(id: id, typeID: "pass")))
    #expect(throws: GraphEditError.self) { try history.redo() }
    #expect(!history.canUndo && !history.canRedo)
}

@Test func historyEntriesRoundTripThroughJSON() throws {
    let history = makeHistory()
    _ = try addNode(history, name: "Add Node")
    let entry = try #require(history.undoStack.first)
    let data = try JSONEncoder().encode(entry)
    #expect(try JSONDecoder().decode(HistoryEntry.self, from: data) == entry)
}
