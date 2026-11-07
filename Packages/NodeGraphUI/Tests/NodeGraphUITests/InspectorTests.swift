import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct InspectionTests {
    let model = TestKit.makeModel()

    @discardableResult
    private func add(_ type: NodeTypeID, x: Double = 0, title: String? = nil, mode: NodeMode = .always) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: 0), title: title, mode: mode)
        try model.perform(.addNode(node: node))
        return node
    }

    @Test func nothingSelectedSummarizesTheGraph() throws {
        try add(TestKit.source)
        try add(TestKit.sink, x: 400)
        try model.perform(.addGroup(group: NodeGroup(title: "G", bounds: GraphRect(x: 0, y: 0, width: 50, height: 50))))
        guard case .graph(let summary) = model.inspection() else {
            Issue.record("expected the graph")
            return
        }
        #expect(summary == GraphSummary(nodeCount: 2, linkCount: 0, groupCount: 1))
    }

    @Test func oneNodeShowsItsPropertiesAndPorts() throws {
        let node = try add(TestKit.widgets, title: "Mine")
        try model.perform(.setNodeProperty(node: node.id, property: "flag", value: .bool(true)))
        model.select(node: node.id)
        guard case .node(let info) = model.inspection() else {
            Issue.record("expected a node")
            return
        }
        #expect(info.title == "Mine" && info.typeName == "Widgets" && info.isKnownType)
        #expect(info.properties.map(\.id) == ["flag", "gain", "count", "label", "mode", "tint", "notes"])
        let flag = try #require(info.properties.first { $0.id == "flag" })
        #expect(flag.value == .bool(true) && !flag.isDefault)
        let gain = try #require(info.properties.first { $0.id == "gain" })
        #expect(gain.value == .double(0.5) && gain.isDefault)
        #expect(gain.spec.kind == .slider(min: 0, max: 1, step: 0.1, isInteger: false))
    }

    @Test func portsListTheirTypeAndLinkCount() throws {
        let source = try add(TestKit.source)
        let sink = try add(TestKit.sink, x: 400)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        model.select(node: sink.id)
        guard case .node(let info) = model.inspection() else {
            Issue.record("expected a node")
            return
        }
        #expect(info.inputs.map(\.definition.id.rawValue) == ["a", "b"])
        #expect(info.inputs.map(\.linkCount) == [1, 0])
        #expect(info.inputs[0].typeName == "Number")
        #expect(info.inputs[0].color == RGBAColor(red: 0.2, green: 0.4, blue: 0.9))
        #expect(info.outputs.isEmpty)
        model.select(node: source.id)
        guard case .node(let sourceInfo) = model.inspection() else {
            Issue.record("expected a node")
            return
        }
        #expect(sourceInfo.outputs.map(\.linkCount) == [1])
    }

    @Test func aNodeOfAnUnknownTypeIsMarked() throws {
        let node = Node(typeID: NodeTypeID("gone.type"))
        // The editor refuses an unregistered type, so put one in through an unvalidated replay.
        try model.editor.apply(.addNode(node: node), validation: .structural)
        model.refresh()
        model.select(node: node.id)
        guard case .node(let info) = model.inspection() else {
            Issue.record("expected a node")
            return
        }
        #expect(!info.isKnownType && info.properties.isEmpty && info.typeName == "gone.type")
    }

    @Test func severalNodesShowOnlyWhatTheyShare() throws {
        let a = try add(TestKit.source, mode: .muted)
        let b = try add(TestKit.source, x: 300, mode: .muted)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        guard case .nodes(let same) = model.inspection() else {
            Issue.record("expected nodes")
            return
        }
        #expect(same.ids == [a.id, b.id] && same.mode == .muted && same.isPinned == false)
        try model.perform(.setNodeAttribute(node: b.id, attribute: .mode(value: .never)))
        try model.perform(.setNodeAttribute(node: b.id, attribute: .color(value: RGBAColor(red: 1, green: 0, blue: 0))))
        guard case .nodes(let mixed) = model.inspection() else {
            Issue.record("expected nodes")
            return
        }
        #expect(mixed.mode == nil && mixed.hasMixedColors)
    }

    @Test func aLinkShowsBothEnds() throws {
        let source = try add(TestKit.source, title: "Origin")
        let sink = try add(TestKit.sink, x: 400)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "b", direction: .input)))
        let link = model.graph.links.keys[0]
        model.selection = GraphSelection(links: [link])
        guard case .link(let info) = model.inspection() else {
            Issue.record("expected a link")
            return
        }
        #expect(info.source == "Origin · out" && info.target == "Sink · b")
        #expect(info.typeName == "Number" && info.waypointCount == 0)
    }

    @Test func aGroupShowsItsMembers() throws {
        try add(TestKit.source, x: 20)
        let group = NodeGroup(title: "Box", bounds: GraphRect(x: 0, y: 0, width: 400, height: 300))
        try model.perform(.addGroup(group: group))
        model.selection = GraphSelection(groups: [group.id])
        guard case .group(let info) = model.inspection() else {
            Issue.record("expected a group")
            return
        }
        #expect(info.title == "Box" && info.memberCount == 1 && info.bounds == group.bounds)
    }
}

