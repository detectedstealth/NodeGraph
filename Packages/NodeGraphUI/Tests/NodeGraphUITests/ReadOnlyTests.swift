import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

/// A model with a source wired to a sink and a widgets node, at zoom 1 so screen and graph
/// points are the same, then switched to read-only.
@MainActor
private struct Rig {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController
    let source: Node
    let sink: Node
    let widgets: Node
    let link: Link

    init() throws {
        controller = GraphInteractionController(model: model)
        source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        widgets = Node(typeID: TestKit.widgets, position: GraphPoint(x: 0, y: 300))
        for node in [source, sink, widgets] { try model.perform(.addNode(node: node)) }
        link = Link(
            sourceNode: source.id, sourcePort: "out", targetNode: sink.id, targetPort: "a")
        try model.perform(.addLink(link: link))
        model.isEditable = false
    }

    func node(_ id: NodeID) -> Node { model.graph.nodes[id]! }

    func center(of node: Node) -> CGPoint {
        let frame = model.layout(of: node.id)!.frame
        return CGPoint(x: frame.minX + frame.size.width / 2, y: frame.minY + 10)
    }

    func drag(from a: CGPoint, to b: CGPoint, kind: PointerKind = .mouse) {
        controller.pointerDown(at: a, kind: kind)
        for i in 1...4 {
            let t = Double(i) / 4
            controller.pointerMoved(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        controller.pointerUp(at: b)
    }

    func click(_ p: CGPoint) {
        controller.pointerDown(at: p, kind: .mouse)
        controller.pointerUp(at: p)
    }

    func widget(_ id: String) -> WidgetLayout {
        model.layout(of: widgets.id)!.widgets.first { $0.spec.id == id }!
    }
}

@MainActor
@Suite struct ReadOnlyModelTests {
    @Test func editsUndoAndRedoAreRefusedAndChangeNothing() throws {
        let rig = try Rig()
        let before = rig.model.graph
        let revision = rig.model.revision

        #expect(throws: GraphEditorModelError.readOnly) {
            try rig.model.perform(.removeNode(id: rig.source.id))
        }
        #expect(throws: GraphEditorModelError.readOnly) {
            try rig.model.group { try rig.model.perform(.removeNode(id: rig.source.id)) }
        }
        #expect(throws: GraphEditorModelError.readOnly) {
            try rig.model.connect(ConnectionProposal(
                source: PortAddress(node: rig.source.id, port: "out", direction: .output),
                target: PortAddress(node: rig.sink.id, port: "b", direction: .input)))
        }
        #expect(throws: GraphEditorModelError.readOnly) { try rig.model.undo() }
        #expect(throws: GraphEditorModelError.readOnly) { try rig.model.redo() }
        #expect(rig.model.graph == before)
        #expect(rig.model.revision == revision)
        #expect(!rig.model.canUndo)
    }

    @Test func editingResumesWhenSwitchedBackOn() throws {
        let rig = try Rig()
        rig.model.isEditable = true
        #expect(rig.model.canUndo)
        try rig.model.perform(.setNodeAttribute(node: rig.source.id, attribute: .isPinned(value: true)))
        #expect(rig.node(rig.source.id).isPinned)
        try rig.model.undo()
        #expect(!rig.node(rig.source.id).isPinned)
    }

    @Test func cameraSelectionAndExternalRefreshStillWork() throws {
        let rig = try Rig()
        rig.model.select(node: rig.source.id)
        rig.model.camera.pan(byScreen: CGSize(width: 10, height: 5))
        rig.model.zoomToFit()
        #expect(rig.model.selection.nodes == [rig.source.id])

        // An edit made behind the model's back (a server change) shows up on refresh.
        try rig.model.editor.apply(.setNodeAttribute(node: rig.source.id, attribute: .isPinned(value: true)))
        rig.model.refresh()
        #expect(rig.node(rig.source.id).isPinned)
    }

    @Test func createSubgraphAndConnectionChooserDoNotOpen() throws {
        let rig = try Rig()
        rig.model.select(node: rig.source.id)
        #expect(!rig.model.beginCreateSubgraph())
        #expect(rig.model.createSubgraphRequest == nil)
        #expect(!rig.model.beginConnection(from: PortAddress(node: rig.source.id, port: "out", direction: .output)))
        #expect(rig.model.connectionRequest == nil)
    }
}

