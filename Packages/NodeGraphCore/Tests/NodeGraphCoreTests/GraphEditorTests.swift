import Foundation
import Testing
@testable import NodeGraphCore

private func makeEditor() -> GraphEditor {
    var types = TypeRegistry()
    types.register(PortTypeInfo(
        type: "number", displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 0)))
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "pass", displayName: "Pass",
        ports: [
            PortDefinition(id: "in", direction: .input, type: "number"),
            PortDefinition(id: "out", direction: .output, type: "number"),
        ],
        properties: [
            PropertyDefinition(id: "gain", displayName: "Gain", kind: .double(min: 0, max: 10), defaultValue: 1.0)
        ]))
    return GraphEditor(nodes: nodes, types: types)
}

private func add(_ editor: GraphEditor, at position: GraphPoint = .zero) throws -> NodeID {
    let node = Node(typeID: "pass", position: position)
    try editor.apply(.addNode(node: node))
    return node.id
}

private func connection(_ a: NodeID, _ b: NodeID) -> ConnectionProposal {
    ConnectionProposal(
        source: PortAddress(node: a, port: "out", direction: .output),
        target: PortAddress(node: b, port: "in", direction: .input))
}

@Test func addNodeAndUndo() throws {
    let editor = makeEditor()
    let before = editor.graph
    let id = try add(editor)
    #expect(editor.graph.nodes[id] != nil && editor.revision == 1)
    let change = GraphChange(revision: 1, command: .addNode(node: editor.graph.nodes[id]!), inverse: .removeNode(id: id))
    try editor.revert(change)
    #expect(editor.graph == before)
}

@Test func undoOfRemovalRestoresNodeAndLinkOrder() throws {
    let editor = makeEditor()
    let a = try add(editor), b = try add(editor), c = try add(editor)
    try editor.connect(connection(a, b))
    try editor.connect(connection(b, c))
    try editor.connect(connection(a, c))
    let before = editor.graph
    let removal = try editor.apply(.removeNode(id: b))
    #expect(editor.graph.nodes.count == 2 && editor.graph.links.count == 1)
    try editor.revert(removal)
    #expect(editor.graph == before)
    #expect(Array(editor.graph.nodes.keys) == [a, b, c])
    #expect(Array(editor.graph.links.values.map(\.id)) == Array(before.links.values.map(\.id)))
}

@Test func revertReturnsAChangeThatRedoes() throws {
    let editor = makeEditor()
    let id = try add(editor)
    let move = try editor.apply(.setNodePositions(placements: [NodePlacement(node: id, position: GraphPoint(x: 5, y: 6))]))
    let undo = try editor.revert(move)
    #expect(editor.graph.nodes[id]?.position == .zero)
    try editor.revert(undo)
    #expect(editor.graph.nodes[id]?.position == GraphPoint(x: 5, y: 6))
}

@Test func attributesAndPropertiesInvert() throws {
    let editor = makeEditor()
    let id = try add(editor)
    let before = editor.graph
    let changes = [
        try editor.apply(.setNodeAttribute(node: id, attribute: .title(value: "Hi"))),
        try editor.apply(.setNodeAttribute(node: id, attribute: .mode(value: .muted))),
        try editor.apply(.setNodeAttribute(node: id, attribute: .size(value: GraphSize(width: 9, height: 9)))),
        try editor.apply(.setNodeProperty(node: id, property: "gain", value: 2.5)),
    ]
    #expect(editor.graph.nodes[id]?.properties["gain"] == 2.5)
    for change in changes.reversed() { try editor.revert(change) }
    #expect(editor.graph == before)
}

@Test func clearingAPropertyRemovesTheOverride() throws {
    let editor = makeEditor()
    let id = try add(editor)
    try editor.apply(.setNodeProperty(node: id, property: "gain", value: 3.0))
    let clear = try editor.apply(.setNodeProperty(node: id, property: "gain", value: nil))
    #expect(editor.graph.nodes[id]?.properties["gain"] == nil)
    try editor.revert(clear)
    #expect(editor.graph.nodes[id]?.properties["gain"] == 3.0)
}

