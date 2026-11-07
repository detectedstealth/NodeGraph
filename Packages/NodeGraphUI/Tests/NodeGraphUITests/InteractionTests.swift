import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

/// A model and controller at zoom 1 with the camera at the origin, so screen and graph points
/// are the same and tests can use plain coordinates.
@MainActor
private struct Rig {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    @discardableResult
    func add(_ type: NodeTypeID, x: Double, y: Double, pinned: Bool = false) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y), isPinned: pinned)
        try model.perform(.addNode(node: node))
        return node
    }

    func position(_ node: Node) -> GraphPoint { model.graph.nodes[node.id]!.position }

    func port(_ node: Node, _ id: String, _ direction: PortDirection) -> CGPoint {
        let layout = model.layout(of: node.id)!
        let ports = direction == .input ? layout.inputs : layout.outputs
        return CGPoint(ports.first { $0.definition.id.rawValue == id }!.position)
    }

    func drag(from a: CGPoint, to b: CGPoint, modifiers: InputModifiers = [], kind: PointerKind = .mouse) {
        controller.pointerDown(at: a, modifiers: modifiers, kind: kind)
        let steps = 4
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            controller.pointerMoved(
                to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), modifiers: modifiers)
        }
        controller.pointerUp(at: b)
    }

    func click(_ p: CGPoint, modifiers: InputModifiers = []) {
        controller.pointerDown(at: p, modifiers: modifiers, kind: .mouse)
        controller.pointerUp(at: p)
    }
}

private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

@MainActor
@Suite struct SelectionInteractionTests {
    @Test func clickSelectsANodeAndEmptyClickClears() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        rig.click(pt(60, 40))
        #expect(rig.model.selection.nodes == [a.id])
        rig.click(pt(900, 900))
        #expect(rig.model.selection.isEmpty)
    }

    @Test func shiftClickAddsAndTogglesOff() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        let b = try rig.add(TestKit.source, x: 400, y: 0)
        rig.click(pt(60, 40))
        rig.click(pt(460, 40), modifiers: .shift)
        #expect(rig.model.selection.nodes == [a.id, b.id])
        rig.click(pt(460, 40), modifiers: .shift)
        #expect(rig.model.selection.nodes == [a.id])
    }

    @Test func plainClickOnOneOfSeveralSelectedNarrowsOnRelease() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        let b = try rig.add(TestKit.source, x: 400, y: 0)
        rig.model.selection = GraphSelection(nodes: [a.id, b.id])
        rig.click(pt(60, 40))
        #expect(rig.model.selection.nodes == [a.id])
    }

    @Test func clickingALinkSelectsIt() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        let b = try rig.add(TestKit.sink, x: 400, y: 0)
        try rig.model.connect(ConnectionProposal(
            source: PortAddress(node: a.id, port: "out", direction: .output),
            target: PortAddress(node: b.id, port: "a", direction: .input)))
        let link = try #require(rig.model.graph.links.values.first)
        let middle = try #require(rig.model.linkPath(of: link)).polyline(curveSteps: 32)[16]
        rig.click(CGPoint(middle))
        #expect(rig.model.selection.links == [link.id])
    }
}

