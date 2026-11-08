import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct ArrangementTests {
    private func item(_ x: Double, _ y: Double, w: Double = 100, h: Double = 50, pinned: Bool = false) -> Arrangement.Item {
        Arrangement.Item(node: NodeID(), frame: GraphRect(x: x, y: y, width: w, height: h), isPinned: pinned)
    }

    private func position(_ id: NodeID, in placements: [NodePlacement]) -> GraphPoint? {
        placements.first { $0.node == id }?.position
    }

    @Test func leftAndRightLineUpOnTheBoxEdges() {
        let a = item(10, 0), b = item(200, 100, w: 60), c = item(120, 40)
        let left = Arrangement.aligned([a, b, c], to: .left)
        #expect(position(b.node, in: left) == GraphPoint(x: 10, y: 100))
        #expect(position(a.node, in: left) == nil)  // already there, so not returned
        let right = Arrangement.aligned([a, b, c], to: .right)
        // The box ends at 260 (b); a and c move so their right edges are at 260.
        #expect(position(a.node, in: right) == GraphPoint(x: 160, y: 0))
        #expect(position(c.node, in: right) == GraphPoint(x: 160, y: 40))
        #expect(position(b.node, in: right) == nil)
    }

    @Test func topAndBottomLineUp() {
        let a = item(0, 10, h: 40), b = item(50, 200, h: 80)
        #expect(position(b.node, in: Arrangement.aligned([a, b], to: .top)) == GraphPoint(x: 50, y: 10))
        #expect(position(a.node, in: Arrangement.aligned([a, b], to: .bottom)) == GraphPoint(x: 0, y: 240))
    }

    @Test func centersLineUpOnTheMiddleOfTheBox() {
        let a = item(0, 0, w: 100), b = item(300, 0, w: 100)
        let placements = Arrangement.aligned([a, b], to: .centerX)
        // The box spans 0...400, so its middle is 200; each 100-wide node centers there.
        #expect(position(a.node, in: placements) == GraphPoint(x: 150, y: 0))
        #expect(position(b.node, in: placements) == GraphPoint(x: 150, y: 0))
        let tall = item(0, 0, h: 50), short = item(0, 100, h: 50)
        let vertical = Arrangement.aligned([tall, short], to: .centerY)
        #expect(position(tall.node, in: vertical) == GraphPoint(x: 0, y: 50))
        #expect(position(short.node, in: vertical) == GraphPoint(x: 0, y: 50))
    }

    @Test func pinnedNodesAreMeasuredButNotMoved() {
        let pinned = item(500, 0, pinned: true), free = item(0, 100)
        let placements = Arrangement.aligned([pinned, free], to: .right)
        #expect(position(pinned.node, in: placements) == nil)
        #expect(position(free.node, in: placements) == GraphPoint(x: 500, y: 100))
    }

    @Test func fewerThanTwoItemsDoNothing() {
        #expect(Arrangement.aligned([], to: .left).isEmpty)
        #expect(Arrangement.aligned([item(0, 0)], to: .left).isEmpty)
        #expect(Arrangement.distributed([item(0, 0), item(300, 0)], along: .horizontal).isEmpty)
    }

    @Test func distributingEvensTheGapsAndKeepsTheOuterTwo() {
        let a = item(0, 0), b = item(120, 0), c = item(500, 0)
        let placements = Arrangement.distributed([c, a, b], along: .horizontal)  // order does not matter
        // Span 0...600 holds 300 of nodes, leaving 300 split into two gaps of 150.
        #expect(position(b.node, in: placements) == GraphPoint(x: 250, y: 0))
        #expect(position(a.node, in: placements) == nil && position(c.node, in: placements) == nil)
    }

    @Test func distributingVerticallyUsesHeights() {
        let a = item(0, 0, h: 40), b = item(0, 10, h: 100), c = item(0, 300, h: 60)
        let placements = Arrangement.distributed([a, b, c], along: .vertical)
        // Span 0...360 holds 200, leaving 160 in two gaps of 80: b starts at 40 + 80.
        #expect(position(b.node, in: placements) == GraphPoint(x: 0, y: 120))
    }

    @Test func aPinnedNodeIsLeftWhereItIs() {
        let a = item(0, 0), b = item(130, 0, pinned: true), c = item(500, 0)
        let placements = Arrangement.distributed([a, b, c], along: .horizontal)
        #expect(placements.isEmpty)
    }
}

