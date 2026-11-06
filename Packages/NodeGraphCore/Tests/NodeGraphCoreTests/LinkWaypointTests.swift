import Foundation
import Testing
@testable import NodeGraphCore

private let route = [GraphPoint(x: 10, y: 20), GraphPoint(x: 30, y: -5)]

private func wired() throws -> (GraphEditor, a: NodeID, b: NodeID, link: LinkID) {
    let (nodes, types) = runnable()
    let editor = GraphEditor(nodes: nodes, types: types)
    let a = Node(typeID: "const", properties: ["value": 2.0]), b = Node(typeID: "add")
    try editor.apply(.addNode(node: a)); try editor.apply(.addNode(node: b))
    let change = try editor.connect(ConnectionProposal(
        source: PortAddress(node: a.id, port: "out", direction: .output),
        target: PortAddress(node: b.id, port: "a", direction: .input)))
    guard case .addLink(let link, _) = change.command else { fatalError("connect adds one link") }
    return (editor, a.id, b.id, link.id)
}

// MARK: Model and file form

@Test func linksStartWithoutWaypointsAndKeepTheirOldFileForm() throws {
    let link = Link(sourceNode: NodeID(), sourcePort: "o", targetNode: NodeID(), targetPort: "i")
    #expect(link.waypoints.isEmpty)
    #expect(!String(decoding: try JSONEncoder().encode(link), as: UTF8.self).contains("waypoints"))
    // A link written before waypoints existed still reads.
    let old = Data(String(decoding: try JSONEncoder().encode(link), as: UTF8.self).utf8)
    #expect(try JSONDecoder().decode(Link.self, from: old) == link)
}

@Test func waypointsRoundTripInOrder() throws {
    let link = Link(sourceNode: NodeID(), sourcePort: "o", targetNode: NodeID(), targetPort: "i", waypoints: route)
    let data = try JSONEncoder().encode(link)
    #expect(String(decoding: data, as: UTF8.self).contains("waypoints"))
    #expect(try JSONDecoder().decode(Link.self, from: data).waypoints == route)

    var graph = Graph()
    graph.insert(link)
    let document = try GraphDocument.decode(from: GraphDocument(graph: graph).encoded())
    #expect(document.graph.links.values.first?.waypoints == route)
}

@Test func waypointsMakeLinksDiffer() {
    let id = LinkID(), a = NodeID(), b = NodeID()
    let plain = Link(id: id, sourceNode: a, sourcePort: "o", targetNode: b, targetPort: "i")
    let routed = Link(id: id, sourceNode: a, sourcePort: "o", targetNode: b, targetPort: "i", waypoints: route)
    #expect(plain != routed)
}

// MARK: Editing

@Test func waypointsAreSetClearedAndUndone() throws {
    let (editor, _, _, link) = try wired()
    let before = editor.graph
    let set = try editor.apply(.setLinkWaypoints(link: link, waypoints: route))
    #expect(editor.graph.links[link]?.waypoints == route)
    let cleared = try editor.apply(.setLinkWaypoints(link: link, waypoints: []))
    #expect(editor.graph.links[link]?.waypoints.isEmpty == true)
    try editor.revert(cleared)
    #expect(editor.graph.links[link]?.waypoints == route)
    try editor.revert(set)
    #expect(editor.graph == before)
}

@Test func theLinkQueriesStillFindALinkAfterItsWaypointsChange() throws {
    let (editor, a, b, link) = try wired()
    try editor.apply(.setLinkWaypoints(link: link, waypoints: route))
    let target = PortAddress(node: b, port: "a", direction: .input)
    #expect(editor.graph.links(into: target).first?.waypoints == route)
    #expect(editor.graph.links(attachedTo: a).count == 1)
    // Reconnecting through the editor still replaces the link, waypoints and all.
    let other = Node(typeID: "const")
    try editor.apply(.addNode(node: other))
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: other.id, port: "out", direction: .output), target: target))
    #expect(editor.graph.links.count == 1 && editor.graph.links.values.first?.waypoints.isEmpty == true)
}

@Test func badWaypointEditsAreRefused() throws {
    let (editor, _, _, link) = try wired()
    let missing = LinkID()
    #expect(throws: GraphEditError.linkNotFound(missing)) {
        try editor.apply(.setLinkWaypoints(link: missing, waypoints: route))
    }
    #expect(throws: GraphEditError.nonFiniteValue) {
        try editor.apply(.setLinkWaypoints(link: link, waypoints: [GraphPoint(x: .nan, y: 0)]))
    }
    #expect(throws: GraphEditError.nonFiniteValue) {
        try editor.apply(.setLinkWaypoints(link: link, waypoints: [GraphPoint(x: 0, y: .infinity)]))
    }
    #expect(editor.graph.links[link]?.waypoints.isEmpty == true)
}

