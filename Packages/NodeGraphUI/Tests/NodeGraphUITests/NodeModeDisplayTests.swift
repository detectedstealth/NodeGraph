import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct NodeModeDisplayTests {
    @Test func eachModeHasItsOwnMarkAndAlwaysHasNone() {
        #expect(NodeModeDisplay(.always) == nil)
        let marks = NodeMode.allCases.compactMap { NodeModeDisplay($0)?.mark }
        #expect(marks.count == 4)
        #expect(Set(marks.map { "\($0)" }).count == 4)
    }

    @Test func onlyOffMutedAndBypassedAreFadedAndOnlyOffAndMutedDimLinks() {
        #expect(NodeModeDisplay(.never)?.isFaded == true)
        #expect(NodeModeDisplay(.muted)?.isFaded == true)
        #expect(NodeModeDisplay(.bypassed)?.isFaded == true)
        #expect(NodeModeDisplay(.onTrigger)?.isFaded == false)
        #expect(NodeModeDisplay(.never)?.dimsOutgoingLinks == true)
        #expect(NodeModeDisplay(.muted)?.dimsOutgoingLinks == true)
        #expect(NodeModeDisplay(.bypassed)?.dimsOutgoingLinks == false)
    }

    @Test func everyModeHasSummaryText() {
        for mode in NodeMode.allCases { #expect(!mode.effectSummary.isEmpty) }
    }

    @Test func toggledSetsTheModeOrClearsItWhenAllHaveIt() {
        #expect(NodeMode.toggled(.muted, among: [NodeMode.always, .muted]) == .muted)
        #expect(NodeMode.toggled(.muted, among: [NodeMode.muted, .muted]) == .always)
        #expect(NodeMode.toggled(.muted, among: [NodeMode.bypassed]) == .muted)
    }

    @Test func keysToggleMuteBypassAndDisable() {
        #expect(CanvasKeyMap.command(for: .character("m"), modifiers: []) == .toggleMode(.muted))
        #expect(CanvasKeyMap.command(for: .character("b"), modifiers: []) == .toggleMode(.bypassed))
        #expect(CanvasKeyMap.command(for: .character("d"), modifiers: []) == .toggleMode(.never))
        #expect(CanvasKeyMap.command(for: .character("d"), modifiers: .command) == .duplicate)
        #expect(CanvasCommand.toggleMode(.muted).isEdit)
    }

    @Test func toggleCommandSetsThenClearsTheModeAsOneUndoStepEach() throws {
        let model = TestKit.makeModel()
        let controller = GraphInteractionController(model: model)
        let a = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let b = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        for node in [a, b] { try model.perform(.addNode(node: node)) }
        model.selection = GraphSelection(nodes: [a.id, b.id])

        #expect(controller.perform(.toggleMode(.bypassed)))
        #expect(model.graph.nodes[a.id]?.mode == .bypassed && model.graph.nodes[b.id]?.mode == .bypassed)
        #expect(controller.perform(.toggleMode(.bypassed)))
        #expect(model.graph.nodes[a.id]?.mode == .always && model.graph.nodes[b.id]?.mode == .always)
    }

    @Test func linksLeavingAnOffOrMutedNodeAreInactive() throws {
        let model = TestKit.makeModel()
        let controller = GraphInteractionController(model: model)
        let a = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let b = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        for node in [a, b] { try model.perform(.addNode(node: node)) }
        let link = Link(sourceNode: a.id, sourcePort: "out", targetNode: b.id, targetPort: "a")
        try model.perform(.addLink(link: link))

        #expect(!model.isLinkInactive(link))
        model.selection = GraphSelection(nodes: [a.id])
        #expect(controller.perform(.toggleMode(.muted)))
        #expect(model.isLinkInactive(link))
        #expect(controller.perform(.setMode(.bypassed)))
        #expect(!model.isLinkInactive(link))
    }
}
