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

@Suite struct UnknownKeyTests {
    private func message(_ json: String) -> String? {
        do { _ = try emptyWorkspace().propose(json: json); return nil } catch { return "\(error)" }
    }

    @Test func aKeyFromAnotherKindOfEditIsNamedWithTheOnesItTakes() {
        let text = message(#"[ { "op": "setMode", "node": "n1", "to": "always" } ]"#)
        #expect(text?.contains(#"Edit 1 (setMode) does not use "to""#) == true)
        #expect(text?.contains(#"It takes "node", "value""#) == true)
    }

    @Test func everyBadEditIsReportedAtOnceAndOperationsObjectsAreChecked() {
        let text = message(#"{ "operations": [ { "op": "removeNode", "node": "n1", "id": 3 }, { "op": "connect", "from": "n1.out", "too": "n2.a" } ] }"#)
        #expect(text?.contains("Edit 1 (removeNode)") == true)
        #expect(text?.contains("Edit 2 (connect)") == true)
    }

    @Test func specKeysAreCheckedAtEveryLevel() {
        #expect(message(#"{ "nodes": [ { "alias": "a", "typ": "math.add" } ] }"#)?.contains(#"node 1 does not use "typ""#) == true)
        #expect(message(#"{ "nodes": [], "links": [ { "from": "a.out", "into": "b.a" } ] }"#)?.contains(#"link 1 does not use "into""#) == true)
        #expect(message(#"{ "nodes": [], "linkz": [] }"#)?.contains(#"does not use "linkz""#) == true)
    }

    @Test func validInputsStillPass() {
        #expect(message(#"[ { "op": "setMode", "node": "n1", "value": "muted" } ]"#)?.contains("does not use") != true)
        #expect(message(#"{ "nodes": [ { "alias": "a", "type": "util.number", "properties": { "value": 1 }, "mode": "muted" } ] }"#) == nil)
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
