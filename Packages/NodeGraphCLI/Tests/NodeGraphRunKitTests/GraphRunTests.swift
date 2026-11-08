import Foundation
import NodeGraphCore
import Testing
@testable import NodeGraphRunKit

private let addID = "00000000-0000-0000-0000-000000000001"
private let secondID = "00000000-0000-0000-0000-000000000002"

/// Two adders, the first feeding the second. `type` is the second node's type.
private func document(secondType: String = "math.add") throws -> GraphDocument {
    let json = """
    {"schemaVersion":1,"metadata":{},"graph":{"groups":[],
    "links":[{"id":"00000000-0000-0000-0000-000000000010",
      "source":{"direction":"output","node":"\(addID)","port":"result"},
      "target":{"direction":"input","node":"\(secondID)","port":"a"}}],
    "nodes":[
     {"id":"\(addID)","isCollapsed":false,"isPinned":false,"mode":"always","position":{"x":0,"y":0},
      "typeID":"math.add","properties":{}},
     {"id":"\(secondID)","isCollapsed":false,"isPinned":false,"mode":"always","position":{"x":200,"y":0},
      "typeID":"\(secondType)","properties":{}}]}}
    """
    return try GraphDocument.decode(from: Data(json.utf8))
}

@Test func runReportsEveryNodeOfEveryTick() async throws {
    let report = try await GraphRun.run(document(), ticks: 3)
    #expect(report.succeeded)
    #expect(report.ticks.map(\.tick) == [0, 1, 2])
    let first = try #require(report.ticks.first?.nodes.first)
    #expect(first.id == addID && first.type == "math.add" && first.status == "success")
    #expect(first.outputs["result"] == .double(0))
}

@Test func reportIsDeterministic() async throws {
    let a = try await GraphRun.run(document(), ticks: 2).encoded()
    let b = try await GraphRun.run(document(), ticks: 2).encoded()
    #expect(a == b)
    let decoded = try JSONDecoder().decode(RunReport.self, from: a)
    #expect(decoded.ticks.count == 2)
}

@Test func failedNodeMakesTheRunUnsuccessful() async throws {
    let report = try await GraphRun.run(document(secondType: "no.such.node"))
    #expect(!report.succeeded)
    let failed = try #require(report.ticks.first?.nodes.first { $0.id == secondID })
    #expect(failed.status != "success" && failed.error != nil)
}

@Test func variablesParseAsJSONOrText() throws {
    let values = try GraphRun.parseVariables(["speed=3", "flag=true", "label=hello world", "pair=[1,2]", "eq=a=b"])
    #expect(values["speed"] == .int(3))
    #expect(values["flag"] == .bool(true))
    #expect(values["label"] == .string("hello world"))
    #expect(values["pair"] == .array([.int(1), .int(2)]))
    #expect(values["eq"] == .string("a=b"))
    #expect(throws: GraphRunError.malformedVariable("nope")) { try GraphRun.parseVariables(["nope"]) }
    #expect(throws: GraphRunError.malformedVariable("=1")) { try GraphRun.parseVariables(["=1"]) }
}

@Test func undeclaredVariableIsRefused() async throws {
    await #expect(throws: VariableOverrideError.self) {
        try await GraphRun.run(document(), variables: ["ghost": .int(1)])
    }
}