@MainActor
@Suite struct ReadOnlyCanvasTests {
    @Test func draggingANodeDoesNotMoveIt() throws {
        let rig = try Rig()
        let start = rig.node(rig.source.id).position
        let point = rig.center(of: rig.source)
        rig.drag(from: point, to: CGPoint(x: point.x + 80, y: point.y + 60))
        #expect(rig.node(rig.source.id).position == start)
        #expect(!rig.model.canUndo)
        // The press still selects it.
        #expect(rig.model.selection.nodes == [rig.source.id])
    }

    @Test func resizingANodeDoesNothing() throws {
        let rig = try Rig()
        let layout = try #require(rig.model.layout(of: rig.sink.id))
        let handle = layout.resizeHandle
        let corner = CGPoint(x: handle.minX + handle.size.width / 2, y: handle.minY + handle.size.height / 2)
        let size = rig.node(rig.sink.id).size
        rig.drag(from: corner, to: CGPoint(x: corner.x + 50, y: corner.y + 50))
        #expect(rig.node(rig.sink.id).size == size)
    }

    @Test func dragFromAPortStartsNoLinkAndMakesNone() throws {
        let rig = try Rig()
        let port = try #require(rig.model.layout(of: rig.source.id)?.outputs.first)
        let target = try #require(rig.model.layout(of: rig.sink.id)?.inputs.last)
        rig.controller.pointerDown(at: CGPoint(port.position))
        rig.controller.pointerMoved(to: CGPoint(x: port.position.x + 50, y: port.position.y + 50))
        #expect(rig.controller.draft == nil)
        rig.controller.pointerMoved(to: CGPoint(target.position))
        rig.controller.pointerUp(at: CGPoint(target.position))
        #expect(rig.model.graph.links.count == 1)
        #expect(rig.controller.addNodeRequest == nil)
    }

    @Test func pickingUpALinkFromItsInputDoesNotDisconnectIt() throws {
        let rig = try Rig()
        let input = try #require(rig.model.layout(of: rig.sink.id)?.inputs.first)
        rig.drag(from: CGPoint(input.position), to: CGPoint(x: 600, y: 600))
        #expect(rig.model.graph.links[rig.link.id] != nil)
        #expect(rig.controller.hiddenLinks.isEmpty)
    }

    @Test func widgetsCannotBeChanged() throws {
        let rig = try Rig()
        let flag = rig.widget("flag"), gain = rig.widget("gain"), count = rig.widget("count")
        let before = rig.node(rig.widgets.id).properties

        rig.click(CGPoint(x: flag.frame.minX + 6, y: flag.frame.minY + flag.frame.size.height / 2))
        rig.click(CGPoint(x: gain.frame.minX + gain.frame.size.width * 0.9, y: gain.frame.minY + gain.frame.size.height / 2))
        rig.drag(
            from: CGPoint(x: count.frame.minX + 40, y: count.frame.minY + count.frame.size.height / 2),
            to: CGPoint(x: count.frame.minX + 120, y: count.frame.minY + count.frame.size.height / 2))
        rig.click(CGPoint(x: count.frame.minX + 40, y: count.frame.minY + count.frame.size.height / 2))

        #expect(rig.node(rig.widgets.id).properties == before)
        #expect(rig.controller.editor == nil)
    }

    @Test func marqueeStillSelectsAndAFingerStillPans() throws {
        let rig = try Rig()
        rig.drag(from: CGPoint(x: -50, y: -50), to: CGPoint(x: 150, y: 150))
        #expect(rig.model.selection.nodes == [rig.source.id])

        let camera = rig.model.camera
        rig.drag(from: CGPoint(x: 700, y: 700), to: CGPoint(x: 740, y: 720), kind: .touch)
        #expect(rig.model.camera != camera)
        #expect(rig.model.graph.nodes.count == 3)
    }

    @Test func doubleClickOnEmptyCanvasDoesNotOpenAddNode() throws {
        let rig = try Rig()
        rig.click(CGPoint(x: 900, y: 900))
        rig.click(CGPoint(x: 900, y: 900))
        #expect(rig.controller.addNodeRequest == nil)
        rig.controller.beginAddNode()
        #expect(rig.controller.addNodeRequest == nil)
    }

