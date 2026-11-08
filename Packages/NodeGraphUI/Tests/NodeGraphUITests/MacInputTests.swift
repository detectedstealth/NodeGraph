import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct CanvasKeyMapTests {
    @Test func editingKeys() {
        #expect(CanvasKeyMap.command(for: .delete, modifiers: []) == .deleteSelection)
        #expect(CanvasKeyMap.command(for: .escape, modifiers: []) == .escape)
        #expect(CanvasKeyMap.command(for: .character("a"), modifiers: .command) == .selectAll)
        #expect(CanvasKeyMap.command(for: .character("a"), modifiers: []) == nil)
    }

    @Test func arrowsNudgeAndShiftMakesItTenCells() {
        #expect(CanvasKeyMap.command(for: .left, modifiers: []) == .nudge(dx: -1, dy: 0))
        #expect(CanvasKeyMap.command(for: .down, modifiers: []) == .nudge(dx: 0, dy: 1))
        #expect(CanvasKeyMap.command(for: .right, modifiers: .shift) == .nudge(dx: 10, dy: 0))
        #expect(CanvasKeyMap.command(for: .up, modifiers: .shift) == .nudge(dx: 0, dy: -10))
    }

    @Test func zoomKeys() {
        #expect(CanvasKeyMap.command(for: .character("0"), modifiers: .command) == .resetZoom)
        #expect(CanvasKeyMap.command(for: .character("="), modifiers: .command) == .zoomIn)
        #expect(CanvasKeyMap.command(for: .character("-"), modifiers: .command) == .zoomOut)
        #expect(CanvasKeyMap.command(for: .character("f"), modifiers: []) == .zoomToFit)
        #expect(CanvasKeyMap.command(for: .character("F"), modifiers: .shift) == .zoomToFit)
        // Command-F belongs to the app (find), not the canvas.
        #expect(CanvasKeyMap.command(for: .character("f"), modifiers: .command) == nil)
    }
}

