import Foundation
import Testing
import NodeGraphCore
@testable import NodeGraphAssistant

private let number = PortType("number")
private let text = PortType("string")

private func makeCompiler() -> GraphSpecCompiler {
    var types = TypeRegistry()
    types.register(PortTypeInfo(type: number, displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 0)))
    types.register(PortTypeInfo(type: text, displayName: "Text", color: RGBAColor(red: 1, green: 1, blue: 1)))
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "math.add", displayName: "Add",
        ports: [
            PortDefinition(id: "a", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "b", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "out", direction: .output, type: number),
        ]))
    nodes.register(NodeDefinition(
        typeID: "math.const", displayName: "Const",
        ports: [PortDefinition(id: "out", direction: .output, type: number)],
        properties: [
            PropertyDefinition(id: "value", displayName: "Value", kind: .double(), defaultValue: 0.0),
            PropertyDefinition(id: "steps", displayName: "Steps", kind: .int(min: 0, max: 10), defaultValue: 1),
        ]))
    nodes.register(NodeDefinition(
        typeID: "text.const", displayName: "Text",
        ports: [PortDefinition(id: "out", direction: .output, type: text)]))
    nodes.register(NodeDefinition(
        typeID: "math.sum", displayName: "Sum",
        ports: [PortDefinition(id: "out", direction: .output, type: number)],
        dynamicPorts: [DynamicPortGroup(id: "in", direction: .input, type: number, minimum: 1, maximum: 4, initialCount: 2)]))
    return GraphSpecCompiler(nodes: nodes, types: types)
}

private typealias N = GraphSpec.NodeSpec
private typealias L = GraphSpec.LinkSpec

@Suite struct GraphSpecCompilerTests {
    @Test func compilesNodesPropertiesAndLinks() throws {
        let spec = GraphSpec(
            nodes: [N(alias: "a", type: "math.const", properties: ["value": .int(4)]), N(alias: "s", type: "math.add", title: "Sum")],
            links: [L(from: "a.out", to: "s.a")])
        let result = makeCompiler().compile(spec)
        #expect(result.isClean)
        #expect(result.fragment.nodes.count == 2 && result.fragment.links.count == 1)
        let a = try #require(result.aliases["a"].flatMap { id in result.fragment.nodes.first { $0.id == id } })
        #expect(a.properties["value"] == .double(4))  // whole number accepted for a double property
        let s = try #require(result.aliases["s"].flatMap { id in result.fragment.nodes.first { $0.id == id } })
        #expect(s.title == "Sum")
        #expect(a.position.x < s.position.x)  // laid out left to right
    }

    @Test func defaultValuedPropertiesAreNotStored() {
        let spec = GraphSpec(nodes: [N(alias: "a", type: "math.const", properties: ["value": .int(0), "steps": .double(1.0)])])
        let node = makeCompiler().compile(spec).fragment.nodes[0]
        #expect(node.properties.isEmpty)
    }

    @Test func aCleanCompilationPastesIntoAnEditor() throws {
        let compiler = makeCompiler()
        let result = compiler.compile(GraphSpec(
            nodes: [N(alias: "a", type: "math.const"), N(alias: "s", type: "math.add")],
            links: [L(from: "a.out", to: "s.b")],
            groups: [.init(title: "Pair", members: ["a", "s"])]))
        #expect(result.isClean && result.fragment.groups.count == 1)
        let editor = GraphEditor(nodes: compiler.nodes, types: compiler.types)
        let paste = try result.pasteCommand(into: editor, at: GraphPoint(x: 100, y: 50))
        try editor.apply(paste.command)
        #expect(editor.graph.nodes.count == 2 && editor.graph.links.count == 1 && editor.graph.groups.count == 1)
        let group = try #require(editor.graph.groups.values.first)
        let members = editor.graph.members(of: group, frame: editor.nodes.frame(of:))
        #expect(members.count == 2)
    }

    @Test func layersFollowTheLongestPath() throws {
        let result = makeCompiler().compile(GraphSpec(
            nodes: [N(alias: "a", type: "math.const"), N(alias: "b", type: "math.add"), N(alias: "c", type: "math.add")],
            links: [L(from: "a.out", to: "b.a"), L(from: "b.out", to: "c.a"), L(from: "a.out", to: "c.b")]))
        let x = { (alias: String) in result.fragment.nodes.first { $0.id == result.aliases[alias] }!.position.x }
        #expect(x("a") < x("b") && x("b") < x("c"))
    }

    // MARK: Errors a model can repair from

    @Test func unknownNodeTypeSuggestsSimilarOnes() {
        let result = makeCompiler().compile(GraphSpec(nodes: [N(alias: "x", type: "math.addition")]))
        #expect(result.errors.count == 1)
        #expect(result.errors[0].kind == .unknownNodeType)
        #expect(result.errors[0].message.contains("x: unknown node type \"math.addition\""))
        #expect(result.fragment.nodes.isEmpty)
        let near = makeCompiler().compile(GraphSpec(nodes: [N(alias: "x", type: "add")]))
        #expect(near.errors[0].message.contains("Similar: math.add"))
    }

