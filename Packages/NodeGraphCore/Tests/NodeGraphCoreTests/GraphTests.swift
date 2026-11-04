import Foundation
import Testing
@testable import NodeGraphCore

private let addDefinition = NodeDefinition(
    typeID: "math.add",
    displayName: "Add",
    category: "Math",
    ports: [
        PortDefinition(id: "a", direction: .input, type: "number", defaultValue: 0.0),
        PortDefinition(id: "b", direction: .input, type: "number", defaultValue: 0.0),
        PortDefinition(id: "sum", direction: .output, type: "number"),
    ],
    properties: [
        PropertyDefinition(id: "clamp", displayName: "Clamp", kind: .bool, defaultValue: false)
    ]
)

// MARK: Definitions and registry

@Test func portMultiLinkDefaultsFollowDirection() {
    #expect(addDefinition.port("a", direction: .input)?.allowsMultipleLinks == false)
    #expect(addDefinition.port("sum", direction: .output)?.allowsMultipleLinks == true)
}

@Test func portsAreLookedUpByIdAndDirection() {
    #expect(addDefinition.inputs.map(\.id) == ["a", "b"])
    #expect(addDefinition.outputs.map(\.id) == ["sum"])
    #expect(addDefinition.port("sum", direction: .input) == nil)
}

@Test func sameIDOnBothDirectionsIsAllowed() {
    let definition = NodeDefinition(typeID: "t", displayName: "T", ports: [
        PortDefinition(id: "value", direction: .input),
        PortDefinition(id: "value", direction: .output),
    ])
    #expect(definition.problems.isEmpty)
}

@Test func definitionReportsProblems() {
    let definition = NodeDefinition(
        typeID: "bad", displayName: "Bad",
        ports: [PortDefinition(id: "x", direction: .input), PortDefinition(id: "x", direction: .input)],
        properties: [
            PropertyDefinition(id: "p", displayName: "P", kind: .int(min: 0, max: 5), defaultValue: 9),
            PropertyDefinition(id: "p", displayName: "P", kind: .bool, defaultValue: false),
        ])
    #expect(definition.problems.count == 3)
    #expect(addDefinition.problems.isEmpty)
}

@Test func registryReplacesAndKeepsOrder() {
    var registry = NodeRegistry()
    registry.register(addDefinition)
    registry.register(NodeDefinition(typeID: "math.sub", displayName: "Sub"))
    registry.register(NodeDefinition(typeID: "math.add", displayName: "Add v2"))
    #expect(registry.registeredDefinitions.map(\.typeID) == ["math.add", "math.sub"])
    #expect(registry.definition(for: "math.add")?.displayName == "Add v2")
    #expect(registry.definition(for: "missing") == nil)
}

// MARK: Node

@Test func nodeFallsBackToDefinitionDefaults() {
    var node = Node(typeID: "math.add", position: GraphPoint(x: 10, y: 20))
    #expect(node.resolvedSize(in: addDefinition) == addDefinition.defaultSize)
    #expect(node.frame(in: addDefinition).origin == GraphPoint(x: 10, y: 20))
    #expect(node.value(of: "clamp", in: addDefinition) == false)
    #expect(node.value(of: "nope", in: addDefinition) == nil)
    node.properties["clamp"] = true
    node.size = GraphSize(width: 50, height: 60)
    #expect(node.value(of: "clamp", in: addDefinition) == true)
    #expect(node.resolvedSize(in: addDefinition) == GraphSize(width: 50, height: 60))
}

// MARK: Geometry

@Test func rectContainmentAndIntersection() {
    let outer = GraphRect(x: 0, y: 0, width: 100, height: 100)
    #expect(outer.contains(GraphRect(x: 10, y: 10, width: 20, height: 20)))
    #expect(outer.contains(outer))
    #expect(!outer.contains(GraphRect(x: 90, y: 90, width: 20, height: 20)))
    #expect(outer.intersects(GraphRect(x: 90, y: 90, width: 20, height: 20)))
    #expect(outer.intersects(GraphRect(x: 100, y: 0, width: 10, height: 10)))
    #expect(!outer.intersects(GraphRect(x: 101, y: 0, width: 10, height: 10)))
    #expect(outer.contains(GraphPoint(x: 100, y: 100)))
    #expect(!outer.contains(GraphPoint(x: 101, y: 50)))
}

// MARK: Graph

private func makeGraph() -> (Graph, Node, Node, Link) {
    var graph = Graph()
    let a = Node(typeID: "math.add")
    let b = Node(typeID: "math.add")
    let link = Link(sourceNode: a.id, sourcePort: "sum", targetNode: b.id, targetPort: "a")
    graph.insert(a)
    graph.insert(b)
    graph.insert(link)
    return (graph, a, b, link)
}

@Test func linkEndsHaveFixedDirections() {
    let (_, a, b, link) = makeGraph()
    #expect(link.source == PortAddress(node: a.id, port: "sum", direction: .output))
    #expect(link.target == PortAddress(node: b.id, port: "a", direction: .input))
    #expect(link.touches(a.id) && link.touches(b.id) && !link.touches(NodeID()))
}

@Test func graphQueriesFindLinksByPort() {
    let (graph, a, b, link) = makeGraph()
    #expect(graph.links(attachedTo: a.id) == [link])
    #expect(graph.links(from: link.source) == [link])
    #expect(graph.links(into: link.target) == [link])
    #expect(graph.links(into: PortAddress(node: b.id, port: "b", direction: .input)).isEmpty)
}

