import Foundation
import FoundationModels
import Synchronization
import Testing
import NodeGraphAssistant
import NodeGraphCore
@testable import NodeGraphAI

/// Answers each request from a script and records what was sent.
private final class StubTransport: HTTPTransport {
    enum Reply { case ok(String), status(Int, String, [String: String]), failure(URLError.Code) }
    private let sent = Mutex<[URLRequest]>([])
    private let replies: Mutex<[Reply]>

    init(_ replies: Reply...) { self.replies = Mutex(replies) }

    var requests: [URLRequest] { sent.withLock { $0 } }
    func body(_ index: Int = 0) throws -> [String: JSONValue] {
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: try #require(requests[index].httpBody)) else { return [:] }
        return fields
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.withLock { $0.append(request) }
        let reply = replies.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? .ok("{}")) }
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        switch reply {
        case .ok(let text): return (Data(text.utf8), response(200, [:]))
        case .status(let code, let text, let headers): return (Data(text.utf8), response(code, headers))
        case .failure(let code): throw URLError(code)
        }
    }
}

private let ollama = ModelEndpoint.openAICompatible(
    name: "Ollama", baseURL: URL(string: "http://localhost:11434/v1")!, model: "llama3.1")
private let router = ModelEndpoint.openAICompatible(
    name: "OpenRouter", baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: "anthropic/claude-sonnet-5-5",
    keyAccount: "openrouter")

private func chat(_ content: String, finish: String = "stop") -> String {
    let message: JSONValue = .object(["choices": .array([.object([
        "message": .object(["role": .string("assistant"), "content": .string(content)]),
        "finish_reason": .string(finish),
    ])])])
    return String(decoding: (try? JSONEncoder().encode(message)) ?? Data(), as: UTF8.self)
}

private func claudeReply(_ text: String, stop: String = "end_turn") -> String {
    let message: JSONValue = .object([
        "stop_reason": .string(stop),
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
    ])
    return String(decoding: (try? JSONEncoder().encode(message)) ?? Data(), as: UTF8.self)
}

