import Foundation
import NodeGraphCore
import NodeGraphNodes
import NodeGraphVideo
import Testing
@testable import NodeGraphRobotics

/// `examples/showcase.nodegraph` at the repo root: one node of every registered type, in a group
/// per category.
private func showcaseDocument() throws -> GraphDocument {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try GraphDocument.decode(from: Data(contentsOf: root.appendingPathComponent("examples/showcase.nodegraph")))
}

private func allPacks() -> NodeRegistry {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    RoboticsPack.register(nodes: &nodes, types: &types)
    VideoPack.register(nodes: &nodes, types: &types)
    return nodes
}

@Test func theShowcaseHasOneNodeOfEveryRegisteredType() throws {
    let document = try showcaseDocument()
    let nodes = allPacks()
    #expect(document.missingNodeTypes(in: nodes).isEmpty)
    let placed = document.graph.nodes.values.map(\.typeID)
    #expect(Set(placed) == Set(nodes.registeredDefinitions.map(\.typeID)))
    #expect(placed.count == Set(placed).count)
}

@Test func theShowcaseNodesSitInsideTheirCategoryGroupOnAGrid() throws {
    let document = try showcaseDocument()
    let nodes = allPacks()
    let graph = document.graph
    for group in graph.groups.values {
        let members = graph.members(of: group, frame: nodes.frame(of:)).compactMap { graph.nodes[$0] }
        let category = try #require(group.title.split(separator: " ").first.map(String.init))
        #expect(!members.isEmpty)
        #expect(members.allSatisfy { nodes.definition(for: $0.typeID)?.category == category })
        // Every node in a group shares one size, and columns share an x.
        #expect(Set(members.compactMap(\.size)).count == 1)
        #expect(Set(members.map(\.position.x)).count <= 5)
    }
}
