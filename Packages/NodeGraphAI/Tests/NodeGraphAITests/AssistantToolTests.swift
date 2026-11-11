import Foundation
import Testing
import NodeGraphAssistant
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAI

/// four + eight, as aliases n1...n3 with n3 = sum.
private func workspace(run: Bool = true) async throws -> AssistantWorkspace {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    let spec = GraphSpec(
        nodes: [
            .init(alias: "four", type: "util.number", properties: ["value": .int(4)]),
            .init(alias: "eight", type: "util.number", properties: ["value": .int(8)]),
            .init(alias: "sum", type: "math.add"),
        ],
        links: [.init(from: "four.value", to: "sum.a"), .init(from: "eight.value", to: "sum.b")])
    let editor = GraphEditor(nodes: nodes, types: types)
    let result = GraphSpecCompiler(nodes: nodes, types: types).compile(spec)
    try editor.apply(try result.pasteCommand(into: editor).command)
    let base = AssistantWorkspace(editor: editor)
    return AssistantWorkspace(editor: editor, runValues: run ? try await base.run().values : RunValues())
}

@Suite struct AssistantToolTests {
    @Test func searchAndDescribeAnswerInWordsEvenWhenNothingMatches() async throws {
        let space = try await workspace()
        let found = try await SearchNodesTool(workspace: space).call(arguments: .init(query: "add numbers"))
        #expect(found.contains("math.add"))
        let none = try await SearchNodesTool(workspace: space).call(arguments: .init(query: "zzzz"))
        #expect(none.contains("No node type"))
        let missing = try await DescribeNodeTool(workspace: space).call(arguments: .init(type: "nope"))
        #expect(missing.contains("searchNodes"))
    }

    @Test func traceReportsABadPortAsTextNotAnError() async throws {
        let space = try await workspace()
        let good = try await TraceValueTool(workspace: space).call(arguments: .init(port: "n3.result"))
        #expect(good.contains("12"))
        let bad = try await TraceValueTool(workspace: space).call(arguments: .init(port: "n99.result"))
        #expect(!bad.isEmpty)
    }

    @Test func proposeEditLeavesTheChangeInTheInboxAndDescribesIt() async throws {
        let space = try await workspace()
        let inbox = ProposalInbox()
        let tool = ProposeEditTool(workspace: space, inbox: inbox)
        let text = try await tool.call(arguments: .init(operations: [
            .init(op: .setProperty, node: "n1", property: "value", value: "10"),
        ]))
        #expect(text.contains("n1"))
        let change = try #require(inbox.take())
        #expect(!change.isEmpty)
        #expect(change.canApply)
        #expect(inbox.take() == nil)
    }