@Test func invalidEditsAreRejected() throws {
    let editor = makeEditor()
    let id = try add(editor)
    #expect(throws: GraphEditError.unknownNodeType("ghost")) {
        try editor.apply(.addNode(node: Node(typeID: "ghost")))
    }
    #expect(throws: GraphEditError.invalidProperty("gain", .outOfRange)) {
        try editor.apply(.setNodeProperty(node: id, property: "gain", value: 99.0))
    }
    #expect(throws: GraphEditError.unknownProperty("nope")) {
        try editor.apply(.setNodeProperty(node: id, property: "nope", value: 1))
    }
    #expect(throws: GraphEditError.nodeNotFound(id)) {
        try editor.apply(.removeNode(id: id)); try editor.apply(.removeNode(id: id))
    }
    #expect(throws: GraphEditError.nonFiniteValue) {
        let other = try add(editor)
        try editor.apply(.setNodePositions(placements: [NodePlacement(node: other, position: GraphPoint(x: .nan, y: 0))]))
    }
}

@Test func duplicateIDsAndBadIndexesAreRejected() throws {
    let editor = makeEditor()
    let node = Node(typeID: "pass")
    try editor.apply(.addNode(node: node))
    #expect(throws: GraphEditError.duplicateID(node.id.description)) {
        try editor.apply(.addNode(node: node))
    }
    #expect(throws: GraphEditError.indexOutOfRange(5)) {
        try editor.apply(.addNode(node: Node(typeID: "pass"), index: 5))
    }
}

@Test func failedBatchLeavesNothingBehind() throws {
    let editor = makeEditor()
    let a = try add(editor)
    let before = editor.graph, revision = editor.revision
    #expect(throws: GraphEditError.self) {
        try editor.apply(.batch(commands: [
            .setNodeAttribute(node: a, attribute: .isPinned(value: true)),
            .removeNode(id: NodeID()),
        ]))
    }
    #expect(editor.graph == before && editor.revision == revision)
}

@Test func batchUndoesAsOneStep() throws {
    let editor = makeEditor()
    let a = try add(editor)
    let before = editor.graph
    let change = try editor.apply(.batch(commands: [
        .setNodeAttribute(node: a, attribute: .isPinned(value: true)),
        .setNodeAttribute(node: a, attribute: .isCollapsed(value: true)),
    ]))
    try editor.revert(change)
    #expect(editor.graph == before)
}

@Test func linksAreValidatedOnAdd() throws {
    let editor = makeEditor()
    let a = try add(editor)
    let selfLink = Link(sourceNode: a, sourcePort: "out", targetNode: a, targetPort: "in")
    #expect(throws: GraphEditError.self) { try editor.apply(.addLink(link: selfLink)) }
    let missing = Link(sourceNode: a, sourcePort: "out", targetNode: NodeID(), targetPort: "in")
    #expect(throws: GraphEditError.self) { try editor.apply(.addLink(link: missing)) }
    #expect(editor.graph.links.isEmpty)
}

@Test func structuralReplayDoesNotRunRules() throws {
    let editor = makeEditor()
    let a = try add(editor)
    let selfLink = Link(sourceNode: a, sourcePort: "out", targetNode: a, targetPort: "in")
    try editor.apply(.addLink(link: selfLink), validation: .structural)
    #expect(editor.graph.links.count == 1)
}

@Test func connectReplacesSingleInputAsOneUndoableStep() throws {
    let editor = makeEditor()
    let a = try add(editor), b = try add(editor), c = try add(editor)
    try editor.connect(connection(a, c))
    let before = editor.graph
    let change = try editor.connect(connection(b, c))
    #expect(editor.graph.links.count == 1)
    #expect(editor.graph.links.values.first?.source.node == b)
    try editor.revert(change)
    #expect(editor.graph == before)
}

