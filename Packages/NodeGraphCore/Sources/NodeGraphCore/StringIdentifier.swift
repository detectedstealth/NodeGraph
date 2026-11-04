/// A string-backed identifier that encodes as a bare JSON string.
public protocol StringIdentifier: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension StringIdentifier {
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }
}
