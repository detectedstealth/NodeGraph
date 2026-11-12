import Testing
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAssistant

private func rig(_ spec: GraphSpec) async throws -> (editor: GraphEditor, values: RunValues, ids: [String: NodeID]) {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    let compiler = GraphSpecCompiler(nodes: nodes, types: types)
    let result = compiler.compile(spec)
    #expect(result.isClean)
    let editor = GraphEditor(nodes: nodes, types: types)
    try editor.apply(try result.pasteCommand(into: editor).command)
    // Pasting gives new ids, so find the nodes again by their order.
    let order = Array(editor.graph.nodes.keys)
    var ids: [String: NodeID] = [:]
    for (index, node) in spec.nodes.enumerated() { ids[node.alias] = order[index] }
    var values = RunValues()
    values.apply(await (try GraphRunner(graph: editor.graph, registry: nodes)).step())
    return (editor, values, ids)
}

private typealias N = GraphSpec.NodeSpec
private typealias L = GraphSpec.LinkSpec

@Suite struct ValueTraceTests {
    /// (4 + 8) * 2, with a muted-free chain: n1=4, n2=8, add, then multiply by a constant 2.
    private func arithmetic() async throws -> (editor: GraphEditor, values: RunValues, ids: [String: NodeID]) {
        try await rig(GraphSpec(
            nodes: [
                N(alias: "four", type: "util.number", properties: ["value": .int(4)]),
                N(alias: "eight", type: "util.number", properties: ["value": .int(8)]),
                N(alias: "sum", type: "math.add"),
                N(alias: "two", type: "util.number", properties: ["value": .int(2)]),
                N(alias: "product", type: "math.multiply", title: "Total"),
            ],
            links: [
                L(from: "four.value", to: "sum.a"), L(from: "eight.value", to: "sum.b"),
                L(from: "sum.result", to: "product.a"), L(from: "two.value", to: "product.b"),
            ]))
    }