    @Test func aSubgraphInstanceStillOpensAndLeaves() throws {
        let rig = try Rig()
        rig.model.isEditable = true
        rig.model.select(node: rig.source.id)
        #expect(rig.model.beginCreateSubgraph())
        #expect(rig.model.createSubgraph(name: "Inner"))
        let instance = try #require(rig.model.selection.nodes.first)
        rig.model.isEditable = false
        #expect(rig.controller.enterSubgraph(of: instance))
        #expect(rig.model.currentScope != nil)
        #expect(rig.controller.leaveSubgraph())
    }
}

@MainActor
@Suite struct ReadOnlyCommandTests {
    @Test func everyEditCommandIsRefusedAndSelectionSurvives() throws {
        let rig = try Rig()
        rig.model.selection = GraphSelection(nodes: [rig.source.id, rig.sink.id])
        let before = rig.model.graph
        let edits: [CanvasCommand] = [
            .deleteSelection, .deleteAndReconnect, .nudge(dx: 1, dy: 0), .cut, .paste(at: nil), .pasteWithConnections(at: nil), .duplicate, .align(.left),
            .distribute(.horizontal), .createSubgraph, .unpackSubgraph, .addNode(at: nil), .toggleCollapsed,
            .togglePinned, .setMode(.muted), .disconnectSelection, .addWaypoint(rig.link.id, at: GraphPoint(x: 5, y: 5)),
        ]
        for command in edits {
            #expect(command.isEdit)
            #expect(!rig.controller.perform(command), "\(command)")
        }
        #expect(rig.model.graph == before)
        #expect(rig.model.selection.nodes.count == 2)
        #expect(rig.controller.addNodeRequest == nil)
        #expect(rig.model.createSubgraphRequest == nil)
    }

    @Test func viewingCommandsStillWork() throws {
        let rig = try Rig()
        #expect(!CanvasCommand.copy.isEdit)
        #expect(rig.controller.perform(.selectAll))
        #expect(rig.model.selection.nodes.count == 3)
        #expect(rig.controller.perform(.zoomIn))
        #expect(rig.controller.perform(.zoomToFit))
        #expect(rig.controller.perform(.escape))
        #expect(rig.model.selection.isEmpty)
    }

    @Test func cutDoesNotPutAnythingOnTheClipboard() throws {
        let rig = try Rig()
        rig.model.select(node: rig.source.id)
        #expect(!rig.controller.cutSelection())
        #expect(rig.model.graph.nodes[rig.source.id] != nil)
    }

    @Test func keysForEditsAreIgnored() throws {
        let rig = try Rig()
        rig.model.select(node: rig.source.id)
        let command = try #require(CanvasKeyMap.command(for: .delete, modifiers: []))
        #expect(!rig.controller.perform(command))
        #expect(rig.model.graph.nodes[rig.source.id] != nil)
    }

    @Test func menusShowEditsDisabledAndKeepViewingEnabled() throws {
        let rig = try Rig()
        func enabled(_ items: [CanvasMenuItem], _ title: String) -> Bool? {
            items.first { $0.title == title }?.isEnabled
        }

        let node = rig.controller.contextMenu(at: rig.center(of: rig.source))
        #expect(enabled(node, "Copy") == true)
        for title in ["Cut", "Duplicate", "Collapse", "Pin", "Mode", "Delete", "Create Subgraph…"] {
            #expect(enabled(node, title) == false, "\(title)")
        }

        let empty = rig.controller.contextMenu(at: CGPoint(x: 900, y: 900))
        #expect(enabled(empty, "Add Node…") == false)
        #expect(enabled(empty, "Paste") == false)
        #expect(enabled(empty, "Select All") == true)
        #expect(enabled(empty, "Zoom to Fit") == true)
    }

    @Test func menuIsUnchangedWhenEditable() throws {
        let rig = try Rig()
        rig.model.isEditable = true
        let node = rig.controller.contextMenu(at: rig.center(of: rig.source))
        #expect(node.first { $0.title == "Delete" }?.isEnabled == true)
        #expect(node.first { $0.title == "Mode" }?.isEnabled == true)
    }

    @Test func accessibilityOffersNoEdits() throws {
        let rig = try Rig()
        let names = rig.model.accessibilityElements()
            .first { $0.subject == .node(rig.source.id) }?.actions.map(\.name) ?? []
        #expect(names == ["Select"])

        rig.model.isEditable = true
        let editable = rig.model.accessibilityElements()
            .first { $0.subject == .node(rig.source.id) }?.actions.map(\.name) ?? []
        #expect(editable.contains("Delete"))
        #expect(editable.contains { $0.hasPrefix("Connect") })
    }
}