@MainActor
@Suite struct MoveResizeInteractionTests {
    @Test func dragMovesTheNodeAsOneUndoStep() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        let before = rig.model.history.undoStack.count
        rig.drag(from: pt(60, 40), to: pt(160, 90))
        #expect(rig.position(a) == GraphPoint(x: 100, y: 50))
        #expect(rig.model.history.undoStack.count == before + 1)
        try rig.model.undo()
        #expect(rig.position(a) == .zero)
    }

    @Test func tinyMovementIsAClickNotADrag() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        rig.controller.pointerDown(at: pt(60, 40), kind: .mouse)
        rig.controller.pointerMoved(to: pt(61, 41))
        rig.controller.pointerUp(at: pt(61, 41))
        #expect(rig.position(a) == .zero)
        #expect(rig.model.selection.nodes == [a.id])
    }

    @Test func draggingASelectedNodeMovesTheWholeSelection() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        let b = try rig.add(TestKit.source, x: 400, y: 0)
        rig.model.selection = GraphSelection(nodes: [a.id, b.id])
        rig.drag(from: pt(60, 40), to: pt(60, 140))
        #expect(rig.position(a) == GraphPoint(x: 0, y: 100))
        #expect(rig.position(b) == GraphPoint(x: 400, y: 100))
        #expect(rig.model.selection.nodes == [a.id, b.id])
    }

    @Test func pinnedNodesStayPut() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0, pinned: true)
        rig.drag(from: pt(60, 40), to: pt(200, 200))
        #expect(rig.position(a) == .zero)
    }

    @Test func snapToGridSnapsTheNodeAndOptionInvertsIt() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        rig.model.snapsToGrid = true
        rig.drag(from: pt(60, 40), to: pt(60 + 33, 40 + 47))
        #expect(rig.position(a) == GraphPoint(x: 40, y: 40))
        rig.drag(from: pt(100, 80), to: pt(100 + 13, 80 + 7), modifiers: .option)
        #expect(rig.position(a) == GraphPoint(x: 53, y: 47))
    }

    @Test func cornerDragResizesWithinTheMinimum() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.sink, x: 0, y: 0)
        let frame = try #require(rig.model.layout(of: a.id)).frame
        let corner = pt(frame.maxX - 4, frame.maxY - 4)
        rig.drag(from: corner, to: pt(corner.x + 100, corner.y + 60))
        #expect(rig.model.graph.nodes[a.id]?.size == GraphSize(width: frame.size.width + 100, height: frame.size.height + 60))
        // Shrinking far past the minimum stops at it.
        let big = try #require(rig.model.layout(of: a.id))
        let newCorner = pt(big.frame.maxX - 4, big.frame.maxY - 4)
        rig.drag(from: newCorner, to: pt(newCorner.x - 1000, newCorner.y - 1000))
        let small = try #require(rig.model.layout(of: a.id))
        #expect(small.frame.size == small.minimumSize)
        #expect(small.frame.size.width == rig.model.metrics.minimumWidth)
    }

    @Test func cancelPutsTheNodeBackAndLeavesNoUndoStep() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        let before = rig.model.history.undoStack.count
        rig.controller.pointerDown(at: pt(60, 40), kind: .mouse)
        rig.controller.pointerMoved(to: pt(160, 140))
        #expect(rig.position(a) == GraphPoint(x: 100, y: 100))
        rig.controller.cancel()
        #expect(rig.position(a) == .zero)
        #expect(rig.model.history.undoStack.count == before)
        #expect(!rig.controller.isDragging)
    }
}

@MainActor
@Suite struct MarqueeAndCameraInteractionTests {
    @Test func mouseDragOnEmptyCanvasSelectsWithAMarquee() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 100, y: 100)
        let b = try rig.add(TestKit.source, x: 500, y: 100)
        rig.controller.pointerDown(at: pt(50, 50), kind: .mouse)
        rig.controller.pointerMoved(to: pt(350, 300))
        #expect(rig.controller.marquee == GraphRect(x: 50, y: 50, width: 300, height: 250))
        #expect(rig.model.selection.nodes == [a.id])
        rig.controller.pointerUp(at: pt(350, 300))
        #expect(rig.controller.marquee == nil)
        #expect(rig.model.selection.nodes == [a.id])
        _ = b
    }

    @Test func shiftMarqueeAddsToTheSelection() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 100, y: 100)
        let b = try rig.add(TestKit.source, x: 500, y: 100)
        rig.model.selection = GraphSelection(nodes: [b.id])
        rig.drag(from: pt(50, 50), to: pt(350, 300), modifiers: .shift)
        #expect(rig.model.selection.nodes == [a.id, b.id])
    }

    @Test func marqueeSelectsGroupsItFullyContains() throws {
        let rig = Rig()
        let group = NodeGroup(title: "G", bounds: GraphRect(x: 100, y: 100, width: 100, height: 100))
        try rig.model.perform(.addGroup(group: group))
        rig.drag(from: pt(50, 50), to: pt(300, 300))
        #expect(rig.model.selection.groups == [group.id])
    }

    @Test func fingerDragOnEmptyCanvasPans() throws {
        let rig = Rig()
        rig.drag(from: pt(300, 300), to: pt(400, 350), kind: .touch)
        // The graph followed the finger, so the view moved the other way.
        #expect(rig.model.camera.origin == GraphPoint(x: -100, y: -50))
        #expect(rig.model.selection.isEmpty)
    }

    @Test func pinchDoesNotCompoundAndKeepsTheAnchorStill() throws {
        let rig = Rig()
        let anchor = pt(300, 200)
        let fixed = rig.model.camera.graphPoint(forScreen: anchor)
        for scale in [1.1, 1.3, 1.6, 2.0] { rig.controller.magnify(totalScale: scale, anchor: anchor) }
        #expect(rig.model.camera.zoom == 2)
        let after = rig.model.camera.graphPoint(forScreen: anchor)
        #expect(abs(after.x - fixed.x) < 1e-9 && abs(after.y - fixed.y) < 1e-9)
        rig.controller.endMagnify()
        // The next pinch starts from the new zoom.
        rig.controller.magnify(totalScale: 1.5, anchor: anchor)
        #expect(rig.model.camera.zoom == 3)
    }

    @Test func scrollPansTheCamera() throws {
        let rig = Rig()
        rig.controller.pan(byScreen: CGSize(width: 30, height: -20))
        #expect(rig.model.camera.origin == GraphPoint(x: -30, y: 20))
    }

    @Test func pinchStartedMidDragCancelsTheDrag() throws {
        let rig = Rig()
        let a = try rig.add(TestKit.source, x: 0, y: 0)
        rig.controller.pointerDown(at: pt(60, 40), kind: .touch)
        rig.controller.pointerMoved(to: pt(160, 140))
        rig.controller.magnify(totalScale: 1.2, anchor: pt(100, 100))
        #expect(rig.position(a) == .zero)
    }
}

