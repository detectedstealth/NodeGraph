import FoundationModels

extension ModelEndpoint {
    /// What can be known about this endpoint right now, without making a request.
    ///
    /// Only the on-device model is asked the system. The other kinds are not built yet, so a
    /// well-formed one reports `.notImplemented`; a malformed one says what it is missing first.
    public var availability: ModelAvailability {
        switch kind {
        case .appleOnDevice:
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: return .unavailable(.notEnabled)
                case .modelNotReady: return .unavailable(.notReady)
                @unknown default: return .unavailable(.other(String(describing: reason)))
                }
            @unknown default:
                return .unavailable(.other("Unknown"))
            }
        case .applePrivateCloud, .claude:
            return .unavailable(.notImplemented)
        case .openAICompatible:
            if baseURL == nil { return .unavailable(.notConfigured("a server address")) }
            if modelName?.isEmpty ?? true { return .unavailable(.notConfigured("a model name")) }
            return .unavailable(.notImplemented)
        }
    }
}
