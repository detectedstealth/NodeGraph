import Testing
import NodeGraphCore
@testable import NodeGraphAssistant

private let number = PortType("number")

private func makeRegistries() -> (NodeRegistry, TypeRegistry) {
    var types = TypeRegistry()
    types.register(PortTypeInfo(type: number, displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 0)))
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "add", displayName: "Add",
        ports: [
            PortDefinition(id: "a", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "b", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "out", direction: .output, type: number),
        ]))
    nodes.register(NodeDefinition(
        typeID: "const", displayName: "Const",
        ports: [PortDefinition(id: "out", direction: .output, type: number)],
        properties: [
            PropertyDefinition(id: "value", displayName: "Value", kind: .double(), defaultValue: 0.0),
            PropertyDefinition(id: "label", displayName: "Label", kind: .string(), defaultValue: ""),
        ]))
    return (nodes, types)
}

private func link(_ editor: GraphEditor, _ from: Node, _ to: Node, _ port: PortID) throws {
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: from.id, port: "out", direction: .output),
        target: PortAddress(node: to.id, port: port, direction: .input)))
}

/// `const(4) -> add.a`, `const -> add.b`, and a lone `const` further right.
private func makeEditor() throws -> (editor: GraphEditor, a: Node, sum: Node, b: Node, lone: Node) {
    let (nodes, types) = makeRegistries()
    let editor = GraphEditor(nodes: nodes, types: types)
    let a = Node(typeID: "const", properties: ["value": 4.0])
    let sum = Node(typeID: "add", position: GraphPoint(x: 300, y: 0))
    let b = Node(typeID: "const")
    let lone = Node(typeID: "const", position: GraphPoint(x: 900, y: 0))
    for node in [a, sum, b, lone] { try editor.apply(.addNode(node: node)) }
    try link(editor, a, sum, "a")
    try link(editor, b, sum, "b")
    return (editor, a, sum, b, lone)
}