@Test func addLinkRefusesToSilentlyDisplace() throws {
    let editor = makeEditor()
    let a = try add(editor), b = try add(editor), c = try add(editor)
    try editor.connect(connection(a, c))
    let second = Link(sourceNode: b, sourcePort: "out", targetNode: c, targetPort: "in")
    #expect(throws: GraphEditError.self) { try editor.apply(.addLink(link: second)) }
}

@Test func connectAcceptsReversedDragsAndRejectsBadOnes() throws {
    let editor = makeEditor()
    let a = try add(editor), b = try add(editor)
    let reversed = ConnectionProposal(
        source: PortAddress(node: b, port: "in", direction: .input),
        target: PortAddress(node: a, port: "out", direction: .output))
    try editor.connect(reversed)
    #expect(editor.graph.links.values.first?.source.node == a)
    #expect(throws: GraphEditError.self) { try editor.connect(connection(b, a)) }
}

@Test func groupsAddUpdateRemoveAndInvert() throws {
    let editor = makeEditor()
    let group = NodeGroup(title: "G", bounds: GraphRect(x: 0, y: 0, width: 10, height: 10))
    let added = try editor.apply(.addGroup(group: group))
    var renamed = group
    renamed.title = "H"
    let updated = try editor.apply(.updateGroup(group: renamed))
    #expect(editor.graph.groups[group.id]?.title == "H")
    try editor.revert(updated)
    #expect(editor.graph.groups[group.id]?.title == "G")
    try editor.revert(added)
    #expect(editor.graph.groups.isEmpty)
}

// MARK: Coalescing

@Test func dragsAndSlidersCoalesceIntoOneStep() throws {
    let editor = makeEditor()
    let id = try add(editor)
    let before = editor.graph
    func move(_ x: Double) throws -> GraphChange {
        try editor.apply(.setNodePositions(placements: [NodePlacement(node: id, position: GraphPoint(x: x, y: 0))]))
    }
    let first = try move(1), second = try move(2), third = try move(3)
    let merged = try #require(first.coalesced(with: second)?.coalesced(with: third))
    #expect(merged.command == .setNodePositions(placements: [NodePlacement(node: id, position: GraphPoint(x: 3, y: 0))]))
    try editor.apply(merged.inverse, validation: .structural)
    #expect(editor.graph == before)
}

@Test func unrelatedCommandsDoNotCoalesce() {
    let a = NodeID(), b = NodeID()
    let moveA = GraphCommand.setNodePositions(placements: [NodePlacement(node: a, position: .zero)])
    let moveB = GraphCommand.setNodePositions(placements: [NodePlacement(node: b, position: .zero)])
    #expect(moveA.coalesced(with: moveB) == nil)
    #expect(GraphCommand.setNodeProperty(node: a, property: "x", value: 1)
        .coalesced(with: .setNodeProperty(node: a, property: "y", value: 1)) == nil)
    #expect(GraphCommand.setNodeAttribute(node: a, attribute: .mode(value: .muted))
        .coalesced(with: .setNodeAttribute(node: a, attribute: .isPinned(value: true))) == nil)
    #expect(GraphCommand.removeNode(id: a).coalesced(with: .removeNode(id: a)) == nil)
}

// MARK: Change stream

@Test func changesReachEverySubscriberInOrder() async throws {
    let editor = makeEditor()
    let first = editor.changes(), second = editor.changes()
    let a = try add(editor)
    try editor.apply(.setNodeAttribute(node: a, attribute: .isPinned(value: true)))

    var firstRevisions: [Int] = [], secondRevisions: [Int] = []
    for await change in first { firstRevisions.append(change.revision); if firstRevisions.count == 2 { break } }
    for await change in second { secondRevisions.append(change.revision); if secondRevisions.count == 2 { break } }
    #expect(firstRevisions == [1, 2] && secondRevisions == [1, 2])
}

