import Foundation
import FoundationModels
import Synchronization
import Testing
import NodeGraphAssistant
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAI

/// Answers each stage from a script and records what it was asked.
private final class Scripted: StructuredGenerator {
    struct Call: Sendable { var stage: GenerationStage; var prompt: String }
    private let calls = Mutex<[Call]>([])
    private let answer: @Sendable (GenerationStage) -> String

    init(_ answer: @escaping @Sendable (GenerationStage) -> String) { self.answer = answer }

    var recorded: [Call] { calls.withLock { $0 } }

    func generate(stage: GenerationStage, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        calls.withLock { $0.append(Call(stage: stage, prompt: prompt)) }
        return try GeneratedContent(json: answer(stage))
    }
}

private func emptyWorkspace() -> AssistantWorkspace {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    return AssistantWorkspace(editor: GraphEditor(nodes: nodes, types: types))
}

@Suite struct GraphGeneratorTests {
    private func source(_ name: String) -> String { "\"\(name)\"" }

    @Test func buildsAGraphInStagesAndProposesItWithoutApplyingIt() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "util.number", "math.add"]"#
            case .setProperties(let alias): alias == "number1" ? #"{"value": 4}"# : #"{"value": 8}"#
            case .chooseSource(let input): input == "add1.a" ? "\"number1.value\"" : "\"number2.value\""
                default: "{}"
            }
        }
        let space = emptyWorkspace()
        let outcome = try await GraphGenerator(workspace: space, generator: script).generate("add four and eight")

        #expect(outcome.spec.nodes.map(\.alias) == ["number1", "number2", "add1"])
        #expect(outcome.spec.nodes[0].properties["value"] == .int(4))
        #expect(outcome.spec.links.map(GraphGenerator.text(of:)) == ["number1.value -> add1.a", "number2.value -> add1.b"])
        #expect(outcome.change.errors.isEmpty)
        #expect(outcome.change.canApply)
        #expect(outcome.change.addedNodes.count == 3)
        #expect(space.graph.nodes.isEmpty)  // proposed, never applied
        // One request per node with settings, then one per input that something could feed.
        #expect(script.recorded.map(\.stage) == [
            .pickNodes, .setProperties(alias: "number1"), .setProperties(alias: "number2"),
            .chooseSource(input: "add1.a"), .chooseSource(input: "add1.b"),
        ])
    }

    @Test func eachInputIsAskedWithTheLinksChosenSoFarAndMayBeLeftUnlinked() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "util.number", "math.add"]"#
            case .setProperties: "{}"
            case .chooseSource(let input): input == "add1.a" ? "\"number1.value\"" : "\"none\""
                default: "{}"
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("add")
        #expect(outcome.spec.links.map(GraphGenerator.text(of:)) == ["number1.value -> add1.a"])
        let second = try #require(script.recorded.last)
        #expect(second.prompt.contains("Links so far: number1.value -> add1.a"))
        #expect(second.prompt.contains("Which output should feed add1.b?"))
    }

    @Test func anAnswerThatWasNotOfferedIsIgnored() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "math.add"]"#
            case .setProperties: "{}"
            case .chooseSource: "\"ghost.out\""
                default: "{}"
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("add")
        #expect(outcome.spec.links.isEmpty)
        #expect(outcome.change.errors.isEmpty)
    }

    @Test func aLinkThatWouldMakeACycleIsNeverOffered() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "math.add", "math.add"]"#
            case .setProperties: "{}"
            case .chooseSource(let input):
                switch input {
                case "add1.a": "\"number1.value\""
                case "add2.a": "\"add1.result\""
                // add2 now depends on add1, so feeding add1 from add2 would loop: not offered, so ignored.
                case "add1.b": "\"add2.result\""
                default: "\"none\""
                }
            default: "{}"
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("add")
        #expect(outcome.spec.links.map(GraphGenerator.text(of:)) == ["number1.value -> add1.a", "add1.result -> add2.a"])
        #expect(outcome.change.errors.isEmpty)
    }

    @Test func anOutputIsOfferedOnlyOnceItsNodeMeansSomething() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["math.add", "util.number", "math.add"]"#
            case .setProperties: "{}"
            default: "\"none\""
            }
        }
        _ = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("add")
        // Nothing feeds either Add yet, so only the number is offered as a source, never an Add output.
        for call in script.recorded {
            guard case .chooseSource = call.stage else { continue }
            #expect(!call.prompt.contains("add1.result ->"))
        }
        let offered = Set(script.recorded.compactMap { call -> String? in
            if case .chooseSource(let input) = call.stage { input } else { nil }
        })
        #expect(offered.contains("add1.a"))
    }

    @Test func textIsKeptOnlyIfTheRequestSaysIt() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.string", "util.string"]"#
            case .setProperties(let alias): alias == "string1" ? #"{"value": "Hello"}"# : #"{"value": "Task: say hello. Set the properties"}"#
            case .chooseSource: "\"none\""
                default: "{}"
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("say hello")
        #expect(outcome.spec.nodes[0].properties == ["value": .string("Hello")])
        #expect(outcome.spec.nodes[1].properties.isEmpty)
        #expect(outcome.notes.contains { $0.contains("string2") && $0.contains("is not in the request") })
    }

    @Test func nothingOutsideTheOfferedChoicesGetsThrough() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "made.up", "math.add"]"#
            case .setProperties: #"{"value": 3, "bogus": 1, "gain": null}"#
            case .chooseSource: "\"number1.value\""
                default: "{}"
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("add")

        #expect(outcome.spec.nodes.map(\.alias) == ["number1", "add1"])
        #expect(outcome.notes.contains { $0.contains("made.up") })
        #expect(outcome.spec.nodes[0].properties == ["value": .int(3)])
    }

    @Test func aModelThatPicksNoRealNodeTypeFailsClearly() async throws {
        let script = Scripted { _ in #"["made.up"]"# }
        await #expect(throws: GenerationError.noNodes) {
            try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("x")
        }
    }

    @Test func aGraphWithNothingToLinkSkipsTheLinkStage() async throws {
        let script = Scripted { stage in
            if case .pickNodes = stage { return #"["util.number"]"# }
            return "{}"
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("one number")
        #expect(!script.recorded.contains { if case .chooseSource = $0.stage { true } else { false } })
        #expect(outcome.spec.links.isEmpty)
    }

    @Test func workedExamplesAreShownOnlyIfTheirTypesExistAndAtMostTwo() async throws {
        let big = GenerationExample(
            task: "double a number", types: ["util.number", "math.multiply"], explanation: "a number and the multiply node")
        let small = GenerationExample(task: "make a number", types: ["util.number"], explanation: "just the number node")
        let third = GenerationExample(task: "third task", types: ["util.bool"])
        let unusable = GenerationExample(task: "other", types: ["made.up"])
        let cases: [([GenerationExample], [String])] = [
            ([unusable, big, small, third], ["double a number", "make a number"]),
            ([unusable], []),
            ([], []),
        ]
        for (examples, shown) in cases {
            let script = Scripted { stage in
                if case .pickNodes = stage { return #"["util.number"]"# }
                return "{}"
            }
            _ = try await GraphGenerator(workspace: emptyWorkspace(), generator: script, examples: examples).generate("x")
            let prompt = try #require(script.recorded.first?.prompt)
            for task in ["double a number", "make a number", "third task"] {
                #expect(prompt.contains("Example: for the task \"\(task)\"") == shown.contains(task), "\(task)")
            }
            #expect(!prompt.contains("made.up"))
        }
        let script = Scripted { _ in #"["util.number"]"# }
        _ = try await GraphGenerator(workspace: emptyWorkspace(), generator: script, examples: [big]).generate("x")
        #expect(script.recorded.first?.prompt.contains("a number and the multiply node.") == true)
    }

    @Test func aRepeatedOperationIsCollapsedUnlessAllowedButValuesMayRepeat() async throws {
        let pick = #"["util.number", "util.number", "math.add", "math.add", "math.add"]"#
        func run(allowing: Bool) async throws -> GenerationOutcome {
            let script = Scripted { stage in
                if case .pickNodes = stage { return pick }
                if case .setProperties = stage { return "{}" }
                return "\"none\""
            }
            return try await GraphGenerator(
                workspace: emptyWorkspace(), generator: script, allowsRepeatedOperations: allowing).generate("add")
        }
        let collapsed = try await run(allowing: false)
        #expect(collapsed.spec.nodes.map(\.alias) == ["number1", "number2", "add1"])
        #expect(collapsed.notes.filter { $0.contains("math.add") }.count == 2)
        let kept = try await run(allowing: true)
        #expect(kept.spec.nodes.map(\.alias) == ["number1", "number2", "add1", "add2", "add3"])
    }

    @Test func eachRequestCarriesItsOwnContextAndStaysSmall() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "math.add"]"#
            case .setProperties: #"{"value": 2}"#
            case .chooseSource: "\"number1.value\""
                default: "{}"
            }
        }
        _ = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("double a number")
        for call in script.recorded {
            #expect(call.prompt.contains("Task: double a number"))
            // Roughly 3 characters a token: far inside a 4K window with room for the schema.
            #expect(call.prompt.count / 3 < 1_000)
        }
    }
}

