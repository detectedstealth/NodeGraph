import Foundation
import NodeGraphCore
import Testing
@testable import NodeGraphRunKit

private let one = "00000000-0000-0000-0000-000000000001"
private let two = "00000000-0000-0000-0000-000000000002"
private let three = "00000000-0000-0000-0000-000000000003"

/// A node as the document format writes it.
private func node(_ id: String, _ type: String, x: Int = 0) -> String {
    """
    {"id":"\(id)","isCollapsed":false,"isPinned":false,"mode":"always","position":{"x":\(x),"y":0},
     "typeID":"\(type)","properties":{}}
    """
}

private func document(nodes: [String], links: String = "") throws -> GraphDocument {
    let json = """
    {"schemaVersion":1,"metadata":{},"graph":{"groups":[],"links":[\(links)],"nodes":[\(nodes.joined(separator: ","))]}}
    """
    return try GraphDocument.decode(from: Data(json.utf8))
}

private let oneToTwo = """
{"id":"00000000-0000-0000-0000-000000000010",
 "source":{"direction":"output","node":"\(one)","port":"result"},
 "target":{"direction":"input","node":"\(two)","port":"a"}}
"""

@Test func aSoundDocumentValidatesCleanly() throws {
    let report = GraphCheck.validate(try document(
        nodes: [node(one, "math.add"), node(two, "math.add", x: 200)], links: oneToTwo))
    #expect(report.findings.isEmpty)
    #expect(report.text == "No findings.")
}

@Test func anUnknownNodeTypeIsAnError() throws {
    let report = GraphCheck.validate(try document(nodes: [node(one, "no.such.node")]))
    let found = try #require(report.findings.first)
    #expect(found.kind == "validation" && found.severity == "error")
    #expect(found.id == "node.unknownType" && found.node == one && found.nodeType == "no.such.node")
    #expect(!report.failing().isEmpty)
}

@Test func lintsFindAnIsolatedNodeAndOnlyHintsDoNotFail() throws {
    let report = GraphCheck.lint(try document(
        nodes: [node(one, "math.add"), node(two, "math.add", x: 200), node(three, "math.add", x: 400)],
        links: oneToTwo))
    let isolated = try #require(report.findings.first { $0.id == "lint.isolatedNode" })
    #expect(isolated.severity == "hint" && isolated.node == three && isolated.hasFix)
    #expect(report.failing().isEmpty)
    #expect(!report.failing(strict: true).isEmpty)
}

@Test func reportsEncodeToTheSameBytesEveryTime() throws {
    let doc = try document(nodes: [node(one, "no.such.node")])
    #expect(try GraphCheck.validate(doc).encoded() == GraphCheck.validate(doc).encoded())
}

@Test func theDigestNamesEveryNodeAndLink() throws {
    let text = GraphCheck.digest(try document(
        nodes: [node(one, "math.add"), node(two, "math.add", x: 200)], links: oneToTwo), detail: .outline)
    #expect(text.contains("n1") && text.contains("n2") && text.contains("math.add"))
    #expect(text.contains("n1.result -> n2.a"))
}
