import Testing
import NodeGraphCore
@testable import NodeGraphAssistant

private let number = PortType("number")

private func makeEditor() -> GraphEditor {
    var types = TypeRegistry()
    types.register(PortTypeInfo(type: number, displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 0)))
    var nodes = NodeRegistry()
    func ports(_ inputs: [String], defaults: Bool, out: Bool = true) -> [PortDefinition] {
        inputs.map { PortDefinition(id: PortID($0), direction: .input, type: number, defaultValue: defaults ? 0.0 : nil) }
            + (out ? [PortDefinition(id: "out", direction: .output, type: number)] : [])
    }
    nodes.register(NodeDefinition(
        typeID: "const", displayName: "Const", ports: ports([], defaults: true),
        properties: [PropertyDefinition(id: "value", displayName: "Value", kind: .double(), defaultValue: 0.0)],
        isPure: true))
    nodes.register(NodeDefinition(typeID: "add", displayName: "Add", ports: ports(["a", "b"], defaults: true), isPure: true))
    nodes.register(NodeDefinition(typeID: "strict", displayName: "Strict", ports: ports(["a", "b"], defaults: false), isPure: true))
    nodes.register(NodeDefinition(typeID: "sink", displayName: "Sink", ports: ports(["in"], defaults: false, out: false)))
    nodes.register(NodeDefinition(
        typeID: "watch", displayName: "Watch",
        ports: [PortDefinition(id: "in", direction: .input, type: number), PortDefinition(id: "out", direction: .output, type: number)]))
    nodes.register(NodeDefinition(
        typeID: "readVar", displayName: "Read Variable", ports: ports([], defaults: true),
        properties: [PropertyDefinition(id: "name", displayName: "Name", kind: .variable, defaultValue: "")],
        isPure: true))
    return GraphEditor(nodes: nodes, types: types)
}

@discardableResult
private func add(_ editor: GraphEditor, _ type: String, at x: Double = 0, _ configure: (inout Node) -> Void = { _ in }) throws -> Node {
    var node = Node(typeID: NodeTypeID(type), position: GraphPoint(x: x, y: 0))
    configure(&node)
    try editor.apply(.addNode(node: node))
    return node
}

private func link(_ editor: GraphEditor, _ from: Node, _ to: Node, _ port: PortID = "a") throws {
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: from.id, port: "out", direction: .output),
        target: PortAddress(node: to.id, port: port, direction: .input)))
}

private func findings(_ editor: GraphEditor, _ lint: any GraphLint) -> [LintFinding] {
    lint.check(in: LintContext(editor: editor))
}

@Suite struct GraphLintTests {
    @Test func unconnectedInputIgnoresDefaultsAndIsolatedNodes() throws {
        let editor = makeEditor()
        let c = try add(editor, "const"), strict = try add(editor, "strict"), loose = try add(editor, "add")
        try add(editor, "strict")  // isolated: reported as isolated, not for each input
        try link(editor, c, strict, "a")
        try link(editor, c, loose, "a")
        let result = findings(editor, Lints.UnconnectedInput())
        #expect(result.count == 1)
        #expect(result[0].diagnostic.port == PortAddress(node: strict.id, port: "b", direction: .input))
        #expect(result[0].level == .problem && result[0].diagnostic.severity == .warning)
    }

