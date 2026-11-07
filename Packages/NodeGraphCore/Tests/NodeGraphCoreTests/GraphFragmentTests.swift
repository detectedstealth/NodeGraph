import Foundation
import Testing
@testable import NodeGraphCore

@Suite struct GraphFragmentTests {
    /// Two linked nodes and a third that is linked to the first, in an editor with an Adder subgraph.
    private func makeEditor() throws -> (editor: GraphEditor, a: Node, b: Node, c: Node) {
        let (nodes, types) = registries()
        let editor = GraphEditor(nodes: nodes, types: types)
        let a = Node(typeID: "const", position: GraphPoint(x: 0, y: 0), properties: ["value": 4.0])
        let b = Node(typeID: "add", position: GraphPoint(x: 300, y: 40))
        let c = Node(typeID: "const", position: GraphPoint(x: 0, y: 300))
        for node in [a, b, c] { try editor.apply(.addNode(node: node)) }
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: a.id, port: "out", direction: .output),
            target: PortAddress(node: b.id, port: "a", direction: .input)))
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: c.id, port: "out", direction: .output),
            target: PortAddress(node: b.id, port: "b", direction: .input)))
        return (editor, a, b, c)
    }

    @Test func aFragmentKeepsOnlyLinksBetweenItsNodes() throws {
        let (editor, a, b, _) = try makeEditor()
        let fragment = try editor.fragment(nodes: [a.id, b.id])
        #expect(fragment.nodes.map(\.id) == [a.id, b.id])
        #expect(fragment.links.count == 1)  // c's link to b is cut at the edge
        #expect(fragment.links.first?.source.node == a.id)
        #expect(fragment.nodes.first?.properties["value"] == 4.0)
    }

    @Test func unknownNodesAndGroupsAreRefused() throws {
        let (editor, _, _, _) = try makeEditor()
        #expect(throws: GraphEditError.self) { try editor.fragment(nodes: [NodeID()]) }
        #expect(throws: GraphEditError.self) { try editor.fragment(nodes: [], groups: [GroupID()]) }
        #expect(throws: GraphEditError.self) { try editor.fragment(nodes: [], in: SubgraphID()) }
    }

    @Test func pastingMakesNewIdsAndKeepsTheShape() throws {
        let (editor, a, b, _) = try makeEditor()
        let fragment = try editor.fragment(nodes: [a.id, b.id])
        let paste = try editor.pasteCommand(fragment, translatedBy: GraphPoint(x: 50, y: 20))
        try editor.apply(paste.command)
        #expect(editor.graph.nodes.count == 5 && editor.graph.links.count == 3)
        #expect(paste.nodes.count == 2 && Set(paste.nodes).isDisjoint(with: [a.id, b.id]))
        let first = try #require(editor.graph.nodes[paste.nodes[0]])
        #expect(first.position == GraphPoint(x: 50, y: 20) && first.properties["value"] == 4.0)
        #expect(editor.graph.nodes[paste.nodes[1]]?.position == GraphPoint(x: 350, y: 60))
        // The pasted link joins the pasted nodes, not the originals.
        let link = try #require(editor.graph.links.values.last)
        #expect(link.source.node == paste.nodes[0] && link.target.node == paste.nodes[1])
    }

    @Test func pastingTwiceGivesDifferentNodes() throws {
        let (editor, a, _, _) = try makeEditor()
        let fragment = try editor.fragment(nodes: [a.id])
        let first = try editor.pasteCommand(fragment)
        let second = try editor.pasteCommand(fragment)
        try editor.apply(first.command)
        try editor.apply(second.command)
        #expect(Set(first.nodes + second.nodes).count == 2)
        #expect(editor.graph.nodes.count == 5)
    }

    @Test func aPasteUndoesAsOneChange() throws {
        let (editor, a, b, _) = try makeEditor()
        let before = editor.graph
        let fragment = try editor.fragment(nodes: [a.id, b.id])
        let change = try editor.apply(editor.pasteCommand(fragment).command)
        try editor.revert(change)
        #expect(editor.graph == before)
    }

    @Test func groupsAndWaypointsMoveWithThePaste() throws {
        let (editor, a, b, _) = try makeEditor()
        let group = NodeGroup(title: "G", bounds: GraphRect(x: -10, y: -10, width: 500, height: 200))
        try editor.apply(.addGroup(group: group))
        let link = try #require(editor.graph.links.values.first { $0.source.node == a.id })
        try editor.apply(.setLinkWaypoints(link: link.id, waypoints: [GraphPoint(x: 150, y: 0)]))
        let fragment = try editor.fragment(nodes: [a.id, b.id], groups: [group.id])
        let paste = try editor.pasteCommand(fragment, translatedBy: GraphPoint(x: 0, y: 600))
        try editor.apply(paste.command)
        let newGroup = try #require(editor.graph.groups[paste.groups[0]])
        #expect(newGroup.id != group.id && newGroup.bounds.origin == GraphPoint(x: -10, y: 590) && newGroup.title == "G")
        let newLink = try #require(editor.graph.links.values.last)
        #expect(newLink.waypoints == [GraphPoint(x: 150, y: 600)])
    }

    @Test func boundsCoverNodesAndGroups() throws {
        let (editor, a, b, _) = try makeEditor()
        let group = NodeGroup(title: "G", bounds: GraphRect(x: -50, y: -50, width: 10, height: 10))
        try editor.apply(.addGroup(group: group))
        let fragment = try editor.fragment(nodes: [a.id, b.id], groups: [group.id])
        let bounds = try #require(fragment.bounds(frame: editor.nodes.frame(of:)))
        #expect(bounds.minX == -50 && bounds.minY == -50)
        #expect(bounds.maxX >= 300 && bounds.maxY >= 40)
        #expect(GraphFragment().bounds(frame: editor.nodes.frame(of:)) == nil)
    }

    @Test func subgraphDefinitionsTravelWithTheirInstancesAndAreAddedOnce() throws {
        let (editor, _, _, _) = try makeEditor()
        let adder = Adder()
        try editor.apply(.addSubgraph(definition: adder.definition))
        let instance = Node(typeID: adder.definition.typeID, position: GraphPoint(x: 600, y: 0))
        try editor.apply(.addNode(node: instance))
        let fragment = try editor.fragment(nodes: [instance.id])
        #expect(fragment.subgraphs.map(\.id) == [adder.definition.id])

        // Into the same document: the definition is already there, so it is not added again.
        try editor.apply(editor.pasteCommand(fragment).command)
        #expect(editor.subgraphs.count == 1)
        #expect(editor.graph.nodes.values.filter { $0.typeID == adder.definition.typeID }.count == 2)

        // Into a document that has never heard of it: the definition comes along.
        let (nodes, types) = registries()
        let other = GraphEditor(nodes: nodes, types: types)
        let paste = try other.pasteCommand(fragment)
        try other.apply(paste.command)
        #expect(other.subgraphs[adder.definition.id] != nil)
        #expect(other.graph.nodes.count == 1)
    }

    @Test func nestedDefinitionsComeInDependencyOrder() throws {
        let (editor, _, _, _) = try makeEditor()
        let inner = Adder()
        try editor.apply(.addSubgraph(definition: inner.definition))
        var outerGraph = Graph()
        outerGraph.insert(Node(typeID: inner.definition.typeID))
        let outer = SubgraphDefinition(interface: SubgraphInterface(name: "Outer"), graph: outerGraph)
        try editor.apply(.addSubgraph(definition: outer))
        let instance = Node(typeID: outer.typeID)
        try editor.apply(.addNode(node: instance))
        let fragment = try editor.fragment(nodes: [instance.id])
        #expect(fragment.subgraphs.map(\.id) == [inner.definition.id, outer.id])
        let (nodes, types) = registries()
        let fresh = GraphEditor(nodes: nodes, types: types)
        try fresh.apply(fresh.pasteCommand(fragment).command)
        #expect(fresh.subgraphs.count == 2)
    }

    @Test func pastingANodeTypeTheEditorLacksIsRefused() throws {
        let (editor, a, _, _) = try makeEditor()
        var fragment = try editor.fragment(nodes: [a.id])
        fragment.nodes[0].typeID = "from.a.missing.pack"
        #expect(editor.missingNodeTypes(in: fragment) == ["from.a.missing.pack"])
        #expect(throws: GraphEditError.self) { try editor.pasteCommand(fragment) }
    }

    @Test func pastingInsideASubgraphChangesTheInnerGraphOnly() throws {
        let (editor, a, _, _) = try makeEditor()
        let adder = Adder()
        try editor.apply(.addSubgraph(definition: adder.definition))
        let fragment = try editor.fragment(nodes: [a.id])
        let rootBefore = editor.graph
        let paste = try editor.pasteCommand(fragment, translatedBy: GraphPoint(x: 5, y: 5), in: adder.definition.id)
        try editor.apply(paste.command)
        #expect(editor.graph == rootBefore)
        #expect(editor.editedGraph(in: adder.definition.id)?.nodes[paste.nodes[0]]?.position == GraphPoint(x: 5, y: 5))
    }

    @Test func copyingFromInsideASubgraphReadsTheInnerGraph() throws {
        let (editor, _, _, _) = try makeEditor()
        let adder = Adder()
        try editor.apply(.addSubgraph(definition: adder.definition))
        let fragment = try editor.fragment(nodes: [adder.add, adder.constant], in: adder.definition.id)
        #expect(fragment.nodes.count == 2 && fragment.links.count == 1)
    }

    @Test func theFileFormRoundTripsAndIsDeterministic() throws {
        let (editor, a, b, _) = try makeEditor()
        let fragment = try editor.fragment(nodes: [a.id, b.id])
        let data = try fragment.encoded()
        #expect(try GraphFragment.decode(from: data) == fragment)
        #expect(try fragment.encoded() == data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"kind\" : \"nodegraph.fragment\""))
    }

    @Test func otherJSONIsNotAFragment() throws {
        #expect(throws: DecodingError.self) { try GraphFragment.decode(from: Data("{\"nodes\": []}".utf8)) }
        #expect(throws: DecodingError.self) {
            try GraphFragment.decode(from: Data("{\"kind\":\"something.else\",\"schemaVersion\":1,\"nodes\":[]}".utf8))
        }
        #expect(throws: DecodingError.self) { try GraphFragment.decode(from: Data("plain text".utf8)) }
    }

    @Test func aNewerVersionIsRefused() throws {
        let json = "{\"kind\":\"nodegraph.fragment\",\"schemaVersion\":99,\"nodes\":[]}"
        #expect(throws: DecodingError.self) { try GraphFragment.decode(from: Data(json.utf8)) }
    }

    @Test func anEmptyFragmentPastesNothing() throws {
        let (editor, _, _, _) = try makeEditor()
        #expect(GraphFragment().isEmpty)
        let paste = try editor.pasteCommand(GraphFragment())
        #expect(paste.nodes.isEmpty)
    }
}
