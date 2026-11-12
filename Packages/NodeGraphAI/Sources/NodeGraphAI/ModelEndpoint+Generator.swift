extension ModelEndpoint {
    /// A generator for this endpoint, or nil if it cannot answer right now (see ``availability``).
    ///
    /// Only the on-device model has one so far; the other kinds arrive with steps D and E.
    public func makeGenerator() -> SessionGenerator? {
        guard availability.isAvailable else { return nil }
        switch kind {
        case .appleOnDevice: return .onDevice
        case .applePrivateCloud, .claude, .openAICompatible: return nil
        }
    }
}