@Suite struct StageSchemaTests {
    @Test func everyRegisteredTypeAndPropertyKindBuildsASchema() throws {
        let space = emptyWorkspace()
        let ids = space.nodes.registeredDefinitions.map(\.typeID.rawValue)
        _ = try StageSchemas.nodePick(types: ids, maxNodes: 10)
        for id in ids {
            let slots = space.propertySlots(type: id)
            if !slots.isEmpty { _ = try StageSchemas.properties(for: slots) }
        }
    }

    @Test func aSourceSchemaOffersTheOutputsAndNone() throws {
        _ = try StageSchemas.source(from: ["a.out", "b.out"])
        _ = try StageSchemas.source(from: [])  // only "none"
    }

    @Test func aliasesAreLettersAndDigitsFromTheTypeName() {
        #expect(GraphGenerator.baseAlias(of: "math.add") == "add")
        #expect(GraphGenerator.baseAlias(of: "util.number") == "number")
        #expect(GraphGenerator.baseAlias(of: "a.b-c d") == "bcd")
        #expect(GraphGenerator.baseAlias(of: "...") == "node")
        #expect(GraphGenerator.alias(of: "add1.a") == "add1")
    }
}

private final class Narrator: TextGenerator {
    private let seen = Mutex<[String]>([])
    var prompts: [String] { seen.withLock { $0 } }
    func narrate(prompt: String) async throws -> String {
        seen.withLock { $0.append(prompt) }
        return "  It is 12 because four plus eight.  "
    }
}

