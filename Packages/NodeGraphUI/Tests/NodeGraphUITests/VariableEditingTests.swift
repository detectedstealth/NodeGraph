import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct VariableEditingTests {
    @Test func newVariablesGetUniqueNamesAndTheKindsStartingValue() throws {
        let model = TestKit.makeModel()
        #expect(model.addVariable(kind: .number) == "variable")
        #expect(model.addVariable(kind: .text) == "variable 2")
        #expect(model.addVariable(named: "gain", kind: .toggle) == "gain")
        #expect(model.addVariable(named: "gain", kind: .toggle) == "gain 2")
        #expect(Array(model.graph.variables.keys) == ["variable", "variable 2", "gain", "gain 2"])
        #expect(model.graph.variables["variable"]?.value == .double(0))
        #expect(model.graph.variables["variable 2"]?.value == .string(""))
        #expect(model.graph.variables["gain"]?.value == .bool(false))
        #expect(model.addVariable(named: "   ", kind: .number) == nil)
    }

    @Test func aValueMustKeepItsKind() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "n", kind: .number)
        #expect(model.setVariable("n", to: .double(2.5)))
        #expect(model.graph.variables["n"]?.value == .double(2.5))
        #expect(!model.setVariable("n", to: .string("x")), "text cannot replace a number")
        #expect(!model.setVariable("n", to: .int(3)), "an int is another kind than a double")
        #expect(!model.setVariable("n", to: .double(2.5)), "nothing to change")
        #expect(!model.setVariable("missing", to: .double(1)))
        #expect(model.graph.variables["n"]?.value == .double(2.5))
    }

    @Test func editsAreUndoableAndASweepIsOneStep() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "a", kind: .number)
        model.addVariable(named: "b", kind: .text)
        model.endCoalescing()
        for value in [1.0, 2.0, 3.0] { model.setVariable("a", to: .double(value), coalescing: true) }
        model.endCoalescing()
        try model.undo()
        #expect(model.graph.variables["a"]?.value == .double(0))

        #expect(model.removeVariable("a"))
        #expect(Array(model.graph.variables.keys) == ["b"])
        try model.undo()
        #expect(Array(model.graph.variables.keys) == ["a", "b"], "undo puts it back where it was")
        #expect(!model.removeVariable("nope"))
    }

    @Test func renamingIsOneUndoStepAndFollowsTheReaders() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "a", kind: .number)
        model.addVariable(named: "b", kind: .text)
        let reader = Node(typeID: TestKit.reader, properties: ["name": .string("a")])
        try model.perform(.addNode(node: reader))
        #expect(model.renameVariable("a", to: "  speed "))
        #expect(Array(model.graph.variables.keys) == ["speed", "b"])
        #expect(model.graph.nodes[reader.id]?.properties["name"] == .string("speed"))
        try model.undo()
        #expect(Array(model.graph.variables.keys) == ["a", "b"])
        #expect(model.graph.nodes[reader.id]?.properties["name"] == .string("a"))

        #expect(!model.renameVariable("a", to: "b"), "taken")
        #expect(!model.renameVariable("a", to: "   "), "blank")
        #expect(!model.renameVariable("a", to: " a "), "unchanged")
        #expect(!model.renameVariable("nope", to: "x"))
    }

    @Test func aVariableNamePropertyOffersTheGraphsVariables() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "gain", kind: .number)
        let property = PropertyDefinition(id: "name", displayName: "Name", kind: .variable, defaultValue: "")
        guard case .combo(let choices) = model.widgetSpec(for: property, currentValue: .string("gain")).kind else {
            Issue.record("expected a choice"); return
        }
        #expect(choices.map(\.value) == ["gain"])
        guard case .combo(let withMissing) = model.widgetSpec(for: property, currentValue: .string("old")).kind else {
            Issue.record("expected a choice"); return
        }
        #expect(withMissing.map(\.value) == ["gain", "old"])
        #expect(withMissing.last?.label == "old (not declared)")
    }

    @Test func aReaderNodeIsAddedBoundToTheVariableAndSelected() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "gain", kind: .number)
        #expect(model.variableReaderType == TestKit.reader)
        let id = try #require(model.addVariableReader(for: "gain"))
        #expect(model.graph.nodes[id]?.typeID == TestKit.reader)
        #expect(model.graph.nodes[id]?.properties["name"] == .string("gain"))
        #expect(model.selection.nodes == [id])
        // In the middle of the view: the node's center is where the view's center is.
        let frame = try #require(model.layout(of: id)?.frame)
        let middle = model.camera.graphPoint(forScreen: CGPoint(x: model.viewSize.width / 2, y: model.viewSize.height / 2))
        #expect(abs(frame.origin.x + frame.size.width / 2 - middle.x) < 1)
        try model.undo()
        #expect(model.graph.nodes[id] == nil)
        #expect(model.addVariableReader(for: "nope") == nil)
    }

    @Test func noReaderIsAddedWithoutAPackThatHasOneOrOnAReadOnlyCanvas() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "gain", kind: .number)
        model.isEditable = false
        #expect(model.addVariableReader(for: "gain") == nil)
        #expect(model.graph.nodes.isEmpty)
    }

    @Test func insideASubgraphTheRootsVariablesCannotBeEdited() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "v", kind: .number)
        let node = Node(typeID: TestKit.source)
        try model.perform(.addNode(node: node))
        model.select(node: node.id)
        #expect(model.beginCreateSubgraph())
        #expect(model.createSubgraph(name: "Inner", open: true))
        #expect(model.currentScope != nil)
        #expect(model.addVariable(kind: .number) == nil)
        #expect(!model.setVariable("v", to: .double(1)))
        #expect(!model.removeVariable("v"))
        model.navigate(toDepth: 0)
        #expect(model.graph.variables["v"] != nil)
    }

    @Test func aReadOnlyCanvasRefusesVariableEdits() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "v", kind: .number)
        model.isEditable = false
        #expect(model.addVariable(kind: .text) == nil)
        #expect(!model.setVariable("v", to: .double(5)))
        #expect(!model.removeVariable("v"))
        #expect(model.graph.variables.count == 1 && model.graph.variables["v"]?.value == .double(0))
    }

    @Test func variablesSurviveAnUndoRedoRoundTripThroughTheModel() throws {
        let model = TestKit.makeModel()
        model.addVariable(named: "v", kind: .toggle)
        try model.undo()
        #expect(model.graph.variables.isEmpty)
        try model.redo()
        #expect(model.graph.variables["v"]?.value == .bool(false))
    }
}