@Suite struct AutoArrangeTests {
    private func item(_ x: Double, _ y: Double, w: Double = 100, h: Double = 50, pinned: Bool = false) -> Arrangement.Item {
        Arrangement.Item(node: NodeID(), frame: GraphRect(x: x, y: y, width: w, height: h), isPinned: pinned)
    }

    private func position(_ node: NodeID, in placements: [NodePlacement]) -> GraphPoint? {
        placements.first { $0.node == node }?.position
    }

    private let spacing = GraphSize(width: 80, height: 40)

    @Test func aChainBecomesColumnsLeftToRight() {
        let a = item(500, 300), b = item(0, 0), c = item(200, 900)
        let edges = [Arrangement.Edge(from: a.node, to: b.node), Arrangement.Edge(from: b.node, to: c.node)]
        let placements = Arrangement.layered([a, b, c], links: edges, spacing: spacing)
        // The box's top-left (0, 0) stays; each column is a width plus the gap further right.
        #expect(position(a.node, in: placements) == GraphPoint(x: 0, y: 0))
        #expect(position(b.node, in: placements) == GraphPoint(x: 180, y: 0))
        #expect(position(c.node, in: placements) == GraphPoint(x: 360, y: 0))
    }

    @Test func aNodeSitsAfterItsFurthestInput() {
        let a = item(0, 0), b = item(0, 100), c = item(0, 200)
        let edges = [
            Arrangement.Edge(from: a.node, to: b.node), Arrangement.Edge(from: b.node, to: c.node),
            Arrangement.Edge(from: a.node, to: c.node),
        ]
        let placements = Arrangement.layered([a, b, c], links: edges, spacing: spacing)
        #expect(position(c.node, in: placements)?.x == 360)
    }

    @Test func nodesInOneColumnStackWithAGapAndTheShorterColumnIsCentered() {
        let source = item(0, 0), top = item(0, 0), bottom = item(0, 100)
        let edges = [Arrangement.Edge(from: source.node, to: top.node), Arrangement.Edge(from: source.node, to: bottom.node)]
        let placements = Arrangement.layered([source, top, bottom], links: edges, spacing: spacing)
        // The right column is 50 + 40 + 50 = 140 tall; the lone source is centered on it.
        #expect(position(source.node, in: placements) == GraphPoint(x: 0, y: 45))
        #expect(position(top.node, in: placements) == GraphPoint(x: 180, y: 0))
        #expect(position(bottom.node, in: placements) == GraphPoint(x: 180, y: 90))
    }

    @Test func columnsKeepLinkedNodesInTheSameOrderToAvoidCrossings() {
        // The first source is lower on screen but feeds the lower target, so nothing should cross.
        let s1 = item(0, 200), s2 = item(0, 0), t1 = item(300, 0), t2 = item(300, 200)
        let edges = [Arrangement.Edge(from: s1.node, to: t2.node), Arrangement.Edge(from: s2.node, to: t1.node)]
        let placements = Arrangement.layered([s1, s2, t1, t2], links: edges, spacing: spacing)
        // A node that does not move has no placement, so fall back to where it already is.
        func y(_ item: Arrangement.Item) -> Double { position(item.node, in: placements)?.y ?? item.frame.minY }
        let sourceOrder = y(s1) < y(s2)
        let targetOrder = y(t2) < y(t1)
        #expect(sourceOrder == targetOrder)
    }

    @Test func aLoopStillGetsDistinctColumns() {
        let a = item(0, 0), b = item(0, 100)
        let edges = [Arrangement.Edge(from: a.node, to: b.node), Arrangement.Edge(from: b.node, to: a.node)]
        let placements = Arrangement.layered([a, b], links: edges, spacing: spacing)
        #expect(position(a.node, in: placements) != position(b.node, in: placements))
        #expect(position(b.node, in: placements)?.x == 180)
    }

    @Test func linksOutsideTheItemsAndSelfLinksAreIgnored() {
        let a = item(0, 0), b = item(0, 100)
        let edges = [Arrangement.Edge(from: a.node, to: a.node), Arrangement.Edge(from: NodeID(), to: b.node)]
        let placements = Arrangement.layered([a, b], links: edges, spacing: spacing)
        #expect(position(b.node, in: placements) == GraphPoint(x: 0, y: 90))  // both in column 0
    }