@MainActor
@Suite struct CanvasCommandTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    @discardableResult
    private func add(_ type: NodeTypeID, x: Double, y: Double = 0) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y))
        try model.perform(.addNode(node: node))
        return node
    }

    private func connect(_ source: Node, _ sink: Node, port: String = "a") throws {
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: PortID(port), direction: .input)))
    }

    @Test func selectAllSelectsNodesAndGroups() throws {
        let a = try add(TestKit.source, x: 0)
        let group = NodeGroup(title: "G", bounds: GraphRect(x: -10, y: -10, width: 400, height: 300))
        try model.perform(.addGroup(group: group))
        #expect(controller.perform(.selectAll))
        #expect(model.selection.nodes == [a.id] && model.selection.groups == [group.id])
    }

    @Test func escapeClearsTheSelectionOrCancelsADrag() throws {
        let a = try add(TestKit.source, x: 0)
        model.select(node: a.id)
        #expect(controller.perform(.escape))
        #expect(model.selection.isEmpty)
        #expect(!controller.perform(.escape))  // nothing left to do, so the key is not consumed

        controller.pointerDown(at: CGPoint(x: 60, y: 40), kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: 160, y: 140))
        #expect(controller.perform(.escape))
        #expect(model.graph.nodes[a.id]?.position == .zero)
    }

    @Test func deleteRemovesTheSelectionAsOneStep() throws {
        let source = try add(TestKit.source, x: 0)
        let sink = try add(TestKit.sink, x: 400)
        let other = try add(TestKit.source, x: 0, y: 300)
        try connect(source, sink)
        model.selection = GraphSelection(nodes: [source.id, other.id])
        let before = model.history.undoStack.count
        #expect(controller.perform(.deleteSelection))
        #expect(model.graph.nodes.keys.elements == [sink.id])
        #expect(model.graph.links.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes.count == 3 && model.graph.links.count == 1)
    }

    @Test func deleteRemovesSelectedLinksAndGroupsButKeepsGroupMembers() throws {
        let source = try add(TestKit.source, x: 0)
        let sink = try add(TestKit.sink, x: 400)
        try connect(source, sink)
        let group = NodeGroup(title: "G", bounds: GraphRect(x: -10, y: -10, width: 300, height: 200))
        try model.perform(.addGroup(group: group))
        model.selection = GraphSelection(links: [model.graph.links.keys[0]], groups: [group.id])
        #expect(controller.perform(.deleteSelection))
        #expect(model.graph.links.isEmpty && model.graph.groups.isEmpty)
        #expect(model.graph.nodes.count == 2)
    }

    @Test func deleteWithNothingSelectedDoesNothing() {
        #expect(!controller.perform(.deleteSelection))
    }

    @Test func nudgeMovesByGridCellsAndSkipsPinnedNodes() throws {
        let a = try add(TestKit.source, x: 0)
        let pinned = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 300), isPinned: true)
        try model.perform(.addNode(node: pinned))
        model.selection = GraphSelection(nodes: [a.id, pinned.id])
        let cell = model.theme.gridSpacing
        #expect(controller.perform(.nudge(dx: 2, dy: -1)))
        #expect(model.graph.nodes[a.id]?.position == GraphPoint(x: 2 * cell, y: -cell))
        #expect(model.graph.nodes[pinned.id]?.position == GraphPoint(x: 0, y: 300))
    }

    @Test func nudgingAGroupMovesItsNodesOnlyOnce() throws {
        let node = try add(TestKit.source, x: 50, y: 50)
        let group = NodeGroup(title: "G", bounds: GraphRect(x: 0, y: 0, width: 400, height: 300))
        try model.perform(.addGroup(group: group))
        model.selection = GraphSelection(nodes: [node.id], groups: [group.id])
        let cell = model.theme.gridSpacing
        #expect(controller.perform(.nudge(dx: 1, dy: 0)))
        #expect(model.graph.nodes[node.id]?.position == GraphPoint(x: 50 + cell, y: 50))
        #expect(model.graph.groups[group.id]?.bounds.origin == GraphPoint(x: cell, y: 0))
    }

    @Test func collapsePinAndModeApplyToTheSelectionAndToggle() throws {
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.source, x: 300)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        controller.perform(.toggleCollapsed)
        #expect(model.graph.nodes.values.allSatisfy { $0.isCollapsed })
        controller.perform(.toggleCollapsed)
        #expect(model.graph.nodes.values.allSatisfy { !$0.isCollapsed })
        controller.perform(.togglePinned)
        #expect(model.graph.nodes.values.allSatisfy { $0.isPinned })
        controller.perform(.setMode(.muted))
        #expect(model.graph.nodes.values.allSatisfy { $0.mode == .muted })
        try model.undo()
        #expect(model.graph.nodes.values.allSatisfy { $0.mode == .always })
    }

    @Test func mixedCollapseStateCollapsesEverything() throws {
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.source, x: 300)
        try model.perform(.setNodeAttribute(node: a.id, attribute: .isCollapsed(value: true)))
        model.selection = GraphSelection(nodes: [a.id, b.id])
        controller.perform(.toggleCollapsed)
        #expect(model.graph.nodes.values.allSatisfy { $0.isCollapsed })
    }

    @Test func disconnectRemovesEveryLinkOfTheSelectedNodes() throws {
        let source = try add(TestKit.source, x: 0)
        let sink = try add(TestKit.sink, x: 400)
        try connect(source, sink, port: "a")
        try connect(source, sink, port: "b")
        model.select(node: source.id)
        #expect(controller.perform(.disconnectSelection))
        #expect(model.graph.links.isEmpty)
        #expect(!controller.perform(.disconnectSelection))
    }

    @Test func waypointGoesBetweenTheNearestStops() throws {
        let source = try add(TestKit.source, x: 0)
        let sink = try add(TestKit.sink, x: 800)
        try connect(source, sink)
        let id = model.graph.links.keys[0]
        let first = GraphPoint(x: 300, y: 0), second = GraphPoint(x: 600, y: 0)
        try model.perform(.setLinkWaypoints(link: id, waypoints: [first, second]))
        #expect(controller.perform(.addWaypoint(id, at: GraphPoint(x: 450, y: 5))))
        #expect(model.graph.links[id]?.waypoints == [first, GraphPoint(x: 450, y: 5), second])
        #expect(controller.perform(.addWaypoint(id, at: GraphPoint(x: 100, y: 5))))
        #expect(model.graph.links[id]?.waypoints.first == GraphPoint(x: 100, y: 5))
    }

    @Test func zoomCommandsZoomAboutTheViewCenter() {
        model.viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: 400, y: 300)
        let fixed = model.camera.graphPoint(forScreen: center)
        controller.perform(.zoomIn)
        #expect(model.camera.zoom == 1.25)
        controller.perform(.zoomOut)
        controller.perform(.zoomOut)
        #expect(abs(model.camera.zoom - 0.8) < 1e-9)
        controller.perform(.resetZoom)
        #expect(model.camera.zoom == 1)
        let after = model.camera.graphPoint(forScreen: center)
        #expect(abs(after.x - fixed.x) < 1e-9 && abs(after.y - fixed.y) < 1e-9)
    }

    @Test func snapToGridToggles() {
        #expect(!model.snapsToGrid)
        controller.perform(.toggleSnapToGrid)
        #expect(model.snapsToGrid)
    }
}

