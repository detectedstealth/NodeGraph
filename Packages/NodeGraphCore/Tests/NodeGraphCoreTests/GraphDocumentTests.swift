import Foundation
import Testing
@testable import NodeGraphCore

private func id(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}

/// A small fixed document, so the golden JSON below is stable.
private func sampleDocument() -> GraphDocument {
    var graph = Graph()
    let a = NodeID(uuid: id(1)), b = NodeID(uuid: id(2))
    graph.insert(Node(
        id: a, typeID: "math.add", position: GraphPoint(x: 10, y: 20),
        properties: ["offset": .int(Int64.max), "scale": .double(1), "label": "hi"]))
    graph.insert(Node(id: b, typeID: "math.add", position: GraphPoint(x: 200, y: 20), title: "Sum"))
    graph.insert(Link(
        id: LinkID(uuid: id(10)), sourceNode: a, sourcePort: "sum", targetNode: b, targetPort: "a"))
    graph.insert(NodeGroup(
        id: GroupID(uuid: id(20)), title: "Box", bounds: GraphRect(x: 0, y: 0, width: 300, height: 100)))
    return GraphDocument(graph: graph, metadata: ["title": "Sample"])
}

private let golden = """
{
  "graph" : {
    "groups" : [
      {
        "bounds" : {
          "origin" : {
            "x" : 0,
            "y" : 0
          },
          "size" : {
            "height" : 100,
            "width" : 300
          }
        },
        "id" : "00000000-0000-0000-0000-000000000020",
        "title" : "Box"
      }
    ],
    "links" : [
      {
        "id" : "00000000-0000-0000-0000-000000000010",
        "source" : {
          "direction" : "output",
          "node" : "00000000-0000-0000-0000-000000000001",
          "port" : "sum"
        },
        "target" : {
          "direction" : "input",
          "node" : "00000000-0000-0000-0000-000000000002",
          "port" : "a"
        }
      }
    ],
    "nodes" : [
      {
        "id" : "00000000-0000-0000-0000-000000000001",
        "isCollapsed" : false,
        "isPinned" : false,
        "mode" : "always",
        "position" : {
          "x" : 10,
          "y" : 20
        },
        "properties" : {
          "label" : {
            "type" : "string",
            "value" : "hi"
          },
          "offset" : {
            "type" : "int",
            "value" : 9223372036854775807
          },
          "scale" : {
            "type" : "double",
            "value" : 1
          }
        },
        "typeID" : "math.add"
      },
      {
        "id" : "00000000-0000-0000-0000-000000000002",
        "isCollapsed" : false,
        "isPinned" : false,
        "mode" : "always",
        "position" : {
          "x" : 200,
          "y" : 20
        },
        "properties" : {

        },
        "title" : "Sum",
        "typeID" : "math.add"
      }
    ]
  },
  "metadata" : {
    "title" : {
      "type" : "string",
      "value" : "Sample"
    }
  },
  "schemaVersion" : 1
}
"""

@Test func formatIsStable() throws {
    let text = String(decoding: try sampleDocument().encoded(), as: UTF8.self)
    #expect(text == golden)
}

@Test func versionOneGoldenFileStillLoads() throws {
    let document = try GraphDocument.decode(from: Data(golden.utf8))
    #expect(document == sampleDocument())
    // The int stays an int and the double stays a double, even though both print as "1".
    #expect(document.graph.nodes.values.first?.properties["scale"] == .double(1))
    #expect(document.graph.nodes.values.first?.properties["offset"] == .int(Int64.max))
}

