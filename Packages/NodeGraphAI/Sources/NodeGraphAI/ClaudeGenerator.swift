#if !os(tvOS) && !os(watchOS)
import Foundation
import FoundationModels
import NodeGraphCore

/// Answers requests with Claude over `URLSession`, no SDK (decision 214; Swift has no official one).
///
/// Structured stages use `output_config.format` (JSON outputs). A forced tool call is the older way
/// to get JSON back, but the current Opus and Sonnet models reject it with a 400, and JSON outputs
/// work on every current model. That format wants an object at the root with closed objects and no
/// numeric or array bounds, which `SchemaAdapter` provides.
public struct ClaudeGenerator: StructuredGenerator, TextGenerator {
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
        let prepared = try SchemaAdapter.prepare(schema, stripBounds: true)
        let text = try await complete(prompt: prompt, format: prepared.schema)
        let json = try SchemaAdapter.answer(from: text, wrapped: prepared.isWrapped)
        do { return try GeneratedContent(json: json) } catch { throw ProviderError.badResponse("The answer was not valid JSON.") }
    }

    public func narrate(prompt: String) async throws -> String {
        try await complete(prompt: prompt, format: nil)
    }

    /// Whether the model takes `output_config.effort`: the 5.x models and Opus and Sonnet 4.6 and up. Haiku 4.5
    /// and older reject it with a 400.
    static func supportsEffort(_ model: String) -> Bool {
        let generation5 = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5"]
        let generation4 = ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return (generation5 + generation4).contains { model.hasPrefix($0) }
    }

    private func complete(prompt: String, format: JSONValue?) async throws -> String {
        guard let model = endpoint.modelName, !model.isEmpty else { throw ProviderError.badResponse("The model has no name.") }
        guard let apiKey, !apiKey.isEmpty else { throw ProviderError.missingKey }
        let base = endpoint.baseURL ?? URL(string: "https://api.anthropic.com")!

        var output: [String: JSONValue] = [:]
        // These requests are small and mechanical, so spend little thinking on them.
        if Self.supportsEffort(model) { output["effort"] = .string("low") }
        if let format { output["format"] = .object(["type": .string("json_schema"), "schema": format]) }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .int(4096),
            "system": .string(Self.instructions),
            "messages": .array([.object(["role": .string("user"), "content": .string(prompt)])]),
        ]
        if !output.isEmpty { body["output_config"] = .object(output) }

        var request = URLRequest(url: base.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) } catch {
            throw ProviderError.wrap(error, host: base.host() ?? base.absoluteString)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.from(status: response.statusCode, data: data, retryAfter: response.value(forHTTPHeaderField: "retry-after"))
        }
        guard case .object(let top)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let blocks)? = top["content"] else {
            throw ProviderError.badResponse("There was no content in the reply.")
        }
        // A safety decline is a normal reply with this stop reason, and its content may not fit the schema.
        if case .string("refusal")? = top["stop_reason"] { throw ProviderError.refused }
        if case .string("max_tokens")? = top["stop_reason"] { throw ProviderError.incomplete }
        let text = blocks.compactMap { block -> String? in
            guard case .object(let fields) = block, fields["type"] == .string("text"), case .string(let text)? = fields["text"] else { return nil }
            return text
        }.joined()
        guard !text.isEmpty else { throw ProviderError.badResponse("The reply held no text.") }
        return text
    }
}
#endif