@MainActor
@Suite struct ContextMenuTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    private func titles(_ items: [CanvasMenuItem]) -> [String] {
        items.filter { $0.kind != .separator }.map(\.title)
    }

    @Test func rightClickOnAnUnselectedNodeSelectsItAndOffersNodeActions() throws {
        let a = Node(typeID: TestKit.source, position: .zero)
        let b = Node(typeID: TestKit.source, position: GraphPoint(x: 400, y: 0))
        try model.perform(.addNode(node: a))
        try model.perform(.addNode(node: b))
        model.select(node: b.id)
        let items = controller.contextMenu(at: CGPoint(x: 60, y: 40))
        #expect(model.selection.nodes == [a.id])
        #expect(titles(items) == ["Copy", "Cut", "Duplicate", "Collapse", "Pin", "Mode", "Shape", "Title Bar", "Disconnect All", "Create Subgraph…", "Delete"])
        #expect(items.first { $0.title == "Disconnect All" }?.isEnabled == false)
    }

    @Test func rightClickOnASelectedNodeKeepsTheWholeSelection() throws {
        let a = Node(typeID: TestKit.source, position: .zero)
        let b = Node(typeID: TestKit.source, position: GraphPoint(x: 400, y: 0))
        try model.perform(.addNode(node: a))
        try model.perform(.addNode(node: b))
        model.selection = GraphSelection(nodes: [a.id, b.id])
        _ = controller.contextMenu(at: CGPoint(x: 60, y: 40))
        #expect(model.selection.nodes == [a.id, b.id])
    }

    @Test func menuReflectsNodeState() throws {
        let a = Node(typeID: TestKit.source, position: .zero, mode: .muted, isCollapsed: true, isPinned: true)
        try model.perform(.addNode(node: a))
        let items = controller.contextMenu(at: CGPoint(x: 60, y: 14))
        #expect(titles(items).filter { $0 == "Expand" || $0 == "Unpin" } == ["Expand", "Unpin"])
        guard case .submenu(let modes) = try #require(items.first { $0.title == "Mode" }).kind else {
            Issue.record("expected a submenu")
            return
        }
        #expect(modes.filter(\.isChecked).map(\.title) == ["Muted"])
    }

    @Test func rightClickOnALinkOffersAReroutePointAtThatSpot() throws {
        let source = Node(typeID: TestKit.source, position: .zero)
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 600, y: 300))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let link = model.graph.links.keys[0]
        let middle = try #require(model.linkPath(of: model.graph.links[link]!)).polyline(curveSteps: 32)[16]
        let items = controller.contextMenu(at: CGPoint(middle))
        #expect(model.selection.links == [link])
        #expect(titles(items) == ["Add Reroute Point", "Delete Link"])
        #expect(items.first?.kind == .command(.addWaypoint(link, at: middle)))
    }

    @Test func rightClickOnEmptyCanvasClearsSelectionAndOffersViewActions() throws {
        let a = Node(typeID: TestKit.source, position: .zero)
        try model.perform(.addNode(node: a))
        model.select(node: a.id)
        model.snapsToGrid = true
        let items = controller.contextMenu(at: CGPoint(x: 900, y: 900))
        #expect(model.selection.isEmpty)
        #expect(titles(items) == ["Add Node…", "Paste", "Select All", "Zoom to Fit", "Actual Size", "Snap to Grid"])
        #expect(items.first { $0.title == "Snap to Grid" }?.isChecked == true)
    }

    @Test func rightClickOnAGroupTitleOffersDeleteGroup() throws {
        let group = NodeGroup(title: "G", bounds: GraphRect(x: 0, y: 0, width: 400, height: 300))
        try model.perform(.addGroup(group: group))
        let items = controller.contextMenu(at: CGPoint(x: 100, y: 10))
        #expect(model.selection.groups == [group.id])
        #expect(titles(items) == ["Copy", "Cut", "Duplicate", "Delete Group"])
    }
}

