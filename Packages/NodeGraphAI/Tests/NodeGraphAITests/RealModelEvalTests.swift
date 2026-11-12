import Foundation
import Testing
import NodeGraphAssistant
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAI

/// Runs staged generation on the real on-device model and prints what it proposes, to judge prompt
/// changes by eye (decision 233; the start of the eval harness, PLAN step G). Not part of the normal
/// run: it needs Apple Intelligence, takes about half a minute, and the answers vary.
///
///     NODEGRAPH_EVAL=1 swift test --package-path Packages/NodeGraphAI --filter RealModelEval
@Suite struct RealModelEvalTests {
    static let enabled = ProcessInfo.processInfo.environment["NODEGRAPH_EVAL"] != nil

    @Test(.enabled(if: RealModelEvalTests.enabled))
    func generatesSensibleGraphsForSimpleTasks() async throws {
        guard let generator = ModelEndpoint.appleOnDevice.makeGenerator() else {
            print("EVAL on-device model unavailable: \(ModelEndpoint.appleOnDevice.availability.summary)")
            return
        }
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardPack.register(nodes: &nodes, types: &types)
        let space = AssistantWorkspace(editor: GraphEditor(nodes: nodes, types: types))
        let examples = [
            GenerationExample(
                task: "double a number and show it", types: ["util.number", "util.number", "math.multiply", "util.watch"],
                explanation: "a number, the number 2, the multiply node, and a node that shows the result"),
            GenerationExample(
                task: "make a number with the value 7", types: ["util.number"],
                explanation: "just the number node, nothing else"),
        ]
        for task in [
            "add two numbers and show the sum",
            "multiply a number by three and show the result",
            "join two pieces of text and show it",
            "keep a running total of a number",
            "create a string with the value hello",
            "show a number",
        ] {
            let outcome = try await GraphGenerator(workspace: space, generator: generator, examples: examples, allowsRepeatedOperations: false).generate(task)
            let nodeText = outcome.spec.nodes.map { "\($0.alias)\($0.properties.isEmpty ? "" : " \($0.properties.mapValues { GraphGenerator.text(of: $0) })")" }
            print("EVAL [\(task)]\n  nodes: \(nodeText)\n  links: \(outcome.spec.links.map(GraphGenerator.text(of:)))\n  notes: \(outcome.notes)")
            #expect(outcome.change.errors.isEmpty)
        }
    }
}
