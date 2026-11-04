import Testing
@testable import NodeGraphCore

private func makeHistory() -> GraphHistory {
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "box", displayName: "Box", defaultSize: GraphSize(width: 10, height: 10)))
    return GraphHistory(editor: GraphEditor(nodes: nodes, types: TypeRegistry()))
}

private func addBox(_ history: GraphHistory, x: Double, y: Double) throws -> NodeID {
    let node = Node(typeID: "box", position: GraphPoint(x: x, y: y))
    try history.perform(.addNode(node: node))
    return node.id
}

private func addGroup(
    _ history: GraphHistory, _ rect: GraphRect, title: String = "G"
) throws -> GroupID {
    let group = NodeGroup(title: title, bounds: rect)
    try history.perform(.addGroup(group: group))
    return group.id
}

@Test func membershipIsDerivedFromContainment() throws {
    let history = makeHistory()
    let inside = try addBox(history, x: 10, y: 10)
    let edge = try addBox(history, x: 90, y: 90)         // frame ends exactly at 100
    let straddling = try addBox(history, x: 95, y: 10)   // pokes out of the right side
    _ = try addBox(history, x: 500, y: 500)
    let group = try addGroup(history, GraphRect(x: 0, y: 0, width: 100, height: 100))
    #expect(try history.editor.members(of: group) == [inside, edge])
    #expect(try !history.editor.members(of: group).contains(straddling))
}

@Test func membershipFollowsNodesAndResizing() throws {
    let history = makeHistory()
    let node = try addBox(history, x: 200, y: 0)
    let group = try addGroup(history, GraphRect(x: 0, y: 0, width: 100, height: 100))
    #expect(try history.editor.members(of: group).isEmpty)
    try history.perform(.setNodePositions(placements: [NodePlacement(node: node, position: GraphPoint(x: 10, y: 10))]))
    #expect(try history.editor.members(of: group) == [node])

    // Resizing the group is an ordinary update; membership follows.
    var smaller = history.editor.graph.groups[group]!
    smaller.bounds = GraphRect(x: 0, y: 0, width: 15, height: 15)
    try history.perform(.updateGroup(group: smaller))
    #expect(try history.editor.members(of: group).isEmpty)
}

@Test func membersOfMissingGroupThrows() {
    let history = makeHistory()
    #expect(throws: GraphEditError.self) { try history.editor.members(of: GroupID()) }
}

@Test func nodesWithUnknownTypesCountAsPoints() {
    var graph = Graph()
    graph.insert(Node(typeID: "ghost", position: GraphPoint(x: 5, y: 5)))
    let group = NodeGroup(title: "G", bounds: GraphRect(x: 0, y: 0, width: 10, height: 10))
    #expect(graph.members(of: group, frame: NodeRegistry().frame(of:)).count == 1)
}

@Test func movingAGroupMovesMembersAndNestedGroups() throws {
    let history = makeHistory()
    let member = try addBox(history, x: 10, y: 10)
    let outsider = try addBox(history, x: 300, y: 300)
    let outer = try addGroup(history, GraphRect(x: 0, y: 0, width: 100, height: 100), title: "Outer")
    let inner = try addGroup(history, GraphRect(x: 5, y: 5, width: 40, height: 40), title: "Inner")
    let before = history.editor.graph

    let move = try history.editor.beginGroupMove(outer)
    try history.perform(move.command(delta: GraphPoint(x: 50, y: 20)), name: "Move Group")
    let graph = history.editor.graph
    #expect(graph.groups[outer]?.bounds.origin == GraphPoint(x: 50, y: 20))
    #expect(graph.groups[inner]?.bounds.origin == GraphPoint(x: 55, y: 25))
    #expect(graph.nodes[member]?.position == GraphPoint(x: 60, y: 30))
    #expect(graph.nodes[outsider]?.position == GraphPoint(x: 300, y: 300))

    try history.undo()
    #expect(history.editor.graph == before)
}

