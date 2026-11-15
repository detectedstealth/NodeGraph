import Foundation
import NodeGraphCore
import Testing
@testable import NodeGraphTutorials

// Chapter 5: the finished code of the automation and assistant tutorials, run.

@Test func aSavedGraphRunsHeadless() async throws {
    let data = try saveToData(try makeAdditionGraph())
    let report = try await runDocument(data, passes: 3)
    #expect(report.succeeded)
    #expect(report.ticks.count == 3)
    #expect(lastNumber(in: report, nodeType: "math.add", port: "result") == 6)
}

@Test func theOutlineNamesEveryNode() throws {
    let text = outline(of: try makeAdditionGraph())
    #expect(text.contains("math.add"))
    #expect(text.contains("util.number"))
}

@Test func theStandardLintsFindAnIsolatedNode() throws {
    let editor = try makeAdditionGraph()
    try editor.apply(.addNode(node: Node(typeID: "util.number")))
    #expect(findings(in: editor).contains { $0.lint == "lint.isolatedNode" })
}

@Test func aPackLintSeesWhatOnlyThePackKnows() throws {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    TemperaturePack.register(nodes: &nodes, types: &types)
    let editor = GraphEditor(nodes: nodes, types: types)
    try editor.apply(.addNode(node: Node(typeID: "temperature.convert")))

    #expect(!findings(in: editor).contains { $0.lint == "temperature.unfedConverter" })
    let found = findingsWithPackLints(in: editor).filter { $0.lint == "temperature.unfedConverter" }
    #expect(found.count == 1)
    #expect(found.first?.fix != nil)
}