    @Test func tracesAnOutputBackThroughItsInputs() async throws {
        let (editor, values, ids) = try await arithmetic()
        let tracer = ValueTracer(graph: editor.graph, registry: editor.nodes, values: values)
        let trace = try #require(tracer.trace(PortAddress(node: ids["product"]!, port: "result", direction: .output)))
        #expect(trace.root.value == .double(24))
        #expect(trace.root.title == "Total")
        #expect(trace.root.inputs.map(\.port) == ["a", "b"])
        guard case .linked(let sum) = trace.root.inputs[0].origin else { Issue.record("a should be linked"); return }
        #expect(sum.value == .double(12) && sum.inputs.count == 2)
        #expect(!trace.isTruncated)

        let digest = GraphDigest(graph: editor.graph, registry: editor.nodes)
        #expect(trace.rendered(aliases: digest) == """
            n5.result = 24.0  math.multiply "Total"
              a <- n3.result = 12.0  math.add
                a <- n1.value = 4.0  util.number value=4.0
                b <- n2.value = 8.0  util.number value=8.0
              b <- n4.value = 2.0  util.number value=2.0
            """)
    }

    @Test func tracingAnInputStartsAtTheOutputThatFeedsIt() async throws {
        let (editor, values, ids) = try await arithmetic()
        let tracer = ValueTracer(graph: editor.graph, registry: editor.nodes, values: values)
        let trace = try #require(tracer.trace(PortAddress(node: ids["product"]!, port: "a", direction: .input)))
        #expect(trace.root.node == ids["sum"] && trace.root.value == .double(12))
        // Nothing feeds an unlinked input.
        #expect(tracer.trace(PortAddress(node: ids["sum"]!, port: "zzz", direction: .input)) == nil)
        #expect(tracer.trace(PortAddress(node: NodeID(), port: "result", direction: .output)) == nil)
    }

    @Test func showsDefaultsForUnlinkedInputs() async throws {
        let (editor, values, ids) = try await rig(GraphSpec(
            nodes: [N(alias: "n", type: "util.number", properties: ["value": .int(5)]), N(alias: "add", type: "math.add")],
            links: [L(from: "n.value", to: "add.a")]))
        let tracer = ValueTracer(graph: editor.graph, registry: editor.nodes, values: values)
        let trace = try #require(tracer.trace(PortAddress(node: ids["add"]!, port: "result", direction: .output)))
        #expect(trace.root.inputs[1].origin == .unlinked(defaultValue: .double(0)))
        let text = trace.rendered(aliases: GraphDigest(graph: editor.graph, registry: editor.nodes))
        #expect(text.contains("b <- default 0.0"))
    }

    @Test func limitsCutTheTraceAndSayHow() async throws {
        let (editor, values, ids) = try await arithmetic()
        let tracer = ValueTracer(graph: editor.graph, registry: editor.nodes, values: values)
        let start = PortAddress(node: ids["product"]!, port: "result", direction: .output)
        let shallow = try #require(tracer.trace(start, maxDepth: 1))
        #expect(shallow.isTruncated)
        guard case .linked(let sum) = shallow.root.inputs[0].origin,
              case .cutOff(_, _, let value) = sum.inputs[0].origin else { Issue.record("expected a cut-off input"); return }
        #expect(value == .double(4))
        let text = shallow.rendered(aliases: GraphDigest(graph: editor.graph, registry: editor.nodes))
        #expect(text.contains("(not expanded)") && text.hasSuffix("(trace cut off; ask for a deeper trace from a node above)"))

        let small = try #require(tracer.trace(start, maxNodes: 2))
        #expect(small.isTruncated)
    }

    @Test func explainsAMissingValue() async throws {
        var spec = GraphSpec(
            nodes: [
                N(alias: "n", type: "util.number", properties: ["value": .int(5)], mode: .muted),
                N(alias: "add", type: "math.add"),
            ],
            links: [L(from: "n.value", to: "add.a")])
        spec.nodes[1].mode = .never
        let (editor, values, ids) = try await rig(spec)
        let tracer = ValueTracer(graph: editor.graph, registry: editor.nodes, values: values)
        let trace = try #require(tracer.trace(PortAddress(node: ids["add"]!, port: "result", direction: .output)))
        #expect(trace.root.value == nil)
        #expect(trace.root.note == "disabled: did not run")
        guard case .linked(let muted) = trace.root.inputs[0].origin else { Issue.record("a should be linked"); return }
        #expect(muted.note == "muted: publishes nothing" && muted.value == nil)
        let text = trace.rendered(aliases: GraphDigest(graph: editor.graph, registry: editor.nodes))
        #expect(text.contains("n2.result = no value") && text.contains("[disabled: did not run]"))
    }

    @Test func sayWhyAFailedNodeHasNoValueAndWhichNodesWereSkippedBecauseOfIt() async throws {
        // 1 / 0 fails; the add after it is skipped because of that.
        let (editor, values, ids) = try await rig(GraphSpec(
            nodes: [
                N(alias: "one", type: "util.number", properties: ["value": .int(1)]),
                N(alias: "zero", type: "util.number"),
                N(alias: "ratio", type: "math.divide"),
                N(alias: "after", type: "math.add"),
            ],
            links: [
                L(from: "one.value", to: "ratio.a"), L(from: "zero.value", to: "ratio.b"),
                L(from: "ratio.result", to: "after.a"),
            ]))
        let space = AssistantWorkspace(editor: editor, runValues: values)
        let failed = try space.traceUpstream("n3.result").rendered(aliases: space.aliases)
        #expect(failed.contains("n3.result = no value"))
        #expect(failed.contains("FAILED in the last run: Division by zero"))
        let skipped = try space.traceUpstream("n4.result").rendered(aliases: space.aliases)
        #expect(skipped.contains("skipped in the last run because a node feeding it failed"))
        // The failing node still shows up above the skipped one, with its reason.
        #expect(skipped.contains("FAILED in the last run: Division by zero"))
        _ = ids

        // The summary states it outright, with each input and where it came from.
        let summary = try space.traceUpstream("n3.result").summary(aliases: space.aliases)
        #expect(summary.contains("n3 (math.divide) failed in the last run: Division by zero."))
        #expect(summary.contains("a = 1.0 from n1.value (util.number)"))
        #expect(summary.contains("b = 0.0 from n2.value (util.number)"))
        let skippedSummary = try space.traceUpstream("n4.result").summary(aliases: space.aliases)
        #expect(skippedSummary.contains("skipped because n3 (math.divide) failed: Division by zero."))
    }

    @Test func summarisesAValueAndNamesDefaultsAndTitles() async throws {
        let (editor, values, _) = try await arithmetic()
        let space = AssistantWorkspace(editor: editor, runValues: values)
        let summary = try space.traceUpstream("n5.result").summary(aliases: space.aliases)
        #expect(summary.hasPrefix("n5.result = 24.0, made by n5 \"Total\" (math.multiply)."))
        #expect(summary.contains("a = 12.0 from n3.result (math.add)"))
        #expect(summary.contains("b = 2.0 from n4.value (util.number)"))
        // An input with no link says it is the default.
        let single = try await rig(GraphSpec(nodes: [N(alias: "add", type: "math.add")], links: []))
        let lone = AssistantWorkspace(editor: single.editor, runValues: single.values)
        #expect(try lone.traceUpstream("n1.result").summary(aliases: lone.aliases).contains("a = 0.0 (not linked: the default)"))
    }
}
