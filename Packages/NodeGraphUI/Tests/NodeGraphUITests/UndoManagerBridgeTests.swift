import Foundation
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct UndoManagerBridgeTests {
    private func makeModel() -> (GraphEditorModel, UndoManager) {
        let model = TestKit.makeModel()
        let manager = UndoManager()
        model.undoManager = manager
        return (model, manager)
    }

    private func add(_ model: GraphEditorModel, x: Double = 0, name: String? = nil) throws -> Node {
        let node = Node(typeID: TestKit.source, position: GraphPoint(x: x, y: 0))
        try model.perform(.addNode(node: node), name: name)
        return node
    }

    @Test func editsRegisterOneUndoActionEach() throws {
        let (model, manager) = makeModel()
        _ = try add(model, name: "Add Node")
        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Add Node")
        _ = try add(model, x: 100)
        // Two edits in the same event are still two separate undo steps.
        manager.undo()
        #expect(model.graph.nodes.count == 1)
        manager.undo()
        #expect(model.graph.nodes.isEmpty)
        #expect(!manager.canUndo)
    }

    @Test func managerUndoAndRedoDriveTheHistory() throws {
        let (model, manager) = makeModel()
        let node = try add(model, name: "Add Node")
        manager.undo()
        #expect(model.graph.nodes.isEmpty)
        #expect(manager.canRedo)
        #expect(manager.redoActionName == "Add Node")
        manager.redo()
        #expect(model.graph.nodes[node.id] != nil)
        #expect(manager.canUndo)
        manager.undo()
        #expect(model.graph.nodes.isEmpty)
    }

    @Test func modelUndoRoutesThroughTheManager() throws {
        let (model, manager) = makeModel()
        _ = try add(model)
        try model.undo()
        #expect(model.graph.nodes.isEmpty)
        #expect(manager.canRedo)
        try model.redo()
        #expect(model.graph.nodes.count == 1)
        #expect(manager.canUndo)
    }

    @Test func coalescedDragIsOneManagerStep() throws {
        let (model, manager) = makeModel()
        let node = try add(model)
        for x in stride(from: 10.0, through: 60, by: 10) {
            try model.perform(
                .setNodePositions(placements: [NodePlacement(node: node.id, position: GraphPoint(x: x, y: 0))]),
                name: "Move", coalescing: true)
        }
        model.endCoalescing()
        manager.undo()
        #expect(model.graph.nodes[node.id]?.position.x == 0)
        #expect(model.graph.nodes.count == 1)  // the add is still there
        #expect(manager.canUndo)
    }

    @Test func groupedEditsAreOneManagerStep() throws {
        let (model, manager) = makeModel()
        try model.group(name: "Add Two") {
            _ = try add(model)
            _ = try add(model, x: 200)
        }
        #expect(manager.undoActionName == "Add Two")
        manager.undo()
        #expect(model.graph.nodes.isEmpty)
        #expect(!manager.canUndo)
    }

    @Test func newEditAfterUndoClearsRedo() throws {
        let (model, manager) = makeModel()
        _ = try add(model)
        manager.undo()
        _ = try add(model, x: 50)
        #expect(!manager.canRedo)
        #expect(!model.canRedo)
    }

    @Test func connectRegistersAStep() throws {
        let (model, manager) = makeModel()
        let source = try add(model)
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)), name: "Connect")
        #expect(manager.undoActionName == "Connect")
        manager.undo()
        #expect(model.graph.links.isEmpty)
    }

    @Test func worksWithoutAnUndoManager() throws {
        let model = TestKit.makeModel()
        _ = try add(model)
        try model.undo()
        #expect(model.graph.nodes.isEmpty)
        try model.redo()
        #expect(model.graph.nodes.count == 1)
    }

    @Test func detachingForgetsItsActions() throws {
        let (model, manager) = makeModel()
        _ = try add(model)
        model.undoManager = nil
        #expect(!manager.canUndo)
        _ = try add(model, x: 10)
        #expect(!manager.canUndo)
    }

    @Test func actionsOlderThanTheHistoryDoNothing() throws {
        let model = TestKit.makeModel()
        model.history.limit = 1
        let manager = UndoManager()
        model.undoManager = manager
        _ = try add(model)
        _ = try add(model, x: 10)
        manager.undo()
        #expect(model.graph.nodes.count == 1)
        #expect(manager.levelsOfUndo == 1)
        #expect(!model.canUndo)
    }
}
