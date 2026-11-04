/// A generic JSON tree, used to migrate older documents before they are decoded into typed models.
///
/// Integers that fit in `Int64` stay integers, so large IDs and counters survive a migration.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// The object's members, or nil for other cases.
    public var object: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    /// The array's elements, or nil for other cases.
    public var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    /// Reads or writes a member of an object. Reading anything else yields nil; writing to a
    /// non-object is ignored. Assigning nil removes the member.
    public subscript(key: String) -> JSONValue? {
        get { object?[key] }
        set {
            guard case .object(var members) = self else { return }
            members[key] = newValue
            self = .object(members)
        }
    }
}