    @Test func isolatedNodesCanBeRemovedWithTheSuggestedFix() throws {
        let editor = makeEditor()
        let lone = try add(editor, "add"), c = try add(editor, "const"), s = try add(editor, "sink")
        try link(editor, c, s, "in")
        let result = findings(editor, Lints.IsolatedNode())
        #expect(result.map(\.diagnostic.node) == [lone.id])
        try editor.apply(try #require(result[0].fix).command)
        #expect(editor.graph.nodes[lone.id] == nil && editor.graph.nodes.count == 2)
        #expect(findings(editor, Lints.IsolatedNode()).isEmpty)
    }

    @Test func unusedOutputsSkipSinksAndPassThroughs() throws {
        let editor = makeEditor()
        let c = try add(editor, "const"), dead = try add(editor, "add"), watch = try add(editor, "watch"), s = try add(editor, "sink")
        try link(editor, c, dead)
        try link(editor, c, watch, "in")
        try link(editor, c, s, "in")
        let result = findings(editor, Lints.UnusedOutput())
        #expect(result.map(\.diagnostic.node) == [dead.id])
        #expect(result[0].fix == nil)
    }

    @Test func disabledAndMutedNodesThatFeedOthersAreProblemsWithAFix() throws {
        let editor = makeEditor()
        let muted = try add(editor, "const") { $0.mode = .muted }
        let off = try add(editor, "const") { $0.mode = .never }
        let idle = try add(editor, "const") { $0.mode = .muted }  // feeds nothing
        let s = try add(editor, "add"), t = try add(editor, "add")
        try link(editor, muted, s)
        try link(editor, off, t)
        let result = findings(editor, Lints.InactiveNode())
        #expect(result.map(\.diagnostic.node) == [muted.id, off.id])
        #expect(result[0].diagnostic.message.contains("muted") && result[1].diagnostic.message.contains("disabled"))
        #expect(result.allSatisfy { $0.level == .problem })
        for finding in result { try editor.apply(try #require(finding.fix).command) }
        #expect(editor.graph.nodes[muted.id]?.mode == .always && editor.graph.nodes[off.id]?.mode == .always)
        #expect(editor.graph.nodes[idle.id]?.mode == .muted)
        #expect(findings(editor, Lints.InactiveNode()).isEmpty)
    }

    @Test func onlyTheEndOfAConstantChainIsReported() throws {
        let editor = makeEditor()
        let c1 = try add(editor, "const"), c2 = try add(editor, "const"), c3 = try add(editor, "const")
        let first = try add(editor, "add"), second = try add(editor, "add"), s = try add(editor, "sink")
        try link(editor, c1, first, "a")
        try link(editor, c2, first, "b")
        try link(editor, first, second, "a")
        try link(editor, c3, second, "b")
        try link(editor, second, s, "in")
        let result = findings(editor, Lints.ConstantExpression())
        #expect(result.map(\.diagnostic.node) == [second.id])
    }

    @Test func nothingFedByAVariableIsConstant() throws {
        let editor = makeEditor()
        try editor.apply(.addVariable(variable: GraphVariable(name: "gain", type: number, value: 1.0)))
        let variable = try add(editor, "readVar") { $0.properties["name"] = "gain" }
        let c = try add(editor, "const"), sum = try add(editor, "add"), s = try add(editor, "sink")
        try link(editor, variable, sum, "a")
        try link(editor, c, sum, "b")
        try link(editor, sum, s, "in")
        #expect(findings(editor, Lints.ConstantExpression()).isEmpty)
    }

    @Test func duplicatesNeedTheSameSettingsAndTheSameInputs() throws {
        let editor = makeEditor()
        let c = try add(editor, "const"), other = try add(editor, "const") { $0.properties["value"] = 2.0 }
        let one = try add(editor, "add"), same = try add(editor, "add"), different = try add(editor, "add")
        try link(editor, c, one)
        try link(editor, c, same)
        try link(editor, other, different)
        let result = findings(editor, Lints.DuplicateNode())
        #expect(result.map(\.diagnostic.node) == [same.id])
        // Equal constants, with no inputs, are not worth a remark.
        try add(editor, "const")
        #expect(findings(editor, Lints.DuplicateNode()).count == 1)
    }

    @Test func emptyGroupsAreFlaggedAndRemovable() throws {
        let editor = makeEditor()
        try add(editor, "const")
        let framing = NodeGroup(title: "Has one", bounds: GraphRect(x: -50, y: -50, width: 400, height: 400))
        let empty = NodeGroup(title: "Empty", bounds: GraphRect(x: 2000, y: 2000, width: 100, height: 100))
        try editor.apply(.addGroup(group: framing))
        try editor.apply(.addGroup(group: empty))
        let result = findings(editor, Lints.EmptyGroup())
        #expect(result.count == 1 && result[0].diagnostic.message.contains("Empty"))
        try editor.apply(try #require(result[0].fix).command)
        #expect(editor.graph.groups.count == 1)
    }

    @Test func unusedVariablesAreFlaggedAndRemovable() throws {
        let editor = makeEditor()
        for name in ["gain", "spare"] {
            try editor.apply(.addVariable(variable: GraphVariable(name: name, type: number, value: 1.0)))
        }
        try add(editor, "readVar") { $0.properties["name"] = "gain" }
        let result = findings(editor, Lints.UnusedVariable())
        #expect(result.count == 1 && result[0].diagnostic.message.contains("spare"))
        try editor.apply(try #require(result[0].fix).command)
        #expect(Array(editor.graph.variables.keys) == ["gain"])
    }

    @Test func theLinterRunsLintsInOrderAndAcceptsRulesAndExtraLints() throws {
        struct NeedsASink: GraphRule {
            let id = "needsSink"
            let summary = "A graph needs a sink."
            func check(in context: ValidationContext) -> [GraphDiagnostic] {
                context.graph.nodes.values.contains { $0.typeID == "sink" }
                    ? [] : [GraphDiagnostic(code: "rule.needsSink", message: "No sink.")]
            }
        }
        let editor = makeEditor()
        try add(editor, "add")
        let context = LintContext(editor: editor)
        let linter = GraphLinter().adding(RuleLint(NeedsASink()))
        let first = linter.run(in: context), second = linter.run(in: context)
        #expect(first == second)
        #expect(first.map(\.lint) == ["lint.isolatedNode", "rule.needsSink"])
        #expect(first[1].level == .problem)
        #expect(linter.lints.map(\.id).count == GraphLinter.standardLints.count + 1)
    }
}