@MainActor
@Suite struct ConnectionInteractionTests {
    private func pair() throws -> (Rig, Node, Node) {
        let rig = Rig()
        let source = try rig.add(TestKit.source, x: 0, y: 0)
        let sink = try rig.add(TestKit.sink, x: 400, y: 0)
        return (rig, source, sink)
    }

    private func linkCount(_ rig: Rig) -> Int { rig.model.graph.links.count }

    @Test func draggingFromAnOutputToAnInputConnects() throws {
        let (rig, source, sink) = try pair()
        rig.drag(from: rig.port(source, "out", .output), to: rig.port(sink, "b", .input))
        let link = try #require(rig.model.graph.links.values.first)
        #expect(link.source.node == source.id && link.target.port == "b")
        try rig.model.undo()
        #expect(linkCount(rig) == 0)
    }

    @Test func draggingFromAnInputConnects() throws {
        let (rig, source, sink) = try pair()
        rig.drag(from: rig.port(sink, "a", .input), to: rig.port(source, "out", .output))
        #expect(linkCount(rig) == 1)
    }

    @Test func draftShowsAValidCandidateAndHidesWhenNone() throws {
        let (rig, source, sink) = try pair()
        rig.controller.pointerDown(at: rig.port(source, "out", .output), kind: .mouse)
        rig.controller.pointerMoved(to: pt(300, 200))
        #expect(rig.controller.draft?.candidate == nil)
        #expect(rig.controller.draft?.pointer == GraphPoint(x: 300, y: 200))
        rig.controller.pointerMoved(to: rig.port(sink, "a", .input))
        #expect(rig.controller.draft?.candidate?.port == "a")
        rig.controller.pointerUp(at: rig.port(sink, "a", .input))
        #expect(rig.controller.draft == nil)
    }

    @Test func aRefusedConnectionShowsAsRejectedAndDoesNothing() throws {
        let rig = Rig()
        let merge = try rig.add(TestKit.merge, x: 0, y: 0)
        let out = rig.port(merge, "out", .output)
        let own = rig.port(merge, "in_1", .input)
        rig.controller.pointerDown(at: out, kind: .mouse)
        rig.controller.pointerMoved(to: own)
        #expect(rig.controller.draft?.rejected?.port == "in_1")
        #expect(rig.controller.draft?.candidate == nil)
        rig.controller.pointerUp(at: own)
        #expect(linkCount(rig) == 0)
    }

    @Test func releaseOnANodeBodyUsesItsFirstAcceptingPort() throws {
        let (rig, source, sink) = try pair()
        rig.drag(from: rig.port(source, "out", .output), to: pt(480, 60))
        let link = try #require(rig.model.graph.links.values.first)
        #expect(link.target.node == sink.id && link.target.port == "a")
    }

    @Test func releaseOnEmptyCanvasReportsThePortAndPlace() throws {
        let (rig, source, _) = try pair()
        var reported: (PortAddress, GraphPoint)?
        rig.controller.onLinkReleasedOnEmpty = { reported = ($0, $1) }
        rig.drag(from: rig.port(source, "out", .output), to: pt(300, 500))
        #expect(reported?.0.port == "out")
        #expect(reported?.1 == GraphPoint(x: 300, y: 500))
        #expect(linkCount(rig) == 0)
    }

    @Test func draggingAConnectedInputMovesTheLinkAsOneStep() throws {
        let (rig, source, sink) = try pair()
        try rig.model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let original = try #require(rig.model.graph.links.values.first)
        let before = rig.model.history.undoStack.count
        rig.controller.pointerDown(at: rig.port(sink, "a", .input), kind: .mouse)
        rig.controller.pointerMoved(to: pt(300, 300))
        #expect(rig.controller.hiddenLinks == [original.id])
        rig.controller.pointerMoved(to: rig.port(sink, "b", .input))
        rig.controller.pointerUp(at: rig.port(sink, "b", .input))
        let link = try #require(rig.model.graph.links.values.first)
        #expect(rig.model.graph.links.count == 1 && link.target.port == "b")
        #expect(rig.model.history.undoStack.count == before + 1)
        try rig.model.undo()
        #expect(rig.model.graph.links.values.first?.target.port == "a")
    }

