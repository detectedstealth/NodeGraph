/// An open, string-backed port type such as `"number"` or `"robot.pose"`.
///
/// Core defines no domain types. Packs register theirs with a ``TypeRegistry``.
/// The only built-in is ``any``, a structural wildcard.
public struct PortType: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: PortType, rhs: PortType) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }

    /// Wildcard that connects to every other type in both directions.
    public static let any = PortType("any")
}
