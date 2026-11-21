#if !os(tvOS) && !os(watchOS)
import FoundationModels

extension ModelEndpoint {
    /// The answer for the kinds Apple provides: the on-device model asks the system; Private Cloud
    /// Compute is not built yet.
    var systemAvailability: ModelAvailability {
        guard kind == .appleOnDevice else { return .unavailable(.notImplemented) }
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
    }
}
#endif
