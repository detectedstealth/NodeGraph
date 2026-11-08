/// Identifies a property within one node definition.
public struct PropertyID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One option of a ``PropertyKind/choice(_:)`` property.
public struct PropertyChoice: Hashable, Sendable, Codable {
    /// Stored value; compared against `GraphValue.string`.
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// The type and constraints of a property. Drives validation, the inspector and in-node widgets.
public enum PropertyKind: Hashable, Sendable, Codable {
    case bool
    case int(min: Int64? = nil, max: Int64? = nil, step: Int64? = nil)
    case double(min: Double? = nil, max: Double? = nil, step: Double? = nil)
    case string(multiline: Bool = false)
    case choice([PropertyChoice])
    /// The name of a graph variable (see ``GraphVariable``), stored as `GraphValue.string`. The
    /// editor offers the graph's variables to pick from, and
    /// ``GraphEditor/renameVariableCommand(from:to:)`` follows a renamed variable by rewriting
    /// every node property of this kind that holds the old name.
    case variable
    case color
    /// A fixed-length vector of doubles.
    case vector(dimension: Int)
    /// A pack-defined kind identified by name, stored as any ``GraphValue``.
    case custom(String)
}

/// Why a value was rejected by a ``PropertyDefinition``.
public enum PropertyValidationError: Error, Hashable, Sendable {
    case typeMismatch(expected: String)
    case outOfRange
    case notAChoice(String)
    case wrongDimension(expected: Int, actual: Int)
}

/// A typed, schema-described node setting.
public struct PropertyDefinition: Hashable, Sendable, Codable {
    public var id: PropertyID
    public var displayName: String
    public var kind: PropertyKind
    public var defaultValue: GraphValue

    public init(id: PropertyID, displayName: String, kind: PropertyKind, defaultValue: GraphValue) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.defaultValue = defaultValue
    }

    /// Throws if `value` does not satisfy ``kind``.
    ///
    /// Numeric kinds are strict: `.int` properties take `.int`, `.double` properties take
    /// `.double`. Non-finite doubles are out of range.
    public func validate(_ value: GraphValue) throws {
        switch (kind, value) {
        case (.bool, .bool), (.color, .color), (.string, .string), (.variable, .string), (.custom, _):
            return
        case (.int(let min, let max, _), .int(let v)):
            if let min, v < min { throw PropertyValidationError.outOfRange }
            if let max, v > max { throw PropertyValidationError.outOfRange }
        case (.double(let min, let max, _), .double(let v)):
            guard v.isFinite else { throw PropertyValidationError.outOfRange }
            if let min, v < min { throw PropertyValidationError.outOfRange }
            if let max, v > max { throw PropertyValidationError.outOfRange }
        case (.choice(let choices), .string(let s)):
            guard choices.contains(where: { $0.value == s }) else {
                throw PropertyValidationError.notAChoice(s)
            }
        case (.vector(let dimension), .vector(let v)):
            guard v.count == dimension else {
                throw PropertyValidationError.wrongDimension(expected: dimension, actual: v.count)
            }
        default:
            throw PropertyValidationError.typeMismatch(expected: kind.expectedTypeName)
        }
    }

    /// Whether ``validate(_:)`` accepts `value`.
    public func isValid(_ value: GraphValue) -> Bool {
        (try? validate(value)) != nil
    }

    /// Returns `value` limited to the kind's min/max, or unchanged for non-numeric kinds.
    public func clamped(_ value: GraphValue) -> GraphValue {
        switch (kind, value) {
        case (.int(let min, let max, _), .int(let v)):
            var r = v
            if let min { r = Swift.max(r, min) }
            if let max { r = Swift.min(r, max) }
            return .int(r)
        case (.double(let min, let max, _), .double(let v)) where !v.isNaN:
            var r = v
            if let min { r = Swift.max(r, min) }
            if let max { r = Swift.min(r, max) }
            return .double(r)
        default:
            return value
        }
    }
}

extension PropertyKind {
    fileprivate var expectedTypeName: String {
        switch self {
        case .bool: "bool"
        case .int: "int"
        case .double: "double"
        case .string, .choice, .variable: "string"
        case .color: "color"
        case .vector: "vector"
        case .custom: "any"
        }
    }
}
