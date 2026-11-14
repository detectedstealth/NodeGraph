import Foundation
import FoundationModels
import NodeGraphCore

/// Answers requests with any server that speaks the OpenAI chat-completions API: OpenAI,
/// OpenRouter, Ollama, LM Studio, llama.cpp's server, vLLM and the like (decision 235).
///
/// Structured stages ask for `response_format: json_schema`. Servers differ in whether they accept
/// it, so a refusal of that field (HTTP 400) is retried once with the schema written into the prompt
/// instead, and whatever JSON the answer contains is read. Plain narration needs neither.
public struct OpenAICompatibleGenerator: StructuredGenerator, TextGenerator {
    public var endpoint: ModelEndpoint
    private let apiKey: String?
    private let transport: any HTTPTransport

    public init(endpoint: ModelEndpoint, apiKey: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
    }

    static let instructions = "You help with node graphs. Use only the options and facts you are given."

    public func generate(stage: GenerationStage, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        let prepared = try SchemaAdapter.prepare(schema, stripBounds: false)
        let format: JSONValue = .object([
            "type": .string("json_schema"),
            "json_schema": .object(["name": .string("result"), "schema": prepared.schema]),
        ])
        let text: String
        do {
            text = try await complete(prompt: prompt, responseFormat: format)
        } catch ProviderError.server(let status, _) where status == 400 || status == 422 {
            // The server does not take response_format: describe the schema in the prompt instead.
            let schemaText = String(decoding: try JSONEncoder().encode(prepared.schema), as: UTF8.self)
            let instructed = prompt + "\n\nReply with only JSON that matches this JSON Schema, and nothing else:\n" + schemaText
            text = try await complete(prompt: instructed, responseFormat: nil)
        }
        let json = try SchemaAdapter.answer(from: text, wrapped: prepared.isWrapped)
        do { return try GeneratedContent(json: json) } catch { throw ProviderError.badResponse("The answer was not valid JSON.") }
    }

    public func narrate(prompt: String) async throws -> String {
        try await complete(prompt: prompt, responseFormat: nil)
    }

    private func complete(prompt: String, responseFormat: JSONValue?) async throws -> String {
        guard let base = endpoint.baseURL, let model = endpoint.modelName, !model.isEmpty else {
            throw ProviderError.badResponse("The model has no address or name.")
        }
        if endpoint.needsKey, apiKey?.isEmpty ?? true { throw ProviderError.missingKey }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(Self.instructions)]),
                .object(["role": .string("user"), "content": .string(prompt)]),
            ]),
        ]
        if let responseFormat { body["response_format"] = responseFormat }

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) } catch {
            throw ProviderError.wrap(error, host: base.host() ?? base.absoluteString)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.from(status: response.statusCode, data: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
        guard case .object(let top)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let choices)? = top["choices"], case .object(let first)? = choices.first,
              case .object(let message)? = first["message"], case .string(let content)? = message["content"] else {
            throw ProviderError.badResponse("There was no message in the reply.")
        }
        if case .string("length")? = first["finish_reason"] { throw ProviderError.incomplete }
        return content
    }
}
