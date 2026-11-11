import Testing
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAssistant

private typealias N = GraphSpec.NodeSpec
private typealias L = GraphSpec.LinkSpec

/// (four + eight) * two, as n1...n5 in that order, with n3 = sum and n5 = product.
private func arithmetic() throws -> GraphEditor {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    let spec = GraphSpec(
        nodes: [
            N(alias: "four", type: "util.number", properties: ["value": .int(4)]),
            N(alias: "eight", type: "util.number", properties: ["value": .int(8)]),
            N(alias: "sum", type: "math.add"),
            N(alias: "two", type: "util.number", properties: ["value": .int(2)]),
            N(alias: "product", type: "math.multiply"),
        ],
        links: [
            L(from: "four.value", to: "sum.a"), L(from: "eight.value", to: "sum.b"),
            L(from: "sum.result", to: "product.a"), L(from: "two.value", to: "product.b"),
        ])
    let editor = GraphEditor(nodes: nodes, types: types)
    let result = GraphSpecCompiler(nodes: nodes, types: types).compile(spec)
    try editor.apply(try result.pasteCommand(into: editor).command)
    return editor
}

private func workspace(_ editor: GraphEditor, run: Bool = true) async throws -> AssistantWorkspace {
    let base = AssistantWorkspace(editor: editor)
    return AssistantWorkspace(editor: editor, runValues: run ? try await base.run().values : RunValues())
}

@Suite struct AssistantReadToolTests {
    @Test func searchRanksByIdNameCategoryAndHelp() throws {
        let space = AssistantWorkspace(editor: try arithmetic())
        let found = space.searchNodes("add numbers")
        #expect(found.first?.typeID == "math.add")
        #expect(found.first?.rendered.contains("in: a number, b number; out: result number") == true)
        #expect(space.searchNodes("add", limit: 1).count == 1)
        #expect(space.searchNodes("add", category: "Logic").allSatisfy { $0.category == "Logic" })
        #expect(space.searchNodes("zzzz").isEmpty)
    }

    @Test func describeNodeListsPortsAndProperties() throws {
        let space = AssistantWorkspace(editor: try arithmetic())
        let text = try #require(space.describeNode(type: "math.clamp"))
        #expect(text.contains("input min: number, default 0.0"))
        #expect(text.contains("output result: number"))
        let number = try #require(space.describeNode(type: "util.number"))
        #expect(number.contains("property value: number, default 0.0"))
        #expect(space.describeNode(type: "nope") == nil)
        #expect(try #require(space.describeNode(type: "math.sum")).contains("input ports in_1, in_2, ..."))
    }

    @Test func digestFollowsAliasesAndTheSelection() throws {
        let editor = try arithmetic()
        let sum = editor.graph.nodes.keys[2]
        let space = AssistantWorkspace(editor: editor, selection: [sum])
        let around = try space.digest(around: ["n3"], depth: 0)
        #expect(around.shownNodes == [sum])
        #expect(try space.digest(depth: 0).shownNodes == [sum])  // the selection, when no alias is given
        #expect(try AssistantWorkspace(editor: editor).digest().shownNodes.count == 5)
        #expect(throws: AssistantToolError.self) { try space.digest(around: ["n9"]) }
    }

    @Test func portReferencesExplainWhatWasValid() throws {
        let space = AssistantWorkspace(editor: try arithmetic())
        #expect(try space.port("n3.result").direction == .output)
        #expect(try space.port("n3.a").direction == .input)
        let error = #expect(throws: AssistantToolError.self) { try space.port("n3.nope") }
        #expect(error?.message.contains("Ports: a (input), b (input), result (output)") == true)
        #expect(throws: AssistantToolError.self) { try space.port("n3") }
        #expect(throws: AssistantToolError.self) { try space.port("n8.out") }
        #expect(throws: AssistantToolError.self) { try space.port("n3.result", direction: .input) }
    }

    @Test func valuesAndTracesUseAliases() async throws {
        let space = try await workspace(try arithmetic())
        #expect(try space.value(of: "n5.result") == .double(24))
        #expect(throws: AssistantToolError.self) { try space.value(of: "n5.a") }  // an input
        let trace = try space.traceUpstream("n5.result")
        #expect(trace.rendered(aliases: space.aliases).hasPrefix("n5.result = 24.0  math.multiply"))
        #expect(throws: AssistantToolError.self) { _ = try space.traceUpstream("n9.x") }
    }

