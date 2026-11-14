import Foundation

/// A model the assistant can run on, with the settings that make one usable (decision 227).
///
/// The assistant talks to every endpoint through `LanguageModelSession` (decision 212), so an
/// endpoint is a choice of model, not a different code path. A person can keep several, for
/// example a local Ollama model and an OpenRouter one. Secrets are never stored here:
/// ``keyAccount`` only names the Keychain item.
public struct ModelEndpoint: Hashable, Sendable, Codable, Identifiable {
    /// The protocol an endpoint is reached with.
    public enum Kind: String, CaseIterable, Hashable, Sendable, Codable {
        /// Apple's on-device model. The default: no network, no limits, no setup.
        case appleOnDevice
        /// Apple Private Cloud Compute. Needs a managed entitlement (decision 214).
        case applePrivateCloud
        /// Claude over `URLSession`, with the user's own API key.
        case claude
        /// Any server that speaks the OpenAI chat-completions API: OpenAI, OpenRouter, Ollama,
        /// LM Studio, llama.cpp's server, vLLM and the like.
        case openAICompatible
    }

    public var id: String
    public var kind: Kind
    /// What the picker shows.
    public var name: String
    /// The server's base URL, for the kinds that have one.
    public var baseURL: URL?
    /// The model to ask the server for, like `llama3.1` or `anthropic/claude-sonnet-4`.
    public var modelName: String?
    /// The context window in tokens. Sizes the graph digest, so a wrong value either wastes
    /// context or overflows it.
    public var contextTokens: Int
    /// The Keychain account holding this endpoint's API key, if it needs one.
    public var keyAccount: String?

    public init(
        id: String = UUID().uuidString, kind: Kind, name: String, baseURL: URL? = nil,
        modelName: String? = nil, contextTokens: Int, keyAccount: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.modelName = modelName
        self.contextTokens = contextTokens
        self.keyAccount = keyAccount
    }

    // MARK: Privacy

    /// Whether a request leaves this device. The UI says so before anything is sent.
    ///
    /// A server on this machine (`localhost`, `127.0.0.1`, `::1`) stays on the device. One on the
    /// local network does not: another computer reads the graph.
    public var sendsDataOffDevice: Bool {
        switch kind {
        case .appleOnDevice: false
        case .applePrivateCloud, .claude: true
        case .openAICompatible: !(baseURL?.isLoopback ?? false)
        }
    }

    /// Whether the endpoint needs an API key before it can be used.
    public var needsKey: Bool { kind == .claude || (kind == .openAICompatible && sendsDataOffDevice) }

    // MARK: Standard endpoints

    public static let appleOnDevice = ModelEndpoint(
        id: "apple.onDevice", kind: .appleOnDevice, name: "Apple (on this device)", contextTokens: 4_096)

    public static let applePrivateCloud = ModelEndpoint(
        id: "apple.privateCloud", kind: .applePrivateCloud, name: "Apple Private Cloud Compute", contextTokens: 32_768)

    public static func claude(model: String = "claude-opus-5-5") -> ModelEndpoint {
        ModelEndpoint(
            id: "claude", kind: .claude, name: "Claude", baseURL: URL(string: "https://api.anthropic.com"),
            modelName: model, contextTokens: 200_000, keyAccount: "claude")
    }

    /// A server that speaks the OpenAI chat-completions API.
    public static func openAICompatible(
        name: String, baseURL: URL, model: String, contextTokens: Int = 8_192, keyAccount: String? = nil
    ) -> ModelEndpoint {
        ModelEndpoint(
            kind: .openAICompatible, name: name, baseURL: baseURL, modelName: model,
            contextTokens: contextTokens, keyAccount: keyAccount)
    }

    /// Starting points for the add-endpoint form. The model name is left for the person to fill in.
    public static let presets: [ModelEndpoint] = [
        preset("Ollama", "http://localhost:11434/v1"),
        preset("LM Studio", "http://localhost:1234/v1"),
        preset("OpenAI", "https://api.openai.com/v1", keyAccount: "openai"),
        preset("OpenRouter", "https://openrouter.ai/api/v1", keyAccount: "openrouter"),
    ]

    private static func preset(_ name: String, _ url: String, keyAccount: String? = nil) -> ModelEndpoint {
        ModelEndpoint(
            id: "preset." + name, kind: .openAICompatible, name: name, baseURL: URL(string: url),
            modelName: nil, contextTokens: 8_192, keyAccount: keyAccount)
    }
}

extension URL {
    /// Whether the host is this machine.
    var isLoopback: Bool {
        guard let host = host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }
}

/// Why an endpoint cannot be used right now, in terms the UI can word and act on.
public enum ModelUnavailableReason: Hashable, Sendable {
    /// This device cannot run the model.
    case deviceNotEligible
    /// The person has not turned the feature on in Settings.
    case notEnabled
    /// The model is still downloading or preparing.
    case notReady
    /// The endpoint lacks something it needs (a server address or a model name), named here.
    case notConfigured(String)
    /// The kind of endpoint is not built yet (steps D and E).
    case notImplemented
    /// Something else, with the system's own description.
    case other(String)
}

/// Whether an endpoint can answer, as plain data so views and tests need no model.
///
/// This is what can be known without a request. Whether a server is reachable, the key is
/// accepted or the quota is spent only shows when a request is made.
public enum ModelAvailability: Hashable, Sendable {
    case available
    case unavailable(ModelUnavailableReason)

    public var isAvailable: Bool { self == .available }

    /// One line for the model picker.
    public var summary: String {
        switch self {
        case .available: "Ready"
        case .unavailable(.deviceNotEligible): "This device can't run the model"
        case .unavailable(.notEnabled): "Turn on Apple Intelligence in Settings"
        case .unavailable(.notReady): "The model is still getting ready"
        case .unavailable(.notConfigured(let what)): "Needs \(what)"
        case .unavailable(.notImplemented): "Not available yet"
        case .unavailable(.other(let text)): text
        }
    }
}
