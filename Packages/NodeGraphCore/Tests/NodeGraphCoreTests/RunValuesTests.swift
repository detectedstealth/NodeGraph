import Foundation
import Testing
@testable import NodeGraphCore

private struct Rig {
    var registry = NodeRegistry()
    var graph = Graph()

    init() {
        registry.register(NodeDefinition(
            typeID: "const", displayName: "Const",
            ports: [PortDefinition(id: "out", direction: .output)],
            properties: [
                PropertyDefinition(id: "value", displayName: "Value", kind: .double(), defaultValue: 0.0),
                PropertyDefinition(id: "fail", displayName: "Fail", kind: .bool, defaultValue: false),
            ])
        ) { ctx in
            if try ctx.property("fail").boolValue == true { throw NodeExecutionError.failed("boom") }
            return ["out": try ctx.property("value")]
        }
    }

    mutating func add(_ properties: [PropertyID: GraphValue] = [:], mode: NodeMode = .always) -> NodeID {
        let node = Node(typeID: "const", mode: mode, properties: properties)
        graph.insert(node)
        return node.id
    }
}

@Suite struct RunValuesTests {
    @Test func holdsWhatEachNodePublishedAndWhatEachLinkCarries() async throws {
        var rig = Rig()
        let a = rig.add(["value": 3.0])
        let b = rig.add(["value": 4.0])
        let link = Link(sourceNode: a, sourcePort: "out", targetNode: b, targetPort: "in")
        let tick = await (try GraphRunner(graph: rig.graph, registry: rig.registry)).step()

        var values = RunValues()
        #expect(values[a, "out"] == nil)
        values.apply(tick)
        #expect(values[a, "out"] == .double(3))
        #expect(values[b] == ["out": .double(4)])
        #expect(values.value(of: link) == .double(3))
        #expect(values.tick == 0)
    }

    @Test func aNodeLosesItsValuesWhenItNoLongerHasCurrentOnes() async throws {
        var rig = Rig()
        let id = rig.add(["value": 3.0])
        let changes = [
            Node(id: id, typeID: "const", properties: ["fail": true]),
            Node(id: id, typeID: "const", mode: .muted, properties: ["value": 3.0]),
            Node(id: id, typeID: "const", mode: .never, properties: ["value": 3.0]),
        ]
        for change in changes {
            let runner = try GraphRunner(graph: rig.graph, registry: rig.registry)
            var values = RunValues()
            values.apply(await runner.step())
            #expect(values[id, "out"] == .double(3))

            var next = rig.graph
            next.insert(change)
            try await runner.update(graph: next, registry: rig.registry)
            values.apply(await runner.step())
            #expect(values[id].isEmpty, "\(change.mode) fail=\(String(describing: change.properties["fail"]))")
        }
    }

    @Test func aNodeThatDidNotFireKeepsItsLastValues() async throws {
        var rig = Rig()
        let id = rig.add(["value": 3.0])
        let runner = try GraphRunner(graph: rig.graph, registry: rig.registry)
        var values = RunValues()
        values.apply(await runner.step())

        var next = rig.graph
        next.insert(Node(id: id, typeID: "const", mode: .onTrigger, properties: ["value": 3.0]))
        try await runner.update(graph: next, registry: rig.registry)
        let tick = await runner.step()
        #expect(tick.results[id]?.outcome == .skipped(.notTriggered))
        values.apply(tick)
        #expect(values[id, "out"] == .double(3))
    }

    @Test func pruneForgetsDeletedNodes() async throws {
        var rig = Rig()
        let a = rig.add(["value": 1.0]), b = rig.add(["value": 2.0])
        var values = RunValues()
        values.apply(await (try GraphRunner(graph: rig.graph, registry: rig.registry)).step())
        values.prune(keeping: [a])
        #expect(values[a, "out"] == .double(1))
        #expect(values[b].isEmpty)
    }
}

@Suite struct GraphValueSummaryTests {
    @Test func scalarsAndText() {
        #expect(GraphValue.null.summary() == "null")
        #expect(GraphValue.bool(true).summary() == "true")
        #expect(GraphValue.int(-4).summary() == "-4")
        #expect(GraphValue.double(0.5).summary() == "0.5")
        #expect(GraphValue.double(3).summary() == "3.0")
        #expect(GraphValue.string("a\nb").summary() == "a⏎b")
        #expect(GraphValue.color(RGBAColor(red: 1, green: 0.5, blue: 0)).summary() == "#FF8000")
        #expect(GraphValue.color(RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)).summary() == "#00000000")
    }

    @Test func collectionsQuoteStringsAndSortFields() {
        #expect(GraphValue.vector([1, 2]).summary() == "(1.0, 2.0)")
        #expect(GraphValue.array([.int(1), .string("a, b")]).summary() == "[1, \"a, b\"]")
        #expect(GraphValue.object(["b": .int(2), "a": .bool(false)]).summary() == "{a: false, b: 2}")
        #expect(GraphValue.matrix(GraphMatrix(rows: 2, columns: 3, elements: Array(repeating: 0, count: 6))).summary() == "2×3 matrix")
        #expect(GraphValue.data(Data([1, 2, 3])).summary() == "3 bytes")
    }

    @Test func longTextIsCutAndDeepNestingIsElided() {
        let long = GraphValue.string(String(repeating: "x", count: 100))
        #expect(long.summary(limit: 10) == "xxxxxxxxx…")
        #expect(long.summary(limit: 0).count == 100)
        let deep = GraphValue.array([.array([.array([.array([.array([.int(1)])])])])])
        #expect(deep.summary() == "[[[[…]]]]")
    }
}