@MainActor
@Suite struct ScrollAndHoverTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    @Test func trackpadScrollPansTheView() {
        controller.scroll(by: CGSize(width: 20, height: -10), at: CGPoint(x: 100, y: 100), isPrecise: true)
        #expect(model.camera.origin == GraphPoint(x: -20, y: 10))
        #expect(model.camera.zoom == 1)
    }

    @Test func trackpadScrollWithCommandZoomsAboutThePointer() {
        let anchor = CGPoint(x: 300, y: 200)
        let fixed = model.camera.graphPoint(forScreen: anchor)
        controller.scroll(by: CGSize(width: 0, height: 20), at: anchor, modifiers: .command, isPrecise: true)
        #expect(model.camera.zoom > 1)
        let after = model.camera.graphPoint(forScreen: anchor)
        #expect(abs(after.x - fixed.x) < 1e-9 && abs(after.y - fixed.y) < 1e-9)
        controller.scroll(by: CGSize(width: 0, height: -40), at: anchor, modifiers: .option, isPrecise: true)
        #expect(model.camera.zoom < 1)
    }

    @Test func mouseWheelZoomsAboutThePointer() {
        let anchor = CGPoint(x: 300, y: 200)
        let fixed = model.camera.graphPoint(forScreen: anchor)
        controller.scroll(by: CGSize(width: 0, height: 3), at: anchor, isPrecise: false)
        #expect(model.camera.zoom > 1)
        let after = model.camera.graphPoint(forScreen: anchor)
        #expect(abs(after.x - fixed.x) < 1e-9 && abs(after.y - fixed.y) < 1e-9)
    }

    @Test func scrollingFarCannotLeaveTheZoomRange() {
        for _ in 0..<100 { controller.scroll(by: CGSize(width: 0, height: 50), at: .zero, isPrecise: false) }
        #expect(model.camera.zoom == GraphCamera.zoomRange.upperBound)
    }

    @Test func hoverReportsPortsNodesAndLinks() throws {
        let source = Node(typeID: TestKit.source, position: .zero)
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 600, y: 300))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        controller.hover(at: CGPoint(x: 60, y: 40))
        #expect(controller.hover == .node(source.id))
        let port = try #require(model.layout(of: source.id)?.outputs.first)
        controller.hover(at: CGPoint(port.position))
        #expect(controller.hover == .port(port.address))
        controller.hover(at: CGPoint(x: 400, y: 600))
        #expect(controller.hover == nil)
        controller.hover(at: nil)
        #expect(controller.hover == nil)
    }

    @Test func hoverIsIgnoredWhileDraggingAndClearedOnPress() throws {
        let node = Node(typeID: TestKit.source, position: .zero)
        try model.perform(.addNode(node: node))
        controller.hover(at: CGPoint(x: 60, y: 40))
        #expect(controller.hover == .node(node.id))
        controller.pointerDown(at: CGPoint(x: 60, y: 40), kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: 160, y: 140))
        controller.hover(at: CGPoint(x: 900, y: 900))
        #expect(controller.hover == nil)
        controller.pointerUp(at: CGPoint(x: 160, y: 140))
        controller.hover(at: CGPoint(x: 200, y: 140))
        #expect(controller.hover == .node(node.id))
    }
}