@Test func draggingAWaypointIsOneUndoStep() throws {
    let (editor, _, _, link) = try wired()
    let history = GraphHistory(editor: editor)
    try history.perform(.setLinkWaypoints(link: link, waypoints: [GraphPoint(x: 0, y: 0)]), name: "Add Reroute")
    for x in 1...20 {
        try history.perform(
            .setLinkWaypoints(link: link, waypoints: [GraphPoint(x: Double(x), y: 5)]),
            name: "Move Reroute", coalescing: true)
    }
    #expect(history.undoStack.count == 2, "adding the point, then one step for the whole drag")
    #expect(editor.graph.links[link]?.waypoints == [GraphPoint(x: 20, y: 5)])
    try history.undo()
    #expect(editor.graph.links[link]?.waypoints == [GraphPoint(x: 0, y: 0)])
    // Waypoints of different links never merge.
    #expect(GraphCommand.setLinkWaypoints(link: link, waypoints: [])
        .coalesced(with: .setLinkWaypoints(link: LinkID(), waypoints: [])) == nil)
}

@Test func waypointsComeBackWhenALinkIsRestored() throws {
    let (editor, a, _, link) = try wired()
    try editor.apply(.setLinkWaypoints(link: link, waypoints: route))
    let before = editor.graph
    let removal = try editor.apply(.removeNode(id: a))            // takes the link with it
    #expect(editor.graph.links.isEmpty)
    try editor.revert(removal)
    #expect(editor.graph == before)
    #expect(editor.graph.links[link]?.waypoints == route)
}

@Test func aFailedBatchPutsWaypointsBack() throws {
    let (editor, _, _, link) = try wired()
    let before = editor.graph
    #expect(throws: GraphEditError.self) {
        try editor.apply(.batch(commands: [
            .setLinkWaypoints(link: link, waypoints: route),
            .removeLink(id: LinkID()),
        ]))
    }
    #expect(editor.graph == before)
}

@Test func waypointsInsideASubgraphAreEditedThroughInSubgraph() throws {
    let (nodes, types) = runnable()
    let editor = GraphEditor(nodes: nodes, types: types)
    let adder = Adder()
    var definition = adder.definition
    let innerLink = try #require(definition.graph.links.values.first)
    try editor.apply(.addSubgraph(definition: definition))
    try editor.apply(.inSubgraph(id: definition.id, command: .setLinkWaypoints(link: innerLink.id, waypoints: route)))
    #expect(editor.subgraphs[definition.id]?.graph.links[innerLink.id]?.waypoints == route)
    definition.graph.setWaypoints(of: innerLink.id, to: route)
    #expect(editor.subgraphs[definition.id] == definition)
}

// MARK: They change the picture, never the result

@Test func waypointsDoNotChangeWhatTheGraphComputes() async throws {
    let (editor, _, b, link) = try wired()
    func result() async throws -> GraphValue? {
        await (try GraphRunner(graph: editor.graph, registry: editor.nodes)).step().outputs(of: b)?["out"]
    }
    let before = try await result()
    try editor.apply(.setLinkWaypoints(link: link, waypoints: route))
    #expect(try await result() == before && before == 2.0)
}

@Test func validationAndPlansIgnoreWaypoints() throws {
    let (editor, _, _, link) = try wired()
    let plain = try ExecutionPlan.compile(editor.graph, nodes: editor.nodes)
    try editor.apply(.setLinkWaypoints(link: link, waypoints: route))
    #expect(try ExecutionPlan.compile(editor.graph, nodes: editor.nodes) == plain)
    #expect(GraphValidator().validate(editor.validationContext).isEmpty)
}

// MARK: Subgraph conversion

@Test func waypointsOfLinksInsideAConvertedSelectionMoveWithThem() throws {
    let (editor, a, b, link) = try wired()
    try editor.apply(.setLinkWaypoints(link: link, waypoints: route))
    let conversion = try editor.convertToSubgraphCommand(nodes: [a, b], name: "Both")
    try editor.apply(conversion.command)
    #expect(editor.subgraphs[conversion.subgraph]?.graph.links[link]?.waypoints == route)
}

@Test func unpackingMovesInnerWaypointsWithTheNodes() throws {
    let (nodes, types) = runnable()
    let editor = GraphEditor(nodes: nodes, types: types)
    let adder = Adder()
    var definition = adder.definition
    definition.graph.insert(Node(id: adder.add, typeID: "add", position: GraphPoint(x: 100, y: 50)))
    definition.graph.insert(Node(id: adder.constant, typeID: "const", position: GraphPoint(x: 20, y: 90), properties: ["value": 10.0]))
    let innerLink = try #require(definition.graph.links.values.first)
    definition.graph.setWaypoints(of: innerLink.id, to: [GraphPoint(x: 60, y: 70)])
    try editor.apply(.addSubgraph(definition: definition))
    let instance = Node(typeID: definition.typeID, position: GraphPoint(x: 300, y: 200))
    try editor.apply(.addNode(node: instance))

    let unpacking = try editor.unpackCommand(instance: instance.id)
    try editor.apply(unpacking.command)
    // The inner top-left (20, 50) lands on (300, 200), so everything moves by (280, 150).
    let copy = try #require(editor.graph.links.values.first)
    #expect(copy.id != innerLink.id)
    #expect(copy.waypoints == [GraphPoint(x: 340, y: 220)])
}
