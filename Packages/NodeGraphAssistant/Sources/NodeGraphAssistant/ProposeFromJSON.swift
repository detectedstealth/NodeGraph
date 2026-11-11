import Foundation
import NodeGraphCore

extension AssistantWorkspace {
    /// Proposes the change written in `text`, so a person can try the propose tools without a
    /// model. Three forms are read:
    /// - a ``GraphSpec`` object (`{"nodes": [...], "links": [...]}`), proposed as a generation;
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
            if first == "[" {
                return proposeEdit(try decoder.decode([EditOperation].self, from: data))
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["operations"] != nil {
                struct Edits: Decodable { var operations: [EditOperation] }
                return proposeEdit(try decoder.decode(Edits.self, from: data).operations)
            }
            if let object, !["nodes", "links", "groups"].contains(where: { object[$0] != nil }) {
                throw AssistantToolError("Expected \"nodes\", \"links\", \"groups\" or \"operations\".")
            }
            return proposeGeneration(try GraphSpec.decode(from: data))
        } catch let error as AssistantToolError {
            throw error
        } catch {
            throw AssistantToolError("Could not read the JSON: \(Self.readable(error))")
        }
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