@Test func moveIsComputedFromTheOriginalsSoDragsDoNotDrift() throws {
    let history = makeHistory()
    let node = try addBox(history, x: 0.1, y: 0.1)
    let group = try addGroup(history, GraphRect(x: 0, y: 0, width: 50, height: 50))
    let move = try history.editor.beginGroupMove(group)
    for step in 1...100 {
        try history.perform(move.command(delta: GraphPoint(x: Double(step) * 0.1, y: 0)),
                            name: "Move Group", coalescing: true)
    }
    // 100 events, one undo step (plus the two setup steps).
    #expect(history.undoStack.count == 3)
    #expect(history.editor.graph.nodes[node]?.position.x == 0.1 + 10.0)
    #expect(history.editor.graph.groups[group]?.bounds.origin.x == 10.0)
}

@Test func groupMoveWithNoMembersJustMovesTheGroup() throws {
    let history = makeHistory()
    let group = try addGroup(history, GraphRect(x: 0, y: 0, width: 10, height: 10))
    let move = try history.editor.beginGroupMove(group)
    try history.perform(move.command(delta: GraphPoint(x: 3, y: 4)))
    #expect(history.editor.graph.groups[group]?.bounds.origin == GraphPoint(x: 3, y: 4))
}

@Test func coincidentGroupsAreNotNested() throws {
    let history = makeHistory()
    let rect = GraphRect(x: 0, y: 0, width: 50, height: 50)
    let first = try addGroup(history, rect), second = try addGroup(history, rect)
    let move = try history.editor.beginGroupMove(first)
    #expect(move.nestedGroups.isEmpty)
    try history.perform(move.command(delta: GraphPoint(x: 10, y: 0)))
    #expect(history.editor.graph.groups[second]?.bounds == rect)
}

@Test func groupAroundNodesEnclosesThemWithPadding() throws {
    let history = makeHistory()
    let a = try addBox(history, x: 0, y: 0)
    let b = try addBox(history, x: 100, y: 50)
    let command = try history.editor.groupCommand(around: [a, b], title: "Pair", padding: 10)
    try history.perform(command)
    let group = try #require(history.editor.graph.groups.values.first)
    #expect(group.bounds == GraphRect(x: -10, y: -10, width: 130, height: 80))
    #expect(try history.editor.members(of: group.id) == [a, b])
}

@Test func groupAroundNothingOrMissingNodesFails() {
    let history = makeHistory()
    #expect(throws: GraphEditError.invalidGeometry) {
        try history.editor.groupCommand(around: [], title: "x")
    }
    #expect(throws: GraphEditError.self) {
        try history.editor.groupCommand(around: [NodeID()], title: "x")
    }
}

@Test func degenerateGroupBoundsAreRejected() throws {
    let history = makeHistory()
    for rect in [GraphRect(x: 0, y: 0, width: 0, height: 10),
                 GraphRect(x: 0, y: 0, width: 10, height: -1),
                 GraphRect(x: .nan, y: 0, width: 10, height: 10)] {
        #expect(throws: GraphEditError.invalidGeometry) {
            try history.perform(.addGroup(group: NodeGroup(title: "bad", bounds: rect)))
        }
    }
    let group = try addGroup(history, GraphRect(x: 0, y: 0, width: 10, height: 10))
    var bad = history.editor.graph.groups[group]!
    bad.bounds.size.width = 0
    #expect(throws: GraphEditError.invalidGeometry) { try history.perform(.updateGroup(group: bad)) }
}

@Test func batchesCoalesceOnlyWhenEveryPairDoes() {
    let a = NodeID(), b = NodeID()
    let move1 = GraphCommand.batch(commands: [.setNodePositions(placements: [NodePlacement(node: a, position: .zero)])])
    let move2 = GraphCommand.batch(commands: [.setNodePositions(placements: [NodePlacement(node: a, position: GraphPoint(x: 1, y: 1))])])
    let other = GraphCommand.batch(commands: [.setNodePositions(placements: [NodePlacement(node: b, position: .zero)])])
    #expect(move1.coalesced(with: move2) == move2)
    #expect(move1.coalesced(with: other) == nil)
    #expect(move1.coalesced(with: .batch(commands: [])) == nil)
    #expect(GraphCommand.batch(commands: []).coalesced(with: .batch(commands: [])) == nil)
}