    @Test func aPinnedNodeIsNotMoved() {
        let a = item(0, 0), pinned = item(400, 400, pinned: true)
        let placements = Arrangement.layered([a, pinned], links: [Arrangement.Edge(from: a.node, to: pinned.node)], spacing: spacing)
        #expect(position(pinned.node, in: placements) == nil)
    }

    @Test func fewerThanTwoItemsDoNothing() {
        #expect(Arrangement.layered([item(5, 5)], links: []).isEmpty)
    }

    @Test func laidOutTwiceGivesTheSameResult() {
        let a = item(30, 10), b = item(10, 60), c = item(90, 20)
        let edges = [Arrangement.Edge(from: a.node, to: c.node)]
        #expect(Arrangement.layered([a, b, c], links: edges) == Arrangement.layered([c, b, a], links: edges))
    }
}

@MainActor
@Suite struct ClipboardInteractionTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController
    let clipboard = InMemoryClipboard()

    init() {
        controller = GraphInteractionController(model: model)
        controller.clipboard = clipboard
    }

    @discardableResult
    private func add(_ type: NodeTypeID, x: Double, y: Double = 0, pinned: Bool = false) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y), isPinned: pinned)
        try model.perform(.addNode(node: node))
        return node
    }

    private func link(_ source: Node, _ sink: Node, port: String = "a") throws {
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: PortID(port), direction: .input)))
    }

    @Test func copyPutsTheSelectionOnTheClipboardWithoutChangingTheGraph() throws {
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.sink, x: 300)
        try link(a, b)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        let before = model.graph
        #expect(controller.perform(.copy))
        #expect(model.graph == before)
        #expect(clipboard.fragment?.nodes.count == 2 && clipboard.fragment?.links.count == 1)
    }

    @Test func pasteWithConnectionsLinksTheCopyToTheOriginalsSources() throws {
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.sink, x: 300)
        try link(a, b)
        model.select(node: b.id)
        controller.perform(.copy)
        let before = model.history.undoStack.count
        #expect(controller.perform(.pasteWithConnections(at: GraphPoint(x: 300, y: 400))))
        let copy = try #require(model.selection.nodes.first)
        #expect(model.graph.links.values.contains { $0.source.node == a.id && $0.target.node == copy && $0.target.port == "a" })
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.links.count == 1, "one undo removes the copy and its links")

        #expect(controller.perform(.paste(at: GraphPoint(x: 300, y: 400))))
        #expect(model.graph.links.count == 1, "a plain paste adds no link")
    }

    @Test func copyWithNothingSelectedDoesNothing() {
        #expect(!controller.perform(.copy))
        #expect(clipboard.fragment == nil)
        #expect(!controller.perform(.cut))
        #expect(!controller.perform(.duplicate))
    }

    @Test func pasteCentersOnTheGivenPointAndSelectsTheNewNodes() throws {
        let a = try add(TestKit.source, x: 0)
        model.select(node: a.id)
        controller.perform(.copy)
        let before = model.history.undoStack.count
        #expect(controller.perform(.paste(at: GraphPoint(x: 1000, y: 500))))
        #expect(model.graph.nodes.count == 2)
        let pasted = try #require(model.graph.nodes.values.last)
        #expect(pasted.id != a.id)
        let frame = try #require(model.layout(of: pasted.id)).frame
        #expect(abs(frame.midX - 1000) < 1e-9 && abs(frame.midY - 500) < 1e-9)
        #expect(model.selection.nodes == [pasted.id])
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes.count == 1)
    }

    @Test func pasteWithAnEmptyClipboardDoesNothing() {
        #expect(!controller.perform(.paste(at: nil)))
    }

    @Test func pasteDefaultsToThePointerThenTheViewCenter() throws {
        let a = try add(TestKit.source, x: 0)
        model.select(node: a.id)
        controller.perform(.copy)
        model.viewSize = CGSize(width: 800, height: 600)
        model.camera = GraphCamera()
        controller.perform(.paste(at: nil))
        var pasted = try #require(model.graph.nodes.values.last)
        var frame = try #require(model.layout(of: pasted.id)).frame
        #expect(abs(frame.midX - 400) < 1e-9 && abs(frame.midY - 300) < 1e-9)
        controller.hover(at: CGPoint(x: 200, y: 150))
        controller.perform(.paste(at: nil))
        pasted = try #require(model.graph.nodes.values.last)
        frame = try #require(model.layout(of: pasted.id)).frame
        #expect(abs(frame.midX - 200) < 1e-9 && abs(frame.midY - 150) < 1e-9)
    }

    @Test func pastingTwiceMakesTwoCopies() throws {
        let a = try add(TestKit.source, x: 0)
        model.select(node: a.id)
        controller.perform(.copy)
        controller.perform(.paste(at: GraphPoint(x: 400, y: 0)))
        controller.perform(.paste(at: GraphPoint(x: 800, y: 0)))
        #expect(model.graph.nodes.count == 3)
    }

    @Test func pasteSnapsToTheGridWhenSnappingIsOn() throws {
        let a = try add(TestKit.source, x: 0)
        model.select(node: a.id)
        controller.perform(.copy)
        model.snapsToGrid = true
        controller.perform(.paste(at: GraphPoint(x: 413, y: 307)))
        let pasted = try #require(model.graph.nodes.values.last)
        let spacing = model.theme.gridSpacing
        #expect(pasted.position.x.truncatingRemainder(dividingBy: spacing) == 0)
        #expect(pasted.position.y.truncatingRemainder(dividingBy: spacing) == 0)
    }

    @Test func cutRemovesTheSelectionAndAPasteBringsItBack() throws {
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.sink, x: 300)
        try link(a, b)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        let before = model.history.undoStack.count
        #expect(controller.perform(.cut))
        #expect(model.graph.nodes.isEmpty && model.graph.links.isEmpty)
        #expect(model.history.undoStack.count == before + 1)
        #expect(controller.perform(.paste(at: GraphPoint(x: 100, y: 100))))
        #expect(model.graph.nodes.count == 2 && model.graph.links.count == 1)
    }

    @Test func duplicateMakesAnOffsetCopyAndLeavesTheClipboardAlone() throws {
        let a = try add(TestKit.source, x: 100, y: 100)
        let b = try add(TestKit.sink, x: 400, y: 100)
        try link(a, b)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        let before = model.history.undoStack.count
        #expect(controller.perform(.duplicate))
        #expect(model.graph.nodes.count == 4 && model.graph.links.count == 2)
        #expect(clipboard.fragment == nil)
        let copies = Array(model.graph.nodes.values.suffix(2))
        let offset = GraphInteractionController.duplicateOffset
        #expect(copies[0].position == GraphPoint(x: 100 + offset, y: 100 + offset))
        #expect(model.selection.nodes == Set(copies.map(\.id)))
        #expect(model.history.undoStack.count == before + 1)
        // Duplicating the copy again steps further along.
        controller.perform(.duplicate)
        #expect(model.graph.nodes.values.suffix(2).first?.position.x == 100 + 2 * offset)
    }

    @Test func copyingAGroupTakesItsContents() throws {
        let inside = try add(TestKit.source, x: 20, y: 20)
        let outside = try add(TestKit.source, x: 900, y: 900)
        let group = NodeGroup(title: "Box", bounds: GraphRect(x: 0, y: 0, width: 400, height: 300))
        try model.perform(.addGroup(group: group))
        model.selection = GraphSelection(groups: [group.id])
        controller.perform(.copy)
        #expect(clipboard.fragment?.nodes.map(\.id) == [inside.id])
        #expect(clipboard.fragment?.groups.map(\.title) == ["Box"])
        #expect(!(clipboard.fragment?.nodes.contains { $0.id == outside.id } ?? true))
    }

    @Test func cuttingAGroupRemovesItsContentsToo() throws {
        let inside = try add(TestKit.source, x: 20, y: 20)
        try add(TestKit.source, x: 900, y: 900)
        let group = NodeGroup(title: "Box", bounds: GraphRect(x: 0, y: 0, width: 400, height: 300))
        try model.perform(.addGroup(group: group))
        model.selection = GraphSelection(groups: [group.id])
        controller.perform(.cut)
        #expect(model.graph.groups.isEmpty && model.graph.nodes[inside.id] == nil && model.graph.nodes.count == 1)
    }

    @Test func aPasteInsideASubgraphGoesIntoItsInnerGraph() throws {
        let sink = try add(TestKit.sink, x: 400)
        let conversion = try model.editor.convertToSubgraphCommand(nodes: [sink.id], name: "Wrapped")
        try model.perform(conversion.command)
        let source = try add(TestKit.source, x: 0)
        model.select(node: source.id)
        controller.perform(.copy)
        controller.enterSubgraph(of: conversion.instance)
        let rootNodes = model.editor.graph.nodes.count
        #expect(controller.perform(.paste(at: GraphPoint(x: 0, y: 0))))
        #expect(model.editor.graph.nodes.count == rootNodes)
        #expect(model.editor.subgraphs[conversion.subgraph]?.graph.nodes.count == 2)
        #expect(model.selection.nodes.count == 1)
        try model.undo()
        #expect(model.editor.subgraphs[conversion.subgraph]?.graph.nodes.count == 1)
    }

    @Test func pastingAnInstanceInsideItsOwnSubgraphIsRefused() throws {
        let sink = try add(TestKit.sink, x: 400)
        let conversion = try model.editor.convertToSubgraphCommand(nodes: [sink.id], name: "Wrapped")
        try model.perform(conversion.command)
        model.select(node: conversion.instance)
        controller.perform(.copy)
        controller.enterSubgraph(of: conversion.instance)
        #expect(!controller.perform(.paste(at: nil)))
        #expect(model.editor.subgraphs[conversion.subgraph]?.graph.nodes.count == 1)
    }

    @Test func aFragmentWithAnUnknownTypeIsRefused() throws {
        var fragment = GraphFragment(nodes: [Node(typeID: NodeTypeID("not.here"))])
        fragment.nodes[0].position = .zero
        clipboard.write(fragment)
        #expect(!controller.perform(.paste(at: nil)))
        #expect(model.graph.nodes.isEmpty)
    }

    @Test func keysAndMenusReachTheCommands() throws {
        #expect(CanvasKeyMap.command(for: .character("c"), modifiers: .command) == .copy)
        #expect(CanvasKeyMap.command(for: .character("x"), modifiers: .command) == .cut)
        #expect(CanvasKeyMap.command(for: .character("v"), modifiers: .command) == .paste(at: nil))
        #expect(CanvasKeyMap.command(for: .character("d"), modifiers: .command) == .duplicate)
        #expect(CanvasKeyMap.command(for: .character("c"), modifiers: []) == nil)
        // Paste is enabled in the empty-canvas menu only when the clipboard has something.
        func pasteItem() -> CanvasMenuItem? { controller.contextMenu(at: CGPoint(x: 900, y: 900)).first { $0.title == "Paste" } }
        #expect(pasteItem()?.isEnabled == false)
        clipboard.write(GraphFragment(nodes: [Node(typeID: TestKit.source)]))
        #expect(pasteItem()?.isEnabled == true)
    }
}