@Suite struct OpenAICompatibleTests {
    @Test func sendsAChatRequestWithAWrappedSchemaAndReadsTheValueBack() async throws {
        let transport = StubTransport(.ok(chat(#"{"value": ["x.a", "x.b"]}"#)))
        let generator = OpenAICompatibleGenerator(endpoint: router, apiKey: "sk-test", transport: transport)
        let schema = try StageSchemas.nodePick(types: ["x.a", "x.b"], maxNodes: 4)
        let content = try await generator.generate(stage: .pickNodes, prompt: "pick", schema: schema)
        #expect(try content.value([String].self) == ["x.a", "x.b"])

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try transport.body()
        #expect(body["model"] == .string("anthropic/claude-sonnet-5-5"))
        guard case .object(let format)? = body["response_format"], case .object(let spec)? = format["json_schema"],
              case .object(let root)? = spec["schema"] else { Issue.record("no response_format"); return }
        #expect(format["type"] == .string("json_schema"))
        #expect(root["type"] == .string("object"))  // an array root is wrapped
        guard case .object(let properties)? = root["properties"], case .object(let value)? = properties["value"] else { Issue.record("not wrapped"); return }
        #expect(value["type"] == .string("array"))
    }

    @Test func aServerOnThisMachineNeedsNoKeyAndSendsNone() async throws {
        let transport = StubTransport(.ok(chat("It is twelve.")))
        let generator = OpenAICompatibleGenerator(endpoint: ollama, apiKey: nil, transport: transport)
        #expect(try await generator.narrate(prompt: "why") == "It is twelve.")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(transport.requests.first?.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(try transport.body()["response_format"] == nil)
    }

    @Test func aHostedServerWithoutAKeyFailsBeforeSendingAnything() async throws {
        let transport = StubTransport(.ok(chat("x")))
        let generator = OpenAICompatibleGenerator(endpoint: router, apiKey: nil, transport: transport)
        await #expect(throws: ProviderError.missingKey) { try await generator.narrate(prompt: "x") }
        #expect(transport.requests.isEmpty)
    }

    @Test func aServerThatRefusesResponseFormatIsAskedAgainWithTheSchemaInThePrompt() async throws {
        let transport = StubTransport(
            .status(400, #"{"error": {"message": "response_format is not supported"}}"#, [:]),
            .ok(chat("Here you go:\n```json\n{\"value\": \"a.out\"}\n```")))
        let generator = OpenAICompatibleGenerator(endpoint: ollama, apiKey: nil, transport: transport)
        let content = try await generator.generate(stage: .chooseSource(input: "b.in"), prompt: "which", schema: try StageSchemas.source(from: ["a.out"]))
        #expect(try content.value(String.self) == "a.out")
        #expect(transport.requests.count == 2)
        #expect(try transport.body(0)["response_format"] != nil)
        #expect(try transport.body(1)["response_format"] == nil)
        guard case .array(let messages)? = try transport.body(1)["messages"], case .object(let last)? = messages.last,
              case .string(let prompt)? = last["content"] else { Issue.record("no messages"); return }
        #expect(prompt.contains("JSON Schema"))
    }

    @Test func failuresAreMappedToWordsForThePerson() async throws {
        func error(_ reply: StubTransport.Reply) async -> ProviderError? {
            let generator = OpenAICompatibleGenerator(endpoint: ollama, apiKey: nil, transport: StubTransport(reply))
            do { _ = try await generator.narrate(prompt: "x"); return nil } catch { return error as? ProviderError }
        }
        #expect(await error(.status(401, #"{"error": {"message": "bad key"}}"#, [:])) == .unauthorized("bad key"))
        #expect(await error(.status(429, "slow down", ["Retry-After": "30"])) == .rateLimited(retryAfter: 30))
        #expect(await error(.status(400, #"{"error": {"message": "This model's maximum context length is 8192 tokens"}}"#, [:])) == .contextTooLong)
        #expect(await error(.status(500, "boom", [:])) == .server(status: 500, message: "boom"))
        #expect(await error(.failure(.cannotConnectToHost)) == .unreachable("localhost"))
        #expect(await error(.ok(chat("cut off", finish: "length"))) == .incomplete)
        #expect(await error(.ok("{}")) != nil)
        #expect(ProviderError.unreachable("localhost").errorDescription?.contains("localhost") == true)
    }
}

@Suite struct ClaudeGeneratorTests {
    @Test func sendsAMessagesRequestWithJSONOutputAndNoForcedTool() async throws {
        let transport = StubTransport(.ok(claudeReply(#"{"value": ["x.a"]}"#)))
        let generator = ClaudeGenerator(endpoint: .claude(), apiKey: "sk-ant-test", transport: transport)
        let content = try await generator.generate(
            stage: .pickNodes, prompt: "pick", schema: try StageSchemas.nodePick(types: ["x.a", "x.b"], maxNodes: 4))
        #expect(try content.value([String].self) == ["x.a"])

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try transport.body()
        #expect(body["model"] == .string("claude-opus-5-5"))
        #expect(body["tool_choice"] == nil && body["tools"] == nil)  // forced tools 400 on current models
        guard case .object(let output)? = body["output_config"], case .object(let format)? = output["format"] else {
            Issue.record("no output_config.format"); return
        }
        #expect(output["effort"] == .string("low"))
        #expect(format["type"] == .string("json_schema"))
        // Bounds the API rejects are gone, and the array root is wrapped in an object.
        let text = String(decoding: try JSONEncoder().encode(format["schema"]), as: UTF8.self)
        #expect(!text.contains("maxItems") && !text.contains("minItems") && !text.contains("x-order"))
        #expect(text.contains("\"additionalProperties\":false"))
    }

    @Test func narrationSendsNoFormatAndAModelWithoutEffortSupportSendsNone() async throws {
        let transport = StubTransport(.ok(claudeReply("Because it is 4 plus 8.")))
        var old = ModelEndpoint.claude(model: "claude-haiku-4-5")
        old.keyAccount = "claude"
        let generator = ClaudeGenerator(endpoint: old, apiKey: "k", transport: transport)
        #expect(try await generator.narrate(prompt: "why") == "Because it is 4 plus 8.")
        #expect(try transport.body()["output_config"] == nil)
    }

    @Test func effortIsSentOnlyToModelsThatTakeIt() {
        for model in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-4-8", "claude-sonnet-4-6"] {
            #expect(ClaudeGenerator.supportsEffort(model), "\(model)")
        }
        for model in ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-5", "claude-3-7-sonnet"] {
            #expect(!ClaudeGenerator.supportsEffort(model), "\(model)")
        }
    }

    @Test func aRefusalAndACutOffAnswerAreNotReadAsAnswers() async throws {
        for (stop, expected) in [("refusal", ProviderError.refused), ("max_tokens", .incomplete)] {
            let generator = ClaudeGenerator(
                endpoint: .claude(), apiKey: "k", transport: StubTransport(.ok(claudeReply("{}", stop: stop))))
            await #expect(throws: expected) { try await generator.narrate(prompt: "x") }
        }
    }

    @Test func aMissingKeyFailsBeforeSendingAndABadKeyIsReported() async throws {
        let transport = StubTransport(.status(401, #"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}"#, [:]))
        await #expect(throws: ProviderError.missingKey) {
            try await ClaudeGenerator(endpoint: .claude(), apiKey: nil, transport: transport).narrate(prompt: "x")
        }
        #expect(transport.requests.isEmpty)
        await #expect(throws: ProviderError.unauthorized("invalid x-api-key")) {
            try await ClaudeGenerator(endpoint: .claude(), apiKey: "bad", transport: transport).narrate(prompt: "x")
        }
    }
}

@Suite struct SchemaAdapterTests {
    @Test func anObjectRootIsKeptAndAnArrayOrChoiceRootIsWrapped() throws {
        let slots = [PropertySlot(id: "value", title: "Value", shape: .double(min: 0, max: 10), defaultText: "0")]
        let object = try SchemaAdapter.prepare(try StageSchemas.properties(for: slots), stripBounds: true)
        #expect(!object.isWrapped)
        #expect(!String(decoding: try JSONEncoder().encode(object.schema), as: UTF8.self).contains("maximum"))
        let kept = try SchemaAdapter.prepare(try StageSchemas.properties(for: slots), stripBounds: false)
        #expect(String(decoding: try JSONEncoder().encode(kept.schema), as: UTF8.self).contains("maximum"))
        #expect(try SchemaAdapter.prepare(try StageSchemas.nodePick(types: ["a"], maxNodes: 2), stripBounds: true).isWrapped)
        #expect(try SchemaAdapter.prepare(try StageSchemas.source(from: ["a.out"]), stripBounds: true).isWrapped)
    }

    @Test func answersAreReadFromFencesAndSentencesAndUnwrapped() throws {
        #expect(try SchemaAdapter.answer(from: #"{"value": "a"}"#, wrapped: true) == "\"a\"")
        #expect(try SchemaAdapter.answer(from: "Sure!\n```json\n{\"value\": [\"a\", \"b\"]}\n```", wrapped: true) == #"["a","b"]"#)
        #expect(try SchemaAdapter.answer(from: #"{"mode": "a"}"#, wrapped: false) == #"{"mode": "a"}"#)
        #expect(throws: ProviderError.self) { try SchemaAdapter.answer(from: #"{"other": 1}"#, wrapped: true) }
    }
}

@Suite struct EndpointAvailabilityTests {
    @Test func aKeyIsNeededWhereDataLeavesTheDeviceAndOnlyThere() {
        let empty = InMemorySecretStore()
        let withKeys = InMemorySecretStore(["claude": "k", "openrouter": "k"])
        #expect(ModelEndpoint.claude().availability(secrets: empty) == .unavailable(.notConfigured("an API key")))
        #expect(ModelEndpoint.claude().availability(secrets: withKeys) == .available)
        #expect(router.availability(secrets: empty).summary == "Needs an API key")
        #expect(router.availability(secrets: withKeys) == .available)
        #expect(ollama.availability(secrets: empty) == .available)
        #expect(ModelEndpoint.applePrivateCloud.availability(secrets: withKeys) == .unavailable(.notImplemented))
    }

    @Test func aServerMissingItsAddressOrModelSaysWhatItNeeds() {
        var endpoint = ModelEndpoint.presets[0]  // Ollama, no model chosen yet
        #expect(endpoint.availability(secrets: InMemorySecretStore()) == .unavailable(.notConfigured("a model name")))
        endpoint.modelName = "llama3.1"
        #expect(endpoint.availability(secrets: InMemorySecretStore()) == .available)
        endpoint.baseURL = nil
        #expect(endpoint.availability(secrets: InMemorySecretStore()).summary == "Needs a server address")
    }

    @Test func onlyAnAvailableEndpointMakesAGeneratorAndItIsTheRightKind() {
        let empty = InMemorySecretStore()
        let withKeys = InMemorySecretStore(["claude": "k", "openrouter": "k"])
        #expect(ModelEndpoint.claude().makeGenerator(secrets: empty) == nil)
        #expect(ModelEndpoint.claude().makeGenerator(secrets: withKeys) is ClaudeGenerator)
        #expect(router.makeGenerator(secrets: empty) == nil)
        #expect(router.makeGenerator(secrets: withKeys) is OpenAICompatibleGenerator)
        #expect(ollama.makeGenerator(secrets: empty) is OpenAICompatibleGenerator)
        #expect(ModelEndpoint.applePrivateCloud.makeGenerator(secrets: withKeys) == nil)
    }

    @Test func theInMemoryStoreSetsReplacesAndRemovesKeys() throws {
        let store = InMemorySecretStore()
        try store.setSecret("one", for: "a")
        try store.setSecret("two", for: "a")
        #expect(store.secret(for: "a") == "two")
        try store.setSecret("", for: "a")
        #expect(store.secret(for: "a") == nil)
    }
}
