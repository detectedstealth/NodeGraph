import Foundation

/// An opaque, `UUID`-backed identifier. Safe to mint offline and merge on a server.
///
/// Identifiers encode as a single UUID string and sort by that string, so serialized
/// output can be made deterministic.
public protocol GraphIdentifier: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    var uuid: UUID { get }
    init(uuid: UUID)
}

extension GraphIdentifier {
    /// Creates a new random identifier.
    public init() {
        self.init(uuid: UUID())
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(uuid: try container.decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    public var description: String { uuid.uuidString }
}

/// Identifies a node instance within a graph.
public struct NodeID: GraphIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// Identifies a link within a graph.
public struct LinkID: GraphIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// Identifies a group within a graph.
public struct GroupID: GraphIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}