@Suite struct ValueExplainerTests {
    /// four + eight, with the run, so n3.result is 12.
    private func ran() async throws -> AssistantWorkspace {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardPack.register(nodes: &nodes, types: &types)
        let editor = GraphEditor(nodes: nodes, types: types)
        let spec = GraphSpec(
            nodes: [
                .init(alias: "four", type: "util.number", properties: ["value": .int(4)]),
                .init(alias: "eight", type: "util.number", properties: ["value": .int(8)]),
                .init(alias: "sum", type: "math.add"),
            ],
            links: [.init(from: "four.value", to: "sum.a"), .init(from: "eight.value", to: "sum.b")])
        let result = GraphSpecCompiler(nodes: nodes, types: types).compile(spec)
        try editor.apply(try result.pasteCommand(into: editor).command)
        let base = AssistantWorkspace(editor: editor)
        return AssistantWorkspace(editor: editor, runValues: try await base.run().values)
    }

    @Test func theTraceIsFactAndTheNarrationIsTheModelsWords() async throws {
        let narrator = Narrator()
        let explainer = ValueExplainer(workspace: try await ran(), generator: narrator, contextTokens: 4_096)
        let result = try await explainer.explain("n3.result")
        #expect(result.trace.contains("12"))
        #expect(result.narration == "It is 12 because four plus eight.")
        let prompt = try #require(narrator.prompts.first)
        #expect(prompt.contains("Do not contradict the facts"))
        #expect(prompt.contains(result.summary))
        #expect(prompt.contains(result.trace))
        #expect(result.summary.contains("n3.result = 12.0"))
    }

    @Test func aPortThatDoesNotExistFailsBeforeAskingTheModel() async throws {
        let narrator = Narrator()
        let explainer = ValueExplainer(workspace: try await ran(), generator: narrator, contextTokens: 4_096)
        await #expect(throws: AssistantToolError.self) { try await explainer.explain("n99.result") }
        #expect(narrator.prompts.isEmpty)
    }

    @Test func aLongTraceIsCutToTheContextBudgetKeepingItsStart() {
        let trace = "start\n" + String(repeating: "step\n", count: 5_000)
        let prompt = ValueExplainer.prompt(port: "n1.out", summary: "fact", trace: trace, limit: 1_000)
        #expect(prompt.count <= 1_000 + 60)
        #expect(prompt.contains("start"))
        #expect(prompt.hasSuffix("(the rest of the trace is left out)"))
        #expect(!ValueExplainer.prompt(port: "n1.out", summary: "fact", trace: "short", limit: 1_000).contains("left out"))
    }

