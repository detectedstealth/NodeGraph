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
    private let numbers = #"["util.number", "util.number", "math.add"]"#

    @Test func buildsAGraphInThreeStagesAndProposesItWithoutApplyingIt() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "util.number", "math.add"]"#
            case .setProperties(let alias): alias == "number1" ? #"{"value": 4}"# : #"{"value": 8}"#
            case .wireLinks: #"["number1.value -> add1.a", "number2.value -> add1.b"]"#
            case .repairLinks: "[]"
            }
        }
        let space = emptyWorkspace()
        let outcome = try await GraphGenerator(workspace: space, generator: script).generate("add four and eight")

        #expect(outcome.spec.nodes.map(\.alias) == ["number1", "number2", "add1"])
        #expect(outcome.spec.nodes[0].properties["value"] == .int(4))
        #expect(outcome.spec.links.count == 2)
        #expect(outcome.repairs == 0)
        #expect(outcome.change.errors.isEmpty)
        #expect(outcome.change.canApply)
        #expect(outcome.change.addedNodes.count == 3)
        #expect(space.graph.nodes.isEmpty)  // proposed, never applied
        // One request per node with settings, plus nodes and links; math.add has no settings.
        #expect(script.recorded.map(\.stage) == [
            .pickNodes, .setProperties(alias: "number1"), .setProperties(alias: "number2"), .wireLinks,
        ])
    }

    @Test func aRejectedLinkIsReplacedInARepairRound() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "util.number", "math.add"]"#
            case .setProperties: "{}"
            // Both numbers into add1.a: the second is rejected, since an input takes one link.
            case .wireLinks: #"["number1.value -> add1.a", "number2.value -> add1.a"]"#
            case .repairLinks: #"["number2.value -> add1.b"]"#
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("add")

        #expect(outcome.repairs == 1)
        #expect(Set(outcome.spec.links.map(GraphGenerator.text(of:))) == ["number1.value -> add1.a", "number2.value -> add1.b"])
        #expect(outcome.change.errors.isEmpty)
        let repair = try #require(script.recorded.last)
        #expect(repair.prompt.contains("These were rejected"))
        // The rejected link is not offered again, and the accepted one is not repeated.
        let offered = repair.prompt.components(separatedBy: "Choose replacements only from:").last ?? ""
        #expect(!offered.contains("number2.value -> add1.a"))
        #expect(!offered.contains("number1.value -> add1.a"))
    }

    @Test func aLinkTheModelCannotReplaceIsDroppedAndReported() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "util.number", "math.add"]"#
            case .setProperties: "{}"
            case .wireLinks: #"["number1.value -> add1.a", "number2.value -> add1.a"]"#
            case .repairLinks: "[]"  // the model has nothing better
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script, maxRepairs: 2).generate("add")

        #expect(outcome.repairs == 1)  // nothing left to repair once the rejected link is gone
        #expect(outcome.spec.links.map(GraphGenerator.text(of:)) == ["number1.value -> add1.a"])
        #expect(outcome.notes.contains { $0.contains("Left out number2.value -> add1.a") })
        #expect(outcome.change.canApply)
    }

    @Test func nothingOutsideTheOfferedChoicesGetsThrough() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "made.up", "math.add"]"#
            case .setProperties: #"{"value": 3, "bogus": 1, "gain": null}"#
            case .wireLinks: #"["number1.value -> add1.a", "ghost.out -> add1.b", "not a link"]"#
            case .repairLinks: "[]"
            }
        }
        let outcome = try await GraphGenerator(workspace: emptyWorkspace(), generator: script).generate("add")

        #expect(outcome.spec.nodes.map(\.alias) == ["number1", "add1"])
        #expect(outcome.notes.contains { $0.contains("made.up") })
        #expect(outcome.spec.nodes[0].properties == ["value": .int(3)])
        #expect(outcome.spec.links.map(GraphGenerator.text(of:)) == ["number1.value -> add1.a"])
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
        #expect(!script.recorded.contains { $0.stage == .wireLinks })
        #expect(outcome.spec.links.isEmpty)
    }

    @Test func eachRequestCarriesItsOwnContextAndStaysSmall() async throws {
        let script = Scripted { stage in
            switch stage {
            case .pickNodes: #"["util.number", "math.add"]"#
            case .setProperties: #"{"value": 2}"#
            case .wireLinks: #"["number1.value -> add1.a"]"#
            case .repairLinks: "[]"
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

    @Test func linkSchemasAcceptAnEmptyChoiceListOnlyViaTheCaller() throws {
        // The generator skips the stage when no link is possible; a schema is built only with choices.
        _ = try StageSchemas.links(from: ["a.out -> b.in"], maxLinks: 4)
    }

    @Test func aliasesAreLettersAndDigitsFromTheTypeName() {
        #expect(GraphGenerator.baseAlias(of: "math.add") == "add")
        #expect(GraphGenerator.baseAlias(of: "util.number") == "number")
        #expect(GraphGenerator.baseAlias(of: "a.b-c d") == "bcd")
        #expect(GraphGenerator.baseAlias(of: "...") == "node")
        #expect(GraphGenerator.link(from: "a.out -> b.in") == .init(from: "a.out", to: "b.in"))
        #expect(GraphGenerator.link(from: "a.out") == nil)
    }
}
