import Foundation
import NodeGraphAssistant
import NodeGraphCore

extension ProposeEditTool.Operation {
    /// The edit this describes. A value is JSON text; text that is not valid JSON (a model writing
    /// `hello` without quotes) is taken as a string rather than rejected.
    var editOperation: EditOperation {
        EditOperation(
            EditOperation.Kind(rawValue: op.rawValue) ?? .setProperty,
            node: node, property: property, value: value.map(Self.json(from:)), from: from, to: to)
    }

    static func json(from text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return parsed
        }
        return .string(trimmed)
    }
}