@MainActor
@Suite struct InspectorActionTests {
    let model = TestKit.makeModel()

    private func add(_ type: NodeTypeID, x: Double = 0) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: 0))
        try model.perform(.addNode(node: node))
        return node
    }

    @Test func renamingSetsAndClearsTheTitle() throws {
        let node = try add(TestKit.source)
        #expect(model.setTitle("Hello", of: [node.id]))
        #expect(model.graph.nodes[node.id]?.title == "Hello")
        #expect(model.setTitle("", of: [node.id]))
        #expect(model.graph.nodes[node.id]?.title == nil)
        #expect(!model.setTitle(nil, of: [node.id]))  // already clear: no step
    }

    @Test func attributesApplyToEveryNodeAsOneUndoStep() throws {
        let a = try add(TestKit.source)
        let b = try add(TestKit.source, x: 300)
        let before = model.history.undoStack.count
        #expect(model.setMode(.bypassed, of: [a.id, b.id]))
        #expect(model.graph.nodes.values.allSatisfy { $0.mode == .bypassed })
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes.values.allSatisfy { $0.mode == .always })
    }

    @Test func settingTheSameValueRecordsNothing() throws {
        let a = try add(TestKit.source)
        let before = model.history.undoStack.count
        #expect(!model.setMode(.always, of: [a.id]))
        #expect(!model.setPinned(false, of: [a.id]))
        #expect(model.history.undoStack.count == before)
    }

    @Test func colorPinAndCollapseApply() throws {
        let a = try add(TestKit.source)
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        #expect(model.setColor(red, of: [a.id]) && model.graph.nodes[a.id]?.color == red)
        #expect(model.setColor(nil, of: [a.id]) && model.graph.nodes[a.id]?.color == nil)
        #expect(model.setPinned(true, of: [a.id]) && model.graph.nodes[a.id]?.isPinned == true)
        #expect(model.setCollapsed(true, of: [a.id]) && model.graph.nodes[a.id]?.isCollapsed == true)
    }

    @Test func positionAndSizeAreExactAndSizeIsLimitedToTheMinimum() throws {
        let sink = try add(TestKit.sink)
        #expect(model.setPosition(GraphPoint(x: 12, y: 34), of: sink.id))
        #expect(model.graph.nodes[sink.id]?.position == GraphPoint(x: 12, y: 34))
        #expect(model.setSize(GraphSize(width: 10, height: 10), of: sink.id))
        let layout = try #require(model.layout(of: sink.id))
        #expect(layout.frame.size == layout.minimumSize)
        #expect(model.setSize(GraphSize(width: 300, height: 200), of: sink.id))
        #expect(model.layout(of: sink.id)?.frame.size == GraphSize(width: 300, height: 200))
    }

    @Test func propertiesAreLimitedToTheirRangeAndCanBeReset() throws {
        let node = try add(TestKit.widgets)
        #expect(model.setProperty(.double(5), named: "gain", of: node.id))
        #expect(model.graph.nodes[node.id]?.properties["gain"] == .double(1))  // clamped to the maximum
        #expect(model.setProperty(nil, named: "gain", of: node.id))
        #expect(model.graph.nodes[node.id]?.properties["gain"] == nil)  // back to the default
        #expect(!model.setProperty(nil, named: "gain", of: node.id))  // already default
        #expect(!model.setProperty(.int(1), named: "nonexistent", of: node.id))
    }

    @Test func aSliderSweepIsOneStep() throws {
        let node = try add(TestKit.widgets)
        let before = model.history.undoStack.count
        for value in [0.1, 0.2, 0.3, 0.4] { model.setProperty(.double(value), named: "gain", of: node.id, coalescing: true) }
        model.endCoalescing()
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes[node.id]?.properties["gain"] == nil)
    }

    @Test func groupsCanBeRenamedAndRecolored() throws {
        let group = NodeGroup(title: "Old", bounds: GraphRect(x: 0, y: 0, width: 100, height: 100))
        try model.perform(.addGroup(group: group))
        #expect(model.setGroupTitle("New", of: group.id))
        #expect(model.setGroupColor(RGBAColor(red: 0, green: 1, blue: 0), of: group.id))
        #expect(model.graph.groups[group.id]?.title == "New")
        #expect(model.graph.groups[group.id]?.color == RGBAColor(red: 0, green: 1, blue: 0))
        #expect(!model.setGroupTitle("New", of: group.id))
    }

    @Test func rerouteLinkPointsCanBeCleared() throws {
        let source = try add(TestKit.source)
        let sink = try add(TestKit.sink, x: 400)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let id = model.graph.links.keys[0]
        #expect(!model.clearWaypoints(of: id))
        try model.perform(.setLinkWaypoints(link: id, waypoints: [GraphPoint(x: 200, y: 50)]))
        #expect(model.clearWaypoints(of: id))
        #expect(model.graph.links[id]?.waypoints.isEmpty == true)
    }
}
