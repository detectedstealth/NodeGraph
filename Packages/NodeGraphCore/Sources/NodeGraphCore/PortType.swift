/// An open, string-backed port type such as `"number"` or `"robot.pose"`.
///
/// Core defines no domain types. Packs register theirs with a ``TypeRegistry``.
/// The only built-in is ``any``, a structural wildcard.
public struct PortType: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Wildcard that connects to every other type in both directions.
    public static let any = PortType("any")
}