    @Test func runAppliesVariableOverridesToACopy() async throws {
        let editor = try arithmetic()
        let space = AssistantWorkspace(editor: editor)
        let report = try await space.run()
        #expect(report.failures.isEmpty && report.values[editor.graph.nodes.keys[4], "result"] == .double(24))
        await #expect(throws: AssistantToolError.self) { try await space.run(variables: ["nope": 1.0]) }
        #expect(editor.graph.nodes.count == 5)  // nothing changed
    }

    @Test func findingsAndDiagnosticsReadWithAliases() throws {
        let editor = try arithmetic()
        try editor.apply(.addNode(node: Node(typeID: "math.add", position: GraphPoint(x: 900, y: 0))))
        let space = AssistantWorkspace(editor: editor)
        let text = space.render(space.lint())
        #expect(text == """
            [hint] n6: Add (math.add) is not linked to anything. (fix: Remove the node)
            [hint] n5: Nothing reads the outputs of Multiply (math.multiply).
            """)
        #expect(space.diagnostics().isEmpty)
    }
}

@Suite struct AssistantProposeToolTests {
    @Test func generationIsProposedNotApplied() async throws {
        let editor = try arithmetic()
        let space = AssistantWorkspace(editor: editor)
        let spec = GraphSpec(
            nodes: [N(alias: "c", type: "util.number", properties: ["value": .int(3)]), N(alias: "w", type: "util.watch")],
            links: [L(from: "c.value", to: "w.value")])
        let change = space.proposeGeneration(spec)
        #expect(editor.graph.nodes.count == 5)  // untouched
        #expect(change.steps == ["Add n6 util.number value=3.0", "Add n7 util.watch", "Link n6.value -> n7.value"])
        #expect(change.errors.isEmpty && change.canApply && change.addedNodes.count == 2)
        #expect(!change.isStale(for: editor))

        try change.apply(to: editor)
        #expect(editor.graph.nodes.count == 7 && editor.graph.links.count == 5)
        #expect(change.isStale(for: editor))
        let placed = try #require(editor.graph.nodes[change.addedNodes[0]])
        #expect(placed.position.x > 400)  // to the right of what was there
    }

    @Test func generationErrorsAndBadResultsAreReported() throws {
        let space = AssistantWorkspace(editor: try arithmetic())
        let change = space.proposeGeneration(GraphSpec(
            nodes: [N(alias: "a", type: "math.nope"), N(alias: "b", type: "math.add")]))
        #expect(change.errors.count == 1 && change.errors[0].contains("unknown node type"))
        #expect(change.steps == ["Add n6 math.add"])
        // The lone node is a new lint finding.
        #expect(change.introducedFindings.map(\.lint) == ["lint.isolatedNode"])

        let nothing = space.proposeGeneration(GraphSpec(nodes: [N(alias: "a", type: "math.nope")]))
        #expect(nothing.isEmpty && !nothing.canApply)
    }

    @Test func editsApplyInOrderAndReportWhatFailed() throws {
        let editor = try arithmetic()
        let space = AssistantWorkspace(editor: editor)
        let change = space.proposeEdit([
            .setProperty("n1", "value", .int(10)),
            .setProperty("n1", "colour", .int(1)),  // no such property
            .setProperty("n2", "value", .string("fast")),  // wrong kind
            .setTitle("n3", "Total"),
            .setMode("n5", .muted),
            .connect("n1.value", "n5.b"),  // replaces the link from n4
            .disconnect("n2.value", "n3.a"),  // no such link
            .removeNode("n4"),
        ])
        #expect(change.steps == [
            "Set n1.value = 10.0", "Rename n3 to \"Total\"", "Set n5 to muted",
            "Link n1.value -> n5.b (replaces the link from n4.value)", "Remove n4 (util.number) and 0 link(s)".replacingOccurrences(of: " and 0 link(s)", with: ""),
        ])
        #expect(change.errors.count == 3)
        #expect(change.errors[0].hasPrefix("Edit 2 (setProperty): n1 (util.number) has no property \"colour\". Properties: value."))
        #expect(change.errors[2].contains("no link from n2.value to n3.a") || change.errors[2].contains("There is no link"))

        try change.apply(to: editor)
        let ids = Array(editor.graph.nodes.keys)
        #expect(editor.graph.nodes.count == 4)
        #expect(editor.graph.nodes[ids[0]]?.properties["value"] == .double(10))
        #expect(editor.graph.nodes[ids[2]]?.title == "Total")
    }

    @Test func settingADefaultOrEmptyValueClearsTheOverride() throws {
        let editor = try arithmetic()
        let space = AssistantWorkspace(editor: editor)
        let change = space.proposeEdit([.setProperty("n1", "value", .int(0)), .setProperty("n2", "value", nil), .setTitle("n3", "")])
        #expect(change.errors.isEmpty)
        try change.apply(to: editor)
        let ids = Array(editor.graph.nodes.keys)
        #expect(editor.graph.nodes[ids[0]]?.properties.isEmpty == true && editor.graph.nodes[ids[1]]?.properties.isEmpty == true)
    }

    @Test func aBadEditIntroducesNoErrorsBecauseItIsLeftOut() throws {
        let space = AssistantWorkspace(editor: try arithmetic())
        let change = space.proposeEdit([.connect("n3.result", "n1.value")])  // an output into nothing
        #expect(change.isEmpty && change.errors.count == 1)
        #expect(change.errors[0].contains("has no input ports") && change.errors[0].contains("value (output)"))
        let misspelled = space.proposeEdit([.connect("n1.value", "n3.nope")])
        #expect(misspelled.errors.count == 1 && misspelled.errors[0].contains("has no port \"nope\""))
        let cycle = space.proposeEdit([.connect("n5.result", "n3.a")])  // closes a loop
        #expect(cycle.isEmpty && cycle.errors[0].contains("not allowed"))
    }

    @Test func lintFixesBecomeOneChangeThatResolvesTheFindings() throws {
        let editor = try arithmetic()
        for x in [900.0, 1000] { try editor.apply(.addNode(node: Node(typeID: "math.add", position: GraphPoint(x: x, y: 0)))) }
        let space = AssistantWorkspace(editor: editor)
        let findings = space.lint().filter { $0.lint == "lint.isolatedNode" }
        #expect(findings.count == 2)
        let change = try #require(space.proposeFix(findings[0]))
        #expect(change.steps == ["Remove the node: n6"] && change.resolvedFindings.count == 1)
        let both = space.proposeFixes(space.lint())
        #expect(both.title == "Apply 2 lint fixes" && both.resolvedFindings.count == 2 && both.introducedFindings.isEmpty)
        try both.apply(to: editor)
        #expect(editor.graph.nodes.count == 5)
        #expect(space.proposeFix(LintFinding(lint: "x", level: .hint, diagnostic: GraphDiagnostic(code: "x", message: "m"))) == nil)
    }

    @Test func aRunComparisonShowsWhatTheEditWouldChange() async throws {
        let editor = try arithmetic()
        let space = try await workspace(editor)
        let change = try await space.proposeEdit([.setProperty("n4", "value", .int(3))])
            .withRunComparison(in: space)
        let comparison = try #require(change.runComparison)
        #expect(comparison.changes.map(\.port) == ["value", "result"])
        #expect(comparison.changes.last?.before == .double(24) && comparison.changes.last?.after == .double(36))
        let text = change.rendered(in: space)
        #expect(text.contains("Running it:") && text.contains("n5.result: 24.0 -> 36.0"))
        #expect(text.hasPrefix("Edit nodes\n- Set n4.value = 3.0"))

        let same = try await space.proposeEdit([.setProperty("n4", "value", .int(2))]).withRunComparison(in: space)
        #expect(same.runComparison?.isUnchanged == true)
    }

    @Test func aRunComparisonSpotsNewFailures() async throws {
        let editor = try arithmetic()
        let space = try await workspace(editor)
        let spec = GraphSpec(
            nodes: [N(alias: "z", type: "util.number"), N(alias: "d", type: "math.divide")],
            links: [L(from: "z.value", to: "d.b")])  // divides by zero
        let change = try await space.proposeGeneration(spec).withRunComparison(in: space)
        let comparison = try #require(change.runComparison)
        #expect(comparison.newFailures.count == 1)
        #expect(change.rendered(in: space).contains("n7 now fails: Division by zero"))
    }
}