    @Test func droppingAPickedUpLinkOnEmptyCanvasDisconnectsIt() throws {
        let (rig, source, sink) = try pair()
        try rig.model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        rig.drag(from: rig.port(sink, "a", .input), to: pt(300, 600))
        #expect(linkCount(rig) == 0)
        try rig.model.undo()
        #expect(linkCount(rig) == 1)
    }

    @Test func droppingAPickedUpLinkBackOnItsInputChangesNothing() throws {
        let (rig, source, sink) = try pair()
        try rig.model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let original = try #require(rig.model.graph.links.values.first)
        let before = rig.model.revision
        rig.drag(from: rig.port(sink, "a", .input), to: pt(300, 300))
        // The drag above ended on empty canvas. Pick it up again and put it back.
        try rig.model.undo()
        let revision = rig.model.revision
        _ = before
        rig.controller.pointerDown(at: rig.port(sink, "a", .input), kind: .mouse)
        rig.controller.pointerMoved(to: pt(300, 300))
        rig.controller.pointerMoved(to: rig.port(sink, "a", .input))
        rig.controller.pointerUp(at: rig.port(sink, "a", .input))
        #expect(rig.model.revision == revision)
        #expect(rig.model.graph.links[original.id] != nil)
    }

    @Test func shiftDragMovesEveryLinkOfAnOutputToAnotherOutput() throws {
        let rig = Rig()
        let first = try rig.add(TestKit.source, x: 0, y: 0)
        let second = try rig.add(TestKit.source, x: 0, y: 300)
        let sink = try rig.add(TestKit.sink, x: 400, y: 0)
        let out1 = PortAddress(node: first.id, port: "out", direction: .output)
        try rig.model.connect(ConnectionProposal(
            source: out1, target: PortAddress(node: sink.id, port: "a", direction: .input)))
        try rig.model.connect(ConnectionProposal(
            source: out1, target: PortAddress(node: sink.id, port: "b", direction: .input)))
        rig.drag(from: rig.port(first, "out", .output), to: rig.port(second, "out", .output), modifiers: .shift)
        #expect(rig.model.graph.links.count == 2)
        #expect(rig.model.graph.links.values.allSatisfy { $0.source.node == second.id })
        try rig.model.undo()
        #expect(rig.model.graph.links.values.allSatisfy { $0.source.node == first.id })
    }
}

@MainActor
@Suite struct GroupInteractionTests {
    @Test func draggingTheTitleBarMovesTheGroupWithItsNodes() throws {
        let rig = Rig()
        let node = try rig.add(TestKit.source, x: 100, y: 100)
        let group = NodeGroup(title: "G", bounds: GraphRect(x: 50, y: 50, width: 400, height: 300))
        try rig.model.perform(.addGroup(group: group))
        let before = rig.model.history.undoStack.count
        rig.drag(from: pt(300, 60), to: pt(340, 100))
        #expect(rig.model.graph.groups[group.id]?.bounds.origin == GraphPoint(x: 90, y: 90))
        #expect(rig.position(node) == GraphPoint(x: 140, y: 140))
        #expect(rig.model.history.undoStack.count == before + 1)
    }

    @Test func draggingTheGroupBodyIsAMarqueeNotAMove() throws {
        let rig = Rig()
        let group = NodeGroup(title: "G", bounds: GraphRect(x: 50, y: 50, width: 400, height: 300))
        try rig.model.perform(.addGroup(group: group))
        rig.drag(from: pt(200, 250), to: pt(260, 300))
        #expect(rig.model.graph.groups[group.id]?.bounds == group.bounds)
    }

    @Test func draggingTheCornerResizesTheGroup() throws {
        let rig = Rig()
        let group = NodeGroup(title: "G", bounds: GraphRect(x: 50, y: 50, width: 400, height: 300))
        try rig.model.perform(.addGroup(group: group))
        rig.drag(from: pt(445, 345), to: pt(545, 395))
        #expect(rig.model.graph.groups[group.id]?.bounds == GraphRect(x: 50, y: 50, width: 500, height: 350))
        rig.drag(from: pt(545, 395), to: pt(-500, -500))
        let size = try #require(rig.model.graph.groups[group.id]).bounds.size
        #expect(size == GraphSize(width: 40, height: 40))
    }
}
