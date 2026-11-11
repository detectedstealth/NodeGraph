import Foundation
import Testing
import NodeGraphCore
import NodeGraphNodes
import NodeGraphRobotics
import NodeGraphVideo
@testable import NodeGraphAssistant

private func example(_ name: String) throws -> LintContext {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let document = try GraphDocument.decode(from: Data(contentsOf: root.appendingPathComponent("examples/\(name).nodegraph")))
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    RoboticsPack.register(nodes: &nodes, types: &types)
    VideoPack.register(nodes: &nodes, types: &types)
    return LintContext(editor: GraphEditor(document: document, nodes: nodes, types: types))
}

/// The example graphs are real, hand-built documents, which keeps the lints honest about noise.
@Suite struct ExampleLintTests {
    @Test func theDemoGraphHasNoProblemsAndOneHint() throws {
        let findings = GraphLinter().run(in: try example("demo"))
        #expect(findings.filter { $0.level == .problem }.isEmpty)
        #expect(findings.map(\.lint) == ["lint.unusedOutput"])
    }

    @Test func theShowcaseOnlyReportsItsUnlinkedNodes() throws {
        let context = try example("showcase")
        let findings = GraphLinter().run(in: context)
        #expect(Set(findings.map(\.lint)) == ["lint.isolatedNode"])
        #expect(findings.count >= context.graph.nodes.count - 5)
    }
}