    @Test func badPropertiesAreReportedAndTheNodeIsKept() {
        let result = makeCompiler().compile(GraphSpec(nodes: [
            N(alias: "a", type: "math.const", properties: ["speed": .int(1), "steps": .int(99), "value": .string("fast")]),
        ]))
        #expect(result.fragment.nodes.count == 1 && result.fragment.nodes[0].properties.isEmpty)
        let kinds = result.errors.map(\.kind)
        #expect(kinds.filter { $0 == .unknownProperty }.count == 1)
        #expect(kinds.filter { $0 == .invalidProperty }.count == 2)
        #expect(result.errors.first { $0.kind == .unknownProperty }!.message.contains("Properties: value, steps."))
    }

    @Test func aliasProblems() {
        let result = makeCompiler().compile(GraphSpec(nodes: [
            N(alias: "a", type: "math.add"), N(alias: "a", type: "math.add"), N(alias: "b.c", type: "math.add"),
            N(alias: "", type: "math.add"),
        ]))
        #expect(result.errors.map(\.kind) == [.duplicateAlias, .invalidAlias, .invalidAlias])
        #expect(result.fragment.nodes.count == 1)
    }

    @Test func linkEndpointProblemsNameWhatWasValid() {
        let spec = GraphSpec(
            nodes: [N(alias: "a", type: "math.const"), N(alias: "s", type: "math.add")],
            links: [
                L(from: "a.out", to: "s.c"),  // no such port
                L(from: "a", to: "s.a"),  // malformed
                L(from: "zz.out", to: "s.a"),  // no such alias
                L(from: "s.a", to: "a.out"),  // ends swapped
            ])
        let result = makeCompiler().compile(spec)
        #expect(result.fragment.links.isEmpty)
        #expect(result.errors.map(\.kind) == [.unknownPort, .malformedEndpoint, .unknownAlias, .unknownPort])
        #expect(result.errors[0].message.contains("Input ports: a, b."))
        #expect(result.errors[3].message.contains("is an input; links go from an output to an input"))
    }

    @Test func theConnectionRulesApply() {
        let spec = GraphSpec(
            nodes: [
                N(alias: "a", type: "math.const"), N(alias: "b", type: "math.const"), N(alias: "t", type: "text.const"),
                N(alias: "s", type: "math.add"), N(alias: "u", type: "math.add"),
            ],
            links: [
                L(from: "a.out", to: "s.a"),
                L(from: "b.out", to: "s.a"),  // the input already has a link
                L(from: "t.out", to: "s.b"),  // string into number
                L(from: "s.out", to: "u.a"),
                L(from: "u.out", to: "s.b"),  // closes a loop
            ])
        let result = makeCompiler().compile(spec)
        #expect(result.errors.count == 3 && result.errors.allSatisfy { $0.kind == .linkRejected })
        #expect(result.errors[0].message.contains("already has a link"))
        #expect(result.fragment.links.count == 2)
    }

    @Test func linksToSkippedNodesAddNoSecondError() {
        let result = makeCompiler().compile(GraphSpec(
            nodes: [N(alias: "a", type: "math.const"), N(alias: "x", type: "nope")],
            links: [L(from: "a.out", to: "x.a")]))
        #expect(result.errors.map(\.kind) == [.unknownNodeType])
    }

    // MARK: Dynamic ports and groups

    @Test func portCountsOpenDynamicPortsAndAreClamped() throws {
        let result = makeCompiler().compile(GraphSpec(
            nodes: [N(alias: "c", type: "math.const"), N(alias: "s", type: "math.sum", portCounts: ["in": 3])],
            links: [L(from: "c.out", to: "s.in_3")]))
        #expect(result.isClean && result.fragment.links.count == 1)

        let tooMany = makeCompiler().compile(GraphSpec(nodes: [N(alias: "s", type: "math.sum", portCounts: ["in": 9, "out": 1])]))
        #expect(tooMany.errors.map(\.kind) == [.unknownPortGroup, .unknownPortGroup])
        #expect(tooMany.errors[0].message.contains("takes 1...4 ports, not 9"))
        #expect(tooMany.fragment.nodes[0].portCounts["in"] == 4)
    }

    @Test func groupMembersMustExist() {
        let result = makeCompiler().compile(GraphSpec(
            nodes: [N(alias: "a", type: "math.const")],
            groups: [.init(title: "G", members: ["a", "ghost"]), .init(title: "Empty", members: [])]))
        #expect(result.errors.map(\.kind) == [.unknownAlias, .emptyGroup])
        #expect(result.fragment.groups.count == 1)
    }

    // MARK: JSON

    @Test func decodesJSONWithOptionalPartsLeftOut() throws {
        let json = #"""
            { "nodes": [ { "alias": "a", "type": "math.const", "properties": { "value": 2.5 } } ] }
            """#
        let spec = try GraphSpec.decode(from: Data(json.utf8))
        #expect(spec.links.isEmpty && spec.groups.isEmpty)
        #expect(spec.nodes[0].properties["value"] == .double(2.5))
        #expect(try GraphSpec.decode(from: spec.encoded()) == spec)
        let result = makeCompiler().compile(spec)
        #expect(result.isClean)
    }

    @Test func wholeNumbersFromJSONAreAcceptedForDoubleProperties() throws {
        let json = #"{ "nodes": [ { "alias": "a", "type": "math.const", "properties": { "value": 4, "steps": 3.0 } } ] }"#
        let result = makeCompiler().compile(try GraphSpec.decode(from: Data(json.utf8)))
        #expect(result.isClean)
        #expect(result.fragment.nodes[0].properties["value"] == .double(4))
        #expect(result.fragment.nodes[0].properties["steps"] == .int(3))
    }
}