@Test func graphPreservesInsertionOrderAndReplacesInPlace() {
    var graph = Graph()
    let nodes = (0..<5).map { _ in Node(typeID: "t") }
    nodes.forEach { graph.insert($0) }
    var moved = nodes[1]
    moved.position = GraphPoint(x: 5, y: 5)
    graph.insert(moved)
    #expect(Array(graph.nodes.keys) == nodes.map(\.id))
    #expect(graph.nodes[moved.id]?.position == GraphPoint(x: 5, y: 5))
}

@Test func graphUpdateAndRemove() {
    var (graph, a, _, link) = makeGraph()
    #expect(graph.updateNode(a.id) { $0.isPinned = true })
    #expect(graph.nodes[a.id]?.isPinned == true)
    #expect(!graph.updateNode(NodeID()) { $0.isPinned = true })
    #expect(graph.removeLink(link.id) == link)
    #expect(graph.removeNode(a.id)?.id == a.id)
    #expect(graph.removeNode(a.id) == nil)
    #expect(graph.links.isEmpty && graph.nodes.count == 1)
}

@Test func graphRoundTripsInOrder() throws {
    var (graph, _, _, _) = makeGraph()
    graph.insert(NodeGroup(title: "G", bounds: GraphRect(x: 0, y: 0, width: 10, height: 10)))
    graph.insert(Node(typeID: "x", properties: ["p": .int(Int64.max)]))
    let data = try JSONEncoder().encode(graph)
    let decoded = try JSONDecoder().decode(Graph.self, from: data)
    #expect(decoded == graph)
    #expect(Array(decoded.nodes.keys) == Array(graph.nodes.keys))
}

@Test func graphDecodingRejectsDuplicateIDs() throws {
    let node = Node(typeID: "t")
    let nodeJSON = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)
    let json = #"{"nodes":[\#(nodeJSON),\#(nodeJSON)],"links":[]}"#
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Graph.self, from: Data(json.utf8))
    }
}

@Test func nodeDefinitionRoundTrips() throws {
    let data = try JSONEncoder().encode(addDefinition)
    #expect(try JSONDecoder().decode(NodeDefinition.self, from: data) == addDefinition)
}

@Test func graphInsertsAtAnIndexForEveryKind() {
    var graph = Graph()
    let nodes = (0..<3).map { _ in Node(typeID: "t") }
    nodes.forEach { graph.insert($0) }
    let early = Node(typeID: "t")
    graph.insert(early, at: 1)
    #expect(Array(graph.nodes.keys) == [nodes[0].id, early.id, nodes[1].id, nodes[2].id])

    let links = (0..<2).map { _ in Link(sourceNode: nodes[0].id, sourcePort: "o", targetNode: nodes[1].id, targetPort: "i") }
    links.forEach { graph.insert($0) }
    let firstLink = Link(sourceNode: nodes[0].id, sourcePort: "o", targetNode: nodes[2].id, targetPort: "i")
    graph.insert(firstLink, at: 0)
    #expect(Array(graph.links.keys) == [firstLink.id, links[0].id, links[1].id])

    let bounds = GraphRect(x: 0, y: 0, width: 1, height: 1)
    let groups = (0..<2).map { _ in NodeGroup(title: "g", bounds: bounds) }
    groups.forEach { graph.insert($0) }
    let firstGroup = NodeGroup(title: "first", bounds: bounds)
    graph.insert(firstGroup, at: 0)
    #expect(Array(graph.groups.keys) == [firstGroup.id, groups[0].id, groups[1].id])
    #expect(graph.removeGroup(firstGroup.id) == firstGroup)
}

@Test func graphDecodingRejectsDuplicateLinkAndGroupIDs() throws {
    let link = Link(sourceNode: NodeID(), sourcePort: "o", targetNode: NodeID(), targetPort: "i")
    let group = NodeGroup(title: "g", bounds: GraphRect(x: 0, y: 0, width: 1, height: 1))
    let linkJSON = String(decoding: try JSONEncoder().encode(link), as: UTF8.self)
    let groupJSON = String(decoding: try JSONEncoder().encode(group), as: UTF8.self)
    for json in [#"{"nodes":[],"links":[\#(linkJSON),\#(linkJSON)]}"#,
                 #"{"nodes":[],"links":[],"groups":[\#(groupJSON),\#(groupJSON)]}"#] {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Graph.self, from: Data(json.utf8)) }
    }
}

@Test func graphDecodingAllowsMissingGroups() throws {
    let graph = try JSONDecoder().decode(Graph.self, from: Data(#"{"nodes":[],"links":[]}"#.utf8))
    #expect(graph.groups.isEmpty)
}

@Test func nodeDecodingFillsDefaultsForOptionalFields() throws {
    let json = """
    {"id":"00000000-0000-0000-0000-000000000001","typeID":"t","position":{"x":1,"y":2}}
    """
    let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
    #expect(node.mode == .always && !node.isCollapsed && !node.isPinned)
    #expect(node.properties.isEmpty && node.size == nil && node.title == nil && node.color == nil)
}

@Test func nodeWithEveryOptionalFieldRoundTrips() throws {
    let node = Node(
        typeID: "t", position: GraphPoint(x: 1, y: 2), size: GraphSize(width: 3, height: 4),
        title: "T", color: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4),
        mode: .bypassed, isCollapsed: true, isPinned: true, properties: ["a": true])
    let data = try JSONEncoder().encode(node)
    #expect(try JSONDecoder().decode(Node.self, from: data) == node)
}
