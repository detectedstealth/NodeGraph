import Testing
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAssistant

private func emptyWorkspace() -> AssistantWorkspace {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    return AssistantWorkspace(editor: GraphEditor(nodes: nodes, types: types))
}

@Suite struct ProposeFromJSONTests {
    @Test func aSpecObjectIsProposedAsGeneration() throws {
        let change = try emptyWorkspace().propose(json: """
            { "nodes": [ { "alias": "a", "type": "util.number", "properties": { "value": 4 } },
                         { "alias": "b", "type": "math.add" } ],
              "links": [ { "from": "a.value", "to": "b.a" } ] }
            """)
        #expect(change.canApply)
        #expect(change.addedNodes.count == 2)
    }

    @Test func anArrayOrAnOperationsObjectIsProposedAsEdit() throws {
        let space = emptyWorkspace()
        let generated = try space.propose(json: #"{ "nodes": [ { "alias": "a", "type": "util.number" } ] }"#)
        let editor = GraphEditor(nodes: space.nodes, types: space.types)
        try generated.apply(to: editor)
        let filled = AssistantWorkspace(editor: editor)
        let array = try filled.propose(json: #"[ { "op": "setTitle", "node": "n1", "value": "Four" } ]"#)
        let object = try filled.propose(json: #"{ "operations": [ { "op": "setTitle", "node": "n1", "value": "Four" } ] }"#)
        #expect(array.steps.count == 1 && array.canApply)
        #expect(object.steps == array.steps)
        #expect(array.resultGraph.nodes.values.first?.title == "Four")
    }

    @Test func curlyQuotesFromASmartTextBoxAreAccepted() throws {
        let space = emptyWorkspace()
        let generated = try space.propose(json: #"{ "nodes": [ { "alias": "a", "type": "util.number" } ] }"#)
        let editor = GraphEditor(nodes: space.nodes, types: space.types)
        try generated.apply(to: editor)
        let curly = "[{\u{201C}op\u{201D}:\u{201C}setMode\u{201D},\u{201C}node\u{201D}:\u{201C}n1\u{201D},\u{201C}value\u{201D}:\u{201C}muted\u{201D}}]"
        let change = try AssistantWorkspace(editor: editor).propose(json: curly)
        #expect(change.canApply)
        #expect(change.resultGraph.nodes.values.first?.mode == .muted)
    }

    @Test func badTextThrowsAndBadContentComesBackAsErrors() throws {
        let space = emptyWorkspace()
        #expect(throws: AssistantToolError.self) { try space.propose(json: "  ") }
        #expect(throws: AssistantToolError.self) { try space.propose(json: "{ nodes: ") }
        #expect(throws: AssistantToolError.self) { try space.propose(json: #"{ "hello": 1 }"#) }
        let unknown = try space.propose(json: #"{ "nodes": [ { "alias": "a", "type": "no.such.type" } ] }"#)
        #expect(!unknown.errors.isEmpty)
        #expect(!unknown.canApply)
    }
}

@Suite struct SelectedOutputTests {
    @Test func listsTheOutputsOfSelectedNodesByAlias() throws {
        let space = emptyWorkspace()
        let change = try space.propose(json: """
            { "nodes": [ { "alias": "a", "type": "util.number" }, { "alias": "b", "type": "math.add" } ] }
            """)
        let editor = GraphEditor(nodes: space.nodes, types: space.types)
        try change.apply(to: editor)
        let ids = Set(editor.graph.nodes.keys)
        let filled = AssistantWorkspace(editor: editor, selection: ids)
        #expect(filled.selectedOutputReferences() == ["n1.value", "n2.result"])
        #expect(AssistantWorkspace(editor: editor).selectedOutputReferences().isEmpty)
    }
}