@Test func failedCommandsPublishNothing() async throws {
    let editor = makeEditor()
    let stream = editor.changes()
    #expect(throws: GraphEditError.self) { try editor.apply(.removeNode(id: NodeID())) }
    let id = try add(editor)
    for await change in stream {
        #expect(change.revision == 1 && change.inverse == .removeNode(id: id))
        break
    }
}

// MARK: Serialization

@Test func commandsRoundTripThroughJSON() throws {
    let a = Node(typeID: "pass", properties: ["gain": 2.0])
    let link = Link(sourceNode: a.id, sourcePort: "out", targetNode: a.id, targetPort: "in")
    let command = GraphCommand.batch(commands: [
        .addNode(node: a, index: 0),
        .addLink(link: link),
        .setNodeAttribute(node: a.id, attribute: .size(value: nil)),
        .setNodeProperty(node: a.id, property: "gain", value: nil),
        .updateGroup(group: NodeGroup(title: "g", bounds: GraphRect(x: 0, y: 0, width: 1, height: 1))),
    ])
    let change = GraphChange(revision: 3, command: command, inverse: .removeNode(id: a.id))
    let data = try JSONEncoder().encode(change)
    #expect(try JSONDecoder().decode(GraphChange.self, from: data) == change)
}

@Test func nodePropertiesEncodeAsASortedObject() throws {
    let node = Node(typeID: "t", properties: ["b": 1, "a": 2, "c": 3])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(node), as: UTF8.self)
    #expect(json.contains(#""properties":{"a":{"type":"int","value":2},"b":{"type":"int","value":1},"c":{"type":"int","value":3}}"#))
    #expect(try JSONDecoder().decode(Node.self, from: Data(json.utf8)) == node)
}

@Test func moveOfAMissingNodeIsRejectedAndChangesNothing() throws {
    let editor = makeEditor()
    let id = try add(editor)
    let before = editor.graph
    #expect(throws: GraphEditError.self) {
        try editor.apply(.setNodePositions(placements: [
            NodePlacement(node: id, position: GraphPoint(x: 9, y: 9)),
            NodePlacement(node: NodeID(), position: .zero),
        ]))
    }
    #expect(editor.graph == before)
}

@Test func addedNodesHaveTheirPropertiesChecked() throws {
    let editor = makeEditor()
    #expect(throws: GraphEditError.invalidProperty("gain", .outOfRange)) {
        try editor.apply(.addNode(node: Node(typeID: "pass", properties: ["gain": 99.0])))
    }
    #expect(throws: GraphEditError.unknownProperty("nope")) {
        try editor.apply(.addNode(node: Node(typeID: "pass", properties: ["nope": 1])))
    }
    #expect(editor.graph.nodes.isEmpty)
}

@Test func propertyEditsOnUnregisteredTypesFailInFullButNotStructuralMode() throws {
    let editor = makeEditor()
    let ghost = Node(typeID: "ghost")
    try editor.apply(.addNode(node: ghost), validation: .structural)
    #expect(throws: GraphEditError.unknownNodeType("ghost")) {
        try editor.apply(.setNodeProperty(node: ghost.id, property: "x", value: 1))
    }
    try editor.apply(.setNodeProperty(node: ghost.id, property: "x", value: 1), validation: .structural)
    #expect(editor.graph.nodes[ghost.id]?.properties["x"] == 1)
}

