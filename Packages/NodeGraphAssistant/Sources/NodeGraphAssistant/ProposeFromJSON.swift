import Foundation
import NodeGraphCore

extension AssistantWorkspace {
    /// Proposes the change written in `text`, so a person can try the propose tools without a
    /// model. Three forms are read:
    /// - a ``GraphSpec`` object (`{"nodes": [...], "links": [...]}`), proposed as a generation. An
    ///   optional `"origin": {"x": 400, "y": 600}` puts the new nodes' top-left corner there instead
    ///   of to the right of the graph;
    /// - an array of ``EditOperation``s, proposed as an edit;
    /// - an object `{"operations": [...]}`, the same.
    ///
    /// Throws `AssistantToolError` if the text is not JSON in one of these forms. Problems in
    /// content that does parse (an unknown node type, a bad alias) come back in
    /// ``PendingChange/errors`` instead.
    public func propose(json text: String) throws -> PendingChange {
        // A text box that "smartens" quotes turns them into curly ones, which JSON does not allow.
        let straightened = text
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        let data = Data(straightened.utf8)
        let decoder = JSONDecoder()
        guard let first = straightened.first(where: { !$0.isWhitespace }) else {
            throw AssistantToolError("Nothing to propose. Write a graph spec or a list of edits as JSON.")
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            if first == "[" {
                try Self.requireKnownKeys(operations: parsed as? [Any] ?? [])
                return proposeEdit(try decoder.decode([EditOperation].self, from: data))
            }
            let object = parsed as? [String: Any]
            if let operations = object?["operations"] {
                try Self.requireKnownKeys(operations: operations as? [Any] ?? [])
                struct Edits: Decodable { var operations: [EditOperation] }
                return proposeEdit(try decoder.decode(Edits.self, from: data).operations)
            }
            if let object, !["nodes", "links", "groups"].contains(where: { object[$0] != nil }) {
                throw AssistantToolError("Expected \"nodes\", \"links\", \"groups\" or \"operations\".")
            }
            if let object { try Self.requireKnownKeys(spec: object) }
            return proposeGeneration(try GraphSpec.decode(from: data), at: try Self.origin(in: object))
        } catch let error as AssistantToolError {
            throw error
        } catch {
            throw AssistantToolError("Could not read the JSON: \(Self.readable(error))")
        }
    }

    // MARK: Unknown keys

    /// The keys each kind of edit reads. A key outside the list would be ignored by the decoder,
    /// so a typo or a key from another kind of edit would quietly change what the edit does.
    private static let keysByOperation: [String: [String]] = [
        "setProperty": ["node", "property", "value"],
        "setTitle": ["node", "value"],
        "setMode": ["node", "value"],
        "connect": ["from", "to"],
        "disconnect": ["from", "to"],
        "removeNode": ["node"],
    ]

    private static func requireKnownKeys(operations: [Any]) throws {
        var problems: [String] = []
        for (index, item) in operations.enumerated() {
            guard let operation = item as? [String: Any], let op = operation["op"] as? String,
                  let allowed = keysByOperation[op] else { continue }
            let unknown = operation.keys.filter { $0 != "op" && !allowed.contains($0) }.sorted()
            if !unknown.isEmpty {
                problems.append("Edit \(index + 1) (\(op)) does not use \(quoted(unknown)). It takes \(quoted(allowed)).")
            }
        }
        try throwIfAny(problems)
    }

    private static let specKeys: [(list: String, singular: String, allowed: [String])] = [
        ("nodes", "node", ["alias", "type", "title", "properties", "portCounts", "mode"]),
        ("links", "link", ["from", "to"]),
        ("groups", "group", ["title", "members"]),
    ]

    private static func requireKnownKeys(spec: [String: Any]) throws {
        var problems: [String] = []
        let unknownTop = spec.keys.filter { key in key != "origin" && !specKeys.contains { $0.list == key } }.sorted()
        if !unknownTop.isEmpty {
            problems.append("A graph spec does not use \(quoted(unknownTop)). It takes \(quoted(specKeys.map(\.list) + ["origin"])).")
        }
        for kind in specKeys {
            for (index, item) in (spec[kind.list] as? [Any] ?? []).enumerated() {
                guard let entry = item as? [String: Any] else { continue }
                let unknown = entry.keys.filter { !kind.allowed.contains($0) }.sorted()
                if !unknown.isEmpty {
                    problems.append("In \"\(kind.list)\", \(kind.singular) \(index + 1) does not use \(quoted(unknown)). It takes \(quoted(kind.allowed)).")
                }
            }
        }
        try throwIfAny(problems)
    }

    /// The spec's `"origin"`, or nil when it has none.
    private static func origin(in spec: [String: Any]?) throws -> GraphPoint? {
        guard let raw = spec?["origin"] else { return nil }
        guard let point = raw as? [String: Any], Set(point.keys) == ["x", "y"],
              let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue else {
            throw AssistantToolError("\"origin\" is a point such as {\"x\": 400, \"y\": 600}.")
        }
        return GraphPoint(x: x, y: y)
    }

    private static func quoted(_ keys: [String]) -> String {
        keys.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    private static func throwIfAny(_ problems: [String]) throws {
        if !problems.isEmpty { throw AssistantToolError(problems.joined(separator: "\n")) }
    }

    private static func readable(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

extension AssistantWorkspace {
    /// The output ports of the selected nodes as `alias.port` references, in alias order, for
    /// choosing something to trace or read.
    public func selectedOutputReferences() -> [String] {
        selection.compactMap { id -> [String]? in
            guard let node = graph.nodes[id], let alias = aliases.alias(for: id),
                  let definition = nodes.definition(for: node.typeID) else { return nil }
            return definition.outputs.map { "\(alias).\($0.id.rawValue)" }
        }
        .flatMap { $0 }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