@Test func savingTwiceGivesIdenticalBytes() throws {
    let document = sampleDocument()
    let first = try document.encoded()
    for _ in 0..<5 { #expect(try document.encoded() == first) }
    let reloaded = try GraphDocument.decode(from: first)
    #expect(try reloaded.encoded() == first)
    #expect(try document.encoded(prettyPrinted: false) == reloaded.encoded(prettyPrinted: false))
}

@Test func compactOutputRoundTrips() throws {
    let data = try sampleDocument().encoded(prettyPrinted: false)
    #expect(!String(decoding: data, as: UTF8.self).contains("\n"))
    #expect(try GraphDocument.decode(from: data) == sampleDocument())
}

// MARK: Versions and migrations

@Test func missingOrBadVersionIsReported() {
    #expect(throws: GraphDocumentError.missingSchemaVersion) {
        try GraphDocument.decode(from: Data(#"{"graph":{"nodes":[],"links":[]}}"#.utf8))
    }
    #expect(throws: GraphDocumentError.missingSchemaVersion) {
        try GraphDocument.decode(from: Data(#"{"schemaVersion":"one"}"#.utf8))
    }
}

@Test func newerFilesAreRefused() {
    #expect(throws: GraphDocumentError.newerThanSupported(found: 99, supported: 1)) {
        try GraphDocument.decode(from: Data(#"{"schemaVersion":99}"#.utf8))
    }
}

@Test func malformedFilesThrowDecodingErrors() {
    #expect(throws: DecodingError.self) {
        try GraphDocument.decode(from: Data(#"{"schemaVersion":1}"#.utf8))
    }
    #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Data("not json".utf8)) }
}

/// Pretends the format is version 3 so the chain has something to do. Version 1 files name
/// the node list "items"; version 2 files lack the `mode` field.
private func chain() -> MigrationChain {
    MigrationChain(targetVersion: 3, migrations: [
        DocumentMigration(from: 1) { tree in
            guard var graph = tree["graph"] else { return }
            graph["nodes"] = graph["items"]
            graph["items"] = nil
            tree["graph"] = graph
        },
        DocumentMigration(from: 2) { tree in
            guard var graph = tree["graph"], case .array(var nodes)? = graph["nodes"] else { return }
            for index in nodes.indices { nodes[index]["mode"] = .string("muted") }
            graph["nodes"] = .array(nodes)
            tree["graph"] = graph
        },
    ])
}

private func oldFile(version: Int) -> Data {
    let list = version == 1 ? "items" : "nodes"
    return Data("""
    {"schemaVersion":\(version),"metadata":{},"graph":{"\(list)":[{
      "id":"00000000-0000-0000-0000-000000000001","typeID":"t","position":{"x":1,"y":2},
      "isCollapsed":false,"isPinned":false,
      "properties":{"big":{"type":"int","value":9007199254740993}}}],"links":[]}}
    """.utf8)
}

@Test(arguments: [1, 2])
func oldDocumentsMigrateStepByStep(version: Int) throws {
    let document = try GraphDocument.decode(from: oldFile(version: version), migrations: chain())
    let node = try #require(document.graph.nodes.values.first)
    #expect(node.mode == .muted)
    #expect(node.position == GraphPoint(x: 1, y: 2))
    // 2^53 + 1 survives the trip through the JSON tree.
    #expect(node.properties["big"] == .int(9_007_199_254_740_993))
}

@Test func missingMigrationIsReported() {
    let gap = MigrationChain(targetVersion: 3, migrations: [DocumentMigration(from: 2) { _ in }])
    #expect(throws: GraphDocumentError.noMigrationPath(from: 1)) {
        try GraphDocument.decode(from: oldFile(version: 1), migrations: gap)
    }
}

@Test func failingMigrationIsReportedWithItsVersion() {
    struct Boom: Error {}
    let broken = MigrationChain(targetVersion: 2, migrations: [DocumentMigration(from: 1) { _ in throw Boom() }])
    #expect(throws: GraphDocumentError.self) {
        try GraphDocument.decode(from: oldFile(version: 1), migrations: broken)
    }
}

@Test func jsonValueKeepsLargeIntegersAndRoundTrips() throws {
    let text = #"{"a":[1,2.5,true,null,"x"],"b":9223372036854775807}"#
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(value["b"] == .int(Int64.max))
    #expect(value["a"]?.array?.count == 5)
    let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    #expect(again == value)
}

// MARK: Unknown node types

@Test func unknownNodeTypesLoadWithAllTheirData() throws {
    var graph = Graph()
    let known = Node(typeID: "math.add")
    let ghost = Node(
        typeID: "robot.pid", position: GraphPoint(x: 7, y: 8),
        properties: ["kp": 2.5, "mode": "fast"])
    graph.insert(known)
    graph.insert(ghost)
    graph.insert(Link(sourceNode: ghost.id, sourcePort: "out", targetNode: known.id, targetPort: "a"))
    let feeder = Node(typeID: "math.add")
    graph.insert(feeder)
    graph.insert(Link(sourceNode: feeder.id, sourcePort: "sum", targetNode: ghost.id, targetPort: "error"))
    let document = GraphDocument(graph: graph)

    var registry = NodeRegistry()
    registry.register(NodeDefinition(typeID: "math.add", displayName: "Add", ports: [
        PortDefinition(id: "a", direction: .input), PortDefinition(id: "sum", direction: .output),
    ]))
    #expect(document.missingNodeTypes(in: registry) == ["robot.pid"])
    #expect(document.missingNodeTypes(in: registry.addingPlaceholders(for: graph)).isEmpty)

    // Saving after loading loses nothing.
    let reloaded = try GraphDocument.decode(from: document.encoded())
    #expect(reloaded == document)
    #expect(reloaded.graph.nodes[ghost.id]?.properties["kp"] == 2.5)
}

@Test func placeholdersMakeMissingNodesValidAndEditable() throws {
    var graph = Graph()
    let known = Node(typeID: "math.add")
    let ghost = Node(typeID: "robot.pid", properties: ["kp": 2.5])
    graph.insert(known)
    graph.insert(ghost)
    graph.insert(Link(sourceNode: ghost.id, sourcePort: "out", targetNode: known.id, targetPort: "a"))
    let feeder = Node(typeID: "math.add")
    graph.insert(feeder)
    graph.insert(Link(sourceNode: feeder.id, sourcePort: "sum", targetNode: ghost.id, targetPort: "error"))

    var registry = NodeRegistry()
    registry.register(NodeDefinition(typeID: "math.add", displayName: "Add", ports: [
        PortDefinition(id: "a", direction: .input), PortDefinition(id: "sum", direction: .output),
    ]))
    let withPlaceholders = registry.addingPlaceholders(for: graph)
    let placeholder = try #require(withPlaceholders.definition(for: "robot.pid"))
    #expect(placeholder.category == "Missing")
    #expect(placeholder.outputs.map(\.id) == ["out"] && placeholder.inputs.map(\.id) == ["error"])
    #expect(placeholder.property("kp") != nil)
    #expect(placeholder.problems.isEmpty)

    let context = ValidationContext(graph: graph, nodes: withPlaceholders, types: TypeRegistry())
    #expect(GraphValidator().validate(context).isEmpty)
    // Real definitions are never replaced.
    #expect(withPlaceholders.definition(for: "math.add")?.displayName == "Add")
}

@Test func placeholderInputsAreMultiLinkOnlyWhereTheGraphAlreadyHasSeveralLinks() throws {
    var graph = Graph()
    let a = Node(typeID: "t"), b = Node(typeID: "t"), ghost = Node(typeID: "ghost")
    [a, b, ghost].forEach { graph.insert($0) }
    graph.insert(Link(sourceNode: a.id, sourcePort: "o", targetNode: ghost.id, targetPort: "many"))
    graph.insert(Link(sourceNode: b.id, sourcePort: "o", targetNode: ghost.id, targetPort: "many"))
    graph.insert(Link(sourceNode: a.id, sourcePort: "o", targetNode: ghost.id, targetPort: "one"))
    let definition = try #require(NodeRegistry().addingPlaceholders(for: graph).definition(for: "ghost"))
    #expect(definition.port("many", direction: .input)?.allowsMultipleLinks == true)
    #expect(definition.port("one", direction: .input)?.allowsMultipleLinks == false)
}