    @Test func onlyAnAvailableEndpointMakesAGenerator() {
        let secrets = InMemorySecretStore()
        #expect(ModelEndpoint.claude().makeGenerator(secrets: secrets) == nil)
        #expect(ModelEndpoint.applePrivateCloud.makeGenerator(secrets: secrets) == nil)
        #expect((ModelEndpoint.appleOnDevice.makeGenerator(secrets: secrets) != nil) == ModelEndpoint.appleOnDevice.availability(secrets: secrets).isAvailable)
    }
}

@Suite struct OneShotGenerationTests {
    /// "add 2 and 3 together then append them to an array containing [1, 2, 3, 4]", as a model might answer it.
    private let arrayAnswer = """
        {"nodes": [
          {"alias": "two", "type": "util.number"}, {"alias": "three", "type": "util.number"}, {"alias": "sum", "type": "math.add"},
          {"alias": "e1", "type": "util.number"}, {"alias": "e2", "type": "util.number"},
          {"alias": "e3", "type": "util.number"}, {"alias": "e4", "type": "util.number"},
          {"alias": "list", "type": "array.make"}, {"alias": "out", "type": "array.append"}],
         "settings": [
          {"node": "two", "property": "value", "value": "2"}, {"node": "three", "property": "value", "value": "3"},
          {"node": "e1", "property": "value", "value": "1"}, {"node": "e2", "property": "value", "value": "2"},
          {"node": "e3", "property": "value", "value": "3"}, {"node": "e4", "property": "value", "value": "4"}],
         "links": [
          {"from": "two.value", "to": "sum.a"}, {"from": "three.value", "to": "sum.b"},
          {"from": "e1.value", "to": "list.in_1"}, {"from": "e2.value", "to": "list.in_2"},
          {"from": "e3.value", "to": "list.in_3"}, {"from": "e4.value", "to": "list.in_4"},
          {"from": "list.result", "to": "out.array"}, {"from": "sum.result", "to": "out.value"}]}
        """

    private func oneShot(_ script: Scripted, repairs: Int = 2) -> GraphGenerator {
        GraphGenerator(workspace: emptyWorkspace(), generator: script, strategy: .oneShot, maxRepairs: repairs)
    }

    @Test func buildsAGraphWithAnArrayNodeTakingFourInputsInOneRequest() async throws {
        let script = Scripted { _ in arrayAnswer }
        let outcome = try await oneShot(script).generate("add 2 and 3 together then append them to an array containing [1, 2, 3, 4]")

        #expect(script.recorded.map(\.stage) == [.draftGraph])
        #expect(outcome.change.errors.isEmpty)
        #expect(outcome.change.canApply)
        #expect(outcome.change.addedNodes.count == 9)
        #expect(outcome.spec.links.count == 8)
        let list = try #require(outcome.spec.nodes.first { $0.alias == "list" })
        #expect(list.portCounts == ["in": 4])  // worked out from the links to in_1 ... in_4
        #expect(outcome.spec.nodes.first { $0.alias == "e3" }?.properties["value"] == .int(3))
        // The one request carried the catalogue with the dynamic ports and the rules.
        let prompt = try #require(script.recorded.first?.prompt)
        #expect(prompt.contains("array.make"))
        #expect(prompt.contains("input ports in_1, in_2"))
        #expect(prompt.contains("Link them in order, starting at in_1"))
    }

    @Test func whatTheCompilerRejectsIsSentBackWithItsOwnMessage() async throws {
        let wrong = arrayAnswer.replacingOccurrences(of: "sum.result", with: "sum.output")
        let script = Scripted { stage in
            if case .draftGraph = stage { return wrong }
            return arrayAnswer
        }
        let outcome = try await oneShot(script).generate("task")

        #expect(script.recorded.map(\.stage) == [.draftGraph, .repairGraph(round: 1)])
        let repair = try #require(script.recorded.last?.prompt)
        #expect(repair.contains("The checker rejected it"))
        #expect(repair.contains("sum.output") || repair.contains("output"))
        #expect(repair.contains("Your last answer"))
        #expect(outcome.change.errors.isEmpty)
        #expect(outcome.spec.links.count == 8)
    }

    @Test func aGraphStillRejectedAfterTheRepairsKeepsItsValidPartAndSaysWhatFailed() async throws {
        let wrong = arrayAnswer.replacingOccurrences(of: "sum.result", with: "sum.output")
        let script = Scripted { _ in wrong }
        let outcome = try await oneShot(script, repairs: 2).generate("task")

        #expect(script.recorded.count == 3)  // the draft and two repairs
        #expect(!outcome.change.errors.isEmpty)
        #expect(outcome.change.addedNodes.count == 9)  // the valid part is still proposed
    }

