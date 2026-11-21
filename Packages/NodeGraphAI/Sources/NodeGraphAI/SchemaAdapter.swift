#if !os(tvOS) && !os(watchOS)
import Foundation
import FoundationModels
import NodeGraphCore

/// Turns a `GenerationSchema` into the JSON Schema a hosted model accepts, and reads the answer back.
///
/// `GenerationSchema` encodes as ordinary JSON Schema. Two things differ for a network API. Structured
/// output wants an object at the root, and several of the stage schemas are an array or a plain
/// choice, so those are wrapped as `{"value": ...}` and unwrapped afterwards. And some servers refuse
/// keywords they do not know, so the one Apple-specific keyword is dropped, and bounds (`minimum`,
/// `maxItems`, ...) are dropped for servers that reject them; the generator already ignores answers
/// that were not offered, so a dropped bound costs nothing.
enum SchemaAdapter {
    struct Prepared: Sendable {
        var schema: JSONValue
        var isWrapped: Bool
    }

    private static let bounds: Set<String> = [
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minItems", "maxItems", "minLength", "maxLength",
    ]

    static func prepare(_ schema: GenerationSchema, stripBounds: Bool) throws -> Prepared {
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        let cleaned = clean(decoded, stripBounds: stripBounds)
        if case .object(let fields) = cleaned, fields["type"] == .string("object") {
            return Prepared(schema: cleaned, isWrapped: false)
        }
        let wrapper: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["value": cleaned]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false),
        ])
        return Prepared(schema: wrapper, isWrapped: true)
    }

    private static func clean(_ value: JSONValue, stripBounds: Bool) -> JSONValue {
        switch value {
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (key, inner) in fields {
                if key == "x-order" || (stripBounds && bounds.contains(key)) { continue }
                result[key] = clean(inner, stripBounds: stripBounds)
            }
            // Servers that validate strictly want every object closed.
            if result["type"] == .string("object") { result["additionalProperties"] = .bool(false) }
            return .object(result)
        case .array(let items):
            return .array(items.map { clean($0, stripBounds: stripBounds) })
        default:
            return value
        }
    }

    /// The JSON text of the answer: the text itself, or its `value` field if the schema was wrapped.
    /// Models sometimes put the JSON in a code fence or after a sentence, so the outermost `{...}` or
    /// `[...]` is taken.
    static func answer(from text: String, wrapped: Bool) throws -> String {
        let json = extractJSON(from: text)
        guard wrapped else { return json }
        guard case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              let value = fields["value"] else {
            throw ProviderError.badResponse("Expected an object with a \"value\" field.")
        }
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))) != nil { return trimmed }
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let start = trimmed.firstIndex(of: Character(open)), let end = trimmed.lastIndex(of: Character(close)), start < end {
                return String(trimmed[start...end])
            }
        }
        return trimmed
    }
}
#endif
