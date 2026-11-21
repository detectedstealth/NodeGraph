#if !os(tvOS) && !os(watchOS)
/// What every provider offers the generation and explain features.
public typealias ModelGenerator = StructuredGenerator & TextGenerator

extension ModelEndpoint {
    /// What can be known about this endpoint without making a request, given the stored keys.
    ///
    /// Reachability, a rejected key and quota only show when a request is made. Private Cloud
    /// Compute is not built yet.
    public func availability(secrets: any SecretStore) -> ModelAvailability {
        switch kind {
        case .appleOnDevice, .applePrivateCloud:
            return systemAvailability
        case .claude:
            if modelName?.isEmpty ?? true { return .unavailable(.notConfigured("a model name")) }
            return hasKey(in: secrets) ? .available : .unavailable(.notConfigured("an API key"))
        case .openAICompatible:
            if baseURL == nil { return .unavailable(.notConfigured("a server address")) }
            if modelName?.isEmpty ?? true { return .unavailable(.notConfigured("a model name")) }
            if needsKey && !hasKey(in: secrets) { return .unavailable(.notConfigured("an API key")) }
            return .available
        }
    }

    private func hasKey(in secrets: any SecretStore) -> Bool {
        guard let account = keyAccount else { return false }
        return !(secrets.secret(for: account)?.isEmpty ?? true)
    }

    /// A generator for this endpoint, or nil if it cannot answer right now (see ``availability(secrets:)``).
    public func makeGenerator(
        secrets: any SecretStore = KeychainSecretStore(), transport: any HTTPTransport = URLSessionTransport()
    ) -> (any ModelGenerator)? {
        guard availability(secrets: secrets).isAvailable else { return nil }
        let key = keyAccount.flatMap { secrets.secret(for: $0) }
        switch kind {
        case .appleOnDevice: return SessionGenerator.onDevice
        case .claude: return ClaudeGenerator(endpoint: self, apiKey: key, transport: transport)
        case .openAICompatible: return OpenAICompatibleGenerator(endpoint: self, apiKey: key, transport: transport)
        case .applePrivateCloud: return nil
        }
    }
}
#endif