    @Test func settingsForMissingNodesAndRepeatedAliasesAreIgnoredWithANote() async throws {
        let answer = """
            {"nodes": [{"alias": "a", "type": "util.number"}, {"alias": "a", "type": "util.number"}, {"alias": "", "type": "util.number"}],
             "settings": [{"node": "ghost", "property": "value", "value": "1"}, {"node": "a", "property": "value", "value": "7"}],
             "links": []}
            """
        let outcome = try await oneShot(Scripted { _ in answer }).generate("task")
        #expect(outcome.spec.nodes.map(\.alias) == ["a"])
        #expect(outcome.spec.nodes[0].properties["value"] == .int(7))
        #expect(outcome.notes.contains { $0.contains("ghost") })
        #expect(outcome.notes.filter { $0.contains("repeated name") }.count == 2)
    }

    @Test func anAnswerWithNumbersWhereTextIsExpectedIsStillAnAnswer() async throws {
        // A hosted model is not always held to "string": a setting's value as the number 2, an alias as 1,
        // a boolean, and a vector given as a JSON array.
        let answer = """
            {"nodes": [{"alias": 1, "type": "util.number"}, {"alias": "flag", "type": "util.bool"}],
             "settings": [{"node": 1, "property": "value", "value": 2}, {"node": "flag", "property": "value", "value": true}],
             "links": null}
            """
        let script = Scripted { _ in answer }
        let outcome = try await oneShot(script).generate("task")
        #expect(script.recorded.count == 1)  // read without a repair
        #expect(outcome.spec.nodes.map(\.alias) == ["1", "flag"])
        #expect(outcome.spec.nodes[0].properties["value"] == .int(2))
        #expect(outcome.spec.nodes[1].properties["value"] == .bool(true))
    }

    @Test func anAnswerThatCannotBeReadIsSentBackLikeAnyOtherMistake() async throws {
        let script = Scripted { stage in
            if case .draftGraph = stage { return #"{"nodes": "oops"}"# }
            return arrayAnswer
        }
        let outcome = try await oneShot(script).generate("task")
        #expect(script.recorded.map(\.stage) == [.draftGraph, .repairGraph(round: 1)])
        let repair = try #require(script.recorded.last?.prompt)
        #expect(repair.contains("nodes"))  // says what shape was expected
        #expect(outcome.change.errors.isEmpty)
        #expect(outcome.change.addedNodes.count == 9)
    }

    @Test func anAnswerThatStaysUnreadableFailsWithAWordsAndTheStartOfTheAnswer() async throws {
        let script = Scripted { _ in #"{"nodes": []}"# }
        do {
            _ = try await oneShot(script).generate("task")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("could not be read"))
            #expect(text.contains(#"{"nodes":[]}"#) || text.contains("nodes"))
        }
        #expect(script.recorded.count == 3)  // the draft and two repairs
    }

    @Test func theGraphSchemaBuildsAndSurvivesConversionForAHostedModel() throws {
        let schema = try StageSchemas.graph(types: ["util.number", "math.add"])
        let prepared = try SchemaAdapter.prepare(schema, stripBounds: true)
        #expect(!prepared.isWrapped)  // an object root needs no wrapper
        let text = String(decoding: try JSONEncoder().encode(prepared.schema), as: UTF8.self)
        #expect(text.contains("util.number") && text.contains("\"links\""))
    }

    @Test func stagedGenerationDropsNodesNothingIsLinkedToButKeepsALoneNode() async throws {
        let padded = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "util.number", "math.add", "util.number"]"#
            case .setProperties: "{}"
            case .chooseSource(let input): input == "add1.a" ? "\"number1.value\"" : "\"none\""
            default: "{}"
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: padded).generate("add")
        #expect(outcome.spec.nodes.map(\.alias) == ["number1", "add1"])
        #expect(outcome.notes.filter { $0.contains("nothing is linked to it") }.count == 2)

        let lone = Scripted { stage in
            if case .pickNodes = stage { return #"["util.number"]"# }
            return "{}"
        }
        let single = try await GraphGenerator(workspace: emptyWorkspace(), generator: lone).generate("one number")
        #expect(single.spec.nodes.map(\.alias) == ["number1"])
    }
}
