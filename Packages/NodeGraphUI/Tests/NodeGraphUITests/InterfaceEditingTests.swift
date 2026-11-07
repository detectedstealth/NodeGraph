import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct InterfaceEditingTests {
    let model = TestKit.makeModel()
    let source: Node
    let instance: NodeID
    let subgraph: SubgraphID

    /// A source feeding a sink, with the sink wrapped as "Wrapped" and opened.
    init() throws {
        source = Node(typeID: TestKit.source, position: .zero)
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 400, y: 0))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let conversion = try model.editor.convertToSubgraphCommand(nodes: [sink.id], name: "Wrapped")
        try model.perform(conversion.command)
        instance = conversion.instance
        subgraph = conversion.subgraph
        model.enterSubgraph(of: instance)
    }

    private var interface: SubgraphInterface { model.editor.subgraphs[subgraph]!.interface }

    private func inner(_ type: NodeTypeID) throws -> Node {
        try #require(model.graph.nodes.values.first { $0.typeID == type })
    }

    @Test func nothingSelectedInsideShowsTheSubgraphAndItsInterface() throws {
        guard case .subgraph(let info) = model.inspection() else {
            Issue.record("expected the subgraph")
            return
        }
        #expect(info.id == subgraph && info.name == "Wrapped" && info.category == "Subgraph")
        #expect(info.instanceCount == 1)
        #expect(info.summary.nodeCount == 1)
        #expect(info.inputs.map(\.displayName) == ["a"] && info.outputs.isEmpty && info.properties.isEmpty)
        #expect(info.inputs[0].typeName == "Number")
        #expect(info.inputs[0].detail == "feeds Sink · a")
        #expect(!info.inputs[0].canMoveUp && !info.inputs[0].canMoveDown)
    }

    @Test func atTheRootThereIsNoSubgraphToShow() {
        model.leaveSubgraph()
        guard case .graph = model.inspection() else {
            Issue.record("expected the graph")
            return
        }
    }

    @Test func renamingTheSubgraphUpdatesTheBreadcrumbNameAndRefusesBlank() throws {
        #expect(model.renameSubgraph(to: "  Better  "))
        #expect(model.scopeName(subgraph) == "Better")
        #expect(!model.renameSubgraph(to: "   "))
        #expect(!model.renameSubgraph(to: "Better"))  // unchanged: no step
        #expect(model.setSubgraphCategory("Math"))
        #expect(interface.category == "Math")
        #expect(model.setSubgraphCategory(""))
        #expect(interface.category == "Subgraph")
    }

    @Test func renamingAnInputKeepsTheLinkOutside() throws {
        #expect(model.renameInput("a", to: "Signal"))
        #expect(interface.inputs.first?.displayName == "Signal")
        #expect(interface.inputs.first?.id == "a")
        #expect(model.editor.graph.links.count == 1)  // the link to the instance survives
        #expect(!model.renameInput("a", to: ""))
        #expect(!model.renameInput("missing", to: "X"))
    }

    @Test func eachEditIsOneUndoStep() throws {
        let before = model.history.undoStack.count
        model.renameSubgraph(to: "One")
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(interface.name == "Wrapped")
        try model.redo()
        #expect(interface.name == "One")
    }

    @Test func removingAnInputDropsTheLinkToTheInstance() throws {
        #expect(model.removeInput("a"))
        #expect(interface.inputs.isEmpty)
        #expect(model.editor.graph.links.isEmpty)
        try model.undo()
        #expect(model.editor.graph.links.count == 1 && interface.inputs.count == 1)
    }

    @Test func exposingAnInnerPortAddsAnInputAndHidingRemovesIt() throws {
        let sink = try inner(TestKit.sink)
        let b = PortAddress(node: sink.id, port: "b", direction: .input)
        #expect(model.isExposed(input: b) == false)
        #expect(model.setExposed(true, input: b))
        #expect(model.isExposed(input: b) == true)
        #expect(interface.inputs.map(\.id.rawValue) == ["a", "b"])
        #expect(interface.inputs.last?.targets == [b] && interface.inputs.last?.type == "number")
        #expect(!model.setExposed(true, input: b))  // already exposed
        #expect(model.setExposed(false, input: b))
        #expect(interface.inputs.map(\.id.rawValue) == ["a"])
        #expect(!model.setExposed(false, input: b))
    }

    @Test func exposingAnOutputAndAPropertyWorks() throws {
        let extra = Node(typeID: TestKit.widgets, position: GraphPoint(x: 0, y: 300))
        let producer = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 600))
        try model.perform(.addNode(node: extra))
        try model.perform(.addNode(node: producer))
        let out = PortAddress(node: producer.id, port: "out", direction: .output)
        #expect(model.setExposed(true, output: out))
        #expect(interface.outputs.first?.source == out && model.isExposed(output: out) == true)
        try model.perform(.setNodeProperty(node: extra.id, property: "gain", value: .double(0.9)))
        let gain = PropertyTarget(node: extra.id, property: "gain")
        #expect(model.setExposed(true, property: gain))
        #expect(interface.properties.first?.defaultValue == .double(0.9))
        #expect(model.isExposed(property: gain) == true)
        // The instance outside now has them.
        let instanceNode = try #require(model.editor.graph.nodes[instance])
        let definition = try #require(model.editor.nodes.definition(for: instanceNode))
        #expect(definition.property("gain") != nil && definition.port("out", direction: .output) != nil)
        #expect(model.setExposed(false, output: out) && model.setExposed(false, property: gain))
        #expect(interface.outputs.isEmpty && interface.properties.isEmpty)
    }

    @Test func idsStayUniqueWhenTwoPortsShareAName() throws {
        let second = Node(typeID: TestKit.sink, position: GraphPoint(x: 0, y: 300))
        try model.perform(.addNode(node: second))
        let a = PortAddress(node: second.id, port: "a", direction: .input)
        #expect(model.setExposed(true, input: a))
        #expect(interface.inputs.map(\.id.rawValue) == ["a", "a_2"])
    }

    @Test func reorderingChangesThePortOrderAndStopsAtTheEnds() throws {
        let sink = try inner(TestKit.sink)
        model.setExposed(true, input: PortAddress(node: sink.id, port: "b", direction: .input))
        #expect(model.moveInput("b", by: -1))
        #expect(interface.inputs.map(\.id.rawValue) == ["b", "a"])
        #expect(!model.moveInput("b", by: -1))  // already first
        #expect(model.moveInput("b", by: 5))  // clamps to the end
        #expect(interface.inputs.map(\.id.rawValue) == ["a", "b"])
        guard case .subgraph(let info) = model.inspection() else {
            Issue.record("expected the subgraph")
            return
        }
        #expect(info.inputs.map(\.canMoveUp) == [false, true] && info.inputs.map(\.canMoveDown) == [true, false])
    }

    @Test func removingAndRenamingOutputsAndProperties() throws {
        let extra = Node(typeID: TestKit.widgets, position: GraphPoint(x: 0, y: 300))
        let producer = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 600))
        try model.perform(.addNode(node: extra))
        try model.perform(.addNode(node: producer))
        model.setExposed(true, output: PortAddress(node: producer.id, port: "out", direction: .output))
        model.setExposed(true, property: PropertyTarget(node: extra.id, property: "flag"))
        #expect(model.renameOutput("out", to: "Result") && interface.outputs.first?.displayName == "Result")
        #expect(model.renameProperty("flag", to: "Enabled") && interface.properties.first?.displayName == "Enabled")
        #expect(model.removeOutput("out") && interface.outputs.isEmpty)
        #expect(model.removeProperty("flag") && interface.properties.isEmpty)
    }

    @Test func nodeInspectionTellsWhatIsExposedInsideAndNothingAtTheRoot() throws {
        let sink = try inner(TestKit.sink)
        model.select(node: sink.id)
        guard case .node(let inside) = model.inspection() else {
            Issue.record("expected a node")
            return
        }
        #expect(inside.inputs.map(\.isExposed) == [true, false])
        model.leaveSubgraph()
        model.select(node: source.id)
        guard case .node(let outside) = model.inspection() else {
            Issue.record("expected a node")
            return
        }
        #expect(outside.outputs.allSatisfy { $0.isExposed == nil })
    }

    @Test func theEditsDoNothingAtTheRoot() throws {
        model.leaveSubgraph()
        #expect(!model.renameSubgraph(to: "X"))
        #expect(!model.removeInput("a"))
        #expect(model.isExposed(input: PortAddress(node: source.id, port: "a", direction: .input)) == nil)
    }

    @Test func theInstanceCountCoversEveryNodeUsingIt() throws {
        model.leaveSubgraph()
        let more = Node(typeID: model.editor.subgraphs[subgraph]!.typeID, position: GraphPoint(x: 0, y: 500))
        try model.perform(.addNode(node: more))
        model.enterSubgraph(of: instance)
        guard case .subgraph(let info) = model.inspection() else {
            Issue.record("expected the subgraph")
            return
        }
        #expect(info.instanceCount == 2)
    }
}

@MainActor
@Suite struct CreateFormStyleTests {
    @Test func inputsAreNamedAfterTheirTitledFeeder() throws {
        let model = TestKit.makeModel()
        let a = Node(typeID: TestKit.source, position: .zero, title: "A")
        let x = Node(typeID: TestKit.sink, position: GraphPoint(x: 400, y: 0))
        let y = Node(typeID: TestKit.sink, position: GraphPoint(x: 400, y: 300))
        for node in [a, x, y] { try model.perform(.addNode(node: node)) }
        for sink in [x, y] {
            try model.connect(ConnectionProposal(
                source: PortAddress(node: a.id, port: "out", direction: .output),
                target: PortAddress(node: sink.id, port: "a", direction: .input)))
        }
        model.selection = GraphSelection(nodes: [x.id, y.id])
        model.beginCreateSubgraph()
        #expect(model.createSubgraph(name: "Pair"))
        let definition = try #require(model.editor.subgraphs.values.first)
        #expect(definition.interface.inputs.map(\.displayName) == ["A"])
        #expect(definition.interface.inputs.first?.targets.count == 2)
    }
}