@MainActor
@Suite struct ArrangeInteractionTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    private func add(x: Double, y: Double, pinned: Bool = false, type: NodeTypeID = TestKit.source) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y), isPinned: pinned)
        try model.perform(.addNode(node: node))
        return node
    }

    @Test func alignMovesTheSelectedNodesAsOneUndoStep() throws {
        let a = try add(x: 50, y: 0)
        let b = try add(x: 300, y: 120)
        let c = try add(x: 700, y: 60)
        model.selection = GraphSelection(nodes: [a.id, b.id, c.id])
        let before = model.history.undoStack.count
        #expect(controller.perform(.align(.left)))
        #expect(model.graph.nodes.values.allSatisfy { $0.position.x == 50 })
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes[c.id]?.position.x == 700)
    }

    @Test func alignWithOneNodeOrAlreadyAlignedDoesNothing() throws {
        let a = try add(x: 0, y: 0)
        model.select(node: a.id)
        #expect(!controller.perform(.align(.top)))
        let b = try add(x: 300, y: 0)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        #expect(!controller.perform(.align(.top)))
    }

    @Test func distributeSpacesThreeNodesEvenly() throws {
        let a = try add(x: 0, y: 0)
        let b = try add(x: 150, y: 0)
        let c = try add(x: 800, y: 0)
        model.selection = GraphSelection(nodes: [a.id, b.id, c.id])
        #expect(controller.perform(.distribute(.horizontal)))
        let widths = 160.0
        let gap = (800 + widths - 0 - 3 * widths) / 2
        #expect(model.graph.nodes[b.id]?.position.x == widths + gap)
        #expect(model.graph.nodes[a.id]?.position.x == 0 && model.graph.nodes[c.id]?.position.x == 800)
    }

    @Test func distributeNeedsThreeNodes() throws {
        let a = try add(x: 0, y: 0)
        let b = try add(x: 400, y: 0)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        #expect(!controller.perform(.distribute(.horizontal)))
    }

    @Test func pinnedNodesStayWhenAligning() throws {
        let pinned = try add(x: 500, y: 0, pinned: true)
        let free = try add(x: 0, y: 200)
        model.selection = GraphSelection(nodes: [pinned.id, free.id])
        #expect(controller.perform(.align(.right)))
        #expect(model.graph.nodes[pinned.id]?.position.x == 500)
        #expect(model.graph.nodes[free.id]?.position.x == 500)
    }

    @Test func theMenuOffersAlignAndDistributeByHowManyAreSelected() throws {
        let a = try add(x: 0, y: 0), b = try add(x: 300, y: 0), c = try add(x: 600, y: 0)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        func titles() -> [String] { controller.contextMenu(at: CGPoint(x: 60, y: 40)).map(\.title) }
        #expect(titles().contains("Align") && !titles().contains("Distribute"))
        model.selection = GraphSelection(nodes: [a.id, b.id, c.id])
        #expect(titles().contains("Align") && titles().contains("Distribute"))
        model.selection = GraphSelection(nodes: [a.id])
        #expect(!titles().contains("Align"))
    }

    @Test func groupSelectionAddsAGroupAroundTheNodesAsOneUndoStep() throws {
        let a = try add(x: 100, y: 100), b = try add(x: 500, y: 300)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        let before = model.history.undoStack.count
        #expect(controller.perform(.groupSelection))
        #expect(model.history.undoStack.count == before + 1)
        let group = try #require(model.graph.groups.values.first)
        for node in [a, b] {
            let frame = try #require(model.layout(of: node.id)?.frame)
            #expect(group.bounds.contains(frame))
            // The title bar must not overlap the nodes.
            #expect(frame.minY >= group.bounds.minY + GraphInteractionController.groupTitleHeight)
        }
        #expect(model.selection == GraphSelection(groups: [group.id]))
        try model.undo()
        #expect(model.graph.groups.isEmpty)
    }

    @Test func groupSelectionNeedsNodesButAddGroupDoesNot() throws {
        #expect(!controller.perform(.groupSelection))
        #expect(controller.perform(.addGroup(at: GraphPoint(x: 0, y: 0))))
        #expect(model.graph.groups.count == 1)
    }

    @Test func groupKeyAndMenuItems() throws {
        #expect(CanvasKeyMap.command(for: .character("g"), modifiers: [.command, .option]) == .groupSelection)
        #expect(CanvasKeyMap.command(for: .character("g"), modifiers: .command) == .createSubgraph)
        let a = try add(x: 0, y: 0)
        model.selection = GraphSelection(nodes: [a.id])
        #expect(controller.contextMenu(at: CGPoint(x: 60, y: 40)).map(\.title).contains("Group"))
        #expect(controller.contextMenu(at: CGPoint(x: 5000, y: 5000)).map(\.title).contains("Add Group"))
    }

    @Test func autoArrangeLaysTheSelectionOutByDataFlowAsOneUndoStep() throws {
        let a = try add(x: 700, y: 300)
        let b = try add(x: 0, y: 0, type: TestKit.sink)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: a.id, port: "out", direction: .output),
            target: PortAddress(node: b.id, port: "a", direction: .input)))
        model.selection = GraphSelection(nodes: [a.id, b.id])
        let before = model.history.undoStack.count
        #expect(controller.perform(.autoArrange))
        let left = model.graph.nodes[a.id]!.position.x, right = model.graph.nodes[b.id]!.position.x
        #expect(left < right)
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes[a.id]?.position == GraphPoint(x: 700, y: 300))
    }

    @Test func autoArrangeWithNothingSelectedArrangesEveryNode() throws {
        let a = try add(x: 900, y: 0)
        let b = try add(x: 0, y: 500, type: TestKit.sink)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: a.id, port: "out", direction: .output),
            target: PortAddress(node: b.id, port: "a", direction: .input)))
        model.clearSelection()
        #expect(controller.perform(.autoArrange))
        #expect(model.graph.nodes[a.id]!.position.x < model.graph.nodes[b.id]!.position.x)
    }

    @Test func autoArrangeLeavesPinnedNodesAndSingleNodesAlone() throws {
        let a = try add(x: 0, y: 0, pinned: true)
        #expect(!controller.perform(.autoArrange))  // one node in the graph
        let b = try add(x: 400, y: 100, pinned: true)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        #expect(!controller.perform(.autoArrange))
        #expect(model.graph.nodes[b.id]?.position == GraphPoint(x: 400, y: 100))
    }
}