    @Test func proposeGraphReportsBadJSONAndKeepsTheInboxEmpty() async throws {
        let space = try await workspace()
        let inbox = ProposalInbox()
        let tool = ProposeGraphTool(workspace: space, inbox: inbox)
        let bad = try await tool.call(arguments: .init(spec: "not json"))
        #expect(!bad.isEmpty)
        #expect(inbox.current == nil)
        let good = try await tool.call(arguments: .init(spec: #"{"nodes":[{"alias":"x","type":"util.number"}],"links":[]}"#))
        #expect(good.contains("util.number") || good.contains("Add"))
        #expect(inbox.current != nil)
    }

    @Test func editValuesReadJSONAndFallBackToAString() {
        #expect(ProposeEditTool.Operation.json(from: "4") == .int(4))
        #expect(ProposeEditTool.Operation.json(from: "true") == .bool(true))
        #expect(ProposeEditTool.Operation.json(from: "\"hi\"") == .string("hi"))
        #expect(ProposeEditTool.Operation.json(from: " hello ") == .string("hello"))
        let op = ProposeEditTool.Operation(op: .connect, from: "n1.value", to: "n3.a").editOperation
        #expect(op.op == .connect && op.from == "n1.value" && op.value == nil)
    }

    @Test func toolSetsStayWithinTheSmallModelBudget() async throws {
        let space = try await workspace()
        #expect(AssistantTools.reading(space).count <= 5)
        #expect(AssistantTools.proposing(space, into: ProposalInbox()).count <= 5)
        let names = AssistantTools.reading(space).map(\.name)
        #expect(Set(names).count == names.count)
    }
}

@Suite struct ModelEndpointTests {
    @Test func onlyOnDeviceAndLoopbackServersStayOnTheDevice() throws {
        #expect(!ModelEndpoint.appleOnDevice.sendsDataOffDevice)
        #expect(ModelEndpoint.applePrivateCloud.sendsDataOffDevice)
        #expect(ModelEndpoint.claude().sendsDataOffDevice)
        func server(_ url: String) throws -> ModelEndpoint {
            .openAICompatible(name: "s", baseURL: try #require(URL(string: url)), model: "m")
        }
        #expect(try !server("http://localhost:11434/v1").sendsDataOffDevice)
        #expect(try !server("http://127.0.0.1:1234/v1").sendsDataOffDevice)
        #expect(try !server("http://[::1]:8080/v1").sendsDataOffDevice)
        // Another computer on the network still reads the graph.
        #expect(try server("http://192.168.1.20:8080/v1").sendsDataOffDevice)
        #expect(try server("https://openrouter.ai/api/v1").sendsDataOffDevice)
        #expect(try server("http://localhost.evil.com/v1").sendsDataOffDevice)
    }

    @Test func keysAreNeededOnlyWhereDataLeavesTheDevice() throws {
        #expect(!ModelEndpoint.appleOnDevice.needsKey)
        #expect(ModelEndpoint.claude().needsKey)
        let byName = Dictionary(uniqueKeysWithValues: ModelEndpoint.presets.map { ($0.name, $0) })
        #expect(try #require(byName["Ollama"]).needsKey == false)
        #expect(try #require(byName["OpenRouter"]).needsKey)
        #expect(try #require(byName["OpenRouter"]).keyAccount == "openrouter")
    }

    @Test func presetsAreLocalOrCloudServersWithAddressesAndNoModelYet() {
        #expect(ModelEndpoint.presets.count >= 4)
        #expect(ModelEndpoint.presets.allSatisfy { $0.kind == .openAICompatible && $0.baseURL != nil && $0.modelName == nil })
        #expect(Set(ModelEndpoint.presets.map(\.id)).count == ModelEndpoint.presets.count)
    }

    @Test func aServerWithoutAModelOrAddressSaysWhatItNeeds() {
        var endpoint = ModelEndpoint.presets[0]
        #expect(endpoint.availability == .unavailable(.notConfigured("a model name")))
        endpoint.modelName = "llama3.1"
        #expect(endpoint.availability == .unavailable(.notImplemented))
        endpoint.baseURL = nil
        #expect(endpoint.availability.summary == "Needs a server address")
    }

    @Test func endpointsSurviveSavingAndLoading() throws {
        let original = ModelEndpoint.openAICompatible(
            name: "Mac Studio", baseURL: try #require(URL(string: "http://localhost:11434/v1")),
            model: "llama3.1", contextTokens: 32_000)
        let copy = try JSONDecoder().decode(ModelEndpoint.self, from: JSONEncoder().encode(original))
        #expect(copy == original)
    }

    @Test func unbuiltKindsSayTheyAreNotAvailableYet() {
        #expect(ModelEndpoint.applePrivateCloud.availability == .unavailable(.notImplemented))
        #expect(ModelEndpoint.claude().availability.summary == "Not available yet")
    }

    @Test func onDeviceAvailabilityIsReportedWithoutCrashing() {
        // The answer depends on the machine; the point is that every state has words for the picker.
        #expect(!ModelEndpoint.appleOnDevice.availability.summary.isEmpty)
        #expect(ModelEndpoint.appleOnDevice.contextTokens < ModelEndpoint.applePrivateCloud.contextTokens)
    }
}
