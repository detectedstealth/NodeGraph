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
        #expect(ModelEndpoint.claude().makeGenerator() == nil)
        #expect(ModelEndpoint.applePrivateCloud.makeGenerator() == nil)
        #expect((ModelEndpoint.appleOnDevice.makeGenerator() != nil) == ModelEndpoint.appleOnDevice.availability.isAvailable)
    }
}
