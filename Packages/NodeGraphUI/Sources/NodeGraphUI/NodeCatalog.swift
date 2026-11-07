import NodeGraphCore

/// What the add-node search needs to know about the port a link is being dragged from, so it
/// only offers nodes that link can end on.
public struct PortFilter: Hashable, Sendable {
    /// The dragged port's own direction. A node must have a port of the opposite one.
    public var direction: PortDirection
    public var type: PortType
    public var kind: PortKind

    public init(direction: PortDirection, type: PortType, kind: PortKind) {
        self.direction = direction
        self.type = type
        self.kind = kind
    }

    public init(_ port: PortDefinition) {
        self.init(direction: port.direction, type: port.type, kind: port.kind)
    }
}

/// A node type the user can add.
public struct NodeCatalogEntry: Hashable, Sendable, Identifiable {
    public var id: NodeTypeID { definition.typeID }
    public var definition: NodeDefinition
    public var displayName: String { definition.displayName }
    public var category: String { definition.category.isEmpty ? "Other" : definition.category }
}

/// A search result: an entry, how well it matched, and, when searching for something a link can
/// attach to, the port it would attach to.
public struct NodeCatalogMatch: Hashable, Sendable, Identifiable {
    public var id: NodeTypeID { entry.id }
    public var entry: NodeCatalogEntry
    public var score: Int
    /// The port the dragged link would connect to. Nil for a plain search.
    public var port: PortDefinition?
}

/// The registered node types as a searchable, browsable list.
///
/// Built from a ``NodeRegistry``, so every pack's nodes, and every subgraph definition in the
/// document, show up with no extra registration. Placeholders for missing packs are left out.
public struct NodeCatalog: Sendable {
    /// Categories not offered for adding.
    public static let hiddenCategories: Set<String> = ["Missing"]

    /// All entries, by category then name.
    public let entries: [NodeCatalogEntry]
    private let types: TypeRegistry

    /// - Parameter excluding: Node types to leave out.
    public init(nodes: NodeRegistry, types: TypeRegistry, excluding: Set<NodeTypeID> = []) {
        self.types = types
        entries = nodes.registeredDefinitions
            .filter { !Self.hiddenCategories.contains($0.category) && !excluding.contains($0.typeID) }
            .map(NodeCatalogEntry.init)
            .sorted { ($0.category, $0.displayName) < ($1.category, $1.displayName) }
    }

    /// Entries grouped by category, in order, for browsing.
    public var categories: [(name: String, entries: [NodeCatalogEntry])] {
        var groups: [(name: String, entries: [NodeCatalogEntry])] = []
        for entry in entries {
            if groups.last?.name == entry.category {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((entry.category, [entry]))
            }
        }
        return groups
    }

    /// Entries that match `query`, best first. Every word of the query must match somewhere in
    /// the name, category or type id. An empty query matches everything in browse order.
    ///
    /// With `filter`, only nodes with a port a link from that port could end on are returned,
    /// each carrying the best such port: an identical type before an accepted one before a
    /// converted one.
    public func search(_ query: String, connecting filter: PortFilter? = nil) -> [NodeCatalogMatch] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [NodeCatalogMatch] = []
        for entry in entries {
            var port: PortDefinition?
            if let filter {
                guard let best = bestPort(in: entry, for: filter) else { continue }
                port = best
            }
            guard let score = Self.score(entry, words: words) else { continue }
            matches.append(NodeCatalogMatch(entry: entry, score: score, port: port))
        }
        // A stable sort keeps browse order among equal scores.
        return matches.enumerated().sorted {
            ($1.element.score, $0.offset) < ($0.element.score, $1.offset)
        }.map(\.element)
    }

    private func bestPort(in entry: NodeCatalogEntry, for filter: PortFilter) -> PortDefinition? {
        let wanted: PortDirection = filter.direction == .output ? .input : .output
        let ports = entry.definition.resolved(for: Node(typeID: entry.id)).ports
        var best: (port: PortDefinition, rank: Int)?
        for port in ports where port.direction == wanted && port.kind == filter.kind {
            let connectability = filter.direction == .output
                ? types.connectability(from: filter.type, to: port.type)
                : types.connectability(from: port.type, to: filter.type)
            let rank: Int
            switch connectability {
            case .identical: rank = 0
            case .accepted: rank = 1
            case .converted: rank = 2
            case .incompatible: continue
            }
            if rank < (best?.rank ?? .max) { best = (port, rank) }
        }
        return best?.port
    }

    /// How well `entry` matches every word, or nil if some word matches nothing.
    private static func score(_ entry: NodeCatalogEntry, words: [String]) -> Int? {
        guard !words.isEmpty else { return 0 }
        let name = entry.displayName.lowercased()
        let category = entry.category.lowercased()
        let typeID = entry.id.rawValue.lowercased()
        let nameWords = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var total = 0
        for word in words {
            if name.hasPrefix(word) {
                total += 100
            } else if nameWords.contains(where: { $0.hasPrefix(word) }) {
                total += 80
            } else if name.contains(word) {
                total += 60
            } else if category.contains(word) {
                total += 30
            } else if typeID.contains(word) {
                total += 20
            } else if isSubsequence(word, of: name) {
                total += 10
            } else {
                return nil
            }
        }
        return total
    }

    /// Whether the letters of `word` appear in `text` in order ("sn" in "sine").
    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var remaining = word[...]
        for character in text where character == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