@Test func missingTargetsAreRejectedForEveryCommand() throws {
    let editor = makeEditor()
    let missing = NodeID()
    #expect(throws: GraphEditError.nodeNotFound(missing)) {
        try editor.apply(.setNodeAttribute(node: missing, attribute: .isPinned(value: true)))
    }
    #expect(throws: GraphEditError.nodeNotFound(missing)) {
        try editor.apply(.setNodeProperty(node: missing, property: "gain", value: 1.0))
    }
    let link = LinkID(), group = GroupID()
    #expect(throws: GraphEditError.linkNotFound(link)) { try editor.apply(.removeLink(id: link)) }
    #expect(throws: GraphEditError.groupNotFound(group)) { try editor.apply(.removeGroup(id: group)) }
    let ghostGroup = NodeGroup(id: group, title: "g", bounds: GraphRect(x: 0, y: 0, width: 1, height: 1))
    #expect(throws: GraphEditError.groupNotFound(group)) { try editor.apply(.updateGroup(group: ghostGroup)) }
}

@Test func duplicateLinkAndGroupIDsAreRejected() throws {
    let editor = makeEditor()
    let a = try add(editor), b = try add(editor)
    let link = Link(sourceNode: a, sourcePort: "out", targetNode: b, targetPort: "in")
    try editor.apply(.addLink(link: link))
    #expect(throws: GraphEditError.duplicateID(link.id.description)) { try editor.apply(.addLink(link: link)) }
    let group = NodeGroup(title: "g", bounds: GraphRect(x: 0, y: 0, width: 1, height: 1))
    try editor.apply(.addGroup(group: group))
    #expect(throws: GraphEditError.duplicateID(group.id.description)) { try editor.apply(.addGroup(group: group)) }
    #expect(throws: GraphEditError.indexOutOfRange(-1)) { try editor.apply(.addGroup(group: NodeGroup(title: "x", bounds: group.bounds), index: -1)) }
}

@Test func everyEditedRevisionIsRecordedInTheChange() throws {
    let editor = makeEditor(), id = try add(editor)
    let change = try editor.apply(.setNodeAttribute(node: id, attribute: .color(value: RGBAColor(red: 1, green: 0, blue: 0))))
    #expect(change.revision == editor.revision && editor.revision == 2)
}

// MARK: Bridging a deleted node

@Suite struct BridgeTests {
    private func rig() throws -> (editor: GraphEditor, a: NodeID, b: NodeID, c: NodeID) {
        let (nodes, types) = registries()
        let editor = GraphEditor(nodes: nodes, types: types)
        let a = Node(typeID: "add"), b = Node(typeID: "add"), c = Node(typeID: "add")
        for node in [a, b, c] { try editor.apply(.addNode(node: node)) }
        return (editor, a.id, b.id, c.id)
    }

    private func link(_ editor: GraphEditor, _ from: NodeID, _ to: NodeID, _ port: PortID) throws {
        try editor.apply(.addLink(link: Link(sourceNode: from, sourcePort: "out", targetNode: to, targetPort: port)))
    }

    @Test func proposesJoiningWhatFeedsTheFirstLinkedInputToWhatItsOutputFeeds() throws {
        let (editor, a, b, c) = try rig()
        try link(editor, a, b, "b")
        try link(editor, b, c, "a")
        let proposals = editor.bridgeProposals(deleting: b)
        #expect(proposals.count == 1)
        #expect(proposals[0].source == PortAddress(node: a, port: "out", direction: .output))
        #expect(proposals[0].target == PortAddress(node: c, port: "a", direction: .input))
    }

    @Test func proposesNothingWhenOneSideIsMissing() throws {
        let (editor, a, b, c) = try rig()
        try link(editor, a, b, "a")
        #expect(editor.bridgeProposals(deleting: b).isEmpty)
        #expect(editor.bridgeProposals(deleting: c).isEmpty)
        #expect(editor.bridgeProposals(deleting: NodeID()).isEmpty)
    }

    @Test func everySourceJoinsEveryTarget() throws {
        let (editor, a, b, c) = try rig()
        let d = Node(typeID: "add")
        try editor.apply(.addNode(node: d))
        try link(editor, a, b, "a")
        try link(editor, b, c, "a")
        try link(editor, b, d.id, "a")
        #expect(editor.bridgeProposals(deleting: b).count == 2)
    }
}