@Suite struct GraphDigestTests {
    @Test func describesNodesAndLinksWithOnlyNonDefaultProperties() throws {
        let (editor, _, _, _, _) = try makeEditor()
        let digest = GraphDigest(graph: editor.graph, registry: editor.nodes)
        #expect(digest.text == """
            nodes:
            n1 const value=4.0
            n2 add
            n3 const
            n4 const
            links:
            n1.out -> n2.a
            n3.out -> n2.b
            """)
        #expect(digest.omittedNodeCount == 0)
    }

    @Test func aliasesMapBackToNodesAndStayStableAcrossScopes() throws {
        let (editor, a, sum, _, lone) = try makeEditor()
        let all = GraphDigest(graph: editor.graph, registry: editor.nodes)
        let part = GraphDigest(graph: editor.graph, registry: editor.nodes, scope: .nodes([lone.id]))
        #expect(all.alias(for: sum.id) == "n2")
        #expect(all.node(for: "n1") == a.id)
        #expect(part.alias(for: lone.id) == "n4")  // numbered over the whole graph, not the selection
        #expect(part.text == "nodes:\nn4 const")
        #expect(all.node(for: "n99") == nil)
    }

    @Test func neighborhoodFollowsLinksBothWaysAndReportsBoundaryLinks() throws {
        let (editor, _, sum, _, _) = try makeEditor()
        let near = GraphDigest(
            graph: editor.graph, registry: editor.nodes, scope: .neighborhood(of: [sum.id], depth: 0))
        #expect(near.text == """
            nodes:
            n2 add
            boundary links:
            n1.out -> n2.a
            n3.out -> n2.b
            """)
        let wider = GraphDigest(
            graph: editor.graph, registry: editor.nodes, scope: .neighborhood(of: [sum.id], depth: 1))
        #expect(wider.shownNodes.count == 3)
        #expect(!wider.text.contains("boundary"))
        #expect(!wider.text.contains("n4"))
    }

    @Test func showsTitleModeAndEscapesStrings() throws {
        let (nodes, types) = makeRegistries()
        let editor = GraphEditor(nodes: nodes, types: types)
        try editor.apply(.addNode(node: Node(
            typeID: "const", title: "Say \"hi\"", mode: .muted, properties: ["label": "a\nb"])))
        let digest = GraphDigest(graph: editor.graph, registry: editor.nodes)
        #expect(digest.text.contains(#"n1 const "Say \"hi\"" label="a\nb" [muted]"#))
    }

    @Test func flagsUnregisteredTypesAndKeepsTheirProperties() throws {
        let (nodes, types) = makeRegistries()
        // The editor knows the type; the registry used for the digest does not, as with a loaded file.
        var known = nodes
        known.register(NodeDefinition(
            typeID: "mystery", displayName: "Mystery",
            properties: [PropertyDefinition(id: "speed", displayName: "Speed", kind: .int(), defaultValue: 0)]))
        let editor = GraphEditor(nodes: known, types: types)
        try editor.apply(.addNode(node: Node(typeID: "mystery", properties: ["speed": 3])))
        let digest = GraphDigest(graph: editor.graph, registry: nodes)
        #expect(digest.text.contains("n1 mystery speed=3 [unregistered]"))
    }

    @Test func fullAddsGroupsAndVariablesWhichCompactOmits() throws {
        let (editor, a, sum, _, _) = try makeEditor()
        try editor.apply(.addGroup(group: NodeGroup(
            title: "Adder",
            bounds: GraphRect(x: -10, y: -10, width: 600, height: 400))))
        try editor.apply(.addVariable(variable: GraphVariable(name: "gain", type: number, value: 2.0, summary: "scale")))
        let full = GraphDigest(graph: editor.graph, registry: editor.nodes, detail: .full)
        #expect(full.text.contains("groups:\n\"Adder\": n1 n2 n3"))
        #expect(full.text.contains("variables:\ngain = 2.0 (number) - scale"))
        let compact = GraphDigest(graph: editor.graph, registry: editor.nodes, detail: .compact)
        #expect(!compact.text.contains("groups:") && !compact.text.contains("variables:"))
        let outline = GraphDigest(graph: editor.graph, registry: editor.nodes, detail: .outline)
        #expect(outline.text.contains("n1 const\n"))  // the value is dropped
        _ = (a, sum)
    }

    @Test func maxNodesDropsTheLastNodesAndCountsThem() throws {
        let (editor, _, _, _, _) = try makeEditor()
        let digest = GraphDigest(graph: editor.graph, registry: editor.nodes, maxNodes: 2)
        #expect(digest.shownNodes.count == 2)
        #expect(digest.omittedNodeCount == 2)
        #expect(digest.text.hasSuffix("(2 more nodes not shown)"))
        #expect(digest.text.contains("boundary links:\nn3.out -> n2.b"))
    }

    @Test func fittingStepsDownDetailThenDropsNodes() throws {
        let (nodes, types) = makeRegistries()
        let editor = GraphEditor(nodes: nodes, types: types)
        var previous: Node?
        for index in 0..<60 {
            let node = Node(typeID: index == 0 ? "const" : "add", properties: index == 0 ? ["value": 7.5] : [:])
            try editor.apply(.addNode(node: node))
            if let previous { try link(editor, previous, node, "a") }
            previous = node
        }
        let large = GraphDigest.fitting(tokenBudget: 100_000, graph: editor.graph, registry: editor.nodes)
        #expect(large.detail == .full && large.omittedNodeCount == 0)

        let full = GraphDigest(graph: editor.graph, registry: editor.nodes, detail: .full)
        let outline = GraphDigest(graph: editor.graph, registry: editor.nodes, detail: .outline)
        let between = GraphDigest.fitting(tokenBudget: outline.estimatedTokens, graph: editor.graph, registry: editor.nodes)
        #expect(full.estimatedTokens > between.estimatedTokens)
        #expect(between.detail == .outline && between.omittedNodeCount == 0)

        let tight = GraphDigest.fitting(tokenBudget: 150, graph: editor.graph, registry: editor.nodes)
        #expect(tight.estimatedTokens <= 150)
        #expect(tight.omittedNodeCount > 0 && !tight.shownNodes.isEmpty)

        let none = GraphDigest.fitting(tokenBudget: 1, graph: editor.graph, registry: editor.nodes)
        #expect(none.shownNodes.isEmpty)
    }

    @Test func descriptionIsDeterministic() throws {
        let (editor, _, _, _, _) = try makeEditor()
        let first = GraphDigest(graph: editor.graph, registry: editor.nodes).text
        let second = GraphDigest(graph: editor.graph, registry: editor.nodes).text
        #expect(first == second)
    }
}
